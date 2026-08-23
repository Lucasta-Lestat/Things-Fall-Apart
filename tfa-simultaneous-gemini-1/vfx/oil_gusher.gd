extends Node2D

# The wellhead of an Oil Well: a jet of crude erupting at the centre, and a wide
# low spatter of droplets flung out across the slick it is filling.
#
# Spawned as a CHILD of FluidWell, not through `visuals.impact_effect`, so its
# lifetime is exactly the well's duration. The impact_effect path hard-frees on
# the visual_duration timer at roughly two seconds and cannot cover six.

# World-space radius the artwork is authored at, read by FluidWell (and by the
# generic _spawn_effect path) via `vfx_base_radius` -- the same contract
# vfx/ice_storm.gd uses. Without it the legacy `radius / 25.0` guess would blow
# this up 7.7x at the spell's authored radius of 192.
const BASE_RADIUS := 192.0

# Seconds of taper before expiry. The spout stops first so the well reads as
# running dry rather than being cut off mid-jet when FluidWell frees itself.
const TAPER_TIME := 1.0

@onready var spout: GPUParticles2D = $Spout
@onready var spatter: GPUParticles2D = $Spatter
@onready var light: PointLight2D = $PointLight2D

var vfx_base_radius: float = BASE_RADIUS

var _duration: float = 6.0
var _age: float = 0.0


## Called by FluidWell with the well's real radius and duration.
func play_well(well_radius: float, well_duration: float) -> void:
	_duration = well_duration
	var s: float = well_radius / BASE_RADIUS

	var spatter_mat := spatter.process_material.duplicate() as ParticleProcessMaterial
	spatter.process_material = spatter_mat
	# The spatter ring tracks the pool. The spout is deliberately NOT scaled --
	# it is a fixed-size wellhead, and a fountain as wide as the whole 384px pool
	# reads as a flood rather than as something welling up out of one point.
	spatter_mat.emission_sphere_radius = well_radius * 0.7
	spatter_mat.scale_min *= s
	spatter_mat.scale_max *= s
	spatter.amount = int(clampf(float(spatter.amount) * s, 20.0, 180.0))

	light.texture_scale *= s

	spout.emitting = true
	spatter.emitting = true


# Fallback for anything spawning this through the generic _spawn_effect path.
func play(size_scale: float = 1.0) -> void:
	play_well(BASE_RADIUS * size_scale, _duration)


func stop() -> void:
	spout.emitting = false
	spatter.emitting = false


func _process(delta: float) -> void:
	# Same gate as FluidWell and SilenceZone: the tactical planner pauses the
	# world, and a jet that keeps pumping through a pause outlives its own well.
	if PauseManager.is_paused:
		return
	_age += delta
	if _duration > 0.0 and _age >= _duration - TAPER_TIME and spout.emitting:
		spout.emitting = false
