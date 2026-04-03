# res://Global/GridManager.gd
extends Node

var TILE_SIZE: int = 64
var map_rect: Rect2i
var grid_costs: Dictionary = {}
var walls: Dictionary = {}
var floors: Dictionary = {}
var fluids: Dictionary = {}

func initialize(map_width_px: int, map_height_px: int) -> void:
	var cols = int(ceil(float(map_width_px) / TILE_SIZE))
	var rows = int(ceil(float(map_height_px) / TILE_SIZE))
	map_rect = Rect2i(0, 0, cols, rows)
	grid_costs.clear()
	walls.clear()
	floors.clear()
	fluids.clear()
	for y in range(rows):
		for x in range(cols):
			var pos = Vector2i(x, y)
			grid_costs[pos] = 1.0
			walls[pos] = false
			floors[pos] = ""
			fluids[pos] = ""

# --- Coordinate Conversion (pure math, no TileMap) ---
func world_to_map(world_pos: Vector2) -> Vector2i:
	return Vector2i(int(floor(world_pos.x / TILE_SIZE)), int(floor(world_pos.y / TILE_SIZE)))

func map_to_world(map_pos: Vector2i) -> Vector2:
	return Vector2(map_pos.x * TILE_SIZE + TILE_SIZE / 2.0, map_pos.y * TILE_SIZE + TILE_SIZE / 2.0)

# --- Dynamic Obstacle Management ---
func would_walk(grid_pos) -> bool:
	return grid_costs.get(grid_pos, INF) <= 10

func register_obstacle(grid_pos: Vector2i) -> void:
	grid_costs[grid_pos] = INF
	walls[grid_pos] = true

func register_floor(grid_pos: Vector2i, floor_node) -> void:
	grid_costs[grid_pos] = 1.0 / floor_node.walkability
	floors[grid_pos] = floor_node.floor_id

func register_object(grid_pos: Vector2i, item) -> void:
	if grid_costs.has(grid_pos):
		grid_costs[grid_pos] *= (1.0 / item.walkability)

func unregister_object(grid_pos: Vector2i, item) -> void:
	if grid_costs.has(grid_pos):
		grid_costs[grid_pos] *= item.walkability

func unregister_obstacle(grid_pos: Vector2i) -> void:
	# Restore to floor cost if a floor is registered, otherwise default
	if floors.has(grid_pos) and floors[grid_pos] != "":
		var floor_data = FloorDatabase.floor_definitions.get(floors[grid_pos])
		if floor_data:
			grid_costs[grid_pos] = 1.0 / floor_data.walkability
		else:
			grid_costs[grid_pos] = 1.0
	else:
		grid_costs[grid_pos] = 1.0
	walls[grid_pos] = false

func unregister_floor(grid_pos: Vector2i) -> void:
	if grid_costs.has(grid_pos):
		grid_costs[grid_pos] = 1.0
		floors[grid_pos] = ""

func get_neighboring_coords(grid_pos) -> Array:
	return [Vector2i(grid_pos.x + 1, grid_pos.y), Vector2i(grid_pos.x - 1, grid_pos.y), Vector2i(grid_pos.x, grid_pos.y + 1), Vector2i(grid_pos.x, grid_pos.y - 1)]

# --- Pathfinding (A*) ---
func find_path(start_pos: Vector2i, end_pos: Vector2i) -> Array[Vector2i]:
	var open_set: Array[Vector2i] = [start_pos]
	var came_from: Dictionary = {}
	var g_score: Dictionary = { start_pos: 0 }
	var f_score: Dictionary = { start_pos: _heuristic(start_pos, end_pos) }

	while not open_set.is_empty():
		var current = open_set[0]
		for pos in open_set:
			if f_score.get(pos, INF) < f_score.get(current, INF):
				current = pos
		if current == end_pos:
			return _reconstruct_path(came_from, current)
		open_set.erase(current)
		for neighbor in _get_neighbors(current):
			var tentative_g_score = g_score.get(current, INF) + grid_costs.get(neighbor, 1)
			if tentative_g_score < g_score.get(neighbor, INF):
				came_from[neighbor] = current
				g_score[neighbor] = tentative_g_score
				f_score[neighbor] = tentative_g_score + _heuristic(neighbor, end_pos)
				if not open_set.has(neighbor):
					open_set.append(neighbor)
	return []

func _heuristic(a: Vector2i, b: Vector2i) -> float:
	return abs(a.x - b.x) + abs(a.y - b.y)

func _get_neighbors(pos: Vector2i) -> Array[Vector2i]:
	var neighbors: Array[Vector2i] = []
	var dirs = [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
	for dir in dirs:
		var n_pos = pos + dir
		if grid_costs.get(n_pos, INF) != INF:
			neighbors.append(n_pos)
	return neighbors

func _reconstruct_path(came_from: Dictionary, current: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = [current]
	while current in came_from:
		current = came_from[current]
		path.push_front(current)
	path.pop_front()
	return path

func create_example_bolt(pos: Vector2i = Vector2i(1000, 1000)):
	var lightning = LightningVFX.new()
	lightning.start_position = pos
	lightning.end_position = Vector2i(pos.x + TILE_SIZE, pos.y + TILE_SIZE)
	lightning.z_index = 100
	lightning.color = Color(0.7, 0.9, 1.0)
	lightning.thickness = 4.0
	lightning.displacement = 40.0
	lightning.jaggedness = 0.9
	lightning.lifetime = 0.4
	lightning.num_branches = 3
	lightning.light_energy = 2.0
	add_child(lightning)
