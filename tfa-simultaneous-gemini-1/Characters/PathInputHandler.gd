# PathInputHandler.gd
# Input state machine for tactical path drawing, action node placement, and rotation arrows.
# Child of ProceduralCharacter. Only active when paused and character is player-controlled.
extends Node
class_name PathInputHandler

enum PathInputState {
	IDLE,              # No path interaction
	DRAWING_PATH,      # Left-click dragging from character, adding waypoints
	PLACING_ACTION,    # Clicked on path line, waiting for action assignment
	DRAWING_ROTATION,  # Middle-click dragging, drawing rotation arrow
}

var state: PathInputState = PathInputState.IDLE
var character: ProceduralCharacter = null
var tactical_path: TacticalPath = null
var path_drawer: PathDrawer = null

# The action node currently being configured (in PLACING_ACTION state)
var pending_action_node: TacticalPath.PathActionNode = null

# Rotation drag tracking
var rotation_start: Vector2 = Vector2.ZERO
var rotation_start_on_path: bool = false  # Whether rotation started on path vs on character

# Detection thresholds
const CHARACTER_HIT_RADIUS := 30.0
const PATH_HIT_DISTANCE := 15.0

# Preloaded icons for common action types
var _attack_icon: Texture2D = null
var _dash_icon: Texture2D = null

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	character = get_parent() as ProceduralCharacter
	# Try to load action icons (graceful fallback if not found)
	_attack_icon = _try_load("res://targeting icon.png")
	_dash_icon = _try_load("res://targeting icon.png")  # Reuse targeting icon for dash

func _try_load(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path)
	return null

func handle_input(mouse_pos: Vector2) -> bool:
	# Returns true if input was consumed (caller should skip further input processing).
	# Only call this when paused and character is player-controlled.
	if tactical_path == null:
		return false

	match state:
		PathInputState.IDLE:
			return _handle_idle(mouse_pos)
		PathInputState.DRAWING_PATH:
			return _handle_drawing_path(mouse_pos)
		PathInputState.PLACING_ACTION:
			return _handle_placing_action(mouse_pos)
		PathInputState.DRAWING_ROTATION:
			return _handle_drawing_rotation(mouse_pos)

	return false

func _handle_idle(mouse_pos: Vector2) -> bool:
	var on_character = mouse_pos.distance_to(character.global_position) < CHARACTER_HIT_RADIUS
	var on_path = false
	var path_snap = {}

	if not tactical_path.is_empty():
		path_snap = tactical_path.find_nearest_point_on_path(mouse_pos)
		on_path = path_snap.distance < PATH_HIT_DISTANCE

	# Left click: start drawing path from character, or place action node on path
	if Input.is_action_just_pressed("left_click"):
		if on_character:
			# Start drawing a new path from character position
			tactical_path.clear()
			tactical_path.add_waypoint(character.global_position)
			state = PathInputState.DRAWING_PATH
			path_drawer.is_drawing_path = true
			path_drawer.queue_redraw()
			return true
		elif on_path:
			# Place an empty action node on the path
			pending_action_node = tactical_path.insert_action_node(mouse_pos)
			state = PathInputState.PLACING_ACTION
			path_drawer.queue_redraw()
			return true

	# Middle click: start drawing rotation from character or path
	if Input.is_action_just_pressed("middle_mouse"):
		if on_character or on_path:
			if on_path and not on_character:
				rotation_start = path_snap.position
				rotation_start_on_path = true
			else:
				rotation_start = character.global_position
				rotation_start_on_path = false
			state = PathInputState.DRAWING_ROTATION
			path_drawer.is_drawing_rotation = true
			path_drawer.rotation_start = rotation_start
			path_drawer.rotation_current = mouse_pos
			path_drawer.queue_redraw()
			return true

	return false

func _handle_drawing_path(mouse_pos: Vector2) -> bool:
	# While left mouse is held, add waypoints
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		tactical_path.add_waypoint(mouse_pos)
		# Don't consume other input while drawing - just track the mouse
		return true

	# Left mouse released - finish drawing
	if Input.is_action_just_released("left_click") or not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		state = PathInputState.IDLE
		path_drawer.is_drawing_path = false
		path_drawer.queue_redraw()
		return true

	return true  # Consume all input while drawing

