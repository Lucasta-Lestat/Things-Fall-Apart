extends Node
# The painted open water, animated (P3-A visual half), on a REAL contract-3
# export: loads a row that ships images.water through MapLoader +
# FluidManager.setup_cell_graph (CellFluidFX binds the mask), renders a shore
# view into an offscreen SubViewport (the window stays 64 x 64, off-screen,
# unfocusable) and reads pixels:
#   1. land.unchanged: every pixel whose mask footprint is 0 is identical with
#      the open-water layer on and off (the branch never runs there);
#   2. water.animates: open-water pixels (mask c >= 0.99 over the footprint)
#      change between two frames ANIM_FRAMES apart, while land does not;
#   3. water.calm-kept: the layer keeps the painted water's own tone (its
#      median luma within CALM_TOL of the frame's) -- the frozen glints are
#      filtered out, not the water re-coloured;
#   4. water.glints-live: the live frame carries glints (luma p99 well over its
#      median) -- they move, they are not gone;
#   5. it reports the GPU time of the view with the layer on and off and the
#      VRAM the mask takes (Performance RENDER_TEXTURE_MEM_USED around its load).
# Needs a row with images.water whose files are imported in this project (a
# contract-3 TG export; under D3D12 never commit its art). The row comes from
# TFA_WATER_ROWS (a Maps.json path, may lie outside the project; default
# res://data/Maps.json), id TFA_WATER_MAP (default tg_hillside_harbor). Camera:
# TFA_CAM_X / TFA_CAM_Y (world px; default the shore texel nearest the map
# centre), TFA_CAM_ZOOM (default 1). Shots: TFA_SHOT_DIR (tests/shot_dir.gd).
# WINDOWED only (the headless renderer is a dummy):
#   godot --path . --fixed-fps 60 --resolution 64x64 --position -20000,-20000 res://tests/water_surface_shot.tscn
# Judge by the PASS/FAIL lines and "WATER SURFACE SHOT DONE: N checks, M FAIL"
# (exit 2: no usable row).

const MAP_LOADER := preload("res://Structures/MapLoader.gd")
const ShotDir := preload("res://tests/shot_dir.gd")
const SIZE := Vector2i(960, 640)
const ANIM_FRAMES := 45         # 0.75 s at --fixed-fps 60
const SETTLE_FRAMES := 8
const CALM_TOL := 0.02          # luma
const GPU_FRAMES := 30

# --- Game stand-in state (read by MapLoader / Structure / FluidManager) ---
var structures_in_scene: Array = []
var characters_in_scene: Array = []
var items_in_scene: Array = []
var party_chars: Array = []
var unlocked_locks: Dictionary = {}
var current_map_data: Dictionary = {}
var current_map_id := ""
var map_loader: Node2D = null

var sv: SubViewport
var _fails := 0
var _checks := 0
var _shot_dir := ""


func load_map(_a = null, _b = "", _c = "") -> void:
	pass   # SurfaceManager._get_game keys on this method name


