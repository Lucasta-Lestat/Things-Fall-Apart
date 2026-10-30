extends Node2D
# Fire-spread performance bench. Loads a real structured map through MapLoader
# (real walls with fire footprints), stands up SurfaceManager + FluidManager +
# FogManager like Game does, lights a few big patches and then drives the cell
# fire for TFA_SECS of fixed-step sim, timing every CellFire phase separately
# (the tick body is replicated 1:1 so each phase can be stopwatched) plus the
# hazard-map rebuild and the FX redraw. Prints one line per simulated second.
# Headless:  godot --headless --path . res://tests/fire_perf_bench.tscn
# Windowed (real render cost, FPS):  godot --path . res://tests/fire_perf_bench.tscn
# Env: TFA_MAP (default tg_castle_keep), TFA_SECS (default 40), TFA_FX=0 to
#      disable the CellFireFX redraw, TFA_CHARS (default 12 idle characters),
#      TFA_SHOT=<png path> + TFA_SHOT_T=<sim second> to screenshot the first
#      patch (windowed only; a path inside the project goes to user://shots:
#      tests/shot_dir.gd), TFA_CAM_ZOOM (default 0.5). The fire RNG is
#      seeded, so two runs light and burn the same cells.
const MAP_LOADER := preload("res://Structures/MapLoader.gd")
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const ShotDir := preload("res://tests/shot_dir.gd")

var structures_in_scene: Array = []
var characters_in_scene: Array = []
var items_in_scene: Array = []
var party_chars: Array = []
var unlocked_locks: Dictionary = {}
var map_loader: Node2D = null
var surface_manager: SurfaceManager = null
var fluid_manager: FluidManager = null
var fog_manager: FogManager = null
var current_map_data: Dictionary = {}
var context_menu_open := false
var primary_selected = null

var _cf: CellFire = null
var _graph: CellGraph = null
var _secs := 40.0
var _t := 0.0
var _frames := 0
var _acc: Dictionary = {}
var _proc_acc := 0.0
var _hz_timer := 0.0
var _hz_cd := 0.0
var _hz_rev := -1
var _peak_burning := 0
var _worst_frame_ms := 0.0
var _spread_timer := 0.0
var _damage_timer := 0.0
var _rows: Array = []
var _wall0 := 0
var _shot_done := false
var _cam: Camera2D = null


func load_map(_a = null, _b = "", _c = "") -> void:
	pass   # SurfaceManager._get_game keys on this method name


func _on_structure_destroyed(structure, _world_pos: Vector2) -> void:
	structures_in_scene.erase(structure)
	if _cf != null:
		_cf.invalidate_fuel()
	if fluid_manager and fluid_manager.cell_fluid:
		fluid_manager.cell_fluid.invalidate_edges()


func _ready() -> void:
	add_to_group("game")
	var f := FileAccess.open("res://data/Maps.json", FileAccess.READ)
	var raw: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	var want := OS.get_environment("TFA_MAP")
	if want == "":
		want = "tg_castle_keep"
	if OS.get_environment("TFA_SECS") != "":
		_secs = float(OS.get_environment("TFA_SECS"))
	var m: Dictionary = {}
	for e in raw.get("maps", []):
		if String(e.get("id", "")) == want:
			m = e
			break
	current_map_data = m
	GridManager.TILE_SIZE = int(m.get("tile_size", 64))
	var ws: Array = m.get("world_size", [2048, 2048])
	GridManager.initialize(int(ws[0]), int(ws[1]))
	_graph = CellGraph.from_structured(String(m.get("cell_graph", "")))
	GridManager.set_elevation_data(_graph)
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	ml.generate_structured_map(m)
	map_loader = ml

	fog_manager = FogManager.new()
	add_child(fog_manager)
	fluid_manager = FluidManager.new()
	add_child(fluid_manager)
	fluid_manager.setup_cell_graph(_graph)
	surface_manager = SurfaceManager.new()
	add_child(surface_manager)
	surface_manager.setup_cell_graph(_graph)
	_cf = surface_manager.cell_fire
	if OS.get_environment("TFA_FX") == "0" and surface_manager.cell_fire_fx:
		surface_manager.cell_fire_fx.set_process(false)

	var nchars := 12
	if OS.get_environment("TFA_CHARS") != "":
		nchars = int(OS.get_environment("TFA_CHARS"))
	for i in nchars:
		var c: ProceduralCharacter = CHAR_SCENE.instantiate()
		c.is_player_controlled = true
		c.AI_enabled = false
		add_child(c)
		c.game = self
		c.global_position = Vector2(float(ws[0]) * (0.2 + 0.6 * float(i) / float(maxi(nchars - 1, 1))),
			float(ws[1]) * 0.5)
		characters_in_scene.append(c)

	_cam = Camera2D.new()
	_cam.position = Vector2(float(ws[0]) * 0.5, float(ws[1]) * 0.5)
	var zm := 0.5
	if OS.get_environment("TFA_CAM_ZOOM") != "":
		zm = float(OS.get_environment("TFA_CAM_ZOOM"))
	_cam.zoom = Vector2(zm, zm)
	add_child(_cam)
	_cam.make_current()
	_cf._rng.seed = 12345

	# light three fuelled patches spread over the map
	var lit := 0
	var sites: Array[Vector2] = []
	for cid in _graph.cell_count:
		if _graph.ground_fuel(cid) <= 0.0:
			continue
		var p := _graph.centroid(cid)
		var far := true
		for s in sites:
			if s.distance_to(p) < 900.0:
				far = false
				break
		if far:
			sites.append(p)
		if sites.size() >= 3:
			break
	for s in sites:
		lit += _cf.ignite_area(s, 220.0)
	if OS.get_environment("TFA_SHOT") != "" and not sites.is_empty():
		_cam.position = sites[0]
	var fire_tiles := 0
	for st in structures_in_scene:
		fire_tiles += surface_manager._fire_tiles_of(st).size()
	print("bench map=%s cells=%d structures=%d fire_tiles=%d chars=%d lit=%d fx=%s" % [
		want, _graph.cell_count, structures_in_scene.size(), fire_tiles, nchars, lit,
		"off" if OS.get_environment("TFA_FX") == "0" else "on"])
	for k in ["spread", "damage", "melt", "lifetime", "apply", "smoke", "hazard", "fluid"]:
		_acc[k] = 0


