# CrimeManager.gd
# Autoload singleton - registered AFTER LawDatabase in project.godot.
#
# The crime MECHANISM (LawDatabase is the policy). Phase 4 scope
# (docs/law_crime_stealth_plan.md): attribute the actor (summon -> summoner),
# resolve jurisdiction from the current map, evaluate legality, debounce,
# write GameLog, emit crime_committed. Phase 5 builds the witness fan-out and
# outcry on top of report(); nothing here blocks an action.
#
# Two-function contract so no call site contains policy:
#   preview(actor, verb, payload) -> {} | Verdict     side-effect free
#   report(actor, verb, payload)  -> void             logs + emits, debounced
#
# Crimes are REPORTED, never blocked — the one exception is the cast
# confirmation (cast_needs_confirmation), which refuses a severe cast exactly
# once per map so a misclick cannot commit a capital crime.
extends Node

signal crime_committed(actor: Node, verdict: Dictionary, payload: Dictionary)
## An enforcer actually HEARD an alarm (or witnessed as the law themselves).
## Phase 6 hangs standing/hostility/ledger off this; Phase 5 dedups and logs.
signal crime_reported(enforcer: Node, payload: Dictionary)

## How close a character must be to take a world item or open a container.
## Also enforced by Game.pick_up_item / show_chest_inventory (1.5 tiles).
const PICKUP_REACH: float = 96.0

## A melee exchange is one crime, not one per damage application. Keyed per
## (statute, actor, target) so an assault escalating to murder still lands.
const DEBOUNCE_WINDOW: float = 2.0
var _recent_reports: Dictionary = {}  # "statute|actor_iid|target_iid" -> absolute_time

# Cast-confirmation state: the first severely-illegal cast on a map is
# refused with a GameLog warning; casting again confirms, and a confirmation
# stops the asking for the rest of the map visit.
var _pending_cast_confirms: Dictionary = {}  # "map_id|ability_id" -> true
var _confirmed_cast_maps: Dictionary = {}    # map_id -> true

func _ready() -> void:
	# The `wanted` condition on the protagonist is a pure display derivative
	# of FactionDatabase's hostile override — derived here (an autoload, so
	# it works identically under the real Game and test harnesses).
	FactionDatabase.player_standing_changed.connect(_on_player_standing_changed)

func _on_player_standing_changed(_faction_id: String, _old_value: int, _new_value: int) -> void:
	var game = get_tree().current_scene
	if game == null or not ("party_chars" in game) or game.party_chars.is_empty():
		return
	var protagonist = game.party_chars[0]
	if not is_instance_valid(protagonist):
		return
	var cm = protagonist.get_node_or_null("ConditionManager")
	if cm == null:
		return
	if FactionDatabase.is_outlaw_anywhere():
		if not cm.has_condition("wanted"):
			cm.apply_condition("wanted", null, 1, -1.0)
	elif cm.has_condition("wanted"):
		cm.remove_condition("wanted")

# Witness pipeline (Phase 5)
var _crime_counter: int = 0
var _recorded_crimes: Dictionary = {}  # crime_id -> true (one report per crime)

# Consequence + thrill tracking (Phase 6)
# _open_crimes: crime_id -> {actor, fuses, resolved, escaped, thrill_key}.
# A crime "gets away clean" when every fuse resolved and none fired — the
# thrill_of_sin reward is for BEATING the fuse, not for the absence of one.
var _open_crimes: Dictionary = {}
var _thrill_granted: Dictionary = {}   # "verb|target_iid" -> true (anti-farming)

# ---------------------------------------------------------------------------
# The two-function contract
# ---------------------------------------------------------------------------

## Side-effect free. {} when legal (or when legality does not apply: actor's
## faction outside laws.json applies_to, no jurisdiction here, lawless code).
func preview(actor, verb: String, payload: Dictionary) -> Dictionary:
	var effective = attribute(actor)
	if effective == null or not is_instance_valid(effective) or not ("faction_id" in effective):
		return {}
	if not str(effective.faction_id) in LawDatabase.applies_to():
		return {}
	var law_faction: String = str(payload.get("law_faction", ""))
	if law_faction.is_empty():
		law_faction = current_law_faction()
	if law_faction.is_empty():
		return {}
	var code: String = LawDatabase.code_for_faction(law_faction)
	if code.is_empty():
		return {}
	var enriched: Dictionary = payload.duplicate()
	enriched["law_faction"] = law_faction
	return LawDatabase.evaluate(code, verb, enriched)

