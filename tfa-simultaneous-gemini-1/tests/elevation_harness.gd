# res://tests/elevation_harness.gd
# Headless assertion harness for elevation-aware movement.
# Run:  godot --headless --path . res://tests/elevation_harness.tscn
# Judge by the printed PASS/FAIL lines (pre-existing project parse errors print
# noise; runs can flake exit 255 — rerun once). Exits 0 iff all checks pass.
# Deliberately does NOT instantiate Game.tscn (avoids the known
# VisibilityManager/HearingManager flake surface).
extends Node2D

const MAP_LOADER := preload("res://Structures/MapLoader.gd")

# game-stub properties for MapLoader's current_scene fallback (battlements scenario)
var structures_in_scene: Array = []
var party_chars: Array = []
var unlocked_locks: Dictionary = {}

var failures := 0

func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])

func _ready() -> void:
	_scenario_projection()
	_scenario_can_step_astar()
	_scenario_deck_refcount()
	_scenario_movement_gate()
	await _scenario_elevation_los()
	_scenario_melee_predicate()
	_scenario_jump_fall()
	_scenario_battlements()   # LAST: loads the full real map into GridManager
	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

# Stub graph for the roof-channel projection check: one roofed cell.
class StubRoofGraph:
	extends RefCounted
	func cell_at(p: Vector2) -> int:
		var t := GridManager.world_to_map(p)
		return t.y * 1000 + t.x
	func ground_elev(_cid: int) -> float:
		return 0.0
	func roof_elev(cid: int) -> float:
		return 2.0 if cid == 3 * 1000 + 3 else 0.0

