# res://SurfaceManager.gd
# Manages grid-based surface effects (fire, etc.) and applies conditions to entities within them.
# Analogous to FogManager and FluidManager.
class_name SurfaceManager
extends Node2D

# Surface data loaded from surfaces.json
var _surface_defs: Dictionary = {}

# Active surface tiles: Dictionary[Vector2i, Dictionary]
# Each entry: { "surface_id": String, "time_remaining": float, "vfx_node": Node, "source_type": String }
# source_type is "floor", "fluid", or "direct"
var surface_grid: Dictionary = {}

# Per-character condition application cooldowns: Dictionary[int, float]
# Keyed by character instance_id to avoid reapplying every frame
var _condition_timers: Dictionary = {}

# Timer accumulators
var _spread_timer: float = 0.0
var _damage_timer: float = 0.0

# Floor node cache: Dictionary[Vector2i, Floor] — rebuilt on demand
var _floor_cache: Dictionary = {}
var _floor_cache_dirty: bool = true

func _ready() -> void:
	_load_surface_database()

func _load_surface_database() -> void:
	var file_path = "res://data/surfaces.json"
	if not FileAccess.file_exists(file_path):
		push_error("SurfaceManager: surfaces.json not found at " + file_path)
		return
	var file = FileAccess.open(file_path, FileAccess.READ)
	var json = JSON.new()
	if json.parse(file.get_as_text()) == OK:
		_surface_defs = json.get_data().get("surfaces", {})
	else:
		push_error("SurfaceManager: Failed to parse surfaces.json")

# --- Main Update (called from Game._process) ---

func update_surfaces(delta: float, characters: Array, game: Node) -> void:
	if surface_grid.is_empty():
		return
	_apply_conditions_to_characters(delta, characters)
	_process_spread(delta, game)
	_process_damage(delta, game)
	_process_lifetime(delta, game)

# --- Condition Application ---

func _apply_conditions_to_characters(delta: float, characters: Array) -> void:
	for tile_pos in surface_grid:
		var tile_data = surface_grid[tile_pos]
		var surface_def = _surface_defs.get(tile_data["surface_id"], {})
		var condition_id = surface_def.get("condition_id", "")
		if condition_id.is_empty():
			continue
		var apply_interval = surface_def.get("apply_interval", 1.0)
		var stacks = int(surface_def.get("condition_stacks", 1))

		for character in characters:
			if not is_instance_valid(character):
				continue
			if character.has_method("is_alive") and not character.is_alive():
				continue
			var char_tile = GridManager.world_to_map(character.global_position)
			if char_tile != tile_pos:
				continue

			# Per-character timer
			var char_id = character.get_instance_id()
			if not _condition_timers.has(char_id):
				_condition_timers[char_id] = 0.0
			_condition_timers[char_id] += delta
			if _condition_timers[char_id] < apply_interval:
				continue
			_condition_timers[char_id] = 0.0

			var cm = character.get_node_or_null("ConditionManager")
			if not cm and character.has_method("get_condition_manager"):
				cm = character.get_condition_manager()
			if cm:
				cm.apply_condition(condition_id, null, stacks)

# --- Fire Spread ---

func _process_spread(delta: float, game: Node) -> void:
	var fire_def = _surface_defs.get("fire", {})
	var spread_interval = fire_def.get("spread_interval", 2.0)
	_spread_timer += delta
	if _spread_timer < spread_interval:
		return
	_spread_timer = 0.0

	var spread_chance = fire_def.get("spread_chance", 0.4)
	var tiles_to_ignite: Array[Vector2i] = []

	# Get wind from the current map's weather group
	var wind_dir := Vector2.ZERO
	var wind_speed := 0.0
	var weather_group := _get_map_weather_group(game)
	if not weather_group.is_empty():
		wind_dir = WeatherManager.get_wind_direction(weather_group)
		wind_speed = WeatherManager.get_wind_speed(weather_group)

	for tile_pos in surface_grid:
		if surface_grid[tile_pos]["surface_id"] != "fire":
			continue
		var neighbors = GridManager.get_neighboring_coords(tile_pos)
		for neighbor in neighbors:
			if surface_grid.has(neighbor):
				continue  # Already burning

			# Wind blocks fire from spreading against its direction
			if wind_speed > 10.0 and wind_dir.length() > 0.01:
				var spread_dir = Vector2(neighbor - tile_pos).normalized()
				var dot = spread_dir.dot(wind_dir.normalized())
				# dot < 0 means spreading against the wind — block it
				if dot < -0.1:
					continue

			if randf() > spread_chance:
				continue
			# Check if neighbor is flammable
			if _is_tile_flammable(neighbor, game):
				tiles_to_ignite.append(neighbor)

	for tile_pos in tiles_to_ignite:
		_ignite_tile(tile_pos, "floor")

