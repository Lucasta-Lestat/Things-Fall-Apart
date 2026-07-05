# BoidField.gd - one GPU-simulated swarm rendered through a MultiMeshInstance2D.
#
# A field owns its agent buffer (on BoidServer's device) and a MultiMesh. The
# server steps the compute shader each physics frame and hands the results back
# here to fill the multimesh buffer in bulk. The same node renders either a
# creature swarm (sprite mode: textured + rotated to heading) or a spell effect
# (mote mode: soft glow, additive or alpha), chosen by preset.
#
# Coordinates are world/scene space: the node stays at the origin and agents
# carry absolute positions, so moving `anchor`/`target` makes the swarm steer
# (no teleport). Typical use:
#
#   var swarm := BoidField.spawn(get_tree().current_scene, "rat_swarm", pos)
#   swarm.set_target(enemy.global_position)   # chase
#   swarm.scatter(blast_pos)                  # flee a point
#   swarm.despawn()                           # fade out + free
class_name BoidField
extends Node2D

const FLOATS_PER_AGENT := 8
const MM_STRIDE := 16          # 8 transform2d + 4 color + 4 custom
const TAU_ := 6.28318530718

# --- configuration (populated from a preset before _ready) -----------------
var config: Dictionary = {}
var count: int = 0
var anchor: Vector2 = Vector2.ZERO     # home / bounds centre (world space)
var target: Vector2 = Vector2.ZERO
var has_target: bool = false

# --- GPU + render state ----------------------------------------------------
var agent_buffer: RID
var uniform_set: RID
var push_bytes: PackedByteArray

var _mmi: MultiMeshInstance2D
var _mm: MultiMesh
var _agent_colors: PackedColorArray = PackedColorArray()
var _mm_buffer: PackedFloat32Array = PackedFloat32Array()

# --- cached config values --------------------------------------------------
var _render_mode: String
var _heading_offset: float
var _flee: float = 0.0
var _bounds_half: Vector2
var _color_variation: float
var _setup_ok: bool = false
var _frozen: bool = false
var _fade: float = 1.0
var _scatter_until: float = 0.0
var _server_time: float = 0.0

static var _glow_tex: Texture2D

# Factory: build, configure, add to `parent`, return. Config/anchor are set
# before add_child so _ready() can allocate GPU resources immediately.
static func spawn(parent: Node, preset_name: String, world_pos: Vector2, overrides: Dictionary = {}) -> BoidField:
	var field := BoidField.new()
	field.config = BoidPresets.get_config(preset_name, overrides)
	field.anchor = world_pos
	field.target = world_pos
	parent.add_child(field)
	return field

func _ready() -> void:
	if config.is_empty():
		config = BoidPresets.get_config("rat_swarm")
	position = Vector2.ZERO   # sim is in world space; keep node at origin
	_setup()

func _setup() -> void:
	if not is_instance_valid(BoidServer) or not BoidServer.is_available():
		push_warning("BoidField: BoidServer unavailable; swarm '%s' inert." % config.get("render_mode", "?"))
		return

	count = int(config["count"])
	_render_mode = String(config["render_mode"])
	_heading_offset = float(config["heading_offset"])
	_bounds_half = config["bounds_half"]
	_color_variation = float(config["color_variation"])

	_build_render_node()
	_build_agent_colors()

	var seed_data := _build_seed()
	var res: Dictionary = BoidServer.create_field_resources(seed_data)
	if res.is_empty():
		push_warning("BoidField: failed to allocate GPU resources.")
		return
	agent_buffer = res["buffer"]
	uniform_set = res["uniform_set"]

	_mm_buffer.resize(count * MM_STRIDE)
	_setup_ok = true
	BoidServer.register_field(self)

# --- rendering setup -------------------------------------------------------

func _build_render_node() -> void:
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_2D
	_mm.use_colors = true
	_mm.use_custom_data = true

	var mesh := QuadMesh.new()
	var tex: Texture2D = null
	var material: Material = null

	if _render_mode == "sprite":
		tex = load(String(config["texture"])) as Texture2D
		var long_side := float(config["sprite_size"])
		var aspect := 1.0
		if tex != null and tex.get_width() > 0:
			aspect = float(tex.get_height()) / float(tex.get_width())
		mesh.size = Vector2(long_side, long_side * aspect)
		if bool(config["gait"]):
			var sm := ShaderMaterial.new()
			sm.shader = load("res://vfx/shaders/boid_sprite.gdshader")
			material = sm
	else:
		tex = _get_glow_texture()
		var d := float(config["mote_size"])
		mesh.size = Vector2(d, d)
		if bool(config["additive"]):
			var cm := CanvasItemMaterial.new()
			cm.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
			material = cm

	_mm.mesh = mesh
	_mm.instance_count = count

	_mmi = MultiMeshInstance2D.new()
	_mmi.multimesh = _mm
	_mmi.texture = tex
	_mmi.material = material
	_mmi.z_index = int(config["z_index"])
	add_child(_mmi)

func _build_agent_colors() -> void:
	_agent_colors.resize(count)
	var base: Color = config["color"]
	var h := base.h
	var s := base.s
	var v := base.v
	for i in count:
		if _color_variation > 0.0:
			var hh: float = fposmod(h + (randf() - 0.5) * 0.08 * _color_variation, 1.0)
			var ss: float = clampf(s + (randf() - 0.5) * 0.30 * _color_variation, 0.0, 1.0)
			var vv: float = clampf(v + (randf() - 0.5) * 0.55 * _color_variation, 0.05, 1.0)
			_agent_colors[i] = Color.from_hsv(hh, ss, vv, base.a)
		else:
			_agent_colors[i] = base

