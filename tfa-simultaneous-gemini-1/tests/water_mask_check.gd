extends Node2D
# The open-water mask's loading and binding (P3-A visual half; TG
# docs/export_contract.md "P3-A: the open-water mask"). A contract-3 row ships
# images.water, a mask at 1/k of the ground's size (TG writes k = 2):
#   1. MapLoader.water_mask_fits: a whole 1/k on both axes, k = 1..8, the same
#      k; anything else (another k per axis, a remainder, k = 9, empty) is not;
#      MapLoader.water_rect_of: the row's water_rect (TG crops the mask to the
#      water's bounding box) as a Rect2i inside the ground; no key = the whole
#      ground; a malformed or outlying rect = empty (the mask is ignored);
#   2. MapLoader.attach_water_mask puts a fitting mask on the ground sprite's
#      meta (CellFluidFX.WATER_MASK_META, its rect under WATER_RECT_META) and
#      refuses a misfit, a null mask, a rect off the ground or a ground without
#      a texture (no meta then);
#   3. generate_structured_map: a row with images.water exposes
#      structured_water_mask and the meta; a row without it (every contract-1/2
#      row) has neither; a missing file, a misfit mask or a bad water_rect warns
#      and reads none; generate_map (a warp to a legacy or world map) clears
#      structured_water_mask, so the last mask is not kept resident; with the
#      tfa/graphics/animated_water setting off the mask is never loaded (no
#      structured_water_mask, no meta: no VRAM);
#   4. CellFluidFX.setup binds the meta's mask to water_surface.gdshader
#      (water_mask, water_rect in UV + water_mask_on 1) and its calm frame
#      (water_calm: a SubViewport at half the mask's size drawing the mask's
#      rect of the ground once through water_calm.gdshader); without a mask,
#      or with the tfa/graphics/animated_water setting off, it sets none of
#      them, so the shader's open-water branch stays off (water_mask_on
#      defaults to 0) and the material carries exactly the pre-P3-A parameters;
#   5. end to end: MapLoader -> FluidManager.setup_cell_graph -> CellFluidFX,
#      the way Game.load_map wires a structured map;
#   6. the shader declares the pair with the branch off by default, the c <
#      0.25 gate, the calm frame's shore rank, and both shaders' remap of the
#      ground UV into water_rect (the cropped mask, the calm frame).
#   7. tests/water_surface_shot's gpu.layer-ms-per-mpx verdict (gpu_verdict,
#      pure; the shot is windowed): no GPU time measured (0 ms) or too little
#      layer area is a SKIP, an on block no slower than the off block a FAIL,
#      else the ceiling decides;
#   The setting's default is checked through CellFluidFX.animated_water_on()
#   with the setting cleared: on (a project.godot that declares it must
#   declare it true).
# The masks are ImageTextures saved to user:// (no art in the project); the
# ground is res://icon.svg (128 x 128). What the shader draws is
# tests/water_surface_shot.tscn's (windowed; needs a contract-3 export).
# Headless:  godot --headless --path . res://tests/water_mask_check.tscn
# Judge by the PASS/FAIL lines and "WATER MASK CHECK DONE: N checks, M FAIL".
const MAP_LOADER := preload("res://Structures/MapLoader.gd")
const SHOT := preload("res://tests/water_surface_shot.gd")
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
	_case_rect()
	_case_attach()
	_case_loader()
	_case_stale_after_legacy()
	_case_fx_bind()
	_case_fx_rect()
	_case_off_switch()
	await _case_end_to_end()
	_case_shader_text()
	_case_gpu_verdict()
	print("WATER MASK CHECK DONE: %d checks, %d FAIL" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _save_mask(path: String, w: int, h: int) -> void:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 0.9, 0.7, 0.27))   # open water, drift (0.8, 0.4), q 0.27
	ResourceSaver.save(ImageTexture.create_from_image(img), path)


func _tex(w: int, h: int) -> ImageTexture:
	return ImageTexture.create_from_image(Image.create(w, h, false, Image.FORMAT_RGBA8))


func _row(images_extra: Dictionary, rect: Variant = null) -> Dictionary:
	var imgs := {"map": GROUND}
	imgs.merge(images_extra, true)
	var row := {"id": "water_mask_check", "format": "structured", "images": imgs, "export_contract": 3.0,
		"tile_size": 64, "world_size": [128, 128], "floors": [], "structures": []}
	if rect != null:
		row["water_rect"] = rect
	return row


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