# --- Fire Damage to Floors/Structures/Fluids ---

func _process_damage(delta: float, game: Node) -> void:
	var fire_def = _surface_defs.get("fire", {})
	var damage_interval = fire_def.get("damage_interval", 1.0)
	_damage_timer += delta
	if _damage_timer < damage_interval:
		return
	_damage_timer = 0.0

	var damage_per_tick = fire_def.get("damage_per_tick", {"fire": 10})
	var fluid_consume_rate = fire_def.get("fluid_consume_rate", 0.05)

	var tiles_to_remove: Array[Vector2i] = []

	for tile_pos in surface_grid:
		if surface_grid[tile_pos]["surface_id"] != "fire":
			continue
		var source_type = surface_grid[tile_pos].get("source_type", "floor")

		if source_type == "fluid":
			# Consume the fluid
			var fluid_manager = _get_fluid_manager(game)
			if fluid_manager:
				fluid_manager.remove_fluid(tile_pos, fluid_consume_rate)
				# If fluid is gone, fire on this tile goes out
				var remaining = fluid_manager.get_fluid_type_at(tile_pos)
				if remaining.is_empty():
					tiles_to_remove.append(tile_pos)
		else:
			# Damage the floor
			var floor_node = _get_floor_at(tile_pos, game)
			if floor_node and is_instance_valid(floor_node):
				var was_alive = floor_node.current_health > 0
				floor_node.take_damage(damage_per_tick.duplicate(), 0)
				# Scorch immediately when the floor dies from fire
				if was_alive and floor_node.current_health <= 0:
					var scorch_color_arr = _surface_defs.get("fire", {}).get("scorch_color", [0.15, 0.12, 0.1, 1.0])
					var sc = Color(scorch_color_arr[0], scorch_color_arr[1], scorch_color_arr[2], scorch_color_arr[3])
					_scorch_floor(tile_pos, sc, game)

		# Damage structures on this tile
		if game and "structures_in_scene" in game:
			for structure in game.structures_in_scene:
				if not is_instance_valid(structure):
					continue
				if tile_pos in structure.occupied_tiles:
					structure.take_damage(damage_per_tick.duplicate(), 0)

	for tile_pos in tiles_to_remove:
		_remove_surface(tile_pos)

# --- Lifetime / Burnout ---

func _process_lifetime(delta: float, game: Node) -> void:
	var fire_def = _surface_defs.get("fire", {})
	var scorch_color_arr = fire_def.get("scorch_color", [0.15, 0.12, 0.1, 1.0])
	var scorch_color = Color(scorch_color_arr[0], scorch_color_arr[1], scorch_color_arr[2], scorch_color_arr[3])

	var tiles_to_scorch: Array[Vector2i] = []

	for tile_pos in surface_grid:
		var time_rem = surface_grid[tile_pos]["time_remaining"]
		# Surfaces with duration -1 (ice) never expire
		if time_rem < 0:
			continue
		surface_grid[tile_pos]["time_remaining"] -= delta
		if surface_grid[tile_pos]["time_remaining"] <= 0.0:
			tiles_to_scorch.append(tile_pos)

	for tile_pos in tiles_to_scorch:
		var source_type = surface_grid[tile_pos].get("source_type", "floor")
		if source_type != "fluid":
			_scorch_floor(tile_pos, scorch_color, game)
		_remove_surface(tile_pos)

# --- Ignition API ---

func try_ignite_area(center_world: Vector2, radius: float) -> void:
	"""Attempt to ignite all flammable tiles within a world-space radius."""
	var center_tile = GridManager.world_to_map(center_world)
	var tile_radius = int(ceil(radius / GridManager.TILE_SIZE))

	for dx in range(-tile_radius, tile_radius + 1):
		for dy in range(-tile_radius, tile_radius + 1):
			var tile_pos = center_tile + Vector2i(dx, dy)
			var tile_world = GridManager.map_to_world(tile_pos)
			if center_world.distance_to(tile_world) <= radius:
				try_ignite(tile_pos)

