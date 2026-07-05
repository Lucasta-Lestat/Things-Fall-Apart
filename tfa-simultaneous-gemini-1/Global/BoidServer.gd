# BoidServer.gd - Autoload singleton.
#
# Owns a single local RenderingDevice + compute pipeline and steps every
# registered BoidField each physics frame in one dispatch/sync cycle. Fields
# register themselves on _ready and ask the server to allocate their GPU
# resources, so all swarms share one device and one pipeline.
#
# Sim runs on the GPU; results are read back once per frame and pushed into each
# field's MultiMesh. Readback of a few thousand floats is sub-millisecond and
# keeps the renderer-side code trivial. If you ever need zero-readback scale,
# the agent buffer could instead be written straight into the multimesh buffer
# via RenderingServer.multimesh_get_buffer_rd_rid() on the main device.
extends Node

const FLOATS_PER_AGENT := 8           # 2 vec4: (pos.xy,vel.xy) + (phase,scale,color,seed)
const PUSH_FLOATS := 24               # must match Params in boids.glsl (96 bytes)
const LOCAL_SIZE := 64                # must match local_size_x in boids.glsl
const SHADER_PATH := "res://vfx/shaders/boids.glsl"

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _available := false
var _fields: Array = []               # Array[BoidField]
var _time := 0.0

func _ready() -> void:
	# Boids should keep simulating even while the tactical layer is paused, to
	# match the existing TIME-driven VFX. Flip to PROCESS_MODE_PAUSABLE if you'd
	# rather swarms freeze with the game.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_init_compute()

func is_available() -> bool:
	return _available

func _init_compute() -> void:
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		push_warning("BoidServer: no compute support on this renderer; swarms disabled.")
		return
	var shader_file := load(SHADER_PATH) as RDShaderFile
	if shader_file == null:
		push_error("BoidServer: failed to load %s" % SHADER_PATH)
		return
	var spirv := shader_file.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("BoidServer: boids.glsl compile error: %s" % spirv.compile_error_compute)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	_available = _shader.is_valid() and _pipeline.is_valid()
	if not _available:
		push_error("BoidServer: failed to build compute pipeline.")

# --- Field registration ----------------------------------------------------

func register_field(field) -> void:
	if not _fields.has(field):
		_fields.append(field)

func unregister_field(field) -> void:
	_fields.erase(field)

# --- GPU resource helpers (called by BoidField) ----------------------------

# Creates the agent storage buffer from seed data and a uniform set bound to it.
# Returns {"buffer": RID, "uniform_set": RID} or an empty dict on failure.
func create_field_resources(seed_floats: PackedFloat32Array) -> Dictionary:
	if not _available:
		return {}
	var bytes := seed_floats.to_byte_array()
	var buffer := _rd.storage_buffer_create(bytes.size(), bytes)
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 0
	u.add_id(buffer)
	var uset := _rd.uniform_set_create([u], _shader, 0)
	return {"buffer": buffer, "uniform_set": uset}

# Re-uploads agent data (used when a field respawns / resizes).
func update_field_buffer(buffer: RID, floats: PackedFloat32Array) -> void:
	if not _available or not buffer.is_valid():
		return
	var bytes := floats.to_byte_array()
	_rd.buffer_update(buffer, 0, bytes.size(), bytes)

func free_field_resources(buffer: RID, uniform_set: RID) -> void:
	if not _available:
		return
	if uniform_set.is_valid():
		_rd.free_rid(uniform_set)
	if buffer.is_valid():
		_rd.free_rid(buffer)

# --- Per-frame step --------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not _available or _fields.is_empty():
		return
	_time += delta

	# Collect fields that actually want to step this frame.
	var stepping: Array = []
	for f in _fields:
		if f.is_active():
			f._pre_step(delta, _time)
			stepping.append(f)
	if stepping.is_empty():
		return

	# One compute list for every swarm: bind pipeline once, then per-field
	# uniform set + push constant + dispatch.
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	for f in stepping:
		var groups := int(ceil(float(f.count) / float(LOCAL_SIZE)))
		_rd.compute_list_bind_uniform_set(cl, f.uniform_set, 0)
		_rd.compute_list_set_push_constant(cl, f.push_bytes, f.push_bytes.size())
		_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	# Read each swarm back and push it into its MultiMesh.
	for f in stepping:
		var data := _rd.buffer_get_data(f.agent_buffer)
		f._render_from_bytes(data)

func _exit_tree() -> void:
	if _rd == null:
		return
	if _pipeline.is_valid():
		_rd.free_rid(_pipeline)
	if _shader.is_valid():
		_rd.free_rid(_shader)
	_rd.free()
	_rd = null
