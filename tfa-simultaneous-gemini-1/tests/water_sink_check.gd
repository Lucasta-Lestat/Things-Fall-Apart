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
#     fluid type drains; the mass ledger closes; 'visual' builds no sinks;
#   - the waterline clamp: shore cells whose own ground is the seabed while
#     their centroid tile is land, and the deck, sit at the waterline and shed
#     into the sea instead of trapping; an inland pit keeps its pond; a deck
#     over water is never a sink, keeps what lands on it, and sheds like it
#     does in 'visual';
#   - the clamp between two bodies (small layouts of their own): a slope from
#     an upper body down to a lower one keeps its ground and a pit beside it
#     its pond; a trap beside the upper body is raised only to the rim it
#     spills over, so the cell behind it still drains; a hollow beside a
#     perched pool (a pit in 'visual' too, its spill the same) keeps its pond;
#     a shore cell a little below the seabed (a shallow pit in 'visual' the
#     sinks deepen) goes to the waterline; the clamp is one flood, not a walk
#     per cell (a 48 x 48 yard below the waterline); and it floods only the
#     ground joined to a body below its head (a perched pool high above a
#     town adds nothing);
#   - FluidWell (Oil Well) skips sinks so its budget fills the land.
# The map: 10 x 6 tiles of 64 px, one cell per tile. Columns 0-4 are a quay at
# 0.5 stories, 5-9 the sea (seabed -1.0, surface 0.0, body 1) except column 9,
# a separate body at surface 0.3 (body 2). Tile (7, 2) carries a deck (its
# cell's ground is the seabed, as in an export). Quay tiles (4, 3) and (3, 3)
# are straddle cells: land tiles whose cells sit on the seabed (-1.0) and
# below sea level (-0.5). Quay tile (1, 3) is an inland pit at -0.5.
# Headless:  godot --headless --path . res://tests/water_sink_check.tscn
const MAP_LOADER := preload("res://Structures/MapLoader.gd")
const COLS := 10
const ROWS := 6
const T := 64
const DECK := Vector2i(7, 2)
const STRADDLE := Vector2i(4, 3)     # next to the sea
const STRADDLE2 := Vector2i(3, 3)    # behind it, below sea level
const PIT := Vector2i(1, 3)          # inland, below sea level, ringed by the quay
const CELLS_PATH := "user://water_sink_check_cells.json"
const LAYOUT_PATH := "user://water_sink_check_layout.json"

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
			te.append(e)
			# a cell's own ground can differ from its centroid tile's terrain
			var t := Vector2i(x, y)
			if t == STRADDLE:
				e = -1.0
			elif t == STRADDLE2 or t == PIT:
				e = -0.5
			elev.append(e)
			roof.append(0.0)
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

	# the waterline clamp: what straddles the shore sits at the sea surface
	var cs := g.cell_at(GridManager.map_to_world(STRADDLE))
	var cs2 := g.cell_at(GridManager.map_to_world(STRADDLE2))
	var cpit := g.cell_at(GridManager.map_to_world(PIT))
	_check("clamp.straddle-at-waterline", not cf.is_sink(cs) and is_equal_approx(cf._ground_head(cs), 0.0),
		"ground head %.3f (cell ground %.2f, centroid tile land)" % [cf._ground_head(cs), g.ground_elev(cs)])
	_check("clamp.behind-straddle", is_equal_approx(cf._ground_head(cs2), 0.0),
		"ground head %.3f (reached through the straddle cell)" % cf._ground_head(cs2))
	_check("clamp.deck-at-waterline", is_equal_approx(cf._ground_head(deck_cid), 0.0),
		"ground head %.3f, not the seabed 1.6 below its sinks" % cf._ground_head(deck_cid))
	_check("clamp.inland-pit-kept", is_equal_approx(cf._ground_head(cpit), -0.5 * CellFluid.HEAD_PER_STORY),
		"ground head %.3f" % cf._ground_head(cpit))
	_check("clamp.quay-untouched", is_equal_approx(cf._ground_head(g.cell_at(GridManager.map_to_world(Vector2i(2, 2)))),
		0.5 * CellFluid.HEAD_PER_STORY), "")
	_check("clamp.count", cf.waterline_count == 3, "%d cells raised (the deck and two straddle cells)" % cf.waterline_count)

	# a deck cell holding water, out in the sea: never deleted outright
	var dd0: float = cf.drained_total()
	cf.deposit(GridManager.map_to_world(DECK), "water", 0.3)
	_check("deck.keeps-a-deposit", is_equal_approx(cf.amount_at(deck_cid), 0.3) and cf.drained_total() == dd0, "")
	cf.deposit(GridManager.map_to_world(PIT), "water", 0.3)
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
	var shed_floor: float = cf._puddle_of(cf._ti_of("water")) + CellFluid.EPSILON + 1e-3
	_check("deck.sheds-to-its-floor", deck1 <= shed_floor,
		"deck 0.3000 -> %.4f (sheds into the sea down to its puddle film, then dries)" % deck1)
	# 40 flow ticks of water evaporation (0.002/s) is all the pit may lose
	var pit1: float = cf.amount_at(cpit)
	_check("clamp.inland-pit-keeps-pond", pit1 >= 0.3 - 40.0 * CellFluid.EVAP_PER_SEC * CellFluid.SIM_INTERVAL - 1e-6,
		"pit 0.3000 -> %.4f" % pit1)
	var led: Dictionary = cf.mass_ledger()
	var in_cells := 0.0
	for i in cf.amount.size():
		in_cells += cf.amount[i]
	var res: float = float(led["poured"]) - in_cells - float(led["drained"]) - float(led["evaporated"]) - float(led["lost"])
	_check("sink.mass-closes", absf(res) < 1e-4, "poured %.4f cells %.4f drained %.4f evaporated %.4f lost %.4f residual %.6f"
		% [float(led["poured"]), in_cells, float(led["drained"]), float(led["evaporated"]), float(led["lost"]), res])

	# --- a straddle cell and the deck shed as they do in 'visual' ---------------
	# (visual: they sit level with the seabed and spread onto it)
	for spot in [[STRADDLE, "oil", 0.6], [DECK, "water", 0.3]]:
		var tile: Vector2i = spot[0]
		var ftype_s: String = spot[1]
		var depth: float = spot[2]
		var v_end: float = _shed_run(ml, fm, g, "visual", tile, ftype_s, depth)
		var s_end: float = _shed_run(ml, fm, g, "sink", tile, ftype_s, depth)
		var pud: float = fm.cell_fluid._puddle_of(fm.cell_fluid._ti_of(ftype_s))
		_check("shed.%s-%s" % [str(tile), ftype_s], s_end <= maxf(v_end, pud + CellFluid.EPSILON) + 1e-3,
			"%.2f %s for 10 s: sink %.4f, visual %.4f (puddle floor %.2f)" % [depth, ftype_s, s_end, v_end, pud])
	ml.set("water_sim", "sink")

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

	# --- two bodies: the clamp raises only the traps the sinks make ------------
	# One cell per tile; H is high ground (2.0 stories) round each layout.
	# A creek S1 (surface 0.5, bed 0.0) above the top of a slope X 0.2 > Y 0.0 >
	# Z -0.5 down to the sea S2 (surface -0.6); P (-0.2), a pit below Y, opens
	# onto Y only.
	#   H  S1 H  H  H
	#   H  X  Y  Z  S2
	#   H  H  P  H  H
	var ts := {"X": Vector2i(1, 1), "Y": Vector2i(2, 1), "Z": Vector2i(3, 1), "P": Vector2i(2, 2)}
	g = _load_layout(5, 3, {Vector2i(1, 0): 0.0, ts["X"]: 0.2, ts["Y"]: 0.0, ts["Z"]: -0.5, Vector2i(4, 1): -1.0, ts["P"]: -0.2},
		{Vector2i(1, 0): [0.5, 1], Vector2i(4, 1): [-0.6, 2]})
	ml.set("water_sim", "sink")
	fm.setup_cell_graph(g)
	cf = fm.cell_fluid
	_check("two.slope-keeps-its-ground", cf.sink_count == 2 and _ground_is(cf, g, ts["X"], 0.2)
		and _ground_is(cf, g, ts["Y"], 0.0) and _ground_is(cf, g, ts["Z"], -0.5),
		"X %.3f Y %.3f Z %.3f stories (it drains to the lower body as it lies)" % [
			_gh(cf, g, ts["X"]), _gh(cf, g, ts["Y"]), _gh(cf, g, ts["Z"])])
	_check("two.pit-beside-slope-kept", _ground_is(cf, g, ts["P"], -0.2) and cf.waterline_count == 0,
		"P %.3f stories, %d raised" % [_gh(cf, g, ts["P"]), cf.waterline_count])
	var pit_v: float = _shed_run(ml, fm, g, "visual", ts["P"], "water", 0.3)
	var pit_s: float = _shed_run(ml, fm, g, "sink", ts["P"], "water", 0.3)
	_check("two.pit-beside-slope-keeps-pond", pit_s >= 0.3 - 40.0 * CellFluid.EVAP_PER_SEC * CellFluid.SIM_INTERVAL - 1e-6
		and absf(pit_s - pit_v) <= 1e-4, "0.3 water for 10 s: sink %.4f, visual %.4f" % [pit_s, pit_v])

	# A trap whose way out runs through another body: S1 (surface 0.0, bed
	# -1.0) above E only; A -0.2 | E -0.5 | F -0.25 run to S2 (surface -0.3).
	# E holds what lands on it up to F, not up to S1's head: raised to F's
	# -0.25, A behind it still drains through it (raised to 0.0, it would cut A
	# off: A a pit at -0.2 between high ground and E).
	#   H  H  S1 H  H
	#   H  A  E  F  S2
	#   H  H  H  H  H
	ts = {"A": Vector2i(1, 1), "E": Vector2i(2, 1), "F": Vector2i(3, 1)}
	g = _load_layout(5, 3, {Vector2i(2, 0): -1.0, ts["A"]: -0.2, ts["E"]: -0.5, ts["F"]: -0.25, Vector2i(4, 1): -1.0},
		{Vector2i(2, 0): [0.0, 1], Vector2i(4, 1): [-0.3, 2]})
	ml.set("water_sim", "sink")
	fm.setup_cell_graph(g)
	cf = fm.cell_fluid
	_check("two.trap-raised-to-its-rim", cf.waterline_count == 1 and _ground_is(cf, g, ts["E"], -0.25)
		and _ground_is(cf, g, ts["A"], -0.2) and _ground_is(cf, g, ts["F"], -0.25),
		"%d raised; A %.3f E %.3f F %.3f stories" % [cf.waterline_count, _gh(cf, g, ts["A"]), _gh(cf, g, ts["E"]), _gh(cf, g, ts["F"])])
	var a_v: float = _shed_run(ml, fm, g, "visual", ts["A"], "water", 0.5)
	var a_s: float = _shed_run(ml, fm, g, "sink", ts["A"], "water", 0.5)
	var pud_w: float = fm.cell_fluid._puddle_of(fm.cell_fluid._ti_of("water"))
	# the bench's trap test: deeper than visual + TRAP_TOL and than the film + TRAP_FLOOR
	_check("two.behind-the-trap-drains", a_s <= maxf(a_v + 0.05, pud_w + 0.1),
		"0.5 water on A for 10 s: sink %.4f, visual %.4f" % [a_s, a_v])

	# A hollow beside a perched pool: S1 (surface 1.0, bed 0.5) above E (0.1),
	# whose rim F (0.28) runs to S2 (surface 0.2, bed -0.5). The pool's bed is
	# above E: E is a pit in 'visual' too, and keeps its pond.
	#   H  S1 H  H
	#   H  E  F  S2
	#   H  H  H  H
	ts = {"E": Vector2i(1, 1), "F": Vector2i(2, 1)}
	g = _load_layout(4, 3, {Vector2i(1, 0): 0.5, ts["E"]: 0.1, ts["F"]: 0.28, Vector2i(3, 1): -0.5},
		{Vector2i(1, 0): [1.0, 1], Vector2i(3, 1): [0.2, 2]})
	ml.set("water_sim", "sink")
	fm.setup_cell_graph(g)
	cf = fm.cell_fluid
	_check("two.perched-hollow-kept", cf.waterline_count == 0 and _ground_is(cf, g, ts["E"], 0.1) and _ground_is(cf, g, ts["F"], 0.28),
		"%d raised; E %.3f F %.3f stories" % [cf.waterline_count, _gh(cf, g, ts["E"]), _gh(cf, g, ts["F"])])
	var e_v: float = _shed_run(ml, fm, g, "visual", ts["E"], "water", 0.5)
	var e_s: float = _shed_run(ml, fm, g, "sink", ts["E"], "water", 0.5)
	_check("two.perched-hollow-keeps-pond", absf(e_s - e_v) <= 0.05,
		"0.5 water on E for 10 s: sink %.4f, visual %.4f" % [e_s, e_v])

	# A shore cell a little below the seabed it opens onto: S (surface 0.0, bed
	# -1.0); A at -1.02 and B at -1.10 are pits in 'visual' too, but shallow
	# ones (0.032 and 0.16 deep before they spill onto the seabed). The sinks
	# make each a basin 1.6 deep and more. Its spill rises with the sinks, so
	# the trap is the sinks' doing: both go to the waterline and shed.
	#   H  H  H  H
	#   H  A  S  S
	#   H  H  S  S
	#   H  B  S  S
	#   H  H  H  H
	ts = {"A": Vector2i(1, 1), "B": Vector2i(1, 3)}
	var dip_ground := {ts["A"]: -1.02, ts["B"]: -1.1}
	var dip_water := {}
	for y in range(1, 4):
		for x in range(2, 4):
			dip_ground[Vector2i(x, y)] = -1.0
			dip_water[Vector2i(x, y)] = [0.0, 1]
	g = _load_layout(4, 5, dip_ground, dip_water)
	ml.set("water_sim", "sink")
	fm.setup_cell_graph(g)
	cf = fm.cell_fluid
	_check("two.shore-dip-raised", cf.waterline_count == 2 and _ground_is(cf, g, ts["A"], 0.0) and _ground_is(cf, g, ts["B"], 0.0),
		"%d raised; A %.3f B %.3f stories" % [cf.waterline_count, _gh(cf, g, ts["A"]), _gh(cf, g, ts["B"])])
	for k in ["A", "B"]:
		var dip_v: float = _shed_run(ml, fm, g, "visual", ts[k], "water", 0.5)
		var dip_s: float = _shed_run(ml, fm, g, "sink", ts[k], "water", 0.5)
		_check("two.shore-dip-%s-sheds" % k, dip_s <= maxf(dip_v + 0.05, pud_w + 0.1),
			"0.5 water on %s for 10 s: sink %.4f, visual %.4f" % [k, dip_s, dip_v])

	# --- the clamp's cost: one flood, not a walk per cell -----------------------
	# A 48 x 48 yard below the waterline (-0.5) behind one gap in a quay of high
	# ground, beside a sea column (surface 0.0, bed -1.0): the yard and the gap
	# are 2305 traps. A walk per judged cell took seconds here.
	var yard := {}
	var sea := {}
	for y in 48:
		yard[Vector2i(49, y)] = -1.0
		sea[Vector2i(49, y)] = [0.0, 1]
		yard[Vector2i(48, y)] = 2.0
		for x in 48:
			yard[Vector2i(x, y)] = -0.5
	yard[Vector2i(48, 24)] = -0.5   # the gap
	g = _load_layout(50, 48, yard, sea)
	var clamp_ms := INF
	for _k in 3:   # best of 3: the machine is shared
		ml.set("water_sim", "visual")
		var v0 := Time.get_ticks_usec()
		fm.setup_cell_graph(g)
		var vis_us: int = Time.get_ticks_usec() - v0
		ml.set("water_sim", "sink")
		var s0 := Time.get_ticks_usec()
		fm.setup_cell_graph(g)
		clamp_ms = minf(clamp_ms, float(Time.get_ticks_usec() - s0 - vis_us) / 1000.0)
	_check("cost.clamp-is-one-flood", fm.cell_fluid.waterline_count == 48 * 48 + 1 and clamp_ms < 250.0,
		"%d raised; sinks + clamp %.1f ms (best of 3)" % [fm.cell_fluid.waterline_count, clamp_ms])

	# --- the clamp floods only ground joined to a body below its head -----------
	# A perched pool on a hill (surface 3.0, bed 2.5, rimmed at 3.5) lifts the
	# highest sink head far above a 64 x 60 town at 0.5, which drains to the sea
	# (surface 0.0, bed -1.0) at its own ground. Only the shore column at -0.5
	# lies below a body's head and joins it there: the clamp raises and floods
	# those 60 cells, not the town under the pool's head (a flood capped at
	# the highest head settled all 3900 cells, twice, building their edges).
	var town := {}
	var town_sea := {}
	for y in 60:
		for x in 64:
			town[Vector2i(x, y)] = 0.5
		town[Vector2i(64, y)] = -0.5
		town[Vector2i(65, y)] = -1.0
		town_sea[Vector2i(65, y)] = [0.0, 1]
	var g_flat := _load_layout(66, 60, town, town_sea)
	var flat_ms: float = _clamp_ms(ml, fm, g_flat)
	var flat_raised: int = fm.cell_fluid.waterline_count
	for y in range(1, 4):
		for x in range(1, 4):
			town[Vector2i(x, y)] = 3.5
	town[Vector2i(2, 2)] = 2.5
	town_sea[Vector2i(2, 2)] = [3.0, 2]
	var g_pool := _load_layout(66, 60, town, town_sea)
	var pool_ms: float = _clamp_ms(ml, fm, g_pool)
	cf = fm.cell_fluid
	var flooded: int = int(cf.get("clamp_cells")) if "clamp_cells" in cf else -1
	_check("cost.clamp-floods-the-shore-only", cf.sink_count == 61 and cf.waterline_count == 60 and flat_raised == 60
		and flooded == 60 and _ground_is(cf, g_pool, Vector2i(64, 30), 0.0) and _ground_is(cf, g_pool, Vector2i(30, 30), 0.5),
		"%d sinks, %d raised (%d without the pool), %d cells flooded" % [cf.sink_count, cf.waterline_count, flat_raised, flooded])
	_check("cost.perched-pool-costs-nothing", pool_ms < flat_ms + 15.0,
		"sinks + clamp %.1f ms with the pool, %.1f ms without (best of 3)" % [pool_ms, flat_ms])
	ml.set("water_sim", "sink")

	ml.free()
	print("water_sink_check: %d checks, %d failures" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)


