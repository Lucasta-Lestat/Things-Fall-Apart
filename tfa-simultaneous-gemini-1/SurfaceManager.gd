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

	for tile_pos in surface_grid:
		if surface_grid[tile_pos]["surface_id"] != "fire":
			continue
		var neighbors = GridManager.get_neighboring_coords(tile_pos)
		for neighbor in neighbors:
			if surface_grid.has(neighbor):
				continue  # Already burning
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
				floor_node.take_damage(damage_per_tick.duplicate(), 0)

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

func try_ignite(tile_pos: Vector2i) -> void:
	"""Attempt to ignite a single tile. Checks fluids first (flood-fill), then floors."""
	if surface_grid.has(tile_pos):
		return  # Already burning

	# Check flammable fluid first
	var game = _get_game()
	var fluid_manager = _get_fluid_manager(game)
	if fluid_manager and fluid_manager.is_fluid_flammable(tile_pos):
		var fluid_type = fluid_manager.get_fluid_type_at(tile_pos)
		_ignite_fluid_body(tile_pos, fluid_type, fluid_manager)
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
	var vfx_path = fire_def.get("vfx_scene", "res://vfx/fire.tscn")
	var vfx_scene = load(vfx_path)
	if not vfx_scene:
		return null
	var vfx = vfx_scene.instantiate()
	vfx.global_position = GridManager.map_to_world(tile_pos)
	add_child(vfx)
	if vfx.has_method("play"):
		vfx.play(2.0)
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
	# Check the actual floor node first (it may have been scorched)
	var floor_node = _floor_cache.get(tile_pos)
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
	"""Apply a scorched ash shader to the floor and make it non-flammable."""
	var floor_node = _get_floor_at(tile_pos, game)
	if floor_node and is_instance_valid(floor_node):
		floor_node.flammable = false
		if floor_node.has_node("Sprite"):
			var sprite = floor_node.get_node("Sprite")
			var mat = ShaderMaterial.new()
			mat.shader = SCORCH_SHADER
			mat.set_shader_parameter("ash_color", Color(0.08, 0.06, 0.05, 1.0))
			mat.set_shader_parameter("ember_color", Color(0.15, 0.05, 0.02, 1.0))
			mat.set_shader_parameter("scorch_amount", 0.85)
			sprite.material = mat

func _get_floor_at(tile_pos: Vector2i, game: Node) -> Node:
	"""Find the Floor node at a tile position by scanning MapLoader children."""
	if _floor_cache_dirty:
		_rebuild_floor_cache(game)
	return _floor_cache.get(tile_pos)

func _rebuild_floor_cache(game: Node) -> void:
	_floor_cache.clear()
	if not game or not game.has_node("MapLoader"):
		_floor_cache_dirty = false
		return
	var map_loader = game.get_node("MapLoader")
	for child in map_loader.get_children():
		if child is Floor:
			var grid_pos = GridManager.world_to_map(child.global_position)
			_floor_cache[grid_pos] = child
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
