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

# Electrified tiles live on a parallel grid so they can coexist with fire/ice
# and never overwrite an active surface. Same per-tile shape as surface_grid.
var electrified_grid: Dictionary = {}  # Dictionary[Vector2i, Dictionary]
# Per-character apply cooldowns for the electrified system (separate from fire's).
var _electrified_condition_timers: Dictionary = {}  # Dictionary[int, float]

# CELL-GRAPH FIRE: when a map supplies a CellGraph (structured -> Stalberg cells,
# legacy -> square-tile adapter), fire runs on it instead of the tile surface_grid
# -- organic spread, fuel scaling, wind bias. The tile-fire code below stays but
# goes dormant (ignition routes to cell_fire, so surface_grid never gets fire).
var cell_fire: CellFire = null
var cell_fire_fx: CellFireFX = null   # editor-look flame renderer: continuous
                                      # blob sheet over burning cells + merged
                                      # cluster lights (no per-cell fire.tscn)
var cell_scorch: CellScorchFX = null  # persistent ground char under the flames
const CELL_FIRE_SCENE := preload("res://CellFire.gd")
const CELL_FIRE_FX_SCENE := preload("res://CellFireFX.gd")
const CELL_SCORCH_SCENE := preload("res://CellScorchFX.gd")

# --- Hazard map (pathfinding danger overlay) ---
# GridManager.hazard_costs is rebuilt HERE because SurfaceManager can see every
# damaging ground system at once: cell fire, legacy tile fire surfaces,
# electrified tiles, and harmful standing fluids. The whole dict is swapped in
# on a short cadence — plus immediately whenever the burning cell set changes
# (burn_rev) so a fresh ignition can't hide inside the cadence window. Route
# planning reads it; the damage loops never do (they keep their exact
# per-cell / per-tile contact tests as ground truth).
const HAZARD_REBUILD_INTERVAL := 0.3
# burn_rev bumps on EVERY ignite/douse/burnout — a big blaze churns the rev
# quasi-continuously, which would turn the "rebuild immediately on change"
# trigger into a per-frame rebuild. Floor the spacing instead: a fresh
# ignition still lands within 0.1s, a 600-cell blaze rebuilds at 10 Hz max.
const HAZARD_MIN_SPACING := 0.1
# Harm is defined by the condition the ground applies, not by surface/fluid id:
# anything that damages a standing character is a core hazard. slowed (oil) and
# "" (water/blood/ink) are nuisances, not hazards.
const DAMAGING_CONDITIONS := {"burning": true, "corroding": true, "poisoned": true,
	"shocked": true, "stuck_in_fire": true, "suffocating": true}
var _hazard_timer := 0.0
var _hazard_min_cd := 0.0
var _hazard_burn_rev := -1


# Called by Game.load_map once the grid + structures exist. graph may be null
# (e.g. world maps) -> fire falls back to the legacy tile path.
func setup_cell_graph(graph: CellGraph) -> void:
	if cell_fire != null and is_instance_valid(cell_fire):
		cell_fire.queue_free()
		cell_fire = null
	if cell_fire_fx != null and is_instance_valid(cell_fire_fx):
		cell_fire_fx.queue_free()
		cell_fire_fx = null
	if cell_scorch != null and is_instance_valid(cell_scorch):
		cell_scorch.queue_free()
		cell_scorch = null
	GridManager.hazard_costs = {}
	_hazard_burn_rev = -1
	if graph == null or graph.cell_count <= 0:
		return
	cell_fire = CELL_FIRE_SCENE.new()
	add_child(cell_fire)
	cell_fire.setup(graph, self, _surface_defs.get("fire", {}))
	cell_fire.native_particles = false
	cell_fire_fx = CELL_FIRE_FX_SCENE.new()
	# z 0, same as the fire.tscn vfx it replaces: SurfaceManager's tree position
	# already draws over map art (the old flames were visible on floors)
	add_child(cell_fire_fx)
	cell_fire_fx.setup(cell_fire, graph)
	# persistent char layer: above the baked ground (-6), below legacy floors
	# (-4) and structures (-3), so burnt grass blackens but walls draw over it.
	# Parent under MapLoader to share the map art's coordinate space/z run;
	# fall back to an absolute z under SurfaceManager if it's missing.
	cell_scorch = CELL_SCORCH_SCENE.new()
	cell_scorch.setup(graph)
	cell_scorch.z_index = -5
	var game = _get_game()
	if game != null and "map_loader" in game and game.map_loader != null:
		game.map_loader.add_child(cell_scorch)
	else:
		cell_scorch.z_as_relative = false
		add_child(cell_scorch)
	cell_fire.scorch_fx = cell_scorch


