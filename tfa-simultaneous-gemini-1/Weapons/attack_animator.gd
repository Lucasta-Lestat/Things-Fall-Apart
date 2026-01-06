# attack_animator.gd
extends Node
class_name AttackAnimator

enum DamageType { SLASHING, PIERCING, BLUDGEONING }
enum AttackState { IDLE, WINDUP, STRIKE, RECOVERY }

signal attack_started(damage_type: String)
signal attack_hit_frame()
signal attack_finished()
var is_attacking: bool

# Animation state
var current_state: AttackState = AttackState.IDLE
var attack_timer: float = 0.0
var attack_progress: float = 0.0

# Animation timing
var windup_duration: float = 0.15
var strike_duration: float = 0.1
var recovery_duration: float = 0.2
var current_rotation_intensity: float = 1.0

# Attack data
var current_damage_type: String = "slashing"
var attack_direction: Vector2 = Vector2.UP

# Visual Offsets - now supports both hands
var animated_arm_offset: Vector2 = Vector2.ZERO
var animated_weapon_rotation: float = 0.0
var animated_body_rotation: float = 0.0

# Legacy getter compatibility

var animated_right_arm_offset: Vector2:
	get: return animated_arm_offset if character.current_hand == "Main" else Vector2.ZERO
var animated_left_arm_offset: Vector2:
	get: return animated_arm_offset if character.current_hand == "Off" else Vector2.ZERO

var knockback_velocity: Vector2 = Vector2.ZERO
var knockback_friction: float = 1500.0
var knockback_active: bool = false

# ===== SECOND ORDER DYNAMICS =====
# Spring-damper system for realistic motion with overshoot and settling
# Based on: https://www.youtube.com/watch?v=KPoeNZZ6H4s (t3ssel8r)

class SecondOrderDynamics:
	var xp: Vector2  # Previous input
	var y: Vector2   # Current position
	var yd: Vector2  # Current velocity
	
	# Dynamics constants
	var k1: float  # Damping
	var k2: float  # Spring stiffness (response speed)
	var k3: float  # Anticipation/overshoot
	
	func _init(f: float = 3.0, z: float = 0.5, r: float = 1.0, x0: Vector2 = Vector2.ZERO):
		# f = natural frequency (speed of response)
		# z = damping coefficient (0 = undamped, 1 = critically damped, >1 = overdamped)
		# r = initial response (0 = smooth start, 1 = immediate, 2 = overshoot anticipation)
		_compute_constants(f, z, r)
		xp = x0
		y = x0
		yd = Vector2.ZERO
	
	func _compute_constants(f: float, z: float, r: float) -> void:
		k1 = z / (PI * f)
		k2 = 1.0 / ((2.0 * PI * f) * (2.0 * PI * f))
		k3 = r * z / (2.0 * PI * f)
	
	func update(delta: float, x: Vector2, xd: Vector2 = Vector2.INF) -> Vector2:
		# x = target position
		# xd = target velocity (estimated if not provided)
		if xd == Vector2.INF:
			xd = (x - xp) / delta
			xp = x
		
		# Clamp k2 to maintain stability at variable framerates
		var k2_stable = maxf(k2, maxf(delta * delta / 2.0 + delta * k1 / 2.0, delta * k1))
		
		# Integrate position by velocity
		y = y + delta * yd
		# Integrate velocity by acceleration
		yd = yd + delta * (x + k3 * xd - y - k1 * yd) / k2_stable
		
		return y
	
	func reset(x0: Vector2) -> void:
		xp = x0
		y = x0
		yd = Vector2.ZERO
	
	func set_position(pos: Vector2) -> void:
		y = pos
	
	func set_velocity(vel: Vector2) -> void:
		yd = vel

class SecondOrderFloat:
	var xp: float
	var y: float
	var yd: float
	var k1: float
	var k2: float
	var k3: float
	
	func _init(f: float = 3.0, z: float = 0.5, r: float = 1.0, x0: float = 0.0):
		_compute_constants(f, z, r)
		xp = x0
		y = x0
		yd = 0.0
	
	func _compute_constants(f: float, z: float, r: float) -> void:
		k1 = z / (PI * f)
		k2 = 1.0 / ((2.0 * PI * f) * (2.0 * PI * f))
		k3 = r * z / (2.0 * PI * f)
	
	func update(delta: float, x: float, xd: float = INF) -> float:
		if xd == INF:
			xd = (x - xp) / delta
			xp = x
		
		var k2_stable = maxf(k2, maxf(delta * delta / 2.0 + delta * k1 / 2.0, delta * k1))
		
		y = y + delta * yd
		yd = yd + delta * (x + k3 * xd - y - k1 * yd) / k2_stable
		
		return y
	
	func reset(x0: float) -> void:
		xp = x0
		y = x0
		yd = 0.0
	
	func set_position(pos: float) -> void:
		y = pos
	
	func set_velocity(vel: float) -> void:
		yd = vel

