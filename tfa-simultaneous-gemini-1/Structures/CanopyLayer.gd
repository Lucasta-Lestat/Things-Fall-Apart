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
#     crown_changed to drop a burnt or felled tree's crown at once.
#   - Fades round each party member standing under a crown's art, and round
#     the cursor over one (the shader; only crowns are faded, the rest of the
#     world is untouched), so the party and what it hovers show through.
#   - Mirrors the tree's hit flash and damage tint (the tree's empty "Art"
#     node, which Structure drives) onto its crown.
#   - Lit only by the sight cones' canopy children (light_mask
#     CollisionLayers.CANOPY_LIGHT; fit_canopy_cone below), so a cone shades a
#     crown wherever the crown rules hide a target under it from that viewer.
#
# Z ORDER (absolute; Game's view layers): above characters (z 5, their VFX
# and conditions' sprites), items (1) and structures (-3); below the ability
# targeting indicators (49..51), projectiles (50), StealthOverlay (60),
# TargetIntentOverlay (90), overhead widgets and floating text (100..115,
# 200), RoofLayer (120: a roof covers a crown over it in the roof view),
# roof-walkers (ProceduralCharacter.ROOF_WALKER_Z 135) and the unexplored fog
# (UnexploredFogLayer.FOG_Z 140), which must filter crowns in never-seen
# ground like everything else.
#
# Parent under MapLoader: freed with the map on unload, like RoofLayer.

const CANOPY_Z := 45
## How far a crown's art reaches, in crown radii (TG CanopyDrawer.MAX_REACH):
## a party member or the cursor this close to a crown is under its art.
const ART_REACH := 1.35
## The fade rings, px: full fade inside x, none outside y.
const PARTY_FADE := Vector2(52.0, 120.0)
const CURSOR_FADE := Vector2(36.0, 96.0)
const FADE_MIN := 0.25
const FADE_MAX_POINTS := 8
## A party member's body: under a crown when its edge is.
const BODY_PAD := 16.0
## The name of a sight cone's canopy child (fit_canopy_cone).
const CANOPY_CONE_NAME := "CanopyCone"
const SHADER := preload("res://Structures/canopy_layer.gdshader")

## Tests: a world point to use instead of the mouse (null = the mouse).
var cursor_override: Variant = null

var _tex: Texture2D = null
var _game: Node = null
var _mat: ShaderMaterial = null
# Per crown: index (GridManager.canopy), pts (map px quad), uvs (0..1 in the
# atlas), art (the tree's "Art" node), color (its tint last frame), alive,
# pos and reach (px) for the fade test.
var _crowns: Array = []
var _fade: PackedVector4Array = PackedVector4Array()


## crowns: [{index, cell: [atlas x, y, w, h, map x, y, w, h], art}] (MapLoader).
## game: whoever holds party_chars (Game).
func setup(tex: Texture2D, crowns: Array, game: Node) -> void:
	_tex = tex
	_game = game
	var ts := Vector2(tex.get_size()) if tex != null else Vector2.ONE
	_crowns.clear()
	for c in crowns:
		var cell: Array = c["cell"]
		var a := Rect2(float(cell[0]), float(cell[1]), float(cell[2]), float(cell[3]))
		var m := Rect2(float(cell[4]), float(cell[5]), float(cell[6]), float(cell[7]))
		var rec: Dictionary = GridManager.canopy.crown(int(c["index"]))
		_crowns.append({
			"index": int(c["index"]),
			"pts": PackedVector2Array([m.position, Vector2(m.end.x, m.position.y), m.end, Vector2(m.position.x, m.end.y)]),
			"uvs": PackedVector2Array([a.position / ts, Vector2(a.end.x, a.position.y) / ts, a.end / ts,
				Vector2(a.position.x, a.end.y) / ts]),
			"art": c["art"],
			"color": Color.WHITE,
			"alive": bool(rec.get("alive", false)),
			"pos": rec.get("pos", m.get_center()),
			"reach": float(rec.get("r", 0.0)) * ART_REACH})


func _ready() -> void:
	z_as_relative = false
	z_index = CANOPY_Z
	light_mask = CollisionLayers.CANOPY_LIGHT
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


