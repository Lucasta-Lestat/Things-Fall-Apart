# res://FluidManager.gd
# Manages fluid simulation and applies conditions to characters standing in fluids
class_name FluidManager
extends Node2D

const WaterTile = preload("res://Fluid.tscn")

# Fluid simulation constants
const FLUID_TYPE_WATER = "water"
const PUDDLE_HEIGHT = 0.01
const PRESSURE_COEFFICIENT = 1.0
const FLOW_RATE = 0.1
const EVAPORATION_RATE = 0.01

# Flow tracking for visualization
var flow_directions: Dictionary = {}  # Dictionary[Vector2i, Vector2]
var flow_speeds: Dictionary = {}  # Dictionary[Vector2i, float]

# Fluid data: Dictionary[Vector2i, Dictionary[String, float]]
var fluid_grid: Dictionary = {}

# Track which tiles need updating
var active_fluid_tiles: Dictionary = {}

# Fluid database loaded from fluids.json
var _fluid_db: Dictionary = {}

# Condition application timer per fluid type per tile
var _condition_timers: Dictionary = {}  # Dictionary[Vector2i, float]

func _ready() -> void:
	_load_fluid_database()
	if TimeManager:
		TimeManager.connect("time_updated", _on_time_updated)

func _load_fluid_database() -> void:
	var file_path = "res://data/fluids.json"
	if not FileAccess.file_exists(file_path):
		push_error("FluidManager: fluids.json not found at " + file_path)
		return
	var file = FileAccess.open(file_path, FileAccess.READ)
	var json = JSON.new()
	if json.parse(file.get_as_text()) == OK:
		_fluid_db = json.get_data().get("fluids", {})
	else:
		push_error("FluidManager: Failed to parse fluids.json")

func _on_time_updated(hour: int, minute: int, second: int) -> void:
	if minute % 3 == 0 and second % 60 == 0:
		update_fluid_simulation()

# --- Condition Application (modeled after FogOverlay) ---

func update_fluid_conditions(delta: float, characters: Array) -> void:
	"""Check each character's position against fluid tiles and apply conditions."""
	for tile_pos in fluid_grid:
		for fluid_type in fluid_grid[tile_pos]:
			var amount = fluid_grid[tile_pos][fluid_type]
			if amount < PUDDLE_HEIGHT:
				continue

			# Look up fluid definition
			if not _fluid_db.has(fluid_type):
				continue
			var fluid_def = _fluid_db[fluid_type]
			var condition_id = fluid_def.get("condition_id", "")
			if condition_id.is_empty():
				continue

			var apply_interval = fluid_def.get("apply_interval", 1.0)
			var stacks = int(fluid_def.get("condition_stacks", 1))

			# Update timer for this tile
			var timer_key = tile_pos
			if not _condition_timers.has(timer_key):
				_condition_timers[timer_key] = 0.0
			_condition_timers[timer_key] += delta
			if _condition_timers[timer_key] < apply_interval:
				continue
			_condition_timers[timer_key] = 0.0

			# Check each character
			for character in characters:
				if not is_instance_valid(character):
					continue
				if not character.has_method("is_alive") or not character.is_alive():
					continue
				var char_tile = GridManager.world_to_map(character.global_position)
				if char_tile != tile_pos:
					continue
				var cm = character.get_node_or_null("ConditionManager")
				if not cm and character.has_method("get_condition_manager"):
					cm = character.get_condition_manager()
				if cm:
					cm.apply_condition(condition_id, null, stacks)

# --- Fluid Registration ---

func register_fluid(tile_pos: Vector2i, fluid_type: String, amount: float) -> void:
	if amount <= 0:
		return
	if not fluid_grid.has(tile_pos):
		fluid_grid[tile_pos] = {}
	var is_new_tile = not fluid_grid[tile_pos].has(fluid_type) or fluid_grid[tile_pos].get(fluid_type, 0.0) < PUDDLE_HEIGHT
	if not fluid_grid[tile_pos].has(fluid_type):
		fluid_grid[tile_pos][fluid_type] = 0.0
	fluid_grid[tile_pos][fluid_type] += amount

	# Spawn a visual tile if this is a new fluid tile
	if is_new_tile and fluid_grid[tile_pos][fluid_type] >= PUDDLE_HEIGHT:
		if not active_fluid_tiles.has(tile_pos) or not is_instance_valid(active_fluid_tiles.get(tile_pos)):
			_create_fluid_visual(tile_pos, fluid_type, fluid_grid[tile_pos][fluid_type])

	if not active_fluid_tiles.has(tile_pos):
		active_fluid_tiles[tile_pos] = true

	# Also update GridManager's fluids dict for pathfinding awareness
	GridManager.fluids[tile_pos] = fluid_type

func get_fluid_amount(tile_pos: Vector2i, fluid_type: String) -> float:
	if fluid_grid.has(tile_pos) and fluid_grid[tile_pos].has(fluid_type):
		return fluid_grid[tile_pos][fluid_type]
	return 0.0

