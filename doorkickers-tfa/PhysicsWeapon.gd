# PhysicsWeapon.gd
extends RigidBody2D
class_name PhysicsWeapon

@export var weapon_name: String = "Sword"
@export var weapon_weight: float = 2.0  # kg
@export var weapon_length: float = 50.0  # pixels
@export var base_damage_multiplier: float = 10.0
@export var damage_type: String = "slashing"  # slashing, piercing, bludgeoning

# Physics properties
@export var sharpness: float = 1.0  # Affects penetration
@export var impact_area: float = 0.1  # m^2, affects pressure

# Visual
@export var weapon_color: Color = Color(0.7, 0.7, 0.8)
@export var handle_color: Color = Color(0.4, 0.2, 0.1)

var current_velocity: Vector2 = Vector2.ZERO
var previous_position: Vector2 = Vector2.ZERO
var is_swinging: bool = false
var has_hit_this_swing: bool = false
var hit_bodies: Array = []

# Damage calculation
var kinetic_energy: float = 0.0
var impact_damage: float = 0.0

signal weapon_hit(body, damage, impact_point)
signal weapon_bounced(body, impact_point)

func _ready():
	_setup_weapon_physics()
	_create_weapon_visual()
	
	# Set up collision detection
	contact_monitor = true
	max_contacts_reported = 10
	
	body_entered.connect(_on_body_entered)
	
	# Track velocity
	set_physics_process(true)

func _setup_weapon_physics():
	mass = weapon_weight
	gravity_scale = 0.0  # Weapon is controlled by motor, not gravity
	linear_damp = 0.5
	angular_damp = 0.5
	
	# Create collision shape
	var shape = CapsuleShape2D.new()
	shape.radius = 3.0
	shape.height = weapon_length
	
	var collision = CollisionShape2D.new()
	collision.shape = shape
	collision.rotation = PI/2  # Horizontal
	add_child(collision)
	
	# Set collision layers
	collision_layer = 0b1000  # Weapon layer
	collision_mask = 0b0111  # Collide with walls, cover, and characters

func _create_weapon_visual():
	var visual = Node2D.new()
	add_child(visual)
	
	# Blade
	var blade = Polygon2D.new()
	var blade_points = PackedVector2Array()
	
	match damage_type:
		"slashing":
			# Sword blade shape
			blade_points.append(Vector2(weapon_length * 0.2, -2))
			blade_points.append(Vector2(weapon_length, -1))
			blade_points.append(Vector2(weapon_length + 5, 0))  # Tip
			blade_points.append(Vector2(weapon_length, 1))
			blade_points.append(Vector2(weapon_length * 0.2, 2))
		"piercing":
			# Spear/thrust weapon shape
			blade_points.append(Vector2(weapon_length * 0.3, -1))
			blade_points.append(Vector2(weapon_length + 8, 0))  # Sharp tip
			blade_points.append(Vector2(weapon_length * 0.3, 1))
		"bludgeoning":
			# Mace/club shape
			blade_points.append(Vector2(weapon_length * 0.3, -3))
			blade_points.append(Vector2(weapon_length, -4))
			blade_points.append(Vector2(weapon_length, 4))
			blade_points.append(Vector2(weapon_length * 0.3, 3))
	
	blade.polygon = blade_points
	blade.color = weapon_color
	visual.add_child(blade)
	
	# Handle
	var handle = Polygon2D.new()
	handle.polygon = PackedVector2Array([
		Vector2(0, -2),
		Vector2(weapon_length * 0.25, -2),
		Vector2(weapon_length * 0.25, 2),
		Vector2(0, 2)
	])
	handle.color = handle_color
	visual.add_child(handle)
	
	# Guard (for swords)
	if damage_type == "slashing":
		var guard = Polygon2D.new()
		guard.polygon = PackedVector2Array([
			Vector2(weapon_length * 0.2, -5),
			Vector2(weapon_length * 0.25, -1),
			Vector2(weapon_length * 0.25, 1),
			Vector2(weapon_length * 0.2, 5)
		])
		guard.color = weapon_color.darkened(0.2)
		visual.add_child(guard)

func _physics_process(delta):
	# Calculate current velocity and kinetic energy
	current_velocity = (global_position - previous_position) / delta
	previous_position = global_position
	
	# Kinetic energy = 0.5 * mass * velocity^2
	var speed = current_velocity.length() / 100.0  # Convert to m/s
	kinetic_energy = 0.5 * weapon_weight * speed * speed
	
	# Calculate potential damage
	impact_damage = base_damage_multiplier * kinetic_energy

