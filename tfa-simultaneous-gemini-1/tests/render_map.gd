extends Node2D
# Throwaway render harness: loads tg_export through MapLoader like the game and
# screenshots. Camera via env TFA_CAM_X/Y/ZOOM (defaults: whole-map fit).
# Run WITHOUT --headless (needs a GPU): godot --path . res://tests/render_map.tscn
const MAP_LOADER := preload("res://Structures/MapLoader.gd")
var structures_in_scene: Array = []
var party_chars: Array = []
var unlocked_locks: Dictionary = {}

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
	var cam := Camera2D.new()
	var cx := float(OS.get_environment("TFA_CAM_X")) if OS.get_environment("TFA_CAM_X") != "" else float(ws[0]) * 0.5
	var cy := float(OS.get_environment("TFA_CAM_Y")) if OS.get_environment("TFA_CAM_Y") != "" else float(ws[1]) * 0.5
	var zm := float(OS.get_environment("TFA_CAM_ZOOM")) if OS.get_environment("TFA_CAM_ZOOM") != "" else 1.0
	cam.position = Vector2(cx, cy)
	cam.zoom = Vector2(zm, zm)
	add_child(cam)
	cam.make_current()
	for _i in 4:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(OS.get_environment("TFA_SHOT"))
	print("render_map shot ok")
	get_tree().quit()
