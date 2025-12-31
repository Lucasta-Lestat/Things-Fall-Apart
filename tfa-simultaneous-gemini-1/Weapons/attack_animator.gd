# attack_animator.gd
# Handles attack animations based on weapon damage type
extends Node
class_name AttackAnimator

enum DamageType { SLASHING, PIERCING, BLUDGEONING }
enum AttackState { IDLE, WINDUP, STRIKE, RECOVERY }

signal attack_started(damage_type: String)
signal attack_hit_frame()  # Fired at the moment of impact
signal attack_finished()

# Animation state
var current_state: AttackState = AttackState.IDLE
var attack_timer: float = 0.0
var attack_progress: float = 0.0  # 0 to 1

# Animation timing (in seconds)
var windup_duration: float = 0.15
var strike_duration: float = 0.1
var recovery_duration: float = 0.2

# Current attack data
var current_damage_type: String = "slashing"
var attack_direction: Vector2 = Vector2.UP  # Direction of attack in local space

# Arm target offsets for animation (relative to rest position)
var animated_right_arm_offset: Vector2 = Vector2.ZERO
var animated_weapon_rotation: float = 0.0

# Body rotation for attack commitment (in radians)
var animated_body_rotation: float = 0.0

# Reference to character
var character: Node2D

func _ready() -> void:
	character = get_parent()

func _process(delta: float) -> void:
	if current_state == AttackState.IDLE:
		return
	
	attack_timer += delta
	_update_animation()

func start_attack(damage_type: String, direction: Vector2 = Vector2.UP) -> void:
	if current_state != AttackState.IDLE:
		return  # Can't attack while already attacking
	
	current_damage_type = damage_type
	attack_direction = direction.normalized()
	current_state = AttackState.WINDUP
	attack_timer = 0.0
	
	# Adjust timing based on weapon type
	match damage_type:
		"slashing":
			windup_duration = 0.18
			strike_duration = 0.10
			recovery_duration = 0.22
		"piercing":
			# Longer windup to coil back, fast explosive strike
			windup_duration = 0.22
			strike_duration = 0.06  # VERY fast thrust
			recovery_duration = 0.25
		"bludgeoning":
			windup_duration = 0.28
			strike_duration = 0.08
			recovery_duration = 0.30
	
	emit_signal("attack_started", damage_type)

func _update_animation() -> void:
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
			# Hit frame at middle of strike
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
				animated_right_arm_offset = Vector2.ZERO
				animated_weapon_rotation = 0.0
				animated_body_rotation = 0.0
				emit_signal("attack_finished")

func _animate_windup() -> void:
	match current_damage_type:
		"slashing":
			_animate_slash_windup()
		"piercing":
			_animate_thrust_windup()
		"bludgeoning":
			_animate_smash_windup()

func _animate_strike() -> void:
	match current_damage_type:
		"slashing":
			_animate_slash_strike()
		"piercing":
			_animate_thrust_strike()
		"bludgeoning":
			_animate_smash_strike()

func _animate_recovery() -> void:
	# All damage types recover similarly - return to rest
	var ease_out = 1.0 - _ease_out_quad(attack_progress)
	
	match current_damage_type:
		"slashing":
			# Return from slash end position
			animated_right_arm_offset = Vector2(-20, -15) * ease_out
			animated_weapon_rotation = -1.5 * ease_out
			animated_body_rotation = -0.25 * ease_out  # Body rotated left
		"piercing":
			# Return from full thrust extension
			animated_right_arm_offset = Vector2(0, -55) * ease_out
			animated_weapon_rotation = -0.05 * ease_out
			animated_body_rotation = -0.2 * ease_out  # Body rotated forward
		"bludgeoning":
			# Return from smash position
			animated_right_arm_offset = Vector2(0, -25) * ease_out
			animated_weapon_rotation = 0.4 * ease_out
			animated_body_rotation = -0.15 * ease_out

# ===== SLASHING ANIMATION (Powerful horizontal arc with hip rotation) =====

func _animate_slash_windup() -> void:
	# Pull weapon back, rotate body to wind up like a batter
	var ease_in = _ease_in_quad(attack_progress)
	animated_right_arm_offset = Vector2(18, 12) * ease_in  # Way back and to the side
	animated_weapon_rotation = 1.2 * ease_in  # Rotate weapon back
	animated_body_rotation = 0.3 * ease_in  # Rotate body right (wind up)

