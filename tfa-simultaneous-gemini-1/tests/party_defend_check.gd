# res://tests/party_defend_check.gd
# Companions defend the party against anyone hunting a party member (user
# report 2026-11-26: after the protagonist killed a merchant, the merchants
# who came at them were ignored by the companions until they struck one), and
# the law calls the party's blows on such a hunter self-defence -- judged on
# the hunt as it stood before each blow, never for a fight the party started.
# Runs the REAL game on tg_hillside_lower with a recruited companion.
# Run:  godot --headless --audio-driver Dummy --path . res://tests/party_defend_check.tscn
# Judge by the DONE line.
extends Node2D

var failures := 0
var checks := 0
var game = null
var comp = null
var crimes: Array = []


func _check(check_name: String, cond: bool, detail: String = "") -> void:
	checks += 1
	if cond:
		print("PASS %s %s" % [check_name, detail])
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])


## Into the next process frame (Engine.get_process_frames moves on): the
## process_frame signal fires before the counter does, so wait for two.
func _pframe() -> void:
	var f: int = Engine.get_process_frames()
	while Engine.get_process_frames() == f:
		await get_tree().process_frame


func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame


func _ready() -> void:
	TimeManager.pause_time()
	await get_tree().process_frame
	var GameScene := load("res://game.tscn")
	game = GameScene.instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _frames(2)
	game.load_map("tg_hillside_lower")
	await _frames(6)
	CrimeManager.crime_committed.connect(_on_crime)
	await _case_defends_against_witness()
	_case_fleeing_is_no_threat()
	_case_pacified_is_no_threat()
	_case_hunt_memory()
	_case_bystanders_unchanged()
	await _case_snapshot_judges_before_blow()
	_case_hunter_is_called_out()
	_case_confused_pick_not_called_out()
	await _case_panic_does_not_poison_defence()
	await _case_compulsion_struck_is_wronged()
	# crimes last: a murder sets the watch on the protagonist
	await _case_lethal_defence_is_no_murder()
	await _case_lawful_burn_tick_is_no_murder()
	await _case_party_started_it()
	_case_ambush_is_murder()
	_case_one_aoe_is_no_licence()
	print("PARTY DEFEND DONE: %d checks, failures=%d" % [checks, failures])
	get_tree().quit(1 if failures > 0 else 0)


func _on_crime(actor, verdict: Dictionary, payload: Dictionary) -> void:
	crimes.append({"actor": actor, "statute": str(verdict.get("statute", "")), "victim": payload.get("victim")})


func _murders_of(victim) -> int:
	var n := 0
	for c in crimes:
		if c["victim"] == victim and c["statute"] == "murder":
			n += 1
	return n


func _kill(victim, by) -> void:
	victim.take_damage({"piercing": int(victim.current_health) + 50}, victim.global_position, by)


func _prot():
	return game.party_chars[0]


## Recruit a fighter the way DialogueActions._do_join_party does.
func _recruit(pos: Vector2):
	var c = game._spawn_character("town_guard", pos)
	if c == null:
		return null
	game.party_state.append({"template_id": str(c.template_id), "overrides": {}, "live_state": null})
	game.party_chars.append(c)
	c.set_meta("party_index", game.party_state.size() - 1)
	c.faction_id = "player"
	c.AI_enabled = true
	c.is_player_controlled = false
	if game.has_method("_clear_companion_ai"):
		game._clear_companion_ai(c)
	return c


## A merchant who keeps their nerve (no panic roll in the way).
func _merchant(pos: Vector2):
	var m = game._spawn_character("merchant", pos)
	if m != null:
		m.set_meta("retaliates", true)
		m.AI_enabled = true
	return m


func _face(c, at: Vector2) -> void:
	c.rotation = (at - c.global_position).angle() + PI / 2.0


func _line(tag: String, c) -> String:
	var ai = c.get_node("AI")
	var t = ai.current_target
	return "%s state=%s alert=%.1f target=%s hp=%d" % [tag, ai.AIState.keys()[ai.current_state],
		float(ai.alertness_value), (t.Name if t != null and is_instance_valid(t) else "none"), int(c.current_health)]


