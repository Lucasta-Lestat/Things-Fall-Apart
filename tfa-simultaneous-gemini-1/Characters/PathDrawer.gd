# PathDrawer.gd
# Renders a character's TacticalPath: a smoothed, direction-flowing ribbon on the
# ground plus action-node markers, rotation arrows and designation leashes.
#
# Draws across TWO layers, because the path and its markers want opposite answers
# to "does this go over the character?":
#   * this node (Z_GROUND) — the route itself. Painted UNDER characters so bodies
#     stand on their path instead of being sliced in half by it.
#   * _node_layer (Z_MARKERS) — action-node discs and their icons. These are
#     read-the-icon UI, so they stay on top of everything.
extends Node2D
class_name PathDrawer

var tactical_path: TacticalPath = null
var character: ProceduralCharacter = null

# Drawing state (set by PathInputHandler)
var is_drawing_path: bool = false
var is_drawing_rotation: bool = false
var rotation_start: Vector2 = Vector2.ZERO
var rotation_current: Vector2 = Vector2.ZERO

# --- Layers -----------------------------------------------------------------
# Above floors (-4) and structures (-3), below the character root (5).
const Z_GROUND := 2
# Above characters and their gear; icons must stay legible.
const Z_MARKERS := 45

# --- Route ribbon -----------------------------------------------------------
# Two passes: a dark shadow stroke, then a bright core on top. A single flat line
# disappears over pale stone and reads as noise over dark ground; the pair holds
# contrast on both.
const PATH_SHADOW_COLOR := Color(0.02, 0.03, 0.06, 0.5)
const PATH_CORE_COLOR := Color(0.93, 0.96, 1.0, 0.85)
const PATH_SHADOW_WIDTH := 5.0
const PATH_CORE_WIDTH := 2.0
# While the drag is still live the route is a proposal, not a plan — fade it.
const DRAWING_ALPHA := 0.55

# Direction chevrons drifting toward the destination.
const FLOW_COLOR := Color(1.0, 1.0, 1.0, 0.55)
const FLOW_SPACING := 34.0     # px between chevrons along the arc
const FLOW_SPEED := 26.0       # px/sec of drift
const FLOW_SIZE := 4.5
const FLOW_WIDTH := 1.6

# Destination pip at the end of the route.
const DEST_COLOR := Color(0.93, 0.96, 1.0, 0.8)
const DEST_RADIUS := 5.0

# Chaikin corner-cutting passes. Waypoints are sampled off a mouse drag every 8px
# (TacticalPath.MIN_WAYPOINT_DISTANCE), so the raw polyline is visibly jittery;
# two passes turn it into a clean stroke without drifting off the walkable route.
const SMOOTH_ITERATIONS := 2

# --- Action nodes -----------------------------------------------------------
const NODE_RADIUS := 14.0
const NODE_FILL_COLOR := Color(0.05, 0.06, 0.09, 0.8)
const NODE_OUTLINE_COLOR := Color(0.95, 0.97, 1.0, 0.92)
const NODE_OUTLINE_WIDTH := 2.0
const NODE_SHADOW_COLOR := Color(0.0, 0.0, 0.0, 0.35)
const ICON_SIZE := Vector2(18, 18)
# An unassigned node is a placement handle, not information. At full ring weight
# a long path turns into a chain of identical circles — the single biggest
# contributor to "messy". Drawn small and dim so assigned nodes stand out.
const EMPTY_NODE_RADIUS := 4.0
const EMPTY_NODE_COLOR := Color(0.95, 0.97, 1.0, 0.45)

# Queued dash preview. Same amber the live AimLine uses while you're aiming the
# dash, so the node's stored plan and the thing you just dragged read as one
# object rather than two unrelated overlays.
const DASH_COLOR := Color(1.0, 0.85, 0.3, 0.6)

const ARROW_COLOR := Color(0.8, 0.8, 1.0, 0.8)
const ARROW_DRAWING_COLOR := Color(1.0, 1.0, 0.5, 0.6)
const DESIGNATION_COLOR := Color(0.95, 0.35, 0.3, 0.65)
const ARROW_LENGTH := 30.0
const ARROW_WIDTH := 2.0
const ARROWHEAD_SIZE := 8.0

