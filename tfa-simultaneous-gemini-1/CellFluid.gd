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
# outflow leaves a per-type minimum pool (water: thin film, oil: thick slick);
# per-type evaporation (oil: none); ONE fluid type per cell (a different type
# arriving wipes the old, unless deposited politely); budgeted outflow.
# Downhill: head = fluid column + ground_elev*HEAD_PER_STORY (CellGraph.ground_elev).
# Edge blocking: a wall/structure obstacle tile on the centroid->centroid path
# stops flow (GridManager.walls; refcounted, so a destroyed wall re-opens once
# invalidate_edges() is called). Water<->fire and oil-as-fuel are bridged by
# FluidManager/CellFire, not here.
# Sea drain (P3-A, maps whose water_sim is "sink"): setup_sinks() tags every
# cell whose centroid tile is open water (GridManager.water_surface_at) as a
# SINK. A sink holds a FIXED head at its body's surface, is never in `active`
# (so it never flows, evaporates or meets fire), and whatever flows, deposits,
# pours or springs into it is deleted at once and counted in `drained`. Shore
# and deck cells below a sink's head that could not drain otherwise are raised
# to the level they spill at (beside one body, its waterline) so they shed into
# it instead of trapping. Only wet cells are iterated, so the cost scales with
# the spill, not the sea.
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
const HEAD_EPS := 1e-4          # ground-head ties (the waterline clamp's spill test)

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
var sink: PackedByteArray = PackedByteArray()          # cid -> 1 = sink; EMPTY on maps without
var sink_count := 0
var waterline_count := 0                               # shore/deck cells setup_sinks raised to their spill level
var drained: PackedFloat64Array = PackedFloat64Array() # per ftype byte: mass the sinks deleted
# Mass ledger (tests/fluid_sink_bench closes it): poured = what is in the cells
# + drained + evaporated + lost. Bookkeeping only: the sim never reads it.
var mass_poured := 0.0        # deposit / pour / sources
var mass_evaporated := 0.0    # evaporation and the dried-cell cull
var mass_lost := 0.0          # wiped by another type, dropped cross-type fronts, burned, frozen, cleared

var _timer := 0.0
var _ti_water := 1                                      # ftype byte of water (water is _order[0])
var _ground: PackedFloat32Array = PackedFloat32Array()  # cached ground head (NAN = not derived)
var _edge_cache: Dictionary = {}                        # cid -> PackedByteArray per neighbour (1 = open)
var _nb_cache: Array = []                               # cid -> neighbour Array (avoid per-tick alloc)
var _heap_key: PackedFloat32Array = PackedFloat32Array() # the clamp's priority flood: a binary min-heap
var _heap_cid: PackedInt32Array = PackedInt32Array()     # of (spill level, cid), stale entries skipped


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
	sink = PackedByteArray()
	sink_count = 0
	waterline_count = 0
	drained = PackedFloat64Array(); drained.resize(_order.size() + 1)
	mass_poured = 0.0; mass_evaporated = 0.0; mass_lost = 0.0
	_ti_water = _ti_of("water")
	# cache neighbour lists once (CellGraph.neighbors builds a fresh Array per call)
	_nb_cache = []
	_nb_cache.resize(n)
	for cid in n:
		_nb_cache[cid] = graph.neighbors(cid)


func active_sim() -> bool:
	return graph != null and graph.cell_count > 0


