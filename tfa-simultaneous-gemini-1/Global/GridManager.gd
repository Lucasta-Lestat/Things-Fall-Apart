# res://Global/GridManager.gd
extends Node

var TILE_SIZE: int = 64
var map_rect: Rect2i
var grid_costs: Dictionary = {}
var walls: Dictionary = {}
var floors: Dictionary = {}
var fluids: Dictionary = {}
# Obstacle REFERENCE COUNTS: structured maps register abutting wall segments /
# trees whose occupied tiles overlap at junctions -- destroying one structure
# must not unblock a tile a standing neighbour still covers.
var _obstacle_refs: Dictionary = {}
# Terrain elevation in signed STORIES per tile, SPARSE (only |elev|>0.001 stored).
var elevations: Dictionary = {}        # Vector2i -> float
# Walkable-deck overlay. Per-tile HEIGHT LIST (not a bare refcount): abutting
# deck segments share junction tiles, and decks of DIFFERENT heights can share
# one — destroying the taller must drop the tile to the survivor's height.
var deck_elevations: Dictionary = {}   # Vector2i -> float (max of registered heights)
var _deck_refs: Dictionary = {}        # Vector2i -> Array of float (one entry per registration)
# Roof surface height per tile, SPARSE — a layer STACKED OVER the ground, never
# folded into effective_elev (a house interior stays at ground height under its
# own roof). Only jump-capable characters (jump_height > 0) ever enter it.
var roof_elevations: Dictionary = {}   # Vector2i -> float (stories)
const MAX_STEP_STORIES := 0.55
const EYE_HEIGHT_STORIES := 0.5
const FALL_SAFE_STORIES := 1.0         # drops <= this are graceful (no damage)
const FALL_DMG_PER_STORY := 3.0        # bludgeoning per story past FALL_SAFE

func initialize(map_width_px: int, map_height_px: int) -> void:
	var cols = int(ceil(float(map_width_px) / TILE_SIZE))
	var rows = int(ceil(float(map_height_px) / TILE_SIZE))
	map_rect = Rect2i(0, 0, cols, rows)
	grid_costs.clear()
	walls.clear()
	floors.clear()
	fluids.clear()
	_obstacle_refs.clear()
	elevations.clear()
	deck_elevations.clear()
	_deck_refs.clear()
	roof_elevations.clear()
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
	_obstacle_refs[grid_pos] = int(_obstacle_refs.get(grid_pos, 0)) + 1
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
	# refcounted: the tile stays blocked while any registered structure covers it
	var refs = int(_obstacle_refs.get(grid_pos, 0)) - 1
	_obstacle_refs[grid_pos] = max(0, refs)
	if refs > 0:
		return
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

# --- Elevation (terrain + walkable decks) ---
# graph: CellGraph or null. Projects per-cell elev onto tiles once per map load.
# CellGraph coordinates are game-world px (see CellGraph.gd) — no export_scale math.
func set_elevation_data(graph) -> void:
	elevations.clear()
	deck_elevations.clear()
	_deck_refs.clear()
	roof_elevations.clear()
	if graph == null:
		return
	for y in range(map_rect.size.y):
		for x in range(map_rect.size.x):
			var t := Vector2i(x, y)
			var cid: int = graph.cell_at(map_to_world(t))
			if cid < 0:
				continue   # square-graph out-of-bounds / empty-bucket sentinel
			var e: float = graph.ground_elev(cid)
			if absf(e) > 0.001:
				elevations[t] = e
			if graph.has_method("roof_elev"):
				var rf: float = graph.roof_elev(cid)
				if rf > 0.001:
					roof_elevations[t] = rf

func effective_elev(t: Vector2i) -> float:
	return deck_elevations.get(t, elevations.get(t, 0.0))

# --- roof layer (jump/rooftop traversal) ---
func roof_at(t: Vector2i) -> float:
	return roof_elevations.get(t, 0.0)

func has_roof(t: Vector2i) -> bool:
	return roof_elevations.has(t)

# Roof-surface walking gate: both tiles roofed and within one step of each other.
func can_step_roof(from_t: Vector2i, to_t: Vector2i) -> bool:
	return has_roof(from_t) and has_roof(to_t) \
		and absf(roof_at(to_t) - roof_at(from_t)) <= MAX_STEP_STORIES

# INVARIANT: anything that mutates global_position directly without move_and_slide
# bypasses elevation. All five current movers + the separation nudge are gated;
# future teleports/tweens must either check can_step or be intentional (warps are).
func can_step(from_t: Vector2i, to_t: Vector2i) -> bool:
	return absf(effective_elev(to_t) - effective_elev(from_t)) <= MAX_STEP_STORIES

func register_deck(t: Vector2i, elev: float) -> void:
	var hs: Array = _deck_refs.get(t, [])
	hs.append(elev)
	_deck_refs[t] = hs
	deck_elevations[t] = maxf(float(deck_elevations.get(t, -1e9)), elev)