# A small map of its own for the two-body cases: `cols` x `rows` tiles of T
# px, one cell per tile (4 neighbours), every tile at 2.0 stories unless
# `ground` says otherwise, open water where `water` holds [surface, body]
# (the contract-3 layer). Loaded as _load does.
func _load_layout(cols: int, rows: int, ground: Dictionary, water: Dictionary) -> CellGraph:
	var cx: Array = []
	var cy: Array = []
	var r: Array = []
	var fuel: Array = []
	var elev: Array = []
	var roof: Array = []
	var nb_off: Array = []
	var nb: Array = []
	var tw: Array = []
	var tb: Array = []
	for y in rows:
		for x in cols:
			var t := Vector2i(x, y)
			cx.append((x + 0.5) * T)
			cy.append((y + 0.5) * T)
			r.append(32.0)
			fuel.append(0.0)
			elev.append(float(ground.get(t, 2.0)))
			roof.append(0.0)
			tw.append(float((water[t] as Array)[0]) if water.has(t) else 0.0)
			tb.append(int((water[t] as Array)[1]) if water.has(t) else 0)
			nb_off.append(nb.size())
			for d in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
				var n: Vector2i = t + d
				if n.x >= 0 and n.y >= 0 and n.x < cols and n.y < rows:
					nb.append(n.y * cols + n.x)
	nb_off.append(nb.size())
	var data := {"n": cols * rows, "export_scale": 2.0, "cx": cx, "cy": cy, "r": r, "fuel": fuel,
		"elev": elev, "roof": roof, "nb_off": nb_off, "nb": nb,
		"tile_elev": {"cols": cols, "rows": rows, "data": elev},
		"tile_water": {"cols": cols, "rows": rows, "data": tw},
		"tile_body": {"cols": cols, "rows": rows, "data": tb}}
	var f := FileAccess.open(LAYOUT_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()
	GridManager.TILE_SIZE = T
	GridManager.initialize(cols * T, rows * T)
	var g: CellGraph = CellGraph.from_structured(LAYOUT_PATH)
	GridManager.set_elevation_data(g)
	for y in rows:
		for x in cols:
			GridManager.floors[Vector2i(x, y)] = "shallow_water" if water.has(Vector2i(x, y)) else "floor_stone"
	return g


# What the sinks and the clamp add to a map load: 'sink' setup minus 'visual'
# setup, best of 3 (the machine is shared). Leaves the 'sink' sim in place.
func _clamp_ms(ml: Node2D, fm: FluidManager, g: CellGraph) -> float:
	var best := INF
	for _k in 3:
		ml.set("water_sim", "visual")
		var v0 := Time.get_ticks_usec()
		fm.setup_cell_graph(g)
		var vis_us: int = Time.get_ticks_usec() - v0
		ml.set("water_sim", "sink")
		var s0 := Time.get_ticks_usec()
		fm.setup_cell_graph(g)
		best = minf(best, float(Time.get_ticks_usec() - s0 - vis_us) / 1000.0)
	return best


# A tile's cell ground head, in stories / against `stories`.
func _gh(cf: CellFluid, g: CellGraph, t: Vector2i) -> float:
	return cf._ground_head(g.cell_at(GridManager.map_to_world(t))) / CellFluid.HEAD_PER_STORY


func _ground_is(cf: CellFluid, g: CellGraph, t: Vector2i, stories: float) -> bool:
	return is_equal_approx(_gh(cf, g, t), stories)


# A fresh sim in `mode`, `depth` of `type_str` deposited on one tile, 10 s of
# ticks: the depth left on that tile's cell.
func _shed_run(ml: Node2D, fm: FluidManager, g: CellGraph, mode: String, tile: Vector2i, type_str: String, depth: float) -> float:
	ml.set("water_sim", mode)
	fm.setup_cell_graph(g)
	var cf: CellFluid = fm.cell_fluid
	cf.deposit(GridManager.map_to_world(tile), type_str, depth)
	for i in 600:
		cf.tick(1.0 / 60.0)
	return cf.amount_at(g.cell_at(GridManager.map_to_world(tile)))
