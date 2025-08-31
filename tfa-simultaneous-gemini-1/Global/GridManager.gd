# res://Global/GridManager.gd
# UPDATED to be more dynamic
extends Node

const TILE_SIZE = 64
var map_rect: Rect2i
var base_layer: TileMapLayer
var grid_costs: Dictionary = {}

func initialize(p_base_layer: TileMapLayer):
	self.base_layer = p_base_layer
	if not is_instance_valid(base_layer):
		printerr("GridManager: Invalid TileMapLayer provided.")
		return
		
	map_rect = base_layer.get_used_rect()
	grid_costs.clear()
	
	# The grid starts completely empty of obstacles.
	# Structures will register themselves as obstacles.
	for y in range(map_rect.position.y, map_rect.end.y):
		for x in range(map_rect.position.x, map_rect.end.x):
			var cell = Vector2i(x, y)
			grid_costs[cell] = 1 # All tiles are initially walkable

# --- NEW: Dynamic Obstacle Management ---
func register_obstacle(grid_pos: Vector2i):
	if grid_costs.has(grid_pos):
		grid_costs[grid_pos] = INF # Set cost to infinity (unwalkable)
		print_debug("GridManager: Obstacle registered at ", grid_pos)

func unregister_obstacle(grid_pos: Vector2i):
	if grid_costs.has(grid_pos):
		grid_costs[grid_pos] = 1 # Set cost back to normal
		print_debug("GridManager: Obstacle unregistered at ", grid_pos)

# --- Coordinate and Pathfinding functions (unchanged from before) ---
func world_to_map(world_pos: Vector2) -> Vector2i:
	if not is_instance_valid(base_layer): return Vector2i.ZERO
	return base_layer.local_to_map(base_layer.to_local(world_pos))

func map_to_world(map_pos: Vector2i) -> Vector2:
	if not is_instance_valid(base_layer): return Vector2.ZERO
	return base_layer.to_global(base_layer.map_to_local(map_pos))

func find_path(start_pos: Vector2i, end_pos: Vector2i) -> Array[Vector2i]:
	var open_set: Array[Vector2i] = [start_pos]
	var came_from: Dictionary = {}
	var g_score: Dictionary = { start_pos: 0 }; var f_score: Dictionary = { start_pos: _heuristic(start_pos, end_pos) }
	
	while not open_set.is_empty():
		var current = open_set[0]
		for pos in open_set:
			if f_score.get(pos, INF) < f_score.get(current, INF): current = pos
		if current == end_pos: return _reconstruct_path(came_from, current)
		open_set.erase(current)
		for neighbor in _get_neighbors(current):
			var tentative_g_score = g_score.get(current, INF) + grid_costs.get(neighbor, 1)
			if tentative_g_score < g_score.get(neighbor, INF):
				came_from[neighbor] = current; g_score[neighbor] = tentative_g_score
				f_score[neighbor] = tentative_g_score + _heuristic(neighbor, end_pos)
				if not open_set.has(neighbor): open_set.append(neighbor)
	return []

func _heuristic(a: Vector2i, b: Vector2i) -> float: return abs(a.x - b.x) + abs(a.y - b.y)
func _get_neighbors(pos: Vector2i) -> Array[Vector2i]:
	var neighbors: Array[Vector2i] = []; var dirs = [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
	for dir in dirs:
		var n_pos = pos + dir
		if grid_costs.get(n_pos, INF) != INF: neighbors.append(n_pos)
	return neighbors
func _reconstruct_path(came_from: Dictionary, current: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = [current]
	while current in came_from: current = came_from[current]; path.push_front(current)
	path.pop_front(); return path
