class_name CanopyLayer
extends Node2D
# Tree crowns ABOVE characters (P3-B; decision 7's visual half, the rules are
# P3-F's GridManager.canopy). Built by MapLoader for a map whose tree rows
# carry the TG export contract-3 canopy cells (canopy_cell / shade_cell into
# images.canopy, the canopy atlas): one quad per crown the crown record holds
# (the crowns that hide), each the crown alone, so a felled one goes without
# a bite out of its neighbours. A tree's shade (cast shadow + understory) and
# a crown that hides nothing (a dead snag, a willow) stay under characters as
# the tree's own slices (MapLoader._add_tree_canopy_art). Hedges stay in the
# structures overlay, under characters.
#
#   - Reads GridManager.canopy: crown(i) for where each crown is, and
#     crown_changed to drop a burnt or felled tree's crown (and its rule
#     disc) at once.
#   - Fades the crowns (the shader; the rest of the world is untouched) round
#     each party member standing under a crown's art, round the cursor over
#     one, and round whatever must stay readable under them: every node in
#     REVEAL_GROUP hands over shapes each frame (canopy_reveal(out), below) --
#     the planned routes and their ground marks (PathDrawer), aim lines
#     (AimLine), queued-order reticles (ActionQueue) and fire (CellFireFX).
#     The shader takes MAX_FADES shapes a frame, so the budget goes only to
#     what can be seen (a shape off the view or away from every live crown
#     is dropped), a polyline costs a shape per straight run near a crown
#     (not one per few px), and the primary selection's own plan is served
#     first, then the rest of the selection's, then everyone else's.
#   - Mirrors the tree's hit flash and damage tint (the tree's empty "Art"
#     node, which Structure drives) onto its crown.
#   - Cone shading by the crown RULES (P3-F), not only by the crown art. The
#     sight cones light light_mask bit 1; each carries a canopy child
#     (fit_canopy_cone) that lights CANOPY_LIGHT out to the range those rules
#     let its viewer see a target under a crown (half range from the ground,
#     none a story up). Lit through CANOPY_LIGHT (and LAMP_LIGHT: torches,
#     map lights, fire) and never bit 1 are: the crowns; each hiding crown's
#     RULE DISC (r minus its trunk, the ground crown_at says is hidden: a copy
#     of the ground there, which shows in the crowns' gaps and fade holes);
#     and every character standing under a live crown (its canvas items'
#     light_mask while it is hidden: _gate_characters). So no cone lights
#     ground or a body its viewer would not see.
#
# Z ORDER (absolute; Game's view layers): above the ground's rule discs (-6,
# drawn right after the ground sprite), structures (-3), fire (0), items (1),
# the path ribbon and aim lines (2), selection rings (3), characters (5, their
# VFX and conditions' sprites) and queued-order reticles (10) -- the fade
# shows these through; below the ability targeting indicators (49..51),
# projectiles (50: thrown things, and weapon shots on these maps,
# Game.spawn_projectile), StealthOverlay (60), TargetIntentOverlay (90),
# overhead widgets and floating text (100..115, 200), RoofLayer (120: a roof
# covers a crown over it in the roof view), roof-walkers
# (ProceduralCharacter.ROOF_WALKER_Z 135), the unexplored fog
# (UnexploredFogLayer.FOG_Z 140), which must filter crowns in never-seen
# ground like everything else, and the action-node markers (152).
#
# Parent under MapLoader: freed with the map on unload, like RoofLayer.