# Second order dynamics instances for smooth animation
var arm_dynamics: SecondOrderDynamics
var weapon_rot_dynamics: SecondOrderFloat
var body_rot_dynamics: SecondOrderFloat

# Target values for dynamics system
var target_arm_offset: Vector2 = Vector2.ZERO
var target_weapon_rotation: float = 0.0
var target_body_rotation: float = 0.0

# Reference to character
var character: Node2D
@onready var combat_manager = get_node("/root/TopDownCharacterScene")

func _ready() -> void:
	character = get_parent()
	_init_dynamics()

func _init_dynamics() -> void:
	# f=frequency (higher=faster), z=damping (0.5=bouncy, 1=critical), r=response (>1 = anticipation)
	# Strike: Fast, slightly bouncy for weapon impact feel
	arm_dynamics = SecondOrderDynamics.new(8.0, 0.6, 1.5, Vector2.ZERO)
	weapon_rot_dynamics = SecondOrderFloat.new(10.0, 0.5, 2.0, 0.0)
	body_rot_dynamics = SecondOrderFloat.new(6.0, 0.7, 1.0, 0.0)

func _process(delta: float) -> void:
	if knockback_active:
		_update_knockback_physics(delta)
		return

	if current_state == AttackState.IDLE:
		return
	
	attack_timer += delta
	_update_animation(delta)
	

func start_attack(damage_type: String, direction: Vector2 = Vector2.UP, hand: String = "Main") -> void:
	if combat_manager == null: 
		combat_manager = get_node("root/TopDownCharacterScene")
	is_attacking = true
	combat_manager.register_attack_start(character)
	if current_state != AttackState.IDLE: 
		return
	
	current_damage_type = damage_type
	attack_direction = direction.normalized()
	current_state = AttackState.WINDUP
	attack_timer = 0.0
	
	# Reset dynamics for fresh attack
	_reset_dynamics()
	
	var dex: float = 10
	var weight: float = 4.0
	
	if "dexterity" in character: 
		dex = character.dexterity
	
	# Get weapon from the appropriate hand
	var weapon = null
	if hand == "Main" and "current_main_hand_weapon" in character:
		weapon = character.current_main_hand_weapon
	elif hand == "Off" and "current_off_hand_weapon" in character:
		weapon = character.current_off_hand_weapon
	
	if weapon != null:
		weight = weapon.weight
	
	weight = max(0.1, weight)
	var speed_multiplier = clamp((dex / 100.0) / (weight / 4.0), 0.4, 3.0)
	current_rotation_intensity = clamp(weight / 4.5, 0.4, 1.4)
	
	# Adjust dynamics based on weapon weight (heavier = slower response, more momentum)
	var weight_factor = clamp(weight / 4.0, 0.5, 2.0)
	arm_dynamics = SecondOrderDynamics.new(8.0 / weight_factor, 0.5 + weight_factor * 0.1, 1.5, Vector2.ZERO)
	weapon_rot_dynamics = SecondOrderFloat.new(10.0 / weight_factor, 0.4 + weight_factor * 0.15, 2.0, 0.0)
	body_rot_dynamics = SecondOrderFloat.new(6.0 / weight_factor, 0.6 + weight_factor * 0.1, 1.0, 0.0)
	
	match damage_type:
		"slashing":
			windup_duration = 0.18; strike_duration = 0.10; recovery_duration = 0.22
		"piercing":
			windup_duration = 0.22; strike_duration = 0.06; recovery_duration = 0.25
		"bludgeoning":
			windup_duration = 0.28; strike_duration = 0.08; recovery_duration = 0.30
	
	windup_duration /= speed_multiplier
	strike_duration /= speed_multiplier
	recovery_duration /= speed_multiplier
	
	emit_signal("attack_started", damage_type)

func _finish_attack() -> void:
	current_state = AttackState.IDLE
	attack_timer = 0.0
	_reset_offsets()
	
	if combat_manager and character is ProceduralCharacter:
		combat_manager.register_attack_end(character)
	is_attacking = false
	emit_signal("attack_finished")

# ===== FEEDBACK FUNCTIONS =====

func push_character(direction: Vector2, force: float) -> void:
	interrupt_attack()
	knockback_active = true

	var char_weight: float = 70.0
	if "weight" in character:
		char_weight = float(character.weight)

	char_weight = max(1.0, char_weight)

	var impulse_speed = force / char_weight
	var game_unit_multiplier = 50.0 
	knockback_velocity = direction.normalized() * (impulse_speed * game_unit_multiplier)

	if character is CharacterBody2D:
		character.velocity = knockback_velocity

