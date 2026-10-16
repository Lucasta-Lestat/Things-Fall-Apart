# =====================
# UI/TargetIntentOverlay.gd - While the game is paused (planning), draws a
# faint line from each NPC the party can see to the character it is after:
# red toward a party member, amber toward another NPC (drawn only when the
# party sees that one too). Solid while the NPC has eyes on its target, dashed
# while it chases where it last saw it (ai.is_target_in_sight). Polls
# ai.current_target, so every way a target is set or cleared shows. Game._ready
# adds it as a world-space child of Game.
#
# Complements UI/OffscreenThreatIndicators.gd (edge arrows for hostiles off
# the screen): this says WHOM each visible NPC is after, on screen.
# =====================

extends Node2D

const COLOR_TO_PARTY := Color(1.0, 0.25, 0.2, 0.5)
const COLOR_TO_OTHER := Color(1.0, 0.75, 0.3, 0.35)
const LINE_WIDTH := 1.5
const DASH := 8.0
const ARROW := 7.0

var game: Node = null
var _drawn: bool = false

func _ready() -> void:
	name = "TargetIntentOverlay"
	# Planning happens while paused, so keep redrawing then.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Above bodies and floor effects, below condition icons (100) and the
	# alertness '?' / '!' (110).
	z_index = 90
	if game == null:
		game = get_parent()

func _process(_delta: float) -> void:
	# One extra redraw after unpausing clears the lines.
	if PauseManager.is_paused or _drawn:
		queue_redraw()

## The lines to draw now: [{npc, target, from, to, color, seen}]. Empty unless
## paused. Never reveals an NPC the party can't see.
func collect_lines() -> Array:
	var out: Array = []
	if game == null or not is_instance_valid(game) or not PauseManager.is_paused:
		return out
	if game.get("downtime_mode_active") == true:
		return out
	# Nobody fights or sneaks on the world map: no lines there.
	var map_data = game.get("current_map_data")
	if map_data is Dictionary and map_data.get("is_world_map", false):
		return out
	for npc in game.characters_in_scene:
		if not is_instance_valid(npc) or not npc.is_alive() or npc.is_party_member():
			continue
		# visible: in ground view a roof-walker the party sees is still hidden.
		if not npc.AI_enabled or not npc.visible or not game.is_seen_by_party(npc):
			continue
		var ai = npc.get_node_or_null("AI")
		if ai == null:
			continue
		var t = ai.current_target
		if t == null or not is_instance_valid(t) or not t.is_alive():
			continue
		var to_party: bool = t.is_party_member()
		if not to_party and (not t.visible or not game.is_seen_by_party(t)):
			continue
		var a: Vector2 = npc.global_position
		var b: Vector2 = t.global_position
		var dist: float = a.distance_to(b)
		if dist < 1.0:
			continue
		var dir: Vector2 = (b - a) / dist
		# Start and end at the bodies' edges; in melee, where the bodies all
		# but touch, keep at least the middle 30% so the pairing still shows.
		var start_off: float = minf(npc.collision_radius + 4.0, dist * 0.35)
		var end_off: float = minf(t.collision_radius + 6.0, dist * 0.35)
		out.append({
			"npc": npc,
			"target": t,
			"from": a + dir * start_off,
			"to": b - dir * end_off,
			"color": COLOR_TO_PARTY if to_party else COLOR_TO_OTHER,
			"seen": ai.is_target_in_sight() if ai.has_method("is_target_in_sight") else true,
		})
	return out

func _draw() -> void:
	var lines: Array = collect_lines()
	for l in lines:
		var from: Vector2 = l["from"]
		var to: Vector2 = l["to"]
		var color: Color = l["color"]
		if l["seen"]:
			draw_line(from, to, color, LINE_WIDTH, true)
		else:
			draw_dashed_line(from, to, color, LINE_WIDTH, DASH)
		var dir: Vector2 = (to - from).normalized()
		var side: Vector2 = Vector2(-dir.y, dir.x) * ARROW * 0.5
		draw_colored_polygon(PackedVector2Array([to, to - dir * ARROW + side, to - dir * ARROW - side]), color)
	_drawn = not lines.is_empty()
