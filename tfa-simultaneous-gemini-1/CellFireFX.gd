extends Node2D
class_name CellFireFX

# Live fire rendering for structured maps: the EDITOR's FireFX recipe ported
# onto CellFire/CellGraph (the same way CellFluidFX ports FluidFX). Each
# burning cell cycles a deterministic set of CPU "particles" drawn as quads
# through the soft radial fire_blob shader (blend_add) — vertically stretched
# tongues respawning across the whole cell each cycle so adjacent cells merge
# into one continuous sheet of fire — plus a broad core sheet, ember
# under-glow, sparks, and drifting smoke on a normal-blend layer beneath.
# ALSO owns the fire light: one merged PointLight2D per connected burning
# CLUSTER (recomputed when CellFire.burn_rev changes). The old per-cell
# fire.tscn lights (~34px each on a ~31px cell lattice) read as a field of
# little yellow circles — the "sparkler" look.

const BLOB_SHADER := preload("res://shaders/fire_blob.gdshader")
const UP := Vector2(0.0, -1.0)
const BLOBS_PER_CELL := 6
const MAX_LIGHTS := 16

var sim: Node                # CellFire
var graph: CellGraph
var _t := 0.0
var _flames: Node2D          # blobs + embers + glow (additive soft-blob shader)
var _smoke: Node2D           # smoke puffs (normal blend)
var _was_burning := false
var _lights: Array = []      # pooled PointLight2Ds, one per burning cluster
var _light_rev := -1         # last CellFire.burn_rev clustered
var _light_timer := 0.0      # recluster cooldown: during a big fire's decay
                             # burn_rev bumps nearly every frame (jittered
                             # burnouts) and light positions barely move --
                             # cap the O(burning) flood-fill at ~3 Hz
var _light_tex: GradientTexture2D


func _ready() -> void:
	_smoke = Node2D.new()
	add_child(_smoke)
	_flames = Node2D.new()
	var sm := ShaderMaterial.new()
	sm.shader = BLOB_SHADER
	_flames.material = sm
	add_child(_flames)
	_smoke.draw.connect(_draw_smoke)
	_flames.draw.connect(_draw_flames)
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


func setup(p_sim: Node, p_graph: CellGraph) -> void:
	sim = p_sim
	graph = p_graph


func _process(delta: float) -> void:
	_t += delta
	var active: bool = sim != null and not sim.burning.is_empty()
	if active or _was_burning:   # one extra redraw after the last flame dies clears it
		_flames.queue_redraw()
		_smoke.queue_redraw()
	_was_burning = active
	_light_timer = maxf(_light_timer - delta, 0.0)
	if sim != null and "burn_rev" in sim and sim.burn_rev != _light_rev \
			and (_light_timer <= 0.0 or sim.burning.is_empty()):
		_light_rev = sim.burn_rev
		_light_timer = 0.35
		_refresh_lights()
	_flicker_lights()


# Size ramp over a cell's burn: quick flare-up, sustain, dwindle at the end.
func _ramp(bd: Dictionary) -> float:
	var t: float = bd["t"]
	var t0: float = bd["t0"]
	return clampf((t0 - t) / 1.2, 0.25, 1.0) * clampf(t / 2.2, 0.22, 1.0)


func _draw_flames() -> void:
	if sim == null or graph == null:
		return
	for cid in sim.burning:
		var bd: Dictionary = sim.burning[cid]
		var p: Vector2 = graph.centroid(cid)
		var cr: float = graph.radius(cid)
		var sd: float = bd["seed"]
		var k := _ramp(bd)
		# glow halo (was the fire.tscn PointLight2D color; lights are per-cluster now)
		var flick := 1.0 + sin(_t * 18.0 + sd * 9.0) * 0.08 + sin(_t * 7.3 + 1.7 + sd * 5.0) * 0.05
		_blob(p, cr * 2.8 * k, Color(1.0, 0.6, 0.2, 0.30 * k * flick))
		# core sheet: one broad soft disc per cell bridging the gaps between
		# neighbouring cells' tongues — the connective tissue of the flame body
		_blob(p, cr * 1.9 * k, Color(1.0, 0.62, 0.15, 0.35 * k * flick))
		# soft ember under-glow: two seeded off-centre blobs, wandering slowly,
		# fading in over ~2s — neighbouring cells merge into one continuous bed
		var elapsed: float = float(bd["t0"]) - float(bd["t"])
		var bed_k := k * clampf(elapsed / 2.0, 0.0, 1.0)
		if bed_k > 0.01:
			for g in 2:
				var fg := float(g)
				var goff := Vector2(_sfr(sd, fg + 71.0) - 0.5, _sfr(sd, fg + 83.0) - 0.5) * cr * 0.9
				goff += Vector2(sin(_t * 0.7 + sd * 12.0 + fg * 3.1), cos(_t * 0.9 + sd * 7.0 + fg * 2.3)) * cr * 0.15
				_blob(p + goff, cr * 1.6, Color(1.0, 0.38, 0.05, 0.40 * bed_k * flick))
		# rising flame tongues: each RESPAWNS somewhere new in the cell every
		# cycle, so tongues dance across the whole area and adjacent cells'
		# fields overlap into a continuous sheet. Fewer + roughly twice the old
		# size, stretched vertically, and they no longer shrivel to dots —
		# late-life fade is the ramp alpha's job, not the geometry's.
		for j in BLOBS_PER_CELL:
			var fj := float(j)
			var dur := 0.7 + 0.45 * _sfr(sd, fj + 13.0)
			var raw := _t / dur + _sfr(sd, fj)
			var u := fposmod(raw, 1.0)
			var cyc := floorf(raw)
			var ease := 1.0 - pow(1.0 - u, 1.7)       # decelerating rise (damping)
			var rise := cr * (1.3 + 0.8 * _sfr(sd, fj + 3.0 + cyc)) * k
			var aoff := TAU * _sfr(sd, fj * 3.7 + cyc * 11.0)
			var rad := sqrt(_sfr(sd, fj * 5.1 + cyc * 17.0)) * cr * 0.85
			var base := p + Vector2(cos(aoff), sin(aoff)) * rad
			var wig := sin(_t * (2.5 + 2.0 * _sfr(sd, fj + 41.0)) + fj * 1.7) * cr * 0.2 * u
			var pos := base + Vector2(wig, cr * 0.25 - rise * ease)
			var s0 := cr * (1.4 + 0.6 * _sfr(sd, fj + 7.0 + cyc)) * k
			var s := s0 * lerpf(1.0, 0.55, minf(u / 0.85, 1.0))
			var stretch := 1.6 + 0.4 * _sfr(sd, fj + 23.0)
			_blob(pos, s, _fire_ramp_color(u, k), stretch)
		# embers: rare sparks that outclimb the flame body (demoted — the old
		# bright 0.8-alpha pinpricks were half the "sparkler" read)
		for e in 2:
			var fe := float(e)
			var ue := fposmod(_t * (0.55 + 0.2 * fe) + sd * 7.0 + fe * 0.37, 1.0)
			var ep := p + Vector2(sin(sd * 40.0 + fe * 9.0 + _t * 2.0) * cr * 0.4, 0.0) \
				+ UP * (cr * 0.5 + cr * 2.6 * ue)
			_blob(ep, 2.0 * (1.0 - ue) * k + 0.8, Color(1.0, 0.62, 0.15, (1.0 - ue) * 0.5 * k))


