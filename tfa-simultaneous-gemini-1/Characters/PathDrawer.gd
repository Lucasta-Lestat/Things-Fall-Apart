# PathDrawer.gd
# Renders a character's TacticalPath: white polyline, action node circles with icons,
# and rotation arrows. Uses _draw() for all rendering.
extends Node2D
class_name PathDrawer

var tactical_path: TacticalPath = null

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
	# Redraw when drawing in progress or when executing (to update consumed portion)
	if is_drawing_path or is_drawing_rotation:
		queue_redraw()
	elif tactical_path and tactical_path.is_executing:
		queue_redraw()

func _draw() -> void:
	if tactical_path == null:
		return

	# Draw the remaining path line (from consumed index onward)
	var remaining = tactical_path.get_remaining_waypoints()
	if remaining.size() >= 2:
		var color = PATH_DRAWING_COLOR if is_drawing_path else PATH_COLOR
		draw_polyline(remaining, color, PATH_WIDTH, true)

	# Draw action nodes (only those not yet consumed)
	for node in tactical_path.action_nodes:
		# Skip nodes that are behind the consumed waypoint index
		if node.path_index < tactical_path.consumed_waypoint_index:
			continue
		var pos = node.world_position
		if node.has_action() and node.icon_texture != null:
			# Filled circle with icon
			draw_circle(pos, NODE_RADIUS, NODE_FILL_COLOR)
			draw_arc(pos, NODE_RADIUS, 0, TAU, 32, NODE_OUTLINE_COLOR, NODE_OUTLINE_WIDTH)
			var icon_rect = Rect2(pos - ICON_SIZE / 2.0, ICON_SIZE)
			draw_texture_rect(node.icon_texture, icon_rect, false)
		elif node.has_action():
			# Filled circle without icon texture
			draw_circle(pos, NODE_RADIUS, NODE_FILL_COLOR)
			draw_arc(pos, NODE_RADIUS, 0, TAU, 32, NODE_OUTLINE_COLOR, NODE_OUTLINE_WIDTH)
		else:
			# Empty circle (unassigned node)
			draw_arc(pos, NODE_RADIUS, 0, TAU, 32, NODE_OUTLINE_COLOR, NODE_OUTLINE_WIDTH)

		# Draw rotation arrow if this node has a facing direction
		if node.has_facing():
			_draw_arrow(pos, node.facing_angle - PI / 2, ARROW_COLOR)

	# Draw in-progress rotation arrow
	if is_drawing_rotation:
		var angle = (rotation_current - rotation_start).angle()
		_draw_arrow(rotation_start, angle, ARROW_DRAWING_COLOR)

func _draw_arrow(origin: Vector2, angle: float, color: Color) -> void:
	var dir = Vector2.from_angle(angle)
	var tip = origin + dir * ARROW_LENGTH

	# Arrow shaft
	draw_line(origin, tip, color, ARROW_WIDTH)

	# Arrowhead (two lines from tip at 135 degrees)
	var left = tip + Vector2.from_angle(angle + PI * 0.8) * ARROWHEAD_SIZE
	var right = tip + Vector2.from_angle(angle - PI * 0.8) * ARROWHEAD_SIZE
	draw_line(tip, left, color, ARROW_WIDTH)
	draw_line(tip, right, color, ARROW_WIDTH)
