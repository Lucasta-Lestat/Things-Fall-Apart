extends Node2D
# Living-water bench (P3-A): the REAL sea drain (CellFluid sink cells) against
# today's visual-only sea, on the maps whose open water fluids can reach. Loads
# each map through MapLoader (real walls, floors, decks) like fire_perf_bench,
# stands up FluidManager the way Game does, then runs every scenario of the map
# once per mode in fixed 1/60 s steps. All 'visual' runs go first, in a fixed
# order, so they see exactly what a build without sinks sees: their end-state
# hashes must equal the same bench run on a pre-P3-A tree (the bit-for-bit
# proof; TFA_SINK_MODES=visual runs only them).
#   harbor_quay_water / harbor_quay_oil: a 0.6-deep pour (r 128 px) on the quay,
#     two tiles back from the deep water (the spill has to FLOW to a sink: the
#     shore cells can straddle land), 30 s;
#   harbor_oil_well: Oil Well (the authored fluid_well payload) on the same
#     spot, pumped by hand like fluid_well_check, 30 s;
#   harbor_rain_storm: 60 s of rain. The weather path only puddles when the
#     weather CHANGES (Game._spawn_rain_puddles: 5 x 0.35 for rain), so the
#     storm is simulated with that path's own deposit, FluidManager.rain_puddle
#     (0.35, every 0.25 s), on tiles drawn from a seeded RNG over the map's
#     unwalled, unroofed tiles -- the _spawn_rain_puddles filter minus its
#     has-fluid test, so both modes get the same storm;
#   ossuary_channel_spill: a 0.6-deep pour two tiles from the narrow channel;
#   harbor_shore_edge_well / ossuary_shore_edge_well: Oil Well on the LOWEST
#     shore cell (the lowest cell ground with an open edge to open water: a
#     cell straddling the shore, whose own ground is the seabed while its
#     centroid tile is land), 30 s. Appended after the older scenarios, so
#     their visual hashes are unchanged.
# Any other map gets one shore_water spill. Per scenario and mode it prints the
# CellFluid flow-tick p50/p95/max (the frames whose tick ran _flow_tick), the
# fluid frame (deposits + well + FluidManager.update_fluid_tick, replicated 1:1)
# mean/p95, peak active cells, the mass ledger and the end-state hash. Sink runs
# also print four trap checks. Structural: no shore cell (a non-sink cell that
# can flow into a sink) may sit below its lowest sink's head without a
# level-or-downhill path to a sink, or it fills before it drains. Dynamic: no
# non-sink cell may end a sink run deeper than in the same scenario's visual
# run (+TRAP_TOL) AND deeper than its puddle floor + TRAP_FLOOR (skipped
# without a visual run). Over-raise: no cell the waterline clamp raised may
# have drained at its own ground already (original grounds, sinks at their
# heads: a slope it flattened), nor be a pit in 'visual' too (every cell at
# its original ground: a pond it filled); the raised cells with no open water
# under their footprint are counted for information. Drain kept: every raised
# cell drains at its raised head (the clamp's heads), and no other non-sink
# cell that drained at its own ground before the clamp (original grounds,
# sinks at their heads) has lost that drain to a raised cell. Then one VERDICT line
# per map: ship 'sink' when every sink run keeps the flow tick p95 <= 2 ms and
# the frame delta vs 'visual' <= 1 ms (mean and p95), each judged on the MEDIAN of
# TFA_SINK_REPEAT repeats (the best is printed beside it), the mass closes, no
# sink ever holds or sheds fluid, no deck cell over water is a sink or a trap
# ('n/a' on a map without one), the four trap checks find nothing, and every
# shore spill reached a sink. Otherwise 'visual'.
# Headless:  godot --headless --path . res://tests/fluid_sink_bench.tscn
# Env: TFA_SINK_MAPS (comma list, default tg_hillside_harbor,tg_hillside_ossuary),
#      TFA_SINK_MODES (default visual,sink), TFA_SINK_ONLY=<scenario id>,
#      TFA_SINK_SECS (overrides every scenario's length), TFA_SINK_REPEAT
#      (default 5: each run is repeated and judged on the median repeat, so
#      one disturbed or lucky repeat does not flip a verdict), TFA_SINK_CELLS=<dir>
#      (load <dir>/<id>_cells.json instead of the row's cell_graph: a contract-3
#      headless dump carries the tile_water layer the shipped files lack yet;
#      the bench never writes it anywhere).
# Exit 0 when every map's verdict could be reached (a 'visual' verdict is a
# result, not a failure), 1 on a setup error, 99 when the watchdog fires (a
# SCRIPT ERROR aborted the coroutine: no run finished in its time).
const MAP_LOADER := preload("res://Structures/MapLoader.gd")

const STEP := 1.0 / 60.0
const TICK_BUDGET_MS := 2.0
const FRAME_BUDGET_MS := 1.0
const SPILL_DEPTH := 0.6
const SPILL_RADIUS := 128.0
const RAIN_AMOUNT := 0.35          # Game._spawn_rain_puddles' "rain" amount
const RAIN_EVERY := 0.25
const RAIN_SEED := 4242
const MASS_REL_TOL := 1e-4
const MASS_ABS_TOL := 1e-3
const HEAD_TOL := 1e-4             # ground-head comparisons (depth units)
const TRAP_TOL := 0.05             # sink run deeper than visual by more than this ...
const TRAP_FLOOR := 0.1            # ... and deeper than its puddle floor + this = a trap
const WATCHDOG_SECS := 120.0       # per map load, and the floor of each run's limit
const WATCHDOG_PER_SIM_SEC := 2.0  # + this per simulated second (a run takes ~0.02 s per sim s here)
const HEADS_NOW := 0               # _drains_at's ground heads: as the clamp left them
const HEADS_ORIG := 1              # ... every non-sink cell at its original ground
const HEADS_VISUAL := 2            # ... every cell at its original ground, sinks too

var structures_in_scene: Array = []
var characters_in_scene: Array = []
var items_in_scene: Array = []
var party_chars: Array = []
var unlocked_locks: Dictionary = {}
var map_loader: Node2D = null
var fluid_manager: FluidManager = null
var current_map_data: Dictionary = {}

