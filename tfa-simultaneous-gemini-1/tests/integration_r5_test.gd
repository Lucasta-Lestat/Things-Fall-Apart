# res://tests/integration_r5_test.gd
# Round 5 integration: the dot-tune lane (Burning max 4, 5 per stack, damage
# over time ignores armour, Poisoned turns into Toxic Shock at 4, neutral
# duration multipliers) against the invisible-npc lane (an invisible NPC is
# hidden from the party unless the party is aware of it).
#   - A transform (Poisoned -> Toxic Shock, Chilled -> Frozen) is no new
#     contact: it carries the condition's FIRST applier as its source, so a
#     sourceless dose turning an old party-applied Poisoned must not locate a
#     hidden invisible NPC (either way round). A fresh condition from a party
#     member still does.
#   - A damage-over-time tick on or from a hidden invisible NPC doesn't locate
#     it, ignores its armour, and its fire, light and overhead icons stay
#     hidden with it; located, they show and the hover reads both the reason
#     and the tick ("4 fire every 1 s").
#   - A party member's 16-cold hit on one it can't see freezes it in one hit
#     (16 since round 6: Chilled freezes at 4, so 15 is Chilled x3):
#     "hits something invisible." is logged, the transform line isn't (it
#     wasn't seen), and once located the hover shows Frozen.
#   - Toxic Shock survives a ConditionManager save round trip, its doubling
#     tick where it was (round 6); the duration table isn't saved.
# Drives the real Game on town_square.
# Run:  godot --headless --path . res://tests/integration_r5_test.tscn
# Judge by PASS/FAIL lines and "HARNESS DONE failures=0".
extends Node2D

var failures := 0
var checks := 0
var game = null
var hover = null
var p = null
var others: Array = []
var face := 0.0
var _spawned: Array = []

