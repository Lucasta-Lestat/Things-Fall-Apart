# PhysicsCharacterBody.gd
extends RigidBody2D
class_name PhysicsCharacterBody

# True top-down physics-based character for Door Kickers style game

# Movement physics
@export var base_movement_force: float = 1000.0  # Newtons
@export var max_velocity: float = 300.0  # pixels/second
@export var friction_coefficient: float = 10.0  # Ground friction

# Character stats that affect physics
var movement_stat: float = 100.0  # 0-200, affects max force when moving
var strength: float = 100.0 # affects max for when througing
var weight: float = 70.0  # kg, affects inertia

# Visual components (top-down view)
@onready var skeleton: Skeleton2D = $Skeleton2D
@onready var body_polygon: Polygon2D = $Skeleton2D/BodyBone/BodyPolygon
@onready var left_arm_polygon: Polygon2D = $Skeleton2D/LeftArmBone/LeftArmPolygon
@onready var right_arm_polygon: Polygon2D = $Skeleton2D/RightArmBone/RightArmPolygon
@onready var weapon_holder: Bone2D = $Skeleton2D/RightArmBone/WeaponHolder

# Movement control
var movement_input: Vector2 = Vector2.ZERO
var facing_direction: float = 0.0  # Radians
var is_moving: bool = false

# Combat
var equipped_weapon: PhysicsWeapon = null
var aim_target: Vector2 = Vector2.ZERO
var is_aiming: bool = false

# Animation
var walk_cycle_time: float = 0.0
var arm_swing_amplitude: float = 0.2  # Radians

# Visual customization
@export var skin_color: Color = Color(0.9, 0.75, 0.6)
@export var clothing_color: Color = Color(0.3, 0.3, 0.5)
@export var body_radius: float = 12.0

signal force_applied(force_vector)
signal external_force_received(force_vector, source)

func _ready():
	# Configure as physics body
	_setup_physics()
	_create_skeleton()
	_create_visuals()
	_setup_collision()
	
	set_physics_process(true)

func _setup_physics():
	# Character is a physics object
	mass = weight
	gravity_scale = 0.0  # Top-down, no gravity
	linear_damp = friction_coefficient
	angular_damp = 5.0  # Rotation damping
	
	# Lock rotation if we want character to only rotate deliberately
	lock_rotation = true
	
	# Set up collision layers
	collision_layer = 0b0100  # Character layer
	collision_mask = 0b1011  # Collide with walls, cover, other characters

func _create_skeleton():
	if not skeleton:
		skeleton = Skeleton2D.new()
		skeleton.name = "Skeleton2D"
		add_child(skeleton)
	
	# Create bones for top-down view
	# Body (torso) is the root
	var body_bone = Bone2D.new()
	body_bone.name = "BodyBone"
	body_bone.rest = Transform2D.IDENTITY
	skeleton.add_child(body_bone)
	
	# Left arm attached to body
	var left_arm_bone = Bone2D.new()
	left_arm_bone.name = "LeftArmBone"
	left_arm_bone.position = Vector2(-body_radius * 0.8, 0)
	left_arm_bone.rest = Transform2D.IDENTITY
	body_bone.add_child(left_arm_bone)
	
	# Right arm attached to body
	var right_arm_bone = Bone2D.new()
	right_arm_bone.name = "RightArmBone"
	right_arm_bone.position = Vector2(body_radius * 0.8, 0)
	right_arm_bone.rest = Transform2D.IDENTITY
	body_bone.add_child(right_arm_bone)
	
	# Weapon attachment point on right arm
	var weapon_holder = Bone2D.new()
	weapon_holder.name = "WeaponHolder"
	weapon_holder.position = Vector2(body_radius * 0.7, 0)
	right_arm_bone.add_child(weapon_holder)
	
	# Create skeleton modification stack
	skeleton.set_modification_stack(SkeletonModificationStack2D.new())

