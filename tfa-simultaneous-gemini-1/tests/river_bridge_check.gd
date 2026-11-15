extends Node2D
# P3-D, the roadmap's Phase 3 exit criterion (5): a test layout with an E-W
# deep river and deck bridges passes the walk, elevation and fluid tests. The
# map is TG's layouts/test_prim_river.json exported under contract 3 (TG
# p3-rivers): its Maps.json row and cells.json are TEXT fixtures in
# tests/fixtures/p3d_river/ (no art: the row's images point at the icon), loaded
# the way Game does (CellGraph, set_elevation_data, MapLoader). The river runs
# west -> east across the whole map, its surface 1.8 stories over ground 2.0
# with its bed at 0.8 -- above sea level, so only the relative deep-water rule
# (GridManager.is_deep_water against tile_water) calls it deep. Two bridges
# cross it: mill_bridge (wood, walk_elev 2.0 = the banks) and weir_bridge
# (stone, 2.3: a 0.3-story step at each end).
#   walk: every open-water tile off the decks is deep, every deck tile is not;
#     the default spawn (north bank) reaches the 'south' spawn and the guard
#     over the bridges, each bridge alone carries the walk, and with the decks
#     gone nothing crosses; the deck tiles walk on planks / stone, not wading;
#   elevation: can_step at both ends of each bridge, never deck -> water or
#     bank -> water; effective_elev on a deck is its walk_elev over the bed;
#     relief LOS on; without the water layer the absolute rule calls none of
#     the river deep (the L8 hole the layer closes); the jump planner never
#     lands in the river, can_jump_to refuses it, knockback stops at the bank
#     and at the deck's edge (the deep-water veto itself) and runs along the deck;
#   view layer: a walker on either bridge over the river is the ground layer
#     (height measured from the water's surface, GridManager.ground_ref), a
#     deck 1.3 over the water is the high layer;
#   bridge art and damage: no loose item rows on the decks (the deck art is
#     baked into the structures overlay); every deck row is indestructible
#     and its Structure neither burns nor breaks (no walker stranded in deep
#     water before P4-B);
#   fluid (water_sim 'sink'): every river cell off the decks is a sink, no
#     deck cell is, each deck cell stands at its own walk_elev head; a deposit
#     anywhere on a deck lands on the deck (never drained on landing); one on
#     the river drains at once; no shore cell lying below a deck beside it sits
#     below the waterline (the clamp saw the deck as the water under it); a
#     0.6 spill on the bridge sheds down to its puddle floor, into the river,
#     and one on such a shore cell runs under the deck; no sink ever holds
#     fluid and the mass ledger closes; 'visual' builds no sinks.
# Headless:  godot --headless --path . res://tests/river_bridge_check.tscn
# Exit 0 when every check passes.
const MAP_LOADER := preload("res://Structures/MapLoader.gd")
const FIX := "res://tests/fixtures/p3d_river/"
const ROW_PATH := FIX + "tg_test_prim_river_row.json"
const CELLS_PATH := FIX + "tg_test_prim_river_cells.json"
const NOLAYER_PATH := "user://river_bridge_check_nolayer_cells.json"

# MapLoader's game stub (it reads these off its parent) + FluidManager's
var structures_in_scene: Array = []
var party_chars: Array = []
var unlocked_locks: Dictionary = {}
var map_loader: Node2D = null

var fails := 0
var checks := 0
var row: Dictionary = {}
var cols := 0
var rows := 0
var decks: Array = []          # [{tiles: Array[Vector2i], elev, id, a, b}] from the row's walk_elev rows


func _check(cname: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if not ok:
		fails += 1
	print("%s %s %s" % ["PASS" if ok else "FAIL", cname, detail])


func _ready() -> void:
	await get_tree().process_frame
	var f := FileAccess.open(ROW_PATH, FileAccess.READ)
	if f == null:
		_check("fixture.row", false, ROW_PATH)
		_done()
		return
	row = JSON.parse_string(f.get_as_text())
	f.close()
	var ws: Array = row["world_size"]
	cols = int(ws[0]) / 64
	rows = int(ws[1]) / 64
	var g := await _load(CELLS_PATH)
	_check("fixture.loaded", g != null and GridManager.has_water_layer() and decks.size() == 2,
		"%dx%d tiles, layer %s, %d decks" % [cols, rows, str(GridManager.has_water_layer()), decks.size()])
	if g == null or decks.size() != 2:
		_done()
		return
	_walk_checks()
	_elevation_checks()
	_view_layer_checks()
	_bridge_art_and_damage_checks()
	await _fluid_checks(g)
	# --- the fallback: the same map without the water layer (contract 2's reading).
	# The river's tiles are taken while the layer is loaded: without it,
	# water_body_at IS is_deep_water, so a list taken after the strip is empty
	var river := _river_tiles()
	_strip_layer()
	g = await _load(NOLAYER_PATH)
	var deep := 0
	for t in river:
		if GridManager.is_deep_water(t):
			deep += 1
	_check("fallback.absolute-rule-misses-the-river", not GridManager.has_water_layer() and GridManager.relief_los
		and river.size() > 0 and deep == 0,
		"%d of %d river tiles deep without the layer (bed 0.8 > -0.5)" % [deep, river.size()])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(NOLAYER_PATH))
	_done()


