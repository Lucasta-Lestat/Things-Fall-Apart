# ProceduralCharacterBody.gd
extends Node2D
class_name ProceduralCharacterBody

# Body part references
@onready var torso: RigidBody2D = $Torso
@onready var head: RigidBody2D = $Torso/Head
@onready var left_upper_arm: RigidBody2D = $Torso/LeftUpperArm
@onready var left_lower_arm: RigidBody2D = $Torso/LeftUpperArm/LeftLowerArm
@onready var right_upper_arm: RigidBody2D = $Torso/RightUpperArm
@onready var right_lower_arm: RigidBody2D = $Torso/RightUpperArm/RightLowerArm
@onready var left_upper_leg: RigidBody2D = $Torso/LeftUpperLeg
@onready var left_lower_leg: RigidBody2D = $Torso/LeftUpperLeg/LeftLowerLeg
@onready var right_upper_leg: RigidBody2D = $Torso/RightUpperLeg
@onready var right_lower_leg: RigidBody2D = $Torso/RightUpperLeg/RightLowerLeg

# IK chains
@onready var left_arm_ik: Skeleton2D = $Torso/LeftArmIK
@onready var right_arm_ik: Skeleton2D = $Torso/RightArmIK

# Visual customization
@export var skin_color: Color = Color(0.9, 0.75, 0.6)
@export var hair_color: Color = Color(0.2, 0.1, 0.05)
@export var clothing_color: Color = Color(0.3, 0.3, 0.5)
@export var body_scale: float = 1.0

# Animation layers
var locomotion_phase: float = 0.0
var walk_speed: float = 0.0
var aim_direction: Vector2 = Vector2.RIGHT
var is_aiming: bool = false
var is_performing_action: bool = false

# Equipment
var equipped_weapon: PhysicsWeapon = null
var weapon_motor: WeaponMotor = null

# Physics parameters
@export var limb_damping: float = 0.8
@export var joint_stiffness: float = 1000.0

signal body_part_hit(part_name, impact_point, damage)

func _ready():
	_setup_body_structure()
	_setup_ik_chains()
	_apply_visual_customization()
	
	weapon_motor = WeaponMotor.new()
	add_child(weapon_motor)

func _setup_body_structure():
	# Create the hierarchical body structure
	_create_torso()
	_create_head()
	_create_arms()
	_create_legs()
	_connect_joints()

func _create_torso():
	if not torso:
		torso = RigidBody2D.new()
		torso.name = "Torso"
		add_child(torso)
	
	# Create torso shape
	var shape = CapsuleShape2D.new()
	shape.radius = 12 * body_scale
	shape.height = 30 * body_scale
	
	var collision = CollisionShape2D.new()
	collision.shape = shape
	torso.add_child(collision)
	
	# Create visual representation
	var visual = Polygon2D.new()
	visual.polygon = _generate_torso_polygon()
	visual.color = clothing_color
	torso.add_child(visual)
	
	# Set physics properties
	torso.mass = 30.0 * body_scale
	torso.linear_damp = limb_damping
	torso.angular_damp = limb_damping

func _create_head():
	if not head:
		head = RigidBody2D.new()
		head.name = "Head"
		torso.add_child(head)
	
	head.position = Vector2(0, -20 * body_scale)
	
	# Create head shape
	var shape = CircleShape2D.new()
	shape.radius = 8 * body_scale
	
	var collision = CollisionShape2D.new()
	collision.shape = shape
	head.add_child(collision)
	
	# Visual representation with layers for customization
	var head_visual = Node2D.new()
	head.add_child(head_visual)
	
	# Base head
	var base = Polygon2D.new()
	base.polygon = _generate_head_polygon()
	base.color = skin_color
	head_visual.add_child(base)
	
	# Hair overlay
	var hair = Polygon2D.new()
	hair.polygon = _generate_hair_polygon()
	hair.color = hair_color
	hair.z_index = 1
	head_visual.add_child(hair)
	
	head.mass = 5.0 * body_scale

func _create_arms():
	# Left arm
	_create_arm_segment(left_upper_arm, "LeftUpperArm", Vector2(-15 * body_scale, -10 * body_scale), true)
	_create_arm_segment(left_lower_arm, "LeftLowerArm", Vector2(0, 12 * body_scale), false, left_upper_arm)
	
	# Right arm
	_create_arm_segment(right_upper_arm, "RightUpperArm", Vector2(15 * body_scale, -10 * body_scale), true)
	_create_arm_segment(right_lower_arm, "RightLowerArm", Vector2(0, 12 * body_scale), false, right_upper_arm)

