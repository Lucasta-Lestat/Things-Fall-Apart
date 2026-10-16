extends Node2D
# Fire fuel/spread regression. (1) DIFFERENTIAL: CellFire._fuel (tile-indexed)
# must equal the pre-index structure scan for every cell, on a real structured
# map and on a legacy square-tile map with registered floors. (2) BEHAVIOUR:
# a fireball-sized ignition on a flammable wooden floor must actually spread
# over the following spread ticks on both graph kinds.
# Headless:  godot --headless --path . res://tests/fire_fuel_diff_check.tscn
const MAP_LOADER := preload("res://Structures/MapLoader.gd")

var structures_in_scene: Array = []
var characters_in_scene: Array = []
var items_in_scene: Array = []
var party_chars: Array = []
var unlocked_locks: Dictionary = {}
var map_loader: Node2D = null
var surface_manager: SurfaceManager = null
var fluid_manager: FluidManager = null
var fog_manager: FogManager = null
var current_map_data: Dictionary = {}
var fails := 0
var checks := 0


class FloorStub:
	var floor_id: String
	var walkability: float = 1.0
	func _init(id: String) -> void:
		floor_id = id


func load_map(_a = null, _b = "", _c = "") -> void:
	pass


func _on_structure_destroyed(structure, _p: Vector2) -> void:
	structures_in_scene.erase(structure)
	if surface_manager and surface_manager.cell_fire:
		surface_manager.cell_fire.invalidate_fuel()


