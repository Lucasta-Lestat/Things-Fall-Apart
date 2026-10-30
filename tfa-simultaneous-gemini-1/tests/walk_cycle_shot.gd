extends Node2D
# QA: live walk-cycle frames for foreshortened rigs, through the REAL game
# build path (gear, holders, facing) -- the rig-only captures sampled seeked
# poses and missed runtime-path artifacts. Two characters (djargo + a robed
# human female), facing south then north, ~16 frames across one walk loop.
# Prints per-frame arm-bone scale telemetry to correlate visual balloons with
# bone state. Run WINDOWED:  godot --path . res://tests/walk_cycle_shot.tscn
# Sheets go to TFA_SHOT_DIR (default user://shots: tests/shot_dir.gd).
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const ShotDir := preload("res://tests/shot_dir.gd")

var chars: Array = []


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	var cam := Camera2D.new()
	cam.position = Vector2(400, 250)
	cam.zoom = Vector2(2.2, 2.2)
	add_child(cam)
	cam.make_current()

	var c1: ProceduralCharacter = CHAR_SCENE.instantiate()
	c1.position = Vector2(320, 250)
	add_child(c1)
	TopDownCharacterDatabase.build_character(c1, "djargo")
	chars.append(c1)

	var c2: ProceduralCharacter = CHAR_SCENE.instantiate()
	c2.position = Vector2(480, 250)
	add_child(c2)
	TopDownCharacterDatabase.build_character(c2, "cultist")
	chars.append(c2)

	for i in 20:
		await get_tree().process_frame

	for c in chars:
		var pc: ProceduralCharacter = c
		print("QA: char rig=", pc.character_rig != null,
			" scene=", pc.character_rig.scene_file_path if pc.character_rig else "none")
		if pc.character_rig and pc.character_rig.has_method("set_moving"):
			pc.character_rig.set_moving(true)

	await _shoot("south")
	for c in chars:
		(c as Node2D).rotation = PI
		(c as ProceduralCharacter).target_rotation = PI   # facing authority --
		# a bare rotation write is reverted by the game's facing code
	for i in 5:
		await get_tree().process_frame
	await _shoot("north")
	print("QA: done")
	get_tree().quit(0)


func _telemetry(tag: String) -> void:
	for c in chars:
		var pc: ProceduralCharacter = c
		if pc.character_rig == null:
			continue
		var line := "QA-T %s:" % tag
		for side in ["l", "r"]:
			var up := pc.character_rig.get_node_or_null(
				"Rig/Skeleton2D/root/upperarm_" + side) as Node2D
			var fo := pc.character_rig.get_node_or_null(
				"Rig/Skeleton2D/root/upperarm_" + side + "/forearm_" + side) as Node2D
			if up and fo:
				line += " %s[u %.2f/%.2f f %.2f/%.2f r%.0f]" % [side,
					up.scale.x, up.scale.y, fo.scale.x, fo.scale.y,
					rad_to_deg(up.rotation)]
		print(line)


func _shoot(tag: String) -> void:
	var frames: Array = []
	for f in 16:
		for i in 3:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		frames.append(get_viewport().get_texture().get_image())
		if f % 4 == 0:
			_telemetry("%s f%d" % [tag, f])
	var fw: int = frames[0].get_width()
	var fh: int = frames[0].get_height()
	var cols := 4
	var rows := 4
	var sheet := Image.create(fw * cols, fh * rows, false, Image.FORMAT_RGB8)
	for f in frames.size():
		var img: Image = frames[f]
		img.convert(Image.FORMAT_RGB8)
		sheet.blit_rect(img, Rect2i(0, 0, fw, fh),
			Vector2i((f % cols) * fw, (f / cols) * fh))
	var out := "%s/__walk_qa_%s.png" % [ShotDir.dir(), tag]
	sheet.save_png(out)
	print("QA: saved ", out)