func _force_condition(c, cid: String, source) -> bool:
	var cm = c.get_node("ConditionManager")
	# a saving throw can shrug stacks off; land it for the check
	for _try in range(8):
		if cm.has_condition(cid):
			break
		cm.apply_condition(cid, source, 3)
	return cm.has_condition(cid)


func _case_defends_against_witness() -> void:
	var prot = _prot()
	prot.max_health = 5000
	prot.current_health = 5000
	var base: Vector2 = prot.global_position + Vector2(0, -220)
	prot.global_position = base
	comp = _recruit(base + Vector2(60, 40))
	_check("defend.companion-recruited", comp != null and comp in game.party_chars)
	if comp == null:
		return
	comp.max_health = 5000
	comp.current_health = 5000
	var merchant = _merchant(base + Vector2(60, -230))
	_check("defend.merchant", merchant != null)
	if merchant == null:
		return
	await _frames(3)
	var cai = comp.get_node("AI")
	var mai = merchant.get_node("AI")
	_check("defend.not-enemy-before", not cai._is_enemy(merchant))
	# the merchant saw the protagonist kill someone of theirs and comes at them
	mai.take_grudge(prot, false)
	_check("defend.merchant-hunts-protagonist", mai.hunted_party_member() == prot, _line("merchant", merchant))
	_check("defend.defended-hunt", mai.defended_hunt() == prot)
	_check("defend.companion-counts-hunter-enemy", cai._is_enemy(merchant))
	_check("defend.self-defence-for-companion", bool(CrimeManager.attack_payload(comp, merchant)["victim_hostile_to_actor"]))
	_check("defend.self-defence-for-protagonist", bool(CrimeManager.attack_payload(prot, merchant)["victim_hostile_to_actor"]))
	_face(comp, merchant.global_position)
	var comp_hp: int = int(comp.current_health)
	var engaged_at: int = -1
	TimeManager.resume_time()
	for step in range(6):
		await _frames(20)
		print(_line("t+%d comp" % ((step + 1) * 20), comp))
		print(_line("t+%d merchant" % ((step + 1) * 20), merchant))
		prot.current_health = prot.max_health
		if engaged_at < 0 and cai.current_target == merchant:
			engaged_at = (step + 1) * 20
			comp_hp = int(comp.current_health)
	TimeManager.pause_time()
	_check("defend.companion-engages", engaged_at > 0 and engaged_at <= 60, "frame %d" % engaged_at)
	_check("defend.before-being-struck", engaged_at > 0 and comp_hp >= int(comp.max_health), "hp at engage %d" % comp_hp)
	# the companion's real blows on the hunter are no crime
	_check("defend.no-crime-in-fight", crimes.is_empty(), str(crimes))
	if is_instance_valid(merchant):
		game.despawn_character(merchant)
	cai._lose_target()


## A hunter who panics is no threat: not hunted, and a companion's own grudge
## doesn't run them down.
func _case_fleeing_is_no_threat() -> void:
	if comp == null:
		return
	var prot = _prot()
	var m = _merchant(prot.global_position + Vector2(120, -60))
	var mai = m.get_node("AI")
	var cai = comp.get_node("AI")
	mai.take_grudge(prot, false)
	cai.take_grudge(m, true)
	_check("flee.hunting-before", mai.hunted_party_member() == prot and cai._is_enemy(m))
	_check("flee.panicked", _force_condition(m, "panicked", prot))
	_check("flee.not-hunting", mai.hunted_party_member() == null)
	_check("flee.companion-lets-go", not cai._is_enemy(m))
	cai.grudges.clear()
	cai._lose_target()
	game.despawn_character(m)


## Apathetic, Transfixed or out cold: no hunt.
func _case_pacified_is_no_threat() -> void:
	if comp == null:
		return
	var prot = _prot()
	for cid in ["apathetic", "transfixed", "unconscious"]:
		var m = _merchant(prot.global_position + Vector2(120, 60))
		var mai = m.get_node("AI")
		mai.take_grudge(prot, false)
		_check("pacified.%s-applied" % cid, _force_condition(m, cid, null))
		_check("pacified.%s-not-hunting" % cid, mai.hunted_party_member() == null)
		_check("pacified.%s-companion-ignores" % cid, not comp.get_node("AI")._is_enemy(m))
		game.despawn_character(m)


