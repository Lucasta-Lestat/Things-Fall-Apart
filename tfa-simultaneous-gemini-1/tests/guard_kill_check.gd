# res://tests/guard_kill_check.gd
# Killing a town guard in Perrow, in front of another guard (user report
# 2026-11-26: the guard beside the victim only showed "?" and never fought).
# Runs the REAL game on tg_hillside_lower with the two map-spawned
# golden_guard town_guards, places them side by side, and kills one with the
# protagonist from a few tiles off -- with the survivor facing the kill, and
# again facing away. Prints the survivor's AI state over time; the checks are
# the contract the fix must keep.
# Run:  godot --headless --path . res://tests/guard_kill_check.tscn
# Judge by the DONE line.
extends Node2D

var failures := 0
var checks := 0
var game = null


func _check(check_name: String, cond: bool, detail: String = "") -> void:
	checks += 1
	if cond:
		print("PASS %s %s" % [check_name, detail])
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])


func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame


func _guards() -> Array:
	var out: Array = []
	for c in game.characters_in_scene:
		if is_instance_valid(c) and c.is_alive() and not (c in game.party_chars) \
				and str(c.faction_id) == "golden_guard":
			out.append(c)
	return out


func _ai_line(tag: String, g) -> String:
	var ai = g.get_node("AI")
	var tgt = ai.current_target
	var k = game.party_chars[0]
	return "%s state=%s alert=%.1f(%s) target=%s grudge=%s enemy=%s manhunt=%s killer_hp=%d dist=%.0f" % [
		tag, ai.AIState.keys()[ai.current_state], float(ai.alertness_value),
		str(ai.current_alertness), (tgt.Name if tgt != null and is_instance_valid(tgt) else "none"),
		str(ai._holds_grudge(game.party_chars[0])), str(ai._is_enemy(game.party_chars[0])),
		str(ai.manhunt_target != null), int(k.current_health), g.global_position.distance_to(k.global_position)]


func _ready() -> void:
	TimeManager.pause_time()
	await get_tree().process_frame
	var GameScene := load("res://game.tscn")
	game = GameScene.instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _frames(2)
	# facing away first: the facing guard wins his fight, and a dead
	# protagonist stays dead into the next case
	await _case(false)
	await _case(true)
	await _case_sneak_close_quarters()
	await _case_wanted()
	_case_witness_filter()
	await _case_settle_holds()
	_case_party_row_rekey()
	print("GUARD KILL DONE: %d checks, failures=%d" % [checks, failures])
	get_tree().quit(1 if failures > 0 else 0)


func _case(facing_kill: bool) -> void:
	var tag: String = "facing" if facing_kill else "away"
	game.load_map("tg_hillside_lower")
	await _frames(6)
	# fresh guards each case (a guard killed in the first case stays dead
	# across the reload), in an open spot of the square
	var base: Vector2 = game.party_chars[0].global_position + Vector2(0, -260)
	var victim = game._spawn_character("town_guard", base)
	var witness = game._spawn_character("town_guard", base + Vector2(48, 0))
	_check("%s.two-guards" % tag, victim != null and witness != null)
	if victim == null or witness == null:
		return
	# _spawn_npcs switches the AI on; _spawn_character alone leaves it off
	victim.AI_enabled = true
	witness.AI_enabled = true
	await _frames(2)
	var killer = game.party_chars[0]
	_check("%s.killer-alive" % tag, killer.is_alive(), "hp %d" % int(killer.current_health))
	witness.global_position = base + Vector2(48, 0)
	killer.global_position = base + Vector2(0, -150)
	await _frames(3)
	var look_at: Vector2 = killer.global_position if facing_kill else base + Vector2(400, 300)
	witness.rotation = (look_at - witness.global_position).angle() + PI / 2.0
	print(_ai_line("%s.before" % tag, witness))
	print("%s liziti stance before: %s  golden_guard: %s" % [tag,
		FactionDatabase.player_stance_toward("liziti"), FactionDatabase.player_stance_toward("golden_guard")])
	var hp: int = int(victim.current_health)
	victim.take_damage({"piercing": hp + 50}, victim.global_position, killer)
	_check("%s.victim-dead" % tag, not victim.is_alive())
	TimeManager.resume_time()
	var wai = witness.get_node("AI")
	var reacted_at: int = -1
	for step in range(8):
		await _frames(30)
		print(_ai_line("%s.t+%d" % [tag, (step + 1) * 30], witness))
		# the guard is meant to win; keep the killer up for the next case
		killer.current_health = killer.max_health
		if reacted_at < 0 and wai._is_enemy(killer) and wai.current_target == killer:
			reacted_at = (step + 1) * 30
	TimeManager.pause_time()
	_check("%s.witness-hostile" % tag, wai._is_enemy(killer), _ai_line("", witness))
	# within ~2 s: the blow seen (facing), or the killer spotted over the body
	_check("%s.witness-targets-killer" % tag, reacted_at > 0 and reacted_at <= 120, "frame %d" % reacted_at)
	_check("%s.liziti-not-hostile" % tag, FactionDatabase.player_stance_toward("liziti") != "hostile",
		FactionDatabase.player_stance_toward("liziti"))
	var cm = killer.get_node("ConditionManager")
	print("%s wanted on killer: %s ; conditions: %s" % [tag, str(cm.has_condition("wanted")), str(cm.conditions.keys())])