var _graph: CellGraph = null
var _well_payload: Dictionary = {}
var _errors := 0
var _repeats := 5
var _watch_gen := 0                     # the watchdog's arm count: only the latest arm fires
var _drain_mark := PackedInt32Array()   # _drains_at's visited marks (walk number per cid)
var _drain_gen := 0
var _kept: Dictionary = {}              # this map's drain-kept result (_drain_kept), walked once


func load_map(_a = null, _b = "", _c = "") -> void:
	pass   # SurfaceManager._get_game keys on this method name


func _ready() -> void:
	add_to_group("game")
	var f := FileAccess.open("res://data/Maps.json", FileAccess.READ)
	var raw: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	_well_payload = _oil_well_payload()
	var want: String = OS.get_environment("TFA_SINK_MAPS")
	if want == "":
		want = "tg_hillside_harbor,tg_hillside_ossuary"
	var modes_env: String = OS.get_environment("TFA_SINK_MODES")
	var modes: PackedStringArray = (modes_env if modes_env != "" else "visual,sink").split(",", false)
	if OS.get_environment("TFA_SINK_REPEAT") != "":
		_repeats = maxi(1, int(OS.get_environment("TFA_SINK_REPEAT")))
	_arm_watchdog(WATCHDOG_SECS)
	await get_tree().process_frame
	var probe := CellFluid.new()
	var sink_api: bool = probe.has_method("is_sink")
	probe.free()
	print("fluid_sink_bench: modes=%s repeats=%d sink_api=%s" % [",".join(modes), _repeats, str(sink_api)])
	for mid in want.split(",", false):
		var m: Dictionary = {}
		for e in raw.get("maps", []):
			if String(e.get("id", "")) == mid:
				m = e
				break
		if m.is_empty():
			print("BENCH ERROR: map %s not in Maps.json" % mid)
			_errors += 1
			continue
		await _bench_map(m, modes, sink_api)
	ProjectSettings.set_setting("tfa/fluids/sea_sink", "auto")
	print("fluid_sink_bench done: %d setup error(s)" % _errors)
	get_tree().quit(1 if _errors > 0 else 0)


# A SCRIPT ERROR aborts the coroutine; don't hang waiting for quit(). Re-armed
# before every map load and every run (its limit grows with the run's
# simulated seconds, so TFA_SINK_SECS can't trip it on a healthy run): only
# the latest arm can fire, and the runs never yield mid-scenario, so the
# limit is checked between them.
func _arm_watchdog(limit: float) -> void:
	_watch_gen += 1
	var gen := _watch_gen
	get_tree().create_timer(limit, true).timeout.connect(func():
		if gen != _watch_gen:
			return
		print("BENCH ERROR: watchdog after %.0f s (coroutine aborted?)" % limit)
		get_tree().quit(99))


func _oil_well_payload() -> Dictionary:
	var af := FileAccess.open("res://data/Abilities.json", FileAccess.READ)
	var js := JSON.new()
	if af == null or js.parse(af.get_as_text()) != OK:
		return {}
	for entry in js.get_data().get("abilities", []):
		if entry is Dictionary and String(entry.get("id", "")) == "oil_well":
			return entry["effects"][0]
	return {}


# --- one map: load, find the sites, run every scenario per mode -------------

func _bench_map(m: Dictionary, modes: PackedStringArray, sink_api: bool) -> void:
	_arm_watchdog(WATCHDOG_SECS)
	_kept = {}
	var mid := String(m.get("id", ""))
	current_map_data = m
	structures_in_scene.clear()
	GridManager.TILE_SIZE = int(m.get("tile_size", 64))
	var ws: Array = m.get("world_size", [2048, 2048])
	GridManager.initialize(int(ws[0]), int(ws[1]))
	var cg_path := String(m.get("cell_graph", ""))
	if OS.get_environment("TFA_SINK_CELLS") != "":
		cg_path = OS.get_environment("TFA_SINK_CELLS").path_join("%s_cells.json" % mid)
	_graph = CellGraph.from_structured(cg_path)
	if _graph == null:
		print("BENCH ERROR: %s has no cell graph" % mid)
		_errors += 1
		return
	GridManager.set_elevation_data(_graph)
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	ml.generate_structured_map(m)
	map_loader = ml
	if fluid_manager == null:
		fluid_manager = FluidManager.new()
		fluid_manager.name = "FluidManager"   # FluidWell looks it up by name
		add_child(fluid_manager)
	var scen := _scenarios(mid)
	var deep := 0
	for t in GridManager.floors:
		if GridManager.is_deep_water(t):
			deep += 1
	var layer: String = "n/a"
	if GridManager.has_method("has_water_layer"):
		layer = str(GridManager.call("has_water_layer"))
	print("bench map=%s cells=%d deep_tiles=%d relief_los=%s water_layer=%s entry_water_sim=%s graph=%s" % [
		mid, _graph.cell_count, deep, str(GridManager.relief_los), layer,
		String(m.get("water_sim", "(absent)")), cg_path])
	var results: Dictionary = {}   # mode -> scenario id -> result
	for mode in modes:
		results[mode] = {}
		for sc in scen:
			var only: String = OS.get_environment("TFA_SINK_ONLY")
			if only != "" and only != String(sc["id"]):
				continue
			if mode == "sink" and not sink_api:
				continue
			# the work is deterministic, the machine is not (other sessions share
			# it): repeat each run and judge the median repeat; every repeat must
			# end in the same state. A sink run is compared cell by cell with
			# the same scenario's visual run (the dynamic trap check).
			var vis_ref: Dictionary = (results.get("visual", {}) as Dictionary).get(sc["id"], {})
			var reps: Array = []
			for _k in _repeats:
				_arm_watchdog(WATCHDOG_SECS + float(sc["secs"]) * WATCHDOG_PER_SIM_SEC)
				reps.append(await _run(sc, mode, vis_ref))
			var r: Dictionary = _summarize_runs(reps)
			(results[mode] as Dictionary)[sc["id"]] = r
			_print_result(mid, sc, mode, r)
	_arm_watchdog(WATCHDOG_SECS)
	_verdict(mid, results, sink_api)
	# tear the map down so the next one loads into a clean tree
	fluid_manager.setup_cell_graph(null)
	ml.queue_free()
	map_loader = null
	await get_tree().process_frame


