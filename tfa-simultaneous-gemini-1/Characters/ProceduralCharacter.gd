# character.gd
# Attach to a Node2D that will be the character root
extends Node2D
class_name ProceduralCharacter

# Character data
var character_data: Dictionary = {}
var skin_color: Color = Color.BEIGE
var body_color: Color  # Derived from skin_color, slightly darker

# Body parts
var body: Line2D
var left_arm: Line2D
var right_arm: Line2D

# Movement
var target_position: Vector2
var target_rotation: float = 0.0
var is_moving: bool = false
@export var move_speed: float = 150.0
@export var rotation_speed: float = 8.0

# Arm IK settings
const ARM_SEGMENT_LENGTHS: Array[float] = [25.0, 20.0, 12.0]
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

# Body dimensions
@export var body_width: float = 20.0
@export var body_height: float = 35.0

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
	
	# Body is darker to appear "below" head
	body_color = skin_color.darkened(0.15)
	
	# Apply other properties
	if data.has("move_speed"):
		move_speed = data["move_speed"]
	
	if data.has("body_width"):
		body_width = data["body_width"]
	
	if data.has("body_height"):
		body_height = data["body_height"]
	
	# Update visuals
	_update_colors()

func _create_body_parts() -> void:
	# Create body (oval/rounded rectangle shape using Line2D)
	body = Line2D.new()
	body.name = "Body"
	body.width = body_width
	body.default_color = body_color if body_color else skin_color.darkened(0.15)
	body.begin_cap_mode = Line2D.LINE_CAP_ROUND
	body.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(body)
	
	# Body is a vertical line that will appear as an oval with round caps
	body.add_point(Vector2(0, -body_height / 2))
	body.add_point(Vector2(0, body_height / 2))
	
	# Create left arm
	left_arm = _create_arm("LeftArm")
	add_child(left_arm)
	
	# Create right arm
	right_arm = _create_arm("RightArm")
	add_child(right_arm)
	
	# Arms render behind body
	left_arm.z_index = -1
	right_arm.z_index = -1

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
	arm.width = 12.0
	
	return arm

func _initialize_arms() -> void:
	# Initialize joint arrays
	left_arm_joints.clear()
	right_arm_joints.clear()
	
	# Left arm starts at left side of body
	var left_shoulder = Vector2(-body_width / 2, -body_height / 4)
	left_arm_joints.append(left_shoulder)
	var pos = left_shoulder
	for length in ARM_SEGMENT_LENGTHS:
		pos += Vector2(-length, 0)  # Extend left
		left_arm_joints.append(pos)
	left_arm_target = left_arm_joints[-1]
	
	# Right arm starts at right side of body
	var right_shoulder = Vector2(body_width / 2, -body_height / 4)
	right_arm_joints.append(right_shoulder)
	pos = right_shoulder
	for length in ARM_SEGMENT_LENGTHS:
		pos += Vector2(length, 0)  # Extend right
		right_arm_joints.append(pos)
	right_arm_target = right_arm_joints[-1]
	
	_update_arm_visuals()

func _update_colors() -> void:
	if body:
		body.default_color = body_color
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
		target_rotation = (mouse_pos - global_position).angle()
		is_moving = false
	
	# Left click: turn and move to point
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		target_position = mouse_pos
		target_rotation = (mouse_pos - global_position).angle()
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
			
			# Swing arms while walking
			_animate_walking_arms(delta)
		else:
			is_moving = false
			emit_signal("character_reached_target")

func _animate_walking_arms(delta: float) -> void:
	# Simple arm swing based on time
	var swing = sin(Time.get_ticks_msec() * 0.01) * 20.0
	
	# Arms swing opposite to each other
	var left_shoulder = Vector2(-body_width / 2, -body_height / 4)
	var right_shoulder = Vector2(body_width / 2, -body_height / 4)
	
	# Calculate swing targets in local space, then we'll handle in IK
	var arm_length = ARM_SEGMENT_LENGTHS[0] + ARM_SEGMENT_LENGTHS[1] + ARM_SEGMENT_LENGTHS[2]
	
	left_arm_target = left_shoulder + Vector2(-arm_length * 0.7, swing)
	right_arm_target = right_shoulder + Vector2(arm_length * 0.7, -swing)

func _update_arm_ik() -> void:
	# When not moving, arms can reach toward mouse or rest position
	if not is_moving:
		var local_mouse = get_local_mouse_position()
		
		# Decide which arm reaches toward mouse based on which side it's on
		var left_shoulder = Vector2(-body_width / 2, -body_height / 4)
		var right_shoulder = Vector2(body_width / 2, -body_height / 4)
		var arm_length = ARM_SEGMENT_LENGTHS[0] + ARM_SEGMENT_LENGTHS[1] + ARM_SEGMENT_LENGTHS[2]
		
		# Rest positions
		var left_rest = left_shoulder + Vector2(-arm_length * 0.6, arm_length * 0.3)
		var right_rest = right_shoulder + Vector2(arm_length * 0.6, arm_length * 0.3)
		
		left_arm_target = left_rest
		right_arm_target = right_rest
	
	# Solve IK for both arms
	_solve_arm_ik(left_arm_joints, left_arm_target, true)
	_solve_arm_ik(right_arm_joints, right_arm_target, false)

func _solve_arm_ik(joints: Array[Vector2], target: Vector2, is_left: bool) -> void:
	var shoulder_pos = Vector2(-body_width / 2, -body_height / 4) if is_left else Vector2(body_width / 2, -body_height / 4)
	
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
	var parent_angle: float = 0.0 if is_left else PI  # Default facing direction
	if joint_idx > 0:
		var parent_dir = joints[joint_idx] - joints[joint_idx - 1]
		parent_angle = parent_dir.angle()
	
	var relative_angle = angle - parent_angle
	
	# Normalize
	while relative_angle > PI:
		relative_angle -= TAU
	while relative_angle < -PI:
		relative_angle += TAU
	
	# Mirror constraints for left arm
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
