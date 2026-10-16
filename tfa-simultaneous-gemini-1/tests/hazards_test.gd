# res://tests/hazards_test.gd
# Headless checks for hazard information: the electrify flood dry run and its
# parity with try_electrify, hazard identification text (fire, ice, fluids
# including dev's oil and ink, electrified ground), poison vs acid colours,
# compass/wind wording, the electrify targeting preview, then on the real Game
# the paused-only hazard hover provider and the wind HUD widget.
# Run:  godot --headless --path . res://tests/hazards_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

# A stand-in for Game: SurfaceManager finds it by its load_map() method.
const STUB_GAME_SRC := """
extends Node2D
var fluid_manager = null
var surface_manager = null
var fog_manager = null
var current_map_data := {}
var characters_in_scene: Array = []
var party_chars: Array = []
func load_map(_id = ""):
	pass
"""

const STUB_CHAR_SRC := """
extends Node2D
var alive := true
func is_alive() -> bool:
	return alive
"""

const EP = preload("res://Abilities/ElectrifyPreview.gd")

var failures := 0

func _check(check_name: String, ok: bool, detail = "") -> void:
	if ok:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, str(detail)])

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _script(src: String) -> GDScript:
	var s := GDScript.new()
	s.source_code = src
	s.reload()
	return s

func _ready() -> void:
	get_tree().create_timer(240.0, true).timeout.connect(func():
		print("FAIL watchdog timeout (coroutine aborted?) failures=%d" % failures)
		get_tree().quit(99))
	await _frames(2)
	_case_globals()
	_case_data()
	await _case_stub_world()
	await _case_game()
	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

# ---------------------------------------------------------------------------

func _case_globals() -> void:
	var compass := {Vector2.RIGHT: "E", Vector2(0, 1): "S", Vector2(1, -1): "NE", Vector2.LEFT: "W", Vector2(0, -1): "N", Vector2(-1, 1): "SW"}
	for d in compass:
		_check("compass %s" % d, Globals.compass_name(d) == compass[d], Globals.compass_name(d))
	# WeatherManager's angle convention: Vector2.RIGHT rotated, 90 deg = down = S.
	_check("compass of a 90 deg wind is S", Globals.compass_name(Vector2.RIGHT.rotated(deg_to_rad(90.0))) == "S")
	var words := {0.0: "Calm", 2.9: "Calm", 3.0: "Light", 14.9: "Light", 15.0: "Moderate", 40.0: "Strong", 80.0: "Gale"}
	for w in words:
		_check("wind word %s" % w, Globals.wind_strength_word(w) == words[w], Globals.wind_strength_word(w))

func _case_data() -> void:
	var parsed = JSON.parse_string(FileAccess.open("res://data/fluids.json", FileAccess.READ).get_as_text())
	_check("fluids.json parses", parsed is Dictionary)
	if not (parsed is Dictionary):
		return
	var fluids: Dictionary = parsed["fluids"]
	var poison: Array = fluids["poison"]["color"]
	var acid: Array = fluids["acid"]["color"]
	_check("poison is violet (blue > green)", poison[2] > poison[1] and poison[0] > poison[1], poison)
	_check("acid stays lime (green > blue)", acid[1] > acid[2], acid)
	var unnamed := []
	for k in fluids:
		if str(fluids[k].get("display_name", "")) == "":
			unnamed.append(k)
	_check("every fluid has a display_name", unnamed.is_empty(), unnamed)
	var fogs = JSON.parse_string(FileAccess.open("res://data/fogs.json", FileAccess.READ).get_as_text())
	var pf: Array = fogs["fogs"]["poison"]["color"]
	_check("poison fog violet like the fluid", pf[2] > pf[1], pf)
	var cloud_txt := FileAccess.open("res://vfx/poison_cloud.tscn", FileAccess.READ).get_as_text()
	_check("poison cloud vfx is violet", cloud_txt.contains("color = Color(0.45, 0.22, 0.6, 1)") and not cloud_txt.contains("0.3, 0.9, 0.2"))

	var ab = JSON.parse_string(FileAccess.open("res://data/Abilities.json", FileAccess.READ).get_as_text())
	var list = ab["abilities"] if ab is Dictionary and ab.has("abilities") else ab
	if list is Dictionary:
		list = list.values()
	var by_id := {}
	for a in list:
		if a is Dictionary:
			by_id[str(a.get("id", ""))] = a
	_check("is_electric(lightning_bolt)", by_id.has("lightning_bolt") and EP.is_electric(by_id["lightning_bolt"]))
	_check("not is_electric(fireball)", by_id.has("fireball") and not EP.is_electric(by_id["fireball"]))
	_check("is_electric reads steps", EP.is_electric({"steps": [{"effects": [{"type": "damage", "damage": {"electric": 5}}]}]}))
	_check("zero electric damage is not electric", not EP.is_electric({"effects": [{"type": "damage", "damage": {"electric": 0, "fire": 5}}]}))

