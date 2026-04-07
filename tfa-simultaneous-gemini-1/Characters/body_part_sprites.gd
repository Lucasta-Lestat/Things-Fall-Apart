# body_part_sprites.gd
# Manages sprite overlays for character body parts (head, torso, arms, legs).
# Sprites are positioned by the procedural animation system each frame,
# replacing the Line2D geometry visually while keeping animation-driven positioning.
extends Node2D
class_name BodyPartSprites

# --- Sprite nodes (created in _setup_sprites) ---
var head_sprite: Sprite2D = null
var torso_sprite: Sprite2D = null

# Arms: two segments each to capture elbow bending from IK
var left_upper_arm: Sprite2D = null
var left_forearm: Sprite2D = null
var right_upper_arm: Sprite2D = null
var right_forearm: Sprite2D = null

# Legs: one sprite each (same pattern as EquipmentShape pants)
var left_leg_sprite: Sprite2D = null
var right_leg_sprite: Sprite2D = null

# --- Loaded texture paths ---
var sprite_data: Dictionary = {}

# --- Target dimensions from character (set by auto_scale_sprites) ---
var _head_width: float = 11.0
var _head_length: float = 10.0
var _body_width: float = 14.0
var _body_height: float = 12.0
var _leg_width: float = 3.0
var _leg_length: float = 8.0
var _arm_segment_lengths: Array[float] = [12.0, 10.0, 6.0]
var _arm_width: float = 7.0

# ===== SETUP =====

func _ready() -> void:
	# Sprites are set up via load_sprites() after being added to scene
	pass

func load_sprites(data: Dictionary) -> void:
	"""Load sprite textures from a dictionary of paths.
	Expected keys: head, torso, upper_arm, forearm, leg"""
	sprite_data = data
	_setup_sprites()

func _setup_sprites() -> void:
	"""Create all Sprite2D nodes and load textures."""
	# Clean up any existing sprites
	_clear_sprites()

	# Head
	head_sprite = _create_sprite("HeadSprite", 1)
	_load_texture(head_sprite, sprite_data.get("head", ""))

	# Torso
	torso_sprite = _create_sprite("TorsoSprite", -1)
	_load_texture(torso_sprite, sprite_data.get("torso", ""))

	# Left arm (two segments)
	left_upper_arm = _create_sprite("LeftUpperArm", -2)
	_load_texture(left_upper_arm, sprite_data.get("upper_arm", ""))

	left_forearm = _create_sprite("LeftForearm", -2)
	_load_texture(left_forearm, sprite_data.get("forearm", ""))

	# Right arm (two segments)
	right_upper_arm = _create_sprite("RightUpperArm", -2)
	_load_texture(right_upper_arm, sprite_data.get("upper_arm", ""))

	right_forearm = _create_sprite("RightForearm", -2)
	_load_texture(right_forearm, sprite_data.get("forearm", ""))

	# Legs
	left_leg_sprite = _create_sprite("LeftLegSprite", -3)
	_load_texture(left_leg_sprite, sprite_data.get("leg", ""))

	right_leg_sprite = _create_sprite("RightLegSprite", -3)
	_load_texture(right_leg_sprite, sprite_data.get("leg", ""))

func _create_sprite(sprite_name: String, z: int) -> Sprite2D:
	var sprite = Sprite2D.new()
	sprite.name = sprite_name
	sprite.z_index = z
	add_child(sprite)
	return sprite

func _load_texture(sprite: Sprite2D, path: String) -> void:
	if path and ResourceLoader.exists(path):
		sprite.texture = load(path)

func _clear_sprites() -> void:
	for child in get_children():
		if child is Sprite2D:
			remove_child(child)
			child.queue_free()
	head_sprite = null
	torso_sprite = null
	left_upper_arm = null
	left_forearm = null
	right_upper_arm = null
	right_forearm = null
	left_leg_sprite = null
	right_leg_sprite = null

# ===== SCALING =====