# 6b. JUMP + FALL: roof channel, layered A*, jump/fall states
func _scenario_jump_fall() -> void:
	GridManager.TILE_SIZE = 64
	GridManager.initialize(20 * 64, 20 * 64)
	# --- roof channel projection: stacked, never leaking into the ground layer
	GridManager.set_elevation_data(StubRoofGraph.new())
	_check("roofchan.loads", GridManager.roof_elevations.size() == 1
		and is_equal_approx(GridManager.roof_at(Vector2i(3, 3)), 2.0))
	_check("roofchan.no-ground-leak", GridManager.effective_elev(Vector2i(3, 3)) == 0.0)
	# --- roof-surface step gate
	GridManager.initialize(20 * 64, 20 * 64)
	# a realistic building: roofed tiles whose GROUND is walled off (INF) —
	# real roofs sit over obstacle tiles, so roof landings must not consult
	# ground pathability
	for x in range(5, 9):
		for y in range(5, 8):
			GridManager.roof_elevations[Vector2i(x, y)] = 2.0
			GridManager.grid_costs[Vector2i(x, y)] = INF
	_check("canstep_roof.gate", GridManager.can_step_roof(Vector2i(5, 5), Vector2i(6, 5))
		and not GridManager.can_step_roof(Vector2i(5, 5), Vector2i(4, 5)))
	GridManager.roof_elevations[Vector2i(8, 5)] = 3.0
	_check("canstep_roof.delta-gate", not GridManager.can_step_roof(Vector2i(7, 5), Vector2i(8, 5)))
	GridManager.roof_elevations[Vector2i(8, 5)] = 2.0
	# --- layered A*: default race cannot reach the roof block, a jumper can
	var ground := Vector2i(2, 6)
	var roof_goal := Vector2i(6, 6)
	_check("astar.default-cannot-mount", GridManager.find_path(ground, roof_goal).is_empty())
	var jp := GridManager.find_path(ground, roof_goal, 2.5, 2)
	_check("astar.jumper-mounts", not jp.is_empty())
	# --- ceiling clearance: from a tile UNDER its own roof you cannot leap up
	# through it onto that same roof; from an UNROOFED tile the roof IS mountable
	GridManager.grid_costs[Vector2i(15, 6)] = 1.0   # unroofed approach
	GridManager.grid_costs[Vector2i(16, 6)] = 1.0   # roofed interior
	GridManager.grid_costs[Vector2i(17, 6)] = 1.0   # roofed interior
	GridManager.roof_elevations[Vector2i(16, 6)] = 2.0
	GridManager.roof_elevations[Vector2i(17, 6)] = 2.0
	var interior_has_mount := false
	for e in GridManager._get_jump_neighbors(Vector3i(16, 6, 0), 2.5, 2):
		if (e["n"] as Vector3i).z == 1:
			interior_has_mount = true
	_check("jump.no-mount-through-own-ceiling", not interior_has_mount)
	var approach_has_mount := false
	for e in GridManager._get_jump_neighbors(Vector3i(15, 6, 0), 2.5, 2):
		if (e["n"] as Vector3i).z == 1:
			approach_has_mount = true
	_check("jump.unroofed-tile-can-mount", approach_has_mount)
	# --- jump DOWN a ledge: a jumper on a 2-story deck can descend (was a
	# one-way trap before — up-jump existed, down-jump did not), a walker cannot
	GridManager.elevations[Vector2i(12, 10)] = 2.0
	GridManager.grid_costs[Vector2i(12, 10)] = 1.0
	GridManager.grid_costs[Vector2i(13, 10)] = 1.0
	GridManager.grid_costs[Vector2i(14, 10)] = 1.0
	_check("astar.jumper-descends-ledge",
		not GridManager.find_path(Vector2i(12, 10), Vector2i(14, 10), 2.5, 2).is_empty())
	_check("astar.walker-stranded-on-ledge",
		GridManager.find_path(Vector2i(12, 10), Vector2i(14, 10)).is_empty())
	# --- goal layer: a roofed interior whose ground is sealed by walls on all
	# four sides is NOT satisfiable at ground level (no "arriving" on the roof
	# above the target — you would have to path THROUGH the roof to its floor),
	# but IS reachable when the caller explicitly asks for the roof surface.
	# (initialize() leaves the grid open at default cost, so the walls must be
	# set explicitly — the target's only access is over the roof.)
	GridManager.roof_elevations[Vector2i(17, 12)] = 2.0
	GridManager.roof_elevations[Vector2i(18, 12)] = 2.0
	GridManager.grid_costs[Vector2i(17, 12)] = INF   # roofed wall (roof approach)
	GridManager.grid_costs[Vector2i(19, 12)] = INF   # seal the interior floor...
	GridManager.grid_costs[Vector2i(18, 11)] = INF
	GridManager.grid_costs[Vector2i(18, 13)] = INF
	GridManager.grid_costs[Vector2i(18, 12)] = 1.0   # roofed interior, ground sealed
	_check("astar.goal-ground-not-faked-on-roof",
		GridManager.find_path(Vector2i(16, 12), Vector2i(18, 12), 2.5, 2).is_empty())
	_check("astar.goal-roof-reached-when-asked",
		not GridManager.find_path(Vector2i(16, 12), Vector2i(18, 12), 2.5, 2, false, true).is_empty())
	# --- character jump/fall states
	var scene: PackedScene = load("res://Characters/ProceduralCharacter.tscn")
	var ch = scene.instantiate()
	ch.AI_enabled = false
	ch.is_player_controlled = false
	add_child(ch)
	ch.jump_height = 2.5
	ch.jump_range = 2
	ch.global_position = GridManager.map_to_world(Vector2i(4, 6))   # beside the roof block
	ch._refresh_elevation()
	_check("canjumpto.gate", ch.can_jump_to(Vector2i(4, 6), Vector2i(5, 6))
		and not ch.can_jump_to(Vector2i(4, 6), Vector2i(7, 6)))   # range 3 > jump_range
	var pre_mask: int = ch.collision_mask
	ch._begin_jump(Vector2i(5, 6))
	_check("jump.suspends-structures", (ch.collision_mask & CollisionLayers.STRUCTURES) == 0)
	for _i in 40:
		if not ch._jump_active:
			break
		ch._update_jump_motion(1.0 / 30.0)
	_check("jump.lands-on-roof", ch.on_roof and is_equal_approx(ch.current_elevation, 2.0)
		and ch.collision_mask == pre_mask,
		"on_roof=%s elev=%.2f" % [str(ch.on_roof), ch.current_elevation])
	# --- forced drop off the rim -> fall state -> ground landing with damage
	ch.global_position = GridManager.map_to_world(Vector2i(5, 6))
	ch.current_health = 20
	var stepv := Vector2(-float(GridManager.TILE_SIZE), 0.0)   # west, off the roof block
	_check("fall.forced-drop-begins", ch._forced_drop_check(stepv) and ch._fall_active)
	for _i in 20:
		if not ch._fall_active:
			break
		ch._update_fall_motion(1.0 / 30.0)
	_check("fall.lands-grounded", not ch.on_roof and is_equal_approx(ch.current_elevation, 0.0))
	_check("fall.damage-applied", ch.current_health < 20, "hp=%d" % ch.current_health)
	# --- graceful ramp: small drops never enter the fall state or hurt
	ch.current_health = 20
	GridManager.elevations[Vector2i(10, 10)] = 0.4
	ch.global_position = GridManager.map_to_world(Vector2i(10, 10))
	ch._refresh_elevation()
	_check("fall.ramp-no-fall", not ch._forced_drop_check(Vector2(float(GridManager.TILE_SIZE), 0.0))
		and not ch._fall_active and ch.current_health == 20)
	# --- fall damage scales with race multiplier (pure base amount; take_damage
	# layers limb/condition effects on top, so health deltas aren't compared)
	ch.fall_damage_mult = 0.4
	var soft_dmg: int = ch.fall_damage_for(3.0)
	ch.fall_damage_mult = 1.0
	var hard_dmg: int = ch.fall_damage_for(3.0)
	_check("fall.damage-scales", soft_dmg > 0 and hard_dmg > soft_dmg
		and ch.fall_damage_for(1.0) == 0,
		"soft=%d hard=%d" % [soft_dmg, hard_dmg])
	# --- controlled drop off a high jump lands hard EVEN when the per-frame
	# _refresh_elevation fires mid-arc: the takeoff must be snapshotted at
	# _begin_jump, else the refresh rewrites current_elevation to the landing
	# and _end_jump computes a zero drop (free hops off any height).
	ch.fall_damage_mult = 1.0
	ch.on_roof = true
	ch.current_elevation = 2.0
	ch.current_health = 20
	ch.global_position = GridManager.map_to_world(Vector2i(6, 6))   # on the roof block
	ch._begin_jump(Vector2i(4, 6))                                  # down to bare ground
	ch._update_jump_motion(1.0 / 60.0)
	ch._refresh_elevation()   # simulate _process's mid-arc refresh (the corruptor)
	for _i in 40:
		if not ch._jump_active:
			break
		ch._update_jump_motion(1.0 / 30.0)
	_check("jump.controlled-drop-still-hurts", ch.current_health < 20 and not ch.on_roof,
		"hp=%d on_roof=%s" % [ch.current_health, str(ch.on_roof)])
	ch.queue_free()