func _handle_placing_action(mouse_pos: Vector2) -> bool:
	if pending_action_node == null:
		state = PathInputState.IDLE
		return false

	# Cancel with right click or escape
	if Input.is_action_just_pressed("right_click") or Input.is_action_just_pressed("ui_cancel"):
		tactical_path.remove_action_node(pending_action_node)
		pending_action_node = null
		state = PathInputState.IDLE
		path_drawer.queue_redraw()
		return true

	# Attack: left click (off the path) assigns attack at mouse position
	if Input.is_action_just_pressed("left_click"):
		pending_action_node.action_type = ActionQueue.ActionType.ATTACK
		pending_action_node.action_data = {"target_position": mouse_pos}
		pending_action_node.icon_texture = _attack_icon
		pending_action_node = null
		state = PathInputState.IDLE
		path_drawer.queue_redraw()
		return true

	# Dash: dash key assigns dash toward mouse position
	if Input.is_action_just_pressed("dash"):
		pending_action_node.action_type = ActionQueue.ActionType.CUSTOM
		pending_action_node.action_data = {"callable": Callable(character, "dash").bind(mouse_pos)}
		pending_action_node.icon_texture = _dash_icon
		pending_action_node = null
		state = PathInputState.IDLE
		path_drawer.queue_redraw()
		return true

	return false  # Don't consume - allow ability/item inputs to reach other handlers

func _handle_drawing_rotation(mouse_pos: Vector2) -> bool:
	# Update arrow preview
	path_drawer.rotation_current = mouse_pos

	if Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
		# Still dragging
		return true

	# Middle mouse released - create FACE action node or queue rotation
	var angle = (mouse_pos - rotation_start).angle() + PI / 2  # +PI/2 to match character rotation convention
	state = PathInputState.IDLE
	path_drawer.is_drawing_rotation = false
	path_drawer.queue_redraw()

	if not tactical_path.is_empty() and rotation_start_on_path:
		# Place a FACE node on the path at the rotation start position
		var node = tactical_path.insert_action_node(rotation_start)
		node.action_type = ActionQueue.ActionType.FACE
		node.action_data = {"target_rotation": angle}
		node.facing_angle = angle
		path_drawer.queue_redraw()
	else:
		# Queue rotation directly to the action queue (not on path)
		character.action_queue.queue_face(mouse_pos)

	return true

# --- Public API for external action assignment (called by PartySidePanel, ability system, etc.) ---

func assign_ability_to_pending_node(ability_id: String, target_pos: Vector2, icon: Texture2D = null) -> bool:
	if state != PathInputState.PLACING_ACTION or pending_action_node == null:
		return false
	pending_action_node.action_type = ActionQueue.ActionType.USE_ABILITY
	pending_action_node.action_data = {
		"ability_id": ability_id,
		"target_position": target_pos,
		"needs_targeting": false,
	}
	pending_action_node.icon_texture = icon
	pending_action_node = null
	state = PathInputState.IDLE
	path_drawer.queue_redraw()
	return true

func assign_item_to_pending_node(action_type: int, action_data: Dictionary, icon: Texture2D = null) -> bool:
	if state != PathInputState.PLACING_ACTION or pending_action_node == null:
		return false
	pending_action_node.action_type = action_type
	pending_action_node.action_data = action_data
	pending_action_node.icon_texture = icon
	pending_action_node = null
	state = PathInputState.IDLE
	path_drawer.queue_redraw()
	return true

func is_placing_action() -> bool:
	return state == PathInputState.PLACING_ACTION

func cancel_path() -> void:
	state = PathInputState.IDLE
	path_drawer.is_drawing_path = false
	path_drawer.is_drawing_rotation = false
	pending_action_node = null
	if tactical_path:
		tactical_path.clear()
	path_drawer.queue_redraw()