const CANOPY_Z := 45
## The rule discs: the ground sprite's own z, after it in tree order.
const GROUND_Z := -6
## How far a crown's art reaches, in crown radii (TG CanopyDrawer.MAX_REACH):
## a party member or the cursor this close to a crown is under its art.
const ART_REACH := 1.35
## The fade rings, px: full fade inside x, none outside y.
const PARTY_FADE := Vector2(52.0, 120.0)
const CURSOR_FADE := Vector2(36.0, 96.0)
## A REVEAL_GROUP shape of radius r fades fully within r, not at all past
## r + REVEAL_FEATHER.
const REVEAL_FEATHER := 28.0
const FADE_MIN := 0.25
## Fade shapes per frame: canopy_layer.gdshader's arrays hold this many (its
## loop runs only over the shapes there are).
const MAX_FADES := 128
## A party member's body: under a crown when its edge is.
const BODY_PAD := 16.0
## Nodes asked each frame for what the crowns must not hide:
##   func canopy_reveal(out: Array) -> void
## appending [points: PackedVector2Array, radius: float] in world px (one
## point: a disc; more: a polyline, faded along its length). Asked only on a
## map with a CanopyLayer.
const REVEAL_GROUP := "canopy_reveal"
## A polyline's points closer than this (px) to the last one kept are
## skipped; the kept ones are merged into the fewest straight capsules that
## keep every one of them within REVEAL_TOL of a capsule's axis (reveal_runs).
const REVEAL_STEP := 32.0
## How far (px) a polyline's merged capsules may stray from its kept points;
## its fade radii grow by as much, so it still fades fully over the line.
const REVEAL_TOL := 6.0
## What the shape kinds are (fade_shapes()).
enum Fade { PARTY, CURSOR, REVEAL }
## The name of a sight cone's canopy child (fit_canopy_cone).
const CANOPY_CONE_NAME := "CanopyCone"
## light_mask of what only a canopy cone (and the ordinary lights) may light:
## the crowns, the rule discs, characters under a crown.
const SHADED_MASK := CollisionLayers.CANOPY_LIGHT | CollisionLayers.LAMP_LIGHT
## A hidden character's canvas items are looked over again this often for
## new ones (gear put on, an effect added) while it stays hidden.
const REGATE_SECONDS := 0.5
## Weapon shots' z on a map with a CanopyLayer (Game.weapon_shot_z): up with
## the thrown things (Game's ThrownProjectile), above the crowns.
const SHOT_Z := 50
const DISC_SEGMENTS := 48
const SHADER := preload("res://Structures/canopy_layer.gdshader")
# The fade's quick reject: crowns by 64 px cell, each crown listed in every
# cell its art reach + BUCKET_MARGIN touches.
const BUCKET_CELL := 64.0
const BUCKET_MARGIN := 64.0
# The long queries (a long capsule, a canopy cone's reach): crowns by the
# COARSE_CELL px cell their centre lies in.
const COARSE_CELL := 256.0

## Tests: a world point to use instead of the mouse (null = the mouse).
var cursor_override: Variant = null
## Tests: a world Rect2 to serve as the view (null = what the viewport shows).
var view_override: Variant = null

var _tex: Texture2D = null
var _game: Node = null
var _ground: Sprite2D = null
var _mat: ShaderMaterial = null
var _disc_mat: Material = null
# Per crown: index (GridManager.canopy), pts (map px quad), uvs (0..1 in the
# atlas), art (the tree's "Art" node), color (its tint last frame), alive,
# pos and reach (px) for the fade test, disc (its rule disc, or null).
var _crowns: Array = []
var _bucket: Dictionary = {}           # Vector2i cell -> [indices into _crowns]
var _grid: Array = []                  # COARSE_CELL cells, row-major: [indices into _crowns]
var _grid_org := Vector2i.ZERO         # the first cell's (x, y)
var _grid_dim := Vector2i.ZERO         # cells across, down
var _max_reach: float = 0.0            # the largest crown's art reach (px)
var _seg := PackedVector4Array()       # this frame's fade shapes: a, b
var _rad := PackedVector2Array()       #   inner, outer radius
var _kind := PackedInt32Array()        #   Fade
var _reveal_buf: Array = []
var _cand: Array = []                  # scratch: coarse-grid candidates
var _gated: Dictionary = {}            # character instance id -> {c, items}
var _regate_left: float = 0.0