func _case_rect() -> void:
	var gs := Vector2i(128, 128)
	_report("rect.absent-is-whole", MAP_LOADER.water_rect_of(null, gs) == Rect2i(0, 0, 128, 128))
	_report("rect.json-floats", MAP_LOADER.water_rect_of([16.0, 32.0, 64.0, 48.0], gs) == Rect2i(16, 32, 64, 48))
	_report("rect.ints", MAP_LOADER.water_rect_of([0, 0, 128, 128], gs) == Rect2i(0, 0, 128, 128))
	for bad: Variant in [[16.5, 0.0, 64.0, 64.0], [0.0, 0.0, 64.0], [0.0, 0.0, 0.0, 64.0], [-8.0, 0.0, 64.0, 64.0],
			[96.0, 0.0, 64.0, 64.0], [0.0, 0.0, 64.0, 136.0], "0,0,64,64", {"x": 0}, [0.0, 0.0, "64", 64.0]]:
		_report("rect.bad %s" % str(bad), not MAP_LOADER.water_rect_of(bad, gs).has_area())
	# a cropped mask fits its rect, not the ground
	_report("fits.k2-rect", MAP_LOADER.water_mask_fits(Vector2i(32, 24), Vector2i(64, 48)))


func _case_attach() -> void:
	var g := Sprite2D.new()
	g.texture = _tex(128, 128)
	var m := _tex(64, 64)
	_report("attach.fit", MAP_LOADER.attach_water_mask(g, m) and g.get_meta(CellFluidFX.WATER_MASK_META, null) == m
		and g.get_meta(CellFluidFX.WATER_RECT_META, null) == Rect2i(0, 0, 128, 128))
	var gr := Sprite2D.new()
	gr.texture = _tex(128, 128)
	var mc := _tex(32, 24)
	_report("attach.cropped", MAP_LOADER.attach_water_mask(gr, mc, Rect2i(16, 32, 64, 48))
		and gr.get_meta(CellFluidFX.WATER_MASK_META, null) == mc
		and gr.get_meta(CellFluidFX.WATER_RECT_META, null) == Rect2i(16, 32, 64, 48))
	var gr2 := Sprite2D.new()
	gr2.texture = _tex(128, 128)
	_report("attach.cropped-misfit", not MAP_LOADER.attach_water_mask(gr2, mc, Rect2i(16, 32, 64, 64))
		and not gr2.has_meta(CellFluidFX.WATER_MASK_META) and not gr2.has_meta(CellFluidFX.WATER_RECT_META))
	_report("attach.rect-off-ground", not MAP_LOADER.attach_water_mask(gr2, mc, Rect2i(96, 32, 64, 48))
		and not gr2.has_meta(CellFluidFX.WATER_MASK_META))
	gr.free()
	gr2.free()
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
	# a 64 x 64 mask on the cropped rect [0, 0, 128, 128] (k = 2): fits
	var ml5 := _loader()
	ml5.generate_structured_map(_row({"water": MASK_OK}, [0.0, 0.0, 128.0, 128.0]))
	var gs5: Sprite2D = ml5.get("structured_ground")
	_report("loader.with-rect", gs5 != null and ml5.get("structured_water_mask") != null
		and gs5.get_meta(CellFluidFX.WATER_RECT_META, null) == Rect2i(0, 0, 128, 128))
	ml5.queue_free()
	# the same mask on a rect it does not span at a whole 1/k, and on a malformed rect
	for bad: Variant in [[0.0, 0.0, 96.0, 128.0], [0.0, 0.0, 128.0]]:
		var ml6 := _loader()
		ml6.generate_structured_map(_row({"water": MASK_OK}, bad))
		var gs6: Sprite2D = ml6.get("structured_ground")
		_report("loader.bad-rect %s" % str(bad), gs6 != null and ml6.get("structured_water_mask") == null
			and not gs6.has_meta(CellFluidFX.WATER_MASK_META))
		ml6.queue_free()


# A warp from a watery structured map to a legacy or world map goes through
# generate_map: the loader (Game keeps one) must drop the last map's mask, or
# its texture stays resident until the next structured load. World mode with a
# missing source image returns early (an error line, no tiles), the cheapest
# generate_map there is.
func _case_stale_after_legacy() -> void:
	var ml := _loader()
	ml.generate_structured_map(_row({"water": MASK_OK}))
	var had: bool = ml.get("structured_water_mask") != null
	ml.set("world_map_mode", true)
	ml.set("map_image_path", "res://tests/water_mask_check_no_such_world.png")
	ml.call("generate_map")
	_report("loader.cleared-by-generate_map", had and ml.get("structured_water_mask") == null,
		"had a mask: %s, after generate_map: %s" % [str(had), str(ml.get("structured_water_mask"))])
	ml.queue_free()


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
		and spr.region_enabled and spr.region_rect == Rect2(0, 0, 128, 128)
		and spr.scale == Vector2(0.25, 0.25) and (spr.material as ShaderMaterial).shader == CellFluidFX.CALM_SHADER
		and (spr.material as ShaderMaterial).get_shader_parameter("water_mask") == m
		and (spr.material as ShaderMaterial).get_shader_parameter("water_rect") == Vector4(0.0, 0.0, 1.0, 1.0)
		and mat.get_shader_parameter("water_rect") == Vector4(0.0, 0.0, 1.0, 1.0),
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
	_report("fx.pre-p3a-parameters", _set_params(mat2) == PRE_P3A, str(_set_params(mat2)))
	fx2.queue_free()
	g2.queue_free()


