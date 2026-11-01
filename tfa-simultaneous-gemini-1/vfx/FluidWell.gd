class_name FluidWell
extends Node2D

# A point on the ground that gushes fluid for a fixed time.
#
# `spawn_fluid` paints a Manhattan diamond once and is done; this owns a
# duration. It is shaped like vfx/SilenceZone.gd -- a self-parented,
# self-expiring Node2D that gates its own clock on PauseManager -- because that
# is the only persistent effect node in the project that survives a tactical
# pause correctly.
#
# Authored generically (fluid_type / radius / duration) rather than as an
# "oil well" node, the same way SilenceZone's `gain` is a float rather than a
# silence flag: a water spring, a blood font or a poison seep are all this node
# with a different payload.
#
# Two deliberate choices keep it cheap and keep the pool sane:
#
# 1. TOP UP, DON'T ACCUMULATE. FluidManager.register_fluid and CellFluid._add
#    are both unbounded adds -- there is no clamp anywhere. Depositing a fixed
#    amount every tick for six seconds builds a mass column that then bleeds
#    outward for minutes (legacy oil has evaporation 0.0, so it never leaves).
#    Instead each tick reads what is already there and deposits only the deficit
#    up to a target depth, so the slick fills, holds, and heals where it has
#    drained -- which is also what a well should look like.
#
# 2. PRECOMPUTE ONCE, EXPAND A FRONT. The target tiles/cells are resolved in a
#    single pass on the first tick and sorted by distance, so per-tick work is a
#    prefix slice of a sorted list. CellFluid.pour() is O(cell_count) and the big
#    structured maps carry ~24,500 cells; calling it every tick would be millions
#    of iterations. The expanding front also staggers the legacy path's
#    Fluid.tscn instantiations across ticks instead of ~29 nodes in one frame.

## Seconds between deposits. Matches FluidManager.SIM_INTERVAL and
## CellFluid.SIM_INTERVAL (both 0.25) -- depositing faster than the sim steps is
## wasted work.
const EMIT_INTERVAL: float = 0.25

## Target depth on the legacy tile sim. FluidManager.FULL_THRESHOLD is 0.1, so
## anything at or above that renders visually full; 0.12 gives a little headroom
## without piling up mass that will creep outward forever.
const TILE_TARGET_DEPTH: float = 0.12

## Target depth on the structured cell sim. CellFluid._puddle_of gives oil a 0.25
## pool floor and flow stops below it, so a target under that settles invisible
## between blob centres. 0.30 sits just above the floor: solid, with a little
## head to creep with.
const CELL_TARGET_DEPTH: float = 0.30

## Fraction of the duration spent growing to the full radius. The pool wells
## outward from the centre rather than appearing whole, which is both the read
## the spell wants and what staggers the legacy visual spawns.
const GROW_FRACTION: float = 0.6

## Hard ceiling on total deposited depth, as a multiple of (targets x target
## depth). Flow drains the centre and the well tops it back up, so without this a
## well over sloped ground could pump indefinitely.
const BUDGET_SLACK: float = 1.6

## Fluid id from data/fluids.json.
@export var fluid_type: String = "oil"

## Radius of the flooded region, in world pixels.
@export var radius: float = 192.0

## Seconds the well gushes. Values <= 0 mean it never expires on its own.
@export var duration: float = 6.0

## Optional Node2D scene spawned as a child for the well's lifetime.
@export var visual_scene_path: String = ""

var _age: float = 0.0
var _emit_accum: float = 0.0
var _built: bool = false
var _fm: FluidManager = null
var _cf: CellFluid = null
var _tiles: Array[Vector2i] = []
var _cells: PackedInt32Array = PackedInt32Array()
var _points: PackedVector2Array = PackedVector2Array()
var _dists: PackedFloat32Array = PackedFloat32Array()
var _deposited: float = 0.0
var _budget: float = 0.0
var _visual: Node2D = null


func _ready() -> void:
	# Emit on the first unpaused frame rather than EMIT_INTERVAL seconds in.
	_emit_accum = EMIT_INTERVAL


func _process(delta: float) -> void:
	# Game.gd sets PROCESS_MODE_ALWAYS on the Game root and process_mode is
	# INHERITED, so get_tree().paused freezes nothing parented under Game. Every
	# persistent node here either self-gates like this or is ticked from
	# Game._process's pause-gated block. Without this the well would burn its six
	# seconds while the tactical planner has the world stopped -- and the fluid
	# sim it feeds is inside that same block, so it would be depositing into a
	# simulation that is not flowing.
	if PauseManager.is_paused:
		return

	if not _built:
		_build()

	_age += delta
	if duration > 0.0 and _age >= duration:
		queue_free()
		return

	_emit_accum += delta
	if _emit_accum < EMIT_INTERVAL:
		return
	_emit_accum = 0.0
	_emit()


# Deferred out of _ready() on purpose. AbilityEffect parents this node before
# positioning it (the documented order -- setting global_position on an
# unparented node silently means something else), so global_position is still
# (0, 0) while _ready runs and every tile/cell picked there would be wrong.
func _build() -> void:
	_built = true

	_spawn_visual()

	var scene_root: Node = get_tree().current_scene
	if scene_root != null:
		_fm = scene_root.get_node_or_null("FluidManager") as FluidManager
	if _fm == null:
		push_warning("FluidWell: no FluidManager under the current scene; well is inert.")
		return

	# Structured maps route every deposit into the covering CELL; the tile grid is
	# only written later by the 0.25s projection. A per-tile loop there wets one
	# ~22px cell per 64px tile and reads as scattered smudges, not a slick.
	var cell: CellFluid = _fm.cell_fluid
	if cell != null and cell.active_sim():
		_cf = cell
		_build_cells()
	else:
		_build_tiles()


