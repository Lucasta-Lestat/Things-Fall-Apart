extends Node2D

# Radar/sonar first-contact ping. Spawned by Game.gd when the player hears an
# NPC they've never directly seen. Plays a single expanding ring at the heard
# position, then auto-frees.

@onready var particles: GPUParticles2D = $GPUParticles2D
@onready var light: PointLight2D = $PointLight2D

# Total time before queue_free. Slightly longer than particle lifetime so
# trailing particles finish their fade before the node is removed.
const FREE_AFTER: float = 1.2


func play(size_scale: float = 1.0) -> void:
	if size_scale != 1.0:
		var mat = particles.process_material.duplicate() as ParticleProcessMaterial
		particles.process_material = mat
		mat.scale_min *= size_scale
		mat.scale_max *= size_scale
		mat.initial_velocity_min *= size_scale
		mat.initial_velocity_max *= size_scale
		light.texture_scale *= size_scale
	particles.emitting = true
	# Auto-cleanup. Use a SceneTreeTimer so we don't depend on particle
	# `finished` signal firing reliably across editor reloads.
	get_tree().create_timer(FREE_AFTER).timeout.connect(queue_free)
