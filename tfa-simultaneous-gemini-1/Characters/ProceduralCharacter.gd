# character.gd
# Attach to a Node2D that will be the character root
extends Node2D
class_name ProceduralCharacter

# Character data
var character_data: Dictionary = {}
var skin_color: Color = Color.BEIGE
var hair_color: Color = Color("#4a3728")  # Default brown hair
var body_color: Color  # Derived from skin_color, slightly darker

# Body parts
var body: Line2D
var head: Line2D
var hair: Line2D
var left_arm: Line2D
var right_arm: Line2D

# Movement
var target_position: Vector2
var target_rotation: float = 0.0
var is_moving: bool = false
@export var move_speed: float = 150.0
@export var rotation_speed: float = 8.0

# Arm IK settings (smaller for top-down proportions)
const ARM_SEGMENT_LENGTHS: Array[float] = [12.0, 10.0, 6.0]
const ARM_JOINT_CONSTRAINTS: Array[Vector2] = [
	Vector2(-135, 135),  # Shoulder
	Vector2(0, 145),      # Elbow
	Vector2(-45, 45)      # Wrist
]
const IK_ITERATIONS: int = 10

# Arm state
var left_arm_joints: Array[Vector2] = []
var right_arm_joints: Array[Vector2] = []
var left_arm_target: Vector2
var right_arm_target: Vector2

# Body dimensions (top-down view: width is left-right, height is front-back)
@export var body_width: float = 28.0   # Shoulder width (horizontal)
@export var body_height: float = 14.0  # Body depth/thickness (vertical in top-down)
@export var head_width: float = 14.0   # Head width (left-right)
@export var head_length: float = 18.0  # Head length (front-back, oval shape)
@export var shoulder_y_offset: float = 4.0  # How far back shoulders are from head center (positive = back)

signal character_reached_target

func _ready() -> void:
	target_position = global_position
	_create_body_parts()
	_initialize_arms()

func load_from_data(data: Dictionary) -> void:
	character_data = data
	
	# Parse skin color
	if data.has("skin_color"):
		skin_color = Color.html(data["skin_color"])
	
	# Parse hair color
	if data.has("hair_color"):
		hair_color = Color.html(data["hair_color"])
	
	# Body is darker to appear "below" head
	body_color = skin_color.darkened(0.15)
	
	# Apply other properties
	if data.has("move_speed"):
		move_speed = data["move_speed"]
	
	if data.has("body_width"):
		body_width = data["body_width"]
	
	if data.has("body_height"):
		body_height = data["body_height"]
	
	if data.has("head_width"):
		head_width = data["head_width"]
	
	if data.has("head_length"):
		head_length = data["head_length"]
	
	# Update visuals
	_update_colors()

func _create_body_parts() -> void:
	# Create arms first (behind everything)
	left_arm = _create_arm("LeftArm")
	left_arm.z_index = -2
	add_child(left_arm)
	
	right_arm = _create_arm("RightArm")
	right_arm.z_index = -2
	add_child(right_arm)
	
	# Create body (horizontal capsule for top-down view - shoulders)
	body = Line2D.new()
	body.name = "Body"
	body.width = body_height  # Height becomes the "thickness" in top-down
	body.default_color = skin_color  # Same color as head - uniform body color
	body.begin_cap_mode = Line2D.LINE_CAP_ROUND
	body.end_cap_mode = Line2D.LINE_CAP_ROUND
	body.z_index = -1  # Behind head
	add_child(body)
	
	# Body is a horizontal line (left shoulder to right shoulder), positioned behind head
	body.add_point(Vector2(-body_width / 2, shoulder_y_offset))
	body.add_point(Vector2(body_width / 2, shoulder_y_offset))
	
	# Create hair (behind head, covers back/top of head)
	hair = Line2D.new()
	hair.name = "Hair"
	hair.width = head_width + 4  # Slightly wider than head
	hair.default_color = hair_color
	hair.begin_cap_mode = Line2D.LINE_CAP_ROUND
	hair.end_cap_mode = Line2D.LINE_CAP_ROUND
	hair.z_index = 0  # Behind head
	add_child(hair)
	
	# Hair covers the back portion of the head (positive Y = back of head)
	hair.add_point(Vector2(0, -head_length * 0.1))
	hair.add_point(Vector2(0, head_length * 0.4))
	
	# Create head (oval shape - vertical line with width for left-right dimension)
	head = Line2D.new()
	head.name = "Head"
	head.width = head_width  # Width of the oval (left-right)
	head.default_color = skin_color
	head.begin_cap_mode = Line2D.LINE_CAP_ROUND
	head.end_cap_mode = Line2D.LINE_CAP_ROUND
	head.z_index = 1  # On top of hair
	add_child(head)
	
	# Head is an oval - line goes front to back, width gives left-right dimension
	# Negative Y = front (face), Positive Y = back of head
	head.add_point(Vector2(0, -head_length * 0.35))  # Front of head (face)
	head.add_point(Vector2(0, head_length * 0.25))   # Back of head (covered by hair)