const PRE_P3A := ["flow_mask", "fluid_mask", "fluid_on", "wave_scale"]

func _set_params(mat: ShaderMaterial) -> Array:
	var have: Array = []
	for pn in ["fluid_mask", "flow_mask", "fluid_on", "wave_scale", "water_mask", "water_calm", "water_rect", "water_mask_on"]:
		if mat != null and mat.get_shader_parameter(pn) != null:
			have.append(pn)
	have.sort()
	return have


# a mask cropped to the ground rect [16, 32, 64, 48] (k = 2: 32 x 24): the water
# shader maps the ground UV into that rect, the calm frame draws only that
# region of the ground (16 x 12 texels) and maps its taps the same way
func _case_fx_rect() -> void:
	var graph := _graph()
	var g := Sprite2D.new()
	g.texture = _tex(128, 128)
	add_child(g)
	var m := _tex(32, 24)
	MAP_LOADER.attach_water_mask(g, m, Rect2i(16, 32, 64, 48))
	var fx := _fx(g, graph)
	var mat := g.material as ShaderMaterial
	var want_uv := Vector4(0.125, 0.25, 0.5, 0.375)
	var cvp: SubViewport = fx.get("_calm_vp")
	var spr: Sprite2D = cvp.get_child(0) as Sprite2D if cvp != null and cvp.get_child_count() > 0 else null
	_report("fx.rect-bound", mat != null and float(mat.get_shader_parameter("water_mask_on")) == 1.0
		and mat.get_shader_parameter("water_rect") == want_uv, str(mat.get_shader_parameter("water_rect") if mat != null else null))
	_report("fx.rect-calm", cvp != null and cvp.size == Vector2i(16, 12) and spr != null and spr.region_enabled
		and spr.region_rect == Rect2(16, 32, 64, 48) and spr.scale == Vector2(0.25, 0.25)
		and (spr.material as ShaderMaterial).get_shader_parameter("water_rect") == want_uv,
		"%s %s %s" % [str(cvp.size) if cvp != null else "-", str(spr.region_rect) if spr != null else "-", str(spr.scale) if spr != null else "-"])
	fx.queue_free()
	g.queue_free()