func get_fluid_type_at(tile_pos: Vector2i) -> String:
	"""Returns the primary fluid type at a tile, or empty string."""
	if not fluid_grid.has(tile_pos):
		return ""
	for fluid_type in fluid_grid[tile_pos]:
		if fluid_grid[tile_pos][fluid_type] > PUDDLE_HEIGHT:
			return fluid_type
	return ""

func is_fluid_flammable(tile_pos: Vector2i) -> bool:
	"""Returns whether the fluid at this tile is flammable."""
	var fluid_type = get_fluid_type_at(tile_pos)
	if fluid_type.is_empty():
		return false
	if not _fluid_db.has(fluid_type):
		return false
	return _fluid_db[fluid_type].get("flammable", false)

func remove_fluid(tile_pos: Vector2i, amount: float) -> void:
	"""Reduces the fluid amount at a tile (e.g. fire consuming oil)."""
	if not fluid_grid.has(tile_pos):
		return
	for fluid_type in fluid_grid[tile_pos]:
		fluid_grid[tile_pos][fluid_type] = max(0.0, fluid_grid[tile_pos][fluid_type] - amount)
	# Clean up if all fluids are gone
	var total = 0.0
	for fluid_type in fluid_grid[tile_pos]:
		total += fluid_grid[tile_pos][fluid_type]
	if total < PUDDLE_HEIGHT:
		remove_fluid_tile(tile_pos)

func is_conductive(tile_pos: Vector2i) -> bool:
	"""Returns whether the fluid at this tile conducts electricity."""
	var fluid_type = get_fluid_type_at(tile_pos)
	if fluid_type.is_empty():
		return false
	if not _fluid_db.has(fluid_type):
		return false
	return _fluid_db[fluid_type].get("conductive", false)

# --- Fluid Simulation ---

func calculate_pressure(tile_pos: Vector2i, fluid_type: String) -> float:
	var amount = get_fluid_amount(tile_pos, fluid_type)
	if amount <= PUDDLE_HEIGHT:
		return 0.0
	return (amount - PUDDLE_HEIGHT) * PRESSURE_COEFFICIENT

func update_fluid_simulation() -> void:
	if active_fluid_tiles.is_empty():
		return

	var flow_deltas: Dictionary = {}
	flow_directions.clear()
	flow_speeds.clear()

	var tiles_to_process = active_fluid_tiles.duplicate()

	for tile_pos in tiles_to_process:
		for fluid_type in fluid_grid.get(tile_pos, {}).keys():
			var amount = get_fluid_amount(tile_pos, fluid_type)
			if amount < PUDDLE_HEIGHT:
				continue

			var pressure = calculate_pressure(tile_pos, fluid_type)
			var total_flow_vector = Vector2.ZERO
			var total_flow_amount = 0.0

			var neighbors = get_neighbors(tile_pos)

			for neighbor_pos in neighbors:
				if GridManager.walls.get(neighbor_pos, true):
					continue
				var neighbor_pressure = calculate_pressure(neighbor_pos, fluid_type)
				var pressure_diff = pressure - neighbor_pressure

				if pressure_diff > 0:
					var flow_amount = min(
						amount * FLOW_RATE * (pressure_diff / (pressure + 0.1)),
						amount - PUDDLE_HEIGHT
					)
					if flow_amount > PUDDLE_HEIGHT:
						if not flow_deltas.has(tile_pos):
							flow_deltas[tile_pos] = {}
						if not flow_deltas[tile_pos].has(fluid_type):
							flow_deltas[tile_pos][fluid_type] = 0.0
						if not flow_deltas.has(neighbor_pos):
							flow_deltas[neighbor_pos] = {}
						if not flow_deltas[neighbor_pos].has(fluid_type):
							flow_deltas[neighbor_pos][fluid_type] = 0.0

						flow_deltas[tile_pos][fluid_type] -= flow_amount
						flow_deltas[neighbor_pos][fluid_type] += flow_amount

						var direction_to_neighbor = Vector2(neighbor_pos - tile_pos).normalized()
						total_flow_vector += direction_to_neighbor * flow_amount
						total_flow_amount += flow_amount

			if total_flow_amount > 0.0:
				flow_directions[tile_pos] = total_flow_vector.normalized()
				flow_speeds[tile_pos] = clamp(total_flow_amount / amount, 0.0, 1.0)
			else:
				flow_directions[tile_pos] = Vector2.ZERO
				flow_speeds[tile_pos] = 0.0

			if amount > PUDDLE_HEIGHT:
				if not flow_deltas.has(tile_pos):
					flow_deltas[tile_pos] = {}
				if not flow_deltas[tile_pos].has(fluid_type):
					flow_deltas[tile_pos][fluid_type] = 0.0
				flow_deltas[tile_pos][fluid_type] -= EVAPORATION_RATE

	apply_flow_deltas(flow_deltas)
	update_water_tile_flows()
	cleanup_inactive_tiles()