## Evaluate and, if criminal, log + emit. Never blocks the action; callers
## invoke it AFTER the act succeeds (a refused pickup is not a theft).
func report(actor, verb: String, payload: Dictionary) -> void:
	var verdict: Dictionary = preview(actor, verb, payload)
	if verdict.is_empty():
		return
	var effective = attribute(actor)
	var target_iid: int = 0
	var target = payload.get("debounce_target")
	if target is Object and is_instance_valid(target):
		target_iid = target.get_instance_id()
	var key: String = "%s|%d|%d" % [str(verdict.get("statute", "")), effective.get_instance_id(), target_iid]
	var now: float = TimeManager.absolute_time()
	var last: float = float(_recent_reports.get(key, -1.0e12))
	if now - last < DEBOUNCE_WINDOW:
		return
	_recent_reports[key] = now
	var actor_name: String = str(effective.Name) if ("Name" in effective) else "Someone"
	GameLog.add_entry("%s commits %s (severity %d) — a crime under the law of %s." % [
		actor_name, str(verdict.get("display_name", "?")), int(verdict.get("severity", 0)),
		str(verdict.get("law_faction", "?"))])
	crime_committed.emit(effective, verdict, payload)
	_fan_out_witnesses(effective, actor, verdict, payload)

# ---------------------------------------------------------------------------
# Attribution and jurisdiction
# ---------------------------------------------------------------------------

## Summons act on their summoner's behalf: AbilityEffect._resolve_summon
## stamps `summoned_by` meta, and crimes walk that chain — otherwise a rat
## pack can massacre a town and only the (despawning) rats are guilty.
func attribute(actor) -> Node:
	var effective = actor
	var hops: int = 0
	while effective is Object and is_instance_valid(effective) \
			and effective.has_meta("summoned_by") and hops < 8:
		var summoner = effective.get_meta("summoned_by")
		if not (summoner is Object) or not is_instance_valid(summoner):
			break
		effective = summoner
		hops += 1
	return effective as Node

## The law faction of the map the game is currently on ("" = lawless).
## Reads current_map_id off the current scene, so a test harness that
## exposes current_map_id is a full stand-in for Game.
func current_law_faction() -> String:
	var game = get_tree().current_scene
	if game == null or not ("current_map_id" in game):
		return ""
	return LawDatabase.jurisdiction_for_map(str(game.current_map_id))

# ---------------------------------------------------------------------------
# Payload builders — call sites stay one-liners and carry no policy
# ---------------------------------------------------------------------------

func cast_payload(ability) -> Dictionary:
	var ability_traits: Dictionary = {}
	if ability != null and ("traits" in ability) and ability.traits is Dictionary:
		ability_traits = ability.traits
	return {"traits": ability_traits}

func attack_payload(actor, victim) -> Dictionary:
	var victim_faction: String = str(victim.faction_id) if ("faction_id" in victim) else ""
	var effective = attribute(actor)
	var actor_faction: String = str(effective.faction_id) if (effective != null and "faction_id" in effective) else ""
	var lethal: bool = true
	if victim.has_method("is_alive"):
		lethal = not victim.is_alive()
	var crime_elev: float = 0.0
	if victim.has_method("get_elevation"):
		crime_elev = float(victim.get_elevation())
	return {
		"victim_faction": victim_faction,
		# Self-defence carve-out: no charge for fighting someone already
		# hostile to you (faction-level; the Phase 1 oracle).
		"victim_hostile_to_actor": FactionDatabase.are_hostile(victim_faction, actor_faction),
		"lethal": lethal,
		"victim": victim,
		"crime_pos": victim.global_position if victim is Node2D else Vector2.INF,
		"crime_elev": crime_elev,
		"debounce_target": victim,
	}

