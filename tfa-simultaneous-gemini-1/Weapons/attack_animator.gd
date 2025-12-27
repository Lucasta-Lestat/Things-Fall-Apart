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
			windup_duration = 0.15
			strike_duration = 0.12
			recovery_duration = 0.18
		"piercing":
			windup_duration = 0.1
			strike_duration = 0.08
			recovery_duration = 0.15
		"bludgeoning":
			windup_duration = 0.25
			strike_duration = 0.1
			recovery_duration = 0.25
	
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
				emit_signal("attack_finished")

func _animate_windup() -> void:
	match current_damage_type:
		DamageType.SLASHING:
			_animate_slash_windup()
		DamageType.PIERCING:
			_animate_thrust_windup()
		DamageType.BLUDGEONING:
			_animate_smash_windup()

func _animate_strike() -> void:
	match current_damage_type:
		DamageType.SLASHING:
			_animate_slash_strike()
		DamageType.PIERCING:
			_animate_thrust_strike()
		DamageType.BLUDGEONING:
			_animate_smash_strike()

func _animate_recovery() -> void:
	# All damage types recover similarly - return to rest
	var ease_out = 1.0 - attack_progress
	ease_out = ease_out * ease_out  # Quadratic ease out
	
	match current_damage_type:
		"slashing":
			# Return from slash end position
			animated_right_arm_offset = Vector2(-15, -10) * ease_out
			animated_weapon_rotation = -1.2 * ease_out
		"piercing":
			# Return from thrust position
			animated_right_arm_offset = Vector2(0, -35) * ease_out
			animated_weapon_rotation = 0.0
		"bludgeoning":
			# Return from smash position
			animated_right_arm_offset = Vector2(0, -15) * ease_out
			animated_weapon_rotation = 0.3 * ease_out

# ===== SLASHING ANIMATION (Horizontal/diagonal arc) =====

func _animate_slash_windup() -> void:
	# Pull weapon back and to the side
	var ease_in = attack_progress * attack_progress
	animated_right_arm_offset = Vector2(12, 5) * ease_in  # Back and right
	animated_weapon_rotation = 0.8 * ease_in  # Rotate weapon back

func _animate_slash_strike() -> void:
	# Swing across in an arc
	var ease_progress = _ease_out_cubic(attack_progress)
	
	# Arc from right-back to left-front
	var start_offset = Vector2(12, 5)
	var end_offset = Vector2(-15, -10)
	animated_right_arm_offset = start_offset.lerp(end_offset, ease_progress)
	
	# Rotate weapon through the swing
	var start_rot = 0.8
	var end_rot = -1.2
	animated_weapon_rotation = lerpf(start_rot, end_rot, ease_progress)

# ===== PIERCING ANIMATION (Forward thrust) =====

func _animate_thrust_windup() -> void:
	# Pull weapon back significantly
	var ease_in = attack_progress * attack_progress
	animated_right_arm_offset = Vector2(5, 15) * ease_in  # Pull back more
	animated_weapon_rotation = 0.15 * ease_in

func _animate_thrust_strike() -> void:
	# Thrust forward quickly and far
	var ease_progress = _ease_out_cubic(attack_progress)
	
	var start_offset = Vector2(5, 15)
	var end_offset = Vector2(0, -35)  # Thrust much further forward
	animated_right_arm_offset = start_offset.lerp(end_offset, ease_progress)
	
	animated_weapon_rotation = lerpf(0.15, 0.0, ease_progress)

# ===== BLUDGEONING ANIMATION (Overhead smash) =====

func _animate_smash_windup() -> void:
	# Raise weapon overhead
	var ease_in = attack_progress * attack_progress
	animated_right_arm_offset = Vector2(8, 10) * ease_in  # Up and back
	animated_weapon_rotation = 1.5 * ease_in  # Point weapon backward/up

func _animate_smash_strike() -> void:
	# Bring weapon down hard
	var ease_progress = _ease_out_cubic(attack_progress)
	
	var start_offset = Vector2(8, 10)
	var end_offset = Vector2(0, -15)  # Smash down forward
	animated_right_arm_offset = start_offset.lerp(end_offset, ease_progress)
	
	animated_weapon_rotation = lerpf(1.5, 0.3, ease_progress)

# ===== UTILITY =====

func _ease_out_cubic(t: float) -> float:
	return 1.0 - pow(1.0 - t, 3)

func is_attacking() -> bool:
	return current_state != AttackState.IDLE

func get_arm_offset() -> Vector2:
	return animated_right_arm_offset

func get_weapon_rotation() -> float:
	return animated_weapon_rotation

func get_current_state() -> AttackState:
	return current_state
