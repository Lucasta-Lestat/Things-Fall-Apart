# PathfindingSystem.gd
extends Node2D
class_name PathfindingSystem

@export var tile_size: int = 32
@export var map_width: int = 100
@export var map_height: int = 100

# Terrain types
enum TerrainType {
	DIRT,
	STONE,
	WOOD_FLOOR,
	GRASS,
	GRAVEL,
	METAL_FLOOR,
	WATER,
	FIRE,
	ELECTRIC
}

# Base materials (non-flammable, non-conductive)
enum BaseMaterial {
	DIRT,
	STONE
}

class TerrainTile:
	var type: TerrainType
	var base_material: BaseMaterial
	var move_speed_modifier: float = 1.0
	var noisiness: float = 1.0
	var flammability: float = 0.0
	var conductivity: float = 0.0
	var is_burning: bool = false
	var is_electrified: bool = false
	var fire_hp: float = 0.0
	var electric_charge: float = 0.0
	
	func _init(terrain_type: TerrainType):
		type = terrain_type
		base_material = BaseMaterial.DIRT
		_set_properties()
	
	func _set_properties():
		match type:
			TerrainType.DIRT:
				move_speed_modifier = 0.9
				noisiness = 0.5
				flammability = 0.0
				conductivity = 0.0
			TerrainType.STONE:
				move_speed_modifier = 1.0
				noisiness = 1.5
				flammability = 0.0
				conductivity = 0.0
			TerrainType.WOOD_FLOOR:
				move_speed_modifier = 1.1
				noisiness = 1.2
				flammability = 0.8
				conductivity = 0.0
				fire_hp = 20.0
			TerrainType.GRASS:
				move_speed_modifier = 0.95
				noisiness = 0.3
				flammability = 0.6
				conductivity = 0.0
				fire_hp = 10.0
			TerrainType.GRAVEL:
				move_speed_modifier = 0.85
				noisiness = 2.0
				flammability = 0.0
				conductivity = 0.0
			TerrainType.METAL_FLOOR:
				move_speed_modifier = 1.0
				noisiness = 1.8
				flammability = 0.0
				conductivity = 0.9
			TerrainType.WATER:
				move_speed_modifier = 0.5
				noisiness = 1.5
				flammability = 0.0
				conductivity = 0.7
			TerrainType.FIRE:
				move_speed_modifier = 0.1  # Very slow, damages
				noisiness = 2.0
				flammability = 0.0
				conductivity = 0.0
			TerrainType.ELECTRIC:
				move_speed_modifier = 0.3  # Slow, damages
				noisiness = 1.0
				flammability = 0.0
				conductivity = 1.0

var terrain_map: Array = []
var astar: AStar2D
func _get_point_id(x: int, y: int) -> int:
	return y * map_width + x
# Helper function to update AStar costs when a tile changes
func _update_pathfinding_costs_for_tile(grid_pos: Vector2i):
	var x = grid_pos.x
	var y = grid_pos.y
	
	# Update the weight of the neighbors pointing to this tile
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			
			var nx = x + dx
			var ny = y + dy
			
			if nx >= 0 and nx < map_width and ny >= 0 and ny < map_height:
				var neighbor_id = _get_point_id(nx, ny)
				var current_id = _get_point_id(x, y)
				
				var is_diagonal = abs(dx) + abs(dy) == 2
				var base_cost = sqrt(2) if is_diagonal else 1.0
				
				var terrain = terrain_map[x][y] # The terrain of the destination tile
				var cost = base_cost / terrain.move_speed_modifier
				
				if terrain.is_burning or terrain.is_electrified:
					cost *= 10.0
				
				# Update the connection from the neighbor to the current tile
				astar.connect_points(neighbor_id, current_id, false)
				# This is a bit of a workaround since you can't directly set a connection's weight.
				# You might need a more robust system for this if you change terrain frequently.
				# For now, we're just updating the weight scale of the destination point.
				astar.set_point_weight_scale(current_id, cost)
					