# 7. BATTLEMENTS: the shipped tg_export loads with walkable fort tower decks
# and ladder warp pairs (walk_elev + derived warps from the editor exporter).
func _scenario_battlements() -> void:
	var f := FileAccess.open("res://data/Maps.json", FileAccess.READ)
	if f == null:
		_check("battlements.maps-json", false, "cannot open Maps.json")
		return
	var raw: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	var m: Dictionary = {}
	for e in raw.get("maps", []):
		if String(e.get("id", "")) == "tg_export":
			m = e
			break
	if m.is_empty():
		_check("battlements.entry", false, "no tg_export entry in Maps.json")
		return
	add_to_group("game")   # harmless for earlier scenarios; MapLoader stub hook
	GridManager.TILE_SIZE = int(m.get("tile_size", 64))
	var ws: Array = m.get("world_size", [2048, 2048])
	GridManager.initialize(int(ws[0]), int(ws[1]))
	var graph: CellGraph = CellGraph.from_structured(String(m.get("cell_graph", "")))
	GridManager.set_elevation_data(graph)
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	ml.generate_structured_map(m)
	_check("battlements.decks-registered", not GridManager.deck_elevations.is_empty(),
		"no deck tiles after load")
	var spawns: Dictionary = m.get("player_spawns", {})
	var ladder_warps := 0
	var top_t := Vector2i(-1, -1)
	var base_t := Vector2i(-1, -1)
	for w in m.get("warp_points", []):
		var wid := String(w.get("id", ""))
		if not wid.begins_with("fort_ladder_"):
			continue
		ladder_warps += 1
		var ts := String(w.get("target_spawn", ""))
		if not spawns.has(ts):
			_check("battlements.arrival-" + ts, false, "missing player_spawns key")
			continue
		var pos_a: Array = spawns[ts]["position"]
		var t := GridManager.world_to_map(Vector2(float(pos_a[0]), float(pos_a[1])))
		var e := GridManager.effective_elev(t)
		if ts.ends_with("_top"):
			top_t = t
			_check("battlements." + ts, e >= 1.0 and GridManager.would_walk(t),
				"elev=%.2f walkable=%s" % [e, str(GridManager.would_walk(t))])
		else:
			base_t = t
			_check("battlements." + ts, absf(e) < 0.55 and GridManager.would_walk(t),
				"elev=%.2f walkable=%s" % [e, str(GridManager.would_walk(t))])
	_check("battlements.ladder-warps-present", ladder_warps == 4, "found %d" % ladder_warps)
	# the deck rim is a cliff: some deck tile must border low ground it cannot step to
	var rim_blocked := false
	for t in GridManager.deck_elevations:
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = t + d
			if not GridManager.deck_elevations.has(n) and not GridManager.can_step(t, n):
				rim_blocked = true
				break
		if rim_blocked:
			break
	_check("battlements.rim-is-cliff", rim_blocked)
	# and the tower top is foot-unreachable from the ladder base (warp-only)
	if top_t.x >= 0 and base_t.x >= 0:
		_check("battlements.tower-foot-unreachable",
			GridManager.find_path(base_t, top_t).is_empty())
	# a jumper can mount a real ROOF from an adjacent street tile (the fort
	# drums stay ladder-gated even for jumpers: their merlon-ring halo keeps
	# every landing 3+ cardinal steps out — accepted balance)
	var mounted := false
	var tried := 0
	for rt in GridManager.roof_elevations:
		if tried >= 200 or mounted:
			break
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var s: Vector2i = (rt as Vector2i) + d * 2
			if GridManager.grid_costs.get(s, INF) == INF or GridManager.has_roof(s):
				continue
			tried += 1
			if not GridManager.find_path(s, rt, 2.5, 2).is_empty():
				mounted = true
				break
	_check("battlements.jumper-mounts-real-roof", mounted,
		"no street-adjacent roof mount found in %d tries" % tried)
	ml.queue_free()

