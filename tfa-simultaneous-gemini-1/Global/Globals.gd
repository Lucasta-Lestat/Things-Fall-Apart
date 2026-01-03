extends Node
const FloatingTextScene = preload("res://UI/FloatingText.tscn")
var world_state = {"Perrow Destroyed": false, "Justinia Remaining Loops": 7}
var dialogue_interaction_distance = 250.0
var default_body_proportions = {}
var default_leg_swing_time: float = 0.0
const SIGHT_TEXTURE = preload("res://sight_cone_smooth.png")

@export var default_leg_swing_speed: float = 12.0  # How fast default_legs oscillate
@export var default_leg_swing_amount: float = 8.0  # How far default_legs swing
@export var default_leg_length: float = 16.0       # Length of each default_leg
@export var default_leg_width: float = 6.0         # Thickness of default_legs
@export var default_leg_spacing: float = 6.0       # Distance between legs (left-right)
# Body dimensions (top-down view: width is left-right, height is front-back)
@export var default_body_width: float = 28.0   # Shoulder width (horizontal)
@export var default_body_height: float = 14.0  # Body depth/thickness (vertical in top-down)
@export var default_head_width: float = 14.0   # Head width (left-right)
@export var default_head_length: float = 14.0  # Head length (front-back, oval shape)
@export var default_shoulder_y_offset: float = 4.0  # How far back shoulders are from head center (positive = back)
const DR_0 = {"slashing":0, "bludgeoning": 0, "piercing": 0, "sonic": 0, "radiant":0, "necrotic": 0, "fire":0, "cold":0, "acid":0, "poison":0, "force":0 }
# Arm IK settings (smaller for top-down proportions)
const DEFAULT_ARM_SEGMENT_LENGTHS: Array[float] = [12.0, 10.0, 6.0]
const ARM_JOINT_CONSTRAINTS: Array[Vector2] = [
	Vector2(-135, 135),  # Shoulder
	Vector2(0, 145),      # Elbow
	Vector2(-45, 45)      # Wrist
]
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
	
func name_to_id(input_name: String) -> String:
	return input_name.to_lower().replace(" ", "_")
