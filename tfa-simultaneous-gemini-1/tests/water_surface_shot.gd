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
#      median and p10 luma within CALM_TOL of the frame's) -- the frozen glints
#      are filtered out, not the water re-coloured or its shadows spread;
#   3b. water.shore-tone-kept: the same within EDGE_PX of the shore (median and
#      p10), where the frame's own lip shadows and dark rims sit;
#   4. water.glints-live: the live frame carries glints (luma p99 well over its
#      median) -- they move, they are not gone;
#   5. vram.mask-is-rgba8: loading the mask adds about 4 bytes a texel to
#      Performance RENDER_TEXTURE_MEM_USED (measured after the ground's load;
#      up to 10 % + 128 KiB allocator slack; on Vulkan + NVIDIA the exact
#      block-linear size (width to 16 texels, height to the 8..128-row block)
#      + 2 % + 128 KiB, so no second copy), and the
#      imported mask has no mipmaps;
#      it reports that, the ground's, and the GPU time of the view with the
#      layer on and off;
#   6. gpu.layer-ms-per-mpx: the layer's GPU cost, the number
#      docs/export_contract.md records (P3-A "GPU"): GPU_VIEWS views of
#      GPU_VIEW px (1080p) on the window with the most open water, all drawing
#      the ground with the map's own water material, measured in alternating
#      blocks with the layer on and off (median of GPU_BLOCKS blocks of the
#      per-frame GPU time of one view; several views keep the GPU clocked up as
#      a game frame does, so the number is stable). Printed as "GPU 1080p
#      view" and JUDGED: the layer's ms per Mpx of the view's layer pixels (c >
#      0.25, where its branch runs), taken from the fastest on block less the
#      fastest off block (other GPU work on a shared machine only ever adds
#      time; the median is printed too), must stay within GPU_CEIL_MS_PER_MPX,
#      the ceiling set for the RTX 4080 Laptop the docs measure on (about 1.6 x
#      the 0.63 measured on harbour's all-sea view, 0.54 on lower's; a full
#      1080p screen of sea at the ceiling costs 2.1 ms): a regression to the
#      per-pixel calm frame or a second surface fails it. Another GPU sets
#      TFA_GPU_CEIL_MS_PER_MPX (ms per Mpx) to its own. A view with fewer than
#      GPU_MIN_MPX Mpx of layer pixels prints a SKIP line instead, not counted
#      as a check: a narrow channel's view pays the shore's warp divergence and
#      the off subtraction's noise per Mpx (ossuary 0.78, middle 0.87 at 0.3-0.4
#      Mpx), so it would judge the map's shape, not the shader. No GPU time
#      measured (a renderer or driver without GPU timestamps reads 0 ms) is a
#      SKIP too; a fastest on block no slower than the fastest off block is a
#      FAIL (the layer measured no cost: the toggle never reached it), not a
#      pass at 0 ms per Mpx (gpu_verdict; tests/water_mask_check checks it).
#      tfa/graphics/animated_water switches the layer off.
# The mask covers the row's water_rect of the ground (TG crops it to the
# water's bounding box; no key = the whole ground): every lookup maps there.
# Needs a row with images.water whose files are imported in this project (a
# contract-3 TG export; under D3D12 never commit its art). The row comes from
# TFA_WATER_ROWS (a Maps.json path, may lie outside the project; default
# res://data/Maps.json), id TFA_WATER_MAP (default tg_hillside_harbor). Camera:
# TFA_CAM_X / TFA_CAM_Y (world px; default the shore of the mask's 64-texel block
# with the most open water; before P3-L, the shore texel nearest the map
# centre), TFA_CAM_ZOOM (default 1, or up to 4 where so little open water is
# in view that view.has-both could not pass: tg_export's wadeable pools). Shots: TFA_SHOT_DIR (tests/shot_dir.gd).
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
const EDGE_PX := 16.0           # the shore band of water.shore-tone-kept, screen px
const GPU_FRAMES := 30
const GPU_VIEW := Vector2i(1920, 1080)
const GPU_VIEWS := 6
const GPU_BLOCKS := 8
const GPU_CEIL_MS_PER_MPX := 1.0   # the RTX 4080 Laptop's ceiling (TFA_GPU_CEIL_MS_PER_MPX overrides)
const GPU_MIN_MPX := 0.5           # less layer area than this in the 1080p view: not judged

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
var _wrect := Rect2()   # the ground rect the mask covers (the row's water_rect)
# the default zoom: 1, or more on a map whose open water is too scarce for the
# view to hold the >1000 water px view.has-both needs (set by _camera_pos)
var _auto_zoom := 1.0
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
	# VRAM (RENDER_TEXTURE_MEM_USED around each load; the ground first, so the
	# mask's delta carries no first-upload overhead; MapLoader reuses both)
	await RenderingServer.frame_post_draw
	var m0: float = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
	var ground_tex := load(String(images.get("map", ""))) as Texture2D
	await RenderingServer.frame_post_draw
	var m1: float = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
	var mask_tex := load(wpath) as Texture2D
	await RenderingServer.frame_post_draw
	var m2: float = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
	var rgba8: float = float(mask_tex.get_width() * mask_tex.get_height() * 4)
	var mask_b: float = m2 - m1
	# the ground's own delta carries the first upload's staging overhead: the
	# share is against its RGBA8 size
	var g_rgba8: float = float(ground_tex.get_width() * ground_tex.get_height() * 4)
	print("water_surface_shot: VRAM mask %s %.2f MiB (RGBA8 %.2f MiB); ground %s RGBA8 %.2f MiB (its load: %+.2f MiB); the mask adds %.1f %%"
		% [str(mask_tex.get_size()), mask_b / 1048576.0, rgba8 / 1048576.0, str(ground_tex.get_size()),
		g_rgba8 / 1048576.0, (m1 - m0) / 1048576.0, 100.0 * mask_b / g_rgba8])
	# RGBA8 plus the allocator's slack (D3D12: +6 % on the big masks; a narrow
	# crop pads its rows and rounds up to 64 KiB blocks: tg_guild_hall's 100 x
	# 1368 creek mask takes 640 KiB for 534 KiB of texels, hence the 128 KiB);
	# a second copy or a wider format would add far more, and the imported
	# image must carry no mipmaps (they would add a third).
	# Vulkan on NVIDIA allocates block-linear: 64 B x 8-row GOBs, the width
	# padded to 16 texels and the height to the block height, 8 rows x the
	# smallest power of two GOBs covering the image, at most 16 (128 rows).
	# Measured on the RTX 4080 Laptop (P3-T, 2026-11-15) every Perrow mask took
	# exactly that: lower's 3680 x 572 -> 3680 x 640 x 4 = 9420800 B (+11.9 %),
	# ossuary's 2648 x 548 -> 2656 x 640 x 4 (+17.1 %), where the D3D12-tuned
	# 10 % failed. So on Vulkan + NVIDIA the bound is that exact tiled size
	# (+2 % + 128 KiB): a second copy or a 16-bit format doubles it and fails.
	# Any other driver keeps the RGBA8 bound.
	var mw: int = mask_tex.get_width()
	var mh: int = mask_tex.get_height()
	var block_rows: int = 8 * mini(16, nearest_po2(ceili(mh / 8.0)))
	var tiled: float = float(ceili(mw / 16.0) * 16 * ceili(float(mh) / float(block_rows)) * block_rows * 4)
	var nv_vulkan: bool = RenderingServer.get_video_adapter_api_version().begins_with("1.") \
		and RenderingServer.get_video_adapter_vendor().to_lower().contains("nvidia")
	var vram_cap: float = (tiled * 1.02 if nv_vulkan else rgba8 * 1.10) + 131072.0
	var mask_mips := mask_tex.get_image().has_mipmaps()
	_report("vram.mask-is-rgba8", mask_b > 0.0 and mask_b <= vram_cap and not mask_mips,
		"%.0f B for %s (RGBA8 = %.0f B, %s cap %.0f B), mipmaps %s"
		% [mask_b, str(mask_tex.get_size()), rgba8,
			("NVIDIA Vulkan block-linear %.0f B," % tiled) if nv_vulkan else "RGBA8", vram_cap, str(mask_mips)])

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
	var wrv: Variant = gs.get_meta(CellFluidFX.WATER_RECT_META, null)
	_wrect = Rect2(wrv as Rect2i) if wrv is Rect2i else Rect2(Vector2.ZERO, gsize)
	print("water_surface_shot: mask %s on the ground rect %s of %s" % [str(mask_img.get_size()), str(_wrect), str(gsize)])
	var cam := Camera2D.new()
	cam.position = _camera_pos(mask_img, gsize)
	var zm := float(OS.get_environment("TFA_CAM_ZOOM")) if OS.get_environment("TFA_CAM_ZOOM") != "" else _auto_zoom
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
	var e_off := PackedFloat32Array()   # open water within EDGE_PX of the shore
	var e_on := PackedFloat32Array()
	var reach := EDGE_PX / zm / _wrect.size.x * msz.x   # EDGE_PX screen px in mask texels
	var diff_img := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGB8)
	for y in range(0, SIZE.y):
		for x in range(0, SIZE.x):
			var wp := world0 + (Vector2(x, y) + Vector2(0.5, 0.5)) / zm
			var mt := (wp - _wrect.position) / _wrect.size * msz - Vector2(0.5, 0.5)
			var cmin := 1.0
			var cmax := 0.0
			if not _wrect.has_point(wp):
				cmin = 0.0   # past the crop: land (the mask holds zero texels around its water)
			else:
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
					var shore := false
					for dv: Vector2 in [Vector2(reach, 0.0), Vector2(-reach, 0.0), Vector2(0.0, reach), Vector2(0.0, -reach)]:
						var te := Vector2i(clampi(int(round(mt.x + dv.x)), 0, int(msz.x) - 1), clampi(int(round(mt.y + dv.y)), 0, int(msz.y) - 1))
						shore = shore or mask_img.get_pixelv(te).r < 0.99
					if shore:
						e_off.append(_luma(a))
						e_on.append(_luma(b))
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
	# p10 too: a de-glint that spreads the frame's darker bands (its shadows, a
	# dark rim) into the water darkens the low tail before the median
	_report("water.calm-kept", absf(on_p[1] - off_p[1]) <= CALM_TOL and absf(on_p[0] - off_p[0]) <= CALM_TOL,
		"p10 %.3f / median %.3f on vs %.3f / %.3f off" % [on_p[0], on_p[1], off_p[0], off_p[1]])
	# by the shore the frame has its own shading (lip shadows, a dark rim): the
	# de-glint must not spread it into the water (a darkest-tap filter did, and
	# printed its tap rings as lines parallel to the shore)
	var eoff_p := _pcts(e_off)
	var eon_p := _pcts(e_on)
	print("water_surface_shot: open water within %d px of the shore (%d samples): luma off %s, on %s" % [int(EDGE_PX), e_off.size(), str(eoff_p), str(eon_p)])
	_report("water.shore-tone-kept", e_off.size() < 50 or (absf(eon_p[1] - eoff_p[1]) <= CALM_TOL and absf(eon_p[0] - eoff_p[0]) <= CALM_TOL),
		"p10 %.3f / median %.3f on vs %.3f / %.3f off" % [eon_p[0], eon_p[1], eoff_p[0], eoff_p[1]])
	_report("water.glints-live", on_p[3] - on_p[1] >= 0.10, "p99 %.3f over median %.3f" % [on_p[3], on_p[1]])
	await _gpu_1080p(gs, mat, mask_img, gsize)
	return 0


