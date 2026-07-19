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
const DRAG_THRESHOLD := 10.0

# Drag tracking for click-and-drag from path
var _action_drag_start: Vector2 = Vector2.ZERO
var _action_drag_snap: Dictionary = {}

# True when AbilityTargeting is active for the pending action node
var _targeting_for_node: bool = false

# True from the moment a node is placed until the creating click is released.
# Lets us distinguish that initial click (which only places the node) from a
# later click (which uses the ability) and from a drag (which redraws the path).
var _awaiting_node_press_release: bool = false

# True only once the handler has witnessed a left press over the world (i.e. NOT
# the node-creating one, and NOT a press that began over UI — the character skips
# us while the cursor is over a Control). Required before a release executes the
# ability or a hold redraws, so a menu click can't leak in via a later release.
var _use_press_armed: bool = false

# Preloaded icons for common action types
var _attack_icon: Texture2D = null
var _dash_icon: Texture2D = null

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	character = get_parent() as ProceduralCharacter
	# Try to load action icons (graceful fallback if not found)
	_attack_icon = _try_load("res://targeting icon.png")
	_dash_icon = _try_load("res://UI/UI Icons/Dash.png")

func _try_load(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path)
	return null

func _resolve_ability_icon(ability_data: Dictionary) -> Texture2D:
	# Prefer the ability's own icon (a Texture2D or a res:// path in the data);
	# fall back to the generic targeting icon so a node is never left blank.
	var icon_val = ability_data.get("icon", null)
	if icon_val is Texture2D:
		return icon_val
	if icon_val is String and icon_val != "" and ResourceLoader.exists(icon_val):
		var res = load(icon_val)
		if res is Texture2D:
			return res
	return _attack_icon

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
			# Start drawing a new path from character position — clear stale movement state
			_clear_stale_movement()
			tactical_path.clear()
			tactical_path.add_waypoint(character.global_position)
			state = PathInputState.DRAWING_PATH
			path_drawer.is_drawing_path = true
			path_drawer.queue_redraw()
			return true
		elif on_path:
			# Place an empty action node on the path (may become a drag — see _handle_placing_action)
			pending_action_node = tactical_path.insert_action_node(mouse_pos)
			_action_drag_start = mouse_pos
			_action_drag_snap = path_snap
			_awaiting_node_press_release = true
			_use_press_armed = false
			state = PathInputState.PLACING_ACTION
			path_drawer.queue_redraw()
			return true

	# Middle click: rotation (on character/path) or A* pathfind (on open ground)
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
		else:
			# Middle-click on open ground: A* pathfind from character to destination
			_clear_stale_movement()
			var astar_waypoints = _astar_path_to_waypoints(character.global_position, mouse_pos)
			tactical_path.clear()
			tactical_path.set_waypoints(astar_waypoints)
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

	# --- Sub-state: targeting is active for this node ---
	if _targeting_for_node:
		# Escape: cancel targeting, stay in PLACING_ACTION (node still pending)
		if Input.is_action_just_pressed("ui_cancel"):
			character.targeting_system.cancel_targeting()
			_targeting_for_node = false
			return true

		# Left-click or right-click while targeting: confirm targeting
		if Input.is_action_just_pressed("left_click") or Input.is_action_just_pressed("right_click"):
			_confirm_targeting_for_node(mouse_pos)
			return true

		return false  # Let targeting system update indicator position

	# --- Normal PLACING_ACTION (no targeting active) ---

	# Escape: cancel the pending action node
	if Input.is_action_just_pressed("ui_cancel"):
		tactical_path.remove_action_node(pending_action_node)
		pending_action_node = null
		state = PathInputState.IDLE
		path_drawer.queue_redraw()
		return true

	# A fresh left press (NOT the click that created the node) re-arms drag
	# detection from its own location, so a click made away from the node is
	# never mistaken for a drag. The gesture resolves on release (a click → use
	# the ability) or once the cursor moves past the threshold (a drag → redraw).
	var fresh_left_press: bool = false
	if Input.is_action_just_pressed("left_click") and not _awaiting_node_press_release:
		_action_drag_start = mouse_pos
		_use_press_armed = true
		fresh_left_press = true

	# Drag-to-redraw: while the left button is held and the cursor leaves the
	# threshold, discard the path after the node and resume free drawing from it.
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not fresh_left_press and (_awaiting_node_press_release or _use_press_armed):
		if mouse_pos.distance_to(_action_drag_start) > DRAG_THRESHOLD:
			tactical_path.truncate_after(_action_drag_snap)
			tactical_path.remove_action_node(pending_action_node)
			pending_action_node = null
			_awaiting_node_press_release = false
			_use_press_armed = false
			state = PathInputState.DRAWING_PATH
			path_drawer.is_drawing_path = true
			path_drawer.queue_redraw()
			return true

	# Left release resolves the click: the node-creating click only keeps the
	# node pending; any later in-place click uses the main-hand ability AT the
	# node (the character walks to the node, then casts/fires there).
	if Input.is_action_just_released("left_click"):
		if _awaiting_node_press_release:
			_awaiting_node_press_release = false
			return true
		if _use_press_armed:
			# A click whose press the handler saw over the world: use the
			# main-hand ability at the node.
			_use_press_armed = false
			_initiate_action_for_node(character.current_main_hand_item, "Main", mouse_pos)
			return true
		# Release of a press we never saw (it began over UI, e.g. a menu click) —
		# ignore it so equipping/menu clicks don't leak in as a planned action.
		return false

	if fresh_left_press:
		return true  # consume the press; wait for the release or a drag

	# No left press in flight (button up) — drop any stale arm so a later release
	# whose press began over UI can't be mistaken for a world click.
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_use_press_armed = false

	# Middle-click: A* pathfind from this node to the destination,
	# truncating the path after the node
	if Input.is_action_just_pressed("middle_mouse"):
		var node_pos = pending_action_node.world_position
		var astar_waypoints = _astar_path_to_waypoints(node_pos, mouse_pos)
		tactical_path.truncate_after(_action_drag_snap)
		tactical_path.remove_action_node(pending_action_node)
		tactical_path.append_waypoints(astar_waypoints)
		pending_action_node = null
		state = PathInputState.IDLE
		path_drawer.queue_redraw()
		return true

	# Right-click: assign off-hand action
	if Input.is_action_just_pressed("right_click"):
		_initiate_action_for_node(character.current_off_hand_item, "Off", mouse_pos)
		return true

	# Dash: dash key assigns dash toward mouse position
	if Input.is_action_just_pressed("dash"):
		pending_action_node.action_type = ActionQueue.ActionType.CUSTOM
		# dash_target / dash_max_range are read by PathDrawer to render the aim
		# line preview from the node out to the (clamped, wall-truncated)
		# endpoint. The action queue itself only consumes "callable".
		var dash_range: float = character.get_dash_range() if character.has_method("get_dash_range") else 0.0
		pending_action_node.action_data = {
			"callable": Callable(character, "dash").bind(mouse_pos),
			"dash_target": mouse_pos,
			"dash_max_range": dash_range,
		}
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

