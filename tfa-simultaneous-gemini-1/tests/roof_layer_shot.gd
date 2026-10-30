extends Node2D
# Visual QA for the DF-style RoofLayer cover: renders tg_guild_hall's ground
# art (roofless, interiors painted in) with the RoofLayer quads on top, and
# saves one screenshot per view slice to the path given by TFA_SHOT_DIR (env),
# defaulting to user://shots (never the project: tests/shot_dir.gd). WINDOWED
# only — the headless renderer is a dummy and saves black PNGs.
# Run: godot --path . res://tests/roof_layer_shot.tscn
const ShotDir := preload("res://tests/shot_dir.gd")

func _ready() -> void:
	GridManager.TILE_SIZE = 64
	var ground := Sprite2D.new()
	ground.texture = load("res://Maps/tg_guild_hall.png")
	ground.centered = false
	ground.z_index = -6
	add_child(ground)
	GridManager.initialize(int(ground.texture.get_width()), int(ground.texture.get_height()))
	var graph: CellGraph = CellGraph.from_structured("res://Maps/tg_guild_hall_cells.json")
	GridManager.set_elevation_data(graph)
	# painted export when present (mirrors MapLoader), else the quad fallback
	var roofs: Node2D
	if ResourceLoader.exists("res://Maps/tg_guild_hall_roofs.png"):
		var spr := Sprite2D.new()
		spr.texture = load("res://Maps/tg_guild_hall_roofs.png")
		spr.centered = false
		var pm := CanvasItemMaterial.new()
		pm.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
		spr.material = pm
		roofs = spr
		add_child(spr)
	else:
		roofs = RoofLayer.new()
		add_child(roofs)

	# frame the camera on the roofed footprint
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := Vector2i(-(1 << 30), -(1 << 30))
	for t in GridManager.roof_elevations:
		lo = Vector2i(mini(lo.x, t.x), mini(lo.y, t.y))
		hi = Vector2i(maxi(hi.x, t.x), maxi(hi.y, t.y))
	print("roof tiles: %d  bbox: %s..%s" % [GridManager.roof_elevations.size(), str(lo), str(hi)])
	var center := (GridManager.map_to_world(lo) + GridManager.map_to_world(hi)) * 0.5
	var extent := (GridManager.map_to_world(hi) - GridManager.map_to_world(lo)).abs() + Vector2(256, 256)
	var cam := Camera2D.new()
	cam.position = center
	var vp := get_viewport().get_visible_rect().size
	var z := minf(vp.x / extent.x, vp.y / extent.y)
	cam.zoom = Vector2(z, z)
	add_child(cam)
	cam.make_current()

	var out_dir := ShotDir.dir()
	roofs.visible = true
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out_dir + "/roof_view_on.png")
	roofs.visible = false
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out_dir + "/roof_view_off.png")
	print("roof_layer_shot: saved to " + out_dir)
	get_tree().quit(0)
