extends Node2D
# FluidWell: the over-time ground emitter behind Oil Well.
#
# The load-bearing promises are (a) it floods the disc the targeting ring drew and
# nothing outside it, (b) it grows outward rather than appearing whole, (c) it
# tops up to a target depth instead of accumulating without bound -- legacy oil
# never evaporates, so an unbounded well would bleed across the map for the rest
# of the session -- (d) it expires on its duration, and (e) a tactical pause
# freezes it instead of letting it burn its six seconds against a frozen sim.
# Headless-safe.  Run:  godot --headless --path . res://tests/fluid_well_check.tscn

const FLUID_MANAGER := preload("res://FluidManager.gd")

var fails := 0
var checks := 0


# AbilityEffect._get_game_scene duck-types the game scene by these two methods.
# Answering to them is what lets resolve_effect parent the well under this test.
func create_item(_a = null, _b = null, _c = null) -> Node:
	return null


func _spawn_character(_a = null, _b = null, _c = null) -> Node:
	return null


func _check(cname: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if not ok:
		fails += 1
	print("%s %s %s" % ["PASS" if ok else "FAIL", cname, detail])


# Drive the well by hand rather than waiting on wall-clock frames: _process is
# the only clock it has, and a headless run has no stable frame rate to lean on.
func _pump(well: FluidWell, seconds: float, step: float = 0.05) -> void:
	var elapsed: float = 0.0
	while elapsed < seconds and is_instance_valid(well):
		well._process(step)
		elapsed += step


func _wet_tiles(fm: Node) -> int:
	var n: int = 0
	for tile in fm.fluid_grid.keys():
		if float(fm.get_fluid_amount(tile, "oil")) >= fm.PUDDLE_HEIGHT:
			n += 1
	return n


func _max_depth(fm: Node) -> float:
	var m: float = 0.0
	for tile in fm.fluid_grid.keys():
		m = maxf(m, float(fm.get_fluid_amount(tile, "oil")))
	return m


func _ready() -> void:
	await get_tree().process_frame

	# A bare legacy-tile FluidManager: no CellFluid, so the well takes the
	# per-tile path. Structured maps route through CellFluid.deposit instead and
	# are exercised in-game, not here.
	var fm = FLUID_MANAGER.new()
	fm.name = "FluidManager"
	add_child(fm)
	await get_tree().process_frame

	GridManager.TILE_SIZE = 64
	GridManager.walls.clear()

	var center := Vector2(1000, 1000)
	var radius := 192.0

	# --- wall exclusion: one tile inside the disc is masonry ------------------
	var walled_tile: Vector2i = GridManager.world_to_map(center) + Vector2i(1, 0)
	GridManager.walls[walled_tile] = true

	var well := FluidWell.new()
	well.fluid_type = "oil"
	well.radius = radius
	well.duration = 6.0
	well.visual_scene_path = ""       # VFX is eyeballed in-game, not asserted here
	add_child(well)
	well.global_position = center

	# --- it starts dry --------------------------------------------------------
	_check("well.starts-dry", _wet_tiles(fm) == 0, "%d wet tiles" % _wet_tiles(fm))

	# --- it grows outward, it does not appear whole ---------------------------
	_pump(well, 0.6)
	var early: int = _wet_tiles(fm)
	_check("well.emits-early", early > 0, "%d wet tiles at t=0.6" % early)

	_pump(well, 1.4)
	var mid: int = _wet_tiles(fm)
	_check("well.grows-outward", mid > early, "%d -> %d wet tiles by t=2.0" % [early, mid])

	# --- it fills the whole disc by the end of the grow phase -----------------
	_pump(well, 2.4)
	var full: int = _wet_tiles(fm)
	# radius 192 / TILE_SIZE 64 = a 3-tile radius disc: 29 tiles cast dead on a
	# tile centre, a little either side depending where in its tile the cursor
	# fell -- i.e. the 6-cell diameter the spell advertises. Minus the wall.
	_check("well.fills-disc", full >= 20 and full <= 40, "%d wet tiles at t=4.4" % full)

	# --- nothing outside the ring the player saw ------------------------------
	var outside: int = 0
	var worst: float = 0.0
	for tile in fm.fluid_grid.keys():
		if float(fm.get_fluid_amount(tile, "oil")) < fm.PUDDLE_HEIGHT:
			continue
		var d: float = center.distance_to(GridManager.map_to_world(tile))
		if d > radius:
			outside += 1
			worst = maxf(worst, d)
	_check("well.respects-radius", outside == 0, "%d tiles beyond r=%d (worst %.0f)" % [outside, int(radius), worst])

	# --- masonry stays dry ----------------------------------------------------
	_check(
		"well.skips-walls",
		float(fm.get_fluid_amount(walled_tile, "oil")) <= 0.0,
		"walled tile depth %.3f" % float(fm.get_fluid_amount(walled_tile, "oil"))
	)

	# --- it tops up, it does not pile up --------------------------------------
	# The whole point of the deficit deposit: after four seconds of ticking, no
	# tile may hold appreciably more than the target depth.
	var deepest: float = _max_depth(fm)
	_check(
		"well.tops-up-not-piles-up",
		deepest <= FluidWell.TILE_TARGET_DEPTH * 1.5,
		"deepest %.3f vs target %.3f" % [deepest, FluidWell.TILE_TARGET_DEPTH]
	)

	# --- a pause freezes it ---------------------------------------------------
	var before_pause: int = _wet_tiles(fm)
	var age_before: float = well._age
	PauseManager.is_paused = true
	_pump(well, 3.0)
	PauseManager.is_paused = false
	_check(
		"well.pause-freezes-clock",
		is_equal_approx(well._age, age_before),
		"age %.2f -> %.2f across a 3s pause" % [age_before, well._age]
	)
	_check(
		"well.pause-freezes-emission",
		_wet_tiles(fm) == before_pause,
		"%d -> %d wet tiles across a 3s pause" % [before_pause, _wet_tiles(fm)]
	)

	# --- it expires on its duration -------------------------------------------
	_pump(well, 2.0)
	await get_tree().process_frame
	await get_tree().process_frame
	_check("well.expires", not is_instance_valid(well), "freed at duration 6.0")

	# --- end to end: the authored JSON payload through the real dispatcher -----
	# Everything above builds a FluidWell by hand. This proves the data entry and
	# the "fluid_well" match arm actually reach it.
	var af := FileAccess.open("res://data/Abilities.json", FileAccess.READ)
	var js := JSON.new()
	var authored: Dictionary = {}
	if af != null and js.parse(af.get_as_text()) == OK:
		for entry in js.get_data().get("abilities", []):
			if entry is Dictionary and String(entry.get("id", "")) == "oil_well":
				authored = entry
	_check("data.oil_well-present", not authored.is_empty(), "found in Abilities.json")

	var payload: Dictionary = {}
	if not authored.is_empty():
		payload = authored["effects"][0]
	_check(
		"data.effect-is-fluid_well",
		String(payload.get("type", "")) == "fluid_well",
		"type=%s fluid=%s r=%s dur=%s" % [
			payload.get("type", ""), payload.get("fluid_type", ""),
			payload.get("radius", ""), payload.get("duration", "")
		]
	)

	var far := Vector2(4000, 4000)
	var res: Dictionary = AbilityEffect.resolve_effect(payload, self, [], null, far)
	_check("dispatch.resolves", bool(res.get("success", false)), String(res.get("error", "")))
	var made: Array = res.get("created_objects", [])
	var spawned: FluidWell = made[0] if made.size() > 0 and made[0] is FluidWell else null
	_check("dispatch.creates-well", spawned != null, "%d objects" % made.size())
	if spawned != null:
		_check(
			"dispatch.carries-payload",
			spawned.fluid_type == "oil" and is_equal_approx(spawned.duration, 6.0),
			"fluid=%s duration=%.1f radius=%.0f" % [spawned.fluid_type, spawned.duration, spawned.radius]
		)
		# Positioned AFTER parenting, so the well must have landed on the target.
		_check(
			"dispatch.positions-well",
			spawned.global_position.distance_to(far) < 1.0,
			"at %s, wanted %s" % [spawned.global_position, far]
		)
		spawned.queue_free()

	# --- the authored asset paths actually resolve ----------------------------
	# Ability.from_dict guards the icon with ResourceLoader.exists() and silently
	# leaves it null on a miss, and FluidWell does the same for its vfx_scene, so
	# a typo in any of these is invisible at runtime. Pin them.
	for key in ["icon"]:
		var path: String = String(authored.get(key, ""))
		_check("asset.%s" % key, ResourceLoader.exists(path), path)
	for path2 in [
		String(payload.get("vfx_scene", "")),
		String(authored.get("visuals", {}).get("in_hand_effect", "")),
		String(authored.get("visuals", {}).get("sound_cast", "")),
	]:
		_check("asset.exists", ResourceLoader.exists(path2), path2)
	# The in-hand scene must have a Node2D root or AbilityShape push_warns and
	# skips it; the gusher must answer play_well or FluidWell falls back to the
	# generic radius guess.
	var hand_scene = load(String(authored.get("visuals", {}).get("in_hand_effect", "")))
	var hand_inst = hand_scene.instantiate() if hand_scene != null else null
	_check("vfx.hand-is-node2d", hand_inst is Node2D, str(hand_inst))
	if hand_inst != null:
		hand_inst.queue_free()
	var gush_scene = load(String(payload.get("vfx_scene", "")))
	var gush_inst = gush_scene.instantiate() if gush_scene != null else null
	_check(
		"vfx.gusher-has-play_well",
		gush_inst is Node2D and gush_inst.has_method("play_well"),
		str(gush_inst)
	)
	if gush_inst != null:
		gush_inst.queue_free()

	print("fluid_well_check: %d checks, %d failures" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)
