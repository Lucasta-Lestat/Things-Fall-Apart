# CollisionDebugVisualizer.gd
# Attach to a Node2D in your scene to visualize collision hitboxes,
# structure colliders, and recent weapon hits.
# Master toggle is DebugManager.enabled (F12 in Game.gd).
# Requires: game.characters_in_scene to return array of characters.
extends Node2D
class_name CollisionDebugVisualizer

@export var enabled: bool = false
@export var show_body_hitbox: bool = true
@export var show_limb_zones: bool = true
@export var show_weapon_line: bool = true
@export var show_arm_reach: bool = true
@export var show_structure_hitboxes: bool = true
@export var show_hit_markers: bool = true

# Colors for different elements
@export var body_hitbox_color: Color = Color(1.0, 0.0, 0.0, 0.3)
@export var body_outline_color: Color = Color(1.0, 0.0, 0.0, 0.8)
@export var head_zone_color: Color = Color(1.0, 1.0, 0.0, 0.3)
@export var arm_zone_color: Color = Color(0.0, 1.0, 0.0, 0.3)
@export var leg_zone_color: Color = Color(0.0, 0.5, 1.0, 0.3)
@export var torso_zone_color: Color = Color(1.0, 0.5, 0.0, 0.3)
@export var weapon_line_color: Color = Color(1.0, 0.0, 1.0, 0.9)
@export var fist_line_color: Color = Color(0.8, 0.2, 0.8, 0.9)
@export var structure_color: Color = Color(0.0, 0.7, 1.0, 0.25)
@export var structure_outline_color: Color = Color(0.0, 0.7, 1.0, 0.8)
@export var hit_marker_penetrated_color: Color = Color(0.2, 1.0, 0.3, 1.0)
@export var hit_marker_bounced_color: Color = Color(1.0, 0.3, 0.2, 1.0)

@export var line_width: float = 2.0

# How long a recorded weapon-hit marker stays on screen.
const HIT_MARKER_LIFETIME: float = 1.0
# Cap on retained hits — older entries are dropped.
const MAX_RECENT_HITS: int = 32

var game: Node = null
var _hit_marker_font: Font = null

# Each entry: { position: Vector2, time_left: float, limb_name: String,
#               penetrated: bool, damage: float }
var recent_hits: Array = []

func _ready() -> void:
	# Find the game node - adjust path as needed
	game = get_tree().current_scene
	z_index = 100  # Draw on top of everything

	# Default font for tiny limb-name labels above hit markers.
	_hit_marker_font = ThemeDB.fallback_font

	# Master debug toggle — sync once and listen for changes.
	if Engine.has_singleton("DebugManager") or typeof(DebugManager) != TYPE_NIL:
		enabled = DebugManager.enabled
		if not DebugManager.enabled_changed.is_connected(_on_debug_enabled_changed):
			DebugManager.enabled_changed.connect(_on_debug_enabled_changed)
	visible = enabled

func _on_debug_enabled_changed(value: bool) -> void:
	enabled = value
	visible = value
	if not value:
		recent_hits.clear()
	queue_redraw()

func _process(delta: float) -> void:
	if not enabled:
		return
	# Tick down hit markers.
	if not recent_hits.is_empty():
		var i := recent_hits.size() - 1
		while i >= 0:
			recent_hits[i].time_left -= delta
			if recent_hits[i].time_left <= 0.0:
				recent_hits.remove_at(i)
			i -= 1
	queue_redraw()

func _draw() -> void:
	if not enabled or game == null:
		return

	var characters = game.characters_in_scene
	if characters != null:
		for character in characters:
			if character == null or not is_instance_valid(character):
				continue

			if show_body_hitbox:
				_draw_body_hitbox(character)

			if show_limb_zones:
				_draw_limb_zones(character)

			if show_weapon_line:
				_draw_weapon_hit_line(character)

			if show_arm_reach:
				_draw_arm_joints(character)

	if show_structure_hitboxes:
		_draw_structures()

	if show_hit_markers:
		_draw_hit_markers()

