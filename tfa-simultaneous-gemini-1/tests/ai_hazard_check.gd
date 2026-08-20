extends Node2D
# AI hazard-avoidance regression harness. Proves the dangerous-ground contract:
# (1) burning cells / harmful fluids project into GridManager.hazard_costs
#     (core = damaging tile, halo = bias only) and A* detours around cores
#     when a detour exists yet still crosses when fire is the only way,
# (2) wander/flee candidates and AoE self-blast checks respect hazards
#     (a caster never drops a circle AoE on its own head — the melee
#     fireball suicide),
# (3) behavioral: an investigator scans a noise INSIDE a fire from a safe
#     standoff without ever entering it, and a character standing in fire
#     escapes to safe ground instead of burning to death mid-goal.
# Synthetic 32x32 square map: CellGraph.from_square_tiles makes cell == tile,
# so force-lit cells land on exact, assertable tiles (render_map.gd idiom).
# Run headless:  godot --headless --path . res://tests/ai_hazard_check.tscn
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

var characters_in_scene: Array = []
var items_in_scene: Array = []
var structures_in_scene: Array = []
var surface_manager: SurfaceManager = null
var fluid_manager: FluidManager = null
var fog_manager: FogManager = null
# selection/UI state the character scripts read off the game root
var context_menu_open := false
var primary_selected = null

var _fails := 0
var _checks := 0
var _cf: CellFire = null
var _graph: CellGraph = null