## crowns: [{index, cell: [atlas x, y, w, h, map x, y, w, h], art}] (MapLoader).
## game: whoever holds party_chars and characters_in_scene (Game).
## ground: the map's ground sprite (MapLoader.structured_ground: uncentred at
## the origin, a texel a px), copied over each hiding crown's rule disc;
## null = no discs.
func setup(tex: Texture2D, crowns: Array, game: Node, ground: Sprite2D = null) -> void:
	_tex = tex
	_game = game
	_ground = ground
	var ts := Vector2(tex.get_size()) if tex != null else Vector2.ONE
	_crowns.clear()
	for c in crowns:
		var cell: Array = c["cell"]
		var a := Rect2(float(cell[0]), float(cell[1]), float(cell[2]), float(cell[3]))
		var m := Rect2(float(cell[4]), float(cell[5]), float(cell[6]), float(cell[7]))
		var rec: Dictionary = GridManager.canopy.crown(int(c["index"]))
		var pos: Vector2 = rec.get("pos", m.get_center())
		var r: float = float(rec.get("r", 0.0))
		var disc: Polygon2D = null
		if _ground != null and _ground.texture != null and r > 0.0:
			disc = _rule_disc(pos, r, float(rec.get("trunk_r", 0.0)))
			add_child(disc)
		_crowns.append({
			"index": int(c["index"]),
			"pts": PackedVector2Array([m.position, Vector2(m.end.x, m.position.y), m.end, Vector2(m.position.x, m.end.y)]),
			"uvs": PackedVector2Array([a.position / ts, Vector2(a.end.x, a.position.y) / ts, a.end / ts,
				Vector2(a.position.x, a.end.y) / ts]),
			"art": c["art"],
			"color": Color.WHITE,
			"alive": bool(rec.get("alive", false)),
			"pos": pos,
			"reach": r * ART_REACH,
			"disc": disc})
	_build_buckets()


# A hiding crown's rule disc: the ground's own texels and material over the
# annulus r .. trunk_r round pos (CanopyMap._covers), lit like the crowns.
func _rule_disc(pos: Vector2, r: float, trunk_r: float) -> Polygon2D:
	var pts := PackedVector2Array()
	for ring in [r, trunk_r]:
		for i in DISC_SEGMENTS:
			var ang: float = TAU * float(i) / float(DISC_SEGMENTS)
			pts.append(pos + Vector2(cos(ang), sin(ang)) * float(ring))
	var quads: Array = []
	for i in DISC_SEGMENTS:
		var j: int = (i + 1) % DISC_SEGMENTS
		quads.append(PackedInt32Array([i, j, DISC_SEGMENTS + j, DISC_SEGMENTS + i]))
	var d := Polygon2D.new()
	d.name = "RuleDisc"
	d.polygon = pts
	d.uv = pts   # map px are ground texels
	d.polygons = quads
	d.texture = _ground.texture
	d.material = _ground.material
	d.light_mask = SHADED_MASK
	d.z_as_relative = false
	d.z_index = GROUND_Z
	return d


func _build_buckets() -> void:
	_bucket.clear()
	for i in _crowns.size():
		var c: Dictionary = _crowns[i]
		var p: Vector2 = c["pos"]
		var rr: float = float(c["reach"]) + BUCKET_MARGIN
		var x0: int = floori((p.x - rr) / BUCKET_CELL)
		var x1: int = floori((p.x + rr) / BUCKET_CELL)
		var y0: int = floori((p.y - rr) / BUCKET_CELL)
		var y1: int = floori((p.y + rr) / BUCKET_CELL)
		for cy in range(y0, y1 + 1):
			for cx in range(x0, x1 + 1):
				var q := Vector2(clampf(p.x, cx * BUCKET_CELL, (cx + 1) * BUCKET_CELL),
					clampf(p.y, cy * BUCKET_CELL, (cy + 1) * BUCKET_CELL))
				if q.distance_squared_to(p) > rr * rr:
					continue
				var k := Vector2i(cx, cy)
				if not _bucket.has(k):
					_bucket[k] = []
				(_bucket[k] as Array).append(i)
	_build_grid()


func _build_grid() -> void:
	_grid.clear()
	_grid_dim = Vector2i.ZERO
	_max_reach = 0.0
	if _crowns.is_empty():
		return
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in _crowns:
		var p: Vector2 = c["pos"]
		lo = lo.min(p)
		hi = hi.max(p)
		_max_reach = maxf(_max_reach, float(c["reach"]))
	_grid_org = Vector2i(floori(lo.x / COARSE_CELL), floori(lo.y / COARSE_CELL))
	_grid_dim = Vector2i(floori(hi.x / COARSE_CELL), floori(hi.y / COARSE_CELL)) - _grid_org + Vector2i.ONE
	_grid.resize(_grid_dim.x * _grid_dim.y)
	for k in _grid.size():
		_grid[k] = []
	for i in _crowns.size():
		var p: Vector2 = _crowns[i]["pos"]
		var cell := Vector2i(floori(p.x / COARSE_CELL), floori(p.y / COARSE_CELL)) - _grid_org
		(_grid[cell.y * _grid_dim.x + cell.x] as Array).append(i)