func _cell_fire_active() -> bool:
	return cell_fire != null and is_instance_valid(cell_fire) and cell_fire.active()

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
	if not surface_grid.is_empty():
		_apply_conditions_to_characters(delta, characters)
		_process_spread(delta, game)
		_process_damage(delta, game)
		_process_lifetime(delta, game)
		# After every heat source has had its say this tick, bleed heat back out
		# of any ice that wasn't warmed (see _decay_ice_heat).
		_decay_ice_heat(delta)
	if _cell_fire_active():
		cell_fire.tick(delta, characters, game)
	if not electrified_grid.is_empty():
		_apply_electrified_to_characters(delta, characters)
		_process_electrified_lifetime(delta)
	_hazard_timer -= delta
	_hazard_min_cd -= delta
	var rev: int = cell_fire.burn_rev if _cell_fire_active() else -1
	if (_hazard_timer <= 0.0 or rev != _hazard_burn_rev) and _hazard_min_cd <= 0.0:
		_hazard_timer = HAZARD_REBUILD_INTERVAL
		_hazard_min_cd = HAZARD_MIN_SPACING
		_hazard_burn_rev = rev
		_rebuild_hazard_map(game)


func _rebuild_hazard_map(game: Node) -> void:
	var hz: Dictionary = {}
	# Cell fire: burning cell -> its centroid tile (core) + 4-neighbourhood
	# (halo). Cells are ~half a tile, so the halo also biases routes off the
	# tiles a burning cell straddles without its centroid landing there.
	if _cell_fire_active():
		var graph: CellGraph = cell_fire.graph
		for cid in cell_fire.burning:
			hz[GridManager.world_to_map(graph.centroid(cid))] = GridManager.HAZARD_CORE_COST
		for t in hz.keys():
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = t + d
				if not hz.has(n):
					hz[n] = GridManager.HAZARD_HALO_COST
	# Legacy tile surfaces (fire/fire_spin on graph-less maps); electricity is
	# tile-grid on ALL maps.
	for tile_pos in surface_grid:
		var sdef: Dictionary = _surface_defs.get(surface_grid[tile_pos]["surface_id"], {})
		if DAMAGING_CONDITIONS.has(String(sdef.get("condition_id", ""))):
			hz[tile_pos] = GridManager.HAZARD_CORE_COST
	for tile_pos in electrified_grid:
		hz[tile_pos] = GridManager.HAZARD_CORE_COST
	# Harmful standing fluids (acid/poison). The tile projection is
	# authoritative on both map kinds (cell sims project every 0.25s).
	var fm := _get_fluid_manager(game)
	if fm != null:
		for tile_pos in fm.harmful_fluid_tiles(DAMAGING_CONDITIONS):
			hz[tile_pos] = GridManager.HAZARD_CORE_COST
	# Damaging clouds (cloud_kill): the fifth damaging ground system. FogOverlay
	# applies its condition to every character inside Rect2(global_position,
	# size) — mark the tiles that rect covers so NPCs walk OUT of a poison
	# cloud instead of standing in it re-stacking poisoned for 15s.
	if game != null and ("fog_manager" in game) and game.fog_manager != null:
		for fog in game.fog_manager._active_fogs:
			if not is_instance_valid(fog) \
					or not DAMAGING_CONDITIONS.has(String(fog.condition_id)):
				continue
			var t0: Vector2i = GridManager.world_to_map(fog.global_position)
			var t1: Vector2i = GridManager.world_to_map(fog.global_position + fog.size)
			for y in range(t0.y, t1.y + 1):
				for x in range(t0.x, t1.x + 1):
					hz[Vector2i(x, y)] = GridManager.HAZARD_CORE_COST
	GridManager.hazard_costs = hz

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

		# Damage structures on this tile (real footprint, not the pathing halo --
		# a fire a body-width away from a wall shouldn't chew through it)
		if game and "structures_in_scene" in game:
			for structure in game.structures_in_scene:
				if not is_instance_valid(structure):
					continue
				if tile_pos in _fire_tiles_of(structure):
					structure.take_damage(damage_per_tick.duplicate(), 0)

	for tile_pos in tiles_to_remove:
		_remove_surface(tile_pos)

	# Sustained tile fire melts the ice it is standing next to (graph-less maps;
	# the cell-fire equivalent is CellFire._melt_ice). Collected into a set first
	# because a thaw ERASES from surface_grid, which must not happen mid-iteration.
	var ice_melt: float = float(fire_def.get("ice_melt_per_tick", 0.34))
	if ice_melt > 0.0:
		var touched: Dictionary = {}
		for tile_pos in surface_grid:
			if surface_grid[tile_pos]["surface_id"] != "fire":
				continue
			touched[tile_pos + Vector2i(1, 0)] = true
			touched[tile_pos + Vector2i(-1, 0)] = true
			touched[tile_pos + Vector2i(0, 1)] = true
			touched[tile_pos + Vector2i(0, -1)] = true
		for tile: Vector2i in touched:
			apply_heat_to_ice(tile, ice_melt)

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
		# only real fire leaves ash -- Bumper Crop's grass or a Fire Spin ring
		# expiring must not char the floor
		if source_type != "fluid" and surface_grid[tile_pos]["surface_id"] == "fire":
			_scorch_floor(tile_pos, scorch_color, game)
		_remove_surface(tile_pos)

