extends Node
# Map-light census + frame-time bench (TG export contract P2-C / P2-D). Boots
# the real game (game.tscn) and loads TFA_MAP, waits for the map, then sorts
# every PointLight2D in the tree by kind:
#   prop   EmittedLight of a placed item (brazier, campfire, torch: Items.json
#          emits_light), by item id
#   map    MapLoader's MapLights (a contract-2 row's "lights")
#   decor  RunRenderer's DecorLight* (lit run decor: the contract-2 candle)
#   sight  the party / NPC sight cones (LineOfSight, NPCLineOfSight[High])
#   worn / held / fire / other
# "lane" lights = prop + map + decor: what P2-C / P2-D added.
#
# TFA_BENCH=count (default, headless-safe): one LIGHTS line per map
#   (total, shadowed, visible) and a per-kind / per-item breakdown.
# TFA_BENCH=time (WINDOWED only: the headless renderer is a dummy): a 64x64
#   off-screen window whose root viewport renders at 1280x720
#   (content_scale_mode VIEWPORT), vsync off, uncapped. Phases of TFA_SECS
#   (default 10) each, after a 1 s settle:
#   game_on / game_off   the game's own camera on the party, lane lights as the
#                        game shows them / all disabled;
#   worst_on / worst_noshadow / worst_off / worst_on2   the camera parked over
#                        the densest cluster of lane lights, every lane light
#                        in view cloned force-visible (the game hides an item's
#                        light with the item when the party cannot see it),
#                        with their shadows / shadows off / disabled / again
#                        (drift check).
#   Per phase: frames, mean / median / p95 frame ms (process delta) and the
#   root viewport's measured GPU and CPU render ms. Read the GPU ms: on the
#   2026-10-30 D3D12 machine the off-screen window's frames stayed pinned near
#   10 ms whatever the load, so frame ms only shows hitches.
# The game boots on TFA_BOOT_MAP (default combat_test) and then loads TFA_MAP
# like a warp: a boot straight into TFA_MAP wipes its authored items (the
# first load_map captures the launch map's empty item state, then restores it).
# Env: TFA_MAP (default tg_hillside_lower); TFA_ROWS = a Maps.json whose row
#   for TFA_MAP replaces the shipped one (e.g. a TG contract-2 export; JSON
#   only, its images are the shipped PNGs); TFA_SECS; TFA_CAM_ZOOM (default 1;
#   the game's camera zooms out to 0.5); TFA_BOOT_MAP.
# Run:  godot --headless --path . res://tests/map_lights_bench.tscn
#       TFA_BENCH=time godot --path . --resolution 64x64 --position -20000,-20000 res://tests/map_lights_bench.tscn


func _ready() -> void:
	var map_id := OS.get_environment("TFA_MAP").strip_edges()
	if map_id == "":
		map_id = "tg_hillside_lower"
	var rows_path := OS.get_environment("TFA_ROWS").strip_edges()
	if rows_path != "":
		var f := FileAccess.open(rows_path, FileAccess.READ)
		if f == null:
			push_error("map_lights_bench: cannot read TFA_ROWS %s" % rows_path)
			get_tree().quit(2)
			return
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		var found := false
		if parsed is Dictionary:
			for e in (parsed as Dictionary).get("maps", []):
				if e is Dictionary and String((e as Dictionary).get("id", "")) == map_id:
					MapDatabase._maps[map_id] = e
					found = true
		if not found:
			push_error("map_lights_bench: %s has no row %s" % [rows_path, map_id])
			get_tree().quit(2)
			return
		var row: Dictionary = MapDatabase._maps[map_id]
		var lights: Array = row.get("lights", [])
		print("map_lights_bench: row %s from %s (export_contract %s, %d lights)" % [map_id, rows_path,
			str(row.get("export_contract", 1)), lights.size()])
	# Boot on another map, then load TFA_MAP like a warp: booting straight into
	# it captures that map's (still empty) item state on the first load_map
	# (current_map_id starts as the launch map) and _restore_item_state then
	# drops every authored item spawn.
	var boot := OS.get_environment("TFA_BOOT_MAP").strip_edges()
	if boot == "":
		boot = "combat_test" if map_id != "combat_test" else "cemetery"
	OS.set_environment("TFA_START_MAP", boot)
	Globals.skip_character_creation = true
	var d := Driver.new()
	d.name = "MapLightsBenchDriver"
	d.map_id = map_id
	d.timing = OS.get_environment("TFA_BENCH").strip_edges() == "time"
	var secs := OS.get_environment("TFA_SECS").strip_edges()
	d.secs = float(secs) if secs.is_valid_float() else 10.0
	var z := OS.get_environment("TFA_CAM_ZOOM").strip_edges()
	d.cam_zoom = float(z) if z.is_valid_float() else 1.0
	get_tree().root.add_child.call_deferred(d)
	get_tree().change_scene_to_file.call_deferred("res://game.tscn")