# ---------------------------------------------------------------------------

func _case_stub_world() -> void:
	GridManager.TILE_SIZE = 64
	GridManager.initialize(20 * 64, 20 * 64)
	var game = _script(STUB_GAME_SRC).new()
	get_tree().root.add_child(game)
	var harness_scene := get_tree().current_scene
	get_tree().current_scene = game
	var fm = load("res://FluidManager.gd").new()
	game.add_child(fm)
	game.fluid_manager = fm
	var sm = load("res://SurfaceManager.gd").new()
	game.add_child(sm)
	game.surface_manager = sm
	await _frames(1)

	# An L of water with a blood pool touching it: different fluids don't join.
	var water: Array[Vector2i] = [Vector2i(2, 2), Vector2i(3, 2), Vector2i(4, 2), Vector2i(4, 3), Vector2i(4, 4)]
	for t in water:
		fm.fluid_grid[t] = {"water": 0.5}
	fm.fluid_grid[Vector2i(5, 2)] = {"blood": 0.5}
	fm.fluid_grid[Vector2i(6, 2)] = {"blood": 0.5}

	var region: Dictionary = sm.electrify_region(Vector2i(2, 2))
	_check("region: the whole water body, no blood", _same(region["tiles"], water), region["tiles"])
	_check("region source fluid", region["source"] == "fluid")
	_check("dry run changes nothing", sm.electrified_grid.is_empty())
	_check("blood pool is its own region", _same(sm.electrify_region(Vector2i(6, 2))["tiles"], [Vector2i(5, 2), Vector2i(6, 2)]))
	var bare: Dictionary = sm.electrify_region(Vector2i(12, 12))
	_check("bare ground: one direct tile", _same(bare["tiles"], [Vector2i(12, 12)]) and bare["source"] == "direct", bare)
	_check("cap bounds the search", sm.electrify_region(Vector2i(2, 2), 2)["tiles"].size() == 2)

	var n: int = sm.try_electrify(Vector2i(4, 4))
	_check("try_electrify electrifies exactly the region", n == water.size() and _same(sm.electrified_grid.keys(), water), [n, sm.electrified_grid.keys()])
	_check("fluid tiles keep the fluid source", sm.electrified_grid[Vector2i(2, 2)]["source_type"] == "fluid")
	sm.electrified_grid[Vector2i(2, 2)]["time_remaining"] = 0.1
	_check("re-hit: no new tiles", sm.try_electrify(Vector2i(3, 2)) == 0)
	_check("re-hit refreshes the duration", is_equal_approx(sm.electrified_grid[Vector2i(2, 2)]["time_remaining"], 1.2), sm.electrified_grid[Vector2i(2, 2)]["time_remaining"])
	_check("bare hit electrifies one tile", sm.try_electrify(Vector2i(12, 12)) == 1 and sm.try_electrify(Vector2i(12, 12)) == 0)

	# Hazard identification
	var tile_pos := func(t: Vector2i) -> Vector2: return GridManager.map_to_world(t)
	var on_water: Array = sm.describe_hazards_at(tile_pos.call(Vector2i(2, 2)))
	var kinds := on_water.map(func(h): return h["kind"])
	_check("electrified water: both listed", kinds.has("electrified") and kinds.has("fluid"), kinds)
	var water_text: String = sm.hazard_tooltip_text(tile_pos.call(Vector2i(2, 2)))
	print("water tooltip: ", water_text.replace("\n", " | "))
	_check("electrified: Shocked + CON save", water_text.contains("Shocked") and water_text.contains("CON save every 0.3 s or Stunned"), water_text)
	_check("water: puts out fire, conducts", water_text.contains("Puts out fire") and water_text.contains("Conducts electricity"), water_text)

	fm.fluid_grid[Vector2i(8, 8)] = {"acid": 0.5}
	var acid: Array = sm.describe_hazards_at(tile_pos.call(Vector2i(8, 8)))
	_check("acid: Corroding", acid.size() == 1 and acid[0]["condition_id"] == "corroding", acid)
	var acid_text: String = sm.hazard_tooltip_text(tile_pos.call(Vector2i(8, 8)))
	print("acid tooltip: ", acid_text.replace("\n", " | "))
	_check("acid text: name, rule, interval", acid_text.contains("[b]Acid[/b]") and acid_text.contains("Applies [b]Corroding[/b] every 1.5 s") and acid_text.contains("Conducts"), acid_text)
	fm.fluid_grid[Vector2i(9, 8)] = {"oil": 0.5}
	var oil_text: String = sm.hazard_tooltip_text(tile_pos.call(Vector2i(9, 8)))
	_check("oil: flammable, slows, doesn't conduct", oil_text.contains("Flammable") and oil_text.contains("Slowed") and not oil_text.contains("Conducts"), oil_text)
	fm.fluid_grid[Vector2i(10, 8)] = {"ink": 0.5}
	var ink_text: String = sm.hazard_tooltip_text(tile_pos.call(Vector2i(10, 8)))
	_check("ink: named, conducts, applies nothing", ink_text.contains("[b]Ink[/b]") and ink_text.contains("Conducts") and not ink_text.contains("Applies"), ink_text)
	fm.fluid_grid[Vector2i(11, 8)] = {"poison": 0.5}
	_check("poison: Poisoned every 2 s", sm.hazard_tooltip_text(tile_pos.call(Vector2i(11, 8))).contains("[b]Poisoned[/b] every 2 s"))

	sm.place_surface_in_area("grassy", tile_pos.call(Vector2i(14, 14)), 10.0)
	var grass: Array = sm.describe_hazards_at(tile_pos.call(Vector2i(14, 14)))
	_check("grassy: verdant_blessing", grass.size() == 1 and grass[0]["id"] == "grassy" and grass[0]["condition_id"] == "verdant_blessing", grass)
	_check("buff surfaces Grant", sm.hazard_tooltip_text(tile_pos.call(Vector2i(14, 14))).contains("Grants"))
	sm._place_ice(Vector2i(15, 15), "water", 0.4)
	var ice_text: String = sm.hazard_tooltip_text(tile_pos.call(Vector2i(15, 15)))
	_check("ice: slippery, frozen water, fire thaws", ice_text.contains("Slippery") and ice_text.contains("frozen water") and ice_text.contains("Fire thaws it"), ice_text)
	_check("plain ground: nothing", sm.hazard_tooltip_text(tile_pos.call(Vector2i(17, 3))) == "")

	await _case_preview(game, sm, fm)
	get_tree().current_scene = harness_scene
	game.queue_free()
	await _frames(1)