func _done() -> void:
	print("RIVER BRIDGE CHECK DONE: %d checks, %d FAIL" % [checks, fails])
	get_tree().quit(1 if fails > 0 or checks == 0 else 0)


# Game.load_map's order: graph -> set_elevation_data -> MapLoader (floors, decks).
func _load(cells_path: String) -> CellGraph:
	if map_loader != null and is_instance_valid(map_loader):
		map_loader.queue_free()
		map_loader = null
		await get_tree().process_frame
	GridManager.TILE_SIZE = 64
	GridManager.initialize(cols * 64, rows * 64)
	var g: CellGraph = CellGraph.from_structured(cells_path)
	if g == null:
		_check("fixture.cells", false, cells_path)
		return null
	GridManager.set_elevation_data(g)
	var m: Dictionary = row.duplicate(true)
	m["images"] = {"map": "res://icon.svg"}
	m["cell_graph"] = cells_path
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	map_loader = ml
	ml.generate_structured_map(m)
	ml.set("structured_ground", null)   # no water renderer in a headless check
	decks = []
	for s_v in row.get("structures", []):
		var s: Dictionary = s_v
		if s.get("walk_elev") == null:
			continue
		var a := Vector2(float(s["a"][0]), float(s["a"][1]))
		var b := Vector2(float(s["b"][0]), float(s["b"][1]))
		var tiles: Array[Vector2i] = ml._tiles_near_segment(a, b, float(s["half"]), 64)
		decks.append({"tiles": tiles, "elev": float(s["walk_elev"]), "id": String(s["id"]), "a": a, "b": b})
	return g


func _water(t: Vector2i) -> bool:
	return GridManager.water_body_at(t) > 0


func _on_deck(t: Vector2i) -> bool:
	return GridManager.deck_elevations.has(t)


func _river_tiles() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in rows:
		for x in cols:
			var t := Vector2i(x, y)
			if _water(t) and not _on_deck(t):
				out.append(t)
	return out


func _spawn_tile(key: String) -> Vector2i:
	var p: Array = ((row["player_spawns"] as Dictionary)[key] as Dictionary)["position"]
	return GridManager.world_to_map(Vector2(float(p[0]), float(p[1])))


func _walk_checks() -> void:
	var river := _river_tiles()
	var deep := 0
	for t in river:
		if GridManager.is_deep_water(t):
			deep += 1
	var deck_deep := 0
	var land_deep := 0
	var deck_wading := 0
	for y in rows:
		for x in cols:
			var t := Vector2i(x, y)
			if _on_deck(t):
				if GridManager.is_deep_water(t):
					deck_deep += 1
				if _water(t) and String(GridManager.floors.get(t, "")) == "shallow_water":
					deck_wading += 1
			elif not _water(t) and GridManager.is_deep_water(t):
				land_deep += 1
	_check("walk.river-is-deep", river.size() > 0 and deep == river.size(), "%d of %d open-water tiles off the decks" % [deep, river.size()])
	_check("walk.decks-and-banks-not-deep", deck_deep == 0 and land_deep == 0, "deck %d, land %d" % [deck_deep, land_deep])
	_check("walk.deck-floors-not-wading", deck_wading == 0, "%d deck tiles over the water read shallow_water" % deck_wading)
	var t0 := _spawn_tile("default")
	var t1 := _spawn_tile("south")
	var p := GridManager.find_path(t0, t1)
	var dry := true
	for t in p:
		dry = dry and (_on_deck(t) or not _water(t))
	_check("walk.north-to-south-over-a-bridge", not p.is_empty() and dry, "path of %d tiles" % p.size())
	var guard_ok := true
	for n_v in row.get("npc_spawns", []):
		var np: Array = (n_v as Dictionary)["position"]
		guard_ok = guard_ok and not GridManager.find_path(t0, GridManager.world_to_map(Vector2(float(np[0]), float(np[1])))).is_empty()
	_check("walk.guard-reachable", guard_ok, "")
	# each bridge alone carries the walk; with no deck nothing crosses
	for k in decks.size():
		var other: Dictionary = decks[1 - k]
		for t in other["tiles"]:
			GridManager.unregister_deck(t, float(other["elev"]))
		_check("walk.%s-alone-carries" % String((decks[k] as Dictionary)["id"]), not GridManager.find_path(t0, t1).is_empty(), "")
		for t in other["tiles"]:
			GridManager.register_deck(t, float(other["elev"]))
	for d in decks:
		for t in (d as Dictionary)["tiles"]:
			GridManager.unregister_deck(t, float((d as Dictionary)["elev"]))
	_check("walk.no-crossing-without-decks", GridManager.find_path(t0, t1).is_empty(), "")
	for d in decks:
		for t in (d as Dictionary)["tiles"]:
			GridManager.register_deck(t, float((d as Dictionary)["elev"]))


