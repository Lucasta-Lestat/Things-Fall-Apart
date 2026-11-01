extends Node2D
# The sea drain's moving parts on a hand-built map (P3-A), where
# fluid_sink_bench runs the shipped maps. No shipped cells.json carries the
# contract-3 open-water layer yet, so this is the only test of that path:
#   - CellGraph reads cells.json tile_water/tile_body; GridManager installs the
#     pair only when it is exactly the map's tiles and answers
#     water_surface_at / water_body_at from it, else from the deep-water rule;
#     is_deep_water's verdicts never move;
#   - MapLoader.resolve_water_sim: the entry key, the tfa/fluids/sea_sink
#     override, the bad values;
#   - CellFluid sinks: tagged from the layer (each body at its own surface),
#     never under a deck; inflow, deposit, polite deposit, pour and a source
#     onto a sink drain at once; nothing ever stands in or leaves a sink; every
#     fluid type drains; the mass ledger closes; a deck over water keeps its
#     level; 'visual' builds no sinks;
#   - FluidWell (Oil Well) skips sinks so its budget fills the land.
# The map: 10 x 6 tiles of 64 px, one cell per tile. Columns 0-4 are a quay at
# 0.5 stories, 5-9 the sea (seabed -1.0, surface 0.0, body 1) except column 9,
# a separate body at surface 0.3 (body 2). Tile (7, 2) carries a deck.
# Headless:  godot --headless --path . res://tests/water_sink_check.tscn
const MAP_LOADER := preload("res://Structures/MapLoader.gd")
const COLS := 10
const ROWS := 6
const T := 64
const DECK := Vector2i(7, 2)
const CELLS_PATH := "user://water_sink_check_cells.json"

var map_loader: Node2D = null   # FluidManager.setup_cell_graph reads water_sim here
var fails := 0
var checks := 0


