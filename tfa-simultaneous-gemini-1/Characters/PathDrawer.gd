# PathDrawer.gd
# Renders a character's TacticalPath: white polyline, action node circles with icons,
# and rotation arrows. Uses _draw() for all rendering.
extends Node2D
class_name PathDrawer

var tactical_path: TacticalPath = null
var character: ProceduralCharacter = null

# Drawing state (set by PathInputHandler)
var is_drawing_path: bool = false
var is_drawing_rotation: bool = false
var rotation_start: Vector2 = Vector2.ZERO
var rotation_current: Vector2 = Vector2.ZERO

# Visual constants
const PATH_COLOR := Color(1, 1, 1, 0.7)
const PATH_DRAWING_COLOR := Color(1, 1, 1, 0.4)
const PATH_WIDTH := 2.0
const NODE_RADIUS := 14.0
const NODE_OUTLINE_COLOR := Color(1, 1, 1, 0.9)
const NODE_FILL_COLOR := Color(1, 1, 1, 0.3)
const NODE_OUTLINE_WIDTH := 2.0
const ICON_SIZE := Vector2(20, 20)
const ARROW_COLOR := Color(0.8, 0.8, 1.0, 0.8)
const ARROW_DRAWING_COLOR := Color(1.0, 1.0, 0.5, 0.6)
const ARROW_LENGTH := 30.0
const ARROW_WIDTH := 2.0
const ARROWHEAD_SIZE := 8.0

func _ready() -> void:
	top_level = true  # Don't inherit character's transform (rotation)
	process_mode = Node.PROCESS_MODE_ALWAYS
	z_index = 45

func _process(_delta: float) -> void:
	# Redraw when drawing in progress, executing, or when a visible path exists
	if is_drawing_path or is_drawing_rotation:
		queue_redraw()
	elif tactical_path and tactical_path.is_executing:
		queue_redraw()
	elif tactical_path and not tactical_path.is_empty():
		queue_redraw()

func _draw() -> void:
	if tactical_path == null:
		return

	if tactical_path.is_executing and character:
		_draw_executing_path()
	else:
		_draw_planning_path()

	# Draw in-progress rotation arrow
	if is_drawing_rotation:
		var angle = (rotation_current - rotation_start).angle()
		_draw_arrow(rotation_start, angle, ARROW_DRAWING_COLOR)

func _draw_planning_path() -> void:
	# During planning: draw full path
	if tactical_path.waypoints.size() >= 2:
		var color = PATH_DRAWING_COLOR if is_drawing_path else PATH_COLOR
		draw_polyline(tactical_path.waypoints, color, PATH_WIDTH, true)

	# Draw all action nodes
	for node in tactical_path.action_nodes:
		_draw_action_node(node)

func _draw_executing_path() -> void:
	# During execution: draw from character's current position forward
	var char_pos = character.global_position
	var remaining = _get_path_from_position(char_pos)

	if remaining.size() >= 2:
		draw_polyline(remaining, PATH_COLOR, PATH_WIDTH, true)

	# Only draw action nodes that are ahead of the character
	var char_progress = _get_linear_progress(char_pos)
	for node in tactical_path.action_nodes:
		var node_progress = tactical_path._get_node_linear_position(node)
		if node_progress > char_progress - 10.0:  # Small tolerance
			_draw_action_node(node)

func _draw_action_node(node) -> void:
	var pos = node.world_position
	if node.has_action() and node.icon_texture != null:
		draw_circle(pos, NODE_RADIUS, NODE_FILL_COLOR)
		draw_arc(pos, NODE_RADIUS, 0, TAU, 32, NODE_OUTLINE_COLOR, NODE_OUTLINE_WIDTH)
		var icon_rect = Rect2(pos - ICON_SIZE / 2.0, ICON_SIZE)
		draw_texture_rect(node.icon_texture, icon_rect, false)
	elif node.has_action():
		draw_circle(pos, NODE_RADIUS, NODE_FILL_COLOR)
		draw_arc(pos, NODE_RADIUS, 0, TAU, 32, NODE_OUTLINE_COLOR, NODE_OUTLINE_WIDTH)
	else:
		draw_arc(pos, NODE_RADIUS, 0, TAU, 32, NODE_OUTLINE_COLOR, NODE_OUTLINE_WIDTH)

	# Dash aim line: persistent preview of where the queued dash will land,
	# clamped to the dash's range and truncated at the first wall.
	if node.has_action() and node.action_data.has("dash_target"):
		var dash_target: Vector2 = node.action_data["dash_target"]
		var dash_max_range: float = node.action_data.get("dash_max_range", 0.0)
		var endpoint: Vector2 = AimLine.compute_endpoint(
			get_world_2d(), pos, dash_target, CollisionLayers.STRUCTURES, dash_max_range
		)
		draw_line(pos, endpoint, Color(1.0, 0.85, 0.3, 0.6), 1.5, true)

	if node.has_facing():
		_draw_arrow(pos, node.facing_angle - PI / 2, ARROW_COLOR)

func _get_path_from_position(pos: Vector2) -> PackedVector2Array:
	# Build a polyline starting from the character's current position,
	# skipping waypoints already passed
	if tactical_path.waypoints.size() < 2:
		return PackedVector2Array()

	# Find the nearest segment on the path
	var snap = tactical_path.find_nearest_point_on_path(pos)
	var seg_idx = snap.path_index
	var result = PackedVector2Array()

	# Start from the snapped position on the path
	result.append(snap.position)

	# Add all remaining waypoints after this segment
	for i in range(seg_idx + 1, tactical_path.waypoints.size()):
		result.append(tactical_path.waypoints[i])

	return result

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

	draw_line(origin, tip, color, ARROW_WIDTH)

	var left = tip + Vector2.from_angle(angle + PI * 0.8) * ARROWHEAD_SIZE
	var right = tip + Vector2.from_angle(angle - PI * 0.8) * ARROWHEAD_SIZE
	draw_line(tip, left, color, ARROW_WIDTH)
	draw_line(tip, right, color, ARROW_WIDTH)