func _draw_body_hitbox(character) -> void:
	"""Draw the rectangular body hitbox used for collision detection"""
	var corners = _get_body_hitbox_corners(character)
	if corners.size() < 4:
		return

	# Draw filled polygon
	var polygon = PackedVector2Array(corners)
	draw_colored_polygon(polygon, body_hitbox_color)

	# Draw outline
	for i in range(corners.size()):
		var start = corners[i]
		var end = corners[(i + 1) % corners.size()]
		draw_line(start, end, body_outline_color, line_width)

func _draw_limb_zones(character) -> void:
	"""Draw the zones used for limb detection"""
	var body_width = character.body_width
	var body_height = character.body_height
	var head_length = character.head_length
	var shoulder_y = character.shoulder_y_offset
	var leg_length = character.leg_length

	var top = -head_length * 0.35
	var bottom = shoulder_y + leg_length
	var half_width = body_width / 2

	# Head zone: y < -body_height * 0.3 and abs(x) < body_width * 0.3
	var head_threshold_y = -body_height * 0.3
	var head_half_width = body_width * 0.3
	var head_corners_local = [
		Vector2(-head_half_width, top),
		Vector2(head_half_width, top),
		Vector2(head_half_width, head_threshold_y),
		Vector2(-head_half_width, head_threshold_y)
	]
	_draw_zone(character, head_corners_local, head_zone_color, "HEAD")

	# Left arm zone: x < -body_width * 0.35
	var arm_threshold_x = body_width * 0.35
	var left_arm_corners_local = [
		Vector2(-half_width, top),
		Vector2(-arm_threshold_x, top),
		Vector2(-arm_threshold_x, bottom),
		Vector2(-half_width, bottom)
	]
	_draw_zone(character, left_arm_corners_local, arm_zone_color, "L_ARM")

	# Right arm zone: x > body_width * 0.35
	var right_arm_corners_local = [
		Vector2(arm_threshold_x, top),
		Vector2(half_width, top),
		Vector2(half_width, bottom),
		Vector2(arm_threshold_x, bottom)
	]
	_draw_zone(character, right_arm_corners_local, arm_zone_color, "R_ARM")

	# Leg zone: y > body_height * 0.2
	var leg_threshold_y = body_height * 0.2

	# Left leg zone
	var left_leg_corners_local = [
		Vector2(-arm_threshold_x, leg_threshold_y),
		Vector2(0, leg_threshold_y),
		Vector2(0, bottom),
		Vector2(-arm_threshold_x, bottom)
	]
	_draw_zone(character, left_leg_corners_local, leg_zone_color, "L_LEG")

	# Right leg zone
	var right_leg_corners_local = [
		Vector2(0, leg_threshold_y),
		Vector2(arm_threshold_x, leg_threshold_y),
		Vector2(arm_threshold_x, bottom),
		Vector2(0, bottom)
	]
	_draw_zone(character, right_leg_corners_local, leg_zone_color, "R_LEG")

	# Torso zone: center area not covered by other zones
	var torso_corners_local = [
		Vector2(-arm_threshold_x, head_threshold_y),
		Vector2(arm_threshold_x, head_threshold_y),
		Vector2(arm_threshold_x, leg_threshold_y),
		Vector2(-arm_threshold_x, leg_threshold_y)
	]
	_draw_zone(character, torso_corners_local, torso_zone_color, "TORSO")

func _draw_zone(character, local_corners: Array, color: Color, _label: String) -> void:
	"""Draw a zone with transformation applied"""
	var world_corners = []
	for corner in local_corners:
		world_corners.append(character.global_position + corner.rotated(character.rotation))

	# Draw filled polygon
	var polygon = PackedVector2Array(world_corners)
	draw_colored_polygon(polygon, color)

	# Draw outline
	var outline_color = Color(color.r, color.g, color.b, 0.8)
	for i in range(world_corners.size()):
		var start = world_corners[i]
		var end = world_corners[(i + 1) % world_corners.size()]
		draw_line(start, end, outline_color, line_width * 0.5)

	# Draw label at center
	var center = Vector2.ZERO
	for corner in world_corners:
		center += corner
	center /= world_corners.size()

	# Draw a small marker at center
	draw_circle(center, 3.0, outline_color)

