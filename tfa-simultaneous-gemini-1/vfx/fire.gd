extends Node2D

@onready var particles: GPUParticles2D = $GPUParticles2D
@onready var light: PointLight2D = $PointLight2D

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
	light.energy *= size_scale

	particles.emitting = true
