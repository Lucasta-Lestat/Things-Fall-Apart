extends Node2D
# The open-water mask's loading and binding (P3-A visual half; TG
# docs/export_contract.md "P3-A: the open-water mask"). A contract-3 row ships
# images.water, a mask at 1/k of the ground's size (TG writes k = 2):
#   1. MapLoader.water_mask_fits: a whole 1/k on both axes, k = 1..8, the same
#      k; anything else (another k per axis, a remainder, k = 9, empty) is not;
#   2. MapLoader.attach_water_mask puts a fitting mask on the ground sprite's
#      meta (CellFluidFX.WATER_MASK_META) and refuses a misfit, a null mask or
#      a ground without a texture (no meta then);
#   3. generate_structured_map: a row with images.water exposes
#      structured_water_mask and the meta; a row without it (every contract-1/2
#      row) has neither; a missing file or a misfit mask warns and reads none;
#   4. CellFluidFX.setup binds the meta's mask to water_surface.gdshader
#      (water_mask + water_mask_on 1) and its calm frame (water_calm: a
#      SubViewport at half the mask's size drawing the ground once through
#      water_calm.gdshader); without a mask it sets none of them, so the
#      shader's open-water branch stays off (water_mask_on defaults to 0) and
#      the material carries exactly the pre-P3-A parameters;
#   5. end to end: MapLoader -> FluidManager.setup_cell_graph -> CellFluidFX,
#      the way Game.load_map wires a structured map;
#   6. the shader declares the pair with the branch off by default.
# The masks are ImageTextures saved to user:// (no art in the project); the
# ground is res://icon.svg (128 x 128). What the shader draws is
# tests/water_surface_shot.tscn's (windowed; needs a contract-3 export).
# Headless:  godot --headless --path . res://tests/water_mask_check.tscn
# Judge by the PASS/FAIL lines and "WATER MASK CHECK DONE: N checks, M FAIL".
const MAP_LOADER := preload("res://Structures/MapLoader.gd")
const MASK_OK := "user://water_mask_check_64.res"      # 64 x 64: icon.svg at k = 2
const MASK_BAD := "user://water_mask_check_50.res"     # 50 x 50: fits no k
const CELLS_PATH := "user://water_mask_check_cells.json"
const GROUND := "res://icon.svg"

# --- Game stand-in state (read by MapLoader, FluidManager) ---
var structures_in_scene: Array = []
var characters_in_scene: Array = []
var items_in_scene: Array = []
var party_chars: Array = []
var unlocked_locks: Dictionary = {}
var current_map_data: Dictionary = {}
var current_map_id := "water_mask_check"
var map_loader: Node2D = null

var _fails := 0
var _checks := 0


func _report(check_name: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("%s %s: %s" % ["PASS" if ok else "FAIL", check_name, detail])


func _ready() -> void:
	add_to_group("game")
	TimeManager.pause_time()
	GridManager.TILE_SIZE = 64
	GridManager.initialize(128, 128)
	_save_mask(MASK_OK, 64, 64)
	_save_mask(MASK_BAD, 50, 50)
	await get_tree().process_frame
	_case_fits()
	_case_attach()
	_case_loader()
	_case_fx_bind()
	await _case_end_to_end()
	_case_shader_text()
	print("WATER MASK CHECK DONE: %d checks, %d FAIL" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _save_mask(path: String, w: int, h: int) -> void:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 0.9, 0.7, 0.27))   # open water, drift (0.8, 0.4), q 0.27
	ResourceSaver.save(ImageTexture.create_from_image(img), path)


func _tex(w: int, h: int) -> ImageTexture:
	return ImageTexture.create_from_image(Image.create(w, h, false, Image.FORMAT_RGBA8))


func _row(images_extra: Dictionary) -> Dictionary:
	var imgs := {"map": GROUND}
	imgs.merge(images_extra, true)
	return {"id": "water_mask_check", "format": "structured", "images": imgs, "export_contract": 3.0,
		"tile_size": 64, "world_size": [128, 128], "floors": [], "structures": []}


func _loader() -> Node2D:
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	return ml