func _create_arm(arm_name: String) -> Line2D:
	var arm = Line2D.new()
	arm.name = arm_name
	arm.default_color = skin_color
	arm.begin_cap_mode = Line2D.LINE_CAP_ROUND
	arm.end_cap_mode = Line2D.LINE_CAP_ROUND
	
	# Create width curve for arm (thicker at shoulder, thinner at hand)
	var curve = Curve.new()
	curve.add_point(Vector2(0.0, 1.0))    # Shoulder: full width
	curve.add_point(Vector2(0.4, 0.85))   # Upper arm
	curve.add_point(Vector2(0.6, 0.7))    # Forearm
	curve.add_point(Vector2(1.0, 0.5))    # Hand: half width
	arm.width_curve = curve
	arm.width = 7.0  # Smaller for top-down view
	
	return arm

func _initialize_arms() -> void:
	# Initialize joint arrays
	left_arm_joints.clear()
	right_arm_joints.clear()
	
	# Shoulders are at the BACK of the body (positive Y = behind)
	# Left arm extends to the LEFT (negative X)
	var left_shoulder = Vector2(-body_width / 2, shoulder_y_offset)
	left_arm_joints.append(left_shoulder)
	var pos = left_shoulder
	for length in ARM_SEGMENT_LENGTHS:
		pos += Vector2(-length, 0)  # Extend left
		left_arm_joints.append(pos)
	left_arm_target = left_arm_joints[-1]
	
	# Right arm extends to the RIGHT (positive X)
	var right_shoulder = Vector2(body_width / 2, shoulder_y_offset)
	right_arm_joints.append(right_shoulder)
	pos = right_shoulder
	for length in ARM_SEGMENT_LENGTHS:
		pos += Vector2(length, 0)  # Extend right
		right_arm_joints.append(pos)
	right_arm_target = right_arm_joints[-1]
	
	_update_arm_visuals()

func _update_colors() -> void:
	if body:
		body.default_color = skin_color  # Same as head
	if head:
		head.default_color = skin_color
	if hair:
		hair.default_color = hair_color
	if left_arm:
		left_arm.default_color = skin_color
	if right_arm:
		right_arm.default_color = skin_color

func _process(delta: float) -> void:
	_handle_input()
	_update_movement(delta)
	_update_arm_ik()
	_update_arm_visuals()

func _handle_input() -> void:
	# Get correct mouse position accounting for SubViewport scaling
	var mouse_pos = _get_adjusted_mouse_position()
	
	# Right click: turn to face point
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		# Add PI/2 (90 degrees) because our character's forward is -Y, not +X
		target_rotation = (mouse_pos - global_position).angle() + PI / 2
		is_moving = false
	
	# Left click: turn and move to point
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		target_position = mouse_pos
		# Add PI/2 (90 degrees) because our character's forward is -Y, not +X
		target_rotation = (mouse_pos - global_position).angle() + PI / 2
		is_moving = true

func _get_adjusted_mouse_position() -> Vector2:
	# Check if we're inside a SubViewport
	var vp = get_viewport()
	var parent = vp.get_parent()
	
	if parent is SubViewportContainer:
		# Get mouse position relative to the container
		var container = parent as SubViewportContainer
		var screen_mouse = DisplayServer.mouse_get_position()
		var window_pos = get_window().position
		var local_mouse = Vector2(screen_mouse) - Vector2(window_pos)
		
		# Account for container position and scaling
		local_mouse -= container.global_position
		
		# Scale factor between container and viewport
		var scale_factor = Vector2(vp.size) / container.size
		local_mouse *= scale_factor
		
		# Convert to global coords within the SubViewport
		# We need to account for camera/transform
		var canvas_transform = vp.canvas_transform
		return canvas_transform.affine_inverse() * local_mouse
	else:
		# Regular viewport, use standard method
		return get_global_mouse_position()