func _draw_weapon_hit_line(character) -> void:
	"""Draw the weapon/fist hit line used for collision checks"""
	var hit_start_world: Vector2
	var hit_end_world: Vector2
	var is_weapon: bool = false

	# Check current hand's weapon
	var current_weapon = null
	if character.current_hand == "Main":
		current_weapon = character.current_main_hand_item
	else:
		current_weapon = character.current_off_hand_item

	if current_weapon != null and current_weapon.has_method("get_tip_local_position"):
		# Weapon logic -- use to_global on the weapon node to chain through holder transform
		is_weapon = true
		var tip = current_weapon.get_tip_local_position()
		var base = current_weapon.get_blade_start_local()
		hit_end_world = current_weapon.to_global(tip)
		hit_start_world = current_weapon.to_global(base)
	else:
		# Fist logic -- arm joints are in character-local space
		var joints: Array
		if character.current_hand == "Main":
			joints = character.right_arm_joints
		else:
			joints = character.left_arm_joints

		if joints.is_empty() or joints.size() < 2:
			return

		var hand_local = joints[-1]
		var elbow_local = joints[-2]
		hit_end_world = character.to_global(hand_local)
		hit_start_world = character.to_global(hand_local.lerp(elbow_local, 0.2))

	# Draw the hit line
	var color = weapon_line_color if is_weapon else fist_line_color
	draw_line(hit_start_world, hit_end_world, color, line_width * 2)

	# Draw interpolation check points
	var num_checks = 5
	for i in range(num_checks):
		var t = float(i) / float(num_checks - 1)
		var check_point = hit_end_world.lerp(hit_start_world, t)
		draw_circle(check_point, 4.0, color)

	# Draw markers at start and end
	draw_circle(hit_start_world, 6.0, Color(0.0, 1.0, 0.0, 0.9))  # Green = base/start
	draw_circle(hit_end_world, 6.0, Color(1.0, 0.0, 0.0, 0.9))    # Red = tip/end

func _draw_arm_joints(character) -> void:
	"""Draw the arm joint positions"""
	# Left arm
	if character.left_arm_joints.size() > 0:
		_draw_joint_chain(character, character.left_arm_joints, Color(0.2, 0.8, 0.2, 0.7))

	# Right arm
	if character.right_arm_joints.size() > 0:
		_draw_joint_chain(character, character.right_arm_joints, Color(0.8, 0.2, 0.2, 0.7))

func _draw_joint_chain(character, joints: Array, color: Color) -> void:
	"""Draw a chain of joints"""
	if joints.size() < 2:
		return

	for i in range(joints.size() - 1):
		var start = character.to_global(joints[i])
		var end = character.to_global(joints[i + 1])
		draw_line(start, end, color, line_width)
		draw_circle(start, 4.0, color)

	# Draw last joint
	var last_joint = character.to_global(joints[-1])
	draw_circle(last_joint, 5.0, color)

func _get_body_hitbox_corners(character) -> Array:
	"""Get character's body hitbox as 4 world-space corners"""
	var half_width = character.body_width / 2
	var top = -character.head_length * 0.35
	var bottom = character.shoulder_y_offset + character.leg_length

	var local_corners = [
		Vector2(-half_width, top),
		Vector2(half_width, top),
		Vector2(half_width, bottom),
		Vector2(-half_width, bottom)
	]

	var world_corners = []
	for corner in local_corners:
		world_corners.append(character.global_position + corner.rotated(character.rotation))

	return world_corners

# ===== STRUCTURE COLLISION VISUALIZATION =====