func _on_body_entered(body):
	if not is_swinging or has_hit_this_swing:
		return
	
	if body in hit_bodies:
		return  # Already hit this body in this swing
	
	# Check if it's a character
	if body.has_method("take_damage"):
		var impact_point = global_position + Vector2(weapon_length, 0).rotated(rotation)
		_handle_character_hit(body, impact_point)
	elif body is StaticBody2D or body is RigidBody2D:
		# Hit a wall or object
		_handle_obstacle_hit(body)

func _handle_character_hit(character, impact_point: Vector2):
	# Get the body part that was hit
	var body_part = "torso"  # Default
	if character.has_method("get_body_part_at_position"):
		body_part = character.get_body_part_at_position(impact_point)
	
	# Get damage resistance of the body part
	var dr = 0.0
	if character.body_parts.has(body_part):
		var part = character.body_parts[body_part]
		if part.armor:
			dr = part.armor.get_dr(damage_type)
	
	# Calculate damage after DR
	var final_damage = max(0, impact_damage - dr)
	
	if final_damage <= 0:
		# Weapon bounces off
		_bounce_off(character, impact_point, dr)
	else:
		# Weapon penetrates, apply slowdown
		_apply_penetration_slowdown(dr)
		
		# Deal damage
		character.take_damage(final_damage, damage_type, body_part)
		weapon_hit.emit(character, final_damage, impact_point)
		
		# Add to hit list
		hit_bodies.append(character)
		
		# Create hit effect
		_create_hit_effect(impact_point, final_damage > 10)

func _bounce_off(body, impact_point: Vector2, dr: float):
	# Calculate bounce impulse
	var bounce_direction = (global_position - impact_point).normalized()
	var bounce_strength = kinetic_energy * 0.5 * (dr / 10.0)  # More DR = stronger bounce
	
	# Apply impulse to weapon
	apply_impulse(bounce_direction * bounce_strength, impact_point - global_position)
	
	# Apply opposite impulse to character if it's a RigidBody2D
	if body is RigidBody2D:
		body.apply_impulse(-bounce_direction * bounce_strength * 0.3, impact_point - body.global_position)
	
	# Stop the swing
	has_hit_this_swing = true
	weapon_bounced.emit(body, impact_point)
	
	# Create spark effect
	_create_spark_effect(impact_point)

func _apply_penetration_slowdown(dr: float):
	# Apply damping based on DR
	var slowdown_factor = 1.0 - (dr / 20.0)  # Max 50% slowdown at DR 10
	linear_velocity *= slowdown_factor
	angular_velocity *= slowdown_factor
	
	# Add drag
	linear_damp = 2.0 + dr * 0.5
	angular_damp = 2.0 + dr * 0.5

func _handle_obstacle_hit(obstacle):
	# Weapon hits wall/cover
	has_hit_this_swing = true
	
	# Apply strong damping
	linear_velocity *= 0.2
	angular_velocity *= 0.2
	
	# Create impact effect
	_create_spark_effect(global_position)

func start_swing():
	is_swinging = true
	has_hit_this_swing = false
	hit_bodies.clear()
	linear_damp = 0.5  # Reset damping
	angular_damp = 0.5

func end_swing():
	is_swinging = false

func _create_hit_effect(position: Vector2, is_critical: bool = false):
	# Create blood splatter or impact effect
	var effect = CPUParticles2D.new()
	effect.position = position
	effect.amount = 20 if is_critical else 10
	effect.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	effect.spread = 30.0
	effect.initial_velocity_min = 50.0
	effect.initial_velocity_max = 150.0 if is_critical else 100.0
	effect.scale_amount_min = 0.5
	effect.scale_amount_max = 1.5
	effect.color = Color(0.8, 0.1, 0.1) if damage_type != "bludgeoning" else Color(0.5, 0.5, 0.5)
	effect.lifetime = 0.5
	effect.emitting = true
	get_parent().add_child(effect)

func _create_spark_effect(position: Vector2):
	# Create sparks for bouncing off armor
	var sparks = CPUParticles2D.new()
	sparks.position = position
	sparks.amount = 15
	sparks.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	sparks.spread = 45.0
	sparks.initial_velocity_min = 100.0
	sparks.initial_velocity_max = 200.0
	sparks.scale_amount_min = 0.3
	sparks.scale_amount_max = 0.8
	sparks.color = Color(1, 0.9, 0.3)
	sparks.lifetime = 0.3
	sparks.emitting = true
	get_parent().add_child(sparks)



#