# --- Ignition API ---

func try_ignite_area(center_world: Vector2, radius: float) -> void:
	"""Attempt to ignite all flammable tiles within a world-space radius."""
	# A burst of fire landing on ice melts it on BOTH map kinds. This must run
	# BEFORE the cell-fire route below: that early return never touches the tile
	# surface grid ice lives on, which is why AoE fire (fireball) stopped melting
	# ice while single-target fire (try_ignite) still did.
	_melt_ice_in_area(center_world, radius, ICE_MELT_THRESHOLD)
	if _cell_fire_active():
		cell_fire.ignite_area(center_world, radius)
		return
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
	Tiles already holding the same surface get their duration refreshed; nothing
	else is overwritten. Returns the number of tiles placed or refreshed."""
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
				# recasting on the same footprint refreshes it rather than doing nothing
				if surface_grid[tile_pos]["surface_id"] == surface_id:
					surface_grid[tile_pos]["time_remaining"] = duration
					placed += 1
				continue
			var vfx_node = _spawn_surface_vfx(tile_pos, surface_def)
			surface_grid[tile_pos] = {
				"surface_id": surface_id,
				"time_remaining": duration,
				"vfx_node": vfx_node,
				"source_type": "direct"
			}
			placed += 1
	if placed == 0:
		# every tile was taken by another surface (e.g. ice): say so at the target
		Globals.show_floating_text("No effect", center_world, self, Color.GRAY, 0, Globals.NOTICE_FONT_SIZE)
	return placed

func try_ignite(tile_pos: Vector2i) -> void:
	"""Attempt to ignite a single tile. Checks fluids first (flood-fill), then floors."""
	# ice thaw stays on the tile grid even under cell fire (ice is tile-based)
	if surface_grid.has(tile_pos) and surface_grid[tile_pos]["surface_id"] == "ice":
		thaw_ice_at(tile_pos)
		return
	if _cell_fire_active():
		# route ground ignition to the cell fire (the tile's centre cell). Oil is
		# heavy fuel and water a firebreak there (CellFire._fuel reads the cell
		# fluid sim, or the tile FluidManager on legacy maps), so a slick burns
		# by spreading cell to cell rather than by flood-ignition.
		cell_fire.ignite_at(GridManager.map_to_world(tile_pos))
		return
	if surface_grid.has(tile_pos):
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

	# Non-flammable structure blocks fire (tight fire footprint, not the pathing
	# halo -- see _fire_tiles_of; any flammable claimer wins on shared tiles)
	if game and "structures_in_scene" in game:
		var claimed := false
		for structure in game.structures_in_scene:
			if is_instance_valid(structure) and tile_pos in _fire_tiles_of(structure):
				if structure.flammable:
					_ignite_tile(tile_pos, "floor")
					return
				claimed = true
		if claimed:
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
	# fire lives on the cell graph now -- bridge the tile water-douse to it
	if _cell_fire_active():
		cell_fire.douse_at(GridManager.map_to_world(tile_pos))
		return
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

# --- Hazard identification (paused hover tooltip) ---

## What is on the ground at world_pos and what it does to whoever stands there.
## Each entry: {kind, id, name, condition_id, interval, conditions: [{id,
## interval}], notes: PackedStringArray}. Fluids are read by TILE, as
## FluidManager.update_fluid_conditions applies them.
func describe_hazards_at(world_pos: Vector2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var tile := GridManager.world_to_map(world_pos)
	var game = _get_game()
	var fluid_manager = _get_fluid_manager(game)

	# Tile surfaces: ice, grassy, fire spin, legacy tile fire
	if surface_grid.has(tile):
		var sid: String = surface_grid[tile].get("surface_id", "")
		var sdef: Dictionary = _surface_defs.get(sid, {})
		var notes: PackedStringArray = []
		var name_text := str(sdef.get("display_name", sid.capitalize()))
		if sid == "ice":
			var frozen := str(surface_grid[tile].get("frozen_fluid_type", ""))
			if frozen != "" and fluid_manager:
				name_text = "Ice (frozen %s)" % fluid_manager.fluid_display_name(frozen).to_lower()
			if sdef.get("causes_sliding", false):
				notes.append("Slippery: whoever steps on it slides until they're off the ice, losing their plan.")
			if sdef.get("thaw_on_fire", false):
				notes.append("Fire thaws it.")
		elif sid == "fire":
			notes.append("Spreads to flammable ground.")
			var wind := _wind_note()
			if wind != "":
				notes.append(wind)
		out.append(_hazard_entry("surface", sid, name_text, str(sdef.get("condition_id", "")), float(sdef.get("apply_interval", 1.0)), notes))

	# Cell-graph fire (structured and legacy maps with a CellGraph)
	if _cell_fire_active():
		var fire_def: Dictionary = _surface_defs.get("fire", {})
		if cell_fire.is_burning_at(world_pos):
			var notes: PackedStringArray = ["Spreads to flammable ground; stone and water stop it."]
			var wind := _wind_note()
			if wind != "":
				notes.append(wind)
			out.append(_hazard_entry("fire", "fire", str(fire_def.get("display_name", "Fire")), str(fire_def.get("condition_id", "burning")), float(fire_def.get("apply_interval", 1.0)), notes))
		elif cell_fire.is_burnt_at(world_pos):
			# Burnt out, even though the char is now drawn: say it can't burn again.
			out.append(_hazard_entry("burnt", "burnt", "Burnt ground", "", 0.0, ["Burnt out: it won't catch fire again."] as PackedStringArray))

	# Electrified ground
	if electrified_grid.has(tile):
		var edef: Dictionary = _surface_defs.get("electrified", {})
		var interval := float(edef.get("apply_interval", 0.3))
		var stat := String(edef.get("stun_save_stat", "constitution")).substr(0, 3).to_upper()
		var notes: PackedStringArray = ["%s save every %s or Stunned." % [stat, _fmt_secs(interval)]]
		out.append(_hazard_entry("electrified", "electrified", str(edef.get("display_name", "Electrified")) + " ground", str(edef.get("condition_id", "shocked")), interval, notes))

	# Fluid (water, poison, oil, acid, ink, blood...)
	if fluid_manager:
		var ft: String = fluid_manager.get_fluid_type_at(tile)
		if ft != "":
			var fdef: Dictionary = fluid_manager.get_fluid_def(ft)
			var notes: PackedStringArray = []
			if fdef.get("conductive", false):
				notes.append("Conducts electricity: a shock spreads through the whole pool.")
			if fdef.get("flammable", false):
				notes.append("Flammable: fire races across it.")
			if ft == "water":
				notes.append("Puts out fire.")
			out.append(_hazard_entry("fluid", ft, fluid_manager.fluid_display_name(ft), str(fdef.get("condition_id", "")), float(fdef.get("apply_interval", 1.0)), notes))

	# Clouds that apply conditions (poison, fire smoke, acidic mist...). One
	# entry for every cloud over the point; a multi-condition fog is one
	# overlay per condition.
	if game and "fog_manager" in game and game.fog_manager and "_active_fogs" in game.fog_manager:
		var conds: Array = []
		var seen: Dictionary = {}
		for fog in game.fog_manager._active_fogs:
			if not is_instance_valid(fog) or str(fog.condition_id) == "" or seen.has(fog.condition_id):
				continue
			if Rect2(fog.global_position, fog.size).has_point(world_pos):
				seen[fog.condition_id] = true
				conds.append({"id": str(fog.condition_id), "interval": float(fog.apply_interval)})
		if not conds.is_empty():
			var e := _hazard_entry("fog", "fog", "Cloud", conds[0]["id"], conds[0]["interval"], PackedStringArray())
			e["conditions"] = conds
			out.append(e)
	return out

func _hazard_entry(kind: String, id: String, name_text: String, condition_id: String, interval: float, notes: PackedStringArray) -> Dictionary:
	var conds: Array = []
	if condition_id != "":
		conds.append({"id": condition_id, "interval": interval})
	return {"kind": kind, "id": id, "name": name_text, "condition_id": condition_id, "interval": interval, "conditions": conds, "notes": notes}

## BBCode for the paused hover tooltip (Game.world_tooltip "hazards"). "" when
## the ground there is plain.
func hazard_tooltip_text(world_pos: Vector2) -> String:
	var parts: PackedStringArray = []
	for h in describe_hazards_at(world_pos):
		var lines: PackedStringArray = []
		var title := "[b]%s[/b]" % h["name"]
		if h["kind"] == "fluid" or h["kind"] == "fog":
			title += " [color=#a69f8f](%s)[/color]" % h["kind"]
		lines.append(title)
		for c in h["conditions"]:
			var cond = ConditionManager.condition_registry.get(c["id"])
			var cname: String = c["id"].capitalize()
			var verb := "Applies"
			var desc := ""
			if cond:
				if cond.display_name != "":
					cname = cond.display_name
				if cond.traits.has("buff"):
					verb = "Grants"
				desc = cond.description
			var line := "%s [b]%s[/b] every %s" % [verb, cname, _fmt_secs(c["interval"])]
			if desc != "":
				line += ": " + desc
			lines.append(line)
		for n in h["notes"]:
			lines.append(n)
		parts.append("\n".join(lines))
	return "\n\n".join(parts)

func _fmt_secs(seconds: float) -> String:
	if is_equal_approx(seconds, roundf(seconds)):
		return "%d s" % int(roundf(seconds))
	return "%.1f s" % seconds

## "The wind pushes it toward the SE." when the map's weather has wind worth
## mentioning (cell fire leans with it from about speed 3), else "".
func _wind_note() -> String:
	var grp := _get_map_weather_group(null)
	if grp == "":
		return ""
	var spd: float = WeatherManager.get_wind_speed(grp)
	var dir: Vector2 = WeatherManager.get_wind_direction(grp)
	if spd < 3.0 or dir.length() < 0.01:
		return ""
	return "The wind pushes it toward the %s." % Globals.compass_name(dir)

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

# --- Ice melting (heat accumulation) ---
# Ice is a TILE surface even on cell-fire maps: freezing DRAINS the cells under
# the tile (FluidManager.freeze_*), so no burning cell ever sits "in" ice and
# nothing inside the fire/fluid cell sims can see it. Fire therefore melts ice
# by feeding heat in from the outside, through this one entry point.
# Total heat an ice tile must absorb before it thaws back into the fluid it
# froze from. CellFire feeds `ice_melt_per_tick` (surfaces.json fire def,
# default 0.34) once per damage tick, so ice next to flames melts in ~3s; a
# direct fire AoE dumps the whole threshold at once and melts on contact
# (matching what try_ignite already did for a single tile).
const ICE_MELT_THRESHOLD := 1.0
# Heat bleeds back out of ice that is no longer being warmed, so a fire that
# burns out doesn't leave the tile permanently primed for an unrelated fire
# minutes later. Tuned slower than the melt rate: sustained heat still wins.
const ICE_MELT_DECAY_PER_SEC := 0.15

func apply_heat_to_ice(tile_pos: Vector2i, amount: float) -> bool:
	"""Feed heat into an ice tile; thaws it once the accumulated heat crosses
	ICE_MELT_THRESHOLD. Returns true if this call thawed the tile."""
	if amount <= 0.0 or get_surface_id_at(tile_pos) != "ice":
		return false
	var ice_def: Dictionary = _surface_defs.get("ice", {})
	if not bool(ice_def.get("thaw_on_fire", true)):
		return false
	var data: Dictionary = surface_grid[tile_pos]
	var heat: float = float(data.get("melt_heat", 0.0)) + amount
	data["melt_heat"] = heat
	# Mark as warmed this frame so the decay pass below skips it.
	data["melt_warmed"] = true
	if heat < ICE_MELT_THRESHOLD:
		return false
	thaw_ice_at(tile_pos)
	return true


func _decay_ice_heat(delta: float) -> void:
	"""Bleed accumulated melt heat out of ice tiles that weren't warmed this
	tick, and clear the per-tick warmed flag."""
	var drop: float = ICE_MELT_DECAY_PER_SEC * delta
	for tile_pos in surface_grid:
		var data: Dictionary = surface_grid[tile_pos]
		if data.get("surface_id", "") != "ice":
			continue
		if bool(data.get("melt_warmed", false)):
			data["melt_warmed"] = false
			continue
		var heat: float = float(data.get("melt_heat", 0.0))
		if heat > 0.0:
			data["melt_heat"] = maxf(0.0, heat - drop)


func _melt_ice_in_area(center_world: Vector2, radius: float, heat: float) -> int:
	"""Dump heat into every ice tile whose centre is inside a world radius.
	Iterates a KEY COPY: a thaw erases from surface_grid. Returns tiles thawed."""
	if surface_grid.is_empty():
		return 0
	var melted: int = 0
	for key in surface_grid.keys():
		var tile_pos: Vector2i = key
		if get_surface_id_at(tile_pos) != "ice":
			continue
		if GridManager.map_to_world(tile_pos).distance_to(center_world) > radius:
			continue
		if apply_heat_to_ice(tile_pos, heat):
			melted += 1
	return melted


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
	for tile_pos in electrified_grid.keys():
		_remove_electrified(tile_pos)
	if cell_fire != null and is_instance_valid(cell_fire):
		cell_fire.clear_all()
	_condition_timers.clear()
	_electrified_condition_timers.clear()
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
	# Surface VFX are spawned one Sprite2D PER TILE, so any shader sampling bare
	# UV repeats identically in every tile (this is what made frozen ponds look
	# like a grid of identical cloudy blobs). Hand the instance its grid
	# coordinate so those shaders can build a world-continuous sample position,
	# the same `tile_position + uv` convention the fluid shaders use (fluid.gd).
	# Set AFTER play() because play() duplicates the material.
	_set_tile_position_param(vfx, tile_pos)
	return vfx

func _set_tile_position_param(vfx: Node, tile_pos: Vector2i) -> void:
	"""Push the tile's grid coordinate into any ShaderMaterial on the VFX that
	declares a `tile_position` uniform. Silently ignores VFX that don't."""
	if vfx == null:
		return
	var tp := Vector2(tile_pos.x, tile_pos.y)
	for node in _canvas_items_of(vfx):
		var mat := node.material as ShaderMaterial
		if mat == null or mat.shader == null:
			continue
		for prop in mat.shader.get_shader_uniform_list():
			if prop.get("name", "") == "tile_position":
				mat.set_shader_parameter("tile_position", tp)
				break

