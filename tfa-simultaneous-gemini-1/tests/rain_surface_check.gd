extends Node2D
# Precipitation-surface regression check (cell maps). Rain puddles used to
# deposit 0.3 into a SINGLE ~31px cell, which spread to water's invisible pool
# floor within seconds — "rain no longer creates surfaces". rain_puddle now
# pours a small polite blot and water/acid carry real pool floors, so a
# settled puddle must KEEP a visible depth. Also proves acid rain lays acid
# and that a rain pour never displaces an authored oil slick.
# Headless-safe.  Run:  godot --headless --path . res://tests/rain_surface_check.tscn
# Env:  TFA_MAP = map id (default tg_castle_keep)
var fails := 0
var checks := 0


func _check(name: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if not ok:
		fails += 1
		print("FAIL ", name, "  ", detail)


func _ready() -> void:
	var f := FileAccess.open("res://data/Maps.json", FileAccess.READ)
	var raw: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	var want := OS.get_environment("TFA_MAP")
	if want == "":
		want = "tg_castle_keep"
	var m: Dictionary = {}
	for e in raw.get("maps", []):
		if String(e.get("id", "")) == want:
			m = e
			break
	GridManager.TILE_SIZE = int(m.get("tile_size", 64))
	var graph: CellGraph = CellGraph.from_structured(String(m.get("cell_graph", "")))
	# No map_loader on this root: FluidManager skips the FX layer (headless).
	var fm := FluidManager.new()
	add_child(fm)
	fm.setup_cell_graph(graph)
	var cf: CellFluid = fm.cell_fluid
	_check("sim.active", cf != null and cf.active_sim())
	if fails > 0:
		print("rain_surface_check: %d checks, %d FAIL" % [checks, fails])
		get_tree().quit(1)
		return

	# Three well-separated FLAT open cells (a pour against a cliff face drains
	# downhill and would make depth thresholds terrain-dependent).
	var flats: Array[int] = []
	for cid in graph.cell_count:
		var g := graph.ground_elev(cid)
		var nbs: Array = graph.neighbors(cid)
		if nbs.size() < 4:
			continue
		var flat := true
		for nb in nbs:
			if absf(graph.ground_elev(nb) - g) > 0.05:
				flat = false
				break
		if not flat:
			continue
		var far := true
		for prev in flats:
			if graph.centroid(prev).distance_to(graph.centroid(cid)) < 300.0:
				far = false
				break
		if far:
			flats.append(cid)
		if flats.size() >= 4:
			break
	_check("map.flat-sites", flats.size() >= 4)
	if fails > 0:
		print("rain_surface_check: %d checks, %d FAIL" % [checks, fails])
		get_tree().quit(1)
		return

	# --- 1. rain -> a water puddle that SURVIVES settling at visible depth ---
	var t_water := GridManager.world_to_map(graph.centroid(flats[0]))
	fm.rain_puddle(t_water, "water", 0.35)
	var wet := 0
	for cid in cf.active:
		if cf.type_at(cid) == "water":
			wet += 1
	_check("rain.blot-not-a-dot", wet >= 3, "wet cells: %d" % wet)
	for _i in 60:
		cf._flow_tick()
	var deep_w := 0.0
	for cid in cf.active:
		if cf.type_at(cid) == "water":
			deep_w = maxf(deep_w, cf.amount[cid])
	_check("rain.settled-visible", deep_w >= 0.15, "max water depth %.3f" % deep_w)

	# --- 2. acid rain -> ACID, not water ---
	var t_acid := GridManager.world_to_map(graph.centroid(flats[1]))
	fm.rain_puddle(t_acid, "acid", 0.6)
	for _i in 60:
		cf._flow_tick()
	var deep_a := 0.0
	for cid in cf.active:
		if cf.type_at(cid) == "acid":
			deep_a = maxf(deep_a, cf.amount[cid])
	_check("acid-rain.settled-visible", deep_a >= 0.2, "max acid depth %.3f" % deep_a)

	# --- 3. a rain pour centered ON a SETTLED slick must not displace it ---
	# Settle first: an authored slick has already spread to its pool floor, so
	# it has no outward press left for the surrounding acid to bury (a fresh
	# unsettled pour legitimately loses its exuded films to a flood). Compare
	# the slick BODY (cells >= 0.2, which never evaporate), matching the
	# TFA_FLUID_RAINTEST contract.
	var slick_world := graph.centroid(flats[2])
	cf.deposit(slick_world, "oil", 0.5)
	for _i in 40:
		cf._flow_tick()
	var body0 := 0.0
	for cid in cf.active:
		if cf.type_at(cid) == "oil" and cf.amount[cid] >= 0.2:
			body0 += cf.amount[cid]
	_check("slick.settled-body-exists", body0 >= 0.2, "body %.3f" % body0)
	fm.rain_puddle(GridManager.world_to_map(slick_world), "acid", 0.6)
	for _i in 40:
		cf._flow_tick()
	var body1 := 0.0
	for cid in cf.active:
		if cf.type_at(cid) == "oil" and cf.amount[cid] >= 0.2:
			body1 += cf.amount[cid]
	_check("rain.polite-to-slicks", body1 >= body0 * 0.98,
		"slick body %.3f -> %.3f" % [body0, body1])

	# --- 4. a heavy blot CENTERED ON THE CELL BESIDE a settled slick must
	# stand off, not bury it (review find: a 0.5+ adjacent deposit tipped the
	# surface-only gate; the booked-front rule keeps sub-dominant fronts out) ---
	var slick2_world := graph.centroid(flats[3])
	cf.deposit(slick2_world, "oil", 0.5)
	for _i in 40:
		cf._flow_tick()
	var body2a := 0.0
	var body_cell := -1
	for cid in cf.active:
		if cf.type_at(cid) == "oil" and cf.amount[cid] >= 0.2:
			body2a += cf.amount[cid]
			if body_cell < 0:
				body_cell = cid
	# The settled slick's sub-floor films cover every direct neighbor — BFS
	# outward for the nearest EMPTY cell to center the blot on (the 42px pour
	# still lands acid against the slick's rim).
	var beside := -1
	if body_cell >= 0:
		var ring: Array = graph.neighbors(body_cell).duplicate()
		var seen := {body_cell: true}
		while not ring.is_empty() and beside < 0:
			var nxt: Array = []
			for nb in ring:
				if seen.has(nb):
					continue
				seen[nb] = true
				if cf.ftype[nb] == 0:
					beside = nb
					break
				nxt.append_array(graph.neighbors(nb))
			ring = nxt
	_check("adjacent-blot.setup", body_cell >= 0 and beside >= 0,
		"body cell %d beside %d" % [body_cell, beside])
	if beside >= 0:
		fm.rain_puddle(GridManager.world_to_map(graph.centroid(beside)), "acid", 0.6)
		for _i in 40:
			cf._flow_tick()
	var body2b := 0.0
	for cid in cf.active:
		if cf.type_at(cid) == "oil" and cf.amount[cid] >= 0.2:
			body2b += cf.amount[cid]
	_check("adjacent-blot.slick-stands", body2b >= body2a * 0.98,
		"slick body %.3f -> %.3f" % [body2a, body2b])

	print("rain_surface_check: %d checks, %d FAIL" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)