# Scenario list for a map: {id, kind, site (world px), secs, fluid, shore}.
func _scenarios(mid: String) -> Array:
	var out: Array = []
	if mid == "tg_hillside_harbor":
		var q := _shore_site(false, 0.45)
		if q == Vector2.INF:
			print("BENCH ERROR: %s: no quay site two tiles from deep water" % mid)
			_errors += 1
			return out
		out.append({"id": "harbor_quay_water", "kind": "spill", "site": q, "secs": 30.0, "fluid": "water", "shore": true})
		out.append({"id": "harbor_quay_oil", "kind": "spill", "site": q, "secs": 30.0, "fluid": "oil", "shore": true})
		out.append({"id": "harbor_oil_well", "kind": "well", "site": q, "secs": 30.0, "fluid": "oil", "shore": true})
		out.append({"id": "harbor_rain_storm", "kind": "rain", "site": q, "secs": 60.0, "fluid": "water", "shore": false})
		var e := _shore_edge_site()
		if e == Vector2.INF:
			print("BENCH ERROR: %s: no shore cell next to open water" % mid)
			_errors += 1
			return out
		out.append({"id": "harbor_shore_edge_well", "kind": "well", "site": e, "secs": 30.0, "fluid": "oil", "shore": true})
	elif mid == "tg_hillside_ossuary":
		var c := _shore_site(true, -INF)
		if c == Vector2.INF:
			print("BENCH ERROR: %s: no bank site two tiles from the channel" % mid)
			_errors += 1
			return out
		out.append({"id": "ossuary_channel_spill", "kind": "spill", "site": c, "secs": 30.0, "fluid": "water", "shore": true})
		var oe := _shore_edge_site()
		if oe == Vector2.INF:
			print("BENCH ERROR: %s: no shore cell next to open water" % mid)
			_errors += 1
			return out
		out.append({"id": "ossuary_shore_edge_well", "kind": "well", "site": oe, "secs": 30.0, "fluid": "oil", "shore": true})
	else:
		var s := _shore_site(false, -INF)
		if s != Vector2.INF:
			out.append({"id": "shore_water", "kind": "spill", "site": s, "secs": 30.0, "fluid": "water", "shore": true})
	if OS.get_environment("TFA_SINK_SECS") != "":
		for sc in out:
			sc["secs"] = float(OS.get_environment("TFA_SINK_SECS"))
	return out


# A dry, unwalled, walkable tile exactly two tiles (Chebyshev) from deep water,
# nearest the default spawn (ties: scan order). narrow: the deep tile must be a
# one-tile channel (dry on both sides along x or along y). min_elev: quay height
# floor (the harbor's graded landing steps sit below the 0.5-story quay).
func _shore_site(narrow: bool, min_elev: float) -> Vector2:
	var spawn := _spawn_point()
	var best := Vector2.INF
	var bestd := INF
	var rect: Rect2i = GridManager.map_rect
	for y in rect.size.y:
		for x in rect.size.x:
			var t := Vector2i(x, y)
			if GridManager.is_deep_water(t) or bool(GridManager.walls.get(t, false)) \
					or GridManager.floors.get(t, "") == "shallow_water" or GridManager.has_roof(t) \
					or GridManager.is_solid_rock(t) or GridManager.terrain_elev(t) < min_elev:
				continue
			var ring := 99
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					var n := t + Vector2i(dx, dy)
					if not GridManager.is_deep_water(n):
						continue
					if narrow and not _narrow(n):
						continue
					ring = mini(ring, maxi(absi(dx), absi(dy)))
			if ring != 2:
				continue
			var p: Vector2 = GridManager.map_to_world(t)
			var d: float = p.distance_squared_to(spawn)
			if d < bestd:
				bestd = d
				best = p
	return best


func _narrow(t: Vector2i) -> bool:
	var ew: bool = not GridManager.is_deep_water(t + Vector2i(1, 0)) and not GridManager.is_deep_water(t + Vector2i(-1, 0))
	var ns: bool = not GridManager.is_deep_water(t + Vector2i(0, 1)) and not GridManager.is_deep_water(t + Vector2i(0, -1))
	return ew or ns


# The lowest shore cell's centroid: a cell whose centroid tile is not open
# water, with an open edge to one that is, on the lowest cell ground
# (CellGraph.ground_elev, the head the sim uses); ties: nearest the default
# spawn. Walkable, unroofed, non-rock centroids only. Open water and the edge
# test use what every tree has (water_surface_at where it exists, else the
# deep-water rule; the GridManager.walls segment test of CellFluid._edges), so
# the site is the same on a pre-P3-A tree.
func _shore_edge_site() -> Vector2:
	var n := _graph.cell_count
	var wet := PackedByteArray()
	wet.resize(n)
	for cid in n:
		wet[cid] = 1 if _open_water_tile(GridManager.world_to_map(_graph.centroid(cid))) else 0
	var spawn := _spawn_point()
	var best := Vector2.INF
	var best_e := INF
	var best_d := INF
	for cid in n:
		if wet[cid] == 1:
			continue
		var c := _graph.centroid(cid)
		var t := GridManager.world_to_map(c)
		if bool(GridManager.walls.get(t, false)) or GridManager.has_roof(t) or GridManager.is_solid_rock(t):
			continue
		var shore := false
		for nb in _graph.neighbors(cid):
			if wet[int(nb)] == 1 and not _blocked(c, _graph.centroid(int(nb))):
				shore = true
				break
		if not shore:
			continue
		var e: float = _graph.ground_elev(cid)
		var d: float = c.distance_squared_to(spawn)
		if e < best_e - 1e-6 or (absf(e - best_e) <= 1e-6 and d < best_d):
			best_e = e
			best_d = d
			best = c
	return best


# CellFluid.setup_sinks' tagging rule: open water, never under a deck.
func _open_water_tile(t: Vector2i) -> bool:
	if GridManager.deck_elevations.has(t):
		return false
	if GridManager.has_method("water_surface_at"):
		return not is_nan(float(GridManager.call("water_surface_at", t)))
	return GridManager.is_deep_water(t)


# CellFluid._blocked_between, for a tree that may not expose it.
func _blocked(a: Vector2, b: Vector2) -> bool:
	var steps := int(ceil(a.distance_to(b) / (GridManager.TILE_SIZE * 0.5))) + 1
	for i in range(1, steps):
		if bool(GridManager.walls.get(GridManager.world_to_map(a.lerp(b, float(i) / float(steps))), false)):
			return true
	return false


