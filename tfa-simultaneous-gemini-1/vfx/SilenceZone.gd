class_name SilenceZone
extends Node2D

# A persistent circular region that damps sound passing through it.
#
# The zone knows nothing about who is listening. It registers itself with
# HearingManager on entering the tree and answers a single question —
# "how much of a sound travelling this path survives?" — which is enough for
# HearingManager to smother emission, hearing and pass-through alike.
#
# Gain is deliberately a float rather than a flag: 0.0 is the Silence spell,
# but a cave that merely muffles, a snowfall, or a heavy curtain can reuse
# the same zone with a gain between 0 and 1 and no new code.

## Radius of the affected region, in world pixels.
@export var radius: float = 120.0:
	set(value):
		radius = value
		queue_redraw()

## Sound multiplier inside the region. 0.0 is true silence; higher values
## muffle rather than smother.
@export var gain: float = 0.0

## Seconds the zone persists. Values <= 0 mean it never expires on its own.
@export var duration: float = 20.0

## Seconds spent fading the visual in on spawn and out before expiry.
@export var fade_time: float = 0.75

# Occult violet, matching the school's other effects (see vfx/creepy_beam.gd).
@export var void_color: Color = Color(0.10, 0.04, 0.18, 0.50)   # dead air
@export var ring_color: Color = Color(0.78, 0.45, 1.0, 0.85)    # collapsing waves
@export var rim_color: Color = Color(0.55, 0.18, 0.70, 0.90)    # boundary

# Concentric rings shown collapsing inward. Sound is drawn into the zone and
# swallowed rather than radiating out of it — the inverse of the game's
# existing sound_waves shader, and the same motif as the ability icon.
const RING_COUNT: int = 4
const RING_SPEED: float = 0.28      # collapses per second
const RIM_WIDTH: float = 3.0
const RING_MAX_WIDTH: float = 4.0
# Rings start just inside the rim so the boundary stays a distinct, steady
# line instead of being doubled by a wave sitting on top of it.
const RING_START: float = 0.92

var _age: float = 0.0
var _phase: float = 0.0


func _ready() -> void:
	# Drawn under characters but over the floor, like the other ground VFX.
	z_index = -1
	HearingManager.register_sound_zone(self)
	queue_redraw()


func _exit_tree() -> void:
	HearingManager.unregister_sound_zone(self)


func _process(delta: float) -> void:
	# Gated the same way fog, fluid and surface ticks are in Game._process:
	# a zone must not burn through its duration while the tactical planner
	# has the world paused.
	if PauseManager.is_paused:
		return

	_age += delta
	_phase = fposmod(_phase + delta * RING_SPEED, 1.0)

	if duration > 0.0 and _age >= duration:
		queue_free()
		return

	queue_redraw()


## How much of a sound travelling from one point to another survives this
## zone. The test is against the whole segment, so a sound is damped whether
## it starts inside, ends inside, or merely passes through.
func sound_gain_for_segment(from_pos: Vector2, to_pos: Vector2) -> float:
	var closest: Vector2 = Geometry2D.get_closest_point_to_segment(
		global_position, from_pos, to_pos
	)
	if global_position.distance_squared_to(closest) <= radius * radius:
		return gain
	return 1.0


## Whether a world position lies inside the zone.
func contains_point(world_pos: Vector2) -> bool:
	return global_position.distance_squared_to(world_pos) <= radius * radius


# Fade in on spawn, and back out over the last `fade_time` seconds so the
# zone never vanishes on a hard cut.
func _visual_alpha() -> float:
	var alpha: float = 1.0
	if fade_time > 0.0:
		alpha = minf(alpha, _age / fade_time)
		if duration > 0.0:
			alpha = minf(alpha, (duration - _age) / fade_time)
	return clampf(alpha, 0.0, 1.0)


func _draw() -> void:
	var alpha: float = _visual_alpha()
	if alpha <= 0.0:
		return

	# The dead air itself — a pool of muted violet.
	draw_circle(Vector2.ZERO, radius, _faded(void_color, alpha))

	# Waves collapsing inward, thinning and dimming as they are swallowed.
	for i in RING_COUNT:
		var t: float = fposmod(_phase + float(i) / float(RING_COUNT), 1.0)
		var ring_radius: float = radius * RING_START * (1.0 - t)
		if ring_radius <= 1.0:
			continue
		# Brightest at the rim, gone by the centre.
		var strength: float = (1.0 - t) * (1.0 - t)
		draw_arc(
			Vector2.ZERO,
			ring_radius,
			0.0,
			TAU,
			48,
			_faded(ring_color, alpha * strength),
			maxf(1.0, RING_MAX_WIDTH * strength),
			true
		)

	# A steady boundary so the silenced area reads as a hard edge on the map.
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 64, _faded(rim_color, alpha), RIM_WIDTH, true)


func _faded(base: Color, alpha: float) -> Color:
	return Color(base.r, base.g, base.b, base.a * alpha)
