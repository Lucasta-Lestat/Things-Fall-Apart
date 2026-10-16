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
	# Input is only handled while paused, so a gesture left open at unpause (an
	# unassigned node, half-finished node targeting, a drag) would otherwise
	# swallow the first click of the next pause. Connected here, before
	# ProceduralCharacter connects _on_game_unpaused_convert_path, so the orphan
	# node is gone before the path is converted.
	PauseManager.game_unpaused.connect(abort_pending_input)

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
			_clear_path_synced()
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
			_clear_path_synced()
			tactical_path.set_waypoints(astar_waypoints)
			path_drawer.queue_redraw()
			return true

	return false

func _handle_drawing_path(mouse_pos: Vector2) -> bool:
	# While left mouse is held, add waypoints (see _try_add_drawn_sample for
	# the walkability rules the pen obeys)
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_try_add_drawn_sample(mouse_pos)
		# Don't consume other input while drawing - just track the mouse
		return true

	# Left mouse released - finish drawing
	if Input.is_action_just_released("left_click") or not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		state = PathInputState.IDLE
		path_drawer.is_drawing_path = false
		path_drawer.queue_redraw()
		return true

	return true  # Consume all input while drawing


# --- freehand pen walkability (GEOMETRY-based, deliberately not tiles) -------
# The pen obeys the body's true footprint: a sample is valid where the body
# circle physically fits, tested against the real STRUCTURES colliders (doors
# excluded — the walker pushes those open). Tile-based clamping made the
# buffer up to a whole tile wide on unlucky wall/grid alignments (and uneven
# per wall), and the wall tiles flanking a doorway blocked drawing through it.
# Rules: (1) a sample must be standable (nudged to the nearest standable
# point when the cursor rides a wall, so the line HUGS the wall at the true
# minimum distance); (2) a drag across a doorway snaps that sample to the
# door's exact gap centre — the same point A* paths thread; (3) every sample
# must CONNECT to the previous waypoint without the swept circle crossing
# masonry — the pen cannot pass through a wall; it stops until routed
# somewhere legal (through the door).
var _pen_shape: CircleShape2D = null


func _pen_radius() -> float:
	# slightly under the body circle: the walker can shave the last pixel by
	# sliding, and the arrival radius absorbs it
	return character._body_circle_radius() * 0.9


func _point_standable(p: Vector2) -> bool:
	if _pen_shape == null:
		_pen_shape = CircleShape2D.new()
	_pen_shape.radius = _pen_radius()
	var params := PhysicsShapeQueryParameters2D.new()
	params.shape = _pen_shape
	params.transform = Transform2D(0.0, p)
	params.collision_mask = CollisionLayers.STRUCTURES
	params.collide_with_areas = false
	for h in character.get_world_2d().direct_space_state.intersect_shape(params, 6):
		var col = h.get("collider")
		# a closed UNLOCKED door yields to the walker's push — ignore its leaf;
		# a locked one is a wall until the key turns
		if col is Door and not (col as Door).locked:
			continue
		return false
	return true


# Swept-circle walkability of the straight segment a->b: overlapping circle
# tests every 12px (radius ~19, so no tunnelling). Steps on door tiles trust
# execution — the gap-centre snap + the walker's own door push thread jambs
# tighter than the pen circle allows.
func _segment_standable(a: Vector2, b: Vector2) -> bool:
	var steps := int(a.distance_to(b) / 12.0) + 1
	for i in range(1, steps + 1):
		var q: Vector2 = a.lerp(b, float(i) / float(steps))
		if GridManager.door_pass.has(GridManager.world_to_map(q)):
			continue
		if not _point_standable(q):
			return false
	return true


func _try_add_drawn_sample(mouse_pos: Vector2) -> void:
	var t: Vector2i = GridManager.world_to_map(mouse_pos)
	var p := mouse_pos
	if GridManager.door_pass.has(t):
		# crossing a doorway: the sample IS the door's exact gap centre
		p = GridManager.door_gaps.get(t, GridManager.map_to_world(t))
	elif not _point_standable(p):
		# cursor is riding a wall: hug it — nudge to the nearest standable
		# point so the line tracks the wall at the true minimum distance
		var found := false
		for step in [8.0, 16.0, 26.0]:
			var best := Vector2.INF
			var best_d := INF
			for k in 8:
				var cand: Vector2 = p + Vector2.from_angle(TAU * float(k) / 8.0) * step
				if _point_standable(cand):
					var d := p.distance_squared_to(cand)
					if d < best_d:
						best_d = d
						best = cand
			if best_d < INF:
				p = best
				found = true
				break
		if not found:
			return
	var prev: Vector2 = character.global_position if tactical_path.waypoints.is_empty() \
		else tactical_path.waypoints[tactical_path.waypoints.size() - 1]
	if not _segment_standable(prev, p):
		return
	tactical_path.add_waypoint(p)

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

		# Character-pick abilities (e.g. Hitch, Fatal Attraction): each click with
		# the targeting hand's button toggles a character until target_count are
		# picked, then the ability is assigned to the node. The other button
		# cancels targeting (the node stays pending, as with Escape).
		var ts = character.targeting_system
		if ts.target_shape == ts.TargetShape.CHARACTERS:
			var pick_button := "left_click" if ts.current_hand == "Main" else "right_click"
			var other_button := "right_click" if pick_button == "left_click" else "left_click"
			if Input.is_action_just_pressed(pick_button):
				ts._handle_character_click(mouse_pos)
				if ts.selected_targets.size() == ts.target_count:
					_confirm_targeting_for_node(mouse_pos)
				return true
			if Input.is_action_just_pressed(other_button):
				ts.cancel_targeting()
				_targeting_for_node = false
				return true
			return false

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
			_truncate_after_synced(_action_drag_snap)
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
		_truncate_after_synced(_action_drag_snap)
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

