extends Node2D
class_name CellFireFX

# Live fire rendering for structured maps: the EDITOR's FireFX recipe ported
# onto CellFire/CellGraph (the same way CellFluidFX ports FluidFX). Each
# burning cell cycles a deterministic set of "particles" through the soft
# radial fire_blob falloff (blend_add) — vertically stretched tongues
# respawning across the whole cell each cycle so adjacent cells merge into one
# continuous sheet of fire — plus a broad core sheet, ember under-glow, sparks,
# and drifting smoke wisps on a normal-blend layer beneath.
#
# GPU-INSTANCED: the particles are MultiMesh instances whose animation lives
# in shaders/fire_cells.gdshader (and fire_smoke_wisps.gdshader), replaying the
# original CPU math off CellFire.sim_time. The CPU only touches the instance
# buffers when the burning KEY SET changes (CellFire.burn_rev): a lit cell
# appends its block of instances, a burnt-out/doused cell swap-removes it. The
# old per-frame path rebuilt ~12 draw_polygon commands per burning cell in
# GDScript every frame — 10k+ canvas commands for a big fire, 6-11 fps.
#
# ALSO owns the fire light: one merged PointLight2D per connected burning
# CLUSTER (recomputed when burn_rev changes). The old per-cell fire.tscn lights
# (~34px each on a ~31px cell lattice) read as a field of little yellow
# circles — the "sparkler" look.

const FLAME_SHADER := preload("res://shaders/fire_cells.gdshader")
const SMOKE_SHADER := preload("res://shaders/fire_smoke_wisps.gdshader")
const FLAME_KINDS := 12      # halo, core, 2 bed, 6 tongues, 2 embers (per cell)
const SMOKE_KINDS := 4       # 2 puffs x (body disc, highlight disc)
const STRIDE := 16           # MultiMesh floats/instance: 8 xform + 4 color + 4 custom
const MIN_CAP := 64          # blocks (cells) allocated up front
const MAX_LIGHTS := 16
# Crackle loops ride the cluster lights, but only the biggest few: a burning
# town is dozens of clusters, and past a handful more loops are just louder
# mush (and a voice each).
const MAX_CRACKLES := 6
const CRACKLE_DB := -6.0

var sim: Node                # CellFire
var graph: CellGraph
var _t := 0.0                # light flicker clock
var _flames: MultiMeshInstance2D
var _flame_mm: MultiMesh
var _flame_mat: ShaderMaterial
var _flame_buf := PackedFloat32Array()
var _smoke: MultiMeshInstance2D
var _smoke_mm: MultiMesh
var _smoke_mat: ShaderMaterial
var _smoke_buf := PackedFloat32Array()
var _slot: Dictionary = {}                  # cid -> block index
var _block_cid := PackedInt32Array()        # block index -> cid
var _blocks := 0                            # live blocks (one per burning cell)
var _cap := 0                               # allocated blocks
var _slot_rev := -1                         # last CellFire.burn_rev synced
var _lights: Array = []      # pooled PointLight2Ds, one per burning cluster
var _light_rev := -1         # last CellFire.burn_rev clustered
var _light_timer := 0.0      # recluster cooldown: during a big fire's decay
                             # burn_rev bumps nearly every frame (jittered
                             # burnouts) and light positions barely move --
                             # cap the O(burning) flood-fill at ~3 Hz
var _light_tex: GradientTexture2D
var _crackles: Array[int] = []   # SfxManager loop handles, largest cluster first


func _ready() -> void:
	# smoke first so it draws under the flames (same order as before)
	_smoke_mat = ShaderMaterial.new()
	_smoke_mat.shader = SMOKE_SHADER
	_smoke_mm = _make_multimesh()
	_smoke = MultiMeshInstance2D.new()
	_smoke.multimesh = _smoke_mm
	_smoke.material = _smoke_mat
	add_child(_smoke)
	_flame_mat = ShaderMaterial.new()
	_flame_mat.shader = FLAME_SHADER
	_flame_mm = _make_multimesh()
	_flames = MultiMeshInstance2D.new()
	_flames.multimesh = _flame_mm
	_flames.material = _flame_mat
	add_child(_flames)
	# fire.tscn's radial light gradient, rebuilt in code (it was a subresource)
	var g := Gradient.new()
	g.colors = PackedColorArray([Color(1.0, 0.6, 0.1, 1.0), Color(0, 0, 0, 0)])
	_light_tex = GradientTexture2D.new()
	_light_tex.gradient = g
	_light_tex.width = 64
	_light_tex.height = 64
	_light_tex.fill = GradientTexture2D.FILL_RADIAL
	_light_tex.fill_from = Vector2(0.5, 0.5)
	_light_tex.fill_to = Vector2(1.0, 0.5)


