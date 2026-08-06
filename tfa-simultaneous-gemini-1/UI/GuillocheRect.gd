## GuillocheRect
## The engine-turned security print an old identity card is printed on: a warm
## paper fill, a field of fine parallel waves, a sunburst behind the emblem, a
## spirograph rosette, and a double-ruled border with a rope motif between the
## rules.
##
## Everything is procedural `_draw()` — no textures — so the pattern scales to
## any card size and re-tints without new art. It is deterministic: the same
## `pattern_seed` always prints the same document.
class_name GuillocheRect
extends Control

@export var paper_color: Color = Color("f2e3ce")
## Fine wave field + rosette. Rose-madder, like the reference cards.
@export var ink_color: Color = Color("a8425f")
## Border rules and the heavier engraving.
@export var deep_ink: Color = Color("5d1c2e")
@export var pattern_seed: int = 43454

## Rosette placement, as a fraction of the card. Sits behind the emblem.
@export var rosette_center := Vector2(0.5, 0.142)
@export var rosette_radius: float = 0.078
@export var show_rosette: bool = true
@export var show_sunburst: bool = true

## Width of the engraved band between the outer and inner border rules.
@export var border_band: float = 13.0
@export var border_inset: float = 7.0

const WAVE_ROW_SPACING: float = 6.0
const WAVE_AMPLITUDE: float = 2.1
const WAVE_LENGTH: float = 27.0
const SUNBURST_RAYS: int = 168

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The sunburst deliberately overruns the rosette; without clipping its rays
	# print onto whatever is behind the card.
	clip_contents = true
	resized.connect(queue_redraw)

func _draw() -> void:
	if size.x < 8.0 or size.y < 8.0:
		return
	draw_rect(Rect2(Vector2.ZERO, size), paper_color, true)
	_draw_wave_field()
	if show_sunburst:
		_draw_sunburst()
	if show_rosette:
		_draw_rosette()
	_draw_border()

# ---------------------------------------------------------------------------
# The field: parallel waves whose phase drifts down the page, which is what
# gives the printed original its shimmer.
# ---------------------------------------------------------------------------

func _draw_wave_field() -> void:
	var faint: Color = Color(ink_color.r, ink_color.g, ink_color.b, 0.17)
	var step: float = maxf(2.0, WAVE_LENGTH / 6.0)
	var row: float = border_inset
	var index: int = 0
	while row < size.y - border_inset:
		var points := PackedVector2Array()
		var x: float = border_inset
		# Phase walks per row; the amplitude swells toward the middle of the
		# card so the border band reads as a distinct, tighter engraving.
		var phase: float = float(index) * 0.7 + float(pattern_seed % 17) * 0.11
		var centre_bias: float = sin(PI * clampf(row / maxf(size.y, 1.0), 0.0, 1.0))
		var amp: float = WAVE_AMPLITUDE * (0.55 + 0.45 * centre_bias)
		while x <= size.x - border_inset:
			points.append(Vector2(x, row + sin(x / WAVE_LENGTH * TAU + phase) * amp))
			x += step
		if points.size() >= 2:
			draw_polyline(points, faint, 1.0, true)
		row += WAVE_ROW_SPACING
		index += 1

# ---------------------------------------------------------------------------
# Sunburst behind the emblem.
# ---------------------------------------------------------------------------

func _draw_sunburst() -> void:
	var centre: Vector2 = rosette_center * size
	var outer: float = rosette_radius * minf(size.x, size.y) * 2.60
	var inner: float = rosette_radius * minf(size.x, size.y) * 0.55
	var faint: Color = Color(ink_color.r, ink_color.g, ink_color.b, 0.13)
	for i in range(SUNBURST_RAYS):
		var a: float = TAU * float(i) / float(SUNBURST_RAYS)
		var dir := Vector2(cos(a), sin(a))
		# Ragged ray lengths — a clean starburst looks like a logo, a jittered
		# one looks engraved.
		var jitter: float = 0.82 + 0.18 * sin(float(i) * 3.7 + float(pattern_seed % 29))
		draw_line(centre + dir * inner, centre + dir * outer * jitter, faint, 1.0, true)

# ---------------------------------------------------------------------------
# Rosette: nested spirograph curves, each ring a different lobe count.
# ---------------------------------------------------------------------------