## Losing sight keeps the hunt for HUNT_MEMORY_SEC while searching.
func _case_hunt_memory() -> void:
	if comp == null:
		return
	var prot = _prot()
	var m = _merchant(prot.global_position + Vector2(0, -150))
	var mai = m.get_node("AI")
	mai.take_grudge(prot, false)
	mai._demote_lost_target()
	_check("memory.lost-target", mai.current_target == null)
	_check("memory.still-hunting", mai.hunted_party_member() == prot, "alert %.1f" % float(mai.alertness_value))
	mai._time_without_target = mai.HUNT_MEMORY_SEC + 1.0
	_check("memory.expires", mai.hunted_party_member() == null)
	game.despawn_character(m)


## Only the party's side defends: a town guard doesn't take up a merchant
## hunting the protagonist, and a hunter hunting a non-party NPC is nobody's
## business of the companions'.
func _case_bystanders_unchanged() -> void:
	if comp == null:
		return
	var prot = _prot()
	var m = _merchant(prot.global_position + Vector2(0, -150))
	var guard = game._spawn_character("town_guard", prot.global_position + Vector2(150, 0))
	guard.AI_enabled = true
	m.get_node("AI").take_grudge(prot, false)
	_check("bystander.guard-not-enemy", not guard.get_node("AI")._is_enemy(m))
	m.get_node("AI").grudges.clear()
	m.get_node("AI")._lose_target()
	var other = _merchant(prot.global_position + Vector2(-150, 0))
	m.get_node("AI").take_grudge(other, true)
	_check("bystander.npc-feud-ignored", m.get_node("AI").hunted_party_member() == null \
		and not comp.get_node("AI")._is_enemy(m))
	for c in [m, guard, other]:
		game.despawn_character(c)


## The law judges a blow on the hunt as it stood before it: the blow that
## panics the hunter (its own AI reacts first) is still self-defence.
func _case_snapshot_judges_before_blow() -> void:
	if comp == null:
		return
	var prot = _prot()
	var m = _merchant(prot.global_position + Vector2(-120, 0))
	var mai = m.get_node("AI")
	mai.take_grudge(prot, false)
	await _pframe()  # a hunt begun this very frame is no hunt to the law
	mai.snapshot_hunt_before_blow()
	_check("snapshot.panicked-after", _force_condition(m, "panicked", comp) and mai.hunted_party_member() == null)
	_check("snapshot.same-blow-self-defence", bool(CrimeManager.attack_payload(comp, m)["victim_hostile_to_actor"]))
	game.despawn_character(m)


## An NPC the party can see turning on a party member raises the companions;
## one that turned out of sight is called out the first time it's seen.
func _case_hunter_is_called_out() -> void:
	if comp == null:
		return
	var prot = _prot()
	var cai = comp.get_node("AI")
	cai._lose_target()
	cai._set_alertness_value(0.0)
	var m = _merchant(prot.global_position + Vector2(0, -120))
	game._npc_was_truly_seen[m] = true
	m.get_node("AI").take_grudge(prot, false)
	_check("callout.companion-raised", float(cai.alertness_value) >= 60.0, "alert %.1f" % float(cai.alertness_value))
	game.despawn_character(m)
	cai._lose_target()
	cai._set_alertness_value(0.0)
	var m2 = _merchant(prot.global_position + Vector2(0, -120))
	var m2ai = m2.get_node("AI")
	game._npc_was_truly_seen[m2] = false
	m2ai.take_grudge(prot, false)
	_check("callout.unseen-not-yet", float(cai.alertness_value) < 60.0, "alert %.1f" % float(cai.alertness_value))
	game._npc_was_truly_seen[m2] = true
	m2ai._update_target(0.016)
	_check("callout.seen-later", float(cai.alertness_value) >= 60.0, "alert %.1f" % float(cai.alertness_value))
	game.despawn_character(m2)