var _node_layer: _NodeMarkerLayer = null
var _flow_phase: float = 0.0
# Separate from _flow_phase: a dash's chevrons run far faster than a walk's, and
# sharing one accumulator would force them to the same cadence.
var _dash_phase: float = 0.0
var _was_live: bool = false

# Smoothed-route cache. Rebuilt only when the waypoint array actually changes —
# during execution the waypoints are static and only the character moves along
# them, so the expensive part runs once per edit rather than once per frame.
var _smooth_cache: PackedVector2Array = PackedVector2Array()
var _smooth_key: Array = []

func _ready() -> void:
	top_level = true  # Don't inherit character's transform (rotation)
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Absolute, not parent-relative: this node is a CHILD of the character, so a
	# relative z would be added to the character's own 5 and land back on top of it.
	z_as_relative = false
	z_index = Z_GROUND

	_node_layer = _NodeMarkerLayer.new()
	_node_layer.name = "NodeMarkers"
	_node_layer.drawer = self
	_node_layer.top_level = true
	_node_layer.z_as_relative = false
	_node_layer.z_index = Z_MARKERS
	add_child(_node_layer)

func _process(delta: float) -> void:
	# Redraw when drawing in progress, executing, or when a visible path exists.
	# _was_live carries one extra frame so the last cleared path actually erases.
	var live := is_drawing_path or is_drawing_rotation \
		or (tactical_path != null and (tactical_path.is_executing or not tactical_path.is_empty()))
	if live:
		_flow_phase = fposmod(_flow_phase + FLOW_SPEED * delta, FLOW_SPACING)
		_dash_phase = fposmod(_dash_phase + AimLine.FLOW_SPEED * delta, AimLine.FLOW_SPACING)
	if live or _was_live:
		queue_redraw()
		if _node_layer:
			_node_layer.queue_redraw()
	_was_live = live

func _draw() -> void:
	if tactical_path == null:
		return

	var route := _visible_route()
	if route.size() >= 2:
		var fade := DRAWING_ALPHA if is_drawing_path else 1.0
		_draw_ribbon(route, fade)

	# Per-node ground decoration (dash aim lines, designation leashes, facing
	# arrows). The node disc itself belongs to _node_layer.
	for node in _visible_nodes():
		_draw_node_ground(node)

	# Draw in-progress rotation arrow
	if is_drawing_rotation:
		var angle = (rotation_current - rotation_start).angle()
		_draw_arrow(rotation_start, angle, ARROW_DRAWING_COLOR)


# ===== ROUTE =====

## The polyline to paint this frame: the whole smoothed route while planning,
## or the part still ahead of the character while executing.
func _visible_route() -> PackedVector2Array:
	var smoothed := _smoothed_route()
	if smoothed.size() < 2:
		return smoothed
	if tactical_path.is_executing and character:
		return _route_ahead_of(smoothed, character.global_position)
	return smoothed

## Chaikin-smoothed copy of the raw waypoints, with cumulative arc lengths.
func _smoothed_route() -> PackedVector2Array:
	var pts := tactical_path.waypoints
	# Count plus three samples. TacticalPath.set_waypoints can swap the array
	# wholesale (A* re-route), so count alone isn't enough to notice an edit.
	var n := pts.size()
	var key := [n,
		pts[0] if n > 0 else Vector2.ZERO,
		pts[n / 2] if n > 0 else Vector2.ZERO,
		pts[n - 1] if n > 0 else Vector2.ZERO]
	if key == _smooth_key:
		return _smooth_cache
	_smooth_key = key
	_smooth_cache = _chaikin(pts, SMOOTH_ITERATIONS)
	return _smooth_cache

static func _chaikin(pts: PackedVector2Array, iterations: int) -> PackedVector2Array:
	var cur := pts
	for _i in range(iterations):
		if cur.size() < 3:
			return cur
		var out := PackedVector2Array()
		out.append(cur[0])
		for j in range(cur.size() - 1):
			var a: Vector2 = cur[j]
			var b: Vector2 = cur[j + 1]
			out.append(a.lerp(b, 0.25))
			out.append(a.lerp(b, 0.75))
		out.append(cur[cur.size() - 1])
		cur = out
	return cur