# Tag the sea drain's sinks (FluidManager calls it right after setup on a map
# whose water_sim is "sink"). A cell is a sink when its centroid tile is open
# water, except under a walkable deck: a deck is never a sink, so a deposit on
# a pier or bridge is not deleted on landing (above its puddle film it sheds
# into the sea like the shore, below). The sink's fixed head is its body
# surface, held in its cached ground head: its amount stays 0, so _head()
# reads exactly that.
# Then the waterline clamp (_clamp_waterline): tagging by centroid tile leaves
# shore cells whose own ground is the seabed while their centroid tile reads
# land (a cell straddling the quay edge), and deck cells over water. Beside a
# sink held at the surface each would be a basin ~1.6 deep that has to fill
# before it drains (and oil never evaporates). Raised to the waterline (or to
# a lower rim they spill over into another body), they shed what stands above
# their puddle floor into the sea, as they shed onto the seabed in 'visual'.
# Known limits, left to P3-D / P4-B: a deck over water gets the waterline, not
# a head of its own; a destroyed deck is not re-tagged as a sink; and the clamp
# follows the walls at load. Doors start closed (Door.gd), so they are walls
# then: a door or a breach opened later re-derives the edges, not the clamp,
# and a below-waterline floor behind it can then trap beside the raised shore.
# One O(cell_count) pass per map load, plus the clamp's two floods over the
# ground below the highest sink head. Returns the sink count.
func setup_sinks() -> int:
	var n := graph.cell_count if graph != null else 0
	sink = PackedByteArray(); sink.resize(n)
	sink_count = 0
	waterline_count = 0
	for cid in n:
		var t := GridManager.world_to_map(graph.centroid(cid))
		if GridManager.deck_elevations.has(t):
			continue
		var surf: float = GridManager.water_surface_at(t)
		if is_nan(surf):
			continue
		sink[cid] = 1
		sink_count += 1
		_ground[cid] = surf * HEAD_PER_STORY
		if amount[cid] > 0.0:   # nothing stands on open water (tagging after a deposit)
			drained[ftype[cid]] += amount[cid]
			amount[cid] = 0.0
			ftype[cid] = 0
			active.erase(cid)
	if sink_count == 0:
		sink = PackedByteArray()   # the hot-path guard reads sink_count first
		return 0
	waterline_count = _clamp_waterline()
	# The clamp's floods built the shore's edges; start cold like 'visual'
	# (edges are rebuilt from the walls on demand, so nothing changes).
	_edge_cache.clear()
	return sink_count


# The waterline clamp (setup_sinks): raises only the traps the sinks make. A
# cell's SPILL level is the lowest head fluid standing on it has to reach
# before it runs off into a sink: over its open paths to a sink, the least
# of the highest ground head on the way, the cell's own and the sink's head
# included (_spill_levels: one priority flood out from the sinks). A cell
# whose spill is above its own ground fills before it drains. It is a trap
# the sinks made when, with every sink at its seabed as 'visual' runs it
# (the same flood: open water is just low ground there), it drains at its
# own ground; it is raised to its spill, the lowest ground that sheds. A
# cell that drains at its own ground (a slope down to a lower body) keeps
# it, and a pit in 'visual' too (an inland pond behind a ridge, a hollow
# beside a perched pool) keeps its pond. Filling a hollow up to its spill
# moves no cell's spill, so every raised cell then has a level-or-downhill
# path to a sink and every cell that drained at its own ground still does.
# A trap the sinks made lies below the head of the sink it drained into in
# 'visual', so only ground at or below the highest sink head is flooded (on
# a one-body map, the shore below its waterline). Ground heads only: the
# cells' fluid is untouched. Returns the raised-cell count.
func _clamp_waterline() -> int:
	var n := sink.size()
	var top := -INF   # the highest sink head
	for cid in n:
		if sink[cid] == 1:
			top = maxf(top, _ground[cid])
	var spill := _spill_levels(top + HEAD_EPS, false)
	var spill_visual := _spill_levels(top + HEAD_EPS, true)
	var raised := 0
	for cid in n:
		if sink[cid] == 1 or spill[cid] == INF:
			continue
		var g := _ground_head(cid)
		if spill[cid] > g + HEAD_EPS and spill_visual[cid] <= g + HEAD_EPS:
			_ground[cid] = spill[cid]
			raised += 1
	return raised


# Every cell's spill level (_clamp_waterline), INF where no open path at or
# below `cap` reaches a sink. A priority flood out from the sinks in rising
# order, upstream across open edges (fluid on nb can flow into c): a sink
# starts at its head, or with `seabed` at its own ground; a cell's spill is
# the higher of its ground and the spill of the neighbour it flows into, the
# lowest such. Each cell is settled once: O(k log k) in the k cells flooded.
# Read before the clamp writes any raised head, so every non-sink cell is at
# its own ground.
func _spill_levels(cap: float, seabed: bool) -> PackedFloat32Array:
	var n := sink.size()
	var spill := PackedFloat32Array()
	spill.resize(n)
	spill.fill(INF)
	_heap_key = PackedFloat32Array()
	_heap_cid = PackedInt32Array()
	for cid in n:
		if sink[cid] == 1:
			spill[cid] = graph.ground_elev(cid) * HEAD_PER_STORY if seabed else _ground[cid]
			_heap_push(spill[cid], cid)
	while not _heap_cid.is_empty():
		var lv: float = _heap_key[0]
		var c := _heap_pop()
		if lv > spill[c]:
			continue   # stale: settled lower since it was pushed
		var nbs: Array = _nb_cache[c]
		for j in nbs.size():
			var nb: int = nbs[j]
			if sink[nb] == 1:
				continue
			var g := _ground_head(nb)
			if g > cap:
				continue
			var s := maxf(g, lv)
			if s >= spill[nb] or not _opens_to(nb, c):
				continue
			spill[nb] = s
			_heap_push(s, nb)
	_heap_key = PackedFloat32Array()
	_heap_cid = PackedInt32Array()
	return spill


