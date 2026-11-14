extends Node
# SubViewport mode for tests/canopy_shot.tscn: the visual canopy check renders
# into an offscreen SubViewport, so the window stays 64x64 and off-screen (no
# normal-size window pops up) while the shots keep their full size. Same env as
# canopy_shot (TFA_MAP, TFA_AT, TFA_SHOT_DIR), plus
# TFA_SHOT_SIZE="WxH" (default 1400x1000). WINDOWED only: the headless renderer
# is a dummy and saves black PNGs. TFA_SHOT_DIR outside the project (unset or
# inside it, the shots go to user://shots: tests/shot_dir.gd).
# Run: godot --path . --resolution 64x64 --position -20000,-20000 res://tests/canopy_shot_sv.tscn

const DEFAULT_SIZE := Vector2i(1400, 1000)


func _ready() -> void:
	# backstop for a run without the window flags
	var w := get_window()
	w.borderless = true
	w.unfocusable = true
	w.size = Vector2i(64, 64)
	w.position = Vector2i(-20000, -20000)
	var size := DEFAULT_SIZE
	var env := OS.get_environment("TFA_SHOT_SIZE").strip_edges().to_lower()
	if env != "":
		var xs := env.split("x")
		if xs.size() == 2 and xs[0].is_valid_int() and xs[1].is_valid_int():
			size = Vector2i(int(xs[0]), int(xs[1]))
	# canopy_shot sizes its camera from get_viewport() and saves
	# get_viewport()'s texture: inside here, both are this SubViewport.
	var sv := SubViewport.new()
	sv.size = size
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	sv.add_child((load("res://tests/canopy_shot.tscn") as PackedScene).instantiate())