func _update_knockback_physics(delta: float) -> void:
	if knockback_velocity.length() > 0:
		knockback_velocity = knockback_velocity.move_toward(Vector2.ZERO, knockback_friction * delta)
		
		if character is CharacterBody2D:
			character.velocity = knockback_velocity
			character.move_and_slide()
	else:
		knockback_active = false
		knockback_velocity = Vector2.ZERO

# ===== ANIMATION UPDATES =====
func _update_animation(delta: float) -> void:
	match current_state:
		AttackState.WINDUP:
			attack_progress = attack_timer / windup_duration
			_animate_windup()
			if attack_timer >= windup_duration:
				current_state = AttackState.STRIKE
				attack_timer = 0.0
		
		AttackState.STRIKE:
			attack_progress = attack_timer / strike_duration
			_animate_strike()
			if attack_progress >= 0.5 and attack_progress - (get_process_delta_time() / strike_duration) < 0.5:
				emit_signal("attack_hit_frame")
			if attack_timer >= strike_duration:
				current_state = AttackState.RECOVERY
				attack_timer = 0.0
		
		AttackState.RECOVERY:
			attack_progress = attack_timer / recovery_duration
			_animate_recovery()
			if attack_timer >= recovery_duration:
				current_state = AttackState.IDLE
				attack_timer = 0.0
				_reset_offsets()
				emit_signal("attack_finished")
				_finish_attack()
	# Apply second-order dynamics to smooth all animations
	_apply_dynamics(delta)

func _apply_dynamics(delta: float) -> void:
	# Update positions using spring-damper system for natural motion
	animated_arm_offset = arm_dynamics.update(delta, target_arm_offset)
	animated_weapon_rotation = weapon_rot_dynamics.update(delta, target_weapon_rotation)
	animated_body_rotation = body_rot_dynamics.update(delta, target_body_rotation)

func _get_hand_mirror() -> float:
	# Returns -1 for Off hand (left), 1 for Main hand (right)
	return -1.0 if character.current_hand == "Off" else 1.0

func _mirror_offset(offset: Vector2) -> Vector2:
	# Mirror the X component for off-hand attacks
	return Vector2(offset.x * _get_hand_mirror(), offset.y)

func _animate_windup() -> void:
	match current_damage_type:
		"slashing": _animate_slash_windup()
		"piercing": _animate_thrust_windup()
		"bludgeoning": _animate_smash_windup()

func _animate_strike() -> void:
	match current_damage_type:
		"slashing": _animate_slash_strike()
		"piercing": _animate_thrust_strike()
		"bludgeoning": _animate_smash_strike()

func _animate_recovery() -> void:
	var ease_out = 1.0 - _ease_out_quad(attack_progress)
	var mirror = _get_hand_mirror()
	
	match current_damage_type:
		"slashing":
			target_arm_offset = _mirror_offset(Vector2(-20, -15)) * ease_out
			target_weapon_rotation = -1.5 * mirror * ease_out
			target_body_rotation = (-0.25 * ease_out * mirror) * current_rotation_intensity
		"piercing":
			target_arm_offset = _mirror_offset(Vector2(0, -55)) * ease_out
			target_weapon_rotation = -0.05 * mirror * ease_out
			target_body_rotation = (-0.2 * ease_out * mirror) * current_rotation_intensity
		"bludgeoning":
			target_arm_offset = _mirror_offset(Vector2(0, -25)) * ease_out
			target_weapon_rotation = 0.4 * mirror * ease_out
			target_body_rotation = (-0.15 * ease_out * mirror) * current_rotation_intensity

func _animate_slash_windup() -> void:
	var ease_in = _ease_in_quad(attack_progress)
	var mirror = _get_hand_mirror()
	
	target_arm_offset = _mirror_offset(Vector2(18, 12)) * ease_in
	target_weapon_rotation = 1.2 * mirror * ease_in
	target_body_rotation = (0.3 * ease_in * mirror) * current_rotation_intensity

func _animate_slash_strike() -> void:
	var ease_progress = _ease_out_cubic(attack_progress)
	var mirror = _get_hand_mirror()
	# Set targets - dynamics system handles the interpolation with overshoot
	var start_offset = _mirror_offset(Vector2(18, 12))
	var end_offset = _mirror_offset(Vector2(-20, -15))
	target_arm_offset = _second_order_vec2(start_offset, end_offset, ease_progress)
	target_weapon_rotation = _second_order_float(1.2 * mirror, -1.5 * mirror, ease_progress)
	target_body_rotation = _second_order_float(
		0.3 * current_rotation_intensity * mirror, 
		-0.25 * current_rotation_intensity * mirror, 
		ease_progress
	)