func _animate_slash_strike() -> void:
	# Explosive swing across - body uncoils, arm sweeps
	var ease_progress = _ease_out_cubic(attack_progress)
	
	# Arc from right-back to left-front with body rotation
	var start_offset = Vector2(18, 12)
	var end_offset = Vector2(-20, -15)  # Further forward and across
	animated_right_arm_offset = start_offset.lerp(end_offset, ease_progress)
	
	# Rotate weapon through the swing
	var start_rot = 1.2
	var end_rot = -1.5
	animated_weapon_rotation = lerpf(start_rot, end_rot, ease_progress)
	
	# Body uncoils - rotates from right to left
	animated_body_rotation = lerpf(0.3, -0.25, ease_progress)

# ===== PIERCING ANIMATION (Full body commitment thrust like a fencer's lunge) =====

func _animate_thrust_windup() -> void:
	# Pull entire arm back, coil body back like loading a spring
	var ease_in = _ease_in_quad(attack_progress)
	# Arm pulls WAY back - elbow high and back
	animated_right_arm_offset = Vector2(15, 35) * ease_in  # Far back
	animated_weapon_rotation = 0.4 * ease_in  # Slight angle back
	animated_body_rotation = 0.25 * ease_in  # Rotate body back/right to coil

func _animate_thrust_strike() -> void:
	# EXPLOSIVE forward thrust - body uncoils, arm extends fully
	# Like a boxer throwing a cross - power from the rotation
	var ease_progress = _ease_out_cubic(attack_progress)
	
	# Start position: coiled back
	var start_offset = Vector2(15, 35)
	# End position: fully extended forward, arm completely straight
	var end_offset = Vector2(0, -55)  # WAY out in front - full extension
	animated_right_arm_offset = start_offset.lerp(end_offset, ease_progress)
	
	# Weapon stays aligned with thrust direction
	animated_weapon_rotation = lerpf(0.4, -0.05, ease_progress)
	
	# Body uncoils forward - drives the thrust
	animated_body_rotation = lerpf(0.25, -0.2, ease_progress)

# ===== BLUDGEONING ANIMATION (Devastating overhead smash with weight drop) =====

func _animate_smash_windup() -> void:
	# Raise weapon high overhead, body leans back
	var ease_in = _ease_in_quad(attack_progress)
	animated_right_arm_offset = Vector2(10, 20) * ease_in  # Up and back
	animated_weapon_rotation = 2.0 * ease_in  # Point weapon way back
	animated_body_rotation = 0.2 * ease_in  # Lean back for the wind up

func _animate_smash_strike() -> void:
	# Bring weapon down HARD - whole body drives downward
	var ease_progress = _ease_out_cubic(attack_progress)
	
	var start_offset = Vector2(10, 20)
	var end_offset = Vector2(0, -25)  # Smash down and forward
	animated_right_arm_offset = start_offset.lerp(end_offset, ease_progress)
	
	animated_weapon_rotation = lerpf(2.0, 0.4, ease_progress)
	
	# Body drives forward/down into the strike
	animated_body_rotation = lerpf(0.2, -0.15, ease_progress)
# ===== INTERRUPTION AND KNOCKBACK =====

var knockback_timer: float = 0.0
var is_knocked_back: bool = false

func interrupt_attack() -> void:
	"""Interrupt current attack and return to idle"""
	if current_state != AttackState.IDLE:
		current_state = AttackState.IDLE
		attack_timer = 0.0
		animated_right_arm_offset = Vector2.ZERO
		animated_weapon_rotation = 0.0
		animated_body_rotation = 0.0
		emit_signal("attack_finished")
# INTERUPTION AND KNOCKBACK
func apply_knockback(duration: float) -> void:
	"""Apply a knockback recovery period (can't attack)"""
	interrupt_attack()
	knockback_timer = duration
	is_knocked_back = true

func is_recovering() -> bool:
	"""Check if recovering from knockback"""
	return is_knocked_back and knockback_timer > 0

func _update_knockback(delta: float) -> void:
	if is_knocked_back:
		knockback_timer -= delta
		if knockback_timer <= 0:
			is_knocked_back = false
			knockback_timer = 0.0
# ===== UTILITY =====

func _ease_in_quad(t: float) -> float:
	return t * t

func _ease_out_quad(t: float) -> float:
	return 1.0 - (1.0 - t) * (1.0 - t)

func _ease_out_cubic(t: float) -> float:
	return 1.0 - pow(1.0 - t, 3)

func is_attacking() -> bool:
	return current_state != AttackState.IDLE

func get_arm_offset() -> Vector2:
	return animated_right_arm_offset

func get_weapon_rotation() -> float:
	return animated_weapon_rotation

func get_body_rotation() -> float:
	return animated_body_rotation

func get_current_state() -> AttackState:
	return current_state