func place_surface_in_area(surface_id: String, center_world: Vector2, radius: float, duration_override: float = -2.0) -> int:
	"""Place a surface (other than fire — use try_ignite for that) on every tile in radius.
	Overwrites nothing already occupied. Returns the number of tiles placed."""
	var surface_def = _surface_defs.get(surface_id, {})
	if surface_def.is_empty():
		push_warning("SurfaceManager: unknown surface_id '%s'" % surface_id)
		return 0
	var duration: float = duration_override if duration_override > -2.0 else surface_def.get("base_duration", 10.0)
	var center_tile = GridManager.world_to_map(center_world)
	var tile_radius = int(ceil(radius / GridManager.TILE_SIZE))
	var placed: int = 0
	for dx in range(-tile_radius, tile_radius + 1):
		for dy in range(-tile_radius, tile_radius + 1):
			var tile_pos = center_tile + Vector2i(dx, dy)
			var tile_world = GridManager.map_to_world(tile_pos)
			if center_world.distance_to(tile_world) > radius:
				continue
			if surface_grid.has(tile_pos):
				continue
			var vfx_node = _spawn_surface_vfx(tile_pos, surface_def)
			surface_grid[tile_pos] = {
				"surface_id": surface_id,
				"time_remaining": duration,
				"vfx_node": vfx_node,
				"source_type": "direct"
			}
			placed += 1
	return placed

func try_ignite(tile_pos: Vector2i) -> void:
	"""Attempt to ignite a single tile. Checks fluids first (flood-fill), then floors."""
	if surface_grid.has(tile_pos):
		# Fire hitting ice → thaw the ice instead of igniting
		if surface_grid[tile_pos]["surface_id"] == "ice":
			thaw_ice_at(tile_pos)
		return  # Already has a surface

	var game = _get_game()
	var fluid_manager = _get_fluid_manager(game)

	# Check flammable fluid first (flood-fill ignition)
	if fluid_manager and fluid_manager.is_fluid_flammable(tile_pos):
		var fluid_type = fluid_manager.get_fluid_type_at(tile_pos)
		_ignite_fluid_body(tile_pos, fluid_type, fluid_manager)
		return

	# Non-flammable fluid blocks fire from reaching the floor (e.g. water)
	if fluid_manager:
		var fluid_type = fluid_manager.get_fluid_type_at(tile_pos)
		if not fluid_type.is_empty():
			return  # Has non-flammable fluid — can't ignite

	# Non-flammable structure blocks fire
	if game and "structures_in_scene" in game:
		for structure in game.structures_in_scene:
			if is_instance_valid(structure) and tile_pos in structure.occupied_tiles:
				if not structure.flammable:
					return
				else:
					_ignite_tile(tile_pos, "floor")
					return

	# Check flammable floor
	if _is_floor_flammable(tile_pos):
		_ignite_tile(tile_pos, "floor")

func _ignite_fluid_body(start_tile: Vector2i, fluid_type: String, fluid_manager: FluidManager) -> void:
	"""BFS flood-fill to ignite an entire contiguous body of flammable fluid."""
	var visited: Dictionary = {}
	var queue: Array[Vector2i] = [start_tile]
	visited[start_tile] = true

	while not queue.is_empty():
		var tile = queue.pop_front()
		if not surface_grid.has(tile):
			_ignite_tile(tile, "fluid")

		var neighbors = GridManager.get_neighboring_coords(tile)
		for neighbor in neighbors:
			if visited.has(neighbor):
				continue
			visited[neighbor] = true
			var neighbor_fluid = fluid_manager.get_fluid_type_at(neighbor)
			if neighbor_fluid == fluid_type:
				queue.append(neighbor)

func _ignite_tile(tile_pos: Vector2i, source_type: String) -> void:
	"""Ignite a single tile with fire."""
	if surface_grid.has(tile_pos):
		return
	var fire_def = _surface_defs.get("fire", {})
	var duration = fire_def.get("base_duration", 10.0)
	var vfx_node = _spawn_fire_vfx(tile_pos, fire_def)

	surface_grid[tile_pos] = {
		"surface_id": "fire",
		"time_remaining": duration,
		"vfx_node": vfx_node,
		"source_type": source_type
	}

func try_extinguish(tile_pos: Vector2i) -> void:
	"""Extinguish fire at a tile (e.g. water flowing in)."""
	if surface_grid.has(tile_pos) and surface_grid[tile_pos]["surface_id"] == "fire":
		_remove_surface(tile_pos)