func assign_ability_to_pending_node(ability_id: String, target_pos: Vector2, icon: Texture2D = null, targets: Array = [], anchor = null) -> bool:
	if state != PathInputState.PLACING_ACTION or pending_action_node == null:
		return false
	pending_action_node.action_type = ActionQueue.ActionType.USE_ABILITY
	pending_action_node.action_data = {
		"ability_id": ability_id,
		"target_position": target_pos,
		"targets": targets,
		"target_anchor": anchor,
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
		# Weapon attack: on a character if one is under the cursor, else at the
		# point, swung with the hand that was clicked.
		_assign_attack_to_pending_node(mouse_pos, hand)
	else:
		# Nothing equipped — basic unarmed attack, with the main hand as before
		_assign_attack_to_pending_node(mouse_pos, "Main")

	pending_action_node = null
	state = PathInputState.IDLE
	path_drawer.queue_redraw()

func _assign_attack_to_pending_node(mouse_pos: Vector2, hand: String = "Main") -> void:
	"""Plan a weapon/unarmed attack on the pending node. A character under the
	cursor is designated as the victim (ATTACK_TARGET, which re-reads their live
	position when the swing actually happens); bare ground plans the old
	fixed-point ATTACK. `hand` is the hand that swings (ActionQueue sets
	character.current_hand from it at execution)."""
	var designated := character._find_character_at(mouse_pos)
	if designated != null:
		pending_action_node.action_type = ActionQueue.ActionType.ATTACK_TARGET
		pending_action_node.action_data = {"target": designated, "hand": hand}
	else:
		pending_action_node.action_type = ActionQueue.ActionType.ATTACK
		pending_action_node.action_data = {"target_position": mouse_pos, "hand": hand}
	pending_action_node.icon_texture = _attack_icon


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
		# Character designation survives the plan→unpause→walk→cast round trip.
		# `targets` binds the effect to exact characters; `target_anchor` re-aims
		# the position at execution. Both are empty/null when the player
		# confirmed over bare ground, leaving plain area targeting intact.
		"targets": result.get("targets", []),
		"target_anchor": result.get("anchor", null),
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
		result.get("caster_position", character.global_position),
		Ability.classify_intent(ability_data)
	)
	if indicator:
		pending_action_node.action_data["queued_indicator"] = indicator
		_bind_aoe_to_node(pending_action_node, result)

	_targeting_for_node = false
	pending_action_node = null
	state = PathInputState.IDLE
	path_drawer.queue_redraw()

func is_placing_action() -> bool:
	return state == PathInputState.PLACING_ACTION

## Drop the gesture currently IN FLIGHT and leave the committed plan untouched.
## cancel_path() is the heavier sibling - it also wipes every waypoint and action
## node - which is exactly what must not happen when the player merely switches to
## another party member and expects to come back to this one's route.
## Idempotent: an IDLE handler with nothing pending does nothing at all.
func abort_pending_input() -> void:
	if _targeting_for_node:
		if character != null and character.targeting_system != null:
			character.targeting_system.cancel_targeting()
		_targeting_for_node = false
	if pending_action_node != null:
		# The node was created by the click that opened this gesture and never got
		# an action assigned (action_type stays -1). Left behind it draws an empty
		# ring on the route and splits the MOVE in two for no reason, so it goes -
		# the same call the ESC branch of _handle_placing_action makes. Free any
		# ghost first: a node dropped without _release_node_ghosts strands an
		# ownerless blue circle. Belt-and-braces, since a node only acquires a
		# ghost in _confirm_targeting_for_node, which clears pending_action_node.
		_release_node_ghosts([pending_action_node])
		if tactical_path != null:
			tactical_path.remove_action_node(pending_action_node)
		pending_action_node = null
	_awaiting_node_press_release = false
	_use_press_armed = false
	state = PathInputState.IDLE
	if path_drawer != null:
		# A mid-drag DRAWING_PATH / DRAWING_ROTATION never sees its own mouse
		# release either, so drop those flags too. The waypoints drawn so far stay:
		# they are already part of the plan.
		path_drawer.is_drawing_path = false
		path_drawer.is_drawing_rotation = false
		path_drawer.queue_redraw()

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
		_clear_path_synced()
	path_drawer.queue_redraw()