func take_payload(item) -> Dictionary:
	return {
		"owner_faction": str(item.owner_faction) if ("owner_faction" in item) else "",
		"item_cost": float(item.cost) if ("cost" in item) else 0.0,
		"crime_pos": item.global_position if item is Node2D else Vector2.INF,
		"debounce_target": item,
	}

func loot_payload(chest) -> Dictionary:
	var payload: Dictionary = take_payload(chest)
	return payload

# ---------------------------------------------------------------------------
# Cast confirmation (the one refusal in the system)
# ---------------------------------------------------------------------------

## {} = cast may proceed. Otherwise {verdict} — refuse this once. Legality is
## jurisdiction-dependent and invisible, so committing a capital crime by
## misclick is worse than a prompt; but the prompt is cast-again-to-confirm,
## and a confirmation holds for the rest of the map visit.
func cast_needs_confirmation(actor, ability) -> Dictionary:
	var verdict: Dictionary = preview(actor, "cast", cast_payload(ability))
	if verdict.is_empty():
		return {}
	if int(verdict.get("severity", 0)) < LawDatabase.confirm_threshold():
		return {}
	var game = get_tree().current_scene
	var map_id: String = str(game.current_map_id) if (game != null and "current_map_id" in game) else ""
	if bool(_confirmed_cast_maps.get(map_id, false)):
		return {}
	var ability_id: String = str(ability.id) if (ability != null and "id" in ability) else "?"
	var key: String = "%s|%s" % [map_id, ability_id]
	if bool(_pending_cast_confirms.get(key, false)):
		_pending_cast_confirms.erase(key)
		_confirmed_cast_maps[map_id] = true
		return {}
	_pending_cast_confirms[key] = true
	return {"verdict": verdict}

# ---------------------------------------------------------------------------
# Witness pipeline (Phase 5) — the centerpiece
# ---------------------------------------------------------------------------

## THE witness-LOS helper — the canonical wrapper the audit found split into
## two disagreeing copies (Game._has_visual_los had no target_elev; ai.gd had
## no blinded check). Game delegates here now; both fixes live in one place.
func has_visual_los(from_char, target_pos: Vector2, target_elev: float = 0.0) -> bool:
	if not is_instance_valid(from_char) or not from_char.has_method("is_alive") or not from_char.is_alive():
		return false
	var cm = from_char.get_node_or_null("ConditionManager")
	if cm and (cm.has_condition("blinded") or cm.has_condition("unconscious")):
		return false
	var to_target: Vector2 = target_pos - from_char.global_position
	var dist: float = to_target.length()
	if dist > 1440.0 * from_char.sight:
		return false
	var facing_dir: Vector2 = Vector2.UP.rotated(from_char.rotation)
	var angle: float = facing_dir.angle_to(to_target.normalized())
	if absf(angle) > deg_to_rad(from_char.fov_angle_degrees * 0.5):
		return false
	var tree := get_tree()
	if tree == null or tree.root == null or tree.root.world_2d == null:
		return true
	var viewer_elev: float = 0.0
	if from_char.has_method("get_elevation"):
		viewer_elev = float(from_char.get_elevation())
	return GridManager.sight_line_clear(tree.root.world_2d.direct_space_state,
		from_char.global_position, target_pos, viewer_elev, target_elev)

## Everyone who saw the crime POSITION (they saw *something happen*), with a
## second LOS test against the ACTOR (identification). Two tests, not one —
## a single witness-to-actor test makes every ranged/AoE crime free: stand
## behind cover, creepy_beam a merchant, and "no witness exists".
## Skips: the actor, party members (player-controlled), the dead.
func witnesses_of(crime_pos: Vector2, crime_elev: float, physical_actor) -> Array:
	var out: Array = []
	var game = get_tree().current_scene
	if game == null or not ("characters_in_scene" in game):
		return out
	var party: Array = game.party_chars if ("party_chars" in game) else []
	var actor_pos: Vector2 = Vector2.INF
	var actor_elev: float = 0.0
	if physical_actor is Node2D and is_instance_valid(physical_actor):
		actor_pos = physical_actor.global_position
		if physical_actor.has_method("get_elevation"):
			actor_elev = float(physical_actor.get_elevation())
	for c in game.characters_in_scene:
		if not is_instance_valid(c) or c == physical_actor:
			continue
		if c in party:
			continue
		if not c.has_method("is_alive") or not c.is_alive():
			continue
		if c.get_node_or_null("AI") == null:
			continue
		if not has_visual_los(c, crime_pos, crime_elev):
			continue
		var sees_actor: bool = false
		if actor_pos != Vector2.INF:
			sees_actor = has_visual_los(c, actor_pos, actor_elev)
		out.append({"witness": c, "sees_actor": sees_actor})
	return out