func _case_fits() -> void:
	_report("fits.k2", MAP_LOADER.water_mask_fits(Vector2i(64, 64), Vector2i(128, 128)))
	_report("fits.k2-harbor", MAP_LOADER.water_mask_fits(Vector2i(2112, 1568), Vector2i(4224, 3136)))
	_report("fits.k1", MAP_LOADER.water_mask_fits(Vector2i(128, 96), Vector2i(128, 96)))
	_report("fits.k8", MAP_LOADER.water_mask_fits(Vector2i(16, 12), Vector2i(128, 96)))
	_report("fits.not-k9", not MAP_LOADER.water_mask_fits(Vector2i(10, 10), Vector2i(90, 90)))
	_report("fits.not-a-remainder", not MAP_LOADER.water_mask_fits(Vector2i(50, 50), Vector2i(128, 128)))
	_report("fits.not-two-ks", not MAP_LOADER.water_mask_fits(Vector2i(64, 32), Vector2i(128, 128)))
	_report("fits.not-bigger", not MAP_LOADER.water_mask_fits(Vector2i(256, 256), Vector2i(128, 128)))
	_report("fits.not-empty", not MAP_LOADER.water_mask_fits(Vector2i(0, 0), Vector2i(128, 128)))


func _case_attach() -> void:
	var g := Sprite2D.new()
	g.texture = _tex(128, 128)
	var m := _tex(64, 64)
	_report("attach.fit", MAP_LOADER.attach_water_mask(g, m) and g.get_meta(CellFluidFX.WATER_MASK_META, null) == m)
	var g2 := Sprite2D.new()
	g2.texture = _tex(128, 128)
	_report("attach.misfit", not MAP_LOADER.attach_water_mask(g2, _tex(50, 50)) and not g2.has_meta(CellFluidFX.WATER_MASK_META))
	_report("attach.null-mask", not MAP_LOADER.attach_water_mask(g2, null) and not g2.has_meta(CellFluidFX.WATER_MASK_META))
	var g3 := Sprite2D.new()
	_report("attach.no-ground-texture", not MAP_LOADER.attach_water_mask(g3, m) and not g3.has_meta(CellFluidFX.WATER_MASK_META))
	g.free()
	g2.free()
	g3.free()


func _case_loader() -> void:
	var ml := _loader()
	ml.generate_structured_map(_row({"water": MASK_OK}))
	var gs: Sprite2D = ml.get("structured_ground")
	var wm: Texture2D = ml.get("structured_water_mask")
	_report("loader.with-mask", gs != null and wm != null and Vector2i(wm.get_size()) == Vector2i(64, 64)
		and gs.get_meta(CellFluidFX.WATER_MASK_META, null) == wm, str(wm))
	ml.queue_free()
	var ml2 := _loader()
	ml2.generate_structured_map(_row({}))
	var gs2: Sprite2D = ml2.get("structured_ground")
	_report("loader.no-key", gs2 != null and ml2.get("structured_water_mask") == null
		and not gs2.has_meta(CellFluidFX.WATER_MASK_META))
	ml2.queue_free()
	var ml3 := _loader()
	ml3.generate_structured_map(_row({"water": "user://water_mask_check_nope.res"}))
	var gs3: Sprite2D = ml3.get("structured_ground")
	_report("loader.missing-file", gs3 != null and ml3.get("structured_water_mask") == null
		and not gs3.has_meta(CellFluidFX.WATER_MASK_META))
	ml3.queue_free()
	var ml4 := _loader()
	ml4.generate_structured_map(_row({"water": MASK_BAD}))
	var gs4: Sprite2D = ml4.get("structured_ground")
	_report("loader.misfit", gs4 != null and ml4.get("structured_water_mask") == null
		and not gs4.has_meta(CellFluidFX.WATER_MASK_META))
	ml4.queue_free()


