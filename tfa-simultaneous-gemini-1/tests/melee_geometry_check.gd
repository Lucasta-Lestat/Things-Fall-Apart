# res://tests/melee_geometry_check.gd
#
# Regression guard for GEOMETRY-DERIVED melee reach + the wall veto.
#
# Run:  godot --headless --path . res://tests/melee_geometry_check.tscn
#
# 1. reach_px must equal (HAND_REACH_PX + total_length * grip_position)
#    * body_size_mod — the drawn blade, not the authored Items.json "range".
#    The range stat is ranged-only now: the spear family authored 3.0-4.5
#    tiles back when nothing consumed the value, and promoting it to the hit
#    distance landed thrusts from ~2x the visible tip.
# 2. The reach ladder must survive the derivation: dagger < longsword < spear
#    < pike, so polearms still out-range swords via their (lengthened) art.
# 3. blade_line_clear must veto a blade line crossing a vision-blocking wall
#    and clear again when the wall goes — the through-wall-skewer guard.
extends Node2D

const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const LADDER := ["dagger", "longsword", "spear", "pike"]

var _failures: int = 0


func _check(ok: bool, label: String) -> void:
	if not ok:
		_failures += 1
	print("    %-58s %s" % [label, "OK" if ok else "FAIL"])


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)

	var victim: ProceduralCharacter = await _spawn("default_human", "", Vector2(0, -2000))
	var reaches: Array[float] = []

	print("=== melee reach derived from weapon geometry ===")
	var unarmed: ProceduralCharacter = await _spawn("default_human", "", Vector2.ZERO)
	var expected_unarmed: float = maxf(
		MeleeReach.UNARMED_REACH_PX * float(unarmed.body_size_mod),
		unarmed._body_circle_radius() + MeleeReach.MIN_CLEARANCE_PX)
	_check(absf(MeleeReach.reach_px(unarmed, null) - expected_unarmed) < 0.01,
		"unarmed reach == %.1f" % expected_unarmed)
	unarmed.queue_free()
	await get_tree().process_frame

	for weapon_id in LADDER:
		var a: ProceduralCharacter = await _spawn("default_human", String(weapon_id), Vector2.ZERO)
		var w = a.current_main_hand_item
		if not (w is WeaponShape):
			_check(false, "%s: no WeaponShape equipped" % weapon_id)
			a.queue_free()
			continue
		var got: float = MeleeReach.reach_px(a, w)
		var expected: float = (MeleeReach.HAND_REACH_PX \
			+ float(w.total_length) * float(w.grip_position)) * float(a.body_size_mod)
		_check(absf(got - expected) < 0.01,
			"%s reach %.1f == hand + drawn blade (len %.0f, grip %.2f)" \
			% [weapon_id, got, float(w.total_length), float(w.grip_position)])
		reaches.append(got)
		a.queue_free()
		await get_tree().process_frame

	for i in range(1, reaches.size()):
		_check(reaches[i] > reaches[i - 1] + 1.0,
			"ladder: %s (%.1f) out-reaches %s (%.1f)" \
			% [LADDER[i], reaches[i], LADDER[i - 1], reaches[i - 1]])

	print("=== wall veto (blade_line_clear) ===")
	var attacker: ProceduralCharacter = await _spawn("default_human", "spear", Vector2.ZERO)
	attacker.rotation = 0.0
	victim.global_position = Vector2(0, -120)
	_check(MeleeReach.in_swing(attacker, victim, attacker.current_main_hand_item, "piercing"),
		"victim at 120px dead ahead is inside a spear thrust")
	_check(MeleeReach.blade_line_clear(_space(), attacker, victim),
		"open ground: blade line clear")

	# No occlude_top meta on purpose: sight_line_clear treats meta-less bodies
	# as always-blocking (the legacy-map behavior), which is the common case
	# for walls.
	var wall := StaticBody2D.new()
	wall.collision_layer = CollisionLayers.VISION_BLOCKERS
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(80, 12)
	shape.shape = rect
	wall.add_child(shape)
	wall.position = Vector2(0, -60)
	add_child(wall)
	for i in 3:
		await get_tree().physics_frame
	_check(not MeleeReach.blade_line_clear(_space(), attacker, victim),
		"wall between the pair blocks the blade")

	wall.queue_free()
	for i in 3:
		await get_tree().physics_frame
	_check(MeleeReach.blade_line_clear(_space(), attacker, victim),
		"wall removed: blade line clear again")

	print("=== %s ===" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


func _space() -> PhysicsDirectSpaceState2D:
	return get_world_2d().direct_space_state


func _spawn(template: String, weapon_id: String, pos: Vector2) -> ProceduralCharacter:
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	c.position = pos
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