# The coarse cells (x0, y0, x1, y1, inclusive; empty when x0 > x1) holding
# every crown whose art may come within `pad` of `rect`.
func _grid_span(rect: Rect2, pad: float) -> Rect2i:
	if _grid_dim.x <= 0:
		return Rect2i(0, 0, -1, -1)
	var g := rect.grow(pad + _max_reach)
	var c0 := Vector2i(floori(g.position.x / COARSE_CELL), floori(g.position.y / COARSE_CELL)) - _grid_org
	var c1 := Vector2i(floori(g.end.x / COARSE_CELL), floori(g.end.y / COARSE_CELL)) - _grid_org
	c0 = c0.max(Vector2i.ZERO)
	c1 = c1.min(_grid_dim - Vector2i.ONE)
	return Rect2i(c0, c1 - c0)


# The crowns (indices into _crowns, into `out`) whose art may come within
# `pad` of `rect` (_grid_span).
func _crowns_near_rect(rect: Rect2, pad: float, out: Array) -> void:
	out.clear()
	var span := _grid_span(rect, pad)
	for cy in range(span.position.y, span.end.y + 1):
		for cx in range(span.position.x, span.end.x + 1):
			out.append_array(_grid[cy * _grid_dim.x + cx])


func _ready() -> void:
	z_as_relative = false
	z_index = CANOPY_Z
	light_mask = SHADED_MASK
	# the party plans while paused: the fade must follow the cursor then too
	process_mode = Node.PROCESS_MODE_ALWAYS
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_mat.set_shader_parameter("fade_min", FADE_MIN)
	material = _mat
	if not GridManager.canopy.crown_changed.is_connected(_on_crown_changed):
		GridManager.canopy.crown_changed.connect(_on_crown_changed)
	queue_redraw()


func _exit_tree() -> void:
	if GridManager.canopy.crown_changed.is_connected(_on_crown_changed):
		GridManager.canopy.crown_changed.disconnect(_on_crown_changed)
	# characters outlive the map (the party warps on): give their lights back
	for id in _gated.keys():
		_ungate(_gated[id])
	_gated.clear()


func _on_crown_changed(index: int) -> void:
	for c in _crowns:
		if int(c["index"]) == index and not bool(GridManager.canopy.crown(index).get("alive", false)):
			_kill(c)
	queue_redraw()


func _kill(c: Dictionary) -> void:
	c["alive"] = false
	var disc: Variant = c["disc"]
	if disc != null and is_instance_valid(disc):
		(disc as Node).queue_free()
	c["disc"] = null


func _draw() -> void:
	if _tex == null:
		return
	for c in _crowns:
		if not bool(c["alive"]):
			continue
		var col: Color = c["color"]
		draw_polygon(c["pts"], PackedColorArray([col, col, col, col]), c["uvs"], _tex)


func _process(delta: float) -> void:
	_update_fade()
	_gate_characters(delta)
	# the rule discs wear the ground's material (CellFluidFX binds the water
	# shader to the ground after the map loads)
	if _ground != null and is_instance_valid(_ground) and _ground.material != _disc_mat:
		_disc_mat = _ground.material
		for c in _crowns:
			var disc: Variant = c["disc"]
			if disc != null and is_instance_valid(disc):
				(disc as Polygon2D).material = _disc_mat
	# the tree's hit flash / damage tint, onto its crown
	var dirty := false
	for c in _crowns:
		if not bool(c["alive"]):
			continue
		var art: Variant = c["art"]
		if not is_instance_valid(art):
			_kill(c)   # the tree is gone (its destroyed signal killed the crown too)
			dirty = true
			continue
		var ci := art as CanvasItem
		var col: Color = ci.modulate * ci.self_modulate
		if col != (c["color"] as Color):
			c["color"] = col
			dirty = true
	if dirty:
		queue_redraw()


# --- the fade -----------------------------------------------------------------

