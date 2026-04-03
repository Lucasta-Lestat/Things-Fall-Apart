extends Node2D

@onready var cloud: ColorRect = $CloudLayer
@onready var particles: GPUParticles2D = $GPUParticles2D
@onready var light: PointLight2D = $PointLight2D

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

	# Scale particle emission area to match cloud size
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	mat.emission_box_extents = Vector3(_base_cloud_size.x * size_scale * 0.5, _base_cloud_size.y * size_scale * 0.5, 0)

	# Scale particle size
	mat.scale_min *= size_scale
	mat.scale_max *= size_scale

	# More particles for larger storms
	particles.amount = int(particles.amount * size_scale * size_scale)

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