func _spawn_point() -> Vector2:
	var sp: Dictionary = (current_map_data.get("player_spawns", {}) as Dictionary).get("default", {})
	var spa: Array = sp.get("position", [0, 0])
	return Vector2(float(spa[0]), float(spa[1]))


# --- one run -----------------------------------------------------------------

func _run(sc: Dictionary, mode: String, vis_ref: Dictionary = {}) -> Dictionary:
	# the switch, exactly as a project-setting override would flip it
	ProjectSettings.set_setting("tfa/fluids/sea_sink", mode)
	if map_loader.has_method("resolve_water_sim"):
		map_loader.set("water_sim", map_loader.call("resolve_water_sim", current_map_data))
	var s0 := Time.get_ticks_usec()
	fluid_manager.setup_cell_graph(_graph)   # the map-load cost: sim, sinks + clamp, FX
	var setup_ms: float = float(Time.get_ticks_usec() - s0) / 1000.0
	await get_tree().process_frame   # let the previous run's sim and FX free
	var cf: CellFluid = fluid_manager.cell_fluid
	var r: Dictionary = {"ok": cf != null, "setup_ms": setup_ms}
	if cf == null:
		_errors += 1
		return r
	var api: bool = cf.has_method("is_sink")
	var sinks := PackedInt32Array()
	if api:
		for cid in _graph.cell_count:
			if cf.call("is_sink", cid):
				sinks.append(cid)
	var decks := _deck_water_cells()
	var site: Vector2 = sc["site"]
	var kind := String(sc["kind"])
	var fluid := String(sc["fluid"])
	var secs: float = float(sc["secs"])
	var rng := RandomNumberGenerator.new()
	rng.seed = RAIN_SEED
	var rain_tiles: Array = _rain_tiles() if kind == "rain" else []
	var well: FluidWell = null
	if kind == "well":
		well = FluidWell.new()
		well.fluid_type = String(_well_payload.get("fluid_type", "oil"))
		well.radius = float(_well_payload.get("radius", 192.0))
		well.duration = float(_well_payload.get("duration", 6.0))
		well.visual_scene_path = ""
		add_child(well)
		well.global_position = site
		well.set_process(false)   # pumped by hand below: fixed steps, no frame clock
	var tick_ms: Array = []        # flow-tick frames only
	var frame_ms: Array = []
	var peak_active := 0
	var sink_violations := 0
	var deck_violations := 0
	var rain_t := 0.0
	var steps := int(round(secs / STEP))
	for i in steps:
		var f0 := Time.get_ticks_usec()
		if i == 0 and kind == "spill":
			cf.pour(site, fluid, SPILL_DEPTH, SPILL_RADIUS)
		elif kind == "rain":
			rain_t += STEP
			if rain_t >= RAIN_EVERY - 1e-9:
				rain_t = 0.0
				var tile: Vector2i = rain_tiles[rng.randi() % rain_tiles.size()]
				fluid_manager.rain_puddle(tile, fluid, RAIN_AMOUNT)
		if well != null and is_instance_valid(well):
			well._process(STEP)
		# --- FluidManager.update_fluid_tick, replicated 1:1 ---
		fluid_manager._update_ripples(STEP)
		var prev_timer: float = cf._timer
		var t0 := Time.get_ticks_usec()
		cf.tick(STEP)
		var t1 := Time.get_ticks_usec()
		var flowed: bool = cf._timer == 0.0 and prev_timer + STEP >= CellFluid.SIM_INTERVAL - 1e-9
		if flowed:
			tick_ms.append(float(t1 - t0) / 1000.0)
		fluid_manager._sim_timer += STEP
		if fluid_manager._sim_timer >= FluidManager.SIM_INTERVAL:
			fluid_manager._sim_timer = 0.0
			fluid_manager._project_cells_to_tiles()
		frame_ms.append(float(Time.get_ticks_usec() - f0) / 1000.0)
		# the bench's own checks stay outside the timed frame
		if flowed and api:
			sink_violations += _sink_check(cf, sinks)
		peak_active = maxi(peak_active, cf.active.size())
	var well_deposited := 0.0
	if well != null and is_instance_valid(well):
		well_deposited = well._deposited
		well.queue_free()
	# the trap checks run after the timed loop: they warm CellFluid's edge
	# cache, which would flatter the sink run's timing (setup_sinks hands it
	# over cold, as 'visual' starts)
	r["amounts"] = cf.amount.duplicate()
	var is_snk := PackedByteArray()
	is_snk.resize(_graph.cell_count)
	for cid in sinks:
		is_snk[cid] = 1
	r["shore_cells"] = 0
	r["shore_traps"] = 0
	r["traps"] = 0
	r["traps_run"] = false
	r["raised"] = 0
	r["over_raised"] = 0
	r["waterline"] = -1
	if api and mode == "sink":
		r["waterline"] = int(cf.get("waterline_count")) if "waterline_count" in cf else -1
		var st: Vector2i = _shore_traps(cf, is_snk)
		r["shore_cells"] = st.x
		r["shore_traps"] = st.y
		if vis_ref.has("amounts"):
			var tr: Dictionary = _deeper_than_visual(cf, is_snk, vis_ref["amounts"])
			r["traps_run"] = true
			r["traps"] = int(tr["count"])
			r["trap_worst"] = tr["worst"]
			r["trap_cells"] = tr["cells"]
		var orz: Dictionary = _over_raised(cf, is_snk)
		r["raised"] = int(orz["raised"])
		r["over_raised"] = int(orz["count"])
		r["over_drained"] = int(orz["drained"])
		r["over_pit"] = int(orz["pit"])
		r["over_dry"] = int(orz["dry"])
		r["over_worst"] = orz["worst"]
		# setup_sinks is deterministic, so every sink run of a map leaves the same
		# heads: walk them once (a contract-3 dump walks thousands of cells)
		if _kept.is_empty():
			_kept = _drain_kept(cf, is_snk)
		r["kept_checked"] = int(_kept["checked"])
		r["kept_stuck"] = int(_kept["stuck"])
		r["kept_cut"] = int(_kept["cut"])
		r["kept_worst"] = _kept["worst"]
	# a deck over water is never a sink, and never a trap
	var trapped: Dictionary = r.get("trap_cells", {})
	for cid in decks:
		if is_snk[cid] == 1 or trapped.has(cid):
			deck_violations += 1
	r["tick"] = _stats(tick_ms)
	r["frame"] = _stats(frame_ms)
	r["peak_active"] = peak_active
	r["final_active"] = cf.active.size()
	r["hash"] = _state_hash(cf)
	r["sinks"] = sinks.size()
	r["decks"] = decks.size()
	r["sink_violations"] = sink_violations
	r["deck_violations"] = deck_violations
	r["in_cells"] = _mass_in_cells(cf)
	r["well_deposited"] = well_deposited
	r["api"] = api
	if api:
		var led: Dictionary = cf.call("mass_ledger")
		r["ledger"] = led
		var poured: float = float(led.get("poured", 0.0))
		var rhs: float = float(r["in_cells"]) + float(led.get("drained", 0.0)) \
			+ float(led.get("evaporated", 0.0)) + float(led.get("lost", 0.0))
		r["mass_residual"] = poured - rhs
		r["mass_ok"] = absf(poured - rhs) <= MASS_REL_TOL * poured + MASS_ABS_TOL
		r["drained_type"] = float(cf.call("drained_mass", fluid))
	return r


