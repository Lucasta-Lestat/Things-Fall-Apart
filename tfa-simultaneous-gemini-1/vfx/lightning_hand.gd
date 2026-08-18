extends Node2D

## In-hand lightning: live arcs crackling between anchor points around the hand,
## plus a fine spray of sparks. The arcs are what make it read as lightning —
## sparks alone are the same puff every other element uses.

@export var arc_count: int = 3
@export var arc_radius: float = 16.0
@export var arc_segments: int = 10
@export var arc_jitter: float = 2.6
@export var regen_interval: float = 0.05
@export var core_color: Color = Color(1.0, 1.0, 1.0, 0.8)
@export var glow_color: Color = Color(0.45, 0.75, 1.0, 0.3)
## Width of the hot filament at its thickest point. Arcs taper to a fraction of
## this at both ends and vary per-arc, so they read as filaments rather than
## uniform bars.
@export var thickness: float = 0.85
@export var end_taper: float = 0.2

@onready var particles: GPUParticles2D = $GPUParticles2D
@onready var light: PointLight2D = $PointLight2D

var _arcs: Array[PackedVector2Array] = []
var _arc_widths: Array[float] = []
var _accum: float = 0.0
var _time: float = 0.0

func _ready() -> void:
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat
	_regenerate()

func play(size_scale: float = 1.0):
	scale = Vector2(size_scale, size_scale)
	if particles:
		particles.emitting = true

func _process(delta: float) -> void:
	_time += delta
	_accum += delta
	if _accum >= regen_interval:
		_accum = 0.0
		_regenerate()
		queue_redraw()

	if light:
		# Electrical flicker rather than a steady lamp
		light.energy = 0.22 + 0.18 * randf()

func _regenerate() -> void:
	_arcs.clear()
	_arc_widths.clear()
	for i in range(arc_count):
		# Each arc gets its own weight so they don't all read as the same stroke
		_arc_widths.append(randf_range(0.55, 1.25))
		# Anchors sit on a slowly turning ring so the arcs wander around the hand
		var spin: float = _time * 0.8
		var a0: float = spin + TAU * (float(i) / float(max(arc_count, 1))) + randf_range(-0.3, 0.3)
		var a1: float = a0 + randf_range(1.8, 3.4)
		var r0: float = arc_radius * randf_range(0.55, 1.0)
		var r1: float = arc_radius * randf_range(0.55, 1.0)
		_arcs.append(_make_arc(Vector2(cos(a0), sin(a0)) * r0, Vector2(cos(a1), sin(a1)) * r1))

func _make_arc(from: Vector2, to: Vector2) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var perpendicular: Vector2 = (to - from).rotated(PI / 2.0).normalized()
	for i in range(arc_segments + 1):
		var t: float = float(i) / float(arc_segments)
		# Envelope pins the arc to both anchors and lets it bow in the middle
		var envelope: float = sin(t * PI)
		var offset: float = randf_range(-arc_jitter, arc_jitter) * envelope
		pts.append(from.lerp(to, t) + perpendicular * offset)
	return pts

func _draw() -> void:
	for i in range(_arcs.size()):
		var arc: PackedVector2Array = _arcs[i]
		if arc.size() < 2:
			continue
		var w: float = thickness * _arc_widths[i]
		# draw_polyline() is a single uniform width end to end, which reads as a
		# fat bar. Stepping segment by segment lets the filament taper out at
		# both anchors and swell in the middle.
		_draw_tapered(arc, glow_color, w * 2.4)
		_draw_tapered(arc, core_color, w)

func _draw_tapered(pts: PackedVector2Array, col: Color, max_width: float) -> void:
	var span := float(max(1, pts.size() - 1))
	for i in range(pts.size() - 1):
		var t: float = (float(i) + 0.5) / span
		# sin() envelope: thinnest where the arc meets its anchors
		var w: float = max_width * (end_taper + (1.0 - end_taper) * sin(t * PI))
		draw_line(pts[i], pts[i + 1], col, max(w, 0.1), true)