func _fan_out_witnesses(effective: Node, physical_actor, verdict: Dictionary, payload: Dictionary) -> void:
	var crime_pos: Vector2 = payload.get("crime_pos", Vector2.INF)
	if crime_pos == Vector2.INF:
		if physical_actor is Node2D and is_instance_valid(physical_actor):
			crime_pos = physical_actor.global_position
		else:
			return
	var crime_elev: float = float(payload.get("crime_elev", 0.0))
	_crime_counter += 1
	var crime_id: int = _crime_counter
	var disguised: bool = is_disguised(physical_actor)
	var cfg: Dictionary = LawDatabase.witness_cfg()
	var victim = payload.get("victim")
	# Corpse discovery (Phase 7): a body dropped by a crime carries the
	# charge — stamped BEFORE the zero-witness early-out, because the
	# unwitnessed murder is exactly the case discovery exists for. Shares
	# the crime_id, so a crime whose alarm already escaped dedups away.
	if bool(payload.get("lethal", false)) and victim is Object and is_instance_valid(victim):
		victim.set_meta("corpse_crime", {
			"crime_id": crime_id,
			"law_faction": str(verdict.get("law_faction", "")),
			"statute": str(verdict.get("statute", "")),
			"display_name": str(verdict.get("display_name", "")),
			"severity": int(verdict.get("severity", 0)),
			"discovered": false,
		})
	var victim_covered: bool = false
	var fuses: int = 0
	for entry in witnesses_of(crime_pos, crime_elev, physical_actor):
		var witness = entry["witness"]
		var is_victim: bool = witness == victim
		# D7: LOS to the actor means identified UNLESS disguised. The victim
		# is forced identified — they were touched; contact beats costume.
		var identified: bool = (bool(entry["sees_actor"]) and not disguised) or is_victim
		if is_victim:
			victim_covered = true
		_start_outcry(witness, crime_id, identified, is_victim, crime_pos, effective, verdict, cfg)
		fuses += 1
	# The victim is a witness even with no LOS at fan-out time (face-down,
	# blinded, hit from behind) — the one person guaranteed to know about an
	# assault must be able to report it.
	if not victim_covered and victim is Object and is_instance_valid(victim) \
			and victim != physical_actor and victim.has_method("is_alive") and victim.is_alive() \
			and victim.get_node_or_null("AI") != null:
		_start_outcry(victim, crime_id, true, true, crime_pos, effective, verdict, cfg)
		fuses += 1
	if fuses == 0:
		# Legibility: absence-as-feedback is unteachable. This line is how
		# the player learns the witness system exists at all.
		if physical_actor is Node2D and is_instance_valid(physical_actor):
			Globals.show_floating_text("Unseen.", physical_actor.global_position, physical_actor, Color(0.7, 0.7, 0.7))
		GameLog.add_entry("No one saw it.")
		return
	# Track open fuses for the thrill_of_sin grant and the all-clear line.
	var target = payload.get("debounce_target")
	var target_iid: int = target.get_instance_id() if (target is Object and is_instance_valid(target)) else 0
	_open_crimes[crime_id] = {
		"actor": effective,
		"fuses": fuses,
		"resolved": 0,
		"escaped": false,
		"thrill_key": "%s|%d" % [str(verdict.get("statute", "")), target_iid],
	}

