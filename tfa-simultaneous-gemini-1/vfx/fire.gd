extends Node2D

@onready var particles: GPUParticles2D = $GPUParticles2D
@onready var light: PointLight2D = $PointLight2D

var _base_light_energy: float = 0.0
var _flicker_phase: float = 0.0
var _flicker_active: bool = true

func _ready() -> void:
	_base_light_energy = light.energy
	_flicker_phase = float(get_instance_id() % 1000) * 0.01

func play(size_scale: float = 1.0):
	# Duplicate material to avoid mutating the shared resource
	var mat = particles.process_material.duplicate() as ParticleProcessMaterial
	particles.process_material = mat

	# Scale particle size
	mat.scale_min *= size_scale
	mat.scale_max *= size_scale

	# Scale velocity so particles travel further
	mat.initial_velocity_min *= size_scale
	mat.initial_velocity_max *= size_scale

	# More particles for larger fires (quadratic scaling)
	particles.amount = int(particles.amount * size_scale * size_scale)

	# Longer lifetime for larger fires
	particles.lifetime *= sqrt(size_scale)

	# Scale the light
	light.texture_scale *= size_scale
	_base_light_energy *= size_scale
	light.energy = _base_light_energy

	particles.emitting = true

func stop() -> void:
	particles.emitting = false
	_flicker_active = false

func _process(delta: float) -> void:
	if not _flicker_active:
		return
	_flicker_phase += delta
	var flicker = sin(_flicker_phase * 18.0) * 0.08 \
		+ sin(_flicker_phase * 7.3 + 1.7) * 0.05 \
		+ (randf() - 0.5) * 0.04
	light.energy = _base_light_energy * (1.0 + flicker)