func _canvas_items_of(root: Node) -> Array[CanvasItem]:
	var out: Array[CanvasItem] = []
	var ci := root as CanvasItem
	if ci != null:
		out.append(ci)
	for child in root.get_children():
		out.append_array(_canvas_items_of(child))
	return out

func _is_tile_flammable(tile_pos: Vector2i, game: Node) -> bool:
	# Non-flammable fluid on tile blocks fire (e.g. water)
	var fluid_manager = _get_fluid_manager(game)
	if fluid_manager:
		var fluid_type = fluid_manager.get_fluid_type_at(tile_pos)
		if not fluid_type.is_empty():
			# There's fluid here — only flammable if the fluid itself is flammable
			return fluid_manager.is_fluid_flammable(tile_pos)

	# Non-flammable structure on tile blocks fire from reaching the floor underneath.
	# Structured maps inflate occupied_tiles by a PATHING margin -- test the tight
	# fire footprint instead (falls back to occupied_tiles on legacy maps, where
	# it is tile-exact), and when several structures claim the tile, ANY flammable
	# claimer lets fire take hold (iteration order must not decide).
	if game and "structures_in_scene" in game:
		var claimed := false
		for structure in game.structures_in_scene:
			if not is_instance_valid(structure):
				continue
			if tile_pos in _fire_tiles_of(structure):
				if structure.flammable:
					return true
				claimed = true
		if claimed:
			return false

	# Check floor flammability
	return _is_floor_flammable(tile_pos)