## Called from the witness fuse on BOTH resolutions: fired (scream happened)
## or cancelled (killed/KO'd/silenced in the window). When the last fuse of
## a crime resolves silently, the actor got away clean — grant the thrill
## stack and say so.
func on_outcry_resolved(crime_id: int, fired: bool) -> void:
	if not _open_crimes.has(crime_id):
		return
	var entry: Dictionary = _open_crimes[crime_id]
	entry["resolved"] = int(entry["resolved"]) + 1
	if fired:
		entry["escaped"] = true
	if int(entry["resolved"]) < int(entry["fuses"]):
		_open_crimes[crime_id] = entry
		return
	_open_crimes.erase(crime_id)
	if bool(entry["escaped"]):
		return
	GameLog.add_entry("No one raised the alarm.")
	_grant_thrill(entry.get("actor"), str(entry.get("thrill_key", "")))

## thrill_of_sin, correctly triggered: no static `criminal` ability trait
## (criminality is jurisdictional — a trait would lie). Walk the actor's
## conditions for on_action_trait_stack.required_traits == ["criminal"] and
## stack them, mirroring AbilityManager._check_action_trait_stacking. Fires
## for ALL four action classes. The reward is for beating a live fuse;
## deduped per (statute, target) so pick-drop-retake cannot farm it.
func _grant_thrill(actor, thrill_key: String) -> void:
	if actor == null or not (actor is Node) or not is_instance_valid(actor):
		return
	if thrill_key != "" and bool(_thrill_granted.get(thrill_key, false)):
		return
	_thrill_granted[thrill_key] = true
	var cm = actor.get_node_or_null("ConditionManager")
	if cm == null:
		return
	for cond_id in cm.conditions.keys():
		var instance = cm.conditions[cond_id]
		var template = instance.condition
		if template == null:
			continue
		var stack_rule: Dictionary = template.on_action_trait_stack
		if stack_rule.is_empty():
			continue
		var required: Array = stack_rule.get("required_traits", [])
		if "criminal" in required:
			cm.apply_condition(str(cond_id), null, 1, -1.0)

func _start_outcry(witness, crime_id: int, identified: bool, is_victim: bool,
		crime_pos: Vector2, effective: Node, verdict: Dictionary, cfg: Dictionary) -> void:
	var law_faction: String = str(verdict.get("law_faction", ""))
	var payload: Dictionary = {
		"crime_id": crime_id,
		"identified": identified,
		# Anonymity is real: an unidentified outcry carries no perp at all.
		"perp": effective if identified else null,
		"crime_pos": crime_pos,
		"law_faction": law_faction,
		"statute": str(verdict.get("statute", "")),
		"display_name": str(verdict.get("display_name", "")),
		"severity": int(verdict.get("severity", 0)),
		"delay": _outcry_delay(witness, is_victim, crime_pos, law_faction, cfg),
		"witness_alert": float(cfg.get("witness_alert", 70.0)) if identified else float(cfg.get("unidentified_alert", 45.0)),
	}
	var ai_node = witness.get_node_or_null("AI")
	if ai_node != null and ai_node.has_method("begin_outcry"):
		ai_node.begin_outcry(payload)

## Outcry payload for an enforcer who just found a crime-stamped corpse:
## always unidentified (the body does not name its killer), delay computed
## for the discoverer like any witness.
func discovery_payload(corpse, discoverer, info: Dictionary) -> Dictionary:
	var cfg: Dictionary = LawDatabase.witness_cfg()
	var law_faction: String = str(info.get("law_faction", ""))
	return {
		"crime_id": int(info.get("crime_id", -1)),
		"identified": false,
		"perp": null,
		"crime_pos": corpse.global_position if corpse is Node2D else Vector2.ZERO,
		"law_faction": law_faction,
		"statute": str(info.get("statute", "")),
		"display_name": str(info.get("display_name", "")),
		"severity": int(info.get("severity", 0)),
		"delay": _outcry_delay(discoverer, false, corpse.global_position if corpse is Node2D else Vector2.ZERO, law_faction, cfg),
		"witness_alert": float(cfg.get("unidentified_alert", 45.0)),
	}

