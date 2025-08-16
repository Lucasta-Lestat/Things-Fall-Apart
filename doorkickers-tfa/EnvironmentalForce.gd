# EnvironmentalForce.gd
extends Area2D
class_name EnvironmentalForce

# Environmental forces that affect physics-based characters

enum ForceType {
	WIND,
	MAGNETIC,
	WATER_CURRENT,
	EXPLOSION,
	VORTEX,
	REPULSION
}

@export var force_type: ForceType = ForceType.WIND
@export var force_vector: Vector2 = Vector2(200, 0)
@export var force_center: Vector2 = Vector2.ZERO  # For radial forces
@export var is_constant: bool = true  # vs impulse
@export var falloff_distance: float = 200.0  # For radial forces
@export var visual_particles: bool = true

var affected_bodies: Array = []

func _ready():
	collision_layer = 0
	collision_mask = 0b0100  # Affect characters
	
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	
	if visual_particles:
		_create_visual_effect()
	
	set_physics_process(true)

func _physics_process(delta):
	if not is_constant:
		return
	
	for body in affected_bodies:
		if body.has_method("apply_external_force"):
			var force = _calculate_force_on_body(body)
			body.apply_external_force(force * delta, "environmental_" + str(force_type))

func _calculate_force_on_body(body) -> Vector2:
	match force_type:
		ForceType.WIND:
			return force_vector
		
		ForceType.MAGNETIC:
			# Pull toward center
			var to_center = (global_position + force_center - body.global_position)
			var distance = to_center.length()
			if distance < 1.0:
				return Vector2.ZERO
			var strength = force_vector.length() * (1.0 - distance / falloff_distance)
			return to_center.normalized() * strength
		
		ForceType.WATER_CURRENT:
			# Directional force with added friction
			if body.physics_body:
				body.physics_body.friction_coefficient = 20.0
			return force_vector * 0.5
		
		ForceType.EXPLOSION:
			# Radial push from center
			var from_center = (body.global_position - (global_position + force_center))
			var distance = from_center.length()
			if distance < 1.0:
				distance = 1.0
			var strength = force_vector.length() * (1.0 - distance / falloff_distance)
			return from_center.normalized() * strength
		
		ForceType.VORTEX:
			# Circular force around center
			var to_center = (global_position + force_center - body.global_position)
			var tangent = Vector2(-to_center.y, to_center.x).normalized()
			var distance = to_center.length()
			var pull_strength = force_vector.length() * 0.3 * (1.0 - distance / falloff_distance)
			var spin_strength = force_vector.length() * 0.7
			return to_center.normalized() * pull_strength + tangent * spin_strength
		
		ForceType.REPULSION:
			# Push away from center
			var from_center = (body.global_position - (global_position + force_center))
			return from_center.normalized() * force_vector.length()
	
	return Vector2.ZERO

func _on_body_entered(body):
	if body is TopDownCharacterController:
		affected_bodies.append(body)
		
		if not is_constant:
			# Apply impulse immediately
			var force = _calculate_force_on_body(body)
			body.add_external_force(force, 0.5, "environmental_impulse")
		
		# Special terrain effects
		match force_type:
			ForceType.WATER_CURRENT:
				body.in_wind_zone = true
				body.wind_force = force_vector

func _on_body_exited(body):
	affected_bodies.erase(body)
	
	if body is TopDownCharacterController:
		match force_type:
			ForceType.WATER_CURRENT:
				body.in_wind_zone = false
				if body.physics_body:
					body.physics_body.friction_coefficient = 10.0  # Reset

func _create_visual_effect():
	var particles = CPUParticles2D.new()
	add_child(particles)
	
	match force_type:
		ForceType.WIND:
			particles.amount = 20
			particles.lifetime = 2.0
			particles.direction = force_vector.normalized()
			particles.initial_velocity_min = force_vector.length() * 0.5
			particles.initial_velocity_max = force_vector.length()
			particles.color = Color(0.8, 0.8, 1.0, 0.3)
			particles.emission_shape = CPUParticles2D.EmissionShape.EMISSION_SHAPE_RECTANGLE
			particles.emission_box_extents = Vector2(100, 100)
		
		ForceType.MAGNETIC:
			particles.amount = 30
			particles.lifetime = 1.0
			particles.radial_accel_min = -force_vector.length()
			particles.radial_accel_max = -force_vector.length() * 0.5
			particles.tangential_accel_min = 50
			particles.tangential_accel_max = 100
			particles.color = Color(0.5, 0.3, 1.0, 0.5)
			particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
			particles.emission_sphere_radius = falloff_distance
		
		ForceType.VORTEX:
			particles.amount = 40
			particles.lifetime = 3.0
			particles.tangential_accel_min = 100
			particles.tangential_accel_max = 200
			particles.radial_accel_min = -50
			particles.color = Color(0.3, 0.8, 0.5, 0.4)
			particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
			particles.emission_sphere_radius = falloff_distance
	
	particles.emitting = true