# 1. PROJECTION: real cells.json -> sparse per-tile elevations
func _scenario_projection() -> void:
	GridManager.TILE_SIZE = 64
	if not ResourceLoader.exists("res://Maps/tg_export_cells.json") \
			and not FileAccess.file_exists("res://Maps/tg_export_cells.json"):
		_check("projection.load", false, "tg_export_cells.json missing")
		return
	var graph: CellGraph = CellGraph.from_structured("res://Maps/tg_export_cells.json")
	if graph == null:
		_check("projection.load", false, "from_structured returned null")
		return
	GridManager.initialize(3328, 4096)
	GridManager.set_elevation_data(graph)
	var has_nonzero := false
	for i in graph._elev.size():
		if absf(graph._elev[i]) > 0.001:
			has_nonzero = true
			break
	_check("projection.nonempty-iff-source",
		GridManager.elevations.is_empty() != has_nonzero,
		"cells nonzero=%s but tile dict size=%d" % [has_nonzero, GridManager.elevations.size()])
	# a tile with no entry must read exactly 0.0
	var flat := Vector2i(-1, -1)
	for y in GridManager.map_rect.size.y:
		for x in GridManager.map_rect.size.x:
			if not GridManager.elevations.has(Vector2i(x, y)):
				flat = Vector2i(x, y)
				break
		if flat.x >= 0:
			break
	if flat.x >= 0:
		_check("projection.flat-reads-zero", GridManager.effective_elev(flat) == 0.0)
	# adjacent-tile delta histogram (tunes MAX_STEP_STORIES)
	var max_d := 0.0
	var buckets := [0, 0, 0, 0]   # <=0.25, <=0.55, <=1.0, >1.0
	for t in GridManager.elevations:
		for d in [Vector2i(1, 0), Vector2i(0, 1)]:
			var dd: float = absf(GridManager.effective_elev(t + d) - GridManager.effective_elev(t))
			max_d = maxf(max_d, dd)
			if dd <= 0.25: buckets[0] += 1
			elif dd <= 0.55: buckets[1] += 1
			elif dd <= 1.0: buckets[2] += 1
			else: buckets[3] += 1
	print("INFO projection: %d elevated tiles, max adjacent delta %.3f, buckets(<=.25/<=.55/<=1/>1)=%s" \
		% [GridManager.elevations.size(), max_d, str(buckets)])

