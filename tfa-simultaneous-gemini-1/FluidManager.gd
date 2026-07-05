# res://FluidManager.gd
# Manages fluid simulation and applies conditions to characters standing in fluids
class_name FluidManager
extends Node2D

const WaterTile = preload("res://Fluid.tscn")

# Fluid simulation constants
const FLUID_TYPE_WATER = "water"
const PUDDLE_HEIGHT = 0.01
const PRESSURE_COEFFICIENT = 1.0
# Per-second rates (multiplied by SIM_INTERVAL each tick) so changing SIM_INTERVAL
# doesn't accidentally change how fast fluids flow or evaporate.
const FLOW_RATE_PER_SEC: float = 0.05      # matches the pre-tickrate-change behavior
const EVAPORATION_RATE_PER_SEC: float = 0.002  # was effectively 0.005/sec; slower per user feedback
# Minimum flow_amount per tick to apply. Lower than PUDDLE_HEIGHT so small puddles
# can still flow at higher tick rates (where per-tick amounts are small).
const MIN_FLOW_AMOUNT: float = 0.001
# Below this height difference, two tiles are treated as level and don't exchange.
# Kills the perpetual micro-churn that made settled water show random flow.
const FLOW_EPSILON: float = 0.006
# Visual: don't show a current (directional waves) below this flow speed, and ease
# the displayed direction over time so neighbours can't disagree frame-to-frame.
const VISUAL_FLOW_MIN: float = 0.03
const DISPLAY_DIR_EMA: float = 0.3

# Flow tracking for visualization
var flow_directions: Dictionary = {}  # Dictionary[Vector2i, Vector2]
var flow_speeds: Dictionary = {}  # Dictionary[Vector2i, float]
# Temporally-smoothed display flow (direction * speed) per tile, for jitter-free
# visuals — settled water eases to still instead of flickering each sim tick.
var _display_flow: Dictionary = {}  # Dictionary[Vector2i, Vector2]

# Average direction fluid moves AS IT ENTERS each tile (per most-recent sim tick).
# Used by the shader to draw a directional fill front. Cleared each sim tick.
var inflow_directions: Dictionary = {}  # Dictionary[Vector2i, Vector2]

# Amount at which a tile is considered visually "full". Below this it renders
# with a partial fill mask growing from the inflow side. Kept small so that
# typical puddles/blood/oil render solidly and evaporation only affects the
# visual at the very end of a tile's lifetime.
const FULL_THRESHOLD: float = 0.1

# Fluid data: Dictionary[Vector2i, Dictionary[String, float]]
var fluid_grid: Dictionary = {}

# Track which tiles need updating
var active_fluid_tiles: Dictionary = {}

# Fluid database loaded from fluids.json
var _fluid_db: Dictionary = {}

# Condition application timer per fluid type per tile
var _condition_timers: Dictionary = {}  # Dictionary[Vector2i, float]

# Coalesce repeated edge-mask refresh requests within a frame
var _edge_mask_update_pending: bool = false

# Real-time fluid simulation
var _sim_timer: float = 0.0
const SIM_INTERVAL: float = 0.25  # Simulate flow 4x/sec. Lerp rates in fluid.gd
                                  # are tuned to settle within one tick at this rate.

# --- Reactive ripples (characters wading, projectile/ability splashes) ---
# Stored in GRID space (world_pos / TILE_SIZE) so a ring crosses tile boundaries
# seamlessly — the shader reads world-continuous (tile_position + UV) coords.
# Each entry: {pos: Vector2, age: float, strength: float}. Aged & broadcast to
# every active fluid material each frame while any ripple is alive.
const RIPPLE_LIFE: float = 1.4
const MAX_RIPPLES: int = 6
var _ripples: Array = []
var _ripples_need_clear: bool = false  # one final count=0 broadcast after the last dies

# Global water-effects quality (caustics / sun-glitter / refraction). Lower on
# weak hardware; 1.0 = full, 0.0 = off. Applied to each fluid material on spawn.
@export var water_quality: float = 1.0