func _report(name: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("%s %s: %s" % ["PASS" if ok else "FAIL", name, detail])


func _process(delta: float) -> void:
	# Stand in for Game._process: the hazard map only rebuilds inside
	# update_surfaces, and cell fire only damages/spreads from its tick.
	if surface_manager != null:
		surface_manager.update_surfaces(delta, characters_in_scene, self)


func _burn(t: Vector2i) -> void:
	var cid := _graph.cell_at(GridManager.map_to_world(t))
	_cf.burning[cid] = {"t": 600.0, "t0": 600.0, "char": 0.0, "seed": 0.5, "vfx": null}
	_cf.burn_rev += 1


func _clear_fire() -> void:
	_cf.burning.clear()
	_cf.burn_rev += 1
	_sync_hazards()


# Force a hazard-map rebuild NOW: the rebuild has a 0.1s min-spacing floor, so
# a single update_surfaces call right after a burn/clear can be deferred.
func _sync_hazards() -> void:
	surface_manager.update_surfaces(0.2, [], self)
	surface_manager.update_surfaces(0.2, [], self)


func _spawn(pos: Vector2, ai_on: bool) -> ProceduralCharacter:
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	c.is_player_controlled = not ai_on   # unit-test actors: FSM fully out of the way
	c.AI_enabled = ai_on
	add_child(c)
	# the member `game` is @onready get_node("/root/Game") — the real scene
	# root's name; here the root is this harness, so rebind it (the area sweep
	# reads game.characters_in_scene through it)
	c.game = self
	c.global_position = pos
	characters_in_scene.append(c)
	return c


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)   # 32x32 tiles, all cost 1.0
	surface_manager = SurfaceManager.new()
	add_child(surface_manager)
	fluid_manager = FluidManager.new()
	add_child(fluid_manager)
	_graph = CellGraph.from_square_tiles()
	surface_manager.setup_cell_graph(_graph)
	_cf = surface_manager.cell_fire
	_report("sim.active", _cf != null and _cf.active(), "")
	await get_tree().process_frame

	# --- 1. hazard map projection -------------------------------------------
	for x in range(8, 13):
		_burn(Vector2i(x, 10))
	_sync_hazards()
	_report("hazard.core", GridManager.is_hazard_tile(Vector2i(10, 10)),
		"cost=%s" % str(GridManager.hazard_costs.get(Vector2i(10, 10))))
	_report("hazard.step-cost", GridManager.step_cost(Vector2i(10, 10)) >= 50.0,
		"step_cost=%.1f" % GridManager.step_cost(Vector2i(10, 10)))
	var halo_cost: float = float(GridManager.hazard_costs.get(Vector2i(10, 9), 0.0))
	_report("hazard.halo-biases-not-blocks",
		halo_cost > 0.0 and not GridManager.is_hazard_tile(Vector2i(10, 9)),
		"halo cost=%.1f" % halo_cost)

	# --- 2. A* detours around fire, crosses only when it must ----------------
	var path: Array[Vector2i] = GridManager.find_path(Vector2i(10, 6), Vector2i(10, 14))
	var burnt_steps := 0
	for t in path:
		if GridManager.is_hazard_tile(t):
			burnt_steps += 1
	_report("astar.detours", not path.is_empty() and burnt_steps == 0,
		"len=%d through-fire=%d" % [path.size(), burnt_steps])
	for x in range(0, 32):
		_burn(Vector2i(x, 10))
	_sync_hazards()
	path = GridManager.find_path(Vector2i(10, 6), Vector2i(10, 14))
	_report("astar.crosses-when-only-route", not path.is_empty(),
		"len=%d" % path.size())

	# --- 2b. the AI path FOLLOWER refuses legs into fire even when A* crosses
	# (the planner keeps the route for players; the follower waits at the edge
	# instead of dipping in and yo-yoing with the escape override) ------------
	var walker := _spawn(GridManager.map_to_world(Vector2i(10, 6)), true)
	await get_tree().physics_frame
	walker.get_node("AI").navigate_to(GridManager.map_to_world(Vector2i(10, 14)))
	var walker_burned := false
	for _i in 240:
		await get_tree().physics_frame
		if GridManager.is_hazard_tile(GridManager.world_to_map(walker.global_position)):
			walker_burned = true
	var walker_tile := GridManager.world_to_map(walker.global_position)
	_report("advance.refuses-hazard-leg", not walker_burned and walker_tile.y < 10,
		"tile=%s burned=%s" % [str(walker_tile), str(walker_burned)])
	walker.hold_position = true   # park it clear of the later behavioral phases
	walker.global_position = GridManager.map_to_world(Vector2i(28, 4))
	_clear_fire()
	_report("hazard.clears", GridManager.hazard_costs.is_empty(),
		"left=%d" % GridManager.hazard_costs.size())

	# --- 3. harmful fluids are hazards, nuisances are not --------------------
	fluid_manager.register_fluid(Vector2i(20, 20), "acid", 0.5)
	fluid_manager.register_fluid(Vector2i(22, 20), "water", 0.5)
	fluid_manager.register_fluid(Vector2i(24, 20), "oil", 0.5)
	surface_manager._rebuild_hazard_map(self)
	_report("fluid.acid-hazard", GridManager.is_hazard_tile(Vector2i(20, 20)), "")
	_report("fluid.water-safe", not GridManager.is_hazard_tile(Vector2i(22, 20)), "")
	_report("fluid.oil-nuisance-not-hazard",
		not GridManager.is_hazard_tile(Vector2i(24, 20)), "")

	# --- 3b. damaging clouds are hazards too (the fifth ground system) -------
	fog_manager = FogManager.new()
	add_child(fog_manager)
	fog_manager.create_cloud(Color(0.2, 0.5, 0.1, 0.4), Vector2(128, 128), 15.0,
		"poisoned", 1, -2.0, 2.0, 0.99, 4.0, Vector2(0.02, 0.01),
		GridManager.map_to_world(Vector2i(26, 26)))
	surface_manager._rebuild_hazard_map(self)
	_report("cloud.poison-is-hazard", GridManager.is_hazard_tile(Vector2i(26, 26)), "")

	# --- 4. wander gate + AoE self-blast gate --------------------------------
	var caster := _spawn(GridManager.map_to_world(Vector2i(4, 24)), false)
	var dummy := _spawn(caster.global_position + Vector2(60, 0), false)
	await get_tree().physics_frame
	var cai = caster.get_node("AI")
	_report("wander.rejects-hazard", not cai.is_tile_walkable(Vector2i(20, 20)), "")

	var ice: Dictionary = AbilityDatabase.get_ability_data("ice_storm")
	_report("cast.self-blast-at-melee",
		cai._would_self_blast(ice, caster.global_position + Vector2(60, 0)),
		"radius=%.0f" % float(ice.get("targeting", {}).get("radius", 0.0)))
	_report("cast.safe-at-range",
		not cai._would_self_blast(ice, caster.global_position + Vector2(300, 0)), "")
	_report("cast.single-target-unaffected",
		not cai._would_self_blast({"targeting": {"shape": "none", "radius": 0.0}},
			caster.global_position + Vector2(60, 0)), "")
	# melee attacks are authored as small circles WITHOUT the aoe trait — the
	# gate must never take an animal's bite away
	var bash: Dictionary = AbilityDatabase.get_ability_data("shield_bash")
	_report("cast.melee-circle-not-gated",
		not cai._would_self_blast(bash, caster.global_position + Vector2(45, 0)),
		"shield_bash r40 at 45px")

	caster.inventory.add_ability_by_id("ice_storm")
	caster.npc_unlimited_resources = true   # bare spawn has no school tiers
	cai.current_target = dummy
	cai._cast_timer = 0.0
	_report("cast.gate-blocks-melee-aoe", not cai._try_cast_ability(0.016),
		"target at 60px, radius 100")
	# Anchored (projectile) casts re-aim after the windup: a target CHARGING
	# the caster must widen the gate by its closing distance; a fleeing one
	# must not. Ground-placed ice storm never widens (tested above at 60px).
	var fireb: Dictionary = AbilityDatabase.get_ability_data("fireball")
	dummy.global_position = caster.global_position + Vector2(250, 0)
	dummy.velocity = Vector2(-150, 0)   # charging the caster; fireball windup 1.0s
	_report("cast.blocks-charging-target",
		cai._would_self_blast(fireb, dummy.global_position, dummy),
		"250px, closing 150px/s, r80")
	dummy.velocity = Vector2(150, 0)    # fleeing
	_report("cast.allows-fleeing-target",
		not cai._would_self_blast(fireb, dummy.global_position, dummy), "")
	dummy.velocity = Vector2.ZERO

	dummy.global_position = caster.global_position + Vector2(300, 0)
	var bystander := _spawn(dummy.global_position + Vector2(50, 0), false)
	caster.target_rotation = (dummy.global_position - caster.global_position).angle() + PI / 2
	caster.rotation = caster.target_rotation   # LOS is FOV-gated: face the target
	await get_tree().physics_frame
	cai._cast_timer = 0.0
	_report("cast.fires-at-range", cai._try_cast_ability(0.016), "target at 300px")
	# position-only AI cast -> real area sweep: the bystander 50px from the
	# blast point splashes too (the old explicit-target path nuked only the
	# target), while the caster 300px out is untouched
	var dummy_hp0: int = dummy.current_health
	var by_hp0: int = bystander.current_health
	var caster_hp0: int = caster.current_health
	for _i in 150:   # ice_storm windup is 1.5s
		await get_tree().physics_frame
		if dummy.current_health < dummy_hp0:
			break
	_report("splash.hits-target", dummy.current_health < dummy_hp0,
		"hp %d -> %d" % [dummy_hp0, dummy.current_health])
	_report("splash.hits-bystander", bystander.current_health < by_hp0,
		"hp %d -> %d" % [by_hp0, bystander.current_health])
	_report("splash.spares-distant-caster", caster.current_health == caster_hp0,
		"hp %d -> %d" % [caster_hp0, caster.current_health])

	# --- 5. behavioral: investigate a noise inside a fire --------------------
	var blaze := Vector2i(10, 10)
	for t in [blaze, blaze + Vector2i(1, 0), blaze + Vector2i(-1, 0),
			blaze + Vector2i(0, 1), blaze + Vector2i(0, -1)]:
		_burn(t)
	_sync_hazards()
	var noise := GridManager.map_to_world(blaze)
	var scout := _spawn(GridManager.map_to_world(Vector2i(10, 16)), true)
	await get_tree().physics_frame
	var sai = scout.get_node("AI")
	sai.alertness_value = 84.0
	sai.last_heard_position = noise
	sai._change_state(sai.AIState.SEARCHING)
	var entered_fire := false
	for _i in 420:
		await get_tree().physics_frame
		if GridManager.is_hazard_tile(GridManager.world_to_map(scout.global_position)):
			entered_fire = true
	_report("search.never-enters-fire", not entered_fire, "")
	var d := scout.global_position.distance_to(noise)
	_report("search.standoff-scan", d > GridManager.TILE_SIZE * 0.9 and d <= 220.0,
		"final distance to noise %.0f px" % d)

	# --- 6. behavioral: reactive escape from standing in fire ----------------
	# but a player-held ally stands where they were told — even in fire
	var heldling := _spawn(noise, false)
	heldling.hold_position = true
	await get_tree().physics_frame
	_report("escape.hold-position-respected",
		not heldling.get_node("AI")._process_hazard_escape(0.016),
		"held ally keeps standing ground (and fighting)")
	characters_in_scene.erase(heldling)
	heldling.queue_free()

	var escapee := _spawn(noise, true)   # dead centre of the blaze
	await get_tree().physics_frame
	var out_frames := -1
	for i in 300:
		await get_tree().physics_frame
		if not GridManager.is_hazard_tile(GridManager.world_to_map(escapee.global_position)) \
				and not _cf.burning.has(_graph.cell_at(escapee.global_position)):
			out_frames = i
			break
	_report("escape.leaves-fire", out_frames >= 0, "frames=%d" % out_frames)
	_report("escape.survives", escapee.is_alive(),
		"hp=%d" % escapee.current_health)

	# --- 6b. trapped DEEPER than the cheap escape radius: the two-tier search
	# still finds the exit. A 5-step-only scan read this as "sea of flame" and
	# stood down — the burning-building death sentence for any room where safe
	# ground sits 6+ steps out (door tiles can't be destinations, so fire
	# spilling past a doorway pushes the nearest exit beyond 5 fast) ----------
	var deep_c := Vector2i(4, 8)
	for dx in range(-6, 7):
		for dy in range(-6, 7):
			if absi(dx) + absi(dy) <= 6:
				var bt := deep_c + Vector2i(dx, dy)
				if GridManager.map_rect.has_point(bt):
					_burn(bt)
	_sync_hazards()
	var deep_exit: Vector2i = escapee.get_node("AI")._find_escape_tile(deep_c)
	var deep_d: int = absi(deep_exit.x - deep_c.x) + absi(deep_exit.y - deep_c.y) \
		if deep_exit != Vector2i.MAX else -1
	_report("escape.widens-past-5-steps",
		deep_exit != Vector2i.MAX and deep_d >= 7,
		"exit=%s manhattan=%d" % [str(deep_exit), deep_d])
	_clear_fire()

	# --- 7. WAIT indicator: stop hand tracks hold_position ------------------
	caster.hold_position = true
	_report("wait.icon-shows", caster._wait_indicator != null
		and is_instance_valid(caster._wait_indicator) and caster._wait_indicator.visible, "")
	caster.hold_position = false
	_report("wait.icon-hides", caster._wait_indicator == null
		or not caster._wait_indicator.visible, "")

	# --- 8. combat steer waits at the fire's edge (the burning-building grind) --
	# A chaser whose only route to the enemy crosses a fire core must WAIT at
	# the edge, not lean on the straight line: _advance_path's hazard refusal
	# empties nav_path exactly like a sealed goal, and _combat_move used to read
	# both as "no route" and steer straight — re-arming is_moving every tick, so
	# the mover's stuck escape never stuck and the body marched into the flames
	# (or ground into the wall facing the target) until the fire burned out.
	for x in range(0, 32):
		_burn(Vector2i(x, 10))
	_sync_hazards()
	scout.hold_position = true   # park the earlier actors clear of the corridor
	scout.global_position = GridManager.map_to_world(Vector2i(28, 8))
	escapee.hold_position = true
	escapee.global_position = GridManager.map_to_world(Vector2i(28, 12))
	var prey := _spawn(GridManager.map_to_world(Vector2i(10, 5)), false)
	var chaser := _spawn(GridManager.map_to_world(Vector2i(10, 13)), true)
	await get_tree().physics_frame
	var chai = chaser.get_node("AI")
	chai.current_target = prey
	chai._change_state(chai.AIState.CHASE)
	var chaser_entered_fire := false
	for _i in 300:
		await get_tree().physics_frame
		if GridManager.is_hazard_tile(GridManager.world_to_map(chaser.global_position)):
			chaser_entered_fire = true
	var chaser_tile := GridManager.world_to_map(chaser.global_position)
	_report("combat.waits-at-fire-edge",
		not chaser_entered_fire and chaser_tile.y >= 11 and not chaser.is_moving,
		"tile=%s entered_fire=%s is_moving=%s" % [str(chaser_tile),
			str(chaser_entered_fire), str(chaser.is_moving)])

	print("ai_hazard_check: %d checks, %d FAIL" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