func _graph() -> CellGraph:
	# 2 x 2 tiles of 64 px, one cell each
	var data := {"n": 4, "export_scale": 2.0, "cx": [32.0, 96.0, 32.0, 96.0], "cy": [32.0, 32.0, 96.0, 96.0],
		"r": [32.0, 32.0, 32.0, 32.0], "fuel": [0.0, 0.0, 0.0, 0.0], "elev": [0.0, 0.0, 0.0, 0.0],
		"roof": [0.0, 0.0, 0.0, 0.0], "nb_off": [0, 2, 4, 6, 8], "nb": [1, 2, 0, 3, 0, 3, 1, 2]}
	var f := FileAccess.open(CELLS_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()
	return CellGraph.from_structured(CELLS_PATH)


func _fx(ground: Sprite2D, graph: CellGraph) -> CellFluidFX:
	var fx := CellFluidFX.new()
	add_child(fx)
	fx.setup(null, graph, ground, {}, [])
	return fx


func _case_fx_bind() -> void:
	var graph := _graph()
	var g := Sprite2D.new()
	g.texture = _tex(128, 128)
	add_child(g)
	var m := _tex(64, 64)
	MAP_LOADER.attach_water_mask(g, m)
	var fx := _fx(g, graph)
	var mat := g.material as ShaderMaterial
	_report("fx.bound", mat != null and fx.water_mask == m and mat.get_shader_parameter("water_mask") == m
		and float(mat.get_shader_parameter("water_mask_on")) == 1.0)
	# the calm frame: a SubViewport at 1/CALM_DIV of the mask, rendering the
	# ground through water_calm.gdshader once, bound as water_calm
	var cvp: SubViewport = fx.get("_calm_vp")
	var ctex: Variant = mat.get_shader_parameter("water_calm") if mat != null else null
	var spr: Sprite2D = cvp.get_child(0) as Sprite2D if cvp != null and cvp.get_child_count() > 0 else null
	_report("fx.calm-frame", cvp != null and ctex is ViewportTexture and cvp.size == Vector2i(32, 32)
		and cvp.render_target_update_mode == SubViewport.UPDATE_ONCE and spr != null and spr.texture == g.texture
		and spr.scale == Vector2(0.25, 0.25) and (spr.material as ShaderMaterial).shader == CellFluidFX.CALM_SHADER
		and (spr.material as ShaderMaterial).get_shader_parameter("water_mask") == m,
		"%s %s" % [str(cvp.size) if cvp != null else "no viewport", str(ctex)])
	fx.queue_free()
	g.queue_free()
	var g2 := Sprite2D.new()
	g2.texture = _tex(128, 128)
	add_child(g2)
	var fx2 := _fx(g2, graph)
	var mat2 := g2.material as ShaderMaterial
	_report("fx.none-without-mask", mat2 != null and fx2.water_mask == null and fx2.get("_calm_vp") == null
		and mat2.get_shader_parameter("water_mask") == null and mat2.get_shader_parameter("water_calm") == null
		and mat2.get_shader_parameter("water_mask_on") == null)
	# exactly the parameters CellFluidFX set before P3-A
	var want := ["flow_mask", "fluid_mask", "fluid_on", "wave_scale"]
	var have: Array = []
	for pn in ["fluid_mask", "flow_mask", "fluid_on", "wave_scale", "water_mask", "water_calm", "water_mask_on"]:
		if mat2 != null and mat2.get_shader_parameter(pn) != null:
			have.append(pn)
	have.sort()
	_report("fx.pre-p3a-parameters", have == want, str(have))
	fx2.queue_free()
	g2.queue_free()


func _case_end_to_end() -> void:
	var graph := _graph()
	GridManager.set_elevation_data(graph)
	var fm := FluidManager.new()
	fm.name = "FluidManager"
	add_child(fm)
	for with_mask in [true, false]:
		var ml := _loader()
		map_loader = ml
		ml.generate_structured_map(_row({"water": MASK_OK} if with_mask else {}))
		fm.setup_cell_graph(graph)
		await get_tree().process_frame
		var fx: CellFluidFX = fm.cell_fluid_fx
		var gs: Sprite2D = ml.get("structured_ground")
		var mat: ShaderMaterial = gs.material as ShaderMaterial if gs != null else null
		if with_mask:
			_report("e2e.bound", fx != null and mat != null and fx.water_mask != null
				and fx.water_mask == ml.get("structured_water_mask")
				and float(mat.get_shader_parameter("water_mask_on")) == 1.0)
		else:
			_report("e2e.contract2-unbound", fx != null and mat != null and fx.water_mask == null
				and mat.get_shader_parameter("water_mask_on") == null)
		fm.setup_cell_graph(null)
		ml.queue_free()
		map_loader = null
	fm.queue_free()


func _case_shader_text() -> void:
	var code: String = (load("res://shaders/water_surface.gdshader") as Shader).code
	_report("shader.uniforms", code.contains("uniform sampler2D water_mask : filter_linear, repeat_disable;")
		and code.contains("uniform float water_mask_on = 0.0;"))
	_report("shader.gated", code.contains("if (water_mask_on > 0.5) {")
		and code.contains("uniform sampler2D water_calm : filter_linear, repeat_disable;"))
	var calm: String = (load("res://shaders/water_calm.gdshader") as Shader).code
	_report("shader.calm", calm.contains("render_mode blend_disabled;") and calm.contains("const int OW_RANK = 5;")
		and calm.contains("uniform sampler2D water_mask : filter_linear, repeat_disable;"))