func _draw_structures() -> void:
	"""Draw structure RectangleShape2D colliders so you can see what's solid."""
	var structures := get_tree().get_nodes_in_group("structures")
	for s in structures:
		if s == null or not is_instance_valid(s):
			continue
		var shape_node: Node = s.get("collision_shape")
		if shape_node == null:
			# Fallback: search for a CollisionShape2D child.
			for child in s.get_children():
				if child is CollisionShape2D:
					shape_node = child
					break
		if shape_node == null or not (shape_node is CollisionShape2D):
			continue
		var shape = shape_node.shape
		if shape == null:
			continue

		var corners: Array = []
		if shape is RectangleShape2D:
			var half_size: Vector2 = shape.size * 0.5
			var local_corners := [
				Vector2(-half_size.x, -half_size.y),
				Vector2(half_size.x, -half_size.y),
				Vector2(half_size.x, half_size.y),
				Vector2(-half_size.x, half_size.y),
			]
			var xform: Transform2D = s.global_transform * shape_node.transform
			for c in local_corners:
				corners.append(xform * c)
		else:
			# Other shape types not yet supported — skip silently.
			continue

		var poly := PackedVector2Array(corners)
		draw_colored_polygon(poly, structure_color)
		for i in range(corners.size()):
			var start: Vector2 = corners[i]
			var end: Vector2 = corners[(i + 1) % corners.size()]
			draw_line(start, end, structure_outline_color, line_width)

# ===== WEAPON-HIT INDICATOR =====

func record_hit(pos: Vector2, limb_name: String, penetrated: bool, damage: float) -> void:
	"""Record a weapon-hit event so it shows as a fading marker on screen."""
	recent_hits.append({
		"position": pos,
		"time_left": HIT_MARKER_LIFETIME,
		"limb_name": String(limb_name),
		"penetrated": penetrated,
		"damage": damage,
	})
	# Drop oldest entries beyond cap
	while recent_hits.size() > MAX_RECENT_HITS:
		recent_hits.pop_front()
	queue_redraw()

func _draw_hit_markers() -> void:
	for hit in recent_hits:
		var lifetime_t: float = clamp(hit.time_left / HIT_MARKER_LIFETIME, 0.0, 1.0)
		# Radius scales with damage; pulses larger right after impact and fades down.
		var radius: float = 6.0 + clamp(hit.damage, 0.0, 50.0) * 0.4
		radius *= lerp(0.6, 1.4, lifetime_t)

		var base_color: Color = hit_marker_penetrated_color if hit.penetrated else hit_marker_bounced_color
		var fill := Color(base_color.r, base_color.g, base_color.b, 0.35 * lifetime_t)
		var outline := Color(base_color.r, base_color.g, base_color.b, lifetime_t)

		draw_circle(hit.position, radius, fill)
		# Outline ring (Godot 4: emulate with two slightly different radii)
		draw_arc(hit.position, radius, 0.0, TAU, 24, outline, max(line_width, 2.0))

		# Tiny limb-name + damage label above the marker.
		if _hit_marker_font:
			var label := "%s  %s" % [String(hit.limb_name), str(int(round(hit.damage)))]
			var label_pos: Vector2 = hit.position + Vector2(-radius - 4.0, -radius - 6.0)
			draw_string(_hit_marker_font, label_pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, outline)

# Toggle functions for runtime control (kept for backwards compatibility)
func toggle_all() -> void:
	DebugManager.toggle()

func toggle_body_hitbox() -> void:
	show_body_hitbox = not show_body_hitbox

func toggle_limb_zones() -> void:
	show_limb_zones = not show_limb_zones

func toggle_weapon_line() -> void:
	show_weapon_line = not show_weapon_line

func toggle_arm_reach() -> void:
	show_arm_reach = not show_arm_reach

func toggle_structure_hitboxes() -> void:
	show_structure_hitboxes = not show_structure_hitboxes

func toggle_hit_markers() -> void:
	show_hit_markers = not show_hit_markers