func _create_visuals():
	# Body circle (viewed from top)
	if not body_polygon:
		body_polygon = Polygon2D.new()
		body_polygon.name = "BodyPolygon"
		var body_bone = skeleton.get_node("BodyBone")
		body_bone.add_child(body_polygon)
	
	# Generate circle polygon for body
	var body_points = PackedVector2Array()
	for i in range(16):
		var angle = (i / 16.0) * TAU
		body_points.append(Vector2(cos(angle), sin(angle)) * body_radius)
	body_polygon.polygon = body_points
	body_polygon.color = clothing_color
	
	# Add a small directional indicator (nose/front)
	var direction_indicator = Polygon2D.new()
	direction_indicator.polygon = PackedVector2Array([
		Vector2(body_radius * 0.8, -3),
		Vector2(body_radius + 4, 0),
		Vector2(body_radius * 0.8, 3)
	])
	direction_indicator.color = skin_color
	body_polygon.add_child(direction_indicator)
	
	# Left arm (simplified rectangle from top view)
	if not left_arm_polygon:
		left_arm_polygon = Polygon2D.new()
		left_arm_polygon.name = "LeftArmPolygon"
		var left_arm_bone = skeleton.get_node("BodyBone/LeftArmBone")
		left_arm_bone.add_child(left_arm_polygon)
	
	left_arm_polygon.polygon = PackedVector2Array([
		Vector2(0, -3),
		Vector2(body_radius * 0.8, -3),
		Vector2(body_radius * 0.8, 3),
		Vector2(0, 3)
	])
	left_arm_polygon.color = skin_color
	
	# Right arm
	if not right_arm_polygon:
		right_arm_polygon = Polygon2D.new()
		right_arm_polygon.name = "RightArmPolygon"
		var right_arm_bone = skeleton.get_node("BodyBone/RightArmBone")
		right_arm_bone.add_child(right_arm_polygon)
	
	right_arm_polygon.polygon = PackedVector2Array([
		Vector2(0, -3),
		Vector2(body_radius * 0.8, -3),
		Vector2(body_radius * 0.8, 3),
		Vector2(0, 3)
	])
	right_arm_polygon.color = skin_color

func _setup_collision():
	# Main body collision
	var collision_shape = CollisionShape2D.new()
	var circle_shape = CircleShape2D.new()
	circle_shape.radius = body_radius
	collision_shape.shape = circle_shape
	add_child(collision_shape)

func _physics_process(delta):
	# Apply movement forces
	_apply_movement_forces(delta)
	
	# Apply friction
	_apply_friction(delta)
	
	# Clamp velocity
	if linear_velocity.length() > max_velocity:
		linear_velocity = linear_velocity.normalized() * max_velocity
	
	# Update animations
	_update_animations(delta)
	
	# Update facing direction based on velocity or aim
	_update_facing_direction()

func _apply_movement_forces(delta):
	if movement_input.length() > 0:
		# Calculate force based on Movement stat
		var force_magnitude = base_movement_force * (movement_stat / 100.0)
		var force = movement_input.normalized() * force_magnitude
		
		# Apply the force
		apply_central_force(force)
		force_applied.emit(force)
		
		is_moving = true
	else:
		is_moving = false

func _apply_friction(delta):
	# Ground friction opposes movement
	var friction_force = -linear_velocity * friction_coefficient * mass
	apply_central_force(friction_force)

func apply_external_force(force: Vector2, source: String = "unknown"):
	# External forces like wind, explosions, magic
	apply_central_impulse(force)
	external_force_received.emit(force, source)

func apply_spell_force(force_type: String, magnitude: float, direction: Vector2):
	# Different spell effects
	match force_type:
		"push":
			apply_external_force(direction * magnitude, "spell_push")
		"pull":
			apply_external_force(-direction * magnitude, "spell_pull")
		"slow":
			# Increase friction temporarily
			friction_coefficient *= 2.0
			get_tree().create_timer(3.0).timeout.connect(func(): friction_coefficient /= 2.0)
		"levitate":
			# Reduce friction to near zero
			var old_friction = friction_coefficient
			friction_coefficient = 0.1
			get_tree().create_timer(2.0).timeout.connect(func(): friction_coefficient = old_friction)

func set_movement_input(input: Vector2):
	movement_input = input

func _update_facing_direction():
	if is_aiming and aim_target != Vector2.ZERO:
		# Face toward aim target
		var to_target = (aim_target - global_position).normalized()
		facing_direction = to_target.angle()
	elif linear_velocity.length() > 10:
		# Face movement direction
		facing_direction = linear_velocity.angle()
	
	# Rotate the visual skeleton
	skeleton.rotation = facing_direction