func _heap_push(key: float, cid: int) -> void:
	_heap_key.append(key)
	_heap_cid.append(cid)
	var i := _heap_key.size() - 1
	while i > 0:
		var p := (i - 1) >> 1
		if _heap_key[p] <= key:
			break
		_heap_key[i] = _heap_key[p]
		_heap_cid[i] = _heap_cid[p]
		i = p
	_heap_key[i] = key
	_heap_cid[i] = cid


# Pops the lowest entry's cid (its key is _heap_key[0] before the call).
func _heap_pop() -> int:
	var top := _heap_cid[0]
	var last := _heap_key.size() - 1
	var key := _heap_key[last]
	var cid := _heap_cid[last]
	_heap_key.resize(last)
	_heap_cid.resize(last)
	if last == 0:
		return top
	var i := 0
	while true:
		var l := i * 2 + 1
		if l >= last:
			break
		var r := l + 1
		var m := r if r < last and _heap_key[r] < _heap_key[l] else l
		if _heap_key[m] >= key:
			break
		_heap_key[i] = _heap_key[m]
		_heap_cid[i] = _heap_cid[m]
		i = m
	_heap_key[i] = key
	_heap_cid[i] = cid
	return top


# True when fluid on cell a can flow into its neighbour b (the edge test
# _flow_tick applies to a's outflow).
func _opens_to(a: int, b: int) -> bool:
	var nbs: Array = _nb_cache[a]
	var k := nbs.find(b)
	if k < 0:
		return false
	var opens := _edges(a)
	return k >= opens.size() or opens[k] == 1


func is_sink(cid: int) -> bool:
	return sink_count > 0 and cid >= 0 and cid < sink.size() and sink[cid] == 1


# Mass the sinks deleted, of one fluid type / of every type.
func drained_mass(type_str: String) -> float:
	var ti := _ti_of(type_str)
	return drained[ti] if ti > 0 and ti < drained.size() else 0.0


func drained_total() -> float:
	var s := 0.0
	for ti in range(1, drained.size()):
		s += drained[ti]
	return s


func mass_ledger() -> Dictionary:
	return {"poured": mass_poured, "drained": drained_total(),
		"evaporated": mass_evaporated, "lost": mass_lost}


# --- public API (mirrors FluidSim; FluidManager routes deposits/queries here) --

# Deposit `depth` of type `ti_or_str` at the cell under a world point (a
# different type wipes the old -- register_fluid semantics). wipe=false makes
# the deposit polite: a cell already holding another type is left alone (rain
# must not erase an authored oil slick drop by drop).
func deposit(world_pos: Vector2, type_str: String, depth: float, wipe: bool = true) -> void:
	var ti := _ti_of(type_str)
	if ti <= 0 or depth <= 0.0:
		return
	var cid := graph.cell_at(world_pos)
	if cid >= 0:
		_add(cid, ti, depth, wipe, true)


# Pour over a world radius (fluid_spawns with radius): fall-off toward the rim.
# wipe=false pours politely (weather: rain must not erase an authored slick).
# Wall-band cells are skipped: a 42px rain blot crosses tile edges, and a
# deposit under a wall band strands sealed fluid there AND projects a phantom
# wet/conductive wall tile (review find) -- rain doesn't fall through masonry.
func pour(center: Vector2, type_str: String, depth: float, radius: float, wipe: bool = true) -> int:
	var ti := _ti_of(type_str)
	if ti <= 0 or depth <= 0.0:
		return 0
	var n := 0
	for cid in graph.cell_count:
		var c := graph.centroid(cid)
		var d := c.distance_to(center)
		if d > radius:
			continue
		if GridManager.walls.get(GridManager.world_to_map(c), false):
			continue
		_add(cid, ti, depth * (1.0 - 0.6 * d / maxf(radius, 1.0)), wipe, true)
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
		mass_lost += amount[cid]
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
		mass_lost += amount[cid]
		amount[cid] = 0.0
		ftype[cid] = 0
		active.erase(cid)
		flow_dir.erase(cid)
		flow_speed.erase(cid)