func _exit_tree() -> void:
	_stop_crackles(0)


func _make_multimesh() -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	# unit quad: vertices at +-1, UVs 0..1 -- the shader scales it per blob
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	mm.mesh = quad
	return mm


func setup(p_sim: Node, p_graph: CellGraph) -> void:
	sim = p_sim
	graph = p_graph
	_slot.clear()
	_blocks = 0
	_slot_rev = -1


func _process(delta: float) -> void:
	_t += delta
	if sim == null or graph == null:
		return
	if "burn_rev" in sim and sim.burn_rev != _slot_rev:
		_sync_slots()
	# the sim clock drives every instance's animation; one uniform write per frame
	var st: float = float(sim.sim_time) if "sim_time" in sim else _t
	_flame_mat.set_shader_parameter("sim_t", st)
	_smoke_mat.set_shader_parameter("sim_t", st)
	if _blocks > 0:
		var wind: Vector2 = sim._wind() if sim.has_method("_wind") else Vector2.ZERO
		_smoke_mat.set_shader_parameter("wind", wind)
	_light_timer = maxf(_light_timer - delta, 0.0)
	if "burn_rev" in sim and sim.burn_rev != _light_rev \
			and (_light_timer <= 0.0 or sim.burning.is_empty()):
		_light_rev = sim.burn_rev
		_light_timer = 0.35
		_refresh_lights()
	_flicker_lights()


# --- instance blocks -----------------------------------------------------------

# Diff the burning key set against our blocks: O(burning) dictionary probes,
# then one buffer upload. Runs only when CellFire.burn_rev changes.
func _sync_slots() -> void:
	_slot_rev = sim.burn_rev
	var burning: Dictionary = sim.burning
	var gone: Array = []
	for cid in _slot:
		if not burning.has(cid):
			gone.append(cid)
	for cid in gone:
		_remove_block(cid)
	var sim_t: float = float(sim.sim_time) if "sim_time" in sim else _t
	for cid in burning:
		if not _slot.has(cid):
			_add_block(cid, burning[cid], sim_t)
	_upload()


func _ensure_cap(blocks: int) -> void:
	if blocks <= _cap:
		return
	var cap := maxi(_cap, MIN_CAP)
	while cap < blocks:
		cap *= 2
	_cap = cap
	_block_cid.resize(cap)
	_flame_buf.resize(cap * FLAME_KINDS * STRIDE)
	_smoke_buf.resize(cap * SMOKE_KINDS * STRIDE)
	# instance_count reallocates the GPU buffer; _upload rewrites all of it
	_flame_mm.instance_count = cap * FLAME_KINDS
	_smoke_mm.instance_count = cap * SMOKE_KINDS


func _add_block(cid: int, bd: Dictionary, sim_t: float) -> void:
	var b := _blocks
	_blocks += 1
	_ensure_cap(_blocks)
	_slot[cid] = b
	_block_cid[b] = cid
	var p: Vector2 = graph.centroid(cid)
	var cr: float = graph.radius(cid)
	var sd: float = clampf(float(bd["seed"]), 0.0, 0.999)
	var t0: float = float(bd["t0"])
	# derive the lit time from the remaining burn so cells poked straight into
	# CellFire.burning (tests) animate too; the shader recovers t = t0 - (sim_t - lit)
	var lit: float = sim_t - (t0 - float(bd["t"]))
	_write_block(_flame_buf, b, FLAME_KINDS, p, cr, sd, t0, lit)
	_write_block(_smoke_buf, b, SMOKE_KINDS, p, cr, sd, t0, lit)


func _write_block(buf: PackedFloat32Array, b: int, kinds: int, p: Vector2,
		cr: float, sd: float, t0: float, lit: float) -> void:
	for i in kinds:
		var o := (b * kinds + i) * STRIDE
		# transform_2d: identity basis, centroid origin (the shader offsets/scales)
		buf[o + 0] = 1.0
		buf[o + 1] = 0.0
		buf[o + 2] = 0.0
		buf[o + 3] = p.x
		buf[o + 4] = 0.0
		buf[o + 5] = 1.0
		buf[o + 6] = 0.0
		buf[o + 7] = p.y
		# color: white, so the canvas modulate still multiplies through
		buf[o + 8] = 1.0
		buf[o + 9] = 1.0
		buf[o + 10] = 1.0
		buf[o + 11] = 1.0
		# custom: radius, kind*2+seed, burn duration, lit time
		buf[o + 12] = cr
		buf[o + 13] = float(i) * 2.0 + sd
		buf[o + 14] = t0
		buf[o + 15] = lit


