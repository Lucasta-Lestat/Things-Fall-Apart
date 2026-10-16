# =====================
# vfx/StealthOverlay.gd - World-space stealth-mode readouts, drawn only while
# Game.stealth_mode is on (the C key). Game._ready adds it as Game's child.
#
#   In-view eyes: an eye over each party member that an onlooker the party
#   can see has in view right now. The test is the AI's own (ai.gd
#   has_in_view: a held target while it isn't occluded, anyone else as target
#   acquisition sees them), the same rules the NPC acts on, so it is exact on
#   battlements and roofs where the drawn cones are only an approximation.
#   Onlookers the party can't see never reveal themselves this way.
#
# It also keeps the NPCs' elevated-surface cones in step with their red ones
# (Game.sync_npc_elevated_cones), creating them for NPCs spawned later.
# =====================

extends Node2D

const EYE_REFRESH_SEC := 0.15
const CONE_SYNC_SEC := 0.5
const EYE_OFFSET := Vector2(0, -44)   # above the head, clear of the body
const EYE_HALF_W := 9.0
const EYE_HALF_H := 5.0
const EYE_COLOR := Color(1.0, 0.4, 0.3, 0.95)

var _game: Node = null
var _in_view: Array = []   # party members an onlooker has in view
var _eye_left: float = 0.0
var _sync_left: float = 0.0

func _ready() -> void:
	name = "StealthOverlay"
	# Planning happens paused, so the eyes must stay current then too.
	process_mode = Node.PROCESS_MODE_ALWAYS
	z_index = 60
	# The sight cones are lights; they would tint the markers they cross.
	light_mask = 0
	_game = get_parent()
	if _game and _game.has_signal("stealth_mode_changed"):
		_game.stealth_mode_changed.connect(_on_stealth_mode_changed)
	if _game and _game.has_signal("map_loaded"):
		_game.map_loaded.connect(_on_map_loaded)

func _stealth_on() -> bool:
	return _game != null and is_instance_valid(_game) and "stealth_mode" in _game and _game.stealth_mode

func _process(delta: float) -> void:
	if not _stealth_on():
		return
	_eye_left -= delta
	if _eye_left <= 0.0:
		_eye_left = EYE_REFRESH_SEC
		_refresh_in_view()
	_sync_left -= delta
	if _sync_left <= 0.0:
		_sync_left = CONE_SYNC_SEC
		if _game.has_method("sync_npc_elevated_cones"):
			_game.sync_npc_elevated_cones()
	if not _in_view.is_empty():
		queue_redraw()   # follow the characters between refreshes

func _on_stealth_mode_changed(active: bool) -> void:
	_eye_left = 0.0
	_sync_left = CONE_SYNC_SEC   # set_stealth_mode has just synced the cones
	if not active:
		_in_view.clear()
	queue_redraw()

func _on_map_loaded(_map_id: String) -> void:
	_in_view.clear()
	_eye_left = 0.0
	_sync_left = 0.0   # the new map's NPCs need their elevated-surface cones
	queue_redraw()

# ---------------------------------------------------------------------------
# In-view eyes
# ---------------------------------------------------------------------------

func _refresh_in_view() -> void:
	var had_any := not _in_view.is_empty()
	_in_view.clear()
	for pc in _game.party_chars:
		if not is_instance_valid(pc) or not pc.is_alive() or pc.on_world_map:
			continue
		if is_in_view_of_onlooker(pc):
			_in_view.append(pc)
	if had_any or not _in_view.is_empty():
		queue_redraw()

## True when an onlooker the party can currently see has `pc` in view, by the
## AI's own rules (ai.has_in_view).
func is_in_view_of_onlooker(pc) -> bool:
	for npc in _game.characters_in_scene:
		if not is_instance_valid(npc) or npc in _game.party_chars:
			continue
		if not npc.is_alive() or not ("AI_enabled" in npc and npc.AI_enabled):
			continue
		var cm = npc.get_node_or_null("ConditionManager")
		if cm and cm.has_condition("unconscious"):
			continue
		# Never reveal an onlooker the party can't see.
		if not _game.is_seen_by_party(npc):
			continue
		var ai = npc.get_node_or_null("AI")
		if ai == null:
			continue
		if ai.has_method("has_in_view"):
			if ai.has_in_view(pc):
				return true
		elif ai.is_in_line_of_sight(pc.global_position, pc.get_elevation()):
			return true
	return false

func is_marked_in_view(pc) -> bool:
	return pc in _in_view

func _draw() -> void:
	for pc in _in_view:
		if is_instance_valid(pc):
			_draw_eye(to_local(pc.global_position) + EYE_OFFSET)

# An almond eye: parabolic lids, dark fill, a black underlay for contrast.
func _draw_eye(c: Vector2) -> void:
	var pts := PackedVector2Array()
	for i in 9:   # upper lid, left to right
		var x := lerpf(-EYE_HALF_W, EYE_HALF_W, float(i) / 8.0)
		pts.append(c + Vector2(x, -EYE_HALF_H * (1.0 - pow(x / EYE_HALF_W, 2.0))))
	for i in range(1, 8):   # lower lid, right to left
		var x := lerpf(EYE_HALF_W, -EYE_HALF_W, float(i) / 8.0)
		pts.append(c + Vector2(x, EYE_HALF_H * (1.0 - pow(x / EYE_HALF_W, 2.0))))
	draw_colored_polygon(pts, Color(0.0, 0.0, 0.0, 0.55))
	var outline := pts.duplicate()
	outline.append(pts[0])
	draw_polyline(outline, Color(0.0, 0.0, 0.0, 0.9), 3.0, true)
	draw_polyline(outline, EYE_COLOR, 1.5, true)
	draw_circle(c, 3.0, Color(0.0, 0.0, 0.0, 0.9))
	draw_circle(c, 2.2, EYE_COLOR)
