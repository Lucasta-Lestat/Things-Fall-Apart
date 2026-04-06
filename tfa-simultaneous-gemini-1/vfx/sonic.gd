extends Node2D

@onready var waves: ColorRect = $WaveLayer
@onready var particles: GPUParticles2D = $GPUParticles2D
@onready var light: PointLight2D = $PointLight2D

var _base_wave_size: Vector2
var _base_wave_pos: Vector2

func _ready() -> void:
	_base_wave_size = waves.size
	_base_wave_pos = waves.position

func play(size_scale: float = 1.0):
	# Scale the cone wave layer — origin stays at left edge (0, -h/2)
	waves.size = _base_wave_size * size_scale
	waves.position = Vector2(0, -waves.size.y * 0.5)
	if waves.material is ShaderMaterial:
		waves.material = waves.material.duplicate()
		waves.material.set_shader_parameter("resolution", waves.size)

	var mat = particles.process_material.duplicate() as ParticleProcessMaterial
	particles.process_material = mat

	mat.emission_sphere_radius *= size_scale
	mat.scale_min *= size_scale
	mat.scale_max *= size_scale
	mat.initial_velocity_min *= size_scale
	mat.initial_velocity_max *= size_scale

	particles.amount = int(particles.amount * size_scale * size_scale)
	particles.lifetime *= sqrt(size_scale)

	light.position = Vector2(75 * size_scale, 0)
	light.texture_scale *= size_scale
	light.energy *= size_scale

	particles.emitting = true

func _process(delta: float) -> void:
	if waves.material is ShaderMaterial:
		var current_time = waves.material.get_shader_parameter("time")
		if current_time == null:
			current_time = 0.0
		waves.material.set_shader_parameter("time", current_time + delta)
