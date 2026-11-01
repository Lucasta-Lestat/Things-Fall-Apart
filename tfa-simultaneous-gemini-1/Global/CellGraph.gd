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
# Optional per-TILE terrain (cells.json "tile_elev": {cols, rows, data}): ABSOLUTE
# stories at each 64px tile centre, row-major. Terrain-editor exports write it
# when the map has a heightfield; nearest-centroid projection of `elev` amplifies
# graded steps (a 0.44-story street step reads 0.7+ when two cells straddle a
# tile), so GridManager prefers this grid when its size matches the map.
# Empty (cols 0) on every legacy export.
var _tile_elev: PackedFloat32Array = PackedFloat32Array()
var _te_cols: int = 0
var _te_rows: int = 0
# Optional per-TILE open water (cells.json "tile_water" + "tile_body", export
# contract 3, P3-A): the water surface in ABSOLUTE stories and the water body
# id (0 = no open water; tile_water is 0 there), the same {cols, rows, data}
# shape and row-major order as tile_elev. The pair travels together: a
# malformed or mismatched pair is dropped whole. Empty on contract-1/2 exports,
# where GridManager falls back to its deep-water rule.
var _tile_water: PackedFloat32Array = PackedFloat32Array()
var _tile_body: PackedInt32Array = PackedInt32Array()
var _tw_cols: int = 0
var _tw_rows: int = 0
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
	var te = data.get("tile_elev", null)
	if typeof(te) == TYPE_DICTIONARY:
		var tc: int = int(te.get("cols", 0))
		var tr: int = int(te.get("rows", 0))
		var td: PackedFloat32Array = _to_f32(te.get("data", []))
		if tc > 0 and tr > 0 and td.size() == tc * tr:
			g._tile_elev = td
			g._te_cols = tc
			g._te_rows = tr
		else:
			push_warning("CellGraph: malformed tile_elev in %s (cols=%d rows=%d data=%d); using nearest-cell elev"
				% [path, tc, tr, td.size()])
	var tw = data.get("tile_water", null)
	var tb = data.get("tile_body", null)
	if typeof(tw) == TYPE_DICTIONARY and typeof(tb) == TYPE_DICTIONARY:
		var wc: int = int(tw.get("cols", 0))
		var wr: int = int(tw.get("rows", 0))
		var wd: PackedFloat32Array = _to_f32(tw.get("data", []))
		var bd: PackedInt32Array = _to_i32(tb.get("data", []))
		if wc > 0 and wr > 0 and int(tb.get("cols", 0)) == wc and int(tb.get("rows", 0)) == wr \
				and wd.size() == wc * wr and bd.size() == wc * wr:
			g._tile_water = wd
			g._tile_body = bd
			g._tw_cols = wc
			g._tw_rows = wr
		else:
			push_warning("CellGraph: malformed tile_water/tile_body in %s (cols=%d rows=%d data=%d/%d); using the deep-water rule"
				% [path, wc, wr, wd.size(), bd.size()])
	elif typeof(tw) == TYPE_DICTIONARY or typeof(tb) == TYPE_DICTIONARY:
		push_warning("CellGraph: %s has only one of tile_water/tile_body; using the deep-water rule" % path)
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
		var baked: float = _fuel[cid] if cid >= 0 and cid < _fuel.size() else 0.0
		if baked > 0.0 or cid < 0 or cid >= _cx.size():
			return baked
		# The terrain editor bakes fuel 0 under every BUILT floor (it gates
		# scatter and fuel off floor rects), so a parquet floor exported as a
		# firebreak and fireballs never spread indoors. The registered floor
		# (MapLoader's per-tile codes -> FloorDatabase) decides instead: wood
		# burns, stone/dirt/water stay breaks.
		return _floor_fuel(GridManager.world_to_map(Vector2(_cx[cid], _cy[cid])))
	return _floor_fuel(Vector2i(cid % _cols, cid / _cols))


# 1.0 when the floor registered on `tile` is flammable (FloorDatabase), else 0.
func _floor_fuel(tile: Vector2i) -> float:
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


# Per-tile terrain grid (see _tile_elev). True only when the grid exists AND is
# exactly cols x rows — the caller passes the map's tile dims, so a stale or
# differently-sized export can never be indexed against the wrong tiles.
func has_tile_elev(cols: int, rows: int) -> bool:
	return _te_cols > 0 and _te_cols == cols and _te_rows == rows


# The grid's own dims (Vector2i.ZERO when the export has none).
func tile_elev_dims() -> Vector2i:
	return Vector2i(_te_cols, _te_rows)


# ABSOLUTE terrain stories at tile t. Out-of-grid tiles read 0.0.
func tile_elev(t: Vector2i) -> float:
	if t.x < 0 or t.y < 0 or t.x >= _te_cols or t.y >= _te_rows:
		return 0.0
	return _tile_elev[t.y * _te_cols + t.x]


# The open-water pair (see _tile_water). True only when it exists AND is exactly
# cols x rows, like has_tile_elev.
func has_tile_water(cols: int, rows: int) -> bool:
	return _tw_cols > 0 and _tw_cols == cols and _tw_rows == rows


func tile_water_dims() -> Vector2i:
	return Vector2i(_tw_cols, _tw_rows)


# The pair's row-major data (packed arrays copy on write, so GridManager keeps
# them for the map without a deep copy).
func tile_water_data() -> PackedFloat32Array:
	return _tile_water


func tile_body_data() -> PackedInt32Array:
	return _tile_body


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


# Cells whose centroid lies within `radius` of `center` (AoE ignition and the
# like), ascending id. Bucket-bounded on structured maps and a tile-range scan
# on square maps -- never a walk of all cell_count cells per query.
func cells_within(center: Vector2, radius: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	if radius < 0.0:
		return out
	var r2 := radius * radius
	if _square:
		var tx0 := maxi(int(floor((center.x - radius) / _tile)), 0)
		var tx1 := mini(int(floor((center.x + radius) / _tile)), _cols - 1)
		var ty0 := maxi(int(floor((center.y - radius) / _tile)), 0)
		var ty1 := mini(int(floor((center.y + radius) / _tile)), _rows - 1)
		for ty in range(ty0, ty1 + 1):
			for tx in range(tx0, tx1 + 1):
				var cid := ty * _cols + tx
				if centroid(cid).distance_squared_to(center) <= r2:
					out.append(cid)
		return out
	var bx0 := int(floor((center.x - radius) / _bucket_size))
	var bx1 := int(floor((center.x + radius) / _bucket_size))
	var by0 := int(floor((center.y - radius) / _bucket_size))
	var by1 := int(floor((center.y + radius) / _bucket_size))
	for by in range(by0, by1 + 1):
		for bx in range(bx0, bx1 + 1):
			var key := Vector2i(bx, by)
			if not _buckets.has(key):
				continue
			for cid in _buckets[key]:
				var dx: float = _cx[cid] - center.x
				var dy: float = _cy[cid] - center.y
				if dx * dx + dy * dy <= r2:
					out.append(cid)
	out.sort()
	return out


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