func _remove_block(cid: int) -> void:
	var b: int = _slot[cid]
	var last := _blocks - 1
	if b != last:
		# swap-remove: move the last block's instances into the hole
		var moved := _block_cid[last]
		_copy_block(_flame_buf, last, b, FLAME_KINDS)
		_copy_block(_smoke_buf, last, b, SMOKE_KINDS)
		_slot[moved] = b
		_block_cid[b] = moved
	_slot.erase(cid)
	_blocks = last


func _copy_block(buf: PackedFloat32Array, src: int, dst: int, kinds: int) -> void:
	var n := kinds * STRIDE
	var so := src * n
	var do := dst * n
	for i in n:
		buf[do + i] = buf[so + i]


func _upload() -> void:
	if _cap == 0:
		return
	_flame_mm.visible_instance_count = _blocks * FLAME_KINDS
	_smoke_mm.visible_instance_count = _blocks * SMOKE_KINDS
	if _blocks > 0:
		_flame_mm.buffer = _flame_buf
		_smoke_mm.buffer = _smoke_buf


# --- cluster lights -----------------------------------------------------------

# One PointLight2D per connected burning cluster: flood-fill over the graph's
# adjacency restricted to burning cells, then size the light to wrap the
# cluster. Runs only when the burning key set changes (CellFire.burn_rev).
func _refresh_lights() -> void:
	var clusters: Array = []
	if sim != null and graph != null and not sim.burning.is_empty():
		var burning: Dictionary = sim.burning
		var seen: Dictionary = {}
		for cid in burning:
			if seen.has(cid):
				continue
			seen[cid] = true
			var stack: Array = [cid]
			var members: Array = []
			while not stack.is_empty():
				var c: int = stack.pop_back()
				members.append(c)
				for nb in graph.neighbors(c):
					if burning.has(nb) and not seen.has(nb):
						seen[nb] = true
						stack.append(nb)
			var center := Vector2.ZERO
			for mc in members:
				center += graph.centroid(mc)
			center /= float(members.size())
			var ext := 0.0
			for mc in members:
				ext = maxf(ext, center.distance_to(graph.centroid(mc)) + graph.radius(mc))
			clusters.append({"pos": center, "ext": ext})
	# largest first: the light cap and the (smaller) crackle cap both keep
	# the biggest clusters
	if clusters.size() > MAX_CRACKLES:
		clusters.sort_custom(func(a, b): return float(a["ext"]) > float(b["ext"]))
	if clusters.size() > MAX_LIGHTS:
		clusters.resize(MAX_LIGHTS)
	_refresh_crackles(clusters)
	while _lights.size() < clusters.size():
		var l := PointLight2D.new()
		l.texture = _light_tex
		l.color = Color(1.0, 0.6, 0.2)
		add_child(l)
		_lights.append(l)
	for i in _lights.size():
		var l: PointLight2D = _lights[i]
		if i >= clusters.size():
			l.visible = false
			continue
		var cl: Dictionary = clusters[i]
		l.visible = true
		l.position = cl["pos"]
		# pool wraps the whole cluster in one glow (min ~120px so even a lone
		# cell gets a real fire pool, not a coin of light)
		var dia := maxf(120.0, float(cl["ext"]) * 2.6)
		l.texture_scale = dia / float(_light_tex.width)
		l.energy = 0.9


# One crackle loop per cluster for the MAX_CRACKLES largest (clusters arrive
# sorted largest-first whenever there are more than that). Slots are reused:
# a loop slides to its cluster's new centre rather than restarting.
func _refresh_crackles(clusters: Array) -> void:
	var want := mini(clusters.size(), MAX_CRACKLES)
	_stop_crackles(want)
	for i in want:
		var pos: Vector2 = to_global(clusters[i]["pos"])
		if i < _crackles.size() and SfxManager.is_loop_active(_crackles[i]):
			SfxManager.set_loop_position(_crackles[i], pos)
			continue
		var h: int = SfxManager.start_loop("fire_crackle_loop", pos, CRACKLE_DB, "Ambience")
		if i < _crackles.size():
			_crackles[i] = h
		else:
			_crackles.append(h)


# Stops crackle slots from `keep` on (0 = all).
func _stop_crackles(keep: int) -> void:
	while _crackles.size() > keep:
		SfxManager.stop_loop(_crackles.pop_back(), 0.6)


func _flicker_lights() -> void:
	for i in _lights.size():
		var l: PointLight2D = _lights[i]
		if l.visible:
			var fi := float(i)
			l.energy = 0.9 * (1.0 + sin(_t * 18.0 + fi * 9.0) * 0.08 \
				+ sin(_t * 7.3 + 1.7 + fi * 5.0) * 0.05)
