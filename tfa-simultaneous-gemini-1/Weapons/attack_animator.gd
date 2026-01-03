# attack_animator.gd
extends Node
class_name AttackAnimator

enum DamageType { SLASHING, PIERCING, BLUDGEONING }
enum AttackState { IDLE, WINDUP, STRIKE, RECOVERY }

signal attack_started(damage_type: String)
signal attack_hit_frame()
signal attack_finished()

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

# Visual Offsets
var animated_right_arm_offset: Vector2 = Vector2.ZERO
var animated_weapon_rotation: float = 0.0
var animated_body_rotation: float = 0.0

var knockback_velocity: Vector2 = Vector2.ZERO
var knockback_friction: float = 1500.0 # Deceleration pixels/sec^2
var knockback_active: bool = false

# Reference to character
var character: Node2D
@onready var combat_manager = get_node("/root/TopDownCharacterScene")
func _ready() -> void:
	character = get_parent()
	


func _process(delta: float) -> void:
	
	# 2. Handle Knockback Physics
	if knockback_active:
		_update_knockback_physics(delta)
		# If the impact is hard enough, we skip the rest of the attack animation
		return

	# 3. Handle Attack Animation
	if current_state == AttackState.IDLE:
		return
	
	attack_timer += delta
	_update_animation()

# ... [start_attack function remains the same as previous step] ...
func start_attack(damage_type: String, direction: Vector2 = Vector2.UP) -> void:
	if combat_manager == null: combat_manager = get_node("root/TopDownCharacterScene")
	combat_manager.register_attack_start(character)
	if current_state != AttackState.IDLE: return
	
	current_damage_type = damage_type
	attack_direction = direction.normalized()
	current_state = AttackState.WINDUP
	attack_timer = 0.0
	
	# Defaults
	var dex: float = 10
	var weight: float = 4.0
	
	if "dexterity" in character: dex = character.dexterity
	if "current_weapon" in character and character.current_weapon != null:
		if typeof(character.current_weapon) == TYPE_DICTIONARY:
			weight = character.current_weapon.get("weight", weight)
		else:
			weight = character.current_weapon.weight
	
	weight = max(0.1, weight)
	var speed_multiplier = clamp((dex / 10.0) / (weight / 4.0), 0.4, 3.0)
	current_rotation_intensity = clamp(weight / 4.5, 0.4, 1.4)
	
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
	"""Clean up when attack ends"""
	current_state = AttackState.IDLE
	attack_timer = 0.0
	_reset_offsets()
	
	# Register attack end for hit tracking
	if combat_manager and character is ProceduralCharacter:
		combat_manager.register_attack_end(character)
	
	emit_signal("attack_finished")
# ===== NEW: FEEDBACK FUNCTIONS =====

func push_character(direction: Vector2, force: float) -> void:
	"""
	Pushes the character based on Force / Weight.
	direction: Normalized vector of the hit source to the character.
	force: The raw power of the impact (e.g., 500 for light, 2000 for heavy).
	"""
	interrupt_attack()
	knockback_active = true

	# 1. Get Character Weight (Default to 70kg if not defined)
	var char_weight: float = 70.0
	if "weight" in character:
		char_weight = float(character.weight)

	# Avoid division by zero
	char_weight = max(1.0, char_weight)

	# 2. Calculate Velocity Impulse (F = ma -> a = F/m)
	# This gives us the initial "pop" speed
	var impulse_speed = force / char_weight

	# Scale this up reasonably for pixels/sec game units 
	# (Arbitrary multiplier to make game units feel good, adjust as needed)
	var game_unit_multiplier = 50.0 
	knockback_velocity = direction.normalized() * (impulse_speed * game_unit_multiplier)

	# 3. Apply directly if character is a physics body
	if character is CharacterBody2D:
		character.velocity = knockback_velocity

func _update_knockback_physics(delta: float) -> void:
	# Apply friction to the knockback velocity
	if knockback_velocity.length() > 0:
		knockback_velocity = knockback_velocity.move_toward(Vector2.ZERO, knockback_friction * delta)
		
		# Keep applying to character if it's a CharacterBody2D
		if character is CharacterBody2D:
			character.velocity = knockback_velocity
			character.move_and_slide()
	else:
		knockback_active = false
		knockback_velocity = Vector2.ZERO

# ===== ANIMATION UPDATES =====
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