## A pick that isn't a hunt (no grudge, no warrant -- a confused lash-out) is
## not called out.
func _case_confused_pick_not_called_out() -> void:
	if comp == null:
		return
	var prot = _prot()
	var cai = comp.get_node("AI")
	cai._lose_target()
	cai._set_alertness_value(0.0)
	var m = _merchant(prot.global_position + Vector2(0, -120))
	var mai = m.get_node("AI")
	game._npc_was_truly_seen[m] = true
	mai._acquire_target(prot)
	_check("confused.not-hunting", mai.hunted_party_member() == null)
	_check("confused.not-called-out", float(cai.alertness_value) < 60.0, "alert %.1f" % float(cai.alertness_value))
	game.despawn_character(m)


## The killing blow on a hunter is self-defence too (the victim is dead when
## the law reads it) -- for the companion, and for the protagonist.
func _case_lethal_defence_is_no_murder() -> void:
	if comp == null:
		return
	var prot = _prot()
	for who in [comp, prot]:
		var tag: String = "comp" if who == comp else "prot"
		var m = _merchant(prot.global_position + Vector2(0, -110))
		m.get_node("AI").take_grudge(prot, false)
		await _pframe()  # a hunt begun this very frame is no hunt to the law
		_kill(m, who)
		_check("lethal.%s-dead" % tag, not m.is_alive())
		_check("lethal.%s-no-murder" % tag, _murders_of(m) == 0, str(crimes))
		game.despawn_character(m)


## A merchant the party struck first answering back (real blows): the
## companions leave it to the player, and finishing them is murder.
func _case_party_started_it() -> void:
	if comp == null:
		return
	var prot = _prot()
	var m = _merchant(prot.global_position + Vector2(-90, -60))
	var mai = m.get_node("AI")
	m.take_damage({"bludgeoning": 1}, m.global_position, prot)
	_check("started.alive-and-hunting", m.is_alive() and mai.hunted_party_member() == prot, _line("m", m))
	_check("started.wronged", mai.wronged_by_party())
	_check("started.no-defended-hunt", mai.defended_hunt() == null)
	_check("started.companion-leaves-it", not comp.get_node("AI")._is_enemy(m))
	_check("started.no-self-defence-companion", not bool(CrimeManager.attack_payload(comp, m)["victim_hostile_to_actor"]))
	_check("started.no-self-defence-protagonist", not bool(CrimeManager.attack_payload(prot, m)["victim_hostile_to_actor"]))
	_kill(m, comp)
	_check("started.companion-kill-is-murder", _murders_of(m) == 1, str(crimes))
	# hit back while hunting is not a fresh wrong
	var m2 = _merchant(prot.global_position + Vector2(-90, 60))
	var m2ai = m2.get_node("AI")
	m2ai.take_grudge(prot, false)
	await _pframe()  # a hunt begun this very frame is no hunt to the law
	m2.take_damage({"bludgeoning": 1}, m2.global_position, comp)
	_check("started.hit-back-not-wronged", m2.is_alive() and not m2ai.wronged_by_party() and m2ai.defended_hunt() == prot,
		_line("m2", m2))
	for c in [m, m2]:
		if is_instance_valid(c):
			game.despawn_character(c)


## Striking a grudge-holder who wasn't hunting anyone is the party's ambush:
## the killing blow is murder, though the victim's AI turns on the striker
## before the law reads the blow.
func _case_ambush_is_murder() -> void:
	var prot = _prot()
	var m = _merchant(prot.global_position + Vector2(140, 0))
	var mai = m.get_node("AI")
	mai.take_grudge(prot, false)
	mai._lose_target()
	mai._time_without_target = mai.HUNT_MEMORY_SEC + 5.0
	_check("ambush.not-hunting", mai.hunted_party_member() == null)
	_kill(m, prot)
	_check("ambush.murder", _murders_of(m) == 1, str(crimes))
	game.despawn_character(m)


