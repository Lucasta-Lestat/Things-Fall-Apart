extends Node2D
## End-to-end integration test for the REAL fluid pipeline: instantiates the
## actual FluidManager, registers fluids (which loads data/fluids.json, applies
## the data-driven style, spawns Fluid.tscn tiles with the upgraded shader,
## computes edge masks, and runs the flow sim), and drives reactive ripples via
## FluidManager.add_ripple. Verifies Tasks 4/5/6 wired together, not just the
## shader. Run:  godot --path <proj> res://vfx/FluidIntegrationTest.tscn -- --shot

const TILE := 64
var _fm  # FluidManager
var _ripple_t := 0.0
var _ripple_i := 0
var _pts := [Vector2(4.5, 3.5), Vector2(5.5, 4.0), Vector2(3.5, 4.5), Vector2(6.0, 3.0)]

func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.10, 0.11, 0.13))
	GridManager.initialize(2048, 2048) # wall-free grid so the sim flows
	_build_floor()
	var bb := BackBufferCopy.new()
	bb.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	bb.z_index = -1
	add_child(bb)
	_build_label()

	_fm = preload("res://FluidManager.gd").new()
	_fm.name = "FluidManager"
	add_child(_fm) # _ready loads fluids.json

	await get_tree().process_frame
	# Water pond
	for y in range(2, 7):
		for x in range(2, 8):
			_fm.register_fluid(Vector2i(x, y), "water", 0.5)
	# One tile of each other fluid type (exercises the data-driven style path)
	_fm.register_fluid(Vector2i(10, 3), "poison", 0.5)
	_fm.register_fluid(Vector2i(12, 3), "acid", 0.5)
	_fm.register_fluid(Vector2i(10, 6), "blood", 0.5)
	_fm.register_fluid(Vector2i(12, 6), "oil", 0.5)

	_setup_camera(Vector2(7.0 * TILE, 4.5 * TILE), 1.0)

	if capture_requested():
		_run_capture()

func capture_requested() -> bool:
	return OS.get_cmdline_user_args().has("--shot")

func _process(delta: float) -> void:
	if _fm == null:
		return
	_fm.update_fluid_tick(delta) # normally called by Game._process
	# Periodic ripples through the real FluidManager API.
	_ripple_t += delta
	if _ripple_t >= 0.5:
		_ripple_t = 0.0
		var p: Vector2 = _pts[_ripple_i] * TILE
		_fm.add_ripple(p, 0.9)
		_ripple_i = (_ripple_i + 1) % _pts.size()

func _build_floor() -> void:
	var n := 512
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in range(n):
		for x in range(n):
			var c := Color(0.32, 0.27, 0.22) if ((int(x / 32) ^ int(y / 32)) & 1) == 0 else Color(0.20, 0.17, 0.14)
			img.set_pixel(x, y, c)
	var spr := Sprite2D.new()
	spr.texture = ImageTexture.create_from_image(img)
	spr.centered = false
	spr.z_index = -4
	spr.scale = Vector2(4, 4)
	add_child(spr)

func _build_label() -> void:
	var ui := CanvasLayer.new(); add_child(ui)
	var lbl := Label.new()
	lbl.position = Vector2(16, 12)
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.text = "FluidManager integration — real data path + ripples (water pond, poison/acid/blood/oil)"
	ui.add_child(lbl)

func _setup_camera(center: Vector2, zoom: float) -> void:
	var cam := Camera2D.new()
	cam.position = center
	cam.zoom = Vector2(zoom, zoom)
	add_child(cam)
	cam.make_current()

func _run_capture() -> void:
	await get_tree().create_timer(1.4).timeout
	_save("res://_preview_integration_1.png")
	await get_tree().create_timer(1.0).timeout
	_save("res://_preview_integration_2.png")
	get_tree().quit()

func _save(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("SAVED ", path)
