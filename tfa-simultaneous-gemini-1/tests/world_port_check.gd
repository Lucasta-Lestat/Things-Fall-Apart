extends Node2D
# World-lane regression harness for the world/hazard/AI feedback fixes, as
# ported onto the current fire, fluid and combat-AI code:
#   1. GridManager.sight_line_clear clears more than 8 low occluders.
#   2. Data: world-map forest/water cost more than plains, every factions.json
#      relation names a real faction (strict JSON), same-map ladder/stairs
#      warps point up/down.
#   3. Structure and floor damage numbers show the whole HP lost; "Blocked"
#      only when nothing got through.
#   4. Surfaces: a recast refreshes, a cast onto other surfaces says "No
#      effect", and only real fire leaves ash when it expires.
#   5. Legacy (square-graph) cell fire: tile oil is fuel and burns off, tile
#      water is a firebreak, a burnt-out floored tile is scorched.
#   6. Fluids: dried puddles stop splashing, fluid conditions run on a
#      per-character clock, water puts out a burning character.
#   7. Shocked's own damage tick doesn't re-electrify the puddle under it.
#   8. Swing speed follows condition-modified DEX.
#   9. NPC AI: the search '?' holds until the search gives up, a visible held
#      target keeps the meter at HOSTILE, confusion re-rolls mid-fight and lets
#      go, party members skip the civilian goal loop, NPCs loot only loose
#      items (as real inventory copies), the readout perception queries.
#  10. A loud sound from a non-hostile NPC wakes an AT_EASE listener.
#  11. Game: the NPC cone rule, warp hover labels and arrows, and the
#      once-per-swing "Out of reach" notice.
# Synthetic 32x32 square map; this node stands in for Game (group "game").
# Run headless:  godot --headless --path . res://tests/world_port_check.tscn
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const ITEM_SCENE := preload("res://Structures/Objects/Item.tscn")
const STRUCTURE_SCENE := preload("res://Structures/Structure.tscn")
const FLOOR_SCENE := preload("res://Structures/Floors/floor.tscn")

# --- Game stand-in state (read by the scripts under test) ---
var characters_in_scene: Array = []
var items_in_scene: Array = []
var structures_in_scene: Array = []
var party_chars: Array = []
var selected_characters: Array = []
var context_menu_open := false
var primary_selected = null
var stealth_mode := false
var current_map_data: Dictionary = {}
var current_map_id := ""
var surface_manager: SurfaceManager = null
var fluid_manager: FluidManager = null
var fog_manager = null
var map_loader = null

var _seen: Dictionary = {}       # is_seen_by_party stand-in: char -> bool
var _game_logic = null           # a bare (not in tree) Game for its helpers
var _graph: CellGraph = null
var _cf: CellFire = null
var _floors_root: Node2D = null
var _tex: ImageTexture = null
var _fails := 0
var _checks := 0


func load_map(_a = null, _b = "", _c = "") -> void:
	pass

func register_attack_start(_a) -> void:
	pass

func register_attack_end(_a) -> void:
	pass

func is_seen_by_party(c) -> bool:
	return c in party_chars or bool(_seen.get(c, false))

func _world_item_options(item) -> Array:
	return _game_logic._world_item_options(item)


