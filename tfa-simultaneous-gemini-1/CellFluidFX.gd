# res://CellFluidFX.gd
# The editor's organic water renderer ported to TFA (from Terrain Generation/
# scripts/FluidFX.gd). Each wet cell contributes one soft radial blob (the
# sqrt-compensated fluid_field.gdshader, blend_add) drawn into an always-on
# offscreen SubViewport; overlapping blobs fuse into one smooth depth+colour
# field, so ponds read as continuous bodies with organic shorelines instead of
# per-tile sprites. A second viewport accumulates the flow field. The STRUCTURED
# map's ground sprite gets water_surface.gdshader, which samples both fields and
# composites the water surface (waves, foam, flow, per-type colour) over the
# ground. The CPU side lerps each cell's displayed depth toward the sim's true
# depth every frame so fills/drains glide instead of stepping at the 4 Hz sim.
# Replaces FluidManager's tile Fluid.tscn visuals on structured maps.
class_name CellFluidFX
extends Node2D

const BLOB_SHADER := preload("res://shaders/fluid_field.gdshader")
const WATER_SHADER := preload("res://shaders/water_surface.gdshader")
const FULL := 0.35             # depth that reads visually "deep" (editor cfg.fluid_full)

var sim: CellFluid
var graph: CellGraph
var _colors: Array = []         # ftype byte -> Color (from fluids.json)
var _ground: Node2D             # the map ground Sprite2D (gets the water material)
var _vp: SubViewport            # depth+colour field
var _drawer: Node2D
var _vpf: SubViewport           # flow field (RG = dir 0.5-centred, B = speed)
var _fdrawer: Node2D
var _disp: Dictionary = {}      # cid -> displayed depth (chases sim.amount)
var _dcol: Dictionary = {}      # cid -> Color (kept while a dry cell fades out)
var _dtype: Dictionary = {}     # cid -> last seen ftype
var _dflow: Dictionary = {}     # cid -> displayed flow vector (dir*speed, EMA-chased)
var _idle := true
var _fluid_on := false


func _ready() -> void:
	_vp = SubViewport.new()
	_vp.transparent_bg = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	_vp.disable_3d = true
	add_child(_vp)
	_drawer = Node2D.new()
	var sm := ShaderMaterial.new()
	sm.shader = BLOB_SHADER
	_drawer.material = sm
	_vp.add_child(_drawer)
	_drawer.draw.connect(_draw_field)
	_vpf = SubViewport.new()
	_vpf.transparent_bg = true
	_vpf.render_target_update_mode = SubViewport.UPDATE_ONCE
	_vpf.disable_3d = true
	add_child(_vpf)
	_fdrawer = Node2D.new()
	var smf := ShaderMaterial.new()
	smf.shader = BLOB_SHADER
	_fdrawer.material = smf
	_vpf.add_child(_fdrawer)
	_fdrawer.draw.connect(_draw_flow)


# ground_sprite: the structured map's Sprite2D (uncentered at origin). We size
# the field viewports to its texture and bind water_surface.gdshader to it.
func setup(p_sim: CellFluid, p_graph: CellGraph, ground_sprite: Node2D, db: Dictionary, order: Array) -> void:
	sim = p_sim
	graph = p_graph
	_ground = ground_sprite
	_disp.clear(); _dcol.clear(); _dtype.clear(); _dflow.clear()
	# per-ftype colour table from fluids.json (index 0 = dry -> unused default)
	_colors = [Color(0.1, 0.35, 0.62, 1.0)]
	for t in order:
		var arr = db.get(t, {}).get("color", [0.0, 0.4, 0.8, 1.0])
		_colors.append(Color(arr[0], arr[1], arr[2], 1.0))
	var tex_size := Vector2(1024, 1024)
	if ground_sprite != null and ground_sprite.texture != null:
		tex_size = ground_sprite.texture.get_size()
	# field resolution ~ half the map (editor world_per_texel 2.0); world (0,0)..
	# (tex_size) maps 1:1 to UV so the ground shader samples it at its own UV
	var res := Vector2i(maxi(8, int(tex_size.x / 2.0)), maxi(8, int(tex_size.y / 2.0)))
	var sc := Vector2(res) / tex_size
	var xf := Transform2D(Vector2(sc.x, 0.0), Vector2(0.0, sc.y), Vector2.ZERO)
	_vp.size = res
	_vp.canvas_transform = xf
	_vpf.size = res
	_vpf.canvas_transform = xf
	if ground_sprite != null:
		var wm := ShaderMaterial.new()
		wm.shader = WATER_SHADER
		wm.set_shader_parameter("fluid_mask", _vp.get_texture())
		wm.set_shader_parameter("flow_mask", _vpf.get_texture())
		wm.set_shader_parameter("fluid_on", 0.0)
		# convert the shader's export-pixel Wn back to WORLD units so the wave/foam/
		# rush frequencies match the editor (which tuned them at world scale)
		wm.set_shader_parameter("wave_scale", 1.0 / maxf(p_graph.export_scale, 0.01))
		ground_sprite.material = wm
	_request_render()