func _update_fade() -> void:
	_seg.clear()
	_rad.clear()
	_kind.clear()
	var view: Rect2 = view_rect()
	var party: Array = []
	if _game != null and is_instance_valid(_game) and "party_chars" in _game:
		party = _game.party_chars
	for pc in party:
		if not (pc is Node2D) or not is_instance_valid(pc) or not (pc as Node2D).is_inside_tree():
			continue
		var p: Vector2 = (pc as Node2D).global_position
		if _in_view(p, p, PARTY_FADE.y, view) and under_art(p, BODY_PAD):
			_add_fade(p, p, PARTY_FADE, Fade.PARTY)
	var cur: Vector2 = get_global_mouse_position()
	if cursor_override is Vector2:
		cur = cursor_override
	if _in_view(cur, cur, CURSOR_FADE.y, view) and under_art(cur, 0.0):
		_add_fade(cur, cur, CURSOR_FADE, Fade.CURSOR)
	# the providers' shapes, served by rank (_reveal_rank): each provider's
	# run [from, to) of _reveal_buf is filed under its rank
	_reveal_buf.clear()
	var runs: Array = [[], [], [], []]
	if is_inside_tree():
		for n in get_tree().get_nodes_in_group(REVEAL_GROUP):
			if not n.has_method("canopy_reveal"):
				continue
			var from: int = _reveal_buf.size()
			n.canopy_reveal(_reveal_buf)
			if _reveal_buf.size() > from:
				(runs[_reveal_rank(n)] as Array).append(Vector2i(from, _reveal_buf.size()))
	for rank_runs in runs:
		for run in rank_runs:
			var span: Vector2i = run
			for i in range(span.x, span.y):
				if _seg.size() >= MAX_FADES:
					break
				_add_reveal(_reveal_buf[i], view)
	if _mat != null:
		_mat.set_shader_parameter("fade_count", _seg.size())
		_mat.set_shader_parameter("fade_seg", _seg)
		_mat.set_shader_parameter("fade_rad", _rad)


## The world rect the fade serves this frame: what the layer's viewport shows
## (view_override when set). A fade shape wholly outside it is dropped.
func view_rect() -> Rect2:
	if view_override is Rect2:
		return view_override
	if not is_inside_tree():
		return Rect2(-1e9, -1e9, 2e9, 2e9)
	return get_canvas_transform().affine_inverse() * get_viewport_rect()


static func _in_view(a: Vector2, b: Vector2, pad: float, view: Rect2) -> bool:
	return Rect2(a, Vector2.ZERO).expand(b).grow(pad).intersects(view)


# Whose plan a REVEAL_GROUP provider draws, as the order the budget serves it
# in: 0 the primary selection's, 1 the rest of the selection's, 2 another
# party member's or nobody's (fire, a loose aim line), 3 an NPC's.
func _reveal_rank(n: Node) -> int:
	var who: Node = null
	var p: Node = n
	for _i in 3:
		if p == null:
			break
		if p is ProceduralCharacter:
			who = p
			break
		p = p.get_parent()
	if who == null or _game == null or not is_instance_valid(_game):
		return 2
	if "primary_selected" in _game and _game.primary_selected == who:
		return 0
	if "selected_characters" in _game and who in _game.selected_characters:
		return 1
	if "party_chars" in _game and not (who in _game.party_chars):
		return 3
	return 2


# Appends a fade shape; false once the budget is spent.
func _add_fade(a: Vector2, b: Vector2, radii: Vector2, kind: int) -> bool:
	if _seg.size() >= MAX_FADES:
		return false
	_seg.append(Vector4(a.x, a.y, b.x, b.y))
	_rad.append(radii)
	_kind.append(kind)
	return true


# One REVEAL_GROUP shape: a disc, or a polyline as its straight runs
# (reveal_runs), each kept only where it is in view and comes near a live
# crown's art.
func _add_reveal(e: Variant, view: Rect2) -> void:
	if not (e is Array) or (e as Array).size() < 2:
		return
	var pts := PackedVector2Array((e as Array)[0])
	var r: float = float((e as Array)[1])
	var radii := Vector2(r, r + REVEAL_FEATHER)
	if pts.size() == 1:
		if _in_view(pts[0], pts[0], radii.y, view) and near_art(pts[0], pts[0], radii.y):
			_add_fade(pts[0], pts[0], radii, Fade.REVEAL)
		return
	radii += Vector2(REVEAL_TOL, REVEAL_TOL)
	var v := reveal_runs(pts)
	for i in range(1, v.size()):
		if _in_view(v[i - 1], v[i], radii.y, view) and near_art(v[i - 1], v[i], radii.y):
			if not _add_fade(v[i - 1], v[i], radii, Fade.REVEAL):
				return