# 6. the layer's GPU cost on a 1080p view of the most open water (see the header)
func _gpu_1080p(gs: Sprite2D, mat: ShaderMaterial, mask_img: Image, gsize: Vector2) -> void:
	var centre := _most_water(mask_img, gsize, Vector2(GPU_VIEW))
	var vrect := Rect2(centre - Vector2(GPU_VIEW) * 0.5, Vector2(GPU_VIEW))
	var share := _open_share(mask_img, gsize, vrect)
	var lshare := _open_share(mask_img, gsize, vrect, 8.0, 0.25)   # the layer's pixels: its branch runs
	var vps: Array = []
	for _k in GPU_VIEWS:
		var vp := SubViewport.new()
		vp.size = GPU_VIEW
		vp.disable_3d = true
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(vp)
		vp.canvas_transform = Transform2D(0.0, Vector2(GPU_VIEW) * 0.5 - centre)
		var spr := Sprite2D.new()
		spr.texture = gs.texture
		spr.centered = false
		spr.texture_filter = gs.texture_filter
		spr.material = mat
		vp.add_child(spr)
		vps.append(vp)
	var rid: RID = (vps[0] as SubViewport).get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	var ons: Array = []
	var offs: Array = []
	for _b in GPU_BLOCKS:
		for on: float in [1.0, 0.0]:
			mat.set_shader_parameter("water_mask_on", on)
			for _i in 5:
				await RenderingServer.frame_post_draw
			var vals: Array = []
			for _i in GPU_FRAMES:
				await RenderingServer.frame_post_draw
				vals.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
			vals.sort()
			(ons if on > 0.5 else offs).append(float(vals[int(vals.size() / 2.0)]))
	RenderingServer.viewport_set_measure_render_time(rid, false)
	mat.set_shader_parameter("water_mask_on", 1.0)
	for vp in vps:
		(vp as SubViewport).queue_free()
	ons.sort()
	offs.sort()
	var on_ms: float = ons[int(ons.size() / 2.0)]
	var off_ms: float = offs[int(offs.size() / 2.0)]
	var vmpx: float = float(GPU_VIEW.x * GPU_VIEW.y) / 1e6
	var layer_ms: float = on_ms - off_ms
	var per_open: float = layer_ms / maxf(1e-6, share * vmpx)
	var lmpx: float = lshare * vmpx
	var per_layer: float = layer_ms / maxf(1e-6, lmpx)
	# the judged number: the fastest blocks (other GPU work only adds time)
	var fast_ms: float = float(ons[0]) - float(offs[0])
	var per_fast: float = fast_ms / maxf(1e-6, lmpx)
	print("water_surface_shot: GPU 1080p view (%d x %dx%d at %s, %.0f %% open water = %.2f Mpx, %.0f %% layer px = %.2f Mpx): layer on %.3f ms, off %.3f ms, the layer %.3f ms (%.3f ms per Mpx of open water, %.3f per Mpx of layer px; a full screen of it: %.2f ms at 1080p, %.2f ms at 4K); fastest blocks: the layer %.3f ms, %.3f ms per Mpx of layer px (blocks on %s, off %s)"
		% [GPU_VIEWS, GPU_VIEW.x, GPU_VIEW.y, str(centre.round()), share * 100.0, share * vmpx, lshare * 100.0, lmpx,
		on_ms, off_ms, layer_ms, per_open, per_layer, per_layer * vmpx, per_layer * vmpx * 4.0, fast_ms, per_fast, str(ons), str(offs)])
	var ceil_s := OS.get_environment("TFA_GPU_CEIL_MS_PER_MPX")
	var ceil_ms: float = float(ceil_s) if ceil_s != "" else GPU_CEIL_MS_PER_MPX
	var v: Dictionary = gpu_verdict(ons, offs, lmpx, ceil_ms)
	var verdict: String = String(v["verdict"])
	var why: String = String(v["why"])
	if verdict == "SKIP":
		print("SKIP gpu.layer-ms-per-mpx: %s" % why)
	else:
		_report("gpu.layer-ms-per-mpx", verdict == "PASS", "%s%.3f ms per Mpx of layer px, fastest blocks (ceiling %.2f%s; median blocks %.3f): %.3f ms on %.2f Mpx"
			% [why + ": " if why != "" else "", per_fast, ceil_ms, ", TFA_GPU_CEIL_MS_PER_MPX" if ceil_s != "" else "", per_layer, fast_ms, lmpx])