func _ready() -> void:
	_load_fluid_database()

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

func update_fluid_tick(delta: float) -> void:
	"""Called from Game._process to drive fluid simulation in real time."""
	_update_ripples(delta)
	_sim_timer += delta
	if _sim_timer >= SIM_INTERVAL:
		_sim_timer = 0.0
		update_fluid_simulation()

# --- Reactive ripples ---

func add_ripple(world_pos: Vector2, strength: float = 0.8) -> void:
	"""Spawn an expanding ripple at a world position (e.g. a footstep or splash).
	Safe to call even if there's no fluid there — it just won't be visible."""
	var gp := world_pos / float(GridManager.TILE_SIZE)
	_ripples.append({"pos": gp, "age": 0.0, "strength": clamp(strength, 0.0, 2.0)})
	if _ripples.size() > MAX_RIPPLES:
		_ripples.pop_front()  # keep the newest MAX_RIPPLES

func _update_ripples(delta: float) -> void:
	if _ripples.is_empty():
		if _ripples_need_clear:
			_broadcast_ripples()  # final broadcast with count 0
			_ripples_need_clear = false
		return
	var alive: Array = []
	for r in _ripples:
		r.age += delta
		if r.age <= RIPPLE_LIFE:
			alive.append(r)
	_ripples = alive
	_broadcast_ripples()
	_ripples_need_clear = true

func _broadcast_ripples() -> void:
	var packed: Array = []
	for r in _ripples:
		packed.append(Vector4(r.pos.x, r.pos.y, r.age, r.strength))
		if packed.size() >= MAX_RIPPLES:
			break
	var n := packed.size()
	while packed.size() < MAX_RIPPLES:
		packed.append(Vector4.ZERO)  # pad to the declared uniform array size
	for tile_pos in active_fluid_tiles:
		var node = active_fluid_tiles[tile_pos]
		if node and not (node is bool) and is_instance_valid(node) and node.has_method("set_ripples"):
			node.set_ripples(packed, n)

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

	# Overwrite: if a different fluid type currently occupies this tile, wipe it.
	var existing_type = get_fluid_type_at(tile_pos)
	var type_changed = not existing_type.is_empty() and existing_type != fluid_type
	if type_changed:
		fluid_grid[tile_pos] = {}
		var old_visual = active_fluid_tiles.get(tile_pos)
		if old_visual and not (old_visual is bool) and is_instance_valid(old_visual):
			old_visual.queue_free()
		active_fluid_tiles.erase(tile_pos)
		flow_directions.erase(tile_pos)
		flow_speeds.erase(tile_pos)
		_condition_timers.erase(tile_pos)

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

	if type_changed:
		_request_edge_mask_update()

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

	# Per-tick scaling of the per-second rates so behavior is independent of SIM_INTERVAL.
	var flow_rate_tick: float = FLOW_RATE_PER_SEC * SIM_INTERVAL
	var evap_rate_tick: float = EVAPORATION_RATE_PER_SEC * SIM_INTERVAL

	var flow_deltas: Dictionary = {}
	flow_directions.clear()
	flow_speeds.clear()
	inflow_directions.clear()
	# Accumulators for averaging inflow vectors across all sources per tile this tick.
	var inflow_vectors: Dictionary = {}
	var inflow_amounts: Dictionary = {}

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

				# Deadband: ignore negligible gradients so near-level tiles stop
				# exchanging (no perpetual churn, no noisy directions).
				if pressure_diff > FLOW_EPSILON:
					# Cap the transfer at HALF the height difference so two tiles
					# settle to level instead of overshooting and sloshing back and
					# forth every tick (the classic two-cell oscillation).
					var flow_amount = min(
						min(amount * flow_rate_tick * (pressure_diff / (pressure + 0.1)),
							pressure_diff * 0.5),
						amount - PUDDLE_HEIGHT
					)
					if flow_amount > MIN_FLOW_AMOUNT:
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

						# direction_to_neighbor is the velocity of the fluid as it
						# enters the neighbor — i.e., the neighbor's inflow direction.
						if not inflow_vectors.has(neighbor_pos):
							inflow_vectors[neighbor_pos] = Vector2.ZERO
							inflow_amounts[neighbor_pos] = 0.0
						inflow_vectors[neighbor_pos] += direction_to_neighbor * flow_amount
						inflow_amounts[neighbor_pos] += flow_amount

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
				flow_deltas[tile_pos][fluid_type] -= evap_rate_tick

	# Average and normalize per-tile inflow direction.
	for pos in inflow_vectors.keys():
		if inflow_amounts[pos] > 0.0:
			var avg = inflow_vectors[pos] / inflow_amounts[pos]
			if avg.length_squared() > 0.0001:
				inflow_directions[pos] = avg.normalized()

	apply_flow_deltas(flow_deltas)
	update_water_tile_flows()
	cleanup_inactive_tiles()
	update_edge_masks()