## Delay modifiers are additive, clamped, jittered — a crowd screams raggedly
## rather than in chorus. Distance does not grant anonymity (D7); it grants
## DOUBT, measured in seconds.
func _outcry_delay(witness, is_victim: bool, crime_pos: Vector2, law_faction: String, cfg: Dictionary) -> float:
	var delay: float = float(cfg.get("outcry_delay_base", 2.2))
	var witness_faction: String = str(witness.faction_id) if ("faction_id" in witness) else ""
	if LawDatabase.enforces(witness_faction, law_faction) or _has_condition(witness, "courageous"):
		delay += float(cfg.get("outcry_delay_guard", -1.1))
	if is_victim:
		delay += float(cfg.get("outcry_delay_victim", -1.3))
	if _has_condition(witness, "frightened") or _has_condition(witness, "panicked"):
		delay += float(cfg.get("outcry_delay_afraid", 0.8))
	if witness is Node2D and witness.global_position.distance_to(crime_pos) > float(cfg.get("outcry_far_distance", 512.0)):
		delay += float(cfg.get("outcry_delay_far", 0.6))
	delay = clampf(delay, float(cfg.get("outcry_delay_min", 0.8)), float(cfg.get("outcry_delay_max", 4.0)))
	var jitter: float = float(cfg.get("outcry_jitter", 0.15))
	return delay + randf_range(-jitter, jitter)

## The witness's fuse reached zero and they can still cry out: scream. The
## alarm rides the NORMAL hearing pipeline — walls damp it, SilenceZones
## smother it — that is the counterplay contract.
func fire_outcry(witness, payload: Dictionary) -> void:
	if not (witness is Node2D) or not is_instance_valid(witness):
		return
	var pos: Vector2 = witness.global_position
	SfxManager.play("witness_scream", pos, Vector2(0.9, 1.15))
	var loudness: float = float(LawDatabase.witness_cfg().get("scream_loudness", 1.35))
	HearingManager.emit(pos, loudness, witness, "alarm", payload)
	# The sole witness may BE the law: HearingManager skips the emitter, so a
	# lone guard's own sighting must be delivered directly — same delay, same
	# kill-window, no round trip.
	var law_faction: String = str(payload.get("law_faction", ""))
	if law_faction != "" and ("faction_id" in witness) \
			and LawDatabase.enforces(str(witness.faction_id), law_faction):
		on_alarm_heard(witness, payload)
		# Knowledge outlives arousal: the enforcer-witness remembers the perp
		# past alertness decay (same as any enforcer hearing the alarm).
		var witness_ai = witness.get_node_or_null("AI")
		var perp = payload.get("perp")
		if witness_ai != null and bool(payload.get("identified", false)) \
				and perp is ProceduralCharacter and is_instance_valid(perp):
			witness_ai.manhunt_target = perp
	on_outcry_resolved(int(payload.get("crime_id", -1)), true)

## An enforcer has the report. One record per crime_id no matter how many
## enforcers hear the scream (C3: callers already gate on
## LawDatabase.enforces, so a bandit overhearing a robbery reports nothing).
func on_alarm_heard(enforcer, payload: Dictionary) -> void:
	var crime_id: int = int(payload.get("crime_id", -1))
	if crime_id >= 0 and bool(_recorded_crimes.get(crime_id, false)):
		return
	_recorded_crimes[crime_id] = true
	var who: String = "person or persons unknown"
	var perp = payload.get("perp")
	var identified: bool = bool(payload.get("identified", false))
	if identified and perp is Object and is_instance_valid(perp) and ("Name" in perp):
		who = str(perp.Name)
	GameLog.add_entry("The alarm is raised: %s — %s stands accused." % [
		str(payload.get("display_name", "a crime")), who])
	# Consequence (identified only — an anonymous alarm rouses the town but
	# moves no standing, writes no ledger, sets no manhunt): standing drops
	# by severity, the override flips (D8's binary — enforcement is one
	# line, and target acquisition / hearing / menus / targeting all follow
	# through are_hostile with no further code).
	if identified:
		var law_faction: String = str(payload.get("law_faction", ""))
		if not law_faction.is_empty():
			FactionDatabase.adjust_player_standing(law_faction, -int(payload.get("severity", 0)))
			FactionDatabase.mark_outlaw(law_faction)
			FactionDatabase.record_crime(law_faction, payload, {"crime_id": crime_id})
	crime_reported.emit(enforcer, payload)