func _guard_at(pos: Vector2, faces: Vector2):
	var g = game._spawn_character("town_guard", pos)
	if g != null:
		g.AI_enabled = true
		g.rotation = (faces - pos).angle() + PI / 2.0
	return g


## Close quarters is peripheral awareness, not a free pass on stealth: a
## killer sneaking up behind a guard's comrade, inside the guard's close
## quarters, is not seen doing it (the reaction path's witnesses_of).
func _case_sneak_close_quarters() -> void:
	game.load_map("tg_hillside_lower")
	await _frames(6)
	var killer = game.party_chars[0]
	killer.max_health = 5000
	killer.current_health = 5000
	var base: Vector2 = killer.global_position + Vector2(0, -260)
	var victim = _guard_at(base, base + Vector2(0, -400))
	# the witness faces AWAY, the killer is inside his close quarters
	var witness = _guard_at(base + Vector2(60, 0), base + Vector2(600, 0))
	killer.global_position = base + Vector2(0, 60)
	await _frames(3)
	var cq: float = witness.get_node("AI")._close_quarters_radius()
	_check("sneak.inside-close-quarters", witness.global_position.distance_to(killer.global_position) < cq)
	# facing away from the killer NOW (his AI may have turned him meanwhile)
	witness.rotation = Vector2.RIGHT.angle() + PI / 2.0
	game.stealth_mode = true
	var seen_sneaking := false
	for e in CrimeManager.witnesses_of(victim.global_position, 0.0, killer, false, [], true):
		if e["witness"] == witness:
			seen_sneaking = bool(e["sees_actor"])
	game.stealth_mode = false
	var seen_walking := false
	for e in CrimeManager.witnesses_of(victim.global_position, 0.0, killer, false, [], true):
		if e["witness"] == witness:
			seen_walking = bool(e["sees_actor"])
	_check("sneak.not-seen-while-sneaking", not seen_sneaking)
	_check("sneak.seen-at-elbow-walking", seen_walking)
	game.despawn_character(victim)
	game.despawn_character(witness)


func _key(c) -> String:
	return CrimeManager.perp_key(c)


