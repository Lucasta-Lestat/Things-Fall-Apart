extends Node2D
## Standalone water/fluid shader preview — no autoload / FluidManager deps.
## Builds a floor, a still pond, a flowing river, partial puddles, and one tile
## per fluid type, drives some reactive ripples, and saves screenshots so the
## look can be reviewed. Run:  godot --path <proj> res://vfx/WaterShowcase.tscn
## Set capture=true (default) to auto-screenshot and quit.

const TILE := 64
const WATER_SHADER := "res://vfx/shaders/water_flow.gdshader"
const OIL_SHADER := "res://vfx/shaders/oil_sheen.gdshader"

# Opened from the editor it just animates interactively. Pass `-- --shot` on the
# command line to auto-capture screenshots and quit.
@export var capture := false

var _white: Texture2D
var _water_mats: Array = []          # materials that react to ripples
var _ripples: Array = []             # each: {pos: Vector2 (grid space), age: float, str: float}
var _spawn_pts: Array = []           # grid-space points a "wader" visits
var _spawn_i := 0
var _spawn_t := 0.0

func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.10, 0.11, 0.13))
	_white = _make_white()
	_build_floor()
	# Single shared back-buffer snapshot of the floor (mirrors game.tscn) so water
	# refraction reads the floor once — no per-tile screen feedback.
	var bb := BackBufferCopy.new()
	bb.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	bb.z_index = -1
	add_child(bb)
	_build_labels()

	# Still pond (water) — top-left
	_pond(Vector2i(2, 2), 6, 5, _cfg_water(), Vector2.ZERO)
	# Flowing river (water with eastward flow) — middle band
	_pond(Vector2i(2, 9), 9, 2, _cfg_water(), Vector2(1.0, 0.05))
	# Partial puddles (fill_ratio < 1)
	_single(Vector2i(13, 2), _cfg_water(), 0.45, Vector2(1, 0))
	_single(Vector2i(15, 2), _cfg_water(), 0.7, Vector2(0, 1))

	# One tile per fluid type, labeled row at the bottom
	var row := 13
	_single(Vector2i(2, row), _cfg_water(), 1.0, Vector2.ZERO)
	_single(Vector2i(4, row), _cfg_poison(), 1.0, Vector2.ZERO)
	_single(Vector2i(6, row), _cfg_acid(), 1.0, Vector2.ZERO)
	_single(Vector2i(8, row), _cfg_blood(), 1.0, Vector2.ZERO)
	_single_oil(Vector2i(10, row), 1.0)

	# A wader path across the pond to exercise ripples.
	_spawn_pts = [
		Vector2(3.5, 3.5), Vector2(4.5, 4.0), Vector2(5.5, 3.2),
		Vector2(6.0, 4.5), Vector2(4.0, 5.0), Vector2(3.0, 3.0),
	]

	_setup_camera(Vector2(5.5 * TILE, 6.0 * TILE), 1.25)

	if capture or OS.get_cmdline_user_args().has("--shot"):
		_run_capture()

# ---------------------------------------------------------------- ripples
func _process(delta: float) -> void:
	_spawn_t += delta
	if _spawn_t >= 0.55 and _spawn_pts.size() > 0:
		_spawn_t = 0.0
		_ripples.append({"pos": _spawn_pts[_spawn_i], "age": 0.0, "str": 0.9})
		_spawn_i = (_spawn_i + 1) % _spawn_pts.size()
	var alive: Array = []
	for r in _ripples:
		r.age += delta
		if r.age <= 1.4:
			alive.append(r)
	_ripples = alive
	_broadcast_ripples()

func _broadcast_ripples() -> void:
	var packed: Array = []
	for r in _ripples:
		packed.append(Vector4(r.pos.x, r.pos.y, r.age, r.str))
		if packed.size() >= 6:
			break
	for m in _water_mats:
		m.set_shader_parameter("u_ripples", packed)
		m.set_shader_parameter("u_ripple_count", packed.size())

