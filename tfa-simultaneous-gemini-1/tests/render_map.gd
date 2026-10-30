extends Node2D
# Throwaway render harness: loads tg_export through MapLoader like the game and
# screenshots. Camera via env TFA_CAM_X/Y/ZOOM (defaults: whole-map fit).
# Run WITHOUT --headless (needs a GPU): godot --path . res://tests/render_map.tscn
# The shot goes to TFA_SHOT (a png path outside the project; default
# user://shots/render_map.png: tests/shot_dir.gd).
const MAP_LOADER := preload("res://Structures/MapLoader.gd")
const ShotDir := preload("res://tests/shot_dir.gd")
var structures_in_scene: Array = []
var party_chars: Array = []
var unlocked_locks: Dictionary = {}
var map_loader: Node2D = null   # FluidManager resolves game.map_loader.structured_ground

func _ready() -> void:
	add_to_group("game")
	var f := FileAccess.open("res://data/Maps.json", FileAccess.READ)
	var raw: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	var want := OS.get_environment("TFA_MAP")
	if want == "":
		want = "tg_export"
	var m: Dictionary = {}
	for e in raw.get("maps", []):
		if String(e.get("id", "")) == want:
			m = e
			break
	GridManager.TILE_SIZE = int(m.get("tile_size", 64))
	var ws: Array = m.get("world_size", [2048, 2048])
	GridManager.initialize(int(ws[0]), int(ws[1]))
	var graph: CellGraph = CellGraph.from_structured(String(m.get("cell_graph", "")))
	GridManager.set_elevation_data(graph)
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	ml.generate_structured_map(m)
	map_loader = ml
	var cam := Camera2D.new()
	var cx := float(OS.get_environment("TFA_CAM_X")) if OS.get_environment("TFA_CAM_X") != "" else float(ws[0]) * 0.5
	var cy := float(OS.get_environment("TFA_CAM_Y")) if OS.get_environment("TFA_CAM_Y") != "" else float(ws[1]) * 0.5
	var zm := float(OS.get_environment("TFA_CAM_ZOOM")) if OS.get_environment("TFA_CAM_ZOOM") != "" else 1.0
	cam.position = Vector2(cx, cy)
	cam.zoom = Vector2(zm, zm)
	add_child(cam)
	cam.make_current()
	# Optional prop smoke-test: TFA_ITEMS=1 spawns the map's item_spawns as real
	# Item nodes (same scene Game.create_item uses) — proves exported furniture
	# ids resolve in Items.json and their art loads at the right footprint
	if OS.get_environment("TFA_ITEMS") != "":
		var item_scene: PackedScene = preload("res://Structures/Objects/Item.tscn")
		var spawned := 0
		for idf in m.get("item_spawns", []):
			var inst: Item = item_scene.instantiate() as Item
			inst.id = String(idf.get("id", ""))
			var ip: Array = idf.get("position", [0, 0])
			inst.global_position = Vector2(float(ip[0]), float(ip[1]))
			inst.rotation = float(idf.get("rotation", 0.0))
			var isc := float(idf.get("scale", 1.0))
			# mirror Game._spawn_items: per-axis stretch/mirror over uniform scale
			var isx := isc * float(idf.get("scale_x", 1.0))
			var isy := isc * float(idf.get("scale_y", 1.0))
			if isx != 1.0 or isy != 1.0:
				inst.scale = Vector2(isx, isy)
			# RUN furniture: the same spawn->run dict Game._spawn_items builds
			if idf.has("length"):
				inst.run = RunLayout.run_from_spawn(idf)
			add_child(inst)
			# z AFTER add_child: Item._ready pins z_index = 1 on enter
			var zb := int(idf.get("z", 0))
			if zb != 0:
				inst.z_index = 1 + zb
			spawned += 1
		print("item smoke-test: spawned ", spawned, " items")

	# Optional fluid smoke-test: TFA_FLUIDS=1 replays the map's fluid_spawns
	# through a real FluidManager (cell sim + FX) and lets them settle
	if OS.get_environment("TFA_FLUIDS") != "":
		var fm := FluidManager.new()
		add_child(fm)
		fm.setup_cell_graph(graph)
		for fd in m.get("fluid_spawns", []):
			var pos_arr: Array = fd.get("position", [0, 0])
			var rad := int(fd.get("radius", 0))
			var amt := float(fd.get("amount", 0.5))
			var ct := Vector2i(int(pos_arr[0]), int(pos_arr[1]))
			# mirror Game._spawn_fluids: contiguous pour for area spawns
			if rad > 0 and fm.cell_fluid != null and fm.cell_fluid.active_sim():
				fm.cell_fluid.pour(GridManager.map_to_world(ct), String(fd.get("type", "water")),
					amt, (float(rad) + 0.5) * GridManager.TILE_SIZE)
			else:
				for dx in range(-rad, rad + 1):
					for dy in range(-rad, rad + 1):
						if Vector2(dx, dy).length() <= rad + 0.5:
							fm.register_fluid(ct + Vector2i(dx, dy), String(fd.get("type", "water")), amt)
		print("fluid smoke-test: spawned ", m.get("fluid_spawns", []).size(), " defs")
		# TFA_FLUID_SETTLE=<n>: run n flow ticks up front (n=240 ~= one minute of
		# sim) -- proves a slick SURVIVES spreading, not just that it spawned
		var settle := OS.get_environment("TFA_FLUID_SETTLE")
		if settle != "" and fm.cell_fluid != null:
			for _i in int(settle):
				fm.cell_fluid._flow_tick()
			var wet := 0
			var deep := 0.0
			for cid in fm.cell_fluid.active:
				wet += 1
				deep = maxf(deep, fm.cell_fluid.amount[cid])
			print("fluid settle: ", settle, " ticks -> ", wet, " wet cells, max depth %.3f" % deep)
		# TFA_FLUID_RAINTEST=1: drop a sub-surface water puddle (0.15) beside the
		# slick and verify cross-type flow does NOT invade it -- the immiscible
		# rule says water must overtop the slick's TRUE surface before it may
		# spill in and wipe. Compares the slick BODY (cells >= 0.2, which never
		# evaporate) so legit sub-floor rim drying can't false-fail the check.
		if OS.get_environment("TFA_FLUID_RAINTEST") != "" and fm.cell_fluid != null:
			var cfld: CellFluid = fm.cell_fluid
			var body0 := 0.0
			var target := -1
			for cid in cfld.active:
				if cfld.type_at(cid) != "oil":
					continue
				if cfld.amount[cid] >= 0.2:
					body0 += cfld.amount[cid]
				if target < 0:
					for nb in graph.neighbors(cid):
						if cfld.ftype[nb] == 0:
							target = nb
							break
			if target >= 0:
				cfld.deposit(graph.centroid(target), "water", 0.15)
				for _i in 80:
					cfld._flow_tick()
			var body1 := 0.0
			for cid in cfld.active:
				if cfld.type_at(cid) == "oil" and cfld.amount[cid] >= 0.2:
					body1 += cfld.amount[cid]
			print("rain-test: slick body %.3f -> %.3f (%s)" % [body0, body1,
				"OK" if body1 >= body0 * 0.98 else "FAIL: water shredded the slick"])
		for _i in 45:
			await RenderingServer.frame_post_draw
	# TFA_RAINDEMO=<water|acid>: scatter weather blots on walkable tiles around
	# the camera and settle -- visual proof precipitation lays visible surfaces.
	var raindemo := OS.get_environment("TFA_RAINDEMO")
	if raindemo != "":
		var rfm: FluidManager = get_node_or_null("FluidManager")
		if rfm == null:
			rfm = FluidManager.new()
			rfm.name = "FluidManager"
			add_child(rfm)
			rfm.setup_cell_graph(graph)
		var amt := 0.35 if raindemo == "water" else 0.6
		var placed := 0
		for i in 60:
			if placed >= 8:
				break
			var ang := float(i) * 2.399963       # golden-angle scatter, deterministic
			var rr := 60.0 + float(i) * 34.0
			var p := Vector2(cx, cy) + Vector2(cos(ang), sin(ang)) * rr
			var t := GridManager.world_to_map(p)
			if GridManager.walls.get(t, true):
				continue
			rfm.rain_puddle(t, raindemo, amt)
			placed += 1
		if rfm.cell_fluid != null:
			for _i in 40:
				rfm.cell_fluid._flow_tick()
		print("rain demo: ", placed, " ", raindemo, " puddles")
		for _i in 45:
			await RenderingServer.frame_post_draw
	# Optional door test: TFA_DOORS_OPEN=1 swings every unlocked door open
	# (phantom-door check: no baked leaf may remain visible under a swung one)
	if OS.get_environment("TFA_DOORS_OPEN") != "":
		var swung := 0
		for s in structures_in_scene:
			if is_instance_valid(s) and s is Door and not (s as Door).locked:
				(s as Door).open_door(1)
				swung += 1
		print("doors swung open: ", swung)
	# Optional fire smoke-test: TFA_FIRE=<radius px> lights every cell within
	# that radius of the camera and renders the CellFireFX flame sheet + merged
	# cluster lights (sim is not ticked -- burning entries are synthetic,
	# mid-burn: t0-t=2 -> full bed), plus a CellScorchFX char field: mid-depth
	# char under the flames, full-to-fading char in a burnt-out ring outside
	# them (what the ground looks like after the fire moves on).
	var fire_r := OS.get_environment("TFA_FIRE")
	if fire_r != "":
		var scorch: CellScorchFX = CellScorchFX.new()
		scorch.z_index = -5   # same slot the game uses: over ground, under walls
		add_child(scorch)
		scorch.setup(graph)
		var cf: CellFire = CellFire.new()
		add_child(cf)
		cf.setup(graph, self, {})
		cf.scorch_fx = scorch
		var fx: CellFireFX = CellFireFX.new()
		add_child(fx)
		fx.setup(cf, graph)
		var fr := float(fire_r)
		var lit := 0
		var charred := 0
		for cid in graph.cell_count:
			var d := graph.centroid(cid).distance_to(Vector2(cx, cy))
			if d < fr:
				cf.burning[cid] = {"t": 6.0, "t0": 8.0, "char": 0.66,
					"seed": fposmod(float(cid) * 0.618034, 1.0)}
				scorch.stamp(cid, 0.66, fposmod(float(cid) * 0.618034, 1.0))
				lit += 1
			elif d < fr * 1.9:
				# burnt-out ring: full char at the fire's edge fading outward
				var k := clampf(1.0 - (d - fr) / (fr * 0.9) * 0.7, 0.3, 1.0)
				scorch.stamp(cid, k, fposmod(float(cid) * 0.618034, 1.0))
				charred += 1
		cf.burn_rev += 1
		print("fire smoke-test: ", lit, " cells lit, ", charred, " charred")
		for _i in 40:
			await RenderingServer.frame_post_draw
	# Optional destroy test: TFA_DESTROY="x,y;x,y" destroys, through the real
	# damage path, the structure whose centre (wall midpoint, tower/tree pos) is
	# nearest each point within 48 px -- proves art_polys slices / art_under
	# reveal sensibly when a curtain piece, a tower or a tree goes
	var destroy_s := OS.get_environment("TFA_DESTROY")
	if destroy_s != "":
		for tok in destroy_s.split(";", false):
			var xy := tok.split(",")
			if xy.size() != 2:
				continue
			var p := Vector2(float(xy[0]), float(xy[1]))
			var best: Structure = null
			var best_d := 48.0
			for s in structures_in_scene:
				if is_instance_valid(s) and s is Structure:
					var d := (s as Structure).global_position.distance_to(p)
					if d < best_d:
						best_d = d
						best = s as Structure
			if best == null:
				print("destroy: nothing within 48 px of ", p)
				continue
			print("destroy: %s at %s (%.1f px), art_under=%s" % [best.name, best.global_position,
				best_d, best.get_node_or_null("Art/ArtUnder") != null])
			best.take_damage({"bludgeoning": 100000})
		for _i in 10:
			await RenderingServer.frame_post_draw
	for _i in 4:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(ShotDir.file(OS.get_environment("TFA_SHOT"), "render_map.png"))
	print("render_map shot ok")
	get_tree().quit()