# ... [Internal Animation functions _animate_slash_windup, etc. remain unchanged] ...
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
	match current_damage_type:
		"slashing":
			animated_right_arm_offset = Vector2(-20, -15) * ease_out
			animated_weapon_rotation = -1.5 * ease_out
			animated_body_rotation = (-0.25 * ease_out) * current_rotation_intensity
		"piercing":
			animated_right_arm_offset = Vector2(0, -55) * ease_out
			animated_weapon_rotation = -0.05 * ease_out
			animated_body_rotation = (-0.2 * ease_out) * current_rotation_intensity
		"bludgeoning":
			animated_right_arm_offset = Vector2(0, -25) * ease_out
			animated_weapon_rotation = 0.4 * ease_out
			animated_body_rotation = (-0.15 * ease_out) * current_rotation_intensity

# ... [Specific animation implementations slash/thrust/smash remain unchanged] ...
func _animate_slash_windup() -> void:
	var ease_in = _ease_in_quad(attack_progress)
	animated_right_arm_offset = Vector2(18, 12) * ease_in
	animated_weapon_rotation = 1.2 * ease_in
	animated_body_rotation = (0.3 * ease_in) * current_rotation_intensity

func _animate_slash_strike() -> void:
	var ease_progress = _ease_out_cubic(attack_progress)
	animated_right_arm_offset = Vector2(18, 12).lerp(Vector2(-20, -15), ease_progress)
	animated_weapon_rotation = lerpf(1.2, -1.5, ease_progress)
	animated_body_rotation = lerpf(0.3 * current_rotation_intensity, -0.25 * current_rotation_intensity, ease_progress)

func _animate_thrust_windup() -> void:
	var ease_in = _ease_in_quad(attack_progress)
	animated_right_arm_offset = Vector2(15, 35) * ease_in
	animated_weapon_rotation = 0.4 * ease_in 
	animated_body_rotation = (0.25 * ease_in) * current_rotation_intensity

func _animate_thrust_strike() -> void:
	var ease_progress = _ease_out_cubic(attack_progress)
	animated_right_arm_offset = Vector2(15, 35).lerp(Vector2(0, -55), ease_progress)
	animated_weapon_rotation = lerpf(0.4, -0.05, ease_progress)
	animated_body_rotation = lerpf(0.25 * current_rotation_intensity, -0.2 * current_rotation_intensity, ease_progress)

func _animate_smash_windup() -> void:
	var ease_in = _ease_in_quad(attack_progress)
	animated_right_arm_offset = Vector2(10, 20) * ease_in
	animated_weapon_rotation = 2.0 * ease_in
	animated_body_rotation = (0.2 * ease_in) * current_rotation_intensity

func _animate_smash_strike() -> void:
	var ease_progress = _ease_out_cubic(attack_progress)
	animated_right_arm_offset = Vector2(10, 20).lerp(Vector2(0, -25), ease_progress)
	animated_weapon_rotation = lerpf(2.0, 0.4, ease_progress)
	animated_body_rotation = lerpf(0.2 * current_rotation_intensity, -0.15 * current_rotation_intensity, ease_progress)

# ===== UTILS =====

func interrupt_attack() -> void:
	if current_state != AttackState.IDLE:
		current_state = AttackState.IDLE
		attack_timer = 0.0
		_reset_offsets()
		
		# Register attack end for hit tracking (attack was interrupted)
		if combat_manager and character is ProceduralCharacter:
			combat_manager.register_attack_end(character)
		
		emit_signal("attack_finished")

func _reset_offsets() -> void:
	animated_right_arm_offset = Vector2.ZERO
	animated_weapon_rotation = 0.0
	animated_body_rotation = 0.0

func _ease_in_quad(t: float) -> float: return t * t
func _ease_out_quad(t: float) -> float: return 1.0 - (1.0 - t) * (1.0 - t)
func _ease_out_cubic(t: float) -> float: return 1.0 - pow(1.0 - t, 3)

# ===== PUBLIC GETTERS =====

func is_attacking() -> bool: return current_state != AttackState.IDLE

func get_arm_offset() -> Vector2: return animated_right_arm_offset
func get_weapon_rotation() -> float: return animated_weapon_rotation
func get_body_rotation() -> float: return animated_body_rotation


func get_knockback_velocity() -> Vector2:
	"""If not using CharacterBody2D, use this to manually move your character"""
	return knockback_velocity