## A polyline's fade capsules, as the vertices of a polyline each of whose
## segments is one: its points at least REVEAL_STEP apart (the last always
## kept), merged greedily into straight runs that keep every kept point
## within REVEAL_TOL of the run's axis.
static func reveal_runs(pts: PackedVector2Array) -> PackedVector2Array:
	var v := PackedVector2Array()
	if pts.is_empty():
		return v
	v.append(pts[0])
	var step2: float = REVEAL_STEP * REVEAL_STEP
	for i in range(1, pts.size()):
		if pts[i].distance_squared_to(v[v.size() - 1]) >= step2 or i == pts.size() - 1:
			v.append(pts[i])
	if v.size() <= 2:
		return v
	var out := PackedVector2Array([v[0]])
	var tol2: float = REVEAL_TOL * REVEAL_TOL
	var s: int = 0
	while s < v.size() - 1:
		var e: int = s + 1
		while e + 1 < v.size() and _run_holds(v, s, e + 1, tol2):
			e += 1
		out.append(v[e])
		s = e
	return out


# True when every point of v strictly between s and e lies within sqrt(tol2)
# of the segment v[s] .. v[e].
static func _run_holds(v: PackedVector2Array, s: int, e: int, tol2: float) -> bool:
	var a: Vector2 = v[s]
	var b: Vector2 = v[e]
	for k in range(s + 1, e):
		var q: Vector2 = Geometry2D.get_closest_point_to_segment(v[k], a, b)
		if q.distance_squared_to(v[k]) > tol2:
			return false
	return true


## True when point `p` (map px) is within `pad` of a live crown's art.
func under_art(p: Vector2, pad: float) -> bool:
	return near_art(p, p, pad)


## True when the capsule p0 .. p1 of radius `r` (map px) reaches a live
## crown's art (ART_REACH r round its trunk).
func near_art(p0: Vector2, p1: Vector2, r: float) -> bool:
	if r + p0.distance_to(p1) * 0.25 > BUCKET_MARGIN:
		_crowns_near_rect(Rect2(p0, Vector2.ZERO).expand(p1), r, _cand)
		return _capsule_hits(p0, p1, r, _cand)
	var mid: Vector2 = (p0 + p1) * 0.5
	for q in [p0, mid, p1]:
		var qv: Vector2 = q
		var b: Variant = _bucket.get(Vector2i(floori(qv.x / BUCKET_CELL), floori(qv.y / BUCKET_CELL)))
		if b != null and _capsule_hits(p0, p1, r, b as Array):
			return true
	return false


func _capsule_hits(p0: Vector2, p1: Vector2, r: float, idx: Array) -> bool:
	var ab: Vector2 = p1 - p0
	var l2: float = ab.length_squared()
	for i in idx:
		var c: Dictionary = _crowns[int(i)]
		if not bool(c["alive"]):
			continue
		var p: Vector2 = c["pos"]
		var t: float = 0.0
		if l2 > 1e-6:
			t = clampf((p - p0).dot(ab) / l2, 0.0, 1.0)
		var reach: float = float(c["reach"]) + r
		if p.distance_squared_to(p0 + ab * t) <= reach * reach:
			return true
	return false


## True when a live crown's art lies within `radius` of `p` (the canopy cone's
## quick reject: no crown in reach, no second shadowed light). Looks only at
## the coarse cells round p (_grid_span).
func any_crown_within(p: Vector2, radius: float) -> bool:
	var span := _grid_span(Rect2(p, Vector2.ZERO), radius)
	for cy in range(span.position.y, span.end.y + 1):
		for cx in range(span.position.x, span.end.x + 1):
			for i in (_grid[cy * _grid_dim.x + cx] as Array):
				var c: Dictionary = _crowns[int(i)]
				if not bool(c["alive"]):
					continue
				var reach: float = float(c["reach"]) + radius
				if p.distance_squared_to(c["pos"] as Vector2) <= reach * reach:
					return true
	return false


