## ScarlattiEmblem
## The arms of the Republic of Scarlatti, engraved procedurally: a laurel
## wreath around a set of scales that does not hang level. In a country whose
## judges publish their bribe rates (see the `judge_for_hire` background) the
## tilt is not an accident of the engraving — it is the coat of arms.
##
## Drawn rather than authored so it tints with the card it sits on and stays
## crisp at any size.
class_name ScarlattiEmblem
extends Control

@export var ink: Color = Color("5d1c2e")
## How far the beam tips, in degrees. Positive tips the right-hand pan down.
@export var tilt_degrees: float = 11.0

const LEAVES_PER_BRANCH: int = 7

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)

func _draw() -> void:
	var r: float = minf(size.x, size.y) * 0.5
	if r < 6.0:
		return
	var c: Vector2 = size * 0.5
	_draw_wreath(c, r)
	_draw_scales(c, r)

# ---------------------------------------------------------------------------

func _draw_wreath(c: Vector2, r: float) -> void:
	var ring: float = r * 0.86
	var thin: Color = Color(ink.r, ink.g, ink.b, 0.9)
	# Two branches sweeping up from the base, meeting at the top.
	var sides: Array[float] = [-1.0, 1.0]
	for side in sides:
		for i in range(LEAVES_PER_BRANCH):
			var t: float = float(i) / float(LEAVES_PER_BRANCH - 1)
			# From the bottom (PI/2) around to the top, on one side.
			var a: float = PI * 0.5 - side * (0.30 + t * 2.35)
			var outward := Vector2(cos(a), sin(a))
			var base: Vector2 = c + outward * ring
			var along: Vector2 = Vector2(-outward.y, outward.x) * side
			var leaf: float = r * (0.26 - 0.09 * t)
			_draw_leaf(base, along, outward, leaf, thin)
	# The stems.
	draw_arc(c, ring, PI * 0.5 - 2.65, PI * 0.5 - 0.28, 40, thin, 1.4, true)
	draw_arc(c, ring, PI * 0.5 + 0.28, PI * 0.5 + 2.65, 40, thin, 1.4, true)
	# The tie at the foot of the wreath.
	draw_arc(c + Vector2(0.0, ring), r * 0.10, 0.0, TAU, 18, thin, 1.2, true)

## One laurel leaf as a two-arc almond, pointing `along` and bulging `outward`.
func _draw_leaf(base: Vector2, along: Vector2, outward: Vector2,
		length: float, col: Color) -> void:
	var tip: Vector2 = base + along * length
	var bulge: float = length * 0.34
	var pts_a := PackedVector2Array()
	var pts_b := PackedVector2Array()
	for i in range(9):
		var t: float = float(i) / 8.0
		var spine: Vector2 = base.lerp(tip, t)
		var swell: float = sin(t * PI) * bulge
		pts_a.append(spine + outward * swell)
		pts_b.append(spine - outward * swell * 0.55)
	draw_polyline(pts_a, col, 1.0, true)
	draw_polyline(pts_b, col, 1.0, true)

func _draw_scales(c: Vector2, r: float) -> void:
	var heavy: Color = Color(ink.r, ink.g, ink.b, 0.95)
	var tilt: float = deg_to_rad(tilt_degrees)
	var beam_half: float = r * 0.50
	var beam_dir := Vector2(cos(tilt), sin(tilt))
	var pivot: Vector2 = c - Vector2(0.0, r * 0.34)

	# Post and foot.
	draw_line(pivot, c + Vector2(0.0, r * 0.50), heavy, 2.2, true)
	draw_line(c + Vector2(-r * 0.24, r * 0.50), c + Vector2(r * 0.24, r * 0.50),
			heavy, 2.2, true)

	# Beam and its centre boss.
	var left: Vector2 = pivot - beam_dir * beam_half
	var right: Vector2 = pivot + beam_dir * beam_half
	draw_line(left, right, heavy, 2.2, true)
	draw_arc(pivot, r * 0.08, 0.0, TAU, 16, heavy, 1.8, true)

	# Pans hang plumb from the beam ends, at different heights — the tilt is
	# the point of the device, so the drop has to differ visibly.
	_draw_pan(left, r * 0.34, r * 0.16, heavy)
	_draw_pan(right, r * 0.34, r * 0.42, heavy)

func _draw_pan(from: Vector2, width: float, drop: float, col: Color) -> void:
	var hook: Vector2 = from + Vector2(0.0, drop)
	draw_line(from, hook, col, 1.0, true)
	# A shallow dish: two chains down to the rim, then the rim itself.
	var l: Vector2 = hook + Vector2(-width * 0.5, 0.0)
	var rr: Vector2 = hook + Vector2(width * 0.5, 0.0)
	draw_line(hook, l, col, 1.0, true)
	draw_line(hook, rr, col, 1.0, true)
	var dish := PackedVector2Array()
	for i in range(13):
		var t: float = float(i) / 12.0
		dish.append(Vector2(
			lerpf(l.x, rr.x, t),
			hook.y + sin(t * PI) * width * 0.24))
	draw_polyline(dish, col, 1.4, true)
