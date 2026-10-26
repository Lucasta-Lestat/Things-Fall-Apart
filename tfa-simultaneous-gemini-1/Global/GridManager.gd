# res://Global/GridManager.gd
extends Node

var TILE_SIZE: int = 64
# Gameplay-unit tile size in px. TILE_SIZE is multiplied by world_render_scale
# on world maps so the grid matches the visually-inflated art; character and
# weapon art is NOT scaled with it, so any tiles->px conversion that measures
# against characters (ranged stand-off, projectile ranges) must use this one.
# Game.load_map keeps it at the map's raw tile size.
var COMBAT_TILE_SIZE: int = 64
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
# Dangerous-ground overlay (Vector2i -> penalty), SEPARATE from grid_costs on
# purpose: would_walk's <=10 threshold and the A* INF-goal reject must never
# see hazard weights (a burning tile is a terrible route, not a wall).
# SurfaceManager rebuilds it on a short cadence from the live fire/fluid sims
# and swaps the whole dict in. step_cost adds it, so every A* consumer — AI
# and player click-paths alike — detours around fire/acid when a detour
# exists, yet can still cross when it is the only way through.
# CORE = tiles that damage a character standing on them; HALO = tiles
# adjacent to fire (cells straddle tile borders and fire spreads) — a bias,
# never treated as dangerous by is_hazard_tile.
var hazard_costs: Dictionary = {}      # Vector2i -> HAZARD_CORE_COST or HAZARD_HALO_COST
const HAZARD_CORE_COST := 50.0
const HAZARD_HALO_COST := 4.0
const MAX_STEP_STORIES := 0.55
const EYE_HEIGHT_STORIES := 0.5
const FALL_SAFE_STORIES := 1.0         # drops <= this are graceful (no damage)
const FALL_DMG_PER_STORY := 8.0        # bludgeoning per story past FALL_SAFE
                                       # (scaled with the 30 HP baseline: a
                                       # 3-story drop wounds, 5 stories kills)

# --- Ground higher than one story (terraced / hillside maps) ---------------
# Every elevation in GridManager is ABSOLUTE stories (sea level 0). "High layer"
# and sight-cone tier are about HEIGHT ABOVE LOCAL GROUND, never a fixed
# constant: a walker on a terrace at ground 8 is on the ground layer.
const HIGH_LAYER_STORIES := 1.0          # raised surface (deck/roof) threshold, ABOVE TERRAIN
const RELIEF_LOS_MIN_SPAN := 1.0         # terrain span (stories) that turns on the eye-line LOS model
const TERRAIN_LOS_EPS := 0.1             # slack for nearest-cell projection noise on graded slopes
const ROOF_SLAB_EPS := 0.05
const MAX_PLANNED_DROP_STORIES := 3.0    # jump planner never plans a deliberate drop deeper than this
const DEEP_WATER_ELEV := -0.5            # shallow_water floor at/below this ABSOLUTE elev = deep (seabed)
var terrain_min: float = 0.0
var terrain_max: float = 0.0
# Relief LOS: interpolated eye line, terrain occlusion, roof slabs, and the
# relative occluder HIGH bit / RoofLayer tint. Auto-detected (terrain span >=
# RELIEF_LOS_MIN_SPAN) — never configured — so every shipped map (all span
# < 1 story) keeps the legacy max(viewer, target) + eye rule exactly.
var relief_los: bool = false             # reset in initialize(); set by refresh_terrain_stats()
# Sight-cone elevation bands (relief maps only): band b covers EYE heights
# [cone_band_base + b, cone_band_base + b + 1). Set by refresh_terrain_stats.
var cone_band_base: int = 0
const CONE_BAND_DECK_ALLOW := 1.5        # a battlement deck on the highest terrace must not clamp
var roof_lint_bad: int = 0               # roofed tiles with roof < terrain + 0.9 (relative-roof export bug)
var deck_lint_bad: int = 0               # deck tiles with walk_elev < terrain - 0.05 (MapLoader)
var tile_elev_used: bool = false         # last set_elevation_data took terrain from cells.json tile_elev

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
	hazard_costs.clear()
	terrain_min = 0.0
	terrain_max = 0.0
	relief_los = false
	cone_band_base = 0
	roof_lint_bad = 0
	deck_lint_bad = 0
	tile_elev_used = false
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
#
# Terrain source per tile: the graph's per-tile grid (cells.json "tile_elev")
# when it exists and is exactly map_rect.size — otherwise the legacy nearest-
# cell-centroid `elev`. Roofs always come from the nearest cell.
func set_elevation_data(graph) -> void:
	elevations.clear()
	deck_elevations.clear()
	_deck_refs.clear()
	roof_elevations.clear()
	roof_lint_bad = 0
	deck_lint_bad = 0
	tile_elev_used = false
	if graph == null:
		refresh_terrain_stats()
		return
	var cols: int = map_rect.size.x
	var rows: int = map_rect.size.y
	var use_te: bool = false
	if graph.has_method("has_tile_elev"):
		if graph.has_tile_elev(cols, rows):
			use_te = true
		elif graph.has_method("tile_elev_dims"):
			var dims: Vector2i = graph.tile_elev_dims()
			if dims != Vector2i.ZERO:
				push_warning("cells tile_elev is %dx%d but the map is %dx%d tiles: using nearest-cell elev"
					% [dims.x, dims.y, cols, rows])
	tile_elev_used = use_te
	var has_roof_ch: bool = graph.has_method("roof_elev")
	for y in range(rows):
		for x in range(cols):
			var t := Vector2i(x, y)
			var cid: int = graph.cell_at(map_to_world(t))
			var e: float = 0.0
			if use_te:
				e = graph.tile_elev(t)
			elif cid >= 0:
				e = graph.ground_elev(cid)
			if absf(e) > 0.001:
				elevations[t] = e
			if cid < 0:
				continue   # square-graph out-of-bounds / empty-bucket sentinel (roof only)
			if has_roof_ch:
				var rf: float = graph.roof_elev(cid)
				if rf > 0.001:
					roof_elevations[t] = rf
					if rf < e + 0.9:
						roof_lint_bad += 1
	refresh_terrain_stats()
	if roof_lint_bad > 0:
		push_warning("cells roof below ground+0.9 on %d tiles: cells.json roof must be ABSOLUTE stories" % roof_lint_bad)