# The repeats of one run (the work is deterministic; the machine is shared).
# The verdict reads the MEDIAN of each timing on its own -- flow-tick p95,
# frame mean, frame p95 -- so neither one disturbed nor one lucky repeat
# decides it; the best of each is kept beside it, and every repeat's tick p95
# and frame mean are listed. r["tick"] is the median-p95 repeat's tick stats.
# A repeat that ends in another state is a setup error.
func _summarize_runs(reps: Array) -> Dictionary:
	var ok: Array = []
	for rep in reps:
		var rd: Dictionary = rep
		if bool(rd.get("ok", false)):
			ok.append(rd)
	if ok.is_empty():
		return reps[0] if not reps.is_empty() else {"ok": false}
	var first: Dictionary = ok[0]
	var p95s: Array = []
	var means: Array = []
	var fp95s: Array = []
	for rd in ok:
		if String(rd["hash"]) != String(first["hash"]):
			print("BENCH ERROR: a repeat ended in another state (%s vs %s)" % [rd["hash"], first["hash"]])
			_errors += 1
		p95s.append(float((rd["tick"] as Dictionary)["p95"]))
		means.append(float((rd["frame"] as Dictionary)["mean"]))
		fp95s.append(float((rd["frame"] as Dictionary)["p95"]))
	var by_p95: Array = ok.duplicate()
	by_p95.sort_custom(func(a, b): return float((a["tick"] as Dictionary)["p95"]) < float((b["tick"] as Dictionary)["p95"]))
	var r: Dictionary = first.duplicate(true)
	r["tick"] = ((by_p95[(by_p95.size() - 1) >> 1] as Dictionary)["tick"] as Dictionary).duplicate()
	r["tick_p95_best"] = _min_of(p95s)
	var fr: Dictionary = (r["frame"] as Dictionary).duplicate()
	fr["mean"] = _median_of(means)
	fr["p95"] = _median_of(fp95s)
	r["frame"] = fr
	r["frame_mean_best"] = _min_of(means)
	r["frame_p95_best"] = _min_of(fp95s)
	var p95_txt: Array = []
	var mean_txt: Array = []
	for i in p95s.size():
		p95_txt.append("%.3f" % float(p95s[i]))
		mean_txt.append("%.3f" % float(means[i]))
	r["repeat_p95"] = ",".join(p95_txt)
	r["repeat_mean"] = ",".join(mean_txt)
	return r


func _median_of(a: Array) -> float:
	var s: Array = a.duplicate()
	s.sort()
	return float(s[(s.size() - 1) >> 1]) if not s.is_empty() else 0.0


func _min_of(a: Array) -> float:
	var m := INF
	for v in a:
		m = minf(m, float(v))
	return m if m != INF else 0.0


# Every flow tick: a sink never sits in `active`, never holds fluid and never
# reports an outflow direction (so nothing it "holds" can leave it).
func _sink_check(cf: CellFluid, sinks: PackedInt32Array) -> int:
	var bad := 0
	for cid in sinks:
		if cf.active.has(cid) or cf.amount[cid] != 0.0 or cf.ftype[cid] != 0 or cf.flow_dir.has(cid):
			bad += 1
	return bad


# Structural trap check (sink runs). A shore cell -- a non-sink cell that can
# flow into a sink -- whose ground head is below its lowest such sink's head
# has to fill before it drains, unless a level-or-downhill path through other
# cells reaches a sink no higher than its ground (a shore between two bodies at
# different surfaces). Untyped cf: a pre-P3-A CellFluid has no sinks to judge.
# Returns (shore cells, traps).
func _shore_traps(cf, is_snk: PackedByteArray) -> Vector2i:
	var shore := 0
	var traps := 0
	for cid in _graph.cell_count:
		if is_snk[cid] == 1:
			continue
		var nbs: Array = cf._nb_cache[cid]
		var opens: PackedByteArray = cf._edges(cid)
		var lo := INF
		for j in nbs.size():
			var nb: int = nbs[j]
			if is_snk[nb] == 1 and (j >= opens.size() or opens[j] == 1):
				var h: float = cf._ground_head(nb)
				lo = minf(lo, h)
		if lo == INF:
			continue
		shore += 1
		var g: float = cf._ground_head(cid)
		if g >= lo - HEAD_TOL:
			continue
		if not _drains_at(cf, is_snk, cid, g + HEAD_TOL):
			traps += 1
	return Vector2i(shore, traps)