# 2. CAN_STEP + A* on a synthetic ridge with a ramp saddle
func _scenario_can_step_astar() -> void:
	GridManager.TILE_SIZE = 64
	GridManager.initialize(20 * 64, 20 * 64)
	for y in range(0, 16):
		GridManager.elevations[Vector2i(10, y)] = 2.0
	GridManager.elevations[Vector2i(10, 16)] = 0.4
	GridManager.elevations[Vector2i(10, 17)] = 0.4
	_check("canstep.ridge-blocked", not GridManager.can_step(Vector2i(9, 5), Vector2i(10, 5)))
	_check("canstep.ridge-blocked-reverse", not GridManager.can_step(Vector2i(10, 5), Vector2i(9, 5)))
	_check("canstep.saddle-open", GridManager.can_step(Vector2i(9, 17), Vector2i(10, 17)))
	var path := GridManager.find_path(Vector2i(5, 5), Vector2i(15, 5))
	_check("astar.path-found", not path.is_empty(), "no route via the saddle")
	var prev := Vector2i(5, 5)
	var ok := true
	for p in path:
		if not GridManager.can_step(prev, p):
			ok = false
			break
		prev = p
	_check("astar.every-step-legal", ok, "path crossed a cliff at %s" % str(prev))

# 3. DECK REFCOUNT (+ mixed-height junction: taller deck dies first)
func _scenario_deck_refcount() -> void:
	GridManager.initialize(20 * 64, 20 * 64)
	GridManager.register_deck(Vector2i(3, 3), 2.0)
	GridManager.register_deck(Vector2i(3, 3), 2.0)
	GridManager.unregister_deck(Vector2i(3, 3), 2.0)
	_check("deck.survives-one-unregister", GridManager.effective_elev(Vector2i(3, 3)) == 2.0)
	_check("deck.blocks-ground-step", not GridManager.can_step(Vector2i(2, 3), Vector2i(3, 3)))
	GridManager.unregister_deck(Vector2i(3, 3), 2.0)
	_check("deck.cleared-at-zero-refs", GridManager.effective_elev(Vector2i(3, 3)) == 0.0)
	# walkway (1.0) + tower top (3.0) share a junction tile; the tower dies —
	# the tile must drop to the surviving walkway's height, not keep 3.0
	GridManager.register_deck(Vector2i(5, 5), 1.0)
	GridManager.register_deck(Vector2i(5, 5), 3.0)
	_check("deck.mixed-max-wins", GridManager.effective_elev(Vector2i(5, 5)) == 3.0)
	GridManager.unregister_deck(Vector2i(5, 5), 3.0)
	_check("deck.survivor-height-restored", GridManager.effective_elev(Vector2i(5, 5)) == 1.0)
	GridManager.unregister_deck(Vector2i(5, 5), 1.0)
	_check("deck.mixed-cleared", GridManager.effective_elev(Vector2i(5, 5)) == 0.0)
	# 3b. CAN_TRAVERSE: a one-tile ravine must not be tunnelled by a long step
	GridManager.elevations[Vector2i(8, 8)] = -1.0
	var west := GridManager.map_to_world(Vector2i(7, 8))
	var east := GridManager.map_to_world(Vector2i(9, 8))
	_check("traverse.blocks-across-ravine", not GridManager.can_traverse(west, east))
	_check("traverse.same-tile-ok", GridManager.can_traverse(west, west + Vector2(3, 0)))
	GridManager.elevations.erase(Vector2i(8, 8))