# the gpu.layer-ms-per-mpx verdict (header, 6.) from the blocks' medians, each list
# sorted ascending, judged on the fastest on block less the fastest off block:
# {"verdict": "SKIP" | "PASS" | "FAIL", "per_fast": ms per Mpx of layer px,
# "why": the reason of a SKIP, or of a FAIL other than the ceiling}. Too little
# layer area, or no GPU time measured (0 ms on either side: no GPU timestamps),
# is a SKIP; an on block no slower than the off block is a FAIL, never a pass.
static func gpu_verdict(ons: Array, offs: Array, lmpx: float, ceil_ms: float) -> Dictionary:
	var on0: float = float(ons[0]) if ons.size() > 0 else 0.0
	var off0: float = float(offs[0]) if offs.size() > 0 else 0.0
	var per_fast: float = (on0 - off0) / maxf(1e-6, lmpx)
	if lmpx < GPU_MIN_MPX:
		return {"verdict": "SKIP", "per_fast": per_fast,
			"why": "%.2f Mpx of layer px in the view (< %.2f), too little to measure" % [lmpx, GPU_MIN_MPX]}
	if on0 <= 0.0 or off0 <= 0.0:
		return {"verdict": "SKIP", "per_fast": per_fast,
			"why": "no GPU time measured (fastest blocks on %.3f ms, off %.3f ms: the renderer gives no GPU timestamps)" % [on0, off0]}
	if on0 <= off0:
		return {"verdict": "FAIL", "per_fast": per_fast,
			"why": "the layer measured no cost (fastest blocks on %.3f ms, off %.3f ms): the toggle never reached it" % [on0, off0]}
	return {"verdict": "PASS" if per_fast <= ceil_ms else "FAIL", "per_fast": per_fast, "why": ""}