func set_terrain(grid_pos: Vector2i, new_type: TerrainType):
	# Check if the coordinates are within the map boundaries
	if grid_pos.x >= 0 and grid_pos.x < map_width and grid_pos.y >= 0 and grid_pos.y < map_height:
		# Create a new terrain tile and assign it to the map
		terrain_map[grid_pos.x][grid_pos.y] = TerrainTile.new(new_type)
		
		# After changing the terrain, you must update the pathfinding costs
		_update_pathfinding_costs_for_tile(grid_pos)

func ignite_tile(world_pos: Vector2):
	var grid_pos = Vector2i(world_pos / tile_size)
	if grid_pos.x >= 0 and grid_pos.x < map_width and grid_pos.y >= 0 and grid_pos.y < map_height:
		var tile = terrain_map[grid_pos.x][grid_pos.y]
		if tile.flammability > 0 and not tile.is_burning:
			tile.is_burning = true
			_update_pathfinding_costs_for_tile(grid_pos)

func electrify_tile(world_pos: Vector2, charge: float):
	var grid_pos = Vector2i(world_pos / tile_size)
	if grid_pos.x >= 0 and grid_pos.x < map_width and grid_pos.y >= 0 and grid_pos.y < map_height:
		var tile = terrain_map[grid_pos.x][grid_pos.y]
		if tile.conductivity > 0 and not tile.is_electrified:
			tile.is_electrified = true
			tile.electric_charge = charge
			_update_pathfinding_costs_for_tile(grid_pos)
			
func get_noise_modifier(world_pos: Vector2) -> float:
	# Convert the world position (e.g., a character's position) to a grid coordinate.
	var grid_pos = Vector2i(world_pos / tile_size)
	
	# Check if the coordinate is within the map's boundaries.
	if grid_pos.x >= 0 and grid_pos.x < map_width and grid_pos.y >= 0 and grid_pos.y < map_height:
		# If it's on the map, get the tile...
		var tile = terrain_map[grid_pos.x][grid_pos.y]
		# ...and return its noisiness value.
		return tile.noisiness
	
	# If the position is outside the map, return a neutral default value.
	return 1.0
			
signal path_calculated(path)

func _ready():
	_initialize_terrain()
	_initialize_pathfinding()
	set_process(true)

func _initialize_terrain():
	terrain_map.resize(map_width)
	for x in range(map_width):
		terrain_map[x] = []
		terrain_map[x].resize(map_height)
		for y in range(map_height):
			# Default to grass
			terrain_map[x][y] = TerrainTile.new(TerrainType.GRASS)

func _initialize_pathfinding():
	astar = AStar2D.new()
	
	# Add all points
	for x in range(map_width):
		for y in range(map_height):
			var id = _get_point_id(x, y)
			var world_pos = Vector2(x * tile_size, y * tile_size)
			astar.add_point(id, world_pos)
	
	# Connect points
	for x in range(map_width):
		for y in range(map_height):
			var id = _get_point_id(x, y)
			
			# Connect to 8 neighbors
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					if dx == 0 and dy == 0:
						continue
					
					var nx = x + dx
					var ny = y + dy
					
					if nx >= 0 and nx < map_width and ny >= 0 and ny < map_height:
						var neighbor_id = _get_point_id(nx, ny)
						var is_diagonal = abs(dx) + abs(dy) == 2
						var base_cost = sqrt(2) if is_diagonal else 1.0
						
						# Adjust cost based on terrain
						var terrain = terrain_map[nx][ny]
						var cost = base_cost / terrain.move_speed_modifier
						
						# Add penalty for damaging terrain
						if terrain.is_burning or terrain.is_electrified:
							cost *= 10.0  # Heavy penalty
						
						astar.connect_points(id, neighbor_id, false)
						astar.set_point_weight_scale(neighbor_id, cost)