## Slice `pts` at the point nearest `pos` and return everything after it. Trims
## the SMOOTHED route rather than re-smoothing a trimmed one, so the stroke stays
## stable instead of rippling as the character walks.
static func _route_ahead_of(pts: PackedVector2Array, pos: Vector2) -> PackedVector2Array:
	var best_i := 0
	var best_pt := pts[0]
	var best_d := INF
	for i in range(pts.size() - 1):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var seg := b - a
		var len_sq := seg.length_squared()
		var closest := a if len_sq < 0.001 else a + seg * clampf((pos - a).dot(seg) / len_sq, 0.0, 1.0)
		var d := pos.distance_squared_to(closest)
		if d < best_d:
			best_d = d
			best_i = i
			best_pt = closest

	var out := PackedVector2Array()
	out.append(best_pt)
	for i in range(best_i + 1, pts.size()):
		out.append(pts[i])
	return out

func _draw_ribbon(route: PackedVector2Array, fade: float) -> void:
	var shadow := PATH_SHADOW_COLOR
	var core := PATH_CORE_COLOR
	shadow.a *= fade
	core.a *= fade
	draw_polyline(route, shadow, PATH_SHADOW_WIDTH, true)
	draw_polyline(route, core, PATH_CORE_WIDTH, true)
	_draw_flow(route, fade)
	_draw_destination(route, fade)

## Chevrons drifting along the route toward the destination — the cheapest way to
## make a static line say which way the character is going.
func _draw_flow(route: PackedVector2Array, fade: float) -> void:
	var color := FLOW_COLOR
	color.a *= fade
	var total := 0.0
	for i in range(route.size() - 1):
		total += route[i].distance_to(route[i + 1])
	if total < FLOW_SPACING:
		return

	var travelled := 0.0
	var next_mark := _flow_phase
	for i in range(route.size() - 1):
		var a: Vector2 = route[i]
		var b: Vector2 = route[i + 1]
		var seg_len := a.distance_to(b)
		if seg_len < 0.001:
			continue
		var dir := (b - a) / seg_len
		while next_mark < travelled + seg_len:
			# Skip the very last chevron so it doesn't collide with the pip
			if next_mark > 0.0 and next_mark < total - DEST_RADIUS * 2.0:
				var p := a + dir * (next_mark - travelled)
				var back := -dir * FLOW_SIZE
				draw_line(p, p + back.rotated(0.6), color, FLOW_WIDTH, true)
				draw_line(p, p + back.rotated(-0.6), color, FLOW_WIDTH, true)
			next_mark += FLOW_SPACING
		travelled += seg_len

func _draw_destination(route: PackedVector2Array, fade: float) -> void:
	var color := DEST_COLOR
	color.a *= fade
	var end: Vector2 = route[route.size() - 1]
	draw_arc(end, DEST_RADIUS, 0, TAU, 20, color, 1.8, true)
	draw_circle(end, DEST_RADIUS * 0.35, color)


# ===== ACTION NODES =====

## The nodes worth drawing this frame — everything while planning, only what's
## still ahead of the character while executing.
func _visible_nodes() -> Array:
	if tactical_path == null:
		return []
	if not (tactical_path.is_executing and character):
		return tactical_path.action_nodes

	var out: Array = []
	var char_progress := _get_linear_progress(character.global_position)
	for node in tactical_path.action_nodes:
		var node_progress = tactical_path._get_node_linear_position(node)
		if node_progress > char_progress - 10.0:  # Small tolerance
			out.append(node)
	return out