# The tiles a structure blocks/feeds fire on: its real-geometry footprint when
# the loader provided one (structured maps), else its occupied tiles (legacy).
func _fire_tiles_of(structure) -> Array:
	if "fire_blocking_tiles" in structure and not structure.fire_blocking_tiles.is_empty():
		return structure.fire_blocking_tiles
	return structure.occupied_tiles

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

# --- Electrified API ---

func try_electrify(tile_pos: Vector2i) -> int:
	"""Electrify a tile and flood-fill across any contiguous conductive matter
	(same-type conductive fluid, or contiguous conductive floor). Instantaneous
	BFS. Re-hits refresh the duration of every tile in the connected region.
	Returns the number of tiles newly electrified (already-electrified tiles
	are refreshed but not counted). The region is electrify_region's, which the
	targeting preview also draws, so the two can't disagree."""
	var region := electrify_region(tile_pos)
	var source: String = region["source"]
	var count: int = 0
	for tile in region["tiles"]:
		if electrified_grid.has(tile):
			# Refresh duration even if already electrified.
			var elec_def = _surface_defs.get("electrified", {})
			electrified_grid[tile]["time_remaining"] = elec_def.get("base_duration", 1.2)
		else:
			_electrify_tile(tile, source)
			count += 1
	return count

## Dry run of try_electrify: the tiles a current entering tile_pos would reach,
## changing nothing. {"tiles": Array[Vector2i], "source": "fluid"|"floor"|"direct"}.
## A conductive fluid floods its contiguous same-type body, a conductive floor
## its contiguous conductive floor; bare ground is just the tile. cap > 0 bounds
## the search (the per-frame preview passes one); try_electrify doesn't.
func electrify_region(tile_pos: Vector2i, cap: int = 0) -> Dictionary:
	var fluid_manager = _get_fluid_manager(_get_game())
	if fluid_manager and fluid_manager.is_conductive(tile_pos):
		var fluid_type: String = fluid_manager.get_fluid_type_at(tile_pos)
		return {"tiles": _flood(tile_pos, func(t: Vector2i) -> bool: return fluid_manager.get_fluid_type_at(t) == fluid_type, cap), "source": "fluid"}
	if _is_floor_conductive(tile_pos):
		return {"tiles": _flood(tile_pos, _is_floor_conductive, cap), "source": "floor"}
	return {"tiles": [tile_pos] as Array[Vector2i], "source": "direct"}