func _stamp(key: String, t0: int) -> void:
	_acc[key] = int(_acc[key]) + (Time.get_ticks_usec() - t0)


func _process(_real_delta: float) -> void:
	var delta := 1.0 / 60.0
	var f0 := Time.get_ticks_usec()
	# --- FluidManager.update_fluid_tick (cell sim + 0.25s tile projection) ---
	var t0 := Time.get_ticks_usec()
	fluid_manager.update_fluid_tick(delta)
	_stamp("fluid", t0)
	# --- CellFire.tick replicated 1:1 with a stopwatch on every phase ---
	_cf.sim_time += delta   # CellFire.tick advances this; the phases are called directly here
	if _cf.active() and not _cf.burning.is_empty():
		_spread_timer += delta
		if _spread_timer >= float(_cf._fire_def.get("spread_interval", 2.0)):
			_spread_timer = 0.0
			t0 = Time.get_ticks_usec()
			_cf._spread(self)
			_stamp("spread", t0)
		_damage_timer += delta
		if _damage_timer >= float(_cf._fire_def.get("damage_interval", 1.0)):
			_damage_timer = 0.0
			t0 = Time.get_ticks_usec()
			_cf._damage(self)
			_stamp("damage", t0)
			t0 = Time.get_ticks_usec()
			_cf._melt_ice()
			_stamp("melt", t0)
		t0 = Time.get_ticks_usec()
		_cf._lifetime(delta)
		_stamp("lifetime", t0)
		t0 = Time.get_ticks_usec()
		_cf._apply_burning(delta, characters_in_scene)
		_stamp("apply", t0)
		t0 = Time.get_ticks_usec()
		_cf._smoke(delta, self)
		_stamp("smoke", t0)
	# --- SurfaceManager hazard-map throttle, replicated ---
	_hz_timer -= delta
	_hz_cd -= delta
	var rev: int = _cf.burn_rev
	if (_hz_timer <= 0.0 or rev != _hz_rev) and _hz_cd <= 0.0:
		_hz_timer = SurfaceManager.HAZARD_REBUILD_INTERVAL
		_hz_cd = SurfaceManager.HAZARD_MIN_SPACING
		_hz_rev = rev
		t0 = Time.get_ticks_usec()
		surface_manager._rebuild_hazard_map(self)
		_stamp("hazard", t0)
	var fms := float(Time.get_ticks_usec() - f0) / 1000.0
	_worst_frame_ms = maxf(_worst_frame_ms, fms)
	_peak_burning = maxi(_peak_burning, _cf.burning.size())
	_frames += 1
	_t += delta
	# whole-engine process time (includes the FX _draw callbacks and every
	# node's _process) as the engine measured it last frame
	_proc_acc += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	if _frames % 60 == 0:
		var wall_ms := float(Time.get_ticks_msec() - _wall0) / 60.0
		_wall0 = Time.get_ticks_msec()
		var row := "t=%2d burning=%4d tileidx=%5d | ms/s: spread=%.1f damage=%.1f melt=%.1f life=%.1f apply=%.1f smoke=%.1f hazard=%.1f fluid=%.1f | engine process ms/frame=%.2f wall ms/frame=%.1f worst sim frame=%.1fms fps=%d" % [
			int(_t), _cf.burning.size(), _cf._tile_index.size(),
			float(_acc["spread"]) / 1000.0, float(_acc["damage"]) / 1000.0,
			float(_acc["melt"]) / 1000.0, float(_acc["lifetime"]) / 1000.0,
			float(_acc["apply"]) / 1000.0, float(_acc["smoke"]) / 1000.0,
			float(_acc["hazard"]) / 1000.0, float(_acc["fluid"]) / 1000.0,
			_proc_acc / 60.0, wall_ms, _worst_frame_ms, Engine.get_frames_per_second()]
		print(row)
		for k in _acc:
			_acc[k] = 0
		_proc_acc = 0.0
		_worst_frame_ms = 0.0
	if not _shot_done and OS.get_environment("TFA_SHOT") != "" 			and _t >= float(OS.get_environment("TFA_SHOT_T") if OS.get_environment("TFA_SHOT_T") != "" else "6"):
		_shot_done = true
		_take_shot(OS.get_environment("TFA_SHOT"))
	if _t >= _secs:
		print("bench done: peak burning=%d structures left=%d" % [_peak_burning, structures_in_scene.size()])
		get_tree().quit(0)


func _take_shot(want: String) -> void:
	var path := ShotDir.file(want, "fire_perf_bench.png")
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("bench shot saved: " + path)
