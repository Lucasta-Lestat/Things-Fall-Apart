# res://tests/melee_repeat_check.gd
# Regression guard for the weapon hitbox LIFECYCLE and its target scope.
#
# Run:  godot --headless --path . res://tests/melee_repeat_check.tscn
#
# Two things this locks down:
#
#  1. The melee state machine used to reach IDLE without ever calling
#     AttackAnimator._finish_attack() — RECOVERY only emitted attack_finished,
#     and the listener (ProceduralCharacter._on_attack_finished) cleared
#     is_attacking but not the hitbox. The blade Area2D was therefore left
#     monitoring FOREVER after the first swing. Because object damage dispatch
#     is body_entered — an EDGE, not a state — anything already inside the idle
#     blade would silently eat the next swing against it.
#
#  2. The hitbox must NOT mask CHARACTERS. Character melee resolves through
#     MeleeReach / Game.resolve_melee_swing; if CHARACTERS came back into the
#     mask, every hit would be applied twice in the same swing.
extends Node2D

const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const SWINGS := 5

const CASES := [["jacana", ""], ["default_human", "longsword"], ["default_human", "spear"]]

var _failures: int = 0


func can_hit_target(_a: Node2D, _t: Node2D) -> bool: return true
func register_hit(_a: Node2D, _t: Node2D) -> void: pass
func register_attack_start(_a: Node2D) -> void: pass
func register_attack_end(_a: Node2D) -> void: pass
func process_weapon_hit(_a, _t, _p, _w, _v) -> void: pass
func process_object_hit(_a, _t, _p, _w, _v) -> void: pass

# Spy for the third thing under test: ProceduralCharacter._on_attack_hit must
# reach the combat manager's resolve_melee_swing once per swing, with the right
# hand. That call IS character melee now — if the wiring breaks, nothing deals
# melee damage at all and every other test here still passes.
var _resolve_calls: Array = []
func resolve_melee_swing(_attacker: Node2D, hand: String) -> void:
	_resolve_calls.append(hand)


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)

	print("=== weapon hitbox lifecycle (%d consecutive swings) ===" % SWINGS)
	for case in CASES:
		await _check(String(case[0]), String(case[1]))
	print("=== %s ===" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


func _spawn(template: String, weapon_id: String) -> ProceduralCharacter:
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	add_child(c)
	TopDownCharacterDatabase.build_character(c, template)
	var ai := c.get_node_or_null("AI")
	if ai:
		ai.set_process(false)
		ai.set_physics_process(false)
	c.set_physics_process(false)
	for i in 20:
		await get_tree().process_frame
	if weapon_id != "":
		var data: Dictionary = ItemDatabase.get_item_data(weapon_id)
		if not data.is_empty():
			c.inventory.equip_weapon_from_data(data.duplicate(true), "Main")
			for i in 10:
				await get_tree().process_frame
	return c


func _check(template: String, weapon_id: String) -> void:
	var a: ProceduralCharacter = await _spawn(template, weapon_id)
	var w = a.current_main_hand_item
	if w == null or not (w is WeaponShape) or w.hitbox == null:
		print("SKIP %s/%s: no main-hand WeaponShape hitbox" % [template, weapon_id])
		a.queue_free()
		return

	var notes: Array = []
	if (w.hitbox.collision_mask & CollisionLayers.CHARACTERS) != 0:
		notes.append("hitbox masks CHARACTERS (double-dip with resolve_melee_swing)")
		_failures += 1

	var idle_states := ""
	var live_seen := false
	_resolve_calls.clear()
	for s in SWINGS:
		a.attack("Main", Vector2(0, -60), null)
		var frames := 0
		while a.attack_animator.is_attacking and frames < 240:
			if w.hitbox.monitoring:
				live_seen = true
			await get_tree().process_frame
			frames += 1
		for i in 8:
			await get_tree().process_frame
		idle_states += "1" if w.hitbox.monitoring else "0"

	if idle_states.contains("1"):
		notes.append("hitbox still monitoring between swings (_finish_attack skipped)")
		_failures += 1
	if not live_seen:
		notes.append("hitbox never armed during the swing")
		_failures += 1
	if _resolve_calls.size() != SWINGS:
		notes.append("resolve_melee_swing called %d times, expected %d" % [_resolve_calls.size(), SWINGS])
		_failures += 1
	for h in _resolve_calls:
		if String(h) != "Main":
			notes.append("resolve_melee_swing got hand '%s', expected Main" % str(h))
			_failures += 1
			break

	print("    %-13s %-11s monitoring_between_swings=%s armed=%-5s resolve_calls=%d/%d  %s" % [
		template, weapon_id if weapon_id != "" else String(w.display_name),
		idle_states, str(live_seen), _resolve_calls.size(), SWINGS,
		"OK" if notes.is_empty() else " ; ".join(notes)])
	a.queue_free()
	await get_tree().process_frame
