extends Label

const LIFETIME := 1.2
const FLOAT_DISTANCE := 80.0
const POP_SCALE := 1.35
const HORIZONTAL_JITTER := 15.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_level = true

func setup(damage_text: String, color: Color, success_level: int = 0, base_world_pos: Vector2 = Vector2.ZERO) -> void:
	text = damage_text
	modulate = color
	var base_scale := 1.0 + 0.3 * success_level
	var jitter_x := randf_range(-HORIZONTAL_JITTER, HORIZONTAL_JITTER)
	global_position = base_world_pos + Vector2(jitter_x - 100.0, -40.0 - 40.0)

	scale = Vector2(base_scale * POP_SCALE, base_scale * POP_SCALE)
	var tw := create_tween().set_parallel()
	tw.tween_property(self, "scale", Vector2(base_scale, base_scale), 0.15).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(self, "global_position:y", global_position.y - FLOAT_DISTANCE, LIFETIME).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(self, "modulate:a", 0.0, LIFETIME * 0.4).set_delay(LIFETIME * 0.6)
	tw.chain().tween_callback(queue_free)
