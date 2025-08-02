extends Node2D
class_name ProceduralCharacter

# Character properties
@export var is_female: bool = false
@export var body_color: Color = Color.WHITE
@export var head_radius: float = 20.0
@export var body_width: float = 30.0
@export var body_height: float = 50.0
@export var hand_radius: float = 8.0
@export var foot_radius: float = 10.0
@export var eye_radius: float = 3.0
@export var pupil_radius: float = 2.0
@export var walk_speed: float = 100.0
@export var limb_speed: float = 8.0
@export var limb_amplitude: float = 15.0

# Animation parameters
var facing_direction: Vector2 = Vector2.DOWN
var eye_look_direction: Vector2 = Vector2.DOWN
var is_walking: bool = false
var walk_cycle: float = 0.0
var velocity: Vector2 = Vector2.ZERO
var debug_target: Vector2 = Vector2.ZERO

# Body parts
var head_pos: Vector2 = Vector2.ZERO
var body_pos: Vector2 = Vector2.ZERO
var left_hand_pos: Vector2 = Vector2.ZERO
var right_hand_pos: Vector2 = Vector2.ZERO
var left_foot_pos: Vector2 = Vector2.ZERO
var right_foot_pos: Vector2 = Vector2.ZERO
var left_eye_pos: Vector2 = Vector2.ZERO
var right_eye_pos: Vector2 = Vector2.ZERO
var left_pupil_pos: Vector2 = Vector2.ZERO
var right_pupil_pos: Vector2 = Vector2.ZERO

# IK targets
var left_hand_target: Vector2 = Vector2.ZERO
var right_hand_target: Vector2 = Vector2.ZERO
var left_foot_target: Vector2 = Vector2.ZERO
var right_foot_target: Vector2 = Vector2.ZERO

# Constants
const ARM_LENGTH: float = 35.0
const LEG_LENGTH: float = 40.0
const SHOULDER_WIDTH: float = 20.0
const HIP_WIDTH: float = 15.0
const HEAD_OFFSET: float = 25.0
const EYE_SPACING: float = 8.0
const PUPIL_LOOK_RANGE: float = 1.5

func _ready():
	set_process(true)
	update_body_positions()
	# Initialize limb positions to their targets
	left_hand_pos = left_hand_target
	right_hand_pos = right_hand_target
	left_foot_pos = left_foot_target
	right_foot_pos = right_foot_target

func _process(delta):
	if is_walking:
		walk_cycle += delta * limb_speed
		update_limb_targets()
	
	update_limb_positions(delta)
	update_eye_positions()
	queue_redraw()

func _draw():
	# Clear any previous draws (this is handled by Godot automatically)
	
	# Draw shadow
	#draw_circle(Vector2(0, body_height/2 + foot_radius), 25, Color(0, 0, 0, 0.3))
	
	# Draw body
	if is_female:
		draw_hourglass_body()
	else:
		draw_rectangle_body()
	
	# Draw head
	draw_circle(head_pos, head_radius, body_color)
	draw_circle(head_pos, head_radius - 2, body_color.darkened(0.1))
	
	# Draw eyes
	draw_circle(left_eye_pos, eye_radius, Color.WHITE)
	draw_circle(right_eye_pos, eye_radius, Color.WHITE)
	draw_circle(left_pupil_pos, pupil_radius, Color.BLACK)
	draw_circle(right_pupil_pos, pupil_radius, Color.BLACK)
	
	# Draw limbs (simple lines for now, can be enhanced)
	var shoulder_left = body_pos + Vector2(-SHOULDER_WIDTH/2, -body_height/3)
	var shoulder_right = body_pos + Vector2(SHOULDER_WIDTH/2, -body_height/3)
	var hip_left = body_pos + Vector2(-HIP_WIDTH/2, body_height/3)
	var hip_right = body_pos + Vector2(HIP_WIDTH/2, body_height/3)
	
	# Arms
	draw_line(shoulder_left, left_hand_pos, body_color.darkened(0.2), 3.0)
	draw_line(shoulder_right, right_hand_pos, body_color.darkened(0.2), 3.0)
	
	# Legs
	draw_line(hip_left, left_foot_pos, body_color.darkened(0.2), 4.0)
	draw_line(hip_right, right_foot_pos, body_color.darkened(0.2), 4.0)
	
	# Draw hands and feet
	draw_circle(left_hand_pos, hand_radius, body_color.lightened(0.1))
	draw_circle(right_hand_pos, hand_radius, body_color.lightened(0.1))
	draw_circle(left_foot_pos, foot_radius, body_color.darkened(0.3))
	draw_circle(right_foot_pos, foot_radius, body_color.darkened(0.3))
	
	# Draw debug target if set
	if debug_target != Vector2.ZERO:
		draw_circle(debug_target, 3, Color.GREEN)
		draw_circle(debug_target, 8, Color(0, 1, 0, 0.3))

func draw_rectangle_body():
	var rect = Rect2(body_pos - Vector2(body_width/2, body_height/2), Vector2(body_width, body_height))
	draw_rect(rect, body_color)
	draw_rect(Rect2(rect.position + Vector2(2, 2), rect.size - Vector2(4, 4)), body_color.darkened(0.1))

func draw_hourglass_body():
	var points = PackedVector2Array()
	var segments = 16
	
	for i in range(segments + 1):
		var t = float(i) / float(segments)
		var y = -body_height/2 + body_height * t
		
		# Hourglass curve
		var width_factor = 0.7 + 0.3 * abs(cos(t * PI))
		var x = body_width/2 * width_factor
		
		points.append(body_pos + Vector2(x, y))
	
	for i in range(segments, -1, -1):
		var t = float(i) / float(segments)
		var y = -body_height/2 + body_height * t
		
		var width_factor = 0.7 + 0.3 * abs(cos(t * PI))
		var x = -body_width/2 * width_factor
		
		points.append(body_pos + Vector2(x, y))
	
	draw_polygon(points, PackedColorArray([body_color]))
	
	# Inner detail
	var inner_points = PackedVector2Array()
	for point in points:
		var dir = (point - body_pos).normalized()
		inner_points.append(point - dir * 2)
	draw_polygon(inner_points, PackedColorArray([body_color.darkened(0.1)]))

