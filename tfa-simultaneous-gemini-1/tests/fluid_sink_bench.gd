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
#   ossuary_channel_spill: a 0.6-deep pour two tiles from the narrow channel.
# Any other map gets one shore_water spill. Per scenario and mode it prints the
# CellFluid flow-tick p50/p95/max (the frames whose tick ran _flow_tick), the
# fluid frame (deposits + well + FluidManager.update_fluid_tick, replicated 1:1)
# mean/p95, peak active cells, the mass ledger and the end-state hash; then one
# VERDICT line per map: ship 'sink' when every sink run keeps the flow tick p95
# <= 2 ms and the frame delta vs 'visual' <= 1 ms (mean and p95; each the best
# of TFA_SINK_REPEAT repeats, the cost without the machine's noise), the mass
# closes, no sink ever holds or sheds fluid, deck cells over water never drain,
# and every shore spill reached a sink. Otherwise 'visual'.
# Headless:  godot --headless --path . res://tests/fluid_sink_bench.tscn
# Env: TFA_SINK_MAPS (comma list, default tg_hillside_harbor,tg_hillside_ossuary),
#      TFA_SINK_MODES (default visual,sink), TFA_SINK_ONLY=<scenario id>,
#      TFA_SINK_SECS (overrides every scenario's length), TFA_SINK_REPEAT
#      (default 3: each run is repeated and judged on its best repeat, so a
#      busy machine does not flip a verdict), TFA_SINK_CELLS=<dir>
#      (load <dir>/<id>_cells.json instead of the row's cell_graph: a contract-3
#      headless dump carries the tile_water layer the shipped files lack yet;
#      the bench never writes it anywhere).
# Exit 0 when every map's verdict could be reached (a 'visual' verdict is a
# result, not a failure), 1 on a setup error.
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
var _repeats := 3


func load_map(_a = null, _b = "", _c = "") -> void:
	pass   # SurfaceManager._get_game keys on this method name


func _ready() -> void:
	add_to_group("game")
	await get_tree().process_frame
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
			# it): repeat each run and judge the best repeat; every repeat must
			# end in the same state
			var reps: Array = []
			for _k in _repeats:
				reps.append(await _run(sc, mode))
			var r: Dictionary = _best_run(reps)
			(results[mode] as Dictionary)[sc["id"]] = r
			_print_result(mid, sc, mode, r)
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
	elif mid == "tg_hillside_ossuary":
		var c := _shore_site(true, -INF)
		if c == Vector2.INF:
			print("BENCH ERROR: %s: no bank site two tiles from the channel" % mid)
			_errors += 1
			return out
		out.append({"id": "ossuary_channel_spill", "kind": "spill", "site": c, "secs": 30.0, "fluid": "water", "shore": true})
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
	var sp: Dictionary = (current_map_data.get("player_spawns", {}) as Dictionary).get("default", {})
	var spa: Array = sp.get("position", [0, 0])
	var spawn := Vector2(float(spa[0]), float(spa[1]))
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


# --- one run -----------------------------------------------------------------

func _run(sc: Dictionary, mode: String) -> Dictionary:
	# the switch, exactly as a project-setting override would flip it
	ProjectSettings.set_setting("tfa/fluids/sea_sink", mode)
	if map_loader.has_method("resolve_water_sim"):
		map_loader.set("water_sim", map_loader.call("resolve_water_sim", current_map_data))
	fluid_manager.setup_cell_graph(_graph)
	await get_tree().process_frame   # let the previous run's sim and FX free
	var cf: CellFluid = fluid_manager.cell_fluid
	var r: Dictionary = {"ok": cf != null}
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
	var deck0 := PackedFloat32Array()
	for cid in decks:
		deck0.append(cf.amount[cid])
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
	for j in decks.size():
		if kind != "rain" and absf(cf.amount[decks[j]] - deck0[j]) > 1e-6:
			deck_violations += 1
		if api and cf.call("is_sink", decks[j]):
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


# Best of the repeats (the work is deterministic, so the least disturbed
# repeat is the closest reading of its cost): the lowest flow-tick p95, frame
# mean and frame p95, each taken on its own; every repeat's tick p95 and frame
# mean are listed. A repeat that ends in another state is a setup error.
func _best_run(reps: Array) -> Dictionary:
	var r: Dictionary = {}
	var p95s: Array = []
	var means: Array = []
	for rep in reps:
		var rd: Dictionary = rep
		if not bool(rd.get("ok", false)):
			continue
		var tk: Dictionary = rd["tick"]
		var fr: Dictionary = rd["frame"]
		p95s.append("%.3f" % float(tk["p95"]))
		means.append("%.3f" % float(fr["mean"]))
		if r.is_empty():
			r = rd.duplicate(true)
			continue
		if String(rd["hash"]) != String(r["hash"]):
			print("BENCH ERROR: a repeat ended in another state (%s vs %s)" % [rd["hash"], r["hash"]])
			_errors += 1
		if float(tk["p95"]) < float((r["tick"] as Dictionary)["p95"]):
			r["tick"] = tk.duplicate()
		var rf: Dictionary = r["frame"]
		rf["mean"] = minf(float(rf["mean"]), float(fr["mean"]))
		rf["p95"] = minf(float(rf["p95"]), float(fr["p95"]))
	if r.is_empty():
		return reps[0] if not reps.is_empty() else {"ok": false}
	r["repeat_p95"] = ",".join(p95s)
	r["repeat_mean"] = ",".join(means)
	return r