func _on_crown_changed(index: int) -> void:
	for c in _crowns:
		if int(c["index"]) == index and not bool(GridManager.canopy.crown(index).get("alive", false)):
			c["alive"] = false
	queue_redraw()


func _draw() -> void:
	if _tex == null:
		return
	for c in _crowns:
		if not bool(c["alive"]):
			continue
		var col: Color = c["color"]
		draw_polygon(c["pts"], PackedColorArray([col, col, col, col]), c["uvs"], _tex)


func _process(_delta: float) -> void:
	_update_fade()
	# the tree's hit flash / damage tint, onto its crown
	var dirty := false
	for c in _crowns:
		if not bool(c["alive"]):
			continue
		var art: Variant = c["art"]
		if not is_instance_valid(art):
			c["alive"] = false   # the tree is gone (its destroyed signal killed the crown too)
			dirty = true
			continue
		var ci := art as CanvasItem
		var col: Color = ci.modulate * ci.self_modulate
		if col != (c["color"] as Color):
			c["color"] = col
			dirty = true
	if dirty:
		queue_redraw()


func _update_fade() -> void:
	_fade.clear()
	var party: Array = []
	if _game != null and is_instance_valid(_game) and "party_chars" in _game:
		party = _game.party_chars
	for pc in party:
		if _fade.size() >= FADE_MAX_POINTS - 1:
			break
		if not (pc is Node2D) or not is_instance_valid(pc) or not (pc as Node2D).is_inside_tree():
			continue
		var p: Vector2 = (pc as Node2D).global_position
		if under_art(p, BODY_PAD):
			_fade.append(Vector4(p.x, p.y, PARTY_FADE.x, PARTY_FADE.y))
	var cur: Vector2 = get_global_mouse_position()
	if cursor_override is Vector2:
		cur = cursor_override
	if under_art(cur, 0.0):
		_fade.append(Vector4(cur.x, cur.y, CURSOR_FADE.x, CURSOR_FADE.y))
	if _mat != null:
		_mat.set_shader_parameter("fade_count", _fade.size())
		_mat.set_shader_parameter("fade_pts", _fade)


## True when point `p` (map px) is within `pad` of a live crown's art.
func under_art(p: Vector2, pad: float) -> bool:
	for c in _crowns:
		if not bool(c["alive"]):
			continue
		var reach: float = float(c["reach"]) + pad
		if p.distance_squared_to(c["pos"] as Vector2) <= reach * reach:
			return true
	return false


## Tests and tools: the crown indices drawn now, and the fade points.
func drawn_crowns() -> Array:
	var out: Array = []
	for c in _crowns:
		if bool(c["alive"]):
			out.append(int(c["index"]))
	return out

func fade_points() -> PackedVector4Array:
	return _fade

func crown_color(index: int) -> Color:
	for c in _crowns:
		if int(c["index"]) == index:
			return c["color"]
	return Color(0, 0, 0, 0)


# --- the cone renderer's canopy child -----------------------------------------
# A sight cone (Game: LineOfSight, NPCLineOfSight; PointLight2D, light_mask 1)
# lights the ground over a crown's whole shade, though the crown rules hide a
# target under a crown from most of that cone (P3-F: a ground viewer sees one
# only within CANOPY_VISIBILITY of its range, or near, or under the same
# crowns; a viewer a story up not at all). The crowns cover the ground under
# them and no full cone lights them (CANOPY_LIGHT): this child does, with the
# cone's own texture, tint, energy and shadows, out to that fraction of its
# radius -- so a crown shows lit exactly where the viewer would see someone
# standing under it.

## Fits `light`'s canopy child to `viewer` (created on first use). `on` false
## (a map without a CanopyLayer) switches it off. Returns it (or null).
static func fit_canopy_cone(light: PointLight2D, viewer: Node2D, on: bool) -> PointLight2D:
	var cc := light.get_node_or_null(CANOPY_CONE_NAME) as PointLight2D
	if not on:
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
	var range_px: float = 0.0
	if light.texture != null:
		range_px = light.texture_scale * float(light.texture.get_width()) * 0.5
	var k: float = canopy_cone_fraction(viewer, range_px)
	var want_on: bool = light.enabled and k > 0.0
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