# True when fluid standing at `level` on `start` reaches a sink whose head is
# no higher, through open edges and cells whose ground head is no higher.
# heads: HEADS_NOW (the clamp's raised heads, sinks at theirs), HEADS_ORIG
# (every non-sink cell at its ORIGINAL ground, CellGraph.ground_elev; sinks at
# their heads) or HEADS_VISUAL (every cell at its original ground, the sinks'
# seabed too: a sink is just open water to reach, as 'visual' runs it).
func _drains_at(cf, is_snk: PackedByteArray, start: int, level: float, heads: int = HEADS_NOW) -> bool:
	if _drain_mark.size() != _graph.cell_count:
		_drain_mark = PackedInt32Array()
		_drain_mark.resize(_graph.cell_count)
		_drain_gen = 0
	_drain_gen += 1
	_drain_mark[start] = _drain_gen
	var queue := PackedInt32Array([start])
	var qi := 0
	while qi < queue.size():
		var c := queue[qi]
		qi += 1
		var nbs: Array = cf._nb_cache[c]
		var opens: PackedByteArray = cf._edges(c)
		for j in nbs.size():
			var nb: int = nbs[j]
			if _drain_mark[nb] == _drain_gen or (j < opens.size() and opens[j] == 0):
				continue
			_drain_mark[nb] = _drain_gen
			var h: float = cf._ground_head(nb)
			if heads == HEADS_VISUAL or (heads == HEADS_ORIG and is_snk[nb] == 0):
				h = _graph.ground_elev(nb) * CellFluid.HEAD_PER_STORY
			if h > level:
				continue
			if is_snk[nb] == 1:
				return true
			queue.append(nb)
	return false


# Over-raise check (sink runs): the cells the waterline clamp raised (a
# non-sink cell whose ground head is above its own ground), and of those the
# ones it had no business raising: one that drained at its own ground already
# (original grounds, sinks at their heads: a slope it flattened), or one that
# is a pit in 'visual' too (no level-or-downhill path to open water with every
# cell at its original ground: a pond it filled, not a trap the sinks made).
# `dry` counts the raised cells with no open water under their footprint (no
# tile within the cell's radius of its centroid is open water or a deck over
# shallow water), for information only: a seabed-level cell a hop behind the
# straddling shore cell is a trap the sinks made with dry tiles under it
# (tg_hillside_harbor cid 1875, tile (28, 10)).
# Returns {raised, count, drained, pit, dry, worst}.
func _over_raised(cf, is_snk: PackedByteArray) -> Dictionary:
	var raised := 0
	var drained := 0
	var pit := 0
	var dry := 0
	var bad := 0
	var worst := "none"
	for cid in _graph.cell_count:
		if is_snk[cid] == 1:
			continue
		var g0: float = _graph.ground_elev(cid) * CellFluid.HEAD_PER_STORY
		if float(cf._ground_head(cid)) <= g0 + HEAD_TOL:
			continue
		raised += 1
		var d: bool = _drains_at(cf, is_snk, cid, g0 + HEAD_TOL, HEADS_ORIG)
		var p: bool = not _drains_at(cf, is_snk, cid, g0 + HEAD_TOL, HEADS_VISUAL)
		if d:
			drained += 1
		if p:
			pit += 1
		if not _wet_footprint(cid):
			dry += 1
		if d or p:
			bad += 1
			if worst == "none":
				worst = "cid %d tile %s ground %.2f -> %.2f stories (%s)" % [cid,
					str(GridManager.world_to_map(_graph.centroid(cid))), g0 / CellFluid.HEAD_PER_STORY,
					float(cf._ground_head(cid)) / CellFluid.HEAD_PER_STORY, "drained already" if d else "a pit in visual"]
	return {"raised": raised, "count": bad, "drained": drained, "pit": pit, "dry": dry, "worst": worst}


# Drain-kept check (sink runs), independent of how the clamp finds its traps:
# every raised cell drains at its raised head with the clamp's heads (stuck
# otherwise: raised, and still a basin), and no other non-sink cell that
# drained at its own ground before the clamp (original grounds, sinks at
# their heads) has lost that drain to a raised cell (cut). A cell whose
# ground is above every raised head can't lose it (raised cells stand no
# higher than that), so only cells at or below the highest raised head are
# walked. Returns {checked, stuck, cut, worst}.
func _drain_kept(cf, is_snk: PackedByteArray) -> Dictionary:
	var top := -INF
	var raised := PackedByteArray()
	raised.resize(_graph.cell_count)
	for cid in _graph.cell_count:
		if is_snk[cid] == 1:
			continue
		var h: float = cf._ground_head(cid)
		if h > _graph.ground_elev(cid) * CellFluid.HEAD_PER_STORY + HEAD_TOL:
			raised[cid] = 1
			top = maxf(top, h)
	var checked := 0
	var stuck := 0
	var cut := 0
	var worst := "none"
	for cid in _graph.cell_count:
		if is_snk[cid] == 1:
			continue
		var h: float = cf._ground_head(cid)
		var bad := ""
		if raised[cid] == 1:
			checked += 1
			if not _drains_at(cf, is_snk, cid, h + HEAD_TOL, HEADS_NOW):
				stuck += 1
				bad = "raised to %.2f stories and still a basin" % (h / CellFluid.HEAD_PER_STORY)
		elif h <= top + HEAD_TOL:
			checked += 1
			# the clamp's heads first: a cell that still drains ends its walk at the
			# first sink, and most do
			if not _drains_at(cf, is_snk, cid, h + HEAD_TOL, HEADS_NOW) and _drains_at(cf, is_snk, cid, h + HEAD_TOL, HEADS_ORIG):
				cut += 1
				bad = "drained at %.2f stories before the clamp, not after" % (h / CellFluid.HEAD_PER_STORY)
		if bad != "" and worst == "none":
			worst = "cid %d tile %s %s" % [cid, str(GridManager.world_to_map(_graph.centroid(cid))), bad]
	return {"checked": checked, "stuck": stuck, "cut": cut, "worst": worst}


# Some tile the cell's disc (CellGraph.radius around its centroid) touches is
# open water (GridManager.water_surface_at, under a deck too) or a deck over
# shallow water.
func _wet_footprint(cid: int) -> bool:
	var c: Vector2 = _graph.centroid(cid)
	var rad: float = _graph.radius(cid)
	var ts: float = float(GridManager.TILE_SIZE)
	for ty in range(floori((c.y - rad) / ts), floori((c.y + rad) / ts) + 1):
		for tx in range(floori((c.x - rad) / ts), floori((c.x + rad) / ts) + 1):
			var qx: float = clampf(c.x, float(tx) * ts, float(tx + 1) * ts)
			var qy: float = clampf(c.y, float(ty) * ts, float(ty + 1) * ts)
			if (qx - c.x) * (qx - c.x) + (qy - c.y) * (qy - c.y) > rad * rad:
				continue
			var t := Vector2i(tx, ty)
			if not is_nan(float(GridManager.call("water_surface_at", t))):
				return true
			if GridManager.deck_elevations.has(t) and GridManager.floors.get(t, "") == "shallow_water":
				return true
	return false


