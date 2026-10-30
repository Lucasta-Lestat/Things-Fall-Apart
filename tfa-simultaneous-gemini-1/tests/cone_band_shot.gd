extends Node2D
# Visual QA for the elevation-band sight cones (v1.1): loads a terraced map
# through MapLoader like the game (structure band bits + cliff occluders),
# picks two viewers and saves, per viewer, the cone as v1 drew it (a ground-
# tier cone: shadowed by every wall, cliffs cast nothing) next to the v1.1
# band-mask cone (GROUND | the viewer's band bit). WINDOWED only — the headless renderer is a
# dummy and saves black PNGs.
#   viewer "low":  at the foot of a long cliff, facing it (cliff shadow)
#   viewer "high": on a terrace above lower-terrace walls, facing down
# Env: TFA_MAP (default tg_hillside_middle), TFA_SHOT_DIR (default "."),
# TFA_VIEWERS="x,y,deg;x,y,deg" (world px, degrees) to override the picks,
# TFA_MASKS="1,2" to render raw cone shadow masks instead of v1 / v1.1.
# Run it through its SubViewport mode (the window stays 64x64 and off-screen):
#   godot --path . --resolution 64x64 --position -20000,-20000 res://tests/cone_band_shot_sv.tscn
# Run directly (res://tests/cone_band_shot.tscn), the shots are the window's size.
const MAP_LOADER := preload("res://Structures/MapLoader.gd")
const CONE_RADIUS := 900.0
var structures_in_scene: Array = []
var party_chars: Array = []
var unlocked_locks: Dictionary = {}
var map_loader: Node2D = null

const DIRS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]


func _ready() -> void:
	var f := FileAccess.open("res://data/Maps.json", FileAccess.READ)
	var raw: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	var want := OS.get_environment("TFA_MAP")
	if want == "":
		want = "tg_hillside_middle"
	var m: Dictionary = {}
	for e in raw.get("maps", []):
		if String(e.get("id", "")) == want:
			m = e
			break
	GridManager.TILE_SIZE = int(m.get("tile_size", 64))
	var ws: Array = m.get("world_size", [2048, 2048])
	GridManager.initialize(int(ws[0]), int(ws[1]))
	GridManager.set_elevation_data(CellGraph.from_structured(String(m.get("cell_graph", ""))))
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	ml.generate_structured_map(m)
	map_loader = ml
	var runs: int = ml.cliff_occluders.get_child_count() if ml.cliff_occluders != null else 0
	print("cone_band_shot: %s relief=%s band_base=%d terrain %.2f..%.2f cliff runs=%d" % [want,
		str(GridManager.relief_los), GridManager.cone_band_base, GridManager.terrain_min, GridManager.terrain_max, runs])
	# faint cyan lines where the cliff occluders run (same in both images)
	if ml.cliff_occluders != null:
		for c in ml.cliff_occluders.get_children():
			var poly: PackedVector2Array = (c as LightOccluder2D).occluder.polygon
			var ln := Line2D.new()
			ln.points = poly
			ln.width = 3.0
			ln.default_color = Color(0.3, 0.95, 1.0, 0.55)
			ln.z_index = 110
			ln.light_mask = 0
			add_child(ln)
	var cm := CanvasModulate.new()
	cm.color = Color(0.5, 0.5, 0.55)
	add_child(cm)

	var viewers: Array = []   # [label, pos, angle_rad]
	var env := OS.get_environment("TFA_VIEWERS")
	if env != "":
		var k := 0
		for part in env.split(";", false):
			var xs := part.split(",")
			viewers.append(["v%d" % k, Vector2(float(xs[0]), float(xs[1])), deg_to_rad(float(xs[2]))])
			k += 1
	else:
		var lo: Array = _pick_low_viewer()
		if not lo.is_empty():
			viewers.append(["low"] + lo)
		var hi: Array = _pick_high_viewer()
		if not hi.is_empty():
			viewers.append(["high"] + hi)

	var cam := Camera2D.new()
	add_child(cam)
	cam.make_current()
	var vp := get_viewport().get_visible_rect().size
	var z := minf(vp.x, vp.y) / (CONE_RADIUS * 2.3)
	cam.zoom = Vector2(z, z)
	var out_dir := OS.get_environment("TFA_SHOT_DIR")
	if out_dir == "":
		out_dir = "."
	for v in viewers:
		var label: String = v[0]
		var pos: Vector2 = v[1]
		var ang: float = v[2]
		var t := GridManager.world_to_map(pos)
		var elev: float = GridManager.effective_elev(t)
		var band: int = GridManager.cone_band(elev)
		print("viewer %s at %s tile %s ground %.2f -> band %d, facing %.0f deg" % [label, str(pos), str(t), elev, band, rad_to_deg(ang)])
		var light := PointLight2D.new()
		light.texture = Globals.get_sight_cone_texture(149.0)
		light.texture_scale = CONE_RADIUS / (light.texture.get_width() * 0.5)
		light.color = Color(1.0, 0.3, 0.2)
		light.energy = 0.9
		light.shadow_enabled = true
		light.range_item_cull_mask = 1
		light.position = pos
		light.rotation = ang
		light.z_index = 102
		add_child(light)
		var dot := Polygon2D.new()
		var pts := PackedVector2Array()
		for i in 16:
			pts.append(pos + Vector2.RIGHT.rotated(TAU * float(i) / 16.0) * 14.0)
		dot.polygon = pts
		dot.color = Color(1.0, 0.95, 0.2)
		dot.z_index = 111
		dot.light_mask = 0
		add_child(dot)
		cam.position = pos + Vector2.RIGHT.rotated(ang) * CONE_RADIUS * 0.45
		# v1: a ground-tier cone shadowed by every wall (on relief maps the
		# structures' torch bit 2 stands in for v1's bit 1), cliffs nothing
		var modes: Dictionary = {"v1": CollisionLayers.LIGHT_SHADOW_MASK,
			"v11": CollisionLayers.SIGHT_MASK_GROUND | GridManager.cone_band_bit(band)}
		if OS.get_environment("TFA_MASKS") != "":   # e.g. "1,2": raw shadow masks instead
			modes.clear()
			for ms in OS.get_environment("TFA_MASKS").split(",", false):
				modes["m" + ms] = int(ms)
		for mode in modes:
			light.shadow_item_cull_mask = int(modes[mode])
			for _i in 3:
				await RenderingServer.frame_post_draw
			var path := "%s/cone_%s_%s_%s.png" % [out_dir, want, label, mode]
			get_viewport().get_texture().get_image().save_png(path)
			print("saved " + path)
		light.queue_free()
		dot.queue_free()
	get_tree().quit(0)