func update_body_positions():
	body_pos = Vector2.ZERO
	head_pos = body_pos + Vector2(0, -body_height/2 - HEAD_OFFSET)
	
	# Set default limb positions
	left_hand_target = body_pos + Vector2(-SHOULDER_WIDTH/2 - 10, 0)
	right_hand_target = body_pos + Vector2(SHOULDER_WIDTH/2 + 10, 0)
	left_foot_target = body_pos + Vector2(-HIP_WIDTH/2, body_height/2 + LEG_LENGTH)
	right_foot_target = body_pos + Vector2(HIP_WIDTH/2, body_height/2 + LEG_LENGTH)

func update_limb_targets():
	var cycle_sin = sin(walk_cycle)
	var cycle_cos = cos(walk_cycle)
	
	# Calculate movement direction offsets
	var forward = facing_direction * limb_amplitude
	var side = facing_direction.rotated(PI/2) * limb_amplitude * 0.5
	
	# Animate hands
	left_hand_target = body_pos + Vector2(-SHOULDER_WIDTH/2, 0) + forward * cycle_sin + side * 0.3
	right_hand_target = body_pos + Vector2(SHOULDER_WIDTH/2, 0) - forward * cycle_sin - side * 0.3
	
	# Animate feet
	left_foot_target = body_pos + Vector2(-HIP_WIDTH/2, body_height/2 + LEG_LENGTH) + forward * cycle_cos
	right_foot_target = body_pos + Vector2(HIP_WIDTH/2, body_height/2 + LEG_LENGTH) - forward * cycle_cos
	
	# Add vertical movement for feet
	if cycle_sin > 0:
		left_foot_target.y -= abs(cycle_sin) * 5
	else:
		right_foot_target.y -= abs(cycle_sin) * 5

func update_limb_positions(delta):
	var ik_speed = 10.0 * delta
	
	# Smooth interpolation to targets
	left_hand_pos = left_hand_pos.lerp(left_hand_target, ik_speed)
	right_hand_pos = right_hand_pos.lerp(right_hand_target, ik_speed)
	left_foot_pos = left_foot_pos.lerp(left_foot_target, ik_speed)
	right_foot_pos = right_foot_pos.lerp(right_foot_target, ik_speed)
	
	# Apply IK constraints
	var shoulder_left = body_pos + Vector2(-SHOULDER_WIDTH/2, -body_height/3)
	var shoulder_right = body_pos + Vector2(SHOULDER_WIDTH/2, -body_height/3)
	var hip_left = body_pos + Vector2(-HIP_WIDTH/2, body_height/3)
	var hip_right = body_pos + Vector2(HIP_WIDTH/2, body_height/3)
	
	left_hand_pos = apply_ik_constraint(shoulder_left, left_hand_pos, ARM_LENGTH)
	right_hand_pos = apply_ik_constraint(shoulder_right, right_hand_pos, ARM_LENGTH)
	left_foot_pos = apply_ik_constraint(hip_left, left_foot_pos, LEG_LENGTH)
	right_foot_pos = apply_ik_constraint(hip_right, right_foot_pos, LEG_LENGTH)

func apply_ik_constraint(origin: Vector2, target: Vector2, max_length: float) -> Vector2:
	var distance = origin.distance_to(target)
	if distance > max_length:
		var direction = (target - origin).normalized()
		return origin + direction * max_length
	return target

func update_eye_positions():
	var eye_offset = Vector2(0, -5)
	left_eye_pos = head_pos + eye_offset + Vector2(-EYE_SPACING/2, 0)
	right_eye_pos = head_pos + eye_offset + Vector2(EYE_SPACING/2, 0)
	
	# Make pupils look at target direction (independent of body facing)
	var pupil_offset = eye_look_direction * PUPIL_LOOK_RANGE
	left_pupil_pos = left_eye_pos + pupil_offset
	right_pupil_pos = right_eye_pos + pupil_offset

func update_eye_tracking(look_direction: Vector2):
	eye_look_direction = look_direction.normalized()

func set_facing_direction(direction: Vector2):
	facing_direction = direction.normalized()
	update_eye_positions()

func start_walking(direction: Vector2):
	is_walking = true
	velocity = direction.normalized() * walk_speed
	set_facing_direction(direction)

func stop_walking():
	is_walking = false
	velocity = Vector2.ZERO
	walk_cycle = 0.0
	update_body_positions()
	# Reset limb positions to defaults when stopping
	left_hand_pos = left_hand_target
	right_hand_pos = right_hand_target
	left_foot_pos = left_foot_target
	right_foot_pos = right_foot_target

func get_velocity() -> Vector2:
	return velocity

# Helper function to determine facing direction from input
func face_direction_from_input(input_vector: Vector2):
	if input_vector.length() < 0.1:
		return
	
	# Determine primary direction (4-way)
	if abs(input_vector.x) > abs(input_vector.y):
		if input_vector.x > 0:
			set_facing_direction(Vector2.RIGHT)
		else:
			set_facing_direction(Vector2.LEFT)
	else:
		if input_vector.y > 0:
			set_facing_direction(Vector2.DOWN)
		else:
			set_facing_direction(Vector2.UP)

func set_debug_target(target: Vector2):
	debug_target = target
	queue_redraw()
