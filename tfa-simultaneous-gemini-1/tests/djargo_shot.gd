extends Node2D
# One-off QA: spawn Djargo the way Game does and verify his authored gear
# renders on the rig (template equipment -> auto-equip -> fitted layers).
# Run WINDOWED:  godot --path . res://tests/djargo_shot.tscn
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const OUT := "C:/dev/Things-Fall-Apart-Local/tfa-simultaneous-gemini-1/__djargo_qa.png"


func _visible_wearables(c) -> Array:
	var out := []
	if c.character_rig == null:
		return out
	var stack: Array = [c.character_rig]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		for ch in n.get_children():
			stack.append(ch)
		if n is CanvasItem and (String(n.name).begins_with("G_")
				or String(n.name).begins_with("EQ_")) and (n as CanvasItem).visible:
			out.append(String(n.name))
	out.sort()
	return out


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	var cam := Camera2D.new()
	cam.position = Vector2(400, 250)
	cam.zoom = Vector2(2.5, 2.5)
	add_child(cam)
	cam.make_current()
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	c.position = Vector2(400, 250)
	add_child(c)
	TopDownCharacterDatabase.build_character(c, "djargo")
	for i in 12:
		await get_tree().process_frame
	print("djargo wearables: ", _visible_wearables(c))
	get_viewport().get_texture().get_image().save_png(OUT)
	print("shot saved: ", OUT)
	get_tree().quit()
