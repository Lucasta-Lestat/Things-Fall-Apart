# res://CellFluid.gd
# PORT of the editor's Stalberg-cell fluid sim (Terrain Generation/scripts/
# FluidSim.gd, itself a port of this project's FluidManager) BACK onto the cell
# graph so structured maps get real downhill flow: water runs to low ground,
# pools in ravines/craters, streams along gully floors -- instead of the flat
# tile puddle-equalisation FluidManager does. Runs ALONGSIDE the tile grid
# exactly like CellFire: FluidManager owns a CellFluid on structured maps,
# ticks it, and PROJECTS cell depths onto the existing tile renderer + query
# grid so every tile-keyed consumer (footsteps, extinguish, conductivity,
# oil-as-fuel) keeps working unchanged.
#
# Semantics kept from FluidManager/FluidSim: depth per cell; each SIM_INTERVAL a
# wet cell pushes toward lower PRESSURE (head), transfer capped at HALF the
# difference so bodies settle level; a deadband stops settled ponds churning;
# outflow leaves a puddle film; everything evaporates; ONE fluid type per cell
# (a different type arriving wipes the old); budgeted outflow (never over-drain).
# Downhill: head = fluid column + ground_elev*HEAD_PER_STORY (CellGraph.ground_elev).
# Edge blocking: a wall/structure obstacle tile on the centroid->centroid path
# stops flow (GridManager.walls; refcounted, so a destroyed wall re-opens once
# invalidate_edges() is called). Water<->fire and oil-as-fuel are bridged by
# FluidManager/CellFire, not here.
class_name CellFluid
extends Node2D

const PUDDLE := 0.01             # min renderable/queryable depth (FluidManager PUDDLE_HEIGHT)
const MIN_FLOW := 0.001
const DRY := 0.0005             # cull threshold, below MIN_FLOW (mass conservation)
const EPSILON := 0.006          # head deadband
const EVAP_PER_SEC := 0.002
const FLOW_RATE_PER_SEC := 0.9  # matches editor cfg.fluid_flow_rate (tile 0.05 was flat-ground equalisation)
const HEAD_PER_STORY := 1.6     # stories -> depth units (matches editor cfg.fluid_head_per_story)
const SIM_INTERVAL := 0.25
const VISUAL_FLOW_MIN := 0.03

var graph: CellGraph
var fm: Node                     # FluidManager (fluid db + fire bridge live there)
var _order: Array = []           # fluid type strings; index+1 == ftype byte (water == 1)
var _db: Dictionary = {}         # type string -> fluids.json def

var amount: PackedFloat32Array = PackedFloat32Array()   # depth per cell
var ftype: PackedByteArray = PackedByteArray()          # 0 = dry, else _order index + 1
var active: Dictionary = {}      # cid -> true
var flow_dir: Dictionary = {}    # cid -> normalized outflow dir (last tick)
var flow_speed: Dictionary = {}  # cid -> outflow fraction 0..1
var sources: Array = []          # {cid, ti, rate} continuous emitters (authored springs)

var _timer := 0.0
var _ti_water := 1                                      # ftype byte of water (water is _order[0])
var _ground: PackedFloat32Array = PackedFloat32Array()  # cached ground head (NAN = not derived)
var _edge_cache: Dictionary = {}                        # cid -> PackedByteArray per neighbour (1 = open)
var _nb_cache: Array = []                               # cid -> neighbour Array (avoid per-tick alloc)


func setup(p_graph: CellGraph, p_fm: Node, fluid_db: Dictionary, order: Array) -> void:
	graph = p_graph
	fm = p_fm
	_db = fluid_db
	_order = order
	var n := graph.cell_count if graph != null else 0
	amount = PackedFloat32Array(); amount.resize(n)
	ftype = PackedByteArray(); ftype.resize(n)
	_ground = PackedFloat32Array(); _ground.resize(n); _ground.fill(NAN)
	active.clear(); flow_dir.clear(); flow_speed.clear(); sources.clear()
	_edge_cache.clear()
	_ti_water = _ti_of("water")
	# cache neighbour lists once (CellGraph.neighbors builds a fresh Array per call)
	_nb_cache = []
	_nb_cache.resize(n)
	for cid in n:
		_nb_cache[cid] = graph.neighbors(cid)


func active_sim() -> bool:
	return graph != null and graph.cell_count > 0


# --- public API (mirrors FluidSim; FluidManager routes deposits/queries here) --

# Deposit `depth` of type `ti_or_str` at the cell under a world point (a
# different type wipes the old -- register_fluid semantics).
func deposit(world_pos: Vector2, type_str: String, depth: float) -> void:
	var ti := _ti_of(type_str)
	if ti <= 0 or depth <= 0.0:
		return
	var cid := graph.cell_at(world_pos)
	if cid >= 0:
		_add(cid, ti, depth)