## Record WHERE the AoE ghost this node just created actually landed, on the node
## itself, so PathDrawer can tether the icon to its blast without ever touching
## AbilityTargeting (and so TacticalPath stays free of TargetShape). Only two
## presentation numbers cross the boundary: an anchor point and a reach.
##
## LINE and CONE are deliberately left unbound. _initiate_action_for_node hands
## start_targeting() the node position as origin_override, so those ghosts are
## already drawn FROM the node outward and are visibly attached; a leader line
## down their own spine would be pure clutter.
func _bind_aoe_to_node(node: TacticalPath.PathActionNode, result: Dictionary) -> void:
	node.aoe_center = Vector2.INF
	node.aoe_extent = 0.0
	# Set unconditionally, ABOVE the shape test: LINE and CONE bind no centre but
	# their ghost is still intent-coloured, and a node re-used for a second ability
	# must never inherit the first one's colour.
	var ability_dict: Dictionary = result.get("ability", {})
	node.aoe_intent = Ability.classify_intent(ability_dict)
	if character == null or character.targeting_system == null:
		return
	var shapes = character.targeting_system.TargetShape
	var shape = result.get("shape", null)
	var center: Vector2 = result.get("position", node.world_position)
	if shape == shapes.CIRCLE:
		node.aoe_center = center
		node.aoe_extent = float(result.get("radius", 0.0))
	elif shape == shapes.RECTANGLE:
		var rect_size: Vector2 = result.get("size", Vector2.ZERO)
		node.aoe_center = center
		# Half the SHORT side: the badge has to end up inside the box whichever
		# way the leader comes in.
		node.aoe_extent = minf(rect_size.x, rect_size.y) * 0.5

## Free the AoE ghosts owned by nodes that are being dropped from the path. The
## ghost is a top_level node parented to the targeting system, not to the node,
## so nothing frees it when the node goes — which is how a redraw used to leave a
## blue circle floating with no icon and no owner. Only this character's own node
## ghosts are touched: a blanket clear_all_queued_indicators() would also erase
## ghosts belonging to unplanned casts already sitting in the action queue.
func _release_node_ghosts(nodes: Array) -> void:
	var ts = character.targeting_system if character != null else null
	for n in nodes:
		var ghost = n.action_data.get("queued_indicator", null)
		if ghost != null and is_instance_valid(ghost) and ts != null:
			ts.remove_queued_indicator(ghost)
		# Reset the node's own state regardless of whether a targeting system was
		# available to free the ghost — these are not dependent on it.
		n.action_data.erase("queued_indicator")
		n.aoe_center = Vector2.INF
		n.aoe_extent = 0.0

## tactical_path.clear() with the AoE ghosts torn down alongside the nodes.
func _clear_path_synced() -> void:
	_release_node_ghosts(tactical_path.action_nodes.duplicate())
	tactical_path.clear()

## tactical_path.truncate_after() with the ghosts of the dropped nodes freed.
## Diffed rather than predicted, so it stays correct if truncate_after's own
## filter rule ever changes.
func _truncate_after_synced(snap: Dictionary) -> void:
	var before: Array = tactical_path.action_nodes.duplicate()
	tactical_path.truncate_after(snap)
	var dropped: Array = []
	for n in before:
		if not (n in tactical_path.action_nodes):
			dropped.append(n)
	_release_node_ghosts(dropped)

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
	# JUMP input: Shift+middle-click a roof targets the ROOF for jumpers
	# (plain clicks under a roof path indoors); unreachable ground under a
	# roof falls back to the roof for jumpers automatically.
	var can_roof := character.jump_height > 0.0 and GridManager.has_roof(end_tile)
	var want_roof := can_roof and Input.is_key_pressed(KEY_SHIFT)
	var tile_path = GridManager.find_path(start_tile, end_tile, character.jump_height, character.jump_range, character.on_roof, want_roof)
	if tile_path.is_empty() and can_roof and not want_roof:
		tile_path = GridManager.find_path(start_tile, end_tile, character.jump_height, character.jump_range, character.on_roof, true)
	if tile_path.is_empty():
		# the clicked tile is blocked (wall/off-map): snap to the floor beside
		# it — never fabricate a straight line through the wall
		var snapped := GridManager.nearest_walkable(end_tile)
		if snapped != end_tile:
			tile_path = GridManager.find_path(start_tile, snapped, character.jump_height, character.jump_range, character.on_roof)
	var waypoints := GridManager.path_to_waypoints(tile_path)
	if waypoints.is_empty():
		# genuinely unreachable — a stand-still path refuses the order safely
		waypoints.append(from_pos)
	return waypoints
