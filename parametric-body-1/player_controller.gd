extends CharacterBody2D
class_name PlayerController

@export var move_speed: float = 150.0
@export var arrival_threshold: float = 5.0
@export var show_debug_target: bool = false
@onready var character: ProceduralCharacter = $ProceduralCharacter

var target_position: Vector2 = Vector2.ZERO
var is_moving: bool = false

func _ready():
	# Ensure we have a ProceduralCharacter child
	if not character:
		character = ProceduralCharacter.new()
		add_child(character)
	
	# Initialize target position to current position
	target_position = global_position

func _input(event):
	# Handle mouse clicks
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			# Set new target position
			target_position = get_global_mouse_position()
			is_moving = true

func _physics_process(delta):
	# Calculate direction to target
	var direction = target_position - global_position
	var distance = direction.length()
	
	# Check if we've arrived at the target
	if distance <= arrival_threshold:
		is_moving = false
		character.stop_walking()
		velocity = Vector2.ZERO
	else:
		# Normalize direction and apply movement
		direction = direction.normalized()
		velocity = direction * move_speed
		
		# Update character animation
		if is_moving:
			character.start_walking(direction)
			character.face_direction_from_input(direction)
	
	# Always update eye tracking to mouse position
	var mouse_pos = get_global_mouse_position()
	var eye_direction = (mouse_pos - global_position).normalized()
	character.update_eye_tracking(eye_direction)
	
	# Move the character
	move_and_slide()
	
	# Update debug visualization if enabled
	if show_debug_target and is_moving:
		character.set_debug_target(to_local(target_position))
	else:
		character.set_debug_target(Vector2.ZERO)

# Example of how to customize character appearance
func set_character_appearance(female: bool, color: Color):
	character.is_female = female
	character.body_color = color
