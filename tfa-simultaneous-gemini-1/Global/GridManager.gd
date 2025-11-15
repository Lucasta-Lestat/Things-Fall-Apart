# res://Global/GridManager.gd
extends Node

const TILE_SIZE = 128
var active_map = "perrow"
var map_rect: Rect2i
var base_layer: TileMapLayer
var highlights_layer: TileMapLayer # NEW: For drawing previews
var grid_costs: Dictionary = {}
var walls: Dictionary = {}
var floors: Dictionary = {}
var fluids: Dictionary = {}
#fluid
const WaterTile = preload("res://Fluid.tscn")
# Fluid simulation constants
const FLUID_TYPE_WATER = "water"
const PUDDLE_HEIGHT = 0.01  # Height threshold for pressure to start
const PRESSURE_COEFFICIENT = 1.0  # How much pressure affects flow
const FLOW_RATE = 0.1  # How fast fluid flows (0-1, lower = more stable)
const EVAPORATION_RATE = 0.0  # Small amount that evaporates per update
# NEW: Flow tracking for visualization
var flow_directions: Dictionary = {}  # Dictionary[Vector2i, Vector2]
var flow_speeds: Dictionary = {}  # Dictionary[Vector2i, float]
# Fluid data structure: Dictionary[Vector2i, Dictionary[String, float]]
# Example: { Vector2i(0,0): {"water": 1.5}, Vector2i(1,0): {"water": 0.8} }
var fluid_grid: Dictionary = {}

# Track which tiles need updating
var active_fluid_tiles: Dictionary = {}
# Active water tiles


# UPDATED: Now takes the highlights layer during initialization
func initialize(p_base_layer: TileMapLayer, p_highlights_layer: TileMapLayer):
	self.base_layer = p_base_layer
	#print("p_base_layer",p_base_layer)
	self.highlights_layer = p_highlights_layer
	if not is_instance_valid(base_layer):
		printerr("GridManager: Invalid TileMapLayer provided.")
		return
		
	map_rect = base_layer.get_used_rect()
	grid_costs.clear()
	
	for y in range(map_rect.position.y, map_rect.end.y):
		for x in range(map_rect.position.x, map_rect.end.x):
			grid_costs[Vector2i(x, y)] = 1
			walls[Vector2i(x, y)] = false
			floors[Vector2i(x, y)] = ""
			fluids[Vector2i(x,y)] = ""

# --- Dynamic Obstacle Management ---
func register_obstacle(grid_pos: Vector2i):
	if grid_costs.has(grid_pos):
		grid_costs[grid_pos] = INF # Set cost to infinity (unwalkable)
		walls[grid_pos] = true
		#print_debug("GridManager: Obstacle registered at ", grid_pos)
		
func register_floor(grid_pos, floor):
	if grid_costs.has(grid_pos):
		grid_costs[grid_pos] = 1/floor.walkability # Set cost to infinity (unwalkable)
		floors[grid_pos] = floor.floor_id
		#print("floors: ",floors[grid_pos])
		#print_debug("GridManager: Floor registered at ", grid_pos)
		
func register_object(grid_pos, item):
	if grid_costs.has(grid_pos):
		grid_costs[grid_pos] = 1/item.walkability # Set cost to infinity (unwalkable)
		
func unregister_object(grid_pos, item):
	if grid_costs.has(grid_pos):
		grid_costs[grid_pos] *= item.walkability # Set cost to infinity (unwalkable)
		
func unregister_obstacle(grid_pos: Vector2i):
	if grid_costs.has(grid_pos):
		grid_costs[grid_pos] = 1 # Set cost back to normal
		walls[grid_pos] = false
		print_debug("GridManager: Obstacle unregistered at ", grid_pos)
		
func unregister_floor(grid_pos): # claude: this needs to set walkability to that of the floor below it, but not sure how.  Could also *= floor's walkability
	if grid_costs.has(grid_pos):
		grid_costs[grid_pos] = 1 # Set cost to normal
		floors[grid_pos] = ""
		print_debug("GridManager: Floor unregistered at ", grid_pos)
		
