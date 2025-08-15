# WeaponMotor.gd
extends Node
class_name WeaponMotor

var current_weapon: PhysicsWeapon = null
var target_path: Array = []
var path_index: int = 0
var attack_type: String = ""
var motor_strength: float = 100.0
var is_active: bool = false

@export var max_force: float = 1000.0
@export var max_torque: float = 500.0
@export var path_tolerance: float = 5.0

signal attack_completed()
signal attack_interrupted()

func _ready():
	set_physics_process(false)

		
func execute_attack(weapon: PhysicsWeapon, path: Array, type: String, strength: float):
	if is_active:
		return
	
	current_weapon = weapon
	target_path = path
	path_index = 0
	attack_type = type
	motor_strength = strength
	is_active = true
	
	weapon.start_swing()
	set_physics_process(true)

func _physics_process(delta):
	if not is_active or not current_weapon or path_index >= target_path.size():
		_complete_attack()
		return
	
	var target_position = target_path[path_index]
	var current_position = current_weapon.global_position
	
	# Calculate error vector
	var error = target_position - current_position
	var distance = error.length()
	
	# Check if we've reached the current path point
	if distance < path_tolerance:
		path_index += 1
		if path_index >= target_path.size():
			_complete_attack()
			return
	
	# Calculate force to apply
	var force_direction = error.normalized()
	var force_magnitude = min(motor_strength * 10.0, max_force)
	
	# Scale force based on distance (P controller)
	force_magnitude *= clamp(distance / 50.0, 0.1, 1.0)
	
	# Apply force to weapon
	var force = force_direction * force_magnitude
	current_weapon.apply_central_force(force)
	
	# Calculate and apply torque for proper orientation
	var desired_angle = _get_desired_angle()
	var current_angle = current_weapon.rotation
	var angle_error = angle_difference(current_angle, desired_angle)
	
	var torque = clamp(angle_error * motor_strength * 5.0, -max_torque, max_torque)
	current_weapon.apply_torque(torque)
	
	# Add velocity prediction for smoother movement
	if path_index < target_path.size() - 1:
		var next_target = target_path[path_index + 1]
		var predicted_velocity = (next_target - target_position).normalized() * motor_strength
		current_weapon.apply_central_force(predicted_velocity * 0.3)

func _get_desired_angle() -> float:
	if path_index >= target_path.size() - 1:
		return current_weapon.rotation
	
	var current_target = target_path[path_index]
	var next_target = target_path[min(path_index + 1, target_path.size() - 1)]
	var direction = (next_target - current_target).normalized()
	
	# Adjust angle based on attack type
	match attack_type:
		"thrust":
			return direction.angle()
		"slash":
			# Perpendicular to movement for slashing
			return direction.angle() + PI/2
		_:
			return direction.angle()

func _complete_attack():
	if current_weapon:
		current_weapon.end_swing()
	
	is_active = false
	set_physics_process(false)
	attack_completed.emit()

func interrupt_attack():
	if current_weapon:
		current_weapon.end_swing()
	
	is_active = false
	set_physics_process(false)
	attack_interrupted.emit()

func angle_difference(from: float, to: float) -> float:
	var diff = to - from
	while diff > PI:
		diff -= TAU
	while diff < -PI:
		diff += TAU
	return diff
