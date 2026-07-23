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
	return {
		"victim_faction": victim_faction,
		# Self-defence carve-out: no charge for fighting someone already
		# hostile to you (faction-level; the Phase 1 oracle).
		"victim_hostile_to_actor": FactionDatabase.are_hostile(victim_faction, actor_faction),
		"lethal": lethal,
		"victim": victim,
		"debounce_target": victim,
	}

func take_payload(item) -> Dictionary:
	return {
		"owner_faction": str(item.owner_faction) if ("owner_faction" in item) else "",
		"item_cost": float(item.cost) if ("cost" in item) else 0.0,
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