func unregister_deck(t: Vector2i, elev: float) -> void:
	var hs: Array = _deck_refs.get(t, [])
	hs.erase(elev)   # removes the first matching height
	if hs.is_empty():
		_deck_refs.erase(t)
		deck_elevations.erase(t)
	else:
		var m := -1e9
		for h in hs:
			m = maxf(m, float(h))
		deck_elevations[t] = m

# True if every tile transition along the straight segment passes can_step.
# Use for displacements that can span more than one tile per frame (knockback,
# dashes, frame hitches) — an endpoint-only can_step would tunnel across a
# one-tile ravine or deck edge.
func can_traverse(from_pos: Vector2, to_pos: Vector2) -> bool:
	var dist := from_pos.distance_to(to_pos)
	if dist < 0.001:
		return true
	var steps := int(ceil(dist / (TILE_SIZE * 0.45)))
	var prev := world_to_map(from_pos)
	for i in range(1, steps + 1):
		var t := world_to_map(from_pos.lerp(to_pos, float(i) / float(steps)))
		if t != prev:
			if not can_step(prev, t):
				return false
			prev = t
	return true

# True if nothing on the VISION_BLOCKERS layer with occlude_top above the viewer's
# eye blocks the segment. Bodies WITHOUT the meta (legacy maps) always block —
# preserves legacy behavior since legacy viewers are always elev 0.
func sight_line_clear(space: PhysicsDirectSpaceState2D, from_pos: Vector2, to_pos: Vector2, viewer_elev: float = 0.0, target_elev: float = 0.0) -> bool:
	var params := PhysicsRayQueryParameters2D.create(from_pos, to_pos, CollisionLayers.VISION_RAY_MASK)
	params.collide_with_areas = false
	params.collide_with_bodies = true
	# An occluder is cleared when EITHER endpoint's eye tops it: a street guard
	# sees a character standing on a roof (target high), and an elevated viewer
	# sees over low cover (viewer high). Without the target term, LOS was
	# one-way — nobody on the ground could ever acquire a roof-walker. This is
	# an approximation (it doesn't interpolate the ray's height at the crossing,
	# so a high target hidden behind a FAR ridge reads as visible), but it fixes
	# the risk-free-rooftop-kill hole. target_elev defaults 0 -> identical to the
	# old viewer-only behavior for every ground target.
	var high := maxf(viewer_elev, target_elev) + EYE_HEIGHT_STORIES
	var excluded: Array[RID] = []
	for i in range(8):
		var hit := space.intersect_ray(params)
		if hit.is_empty():
			return true
		var top := 1e9
		if hit.collider != null and hit.collider.has_meta("occlude_top"):
			top = float(hit.collider.get_meta("occlude_top"))
		if high >= top:
			excluded.append(hit.rid)
			params.exclude = excluded
			continue
		return false
	return false

func get_neighboring_coords(grid_pos) -> Array:
	return [Vector2i(grid_pos.x + 1, grid_pos.y), Vector2i(grid_pos.x - 1, grid_pos.y), Vector2i(grid_pos.x, grid_pos.y + 1), Vector2i(grid_pos.x, grid_pos.y - 1)]

# --- Pathfinding (A*) ---
# jump_height/jump_range: a jump-capable character (grimalkin etc.) paths over
# a LAYERED graph (ground + roofs). Default 0.0 short-circuits to the exact
# walking A* every existing caller gets today.
func find_path(start_pos: Vector2i, end_pos: Vector2i, jump_height: float = 0.0, jump_range: int = 1, start_on_roof: bool = false, goal_on_roof: bool = false) -> Array[Vector2i]:
	if jump_height <= 0.001:
		return _find_path_walk(start_pos, end_pos)
	return _find_path_jump(start_pos, end_pos, jump_height, jump_range, start_on_roof, goal_on_roof)

func _find_path_walk(start_pos: Vector2i, end_pos: Vector2i) -> Array[Vector2i]:
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

# Layered A* for jumpers: nodes are Vector3i(x, y, layer) with layer 0 = the
# ground/deck surface and layer 1 = the roof surface. Jump edges (up onto a
# roof, across a gap, over a raised step) cost extra; drop-down edges cost a
# lot so the planner prefers graded routes and only drops when needed.
const JUMP_COST := 4.0
const DROP_COST := 40.0

