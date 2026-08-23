extends Node2D

# Generic in-hand mote effect: particles plus a small tinted light, scaled by the
# caller. Every look lives in the .tscn (gradient ramp, process material, light
# colour) so one script backs many spells.
#
# The project already carries fifteen byte-identical copies of this function --
# acid_hand.gd, nature_hand.gd, oil_hand.gd and the rest. New in-hand scenes
# point at THIS file instead of adding a sixteenth.
#
# AbilityShape.setup_from_database requires a Node2D root and calls play(); the
# process material is duplicated before mutation because the .tscn resource is
# shared between every instance of the scene.

@onready var particles: GPUParticles2D = $GPUParticles2D
@onready var light: PointLight2D = $PointLight2D


func play(size_scale: float = 1.0) -> void:
	var mat = particles.process_material.duplicate() as ParticleProcessMaterial
	particles.process_material = mat

	mat.scale_min *= size_scale
	mat.scale_max *= size_scale
	mat.initial_velocity_min *= size_scale
	mat.initial_velocity_max *= size_scale

	particles.amount = int(particles.amount * size_scale * size_scale)
	particles.lifetime *= sqrt(size_scale)

	light.texture_scale *= size_scale
	light.energy *= size_scale

	particles.emitting = true