func apply_flow_deltas(flow_deltas: Dictionary) -> void:
	for tile_pos in flow_deltas.keys():
		for fluid_type in flow_deltas[tile_pos].keys():
			var delta = flow_deltas[tile_pos][fluid_type]
			if delta > 0.0:
				# Positive delta: route through register_fluid so type-overwrite,
				# correct visual spawn, and GridManager.fluids stay consistent.
				register_fluid(tile_pos, fluid_type, delta)
			elif delta < 0.0:
				# Negative delta: decrement existing amount of this exact type.
				if fluid_grid.has(tile_pos) and fluid_grid[tile_pos].has(fluid_type):
					var prev = fluid_grid[tile_pos][fluid_type]
					var new_amount = max(0.0, prev + delta)
					fluid_grid[tile_pos][fluid_type] = new_amount
					if prev > PUDDLE_HEIGHT and new_amount <= PUDDLE_HEIGHT:
						_request_edge_mask_update()

			# Water present at this tile extinguishes fire
			if fluid_type == FLUID_TYPE_WATER and fluid_grid.has(tile_pos) \
					and fluid_grid[tile_pos].get(fluid_type, 0.0) > PUDDLE_HEIGHT:
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

		# Data-driven visual style (caustics, sparkle, foam, emissive, viscosity,
		# refraction) from fluids.json — falls back to the shader defaults.
		if fluid_node.has_method("apply_fluid_style"):
			fluid_node.apply_fluid_style(fluid_def)
		if fluid_node.has_method("set_effects_quality"):
			fluid_node.set_effects_quality(water_quality)

	# Snap initial fill state so a freshly-spawned partial tile doesn't render
	# at full opacity for a frame and then lerp down. inflow_directions has
	# already been populated for this tick before apply_flow_deltas runs.
	if fluid_node.has_method("snap_fill_state"):
		fluid_node.snap_fill_state(amount / FULL_THRESHOLD, inflow_directions.get(grid_pos, Vector2.ZERO))

	active_fluid_tiles[grid_pos] = fluid_node
	# Defer edge mask update so all tiles in a batch are created first
	_request_edge_mask_update()

func _request_edge_mask_update() -> void:
	"""Coalesce edge-mask refreshes within a frame to avoid running update_edge_masks N times."""
	if _edge_mask_update_pending:
		return
	_edge_mask_update_pending = true
	call_deferred("_run_edge_mask_update")

func _run_edge_mask_update() -> void:
	_edge_mask_update_pending = false
	update_edge_masks()