func _walkable(t: Vector2i) -> bool:
	return GridManager.map_rect.has_point(t) and GridManager.would_walk(t) and not GridManager.is_deep_water(t)


# Below the longest tall cliff: a walkable tile with a rise of >= 2 stories
# 3..5 tiles ahead (room for its own lit ground in the shot), scored by how
# far that cliff edge runs sideways.
func _pick_low_viewer() -> Array:
	var best := -1.0
	var out: Array = []
	for y in GridManager.map_rect.size.y:
		for x in GridManager.map_rect.size.x:
			var t := Vector2i(x, y)
			if not _walkable(t):
				continue
			var g: float = GridManager.terrain_elev(t)
			for d in DIRS:
				for k in range(1, 6):
					var a := t + d * (k - 1)
					var b := t + d * k
					if not GridManager.map_rect.has_point(b):
						break
					var rise: float = GridManager.terrain_elev(b) - g
					if GridManager.terrain_elev(b) - GridManager.terrain_elev(a) <= GridManager.MAX_STEP_STORIES:
						continue
					if rise < 2.0 or k < 3:
						break
					var perp := Vector2i(d.y, d.x)
					var lateral := 0
					for j in range(-6, 7):
						if GridManager.terrain_elev(b + perp * j) - GridManager.terrain_elev(a + perp * j) > GridManager.MAX_STEP_STORIES:
							lateral += 1
					var score: float = float(lateral) * 10.0 + minf(rise, 4.0)
					if score > best:
						best = score
						out = [GridManager.map_to_world(t), Vector2(d).angle()]
					break
	return out


# A terrace viewer facing down over walls that stand on ground >= 1.5 stories
# below them, 2..9 tiles ahead inside the cone; scored by how many.
func _pick_high_viewer() -> Array:
	var low_walls: Dictionary = {}   # tile -> count of wall structures centred there
	for s in map_loader.get_children():
		if s is Structure and s.has_meta("occlude_top") and not s.is_deck:
			var st := GridManager.world_to_map(s.position)
			low_walls[st] = int(low_walls.get(st, 0)) + 1
	var best := 0
	var out: Array = []
	for y in GridManager.map_rect.size.y:
		for x in GridManager.map_rect.size.x:
			var t := Vector2i(x, y)
			if not _walkable(t):
				continue
			var g: float = GridManager.terrain_elev(t)
			for d in DIRS:
				if not _walkable(t + d):
					continue
				var perp := Vector2i(d.y, d.x)
				var n := 0
				for k in range(2, 10):
					var hw: int = k >> 1
					for j in range(-hw, hw + 1):
						var c := t + d * k + perp * j
						if low_walls.has(c) and GridManager.terrain_elev(c) <= g - 1.5:
							n += int(low_walls[c])
				if n > best:
					best = n
					out = [GridManager.map_to_world(t), Vector2(d).angle()]
	return out
