# res://CellScorchFX.gd
# Persistent ground char for cell fires -- the render half of the editor's
# scorch port. The editor stamps char directly into its ground bake
# (FireSim._damage -> Main._stamp_char -> ravine alpha channel, consumed by
# ground_paint.gdshader); TFA's structured ground is a baked PNG it cannot
# rewrite, so this layer draws the same wobbly char stamps OVER it instead.
# Sits at z -5 under MapLoader: above the ground sprite (-6), below floors
# (-4) / structures (-3) / the z-0 flame FX. Known limitation: standing water
# is composited inside the ground sprite's material (water_surface.gdshader),
# so char draws over water rather than under it -- rare overlap (water douses
# fire), lives with it until the scorch texture is fed into the water shader.
#
# CHUNKED: stamps land in 256px-bucket child canvas items, so deepening one
# cell re-triangulates only its chunk (a map-wide burn used to rebuild every
# historical stamp on each new one -- review find), and chunks far offscreen
# rect-cull wholesale instead of re-walking the whole burn history per frame.
class_name CellScorchFX
extends Node2D

# editor ground_paint.gdshader char_col
const CHAR_COL := Color(0.11, 0.095, 0.075)
const SEGS := 14
const CHUNK := 256.0

var graph: CellGraph
var _chark: Dictionary = {}    # cid -> {"k": char depth 0..1, "seed": float}
var _chunks: Dictionary = {}   # Vector2i bucket -> Chunk


class Chunk extends Node2D:
	var fx: CellScorchFX
	var cells: Dictionary = {}   # cid -> true

	func _draw() -> void:
		for cid in cells:
			fx._draw_stamp(self, cid)


func setup(p_graph: CellGraph) -> void:
	graph = p_graph
	_chark.clear()
	for key in _chunks:
		_chunks[key].queue_free()
	_chunks.clear()


# Deepen a cell's char to k. Monotonic max is enforced HERE because douse
# erases the burning entry without setting burnt: a doused-then-reignited cell
# restarts its progressive char at 0.22 and must not stamp lighter over the
# deeper char it already earned.
func stamp(cid: int, k: float, sd: float) -> void:
	var prev = _chark.get(cid)
	if prev != null and float(prev["k"]) >= k:
		return
	_chark[cid] = {"k": k, "seed": sd}
	var p := graph.centroid(cid)
	var key := Vector2i(int(floorf(p.x / CHUNK)), int(floorf(p.y / CHUNK)))
	var ch: Chunk = _chunks.get(key)
	if ch == null:
		ch = Chunk.new()
		ch.fx = self
		add_child(ch)
		_chunks[key] = ch
	ch.cells[cid] = true
	ch.queue_redraw()


# One cell's stamp, drawn onto its chunk: the editor's disk with wobbly rim
# edge = r*(0.72+0.28*sin(ang*5+seed*40)) and a smooth falloff, faked with
# three nested fans; overlapping neighbour stamps fuse into a burn field.
func _draw_stamp(canvas: CanvasItem, cid: int) -> void:
	var e: Dictionary = _chark[cid]
	var k: float = e["k"]
	var sd: float = e["seed"]
	var p: Vector2 = graph.centroid(cid)
	var r: float = graph.radius(cid) * 1.5
	_splat(canvas, p, r, sd, Color(CHAR_COL.r, CHAR_COL.g, CHAR_COL.b, 0.30 * k))
	_splat(canvas, p, r * 0.78, sd, Color(CHAR_COL.r, CHAR_COL.g, CHAR_COL.b, 0.30 * k))
	_splat(canvas, p, r * 0.52, sd, Color(CHAR_COL.r * 0.85, CHAR_COL.g * 0.85, CHAR_COL.b * 0.85, 0.35 * k))


func _splat(canvas: CanvasItem, p: Vector2, r: float, sd: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in SEGS:
		var ang := TAU * float(i) / float(SEGS)
		var wob := 0.72 + 0.28 * sin(ang * 5.0 + sd * 40.0)
		pts.append(p + Vector2(cos(ang), sin(ang)) * r * wob)
	canvas.draw_colored_polygon(pts, col)