func _check(cname: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if not ok:
		fails += 1
	print("%s %s %s" % ["PASS" if ok else "FAIL", cname, detail])


func _sea(x: int) -> bool:
	return x >= 5


# cells.json for the test map; layer: "pair" | "none" | "bad_dims" | "half".
func _write_cells(layer: String) -> void:
	var cx: Array = []
	var cy: Array = []
	var r: Array = []
	var fuel: Array = []
	var elev: Array = []
	var roof: Array = []
	var nb_off: Array = []
	var nb: Array = []
	var te: Array = []
	var tw: Array = []
	var tb: Array = []
	for y in ROWS:
		for x in COLS:
			cx.append((x + 0.5) * T)
			cy.append((y + 0.5) * T)
			r.append(32.0)
			fuel.append(0.0)
			var e: float = -1.0 if _sea(x) else 0.5
			elev.append(e)
			roof.append(0.0)
			te.append(e)
			tw.append(0.3 if x == 9 else 0.0)
			tb.append(2 if x == 9 else (1 if _sea(x) else 0))
			nb_off.append(nb.size())
			for d in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
				var n: Vector2i = Vector2i(x, y) + d
				if n.x >= 0 and n.y >= 0 and n.x < COLS and n.y < ROWS:
					nb.append(n.y * COLS + n.x)
	nb_off.append(nb.size())
	var data := {"n": COLS * ROWS, "export_scale": 2.0, "cx": cx, "cy": cy, "r": r, "fuel": fuel,
		"elev": elev, "roof": roof, "nb_off": nb_off, "nb": nb,
		"tile_elev": {"cols": COLS, "rows": ROWS, "data": te}}
	if layer == "pair":
		data["tile_water"] = {"cols": COLS, "rows": ROWS, "data": tw}
		data["tile_body"] = {"cols": COLS, "rows": ROWS, "data": tb}
	elif layer == "bad_dims":
		data["tile_water"] = {"cols": COLS - 1, "rows": ROWS, "data": tw.slice(0, (COLS - 1) * ROWS)}
		data["tile_body"] = {"cols": COLS - 1, "rows": ROWS, "data": tb.slice(0, (COLS - 1) * ROWS)}
	elif layer == "half":
		data["tile_water"] = {"cols": COLS, "rows": ROWS, "data": tw}
	var f := FileAccess.open(CELLS_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()


# Load the test map into GridManager the way Game.load_map does: graph, then
# terrain + water (set_elevation_data), then floors and the deck (MapLoader).
func _load(layer: String) -> CellGraph:
	_write_cells(layer)
	GridManager.TILE_SIZE = T
	GridManager.initialize(COLS * T, ROWS * T)
	var g: CellGraph = CellGraph.from_structured(CELLS_PATH)
	GridManager.set_elevation_data(g)
	for y in ROWS:
		for x in COLS:
			GridManager.floors[Vector2i(x, y)] = "shallow_water" if _sea(x) else "floor_stone"
	GridManager.register_deck(DECK, 0.5)
	return g


func _deep_verdicts() -> PackedByteArray:
	var out := PackedByteArray()
	for y in ROWS:
		for x in COLS:
			out.append(1 if GridManager.is_deep_water(Vector2i(x, y)) else 0)
	return out


func _ready() -> void:
	await get_tree().process_frame
	var ml: Node2D = MAP_LOADER.new()
	map_loader = ml
	var fm := FluidManager.new()
	fm.name = "FluidManager"   # FluidWell looks it up by name
	add_child(fm)
	await get_tree().process_frame

	# --- the layer and the accessor ------------------------------------------
	var g := _load("none")
	var deep_none := _deep_verdicts()
	_check("fallback.no-layer", not GridManager.has_water_layer(), "")
	_check("fallback.surface", GridManager.water_surface_at(Vector2i(6, 1)) == GridManager.SEA_SURFACE_ELEV
		and GridManager.water_body_at(Vector2i(6, 1)) == 1, "deep tile reads the sea surface, body 1")
	_check("fallback.land", is_nan(GridManager.water_surface_at(Vector2i(2, 1))) and GridManager.water_body_at(Vector2i(2, 1)) == 0, "")
	_check("fallback.deck-is-not-deep", is_nan(GridManager.water_surface_at(DECK)), "the deep-water rule reads the deck")

	g = _load("pair")
	_check("layer.used", GridManager.has_water_layer(), "")
	_check("layer.sea", GridManager.water_surface_at(Vector2i(6, 1)) == 0.0 and GridManager.water_body_at(Vector2i(6, 1)) == 1, "")
	var s9: float = GridManager.water_surface_at(Vector2i(9, 3))
	_check("layer.own-surface", is_equal_approx(s9, 0.3) and GridManager.water_body_at(Vector2i(9, 3)) == 2,
		"column 9 surface %.3f body %d" % [s9, GridManager.water_body_at(Vector2i(9, 3))])
	_check("layer.land", is_nan(GridManager.water_surface_at(Vector2i(4, 0))) and GridManager.water_body_at(Vector2i(4, 0)) == 0, "")
	_check("layer.off-map", is_nan(GridManager.water_surface_at(Vector2i(-1, 0))) and GridManager.water_body_at(Vector2i(COLS, 0)) == 0, "")
	_check("layer.under-deck", GridManager.water_body_at(DECK) == 1, "the layer reports the water under a deck")
	_check("layer.deep-water-unchanged", _deep_verdicts() == deep_none, "is_deep_water verdicts with and without the layer")

	_load("bad_dims")
	_check("layer.bad-dims-fall-back", not GridManager.has_water_layer()
		and GridManager.water_surface_at(Vector2i(9, 3)) == GridManager.SEA_SURFACE_ELEV, "")
	_load("half")
	_check("layer.half-pair-falls-back", not GridManager.has_water_layer(), "")

	# --- the switch ------------------------------------------------------------
	var setting: String = MAP_LOADER.WATER_SIM_SETTING
	ProjectSettings.set_setting(setting, "auto")
	_check("switch.absent-is-visual", MAP_LOADER.resolve_water_sim({}) == "visual", "")
	_check("switch.entry-sink", MAP_LOADER.resolve_water_sim({"water_sim": "sink"}) == "sink", "")
	_check("switch.entry-visual", MAP_LOADER.resolve_water_sim({"water_sim": "visual"}) == "visual", "")
	_check("switch.bad-entry", MAP_LOADER.resolve_water_sim({"water_sim": "drain"}) == "visual", "")
	ProjectSettings.set_setting(setting, "sink")
	_check("switch.override-sink", MAP_LOADER.resolve_water_sim({"water_sim": "visual"}) == "sink", "")
	ProjectSettings.set_setting(setting, "visual")
	_check("switch.override-visual", MAP_LOADER.resolve_water_sim({"water_sim": "sink"}) == "visual", "")
	ProjectSettings.set_setting(setting, "bogus")
	_check("switch.bad-override-uses-entry", MAP_LOADER.resolve_water_sim({"water_sim": "sink"}) == "sink", "")
	ProjectSettings.set_setting(setting, "auto")

	# --- 'visual' builds no sinks: the sea holds what lands on it ---------------
	g = _load("pair")
	ml.set("water_sim", "visual")
	fm.setup_cell_graph(g)
	var cf: CellFluid = fm.cell_fluid
	_check("visual.no-sinks", cf.sink_count == 0 and not cf.is_sink(g.cell_at(Vector2(6.5 * T, 1.5 * T))), "")
	cf.deposit(Vector2(6.5 * T, 1.5 * T), "water", 0.4)
	_check("visual.sea-holds-fluid", cf.amount_at(g.cell_at(Vector2(6.5 * T, 1.5 * T))) > 0.39, "")

	# --- 'sink' ----------------------------------------------------------------
	ml.set("water_sim", "sink")
	fm.setup_cell_graph(g)
	cf = fm.cell_fluid
	var deck_cid := g.cell_at(GridManager.map_to_world(DECK))
	var want_sinks := 5 * ROWS - 1
	_check("sink.count", cf.sink_count == want_sinks, "%d sinks, want %d (the sea minus the deck)" % [cf.sink_count, want_sinks])
	_check("sink.not-under-deck", not cf.is_sink(deck_cid), "")
	var c9 := g.cell_at(GridManager.map_to_world(Vector2i(9, 3)))
	_check("sink.own-head", cf.is_sink(c9) and is_equal_approx(cf._head(c9), 0.3 * CellFluid.HEAD_PER_STORY),
		"column 9 head %.3f" % cf._head(c9))
	var c6 := g.cell_at(GridManager.map_to_world(Vector2i(6, 1)))
	_check("sink.sea-head", is_equal_approx(cf._head(c6), 0.0), "head %.3f (surface, not the seabed)" % cf._head(c6))

	# a deck cell holding water, out in the sea
	cf.deposit(GridManager.map_to_world(DECK), "water", 0.3)
	var deck0: float = cf.amount_at(deck_cid)
	# a quay spill next to the sea, a direct deposit, a polite one, a pour across
	# the shore and a spring on the water
	var quay := GridManager.map_to_world(Vector2i(4, 4))
	cf.deposit(quay, "water", 0.8)
	var d0: float = cf.drained_mass("water")
	cf.deposit(GridManager.map_to_world(Vector2i(6, 4)), "water", 0.25)
	_check("sink.deposit-drains", is_equal_approx(cf.drained_mass("water") - d0, 0.25)
		and cf.amount_at(g.cell_at(GridManager.map_to_world(Vector2i(6, 4)))) == 0.0, "")
	d0 = cf.drained_mass("water")
	cf.deposit(GridManager.map_to_world(Vector2i(6, 5)), "water", 0.1, false)
	_check("sink.polite-deposit-drains", is_equal_approx(cf.drained_mass("water") - d0, 0.1), "")
	var poured_n := cf.pour(GridManager.map_to_world(Vector2i(5, 0)), "water", 0.5, 80.0)
	_check("sink.pour", poured_n > 0, "%d cells poured" % poured_n)
	cf.add_source(GridManager.map_to_world(Vector2i(8, 5)), "water", 0.2)
	cf.deposit(GridManager.map_to_world(Vector2i(4, 1)), "oil", 0.9)
	var leaks := 0
	for i in 600:   # 10 s
		cf.tick(1.0 / 60.0)
		for cid in cf.active:
			if cf.is_sink(cid):
				leaks += 1
		if i % 15 == 0:
			for cid in g.cell_count:
				if cf.is_sink(cid) and (cf.amount[cid] != 0.0 or cf.flow_dir.has(cid)):
					leaks += 1
	_check("sink.never-holds-or-sheds", leaks == 0, "%d sink sightings in active / holding fluid" % leaks)
	_check("sink.quay-spill-drains", cf.drained_mass("water") > 0.5, "water drained %.3f" % cf.drained_mass("water"))
	_check("sink.oil-drains", cf.drained_mass("oil") > 0.0, "oil drained %.3f" % cf.drained_mass("oil"))
	_check("sink.source-drains", cf.drained_mass("water") > 2.0 and cf.sources.size() == 1, "a 0.2/s spring on the sea for 10 s")
	var deck1: float = cf.amount_at(deck_cid)
	# 40 flow ticks of water evaporation (0.002/s) is all it may lose
	_check("sink.deck-keeps-level", deck1 <= deck0 and deck0 - deck1 <= 40.0 * CellFluid.EVAP_PER_SEC * CellFluid.SIM_INTERVAL + 1e-6,
		"deck %.4f -> %.4f (evaporation only)" % [deck0, deck1])
	var led: Dictionary = cf.mass_ledger()
	var in_cells := 0.0
	for i in cf.amount.size():
		in_cells += cf.amount[i]
	var res: float = float(led["poured"]) - in_cells - float(led["drained"]) - float(led["evaporated"]) - float(led["lost"])
	_check("sink.mass-closes", absf(res) < 1e-4, "poured %.4f cells %.4f drained %.4f evaporated %.4f lost %.4f residual %.6f"
		% [float(led["poured"]), in_cells, float(led["drained"]), float(led["evaporated"]), float(led["lost"]), res])

	# --- Oil Well on the shore: the budget fills the land, not the sea ----------
	fm.setup_cell_graph(g)
	var well := FluidWell.new()
	well.fluid_type = "oil"
	well.radius = 150.0
	well.duration = 4.0
	well.visual_scene_path = ""
	add_child(well)
	well.global_position = Vector2(5.0 * T, 3.0 * T)   # on the shoreline
	well.set_process(false)
	well._process(0.05)
	var sink_targets := 0
	for cid in well._cells:
		if fm.cell_fluid.is_sink(cid):
			sink_targets += 1
	_check("well.skips-sinks", well._cells.size() > 0 and sink_targets == 0,
		"%d target cells, %d of them sinks" % [well._cells.size(), sink_targets])
	_check("well.budget-on-land", is_equal_approx(well._budget, float(well._cells.size()) * FluidWell.CELL_TARGET_DEPTH * FluidWell.BUDGET_SLACK), "")
	well.queue_free()

	ml.free()
	print("water_sink_check: %d checks, %d failures" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)
