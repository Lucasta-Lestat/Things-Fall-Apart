# res://Global/CellGraph.gd
# The cell-graph abstraction the ported simulations (fire now; fluids next) run
# on. Two backings satisfy one interface so there is a single sim codebase:
#   - STRUCTURED maps (procedural level-editor exports) supply the irregular
#     Stalberg cell graph, loaded verbatim from <id>_cells.json (exported as
#     DATA to dodge cross-build float-determinism drift).
#   - LEGACY maps (hand/LLM-made images) supply a trivial SQUARE-TILE graph:
#     one cell per GridManager tile, 4-neighbours, tile-centre centroid.
# Interface: cell_count, centroid(id), radius(id), neighbors(id),
# ground_fuel(id), cell_at(world_pos). All coordinates are world pixels.
class_name CellGraph
extends RefCounted

var cell_count: int = 0
var _cx: PackedFloat32Array = PackedFloat32Array()
var _cy: PackedFloat32Array = PackedFloat32Array()
var _r: PackedFloat32Array = PackedFloat32Array()
var _fuel: PackedFloat32Array = PackedFloat32Array()   # structured: baked; square: unused
var _elev: PackedFloat32Array = PackedFloat32Array()   # signed ground elevation, stories (fluid head); square: flat 0
var _roof: PackedFloat32Array = PackedFloat32Array()   # roof surface height, stories (0 = unroofed); the jump layer
var _nb_off: PackedInt32Array = PackedInt32Array()
var _nb: PackedInt32Array = PackedInt32Array()
var _square: bool = false
var _cols: int = 0
var _rows: int = 0
var _tile: int = 64
# spatial acceleration for structured cell_at: cell ids bucketed by a coarse grid
var _bucket_size: float = 128.0
var _buckets: Dictionary = {}   # Vector2i -> PackedInt32Array of cell ids
var _bmin: Vector2i = Vector2i.ZERO
var export_scale: float = 1.0   # world units -> export px (structured); the water shader
                                # divides its Wn back to world units so waves match the editor


# Load the Stalberg graph from the exported companion file. Returns "" or error.
static func from_structured(path: String) -> CellGraph:
	if not FileAccess.file_exists(path):
		push_error("CellGraph: cell graph not found at " + path)
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(data) != TYPE_DICTIONARY or not data.has("nb_off"):
		push_error("CellGraph: malformed cell graph " + path)
		return null
	var g := CellGraph.new()
	g.cell_count = int(data.get("n", 0))
	g.export_scale = float(data.get("export_scale", 1.0))
	g._cx = _to_f32(data.get("cx", []))
	g._cy = _to_f32(data.get("cy", []))
	g._r = _to_f32(data.get("r", []))
	g._fuel = _to_f32(data.get("fuel", []))
	g._elev = _to_f32(data.get("elev", []))
	g._roof = _to_f32(data.get("roof", []))   # absent in legacy exports -> empty -> roof_elev 0
	g._nb_off = _to_i32(data.get("nb_off", []))
	g._nb = _to_i32(data.get("nb", []))
	g._build_buckets()
	return g


# Build a square-tile graph over the initialised GridManager (legacy maps).
static func from_square_tiles() -> CellGraph:
	var g := CellGraph.new()
	g._square = true
	g._tile = GridManager.TILE_SIZE
	g._cols = GridManager.map_rect.size.x
	g._rows = GridManager.map_rect.size.y
	g.cell_count = g._cols * g._rows
	return g


# --- interface ---------------------------------------------------------------

func centroid(cid: int) -> Vector2:
	if _square:
		return Vector2((cid % _cols + 0.5) * _tile, (cid / _cols + 0.5) * _tile)
	if cid < 0 or cid >= _cx.size():
		return Vector2.ZERO
	return Vector2(_cx[cid], _cy[cid])


func radius(cid: int) -> float:
	if _square:
		return _tile * 0.5
	return _r[cid] if cid >= 0 and cid < _r.size() else 32.0


func neighbors(cid: int) -> Array:
	var out: Array = []
	if _square:
		var tx := cid % _cols
		var ty := cid / _cols
		if tx > 0: out.append(cid - 1)
		if tx < _cols - 1: out.append(cid + 1)
		if ty > 0: out.append(cid - _cols)
		if ty < _rows - 1: out.append(cid + _cols)
		return out
	if cid < 0 or cid + 1 >= _nb_off.size():
		return out
	for i in range(_nb_off[cid], _nb_off[cid + 1]):
		out.append(_nb[i])
	return out


# STATIC ground fuel (0 = firebreak). Structured maps ship it per cell; square
# maps derive it from the tile's floor flammability (FloorDatabase). Structures
# and fluids are combined on top by the sim, not here.
func ground_fuel(cid: int) -> float:
	if not _square:
		return _fuel[cid] if cid >= 0 and cid < _fuel.size() else 0.0
	var tile := Vector2i(cid % _cols, cid / _cols)
	var fid = GridManager.floors.get(tile, "")
	if fid == "":
		return 0.0
	var fdef = FloorDatabase.floor_definitions.get(fid)
	if fdef == null:
		return 0.0
	return 1.0 if fdef.flammable else 0.0


# Signed ground elevation in STORIES (0 = ground, <0 ravine/crater). The fluid
# sim's downhill substrate. Legacy square-tile maps have no height field -> flat.
func ground_elev(cid: int) -> float:
	if _square:
		return 0.0
	return _elev[cid] if cid >= 0 and cid < _elev.size() else 0.0


# Roof surface height in STORIES over this cell (0 = unroofed). A separate
# stacked layer — NEVER folded into ground_elev (interiors keep ground height).
func roof_elev(cid: int) -> float:
	if _square:
		return 0.0
	return _roof[cid] if cid >= 0 and cid < _roof.size() else 0.0


func cell_at(world_pos: Vector2) -> int:
	if _square:
		var tx := int(floor(world_pos.x / _tile))
		var ty := int(floor(world_pos.y / _tile))
		if tx < 0 or ty < 0 or tx >= _cols or ty >= _rows:
			return -1
		return ty * _cols + tx
	# nearest centroid in the point's bucket + 8 neighbours
	var b := Vector2i(int(floor(world_pos.x / _bucket_size)), int(floor(world_pos.y / _bucket_size)))
	var best := -1
	var bestd := INF
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var key := b + Vector2i(dx, dy)
			if not _buckets.has(key):
				continue
			for cid in _buckets[key]:
				var d := world_pos.distance_squared_to(Vector2(_cx[cid], _cy[cid]))
				if d < bestd:
					bestd = d
					best = cid
	return best


# --- internals ---------------------------------------------------------------

func _build_buckets() -> void:
	for cid in cell_count:
		var key := Vector2i(int(floor(_cx[cid] / _bucket_size)), int(floor(_cy[cid] / _bucket_size)))
		if not _buckets.has(key):
			_buckets[key] = PackedInt32Array()
		_buckets[key].append(cid)


static func _to_f32(a) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if typeof(a) == TYPE_ARRAY:
		out.resize(a.size())
		for i in a.size():
			out[i] = float(a[i])
	return out


static func _to_i32(a) -> PackedInt32Array:
	var out := PackedInt32Array()
	if typeof(a) == TYPE_ARRAY:
		out.resize(a.size())
		for i in a.size():
			out[i] = int(a[i])
	return out
