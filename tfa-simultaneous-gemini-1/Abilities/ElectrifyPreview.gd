# =====================
# Abilities/ElectrifyPreview.gd - While an electric/lightning ability is being
# aimed, highlights every tile the current would flood (the dry run
# SurfaceManager.electrify_region, the same rule try_electrify applies) from
# each character the shape would hit, and rings whoever stands in that flood:
# orange for party members (friendly fire), yellow for the rest. Child of
# AbilityTargeting, which it only reads; it adds nothing to its state.
#
# Approximate on purpose, like the reticle: it ignores DR and immunity (the
# flood only starts when damage gets through), and a paused plan resolves
# later, when bodies may have moved. Only characters the party can see count,
# so the preview never reveals a hidden NPC.
# =====================

extends Node2D

const RECOMPUTE_SEC := 0.15
const BFS_CAP := 4096
const TILE_FILL := Color(1.0, 0.95, 0.35, 0.22)
const TILE_EDGE := Color(1.0, 0.95, 0.35, 0.7)
const RING_PARTY := Color(1.0, 0.45, 0.2, 0.9)
const RING_OTHER := Color(1.0, 0.95, 0.35, 0.9)
const RING_RADIUS := 22.0
const LABEL_SIZE := 14

var _tiles: Array[Vector2i] = []
var _rings: Array = []          # [{pos: Vector2, party: bool}]
var _label_pos: Vector2 = Vector2.ZERO
var _recompute_left: float = 0.0
var _shown := false

func _ready() -> void:
	name = "ElectrifyPreview"
	# World coordinates, whatever the caster's transform (it rotates).
	top_level = true
	z_index = 1
	process_mode = Node.PROCESS_MODE_ALWAYS

## True when any damage effect of the ability deals electric or lightning
## damage, the types that start the conductive flood (ProceduralCharacter's
## per-type rider). Looks at "effects" and at each of "steps"' effects.
static func is_electric(ability: Dictionary) -> bool:
	var lists: Array = [ability.get("effects", [])]
	var steps = ability.get("steps", [])
	if steps is Array:
		for step in steps:
			if step is Dictionary:
				lists.append(step.get("effects", []))
	for effects in lists:
		if not (effects is Array):
			continue
		for e in effects:
			if not (e is Dictionary) or str(e.get("type", "")) != "damage":
				continue
			var dmg = e.get("damage", {})
			if not (dmg is Dictionary):
				continue
			for t in ["electric", "lightning"]:
				if _positive(dmg.get(t, 0)):
					return true
	return false

static func _positive(v) -> bool:
	if v is int or v is float:
		return v > 0
	if v is String:
		return v != "" and v != "0"
	return v != null

func _process(delta: float) -> void:
	var targeting = get_parent()
	var active: bool = targeting != null and targeting.get("is_targeting") == true \
		and is_electric(targeting.get("current_ability") if targeting.get("current_ability") is Dictionary else {})
	if not active:
		if _shown:
			_clear()
		return
	_recompute_left -= delta
	if _recompute_left > 0.0 and _shown:
		return
	_recompute_left = RECOMPUTE_SEC
	_recompute(targeting)

func _clear() -> void:
	_tiles.clear()
	_rings.clear()
	_shown = false
	queue_redraw()

func _game() -> Node:
	var g = get_tree().current_scene if is_inside_tree() else null
	return g if g != null and "surface_manager" in g else null

func _recompute(targeting) -> void:
	_tiles.clear()
	_rings.clear()
	_shown = true
	var game := _game()
	if game == null or game.surface_manager == null:
		queue_redraw()
		return
	var caster = targeting.get_parent()
	var origin: Vector2 = targeting._origin_pos() if targeting.has_method("_origin_pos") else caster.global_position
	var seen := {}
	for c in _hit_characters(targeting, game, caster, origin):
		var start := GridManager.world_to_map(_pos_of(c, caster, origin))
		if seen.has(start):
			continue
		var region: Dictionary = game.surface_manager.electrify_region(start, BFS_CAP)
		for t in region["tiles"]:
			if not seen.has(t):
				seen[t] = true
				_tiles.append(t)
	# Who stands in the flood (the caster too: casting from the puddle hurts).
	for c in game.characters_in_scene:
		if not _counts(c, game):
			continue
		var p := _pos_of(c, caster, origin)
		if seen.has(GridManager.world_to_map(p)):
			_rings.append({"pos": p, "party": c in game.party_chars})
	# Above the reticle: the world hover tooltip opens below-right of the
	# cursor (on the UI layer) and would cover a label placed there.
	_label_pos = targeting.target_position + Vector2(18, -28)
	queue_redraw()

