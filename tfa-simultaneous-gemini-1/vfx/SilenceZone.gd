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

# Deliberately faint and desaturated. Silence is the absence of sound, so the
# zone reads as a quiet, still pool of dead air — not an active effect. A large
# bright wash would be the visual equivalent of a loud noise.
@export var wash_color: Color = Color(0.16, 0.13, 0.20, 0.14)   # dead air
@export var rim_color: Color = Color(0.55, 0.46, 0.62, 0.30)    # soft boundary

const RIM_WIDTH: float = 2.0

# The centred mark is the ability's own icon, scaled to this fraction of the
# zone diameter — a small, still glyph in the middle of the quiet, not a
# pattern that fills it.
const ICON_SCALE: float = 0.6
const ICON_PATH: String = "res://UI/UI Icons/ability_silence.png"

var _age: float = 0.0
var _icon: Texture2D = null


func _ready() -> void:
	# Drawn under characters but over the floor, like the other ground VFX.
	z_index = -1
	if ResourceLoader.exists(ICON_PATH):
		_icon = load(ICON_PATH)
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

	if duration > 0.0 and _age >= duration:
		queue_free()
		return

	# The zone is otherwise static, so only redraw while the fade is actually
	# changing the image — no per-frame churn once it has settled.
	if _is_fading():
		queue_redraw()


# True while the spawn fade-in or the pre-expiry fade-out is in progress.
func _is_fading() -> bool:
	if fade_time <= 0.0:
		return false
	if _age < fade_time:
		return true
	return duration > 0.0 and (duration - _age) < fade_time


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

	# The dead air itself — a faint, still pool.
	draw_circle(Vector2.ZERO, radius, _faded(wash_color, alpha))

	# A soft boundary so the silenced area reads as a discrete region.
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 64, _faded(rim_color, alpha), RIM_WIDTH, true)

	# The silence mark, centred.
	if _icon != null:
		var side: float = radius * ICON_SCALE
		var rect := Rect2(-Vector2(side, side) * 0.5, Vector2(side, side))
		draw_texture_rect(_icon, rect, false, Color(1.0, 1.0, 1.0, alpha))


func _faded(base: Color, alpha: float) -> Color:
	return Color(base.r, base.g, base.b, base.a * alpha)