func update_edge_masks() -> void:
	"""Recompute edge masks for all active fluid tiles based on same-type neighbor presence."""
	for tile_pos in active_fluid_tiles:
		var fluid_node = active_fluid_tiles[tile_pos]
		if not fluid_node or not is_instance_valid(fluid_node) or fluid_node is bool:
			continue
		if not fluid_node.has_method("set_edge_mask"):
			continue

		var my_type = get_fluid_type_at(tile_pos)
		if my_type.is_empty():
			continue

		var right = Vector2i(tile_pos.x + 1, tile_pos.y)
		var left = Vector2i(tile_pos.x - 1, tile_pos.y)
		var bottom = Vector2i(tile_pos.x, tile_pos.y + 1)
		var top = Vector2i(tile_pos.x, tile_pos.y - 1)

		var right_open = not _has_compatible_fluid_at(right, my_type)
		var left_open = not _has_compatible_fluid_at(left, my_type)
		var bottom_open = not _has_compatible_fluid_at(bottom, my_type)
		var top_open = not _has_compatible_fluid_at(top, my_type)

		var mask = Vector4(
			1.0 if right_open else 0.0,
			1.0 if left_open else 0.0,
			1.0 if bottom_open else 0.0,
			1.0 if top_open else 0.0
		)
		fluid_node.set_edge_mask(mask)

		# Inside-corner fade: when both adjacent edges have neighbors but the diagonal
		# is missing, the corner pixel would otherwise stick out into the gap.
		var tr_diag = Vector2i(tile_pos.x + 1, tile_pos.y - 1)
		var tl_diag = Vector2i(tile_pos.x - 1, tile_pos.y - 1)
		var bl_diag = Vector2i(tile_pos.x - 1, tile_pos.y + 1)
		var br_diag = Vector2i(tile_pos.x + 1, tile_pos.y + 1)
		var corner_mask = Vector4(
			1.0 if not right_open and not top_open and not _has_compatible_fluid_at(tr_diag, my_type) else 0.0,
			1.0 if not left_open and not top_open and not _has_compatible_fluid_at(tl_diag, my_type) else 0.0,
			1.0 if not left_open and not bottom_open and not _has_compatible_fluid_at(bl_diag, my_type) else 0.0,
			1.0 if not right_open and not bottom_open and not _has_compatible_fluid_at(br_diag, my_type) else 0.0
		)
		if fluid_node.has_method("set_corner_mask"):
			fluid_node.set_corner_mask(corner_mask)

		# Continuous-shoreline coverage: pass the 8-neighbour presence so the shader
		# reconstructs one smooth waterline across the whole body (no square cores).
		if fluid_node.has_method("set_coverage"):
			var cov_sides = Vector4(
				0.0 if right_open else 1.0,
				0.0 if left_open else 1.0,
				0.0 if bottom_open else 1.0,
				0.0 if top_open else 1.0
			)
			var cov_diag = Vector4(
				1.0 if _has_compatible_fluid_at(tr_diag, my_type) else 0.0,
				1.0 if _has_compatible_fluid_at(tl_diag, my_type) else 0.0,
				1.0 if _has_compatible_fluid_at(bl_diag, my_type) else 0.0,
				1.0 if _has_compatible_fluid_at(br_diag, my_type) else 0.0
			)
			fluid_node.set_coverage(cov_sides, cov_diag)

func _has_compatible_fluid_at(tile_pos: Vector2i, fluid_type: String) -> bool:
	"""True only if neighbor has the same fluid type with > PUDDLE_HEIGHT amount."""
	if not fluid_grid.has(tile_pos):
		return false
	return fluid_grid[tile_pos].get(fluid_type, 0.0) > PUDDLE_HEIGHT

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
	_display_flow.erase(grid_pos)
	_condition_timers.erase(grid_pos)
	_request_edge_mask_update()

func clear_all_water_tiles() -> void:
	for pos in active_fluid_tiles.keys():
		remove_fluid_tile(pos)
	_condition_timers.clear()

# --- Freeze / Thaw ---