func _create_arm_segment(segment: RigidBody2D, segment_name: String, pos: Vector2, is_upper: bool, parent: Node2D = null):
	if not segment:
		segment = RigidBody2D.new()
		segment.name = segment_name
		
		if parent:
			parent.add_child(segment)
		else:
			torso.add_child(segment)
	
	segment.position = pos
	
	# Create shape
	var shape = CapsuleShape2D.new()
	shape.radius = 4 * body_scale if is_upper else 3 * body_scale
	shape.height = 12 * body_scale
	
	var collision = CollisionShape2D.new()
	collision.shape = shape
	collision.rotation = PI/2  # Horizontal orientation
	segment.add_child(collision)
	
	# Visual
	var visual = Polygon2D.new()
	visual.polygon = _generate_limb_polygon(shape.radius * 2, shape.height)
	visual.color = skin_color if not is_upper else clothing_color
	segment.add_child(visual)
	
	segment.mass = 3.0 * body_scale if is_upper else 2.0 * body_scale
	segment.linear_damp = limb_damping
	segment.angular_damp = limb_damping

func _create_legs():
	# Left leg
	_create_leg_segment(left_upper_leg, "LeftUpperLeg", Vector2(-6 * body_scale, 15 * body_scale), true)
	_create_leg_segment(left_lower_leg, "LeftLowerLeg", Vector2(0, 15 * body_scale), false, left_upper_leg)
	
	# Right leg
	_create_leg_segment(right_upper_leg, "RightUpperLeg", Vector2(6 * body_scale, 15 * body_scale), true)
	_create_leg_segment(right_lower_leg, "RightLowerLeg", Vector2(0, 15 * body_scale), false, right_upper_leg)

func _create_leg_segment(segment: RigidBody2D, segment_name: String, pos: Vector2, is_upper: bool, parent: Node2D = null):
	if not segment:
		segment = RigidBody2D.new()
		segment.name = segment_name
		
		if parent:
			parent.add_child(segment)
		else:
			torso.add_child(segment)
	
	segment.position = pos
	
	# Create shape
	var shape = CapsuleShape2D.new()
	shape.radius = 5 * body_scale if is_upper else 4 * body_scale
	shape.height = 15 * body_scale
	
	var collision = CollisionShape2D.new()
	collision.shape = shape
	segment.add_child(collision)
	
	# Visual
	var visual = Polygon2D.new()
	visual.polygon = _generate_limb_polygon(shape.radius * 2, shape.height)
	visual.color = clothing_color if is_upper else skin_color
	segment.add_child(visual)
	
	segment.mass = 5.0 * body_scale if is_upper else 3.0 * body_scale

func _connect_joints():
	# Head to torso
	_create_joint(torso, head, Vector2(0, -15 * body_scale), Vector2(0, 5 * body_scale))
	
	# Arms to torso
	_create_joint(torso, left_upper_arm, Vector2(-10 * body_scale, -10 * body_scale), Vector2(0, 0))
	_create_joint(left_upper_arm, left_lower_arm, Vector2(0, 10 * body_scale), Vector2(0, -5 * body_scale))
	
	_create_joint(torso, right_upper_arm, Vector2(10 * body_scale, -10 * body_scale), Vector2(0, 0))
	_create_joint(right_upper_arm, right_lower_arm, Vector2(0, 10 * body_scale), Vector2(0, -5 * body_scale))
	
	# Legs to torso
	_create_joint(torso, left_upper_leg, Vector2(-5 * body_scale, 12 * body_scale), Vector2(0, -6 * body_scale))
	_create_joint(left_upper_leg, left_lower_leg, Vector2(0, 12 * body_scale), Vector2(0, -6 * body_scale))
	
	_create_joint(torso, right_upper_leg, Vector2(5 * body_scale, 12 * body_scale), Vector2(0, -6 * body_scale))
	_create_joint(right_upper_leg, right_lower_leg, Vector2(0, 12 * body_scale), Vector2(0, -6 * body_scale))

func _create_joint(body_a: RigidBody2D, body_b: RigidBody2D, anchor_a: Vector2, anchor_b: Vector2):
	
	var joint = PinJoint2D.new()
	joint.node_a = body_a.get_path()
	joint.node_b = body_b.get_path()
	joint.position = body_a.position + anchor_a
	add_child(joint)

func _setup_ik_chains():
	# Setup IK for arms (simplified - in practice you'd use Skeleton2D)
	pass

func _generate_torso_polygon() -> PackedVector2Array:
	var points = PackedVector2Array()
	var width = 24 * body_scale
	var height = 30 * body_scale
	
	points.append(Vector2(-width/2, -height/2))
	points.append(Vector2(-width/3, -height/2))
	points.append(Vector2(width/3, -height/2))
	points.append(Vector2(width/2, -height/2))
	points.append(Vector2(width/2, height/2))
	points.append(Vector2(-width/2, height/2))
	
	return points

func _generate_head_polygon() -> PackedVector2Array:
	var points = PackedVector2Array()
	var radius = 8 * body_scale
	
	for i in range(16):
		var angle = (i / 16.0) * TAU
		points.append(Vector2(cos(angle), sin(angle)) * radius)
	
	return points

func _generate_hair_polygon() -> PackedVector2Array:
	var points = PackedVector2Array()
	var radius = 8 * body_scale
	
	# Simple hair shape on top of head
	points.append(Vector2(-radius, -radius * 0.3))
	points.append(Vector2(-radius * 0.8, -radius))
	points.append(Vector2(0, -radius * 1.2))
	points.append(Vector2(radius * 0.8, -radius))
	points.append(Vector2(radius, -radius * 0.3))
	
	return points