## Settlement — the mechanism Phase 7's surrender UI drives. Return goods is
## always a component (giving back what you stole is the fiction), then coin
## or time, then FactionDatabase.settle squares the books. Clears manhunts.
func settle_with(law_faction: String, mode: String) -> void:
	var game = get_tree().current_scene
	var protagonist = null
	if game != null and ("party_chars" in game) and not game.party_chars.is_empty():
		protagonist = game.party_chars[0]
	var returned: int = 0
	if game != null and ("party_chars" in game):
		for c in game.party_chars:
			if not is_instance_valid(c) or not ("inventory" in c) or c.inventory == null:
				continue
			for i in range(c.inventory.items.size() - 1, -1, -1):
				var entry = c.inventory.items[i]
				if entry is Dictionary and str(entry.get("stolen_from", "")) == law_faction:
					c.inventory.items.remove_at(i)
					returned += 1
			for i in range(c.inventory.stowed_items.size() - 1, -1, -1):
				var w = c.inventory.stowed_items[i]
				if w != null and ("stolen_from" in w) and w.stolen_from == law_faction:
					c.inventory.stowed_items.remove_at(i)
					returned += 1
	if returned > 0:
		GameLog.add_entry("Stolen goods returned (%d)." % returned)
	match mode:
		"pay_fine":
			var fine: int = FactionDatabase.fine_owed(law_faction)
			if fine > 0 and protagonist != null:
				DowntimeEffectApplier._apply_money(protagonist, -fine, 1)
				GameLog.add_entry("Fine paid: %d gold to %s." % [fine, law_faction])
		"serve_time":
			var days: int = FactionDatabase.jail_days_owed(law_faction)
			if days > 0:
				TimeManager.advance_days(days)
				GameLog.add_entry("Sentence served: %d days." % days)
	FactionDatabase.settle(law_faction, mode)
	clear_manhunts(law_faction)
	GameLog.add_entry("You are square with %s. Nobody has forgotten." % law_faction)

## A settled account calls off the hunt: every enforcer of this law faction
## drops its manhunt_target.
func clear_manhunts(law_faction: String) -> void:
	var game = get_tree().current_scene
	if game == null or not ("characters_in_scene" in game):
		return
	for c in game.characters_in_scene:
		if not is_instance_valid(c):
			continue
		var ai_node = c.get_node_or_null("AI")
		if ai_node == null or not ("manhunt_target" in ai_node):
			continue
		if ai_node.manhunt_target != null and ("faction_id" in c) \
				and LawDatabase.enforces(str(c.faction_id), law_faction):
			ai_node.manhunt_target = null

## Binary, per D7: strength >= 3 summed over equipped disguise blocks, head
## slot required. Pure read of equipment state via the item_data meta already
## stamped at equip time — no lifecycle, nothing to desync or serialize.
const _EQUIP_SLOTS: Array = ["head_equipment", "torso_equipment", "back_equipment", "legs_equipment", "feet_equipment"]

func is_disguised(actor) -> bool:
	if actor == null or not (actor is Object) or not is_instance_valid(actor):
		return false
	var total: int = 0
	var head_covered: bool = false
	for slot_name in _EQUIP_SLOTS:
		if not (slot_name in actor):
			continue
		var equip = actor.get(slot_name)
		if equip == null or not (equip is Object) or not equip.has_meta("item_data"):
			continue
		var item_data: Dictionary = equip.get_meta("item_data")
		var disguise: Dictionary = item_data.get("disguise", {})
		if disguise.is_empty():
			continue
		total += int(disguise.get("strength", 0))
		if String(slot_name) == "head_equipment":
			head_covered = true
	return head_covered and total >= 3

func outcry_cancel_conditions() -> Array:
	return LawDatabase.witness_cfg().get("cancel_on_conditions", ["unconscious", "silenced", "panicked"])

func _has_condition(who, cond_id: String) -> bool:
	var cm = who.get_node_or_null("ConditionManager") if who is Node else null
	return cm != null and cm.has_condition(cond_id)