class Driver:
	extends Node
	const VIEW := Vector2i(1280, 720)
	const SETTLE_S := 1.0
	const LANE_KINDS := ["prop", "map", "decor"]
	var map_id := ""
	var timing := false
	var secs := 10.0
	var cam_zoom := 1.0
	var _state := "wait"
	var _t := 0.0
	var _frames_after_load := 0
	var _warped := false
	var _phases: Array = []
	var _phase_i := -1
	var _samples: Array = []    # [frame ms, gpu ms, cpu ms]
	var _lane: Array = []       # the game's lane lights (PointLight2D)
	var _clones: Array = []
	var _clone_shadow: Array = []
	var _clone_root: Node2D = null
	var _vp_rid: RID

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		if timing:
			var w := get_window()
			w.borderless = true
			w.unfocusable = true
			w.size = Vector2i(64, 64)
			w.position = Vector2i(-20000, -20000)
			w.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
			w.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
			w.content_scale_size = VIEW
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
			Engine.max_fps = 0
			_vp_rid = get_tree().root.get_viewport_rid()
			RenderingServer.viewport_set_measure_render_time(_vp_rid, true)

	func _game() -> Node:
		var g: Node = get_tree().current_scene
		if g == null or not ("current_map_data" in g):
			return null
		return g

	func _process(delta: float) -> void:
		var g := _game()
		if _state == "wait":
			var md: Dictionary = {}
			if g != null:
				md = g.get("current_map_data")
			if md.is_empty():
				_t += delta
				if _t > 120.0:
					push_error("map_lights_bench: map %s never loaded" % map_id)
					get_tree().quit(1)
				return
			if String(g.get("current_map_id")) != map_id:
				if not _warped:
					_warped = true
					g.call("load_map", map_id)
				return
			_frames_after_load += 1
			if _frames_after_load < 90:   # item spawns, run renderers, sight cones
				return
			_lane = _census(g)
			if not timing:
				print("MAP LIGHTS BENCH DONE")
				get_tree().quit(0)
				return
			_start_timing(g)
		elif _state == "time":
			_tick_timing(g, delta)

	# --- census ---------------------------------------------------------------
	func _kind(l: PointLight2D) -> String:
		var n := String(l.name)
		if n in ["LineOfSight", "NPCLineOfSight", "NPCLineOfSightHigh"]:
			return "sight"
		if n == "WornLight":
			return "worn"
		if n.begins_with("DecorLight"):
			return "decor"
		var par := l.get_parent()
		if par != null and String(par.name) == "MapLights":
			return "map"
		if n == "EmittedLight":
			var a: Node = par
			while a != null:
				if a is ProceduralCharacter:
					return "held"
				a = a.get_parent()
			if par != null and "id" in par:
				return "prop"
		if par != null and par.get_script() != null and String((par.get_script() as Script).resource_path).ends_with("CellFireFX.gd"):
			return "fire"
		return "other"

	func _census(g: Node) -> Array:
		var all: Array = []
		_collect(get_tree().root, all)
		var by_kind: Dictionary = {}
		var props: Dictionary = {}
		var lane: Array = []
		var tot := 0
		var tot_sh := 0
		var tot_vis := 0
		var lane_sh := 0
		var lane_vis := 0
		var lane_vis_sh := 0
		for lv in all:
			var l: PointLight2D = lv
			var k := _kind(l)
			var row: Array = by_kind.get(k, [0, 0, 0])
			var sh := l.enabled and l.shadow_enabled
			var vis := l.enabled and l.is_visible_in_tree()
			row[0] = int(row[0]) + 1
			row[1] = int(row[1]) + (1 if sh else 0)
			row[2] = int(row[2]) + (1 if vis else 0)
			by_kind[k] = row
			tot += 1
			tot_sh += 1 if sh else 0
			tot_vis += 1 if vis else 0
			if k in LANE_KINDS:
				lane.append(l)
				lane_sh += 1 if sh else 0
				lane_vis += 1 if vis else 0
				lane_vis_sh += 1 if (vis and sh) else 0
			if k == "prop":
				var iid := String(l.get_parent().get("id"))
				var pr: Array = props.get(iid, [0, 0])
				pr[0] = int(pr[0]) + 1
				pr[1] = int(pr[1]) + (1 if sh else 0)
				props[iid] = pr
		var md: Dictionary = g.get("current_map_data")
		print("LIGHTS %s contract=%s total=%d shadowed=%d visible=%d | lane=%d shadowed=%d visible=%d visible_shadowed=%d" % [
			map_id, str(md.get("export_contract", 1)), tot, tot_sh, tot_vis, lane.size(), lane_sh, lane_vis, lane_vis_sh])
		var ks: Array = by_kind.keys()
		ks.sort()
		var parts: Array = []
		for k in ks:
			var r: Array = by_kind[k]
			parts.append("%s=%d(sh %d, vis %d)" % [k, int(r[0]), int(r[1]), int(r[2])])
		print("LIGHTS %s kinds: %s" % [map_id, ", ".join(parts)])
		var ps: Array = []
		for iid in props.keys():
			var pr: Array = props[iid]
			ps.append("%s=%d(sh %d)" % [iid, int(pr[0]), int(pr[1])])
		ps.sort()
		print("LIGHTS %s props: %s" % [map_id, ", ".join(ps)])
		for lv in all:
			if _kind(lv) == "other":
				print("LIGHTS %s other: %s" % [map_id, str((lv as Node).get_path())])
		return lane

	func _collect(n: Node, out: Array) -> void:
		if n is PointLight2D:
			out.append(n)
		for c in n.get_children():
			_collect(c, out)

	# --- timing ----------------------------------------------------------------
	func _start_timing(g: Node) -> void:
		print("map_lights_bench: render size %s, window %s at %s, renderer %s" % [
			str(get_tree().root.get_visible_rect().size), str(get_window().size), str(get_window().position),
			RenderingServer.get_video_adapter_api_version()])
		_phases = ["game_on", "game_off", "worst_on", "worst_noshadow", "worst_off", "worst_on2"]
		_state = "time"
		_next_phase(g)

	func _set_lane(on: bool) -> void:
		for lv in _lane:
			if is_instance_valid(lv):
				(lv as PointLight2D).enabled = on

	func _light_r(l: PointLight2D) -> float:
		return 0.5 * l.texture_scale * float(l.texture.get_width()) if l.texture != null else 0.0

	func _build_worst(g: Node) -> void:
		var cam: Camera2D = g.get("player_camera")
		cam.set("manual_pan_active", true)
		cam.set("target_zoom", Vector2(cam_zoom, cam_zoom))
		cam.zoom = Vector2(cam_zoom, cam_zoom)
		var half := Vector2(VIEW) * 0.5 / cam_zoom
		var live: Array = []
		for lv in _lane:
			if is_instance_valid(lv):
				live.append(lv)
		var best: PointLight2D = null
		var best_n := -1
		for lv in live:
			var c: Vector2 = (lv as PointLight2D).global_position
			var n := _in_view(live, Rect2(c - half, half * 2.0)).size()
			if n > best_n:
				best_n = n
				best = lv
		_clone_root = Node2D.new()
		_clone_root.name = "MapLightsBenchClones"
		g.add_child(_clone_root)
		if best == null:
			print("map_lights_bench: no lane lights; the worst phases measure the bare map")
			return
		var centre: Vector2 = best.global_position
		cam.global_position = centre
		var n_sh := 0
		for lv in _in_view(live, Rect2(centre - half, half * 2.0)):
			var src: PointLight2D = lv
			var cl := src.duplicate() as PointLight2D
			cl.enabled = true
			_clone_root.add_child(cl)
			cl.global_position = src.global_position
			_clones.append(cl)
			_clone_shadow.append(src.shadow_enabled)
			n_sh += 1 if src.shadow_enabled else 0
		_set_lane(false)
		print("map_lights_bench: worst view centre %s zoom %.2f: %d lane lights in view (%d shadowed), clones force-visible" % [
			str(centre), cam_zoom, _clones.size(), n_sh])

	func _in_view(lights: Array, view: Rect2) -> Array:
		var out: Array = []
		for lv in lights:
			var l: PointLight2D = lv
			var r := _light_r(l)
			if view.intersects(Rect2(l.global_position - Vector2(r, r), Vector2(r, r) * 2.0)):
				out.append(l)
		return out

	func _next_phase(g: Node) -> void:
		if _phase_i >= 0:
			_report(String(_phases[_phase_i]))
		_phase_i += 1
		if _phase_i >= _phases.size():
			print("MAP LIGHTS BENCH DONE")
			get_tree().quit(0)
			return
		var ph := String(_phases[_phase_i])
		match ph:
			"game_on":
				_set_lane(true)
			"game_off":
				_set_lane(false)
			"worst_on", "worst_on2":
				if _clone_root == null:
					_build_worst(g)
				for i in _clones.size():
					var c: PointLight2D = _clones[i]
					c.enabled = true
					c.shadow_enabled = bool(_clone_shadow[i])
			"worst_noshadow":
				for cv in _clones:
					(cv as PointLight2D).shadow_enabled = false
			"worst_off":
				for cv in _clones:
					(cv as PointLight2D).enabled = false
		_t = 0.0
		_samples = []

	func _tick_timing(g: Node, delta: float) -> void:
		_t += delta
		if _t < SETTLE_S:
			return
		var gpu: float = RenderingServer.viewport_get_measured_render_time_gpu(_vp_rid)
		var cpu: float = RenderingServer.viewport_get_measured_render_time_cpu(_vp_rid)
		_samples.append([delta * 1000.0, gpu, cpu])
		if _t >= SETTLE_S + secs:
			_next_phase(g)

	func _report(ph: String) -> void:
		var fr: Array = []
		var gsum := 0.0
		var csum := 0.0
		for s in _samples:
			fr.append(float(s[0]))
			gsum += float(s[1])
			csum += float(s[2])
		var n := fr.size()
		if n == 0:
			print("BENCH %s %s: no frames" % [map_id, ph])
			return
		var mean := 0.0
		for v in fr:
			mean += float(v)
		mean /= float(n)
		fr.sort()
		var med: float = fr[n >> 1]
		var p95: float = fr[mini(n - 1, int(float(n) * 0.95))]
		print("BENCH %s %s: frames=%d frame_ms mean=%.3f median=%.3f p95=%.3f gpu_ms=%.3f cpu_render_ms=%.3f" % [
			map_id, ph, n, mean, med, p95, gsum / float(n), csum / float(n)])