func effective_elev(t: Vector2i) -> float:
	return deck_elevations.get(t, elevations.get(t, 0.0))

# Bare terrain under a tile — never decks or roofs. ABSOLUTE stories.
func terrain_elev(t: Vector2i) -> float:
	return float(elevations.get(t, 0.0))

# How far `elev` (an absolute surface height) stands above the terrain at t.
func height_above_ground(t: Vector2i, elev: float) -> float:
	return elev - terrain_elev(t)

# THE view-layer / sight-tier predicate: on a roof, or standing on a surface
# at least HIGH_LAYER_STORIES above the local ground (a battlement deck). A
# walker on a high terrace is on the ground layer.
func is_high_layer(c) -> bool:
	if c == null or not is_instance_valid(c):
		return false
	if "on_roof" in c and c.on_roof:
		return true
	if c.has_method("height_above_ground"):
		var hag: float = c.height_above_ground()
		return hag >= HIGH_LAYER_STORIES
	if c.has_method("get_elevation") and c is Node2D:
		var ce: float = c.get_elevation()
		return height_above_ground(world_to_map(c.global_position), ce) >= HIGH_LAYER_STORIES
	return false

# Terrain span + the relief_los switch. Call after any bulk write to
# `elevations` (set_elevation_data does; tests that hand-write terrain must).
func refresh_terrain_stats() -> void:
	var lo: float = INF
	var hi: float = -INF
	for v in elevations.values():
		lo = minf(lo, float(v))
		hi = maxf(hi, float(v))
	if elevations.size() < map_rect.size.x * map_rect.size.y:   # sparse: absent tiles read 0
		lo = minf(lo, 0.0)
		hi = maxf(hi, 0.0)
	terrain_min = lo if lo != INF else 0.0
	terrain_max = hi if hi != -INF else 0.0
	relief_los = terrain_max - terrain_min >= RELIEF_LOS_MIN_SPAN
	# Band 0 sits at the lowest ground, unless the highest surface someone can
	# stand on (top terrace + a deck, or the highest roof) would then clamp
	# above band 17. Then the bands anchor at the TOP instead: a viewer
	# clamped into band 0 reads as standing higher (cone over-reports, the
	# safe direction), but one clamped into band 17 would read lower and be
	# shadowed by the very cliff they stand on (tg_hillside_upper/middle span
	# 18+ stories from the sea floor to the summit roofs).
	var top: float = terrain_max + CONE_BAND_DECK_ALLOW
	for r in roof_elevations.values():
		top = maxf(top, float(r))
	cone_band_base = floori(terrain_min)
	var top_band: int = floori(top + EYE_HEIGHT_STORIES) - cone_band_base
	if top_band > CollisionLayers.SIGHT_BAND_COUNT - 1:
		cone_band_base += top_band - (CollisionLayers.SIGHT_BAND_COUNT - 1)