# ---------------------------------------------------------------- builders
func _make_white() -> Texture2D:
	var img := Image.create(TILE, TILE, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	return ImageTexture.create_from_image(img)

func _build_floor() -> void:
	# High-contrast checker + diagonal lines so refraction wobble is visible.
	var n := 512
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in range(n):
		for x in range(n):
			var cx := int(x / 32) % 2
			var cy := int(y / 32) % 2
			var base := Color(0.32, 0.27, 0.22) if (cx ^ cy) == 0 else Color(0.20, 0.17, 0.14)
			if (x + y) % 64 < 3:
				base = base.lightened(0.25)
			img.set_pixel(x, y, base)
	var spr := Sprite2D.new()
	spr.texture = ImageTexture.create_from_image(img)
	spr.centered = false
	spr.z_index = -4
	spr.scale = Vector2(4, 4) # cover ~2048 px
	add_child(spr)

func _build_labels() -> void:
	var ui := CanvasLayer.new()
	add_child(ui)
	var lbl := Label.new()
	lbl.position = Vector2(16, 12)
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.text = "Water shader preview — pond / river / puddles | row: water  poison  acid  blood  oil"
	ui.add_child(lbl)

func _pond(origin: Vector2i, w: int, h: int, cfg: Dictionary, flow: Vector2) -> void:
	for iy in range(h):
		for ix in range(w):
			var gp := Vector2i(origin.x + ix, origin.y + iy)
			var mask := Vector4(
				1.0 if ix == w - 1 else 0.0,
				1.0 if ix == 0 else 0.0,
				1.0 if iy == h - 1 else 0.0,
				1.0 if iy == 0 else 0.0)
			_tile(gp, cfg, 1.0, flow, mask)

func _single(gp: Vector2i, cfg: Dictionary, fill: float, flow: Vector2) -> void:
	# Isolated tile: all four edges exposed.
	_tile(gp, cfg, fill, flow, Vector4(1, 1, 1, 1))

func _single_oil(gp: Vector2i, fill: float) -> void:
	var spr := _sprite_at(gp)
	var mat := ShaderMaterial.new()
	mat.shader = load(OIL_SHADER)
	mat.set_shader_parameter("tile_position", Vector2(gp.x, gp.y))
	mat.set_shader_parameter("edge_mask", Vector4(1, 1, 1, 1))
	mat.set_shader_parameter("fill_ratio", fill)
	spr.material = mat
	_water_mats.append(mat)

func _tile(gp: Vector2i, cfg: Dictionary, fill: float, flow: Vector2, edge_mask: Vector4) -> void:
	var spr := _sprite_at(gp)
	var mat := ShaderMaterial.new()
	mat.shader = load(WATER_SHADER)
	mat.set_shader_parameter("tile_position", Vector2(gp.x, gp.y))
	mat.set_shader_parameter("edge_mask", edge_mask)
	mat.set_shader_parameter("fill_ratio", fill)
	mat.set_shader_parameter("flow_direction", flow)
	mat.set_shader_parameter("flow_speed", 0.6 if flow.length() > 0.01 else 0.0)
	for k in cfg:
		mat.set_shader_parameter(k, cfg[k])
	spr.material = mat
	_water_mats.append(mat)

func _sprite_at(gp: Vector2i) -> Sprite2D:
	var spr := Sprite2D.new()
	spr.texture = _white
	spr.centered = false
	spr.position = Vector2(gp.x * TILE, gp.y * TILE)
	spr.z_index = 0
	add_child(spr)
	return spr

func _setup_camera(center: Vector2, zoom: float) -> void:
	var cam := Camera2D.new()
	cam.position = center
	cam.zoom = Vector2(zoom, zoom)
	add_child(cam)
	cam.make_current()

# ---------------------------------------------------------------- fluid configs
# These mirror the values that data/fluids.json will hold (Task 5).
func _cfg_water() -> Dictionary:
	return {
		"water_color": Color(0.10, 0.35, 0.62, 0.80),
		"wave_color": Color(0.40, 0.78, 0.96, 0.5),
		"foam_color": Color(0.92, 0.97, 1.0, 1.0),
		"caustic_intensity": 0.40, "sparkle_intensity": 0.9,
		"specular_intensity": 0.75, "emissive": 0.0,
		"refraction_strength": 0.013, "viscosity": 1.0,
	}

func _cfg_poison() -> Dictionary:
	return {
		"water_color": Color(0.16, 0.45, 0.10, 0.78),
		"wave_color": Color(0.55, 0.95, 0.35, 0.5),
		"foam_color": Color(0.75, 0.95, 0.55, 1.0),
		"caustic_intensity": 0.25, "sparkle_intensity": 0.4,
		"specular_intensity": 0.5, "emissive": 0.22,
		"refraction_strength": 0.010, "viscosity": 1.3,
	}

func _cfg_acid() -> Dictionary:
	return {
		"water_color": Color(0.32, 0.62, 0.08, 0.80),
		"wave_color": Color(0.75, 1.0, 0.30, 0.55),
		"foam_color": Color(0.85, 1.0, 0.55, 1.0),
		"caustic_intensity": 0.3, "sparkle_intensity": 0.6,
		"specular_intensity": 0.6, "emissive": 0.30,
		"refraction_strength": 0.011, "viscosity": 1.1,
	}

func _cfg_blood() -> Dictionary:
	return {
		"water_color": Color(0.34, 0.03, 0.05, 0.92),
		"wave_color": Color(0.6, 0.10, 0.10, 0.6),
		"foam_color": Color(0.5, 0.18, 0.18, 1.0),
		"caustic_intensity": 0.0, "sparkle_intensity": 0.15,
		"specular_intensity": 0.45, "emissive": 0.0,
		"refraction_strength": 0.004, "viscosity": 2.4,
	}

# ---------------------------------------------------------------- capture
func _run_capture() -> void:
	await get_tree().create_timer(1.6).timeout
	_save("res://_preview_water_1.png")
	await get_tree().create_timer(1.1).timeout
	_save("res://_preview_water_2.png")
	await get_tree().create_timer(1.1).timeout
	_save("res://_preview_water_3.png")
	get_tree().quit()

func _save(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("SAVED ", path)