## Ground-plane decoration for one node. Runs on THIS layer (under characters):
## these are long leashes and aim lines, and they'd cut across every body between
## here and the target if they sat with the icons.
func _draw_node_ground(node) -> void:
	var pos = node.world_position

	if node.has_action():
		# Dash aim line: persistent preview of where the queued dash will land,
		# clamped to the dash's range and truncated at the first wall.
		if node.action_data.has("dash_target"):
			var dash_target: Vector2 = node.action_data["dash_target"]
			var dash_max_range: float = node.action_data.get("dash_max_range", 0.0)
			var aim := AimLine.compute_aim(
				get_world_2d(), pos, dash_target, CollisionLayers.STRUCTURES, dash_max_range
			)
			var endpoint: Vector2 = aim["endpoint"]
			var blocked: bool = aim["blocked"]
			AimLine.draw_ribbon(self, pos, endpoint, DASH_COLOR, _dash_phase, blocked)

		# Designation leash: when the planned action names a character rather than
		# a spot, draw to where that character is right now. Redrawn every frame,
		# so it visibly tracks them as they move — the point of designating.
		var designated = _node_designated_target(node)
		if designated != null:
			draw_dashed_line(pos, designated.global_position, DESIGNATION_COLOR, 1.5, 6.0, true)
			draw_arc(designated.global_position, NODE_RADIUS * 0.9, 0, TAU, 24, DESIGNATION_COLOR, 1.5, true)

	# Independent of has_action(): a FACE node carries only a facing angle.
	if node.has_facing():
		_draw_arrow(pos, node.facing_angle - PI / 2, ARROW_COLOR)

## The node disc + icon. Called by _NodeMarkerLayer, which sits above characters.
func _draw_node_marker(canvas: CanvasItem, node) -> void:
	var pos = node.world_position

	if not node.has_action():
		canvas.draw_arc(pos, EMPTY_NODE_RADIUS, 0, TAU, 12, EMPTY_NODE_COLOR, 1.5, true)
		return

	# Soft drop shadow lifts the disc off busy terrain.
	canvas.draw_circle(pos + Vector2(0, 1.5), NODE_RADIUS + 1.0, NODE_SHADOW_COLOR)
	canvas.draw_circle(pos, NODE_RADIUS, NODE_FILL_COLOR)
	canvas.draw_arc(pos, NODE_RADIUS, 0, TAU, 32, NODE_OUTLINE_COLOR, NODE_OUTLINE_WIDTH, true)
	if node.icon_texture != null:
		canvas.draw_texture_rect(node.icon_texture, Rect2(pos - ICON_SIZE / 2.0, ICON_SIZE), false)


## The live character a planned action is aimed at, or null if it targets a spot.
## ATTACK_TARGET stores it under "target"; abilities under "target_anchor".
func _node_designated_target(node) -> Node2D:
	var designated = node.action_data.get("target", null)
	if designated == null:
		designated = node.action_data.get("target_anchor", null)
	if designated == null or not is_instance_valid(designated):
		return null
	return designated as Node2D

func _get_linear_progress(pos: Vector2) -> float:
	# Returns how far along the path (in pixels) the given position is
	var snap = tactical_path.find_nearest_point_on_path(pos)
	var dist = 0.0
	for i in range(snap.path_index):
		dist += tactical_path.waypoints[i].distance_to(tactical_path.waypoints[i + 1])
	if snap.path_index < tactical_path.waypoints.size() - 1:
		dist += tactical_path.waypoints[snap.path_index].distance_to(tactical_path.waypoints[snap.path_index + 1]) * snap.t
	return dist

func _draw_arrow(origin: Vector2, angle: float, color: Color) -> void:
	var dir = Vector2.from_angle(angle)
	var tip = origin + dir * ARROW_LENGTH

	draw_line(origin, tip, color, ARROW_WIDTH, true)

	var left = tip + Vector2.from_angle(angle + PI * 0.8) * ARROWHEAD_SIZE
	var right = tip + Vector2.from_angle(angle - PI * 0.8) * ARROWHEAD_SIZE
	draw_line(tip, left, color, ARROW_WIDTH, true)
	draw_line(tip, right, color, ARROW_WIDTH, true)


## Marker layer: same content source as PathDrawer, drawn at a z above characters.
class _NodeMarkerLayer extends Node2D:
	var drawer: PathDrawer = null

	func _draw() -> void:
		if drawer == null or drawer.tactical_path == null:
			return
		for node in drawer._visible_nodes():
			drawer._draw_node_marker(self, node)