func get_neighboring_coords(grid_pos):
	return [Vector2(grid_pos.x+1,grid_pos.y),Vector2(grid_pos.x-1,grid_pos.y),Vector2(grid_pos.x,grid_pos.y+1),Vector2(grid_pos.x,grid_pos.y-1)]
# --- UPDATED: More robust coordinate conversion ---
func world_to_map(world_pos: Vector2) -> Vector2i:
	if not is_instance_valid(base_layer): return Vector2i.ZERO
	# This is a more robust way to convert from global to local coordinates,
	# as it correctly handles the TileMap's transform no matter where it is.
	var local_pos = base_layer.to_local(world_pos)
	return base_layer.local_to_map(local_pos)

func map_to_world(map_pos: Vector2i) -> Vector2:
	if not is_instance_valid(base_layer): return Vector2.ZERO
	# Get the tile's position in the TileMap's local space
	var local_pos = base_layer.map_to_local(map_pos)
	# Convert that local position to the global world position
	return base_layer.to_global(local_pos)


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

func _ready():
	# Connect to TimeManager for periodic updates
	if TimeManager:
		TimeManager.connect("time_updated", _on_time_updated)

func _on_time_updated(hour: int, minute: int, second: int):
	# Update fluid simulation every minute (adjust as needed)
	#print("minute: ", minute)
	if minute % 3 == 0 and second % 60 == 0:  # every 3 minutes of game time, which should be 6 seconds of real time
		update_fluid_simulation()

# Register fluid at a specific tile
func register_fluid(tile_pos: Vector2i, fluid_type: String, amount: float):
	if amount <= 0:
		return
	
	if not fluid_grid.has(tile_pos):
		fluid_grid[tile_pos] = {}
	
	if not fluid_grid[tile_pos].has(fluid_type):
		fluid_grid[tile_pos][fluid_type] = 0.0
	
	fluid_grid[tile_pos][fluid_type] += amount
	print("registered fluid at fluid grid pos: ", tile_pos)
	# Add to active tiles if not already present
	if not active_fluid_tiles.has(tile_pos):
		active_fluid_tiles[tile_pos] = true
	
	if grid_costs.has(tile_pos):
		grid_costs[tile_pos] += amount
		

# Get fluid amount at a tile
func get_fluid_amount(tile_pos: Vector2i, fluid_type: String) -> float:
	if fluid_grid.has(tile_pos) and fluid_grid[tile_pos].has(fluid_type):
		return fluid_grid[tile_pos][fluid_type]
	return 0.0

# Calculate pressure at a tile (only if above puddle height)
func calculate_pressure(tile_pos: Vector2i, fluid_type: String) -> float:
	var amount = get_fluid_amount(tile_pos, fluid_type)
	
	if amount <= PUDDLE_HEIGHT:
		return 0.0
	
	# Pressure is proportional to height above puddle threshold
	return (amount - PUDDLE_HEIGHT) * PRESSURE_COEFFICIENT