func _check(name: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if not ok:
		fails += 1
	print("%s %s: %s" % ["PASS" if ok else "FAIL", name, detail])


# The ORIGINAL CellFire._compute_fuel, verbatim in spirit: full structure scan.
func _old_fuel(cf: CellFire, cid: int) -> float:
	var tile := GridManager.world_to_map(cf.graph.centroid(cid))
	var blocked := false
	var flammable_fuel := 0.0
	for structure in structures_in_scene:
		if not is_instance_valid(structure):
			continue
		if tile in surface_manager._fire_tiles_of(structure):
			if structure.flammable:
				flammable_fuel = maxf(flammable_fuel, 1.25)
			else:
				blocked = true
	if flammable_fuel > 0.0:
		return flammable_fuel
	if blocked:
		return 0.0
	var cfl = fluid_manager.cell_fluid if fluid_manager else null
	if cfl != null and cfl.active_sim():
		if cfl.is_flammable_at(cid):
			return 2.5
		if cfl.amount_at(cid) > 0.01:
			return 0.0
	return cf.graph.ground_fuel(cid)


func _diff(label: String, cf: CellFire) -> void:
	var bad := 0
	var first := ""
	for cid in cf.graph.cell_count:
		var a := cf._fuel(cid)
		var b := _old_fuel(cf, cid)
		if not is_equal_approx(a, b):
			bad += 1
			if first == "":
				first = "cid %d new %.2f old %.2f" % [cid, a, b]
	_check(label + ".fuel-matches-old-scan", bad == 0, "%d mismatches of %d %s" % [bad, cf.graph.cell_count, first])


func _spread_test(label: String, cf: CellFire, at: Vector2, radius: float) -> void:
	surface_manager.try_ignite_area(at, radius)   # the real fireball path
	var n0 := cf.burning.size()
	_check(label + ".ignites", n0 > 0, "lit %d" % n0)
	for _i in 6:
		cf._spread(self)
	var n1 := cf.burning.size()
	_check(label + ".spreads", n1 > n0, "burning %d -> %d after 6 spread ticks" % [n0, n1])
	# and it keeps growing through the real tick (timers, lifetime, damage)
	for _i in 300:
		surface_manager.update_surfaces(1.0 / 60.0, [], self)
	var n2 := cf.burning.size()
	_check(label + ".sustains", n2 > n1 or n2 > n0, "burning %d after 5s of real ticks" % n2)
	cf.clear_all()


func _teardown() -> void:
	for s in structures_in_scene:
		if is_instance_valid(s):
			s.queue_free()
	structures_in_scene.clear()
	if map_loader:
		map_loader.queue_free()
		map_loader = null
	surface_manager.queue_free()
	fluid_manager.queue_free()
	fog_manager.queue_free()


func _ready() -> void:
	add_to_group("game")
	# --- A. structured map (tg_castle_keep) -----------------------------------
	var f := FileAccess.open("res://data/Maps.json", FileAccess.READ)
	var raw: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	var m: Dictionary = {}
	for e in raw.get("maps", []):
		if String(e.get("id", "")) == "tg_castle_keep":
			m = e
			break
	current_map_data = m
	GridManager.TILE_SIZE = int(m.get("tile_size", 64))
	var ws: Array = m.get("world_size", [2048, 2048])
	GridManager.initialize(int(ws[0]), int(ws[1]))
	var graph: CellGraph = CellGraph.from_structured(String(m.get("cell_graph", "")))
	GridManager.set_elevation_data(graph)
	map_loader = MAP_LOADER.new()
	add_child(map_loader)
	map_loader.generate_structured_map(m)
	fog_manager = FogManager.new()
	add_child(fog_manager)
	fluid_manager = FluidManager.new()
	add_child(fluid_manager)
	fluid_manager.setup_cell_graph(graph)
	surface_manager = SurfaceManager.new()
	add_child(surface_manager)
	surface_manager.setup_cell_graph(graph)
	var cf: CellFire = surface_manager.cell_fire
	cf._rng.seed = 1
	_diff("structured", cf)
	# pick a fuelled cell whose neighbours are fuelled too (open grass/wood)
	var site := Vector2.ZERO
	for cid in graph.cell_count:
		if graph.ground_fuel(cid) <= 0.0 or cf._fuel(cid) <= 0.0:
			continue
		var ok := true
		for nb in graph.neighbors(cid):
			if cf._fuel(nb) <= 0.0:
				ok = false
		if ok:
			site = graph.centroid(cid)
			break
	_spread_test("structured", cf, site, 48.0)
	# structure death must refresh the index (a burnt-down wall stops blocking)
	# (pick a stone wall tile no OTHER structure also claims, over fuelled ground)
	var wall = null
	var wt := Vector2i.ZERO
	cf._ensure_index()
	for s in structures_in_scene:
		if not is_instance_valid(s) or s.flammable:
			continue
		for t in surface_manager._fire_tiles_of(s):
			var claimers: Array = cf._tile_structs.get(t, [])
			var wc := graph.cell_at(GridManager.map_to_world(t))
			if claimers.size() == 1 and wc >= 0 and graph.ground_fuel(wc) > 0.0:
				wall = s
				wt = t
				break
		if wall != null:
			break
	_check("structured.found-lone-wall", wall != null)
	if wall != null:
		var wcid := graph.cell_at(GridManager.map_to_world(wt))
		var before := cf._fuel(wcid)
		wall.take_damage({"fire": 100000.0}, 0)
		await get_tree().process_frame
		var after := cf._fuel(wcid)
		_check("structured.index-refreshes-on-death", before == 0.0 and after > 0.0,
			"fuel %.2f -> %.2f" % [before, after])
	# parquet floors export baked fuel 0 (editor gates fuel off built floors);
	# the registered floor_wood must still make them fuel
	var p_cells := 0
	var p_fuel := 0
	for cid in graph.cell_count:
		var t := GridManager.world_to_map(graph.centroid(cid))
		if GridManager.floors.get(t, "") != "floor_wood":
			continue
		if not cf._tile_structs.get(t, []).is_empty():
			continue   # a wall/door claims it; structures decide there
		p_cells += 1
		if cf._fuel(cid) > 0.0:
			p_fuel += 1
	_check("structured.parquet-is-fuel", p_cells > 0 and p_fuel == p_cells, "%d of %d clear parquet cells fuelled" % [p_fuel, p_cells])
	_teardown()
	await get_tree().process_frame

	# --- B. legacy square-tile map with a wooden floor ------------------------
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	for x in range(6, 26):
		for y in range(6, 26):
			GridManager.register_floor(Vector2i(x, y), FloorStub.new("floor_wood"))
	for x in range(0, 6):
		for y in range(0, 32):
			GridManager.register_floor(Vector2i(x, y), FloorStub.new("floor_stone"))
	fog_manager = FogManager.new()
	add_child(fog_manager)
	fluid_manager = FluidManager.new()
	add_child(fluid_manager)
	surface_manager = SurfaceManager.new()
	add_child(surface_manager)
	var sq := CellGraph.from_square_tiles()
	surface_manager.setup_cell_graph(sq)
	cf = surface_manager.cell_fire
	cf._rng.seed = 1
	_check("square.wood-is-fuel", cf._fuel(sq.cell_at(GridManager.map_to_world(Vector2i(10, 10)))) > 0.0)
	_check("square.stone-is-break", cf._fuel(sq.cell_at(GridManager.map_to_world(Vector2i(2, 10)))) == 0.0)
	_diff("square", cf)
	_spread_test("square", cf, GridManager.map_to_world(Vector2i(15, 15)), 96.0)
	print("fire_fuel_diff_check: %d checks, %d FAIL" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)
