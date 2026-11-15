# res://tests/wave2_map_state_check.gd
# Headless integration check for TG roadmap Phase 3 wave 2 (P3-A, P3-B and
# P3-D merged into one TFA). Each package keeps per-map state on MapLoader
# (and GridManager); one structured load must build all of it, a warp to a
# legacy or world map must clear all of it, and the next structured load (a
# save-load is the same Game.load_map) must build it afresh:
#   P3-A  MapLoader.structured_water_mask (on the ground's meta) and the
#         ground material's water_mask_on (CellFluidFX)
#   P3-B  MapLoader.canopy_layer (CanopyLayer.of) and its rule discs
#   P3-D  MapLoader.bridge_deck_arts (each on deck_fluid.gdshader, bound by
#         CellFluidFX.bind_deck_arts), GridManager.deck_ground_refs and the
#         relief_los entry key (GridManager.relief_los_override)
# and the two renderers that share CellFluidFX must both survive: the decks
# and their fluid pass draw above the animated ground water, the crowns above
# both, and the tfa/graphics/animated_water off switch withholds only the
# mask, never the deck fluid pass.
# The map: P3-D's committed river fixture (tests/fixtures/p3d_river: an E-W
# deep river under two deck bridges; cells.json with tile_water / tile_body),
# its relief_los key set false, plus one contract-3 tree row (canopy_cell /
# shade_cell) on the north bank; the ground and the open-water mask are
# ImageTextures saved to user:// (no art in the project), the structures
# overlay and the canopy atlas are project icons.
#   1. load, in Game.load_map's order (GridManager.initialize,
#      set_elevation_data, generate_structured_map, FluidManager
#      .setup_cell_graph): every package's state built.
#   2. the same load with tfa/graphics/animated_water off.
#   3. a warp to a world map (the unload sweep of MapLoader's children,
#      set_elevation_data(null), initialize, generate_map): all cleared, the
#      old CanopyLayer and deck arts freed.
#   4. load again: all rebuilt, as fresh instances.
# Run:  godot --headless --path . res://tests/wave2_map_state_check.tscn
# Judge by the PASS/FAIL lines and "WAVE2 MAP STATE CHECK DONE: N checks, M FAIL".
extends Node2D

const MAP_LOADER := preload("res://Structures/MapLoader.gd")
const FIX := "res://tests/fixtures/p3d_river/"
const ROW_PATH := FIX + "tg_test_prim_river_row.json"
const CELLS_PATH := FIX + "tg_test_prim_river_cells.json"
const GROUND_PATH := "user://wave2_map_state_ground.res"
const MASK_PATH := "user://wave2_map_state_water.res"
const OVERLAY_RES := "res://icon.svg"
const ATLAS_RES := "res://UI/UI Icons/Dash.png"
const NO_WORLD := "res://tests/wave2_map_state_no_such_world.png"
const TREE_POS := Vector2(320.0, 200.0)   # the north bank (the river runs along tile rows 8-10)
const TREE_R := 40.0

# --- Game stand-in (MapLoader, FluidManager and CanopyLayer read these) ---
var structures_in_scene: Array = []
var characters_in_scene: Array = []
var items_in_scene: Array = []
var party_chars: Array = []
var unlocked_locks: Dictionary = {}
var current_map_data: Dictionary = {}
var current_map_id := "wave2_map_state_check"
var map_loader: Node2D = null
var fluid_manager: FluidManager = null

var _checks := 0
var _fails := 0
var _row: Dictionary = {}
var _cols := 0
var _rows := 0


func _check(check_name: String, ok: bool, detail: Variant = "") -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("%s %s: %s" % ["PASS" if ok else "FAIL", check_name, str(detail)])