## 4-neighbour BFS from start over tiles where joins(tile) holds (start is
## always included). Breadth-first order, as the old per-source fills were.
func _flood(start: Vector2i, joins: Callable, cap: int = 0) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var visited: Dictionary = {start: true}
	var queue: Array[Vector2i] = [start]
	while not queue.is_empty():
		var tile: Vector2i = queue.pop_front()
		out.append(tile)
		if cap > 0 and out.size() >= cap:
			break
		for neighbor in GridManager.get_neighboring_coords(tile):
			if visited.has(neighbor):
				continue
			visited[neighbor] = true
			if joins.call(neighbor):
				queue.append(neighbor)
	return out

func _electrify_tile(tile_pos: Vector2i, source_type: String) -> void:
	"""Place an electrified surface on a single tile (parallel to _ignite_tile)."""
	if electrified_grid.has(tile_pos):
		return
	var elec_def = _surface_defs.get("electrified", {})
	if elec_def.is_empty():
		return
	var duration: float = elec_def.get("base_duration", 1.2)
	var vfx_node = _spawn_surface_vfx(tile_pos, elec_def)
	electrified_grid[tile_pos] = {
		"surface_id": "electrified",
		"time_remaining": duration,
		"vfx_node": vfx_node,
		"source_type": source_type
	}