# Main fluid simulation update - FIXED VERSION
func update_fluid_simulation():
	print("updating fluid simulation")
	if active_fluid_tiles.is_empty():
		return
	
	# Store flow changes to apply all at once (prevents order dependency)
	var flow_deltas: Dictionary = {}  # Dictionary[Vector2i, Dictionary[String, float]]
	
	# NEW: Clear previous frame's flow data
	flow_directions.clear()
	flow_speeds.clear()
	
	# Process each active tile
	var tiles_to_process = active_fluid_tiles.duplicate()
	
	for tile_pos in tiles_to_process:
		for fluid_type in fluid_grid.get(tile_pos, {}).keys():
			var amount = get_fluid_amount(tile_pos, fluid_type)
			
			if amount < PUDDLE_HEIGHT:
				continue
			
			var pressure = calculate_pressure(tile_pos, fluid_type)
			
			# NEW: Track total flow for this tile
			var total_flow_vector = Vector2.ZERO
			var total_flow_amount = 0.0
			
			# Get neighboring tiles (4-directional: up, down, left, right)
			var neighbors = get_neighbors(tile_pos)
			
			# Calculate pressure gradient and flow
			for neighbor_pos in neighbors:
				# Check if neighbor tile is valid (not blocked)
				if not walls[neighbor_pos]:
					var neighbor_pressure = calculate_pressure(neighbor_pos, fluid_type)
					var pressure_diff = pressure - neighbor_pressure
					
					# Fluid flows down pressure gradient
					if pressure_diff > 0:
						# Calculate flow amount based on pressure difference
						var flow_amount = min(
							amount * FLOW_RATE * (pressure_diff / (pressure + 0.1)),
							amount - PUDDLE_HEIGHT
						)
						
						if flow_amount > PUDDLE_HEIGHT:
							# Initialize delta dictionaries if needed
							if not flow_deltas.has(tile_pos):
								flow_deltas[tile_pos] = {}
							if not flow_deltas[tile_pos].has(fluid_type):
								flow_deltas[tile_pos][fluid_type] = 0.0
							
							if not flow_deltas.has(neighbor_pos):
								flow_deltas[neighbor_pos] = {}
							if not flow_deltas[neighbor_pos].has(fluid_type):
								flow_deltas[neighbor_pos][fluid_type] = 0.0
							
							# Record the flow
							flow_deltas[tile_pos][fluid_type] -= flow_amount
							flow_deltas[neighbor_pos][fluid_type] += flow_amount
							
							# NEW: Track flow direction and speed
							var direction_to_neighbor = Vector2(neighbor_pos - tile_pos).normalized()
							total_flow_vector += direction_to_neighbor * flow_amount
							total_flow_amount += flow_amount
			
			# NEW: Store the net flow direction and speed for this tile
			if total_flow_amount > 0.0:
				flow_directions[tile_pos] = total_flow_vector.normalized()
				# Normalize flow speed to 0-1 range based on amount
				flow_speeds[tile_pos] = clamp(total_flow_amount / amount, 0.0, 1.0)
				print("Flow at ", tile_pos, ": direction=", flow_directions[tile_pos], " speed=", flow_speeds[tile_pos])
			else:
				flow_directions[tile_pos] = Vector2.ZERO
				flow_speeds[tile_pos] = 0.0
			
			# Apply evaporation
			if amount > PUDDLE_HEIGHT:
				if not flow_deltas.has(tile_pos):
					flow_deltas[tile_pos] = {}
				if not flow_deltas[tile_pos].has(fluid_type):
					flow_deltas[tile_pos][fluid_type] = 0.0
				
				flow_deltas[tile_pos][fluid_type] -= EVAPORATION_RATE
	
	# Apply all flow deltas
	apply_flow_deltas(flow_deltas)
	
	# Update water tile visuals with flow data
	update_water_tile_flows()
	
	# Clean up tiles with negligible fluid
	cleanup_inactive_tiles()

# Apply flow changes to the grid
func apply_flow_deltas(flow_deltas: Dictionary):
	for tile_pos in flow_deltas.keys():
		for fluid_type in flow_deltas[tile_pos].keys():
			var delta = flow_deltas[tile_pos][fluid_type]
			
			if not fluid_grid.has(tile_pos):
				fluid_grid[tile_pos] = {}
			
			if not fluid_grid[tile_pos].has(fluid_type):
				fluid_grid[tile_pos][fluid_type] = 0.0
			
			fluid_grid[tile_pos][fluid_type] += delta
			
			# Ensure non-negative
			fluid_grid[tile_pos][fluid_type] = max(0.0, fluid_grid[tile_pos][fluid_type])
			
			# Add to active tiles if not present and has fluid
			if fluid_grid[tile_pos][fluid_type] > PUDDLE_HEIGHT and not active_fluid_tiles.has(tile_pos):
				active_fluid_tiles[tile_pos] = true
				spawn_fluid_tile(tile_pos, fluid_grid[tile_pos][fluid_type])
			