## Wanted is per region and per culprit, saved, and the region's enforcers
## attack the culprit on sight; surrender settles with the law that is owed,
## and settling clears the wanted entry and the watch's grudges.
func _case_wanted() -> void:
	game.load_map("tg_hillside_lower")
	await _frames(6)
	if game.party_chars.size() < 2:
		_check("wanted.two-party-members", false)
		return
	var prot = game.party_chars[0]
	var comp = game.party_chars[1]
	var comp_key: String = _key(comp)
	var guard = _guard_at(comp.global_position + Vector2(120, 0), comp.global_position)
	await _frames(2)
	CrimeManager.on_alarm_heard(guard, {"crime_id": 777001, "identified": true, "perp": comp,
		"law_faction": "liziti", "statute": "murder", "display_name": "Murder", "severity": 90,
		"crime_pos": comp.global_position})
	_check("wanted.registry", FactionDatabase.is_wanted("perrow", comp_key), comp_key)
	_check("wanted.on-culprit", comp.get_node("ConditionManager").has_condition("wanted"))
	_check("wanted.not-on-protagonist", not prot.get_node("ConditionManager").has_condition("wanted"))
	var gai = guard.get_node("AI")
	_check("wanted.guard-attacks-culprit", gai._is_enemy(comp))
	_check("wanted.liziti-outlaw-not-golden-guard", not FactionDatabase.are_hostile("golden_guard", "player"))
	# save round trip
	var saved: Dictionary = FactionDatabase.standing_to_dict()
	FactionDatabase.standing_from_dict({})
	_check("wanted.cleared-by-empty-load", not comp.get_node("ConditionManager").has_condition("wanted"))
	FactionDatabase.standing_from_dict(saved)
	_check("wanted.restored-by-load", comp.get_node("ConditionManager").has_condition("wanted")
		and gai._is_enemy(comp))
	# elsewhere (a map in no region: its own bucket): no icon, nobody hunts them
	game.load_map("tg_castle_demo")
	await _frames(6)
	var comp2 = null
	for c in game.party_chars:
		if is_instance_valid(c) and _key(c) == comp_key:
			comp2 = c
	_check("wanted.warped-away", game.current_map_id == "tg_castle_demo", game.current_map_id)
	_check("wanted.other-region-no-icon", comp2 != null and not comp2.get_node("ConditionManager").has_condition("wanted"))
	_check("wanted.other-region-no-cache", CrimeManager.wanted_here.is_empty())
	# back in Perrow, a fresh guard knows them
	game.load_map("tg_hillside_lower")
	await _frames(6)
	var comp3 = null
	for c in game.party_chars:
		if is_instance_valid(c) and _key(c) == comp_key:
			comp3 = c
	_check("wanted.back-in-region-icon", comp3 != null and comp3.get_node("ConditionManager").has_condition("wanted"))
	var guard2 = _guard_at(comp3.global_position + Vector2(120, 0), comp3.global_position)
	await _frames(2)
	_check("wanted.after-warp-guard-attacks", guard2.get_node("AI")._is_enemy(comp3))
	# surrender to the guard: the counterparty is the law owed, not his faction
	game._mark_threat_known(guard2)
	var panel = load("res://UI/SurrenderPanel.gd").new()
	panel.game = game
	_check("surrender.counterparty-is-law", panel._pick_counterparty() == "liziti", panel._pick_counterparty())
	panel.free()
	# a grudge the watch holds is settled with the account
	guard2.get_node("AI").take_grudge(comp3, false)
	CrimeManager.settle_with("liziti", "")
	_check("settle.wanted-cleared", not FactionDatabase.is_wanted("perrow", comp_key)
		and not comp3.get_node("ConditionManager").has_condition("wanted"))
	_check("settle.guard-grudge-cleared", not guard2.get_node("AI")._holds_grudge(comp3))
	_check("settle.guard-no-longer-enemy", not guard2.get_node("AI")._is_enemy(comp3))