func _initiate_action_for_node(item: Node2D, hand: String, mouse_pos: Vector2) -> void:
	"""Inspect the equipped item and either start targeting or assign the action directly."""
	if pending_action_node == null:
		return

	if item is AbilityShape:
		var ability_data = item.get_ability_data()
		if ability_data.get("requires_targeting", false):
			# Start targeting UI — stay in PLACING_ACTION, wait for confirm click.
			# Anchor the preview origin to the node so line/cone AoE previews start
			# from where the ability will be cast, not the character's live position.
			character.targeting_system.start_targeting(hand, ability_data, mouse_pos, pending_action_node.world_position)
			_targeting_for_node = true
			return
		else:
			# Instant ability (self-buffs, etc.) — assign directly. The cast
			# happens when the character reaches the node, so anchor it there.
			# Self-targeted abilities re-resolve to the live body position at
			# execution time (see AbilityManager.use_ability).
			pending_action_node.action_type = ActionQueue.ActionType.USE_ABILITY
			pending_action_node.action_data = {
				"ability_id": item.ability_id,
				"target_position": pending_action_node.world_position,
				"needs_targeting": false,
			}
			pending_action_node.icon_texture = _resolve_ability_icon(ability_data)
	elif item is WeaponShape:
		# Weapon attack at mouse position
		pending_action_node.action_type = ActionQueue.ActionType.ATTACK
		pending_action_node.action_data = {"target_position": mouse_pos}
		pending_action_node.icon_texture = _attack_icon
	else:
		# Nothing equipped — basic unarmed attack
		pending_action_node.action_type = ActionQueue.ActionType.ATTACK
		pending_action_node.action_data = {"target_position": mouse_pos}
		pending_action_node.icon_texture = _attack_icon

	pending_action_node = null
	state = PathInputState.IDLE
	path_drawer.queue_redraw()

