extends Node2D
# In-engine screenshots of RUN furniture (Items/RunRenderer.gd) on an EXPORTED
# map that lives OUTSIDE this project (a Terrain Generation sandbox): the
# map's ground + structures PNGs are loaded from disk as a backdrop, and its
# item_spawns are spawned as real Item nodes (same scene + run/shape rules as
# Game._spawn_items) -- so the shot is the real renderer (mipmapped atlases,
# clip_uv strips, procedural decor) without importing the map into TFA.
# Run WINDOWED (needs a GPU):
#   RUN_SHOW_ROOT=<sandbox with data/Maps.json + Maps/> RUN_SHOW_SPEC=<shots.json>
#   godot --path . res://tests/run_showcase.tscn
# shots.json: [{"map": "tg_hillside_middle", "x": 1897, "y": 1568, "zoom": 1.5,
#               "out": "C:/.../guildhall.png"}, ...]   (x/y = export px)
const ITEM_SCENE := preload("res://Structures/Objects/Item.tscn")

var _items_root: Node2D = null
var _backdrop: Sprite2D = null


func _ready() -> void:
	var root := OS.get_environment("RUN_SHOW_ROOT").replace("\\", "/").trim_suffix("/")
	var sf := FileAccess.open(OS.get_environment("RUN_SHOW_SPEC"), FileAccess.READ)
	var shots: Array = JSON.parse_string(sf.get_as_text())
	sf.close()
	var mf := FileAccess.open(root + "/data/Maps.json", FileAccess.READ)
	var maps: Dictionary = JSON.parse_string(mf.get_as_text())
	mf.close()
	var cam := Camera2D.new()
	add_child(cam)
	cam.make_current()
	var cur_map := ""
	var ground: Image = null
	for sv in shots:
		var shot: Dictionary = sv
		var mid := String(shot["map"])
		if mid != cur_map:
			cur_map = mid
			var m: Dictionary = {}
			for e in maps.get("maps", []):
				if String(e.get("id", "")) == mid:
					m = e
			var ws: Array = m.get("world_size", [2048, 2048])
			GridManager.TILE_SIZE = int(m.get("tile_size", 64))
			GridManager.initialize(int(ws[0]), int(ws[1]))
			ground = Image.load_from_file(root + "/Maps/" + mid + ".png")
			var st := Image.load_from_file(root + "/Maps/" + mid + "_structures.png")
			if st != null and ground != null:
				ground.convert(Image.FORMAT_RGBA8)
				st.convert(Image.FORMAT_RGBA8)
				ground.blend_rect(st, Rect2i(Vector2i.ZERO, st.get_size()), Vector2i.ZERO)
			_spawn_map_items(m)
		var c := Vector2(float(shot["x"]), float(shot["y"]))
		var zm := float(shot.get("zoom", 1.0))
		var vs := get_viewport_rect().size
		var half := vs / zm * 0.5 + Vector2(8, 8)
		var r := Rect2i(Vector2i(c - half), Vector2i(half * 2.0)).intersection(Rect2i(Vector2i.ZERO, ground.get_size()))
		if _backdrop != null:
			_backdrop.queue_free()
		_backdrop = Sprite2D.new()
		_backdrop.centered = false
		_backdrop.texture = ImageTexture.create_from_image(ground.get_region(r))
		_backdrop.position = Vector2(r.position)
		_backdrop.z_index = -10
		_backdrop.z_as_relative = false
		add_child(_backdrop)
		cam.position = c
		cam.zoom = Vector2(zm, zm)
		for _i in 6:
			await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png(String(shot["out"]))
		print("run_showcase shot ok: ", shot["out"])
	get_tree().quit()


func _spawn_map_items(m: Dictionary) -> void:
	if _items_root != null:
		_items_root.queue_free()
	_items_root = Node2D.new()
	add_child(_items_root)
	var n := 0
	var runs := 0
	for dv in m.get("item_spawns", []):
		var d: Dictionary = dv
		var inst: Item = ITEM_SCENE.instantiate() as Item
		inst.id = String(d.get("id", ""))
		var pa: Array = d.get("position", [0, 0])
		var sc := float(d.get("scale", 1.0))
		# Game._apply_spawn_shape (before add_child: no physics sync involved)
		inst.transform = Transform2D(float(d.get("rotation", 0.0)),
			Vector2(sc * float(d.get("scale_x", 1.0)), sc * float(d.get("scale_y", 1.0))), 0.0,
			Vector2(float(pa[0]), float(pa[1])))
		if d.has("length"):
			inst.run = RunLayout.run_from_spawn(d)
			runs += 1
		_items_root.add_child(inst)
		var zb := int(d.get("z", 0))
		if zb != 0:
			inst.z_index = 1 + zb
		n += 1
	print("run_showcase: %s spawned %d items (%d runs)" % [String(m.get("id", "")), n, runs])