func _animate_thrust_windup() -> void:
	var ease_in = _ease_in_quad(attack_progress)
	var mirror = _get_hand_mirror()
	
	target_arm_offset = _mirror_offset(Vector2(15, 35)) * ease_in
	target_weapon_rotation = 0.4 * mirror * ease_in
	target_body_rotation = (0.25 * ease_in * mirror) * current_rotation_intensity

func _animate_thrust_strike() -> void:
	var ease_progress = _ease_out_cubic(attack_progress)
	var mirror = _get_hand_mirror()
	
	var start_offset = _mirror_offset(Vector2(15, 35))
	var end_offset = _mirror_offset(Vector2(0, -55))
	target_arm_offset = _second_order_vec2(start_offset, end_offset, ease_progress)
	target_weapon_rotation = _second_order_float(0.4 * mirror, -0.05 * mirror, ease_progress)
	target_body_rotation = _second_order_float(
		0.25 * current_rotation_intensity * mirror, 
		-0.2 * current_rotation_intensity * mirror, 
		ease_progress
	)

func _animate_smash_windup() -> void:
	var ease_in = _ease_in_quad(attack_progress)
	var mirror = _get_hand_mirror()
	
	target_arm_offset = _mirror_offset(Vector2(10, 20)) * ease_in
	target_weapon_rotation = 2.0 * mirror * ease_in
	target_body_rotation = (0.2 * ease_in * mirror) * current_rotation_intensity

func _animate_smash_strike() -> void:
	var ease_progress = _ease_out_cubic(attack_progress)
	var mirror = _get_hand_mirror()
	
	var start_offset = _mirror_offset(Vector2(10, 20))
	var end_offset = _mirror_offset(Vector2(0, -25))
	target_arm_offset = _second_order_vec2(start_offset, end_offset, ease_progress)
	target_weapon_rotation = _second_order_float(2.0 * mirror, 0.4 * mirror, ease_progress)
	target_body_rotation = _second_order_float(
		0.2 * current_rotation_intensity * mirror, 
		-0.15 * current_rotation_intensity * mirror, 
		ease_progress
	)

# ===== SECOND ORDER INTERPOLATION HELPERS =====
# These provide target values that the dynamics system will smooth

func _second_order_vec2(from: Vector2, to: Vector2, t: float) -> Vector2:
	# Simple blend for target - dynamics adds the realistic motion
	return from + (to - from) * t

func _second_order_float(from: float, to: float, t: float) -> float:
	return from + (to - from) * t

# ===== UTILS =====

func interrupt_attack() -> void:
	if current_state != AttackState.IDLE:
		current_state = AttackState.IDLE
		attack_timer = 0.0
		_reset_offsets()
		
		if combat_manager and character is ProceduralCharacter:
			combat_manager.register_attack_end(character)
		
		emit_signal("attack_finished")

func _reset_offsets() -> void:
	animated_arm_offset = Vector2.ZERO
	animated_weapon_rotation = 0.0
	animated_body_rotation = 0.0
	target_arm_offset = Vector2.ZERO
	target_weapon_rotation = 0.0
	target_body_rotation = 0.0

func _reset_dynamics() -> void:
	if arm_dynamics:
		arm_dynamics.reset(Vector2.ZERO)
	if weapon_rot_dynamics:
		weapon_rot_dynamics.reset(0.0)
	if body_rot_dynamics:
		body_rot_dynamics.reset(0.0)

func _ease_in_quad(t: float) -> float: 
	return t * t

func _ease_out_quad(t: float) -> float: 
	return 1.0 - (1.0 - t) * (1.0 - t)

func _ease_out_cubic(t: float) -> float: 
	return 1.0 - pow(1.0 - t, 3)

# ===== PUBLIC GETTERS =====

func get_current_hand() -> String:
	return character.current_hand

func get_arm_offset(hand: String = "") -> Vector2:
	# If no hand specified, return current attacking arm's offset
	if hand == "" or hand == character.current_hand:
		return animated_arm_offset
	return Vector2.ZERO

func get_main_arm_offset() -> Vector2:
	return animated_arm_offset if character.current_hand == "Main" else Vector2.ZERO

func get_off_arm_offset() -> Vector2:
	return animated_arm_offset if character.current_hand == "Off" else Vector2.ZERO

func get_weapon_rotation() -> float: 
	return animated_weapon_rotation

func get_body_rotation() -> float: 
	return animated_body_rotation

func get_knockback_velocity() -> Vector2:
	return knockback_velocity