# Dynamic trap check (sink runs): the non-sink cells that end the run deeper
# than the same scenario's visual run by more than TRAP_TOL AND deeper than
# their puddle floor + TRAP_FLOOR. A shore basin the sinks made fills well past
# both; a cell under the well or in a real pit is just as deep in visual.
# Returns {count, worst: "depth sink/visual at cid tile", cells: cid -> true}.
func _deeper_than_visual(cf, is_snk: PackedByteArray, vis: PackedFloat32Array) -> Dictionary:
	var count := 0
	var cells := {}
	var worst := ""
	var worst_x := -INF
	for cid in _graph.cell_count:
		if is_snk[cid] == 1:
			continue
		var s: float = cf.amount[cid]
		if s <= 0.0:
			continue
		var v: float = vis[cid] if cid < vis.size() else 0.0
		var pud: float = cf._puddle_of(int(cf.ftype[cid]))
		var x: float = s - maxf(v + TRAP_TOL, pud + TRAP_FLOOR)
		if x > worst_x:
			worst_x = x
			worst = "%.3f sink / %.3f visual at cid %d tile %s" % [s, v, cid,
				str(GridManager.world_to_map(_graph.centroid(cid)))]
		if x > 0.0:
			count += 1
			cells[cid] = true
	return {"count": count, "worst": worst, "cells": cells}


# Cells standing on a walkable deck (walk_elev) whose tile is over water.
func _deck_water_cells() -> PackedInt32Array:
	var out := PackedInt32Array()
	for cid in _graph.cell_count:
		var t: Vector2i = GridManager.world_to_map(_graph.centroid(cid))
		if not GridManager.deck_elevations.has(t):
			continue
		var wet: bool = GridManager.floors.get(t, "") == "shallow_water"
		if GridManager.has_method("water_body_at"):
			wet = wet or int(GridManager.call("water_body_at", t)) > 0
		if wet:
			out.append(cid)
	return out


func _rain_tiles() -> Array:
	var out: Array = []
	var rect: Rect2i = GridManager.map_rect
	for y in rect.size.y:
		for x in rect.size.x:
			var t := Vector2i(x, y)
			if bool(GridManager.walls.get(t, true)) or GridManager.has_roof(t):
				continue
			out.append(t)
	return out


func _mass_in_cells(cf: CellFluid) -> float:
	var s := 0.0
	for i in cf.amount.size():
		s += cf.amount[i]
	return s


# The fluid state a later tick depends on: every cell's depth and type, and the
# active set in iteration order.
func _state_hash(cf: CellFluid) -> String:
	var hc := HashingContext.new()
	hc.start(HashingContext.HASH_SHA256)
	hc.update(cf.amount.to_byte_array())
	hc.update(cf.ftype)
	var keys := PackedInt32Array()
	for cid in cf.active:
		keys.append(int(cid))
	hc.update(keys.to_byte_array())
	return hc.finish().hex_encode()


func _stats(a: Array) -> Dictionary:
	if a.is_empty():
		return {"n": 0, "mean": 0.0, "p50": 0.0, "p95": 0.0, "max": 0.0}
	var s: Array = a.duplicate()
	s.sort()
	var tot := 0.0
	for v in s:
		tot += float(v)
	return {"n": s.size(), "mean": tot / float(s.size()),
		"p50": float(s[int(0.50 * float(s.size() - 1))]),
		"p95": float(s[int(ceil(0.95 * float(s.size() - 1)))]),
		"max": float(s[s.size() - 1])}


# --- reporting ---------------------------------------------------------------

func _print_result(mid: String, sc: Dictionary, mode: String, r: Dictionary) -> void:
	if not bool(r.get("ok", false)):
		print("RUN %s %s %s: no CellFluid" % [mid, sc["id"], mode])
		return
	var tk: Dictionary = r["tick"]
	var fr: Dictionary = r["frame"]
	var site: Vector2 = sc["site"]
	print("RUN %s %s %s site=(%d,%d) secs=%.0f | flow ticks=%d p50=%.3f p95=%.3f max=%.3f ms | frame mean=%.3f p95=%.3f max=%.3f ms | active peak=%d end=%d | sinks=%d deck_cells=%d | setup %.1f ms" % [
		mid, sc["id"], mode, int(site.x), int(site.y), float(sc["secs"]),
		int(tk["n"]), float(tk["p50"]), float(tk["p95"]), float(tk["max"]),
		float(fr["mean"]), float(fr["p95"]), float(fr["max"]),
		int(r["peak_active"]), int(r["final_active"]), int(r["sinks"]), int(r["decks"]), float(r.get("setup_ms", 0.0))])
	print("  REPEATS %s %s %s tick p95 [%s] ms, frame mean [%s] ms (the RUN line is the median of each; best: tick p95 %.3f, frame mean %.3f / p95 %.3f ms)" % [
		mid, sc["id"], mode, r.get("repeat_p95", ""), r.get("repeat_mean", ""),
		float(r.get("tick_p95_best", 0.0)), float(r.get("frame_mean_best", 0.0)), float(r.get("frame_p95_best", 0.0))])
	if bool(r["api"]):
		var led: Dictionary = r["ledger"]
		print("  MASS %s %s %s poured=%.4f in_cells=%.4f drained=%.4f (%s %.4f) evaporated=%.4f lost=%.4f residual=%s %s" % [
			mid, sc["id"], mode, float(led.get("poured", 0.0)), float(r["in_cells"]),
			float(led.get("drained", 0.0)), sc["fluid"], float(r["drained_type"]),
			float(led.get("evaporated", 0.0)), float(led.get("lost", 0.0)),
			_sci(float(r["mass_residual"])), "CLOSES" if bool(r["mass_ok"]) else "OPEN"])
		print("  SINKS %s %s %s violations=%d %s" % [
			mid, sc["id"], mode, int(r["sink_violations"]),
			"deck check: n/a (0 deck cells)" if int(r["decks"]) == 0
				else "deck_violations=%d of %d deck cells" % [int(r["deck_violations"]), int(r["decks"])]])
		if mode == "sink":
			var dyn: String = "deeper_than_visual=skipped (no visual run)"
			if bool(r.get("traps_run", false)):
				dyn = "deeper_than_visual=%d (closest: %s)" % [int(r["traps"]), String(r.get("trap_worst", "n/a"))]
			print("  TRAPS %s %s %s waterline_cells=%d shore_cells=%d below_sink_head=%d | %s | raised=%d over_raised=%d (drained already %d, a pit in visual %d; first: %s; info: %d raised with no water under them) | drain_kept: stuck=%d cut=%d of %d (first: %s)" % [
				mid, sc["id"], mode, int(r["waterline"]), int(r["shore_cells"]), int(r["shore_traps"]), dyn,
				int(r["raised"]), int(r["over_raised"]), int(r.get("over_drained", 0)), int(r.get("over_pit", 0)),
				String(r.get("over_worst", "none")), int(r.get("over_dry", 0)),
				int(r.get("kept_stuck", 0)), int(r.get("kept_cut", 0)), int(r.get("kept_checked", 0)), String(r.get("kept_worst", "none"))])
	else:
		print("  MASS %s %s %s in_cells=%.4f well_deposited=%.4f (no ledger in this tree)" % [
			mid, sc["id"], mode, float(r["in_cells"]), float(r["well_deposited"])])
	print("  STATE %s %s %s sha256=%s" % [mid, sc["id"], mode, r["hash"]])