func auto_scale_sprites(character) -> void:
	"""Scale all sprites to match character body dimensions.
	Call after load_sprites() and after character dimensions are set."""
	_head_width = character.head_width
	_head_length = character.head_length
	_body_width = character.body_width
	_body_height = character.body_height
	_leg_width = character.leg_width
	_leg_length = character.leg_length
	_arm_width = 7.0 * Globals.default_body_scale  # Match Line2D arm width
	if "ARM_SEGMENT_LENGTHS" in character:
		var segs = character.ARM_SEGMENT_LENGTHS
		_arm_segment_lengths.clear()
		for s in segs:
			_arm_segment_lengths.append(s)
	else:
		_arm_segment_lengths.clear()
		for s in Globals.DEFAULT_ARM_SEGMENT_LENGTHS:
			_arm_segment_lengths.append(s)

	# Scale each sprite to its target dimensions
	_scale_sprite_to_size(head_sprite, _head_width, _head_length)
	_scale_sprite_to_size(torso_sprite, _body_width, _body_height)

	# Arm segments: width is arm thickness, height is segment length
	if _arm_segment_lengths.size() >= 3:
		_scale_sprite_to_size(left_upper_arm, _arm_width, _arm_segment_lengths[0])
		_scale_sprite_to_size(left_forearm, _arm_width * 0.8, _arm_segment_lengths[1] + _arm_segment_lengths[2])
		_scale_sprite_to_size(right_upper_arm, _arm_width, _arm_segment_lengths[0])
		_scale_sprite_to_size(right_forearm, _arm_width * 0.8, _arm_segment_lengths[1] + _arm_segment_lengths[2])

	# Legs: width is leg thickness, height is leg length
	_scale_sprite_to_size(left_leg_sprite, _leg_width, _leg_length)
	_scale_sprite_to_size(right_leg_sprite, _leg_width, _leg_length)

func _scale_sprite_to_size(sprite: Sprite2D, target_width: float, target_height: float) -> void:
	"""Scale a sprite so it fits the target dimensions in game units."""
	if not sprite or not sprite.texture:
		return
	var tex_size = sprite.texture.get_size()
	if tex_size.x <= 0 or tex_size.y <= 0:
		return
	sprite.scale = Vector2(target_width / tex_size.x, target_height / tex_size.y)

# ===== PER-FRAME UPDATES (called by ProceduralCharacter) =====

func update_head(head_offset: Vector2) -> void:
	"""Position head sprite at the head offset."""
	if head_sprite:
		head_sprite.position = head_offset

func update_torso(shoulder_y_offset: float) -> void:
	"""Position torso sprite at body center."""
	if torso_sprite:
		torso_sprite.position = Vector2(0, shoulder_y_offset)

func update_legs(left_hip: Vector2, left_foot: Vector2, right_hip: Vector2, right_foot: Vector2) -> void:
	"""Position and rotate leg sprites to match walking animation.
	Same pattern as EquipmentShape._update_pants_position()."""
	if left_leg_sprite:
		var left_mid = (left_hip + left_foot) * 0.5
		var left_dir = (left_foot - left_hip).normalized()
		var left_angle = left_dir.angle() + PI / 2
		left_leg_sprite.position = left_mid
		left_leg_sprite.rotation = left_angle

	if right_leg_sprite:
		var right_mid = (right_hip + right_foot) * 0.5
		var right_dir = (right_foot - right_hip).normalized()
		var right_angle = right_dir.angle() + PI / 2
		right_leg_sprite.position = right_mid
		right_leg_sprite.rotation = right_angle

func update_arms(left_joints: Array[Vector2], right_joints: Array[Vector2]) -> void:
	"""Position and rotate arm segment sprites to match IK joint positions.
	joints[0] = shoulder, joints[1] = upper arm end, joints[2] = forearm end, joints[3] = hand"""
	if left_joints.size() >= 4:
		_update_arm_segment(left_upper_arm, left_joints[0], left_joints[1])
		_update_arm_segment(left_forearm, left_joints[1], left_joints[3])

	if right_joints.size() >= 4:
		_update_arm_segment(right_upper_arm, right_joints[0], right_joints[1])
		_update_arm_segment(right_forearm, right_joints[1], right_joints[3])

func _update_arm_segment(sprite: Sprite2D, start_pos: Vector2, end_pos: Vector2) -> void:
	"""Position an arm segment sprite at the midpoint between two joints, rotated to align."""
	if not sprite:
		return
	var mid = (start_pos + end_pos) * 0.5
	var dir = (end_pos - start_pos).normalized()
	var angle = dir.angle() + PI / 2  # Rotate sprite to align along segment

	sprite.position = mid
	sprite.rotation = angle

	# Dynamically scale length to match actual joint distance
	if sprite.texture:
		var tex_size = sprite.texture.get_size()
		var segment_length = start_pos.distance_to(end_pos)
		if tex_size.y > 0:
			sprite.scale.y = segment_length / tex_size.y

# ===== COLOR =====

func set_skin_color(color: Color) -> void:
	"""Tint skin-exposed sprites (head, arms) to match character skin color.
	Torso and legs are not tinted since they show clothing."""
	if head_sprite:
		head_sprite.modulate = color
	if left_upper_arm:
		left_upper_arm.modulate = color
	if left_forearm:
		left_forearm.modulate = color
	if right_upper_arm:
		right_upper_arm.modulate = color
	if right_forearm:
		right_forearm.modulate = color
	# Legs and torso keep default modulate (they show clothing, not skin)

# ===== VISIBILITY =====

func set_all_visible(enabled: bool) -> void:
	"""Show or hide all body part sprites."""
	for child in get_children():
		if child is Sprite2D:
			child.visible = enabled