func freeze_fluid_at(tile_pos: Vector2i) -> Array[Vector2i]:
	"""BFS freeze the contiguous fluid body starting at tile_pos.
	Removes fluid visuals and data. Returns the list of frozen tiles
	(caller should place ice surfaces via SurfaceManager)."""
	var fluid_type = get_fluid_type_at(tile_pos)
	if fluid_type.is_empty():
		return []

	var frozen_tiles: Array[Vector2i] = []
	var visited: Dictionary = {}
	var queue: Array[Vector2i] = [tile_pos]
	visited[tile_pos] = true

	while not queue.is_empty():
		var tile = queue.pop_front()
		var ft = get_fluid_type_at(tile)
		if ft != fluid_type:
			continue
		var amount = get_fluid_amount(tile, fluid_type)
		if amount < PUDDLE_HEIGHT:
			continue

		frozen_tiles.append(tile)

		var neighbors = get_neighbors(tile)
		for neighbor in neighbors:
			if visited.has(neighbor):
				continue
			visited[neighbor] = true
			queue.append(neighbor)

	# Remove all the fluid from the frozen tiles
	for tile in frozen_tiles:
		remove_fluid_tile(tile)

	return frozen_tiles

func freeze_all_fluids() -> Dictionary:
	"""Freeze every fluid tile currently on the map.
	Returns Dictionary[Vector2i, Dictionary] with keys 'fluid_type' and 'amount'
	so SurfaceManager can record what was frozen."""
	var frozen_data: Dictionary = {}
	var tiles_to_freeze: Array[Vector2i] = []

	for tile_pos in fluid_grid.keys():
		for fluid_type in fluid_grid[tile_pos]:
			if fluid_grid[tile_pos][fluid_type] >= PUDDLE_HEIGHT:
				frozen_data[tile_pos] = {
					"fluid_type": fluid_type,
					"amount": fluid_grid[tile_pos][fluid_type]
				}
				tiles_to_freeze.append(tile_pos)
				break  # one fluid type per tile

	for tile_pos in tiles_to_freeze:
		remove_fluid_tile(tile_pos)

	return frozen_data

func restore_fluid(tile_pos: Vector2i, fluid_type: String, amount: float) -> void:
	"""Restore a previously frozen fluid tile (called when ice thaws)."""
	register_fluid(tile_pos, fluid_type, amount)

func update_water_tile_flows() -> void:
	for grid_pos in active_fluid_tiles.keys():
		var water_tile = active_fluid_tiles[grid_pos]
		if water_tile and is_instance_valid(water_tile):
			# Smooth + gate the displayed current: hide tiny residual flows and ease
			# the direction over time so a settled pond looks still and adjacent
			# tiles don't disagree from one tick to the next.
			var raw_dir: Vector2 = flow_directions.get(grid_pos, Vector2.ZERO)
			var raw_speed: float = flow_speeds.get(grid_pos, 0.0)
			if raw_speed < VISUAL_FLOW_MIN:
				raw_dir = Vector2.ZERO
				raw_speed = 0.0
			var prev_vec: Vector2 = _display_flow.get(grid_pos, Vector2.ZERO)
			var smooth_vec: Vector2 = prev_vec.lerp(raw_dir * raw_speed, DISPLAY_DIR_EMA)
			_display_flow[grid_pos] = smooth_vec
			var disp_speed: float = smooth_vec.length()
			var disp_dir: Vector2 = smooth_vec / disp_speed if disp_speed > 0.0001 else Vector2.ZERO
			water_tile.set_flow_direction(disp_dir, disp_speed)
			var fluid_type = get_fluid_type_at(grid_pos)
			if not fluid_type.is_empty():
				var amount = get_fluid_amount(grid_pos, fluid_type)
				if amount > 0:
					water_tile.set_water_depth(amount)
				if water_tile.has_method("set_fill_ratio"):
					water_tile.set_fill_ratio(clamp(amount / FULL_THRESHOLD, 0.0, 1.0))
			if water_tile.has_method("set_inflow_direction"):
				water_tile.set_inflow_direction(inflow_directions.get(grid_pos, Vector2.ZERO))
