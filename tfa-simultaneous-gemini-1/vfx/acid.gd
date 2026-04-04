extends Node2D

@onready var liquid: ColorRect = $LiquidLayer
@onready var particles: GPUParticles2D = $GPUParticles2D
@onready var light: PointLight2D = $PointLight2D

var _base_liquid_size: Vector2

func _ready() -> void:
	_base_liquid_size = liquid.size

func play(size_scale: float = 1.0):
	# Scale the liquid shader layer
	liquid.size = _base_liquid_size * size_scale
	liquid.position = -liquid.size * 0.5
	if liquid.material is ShaderMaterial:
		liquid.material = liquid.material.duplicate()
		liquid.material.set_shader_parameter("resolution", liquid.size)

	var mat = particles.process_material.duplicate() as ParticleProcessMaterial
	particles.process_material = mat

	mat.emission_box_extents = Vector3(_base_liquid_size.x * size_scale * 0.5, _base_liquid_size.y * size_scale * 0.5, 0)
	mat.scale_min *= size_scale
	mat.scale_max *= size_scale

	particles.amount = int(particles.amount * size_scale * size_scale)
	particles.lifetime *= sqrt(size_scale)

	light.texture_scale *= size_scale
	light.energy *= size_scale

	particles.emitting = true

func _process(delta: float) -> void:
	if liquid.material is ShaderMaterial:
		var current_time = liquid.material.get_shader_parameter("time")
		if current_time == null:
			current_time = 0.0
		liquid.material.set_shader_parameter("time", current_time + delta)