func _update_animations(delta):
	if is_moving:
		walk_cycle_time += delta * 5.0  # Walk cycle speed
		
		# Animate arms with walking
		var left_arm = skeleton.get_node("BodyBone/LeftArmBone")
		var right_arm = skeleton.get_node("BodyBone/RightArmBone")
		
		if left_arm and not is_aiming:
			left_arm.rotation = sin(walk_cycle_time) * arm_swing_amplitude
		
		if right_arm and not is_aiming:
			right_arm.rotation = -sin(walk_cycle_time) * arm_swing_amplitude
	else:
		walk_cycle_time = 0
		
		# Return arms to rest position
		if not is_aiming:
			var left_arm = skeleton.get_node("BodyBone/LeftArmBone")
			var right_arm = skeleton.get_node("BodyBone/RightArmBone")
			
			if left_arm:
				left_arm.rotation = lerp(left_arm.rotation, 0.0, 0.1)
			if right_arm:
				right_arm.rotation = lerp(right_arm.rotation, 0.0, 0.1)

func aim_at(target_pos: Vector2):
	aim_target = target_pos
	is_aiming = true
	
	# Point arms toward target
	var to_target = (target_pos - global_position).normalized()
	var target_angle = to_target.angle() - skeleton.rotation
	
	var left_arm = skeleton.get_node("BodyBone/LeftArmBone")
	var right_arm = skeleton.get_node("BodyBone/RightArmBone")
	
	if equipped_weapon:
		# Both arms hold weapon, point toward target
		if right_arm:
			right_arm.rotation = target_angle
		if left_arm:
			left_arm.rotation = target_angle * 0.8  # Left arm follows slightly
	else:
		# Just point right arm
		if right_arm:
			right_arm.rotation = target_angle

func stop_aiming():
	is_aiming = false
	aim_target = Vector2.ZERO

func equip_weapon(weapon: PhysicsWeapon):
	if equipped_weapon:
		equipped_weapon.queue_free()
	
	equipped_weapon = weapon
	
	var weapon_holder = skeleton.get_node("BodyBone/RightArmBone/WeaponHolder")
	if weapon_holder:
		weapon_holder.add_child(weapon)
		weapon.position = Vector2.ZERO
		weapon.rotation = 0

func perform_melee_attack(attack_type: String):
	if not equipped_weapon:
		return
	
	var right_arm = skeleton.get_node("BodyBone/RightArmBone")
	if not right_arm:
		return
	
	# Apply force to weapon based on attack type and strength
	var force_multiplier = strength / 100.0  
	
	match attack_type:
		"thrust":
			# Quick forward jab
			var thrust_force = Vector2(300 * force_multiplier, 0).rotated(facing_direction)
			equipped_weapon.apply_central_impulse(thrust_force)
		"slash":
			# Wide arc
			var slash_torque = 500 * force_multiplier
			equipped_weapon.apply_torque(slash_torque)
			
			# Animate arm sweep
			var tween = get_tree().create_tween()
			tween.tween_property(right_arm, "rotation", right_arm.rotation + PI/2, 0.2)
			tween.tween_property(right_arm, "rotation", right_arm.rotation - PI/2, 0.2)

func get_movement_force() -> float:
	return base_movement_force * (movement_stat / 100.0)

func get_current_friction() -> float:
	# Get terrain friction
	var terrain_friction = friction_coefficient
	
	# Check if on special terrain
	var pathfinding = get_node_or_null("/root/Main/PathfindingSystem")
	if pathfinding:
		var terrain = pathfinding.get_terrain(global_position)
		if terrain:
			# Ice has low friction, mud has high friction
			match terrain.type:
				PathfindingSystem.TerrainType.WATER:
					terrain_friction *= 0.5
				PathfindingSystem.TerrainType.GRAVEL:
					terrain_friction *= 1.5
	
	return terrain_friction

func update_stats(character_stats: Dictionary):
	# Update physics based on character stats
	movement_stat = character_stats.get("movement", 100.0)
	strength = character_stats.get("strength", 100.0)
	# Weight affects mass (strength affects carrying capacity but also body mass)
	weight = 70.0 + (character_stats.get("strength", 100.0) - 100.0) * 0.3
	mass = weight
