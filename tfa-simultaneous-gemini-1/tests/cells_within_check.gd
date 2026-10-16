extends Node2D
# CellGraph.cells_within regression: the bucket-bounded query must return
# exactly the cells a brute-force centroid scan does, on BOTH graph kinds
# (structured Stalberg cells and the legacy square-tile adapter), including
# radii that straddle bucket/tile edges and points off the map.
# Headless:  godot --headless --path . res://tests/cells_within_check.tscn
var fails := 0
var checks := 0


func _check(name: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if not ok:
		fails += 1
		print("FAIL ", name, "  ", detail)


func _brute(g: CellGraph, c: Vector2, r: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	for cid in g.cell_count:
		if g.centroid(cid).distance_to(c) <= r:
			out.append(cid)
	return out


func _compare(label: String, g: CellGraph, c: Vector2, r: float) -> void:
	var a := g.cells_within(c, r)
	var b := _brute(g, c, r)
	_check(label, a == b, "query %d vs brute %d at %s r=%.1f" % [a.size(), b.size(), str(c), r])


func _ready() -> void:
	var f := FileAccess.open("res://data/Maps.json", FileAccess.READ)
	var raw: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	var m: Dictionary = {}
	for e in raw.get("maps", []):
		if String(e.get("id", "")) == "tg_cemetery":
			m = e
			break
	GridManager.TILE_SIZE = int(m.get("tile_size", 64))
	var ws: Array = m.get("world_size", [2048, 2048])
	GridManager.initialize(int(ws[0]), int(ws[1]))
	var sg: CellGraph = CellGraph.from_structured(String(m.get("cell_graph", "")))
	_check("structured.loaded", sg != null and sg.cell_count > 0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 40:
		var c := Vector2(rng.randf_range(-100.0, float(ws[0]) + 100.0), rng.randf_range(-100.0, float(ws[1]) + 100.0))
		_compare("structured.%d" % i, sg, c, rng.randf_range(0.0, 400.0))
	_compare("structured.zero", sg, sg.centroid(10), 0.0)
	_compare("structured.negative", sg, sg.centroid(10), -5.0)
	var qg := CellGraph.from_square_tiles()
	_check("square.loaded", qg.cell_count > 0)
	for i in 40:
		var c := Vector2(rng.randf_range(-100.0, float(ws[0]) + 100.0), rng.randf_range(-100.0, float(ws[1]) + 100.0))
		_compare("square.%d" % i, qg, c, rng.randf_range(0.0, 400.0))
	_compare("square.zero", qg, qg.centroid(5), 0.0)
	_compare("square.edge", qg, Vector2.ZERO, 64.0)
	print("cells_within_check: %d checks, %d FAIL" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)