func has_surface_at(tile_pos: Vector2i) -> bool:
	return surface_grid.has(tile_pos)

func get_surface_id_at(tile_pos: Vector2i) -> String:
	if surface_grid.has(tile_pos):
		return surface_grid[tile_pos].get("surface_id", "")
	return ""

func is_ice_at(tile_pos: Vector2i) -> bool:
	return get_surface_id_at(tile_pos) == "ice"

# --- Ice / Freeze API ---

func try_freeze_at(tile_pos: Vector2i) -> void:
	"""Freeze the contiguous fluid body at tile_pos into ice surfaces."""
	var game = _get_game()
	var fluid_manager = _get_fluid_manager(game)
	if not fluid_manager:
		return
	var fluid_type = fluid_manager.get_fluid_type_at(tile_pos)
	if fluid_type.is_empty():
		return

	var amount = fluid_manager.get_fluid_amount(tile_pos, fluid_type)
	var frozen_tiles = fluid_manager.freeze_fluid_at(tile_pos)
	for tile in frozen_tiles:
		_place_ice(tile, fluid_type, amount)

func try_freeze_all_fluids() -> void:
	"""Freeze every fluid tile on the map (e.g. when snow starts)."""
	var game = _get_game()
	var fluid_manager = _get_fluid_manager(game)
	if not fluid_manager:
		return
	var frozen_data = fluid_manager.freeze_all_fluids()
	for tile_pos in frozen_data:
		var data = frozen_data[tile_pos]
		_place_ice(tile_pos, data["fluid_type"], data["amount"])

func _place_ice(tile_pos: Vector2i, frozen_fluid_type: String, frozen_fluid_amount: float) -> void:
	"""Place an ice surface on a tile, recording what fluid was frozen."""
	if surface_grid.has(tile_pos):
		# If there's fire here, remove it first
		if surface_grid[tile_pos]["surface_id"] == "fire":
			_remove_surface(tile_pos)
		else:
			return  # Don't overwrite other surfaces
	var ice_def = _surface_defs.get("ice", {})
	var vfx_node = _spawn_surface_vfx(tile_pos, ice_def)
	surface_grid[tile_pos] = {
		"surface_id": "ice",
		"time_remaining": -1.0,  # Never expires naturally
		"vfx_node": vfx_node,
		"source_type": "frozen_fluid",
		"frozen_fluid_type": frozen_fluid_type,
		"frozen_fluid_amount": frozen_fluid_amount
	}

func thaw_ice_at(tile_pos: Vector2i) -> void:
	"""Thaw an ice tile, restoring its original fluid."""
	if not surface_grid.has(tile_pos):
		return
	if surface_grid[tile_pos]["surface_id"] != "ice":
		return
	var fluid_type = surface_grid[tile_pos].get("frozen_fluid_type", "water")
	var fluid_amount = surface_grid[tile_pos].get("frozen_fluid_amount", 0.3)
	_remove_surface(tile_pos)

	var game = _get_game()
	var fluid_manager = _get_fluid_manager(game)
	if fluid_manager:
		fluid_manager.restore_fluid(tile_pos, fluid_type, fluid_amount)

func clear_all_surfaces() -> void:
	for tile_pos in surface_grid.keys():
		_remove_surface(tile_pos)
	_condition_timers.clear()
	_spread_timer = 0.0
	_damage_timer = 0.0
	_floor_cache.clear()
	_floor_cache_dirty = true

# --- Internal Helpers ---

func _remove_surface(tile_pos: Vector2i) -> void:
	if not surface_grid.has(tile_pos):
		return
	var tile_data = surface_grid[tile_pos]
	var vfx = tile_data.get("vfx_node")
	if vfx and is_instance_valid(vfx):
		vfx.queue_free()
	surface_grid.erase(tile_pos)

func _spawn_fire_vfx(tile_pos: Vector2i, fire_def: Dictionary) -> Node:
	return _spawn_surface_vfx(tile_pos, fire_def)

func _spawn_surface_vfx(tile_pos: Vector2i, surface_def: Dictionary) -> Node:
	var vfx_path = surface_def.get("vfx_scene", "")
	if vfx_path.is_empty():
		return null
	var vfx_scene = load(vfx_path)
	if not vfx_scene:
		return null
	var vfx = vfx_scene.instantiate()
	vfx.global_position = GridManager.map_to_world(tile_pos)
	add_child(vfx)
	if vfx.has_method("play"):
		vfx.play(1.0)
	return vfx