func clear_all() -> void:
	_disp.clear(); _dcol.clear(); _dtype.clear(); _dflow.clear()
	_request_render()


func _request_render() -> void:
	if _drawer != null:
		_drawer.queue_redraw()
	if _fdrawer != null:
		_fdrawer.queue_redraw()
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	_vpf.render_target_update_mode = SubViewport.UPDATE_ONCE


func _process(delta: float) -> void:
	if sim == null:
		return
	var k := 1.0 - pow(0.002, delta)
	var changed := false
	for cid in sim.active:
		var target: float = sim.amount[cid]
		var cur: float = _disp.get(cid, 0.0)
		if absf(target - cur) > 0.0005:
			_disp[cid] = lerpf(cur, target, k)
			changed = true
		var ti: int = sim.ftype[cid]
		if int(_dtype.get(cid, -1)) != ti:
			_dtype[cid] = ti
			_dcol[cid] = _colors[ti] if ti < _colors.size() else _colors[0]
			changed = true
		var tflow: Vector2 = (sim.flow_dir.get(cid, Vector2.ZERO) as Vector2) \
			* float(sim.flow_speed.get(cid, 0.0))
		var cflow: Vector2 = _dflow.get(cid, Vector2.ZERO)
		if cflow.distance_squared_to(tflow) > 0.0004:
			_dflow[cid] = cflow.lerp(tflow, 1.0 - pow(0.05, delta))
			changed = true
		elif tflow == Vector2.ZERO and cflow != Vector2.ZERO:
			_dflow.erase(cid)
			changed = true
	var drop: Array = []
	for cid in _disp:
		if sim.active.has(cid):
			continue
		if _dflow.has(cid):
			var cf: Vector2 = _dflow[cid]
			if cf.length_squared() < 0.0001:
				_dflow.erase(cid)
			else:
				_dflow[cid] = cf.lerp(Vector2.ZERO, k)
			changed = true
		var cur2: float = _disp[cid]
		if cur2 < 0.004:
			drop.append(cid)
		else:
			_disp[cid] = lerpf(cur2, 0.0, k)
			changed = true
	for cid in drop:
		_disp.erase(cid); _dcol.erase(cid); _dtype.erase(cid); _dflow.erase(cid)
	# toggle the ground shader's water pass so a dry map pays nothing
	var want_on := not _disp.is_empty()
	if want_on != _fluid_on and _ground != null and _ground.material != null:
		_fluid_on = want_on
		_ground.material.set_shader_parameter("fluid_on", 1.0 if want_on else 0.0)
	if changed or not _idle:
		_request_render()
	_idle = not changed


func _draw_field() -> void:
	if sim == null or graph == null:
		return
	var ncells := graph.cell_count
	for cid in _disp:
		if cid >= ncells:
			continue
		var dv: float = _disp[cid]
		var fill := clampf(dv / FULL, 0.0, 1.0)
		if fill < 0.02:
			continue
		var r: float = graph.radius(cid) * (0.95 + 0.85 * fill)
		var a := clampf(dv / (FULL * 2.0), 0.0, 1.0) * 0.55 + 0.45 * fill
		var c: Color = _dcol.get(cid, _colors[0])
		var p: Vector2 = graph.centroid(cid)
		var col := Color(c.r, c.g, c.b, a)
		_drawer.draw_polygon(
			PackedVector2Array([p + Vector2(-r, -r), p + Vector2(r, -r),
				p + Vector2(r, r), p + Vector2(-r, r)]),
			PackedColorArray([col, col, col, col]),
			PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]))


func _draw_flow() -> void:
	if sim == null or graph == null:
		return
	var ncells := graph.cell_count
	for cid in _dflow:
		if cid >= ncells or not _disp.has(cid):
			continue
		var fv: Vector2 = _dflow[cid]
		var spd := fv.length()
		if spd < 0.01:
			continue
		var dirn := fv / spd
		var r: float = graph.radius(cid) * 1.6
		var p: Vector2 = graph.centroid(cid)
		var col := Color(dirn.x * 0.5 + 0.5, dirn.y * 0.5 + 0.5, clampf(spd, 0.0, 1.0), 1.0)
		_fdrawer.draw_polygon(
			PackedVector2Array([p + Vector2(-r, -r), p + Vector2(r, -r),
				p + Vector2(r, r), p + Vector2(-r, r)]),
			PackedColorArray([col, col, col, col]),
			PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]))