# --- characters under a crown ---------------------------------------------------
# The rules hide a character under a live crown (the target side: alive, not
# given away by an attack or a cast) from every viewer whose canopy cone does
# not reach it. Its canvas items (the body, its gear, its effects; not its
# own lights nor the world-space UI it owns, which is top_level) trade light
# mask 1 for SHADED_MASK while it is, so the full cones stop lighting it --
# a hidden party member in a fade hole does not show lit by a cone whose
# viewer is blind to it -- and are given mask 1 back the moment it is not.

## True when the crown rules hide `c` under a live crown (CanopyMap via its
## canopy_crown(); not in a reveal() window).
static func hides_under_crown(c: Node) -> bool:
	if c == null or not is_instance_valid(c) or not c.has_method("canopy_crown"):
		return false
	if int(c.canopy_crown()) < 0:
		return false
	return not (c.has_method("_canopy_revealed") and bool(c._canopy_revealed()))


func _gate_characters(delta: float) -> void:
	var chars: Array = []
	if _game != null and is_instance_valid(_game) and "characters_in_scene" in _game:
		chars = _game.characters_in_scene
	_regate_left -= delta
	var rewalk: bool = _regate_left <= 0.0
	if rewalk:
		_regate_left = REGATE_SECONDS
	var hidden: Dictionary = {}
	for c in chars:
		if not is_instance_valid(c) or not (c is Node2D) or not (c as Node2D).is_inside_tree():
			continue
		if not hides_under_crown(c):
			continue
		var id: int = (c as Node).get_instance_id()
		hidden[id] = true
		if not _gated.has(id):
			_gated[id] = {"c": c, "items": []}
			_gate(_gated[id])
		elif rewalk:
			_gate(_gated[id])
	for id in _gated.keys():
		if not hidden.has(id):
			_ungate(_gated[id])
			_gated.erase(id)


func _gate(rec: Dictionary) -> void:
	var c: Variant = rec["c"]
	if not is_instance_valid(c):
		return
	var items: Array = rec["items"]
	var stack: Array = [c]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Light2D:
			continue
		if n != c and n is CanvasItem and (n as CanvasItem).top_level:
			continue
		if n is CanvasItem and (n as CanvasItem).light_mask == 1:
			(n as CanvasItem).light_mask = SHADED_MASK
			items.append(n)
		for ch in n.get_children():
			stack.append(ch)


func _ungate(rec: Dictionary) -> void:
	for n in (rec["items"] as Array):
		if is_instance_valid(n) and (n as CanvasItem).light_mask == SHADED_MASK:
			(n as CanvasItem).light_mask = 1
	(rec["items"] as Array).clear()


# --- tests and tools -------------------------------------------------------------

## The crown indices drawn now.
func drawn_crowns() -> Array:
	var out: Array = []
	for c in _crowns:
		if bool(c["alive"]):
			out.append(int(c["index"]))
	return out

## This frame's fade shapes: [{a, b, inner, outer, kind (Fade)}].
func fade_shapes() -> Array:
	var out: Array = []
	for i in _seg.size():
		var s: Vector4 = _seg[i]
		out.append({"a": Vector2(s.x, s.y), "b": Vector2(s.z, s.w), "inner": _rad[i].x,
			"outer": _rad[i].y, "kind": _kind[i]})
	return out

func crown_color(index: int) -> Color:
	for c in _crowns:
		if int(c["index"]) == index:
			return c["color"]
	return Color(0, 0, 0, 0)

## The rule disc of crown `index` (GridManager.canopy), or null.
func rule_disc(index: int) -> Polygon2D:
	for c in _crowns:
		if int(c["index"]) == index:
			var disc: Variant = c["disc"]
			if disc != null and is_instance_valid(disc):
				return disc as Polygon2D
	return null

## The characters whose lights are gated now.
func gated_characters() -> Array:
	var out: Array = []
	for id in _gated:
		var c: Variant = (_gated[id] as Dictionary)["c"]
		if is_instance_valid(c):
			out.append(c)
	return out


