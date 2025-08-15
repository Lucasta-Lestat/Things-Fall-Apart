# Weapon.gd
extends Resource
class_name Weapon

@export var name: String = "Weapon"
@export var damage_base: float = 10.0
@export var damage_type: String = "piercing"  # slashing, piercing, bludgeoning, fire, electric
@export var attack_range: float = 50.0
@export var is_ranged: bool = false
@export var attack_speed: float = 1.0  # Attacks per second
@export var accuracy: float = 90.0  # Percentage
@export var projectile_speed: float = 1000.0  # For ranged weapons
@export var spread_angle: float = 5.0  # Degrees of spread
@export var attacks_per_action: int = 1  # For burst/multi-hit weapons
@export var arc_attack: bool = false  # Wide swing attacks
@export var arc_angle: float = 90.0  # Degrees for arc attacks

# Ammo for ranged weapons
@export var uses_ammo: bool = false
@export var ammo_type: String = ""
@export var current_ammo: int = 0
@export var max_ammo: int = 30

# Special effects
@export var applies_status: bool = false
@export var status_effect: Dictionary = {}

var last_attack_time: float = 0.0

func can_attack() -> bool:
	var current_time = Time.get_ticks_msec() / 1000.0
	if current_time - last_attack_time < (1.0 / attack_speed):
		return false
	
	if uses_ammo and current_ammo <= 0:
		return false
	
	return true

func fire(shooter: CharacterController, target: CharacterController) -> bool:
	if not can_attack():
		return false
	
	last_attack_time = Time.get_ticks_msec() / 1000.0
	
	if uses_ammo:
		current_ammo -= 1
	
	if is_ranged:
		_fire_projectile(shooter, target)
	else:
		_melee_attack(shooter, target)
	
	return true

func _fire_projectile(shooter: CharacterController, target: CharacterController):
	# Calculate hit chance
	var distance = shooter.global_position.distance_to(target.global_position)
	var hit_chance = accuracy - (distance / attack_range * 20.0)  # Distance penalty
	
	# Add spread
	var direction = (target.global_position - shooter.global_position).normalized()
	var spread = randf_range(-spread_angle, spread_angle)
	direction = direction.rotated(deg_to_rad(spread))
	
	# Check for hit
	if randf() * 100 < hit_chance:
		# Determine which body part was hit
		var body_part = _calculate_hit_location(target, direction)
		var damage = calculate_damage(target)
		target.take_damage(damage, damage_type, body_part)
		
		# Apply status effects
		if applies_status and status_effect.size() > 0:
			target.status_effects.append(status_effect.duplicate())

func _melee_attack(attacker: CharacterController, target: CharacterController):
	if arc_attack:
		_perform_arc_attack(attacker)
	else:
		var body_part = _calculate_hit_location(target, Vector2.ZERO)
		var damage = calculate_damage(target)
		target.take_damage(damage, damage_type, body_part)
		
		if applies_status and status_effect.size() > 0:
			target.status_effects.append(status_effect.duplicate())

func _perform_arc_attack(attacker: CharacterController):
	# Hit all enemies in arc
	var facing = attacker.facing_direction
	var start_angle = facing.angle() - deg_to_rad(arc_angle / 2)
	var end_angle = facing.angle() + deg_to_rad(arc_angle / 2)
	
	for character in attacker.get_tree().get_nodes_in_group("characters"):
		if character == attacker:
			continue
		
		var to_target = (character.global_position - attacker.global_position)
		var distance = to_target.length()
		
		if distance > attack_range:
			continue
		
		var angle_to_target = to_target.normalized().angle()
		
		# Check if target is within arc
		if _is_angle_between(angle_to_target, start_angle, end_angle):
			var body_part = _calculate_hit_location(character, Vector2.ZERO)
			var damage = calculate_damage(character) * 0.75  # Reduced damage for arc attacks
			character.take_damage(damage, damage_type, body_part)

func _is_angle_between(angle: float, start: float, end: float) -> bool:
	# Normalize angles to 0-2PI range
	angle = fmod(angle + TAU, TAU)
	start = fmod(start + TAU, TAU)
	end = fmod(end + TAU, TAU)
	
	if start <= end:
		return angle >= start and angle <= end
	else:
		return angle >= start or angle <= end

func _calculate_hit_location(target: CharacterController, attack_direction: Vector2) -> String:
	# Simplified hit location calculation
	# In a full implementation, you'd use actual hitboxes
	var roll = randf()
	
	# Weighted probabilities for body parts
	if roll < 0.4:
		return "torso"  # 40% chance
	elif roll < 0.55:
		return "head"  # 15% chance
	elif roll < 0.65:
		return "left_arm"  # 10% chance
	elif roll < 0.75:
		return "right_arm"  # 10% chance
	elif roll < 0.85:
		return "left_leg"  # 10% chance
	elif roll < 0.95:
		return "right_leg"  # 10% chance
	elif roll < 0.97:
		return "left_hand"  # 2% chance
	elif roll < 0.99:
		return "right_hand"  # 2% chance
	else:
		return "eyes"  # 1% chance

func calculate_damage(target: CharacterController) -> float:
	# Base damage modified by attacker's strength
	var damage = damage_base
	
	# Add randomness
	damage *= randf_range(0.8, 1.2)
	
	return damage

func reload():
	if uses_ammo:
		current_ammo = max_ammo
