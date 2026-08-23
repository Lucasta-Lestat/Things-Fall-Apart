extends Node2D

# Generic in-world visual for a CompulsionField: a particle body plus a light,
# sized to the field and tapering out before the field frees itself.
#
# One script, three looks -- the musk cloud, the idol's halo and the apple's
# shimmer differ only in their .tscn (process materials, ramps, light colour and
# energy). Spawned as a CHILD of the field, so its lifetime is exactly the
# field's duration; routing it through visuals.impact_effect instead would cap it
# at roughly two seconds and could never cover a 30-second idol.

# World radius the artwork is authored at. CompulsionField reads this through
# `vfx_base_radius` -- the same duck-typed contract vfx/ice_storm.gd and
# vfx/oil_gusher.gd use. Each scene overrides it in the inspector to match the
# radius its spell authors, so the common case scales by exactly 1.0.
@export var base_radius: float = 256.0

## Seconds of taper before expiry. Emission stops early so the effect reads as
## fading rather than being cut mid-frame when the field frees itself.
@export var taper_time: float = 1.5

## Multiplier applied to the light's reach as the field scales. The idol wants
## its glow to stay a fixed beacon, so its scene sets this to 0.
@export var light_tracks_radius: float = 1.0

var vfx_base_radius: float = 256.0

var _duration: float = 12.0
var _age: float = 0.0
var _particles: Array[GPUParticles2D] = []
var _light: PointLight2D = null


func _ready() -> void:
	vfx_base_radius = base_radius
	for child in get_children():
		if child is GPUParticles2D:
			_particles.append(child)
		elif child is PointLight2D and _light == null:
			_light = child


## Called by CompulsionField with the field's real radius and duration.
func play_field(field_radius: float, field_duration: float) -> void:
	_duration = field_duration
	var s: float = field_radius / maxf(base_radius, 1.0)

	for p in _particles:
		var mat = p.process_material.duplicate() as ParticleProcessMaterial
		p.process_material = mat
		# Emission area tracks the field so the visual never claims ground the
		# spell does not actually reach.
		mat.emission_sphere_radius *= s
		mat.scale_min *= s
		mat.scale_max *= s
		p.amount = int(clampf(float(p.amount) * s, 12.0, 200.0))
		p.emitting = true

	if _light != null and light_tracks_radius > 0.0:
		_light.texture_scale *= 1.0 + (s - 1.0) * light_tracks_radius


# Fallback for anything spawning this through the generic _spawn_effect path.
func play(size_scale: float = 1.0) -> void:
	play_field(base_radius * size_scale, _duration)


func stop() -> void:
	for p in _particles:
		p.emitting = false


func _process(delta: float) -> void:
	# Same gate as CompulsionField, FluidWell and SilenceZone: the tactical
	# planner stops the world, and a visual that kept running through a pause
	# would taper out while its own field is still frozen at full strength.
	if PauseManager.is_paused:
		return
	_age += delta
	if _duration > 0.0 and _age >= _duration - taper_time:
		stop()