# Every flow tick: a sink never sits in `active`, never holds fluid and never
# reports an outflow direction (so nothing it "holds" can leave it).
func _sink_check(cf: CellFluid, sinks: PackedInt32Array) -> int:
	var bad := 0
	for cid in sinks:
		if cf.active.has(cid) or cf.amount[cid] != 0.0 or cf.ftype[cid] != 0 or cf.flow_dir.has(cid):
			bad += 1
	return bad


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
	print("RUN %s %s %s site=(%d,%d) secs=%.0f | flow ticks=%d p50=%.3f p95=%.3f max=%.3f ms | frame mean=%.3f p95=%.3f max=%.3f ms | active peak=%d end=%d | sinks=%d deck_cells=%d" % [
		mid, sc["id"], mode, int(site.x), int(site.y), float(sc["secs"]),
		int(tk["n"]), float(tk["p50"]), float(tk["p95"]), float(tk["max"]),
		float(fr["mean"]), float(fr["p95"]), float(fr["max"]),
		int(r["peak_active"]), int(r["final_active"]), int(r["sinks"]), int(r["decks"])])
	print("  REPEATS %s %s %s tick p95 [%s] ms, frame mean [%s] ms (the RUN line is the best of each)" % [
		mid, sc["id"], mode, r.get("repeat_p95", ""), r.get("repeat_mean", "")])
	if bool(r["api"]):
		var led: Dictionary = r["ledger"]
		print("  MASS %s %s %s poured=%.4f in_cells=%.4f drained=%.4f (%s %.4f) evaporated=%.4f lost=%.4f residual=%s %s" % [
			mid, sc["id"], mode, float(led.get("poured", 0.0)), float(r["in_cells"]),
			float(led.get("drained", 0.0)), sc["fluid"], float(r["drained_type"]),
			float(led.get("evaporated", 0.0)), float(led.get("lost", 0.0)),
			_sci(float(r["mass_residual"])), "CLOSES" if bool(r["mass_ok"]) else "OPEN"])
		print("  SINKS %s %s %s violations=%d deck_violations=%d" % [
			mid, sc["id"], mode, int(r["sink_violations"]), int(r["deck_violations"])])
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
	var worst_dmean := -INF
	var worst_dp95 := -INF
	for sid in snk:
		var r: Dictionary = snk[sid]
		if not bool(r.get("ok", false)):
			why.append("%s: no sim" % sid)
			continue
		var tp95: float = float((r["tick"] as Dictionary)["p95"])
		worst_tick = maxf(worst_tick, tp95)
		if tp95 > TICK_BUDGET_MS:
			why.append("%s: tick p95 %.3f ms > %.1f" % [sid, tp95, TICK_BUDGET_MS])
		if vis.has(sid):
			var v: Dictionary = vis[sid]
			var dmean: float = float((r["frame"] as Dictionary)["mean"]) - float((v["frame"] as Dictionary)["mean"])
			var dp95: float = float((r["frame"] as Dictionary)["p95"]) - float((v["frame"] as Dictionary)["p95"])
			worst_dmean = maxf(worst_dmean, dmean)
			worst_dp95 = maxf(worst_dp95, dp95)
			if dmean > FRAME_BUDGET_MS or dp95 > FRAME_BUDGET_MS:
				why.append("%s: frame delta mean %+.3f / p95 %+.3f ms > %.1f" % [sid, dmean, dp95, FRAME_BUDGET_MS])
		else:
			why.append("%s: no visual run to compare" % sid)
		if not bool(r.get("mass_ok", false)):
			why.append("%s: mass open by %s" % [sid, _sci(float(r.get("mass_residual", 0.0)))])
		if int(r["sink_violations"]) > 0:
			why.append("%s: %d sink violations" % [sid, int(r["sink_violations"])])
		if int(r["deck_violations"]) > 0:
			why.append("%s: %d deck cells drained or changed" % [sid, int(r["deck_violations"])])
		if int(r["sinks"]) == 0:
			why.append("%s: no sink cells" % sid)
		if _shore(sid) and float(r.get("drained_type", 0.0)) <= 0.0:
			why.append("%s: the shore spill never reached a sink" % sid)
	var ship := "sink" if why.is_empty() else "visual"
	print("VERDICT %s: ship '%s' (worst tick p95 %.3f ms, worst frame delta mean %+.3f / p95 %+.3f ms)%s" % [
		mid, ship, worst_tick, worst_dmean, worst_dp95,
		"" if why.is_empty() else " -- " + "; ".join(why)])


# GDScript's % has no %e: a residual in scientific notation.
func _sci(v: float) -> String:
	if v == 0.0:
		return "0"
	var e: int = floori(log(absf(v)) / log(10.0))
	return "%.2fe%d" % [v / pow(10.0, e), e]


func _shore(sid: String) -> bool:
	return sid != "harbor_rain_storm"