## Who raises the alarm against the party: the law's enforcers and bystanders,
## never the party's own summons, nor the culprit's enemies.
func _case_witness_filter() -> void:
	var prot = game.party_chars[0]
	var pos: Vector2 = prot.global_position + Vector2(0, 200)
	var guard = _guard_at(pos, prot.global_position)
	var merchant = game._spawn_character("merchant", pos + Vector2(60, 0))
	var bandit = game._spawn_character("bandit", pos + Vector2(120, 0))
	var summon = game._spawn_character("merchant", pos + Vector2(180, 0))
	summon.faction_id = "player"
	summon.set_meta("summoned_by", prot)
	_check("filter.enforcer-cries", CrimeManager.would_cry_out(guard, prot, "liziti"))
	_check("filter.bystander-cries", CrimeManager.would_cry_out(merchant, prot, "liziti"))
	_check("filter.enemy-silent", bandit == null or not CrimeManager.would_cry_out(bandit, prot, "liziti"))
	_check("filter.own-summon-silent", not CrimeManager.would_cry_out(summon, prot, "liziti"))
	# an enforcer the culprit has charmed keeps quiet about them
	var charmed = _guard_at(pos + Vector2(240, 0), prot.global_position)
	charmed.get_node("ConditionManager").apply_condition("infatuated", prot, 1, 60.0)
	var is_charmed: bool = charmed.get_node("AI")._infatuation_source() == prot
	_check("filter.charmed-enforcer-silent", not is_charmed or not CrimeManager.would_cry_out(charmed, prot, "liziti"),
		"charmed=%s" % str(is_charmed))
	game.despawn_character(charmed)
	for c in [guard, merchant, bandit, summon]:
		if c != null and is_instance_valid(c):
			game.despawn_character(c)


## Settling right after a guard kill holds: the comrade's body no longer
## re-arms the grudge a second later (the slain_by stamp is closed), and a
## wanted character striking back at the guard hunting them is self-defence.
func _case_settle_holds() -> void:
	game.load_map("tg_hillside_lower")
	await _frames(6)
	var killer = game.party_chars[0]
	var base: Vector2 = killer.global_position + Vector2(0, -200)
	var victim = _guard_at(base, base + Vector2(0, -400))
	var witness = _guard_at(base + Vector2(48, 0), killer.global_position)
	killer.global_position = base + Vector2(0, 90)
	await _frames(3)
	witness.rotation = (killer.global_position - witness.global_position).angle() + PI / 2.0
	victim.take_damage({"piercing": int(victim.current_health) + 50}, victim.global_position, killer)
	var wai = witness.get_node("AI")
	_check("settle-holds.grudge-taken", wai._holds_grudge(killer))
	CrimeManager.settle_with("golden_guard", "")
	TimeManager.resume_time()
	for i in range(4):
		await _frames(30)
		killer.current_health = killer.max_health
	TimeManager.pause_time()
	_check("settle-holds.no-regrudge-from-body", not wai._holds_grudge(killer) and not victim.has_meta("slain_by"),
		_ai_line("", witness))
	# a wanted character hitting back at the guard hunting them: no new charge
	var comp = game.party_chars[1] if game.party_chars.size() > 1 else killer
	FactionDatabase.mark_wanted(CrimeManager.current_wanted_bucket(), CrimeManager.perp_key(comp), str(comp.Name), "liziti", "Murder")
	var pay: Dictionary = CrimeManager.attack_payload(comp, witness)
	_check("settle-holds.wanted-strikes-back-is-self-defence", bool(pay["victim_hostile_to_actor"]))
	CrimeManager.settle_with("liziti", "")
	var merchant = game._spawn_character("merchant", base + Vector2(-120, 0))
	merchant.AI_enabled = true
	merchant.get_node("AI").take_grudge(comp, true)
	_check("settle-holds.grudge-is-not-self-defence", not bool(CrimeManager.attack_payload(comp, merchant)["victim_hostile_to_actor"]))
	for c in [victim, witness, merchant]:
		if is_instance_valid(c):
			game.despawn_character(c)


## A member leaving takes their wanted entry with them; later rows move up.
func _case_party_row_rekey() -> void:
	FactionDatabase.mark_wanted("perrow", "party:1", "A", "liziti", "Murder")
	FactionDatabase.mark_wanted("perrow", "party:2", "B", "liziti", "Theft")
	FactionDatabase.party_row_removed(1)
	_check("rekey.leaver-gone", str(FactionDatabase.wanted_entry("perrow", "party:1").get("name", "")) == "B")
	_check("rekey.no-orphan-row", not FactionDatabase.is_wanted("perrow", "party:2"))
	CrimeManager.settle_with("liziti", "")