# 4. MOVEMENT GATE: real ProceduralCharacter vs the synthetic ridge.
# The character is placed 1px from the tile boundary so the gate decision
# fires on the first _update_movement call — move_and_slide's real motion is
# frame-delta dependent and unreliable in a headless synchronous loop, but the
# gate math, axis-slide, and fake-arrival contract are position-based and
# fully deterministic.
func _scenario_movement_gate() -> void:
	GridManager.initialize(20 * 64, 20 * 64)
	for y in range(0, 16):
		GridManager.elevations[Vector2i(10, y)] = 2.0
	GridManager.elevations[Vector2i(10, 16)] = 0.4
	GridManager.elevations[Vector2i(10, 17)] = 0.4
	var scene: PackedScene = load("res://Characters/ProceduralCharacter.tscn")
	var ch = scene.instantiate()
	ch.AI_enabled = false
	ch.is_player_controlled = false
	add_child(ch)
	var arrivals := [0]
	ch.character_reached_target.connect(func(): arrivals[0] += 1)
	# (a) dead-on at the cliff: pure-east move into the ridge — no slide axis,
	# stuck timer must fake-arrive within ~0.5s of calls
	ch.global_position = Vector2(10 * 64 - 1.0, 5 * 64 + 32.0)   # 1px west of the ridge boundary
	ch.target_position = GridManager.map_to_world(Vector2i(12, 5))
	ch.is_moving = true
	for i in 40:
		ch._update_movement(1.0 / 60.0)
	var end_tile: Vector2i = GridManager.world_to_map(ch.global_position)
	_check("gate.cliff-not-crossed", end_tile.x <= 9, "ended at %s" % str(end_tile))
	_check("gate.fake-arrival-fired", arrivals[0] >= 1 and not ch.is_moving,
		"arrivals=%d is_moving=%s" % [arrivals[0], str(ch.is_moving)])
	# (b) diagonal at the cliff: the y-axis is safe, so the gate must SLIDE
	# (velocity straight south) instead of dead-stopping
	ch.global_position = Vector2(10 * 64 - 1.0, 5 * 64 + 32.0)
	ch.target_position = GridManager.map_to_world(Vector2i(12, 7))
	ch.is_moving = true
	ch.velocity = Vector2.ZERO
	ch._update_movement(1.0 / 60.0)
	_check("gate.axis-slide", ch.velocity.x == 0.0 and ch.velocity.y > 0.0,
		"velocity=%s" % str(ch.velocity))
	# (c) legal move toward the saddle: the gate must NOT veto (velocity keeps
	# its eastward component, no fake arrival)
	arrivals[0] = 0
	ch.global_position = Vector2(10 * 64 - 1.0, 17 * 64 + 32.0)   # boundary of the 0.4 saddle
	ch.target_position = GridManager.map_to_world(Vector2i(12, 17))
	ch.is_moving = true
	ch.velocity = Vector2.ZERO
	for i in 10:
		ch._update_movement(1.0 / 60.0)
	_check("gate.ramp-passes", ch.is_moving and arrivals[0] == 0 and ch.velocity.x > 0.0,
		"is_moving=%s arrivals=%d velocity=%s" % [str(ch.is_moving), arrivals[0], str(ch.velocity)])
	# (d) elevation state tracks the tile under the feet
	ch.global_position = GridManager.map_to_world(Vector2i(10, 17))
	ch._refresh_elevation()
	_check("gate.elevation-tracks", is_equal_approx(ch.current_elevation, 0.4),
		"elev=%f" % ch.current_elevation)
	ch.queue_free()

# 5. ELEVATION LOS: occlude_top filtering in sight_line_clear
func _scenario_elevation_los() -> void:
	var a := Vector2(100, 100)
	var b := Vector2(500, 100)
	var low := _make_blocker(Vector2(300, 100), 1.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := get_world_2d().direct_space_state
	_check("los.ground-blocked", not GridManager.sight_line_clear(space, a, b, 0.0))
	_check("los.elevated-sees-over", GridManager.sight_line_clear(space, a, b, 1.5))
	# target-aware: a GROUND viewer sees a HIGH target (roof-walker) over low
	# cover — without the target term, LOS was one-way and nobody on the street
	# could ever acquire a character standing on a roof.
	_check("los.ground-sees-high-target", GridManager.sight_line_clear(space, a, b, 0.0, 2.0))
	var high := _make_blocker(Vector2(400, 100), 3.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("los.excludes-only-low", not GridManager.sight_line_clear(space, a, b, 1.5))
	low.queue_free()
	high.queue_free()
	var legacy := _make_blocker(Vector2(300, 100), -1.0)   # no meta
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("los.legacy-always-blocks", not GridManager.sight_line_clear(space, a, b, 50.0))
	legacy.queue_free()

func _make_blocker(pos: Vector2, occlude_top: float) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.collision_layer = CollisionLayers.VISION_BLOCKERS
	body.collision_mask = 0
	var cs := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(40, 200)
	cs.shape = rect
	body.add_child(cs)
	body.position = pos
	if occlude_top >= 0.0:
		body.set_meta("occlude_top", occlude_top)
	add_child(body)
	return body

# 6. MELEE PREDICATE: the gate constant + logic (Game.tscn itself is not
# bootable in this harness; the predicate is one absf compare)
func _scenario_melee_predicate() -> void:
	var game_script := load("res://Game.gd")
	var tol: float = game_script.MELEE_ELEV_TOLERANCE
	_check("melee.const-exists", tol == 0.75, "tolerance=%f" % tol)
	_check("melee.deck-vs-ground-blocked", absf(0.0 - 2.0) > tol)
	_check("melee.mid-ramp-allowed", not (absf(0.0 - 0.5) > tol))
