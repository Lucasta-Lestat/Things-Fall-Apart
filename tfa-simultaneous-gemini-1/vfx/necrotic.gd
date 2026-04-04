extends Node2D

@onready var swirl: ColorRect = $SwirlLayer
@onready var particles: GPUParticles2D = $GPUParticles2D
@onready var light: PointLight2D = $PointLight2D

var _base_swirl_size: Vector2

func _ready() -> void:
	_base_swirl_size = swirl.size

func play(size_scale: float = 1.0):
	# Scale the swirl shader layer
	swirl.size = _base_swirl_size * size_scale
	swirl.position = -swirl.size * 0.5
	if swirl.material is ShaderMaterial:
		swirl.material = swirl.material.duplicate()
		swirl.material.set_shader_parameter("resolution", swirl.size)

	var mat = particles.process_material.duplicate() as ParticleProcessMaterial
	particles.process_material = mat

	mat.emission_box_extents = Vector3(_base_swirl_size.x * size_scale * 0.5, _base_swirl_size.y * size_scale * 0.5, 0)
	mat.scale_min *= size_scale
	mat.scale_max *= size_scale

	particles.amount = int(particles.amount * size_scale * size_scale)
	particles.lifetime *= sqrt(size_scale)

	light.texture_scale *= size_scale
	light.energy *= size_scale

	particles.emitting = true

func _process(delta: float) -> void:
	if swirl.material is ShaderMaterial:
		var current_time = swirl.material.get_shader_parameter("time")
		if current_time == null:
			current_time = 0.0
		swirl.material.set_shader_parameter("time", current_time + delta)