# Get neighboring tile positions (4-directional)
func get_neighbors(tile_pos: Vector2i) -> Array[Vector2i]:
	var neighbors: Array[Vector2i] = []
	
	# Priority order: down, left, right, up (water flows down preferentially)
	neighbors.append(Vector2i(tile_pos.x, tile_pos.y + 1))  # Down
	neighbors.append(Vector2i(tile_pos.x - 1, tile_pos.y))  # Left
	neighbors.append(Vector2i(tile_pos.x + 1, tile_pos.y))  # Right
	neighbors.append(Vector2i(tile_pos.x, tile_pos.y - 1))  # Up
	
	return neighbors

# Remove tiles with negligible fluid from active list
func cleanup_inactive_tiles():
	var tiles_to_remove = []
	
	for tile_pos in active_fluid_tiles.keys():
		var total_fluid = 0.0
		if fluid_grid.has(tile_pos):
			for fluid_type in fluid_grid[tile_pos].keys():
				total_fluid += fluid_grid[tile_pos][fluid_type]
		
		if total_fluid < PUDDLE_HEIGHT:
			tiles_to_remove.append(tile_pos)
	
	for tile_pos in tiles_to_remove:
		remove_fluid_tile(tile_pos)

# Debug: Get all fluid data
func get_all_fluid_data() -> Dictionary:
	return fluid_grid.duplicate(true)

# Debug: Get active tile count
func get_active_tile_count() -> int:
	return active_fluid_tiles.size()

func spawn_fluid_tile(grid_pos: Vector2i, water_amount: float):
	"""Spawn a new water tile"""
	print("spawning a fluid tile at ", grid_pos, " with amount ", water_amount)
	var water_tile = WaterTile.instantiate()
	water_tile.z_index = 100
	water_tile.get_node("Sprite")
	var water_sprite = water_tile.get_node("Sprite")
	water_sprite.texture = load("res://water_texture.png")
	add_child(water_tile)
	
	# Initialize the tile
	water_tile.initialize(grid_pos, water_amount)
	
	# Store reference
	active_fluid_tiles[grid_pos] = water_tile
	GridManager.register_fluid(grid_pos,"water", water_amount)
	# Set initial flow if available
	print("flow_directions.has(grid_pos): ", flow_directions.has(grid_pos))
	if flow_directions.has(grid_pos):
		var flow_dir = flow_directions[grid_pos]
		var flow_speed = flow_speeds.get(grid_pos, 0.1)
		water_tile.set_flow_direction(flow_dir, flow_speed)
		print("Set initial flow for tile at ", grid_pos, ": ", flow_dir, " speed: ", flow_speed)

func update_fluid_tile(grid_pos: Vector2i, water_amount: float):
	"""Update an existing water tile"""
	var water_tile = active_fluid_tiles.get(grid_pos)
	if water_tile and is_instance_valid(water_tile):
		water_tile.set_water_depth(water_amount)

func remove_fluid_tile(grid_pos: Vector2i):
	"""Remove a water tile"""
	if not active_fluid_tiles.has(grid_pos):
		return
	
	var water_tile = active_fluid_tiles[grid_pos]
	if water_tile and is_instance_valid(water_tile):
		water_tile.queue_free()
	
	active_fluid_tiles.erase(grid_pos)
	
	# Clean up fluid grid data
	if fluid_grid.has(grid_pos):
		fluid_grid.erase(grid_pos)
	
	# Clean up flow data
	flow_directions.erase(grid_pos)
	flow_speeds.erase(grid_pos)

func clear_all_water_tiles():
	"""Remove all water tiles"""
	for pos in active_fluid_tiles.keys():
		remove_fluid_tile(pos)
		
func update_water_tile_flows():
	"""Update flow direction for all active water tiles"""
	for grid_pos in active_fluid_tiles.keys():
		var water_tile = active_fluid_tiles[grid_pos]
		if water_tile and is_instance_valid(water_tile):
			var flow_dir = flow_directions.get(grid_pos, Vector2.ZERO)
			var flow_speed = flow_speeds.get(grid_pos, 0.0)
			
			# Call the water tile's method to update flow
			water_tile.set_flow_direction(flow_dir, flow_speed)
			
			# Also update depth
			var water_amount = get_fluid_amount(grid_pos, FLUID_TYPE_WATER)
			if water_amount > 0:
				water_tile.set_water_depth(water_amount)