func _update_movement(delta: float) -> void:
	# Smoothly rotate toward target
	var angle_diff = wrapf(target_rotation - rotation, -PI, PI)
	rotation += sign(angle_diff) * min(abs(angle_diff), rotation_speed * delta)
	
	# Move toward target if moving
	if is_moving:
		var to_target = target_position - global_position
		var distance = to_target.length()
		
		if distance > 5.0:
			var move_dir = to_target.normalized()
			global_position += move_dir * min(move_speed * delta, distance)
		else:
			is_moving = false
			emit_signal("character_reached_target")

func _update_arm_ik() -> void:
	# Shoulder positions - at the sides and toward the back
	var left_shoulder = Vector2(-body_width / 2, shoulder_y_offset)
	var right_shoulder = Vector2(body_width / 2, shoulder_y_offset)
	var arm_length = ARM_SEGMENT_LENGTHS[0] + ARM_SEGMENT_LENGTHS[1] + ARM_SEGMENT_LENGTHS[2]
	
	# Rest positions: arms curling forward and inward (hands near front of body)
	# Negative Y = forward, hands come inward toward center
	left_arm_target = left_shoulder + Vector2(arm_length * 0.3, -arm_length * 0.6)
	right_arm_target = right_shoulder + Vector2(-arm_length * 0.3, -arm_length * 0.6)
	
	# Solve IK for both arms
	_solve_arm_ik(left_arm_joints, left_arm_target, true)
	_solve_arm_ik(right_arm_joints, right_arm_target, false)

func _solve_arm_ik(joints: Array[Vector2], target: Vector2, is_left: bool) -> void:
	var shoulder_pos = Vector2(-body_width / 2, shoulder_y_offset) if is_left else Vector2(body_width / 2, shoulder_y_offset)
	
	for _iter in range(IK_ITERATIONS):
		# Forward pass: end to base
		joints[-1] = target
		for i in range(ARM_SEGMENT_LENGTHS.size() - 1, -1, -1):
			var dir = (joints[i] - joints[i + 1]).normalized()
			joints[i] = joints[i + 1] + dir * ARM_SEGMENT_LENGTHS[i]
		
		# Backward pass: base to end
		joints[0] = shoulder_pos
		for i in range(ARM_SEGMENT_LENGTHS.size()):
			var dir = (joints[i + 1] - joints[i]).normalized()
			var constrained = _apply_arm_constraint(joints, i, dir, is_left)
			joints[i + 1] = joints[i] + constrained * ARM_SEGMENT_LENGTHS[i]

func _apply_arm_constraint(joints: Array[Vector2], joint_idx: int, direction: Vector2, is_left: bool) -> Vector2:
	var angle = direction.angle()
	
	# Get parent angle
	var parent_angle: float
	if joint_idx == 0:
		# Shoulder: default arm direction is outward horizontally
		if is_left:
			parent_angle = PI  # 180 degrees (pointing left)
		else:
			parent_angle = 0.0  # 0 degrees (pointing right)
	else:
		var parent_dir = joints[joint_idx] - joints[joint_idx - 1]
		parent_angle = parent_dir.angle()
	
	var relative_angle = angle - parent_angle
	
	# Normalize
	while relative_angle > PI:
		relative_angle -= TAU
	while relative_angle < -PI:
		relative_angle += TAU
	
	# Apply constraints
	var constraint = ARM_JOINT_CONSTRAINTS[joint_idx]
	var min_ang = deg_to_rad(constraint.x)
	var max_ang = deg_to_rad(constraint.y)
	
	if is_left:
		# Mirror the constraints for left arm
		var temp = -max_ang
		max_ang = -min_ang
		min_ang = temp
	
	relative_angle = clamp(relative_angle, min_ang, max_ang)
	
	return Vector2.from_angle(parent_angle + relative_angle)

func _update_arm_visuals() -> void:
	if left_arm:
		left_arm.clear_points()
		for joint in left_arm_joints:
			left_arm.add_point(joint)
	
	if right_arm:
		right_arm.clear_points()
		for joint in right_arm_joints:
			right_arm.add_point(joint)