func _find_path_jump(start_pos: Vector2i, end_pos: Vector2i, jump_height: float, jump_range: int, start_on_roof: bool, goal_on_roof: bool = false) -> Array[Vector2i]:
	var start := Vector3i(start_pos.x, start_pos.y, 1 if start_on_roof and has_roof(start_pos) else 0)
	# The goal SURFACE must match, not just x/y: every roofed footprint tile has
	# both a ground (interior) node and a roof node, so an x/y-only test lets A*
	# "arrive" on the roof directly above a ground/interior target. Reach a
	# roof-only tile (no pathable ground, e.g. a target on a roof over a wall)
	# on layer 1; reach everything else on layer 0. goal_on_roof forces layer 1
	# for an explicit roof pursuit over a walkable interior.
	var goal_ground: bool = grid_costs.get(end_pos, INF) != INF
	var want_layer: int = 1 if (goal_on_roof or not goal_ground) else 0
	var open_set: Array[Vector3i] = [start]
	var came_from: Dictionary = {}
	var g_score: Dictionary = { start: 0.0 }
	var f_score: Dictionary = { start: _heuristic(start_pos, end_pos) }
	while not open_set.is_empty():
		var current: Vector3i = open_set[0]
		for pos in open_set:
			if f_score.get(pos, INF) < f_score.get(current, INF):
				current = pos
		if current.x == end_pos.x and current.y == end_pos.y and current.z == want_layer:
			# project the layer out
			var path: Array[Vector2i] = [Vector2i(current.x, current.y)]
			var cur := current
			while cur in came_from:
				cur = came_from[cur]
				path.push_front(Vector2i(cur.x, cur.y))
			path.pop_front()
			return path
		open_set.erase(current)
		for e in _get_jump_neighbors(current, jump_height, jump_range):
			var nb: Vector3i = e["n"]
			var tentative: float = g_score.get(current, INF) + float(e["cost"])
			if tentative < g_score.get(nb, INF):
				came_from[nb] = current
				g_score[nb] = tentative
				f_score[nb] = tentative + _heuristic(Vector2i(nb.x, nb.y), end_pos)
				if not open_set.has(nb):
					open_set.append(nb)
	return []

func _get_jump_neighbors(node: Vector3i, jump_height: float, jump_range: int) -> Array:
	var out: Array = []
	var t := Vector2i(node.x, node.y)
	var dirs := [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
	if node.z == 0:
		var here := effective_elev(t)
		for dir in dirs:
			# plain walk
			var n1: Vector2i = t + dir
			if grid_costs.get(n1, INF) != INF and can_step(t, n1):
				out.append({"n": Vector3i(n1.x, n1.y, 0), "cost": grid_costs.get(n1, 1.0)})
			for d in range(1, jump_range + 1):
				var n: Vector2i = t + dir * d
				# jump up onto a roof: the ROOF layer floats above ground
				# obstacles (real roofs sit over INF wall tiles) — never
				# consult grid_costs for a roof landing. A roof over our OWN
				# head caps the mount: we can't leap up THROUGH the ceiling we
				# stand under onto a roof at/below it (only an unroofed tile, or
				# a strictly higher target, is mountable).
				if has_roof(n) and roof_at(n) - here <= jump_height \
						and (not has_roof(t) or roof_at(t) > roof_at(n) + 0.01):
					out.append({"n": Vector3i(n.x, n.y, 1), "cost": 1.0 + JUMP_COST * d})
				# ground-to-ground jumps (raised terrain / decks). Landings need
				# a pathable, UNROOFED tile (a roofed pathable tile is an interior
				# reached by walking/mounting, never by hopping a wall).
				if grid_costs.get(n, INF) != INF and not has_roof(n):
					var rise := effective_elev(n) - here
					if rise > MAX_STEP_STORIES and rise <= jump_height:
						# jump UP a step too tall to walk
						out.append({"n": Vector3i(n.x, n.y, 0), "cost": grid_costs.get(n, 1.0) + JUMP_COST * d})
					elif rise < -MAX_STEP_STORIES:
						# jump DOWN a ledge — the mirror of the roof drop-down.
						# Without it, a deck/scarp a jumper hopped UP onto is a
						# one-way trap (AI strands up top).
						out.append({"n": Vector3i(n.x, n.y, 0), "cost": grid_costs.get(n, 1.0) + DROP_COST * (-rise)})
	else:
		var rhere := roof_at(t)
		for dir in dirs:
			# roof-surface walk (flat cost: ground obstacles are irrelevant up here)
			var n1: Vector2i = t + dir
			if can_step_roof(t, n1):
				out.append({"n": Vector3i(n1.x, n1.y, 1), "cost": 1.0})
			for d in range(1, jump_range + 1):
				var n: Vector2i = t + dir * d
				# jump across a gap to another roof (no ground consult)
				if d > 1 and has_roof(n) and roof_at(n) - rhere <= jump_height:
					out.append({"n": Vector3i(n.x, n.y, 1), "cost": 1.0 + JUMP_COST * d})
				# drop down to the ground/deck surface: needs a pathable tile
				if grid_costs.get(n, INF) != INF and effective_elev(n) < rhere and not has_roof(n):
					out.append({"n": Vector3i(n.x, n.y, 0),
						"cost": grid_costs.get(n, 1.0) + DROP_COST * (rhere - effective_elev(n))})
	return out

func _heuristic(a: Vector2i, b: Vector2i) -> float:
	return abs(a.x - b.x) + abs(a.y - b.y)

func _get_neighbors(pos: Vector2i) -> Array[Vector2i]:
	var neighbors: Array[Vector2i] = []
	var dirs = [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
	for dir in dirs:
		var n_pos = pos + dir
		if grid_costs.get(n_pos, INF) != INF:
			if not can_step(pos, n_pos):
				continue
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