# Pour over a world radius (fluid_spawns with radius): fall-off toward the rim.
func pour(center: Vector2, type_str: String, depth: float, radius: float) -> int:
	var ti := _ti_of(type_str)
	if ti <= 0 or depth <= 0.0:
		return 0
	var n := 0
	for cid in graph.cell_count:
		var d := graph.centroid(cid).distance_to(center)
		if d > radius:
			continue
		_add(cid, ti, depth * (1.0 - 0.6 * d / maxf(radius, 1.0)))
		n += 1
	return n


func add_source(world_pos: Vector2, type_str: String, rate: float) -> void:
	var ti := _ti_of(type_str)
	if ti <= 0:
		return
	var cid := graph.cell_at(world_pos)
	if cid >= 0:
		sources.append({"cid": cid, "ti": ti, "rate": rate})


func clear_all() -> void:
	for cid in active:
		amount[cid] = 0.0
		ftype[cid] = 0
	active.clear(); flow_dir.clear(); flow_speed.clear(); sources.clear()


# Remove fluid from every cell projecting into a tile (freeze: the tile's water
# became ice, so the cells must empty or the projection re-floods it next tick).
func drain_tile(tile: Vector2i) -> void:
	var drop: Array = []
	for cid in active:
		if GridManager.world_to_map(graph.centroid(cid)) == tile:
			drop.append(cid)
	for cid in drop:
		amount[cid] = 0.0
		ftype[cid] = 0
		active.erase(cid)
		flow_dir.erase(cid)
		flow_speed.erase(cid)


# A destroyed wall un-refcounts its obstacle tiles -> re-derive edge blocking so
# fluid can flow through the breach. Called from Game._on_structure_destroyed.
func invalidate_edges() -> void:
	_edge_cache.clear()


# --- fire bridge (CellFire._compute_fuel consults these) ---------------------

func amount_at(cid: int) -> float:
	return amount[cid] if cid >= 0 and cid < amount.size() else 0.0


func type_at(cid: int) -> String:
	if cid < 0 or cid >= ftype.size() or ftype[cid] == 0:
		return ""
	return _order[ftype[cid] - 1] if ftype[cid] - 1 < _order.size() else ""


func is_flammable_at(cid: int) -> bool:
	var t := type_at(cid)
	return t != "" and _db.get(t, {}).get("flammable", false)


func is_conductive_at(cid: int) -> bool:
	var t := type_at(cid)
	return t != "" and _db.get(t, {}).get("conductive", false)


# Fire consumes the flammable fluid it burns on (CellFire calls this).
func burn_off(cid: int, amt: float) -> void:
	if cid < 0 or cid >= ftype.size() or not is_flammable_at(cid):
		return
	amount[cid] = maxf(0.0, amount[cid] - amt)
	if amount[cid] < DRY:
		amount[cid] = 0.0
		ftype[cid] = 0
		active.erase(cid)


# --- simulation --------------------------------------------------------------

func tick(delta: float) -> void:
	for s in sources:
		_add(int(s["cid"]), int(s["ti"]), float(s["rate"]) * delta)
	if active.is_empty():
		return
	_timer += delta
	if _timer < SIM_INTERVAL:
		return
	_timer = 0.0
	_flow_tick()
	_fire_interactions()


# Water on a burning cell extinguishes it -- doused on the EXACT cell id (fire
# shares this CellGraph), no tile round-trip that could resolve to a neighbour.
func _fire_interactions() -> void:
	var cf = _cell_fire()
	if cf == null or cf.burning.is_empty():
		return
	for cid in active:
		if ftype[cid] == _ti_water and amount[cid] > PUDDLE and cf.burning.has(cid):
			cf.douse(cid)


func _cell_fire():
	if fm == null:
		return null
	var game = fm.get_parent()
	if game == null or not ("surface_manager" in game) or game.surface_manager == null:
		return null
	return game.surface_manager.cell_fire