# tfa/graphics/animated_water off: a map that ships a mask shows exactly its
# painted frame (the pre-P3-A material, no calm frame); on again: bound
func _case_off_switch() -> void:
	var graph := _graph()
	var had: bool = ProjectSettings.has_setting(CellFluidFX.ANIMATED_WATER_SETTING)
	var old: Variant = ProjectSettings.get_setting(CellFluidFX.ANIMATED_WATER_SETTING, null)
	# the default through the getter alone (the setting cleared); a project
	# that declares the setting (an options menu would) must declare it on
	if had:
		ProjectSettings.clear(CellFluidFX.ANIMATED_WATER_SETTING)
	var unset_on := CellFluidFX.animated_water_on()
	if had:
		ProjectSettings.set_setting(CellFluidFX.ANIMATED_WATER_SETTING, old)
	_report("off.default-on", unset_on and (not had or bool(old)),
		"unset reads %s; declared: %s (%s)" % [str(unset_on), str(had), str(old)])
	ProjectSettings.set_setting(CellFluidFX.ANIMATED_WATER_SETTING, false)
	# off, the loader never loads the mask: no structured_water_mask, no meta
	# on the ground (so the mask takes no VRAM), the row otherwise loaded
	var mlo := _loader()
	mlo.generate_structured_map(_row({"water": MASK_OK}))
	var gso: Sprite2D = mlo.get("structured_ground")
	_report("off.loader-skips-mask", gso != null and mlo.get("structured_water_mask") == null
		and not gso.has_meta(CellFluidFX.WATER_MASK_META) and not gso.has_meta(CellFluidFX.WATER_RECT_META),
		"structured_water_mask %s, ground meta %s" % [str(mlo.get("structured_water_mask")),
		str(gso.has_meta(CellFluidFX.WATER_MASK_META)) if gso != null else "no ground"])
	mlo.queue_free()
	var g := Sprite2D.new()
	g.texture = _tex(128, 128)
	add_child(g)
	MAP_LOADER.attach_water_mask(g, _tex(64, 64))
	var fx := _fx(g, graph)
	var mat := g.material as ShaderMaterial
	_report("off.painted-frame", mat != null and fx.water_mask == null and fx.get("_calm_vp") == null
		and _set_params(mat) == PRE_P3A, str(_set_params(mat)))
	fx.queue_free()
	ProjectSettings.set_setting(CellFluidFX.ANIMATED_WATER_SETTING, true)
	var fx2 := _fx(g, graph)
	var mat2 := g.material as ShaderMaterial
	_report("off.on-again", mat2 != null and fx2.water_mask != null and float(mat2.get_shader_parameter("water_mask_on")) == 1.0)
	fx2.queue_free()
	g.queue_free()
	if had:
		ProjectSettings.set_setting(CellFluidFX.ANIMATED_WATER_SETTING, old)
	else:
		ProjectSettings.clear(CellFluidFX.ANIMATED_WATER_SETTING)


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
	_report("shader.gated", code.contains("if (water_mask_on > 0.5 && wuv.x >= 0.0")
		and code.contains("uniform sampler2D water_calm : filter_linear, repeat_disable;")
		and code.contains("uniform vec4 water_rect = vec4(0.0, 0.0, 1.0, 1.0);"))
	# nothing is computed where the blend weight is 0 (c <= 0.25): the same
	# pixels as computing it and mixing by 0
	_report("shader.weight-gate", code.contains("float ww = smoothstep(0.25, 0.75, wc);")
		and code.contains("if (ww > 0.0) {") and code.contains("col = mix(col, live, ww);"))
	# the ground UV mapped into water_rect (a mask cropped to the water): the
	# mask and the calm frame are both looked up there, never at UV
	_report("shader.rect-remap", code.contains("vec2 wuv = (UV - water_rect.xy) / water_rect.zw;")
		and code.contains("vec4 wmk = texture(water_mask, wuv);") and code.contains("vec4 cm = texture(water_calm, wuv);")
		and not code.contains("texture(water_mask, UV)") and not code.contains("texture(water_calm, UV)"))
	# the open water's surface is waterSurf's six warpfields in one loop; the
	# dynamic fluids keep waterSurf itself
	_report("shader.surface", code.contains("float oh = waterSurfOW(Wn, normalize(odir + vec2(1e-4)), TIME, ogr);")
		and code.contains("float hA = waterSurf(Wn - offA, vec2(0.22, -0.14), TIME, gradA);"))
	var calm: String = (load("res://shaders/water_calm.gdshader") as Shader).code
	_report("shader.calm", calm.contains("render_mode blend_disabled;") and calm.contains("const int OW_RANK = 5;")
		and calm.contains("int kk = min(OW_RANK, (nv - 1) / 2);")
		and calm.contains("uniform sampler2D water_mask : filter_linear, repeat_disable;")
		and calm.contains("uniform vec4 water_rect = vec4(0.0, 0.0, 1.0, 1.0);"))
	# its taps' open-water test maps the ground UV into water_rect the same way
	_report("shader.calm-rect-remap", calm.contains("return texture(water_mask, (uv - water_rect.xy) / water_rect.zw).r;")
		and not calm.contains("texture(water_mask, uv)") and not calm.contains("texture(water_mask, UV)"))


# 7. the shot's GPU verdict: a measurement that never happened is not a pass
func _case_gpu_verdict() -> void:
	var zero: Array = [0.0, 0.0, 0.0]
	var cases: Array = [
		# [name, ons, offs, layer Mpx, ceiling, verdict]
		["no-timestamps-skip", zero, zero, 1.5, 1.0, "SKIP"],
		["off-unmeasured-skip", [0.9, 1.0], zero, 1.5, 1.0, "SKIP"],
		["no-cost-fails", [0.4, 0.5], [0.4, 0.45], 1.5, 1.0, "FAIL"],
		["cheaper-on-fails", [0.3, 0.5], [0.4, 0.45], 1.5, 1.0, "FAIL"],
		["small-view-skip", [1.3, 1.4], [0.4, 0.45], 0.3, 1.0, "SKIP"],
		["within-ceiling-pass", [1.3, 1.4], [0.4, 0.45], 1.5, 1.0, "PASS"],   # 0.6 ms / Mpx
		["over-ceiling-fails", [2.4, 2.5], [0.4, 0.45], 1.5, 1.0, "FAIL"],    # 1.33 ms / Mpx
	]
	for c: Array in cases:
		var v: Dictionary = SHOT.gpu_verdict(c[1], c[2], float(c[3]), float(c[4]))
		_report("gpu-verdict.%s" % String(c[0]), String(v["verdict"]) == String(c[5]),
			"%s (%s), want %s" % [String(v["verdict"]), String(v["why"]), String(c[5])])