# A destroyed wall un-refcounts its obstacle tiles -> re-derive edge blocking so
# fluid can flow through the breach. Called from Game._on_structure_destroyed.
func invalidate_edges() -> void:
	_edge_cache.clear()


# --- fire bridge (CellFire._fuel consults these) ---------------------

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
	var before := amount[cid]
	amount[cid] = maxf(0.0, amount[cid] - amt)
	if amount[cid] < DRY:
		amount[cid] = 0.0
		ftype[cid] = 0
		active.erase(cid)
	mass_lost += before - amount[cid]


# --- simulation --------------------------------------------------------------

func tick(delta: float) -> void:
	for s in sources:
		_add(int(s["cid"]), int(s["ti"]), float(s["rate"]) * delta, true, true)
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
	var deltas: Dictionary = {}
	flow_dir.clear(); flow_speed.clear()
	for cid in active:
		var amt := amount[cid]
		var ti := ftype[cid]
		# per-type evaporation: water dries at the base rate; an oil slick is
		# effectively permanent until burned (fluids.json "evaporation"
		# overrides; the uniform rate made oil pools fade before the fight
		# reached them)
		# per-type minimum pool: below it a cell stops pushing outward entirely.
		# Water keeps the thin PUDDLE film; oil holds a THICK slick (0.25) --
		# on a flat map the old uniform film let a pour spread into an
		# invisible-but-still-slowing sheet within a minute.
		var pud := _puddle_of(ti)
		var ev := _evap_of(ti)
		# a no-evap fluid (oil) stranded BELOW its pool floor can neither flow
		# nor dry -- an invisible immortal film that still slows walkers and
		# reads as heavy fuel (review find). Sub-floor films dry at the base
		# rate; the standing slick body above the floor never evaporates.
		if ev <= 0.0 and amt < pud and amt > 0.0:
			ev = EVAP_PER_SEC
		_delta_add(deltas, cid, ti, -ev * SIM_INTERVAL)
		mass_evaporated += ev * SIM_INTERVAL   # the debit pass refunds a clamped shortfall
		if amt < pud:
			continue
		var visc := _visc(ti)
		var head := _head(cid)
		var press := amt - pud
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
			var nti := int(ftype[nb])
			var diff: float
			if nti == 0 or nti == int(ti):
				diff = head - _head(nb)
			else:
				# immiscible standing bodies: a DIFFERENT-type column counts in
				# FULL, and the arriving front must be able to BURY the whole
				# resident before any of it flows -- a cross-type credit wipes
				# the neighbour's entire column (_add), so anything less than a
				# dominant front annihilates mass both ways (an acid pour
				# ringing an oil slick ground 95% of it to nothing in 40 ticks;
				# pool-floor-discounted heads earlier let a 0.04 trickle read a
				# settled 0.28 slick as near-vacuum -- both review finds).
				# Donor-side, like the trickle rule above: never book what
				# can't dominate. This surface test is the cheap prefilter; the
				# booked-front test below is the real gate.
				diff = (_ground_head(cid) + amount[cid]) - (_ground_head(nb) + amount[nb])
				if diff <= amount[nb] + EPSILON:
					continue
			if diff <= EPSILON:
				continue
			var fa := minf(minf(
				amt * rate_tick * (diff / (press + 0.1)) / visc,
				diff * 0.5), avail)
			if fa <= MIN_FLOW:
				continue
			# cross-type: the BOOKED front itself must bury the resident. The
			# diff gate above tests the potential, but fa is rate/half-diff
			# capped -- a 0.10 credit approved against a 0.29 column would
			# still wipe the whole column at apply time, and the sub-floor
			# beachhead left behind is counter-wiped next tick (verifier sim:
			# 28% of system mass annihilated in 60 ticks of adjacency churn).
			if nti != 0 and nti != int(ti) and fa <= amount[nb]:
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
				if amount[cid] + d < 0.0:
					mass_evaporated += amount[cid] + d   # booked more than the cell held
				amount[cid] = maxf(0.0, amount[cid] + d)
	for cid in deltas:
		var per: Dictionary = deltas[cid]
		for ti in per:
			var d: float = per[ti]
			if d > 0.0:
				# a cross-type credit smaller than the CURRENT column must not
				# wipe it -- same-type credits earlier in this per-cell dict
				# may have topped the column up since the booking snapshot
				# (Dictionary-order aggravator, verifier find). Dropping the
				# credit destroys strictly less than zeroing the resident.
				if ftype[cid] != 0 and ftype[cid] != int(ti) and d <= amount[cid]:
					mass_lost += d
					continue
				_add(cid, int(ti), d)   # into a sink: deleted and counted there
	# cull dried cells
	var drop: Array = []
	for cid in active:
		if amount[cid] < DRY:
			drop.append(cid)
	for cid in drop:
		mass_evaporated += amount[cid]
		amount[cid] = 0.0
		ftype[cid] = 0
		active.erase(cid)
		flow_dir.erase(cid)
		flow_speed.erase(cid)


