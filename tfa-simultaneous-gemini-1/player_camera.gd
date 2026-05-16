# Attach this script directly to your Camera2D node.

extends Camera2D

@export var zoom_speed: float = 0.1  # How much each scroll adds/removes
@export var lerp_speed: float = 10.0 # How quickly the camera interpolates to the target zoom
@export var min_zoom: float = 0.5
@export var max_zoom: float = 3.0
@export var pan_speed: float = 600.0 # world units / sec at zoom = 1.0

# We will change this target value first, then smoothly move the actual zoom towards it.
var target_zoom: Vector2 = Vector2.ONE
# True while the user is actively WASD-panning. Game.gd checks this to
# suspend the camera-follow-lerp; cleared when a new primary is selected
# (see Game.select_character / toggle_character_selection).
var manual_pan_active: bool = false

func _ready() -> void:
	# Initialize the target_zoom with the camera's current zoom.
	target_zoom = zoom
	# Pan + zoom must work while the game is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.is_pressed():
			target_zoom -= Vector2(zoom_speed, zoom_speed)
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.is_pressed():
			target_zoom += Vector2(zoom_speed, zoom_speed)

		# Clamp the target zoom.
		target_zoom.x = clamp(target_zoom.x, min_zoom, max_zoom)
		target_zoom.y = clamp(target_zoom.y, min_zoom, max_zoom)

func _process(delta: float) -> void:
	# In every frame, smoothly move the current zoom towards the target zoom.
	# lerp() stands for "linear interpolation".
	zoom = lerp(zoom, target_zoom, lerp_speed * delta)
	_process_pan(delta)

func _process_pan(delta: float) -> void:
	var dir := Vector2(
		Input.get_action_strength("pan_right") - Input.get_action_strength("pan_left"),
		Input.get_action_strength("pan_down") - Input.get_action_strength("pan_up")
	)
	if dir == Vector2.ZERO:
		return
	# Normalize so diagonals aren't sqrt(2) faster than cardinals.
	dir = dir.normalized()
	# Higher zoom (more zoomed-in) → smaller world step, keeping on-screen
	# pan rate roughly constant. zoom.x is > 0 thanks to min_zoom clamp.
	global_position += dir * pan_speed * delta / zoom.x
	manual_pan_active = true
