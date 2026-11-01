# =====================
# vfx/StealthOverlay.gd - World-space stealth-mode readouts, drawn only while
# Game.stealth_mode is on (the C key). Game._ready adds it as Game's child.
#
#   In-view eyes: an eye over each party member that an onlooker the party
#   can see has in view right now. The test is the AI's own (ai.gd
#   has_in_view: a held target while it isn't occluded, anyone else as target
#   acquisition sees them), the same rules the NPC acts on, so it is exact on
#   battlements and roofs where the drawn cones are only an approximation.
#   Onlookers the party can't see, or that the current view slice hides,
#   never reveal themselves this way.
#
#   Noise rings: a faint expanding ring for each sound a party member makes
#   (HearingManager.sound_emitted: footsteps, swings, casts...), sized to how
#   far it carries in the open to normal hearing (HearingManager.audible_radius,
#   emit's own reach), with a fainter inner ring for how far it carries through
#   one wall. Coloured Quiet / Normal / Loud.
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
## A member newly in an onlooker's view gets a quiet cue (the eye alone is
## easy to miss with the camera elsewhere), at most this often...
const EYE_CUE_COOLDOWN := 1.5
## ...and none this long after a toggle (it has its own sound) or a map load
## (arriving is not being spotted; sight settles over the first sweeps).
const EYE_CUE_QUIET_SEC := 1.5

const RING_LIFE_SEC := 0.7
const RING_GROW_FRAC := 0.45      # reaches full size this far into its life, then fades
const RING_PEAK_ALPHA := 0.35
const RING_WIDTH := 1.5
const RING_THROTTLE_SEC := 0.3    # per source; loud sounds always get a ring
const RING_MAX := 24
const RING_TIER_COLORS := {
	"Quiet": Color(0.55, 0.85, 1.0),
	"Normal": Color(1.0, 0.9, 0.45),
	"Loud": Color(1.0, 0.5, 0.35),
}

var _game: Node = null
var _in_view: Array = []   # party members an onlooker has in view
var _eye_left: float = 0.0
var _eye_cue_quiet_left: float = 0.0
var _sync_left: float = 0.0
var _rings: Array = []           # {pos, r, r_wall, age, col}, oldest first
var _last_ring_at: Dictionary = {}   # source -> ticks (s) of its last ring

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
	HearingManager.sound_emitted.connect(_on_sound_emitted)

func _stealth_on() -> bool:
	return _game != null and is_instance_valid(_game) and "stealth_mode" in _game and _game.stealth_mode

func _process(delta: float) -> void:
	if not _rings.is_empty():
		for ring in _rings:
			ring["age"] += delta
		_rings = _rings.filter(func(ring): return ring["age"] < RING_LIFE_SEC)
		queue_redraw()
	if not _stealth_on():
		return
	_eye_cue_quiet_left -= delta
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
	_eye_cue_quiet_left = EYE_CUE_QUIET_SEC
	_sync_left = CONE_SYNC_SEC   # set_stealth_mode has just synced the cones
	if not active:
		_in_view.clear()
		_rings.clear()
	queue_redraw()

func _on_map_loaded(_map_id: String) -> void:
	_in_view.clear()
	_rings.clear()
	_last_ring_at.clear()
	_eye_left = 0.0
	_eye_cue_quiet_left = EYE_CUE_QUIET_SEC
	_sync_left = 0.0   # the new map's NPCs need their elevated-surface cones
	queue_redraw()

# ---------------------------------------------------------------------------
# In-view eyes
# ---------------------------------------------------------------------------

func _refresh_in_view() -> void:
	var had_any := not _in_view.is_empty()
	var before: Array = _in_view.duplicate()
	_in_view.clear()
	var newly_seen := false
	for pc in _game.party_chars:
		if not is_instance_valid(pc) or not pc.is_alive() or pc.on_world_map:
			continue
		# Not drawn (a member on the high layer in ground view): no eye over
		# empty ground.
		if not pc.visible:
			continue
		if is_in_view_of_onlooker(pc):
			_in_view.append(pc)
			if not pc in before:
				newly_seen = true
	if newly_seen and _eye_cue_quiet_left <= 0.0:
		SfxManager.play_ui_throttled("stealth_in_view", EYE_CUE_COOLDOWN, "alert_search", Vector2(0.97, 1.03), -14.0)
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
		# Never reveal an onlooker the party can't see. `visible` too: in
		# ground view a roof-walker the party sees is still hidden.
		if not npc.visible or not _game.is_seen_by_party(npc):
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
	for ring in _rings:
		_draw_ring(ring)
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

# ---------------------------------------------------------------------------
# Noise rings
# ---------------------------------------------------------------------------

func _on_sound_emitted(world_pos: Vector2, loudness: float, source) -> void:
	if not _stealth_on() or loudness <= 0.0:
		return
	if not (source is ProceduralCharacter) or not (source in _game.party_chars):
		return
	# Nobody sneaks on the world map and the badge hides there; so do the rings.
	if source.on_world_map:
		return
	# Footsteps come ~2-3 a second; one ring per source per RING_THROTTLE_SEC
	# keeps them from stacking. A loud sound (gunshot) always shows.
	var now := Time.get_ticks_msec() / 1000.0
	if loudness < HearingManager.LOUD_SOUND_THRESHOLD and now - float(_last_ring_at.get(source, -1000.0)) < RING_THROTTLE_SEC:
		return
	_last_ring_at[source] = now
	_rings.append({
		"pos": world_pos,
		"r": HearingManager.audible_radius(loudness),
		"r_wall": HearingManager.audible_radius(loudness, 1.0, 1),
		"age": 0.0,
		"col": RING_TIER_COLORS.get(HearingManager.loudness_tier(loudness), Color.WHITE),
	})
	if _rings.size() > RING_MAX:
		_rings.pop_front()
	queue_redraw()

## Rings currently shown, for tests: [{pos, r, r_wall, age, col}].
func get_rings() -> Array:
	return _rings

func _draw_ring(ring: Dictionary) -> void:
	var t: float = clampf(ring["age"] / RING_LIFE_SEC, 0.0, 1.0)
	var grow: float = 1.0 - pow(1.0 - minf(t / RING_GROW_FRAC, 1.0), 2.0)
	var r: float = ring["r"] * grow
	if r < 1.0:
		return
	var col: Color = ring["col"]
	col.a = RING_PEAK_ALPHA * (1.0 - t)
	var c := to_local(ring["pos"])
	draw_arc(c, r, 0.0, TAU, 48, col, RING_WIDTH, true)
	# How far the same sound carries through a wall.
	col.a *= 0.5
	draw_arc(c, float(ring["r_wall"]) * grow, 0.0, TAU, 32, col, RING_WIDTH, true)
