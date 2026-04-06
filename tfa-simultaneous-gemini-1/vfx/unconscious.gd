extends Node2D

var _size_scale: float = 1.0
var _spawn_timer: float = 0.0
var _spawn_interval: float = 0.8
var _active: bool = false

func play(size_scale: float = 1.0):
	_size_scale = size_scale
	_active = true
	_spawn_timer = 0.0
	_spawn_z()

func stop():
	_active = false

func _process(delta: float) -> void:
	if not _active:
		return
	_spawn_timer += delta
	if _spawn_timer >= _spawn_interval:
		_spawn_timer -= _spawn_interval
		_spawn_z()

func _spawn_z() -> void:
	var label = Label.new()
	label.text = "Z"
	label.add_theme_font_size_override("font_size", int(14 * _size_scale))
	label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.9))
	label.z_index = 50
	label.position = Vector2(randf_range(-5, 5), -20)
	label.scale = Vector2(0.8, 0.8) * _size_scale
	label.pivot_offset = Vector2(7, 7)
	add_child(label)

	var duration = 1.5
	var tween = create_tween().set_parallel()
	tween.tween_property(label, "position", label.position + Vector2(randf_range(-8, 8), -50 * _size_scale), duration)
	tween.tween_property(label, "scale", Vector2(1.3, 1.3) * _size_scale, duration)
	tween.tween_property(label, "rotation", randf_range(-0.3, 0.3), duration)
	tween.tween_property(label, "modulate:a", 0.0, duration)
	tween.chain().tween_callback(label.queue_free)