func _case_preview(game, sm, fm) -> void:
	# A puddle at tiles (0..2, 0); an enemy on (0,0) inside a circle aimed at the
	# origin (the headless mouse); a party member on (2,0), outside the circle
	# but in the same water; the caster far away.
	sm.electrified_grid.clear()
	var puddle: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)]
	for t in puddle:
		fm.fluid_grid[t] = {"water": 0.5}
	var CS := _script(STUB_CHAR_SRC)
	var enemy = CS.new()
	enemy.position = Vector2(32, 32)
	var friend = CS.new()
	friend.position = Vector2(160, 32)
	var caster = CS.new()
	caster.position = Vector2(900, 900)
	for c in [enemy, friend, caster]:
		game.add_child(c)
	game.characters_in_scene = [enemy, friend, caster]
	game.party_chars = [friend, caster]
	var targeting = load("res://Abilities/AbilityTargeting.gd").new()
	caster.add_child(targeting)
	await _frames(1)
	var preview = targeting.get_node_or_null("ElectrifyPreview")
	_check("preview is a child of AbilityTargeting", preview != null)
	if preview == null:
		return
	var bolt := {"display_name": "Test Bolt", "target_shape": "circle", "radius": 60.0, "requires_targeting": true,
		"effects": [{"type": "damage", "damage": {"lightning": 10}}]}
	targeting.start_targeting("Main", bolt, Vector2.ZERO)
	# Hold the reticle on the origin whatever the headless mouse reports.
	targeting.target_position = Vector2.ZERO
	targeting.circle_indicator.global_position = Vector2.ZERO
	await _frames(2)
	targeting.circle_indicator.global_position = Vector2.ZERO
	preview._recompute(targeting)
	print("preview tiles ", preview._tiles, " rings ", preview._rings, " reticle ", targeting.circle_indicator.global_position)
	_check("preview floods the puddle", _same(preview._tiles, puddle), preview._tiles)
	var party_ring := false
	var enemy_ring := false
	for r in preview._rings:
		if r["pos"] == friend.global_position and r["party"]:
			party_ring = true
		if r["pos"] == enemy.global_position and not r["party"]:
			enemy_ring = true
	_check("party member in the flood gets the warning ring", party_ring, preview._rings)
	_check("enemy in the flood ringed", enemy_ring, preview._rings)
	_check("label sits above the reticle (clear of the hover tooltip)", preview._label_pos.y < targeting.target_position.y, preview._label_pos)
	# The preview and the real flood agree.
	var real: int = sm.try_electrify(GridManager.world_to_map(enemy.global_position))
	_check("casting electrifies exactly the previewed tiles", real == puddle.size() and _same(sm.electrified_grid.keys(), preview._tiles))
	targeting.end_targeting()
	await _frames(1)
	_check("preview clears when targeting ends", preview._tiles.is_empty() and not preview._shown)
	var fire := {"display_name": "Test Fire", "target_shape": "circle", "radius": 60.0, "requires_targeting": true,
		"effects": [{"type": "damage", "damage": {"fire": 10}}]}
	targeting.start_targeting("Main", fire, Vector2.ZERO)
	await _frames(2)
	_check("no preview for non-electric abilities", preview._tiles.is_empty())
	targeting.end_targeting()
	for c in [enemy, friend, caster]:
		c.queue_free()

