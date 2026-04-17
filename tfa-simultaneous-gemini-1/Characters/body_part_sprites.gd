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

# Quadruped support
var _is_quadruped: bool = false
var _body_length: float = 0.0  # Front-to-back length for quadrupeds

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

	# Head (image TOP = back of head toward body, BOTTOM = face toward front)
	head_sprite = _create_sprite("HeadSprite", 1)
	_load_texture(head_sprite, sprite_data.get("head", ""))

	# Torso (image TOP = back/shoulders, BOTTOM = chest front)
	torso_sprite = _create_sprite("TorsoSprite", -1)
	_load_texture(torso_sprite, sprite_data.get("torso", ""))

	# Left arm (two segments) - flipped horizontally to mirror right arm
	# so elbows bend in opposite directions
	left_upper_arm = _create_sprite("LeftUpperArm", -2)
	_load_texture(left_upper_arm, sprite_data.get("upper_arm", ""))
	left_upper_arm.flip_h = true

	left_forearm = _create_sprite("LeftForearm", -2)
	_load_texture(left_forearm, sprite_data.get("forearm", ""))
	left_forearm.flip_h = true

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
	Call after load_sprites() and after character dimensions are set.
	All character dimensions are expected to already be at final game-unit scale:
	- Body/head dims from race data are set at final scale in races.json
	- Leg dims from Globals already include default_body_scale * body_size_mod
	- Arm segment lengths already include default_body_scale * body_size_mod"""

	# Body and head: race data provides final-scale values directly
	_head_width = character.head_width
	_head_length = character.head_length
	_body_width = character.body_width
	_body_height = character.body_height
	# Quadruped: torso sprite uses body_length (front-to-back) instead of body_height
	_is_quadruped = character.body_type == 1  # BodyType.QUADRUPED
	_body_length = character.body_length if "body_length" in character else 0.0
	# Legs: Globals defaults already include * default_body_scale * body_size_mod
	_leg_width = character.leg_width
	_leg_length = character.leg_length
	# Arm thickness: raw value needs scale applied
	_arm_width = 7.0 * Globals.default_body_scale
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
	if _is_quadruped and _body_length > 0:
		# Quadruped torso is rotated 90° in update_torso(), so swap axes:
		# sprite X (becomes Y after rotation) = body_length (front-to-back)
		# sprite Y (becomes X after rotation) = body_width (left-to-right)
		_scale_sprite_to_size(torso_sprite, _body_length, _body_width)
	else:
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
	"""Position torso sprite at body center.
	Bipedal: positioned at shoulder_y_offset (horizontal body).
	Quadruped: positioned at body midpoint, rotated 90° so the sprite
	(drawn as top-down shoulders view) aligns with the elongated front-to-back body."""
	if torso_sprite:
		if _is_quadruped and _body_length > 0:
			# Quadruped body center: midpoint between front (-0.4*bl) and rear (+0.45*bl)
			var body_center_y = _body_length * 0.025  # (−0.4 + 0.45) / 2
			torso_sprite.position = Vector2(0, body_center_y)
			# Rotate 90° so the sprite's width axis aligns with the body's front-to-back axis
			torso_sprite.rotation = PI / 2
		else:
			torso_sprite.position = Vector2(0, shoulder_y_offset)
			torso_sprite.rotation = 0.0

func update_legs(left_hip: Vector2, left_foot: Vector2, right_hip: Vector2, right_foot: Vector2) -> void:
	"""Position and rotate leg sprites to match walking animation.
	-PI/2 so the wider hip end of the sprite points toward the hip joint."""
	if left_leg_sprite:
		var left_mid = (left_hip + left_foot) * 0.5
		var left_dir = (left_foot - left_hip).normalized()
		var left_angle = left_dir.angle() - PI / 2
		left_leg_sprite.position = left_mid
		left_leg_sprite.rotation = left_angle

	if right_leg_sprite:
		var right_mid = (right_hip + right_foot) * 0.5
		var right_dir = (right_foot - right_hip).normalized()
		var right_angle = right_dir.angle() - PI / 2
		right_leg_sprite.position = right_mid
		right_leg_sprite.rotation = right_angle

func update_arms(left_joints: Array[Vector2], right_joints: Array[Vector2]) -> void:
	"""Position and rotate arm segment sprites to match IK joint positions.
	joints[0] = shoulder, joints[1] = elbow, joints[2] = wrist, joints[3] = hand
	Each segment maps directly to its joint pair — no extensions or bias offsets."""

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
	var angle = dir.angle() - PI / 2  # -PI/2 so wider end points toward start_pos (shoulder/elbow)

	sprite.position = mid
	sprite.rotation = angle

	# Dynamically scale length to match actual joint distance, with a small
	# 8% overlap beyond the segment so upper-arm and forearm sprites meet
	# cleanly at the elbow instead of leaving a visible seam.
	if sprite.texture:
		var tex_size = sprite.texture.get_size()
		var segment_length = start_pos.distance_to(end_pos)
		if tex_size.y > 0:
			sprite.scale.y = (segment_length * 1.08) / tex_size.y

# ===== COLOR =====

func set_skin_color(color: Color) -> void:
	"""Tint all body part sprites to match character skin color.
	All sprites are bare skin — clothing comes from the equipment system."""
	for child in get_children():
		if child is Sprite2D:
			child.modulate = color

# ===== VISIBILITY =====

func set_all_visible(enabled: bool) -> void:
	"""Show or hide all body part sprites."""
	for child in get_children():
		if child is Sprite2D:
			child.visible = enabled