func _generate_limb_polygon(width: float, height: float) -> PackedVector2Array:
	var points = PackedVector2Array()
	
	points.append(Vector2(-height/2, -width/2))
	points.append(Vector2(height/2, -width/2))
	points.append(Vector2(height/2, width/2))
	points.append(Vector2(-height/2, width/2))
	
	return points

func _apply_visual_customization():
	# Apply colors to all body parts
	pass

func update_locomotion(velocity: Vector2, delta: float):
	if velocity.length() > 0:
		walk_speed = velocity.length()
		locomotion_phase += walk_speed * delta * 0.01
		
		# Apply walk cycle to legs
		var leg_swing = sin(locomotion_phase) * 0.3
		var opposite_swing = -leg_swing
		
		# Apply forces to create walking motion
		left_upper_leg.apply_torque(leg_swing * joint_stiffness)
		right_upper_leg.apply_torque(opposite_swing * joint_stiffness)
		
		# Body sway
		torso.apply_torque(sin(locomotion_phase * 2) * 0.1 * joint_stiffness)
	else:
		walk_speed = 0

func update_aiming(target_position: Vector2):
	aim_direction = (target_position - global_position).normalized()
	is_aiming = true
	
	# Rotate upper body toward aim direction
	var target_angle = aim_direction.angle()
	
	# Apply torque to torso to face direction
	var current_angle = torso.rotation
	var angle_diff = angle_difference(current_angle, target_angle)
	torso.apply_torque(angle_diff * joint_stiffness * 0.5)
	
	# Point arms toward target using IK
	if equipped_weapon:
		_update_arm_ik(target_position)

func _update_arm_ik(target: Vector2):
	# Simplified IK - in practice, use Godot's built-in IK system
	var local_target = torso.to_local(target)
	
	# Calculate angles for arm segments to reach target
	var shoulder_to_target = local_target - right_upper_arm.position
	var upper_arm_length = 12 * body_scale
	var lower_arm_length = 12 * body_scale
	
	# Two-bone IK solution
	var distance = shoulder_to_target.length()
	if distance < upper_arm_length + lower_arm_length:
		# Apply forces to move arms toward target
		right_upper_arm.apply_force(shoulder_to_target.normalized() * joint_stiffness, Vector2.ZERO)

func equip_weapon(weapon: PhysicsWeapon):
	if equipped_weapon:
		equipped_weapon.queue_free()
	
	equipped_weapon = weapon
	right_lower_arm.add_child(weapon)
	weapon.position = Vector2(10 * body_scale, 0)  # Position in hand
	
	# Connect weapon to hand with joint
	var joint = PinJoint2D.new()
	joint.node_a = right_lower_arm.get_path()
	joint.node_b = weapon.get_path()
	right_lower_arm.add_child(joint)

func perform_attack(attack_type: String, target: Vector2):
	if not equipped_weapon or is_performing_action:
		return
	
	is_performing_action = true
	
	match attack_type:
		"thrust":
			_perform_thrust(target)
		"slash":
			_perform_slash(target)
		"shoot":
			_perform_shoot(target)

func _perform_thrust(target: Vector2):
	var path = [equipped_weapon.global_position, target]
	weapon_motor.execute_attack(equipped_weapon, path, "thrust", get_parent().stats.strength)

func _perform_slash(target: Vector2):
	# Calculate arc path
	var start = equipped_weapon.global_position
	var center = global_position
	var radius = start.distance_to(center)
	
	var path = []
	var start_angle = (start - center).angle()
	var end_angle = (target - center).angle()
	
	for i in range(10):
		var t = i / 9.0
		var angle = lerp(start_angle, end_angle, t)
		var point = center + Vector2.from_angle(angle) * radius
		path.append(point)
	
	weapon_motor.execute_attack(equipped_weapon, path, "slash", get_parent().stats.strength)

func _perform_shoot(target: Vector2):
	# Trigger pulling animation
	# This would be more complex with actual finger bones
	is_performing_action = false

func get_body_part_at_position(pos: Vector2) -> String:
	# Check which body part contains the position
	var parts = {
		"head": head,
		"torso": torso,
		"left_upper_arm": left_upper_arm,
		"left_lower_arm": left_lower_arm,
		"right_upper_arm": right_upper_arm,
		"right_lower_arm": right_lower_arm,
		"left_upper_leg": left_upper_leg,
		"left_lower_leg": left_lower_leg,
		"right_upper_leg": right_upper_leg,
		"right_lower_leg": right_lower_leg
	}
	
	for part_name in parts:
		var part = parts[part_name]
		if part and part.has_method("get_global_transform"):
			var local_pos = part.to_local(pos)
			# Check if position is within part's collision shape
			# Simplified check - in practice, use actual collision detection
			if local_pos.length() < 20 * body_scale:
				return part_name
	
	return "torso"  # Default
