# res://tests/melee_reach_check.gd
#
# SUPERSEDED — kept only as the record of the OLD physical model. Character
# melee no longer resolves through the blade Area2D (see MeleeReach and
# Game.resolve_melee_swing), and the hitbox no longer masks CHARACTERS, so every
# cell in this harness now reports a miss. That is expected, not a regression.
# For the live model use melee_arc_check (hit field), melee_bands_check (AI
# stand-off agrees with the hit test) and melee_repeat_check (hitbox lifecycle).
#
# Diagnostic harness for the melee range/hitbox mismatch.
#
# Run:  godot --headless --path . res://tests/melee_reach_check.tscn
#
# Melee damage is resolved PHYSICALLY: WeaponShape's blade Area2D must overlap
# the victim's body during the swing. Nothing reconciles that physical reach
# with either the authored Items.json "range" (tiles) or the stand-off distance
# the AI actually walks to (ai.gd safe_attack_range). This drives a real swing
# against a real victim at a sweep of distances and reports the true hit window.
extends Node2D

const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

# (wielder template, weapon item id or "" to keep the template's own main hand)
const CASES := [
	["jacana", ""],
	["default_human", "sickle"],
	["default_human", "dagger"],
	["default_human", "shortsword"],
	["default_human", "longsword"],
	["default_human", "battle_axe"],
	["default_human", "spear"],
	["default_human", "pike"],
]

const DISTS := [45.0, 50.0, 55.0, 60.0, 65.0, 70.0, 75.0, 80.0, 90.0, 100.0]
const TRACE_CASES := []
# Victim bearings to sweep, degrees clockwise from "dead ahead" (attacker -Y).
const ANGLES := [-90.0, -60.0, -30.0, -15.0, 0.0, 15.0, 30.0, 60.0, 90.0]

var _victim: ProceduralCharacter = null
var _hits: Dictionary = {}
var _verbose := false
var _trace := false


# --- combat-manager stubs the WeaponShape hitbox calls into ---------------
func can_hit_target(_a: Node2D, _t: Node2D) -> bool: return true
func register_hit(_a: Node2D, _t: Node2D) -> void: pass
func register_attack_start(_a: Node2D) -> void: pass
func register_attack_end(_a: Node2D) -> void: pass
func process_weapon_hit(_a, t, _p, _w, _v) -> void: _hits[t.get_instance_id()] = true
func process_object_hit(_a, t, _p, _w, _v) -> void: _hits[t.get_instance_id()] = true


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)

	_victim = await _spawn("default_human", "", Vector2(0, -1000))
	_victim.set_process(false)

	print("=== melee reach vs. AI stand-off (TILE_SIZE=%d) ===" % GridManager.TILE_SIZE)
	print("victim body radius=%.1f  collision_radius=%.1f" % [
		_victim._body_circle_radius(), _victim.collision_radius])

	for case in CASES:
		await _measure(String(case[0]), String(case[1]))

	get_tree().quit(0)


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
		if data.is_empty():
			push_warning("no item data for " + weapon_id)
		else:
			c.inventory.equip_weapon_from_data(data.duplicate(true), "Main")
			for i in 10:
				await get_tree().process_frame
	return c


func _measure(template: String, weapon_id: String) -> void:
	var a: ProceduralCharacter = await _spawn(template, weapon_id, Vector2.ZERO)
	a.rotation = 0.0   # local -Y is forward; victim sits straight ahead

	var w = a.current_main_hand_item
	if w == null or not (w is WeaponShape):
		print("SKIP %s/%s: no main-hand WeaponShape" % [template, weapon_id])
		a.queue_free()
		return

	var ai := a.get_node_or_null("AI")
	var ai_attack_range: float = float(ai.attack_range) if ai else -1.0
	var combined: float = a.collision_radius + _victim.collision_radius + a.minimum_separation
	var safe_attack_range: float = maxf(ai_attack_range, combined + 5.0)
	var body_gap: float = a._body_circle_radius() + _victim._body_circle_radius() + a.minimum_separation

	print("--- %s / %s  authored=%.2ft(%.0fpx) blade_reach=%.1f | ai_range=%.1f safe=%.1f | body_gap=%.1f" % [
		template, weapon_id if weapon_id != "" else w.display_name,
		w.weapon_range, w.weapon_range * GridManager.TILE_SIZE,
		w.total_length * w.grip_position, ai_attack_range, safe_attack_range, body_gap])

	# Dead-ahead distance sweep (the attacker always faces its target in game).
	var line := "    dist  "
	for d in DISTS:
		var res: Array = await _swing_at(a, d, 0.0)
		line += "%3.0f:%s " % [d, "H" if res[0] else "."]
	print(line)

	# Bearing sweep at the AI's own stand-off distance: how wide is the arc, i.e.
	# how much facing error the swing tolerates.
	line = "    bear@%-3.0f" % safe_attack_range
	for ang in ANGLES:
		var res: Array = await _swing_at(a, safe_attack_range, ang)
		line += "%+4.0f:%s " % [ang, "H" if res[0] else "."]
	print(line)

	a.queue_free()
	await get_tree().process_frame


# One full swing against the victim parked `d` px straight ahead. Returns
# [did_hit, max_tip_distance_from_attacker_origin].
func _swing_at(a: ProceduralCharacter, d: float, bearing_deg: float) -> Array:
	_hits.clear()
	var spot: Vector2 = Vector2(0, -d).rotated(deg_to_rad(bearing_deg))
	_victim.global_position = spot
	await get_tree().physics_frame
	var w = a.current_main_hand_item
	a.attack_animator._finish_attack()
	a.attack("Main", _victim.global_position, null)
	var tip_max: float = 0.0
	var frames := 0
	var monitored := false
	var overlapped := false
	var min_blade_gap: float = 1e9
	while a.attack_animator.is_attacking and frames < 240:
		a.global_position = Vector2.ZERO
		a.rotation = 0.0
		_victim.global_position = spot
		var tip: Vector2 = w.to_global(w.get_tip_local_position())
		tip_max = maxf(tip_max, tip.distance_to(a.global_position))
		if w.hitbox:
			if w.hitbox.monitoring:
				monitored = true
			if _victim in w.hitbox.get_overlapping_bodies():
				overlapped = true
		# closest approach of the blade segment to the victim centre
		var rect: Rect2 = w.get_blade_collision_rect()
		for i in 17:
			var t: float = float(i) / 16.0
			var p: Vector2 = w.to_global(Vector2(0.0, lerp(rect.position.y, rect.end.y, t)))
			min_blade_gap = minf(min_blade_gap, p.distance_to(_victim.global_position))
		if _trace and frames % 3 == 0:
			var tl: Vector2 = a.to_local(tip)
			var hl: Vector2 = a.to_local(a.main_hand_holder.global_position)
			print("      f%-3d hand=(%6.1f,%6.1f) tip=(%6.1f,%6.1f) rot=%.2f" % [
				frames, hl.x, hl.y, tl.x, tl.y, w.global_rotation - a.global_rotation])
		await get_tree().process_frame
		frames += 1
	var hit: bool = _hits.has(_victim.get_instance_id())
	if _verbose:
		print("      d=%-5.0f bear=%+5.0f hit=%-5s overlap=%-5s blade_gap=%.1f tip_max=%.1f" % [
			d, bearing_deg, str(hit), str(overlapped), min_blade_gap, tip_max])
	_victim.global_position = Vector2(0, -1000)
	await get_tree().physics_frame
	return [hit, tip_max]