# --- Sight-cone elevation bands (v1.1; relief maps only) --------------------
# A 2D light's shadow depends only on the light, the occluder and their mask
# bits, so cones can't interpolate an eye line. Instead each viewer's cone
# culls on ONE band bit picked by its own eye height, and every occluder
# carries the bits of the bands it hides things from. Like the GROUND/HIGH
# tiers this only looks at the viewer (no target height, no interpolation).
# Flat maps never use bands: Game / ProceduralCharacter keep GROUND/HIGH.

# Band of a viewer whose standing surface is at `elev` (ABSOLUTE stories).
func cone_band(elev: float) -> int:
	return clampi(floori(elev + EYE_HEIGHT_STORIES - float(cone_band_base)), 0, CollisionLayers.SIGHT_BAND_COUNT - 1)

func cone_band_bit(band: int) -> int:
	return 1 << (CollisionLayers.SIGHT_BAND_SHIFT + clampi(band, 0, CollisionLayers.SIGHT_BAND_COUNT - 1))

# Bits of every band whose representative eye (the middle of the band,
# cone_band_base + b + 0.5) is below `top_abs`: an occluder that tall hides
# what lies behind it from those viewers.
func band_mask_below(top_abs: float) -> int:
	var n: int = clampi(ceili(top_abs - float(cone_band_base) - 0.5), 0, CollisionLayers.SIGHT_BAND_COUNT)
	return ((1 << n) - 1) << CollisionLayers.SIGHT_BAND_SHIFT

# Sea / deep water: a shallow_water floor whose surface sits at or below
# DEEP_WATER_ELEV (absolute; sea surface is 0, seabed -1). There is no swimming:
# the jump planner never drops into it and forced movers refuse to carry a body
# into it (a knocked-off-the-quay body would be soft-locked on the seabed).
# Relief maps only: a sea map always spans >= 1 story (land >= 0, seabed -1),
# while the shipped flat maps' walkable ravine streams (tg_export -0.98,
# tg_guild_hall -0.66) must keep their current knockback/jump behaviour.
func is_deep_water(t: Vector2i) -> bool:
	return relief_los and floors.get(t, "") == "shallow_water" \
		and effective_elev(t) <= DEEP_WATER_ELEV + 0.0001

# True if the straight segment enters a deep-water tile that its start tile is
# not already in (sampled like can_traverse). Forced movers dead-stop on it.
func segment_enters_deep_water(from_pos: Vector2, to_pos: Vector2) -> bool:
	if not relief_los:
		return false
	var start_t := world_to_map(from_pos)
	if is_deep_water(start_t):
		return false   # already in: let them move (out, ideally)
	var dist := from_pos.distance_to(to_pos)
	if dist < 0.001:
		return false
	var steps := int(ceil(dist / (TILE_SIZE * 0.45)))
	var prev := start_t
	for i in range(1, steps + 1):
		var t := world_to_map(from_pos.lerp(to_pos, float(i) / float(steps)))
		if t != prev:
			if is_deep_water(t):
				return true
			prev = t
	return false

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

# Tiles under CLOSED-but-UNLOCKED doors (Door._sync_door_pass): the obstacle
# grid says INF (the leaf physically blocks), but A* may route through at a
# penalty — the walker pushes the door open on contact. Refcounted: junction
# tiles could be shared by two doorways.
var door_pass: Dictionary = {}
# Tile -> the covering door's exact GAP CENTRE (world px), open or closed.
# Path waypoints are tile centres, and a 60px door gap rarely centres on a
# 64px tile — walking tile-centre paths caught the jamb and scraped through
# every doorway. path_to_waypoints snaps door tiles to these.
var door_gaps: Dictionary = {}