func _build_seed() -> PackedFloat32Array:
	var arr := PackedFloat32Array()
	arr.resize(count * FLOATS_PER_AGENT)
	var spawn_radius := float(config["spawn_radius"])
	var max_speed := float(config["max_speed"])
	var min_speed := float(config["min_speed"])
	for i in count:
		var a := randf() * TAU_
		var r := sqrt(randf()) * spawn_radius
		var p := anchor + Vector2(cos(a), sin(a)) * r
		var vdir := randf() * TAU_
		var spd := min_speed + randf() * maxf(max_speed - min_speed, 1.0) * 0.3
		var v := Vector2(cos(vdir), sin(vdir)) * spd
		var b := i * FLOATS_PER_AGENT
		arr[b + 0] = p.x
		arr[b + 1] = p.y
		arr[b + 2] = v.x
		arr[b + 3] = v.y
		arr[b + 4] = randf() * TAU_                          # gait phase
		arr[b + 5] = (randf() * 2.0 - 1.0) * _color_variation  # scale variation
		arr[b + 6] = float(i)                                # color idx (reserved)
		arr[b + 7] = randf() * 1000.0                        # per-agent seed
	return arr

# --- server callbacks ------------------------------------------------------

func is_active() -> bool:
	return _setup_ok and not _frozen and count > 0 and visible

func _pre_step(delta: float, server_time: float) -> void:
	_server_time = server_time
	delta = minf(delta, 0.05)   # guard against lag-spike blow-ups

	# Scatter is a timed flee from the last scatter point.
	var tw := 0.0
	var flee := 0.0
	if server_time < _scatter_until:
		tw = float(config["target_weight"]) * 1.6
		flee = 1.0
	elif has_target:
		tw = float(config["target_weight"])

	var bmin := anchor - _bounds_half
	var bmax := anchor + _bounds_half

	var p := PackedFloat32Array([
		float(count), delta, server_time, float(config["max_speed"]),
		float(config["min_speed"]), float(config["max_force"]),
		float(config["perception"]), float(config["sep_radius"]),
		float(config["separation"]), float(config["alignment"]),
		float(config["cohesion"]), float(config["wander"]),
		target.x, target.y, tw, flee,
		bmin.x, bmin.y, bmax.x, bmax.y,
		float(config["bounds_weight"]), float(config["home_weight"]),
		float(config["damping"]), float(config["swirl"]),
	])
	push_bytes = p.to_byte_array()

func _render_from_bytes(bytes: PackedByteArray) -> void:
	var f := bytes.to_float32_array()
	var buf := _mm_buffer
	var scale_mul: float = lerpf(0.3, 1.0, _fade) if _fade < 1.0 else 1.0
	for i in count:
		var b := i * FLOATS_PER_AGENT
		var px := f[b + 0]
		var py := f[b + 1]
		var vx := f[b + 2]
		var vy := f[b + 3]
		var phase := f[b + 4]
		var scale_var := f[b + 5]

		var ang := atan2(vy, vx) + _heading_offset
		var cs := cos(ang)
		var sn := sin(ang)
		var sc: float = (1.0 + scale_var) * scale_mul

		var o := i * MM_STRIDE
		# transform_2d (8 floats)
		buf[o + 0] = cs * sc
		buf[o + 1] = -sn * sc
		buf[o + 2] = 0.0
		buf[o + 3] = px
		buf[o + 4] = sn * sc
		buf[o + 5] = cs * sc
		buf[o + 6] = 0.0
		buf[o + 7] = py
		# color (4 floats)
		var col := _agent_colors[i]
		buf[o + 8] = col.r
		buf[o + 9] = col.g
		buf[o + 10] = col.b
		buf[o + 11] = col.a * _fade
		# custom data (4 floats) - gait phase for the sprite shader
		buf[o + 12] = phase
		buf[o + 13] = scale_var
		buf[o + 14] = 0.0
		buf[o + 15] = 0.0
	_mm.buffer = buf

# --- public API ------------------------------------------------------------

func set_target(world_pos: Vector2) -> void:
	target = world_pos
	has_target = true

func clear_target() -> void:
	has_target = false

# Make the swarm flee `world_pos` for `duration` seconds, then resume.
func scatter(world_pos: Vector2, duration: float = 1.2) -> void:
	target = world_pos
	_scatter_until = _server_time + duration

# Pull the swarm tightly back to its anchor.
func gather() -> void:
	target = anchor
	has_target = true
	_scatter_until = 0.0

# Move the home/bounds centre; the swarm steers to follow.
func set_anchor(world_pos: Vector2) -> void:
	anchor = world_pos

func set_frozen(frozen: bool) -> void:
	_frozen = frozen

func set_color(color: Color) -> void:
	config["color"] = color
	_build_agent_colors()

func despawn(fade_time: float = 0.6) -> void:
	if fade_time <= 0.0:
		queue_free()
		return
	var t := create_tween()
	t.tween_method(func(v: float): _fade = v, 1.0, 0.0, fade_time)
	t.tween_callback(queue_free)

func _exit_tree() -> void:
	if is_instance_valid(BoidServer):
		BoidServer.unregister_field(self)
		if _setup_ok:
			BoidServer.free_field_resources(agent_buffer, uniform_set)
	_setup_ok = false

# --- shared assets ---------------------------------------------------------

static func _get_glow_texture() -> Texture2D:
	if _glow_tex != null:
		return _glow_tex
	var size := 64
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := Vector2(size, size) * 0.5
	var radius := float(size) * 0.5
	for y in size:
		for x in size:
			var d := (Vector2(x + 0.5, y + 0.5) - c).length() / radius
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a   # soft falloff
			img.set_pixel(x, y, Color(1, 1, 1, a))
	_glow_tex = ImageTexture.create_from_image(img)
	return _glow_tex