func _draw_rosette() -> void:
	var centre: Vector2 = rosette_center * size
	var radius: float = rosette_radius * minf(size.x, size.y)
	# Shallow lobes and many of them: an engine-turned rosette is a dense ring
	# of fine scallops, not a flower. Deep lobes read as an amoeba.
	var rings: Array[Vector3] = [
		# x = lobe count, y = lobe depth (fraction of radius), z = scale
		Vector3(36.0, 0.045, 1.00),
		Vector3(30.0, 0.055, 0.88),
		Vector3(24.0, 0.065, 0.76),
		Vector3(18.0, 0.075, 0.63),
		Vector3(12.0, 0.090, 0.50),
	]
	for i in range(rings.size()):
		var ring: Vector3 = rings[i]
		var col: Color = Color(deep_ink.r, deep_ink.g, deep_ink.b, 0.30 - 0.04 * float(i))
		var points := PackedVector2Array()
		var steps: int = 360
		for s in range(steps + 1):
			var t: float = TAU * float(s) / float(steps)
			var r: float = radius * ring.z * (1.0 - ring.y + ring.y * cos(ring.x * t))
			points.append(centre + Vector2(cos(t), sin(t)) * r)
		draw_polyline(points, col, 1.0, true)

# ---------------------------------------------------------------------------
# Border: heavy outer rule, engraved band, thin inner rule.
# ---------------------------------------------------------------------------

func _draw_border() -> void:
	var outer := Rect2(Vector2(border_inset, border_inset),
			size - Vector2(border_inset, border_inset) * 2.0)
	var inner := Rect2(outer.position + Vector2(border_band, border_band),
			outer.size - Vector2(border_band, border_band) * 2.0)
	if inner.size.x <= 0.0 or inner.size.y <= 0.0:
		return

	_draw_rope_band(outer, inner)

	draw_rect(outer, deep_ink, false, 2.0)
	draw_rect(inner, Color(deep_ink.r, deep_ink.g, deep_ink.b, 0.75), false, 1.0)
	# A hair inside the inner rule, the way a real card double-frames its text.
	draw_rect(inner.grow(-3.0), Color(deep_ink.r, deep_ink.g, deep_ink.b, 0.35), false, 1.0)

## Two counter-phased waves woven down the band, with a bead at every crossing.
func _draw_rope_band(outer: Rect2, inner: Rect2) -> void:
	var mid: float = (outer.position.y + inner.position.y) * 0.5
	var col: Color = Color(deep_ink.r, deep_ink.g, deep_ink.b, 0.55)
	var amp: float = border_band * 0.30
	var wave: float = 18.0

	var mid_x: float = (outer.position.x + inner.position.x) * 0.5
	var signs: Array[float] = [1.0, -1.0]

	# Horizontal runs (top and bottom).
	var rows: Array[float] = [mid, size.y - mid]
	for edge_y in rows:
		for s in signs:
			var pts := PackedVector2Array()
			var x: float = outer.position.x
			while x <= outer.end.x:
				pts.append(Vector2(x, edge_y + sin(x / wave * TAU) * amp * s))
				x += 3.0
			if pts.size() >= 2:
				draw_polyline(pts, col, 1.0, true)

	# Vertical runs (left and right).
	var cols: Array[float] = [mid_x, size.x - mid_x]
	for edge_x in cols:
		for s in signs:
			var pts := PackedVector2Array()
			var y: float = outer.position.y
			while y <= outer.end.y:
				pts.append(Vector2(edge_x + sin(y / wave * TAU) * amp * s, y))
				y += 3.0
			if pts.size() >= 2:
				draw_polyline(pts, col, 1.0, true)

	# Corner rosettes tie the four runs together.
	var corners: Array[Vector2] = [
		Vector2(mid_x, mid),
		Vector2(size.x - mid_x, mid),
		Vector2(mid_x, size.y - mid),
		Vector2(size.x - mid_x, size.y - mid),
	]
	for corner in corners:
		draw_arc(corner, border_band * 0.42, 0.0, TAU, 24, col, 1.0, true)
		draw_arc(corner, border_band * 0.20, 0.0, TAU, 16, col, 1.0, true)