func _remove_electrified(tile_pos: Vector2i) -> void:
	if not electrified_grid.has(tile_pos):
		return
	var tile_data = electrified_grid[tile_pos]
	var vfx = tile_data.get("vfx_node")
	if vfx and is_instance_valid(vfx):
		vfx.queue_free()
	electrified_grid.erase(tile_pos)

func _apply_electrified_to_characters(delta: float, characters: Array) -> void:
	"""For each electrified tile, apply 'shocked' to characters on it (drives
	the per-tick electric damage via the condition's triggered_effects), and
	roll a CON save against being stunned."""
	var elec_def = _surface_defs.get("electrified", {})
	var condition_id: String = elec_def.get("condition_id", "shocked")
	var apply_interval: float = elec_def.get("apply_interval", 0.3)
	var stacks: int = int(elec_def.get("condition_stacks", 1))

	for tile_pos in electrified_grid:
		for character in characters:
			if not is_instance_valid(character):
				continue
			if character.has_method("is_alive") and not character.is_alive():
				continue
			var char_tile = GridManager.world_to_map(character.global_position)
			if char_tile != tile_pos:
				continue

			var char_id = character.get_instance_id()
			if not _electrified_condition_timers.has(char_id):
				_electrified_condition_timers[char_id] = 0.0
			_electrified_condition_timers[char_id] += delta
			if _electrified_condition_timers[char_id] < apply_interval:
				continue
			_electrified_condition_timers[char_id] = 0.0

			var cm = character.get_node_or_null("ConditionManager")
			if not cm and character.has_method("get_condition_manager"):
				cm = character.get_condition_manager()
			if cm and not condition_id.is_empty():
				cm.apply_condition(condition_id, null, stacks)

			# CON save: roll d100. If roll >= effective_constitution, apply stunned.
			var con: float = 50.0
			if character.has_method("effective_constitution"):
				con = character.effective_constitution()
			elif "constitution" in character:
				con = float(character.constitution)
			var roll: int = randi() % 100 + 1
			if roll >= con and cm:
				cm.apply_condition("stunned", null, 1)

func _process_electrified_lifetime(delta: float) -> void:
	var to_remove: Array[Vector2i] = []
	for tile_pos in electrified_grid:
		electrified_grid[tile_pos]["time_remaining"] -= delta
		if electrified_grid[tile_pos]["time_remaining"] <= 0.0:
			to_remove.append(tile_pos)
	for tile_pos in to_remove:
		_remove_electrified(tile_pos)

func _is_floor_conductive(tile_pos: Vector2i) -> bool:
	"""Mirror of _is_floor_flammable but checks the 'conductive' field."""
	if not GridManager.floors.has(tile_pos):
		return false
	var game = _get_game()
	var floor_node = _get_floor_at(tile_pos, game)
	if floor_node and is_instance_valid(floor_node):
		if "conductive" in floor_node:
			return floor_node.conductive
	var floor_id = GridManager.floors[tile_pos]
	if not FloorDatabase.floor_definitions.has(floor_id):
		return false
	var floor_data = FloorDatabase.floor_definitions[floor_id]
	return floor_data.get("conductive", false)