## A follow-up blow while the hunter is briefly panicked is a crime on its
## own, but doesn't make the party the aggressor: once the panic passes the
## witness hunt is still one the companions defend against.
func _case_panic_does_not_poison_defence() -> void:
	if comp == null:
		return
	var prot = _prot()
	var m = _merchant(prot.global_position + Vector2(-100, -100))
	m.max_health = 500
	m.current_health = 500
	var mai = m.get_node("AI")
	mai.take_grudge(prot, false)
	await _pframe()  # a hunt begun this very frame is no hunt to the law
	m.take_damage({"bludgeoning": 1}, m.global_position, comp)
	_check("panicpoison.first-blow-lawful", not mai.wronged_by_party())
	_check("panicpoison.panicked", _force_condition(m, "panicked", comp))
	await _frames(2)
	m.take_damage({"bludgeoning": 1}, m.global_position, prot)
	_check("panicpoison.not-wronged", not mai.wronged_by_party())
	m.get_node("ConditionManager").remove_condition("panicked")
	if mai.current_target == null:
		mai._acquire_target(prot)
	_check("panicpoison.defended-again", mai.defended_hunt() != null and comp.get_node("AI")._is_enemy(m),
		_line("m", m))
	game.despawn_character(m)


## A hunter driven only by a compulsion: striking it starts a fight of the
## party's own.
func _case_compulsion_struck_is_wronged() -> void:
	if comp == null:
		return
	var prot = _prot()
	var m = _merchant(prot.global_position + Vector2(100, 100))
	var mai = m.get_node("AI")
	mai.compel_victim = comp
	mai._acquire_target(comp)
	_check("compel.hunts-companion", mai.hunted_party_member() == comp)
	_check("compel.not-defended", mai.defended_hunt() == null)
	await _pframe()
	m.take_damage({"bludgeoning": 1}, m.global_position, prot)
	_check("compel.struck-is-wronged", mai.wronged_by_party())
	mai.compel_victim = null
	game.despawn_character(m)


## A killing Burning tick after a lawful fire hit is no murder; one from a
## burn the party set going unprovoked is.
func _case_lawful_burn_tick_is_no_murder() -> void:
	if comp == null:
		return
	var prot = _prot()
	var m = _merchant(prot.global_position + Vector2(-60, 120))
	m.max_health = 500
	m.current_health = 500
	m.get_node("AI").take_grudge(prot, false)
	await _pframe()  # a hunt begun this very frame is no hunt to the law
	m.take_damage({"fire": 1}, m.global_position, comp)
	_force_condition(m, "panicked", comp)
	await _pframe()  # the tick lands seconds later, judged on its own frame
	m.current_health = 2
	m._condition_tick_damage = true
	m.take_damage({"fire": 50}, m.global_position, comp)
	m._condition_tick_damage = false
	_check("burn.lawful-dead", not m.is_alive())
	_check("burn.lawful-no-murder", _murders_of(m) == 0, str(crimes))
	var n = _merchant(prot.global_position + Vector2(60, 120))
	n.current_health = 2
	n._condition_tick_damage = true
	n.take_damage({"fire": 50}, n.global_position, comp)
	n._condition_tick_damage = false
	_check("burn.unprovoked-murder", _murders_of(n) == 1, str(crimes))
	for c in [m, n]:
		game.despawn_character(c)


## One area blow: a later victim who saw an earlier one fall and turned on the
## caster mid-resolution is still a victim, not a hunter.
func _case_one_aoe_is_no_licence() -> void:
	var prot = _prot()
	var base: Vector2 = prot.global_position + Vector2(0, -140)
	var v = _merchant(base)
	var w = _merchant(base + Vector2(40, 0))
	_face(w, v.global_position)
	game._npc_was_truly_seen[w] = true
	_kill(v, prot)
	var wai = w.get_node("AI")
	_check("aoe.witness-turned", wai._holds_grudge(prot) and wai.current_target == prot, _line("w", w))
	_kill(w, prot)
	_check("aoe.second-victim-murder", _murders_of(w) == 1, str(crimes))
	for c in [v, w]:
		game.despawn_character(c)