## The map's CanopyLayer (MapLoader.canopy_layer), or null: a map without
## crowns above characters (every contract-2 map). Game asks it for the sight
## cones and the weapon shots.
static func of(map_loader: Node) -> CanopyLayer:
	if map_loader == null or not is_instance_valid(map_loader) or not ("canopy_layer" in map_loader):
		return null
	var l: Variant = map_loader.canopy_layer
	if l == null or not is_instance_valid(l) or not (l is CanopyLayer):
		return null
	var layer: CanopyLayer = l
	if layer.is_queued_for_deletion():
		return null
	return layer


# --- the cone renderer's canopy child -----------------------------------------
# A sight cone (Game: LineOfSight, NPCLineOfSight; PointLight2D, range mask 1)
# lights bit 1: the ground, structure art, characters in the open. It no
# longer lights what a crown hides (SHADED_MASK above: the crowns, the rule
# discs, characters under a crown); this child does, with the cone's own
# texture, tint, energy and shadows, out to the fraction of its radius within
# which the rules let the viewer see a target under a crown (P3-F: a ground
# viewer within CANOPY_VISIBILITY of its range, or near, or all of it from
# under a crown; a viewer a story up not at all). So a cone shows lit
# exactly where the viewer would see someone standing there.

## Fits `light`'s canopy child to `viewer` (created on first use), for the
## map's CanopyLayer `layer` (null: a map without one, so it is switched
## off). On only while the cone is on and shown (stealth mode owns an NPC
## cone's visible) and a live crown lies within its reach. Returns it (or
## null).
static func fit_canopy_cone(light: PointLight2D, viewer: Node2D, layer: CanopyLayer) -> PointLight2D:
	var cc := light.get_node_or_null(CANOPY_CONE_NAME) as PointLight2D
	if layer == null or not is_instance_valid(layer):
		if cc != null and cc.enabled:
			cc.enabled = false
		return cc
	if cc == null:
		cc = PointLight2D.new()
		cc.name = CANOPY_CONE_NAME
		cc.shadow_enabled = true
		cc.range_item_cull_mask = CollisionLayers.CANOPY_LIGHT
		light.add_child(cc)
	if cc.texture != light.texture:
		cc.texture = light.texture
	if cc.color != light.color:
		cc.color = light.color
	if not is_equal_approx(cc.energy, light.energy):
		cc.energy = light.energy
	var mask: int = light.shadow_item_cull_mask | CollisionLayers.CANOPY_LIGHT
	if cc.shadow_item_cull_mask != mask:
		cc.shadow_item_cull_mask = mask
	if not light.enabled or not light.is_visible_in_tree():
		if cc.enabled:
			cc.enabled = false
		return cc
	var range_px: float = 0.0
	if light.texture != null:
		range_px = light.texture_scale * float(light.texture.get_width()) * 0.5
	var k: float = canopy_cone_fraction(viewer, range_px)
	var want_on: bool = k > 0.0 and layer.any_crown_within(viewer.global_position, range_px * k)
	if cc.enabled != want_on:
		cc.enabled = want_on
	if want_on and not is_equal_approx(cc.texture_scale, light.texture_scale * k):
		cc.texture_scale = light.texture_scale * k
	return cc


## The fraction of a viewer's sight range (range_px) within which it sees a
## target under a crown: 0 a story or more up (on a roof, or a deck that high:
## the crown blocks it outright), all of it under a crown itself (its own
## cluster hides nothing from it; elsewhere that over-reports, the safe
## side), else CANOPY_VISIBILITY, or the near exemption's reach when that is
## farther.
static func canopy_cone_fraction(viewer: Node2D, range_px: float) -> float:
	if viewer == null or range_px <= 0.0:
		return 0.0
	if GridManager.is_high_layer(viewer):
		return 0.0
	if viewer.has_method("canopy_crown") and int(viewer.canopy_crown()) >= 0:
		return 1.0
	var near: float = GridManager.TILE_SIZE * ProceduralCharacter.CANOPY_NEAR_TILES
	if viewer.has_method("_canopy_near_px"):
		near = float(viewer._canopy_near_px(viewer))
	return clampf(maxf(ProceduralCharacter.CANOPY_VISIBILITY, near / range_px), 0.0, 1.0)