# Path tiles -> world waypoints, snapping door tiles to the door's gap centre.
# Consecutive tiles of the same door collapse onto one waypoint.
func path_to_waypoints(tile_path: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for t in tile_path:
		var p: Vector2 = door_gaps.get(t, map_to_world(t))
		if out.size() > 0 and out[out.size() - 1].distance_to(p) < 8.0:
			continue
		out.append(p)
	return out
const DOOR_PASS_COST := 6.0

func set_door_pass(t: Vector2i, on: bool) -> void:
	if on:
		door_pass[t] = int(door_pass.get(t, 0)) + 1
	elif door_pass.has(t):
		var n := int(door_pass[t]) - 1
		if n <= 0:
			door_pass.erase(t)
		else:
			door_pass[t] = n

func step_cost(t: Vector2i) -> float:
	var c: float = grid_costs.get(t, INF)
	if c == INF and door_pass.has(t):
		c = DOOR_PASS_COST
	if c != INF and not hazard_costs.is_empty():
		# added AFTER the door substitution so a burning doorway is penalized too
		c += float(hazard_costs.get(t, 0.0))
	return c

# True only for tiles that actively damage a standing character (fire core,
# acid/poison pools, electrified ground) — the halo bias never trips this.
func is_hazard_tile(t: Vector2i) -> bool:
	return float(hazard_costs.get(t, 0.0)) >= HAZARD_CORE_COST

# Nearest walkable, non-hazardous tile in growing rings around t (t itself
# qualifies). Vector2i.MAX when every candidate within max_r is unsafe —
# callers keep their original goal in that case.
func nearest_safe_tile(t: Vector2i, max_r: int = 4) -> Vector2i:
	for r in range(0, max_r + 1):
		var best := Vector2i.MAX
		var best_d2 := 2147483647
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue   # ring shell only
				var c := t + Vector2i(dx, dy)
				if not would_walk(c) or is_hazard_tile(c):
					continue
				var d2 := dx * dx + dy * dy
				if d2 < best_d2:
					best_d2 = d2
					best = c
		if best != Vector2i.MAX:
			return best
	return Vector2i.MAX

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
#
# Elevations are ABSOLUTE stories. NAN (the default) means "the ground or deck
# under that point" (effective_elev) — sea level 0 is underground on a terrace.
#
# Two models, chosen per map by relief_los (terrain span >= 1 story):
#   - flat maps (every shipped map): the legacy rule below, unchanged — an
#     occluder clears when max(viewer, target) + eye tops it.
#   - relief maps: the eye LINE is interpolated between the two eyes at the
#     occluder crossing, terrain-following walls re-base their top on the
#     ground at the hit, and terrain_line_clear adds terrain and roof slabs.
func sight_line_clear(space: PhysicsDirectSpaceState2D, from_pos: Vector2, to_pos: Vector2, viewer_elev: float = NAN, target_elev: float = NAN) -> bool:
	if is_nan(viewer_elev):
		viewer_elev = effective_elev(world_to_map(from_pos))
	if is_nan(target_elev):
		target_elev = effective_elev(world_to_map(to_pos))
	if relief_los:
		return _sight_line_clear_relief(space, from_pos, to_pos, viewer_elev, target_elev)
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
	# Each cleared occluder joins the exclude list, so this ends as soon as the
	# ray stops hitting; 64 is only a safety cap. (8 was low enough that an
	# elevated eye over many short wall segments lost targets in its lit cone.)
	for i in range(64):
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

# Relief-map sight line (relief_los on). Physics first, so wall-blocked rays
# never pay for the terrain walk.
func _sight_line_clear_relief(space: PhysicsDirectSpaceState2D, from_pos: Vector2, to_pos: Vector2, viewer_elev: float, target_elev: float) -> bool:
	var h0: float = viewer_elev + EYE_HEIGHT_STORIES
	var h1: float = target_elev + EYE_HEIGHT_STORIES
	var seg_len: float = from_pos.distance_to(to_pos)
	var dir: Vector2 = (to_pos - from_pos) / seg_len if seg_len > 0.001 else Vector2.ZERO
	var params := PhysicsRayQueryParameters2D.create(from_pos, to_pos, CollisionLayers.VISION_RAY_MASK)
	params.collide_with_areas = false
	params.collide_with_bodies = true
	var excluded: Array[RID] = []
	for i in range(64):
		var hit := space.intersect_ray(params)
		if hit.is_empty():
			return terrain_line_clear(from_pos, to_pos, h0, h1)
		var top := 1e9
		var col: Object = hit.collider
		var hp: Vector2 = hit.position
		if col != null and col.has_meta("occlude_top"):
			top = float(col.get_meta("occlude_top"))
			if col.has_meta("occlude_rel_h"):
				# wall spanning relief: its top follows the ground at the
				# crossing — the HIGHER of its two faces, so a pad-edge house
				# wall seen from the street below still reaches pad + height
				var half_px: float = float(col.get_meta("occlude_half_px", 8.0))
				top = _wall_face_ground_max(hp, dir, half_px) + float(col.get_meta("occlude_rel_h"))
		var eye: float = maxf(h0, h1)
		if seg_len > 0.001:
			eye = lerpf(h0, h1, clampf(from_pos.distance_to(hp) / seg_len, 0.0, 1.0))
		if eye >= top:
			excluded.append(hit.rid)
			params.exclude = excluded
			continue
		return false
	return false

# Highest terrain on either face of a terrain-following wall where a sight ray
# crosses it (hp = the ray's hit on the near face, dir = unit ray direction,
# half_px = the wall's half thickness). Each face is read at the surface AND
# half a tile further out: tile_elev is sampled at tile centres, so a pad edge
# is only placed to within half a tile and a house wall can stand that far
# inside a street-valued tile while still bounding the raised pad. Reading only
# the surface let a street viewer see into the pad interior whenever the wall
# sat more than ~9 px from the tile step (xcheck C12 / risk 6). Off-map samples
# are skipped. Mirrors MapLoader._wall_spans_relief's reach.
func _wall_face_ground_max(hp: Vector2, dir: Vector2, half_px: float) -> float:
	var reach: float = float(TILE_SIZE) * 0.5
	var far0: Vector2 = hp + dir * (2.0 * half_px + 2.0)
	var qs := PackedVector2Array([hp - dir * 2.0, hp - dir * (reach + 2.0), far0, far0 + dir * reach])
	var g: float = -INF
	for q in qs:
		var t := world_to_map(q)
		if map_rect.has_point(t):
			g = maxf(g, terrain_elev(t))
	if g == -INF:
		g = terrain_elev(world_to_map(hp))
	return g

## Tile-exact walk (Amanatides-Woo) over every tile the segment crosses.
## Endpoint tiles never block. Terrain is a heightfield sampled at tile centres:
## a tile blocks when its ground is above the eye line at the segment point
## nearest its centre (+TERRAIN_LOS_EPS slack). A roof blocks only when the line
## CROSSES its plane inside the tile (indoors-to-indoors and over-the-top both
## pass). h0/h1 are absolute EYE heights at from/to.
func terrain_line_clear(from_pos: Vector2, to_pos: Vector2, h0: float, h1: float) -> bool:
	var t0 := world_to_map(from_pos)
	var t1 := world_to_map(to_pos)
	if t0 == t1:
		return true
	var d: Vector2 = to_pos - from_pos
	var len2: float = d.length_squared()
	if len2 < 1e-9:
		return true
	var ts := float(TILE_SIZE)
	var sx: int = 1 if d.x > 0.0 else -1
	var sy: int = 1 if d.y > 0.0 else -1
	var tmx: float = INF
	var tdx: float = INF
	var tmy: float = INF
	var tdy: float = INF
	if absf(d.x) > 1e-6:
		tmx = ((float(t0.x) + (1.0 if sx > 0 else 0.0)) * ts - from_pos.x) / d.x
		tdx = ts / absf(d.x)
	if absf(d.y) > 1e-6:
		tmy = ((float(t0.y) + (1.0 if sy > 0 else 0.0)) * ts - from_pos.y) / d.y
		tdy = ts / absf(d.y)
	var cur := t0
	var t_in := 0.0
	for _g in range(2 * (absi(t1.x - t0.x) + absi(t1.y - t0.y)) + 4):
		var t_out: float = minf(minf(tmx, tmy), 1.0)
		if cur != t0 and cur != t1:
			var tc: float = clampf((map_to_world(cur) - from_pos).dot(d) / len2, t_in, t_out)
			var g: float = float(elevations.get(cur, 0.0))
			if g > lerpf(h0, h1, tc) + TERRAIN_LOS_EPS:
				return false
			var r: float = float(roof_elevations.get(cur, 0.0))
			if r > 0.0:
				var ha: float = lerpf(h0, h1, t_in)
				var hb: float = lerpf(h0, h1, t_out)
				if minf(ha, hb) < r - ROOF_SLAB_EPS and maxf(ha, hb) > r + ROOF_SLAB_EPS:
					return false
		if cur == t1 or t_out >= 1.0:
			return true
		if tmx < tmy:
			cur.x += sx
			t_in = tmx
			tmx += tdx
		else:
			cur.y += sy
			t_in = tmy
			tmy += tdy
	return true

func get_neighboring_coords(grid_pos) -> Array:
	return [Vector2i(grid_pos.x + 1, grid_pos.y), Vector2i(grid_pos.x - 1, grid_pos.y), Vector2i(grid_pos.x, grid_pos.y + 1), Vector2i(grid_pos.x, grid_pos.y - 1)]

# --- A* open set: binary min-heap over [f, node] pairs ---
# LAZY DELETION, deliberately not a closed set. The old linear open_set re-added
# an already-expanded node whenever its g improved, so the search tolerated an
# inconsistent heuristic — and this one IS inconsistent whenever a floor has
# walkability > 1 (grid_costs = 1.0/walkability, so a step can cost < 1 while
# _heuristic charges a flat 1 per tile). A hard closed set would silently start
# returning worse paths on those tiles. Instead an entry whose f no longer
# matches f_score is stale and skipped, and an improved node is simply pushed
# again — same expansions, same paths, cheaper bookkeeping.
func _heap_push(heap: Array, f: float, node: Variant) -> void:
	heap.append([f, node])
	var i := heap.size() - 1
	while i > 0:
		var parent := (i - 1) >> 1
		if float(heap[parent][0]) <= float(heap[i][0]):
			break
		var tmp: Array = heap[parent]
		heap[parent] = heap[i]
		heap[i] = tmp
		i = parent

func _heap_pop(heap: Array) -> Array:
	var top: Array = heap[0]
	var last: Array = heap.pop_back()
	if not heap.is_empty():
		heap[0] = last
		var i := 0
		var n := heap.size()
		while true:
			var l := i * 2 + 1
			var r := l + 1
			var small := i
			if l < n and float(heap[l][0]) < float(heap[small][0]):
				small = l
			if r < n and float(heap[r][0]) < float(heap[small][0]):
				small = r
			if small == i:
				break
			var tmp: Array = heap[small]
			heap[small] = heap[i]
			heap[i] = tmp
			i = small
	return top

# --- Pathfinding (A*) ---
# jump_height/jump_range: a jump-capable character (grimalkin etc.) paths over
# a LAYERED graph (ground + roofs). Default 0.0 short-circuits to the exact
# walking A* every existing caller gets today.
func find_path(start_pos: Vector2i, end_pos: Vector2i, jump_height: float = 0.0, jump_range: int = 1, start_on_roof: bool = false, goal_on_roof: bool = false) -> Array[Vector2i]:
	if jump_height <= 0.001:
		return _find_path_walk(start_pos, end_pos)
	return _find_path_jump(start_pos, end_pos, jump_height, jump_range, start_on_roof, goal_on_roof)

func _find_path_walk(start_pos: Vector2i, end_pos: Vector2i) -> Array[Vector2i]:
	# Unreachable-goal early-out. _get_neighbors never emits a tile the grid calls
	# INF, so `current == end_pos` can never fire for a goal inside a wall or off
	# the map — the loop below would drain the entire connected component first
	# and only then return []. On structured maps that is the single most
	# expensive thing pathfinding does, and callers ask for it constantly (a goal
	# under a structure, a cursor dragged across a building, an AI probing a
	# sealed room). Answer it in O(1) instead.
	if grid_costs.get(end_pos, INF) == INF and not door_pass.has(end_pos):
		return []
	var open_heap: Array = []
	var came_from: Dictionary = {}
	var g_score: Dictionary = { start_pos: 0.0 }
	var start_f: float = _heuristic(start_pos, end_pos)
	var f_score: Dictionary = { start_pos: start_f }
	_heap_push(open_heap, start_f, start_pos)

	while not open_heap.is_empty():
		var entry: Array = _heap_pop(open_heap)
		var current: Vector2i = entry[1]
		if float(entry[0]) > float(f_score.get(current, INF)):
			continue   # stale entry: this node was re-pushed with a better f
		if current == end_pos:
			return _reconstruct_path(came_from, current)
		for neighbor in _get_neighbors(current):
			var tentative_g_score: float = float(g_score.get(current, INF)) + step_cost(neighbor)
			if tentative_g_score < float(g_score.get(neighbor, INF)):
				came_from[neighbor] = current
				g_score[neighbor] = tentative_g_score
				var nf: float = tentative_g_score + _heuristic(neighbor, end_pos)
				f_score[neighbor] = nf
				_heap_push(open_heap, nf, neighbor)
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
	# Same early-out as the walking search, widened by the two ways a jumper can
	# legitimately finish on a tile the ground grid calls INF: a roof over it, or
	# a closed-unlocked door it will shove open. Without one of those three the
	# goal node is unreachable and the search below is a pure component drain.
	if not goal_ground and not door_pass.has(end_pos) and not has_roof(end_pos):
		return []
	var want_layer: int = 1 if (goal_on_roof or not goal_ground) else 0
	var open_heap: Array = []
	var came_from: Dictionary = {}
	var g_score: Dictionary = { start: 0.0 }
	var start_f: float = _heuristic(start_pos, end_pos)
	var f_score: Dictionary = { start: start_f }
	_heap_push(open_heap, start_f, start)
	while not open_heap.is_empty():
		var entry: Array = _heap_pop(open_heap)
		var current: Vector3i = entry[1]
		if float(entry[0]) > float(f_score.get(current, INF)):
			continue   # stale entry: this node was re-pushed with a better f
		if current.x == end_pos.x and current.y == end_pos.y and current.z == want_layer:
			# project the layer out
			var path: Array[Vector2i] = [Vector2i(current.x, current.y)]
			var cur := current
			while cur in came_from:
				cur = came_from[cur]
				path.push_front(Vector2i(cur.x, cur.y))
			path.pop_front()
			return path
		for e in _get_jump_neighbors(current, jump_height, jump_range):
			var nb: Vector3i = e["n"]
			var tentative: float = float(g_score.get(current, INF)) + float(e["cost"])
			if tentative < float(g_score.get(nb, INF)):
				came_from[nb] = current
				g_score[nb] = tentative
				var nbf: float = tentative + _heuristic(Vector2i(nb.x, nb.y), end_pos)
				f_score[nb] = nbf
				_heap_push(open_heap, nbf, nb)
	return []

func _get_jump_neighbors(node: Vector3i, jump_height: float, jump_range: int) -> Array:
	var out: Array = []
	var t := Vector2i(node.x, node.y)
	var dirs := [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
	if node.z == 0:
		var here := effective_elev(t)
		for dir in dirs:
			# plain walk (door_pass: closed-unlocked doors are walkable at a
			# penalty — the walker pushes them open on contact)
			var n1: Vector2i = t + dir
			if (grid_costs.get(n1, INF) != INF or door_pass.has(n1)) and can_step(t, n1):
				out.append({"n": Vector3i(n1.x, n1.y, 0), "cost": step_cost(n1)})
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
						# jump UP a step too tall to walk. step_cost, not raw
						# grid_costs: a landing pays hazard weights like any
						# walk edge, or the planner leaps INTO fire for ~9.
						out.append({"n": Vector3i(n.x, n.y, 0), "cost": step_cost(n) + JUMP_COST * d})
					elif rise < -MAX_STEP_STORIES and -rise <= MAX_PLANNED_DROP_STORIES \
							and not is_deep_water(n):
						# jump DOWN a ledge — the mirror of the roof drop-down.
						# Without it, a deck/scarp a jumper hopped UP onto is a
						# one-way trap (AI strands up top). Capped: on a hillside
						# a cliff brow is a 4-8 story (lethal) drop the planner
						# must never choose; never into the sea (no swimming).
						out.append({"n": Vector3i(n.x, n.y, 0), "cost": step_cost(n) + DROP_COST * (-rise)})
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
				# step_cost so a burning street below costs its hazard weight
				# (same planned-drop cap and sea veto as the ground ledge edge)
				if grid_costs.get(n, INF) != INF and effective_elev(n) < rhere and not has_roof(n) \
						and rhere - effective_elev(n) <= MAX_PLANNED_DROP_STORIES and not is_deep_water(n):
					out.append({"n": Vector3i(n.x, n.y, 0),
						"cost": step_cost(n) + DROP_COST * (rhere - effective_elev(n))})
	return out

func _heuristic(a: Vector2i, b: Vector2i) -> float:
	return abs(a.x - b.x) + abs(a.y - b.y)

func _get_neighbors(pos: Vector2i) -> Array[Vector2i]:
	var neighbors: Array[Vector2i] = []
	var dirs = [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
	for dir in dirs:
		var n_pos = pos + dir
		if grid_costs.get(n_pos, INF) != INF or door_pass.has(n_pos):
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

# Every tile reachable from `from_t` in at most `max_steps` moves, mapped to the
# number of moves it takes. `from_t` itself is excluded.
#
# This is the answer to "where near here can I actually get to", which callers
# used to compute by running a full find_path() PER CANDIDATE TILE — quadratic
# work whose worst case (a candidate walled off from the asker) drained the whole
# component every single time. One flood costs at most one expansion per tile in
# range and answers for all of them at once.
#
# Pull a world point out of wall tiles and off their edges so a body circle
# can actually STAND on it: an INF tile becomes the nearest walkable tile's
# centre, and coordinates are inset away from any adjacent INF tile edge.
# Used to sanitise freehand movement targets (drawn tactical samples, sub-tile
# micro-moves) — a sample a few px inside the blocked band is an unreachable
# target the mover can only resolve with a stuck-escape stall.
# Door tiles are exempt: their gap centres legitimately sit near tile edges.
func clamp_off_walls(p: Vector2, inset: float = 9.0) -> Vector2:
	var t := world_to_map(p)
	if grid_costs.get(t, INF) == INF and not door_pass.has(t):
		t = nearest_walkable(t)
		p = map_to_world(t)
	if door_pass.has(t) or door_gaps.has(t):
		return p
	var half := TILE_SIZE * 0.5
	var c := map_to_world(t)
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nb: Vector2i = t + d
		if grid_costs.get(nb, INF) == INF and not door_pass.has(nb):
			if d.x > 0:
				p.x = minf(p.x, c.x + half - inset)
			elif d.x < 0:
				p.x = maxf(p.x, c.x - half + inset)
			elif d.y > 0:
				p.y = minf(p.y, c.y + half - inset)
			else:
				p.y = maxf(p.y, c.y - half + inset)
	return p


# Nearest finite-cost tile to `t` within max_r rings (t itself first). Lets a
# click that lands ON a wall resolve to the floor beside it instead of an
# empty path (the empty-path fallbacks used to fabricate a straight line
# through the wall — the "party member grinds into the wall" bug).
func nearest_walkable(t: Vector2i, max_r: int = 3) -> Vector2i:
	if grid_costs.get(t, INF) != INF:
		return t
	for r in range(1, max_r + 1):
		var best := t
		var best_d := INF
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var n := t + Vector2i(dx, dy)
				if grid_costs.get(n, INF) == INF:
					continue
				var d := Vector2(dx, dy).length_squared()
				if d < best_d:
					best_d = d
					best = n
		if best_d < INF:
			return best
	return t


# STEPS, not cost: this is a reachability question, so per-tile walkability is
# irrelevant and a plain BFS is exact. Use find_path when you need the route.
# The step bound is also a feature for "nearby" queries — a tile two away around
# forty tiles of wall is not somewhere you wanted to send anyone.
#
# jump_height mirrors find_path: <= 0 walks the ground graph (the common case),
# otherwise the layered ground+roof graph, with roof nodes projected back down to
# their tile so callers still get plain Vector2i keys.
func reachable_within(from_t: Vector2i, max_steps: int, jump_height: float = 0.0, jump_range: int = 1, start_on_roof: bool = false) -> Dictionary:
	var out: Dictionary = {}
	if max_steps <= 0:
		return out
	if jump_height <= 0.001:
		var frontier: Array[Vector2i] = [from_t]
		var depth := 0
		while depth < max_steps and not frontier.is_empty():
			depth += 1
			var next: Array[Vector2i] = []
			for t in frontier:
				for n in _get_neighbors(t):
					if n == from_t or out.has(n):
						continue
					out[n] = depth
					next.append(n)
			frontier = next
		return out
	# Layered flood. Nodes are Vector3i(x, y, layer) exactly as in _find_path_jump;
	# `seen` keys on the node so a tile can be entered once per surface, while
	# `out` keeps the shallowest depth at which the tile was touched on either.
	var seen: Dictionary = {}
	var start := Vector3i(from_t.x, from_t.y, 1 if start_on_roof and has_roof(from_t) else 0)
	seen[start] = true
	var lframe: Array[Vector3i] = [start]
	var ldepth := 0
	while ldepth < max_steps and not lframe.is_empty():
		ldepth += 1
		var lnext: Array[Vector3i] = []
		for node in lframe:
			for e in _get_jump_neighbors(node, jump_height, jump_range):
				var nb: Vector3i = e["n"]
				if seen.has(nb):
					continue
				seen[nb] = true
				lnext.append(nb)
				var flat := Vector2i(nb.x, nb.y)
				if flat != from_t and not out.has(flat):
					out[flat] = ldepth
		lframe = lnext
	return out

# A random point within +-spread of base_pos that a group member can actually
# stand on AND walk to from base_pos: same step-connected component (never the
# terrace above or below across a cliff, never inside a wall), not a hazard.
# Falls back to base_pos after `tries` misses. Pass a precomputed `reach`
# (reachable_within from base_pos's tile) when scattering several members.
func scatter_point(base_pos: Vector2, spread: float, reach: Dictionary = {}, tries: int = 8) -> Vector2:
	var bt := world_to_map(base_pos)
	if reach.is_empty():
		reach = reachable_within(bt, int(ceil(spread / float(TILE_SIZE))) * 2 + 1)
	for _i in tries:
		var p: Vector2 = base_pos + Vector2(randf_range(-spread, spread), randf_range(-spread, spread))
		var t := world_to_map(p)
		if t == bt or (reach.has(t) and would_walk(t) and not is_hazard_tile(t)):
			return p
	return base_pos

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
