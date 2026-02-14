# Attach this script directly to your Camera2D node.

extends Camera2D

@export var zoom_speed: float = 0.1  # How much each scroll adds/removes
@export var lerp_speed: float = 10.0 # How quickly the camera interpolates to the target zoom
@export var min_zoom: float = 0.5
@export var max_zoom: float = 3.0

# We will change this target value first, then smoothly move the actual zoom towards it.
var target_zoom: Vector2 = Vector2.ONE

func _ready() -> void:
	# Initialize the target_zoom with the camera's current zoom.
	target_zoom = zoom

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