# --- internals ---------------------------------------------------------------

# ext = an outside input (deposit / pour / source), booked as poured. A sink
# takes anything at once, polite or not, and never becomes active.
func _add(cid: int, ti: int, amt: float, wipe: bool = true, ext: bool = false) -> void:
	if amt <= 0.0 or cid < 0 or cid >= amount.size():
		return
	if sink_count > 0 and sink[cid] == 1:
		drained[ti] += amt
		if ext:
			mass_poured += amt
		return
	if ftype[cid] != 0 and ftype[cid] != ti:
		if not wipe:
			return           # polite deposit: never displace a standing fluid
		mass_lost += amount[cid]
		amount[cid] = 0.0    # a different type arriving wipes the old (register_fluid)
	ftype[cid] = ti
	amount[cid] += amt
	if ext:
		mass_poured += amt
	active[cid] = true


func _delta_add(deltas: Dictionary, cid: int, ti: int, d: float) -> void:
	if not deltas.has(cid):
		deltas[cid] = {}
	var per: Dictionary = deltas[cid]
	per[ti] = float(per.get(ti, 0.0)) + d


func _head(cid: int) -> float:
	# the per-type minimum pool carries no head: a settled slick reads level to
	# its neighbours instead of forever pressing outward (dry cells: ftype 0 ->
	# _puddle_of falls back to PUDDLE, amount 0 -> maxf clamps to 0 either way)
	return _ground_head(cid) + maxf(amount[cid] - _puddle_of(ftype[cid]), 0.0)


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


func _evap_of(ti: int) -> float:
	if ti <= 0 or ti - 1 >= _order.size():
		return EVAP_PER_SEC
	var t: String = _order[ti - 1]
	# real oil barely evaporates; default everything else to the water rate
	var dflt: float = 0.0 if t == "oil" else EVAP_PER_SEC
	return float((_db.get(t, {}) as Dictionary).get("evaporation", dflt))


# Per-type minimum pool depth (fluids.json "puddle" overrides). Oil's 0.25 is
# render-derived: the water shader's shore cutoff needs roughly >= 0.25 cell
# depth for a slick to stay FULLY visible (0.12 still reads invisible between
# blob centres) -- and a thick slick that stops creeping is also the right
# physics for a viscous fluid.
func _puddle_of(ti: int) -> float:
	if ti <= 0 or ti - 1 >= _order.size():
		return PUDDLE
	var t: String = _order[ti - 1]
	var dflt: float = 0.25 if t == "oil" else PUDDLE
	return float((_db.get(t, {}) as Dictionary).get("puddle", dflt))


func _visc(ti: int) -> float:
	if ti <= 0 or ti - 1 >= _order.size():
		return 1.0
	var t: String = _order[ti - 1]
	# data/fluids.json omits oil's viscosity (its shader defaulted to 1.0); a
	# slick that runs like water reads wrong on slopes -- give it a syrupy crawl,
	# matching the editor's FluidDefs override.
	var dflt: float = 1.8 if t == "oil" else 1.0
	return float(_db.get(t, {}).get("viscosity", dflt))