func _ready() -> void:
	add_to_group("game")
	TimeManager.pause_time()
	await get_tree().process_frame
	var f := FileAccess.open(ROW_PATH, FileAccess.READ)
	if f == null:
		_check("fixture.row", false, ROW_PATH)
		_done()
		return
	_row = JSON.parse_string(f.get_as_text())
	f.close()
	var ws: Array = _row["world_size"]
	_cols = int(ws[0]) / 64
	_rows = int(ws[1]) / 64
	_save_tex(GROUND_PATH, _cols * 64, _rows * 64, Color(0.3, 0.45, 0.25, 1.0))
	_save_tex(MASK_PATH, _cols * 32, _rows * 32, Color(1.0, 0.9, 0.7, 0.27))   # k = 2
	var ml: Node2D = MAP_LOADER.new()
	ml.name = "MapLoader"
	add_child(ml)
	map_loader = ml
	fluid_manager = FluidManager.new()
	fluid_manager.name = "FluidManager"
	add_child(fluid_manager)
	await get_tree().process_frame

	# 1. a structured load builds every package's state
	await _load()
	var first := _built("load")

	# 2. the animated open water off: only the mask goes
	var had: bool = ProjectSettings.has_setting(CellFluidFX.ANIMATED_WATER_SETTING)
	var old: Variant = ProjectSettings.get_setting(CellFluidFX.ANIMATED_WATER_SETTING, null)
	ProjectSettings.set_setting(CellFluidFX.ANIMATED_WATER_SETTING, false)
	_unload()
	await get_tree().process_frame
	await _load()
	_off_checks()
	if had:
		ProjectSettings.set_setting(CellFluidFX.ANIMATED_WATER_SETTING, old)
	else:
		ProjectSettings.clear(CellFluidFX.ANIMATED_WATER_SETTING)

	# 3. a warp to a world map clears it all
	_unload()
	await get_tree().process_frame
	await _load()
	var before := _built("reload")
	_unload()
	GridManager.TILE_SIZE = 64
	GridManager.initialize(1024, 1024)
	ml.set("world_map_mode", true)
	ml.set("map_image_path", NO_WORLD)
	ml.call("generate_map")
	fluid_manager.setup_cell_graph(null)
	await get_tree().process_frame
	_cleared_checks(before)

	# 4. the next structured load (a save-load is the same Game.load_map)
	ml.set("world_map_mode", false)
	await _load()
	var again := _built("after-warp")
	var fresh: bool = again.get("layer") != null and again.get("layer") != first.get("layer") \
		and again.get("layer") != before.get("layer")
	var arts_a: Array = again.get("arts", [])
	var arts_b: Array = before.get("arts", [])
	for a in arts_a:
		if a in arts_b:
			fresh = false
	_check("after-warp.fresh-instances", fresh and arts_a.size() == 2)

	_unload()
	await get_tree().process_frame
	for p in [GROUND_PATH, MASK_PATH]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	_done()


func _done() -> void:
	print("WAVE2 MAP STATE CHECK DONE: %d checks, %d FAIL" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 or _checks == 0 else 0)


func _save_tex(path: String, w: int, h: int, col: Color) -> void:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(col)
	ResourceSaver.save(ImageTexture.create_from_image(img), path)


# A tree row as a TG contract-3 export writes it: the crown cell 1.35 r round
# the trunk, the shade cell (understory + cast shadow) at half resolution.
func _tree_row() -> Dictionary:
	var ch: int = ceili(TREE_R * 1.35 + 4.0)
	var sh: int = ceili(TREE_R * 1.9 + 4.0)
	var px: int = int(TREE_POS.x)
	var py: int = int(TREE_POS.y)
	return {"kind": "tree", "pos": [TREE_POS.x, TREE_POS.y], "r": TREE_R, "id": "tree", "hp": 80, "stories": 1.7,
		"canopy_cell": [2, 2, 2 * ch, 2 * ch, px - ch, py - ch, 2 * ch, 2 * ch],
		"shade_cell": [2, 2, sh, sh, px - sh, py - sh, 2 * sh, 2 * sh]}


# Game.load_map's order: initialize, the cell graph, MapLoader, the sims.
func _load() -> void:
	GridManager.TILE_SIZE = 64
	GridManager.initialize(_cols * 64, _rows * 64)
	var g: CellGraph = CellGraph.from_structured(CELLS_PATH)
	GridManager.set_elevation_data(g)
	var m: Dictionary = _row.duplicate(true)
	m["images"] = {"map": GROUND_PATH, "structures": OVERLAY_RES, "water": MASK_PATH, "canopy": ATLAS_RES}
	m["cell_graph"] = CELLS_PATH
	m["relief_los"] = false
	(m["structures"] as Array).append(_tree_row())
	current_map_data = m
	structures_in_scene.clear()
	map_loader.call("generate_structured_map", m)
	fluid_manager.setup_cell_graph(g)
	await get_tree().process_frame


# Game._unload_current_map's part that touches this state.
func _unload() -> void:
	for child in map_loader.get_children():
		child.queue_free()
	fluid_manager.clear_all_water_tiles()
	GridManager.set_elevation_data(null)


# The absolute z a canvas item draws at (z_index summed up its relative chain).
func _abs_z(n: Node) -> int:
	var z: int = 0
	var c: Node = n
	while c is CanvasItem:
		var ci := c as CanvasItem
		z += ci.z_index
		if not ci.z_as_relative:
			break
		c = c.get_parent()
	return z


