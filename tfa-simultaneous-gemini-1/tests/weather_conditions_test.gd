# res://tests/weather_conditions_test.gd
# Headless checks for weather that applies conditions outdoors (F9): Acid Rain
# corrodes and Freezing Rain chills characters under open sky but not under a
# roof, rain puddles only on open ground, timed spell weather reverting (and
# its conditions being the caster's), and weather spells refused indoors.
# Run:  godot --headless --path . res://tests/weather_conditions_test.tscn
# Judge by PASS/FAIL lines and the HARNESS DONE count.
extends Node2D

var failures := 0
var game = null

func _check(check_name: String, cond: bool, detail = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, str(detail)])

func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

func _log_has(parts: Array) -> bool:
	for e in GameLog.get_entries():
		var text := str(e.get("text", ""))
		var ok := true
		for part in parts:
			if not (part in text):
				ok = false
		if ok:
			return true
	return false

func _ready() -> void:
	TimeManager.pause_time()
	await get_tree().process_frame
	var GameScene := load("res://game.tscn")
	game = GameScene.instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _frames(2)
	game.load_map("tg_castle_demo")
	await _frames(10)
	await _run()
	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _run() -> void:
	var group: String = game.current_map_data.get("weather_group", "")
	# Drive the weather ticks by hand; keep real time from moving the fight.
	PauseManager.is_paused = true
	for c in game.characters_in_scene:
		c.AI_enabled = false
	_check("castle.outdoors", not game.is_map_indoors())
	_check("castle.roof-layer", GridManager.roof_elevations.size() > 0, GridManager.roof_elevations.size())
	WeatherManager.set_precipitation(group, "clear")
	await _frames(1)

	# ---- Acid Rain (timed spell weather on a map with a weather group)
	var caster = game.party_chars[0]
	game.force_weather("acid_rain", 60.0, caster)
	_check("acid.falling", game.current_precipitation() == "acid_rain", game.current_precipitation())
	_check("acid.timed-reverts-to-clear", is_equal_approx(game._forced_weather_left, 60.0) and game._forced_weather_revert == "clear",
		[game._forced_weather_left, game._forced_weather_revert])
	_check("acid.log-names-the-danger", _log_has(["Sight drops to 70%", "corrode"]))

	# Puddles: acid on open ground, none under roofs. Structured maps deposit
	# into fluid cells, projected onto tiles on the fluid tick; project now.
	if game.fluid_manager.cell_fluid != null and game.fluid_manager.cell_fluid.has_method("active_sim") \
			and game.fluid_manager.cell_fluid.active_sim() and game.fluid_manager.has_method("_project_cells_to_tiles"):
		game.fluid_manager._project_cells_to_tiles()
	var acid_roofed := 0
	var r: Rect2i = GridManager.map_rect
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var t := Vector2i(x, y)
			if game.fluid_manager.get_fluid_type_at(t) == "acid" and GridManager.has_roof(t):
				acid_roofed += 1
	_check("acid.no-puddles-under-roofs", acid_roofed == 0, acid_roofed)

	# One character under a roof, one in the open.
	var roofed := Vector2i(-1, -1)
	for t in GridManager.roof_elevations:
		if not GridManager.walls.get(t, true):
			roofed = t
			break
	var open_t := Vector2i(-1, -1)
	for y in range(r.position.y + 2, r.end.y - 2):
		for x in range(r.position.x + 2, r.end.x - 2):
			var t := Vector2i(x, y)
			if not GridManager.has_roof(t) and not GridManager.walls.get(t, true):
				open_t = t
				break
		if open_t.x >= 0:
			break
	var p = game.party_chars[0]
	var sheltered = game.party_chars[1] if game.party_chars.size() > 1 else null
	_check("setup.open-tile-roofed-tile-two-members", open_t.x >= 0 and roofed.x >= 0 and sheltered != null)
	if sheltered == null or open_t.x < 0 or roofed.x < 0:
		return
	p.global_position = GridManager.map_to_world(open_t)
	sheltered.global_position = GridManager.map_to_world(roofed)
	sheltered.on_roof = false
	_check("exposure.open-tile", game.is_exposed_to_sky(p))
	_check("exposure.roofed-tile-sheltered", not game.is_exposed_to_sky(sheltered))
	p.condition_manager.remove_condition("corroding")
	sheltered.condition_manager.remove_condition("corroding")
	game._weather_condition_timers.clear()
	game._tick_weather_conditions(1.0)
	game._tick_weather_conditions(1.0)
	_check("acid.not-yet-after-2s", not p.condition_manager.has_condition("corroding"))
	game._tick_weather_conditions(1.0)
	_check("acid.3s-in-the-open-corroding", p.condition_manager.has_condition("corroding"))
	_check("acid.under-a-roof-no-corroding", not sheltered.condition_manager.has_condition("corroding"))
	var inst = p.condition_manager.conditions.get("corroding")
	_check("acid.the-casters-doing", inst != null and inst.source == caster, inst.source if inst else null)
	var exp0: float = inst.expires_at if inst else 0.0
	TimeManager.game_time += 2.0
	game._tick_weather_conditions(3.0)
	inst = p.condition_manager.conditions.get("corroding")
	_check("acid.one-stack-timer-refreshed", inst != null and inst.stacks == 1 and inst.expires_at > exp0,
		[inst.stacks if inst else null, exp0, inst.expires_at if inst else null])
	# Standing on a roof is open sky.
	sheltered.on_roof = true
	_check("exposure.on-a-roof", game.is_exposed_to_sky(sheltered))
	sheltered.on_roof = false

	# ---- Freezing Rain: chilled, capped at 2 stacks (no Frozen from rain alone)
	p.condition_manager.remove_condition("corroding")
	game.force_weather("freezing_rain")
	_check("freeze.log-chilled-to-the-bone", _log_has(["chilled to the bone"]))
	game._weather_condition_timers.clear()
	for i in 6:
		game._tick_weather_conditions(4.0)
	var chilled = p.condition_manager.conditions.get("chilled")
	_check("freeze.chills-the-exposed-2-stacks", chilled != null and chilled.stacks == 2, chilled.stacks if chilled else null)
	_check("freeze.rain-alone-never-freezes", not p.condition_manager.has_condition("frozen"))
	_check("freeze.sheltered-stays-warm", not sheltered.condition_manager.has_condition("chilled"))
	_check("freeze.untimed-weather-has-no-caster", chilled == null or chilled.source == null)
	p.condition_manager.remove_condition("chilled")

	# ---- Timed spell weather passes
	WeatherManager.set_precipitation(group, "clear")
	game._forced_weather_left = 0.0
	game.force_weather("acid_rain", 2.0, caster)
	game._tick_forced_weather(1.0)
	_check("timed.still-raining-at-1s", game.current_precipitation() == "acid_rain")
	game._tick_forced_weather(1.5)
	_check("timed.reverts-when-it-runs-out", game.current_precipitation() == "clear", game.current_precipitation())
	_check("timed.log-passes", _log_has(["Acid Rain passes."]))
	# One line for the change, the passing spell leading it (GWT-1).
	_check("timed.log-one-line", _log_has(["Acid Rain passes. The weather turns: Clear."]))
	_check("timed.log-full-sight-returns", _log_has(["Full sight returns."]))
	game._weather_condition_timers.clear()
	game._tick_weather_conditions(10.0)
	_check("timed.clear-sky-applies-nothing", game._weather_condition_timers.is_empty() and not p.condition_manager.has_condition("corroding"))

	# ---- World map: nobody is exposed
	game.current_map_data["is_world_map"] = true
	_check("world-map.nobody-exposed", not game.is_exposed_to_sky(p))
	game.current_map_data.erase("is_world_map")

	# ---- Wired into Game._process: exposure timers run for exactly the exposed
	game.force_weather("acid_rain")
	PauseManager.is_paused = false
	await _frames(3)
	PauseManager.is_paused = true
	var timers_ok := true
	for c in game.characters_in_scene:
		if not is_instance_valid(c) or not c.is_alive():
			continue
		var timed: bool = game._weather_condition_timers.has(c.get_instance_id())
		if timed != game.is_exposed_to_sky(c):
			timers_ok = false
	_check("process.times-exactly-the-exposed", timers_ok and game._weather_condition_timers.size() > 0, game._weather_condition_timers.size())

	# ---- Leaving the map restores the group's weather under timed spell weather
	game.force_weather("acid_rain", 30.0, caster)
	WeatherManager.set_precipitation(group, "clear")
	game.force_weather("acid_rain", 30.0, caster)
	game._forced_weather_revert = "overcast"

	# ---- Indoors: the weather spell is refused
	PauseManager.is_paused = false
	game.load_map("perrow_tavern")
	await _frames(20)
	_check("leave.group-weather-restored", WeatherManager.get_precipitation(group) == "overcast", WeatherManager.get_precipitation(group))
	_check("leave.spell-timer-cleared", game._forced_weather_left == 0.0 and game._weather_caster == null)
	_check("indoors.tavern-flagged", game.is_map_indoors())
	var tav_caster = game.party_chars[0]
	var res: Dictionary = tav_caster._change_weather({"precipitation_type": "acid_rain", "duration": 60}, [], null, Vector2.ZERO)
	_check("indoors.weather-spell-refused", res.get("success", true) == false and game.current_precipitation() == "clear", res)
	_check("indoors.refusal-explained", _log_has(["no open sky"]))
	_check("indoors.weather-never-reduces-sight", is_equal_approx(game.get_weather_visibility_mult(), 1.0))
	WeatherManager.set_precipitation(group, "clear")