func _report(check_name: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("%s %s: %s" % ["PASS" if ok else "FAIL", check_name, detail])


func _ready() -> void:
	add_to_group("game")
	var w := get_window()
	w.borderless = true
	w.unfocusable = true
	w.size = Vector2i(64, 64)
	w.position = Vector2i(-20000, -20000)
	TimeManager.pause_time()
	_shot_dir = ShotDir.dir("TFA_SHOT_DIR", true)
	var rc := await _run()
	print("WATER SURFACE SHOT DONE: %d checks, %d FAIL" % [_checks, _fails])
	get_tree().quit(rc if rc != 0 else (1 if _fails > 0 else 0))


func _row() -> Dictionary:
	var path := OS.get_environment("TFA_WATER_ROWS")
	if path == "":
		path = "res://data/Maps.json"
	var want := OS.get_environment("TFA_WATER_MAP")
	if want == "":
		want = "tg_hillside_harbor"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var raw: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (raw is Dictionary):
		return {}
	for e: Variant in (raw as Dictionary).get("maps", []):
		if e is Dictionary and String((e as Dictionary).get("id", "")) == want:
			return e
	return {}


func _run() -> int:
	print("water_surface_shot: renderer %s, %s" % [RenderingServer.get_video_adapter_api_version(),
		RenderingServer.get_video_adapter_name()])
	var row := _row()
	var images: Dictionary = row.get("images", {})
	var wpath := String(images.get("water", ""))
	if row.is_empty() or wpath == "" or not ResourceLoader.exists(wpath):
		print("water_surface_shot: no row with an imported images.water (TFA_WATER_ROWS / TFA_WATER_MAP)")
		return 2
	current_map_id = String(row.get("id", ""))
	current_map_data = row
	# VRAM: the mask alone, loaded before the map (MapLoader reuses the cached one)
	await RenderingServer.frame_post_draw
	var m0: float = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
	var mask_tex := load(wpath) as Texture2D
	await RenderingServer.frame_post_draw
	var m1: float = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
	var ground_tex := load(String(images.get("map", ""))) as Texture2D
	await RenderingServer.frame_post_draw
	var m2: float = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
	print("water_surface_shot: VRAM mask %s %.1f MB (RGBA8 %.1f MB), ground %s %.1f MB"
		% [str(mask_tex.get_size()), (m1 - m0) / 1048576.0, mask_tex.get_width() * mask_tex.get_height() * 4.0 / 1048576.0,
		str(ground_tex.get_size()), (m2 - m1) / 1048576.0])

	sv = SubViewport.new()
	sv.size = SIZE
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	GridManager.TILE_SIZE = int(row.get("tile_size", 64))
	var ws: Array = row.get("world_size", [2048, 2048])
	GridManager.initialize(int(ws[0]), int(ws[1]))
	var graph: CellGraph = CellGraph.from_structured(String(row.get("cell_graph", "")))
	GridManager.set_elevation_data(graph)
	var ml: Node2D = MAP_LOADER.new()
	sv.add_child(ml)
	ml.generate_structured_map(row)
	map_loader = ml
	var fm := FluidManager.new()
	fm.name = "FluidManager"
	add_child(fm)
	await get_tree().process_frame
	fm.setup_cell_graph(graph)
	var gs: Sprite2D = ml.get("structured_ground")
	var mat: ShaderMaterial = gs.material as ShaderMaterial if gs != null else null
	_report("setup.bound", mat != null and fm.cell_fluid_fx != null and fm.cell_fluid_fx.water_mask != null
		and float(mat.get_shader_parameter("water_mask_on")) == 1.0)
	if mat == null:
		return 1
	var mask_img := mask_tex.get_image()
	if mask_img.is_compressed():
		mask_img.decompress()
	var gsize := Vector2(gs.texture.get_size())
	var cam := Camera2D.new()
	cam.position = _camera_pos(mask_img, gsize)
	var zm := float(OS.get_environment("TFA_CAM_ZOOM")) if OS.get_environment("TFA_CAM_ZOOM") != "" else 1.0
	cam.zoom = Vector2(zm, zm)
	sv.add_child(cam)
	cam.make_current()
	print("water_surface_shot: %s, camera %s zoom %.2f" % [current_map_id, str(cam.position), zm])

	# the layer off (the painted frame), on, and on again ANIM_FRAMES later
	mat.set_shader_parameter("water_mask_on", 0.0)
	var off := await _shot("off")
	if off.get_size() != SIZE:
		_report("setup.rendered", false, "size %s (headless? run it windowed)" % str(off.get_size()))
		return 1
	var gpu_off := await _gpu_ms()
	mat.set_shader_parameter("water_mask_on", 1.0)
	var on1 := await _shot("on_t1")
	for _i in ANIM_FRAMES:
		await RenderingServer.frame_post_draw
	var on2 := await _shot("on_t2")
	var gpu_on := await _gpu_ms()
	print("water_surface_shot: GPU %.3f ms with the layer, %.3f ms without (%dx%d view)" % [gpu_on, gpu_off, SIZE.x, SIZE.y])

	# classify the view's pixels by the mask footprint under them
	var world0 := cam.position - Vector2(SIZE) * 0.5 / zm
	var msz := Vector2(mask_img.get_size())
	var land := 0
	var land_diff := 0
	var land_anim := 0
	var water := 0
	var water_anim := 0
	var l_off := PackedFloat32Array()
	var l_on := PackedFloat32Array()
	var diff_img := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGB8)
	for y in range(0, SIZE.y):
		for x in range(0, SIZE.x):
			var wp := world0 + (Vector2(x, y) + Vector2(0.5, 0.5)) / zm
			var mt := wp / gsize * msz - Vector2(0.5, 0.5)
			var cmin := 1.0
			var cmax := 0.0
			for oy: int in [0, 1]:
				for ox: int in [0, 1]:
					var t := Vector2i(clampi(int(floor(mt.x)) + ox, 0, int(msz.x) - 1), clampi(int(floor(mt.y)) + oy, 0, int(msz.y) - 1))
					var c: float = mask_img.get_pixelv(t).r
					cmin = minf(cmin, c)
					cmax = maxf(cmax, c)
			var a := off.get_pixel(x, y)
			var b := on1.get_pixel(x, y)
			var b2 := on2.get_pixel(x, y)
			var dab := _maxd(a, b)
			var d12 := _maxd(b, b2)
			diff_img.set_pixel(x, y, Color(minf(1.0, d12 * 4.0), minf(1.0, dab * 4.0), cmax))
			if cmax <= 0.0:
				land += 1
				if dab > 0.0:
					land_diff += 1
				if d12 > 0.0:
					land_anim += 1
			elif cmin >= 0.99:
				water += 1
				if d12 > 2.5 / 255.0:
					water_anim += 1
				if (x + y) % 3 == 0:
					l_off.append(_luma(a))
					l_on.append(_luma(b))
	if _shot_dir != "":
		diff_img.save_png("%s/water_surface_shot_%s_diff.png" % [_shot_dir, current_map_id])
	print("water_surface_shot: %d land px, %d open-water px in the view" % [land, water])
	_report("view.has-both", land > 1000 and water > 1000, "land %d, water %d" % [land, water])
	_report("land.unchanged", land_diff == 0, "%d of %d land px differ with the layer on" % [land_diff, land])
	_report("land.still", land_anim == 0, "%d of %d land px moved between the two frames" % [land_anim, land])
	var frac := float(water_anim) / float(maxi(1, water))
	_report("water.animates", frac >= 0.10, "%.1f %% of open-water px moved > 2.5/255 in %d frames" % [frac * 100.0, ANIM_FRAMES])
	var off_p := _pcts(l_off)
	var on_p := _pcts(l_on)
	print("water_surface_shot: open-water luma off p10/p50/p90/p99 %s, on %s" % [str(off_p), str(on_p)])
	_report("water.calm-kept", absf(on_p[1] - off_p[1]) <= CALM_TOL, "median %.3f on vs %.3f off" % [on_p[1], off_p[1]])
	_report("water.glints-live", on_p[3] - on_p[1] >= 0.10, "p99 %.3f over median %.3f" % [on_p[3], on_p[1]])
	return 0