func _verdict(mid: String, results: Dictionary, sink_api: bool) -> void:
	var vis: Dictionary = results.get("visual", {})
	var snk: Dictionary = results.get("sink", {})
	if not sink_api or snk.is_empty():
		print("VERDICT %s: n/a (%s)" % [mid, "no sink API in this tree" if not sink_api else "sink mode not run"])
		return
	var why: Array = []
	var worst_tick := 0.0
	var worst_tick_best := 0.0
	var worst_dmean := -INF
	var worst_dp95 := -INF
	var worst_dmean_best := -INF
	var worst_dp95_best := -INF
	var deck_cells := 0
	for sid in snk:
		var r: Dictionary = snk[sid]
		if not bool(r.get("ok", false)):
			why.append("%s: no sim" % sid)
			continue
		var tp95: float = float((r["tick"] as Dictionary)["p95"])
		worst_tick = maxf(worst_tick, tp95)
		worst_tick_best = maxf(worst_tick_best, float(r.get("tick_p95_best", tp95)))
		if tp95 > TICK_BUDGET_MS:
			why.append("%s: tick p95 %.3f ms > %.1f" % [sid, tp95, TICK_BUDGET_MS])
		if vis.has(sid):
			var v: Dictionary = vis[sid]
			var dmean: float = float((r["frame"] as Dictionary)["mean"]) - float((v["frame"] as Dictionary)["mean"])
			var dp95: float = float((r["frame"] as Dictionary)["p95"]) - float((v["frame"] as Dictionary)["p95"])
			worst_dmean = maxf(worst_dmean, dmean)
			worst_dp95 = maxf(worst_dp95, dp95)
			worst_dmean_best = maxf(worst_dmean_best, float(r.get("frame_mean_best", 0.0)) - float(v.get("frame_mean_best", 0.0)))
			worst_dp95_best = maxf(worst_dp95_best, float(r.get("frame_p95_best", 0.0)) - float(v.get("frame_p95_best", 0.0)))
			if dmean > FRAME_BUDGET_MS or dp95 > FRAME_BUDGET_MS:
				why.append("%s: frame delta mean %+.3f / p95 %+.3f ms > %.1f" % [sid, dmean, dp95, FRAME_BUDGET_MS])
		else:
			why.append("%s: no visual run to compare" % sid)
		if not bool(r.get("mass_ok", false)):
			why.append("%s: mass open by %s" % [sid, _sci(float(r.get("mass_residual", 0.0)))])
		if int(r["sink_violations"]) > 0:
			why.append("%s: %d sink violations" % [sid, int(r["sink_violations"])])
		if int(r["deck_violations"]) > 0:
			why.append("%s: %d deck cells over water are sinks or traps" % [sid, int(r["deck_violations"])])
		if int(r.get("shore_traps", 0)) > 0:
			why.append("%s: %d shore cells sit below their sink's head" % [sid, int(r["shore_traps"])])
		if int(r.get("traps", 0)) > 0:
			why.append("%s: %d cells end deeper than in visual (%s)" % [sid, int(r["traps"]), String(r.get("trap_worst", ""))])
		if int(r.get("over_raised", 0)) > 0:
			why.append("%s: the clamp raised %d cells it should not have (%s)" % [sid, int(r["over_raised"]), String(r.get("over_worst", ""))])
		if int(r.get("kept_stuck", 0)) + int(r.get("kept_cut", 0)) > 0:
			why.append("%s: %d raised cells still trap and %d cells lost their drain (%s)" % [sid, int(r.get("kept_stuck", 0)),
				int(r.get("kept_cut", 0)), String(r.get("kept_worst", ""))])
		deck_cells = maxi(deck_cells, int(r.get("decks", 0)))
		if int(r["sinks"]) == 0:
			why.append("%s: no sink cells" % sid)
		if _shore(sid) and float(r.get("drained_type", 0.0)) <= 0.0:
			why.append("%s: the shore spill never reached a sink" % sid)
	var ship := "sink" if why.is_empty() else "visual"
	var deltas: String = "n/a (no visual run)"
	if worst_dmean != -INF:
		deltas = "mean %+.3f / p95 %+.3f ms; best: %.3f ms, %+.3f / %+.3f ms" % [worst_dmean, worst_dp95,
			worst_tick_best, worst_dmean_best, worst_dp95_best]
	print("VERDICT %s: ship '%s' (median of %d: worst tick p95 %.3f ms, worst frame delta %s; %s)%s" % [
		mid, ship, _repeats, worst_tick, deltas,
		"deck check: n/a (0 deck cells)" if deck_cells == 0 else "deck check: %d deck cells" % deck_cells,
		"" if why.is_empty() else " -- " + "; ".join(why)])


# GDScript's % has no %e: a residual in scientific notation.
func _sci(v: float) -> String:
	if v == 0.0:
		return "0"
	var e: int = floori(log(absf(v)) / log(10.0))
	return "%.2fe%d" % [v / pow(10.0, e), e]


func _shore(sid: String) -> bool:
	return sid != "harbor_rain_storm"
