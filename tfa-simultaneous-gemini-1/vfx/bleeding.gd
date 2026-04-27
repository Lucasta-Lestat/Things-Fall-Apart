extends Node2D

# Persistent bleeding VFX — attached as child of a character while the
# bleeding condition is active. Emits small dark droplets and a faint mist.

@onready var drip_particles: GPUParticles2D = $DripParticles
@onready var mist_particles: GPUParticles2D = $MistParticles

func play(size_scale: float = 1.0) -> void:
	_scale_particles(drip_particles, size_scale)
	_scale_particles(mist_particles, size_scale)
	drip_particles.emitting = true
	mist_particles.emitting = true

func stop() -> void:
	drip_particles.emitting = false
	mist_particles.emitting = false

func _scale_particles(p: GPUParticles2D, size_scale: float) -> void:
	if not p:
		return
	var mat = p.process_material.duplicate() as ParticleProcessMaterial
	p.process_material = mat
	mat.scale_min *= size_scale
	mat.scale_max *= size_scale
	mat.initial_velocity_min *= size_scale
	mat.initial_velocity_max *= size_scale
	p.amount = max(1, int(p.amount * size_scale))

# Fire a short, one-shot burst of droplets — used for impacts and severing.
func burst(amount_multiplier: float = 1.0) -> void:
	if not drip_particles:
		return
	var one_shot: GPUParticles2D = drip_particles.duplicate() as GPUParticles2D
	add_child(one_shot)
	one_shot.one_shot = true
	one_shot.explosiveness = 0.95
	one_shot.amount = max(1, int(drip_particles.amount * amount_multiplier))
	one_shot.emitting = true
	var lifetime = one_shot.lifetime
	get_tree().create_timer(lifetime + 0.1).timeout.connect(func():
		if is_instance_valid(one_shot):
			one_shot.queue_free()
	, CONNECT_ONE_SHOT)