func _flow_tick() -> void:
	var rate_tick := FLOW_RATE_PER_SEC * SIM_INTERVAL
	var evap_tick := EVAP_PER_SEC * SIM_INTERVAL
	var deltas: Dictionary = {}
	flow_dir.clear(); flow_speed.clear()
	for cid in active:
		var amt := amount[cid]
		var ti := ftype[cid]
		_delta_add(deltas, cid, ti, -evap_tick)
		if amt < PUDDLE:
			continue
		var visc := _visc(ti)
		var head := _head(cid)
		var press := amt - PUDDLE
		var avail := press
		var vect := Vector2.ZERO
		var out_total := 0.0
		var cc := graph.centroid(cid)
		var nbs: Array = _nb_cache[cid]
		var opens := _edges(cid)
		for j in nbs.size():
			if avail <= MIN_FLOW:
				break
			if j < opens.size() and opens[j] == 0:
				continue
			var nb: int = nbs[j]
			var diff := head - _head(nb)
			if diff <= EPSILON:
				continue
			var fa := minf(minf(
				amt * rate_tick * (diff / (press + 0.1)) / visc,
				diff * 0.5), avail)
			if fa <= MIN_FLOW:
				continue
			avail -= fa
			_delta_add(deltas, cid, ti, -fa)
			_delta_add(deltas, nb, ti, fa)
			var dirn := (graph.centroid(nb) - cc).normalized()
			vect += dirn * fa
			out_total += fa
		if out_total > 0.0:
			var spd := clampf(out_total / maxf(amt, 0.001), 0.0, 1.0)
			if spd >= VISUAL_FLOW_MIN:
				flow_dir[cid] = vect.normalized()
				flow_speed[cid] = spd
	# apply: all DEBITS first (each charged only to the type it was booked against),
	# THEN the credits -- cross-type fronts must not depend on Dictionary order
	for cid in deltas:
		var per: Dictionary = deltas[cid]
		for ti in per:
			var d: float = per[ti]
			if d < 0.0 and ftype[cid] == int(ti):
				amount[cid] = maxf(0.0, amount[cid] + d)
	for cid in deltas:
		var per: Dictionary = deltas[cid]
		for ti in per:
			var d: float = per[ti]
			if d > 0.0:
				_add(cid, int(ti), d)
	# cull dried cells
	var drop: Array = []
	for cid in active:
		if amount[cid] < DRY:
			drop.append(cid)
	for cid in drop:
		amount[cid] = 0.0
		ftype[cid] = 0
		active.erase(cid)
		flow_dir.erase(cid)
		flow_speed.erase(cid)


# --- internals ---------------------------------------------------------------

func _add(cid: int, ti: int, amt: float) -> void:
	if amt <= 0.0 or cid < 0 or cid >= amount.size():
		return
	if ftype[cid] != 0 and ftype[cid] != ti:
		amount[cid] = 0.0    # a different type arriving wipes the old (register_fluid)
	ftype[cid] = ti
	amount[cid] += amt
	active[cid] = true


func _delta_add(deltas: Dictionary, cid: int, ti: int, d: float) -> void:
	if not deltas.has(cid):
		deltas[cid] = {}
	var per: Dictionary = deltas[cid]
	per[ti] = float(per.get(ti, 0.0)) + d


func _head(cid: int) -> float:
	return _ground_head(cid) + maxf(amount[cid] - PUDDLE, 0.0)


func _ground_head(cid: int) -> float:
	var g := _ground[cid]
	if is_nan(g):
		g = graph.ground_elev(cid) * HEAD_PER_STORY
		_ground[cid] = g
	return g


# Per-neighbour open/blocked flags (1 = open): an obstacle tile (wall/structure)
# on the centroid->centroid path stops flow. Uses GridManager.walls (refcounted),
# cached; invalidate_edges() clears the cache when a wall is destroyed.
func _edges(cid: int) -> PackedByteArray:
	if _edge_cache.has(cid):
		return _edge_cache[cid]
	var nbs: Array = _nb_cache[cid]
	var e := PackedByteArray()
	e.resize(nbs.size())
	e.fill(1)
	var cc := graph.centroid(cid)
	for j in nbs.size():
		var nc := graph.centroid(nbs[j])
		if _blocked_between(cc, nc):
			e[j] = 0
	_edge_cache[cid] = e
	return e


# Sample tiles along the segment; blocked if any is a standing obstacle. Cheap
# and matches what movement collides with (the same GridManager obstacle tiles).
func _blocked_between(a: Vector2, b: Vector2) -> bool:
	var steps := int(ceil(a.distance_to(b) / (GridManager.TILE_SIZE * 0.5))) + 1
	for i in range(1, steps):
		var p := a.lerp(b, float(i) / float(steps))
		if GridManager.walls.get(GridManager.world_to_map(p), false):
			return true
	return false


func _ti_of(type_str: String) -> int:
	var i := _order.find(type_str)
	return i + 1 if i >= 0 else 0


func _visc(ti: int) -> float:
	if ti <= 0 or ti - 1 >= _order.size():
		return 1.0
	var t: String = _order[ti - 1]
	# data/fluids.json omits oil's viscosity (its shader defaulted to 1.0); a
	# slick that runs like water reads wrong on slopes -- give it a syrupy crawl,
	# matching the editor's FluidDefs override.
	var dflt: float = 1.8 if t == "oil" else 1.0
	return float(_db.get(t, {}).get("viscosity", dflt))