func _is_tile_flammable(tile_pos: Vector2i, game: Node) -> bool:
	# Non-flammable fluid on tile blocks fire (e.g. water)
	var fluid_manager = _get_fluid_manager(game)
	if fluid_manager:
		var fluid_type = fluid_manager.get_fluid_type_at(tile_pos)
		if not fluid_type.is_empty():
			# There's fluid here — only flammable if the fluid itself is flammable
			return fluid_manager.is_fluid_flammable(tile_pos)

	# Non-flammable structure on tile blocks fire from reaching the floor underneath
	if game and "structures_in_scene" in game:
		for structure in game.structures_in_scene:
			if not is_instance_valid(structure):
				continue
			if tile_pos in structure.occupied_tiles:
				# Structure is here — fire can only spread if structure is flammable
				return structure.flammable

	# Check floor flammability
	return _is_floor_flammable(tile_pos)

func _is_floor_flammable(tile_pos: Vector2i) -> bool:
	if not GridManager.floors.has(tile_pos):
		return false
	# Check the actual main floor node first (it may have been scorched)
	var game = _get_game()
	var floor_node = _get_floor_at(tile_pos, game)
	if floor_node and is_instance_valid(floor_node):
		return floor_node.flammable
	# Fallback to database definition
	var floor_id = GridManager.floors[tile_pos]
	if not FloorDatabase.floor_definitions.has(floor_id):
		return false
	var floor_data = FloorDatabase.floor_definitions[floor_id]
	return floor_data.get("flammable", false)

const SCORCH_SHADER = preload("res://vfx/shaders/scorched.gdshader")

func _scorch_floor(tile_pos: Vector2i, scorch_color: Color, game: Node) -> void:
	"""Apply a scorched ash shader to ALL floor layers at this tile."""
	var floors = _get_all_floors_at(tile_pos, game)
	if floors.is_empty():
		return
	for floor_node in floors:
		if not is_instance_valid(floor_node):
			continue
		floor_node.flammable = false
		var sprite = floor_node.get_node_or_null("Sprite")
		if not sprite:
			continue
		sprite.visible = true
		var mat = ShaderMaterial.new()
		mat.shader = SCORCH_SHADER
		mat.set_shader_parameter("ash_color", Color(0.08, 0.06, 0.05, 1.0))
		mat.set_shader_parameter("ember_color", Color(0.15, 0.05, 0.02, 1.0))
		mat.set_shader_parameter("scorch_amount", 0.85)
		sprite.material = mat

func _get_floor_at(tile_pos: Vector2i, game: Node) -> Node:
	"""Find the top Floor node at a tile position (highest z_index)."""
	var floors = _get_all_floors_at(tile_pos, game)
	if floors.is_empty():
		return null
	# Return the one with highest z_index (the visible main floor)
	var best = floors[0]
	for f in floors:
		if f.z_index > best.z_index:
			best = f
	return best

func _get_all_floors_at(tile_pos: Vector2i, game: Node) -> Array:
	"""Get all Floor nodes at a tile position (main + under layers)."""
	if _floor_cache_dirty:
		_rebuild_floor_cache(game)
	return _floor_cache.get(tile_pos, [])

func _rebuild_floor_cache(game: Node) -> void:
	_floor_cache.clear()
	if not game or not game.has_node("MapLoader"):
		_floor_cache_dirty = false
		return
	var map_loader = game.get_node("MapLoader")
	for child in map_loader.get_children():
		if child is Floor:
			var grid_pos = GridManager.world_to_map(child.global_position)
			if not _floor_cache.has(grid_pos):
				_floor_cache[grid_pos] = []
			_floor_cache[grid_pos].append(child)
	_floor_cache_dirty = false

func invalidate_floor_cache() -> void:
	_floor_cache_dirty = true

func _get_game() -> Node:
	# Walk up the tree to find the Game node
	var parent = get_parent()
	while parent:
		if parent.has_method("load_map"):
			return parent
		parent = parent.get_parent()
	return null

func _get_fluid_manager(game: Node) -> FluidManager:
	if not game:
		game = _get_game()
	if game and "fluid_manager" in game:
		return game.fluid_manager
	return null

func _get_map_weather_group(game: Node) -> String:
	if not game:
		game = _get_game()
	if game and "current_map_data" in game:
		return game.current_map_data.get("weather_group", "")
	return ""