func _confirm_targeting_for_node(mouse_pos: Vector2) -> void:
	"""Confirm the active targeting and assign the ability to the pending action node."""
	if pending_action_node == null:
		return

	var result = character.targeting_system.confirm_targeting()
	if result.is_empty():
		return

	var ability_data = result.get("ability", {})
	var target_pos = result.get("position", Vector2.ZERO)
	var ability_id = ability_data.get("id", "")

	pending_action_node.action_type = ActionQueue.ActionType.USE_ABILITY
	pending_action_node.action_data = {
		"ability_id": ability_id,
		"target_position": target_pos,
		"needs_targeting": false,
	}
	pending_action_node.icon_texture = _resolve_ability_icon(ability_data)

	# End targeting and create persistent queued indicator (AOE preview)
	character.targeting_system.end_targeting()
	var indicator = character.targeting_system.create_queued_indicator(
		target_pos,
		result.get("shape"),
		result.get("radius", 0),
		result.get("size", Vector2.ZERO),
		result.get("rotation", 0.0),
		result.get("caster_position", character.global_position)
	)
	if indicator:
		pending_action_node.action_data["queued_indicator"] = indicator

	_targeting_for_node = false
	pending_action_node = null
	state = PathInputState.IDLE
	path_drawer.queue_redraw()

func is_placing_action() -> bool:
	return state == PathInputState.PLACING_ACTION

func cancel_path() -> void:
	if _targeting_for_node:
		character.targeting_system.cancel_targeting()
		_targeting_for_node = false
	_awaiting_node_press_release = false
	_use_press_armed = false
	state = PathInputState.IDLE
	path_drawer.is_drawing_path = false
	path_drawer.is_drawing_rotation = false
	pending_action_node = null
	if tactical_path:
		tactical_path.clear()
	path_drawer.queue_redraw()

func _clear_stale_movement() -> void:
	"""Clear any stale ActionQueue actions and nav waypoints when creating a new path."""
	if character.action_queue:
		character.action_queue.cancel_all()
	character._nav_waypoints.clear()
	character._nav_index = 0
	character.is_moving = false

func _astar_path_to_waypoints(from_pos: Vector2, to_pos: Vector2) -> PackedVector2Array:
	"""Use A* pathfinding to get waypoints between two world positions."""
	var start_tile = GridManager.world_to_map(from_pos)
	var end_tile = GridManager.world_to_map(to_pos)
	var tile_path = GridManager.find_path(start_tile, end_tile, character.jump_height, character.jump_range, character.on_roof)
	var waypoints = PackedVector2Array()
	for tile in tile_path:
		waypoints.append(GridManager.map_to_world(tile))
	if waypoints.is_empty():
		# Fallback: direct line
		waypoints.append(from_pos)
		waypoints.append(to_pos)
	return waypoints