func _build_tiles() -> void:
	var center: Vector2 = global_position
	var center_tile: Vector2i = GridManager.world_to_map(center)
	# Sweep the bounding square, keep tiles whose CENTRE is within `radius` world
	# px of the actual cast point -- the same disc rule SurfaceManager uses, so
	# the wet area matches the targeting ring the player saw. At radius 192 and
	# TILE_SIZE 64 that is tile_radius 3 and ~29 tiles.
	var tile_radius: int = int(ceil(radius / float(GridManager.TILE_SIZE)))
	var scratch: Array = []
	for dx in range(-tile_radius, tile_radius + 1):
		for dy in range(-tile_radius, tile_radius + 1):
			var tile: Vector2i = center_tile + Vector2i(dx, dy)
			# register_fluid ignores walls entirely (unlike Game._spawn_fluids),
			# so this has to filter them or oil pools inside masonry.
			if bool(GridManager.walls.get(tile, false)):
				continue
			var d: float = center.distance_to(GridManager.map_to_world(tile))
			if d > radius:
				continue
			scratch.append([d, tile.x, tile.y])

	scratch.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	for entry in scratch:
		_dists.append(float(entry[0]))
		_tiles.append(Vector2i(int(entry[1]), int(entry[2])))
	_budget = float(_tiles.size()) * TILE_TARGET_DEPTH * BUDGET_SLACK


func _build_cells() -> void:
	var graph: CellGraph = _cf.graph
	if graph == null:
		return
	var center: Vector2 = global_position
	var scratch: Array = []
	# ONE O(cell_count) pass, here and never again. The big structured exports
	# carry ~24,500 cells, so this is the single expensive moment of the spell.
	for cid in graph.cell_count:
		var c: Vector2 = graph.centroid(cid)
		var d: float = c.distance_to(center)
		if d > radius:
			continue
		# Wall-band cells strand sealed fluid and project a phantom wet wall tile
		# -- the same guard CellFluid.pour applies.
		if bool(GridManager.walls.get(GridManager.world_to_map(c), false)):
			continue
		# A sea-drain sink (P3-A) reads dry forever, so it would take the full
		# deficit every tick and burn the budget the slick on land needs. What
		# a well gushes onto open water is gone anyway; flow carries the land
		# part's overspill into the sea.
		if _cf.is_sink(cid):
			continue
		scratch.append([d, cid, c.x, c.y])

	scratch.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	for entry in scratch:
		_dists.append(float(entry[0]))
		_cells.append(int(entry[1]))
		_points.append(Vector2(float(entry[2]), float(entry[3])))
	_budget = float(_cells.size()) * CELL_TARGET_DEPTH * BUDGET_SLACK


func _emit() -> void:
	if _fm == null or _deposited >= _budget:
		return

	var grow: float = maxf(duration * GROW_FRACTION, 0.001)
	var front: float = radius * clampf(_age / grow, 0.0, 1.0)
	var count: int = _dists.size()

	for i in count:
		# The list is distance-sorted, so the first entry past the front ends it.
		if _dists[i] > front:
			return
		if _deposited >= _budget:
			return
		if _cf != null:
			var have: float = _cf.amount_at(_cells[i])
			var deficit: float = CELL_TARGET_DEPTH - have
			if deficit <= 0.0:
				continue
			# wipe=true matches register_fluid's default: the well displaces
			# standing water rather than politely refusing to fill over it.
			_cf.deposit(_points[i], fluid_type, deficit, true)
			_deposited += deficit
		else:
			var have_t: float = _fm.get_fluid_amount(_tiles[i], fluid_type)
			var deficit_t: float = TILE_TARGET_DEPTH - have_t
			if deficit_t <= 0.0:
				continue
			_fm.register_fluid(_tiles[i], fluid_type, deficit_t, false)
			_deposited += deficit_t


func _spawn_visual() -> void:
	if visual_scene_path.is_empty() or not ResourceLoader.exists(visual_scene_path):
		return
	var packed: PackedScene = load(visual_scene_path) as PackedScene
	if packed == null:
		return
	var inst: Node = packed.instantiate()
	if not (inst is Node2D):
		push_warning("FluidWell: visual '%s' must have a Node2D root." % visual_scene_path)
		inst.queue_free()
		return
	_visual = inst as Node2D
	# Parented as a CHILD so the visual's lifetime is the well's lifetime exactly.
	# Routing it through visuals.impact_effect instead would cap it at 1.5 s,
	# because `visual_duration` is inert in Ability.from_dict and
	# _schedule_effect_cleanup hard-frees on that timer -- it cannot reach 6s.
	add_child(_visual)
	_visual.position = Vector2.ZERO
	# ABSOLUTE, not relative. The fluid tiles this well is filling are children of
	# FluidManager at the default z_index 0, so a visual left at 0 would order
	# against them by tree position -- and the pool drew straight over the jet.
	# The wellhead has to sit above the slick it is producing.
	_visual.z_as_relative = false
	_visual.z_index = 1
	if _visual.has_method("play_well"):
		_visual.call("play_well", radius, duration)
	elif _visual.has_method("play"):
		var base: float = 192.0
		if "vfx_base_radius" in _visual:
			base = float(_visual.vfx_base_radius)
		_visual.call("play", radius / maxf(base, 1.0))
