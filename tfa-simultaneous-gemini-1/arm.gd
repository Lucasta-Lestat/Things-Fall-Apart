extends Line2D

# IK Configuration
@export var segment_count: int = 2  # Upper arm, forearm, hand
@export var segment_lengths: Array[float] = [60.0, 50.0, 30.0]
@export var total_iterations: int = 10

# Joint constraints (in degrees) - [min_angle, max_angle] relative to parent
@export var joint_constraints: Array[Vector2] = [
	Vector2(-135, 135),  # Shoulder - wide range
	Vector2(0, 145),      # Elbow - only bends one way
	Vector2(-45, 45)      # Wrist - limited rotation
]

# Points for IK chain
var joint_positions: Array[Vector2] = []
var base_position: Vector2

func _ready() -> void:
	# Initialize joint positions
	base_position = Vector2.ZERO
	_initialize_chain()

func _initialize_chain() -> void:
	joint_positions.clear()
	joint_positions.append(base_position)
	
	var current_pos = base_position
	for i in range(segment_count):
		current_pos += Vector2(segment_lengths[i], 0)
		joint_positions.append(current_pos)
	
	_update_line()

func _process(_delta: float) -> void:
	# Get mouse position relative to this node
	var target = get_local_mouse_position()
	_solve_ik(target)
	_update_line()

func _solve_ik(target: Vector2) -> void:
	for _iteration in range(total_iterations):
		# FABRIK: Forward pass (end effector to base)
		joint_positions[-1] = target
		
		for i in range(segment_count - 1, -1, -1):
			var direction = (joint_positions[i] - joint_positions[i + 1]).normalized()
			joint_positions[i] = joint_positions[i + 1] + direction * segment_lengths[i]
		
		# FABRIK: Backward pass (base to end effector)
		joint_positions[0] = base_position
		
		for i in range(segment_count):
			var direction = (joint_positions[i + 1] - joint_positions[i]).normalized()
			var constrained_dir = _apply_constraint(i, direction)
			joint_positions[i + 1] = joint_positions[i] + constrained_dir * segment_lengths[i]

func _apply_constraint(joint_index: int, direction: Vector2) -> Vector2:
	var angle = direction.angle()
	
	# Get parent angle for relative constraint
	var parent_angle: float = 0.0
	if joint_index > 0:
		var parent_dir = joint_positions[joint_index] - joint_positions[joint_index - 1]
		parent_angle = parent_dir.angle()
	
	# Calculate relative angle
	var relative_angle = angle - parent_angle
	
	# Normalize to [-PI, PI]
	while relative_angle > PI:
		relative_angle -= TAU
	while relative_angle < -PI:
		relative_angle += TAU
	
	# Apply constraints
	var min_angle = deg_to_rad(joint_constraints[joint_index].x)
	var max_angle = deg_to_rad(joint_constraints[joint_index].y)
	
	relative_angle = clamp(relative_angle, min_angle, max_angle)
	
	# Convert back to global angle
	var constrained_angle = parent_angle + relative_angle
	return Vector2.from_angle(constrained_angle)

func _update_line() -> void:
	clear_points()
	for pos in joint_positions:
		add_point(pos)