func _report(check_name: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("%s %s: %s" % ["PASS" if ok else "FAIL", check_name, detail])


func _spawn(t: Vector2i, faction: String, party := false) -> ProceduralCharacter:
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	# AI off and not player-driven: the harness calls the AI by hand.
	c.is_player_controlled = false
	c.AI_enabled = false
	add_child(c)
	c.game = self
	c.faction_id = faction
	c.Name = "%s_%d" % [faction, characters_in_scene.size()]
	c.global_position = GridManager.map_to_world(t)
	c.rotation = 0.0
	c.target_rotation = 0.0
	characters_in_scene.append(c)
	if party:
		party_chars.append(c)
	return c


func _item(id: String, t: Vector2i, stack := 1) -> Item:
	var it: Item = ITEM_SCENE.instantiate()
	it.id = id
	it.global_position = GridManager.map_to_world(t)
	add_child(it)
	# after _ready: _apply_item_data resets stack_count from the item data
	if stack > 1:
		it.stack_count = stack
	items_in_scene.append(it)
	return it


func _add_floor(t: Vector2i, fid: StringName = &"floor_wood") -> Floor:
	var fl: Floor = FLOOR_SCENE.instantiate()
	fl.floor_id = fid
	fl.use_custom_texture = true
	fl.custom_texture = _tex
	fl.skip_grid_snap = true
	fl.position = GridManager.map_to_world(t)
	_floors_root.add_child(fl)
	GridManager.register_floor(t, fl)
	return fl


func _log_count(fragment: String) -> int:
	var n := 0
	for e in GameLog.get_entries():
		if String(e.get("text", "")).contains(fragment):
			n += 1
	return n


func _floats_with(parent: Node, text: String) -> int:
	var n := 0
	for ch in parent.get_children():
		if ch is Label and (ch as Label).text == text:
			n += 1
	return n


func _cond(c: ProceduralCharacter, id: String) -> bool:
	return c.get_node("ConditionManager").has_condition(id)


func _apply(c: ProceduralCharacter, id: String, source: Node = null) -> bool:
	# Big stack count so a landing save can't refuse it (deterministic harness).
	var cm = c.get_node("ConditionManager")
	cm.apply_condition(id, source, 10)
	return cm.has_condition(id)


func _ready() -> void:
	add_to_group("game")
	TimeManager.pause_time()
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)   # 32x32 tiles, all cost 1.0
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.5, 0.5, 0.5))
	_tex = ImageTexture.create_from_image(img)
	_floors_root = Node2D.new()
	_floors_root.name = "MapLoader"   # where SurfaceManager looks for Floor nodes
	add_child(_floors_root)
	fluid_manager = FluidManager.new()
	add_child(fluid_manager)          # no cell graph: the legacy flat tile sim
	surface_manager = SurfaceManager.new()
	add_child(surface_manager)
	_graph = CellGraph.from_square_tiles()
	surface_manager.setup_cell_graph(_graph)
	_cf = surface_manager.cell_fire
	_game_logic = load("res://Game.gd").new()
	await get_tree().process_frame

	await _case_sight_cap()
	_case_data()
	_case_structure_numbers()
	_case_surfaces()
	_case_legacy_fire()
	_case_fluids()
	_case_shock_tick()
	_case_swing_speed()
	await _case_ai()
	_case_hearing()
	_case_game_helpers()

	_game_logic.free()
	print("world_port_check: %d checks, %d FAIL" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


# ---------------------------------------------------------------------------
# 1. sight_line_clear: more than 8 low occluders
# ---------------------------------------------------------------------------

func _case_sight_cap() -> void:
	var bodies: Array = []
	for i in 12:
		var body := StaticBody2D.new()
		body.collision_layer = CollisionLayers.VISION_BLOCKERS
		body.collision_mask = 0
		body.set_meta("occlude_top", 1.0)   # one story: an elevated eye tops it
		var cs := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(12, 64)
		cs.shape = rect
		body.add_child(cs)
		body.position = Vector2(300 + i * 100, 1000)
		add_child(body)
		bodies.append(body)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := get_world_2d().direct_space_state
	var from := Vector2(150, 1000)
	var to := Vector2(1900, 1000)
	_report("grid.sight-over-12-low-walls", GridManager.sight_line_clear(space, from, to, 1.0, 0.0),
		"an elevated viewer over 12 one-story occluders")
	_report("grid.ground-eye-still-blocked", not GridManager.sight_line_clear(space, from, to, 0.0, 0.0))
	for b in bodies:
		b.queue_free()
	await get_tree().physics_frame


# ---------------------------------------------------------------------------
# 2. data
# ---------------------------------------------------------------------------

func _case_data() -> void:
	var fd: Dictionary = FloorDatabase.floor_definitions
	var plains := 1.0 / float(fd["world_plains"]["walkability"])
	var forest := 1.0 / float(fd["world_forest"]["walkability"])
	var water := 1.0 / float(fd["world_water"]["walkability"])
	_report("data.world-forest-slow", forest > plains and is_equal_approx(forest, 2.5),
		"cost forest %.2f plains %.2f" % [forest, plains])
	_report("data.world-water-slowest", water > forest, "cost water %.2f" % water)

	var f := FileAccess.open("res://data/factions.json", FileAccess.READ)
	var text := f.get_as_text()
	f.close()
	var rx := RegEx.new()
	rx.compile(",\\s*[}\\]]")
	_report("data.factions-strict-json", rx.search(text) == null, "no trailing commas")
	var parsed = JSON.parse_string(text)
	var ids: Dictionary = {}
	for fac in parsed.get("factions", []):
		ids[String(fac["id"])] = true
	var undefined: Array = []
	for fac in parsed.get("factions", []):
		for key in ["allies", "enemies"]:
			for other in fac.get(key, []):
				if not ids.has(String(other)):
					undefined.append("%s.%s:%s" % [fac["id"], key, other])
	_report("data.factions-relations-defined", undefined.is_empty(), str(undefined))

	var mf := FileAccess.open("res://data/Maps.json", FileAccess.READ)
	var maps = JSON.parse_string(mf.get_as_text())
	mf.close()
	var checked := 0
	var wrong: Array = []
	for m in maps.get("maps", []):
		for w in m.get("warp_points", []):
			if String(w.get("target_map", "")) != String(m.get("id", "")):
				continue
			var lab := String(w.get("label", "")).to_lower()
			var want := ""
			if lab in ["ladder up", "stairs up"]:
				want = "up"
			elif lab in ["ladder down", "stairs down"]:
				want = "down"
			if want == "":
				continue
			checked += 1
			if String(w.get("direction", "")) != want:
				wrong.append("%s/%s" % [m["id"], w["id"]])
	_report("data.ladder-warps-point-up-down", checked >= 12 and wrong.is_empty(),
		"%d checked, wrong: %s" % [checked, str(wrong)])


# ---------------------------------------------------------------------------
# 3. structure / floor damage numbers
# ---------------------------------------------------------------------------

func _case_structure_numbers() -> void:
	var s: Structure = STRUCTURE_SCENE.instantiate()
	s.structure_id = &"stone_wall"
	s.use_custom_texture = true
	s.custom_texture = _tex
	s.custom_size = Vector2(64, 64)
	s.skip_grid_snap = true
	s.position = GridManager.map_to_world(Vector2i(30, 30))
	add_child(s)
	s.damage_resistances["slashing"] = 5
	var hp0: int = s.current_health
	s.take_damage({"slashing": 13.5}, 0)
	_report("structure.loses-whole-hp", hp0 - s.current_health == 9, "%d -> %d" % [hp0, s.current_health])
	_report("structure.shows-dealt-not-raw", s.floating_text_label.text == "9", s.floating_text_label.text)
	_report("structure.number-in-type-colour",
		s.floating_text_label.modulate.is_equal_approx(Globals.damage_color("slashing")))
	var hp1: int = s.current_health
	s.take_damage({"slashing": 3.0}, 0)
	_report("structure.fully-resisted-says-blocked", s.floating_text_label.text == "Blocked" and s.current_health == hp1,
		s.floating_text_label.text)
	s.take_damage({"slashing": 3.0, "fire": 4.0}, 0)
	_report("structure.rider-blocked-keeps-number", s.floating_text_label.text == "4", s.floating_text_label.text)
	s.queue_free()

	var fl: Floor = FLOOR_SCENE.instantiate()
	fl.floor_id = &"floor_stone"
	fl.use_custom_texture = true
	fl.custom_texture = _tex
	fl.skip_grid_snap = true
	fl.position = GridManager.map_to_world(Vector2i(31, 30))
	add_child(fl)
	fl.damage_resistances["slashing"] = 2
	var fhp0: int = fl.current_health
	fl.take_damage({"slashing": 4.4}, 0)
	_report("floor.loses-whole-hp", fhp0 - fl.current_health == 2 and fl.floating_text_label.text == "2",
		"%d -> %d '%s'" % [fhp0, fl.current_health, fl.floating_text_label.text])
	fl.take_damage({"slashing": 1.0}, 0)
	_report("floor.fully-resisted-says-blocked", fl.floating_text_label.text == "Blocked", fl.floating_text_label.text)
	fl.queue_free()


# ---------------------------------------------------------------------------
# 4. surfaces
# ---------------------------------------------------------------------------

func _floor_scorched(fl: Floor) -> bool:
	var spr: Sprite2D = fl.get_node_or_null("Sprite")
	return spr != null and spr.material is ShaderMaterial \
		and (spr.material as ShaderMaterial).shader == SurfaceManager.SCORCH_SHADER

func _case_surfaces() -> void:
	var sm := surface_manager
	var floors: Array = []
	for x in range(3, 8):
		for y in range(18, 23):
			floors.append(_add_floor(Vector2i(x, y)))
	sm.invalidate_floor_cache()
	var center := GridManager.map_to_world(Vector2i(5, 20))
	var n1: int = sm.place_surface_in_area("grassy", center, 70.0)
	_report("surface.placed", n1 > 0, "%d tiles" % n1)
	for t in sm.surface_grid:
		sm.surface_grid[t]["time_remaining"] = 1.0
	var n2: int = sm.place_surface_in_area("grassy", center, 70.0)
	var refreshed := true
	for t in sm.surface_grid:
		if not is_equal_approx(float(sm.surface_grid[t]["time_remaining"]), 30.0):
			refreshed = false
	_report("surface.recast-refreshes", n2 == n1 and refreshed, "%d of %d" % [n2, n1])
	# Bumper Crop's grass expiring leaves no ash
	for t in sm.surface_grid:
		sm.surface_grid[t]["time_remaining"] = 0.01
	sm._process_lifetime(0.1, self)
	var any_scorched := false
	for fl in floors:
		if _floor_scorched(fl) or not fl.flammable:
			any_scorched = true
	_report("surface.grass-expiry-leaves-no-ash", sm.surface_grid.is_empty() and not any_scorched)
	# Fire Spin too
	var n3: int = sm.place_surface_in_area("fire_spin", center, 70.0)
	for t in sm.surface_grid:
		sm.surface_grid[t]["time_remaining"] = 0.01
	sm._process_lifetime(0.1, self)
	any_scorched = false
	for fl in floors:
		if _floor_scorched(fl):
			any_scorched = true
	_report("surface.fire-spin-expiry-leaves-no-ash", n3 > 0 and not any_scorched)
	# ...while real tile fire still does
	var ft := Vector2i(5, 20)
	sm.surface_grid[ft] = {"surface_id": "fire", "time_remaining": 0.01, "vfx_node": null, "source_type": "floor"}
	sm._process_lifetime(0.1, self)
	var fire_floor: Floor = null
	for fl in floors:
		if GridManager.world_to_map(fl.global_position) == ft:
			fire_floor = fl
	_report("surface.fire-expiry-still-scorches", fire_floor != null and _floor_scorched(fire_floor))
	# every tile already holds another surface (ice): "No effect" at the target
	var ice_center := GridManager.map_to_world(Vector2i(20, 5))
	for dx in range(-2, 3):
		for dy in range(-2, 3):
			sm.surface_grid[Vector2i(20 + dx, 5 + dy)] = {"surface_id": "ice", "time_remaining": -1.0,
				"vfx_node": null, "source_type": "direct"}
	var before := _floats_with(sm, "No effect")
	var n4: int = sm.place_surface_in_area("grassy", ice_center, 70.0)
	_report("surface.no-room-says-no-effect", n4 == 0 and _floats_with(sm, "No effect") == before + 1,
		"placed %d" % n4)
	sm.surface_grid.clear()


# ---------------------------------------------------------------------------
# 5. legacy cell fire: tile oil and water, burnt-out scorch
# ---------------------------------------------------------------------------

func _case_legacy_fire() -> void:
	var fm := fluid_manager
	_report("fire.legacy-map-has-no-cell-fluid", fm.cell_fluid == null and _cf != null and _cf.active())
	var oil_t := Vector2i(24, 24)
	var water_t := Vector2i(27, 24)
	var dry_t := Vector2i(24, 27)
	fm.register_fluid(oil_t, "oil", 0.3)
	fm.register_fluid(water_t, "water", 0.3)
	var oil_cid := _graph.cell_at(GridManager.map_to_world(oil_t))
	var water_cid := _graph.cell_at(GridManager.map_to_world(water_t))
	var dry_cid := _graph.cell_at(GridManager.map_to_world(dry_t))
	_report("fire.legacy-oil-is-fuel", is_equal_approx(_cf._fuel(oil_cid), 2.5), "fuel %.2f" % _cf._fuel(oil_cid))
	_report("fire.legacy-water-is-firebreak", _cf._fuel(water_cid) == 0.0)
	_report("fire.legacy-bare-ground-unchanged", _cf._fuel(dry_cid) == _graph.ground_fuel(dry_cid))
	surface_manager.try_ignite(oil_t)
	_report("fire.legacy-oil-takes-a-spark", _cf.burning.has(oil_cid))
	var before := fm.get_fluid_amount(oil_t, "oil")
	_cf._damage(self)
	var after := fm.get_fluid_amount(oil_t, "oil")
	_report("fire.legacy-oil-burns-off", after < before, "%.3f -> %.3f" % [before, after])
	_cf.clear_all()
	fm.remove_fluid_tile(oil_t)
	fm.remove_fluid_tile(water_t)

	# a cell that burns out on a floored legacy tile scorches the floor (the
	# char layer draws UNDER legacy floors, so it alone would show nothing)
	var bt := Vector2i(12, 12)
	var fl := _add_floor(bt)
	surface_manager.invalidate_floor_cache()
	var cid := _graph.cell_at(GridManager.map_to_world(bt))
	_cf.burning[cid] = {"t": 0.01, "t0": 1.0, "seed": 0.5, "char": 0.0, "vfx": null}
	_cf._lifetime(0.1)
	_report("fire.burnt-out-legacy-floor-scorched", _cf.burnt[cid] == 1 and _floor_scorched(fl) and not fl.flammable)


# ---------------------------------------------------------------------------
# 6. fluids
# ---------------------------------------------------------------------------

func _case_fluids() -> void:
	var fm := fluid_manager
	# dried / burnt-off puddle: footsteps stop splashing
	var pt := Vector2i(2, 2)
	fm.register_fluid(pt, "water", 0.2)
	var wet := String(GridManager.fluids.get(pt, ""))
	fm.remove_fluid(pt, 1.0)   # burnt/dried off entirely
	_report("fluid.gone-puddle-stops-splashing", wet == "water" and String(GridManager.fluids.get(pt, "")) == "",
		"'%s' -> '%s'" % [wet, String(GridManager.fluids.get(pt, ""))])

	# per-character clock: stepping into a pool doesn't inherit its clock
	var t1 := Vector2i(3, 28)
	var t2 := Vector2i(5, 28)
	fm.register_fluid(t1, "acid", 0.3)
	fm.register_fluid(t2, "acid", 0.3)
	var c := _spawn(Vector2i(30, 28), "neutral")
	fm.update_fluid_conditions(1.4, [c])   # dry: no clock runs for anyone
	c.global_position = GridManager.map_to_world(t2)
	fm.update_fluid_conditions(0.2, [c])
	_report("fluid.clock-starts-on-entry", not _cond(c, "corroding"), "0.2 s in acid (interval 1.5)")
	fm.update_fluid_conditions(1.4, [c])
	_report("fluid.clock-applies-after-interval", _cond(c, "corroding"), "1.6 s in acid")
	fm.remove_fluid_tile(t1)
	fm.remove_fluid_tile(t2)

	# water puts out a burning party member, with a log line
	var wt := Vector2i(8, 28)
	fm.register_fluid(wt, "water", 0.3)
	var p := _spawn(Vector2i(10, 28), "player", true)
	var lit := _apply(p, "burning")
	p.global_position = GridManager.map_to_world(wt)
	var logs := _log_count("Burning is put out (water)")
	fm.update_fluid_conditions(0.05, [p])
	_report("fluid.water-douses-burning", lit and not _cond(p, "burning"), "lit=%s" % str(lit))
	_report("fluid.douse-logged-for-party", _log_count("Burning is put out (water)") == logs + 1)
	_report("fluid.douse-floats-extinguished", _floats_with(self, "Burning put out") >= 1)
	# an NPC the party doesn't see is doused too, without a float or a log line
	var q := _spawn(Vector2i(12, 28), "bandits")
	var qlit := _apply(q, "burning")
	q.global_position = GridManager.map_to_world(wt)
	var floats := _floats_with(self, "Burning put out")
	logs = _log_count("is put out (water)")
	fm.update_fluid_conditions(0.05, [q])
	_report("fluid.unseen-npc-doused-silently", qlit and not _cond(q, "burning") \
		and _floats_with(self, "Burning put out") <= floats and _log_count("is put out (water)") == logs)
	fm.remove_fluid_tile(wt)


# ---------------------------------------------------------------------------
# 7. Shocked's tick doesn't re-electrify the tile
# ---------------------------------------------------------------------------

func _case_shock_tick() -> void:
	var fm := fluid_manager
	var sm := surface_manager
	var wt := Vector2i(16, 28)
	fm.register_fluid(wt, "water", 0.3)
	var c := _spawn(wt, "neutral")
	sm.electrified_grid.clear()
	var shocked := _apply(c, "shocked")
	var inst = c.get_node("ConditionManager").conditions.get("shocked")
	if inst != null:
		c._on_triggered_effect_fired(inst, {}, {"damage": 3, "damage_type": "electric"})
	_report("shock.tick-doesnt-reelectrify", shocked and inst != null and sm.electrified_grid.is_empty(),
		"electrified %d" % sm.electrified_grid.size())
	c.take_damage({"electric": 4}, c.global_position)
	_report("shock.real-hit-still-electrifies", not sm.electrified_grid.is_empty())
	sm.electrified_grid.clear()
	fm.remove_fluid_tile(wt)


# ---------------------------------------------------------------------------
# 8. swing speed follows effective DEX
# ---------------------------------------------------------------------------

func _case_swing_speed() -> void:
	var c := _spawn(Vector2i(20, 28), "neutral")
	c.dexterity = 50
	c.dexterity_modifier = 0.0
	var anim = c.get_node("AttackAnimator")
	anim.start_attack("bludgeoning", Vector2.UP, "Main", null)
	var w0: float = anim.windup_duration
	anim._finish_attack()
	c.dexterity_modifier = 50.0   # e.g. a +DEX condition: effective 100
	anim.start_attack("bludgeoning", Vector2.UP, "Main", null)
	var w1: float = anim.windup_duration
	anim._finish_attack()
	_report("swing.speed-follows-effective-dex", w0 > 0.0 and is_equal_approx(w1, w0 * 0.5),
		"windup %.3f -> %.3f" % [w0, w1])


# ---------------------------------------------------------------------------
# 9. NPC AI
# ---------------------------------------------------------------------------

func _case_ai() -> void:
	# --- '?' held for the whole search ---
	var s := _spawn(Vector2i(28, 2), "bandits")
	var sai = s.get_node("AI")
	sai._change_state(sai.AIState.SEARCHING)
	sai._set_alertness_value(50.0)
	_report("ai.search-?-holds-below-60", sai.current_alertness == sai.Alertness.SEARCHING, str(sai.current_alertness))
	sai._set_alertness_value(30.0)
	_report("ai.search-?-drops-at-give-up", sai.current_alertness == sai.Alertness.SUSPICIOUS, str(sai.current_alertness))
	sai._set_alertness_value(50.0)
	sai._change_state(sai.AIState.IDLE)
	_report("ai.leaving-search-drops-?", sai.current_alertness == sai.Alertness.SUSPICIOUS, str(sai.current_alertness))

	# --- a visible held target keeps the meter at HOSTILE ---
	var a := _spawn(Vector2i(10, 10), "bandits")
	var b := _spawn(Vector2i(10, 7), "rival_party")   # in front (facing up)
	await get_tree().physics_frame
	var aai = a.get_node("AI")
	aai._acquire_target(b)
	aai._set_alertness_value(80.0)
	aai.time_since_last_stimulus = 9.0
	aai.last_heard_position = Vector2.ZERO
	aai._update_target(0.1)
	_report("ai.fighting-holds-hostile",
		aai.alertness_value >= aai.ALERTNESS_MAX and aai.current_alertness == aai.Alertness.HOSTILE,
		"alert %.0f class %d" % [aai.alertness_value, aai.current_alertness])
	_report("ai.fighting-refreshes-stimulus", aai.time_since_last_stimulus == 0.0 and aai.last_heard_position == b.global_position)
	# The held-target readout, is_target_in_sight(), comes with the world-info
	# lane and reads this clock: zero while the hold has the target in sight.
	_report("ai.held-target-seen-by-hold", aai._target_occluded_time == 0.0)
	if aai.has_method("is_target_in_sight"):
		_report("ai.held-target-in-sight", aai.is_target_in_sight())
		aai._target_occluded_time = 1.0
		_report("ai.occluded-held-target-not-in-sight", not aai.is_target_in_sight())
		aai._target_occluded_time = 0.0
	aai._lose_target()
	# park everyone so far behind the next onlooker (it faces up the map), so
	# the only one its confused eye can pick is `ahead`
	s.global_position = GridManager.map_to_world(Vector2i(1, 31))
	a.global_position = GridManager.map_to_world(Vector2i(2, 31))
	b.global_position = GridManager.map_to_world(Vector2i(3, 31))

	# --- confusion re-rolls mid-fight and lets go ---
	var x := _spawn(Vector2i(16, 16), "bandits")
	var behind := _spawn(Vector2i(16, 19), "rival_party")   # 3 tiles behind: held, not seen
	var ahead := _spawn(Vector2i(16, 13), "rival_party")    # 3 tiles in front
	await get_tree().physics_frame
	var xai = x.get_node("AI")
	_report("ai.perception-sees-ahead", xai.can_see_character(ahead))
	_report("ai.perception-misses-behind", not xai.can_see_character(behind))
	xai._acquire_target(behind)
	xai._update_target(0.1)
	_report("ai.precondition-holds-target-behind", xai.current_target == behind)
	_seen[x] = true
	var lash := _log_count("lashes out at")
	var lash_unseen := _log_count("%s lashes out at someone unseen in confusion!" % x.Name)
	var confused := _apply(x, "confused")
	xai._update_target(0.1)
	_report("ai.confusion-rerolls-mid-fight", confused and xai.current_target == ahead,
		"target %s" % (xai.current_target.Name if xai.current_target else "none"))
	_report("ai.confusion-logged", _log_count("lashes out at") == lash + 1)
	# Round 6: the one it picked isn't seen by the party, so it isn't named.
	_report("ai.confusion-unseen-pick-unnamed", _log_count("%s lashes out at someone unseen in confusion!" % x.Name) == lash_unseen + 1 \
		and _log_count("lashes out at %s" % ahead.Name) == 0)
	xai._update_target(0.1)
	var last: Dictionary = GameLog.get_entries()[-1]
	_report("ai.confusion-logged-once", _log_count("lashes out at") == lash + 1 \
		and not (String(last.get("text", "")).contains("lashes out") and int(last.get("count", 1)) > 1))
	x.get_node("ConditionManager").remove_condition("confused")
	xai._update_target(0.1)
	_report("ai.confusion-end-drops-random-target", xai.current_target == null and not xai._confused_pick_done)
	# a confused pick never lands on the charmer
	var charmed := _apply(x, "infatuated", ahead)
	confused = _apply(x, "confused")
	xai._update_target(0.1)
	_report("ai.confusion-spares-the-charmer", charmed and confused and xai.current_target != ahead,
		"target %s" % (xai.current_target.Name if xai.current_target else "none"))
	x.get_node("ConditionManager").remove_condition("confused")
	x.get_node("ConditionManager").remove_condition("infatuated")
	xai._update_target(0.1)

	# close quarters: seen behind unless sneaking
	behind.global_position = GridManager.map_to_world(Vector2i(16, 17))
	await get_tree().physics_frame
	_report("ai.perception-close-quarters", xai.can_see_character(behind))
	party_chars.append(behind)
	stealth_mode = true
	_report("ai.perception-sneaker-unseen-behind", not xai.can_see_character(behind))
	stealth_mode = false
	party_chars.erase(behind)

	# --- party members skip the civilian goal loop; NPCs still run it ---
	var helm := _item("golden_crown_helm", Vector2i(24, 12))
	var p := _spawn(Vector2i(24, 15), "player", true)
	var n := _spawn(Vector2i(25, 15), "neutral")
	await get_tree().physics_frame
	var pai = p.get_node("AI")
	var nai = n.get_node("AI")
	pai.reassess_goals()
	nai.reassess_goals()
	_report("ai.npc-goes-for-loose-valuable", nai.current_goal == "seek_wealth" and nai.target_item == helm,
		nai.current_goal)
	_report("ai.party-member-skips-goals", pai.current_goal == "idle" and pai.target_item == null, pai.current_goal)
	pai.current_goal = "wander"
	pai.execute_current_goal()
	_report("ai.party-member-doesnt-wander", pai.nav_path.is_empty())

	# --- NPC looting: loose items only, as inventory copies ---
	var chest := _item("treasure_chest", Vector2i(28, 20))
	var key := _item("gold_key", Vector2i(27, 20))
	var apple := _item("apple", Vector2i(29, 20))
	var gold := _item("gold", Vector2i(26, 20), 5)
	var looter := _spawn(Vector2i(28, 23), "neutral")
	await get_tree().physics_frame
	var lai = looter.get_node("AI")
	_report("ai.loot-skips-chest", not lai._is_takeable_item(chest))
	_report("ai.loot-skips-key", not lai._is_takeable_item(key))
	_report("ai.loot-takes-loose-item", lai._is_takeable_item(apple) and lai._is_takeable_item(gold))
	var best = lai.find_most_valuable_item_in_sight()
	_report("ai.loot-best-is-not-the-chest", best != null and best != chest and best != key,
		str(best.id) if best else "none")
	_seen.erase(looter)
	var picks := _log_count("picks up")
	lai.current_goal = "seek_wealth"
	lai.pickup_item(apple)
	var has_apple := false
	for d in looter.inventory.items:
		if String(d.get("id", "")) == "apple":
			has_apple = true
	_report("ai.loot-real-inventory-copy", has_apple and not (apple in items_in_scene) and apple.is_queued_for_deletion())
	_report("ai.loot-unseen-not-logged", _log_count("picks up") == picks)
	_seen[looter] = true
	lai.pickup_item(gold)
	_report("ai.loot-seen-logged", _log_count("picks up") == picks + 1 and _log_count("(x5)") >= 1,
		"log: %s" % String(GameLog.get_entries()[-1].get("text", "")))
	_report("ai.loot-chest-untouched", is_instance_valid(chest) and chest in items_in_scene and not chest.is_queued_for_deletion())
	# a non-stackable (Items.json "num_stacks": null) is taken too, not refused
	# by add_stack's int(null)
	var helm2 := _item("fancy_metal_helmet", Vector2i(27, 22))
	lai.current_goal = "seek_wealth"
	lai.pickup_item(helm2)
	var has_helm := false
	for d in looter.inventory.items:
		if String(d.get("id", "")) == "fancy_metal_helmet":
			has_helm = true
	_report("ai.loot-takes-non-stackable", has_helm and helm2.is_queued_for_deletion())


# ---------------------------------------------------------------------------
# 10. hearing: a loud sound wakes AT_EASE whoever made it
# ---------------------------------------------------------------------------

func _case_hearing() -> void:
	var src := _spawn(Vector2i(2, 10), "golden_guard")
	var calm := _spawn(Vector2i(4, 10), "neutral")
	var calm2 := _spawn(Vector2i(3, 12), "neutral")
	var cai = calm.get_node("AI")
	var cai2 = calm2.get_node("AI")
	_report("hear.precondition-not-hostile", not FactionDatabase.are_hostile("neutral", "golden_guard"))
	cai2.apply_default_alertness("at_ease")
	HearingManager.emit(src.global_position, 0.5, src)
	_report("hear.quiet-guard-noise-ignored", cai2.is_at_ease)
	cai.apply_default_alertness("at_ease")
	HearingManager.emit(src.global_position, 1.9, src)   # a guard's gunshot
	_report("hear.loud-guard-noise-wakes-at-ease", not cai.is_at_ease)


# ---------------------------------------------------------------------------
# 11. Game helpers (on a bare Game instance)
# ---------------------------------------------------------------------------

func _case_game_helpers() -> void:
	var g = _game_logic
	var npc := _spawn(Vector2i(6, 6), "bandits")
	g.stealth_mode = true
	g.current_map_data = {}
	_report("cones.shown-in-stealth", g._npc_cones_shown(npc))
	g.current_map_data = {"is_world_map": true}
	_report("cones.hidden-on-world-map", not g._npc_cones_shown(npc))
	g.current_map_data = {}
	g.stealth_mode = false
	_report("cones.hidden-without-stealth", not g._npc_cones_shown(npc))
	g.stealth_mode = true
	var corpse := _spawn(Vector2i(7, 6), "bandits")
	corpse.current_health = 0
	_report("cones.hidden-on-corpse", not g._npc_cones_shown(corpse))

	g.current_map_id = "tg_castle_demo"
	_report("warp.same-map-ladder-names-itself",
		g._warp_hover_text({"label": "Ladder up", "target_map": "tg_castle_demo"}) == "Ladder up")
	_report("warp.world-warp-names-itself",
		g._warp_hover_text({"label": "Alamone", "target_map": "town_square", "world_warp": true}) == "Alamone")
	var other: String = g._warp_hover_text({"label": "To Town Square", "target_map": "town_square"})
	_report("warp.cross-map-names-destination", other != "" and other != "To Town Square", other)
	_report("warp.up-arrow-points-north", is_equal_approx(g._warp_arrow_rotation({"direction": "up"}, Vector2.ZERO), -PI / 2.0))
	_report("warp.down-arrow-points-south", is_equal_approx(g._warp_arrow_rotation({"direction": "down"}, Vector2.ZERO), PI / 2.0))

	# "Out of reach": selected swinger only, the intended body only, once per swing
	var hero := _spawn(Vector2i(10, 2), "player")
	var foe := _spawn(Vector2i(10, 1), "bandits")
	var foe2 := _spawn(Vector2i(11, 1), "bandits")
	hero.current_elevation = 1.0
	foe.current_elevation = 0.0
	foe2.current_elevation = 0.0
	g.party_chars = [hero]
	g.selected_characters = [hero]
	g.register_attack_start(hero)
	var reach := _log_count("melee can't strike between levels")
	var hit_ok: bool = g.can_hit_target(hero, foe)
	_report("reach.cross-level-vetoed", not hit_ok)
	_report("reach.selected-swinger-warned", _log_count("melee can't strike between levels") == reach + 1)
	g.can_hit_target(hero, foe)
	g.can_hit_target(hero, foe2)
	var last: Dictionary = GameLog.get_entries()[-1]
	_report("reach.once-per-swing", _log_count("melee can't strike between levels") == reach + 1 \
		and int(last.get("count", 1)) == 1)
	g.selected_characters = []
	g.register_attack_start(hero)
	hero._last_notify_ms = -100000
	g.can_hit_target(hero, foe)
	_report("reach.ai-driven-swing-silent", _log_count("melee can't strike between levels") == reach + 1)
	g.selected_characters = [hero]
	g.register_attack_start(hero)
	hero._last_notify_ms = -100000
	hero.attack_aim_node = foe2
	g.can_hit_target(hero, foe)
	_report("reach.only-the-intended-body-warns", _log_count("melee can't strike between levels") == reach + 1)
	g.can_hit_target(hero, foe2)
	_report("reach.intended-body-warns", _log_count("melee can't strike between levels") == reach + 2)
	hero.attack_aim_node = null
	g.party_chars = []
	g.selected_characters = []
