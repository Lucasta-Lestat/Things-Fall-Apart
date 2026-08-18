extends Node2D

# World-space radius the artwork is authored at (the cloud layer is 160x160,
# i.e. a radius of 80). The spawner scales by ability_radius / this, so the
# storm covers exactly the AoE it damages.
const BASE_RADIUS := 80.0

@onready var cloud: ColorRect = $CloudLayer
@onready var particles: GPUParticles2D = $GPUParticles2D
@onready var light: PointLight2D = $PointLight2D

var vfx_base_radius: float = BASE_RADIUS

var _base_cloud_size: Vector2

func _ready() -> void:
	_base_cloud_size = cloud.size

func play(size_scale: float = 1.0):
	# Scale the cloud layer
	cloud.size = _base_cloud_size * size_scale
	cloud.position = -cloud.size * 0.5
	if cloud.material is ShaderMaterial:
		cloud.material = cloud.material.duplicate()
		cloud.material.set_shader_parameter("resolution", cloud.size)

	# Duplicate particle material to avoid shared resource mutation
	var mat = particles.process_material.duplicate() as ParticleProcessMaterial
	particles.process_material = mat

	# Emit from a disc, not a box — the AoE is a circle, and box corners were
	# throwing snow well outside the area the spell actually hits.
	var radius_px: float = BASE_RADIUS * size_scale
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = radius_px * 0.92

	# Scale particle size
	mat.scale_min *= size_scale
	mat.scale_max *= size_scale

	# Keep the fall distance a small fraction of the radius so snow stays inside
	# the circle instead of raining out the bottom of it.
	mat.initial_velocity_min *= size_scale * 0.4
	mat.initial_velocity_max *= size_scale * 0.4
	mat.gravity = Vector3(0, 40.0 * size_scale, 0)

	# More particles for larger storms (linear in area, capped)
	particles.amount = int(clampf(float(particles.amount) * size_scale, 20.0, 220.0))

	# Longer lifetime for larger storms
	particles.lifetime *= sqrt(size_scale)

	# Scale the light
	light.texture_scale *= size_scale
	light.energy *= size_scale

	particles.emitting = true

func _process(delta: float) -> void:
	# Animate cloud shader time
	if cloud.material is ShaderMaterial:
		var current_time = cloud.material.get_shader_parameter("time")
		if current_time == null:
			current_time = 0.0
		cloud.material.set_shader_parameter("time", current_time + delta)