func _check(check_name: String, ok: bool, detail = "") -> void:
	checks += 1
	if ok:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, str(detail)])

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _physics(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _log_count(fragment: String) -> int:
	var n := 0
	for e in GameLog.get_entries():
		if fragment in str(e.get("text", "")):
			n += 1
	return n

func _log_tail() -> String:
	var out: Array = []
	for e in GameLog.get_entries().slice(-4):
		out.append(str(e.get("text", "")))
	return str(out)

func _advance(seconds: float) -> void:
	TimeManager.game_time += seconds

func _ready() -> void:
	get_tree().create_timer(300.0, true).timeout.connect(func():
		print("FAIL watchdog timeout (coroutine aborted?) failures=%d" % failures)
		get_tree().quit(99))
	await get_tree().process_frame
	game = load("res://game.tscn").instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _frames(2)
	game.load_map("town_square")
	await _frames(10)
	if PauseManager.is_paused:
		PauseManager.unpause()
	TimeManager.pause_time()   # the awareness clock and DoT ticks are moved by hand
	_check("game.loaded", game.party_chars.size() > 0)
	if game.party_chars.is_empty():
		_finish()
		return
	hover = game.get_node_or_null("WorldHoverInfo")
	_setup()
	await _frames(3)

	await _case_transform_no_contact()
	await _case_party_transform_no_contact()
	await _case_dot_on_hidden()
	await _case_dot_from_hidden()
	await _case_freeze_unseen()
	await _case_save()
	_finish()

func _finish() -> void:
	print("HARNESS DONE failures=%d checks=%d" % [failures, checks])
	get_tree().quit(1 if failures > 0 else 0)

# ---------------------------------------------------------------------------
# Setup and helpers (as invisible_npc_r5_test)
# ---------------------------------------------------------------------------

func _setup() -> void:
	for c in game.characters_in_scene:
		if is_instance_valid(c):
			c.AI_enabled = false
	p = game.party_chars[0]
	for deg in range(0, 360, 15):
		var a: float = deg_to_rad(deg)
		if GridManager.sight_line_clear(p.get_world_2d().direct_space_state, p.global_position,
				p.global_position + Vector2.UP.rotated(a) * 450.0, p.get_elevation(), 0.0):
			face = a
			break
	_turn(p, face)
	var i := 1
	for pc in game.party_chars:
		if pc == p:
			continue
		others.append(pc)
		pc.global_position = p.global_position - Vector2.UP.rotated(face) * (40.0 * i)
		_turn(pc, face + PI)
		i += 1

func _turn(c, ang: float) -> void:
	c.rotation = ang
	c.target_rotation = ang

func _ahead(dist: float) -> Vector2:
	return p.global_position + Vector2.UP.rotated(face) * dist

func _spawn(npc_name: String, dist: float, faction: String = "bandits"):
	var npc = game._spawn_character("default_human", _ahead(dist), {"faction": faction})
	if npc == null:
		return null
	npc.AI_enabled = false
	npc.faction_id = faction
	npc.Name = npc_name
	_turn(npc, face)
	_spawned.append(npc)
	return npc

func _despawn_all() -> void:
	for npc in _spawned:
		if is_instance_valid(npc):
			game.characters_in_scene.erase(npc)
			npc.queue_free()
	_spawned.clear()
	_turn(p, face)
	await _frames(2)

## Invisible where the party can't see it, then the leader faces it again:
## Invisible with no cue at all.
func _invisible_unseen(npc) -> void:
	_turn(p, face + PI)
	await _frames(3)
	npc.condition_manager.apply_condition("invisible", null, 1, -1.0)
	await _frames(1)
	_turn(p, face)
	await _frames(3)
	await _physics(2)

## The party's awareness of every invisible NPC runs out (game time).
func _lapse() -> void:
	_advance(game.INVISIBLE_AWARE_SECONDS + 1.0)
	await _frames(3)

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

## A party member's old dose, turned by a dose from nobody: no contact.
func _case_transform_no_contact() -> void:
	var dosed = _spawn("Dosed", 300.0)
	await _frames(3)
	# Seen and not yet invisible: the party member's doses carry no cue.
	dosed.condition_manager.apply_condition("poisoned", p, 3)
	dosed.condition_manager.apply_condition("chilled", p, 3)
	await _invisible_unseen(dosed)
	_check("xform.control-hidden", not game.is_seen_by_party(dosed))
	_check("xform.control-poisoned-from-party", dosed.condition_manager.get_condition("poisoned") != null
		and dosed.condition_manager.get_condition("poisoned").source == p)
	var lines := _log_count("Dosed's Poisoned reaches")
	# A poison puddle's dose (no source) brings the 4th stack.
	dosed.condition_manager.apply_condition("poisoned", null, 1)
	_check("xform.toxic-shock", dosed.condition_manager.has_condition("toxic_shock")
		and not dosed.condition_manager.has_condition("poisoned"))
	await _frames(3)
	_check("xform.toxic-shock-no-locate", not game.is_seen_by_party(dosed), game.invisible_perception_text(dosed))
	_check("xform.hidden-no-transform-line", _log_count("Dosed's Poisoned reaches") == lines, _log_tail())
	# Chilled's 4th stack from a sourceless dose: Frozen, still hidden.
	dosed.condition_manager.apply_condition("chilled", null, 1)
	_check("xform.frozen", dosed.condition_manager.has_condition("frozen"))
	await _frames(3)
	_check("xform.frozen-no-locate", not game.is_seen_by_party(dosed))
	_check("xform.still-not-drawn", not dosed.visible or dosed.modulate.a == 0.0, [dosed.visible, dosed.modulate.a])
	# Control: a fresh condition a party member puts on it still locates it.
	dosed.condition_manager.apply_condition("weakened", p, 1)
	await _frames(3)
	_check("xform.control-fresh-condition-locates", game.is_seen_by_party(dosed))
	await _despawn_all()

## The same the other way round: a party member's Poisoned from an invisible
## NPC, turned later by a sourceless dose, doesn't locate the NPC.
func _case_party_transform_no_contact() -> void:
	var poisoner = _spawn("Poisoner", 320.0)
	await _invisible_unseen(poisoner)
	_check("party-xform.control-hidden", not game.is_seen_by_party(poisoner))
	# Its dose lands on the party member: that is a contact.
	p.condition_manager.apply_condition("poisoned", poisoner, 3)
	await _frames(3)
	_check("party-xform.dose-locates", game.is_seen_by_party(poisoner))
	await _lapse()
	_check("party-xform.lapsed", not game.is_seen_by_party(poisoner))
	p.condition_manager.apply_condition("poisoned", null, 1)
	_check("party-xform.toxic-shock", p.condition_manager.has_condition("toxic_shock"))
	await _frames(3)
	_check("party-xform.no-locate", not game.is_seen_by_party(poisoner), game.invisible_perception_text(poisoner))
	p.condition_manager.remove_condition("toxic_shock")
	p.condition_manager.remove_condition("poisoned")
	p.current_health = p.max_health
	await _despawn_all()

## A Burning on a hidden invisible NPC: the ticks ignore its armour and don't
## give it away, and its flames, light and icons hide with it.
func _case_dot_on_hidden() -> void:
	var burner = _spawn("Burner", 300.0)
	await _frames(3)
	burner.set_limb_armor(ProceduralCharacter.LimbType.TORSO, {"fire": 5})
	burner.condition_manager.apply_condition("burning", p, 4)
	await _frames(2)
	await _invisible_unseen(burner)
	_check("dot-on.control-hidden", not game.is_seen_by_party(burner))
	var fire = burner._active_condition_vfx.get("burning", null)
	_check("dot-on.fire-vfx-exists", fire != null and is_instance_valid(fire))
	if fire != null and is_instance_valid(fire):
		_check("dot-on.fire-hidden", not fire.is_visible_in_tree())
		var light = fire.get_node_or_null("PointLight2D")
		_check("dot-on.fire-light-hidden", light == null or not light.is_visible_in_tree())
	_check("dot-on.icons-hidden", burner._condition_display == null or not burner._condition_display.is_visible_in_tree())
	var hp: int = burner.current_health
	_advance(1.0)
	await _frames(3)
	_check("dot-on.tick-ignores-armour", hp - burner.current_health == 4, [hp, burner.current_health])
	_check("dot-on.tick-no-locate", not game.is_seen_by_party(burner))
	# Located by a blow: drawn see-through, flames and all, and the hover says
	# why and what the burn does.
	burner.take_damage({"bludgeoning": 1}, burner.global_position, p)
	await _frames(3)
	_check("dot-on.hit-locates", game.is_seen_by_party(burner))
	if fire != null and is_instance_valid(fire):
		_check("dot-on.fire-shown-located", fire.is_visible_in_tree())
	var desc: String = hover.describe_character(burner) if hover != null else ""
	_check("dot-on.hover-reason", "located by a hit" in desc, desc)
	_check("dot-on.hover-tick", "4 fire every 1 s" in desc, desc)
	await _despawn_all()

## A Burning an invisible NPC put on a party member: its ticks are no blow, so
## they neither locate it nor say "hit by something invisible".
func _case_dot_from_hidden() -> void:
	var torch = _spawn("Torch", 330.0)
	await _frames(3)
	p.condition_manager.apply_condition("burning", torch, 2)
	await _frames(2)
	await _invisible_unseen(torch)
	_check("dot-from.control-hidden", not game.is_seen_by_party(torch))
	var lines := _log_count("hit by something invisible")
	var hp: int = p.current_health
	_advance(1.0)
	await _frames(3)
	_check("dot-from.ticked", p.current_health < hp, [hp, p.current_health])
	_check("dot-from.no-locate", not game.is_seen_by_party(torch))
	_check("dot-from.no-hit-line", _log_count("hit by something invisible") == lines, _log_tail())
	p.condition_manager.remove_condition("burning")
	p.current_health = p.max_health
	await _despawn_all()

## 16 cold from a party member on one it can't see (an Iciclet thrown at STR
## 57+): frozen in one hit.
func _case_freeze_unseen() -> void:
	var iced = _spawn("Iced", 280.0)
	await _invisible_unseen(iced)
	_check("freeze.control-hidden", not game.is_seen_by_party(iced))
	var hits := _log_count("%s hits something invisible." % p.Name)
	var xform := _log_count("Iced's Chilled reaches")
	iced.take_damage({"cold": 16}, iced.global_position, p)
	_check("freeze.frozen-one-hit", iced.condition_manager.has_condition("frozen"))
	_check("freeze.hit-line", _log_count("%s hits something invisible." % p.Name) == hits + 1, _log_tail())
	_check("freeze.no-transform-line-unseen", _log_count("Iced's Chilled reaches") == xform, _log_tail())
	await _frames(3)
	_check("freeze.located", game.is_seen_by_party(iced))
	var desc: String = hover.describe_character(iced) if hover != null else ""
	_check("freeze.hover-frozen", "Frozen" in desc, desc)
	await _despawn_all()

func _case_save() -> void:
	var held = _spawn("Held", 260.0)
	await _frames(3)
	held.condition_manager.apply_condition("toxic_shock", null)
	# Three doublings in (round 6): the next tick is 8, and stays 8 after.
	held.condition_manager.get_condition("toxic_shock").step_escalation(0, 3)
	var d: Dictionary = held.condition_manager.to_dict()
	held.condition_manager.clear_all_conditions()
	held.condition_manager.from_dict(d)
	var ts = held.condition_manager.get_condition("toxic_shock")
	_check("save.toxic-shock-round-trip", ts != null and ts.get_dot_text() == "8 poison every 2 s, doubling", ts.get_dot_text() if ts else "none")
	var state: Dictionary = game._serialize_character(held)
	_check("save.no-duration-table", not state.has("MODIFY_DURATION_BY_TRAIT"))
	await _despawn_all()
