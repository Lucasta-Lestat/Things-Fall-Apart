extends Node
const FloatingTextScene = preload("res://UI/FloatingText.tscn")
var world_state = {"Perrow Destroyed": false, "Justinia Remaining Loops": 7}
var dialogue_interaction_distance = 250.0

# === GLOBAL FUNCTIONS ===
func show_floating_text(text: String, pos: Vector2, parent: Node):
	var floating_text = FloatingTextScene.instantiate()
	floating_text.text = text
	floating_text.position = pos
	parent.add_child(floating_text)

func clamp_to_screen(pos: Vector2, screen_size: Vector2) -> Vector2:
	return Vector2(
		clamp(pos.x, 0, screen_size.x),
		clamp(pos.y, 0, screen_size.y)
	)

func format_time(seconds: float) -> String:
	var mins = int(seconds) / 60
	var secs = int(seconds) % 60
	return "%02d:%02d" % [mins, secs]
