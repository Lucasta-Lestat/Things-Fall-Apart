extends Control
## Edge-of-screen arrows for hostile characters the party can SEE but the
## camera can't. Zoomed in on one fighter, a spearman closing from off-screen
## is invisible right up until he kills them; this pins a red chevron to the
## screen edge pointing at him.
##
## The "can see" answer is Game.hostiles_in_party_los(), the same LOS pass
## that decides whether NPC sprites render, so an arrow never betrays
## something the party hasn't actually seen. Display-only (mouse_filter
## IGNORE): world clicks are polled from Input, so a clickable arrow would
## also issue a move order underneath it.

## Arrow centre sits this far inside the screen edge.
const EDGE_INSET: float = 34.0
## A character whose centre is at least this far inside the edge counts as
## on-screen (no arrow) — a half-visible body at the border is visible enough.
const ONSCREEN_MARGIN: float = 12.0
## Hostile-set refresh rate. Positions are re-projected every frame (the
## camera pans and zooms while paused); hostility only needs a few Hz.
const REFRESH_INTERVAL: float = 0.1
## Arrows closer than this on screen merge into one with a count badge.
const MERGE_DIST: float = 46.0
## World distance to the nearest party member: at NEAR_DIST and closer the
## arrow is full size and opacity, fading down to the minimum at FAR_DIST.
const NEAR_DIST: float = 400.0
const FAR_DIST: float = 1800.0
const SIZE_MIN: float = 14.0
const SIZE_MAX: float = 22.0
const ALPHA_MIN: float = 0.6

## A hostile out of the party's sight for this long is new again when it
## reappears off-screen. Long enough that one ducking behind a pillar mid-fight
## doesn't re-ping.
const FORGET_AFTER: float = 6.0
## No pings this soon after a map loads: whatever is in view on arrival was
## not "spotted", the party just walked in on it.
const MAP_LOAD_GRACE: float = 1.5

const COLOR_FILL := Color(0.88, 0.12, 0.10)
const COLOR_OUTLINE := Color(0.06, 0.0, 0.0, 0.9)
const COLOR_BADGE_TEXT := Color(1.0, 0.95, 0.9)

var game: Node = null

var _hostiles: Array = []
var _refresh_accum: float = REFRESH_INTERVAL
var _time: float = 0.0
## [{pos: Vector2, dir: Vector2, urgency: float, engaged: bool, count: int}]
var _arrows: Array = []
## instance id -> _time the hostile was last in party sight. Decides which
## off-screen arrows are new threats that earn a ping.
var _last_seen: Dictionary = {}
var _quiet_until: float = MAP_LOAD_GRACE


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The camera pans and zooms during tactical pause — that is exactly when
	# the player is surveying, so the arrows must keep tracking.
	process_mode = Node.PROCESS_MODE_ALWAYS
	if game != null and is_instance_valid(game) and game.has_signal("map_loaded"):
		game.connect("map_loaded", _on_map_loaded)


func _on_map_loaded(_map_id: String) -> void:
	_quiet_until = _time + MAP_LOAD_GRACE


func _process(delta: float) -> void:
	_time += delta
	_refresh_accum += delta
	if _refresh_accum >= REFRESH_INTERVAL:
		_refresh_accum = 0.0
		_hostiles = []
		if game != null and is_instance_valid(game) and game.has_method("hostiles_in_party_los"):
			_hostiles = game.hostiles_in_party_los()
		_ping_new_threats()
	var had_arrows: bool = not _arrows.is_empty()
	_rebuild_arrows()
	if had_arrows or not _arrows.is_empty():
		queue_redraw()


func _rebuild_arrows() -> void:
	_arrows.clear()
	if _hostiles.is_empty():
		return
	var vp := get_viewport()
	if vp == null:
		return
	var xf: Transform2D = vp.get_canvas_transform()
	# The viewport rect, not this Control's size: the Control's layout isn't
	# guaranteed to have run under a bare CanvasLayer, and the canvas
	# transform projects into exactly this space.
	var screen: Rect2 = get_viewport_rect()
	var on_screen: Rect2 = screen.grow(-ONSCREEN_MARGIN)
	var edge: Rect2 = screen.grow(-EDGE_INSET)
	var center: Vector2 = screen.get_center()
	var half: Vector2 = edge.size * 0.5

	var raw: Array = []
	for npc in _hostiles:
		if not is_instance_valid(npc):
			continue
		var sp: Vector2 = xf * npc.global_position
		if on_screen.has_point(sp):
			continue
		var v: Vector2 = sp - center
		if v.length_squared() < 0.0001:
			continue
		# Ray from screen centre toward the character, clipped to the inset
		# rect — the arrow slides along the edge as the bearing changes.
		var t: float = INF
		if absf(v.x) > 0.0001:
			t = minf(t, half.x / absf(v.x))
		if absf(v.y) > 0.0001:
			t = minf(t, half.y / absf(v.y))
		var pos: Vector2 = center + v * minf(t, 1.0)
		raw.append({
			"pos": pos,
			"dir": v.normalized(),
			"urgency": _urgency(npc),
			"engaged": _is_engaging_party(npc),
			"count": 1,
		})

	# Most urgent first, so a merged arrow keeps the nearest threat's bearing.
	raw.sort_custom(func(a, b): return a.urgency > b.urgency)
	for a in raw:
		var merged: bool = false
		for g in _arrows:
			if g.pos.distance_to(a.pos) < MERGE_DIST:
				g.count += 1
				g.engaged = g.engaged or a.engaged
				merged = true
				break
		if not merged:
			_arrows.append(a)


