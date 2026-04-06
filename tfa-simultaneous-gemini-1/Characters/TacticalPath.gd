# TacticalPath.gd
# Pure data model for a character's planned freeform movement path and action nodes.
# Used during paused planning phase (Doorkickers 2-style tactical path).
extends RefCounted
class_name TacticalPath

# Freeform world-space waypoints from left-click drag
var waypoints: PackedVector2Array = PackedVector2Array()

# Action nodes placed on the path (sorted by path_index, then t)
var action_nodes: Array = []  # Array of PathActionNode

# Minimum distance between waypoints during drawing (distance gating)
const MIN_WAYPOINT_DISTANCE: float = 8.0

class PathActionNode:
	var path_index: int = 0        # Segment index: between waypoints[path_index] and waypoints[path_index+1]
	var t: float = 0.0             # 0.0-1.0 interpolation along that segment
	var world_position: Vector2 = Vector2.ZERO
	var action_type: int = -1      # ActionQueue.ActionType value, -1 means empty/unassigned
	var action_data: Dictionary = {}
	var icon_texture: Texture2D = null
	var facing_angle: float = NAN  # For FACE action nodes (rotation arrows)

	func _init(p_index: int = 0, p_t: float = 0.0, p_pos: Vector2 = Vector2.ZERO) -> void:
		path_index = p_index
		t = p_t
		world_position = p_pos

	func has_action() -> bool:
		return action_type >= 0

	func has_facing() -> bool:
		return not is_nan(facing_angle)

func add_waypoint(pos: Vector2) -> void:
	if waypoints.size() == 0:
		waypoints.append(pos)
		return
	var last = waypoints[waypoints.size() - 1]
	if pos.distance_to(last) >= MIN_WAYPOINT_DISTANCE:
		waypoints.append(pos)

func get_position_at(path_index: int, t: float) -> Vector2:
	if waypoints.size() < 2:
		if waypoints.size() == 1:
			return waypoints[0]
		return Vector2.ZERO
	path_index = clampi(path_index, 0, waypoints.size() - 2)
	t = clampf(t, 0.0, 1.0)
	return waypoints[path_index].lerp(waypoints[path_index + 1], t)

func find_nearest_point_on_path(world_pos: Vector2) -> Dictionary:
	# Returns {path_index, t, position, distance} for the closest point on any segment
	var best = {"path_index": 0, "t": 0.0, "position": Vector2.ZERO, "distance": INF}
	if waypoints.size() < 2:
		if waypoints.size() == 1:
			best.position = waypoints[0]
			best.distance = world_pos.distance_to(waypoints[0])
		return best

	for i in range(waypoints.size() - 1):
		var a = waypoints[i]
		var b = waypoints[i + 1]
		var ab = b - a
		var ab_len_sq = ab.length_squared()
		if ab_len_sq < 0.001:
			continue
		var t_val = clampf((world_pos - a).dot(ab) / ab_len_sq, 0.0, 1.0)
		var closest = a.lerp(b, t_val)
		var dist = world_pos.distance_to(closest)
		if dist < best.distance:
			best.path_index = i
			best.t = t_val
			best.position = closest
			best.distance = dist
	return best

func insert_action_node(world_pos: Vector2, action_type: int = -1, action_data: Dictionary = {}, icon: Texture2D = null) -> PathActionNode:
	var snap = find_nearest_point_on_path(world_pos)
	var node = PathActionNode.new(snap.path_index, snap.t, snap.position)
	node.action_type = action_type
	node.action_data = action_data
	node.icon_texture = icon

	# Insert sorted by (path_index, t)
	var insert_idx = 0
	for i in range(action_nodes.size()):
		var existing = action_nodes[i] as PathActionNode
		if existing.path_index < node.path_index or (existing.path_index == node.path_index and existing.t < node.t):
			insert_idx = i + 1
		else:
			break
	action_nodes.insert(insert_idx, node)
	return node

func remove_action_node(node: PathActionNode) -> void:
	action_nodes.erase(node)

func clear() -> void:
	waypoints.clear()
	action_nodes.clear()

func is_empty() -> bool:
	return waypoints.size() < 2

func get_total_length() -> float:
	var length = 0.0
	for i in range(waypoints.size() - 1):
		length += waypoints[i].distance_to(waypoints[i + 1])
	return length

func _get_node_linear_position(node: PathActionNode) -> float:
	# Returns cumulative distance along the path to this node's position
	var dist = 0.0
	for i in range(node.path_index):
		dist += waypoints[i].distance_to(waypoints[i + 1])
	if node.path_index < waypoints.size() - 1:
		dist += waypoints[node.path_index].distance_to(waypoints[node.path_index + 1]) * node.t
	return dist

func to_action_queue_actions() -> Array:
	# Converts the path + action nodes into an ordered list of ActionQueue-compatible dicts:
	# [{type: ActionType, data: Dictionary}, ...]
	# Splits the waypoint list at each action node, producing interleaved MOVE + ACTION entries.
	if is_empty():
		return []

	var actions: Array = []

	if action_nodes.is_empty():
		# No action nodes: single MOVE with all waypoints
		actions.append(_make_move_action(waypoints))
		return actions

	# Sort nodes by position along path (should already be sorted from insert)
	var sorted_nodes = action_nodes.duplicate()
	sorted_nodes.sort_custom(func(a, b):
		if a.path_index != b.path_index:
			return a.path_index < b.path_index
		return a.t < b.t
	)

	# Build waypoint segments split at action node positions
	var current_segment: PackedVector2Array = PackedVector2Array()
	current_segment.append(waypoints[0])
	var wp_idx = 0  # Current waypoint index we've processed up to

	for node in sorted_nodes:
		# Add all full waypoints up to this node's segment
		while wp_idx < node.path_index:
			wp_idx += 1
			if wp_idx < waypoints.size():
				current_segment.append(waypoints[wp_idx])

		# Add the interpolated node position as the end of this segment
		current_segment.append(node.world_position)

		# Emit MOVE for this segment (if it has actual distance)
		if current_segment.size() >= 2:
			actions.append(_make_move_action(current_segment))

		# Emit the action at this node
		if node.has_action():
			actions.append({"type": node.action_type, "data": node.action_data})

		# Emit FACE if this node has a facing direction
		if node.has_facing():
			actions.append({"type": ActionQueue.ActionType.FACE, "data": {"target_rotation": node.facing_angle}})

		# Start new segment from this node's position
		current_segment = PackedVector2Array()
		current_segment.append(node.world_position)

	# Add remaining waypoints after the last action node
	var last_node = sorted_nodes[sorted_nodes.size() - 1] as PathActionNode
	var resume_idx = last_node.path_index + 1
	while resume_idx < waypoints.size():
		current_segment.append(waypoints[resume_idx])
		resume_idx += 1

	# Emit final MOVE segment if it has distance
	if current_segment.size() >= 2:
		actions.append(_make_move_action(current_segment))

	return actions

func _make_move_action(segment_waypoints: PackedVector2Array) -> Dictionary:
	var wp_array: Array[Vector2] = []
	for wp in segment_waypoints:
		wp_array.append(wp)
	return {
		"type": ActionQueue.ActionType.MOVE,
		"data": {
			"target_position": segment_waypoints[segment_waypoints.size() - 1],
			"waypoints": wp_array,
			"waypoint_index": 0,
			"freeform": true,  # Flag to skip A* recalculation
		}
	}