func _built(tag: String) -> Dictionary:
	var ml := map_loader
	var gs: Sprite2D = ml.get("structured_ground")
	var gmat: ShaderMaterial = gs.material as ShaderMaterial if gs != null else null
	# P3-A
	var mask: Variant = ml.get("structured_water_mask")
	_check(tag + ".a.mask-loaded", mask != null and gs != null and gs.get_meta(CellFluidFX.WATER_MASK_META, null) == mask,
		str(mask))
	_check(tag + ".a.ground-water-animates", gmat != null and gmat.shader == CellFluidFX.WATER_SHADER
		and gmat.get_shader_parameter("water_mask") == mask
		and gmat.get_shader_parameter("water_mask_on") == 1.0)
	# P3-B
	var layer: CanopyLayer = CanopyLayer.of(ml)
	var crowns: Array = layer.drawn_crowns() if layer != null else []
	var disc: Polygon2D = layer.rule_disc(int(crowns[0])) if crowns.size() == 1 else null
	_check(tag + ".b.canopy-layer", layer != null and layer == ml.get("canopy_layer") and layer.get_parent() == ml
		and crowns.size() == 1 and disc != null and ml.get("_canopy_tex") == null,
		"layer %s, crowns %s" % [str(layer), str(crowns)])
	# P3-D
	var arts: Array = ml.get("bridge_deck_arts")
	var wired: int = 0
	for a_v in arts:
		var art := a_v as Polygon2D
		var dm: ShaderMaterial = art.material as ShaderMaterial if art != null else null
		if dm != null and dm.shader == CellFluidFX.DECK_SHADER and gmat != null \
				and dm.get_shader_parameter("fluid_mask") == gmat.get_shader_parameter("fluid_mask"):
			wired += 1
	_check(tag + ".d.deck-fluid-pass", arts.size() == 2 and wired == 2, "%d arts, %d on the deck pass" % [arts.size(), wired])
	_check(tag + ".d.bank-grounds", GridManager.deck_ground_refs.size() > 0, GridManager.deck_ground_refs.size())
	_check(tag + ".d.relief-los-key", GridManager.relief_los_override == 0 and not GridManager.relief_los,
		"override %d, relief_los %s" % [GridManager.relief_los_override, str(GridManager.relief_los)])
	# draw order: ground (its animated water) < decks (their fluid pass) < crowns
	var zg: int = _abs_z(gs) if gs != null else 999
	var zd: int = -999
	for a_v in arts:
		zd = maxi(zd, _abs_z(a_v as Node))
	var zd_min: int = 999
	for a_v in arts:
		zd_min = mini(zd_min, _abs_z(a_v as Node))
	var zc: int = _abs_z(layer) if layer != null else -999
	_check(tag + ".z.ground-decks-crowns", zg < zd_min and zd < zc, "ground %d, decks %d..%d, crowns %d" % [zg, zd_min, zd, zc])
	return {"layer": layer, "had_layer": layer != null, "arts": arts.duplicate(), "mask": mask}


func _off_checks() -> void:
	var ml := map_loader
	var gs: Sprite2D = ml.get("structured_ground")
	var gmat: ShaderMaterial = gs.material as ShaderMaterial if gs != null else null
	_check("off.a.no-mask", ml.get("structured_water_mask") == null and gs != null
		and not gs.has_meta(CellFluidFX.WATER_MASK_META) and gmat != null
		and gmat.get_shader_parameter("water_mask_on") == null)
	var arts: Array = ml.get("bridge_deck_arts")
	var wired: int = 0
	for a_v in arts:
		var dm: ShaderMaterial = (a_v as Polygon2D).material as ShaderMaterial
		if dm != null and dm.shader == CellFluidFX.DECK_SHADER:
			wired += 1
	_check("off.d.deck-fluid-pass-kept", arts.size() == 2 and wired == 2, "%d arts, %d on the deck pass" % [arts.size(), wired])
	_check("off.b.canopy-layer-kept", CanopyLayer.of(ml) != null)


func _cleared_checks(before: Dictionary) -> void:
	var ml := map_loader
	_check("warp.a.mask-cleared", ml.get("structured_water_mask") == null)
	_check("warp.b.layer-cleared", ml.get("canopy_layer") == null and CanopyLayer.of(ml) == null
		and ml.get("_canopy_tex") == null and (ml.get("_canopy_crowns") as Array).is_empty())
	# (a freed object reads as null, so whether there was one is recorded at load)
	var old_layer: Variant = before.get("layer")
	_check("warp.b.old-layer-freed", bool(before.get("had_layer", false)) and not is_instance_valid(old_layer))
	var old_arts: Array = before.get("arts", [])
	var alive: int = 0
	for a in old_arts:
		if is_instance_valid(a):
			alive += 1
	_check("warp.d.deck-arts-cleared", (ml.get("bridge_deck_arts") as Array).is_empty() and old_arts.size() == 2 and alive == 0,
		"%d old deck arts still alive" % alive)
	_check("warp.d.bank-grounds-cleared", GridManager.deck_ground_refs.is_empty(), GridManager.deck_ground_refs.size())
	_check("warp.d.relief-los-key-reset", GridManager.relief_los_override == -1, GridManager.relief_los_override)
	_check("warp.fluids-unbound", fluid_manager.cell_fluid_fx == null and ml.get("water_sim") == "visual")
