extends Node2D
# Visual QA shot for the wearable-strip fix: three equipped characters, one
# frame, saved to __wearable_qa.png at the project root. Run WINDOWED:
#   godot --path . res://tests/wearable_qa_shot.tscn
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const OUT := "C:/dev/Things-Fall-Apart-Local/tfa-simultaneous-gemini-1/__wearable_qa.png"


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
	# the user's repro: breastplate_2 + full_face_helmet on a human
	_spawn("human", "male", Vector2(250, 250),
		["full_face_helmet", "steel_greaves", "breastplate_2"])
	# naked control: must wear NOTHING
	_spawn("human", "male", Vector2(400, 250), [])
	# race spread: same pieces on an orc
	_spawn("orc", "male", Vector2(550, 250),
		["full_face_helmet", "steel_greaves", "breastplate_2"])
	for i in 12:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(OUT)
	print("shot saved: ", OUT)
	get_tree().quit()
