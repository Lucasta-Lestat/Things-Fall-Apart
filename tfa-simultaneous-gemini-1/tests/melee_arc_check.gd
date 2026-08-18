# res://tests/melee_arc_check.gd
# Maps the melee hit field (bearing x distance) under the reach + arc model.
#
# Run:  godot --headless --path . res://tests/melee_arc_check.tscn
#
# Before the model change this harness drove a real swing per cell and read the
# blade Area2D. It measured, for every slashing weapon at every distance:
#
#     dist\deg -120 -105  -90  -75  -60  -45  -30  -20  -10    0   10   20   30 ...
#       60        #    #    #    #    #    #    #    #    #    #    #    #    .
#       70        #    #    #    #    #    #    #    #    #    #    #    .    .
#
# — an arc centred ~50deg off the wielder's LEFT, with the entire right flank
# immune, because the blade Area2D hangs off the rig hand ~60px off-centre.
# Piercing weapons (dagger/spear/pike) hit NOTHING at any cell.
#
# MeleeReach is pure, so this now samples it directly: no animation, no physics,
# runs in seconds, and asserts the field is symmetric about facing.
extends Node2D

const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

const CASES := [
	["jacana", ""],
	["default_human", ""],            # unarmed
	["default_human", "sickle"],
	["default_human", "dagger"],
	["default_human", "shortsword"],
	["default_human", "longsword"],
	["default_human", "battle_axe"],
	["default_human", "spear"],
]

const DISTS := [40.0, 50.0, 60.0, 70.0, 80.0, 100.0, 130.0, 180.0, 230.0]
const ANGLES := [-120.0, -90.0, -60.0, -45.0, -30.0, -15.0, 0.0, 15.0, 30.0, 45.0, 60.0, 90.0, 120.0]

var _victim: ProceduralCharacter = null
var _failures: int = 0


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	_victim = await _spawn("default_human", "", Vector2(0, -2000))

	print("=== melee hit field: reach + arc (TILE_SIZE=%d) ===" % GridManager.TILE_SIZE)
	print("victim body radius=%.1f | rows = centre-to-centre px, cols = bearing deg (+ = attacker's RIGHT)" % \
		_victim._body_circle_radius())

	for case in CASES:
		await _map(String(case[0]), String(case[1]))

	print("=== %s ===" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


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


func _map(template: String, weapon_id: String) -> void:
	var a: ProceduralCharacter = await _spawn(template, weapon_id, Vector2.ZERO)
	a.rotation = 0.0
	var w = a.current_main_hand_item
	var dmg: String = String(w.primary_damage_type) if w is WeaponShape else String(a.unarmed_strike_damage_type)
	var label: String = weapon_id if weapon_id != "" else ("unarmed" if w == null else String(w.display_name))

	print("--- %s / %s  dmg=%-12s reach=%.1f  max_centre=%.1f  arc=+/-%.0fdeg" % [
		template, label, dmg,
		MeleeReach.reach_px(a, w),
		MeleeReach.max_center_dist(a, _victim, w),
		rad_to_deg(MeleeReach.half_arc_rad(w, dmg))])

	var hdr := "     dist\\deg"
	for ang in ANGLES:
		hdr += "%5.0f" % ang
	print(hdr)

	for d in DISTS:
		var row := "     %-9.0f" % d
		var hits: Array = []
		for ang in ANGLES:
			_victim.global_position = Vector2(0, -d).rotated(deg_to_rad(ang))
			var hit: bool = MeleeReach.in_swing(a, _victim, w, dmg)
			hits.append(hit)
			row += "%5s" % ("#" if hit else ".")
		print(row)
		# The whole point of the change: the field must be symmetric about
		# facing. ANGLES is symmetric, so hits must mirror end-to-end.
		for i in ANGLES.size():
			if hits[i] != hits[ANGLES.size() - 1 - i]:
				print("      ASYMMETRY at d=%.0f, %+.0f vs %+.0f" % [d, ANGLES[i], ANGLES[ANGLES.size() - 1 - i]])
				_failures += 1

	# Every melee weapon must be able to hit something dead ahead, at some
	# distance. Piercing weapons previously could not, at any distance at all.
	var any_forward := false
	for d in DISTS:
		_victim.global_position = Vector2(0, -d)
		if MeleeReach.in_swing(a, _victim, w, dmg):
			any_forward = true
			break
	if not any_forward:
		print("      NO FORWARD HIT at any sampled distance")
		_failures += 1

	_victim.global_position = Vector2(0, -2000)
	a.queue_free()
	await get_tree().process_frame