## A quiet radar ping when a hostile the party hasn't had in sight lately
## shows up off-screen: the arrow alone is easy to miss while zoomed in on a
## fight. One the player already saw on screen and then panned away from
## isn't new.
func _ping_new_threats() -> void:
	var fresh_off_screen: bool = false
	var quiet: bool = _time < _quiet_until
	var vp := get_viewport()
	var xf: Transform2D = vp.get_canvas_transform() if vp != null else Transform2D.IDENTITY
	var on_screen: Rect2 = get_viewport_rect().grow(-ONSCREEN_MARGIN)
	for npc in _hostiles:
		if not is_instance_valid(npc):
			continue
		var id: int = npc.get_instance_id()
		var seen_at: float = float(_last_seen.get(id, -INF))
		var fresh: bool = _time - seen_at > FORGET_AFTER
		if fresh and not quiet and not on_screen.has_point(xf * npc.global_position):
			fresh_off_screen = true
		_last_seen[id] = _time
	for key in _last_seen.keys():
		if _time - float(_last_seen[key]) > FORGET_AFTER:
			_last_seen.erase(key)
	if fresh_off_screen:
		SfxManager.play_ui_throttled("threat", 2.0, "radar_ping", Vector2(0.97, 1.03), -14.0)


## 1.0 within NEAR_DIST of any living party member, 0.0 at FAR_DIST or beyond.
func _urgency(npc) -> float:
	var best: float = INF
	for pc in game.party_chars:
		if not is_instance_valid(pc) or not pc.is_alive():
			continue
		best = minf(best, npc.global_position.distance_to(pc.global_position))
	if best == INF:
		return 0.0
	return 1.0 - clampf((best - NEAR_DIST) / (FAR_DIST - NEAR_DIST), 0.0, 1.0)


## True when this hostile has a party member as its combat target — the
## "about to be attacked" case, which gets the pulsing ring.
func _is_engaging_party(npc) -> bool:
	var ai_node = npc.get_node_or_null("AI")
	if ai_node == null or not ("current_target" in ai_node):
		return false
	var target = ai_node.current_target
	return target != null and is_instance_valid(target) and target in game.party_chars


func _draw() -> void:
	var font: Font = ThemeDB.fallback_font
	for a in _arrows:
		var u: float = a.urgency
		var s: float = lerpf(SIZE_MIN, SIZE_MAX, u)
		var alpha: float = lerpf(ALPHA_MIN, 1.0, u)
		var dir: Vector2 = a.dir
		var perp := Vector2(-dir.y, dir.x)
		var pos: Vector2 = a.pos

		if a.engaged:
			var pulse: float = 0.5 + 0.5 * sin(_time * TAU * 1.6)
			var ring := COLOR_FILL
			ring.a = 0.25 + 0.35 * pulse
			draw_circle(pos, s * (1.25 + 0.25 * pulse), ring, false, 3.0, true)

		# Chevron: tip toward the threat, notched tail.
		var tip: Vector2 = pos + dir * s
		var left: Vector2 = pos - dir * s * 0.6 + perp * s * 0.8
		var notch: Vector2 = pos - dir * s * 0.15
		var right: Vector2 = pos - dir * s * 0.6 - perp * s * 0.8
		var pts := PackedVector2Array([tip, left, notch, right])
		var outline := COLOR_OUTLINE
		outline.a *= alpha
		var fill := COLOR_FILL
		fill.a = alpha
		draw_colored_polygon(pts, fill)
		pts.append(tip)
		draw_polyline(pts, outline, 2.0, true)

		if a.count > 1:
			var badge_pos: Vector2 = pos - dir * s * 1.45
			draw_circle(badge_pos, 9.0, outline)
			var text: String = str(a.count)
			var fs: int = 13
			var tw: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			draw_string(font, badge_pos + Vector2(-tw * 0.5, fs * 0.38), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, COLOR_BADGE_TEXT)