# the open-water (c >= 0.99) share of a ground rect, sampled every `step` ground
# px; with `above`, the share of c > above instead (0.25: the layer's pixels)
func _open_share(mask_img: Image, gsize: Vector2, r: Rect2, step: float = 8.0, above: float = -1.0) -> float:
	var msz := Vector2(mask_img.get_size())
	var n := 0
	var w := 0
	var y := r.position.y + step * 0.5
	while y < r.end.y:
		var x := r.position.x + step * 0.5
		while x < r.end.x:
			n += 1
			var wp := Vector2(x, y)
			if _wrect.has_point(wp) and x >= 0.0 and y >= 0.0 and x < gsize.x and y < gsize.y:
				var t := Vector2i(((wp - _wrect.position) / _wrect.size * msz).floor())
				var c: float = mask_img.get_pixelv(t.clamp(Vector2i.ZERO, Vector2i(msz) - Vector2i.ONE)).r
				var hit: bool = (c > above) if above >= 0.0 else (c >= 0.99)
				if hit:
					w += 1
			x += step
		y += step
	return float(w) / float(maxi(1, n))


# the view centre (ground px) whose view-sized window holds the most open water,
# kept inside the ground; TFA_GPU_X / TFA_GPU_Y override it
func _most_water(mask_img: Image, gsize: Vector2, view: Vector2) -> Vector2:
	if OS.get_environment("TFA_GPU_X") != "" and OS.get_environment("TFA_GPU_Y") != "":
		return Vector2(float(OS.get_environment("TFA_GPU_X")), float(OS.get_environment("TFA_GPU_Y")))
	var half := (view * 0.5).min(gsize * 0.5)
	var best := gsize * 0.5
	var best_s := -1.0
	var step := 256.0
	var y := half.y
	while y <= gsize.y - half.y + 0.5:
		var x := half.x
		while x <= gsize.x - half.x + 0.5:
			var sh := _open_share(mask_img, gsize, Rect2(Vector2(x, y) - view * 0.5, view), 32.0)
			if sh > best_s:
				best_s = sh
				best = Vector2(x, y)
			x += step
		y += step
	return best