func _elevation_checks() -> void:
	_check("elev.relief-los", GridManager.relief_los, "span %.2f" % (GridManager.terrain_max - GridManager.terrain_min))
	for d_v in decks:
		var d: Dictionary = d_v
		var tiles: Array = d["tiles"]
		var ends_ok := 0
		var ends_bad := 0
		var off_bad := 0
		var off_ok := 0
		var elev_ok := true
		for t_v in tiles:
			var t: Vector2i = t_v
			elev_ok = elev_ok and is_equal_approx(GridManager.effective_elev(t), float(d["elev"]))
			if _water(t):
				elev_ok = elev_ok and GridManager.terrain_elev(t) < 1.0
			for dd: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = t + dd
				if not GridManager.map_rect.has_point(n) or _on_deck(n):
					continue
				if _water(n):
					if GridManager.can_step(t, n):
						off_bad += 1
					else:
						off_ok += 1
				elif GridManager.can_step(t, n) and GridManager.can_step(n, t):
					ends_ok += 1
				else:
					ends_bad += 1
		_check("elev.%s-deck-at-walk-elev" % String(d["id"]), elev_ok, "walk_elev %.2f over the bed" % float(d["elev"]))
		_check("elev.%s-can-step-at-ends" % String(d["id"]), ends_ok > 0 and ends_bad == 0, "%d bank steps pass, %d fail" % [ends_ok, ends_bad])
		_check("elev.%s-no-step-into-water" % String(d["id"]), off_ok > 0 and off_bad == 0, "%d deck -> water steps refused, %d allowed" % [off_ok, off_bad])
	var bank_river := 0
	for t in _river_tiles():
		for dd: Vector2i in [Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = t + dd
			if GridManager.map_rect.has_point(n) and not _water(n) and GridManager.can_step(n, t):
				bank_river += 1
	_check("elev.bank-never-steps-into-river", bank_river == 0, "%d" % bank_river)
	# jumps and knockback: never into the river
	var river := _river_tiles()
	var landings := 0
	for t in river:
		for dd: Vector2i in [Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = t + dd
			if not GridManager.map_rect.has_point(n) or _water(n):
				continue
			for e in GridManager._get_jump_neighbors(Vector3i(n.x, n.y, 0), 2.5, 2):
				var en := Vector2i((e["n"] as Vector3i).x, (e["n"] as Vector3i).y)
				if GridManager.is_deep_water(en):
					landings += 1
	_check("elev.planner-never-lands-in-river", landings == 0, "%d jump edges into deep water" % landings)
	var bank := Vector2i(-1, -1)
	var below := Vector2i(-1, -1)
	for t in river:
		var n := t + Vector2i(0, -1)
		if GridManager.map_rect.has_point(n) and not _water(n) and not _on_deck(n):
			bank = n
			below = t
			break
	var ch = load("res://Characters/ProceduralCharacter.tscn").instantiate()
	ch.AI_enabled = false
	ch.is_player_controlled = false
	add_child(ch)
	ch.jump_height = 2.5
	ch.jump_range = 2
	ch.global_position = GridManager.map_to_world(bank)
	ch._refresh_elevation()
	_check("elev.can-jump-to-refuses-river", bank.x >= 0 and not ch.can_jump_to(bank, below), "%s -> %s" % [str(bank), str(below)])
	# the forced-mover veto itself: on this fixture the bank and the deck stand
	# 1.2 over the bed, so can_traverse alone already refuses those steps
	_check("elev.knockback-veto-at-bank", GridManager.segment_enters_deep_water(
		GridManager.map_to_world(bank), GridManager.map_to_world(below)), "%s -> %s" % [str(bank), str(below)])
	_check("elev.knockback-stops-at-bank", not ch._forced_step_ok(GridManager.map_to_world(bank), GridManager.map_to_world(below))
		and not ch._forced_drop_check(Vector2(0.0, 64.0)) and not ch._fall_active)
	var mill: Dictionary = decks[0]
	var a: Vector2 = mill["a"]
	var b: Vector2 = mill["b"]
	var mid := (a + b) * 0.5
	var side := mid + (b - a).normalized().orthogonal() * 160.0
	_check("elev.knockback-runs-along-deck", ch._forced_step_ok(a.lerp(b, 0.15), a.lerp(b, 0.85)), "")
	_check("elev.knockback-veto-at-deck-edge", GridManager.segment_enters_deep_water(mid, side), "")
	_check("elev.knockback-stops-at-deck-edge", not ch._forced_step_ok(mid, side), "")
	_check("elev.knockback-along-deck-no-veto", not GridManager.segment_enters_deep_water(a.lerp(b, 0.15), a.lerp(b, 0.85)), "")
	ch.queue_free()


# The view layer / sight tier on a bridge (GridManager.ground_ref): a walker on
# a deck over the river is measured from the water's surface, not the bed a
# story further down, so neither bridge (0.2 / 0.5 over a surface at 1.8) is
# the HIGH layer (was: 1.2 / 1.5 over the bed: hidden in ground view, the
# leader's view flipped to the roof slice, crowns always blocking them). A
# deck 1.3 over the same water still is.
func _view_layer_checks() -> void:
	var ch = load("res://Characters/ProceduralCharacter.tscn").instantiate()
	ch.AI_enabled = false
	ch.is_player_controlled = false
	add_child(ch)
	for d_v in decks:
		var d: Dictionary = d_v
		var n := 0
		var high := 0
		var hag_max := -INF
		for t_v in d["tiles"]:
			var t: Vector2i = t_v
			if not _water(t):
				continue
			n += 1
			ch.global_position = GridManager.map_to_world(t)
			ch._refresh_elevation()
			hag_max = maxf(hag_max, ch.height_above_ground())
			if GridManager.is_high_layer(ch) or ch.is_on_raised_surface() \
					or GridManager.height_above_ground(t, ch.get_elevation()) >= GridManager.HIGH_LAYER_STORIES:
				high += 1
		_check("view.%s-walker-is-ground-layer" % String(d["id"]), n > 0 and high == 0,
			"%d deck tiles over the water, %d on the high layer, height above the water %.2f" % [n, high, hag_max])
	var bank := _spawn_tile("default")
	ch.global_position = GridManager.map_to_world(bank)
	ch._refresh_elevation()
	_check("view.bank-walker-is-ground-layer", not GridManager.is_high_layer(ch) and is_zero_approx(ch.height_above_ground()), "")
	var rt: Vector2i = _river_tiles()[0]
	var hi_e: float = GridManager.water_surface_at(rt) + 1.3
	GridManager.register_deck(rt, hi_e)
	ch.global_position = GridManager.map_to_world(rt)
	ch._refresh_elevation()
	_check("view.high-deck-over-water-is-high", GridManager.is_high_layer(ch) and absf(ch.height_above_ground() - 1.3) < 1e-4,
		"deck %.2f over the water at %.2f: hag %.2f" % [hi_e, GridManager.water_surface_at(rt), ch.height_above_ground()])
	GridManager.unregister_deck(rt, hi_e)
	ch.queue_free()


# Bridge art is baked (TG draws the deck into the structures overlay, which the
# deck's own Art slices): no loose plank items to loot or knock away. And a
# bridge deck is indestructible until P4-B: fire or a big hit never drops its
# walkers into deep water.
func _bridge_art_and_damage_checks() -> void:
	var loose := 0
	for it_v in row.get("item_spawns", []):
		var it: Dictionary = it_v
		var ip: Array = it.get("position", [0, 0])
		if _on_deck(GridManager.world_to_map(Vector2(float(ip[0]), float(ip[1])))) or String(it.get("id", "")) == "plank_bridge":
			loose += 1
	_check("art.no-loose-items-on-the-decks", loose == 0, "%d item rows on a deck or plank_bridge" % loose)
	var rows_ok := 0
	for s_v in row.get("structures", []):
		var s: Dictionary = s_v
		if s.get("walk_elev") != null and s.get("indestructible", false) == true:
			rows_ok += 1
	_check("damage.deck-rows-indestructible", rows_ok == decks.size(), "%d of %d deck rows" % [rows_ok, decks.size()])
	var insts: Array = []
	for st in structures_in_scene:
		if is_instance_valid(st) and (st as Structure).is_deck:
			insts.append(st)
	var flags_ok := insts.size() == decks.size()
	for st in insts:
		flags_ok = flags_ok and (st as Structure).indestructible and not (st as Structure).flammable
	_check("damage.decks-indestructible-not-flammable", flags_ok, "%d deck structures" % insts.size())
	var tiles_before := 0
	for d in decks:
		tiles_before += ((d as Dictionary)["tiles"] as Array).size()
	for st in insts:
		(st as Structure).take_damage({"fire": 100000, "bludgeoning": 100000})
	var alive := 0
	var hp_ok := true
	for st in insts:
		if is_instance_valid(st) and not (st as Structure).is_queued_for_deletion():
			alive += 1
			hp_ok = hp_ok and (st as Structure).current_health == (st as Structure).max_health
	var still := 0
	for d in decks:
		for t in (d as Dictionary)["tiles"]:
			if is_equal_approx(GridManager.effective_elev(t), float((d as Dictionary)["elev"])):
				still += 1
	_check("damage.decks-survive-fire-and-blows", alive == insts.size() and hp_ok and still == tiles_before,
		"%d of %d decks stand, %d of %d deck tiles registered" % [alive, insts.size(), still, tiles_before])


func _fluid_checks(g: CellGraph) -> void:
	var fm := FluidManager.new()
	fm.name = "FluidManager"
	add_child(fm)
	await get_tree().process_frame
	# 'visual': no sinks, as before P3-A
	map_loader.set("water_sim", "visual")
	fm.setup_cell_graph(g)
	_check("fluid.visual-no-sinks", fm.cell_fluid.sink_count == 0, "")
	map_loader.set("water_sim", "sink")
	fm.setup_cell_graph(g)
	var cf: CellFluid = fm.cell_fluid
	var river_cells := 0
	var river_sinks := 0
	var deck_cells: Array[int] = []
	var deck_sinks := 0
	var head_bad := 0
	for cid in g.cell_count:
		var t := GridManager.world_to_map(g.centroid(cid))
		if _on_deck(t):
			if _water(t):
				deck_cells.append(cid)
				if cf.is_sink(cid):
					deck_sinks += 1
				var want: float = maxf(float(GridManager.deck_elevations[t]), GridManager.water_surface_at(t)) * CellFluid.HEAD_PER_STORY
				if absf(cf._ground_head(cid) - want) > 1e-4:
					head_bad += 1
		elif _water(t):
			river_cells += 1
			if cf.is_sink(cid):
				river_sinks += 1
	_check("fluid.river-cells-are-sinks", river_cells > 0 and river_sinks == river_cells, "%d of %d" % [river_sinks, river_cells])
	_check("fluid.no-deck-is-a-sink", deck_cells.size() > 0 and deck_sinks == 0, "%d deck cells over the water" % deck_cells.size())
	_check("fluid.decks-stand-at-their-own-head", head_bad == 0 and cf.deck_head_count == deck_cells.size(),
		"%d heads off, deck_head_count %d" % [head_bad, cf.deck_head_count])
	# a deposit on every deck tile, and at its edges, lands on the deck
	var landed_bad := 0
	var n_dep := 0
	for d_v in decks:
		var d: Dictionary = d_v
		for t_v in d["tiles"]:
			var t: Vector2i = t_v
			if not _water(t):
				continue
			for off in [Vector2(0, 0), Vector2(-28, 0), Vector2(28, 0), Vector2(0, -28), Vector2(0, 28)]:
				var wp: Vector2 = GridManager.map_to_world(t) + off
				var dr0: float = cf.drained_total()
				cf.deposit(wp, "water", 0.05)
				n_dep += 1
				if cf.drained_total() != dr0:
					landed_bad += 1
	_check("fluid.deposit-on-deck-lands-on-deck", n_dep > 0 and landed_bad == 0, "%d of %d deposits drained on landing" % [landed_bad, n_dep])
	var deck_mass0 := 0.0
	for cid in deck_cells:
		deck_mass0 += cf.amount_at(cid)
	var rt: Vector2i = _river_tiles()[0]
	var dr1: float = cf.drained_mass("water")
	cf.deposit(GridManager.map_to_world(rt), "water", 0.3)
	_check("fluid.river-deposit-drains", is_equal_approx(cf.drained_mass("water") - dr1, 0.3), "")
	# the shore beside a bridge: a non-deck cell lying below a deck over the
	# water drains UNDER it (the clamp saw the deck as the water): none sits
	# below the waterline
	var beside: Array[int] = []
	var low_beside := 0
	for cid in deck_cells:
		for nb in g.neighbors(cid):
			var nbi: int = nb
			if cf.is_sink(nbi) or deck_cells.has(nbi) or beside.has(nbi):
				continue
			if cf._ground_head(nbi) < cf._ground_head(cid) - CellFluid.HEAD_EPS:
				beside.append(nbi)
				if cf._ground_head(nbi) < 1.8 * CellFluid.HEAD_PER_STORY - CellFluid.HEAD_EPS:
					low_beside += 1
	_check("fluid.shore-beside-a-deck-at-the-waterline", low_beside == 0,
		"%d cells below a deck beside it, %d below the waterline" % [beside.size(), low_beside])
	# a spill on the bridge: the deck holds its puddle floor and sheds the
	# rest off its edges into the river; a spill on such a shore cell runs
	# under the deck into the river
	var mid_t: Vector2i = GridManager.world_to_map(((decks[0] as Dictionary)["a"] as Vector2).lerp((decks[0] as Dictionary)["b"], 0.5))
	var spill_cid: int = cf._deck_cell_at(GridManager.map_to_world(mid_t), g.cell_at(GridManager.map_to_world(mid_t)))
	var dr2: float = cf.drained_mass("water")
	cf.deposit(GridManager.map_to_world(mid_t), "water", 0.6)
	var shore_cid := -1
	if not beside.is_empty():
		shore_cid = beside[0]
		cf.deposit(g.centroid(shore_cid), "water", 0.6)
	var leaks := 0
	for i in 600:   # 10 s
		cf.tick(1.0 / 60.0)
		if i % 15 == 0:
			for cid in g.cell_count:
				if cf.is_sink(cid) and (cf.amount[cid] != 0.0 or cf.active.has(cid)):
					leaks += 1
	_check("fluid.no-sink-holds-fluid", leaks == 0, "%d" % leaks)
	var floor_w: float = cf._puddle_of(cf._ti_of("water")) + CellFluid.EPSILON + 0.01
	_check("fluid.bridge-spill-sheds-to-its-floor", deck_cells.has(spill_cid) and cf.amount_at(spill_cid) <= floor_w
		and cf.amount_at(spill_cid) > 0.0 and cf.drained_mass("water") > dr2 + 0.05,
		"deck cell %d: 0.6 -> %.3f (floor %.2f), drained +%.3f" % [spill_cid, cf.amount_at(spill_cid), floor_w, cf.drained_mass("water") - dr2])
	_check("fluid.shore-spill-runs-under-the-deck", shore_cid >= 0 and cf.amount_at(shore_cid) <= floor_w,
		"shore cell %d: 0.6 -> %.3f" % [shore_cid, cf.amount_at(shore_cid) if shore_cid >= 0 else -1.0])
	var deck_mass1 := 0.0
	for cid in deck_cells:
		deck_mass1 += cf.amount_at(cid)
	_check("fluid.decks-keep-what-landed", deck_mass1 > 0.0, "deck water %.3f -> %.3f (+0.6 spilled)" % [deck_mass0, deck_mass1])
	var led: Dictionary = cf.mass_ledger()
	var in_cells := 0.0
	for i in cf.amount.size():
		in_cells += cf.amount[i]
	var res: float = float(led["poured"]) - in_cells - float(led["drained"]) - float(led["evaporated"]) - float(led["lost"])
	_check("fluid.mass-closes", absf(res) < 1e-4, "residual %.6f" % res)
	fm.queue_free()
	await get_tree().process_frame


# The fixture's cells.json without tile_water / tile_body (the contract-2 reading).
func _strip_layer() -> void:
	var f := FileAccess.open(CELLS_PATH, FileAccess.READ)
	var d: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	d.erase("tile_water")
	d.erase("tile_body")
	var w := FileAccess.open(NOLAYER_PATH, FileAccess.WRITE)
	w.store_string(JSON.stringify(d))
	w.close()