# fire.tres color ramp: white-yellow -> orange -> deep red wisp -> gone.
# Start alpha 0.85 (not 1.0): shifts the additive budget from small bright
# cores to the large soft sheet/halo layers so the field fuses.
func _fire_ramp_color(u: float, k: float) -> Color:
	var c: Color
	if u < 0.35:
		c = Color(1.0, 0.95, 0.6, 0.85).lerp(Color(1.0, 0.55, 0.1, 0.85), u / 0.35)
	elif u < 0.75:
		c = Color(1.0, 0.55, 0.1, 0.85).lerp(Color(0.6, 0.05, 0.0, 0.7), (u - 0.35) / 0.4)
	else:
		c = Color(0.6, 0.05, 0.0, 0.7).lerp(Color(0.05, 0.02, 0.0, 0.0), (u - 0.75) / 0.25)
	c.a *= k
	return c


# One soft radial blob: a quad with UVs 0..1 through the fire_blob falloff
# shader. stretch > 1 elongates it vertically (UVs unchanged -> soft ellipse),
# turning circles into flame tongues.
func _blob(center: Vector2, s: float, col: Color, stretch: float = 1.0) -> void:
	if s <= 0.1:
		return
	var sy := s * stretch
	_flames.draw_polygon(
		PackedVector2Array([center + Vector2(-s, -sy), center + Vector2(s, -sy),
			center + Vector2(s, sy), center + Vector2(-s, sy)]),
		PackedColorArray([col, col, col, col]),
		PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]))


func _draw_smoke() -> void:
	if sim == null or graph == null:
		return
	var wind: Vector2 = sim._wind() if sim.has_method("_wind") else Vector2.ZERO
	for cid in sim.burning:
		var bd: Dictionary = sim.burning[cid]
		var p: Vector2 = graph.centroid(cid)
		var cr: float = graph.radius(cid)
		var sd: float = bd["seed"]
		var k := _ramp(bd)
		for i in 2:
			var fi := float(i)
			var u := fposmod(_t * 0.22 + sd * 3.0 + fi * 0.5, 1.0)
			var drift := p + UP * (cr * 1.6 + cr * 2.8 * u) + wind * cr * 1.6 * u \
				+ Vector2(sin(_t * 0.9 + sd * 20.0 + fi * 3.0) * cr * 0.3, 0.0)
			var rad := cr * (0.30 + 0.55 * u) * k
			# These puffs are the WISPS right at the flame. The drifting body of
			# smoke is now a real FogOverlay plume (CellFire._emit_smoke), so they
			# are held back a little to layer with it instead of doubling up into
			# a muddy patch. Restore 0.26 / 0.18 for the pre-plume look.
			_smoke.draw_circle(drift, rad, Color(0.13, 0.12, 0.11, 0.17 * (1.0 - u)))
			_smoke.draw_circle(drift + Vector2(-rad * 0.3, -rad * 0.25), rad * 0.6,
				Color(0.22, 0.21, 0.20, 0.12 * (1.0 - u)))


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
	if clusters.size() > MAX_LIGHTS:
		clusters.sort_custom(func(a, b): return float(a["ext"]) > float(b["ext"]))
		clusters.resize(MAX_LIGHTS)
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


func _flicker_lights() -> void:
	for i in _lights.size():
		var l: PointLight2D = _lights[i]
		if l.visible:
			var fi := float(i)
			l.energy = 0.9 * (1.0 + sin(_t * 18.0 + fi * 9.0) * 0.08 \
				+ sin(_t * 7.3 + 1.7 + fi * 5.0) * 0.05)


func _sfr(sd: float, i: float) -> float:
	return fposmod(sin((sd * 91.7 + i * 47.3)) * 437.585, 1.0)