func _camera_pos(mask_img: Image, _gsize: Vector2) -> Vector2:
	if OS.get_environment("TFA_CAM_X") != "" and OS.get_environment("TFA_CAM_Y") != "":
		return Vector2(float(OS.get_environment("TFA_CAM_X")), float(OS.get_environment("TFA_CAM_Y")))
	# The shore of the most open water: the 64-texel block holding the most
	# open-water texels (c >= 0.99; ties: nearest the mask's centre), then the
	# shore texel (0.3 < c < 0.7) nearest that block's open-water centroid. The
	# shore nearest the mask's centre alone (the rule before P3-L) can land on
	# a pool with no open water at all: tg_export's 25 wadeable ravine pools
	# hold 120 open-water texels in three blobs across a 1788 x 1172 mask, and
	# that view had 56 water px.
	var msz := Vector2(mask_img.get_size())
	var centre := msz * 0.5
	const BLOCK := 64
	var counts := {}
	var sums := {}
	for y in range(0, mask_img.get_height(), 4):
		for x in range(0, mask_img.get_width(), 4):
			if mask_img.get_pixel(x, y).r >= 0.99:
				var key := Vector2i(floori(float(x) / BLOCK), floori(float(y) / BLOCK))
				counts[key] = int(counts.get(key, 0)) + 1
				var acc: Vector2 = sums.get(key, Vector2.ZERO)
				sums[key] = acc + Vector2(x, y)
	var target := centre
	if not counts.is_empty():
		var best_key := Vector2i(-1, -1)
		var best_n := -1
		var best_d := INF
		for key_v in counts:
			var key: Vector2i = key_v
			var n: int = counts[key]
			var dk := (Vector2(key) * BLOCK).distance_squared_to(centre)
			if n > best_n or (n == best_n and dk < best_d):
				best_key = key
				best_n = n
				best_d = dk
		var s: Vector2 = sums[best_key]
		target = s / float(best_n)
	var best := target
	var bd := INF
	for y in range(0, mask_img.get_height(), 4):
		for x in range(0, mask_img.get_width(), 4):
			var c: float = mask_img.get_pixel(x, y).r
			if c > 0.3 and c < 0.7:
				var d := Vector2(x, y).distance_squared_to(target)
				if d < bd:
					bd = d
					best = Vector2(x, y)
	# the open water a zoom-1 view round best would hold (each 4-texel sample
	# stands for 16 texels of k x k world px): too little, and the default zoom
	# goes up to 4 so the view holds about 1500 water px (tg_export at zoom 1:
	# 272 px; its largest open-water blob is 90 texels)
	var k: float = _wrect.size.x / msz.x
	var half := Vector2(SIZE) * 0.5 / k
	var n_view := 0
	for y in range(maxi(0, floori(best.y - half.y)), mini(mask_img.get_height(), ceili(best.y + half.y)), 4):
		for x in range(maxi(0, floori(best.x - half.x)), mini(mask_img.get_width(), ceili(best.x + half.x)), 4):
			if mask_img.get_pixel(x, y).r >= 0.99:
				n_view += 1
	var est: float = float(n_view) * 16.0 * k * k
	if est > 0.0 and est < 1500.0:
		_auto_zoom = clampf(ceilf(sqrt(1500.0 / est)), 1.0, 4.0)
	return _wrect.position + (best + Vector2(0.5, 0.5)) / msz * _wrect.size


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
