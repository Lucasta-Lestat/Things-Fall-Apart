# res://tests/reward_screen_preview.gd
# Visual preview for the quest reward screen and the new trophy sprite.
#
# --headless uses the dummy renderer and cannot screenshot, so run this WINDOWED:
#
#   <godot_console_exe> --path . res://tests/reward_screen_preview.tscn
#
# It renders each shot with the real engine — real Cinzel, real theme, real
# container layout, real GuillocheRect _draw — writes PNGs under TFA_SHOT_DIR
# (default user://shots, never the project: tests/shot_dir.gd), and quits. Beats playing to a turn-in every time you nudge a margin.
#
# Shots written:
#   _preview_reward_3.png    the shipped three-offer bounty screen
#   _preview_reward_2.png    two offers (layout has to re-centre)
#   _preview_reward_4.png    four offers (the squeeze case)
#   _preview_trophy.png      the severed head at its real in-world pixel width
#
extends Node2D

const ShotDir := preload("res://tests/shot_dir.gd")
var _out_dir := ""
const SHOTS: Array = [
	{"file": "_preview_reward_3.png", "offers": [
		{"type": "money", "amount": 180},
		{"type": "item", "item_id": "winters_grip"},
		{"type": "training", "ability_id": "shield_bash", "base_days": 4,
			"teacher_title": "the Guild's master-at-arms"},
	]},
	{"file": "_preview_reward_2.png", "offers": [
		{"type": "item", "item_id": "potion_of_healing"},
		{"type": "training", "ability_id": "fireball", "base_days": 6,
			"teacher_title": "Surgeon-Captain Federica"},
	]},
	{"file": "_preview_reward_4.png", "offers": [
		{"type": "money", "amount": 40},
		{"type": "item", "item_id": "longsword"},
		{"type": "item", "item_id": "iron_shield"},
		{"type": "training", "ability_id": "heal", "base_days": 3, "teacher_title": "a hedge-priest"},
	]},
]


func _ready() -> void:
	DisplayServer.window_set_size(Vector2i(1600, 900))
	await _settle(10)

	for shot in SHOTS:
		await _shoot_reward(str(shot["file"]), shot["offers"])

	await _shoot_trophy()

	print("[preview] done — open the _preview_*.png files in %s" % _out_dir)
	get_tree().quit(0)


func _shoot_reward(file_name: String, offers: Array) -> void:
	var screen = load("res://UI/QuestRewardScreen.gd").new()
	screen.setup("preview", offers, null)
	add_child(screen)
	# Containers need several frames to settle; four is too few and you get a
	# shot of everything stacked at the origin.
	await _settle(20)
	_capture(file_name)
	screen.queue_free()
	await _settle(2)


## The trophy at the size it actually occupies: scale_sprite uses base_width as
## an on-screen PIXEL width, so 16 means sixteen pixels across on the ground,
## not sixteen units of anything. Shot beside the king's head and at 4x for a
## look at the art itself.
func _shoot_trophy() -> void:
	var root := Node2D.new()
	add_child(root)

	var bg := ColorRect.new()
	bg.color = Color(0.16, 0.15, 0.13, 1.0)
	bg.size = Vector2(1600, 900)
	root.add_child(bg)

	var pairs := [["res://Items/severed_head.png", 16.0], ["res://Items/skarsgaard_king_head.png", 16.0]]
	var x := 200.0
	for pair in pairs:
		var path: String = str(pair[0])
		if not ResourceLoader.exists(path):
			continue
		var tex: Texture2D = load(path)
		for zoom in [1.0, 4.0, 12.0]:
			var s := Sprite2D.new()
			s.texture = tex
			# Mirror Item.scale_sprite exactly: uniform, driven by width alone.
			var ratio: float = (float(pair[1]) * zoom) / float(tex.get_size().x)
			s.scale = Vector2(ratio, ratio)
			s.position = Vector2(x, 450)
			root.add_child(s)
			x += 60.0 * zoom + 40.0
		x += 80.0

	await _settle(10)
	_capture("_preview_trophy.png")
	root.queue_free()


func _capture(file_name: String) -> void:
	var img: Image = get_viewport().get_texture().get_image()
	if _out_dir == "":
		_out_dir = ShotDir.dir()
	var path: String = _out_dir + "/" + file_name
	var err: int = img.save_png(path)
	print("[preview] %s -> %s" % [file_name, "ok" if err == OK else "ERR %d" % err])


func _settle(frames: int) -> void:
	for _i in range(frames):
		await get_tree().process_frame