func apply_flow_deltas(flow_deltas: Dictionary) -> void:
	for tile_pos in flow_deltas.keys():
		for fluid_type in flow_deltas[tile_pos].keys():
			var delta = flow_deltas[tile_pos][fluid_type]
			if not fluid_grid.has(tile_pos):
				fluid_grid[tile_pos] = {}
			if not fluid_grid[tile_pos].has(fluid_type):
				fluid_grid[tile_pos][fluid_type] = 0.0
			fluid_grid[tile_pos][fluid_type] += delta
			fluid_grid[tile_pos][fluid_type] = max(0.0, fluid_grid[tile_pos][fluid_type])

			if fluid_grid[tile_pos][fluid_type] > PUDDLE_HEIGHT and not active_fluid_tiles.has(tile_pos):
				active_fluid_tiles[tile_pos] = true
				spawn_fluid_tile(tile_pos, fluid_grid[tile_pos][fluid_type])

			# Water flowing into a tile extinguishes fire
			if fluid_type == FLUID_TYPE_WATER and fluid_grid[tile_pos][fluid_type] > PUDDLE_HEIGHT:
				var game = get_tree().get_first_node_in_group("game")
				if not game:
					game = get_tree().current_scene
				if game and "surface_manager" in game and game.surface_manager:
					game.surface_manager.try_extinguish(tile_pos)

func get_neighbors(tile_pos: Vector2i) -> Array[Vector2i]:
	var neighbors: Array[Vector2i] = []
	neighbors.append(Vector2i(tile_pos.x, tile_pos.y + 1))
	neighbors.append(Vector2i(tile_pos.x - 1, tile_pos.y))
	neighbors.append(Vector2i(tile_pos.x + 1, tile_pos.y))
	neighbors.append(Vector2i(tile_pos.x, tile_pos.y - 1))
	return neighbors

func cleanup_inactive_tiles() -> void:
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

func get_all_fluid_data() -> Dictionary:
	return fluid_grid.duplicate(true)

func get_active_tile_count() -> int:
	return active_fluid_tiles.size()

func _create_fluid_visual(grid_pos: Vector2i, fluid_type: String, amount: float) -> void:
	"""Instantiate a visible fluid tile node at the given grid position."""
	var fluid_node = WaterTile.instantiate()
	add_child(fluid_node)
	fluid_node.initialize(grid_pos, amount)

	# Apply fluid-type-specific shader and colors from the database
	if _fluid_db.has(fluid_type):
		var fluid_def = _fluid_db[fluid_type]

		# Custom shader (e.g. oil sheen) — must be set before colors
		var shader_path = fluid_def.get("shader", "")
		if not shader_path.is_empty() and fluid_node.has_method("set_custom_shader"):
			fluid_node.set_custom_shader(shader_path)

		# Colors
		if fluid_node.has_method("set_fluid_colors"):
			var color_arr = fluid_def.get("color", [0.0, 0.4, 0.8, 0.7])
			var wave_arr = fluid_def.get("wave_color", [0.0, 0.9, 1.0, 0.4])
			var water_color = Color(color_arr[0], color_arr[1], color_arr[2], color_arr[3])
			var wave_color = Color(wave_arr[0], wave_arr[1], wave_arr[2], wave_arr[3])
			fluid_node.set_fluid_colors(water_color, wave_color)

	active_fluid_tiles[grid_pos] = fluid_node

func spawn_fluid_tile(grid_pos: Vector2i, water_amount: float) -> void:
	register_fluid(grid_pos, "water", water_amount)

func update_fluid_tile(grid_pos: Vector2i, water_amount: float) -> void:
	var water_tile = active_fluid_tiles.get(grid_pos)
	if water_tile and is_instance_valid(water_tile):
		water_tile.set_water_depth(water_amount)

func remove_fluid_tile(grid_pos: Vector2i) -> void:
	if not active_fluid_tiles.has(grid_pos):
		return
	var water_tile = active_fluid_tiles[grid_pos]
	if water_tile and is_instance_valid(water_tile):
		water_tile.queue_free()
	active_fluid_tiles.erase(grid_pos)
	if fluid_grid.has(grid_pos):
		fluid_grid.erase(grid_pos)
	flow_directions.erase(grid_pos)
	flow_speeds.erase(grid_pos)
	_condition_timers.erase(grid_pos)

func clear_all_water_tiles() -> void:
	for pos in active_fluid_tiles.keys():
		remove_fluid_tile(pos)
	_condition_timers.clear()

func update_water_tile_flows() -> void:
	for grid_pos in active_fluid_tiles.keys():
		var water_tile = active_fluid_tiles[grid_pos]
		if water_tile and is_instance_valid(water_tile):
			var flow_dir = flow_directions.get(grid_pos, Vector2.ZERO)
			var flow_speed = flow_speeds.get(grid_pos, 0.0)
			water_tile.set_flow_direction(flow_dir, flow_speed)
			var water_amount = get_fluid_amount(grid_pos, FLUID_TYPE_WATER)
			if water_amount > 0:
				water_tile.set_water_depth(water_amount)