func _same(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for x in a:
		if not b.has(x):
			return false
	return true

# ---------------------------------------------------------------------------

func _case_game() -> void:
	var game = load("res://game.tscn").instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _frames(2)
	game.load_map("town_square")
	await _frames(10)
	var tip = game.world_tooltip
	_check("hazards provider registered, paused only", tip._providers.has("hazards") and tip._providers["hazards"].paused_only)

	# A grassy patch well away from everyone.
	var spot: Vector2 = game.party_chars[0].global_position + Vector2(-4000, -4000)
	spot = GridManager.map_to_world(GridManager.world_to_map(spot))   # a tile centre
	_check("grassy patch placed", game.surface_manager.place_surface_in_area("grassy", spot, 10.0) > 0)
	var was_paused: bool = PauseManager.is_paused
	var explore_was: bool = ExplorationManager.active
	ExplorationManager.active = false
	PauseManager.is_paused = false
	_check("unpaused: no hazard hover", not tip._query(spot).contains("Grassy"), tip._query(spot))
	PauseManager.is_paused = true
	var paused_text: String = tip._query(spot)
	_check("paused: hazard hover names it", paused_text.contains("Grassy") and paused_text.contains("Verdant"), paused_text)
	ExplorationManager.active = true
	if not ExplorationManager.is_explored(GridManager.world_to_map(spot)):
		_check("unexplored ground: no hazard hover", not tip._query(spot).contains("Grassy"), tip._query(spot))
	ExplorationManager.active = explore_was
	game.current_map_data["is_world_map"] = true
	ExplorationManager.active = false
	_check("world map: no hazard hover", not tip._query(spot).contains("Grassy"))
	ExplorationManager.active = explore_was
	game.current_map_data.erase("is_world_map")

	# Cell-graph fire: burning, then burnt out (it can't catch again).
	var sm = game.surface_manager
	if sm._cell_fire_active():
		var cf = sm.cell_fire
		var fire_spot: Vector2 = game.party_chars[0].global_position + Vector2(96, 0)
		var cid: int = cf.graph.cell_at(fire_spot)
		if cid >= 0:
			cf.burning[cid] = {"t": 5.0, "t0": 5.0, "seed": 0.0, "char": 0.0, "vfx": null}
			_check("cell fire: is_burning_at", cf.is_burning_at(fire_spot))
			var fire_text: String = sm.hazard_tooltip_text(fire_spot)
			_check("cell fire text: Burning + spread rule", fire_text.contains("[b]Fire[/b]") and fire_text.contains("Applies [b]Burning[/b] every 1 s") and fire_text.contains("Spreads to flammable ground"), fire_text)
			cf.burning.erase(cid)
			cf.burnt[cid] = 1
			_check("cell fire: is_burnt_at", cf.is_burnt_at(fire_spot) and not cf.is_burning_at(fire_spot))
			_check("burnt ground: won't catch again", sm.hazard_tooltip_text(fire_spot).contains("Burnt out"), sm.hazard_tooltip_text(fire_spot))
			cf.burnt[cid] = 0
		else:
			print("SKIP cell fire (no cell under the probe)")
	else:
		print("SKIP cell fire (no cell graph on this map)")
	ExplorationManager.active = explore_was
	PauseManager.is_paused = was_paused

	# Wind widget on the HUD strip.
	var wind = game.hud_status.get_node_or_null("WindIndicator")
	_check("wind indicator on hud_status", wind != null)
	if wind == null:
		return
	_check("wind keeps its tooltip (PASS)", wind.mouse_filter == Control.MOUSE_FILTER_PASS)
	var grp := str(game.current_map_data.get("weather_group", ""))
	_check("wind shown only with weather", wind.visible == (grp != "" and not WeatherManager.get_weather(grp).is_empty()), [grp, wind.visible])
	var d: String = wind.describe(52.0, Vector2(1, 1))
	_check("wind tooltip: strength, compass, fire", d.contains("Strong") and d.contains("toward the SE") and d.contains("twice as fast downwind"), d)
	_check("calm tooltip", wind.describe(1.0, Vector2.RIGHT).contains("evenly"))
	# The widget is as wide as its longest text, so a widget appended after it
	# in the strip doesn't sit on "Moderate wind toward NW".
	var wgrp: String = WeatherManager.current_weather.keys()[0] if not WeatherManager.current_weather.is_empty() else ""
	if wgrp == "":
		print("SKIP wind label (no weather group rolled)")
		return
	var had_group: bool = game.current_map_data.has("weather_group")
	var old_group = game.current_map_data.get("weather_group")
	var old_speed: float = WeatherManager.get_wind_speed(wgrp)
	var old_angle: float = WeatherManager.get_wind_angle(wgrp)
	game.current_map_data["weather_group"] = wgrp
	WeatherManager.set_wind_speed(wgrp, 25.0)
	WeatherManager.set_wind_angle(wgrp, 225.0)
	wind.refresh()
	await _frames(2)
	var lbl: Label = wind._label
	_check("wind label reads the wind", wind.visible and lbl.text == "Moderate wind toward NW", lbl.text)
	_check("wind widget covers its label", wind.size.x >= lbl.position.x + lbl.size.x, [wind.size, lbl.position, lbl.size])
	# Fire under that wind says which way it is pushed.
	var fire_note: String = game.surface_manager._wind_note()
	_check("fire note follows the wind", fire_note.contains("toward the NW"), fire_note)
	game.current_map_data["is_world_map"] = true
	wind.refresh()
	_check("wind hidden on the world map", not wind.visible)
	game.current_map_data.erase("is_world_map")
	WeatherManager.set_wind_speed(wgrp, old_speed)
	WeatherManager.set_wind_angle(wgrp, old_angle)
	if had_group:
		game.current_map_data["weather_group"] = old_group
	else:
		game.current_map_data.erase("weather_group")
	wind.refresh()
