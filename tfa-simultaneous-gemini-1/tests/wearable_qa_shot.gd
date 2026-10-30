extends Node2D
# Visual QA shot for the wearable-strip fix: three equipped characters, one
# frame, saved to __wearable_qa.png under TFA_SHOT_DIR (default user://shots:
# tests/shot_dir.gd). Run WINDOWED:
#   godot --path . res://tests/wearable_qa_shot.tscn
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const ShotDir := preload("res://tests/shot_dir.gd")


func _spawn(rid: String, gender: String, pos: Vector2, items: Array) -> void:
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	c.position = pos
	add_child(c)
	RaceDatabase.apply_race_to_character(c, rid, {"gender": gender})
	c.rebuild_visuals()
	for id in items:
		var d: Dictionary = ItemDatabase.get_item_data(id)
		if not d.is_empty():
			c.equip_equipment(d.duplicate())


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	var cam := Camera2D.new()
	cam.position = Vector2(400, 250)
	cam.zoom = Vector2(2.2, 2.2)
	add_child(cam)
	cam.make_current()
	# grimalkin rebuild + slender quadrelf female QA round
	_spawn("grimalkin", "male", Vector2(220, 250), [])
	_spawn("grimalkin", "female", Vector2(370, 250), ["dark_hood"])
	_spawn("quadrelf", "female", Vector2(520, 250), [])
	_spawn("quadrelf", "female", Vector2(650, 250),
		["purple_hood", "peasant's_stained_shirt", "leather_boots"])
	for i in 12:
		await get_tree().process_frame
	var out := ShotDir.dir() + "/__wearable_qa.png"
	get_viewport().get_texture().get_image().save_png(out)
	print("shot saved: ", out)
	get_tree().quit()