func _camera_pos(mask_img: Image, gsize: Vector2) -> Vector2:
	if OS.get_environment("TFA_CAM_X") != "" and OS.get_environment("TFA_CAM_Y") != "":
		return Vector2(float(OS.get_environment("TFA_CAM_X")), float(OS.get_environment("TFA_CAM_Y")))
	# the shore texel (0.3 < c < 0.7) nearest the map centre
	var msz := Vector2(mask_img.get_size())
	var centre := msz * 0.5
	var best := centre
	var bd := INF
	for y in range(0, mask_img.get_height(), 4):
		for x in range(0, mask_img.get_width(), 4):
			var c: float = mask_img.get_pixel(x, y).r
			if c > 0.3 and c < 0.7:
				var d := Vector2(x, y).distance_squared_to(centre)
				if d < bd:
					bd = d
					best = Vector2(x, y)
	return (best + Vector2(0.5, 0.5)) / msz * gsize


func _shot(tag: String) -> Image:
	for _i in SETTLE_FRAMES:
		await RenderingServer.frame_post_draw
	var img := sv.get_texture().get_image()
	if _shot_dir != "":
		img.save_png("%s/water_surface_shot_%s_%s.png" % [_shot_dir, current_map_id, tag])
	return img


func _gpu_ms() -> float:
	var rid := sv.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	var acc := 0.0
	for _i in GPU_FRAMES:
		await RenderingServer.frame_post_draw
		acc += RenderingServer.viewport_get_measured_render_time_gpu(rid)
	RenderingServer.viewport_set_measure_render_time(rid, false)
	return acc / float(GPU_FRAMES)


func _maxd(a: Color, b: Color) -> float:
	return maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b)))


func _luma(c: Color) -> float:
	return c.r * 0.299 + c.g * 0.587 + c.b * 0.114


func _pcts(v: PackedFloat32Array) -> Array:
	if v.is_empty():
		return [0.0, 0.0, 0.0, 0.0]
	var s := v.duplicate()
	s.sort()
	var out: Array = []
	for q in [0.10, 0.50, 0.90, 0.99]:
		out.append(snappedf(s[mini(s.size() - 1, int(q * float(s.size())))], 0.001))
	return out