## Where a character will be for this cast: the caster casts from the planned
## node when aiming a paused plan (AbilityTargeting's origin), others stay put.
func _pos_of(c, caster, origin: Vector2) -> Vector2:
	return origin if c == caster else c.global_position

func _counts(c, game) -> bool:
	if not is_instance_valid(c) or (c.has_method("is_alive") and not c.is_alive()):
		return false
	# No ring on someone the player can't see (Game.hidden_from_party, the
	# pickers' rule: out of sight, or not drawn in this view layer).
	if game.has_method("hidden_from_party"):
		return not game.hidden_from_party(c)
	return not game.has_method("is_seen_by_party") or game.is_seen_by_party(c)

## The characters the current reticle would hit, with the shape rules of
## ProceduralCharacter._find_targets_in_area, read off the live indicators so
## any range clamp or projectile stop is already applied.
func _hit_characters(targeting, game, caster, origin: Vector2) -> Array:
	var out: Array = []
	# The shape by name (AbilityTargeting.start_targeting maps the same string
	# onto its TargetShape), which spares this child a preload of its parent.
	var shape := str(targeting.current_ability.get("target_shape", "none"))
	if shape == "characters":
		for t in targeting.selected_targets:
			if _counts(t, game):
				out.append(t)
		return out
	var self_centred: bool = targeting.lock_to_caster
	for c in game.characters_in_scene:
		if not _counts(c, game):
			continue
		var p := _pos_of(c, caster, origin)
		var hit := false
		if shape == "circle":
			if self_centred and c == caster:
				continue
			hit = p.distance_to(targeting.circle_indicator.global_position) <= targeting.circle_radius
		elif shape == "rectangle":
			var half: Vector2 = targeting.rectangle_size / 2.0
			var d: Vector2 = p - targeting.rectangle_indicator.global_position
			hit = absf(d.x) <= half.x and absf(d.y) <= half.y
		elif shape == "line":
			if c == caster:
				continue
			var drawer = targeting.line_indicator.get_child(0) if targeting.line_indicator.get_child_count() > 0 else null
			var seg: Vector2 = drawer.line_end if drawer != null and "line_end" in drawer else targeting.target_position - origin
			if seg.length_squared() < 1.0:
				continue
			var half_w: float = targeting.line_width / 2.0 if targeting.line_width > 0.0 else 15.0
			var t := clampf((p - origin).dot(seg) / seg.length_squared(), 0.0, 1.0)
			hit = p.distance_to(origin + seg * t) <= half_w
		elif shape == "cone":
			if c == caster:
				continue
			var to_c: Vector2 = p - origin
			if to_c.length() <= targeting.cone_radius:
				var axis: Vector2 = (targeting.target_position - origin).normalized()
				hit = absf(axis.angle_to(to_c.normalized())) <= deg_to_rad(targeting.cone_angle) / 2.0
		if hit:
			out.append(c)
	return out

func _draw() -> void:
	if not _shown:
		return
	var ts := float(GridManager.TILE_SIZE)
	for t in _tiles:
		var r := Rect2(Vector2(t) * ts, Vector2(ts, ts))
		draw_rect(r, TILE_FILL, true)
		draw_rect(r, TILE_EDGE, false, 1.5)
	for ring in _rings:
		draw_arc(ring["pos"], RING_RADIUS, 0.0, TAU, 32, RING_PARTY if ring["party"] else RING_OTHER, 2.5, true)
	if _tiles.size() > 1:
		var font := ThemeDB.fallback_font
		var text := "Current spreads through %d tiles" % _tiles.size()
		draw_string_outline(font, _label_pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_SIZE, 4, Color.BLACK)
		draw_string(font, _label_pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_SIZE, TILE_EDGE)
