# res://tests/melee_bands_check.gd
# Regression guard: the AI's stand-off must agree with the melee hit test.
#
# Run:  godot --headless --path . res://tests/melee_bands_check.tscn
#
# Two bugs this locks down, both of which produced "stands in front of the enemy
# and never connects":
#
#  1. `stand` (where APPROACH walks to) used to be `combined_collision + 10`
#     while `swing` (the attack gate) was `combined_collision + 5`. Any weapon
#     whose reach fell under that floor — authored range below ~1.23 tiles, i.e.
#     sickle 0.9, dagger 0.8, shortsword 1.0, but NOT longsword or axe — parked
#     5px BEYOND its own gate and only strafed. Hence "not consistently".
#  2. `swing` was a number ai.gd invented, unrelated to what actually landed a
#     hit. It must now be exactly MeleeReach.max_center_dist — the same call
#     Game.resolve_melee_swing makes.
extends Node2D

const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

const CASES := [
	["jacana", ""],
	["default_human", ""],
	["default_human", "sickle"],
	["default_human", "dagger"],
	["default_human", "shortsword"],
	["default_human", "longsword"],
	["default_human", "battle_axe"],
	["default_human", "spear"],
	["default_human", "pike"],
]

var _victim: ProceduralCharacter = null
var _failures: int = 0


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	_victim = await _spawn("default_human", "", Vector2(0, -2000))

	print("=== AI melee engagement bands ===")
	print("gap = body contact | swing = attack gate | stand = walks to | hit = MeleeReach max")
	print("INVARIANTS: gap <= stand <= swing, and swing == hit")

	for case in CASES:
		await _check(String(case[0]), String(case[1]))

	print("=== %s ===" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


func _spawn(template: String, weapon_id: String, pos: Vector2) -> ProceduralCharacter:
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	c.position = pos
	add_child(c)
	TopDownCharacterDatabase.build_character(c, template)
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
	var a: ProceduralCharacter = await _spawn(template, weapon_id, Vector2.ZERO)
	var ai := a.get_node_or_null("AI")
	if ai == null:
		print("SKIP %s/%s: no AI node" % [template, weapon_id])
		a.queue_free()
		return
	ai.set_process(false)
	ai.set_physics_process(false)

	var bands: Dictionary = ai._engagement_bands(_victim)
	var gap: float = bands["gap"]
	var swing: float = bands["swing"]
	var stand: float = bands["stand"]
	var w = a.current_main_hand_item
	var hit_max: float = MeleeReach.max_center_dist(a, _victim, w)

	var notes: Array = []
	if stand > swing:
		notes.append("STAND>SWING")
		_failures += 1
	if stand < gap - 0.01:
		notes.append("stand inside body contact")
		_failures += 1
	if absf(swing - hit_max) > 0.01:
		notes.append("swing %.1f != hit max %.1f" % [swing, hit_max])
		_failures += 1

	var label: String = weapon_id if weapon_id != "" else ("unarmed" if w == null else String(w.display_name))
	print("    %-13s %-11s gap=%-5.1f stand=%-6.1f swing=%-6.1f hit=%-6.1f  %s" % [
		template, label, gap, stand, swing, hit_max,
		"OK" if notes.is_empty() else " ; ".join(notes)])
	a.queue_free()
	await get_tree().process_frame
