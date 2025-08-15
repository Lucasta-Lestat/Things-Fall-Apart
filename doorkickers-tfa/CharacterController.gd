# CharacterController.gd
extends CharacterBody2D
class_name CharacterController

signal character_spotted(character)
signal character_heard(character)
signal body_part_damaged(part_name, damage)
signal character_died()
signal character_unconscious()

# Core Stats
var stats = {
	"vision": 100.0,
	"hearing": 100.0,
	"manipulation": 100.0,
	"movement": 100.0,
	"strength": 100.0,
	"mind": 100.0,
	"blood": 100.0
}

# Body Parts System
var body_parts = {
	"head": {"hp": 10, "max_hp": 10, "function": 1.0, "armor": null},
	"torso": {"hp": 20, "max_hp": 20, "function": 1.0, "armor": null},
	"left_arm": {"hp": 10, "max_hp": 10, "function": 1.0, "armor": null},
	"right_arm": {"hp": 10, "max_hp": 10, "function": 1.0, "armor": null},
	"left_hand": {"hp": 8, "max_hp": 8, "function": 1.0, "armor": null},
	"right_hand": {"hp": 8, "max_hp": 8, "function": 1.0, "armor": null},
	"left_leg": {"hp": 12, "max_hp": 12, "function": 1.0, "armor": null},
	"right_leg": {"hp": 12, "max_hp": 12, "function": 1.0, "armor": null},
	"eyes": {"hp": 4, "max_hp": 4, "function": 1.0, "armor": null},
	"ears": {"hp": 4, "max_hp": 4, "function": 1.0, "armor": null}
}

# Vision System
@export var vision_angle: float = 90.0  # degrees
@export var vision_range: float = 500.0
@export var base_vision_stat: float = 100.0
var facing_direction: Vector2 = Vector2.RIGHT
var visible_characters: Array = []
var vision_polygon: PackedVector2Array

# Hearing System
@export var base_hearing_stat: float = 100.0
var heard_characters: Dictionary = {}  # character: last_known_position

# Movement and Pathfinding
var current_path: Array = []
var path_index: int = 0
@export var base_speed: float = 200.0
var current_speed_modifier: float = 1.0

# AI State
enum AIState { IDLE, PATROLLING, ENGAGING, REPOSITIONING, FOLLOWING_PATH }
var ai_state: AIState = AIState.IDLE
var target_enemy: CharacterController = null
var wander_range: float = 300.0
var is_player_controlled: bool = false

# Combat
var equipped_weapon: Weapon = null
var attack_range: float = 50.0
var is_ranged: bool = false

# Status Effects
var bleeding_rate: float = 0.0
var status_effects: Array = []

# Equipment
var equipment = {
	"helmet": null,
	"chest": null,
	"gloves": null,
	"boots": null,
	"weapon": null
}

func _ready():
	add_to_group("characters")
	_update_derived_stats()
	set_physics_process(true)

func _physics_process(delta):
	_update_vision()
	_update_hearing()
	_process_bleeding(delta)
	_process_status_effects(delta)
	_update_ai(delta)
	_move_along_path(delta)

func _update_derived_stats():
	# Vision from eyes
	stats.vision = base_vision_stat * body_parts.eyes.function
	
	# Hearing from ears
	stats.hearing = base_hearing_stat * body_parts.ears.function
	
	# Manipulation from hands and arms
	var hand_function = (body_parts.left_hand.function + body_parts.right_hand.function) / 2.0
	var arm_function = (body_parts.left_arm.function + body_parts.right_arm.function) / 2.0
	stats.manipulation = 100.0 * hand_function * arm_function
	
	# Movement from legs
	var leg_function = (body_parts.left_leg.function + body_parts.right_leg.function) / 2.0
	stats.movement = 100.0 * leg_function
	
	# Strength from arms
	stats.strength = 100.0 * arm_function
	
	# Mind from head
	stats.mind = 100.0 * body_parts.head.function * (stats.blood / 100.0)
	
	# Check consciousness
	if stats.mind < 25.0 and stats.mind > 0:
		_become_unconscious()
	elif stats.mind <= 0:
		_die()

func _update_vision():
	visible_characters.clear()
	vision_polygon.clear()
	
	var space_state = get_world_2d().direct_space_state
	var vision_points = []
	
	# Generate vision cone points
	var start_angle = facing_direction.angle() - deg_to_rad(vision_angle / 2)
	var end_angle = facing_direction.angle() + deg_to_rad(vision_angle / 2)
	
	vision_points.append(global_position)
	
	for i in range(16):  # Sample points for vision cone
		var angle = start_angle + (end_angle - start_angle) * (i / 15.0)
		var check_point = global_position + Vector2.from_angle(angle) * vision_range * (stats.vision / 100.0)
		
		var query = PhysicsRayQueryParameters2D.create(global_position, check_point)
		query.exclude = [self]
		query.collision_mask = 0b0001  # Walls/obstacles layer
		
		var result = space_state.intersect_ray(query)
		if result:
			vision_points.append(result.position)
		else:
			vision_points.append(check_point)
	
	vision_polygon = PackedVector2Array(vision_points)
	
	# Check for visible characters
	for character in get_tree().get_nodes_in_group("characters"):
		if character != self and _can_see_character(character):
			visible_characters.append(character)
			character_spotted.emit(character)

func _can_see_character(target: CharacterController) -> bool:
	if not target:
		return false
	
	var distance = global_position.distance_to(target.global_position)
	if distance > vision_range * (stats.vision / 100.0):
		return false
	
	# Check if in vision cone
	var to_target = (target.global_position - global_position).normalized()
	var angle_to_target = rad_to_deg(acos(facing_direction.dot(to_target)))
	
	if angle_to_target > vision_angle / 2:
		return false
	
	# Calculate concealment
	var concealment = _calculate_concealment(target)
	
	# Vision check
	return stats.vision > concealment * 1.25

func _calculate_concealment(target: CharacterController) -> float:
	var concealment = 0.0
	
	# Check for cover between self and target
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsRayQueryParameters2D.create(global_position, target.global_position)
	query.exclude = [self, target]
	query.collision_mask = 0b0010  # Cover layer
	
	var results = space_state.intersect_ray(query)
	if results:
		concealment += 30.0  # Cover provides 30% concealment
	
	# Add illumination penalty (simplified - you'd check actual light level)
	var light_level = _get_light_level_at(target.global_position)
	concealment += (100 - light_level) * 0.5
	
	# Add cloud/smoke concealment
	if _is_in_cloud(target.global_position):
		concealment += 50.0
	
	return concealment

func _update_hearing():
	# Process sounds from other characters
	for character in get_tree().get_nodes_in_group("characters"):
		if character != self:
			var noise_level = character.get_noise_level()
			if noise_level > 0:
				var distance = global_position.distance_to(character.global_position)
				var muffling = _calculate_sound_muffling(character.global_position)
				
				var effective_hearing = stats.hearing - muffling - (distance / 10.0)
				
				if effective_hearing > noise_level * 0.5:
					heard_characters[character] = character.global_position
					character_heard.emit(character)

func _calculate_sound_muffling(source_pos: Vector2) -> float:
	var muffling = 0.0
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsRayQueryParameters2D.create(global_position, source_pos)
	query.exclude = [self]
	query.collision_mask = 0b0001  # Walls
	
	var results = space_state.intersect_ray(query)
	if results:
		muffling += 30.0  # Each wall muffles by 30%
	
	return muffling

func take_damage(damage: float, damage_type: String, body_part: String):
	if not body_parts.has(body_part):
		return
	
	var part = body_parts[body_part]
	var armor = part.armor
	var final_damage = damage
	
	# Apply armor damage reduction
	if armor:
		final_damage = max(0, damage - armor.get_dr(damage_type))
	
	# Apply damage
	part.hp -= final_damage
	part.hp = max(0, part.hp)
	
	# Update function based on remaining HP
	part.function = part.hp / float(part.max_hp)
	
	# Start bleeding for slashing/piercing damage
	if damage_type in ["slashing", "piercing"] and final_damage > 0:
		bleeding_rate += final_damage * 0.1
	
	# Check if body part is destroyed
	if part.hp <= 0:
		part.function = 0.0
		_on_body_part_destroyed(body_part)
	
	body_part_damaged.emit(body_part, final_damage)
	_update_derived_stats()

func _process_bleeding(delta):
	if bleeding_rate > 0:
		stats.blood -= bleeding_rate * delta
		stats.blood = max(0, stats.blood)
		_update_derived_stats()

func _process_status_effects(delta):
	for i in range(status_effects.size() - 1, -1, -1):
		var effect = status_effects[i]
		effect.duration -= delta
		
		if effect.duration <= 0:
			_remove_status_effect(effect)
			status_effects.remove_at(i)
		else:
			_apply_status_effect(effect, delta)

func _apply_status_effect(effect: Dictionary, delta):
	match effect.type:
		"slow":
			current_speed_modifier = effect.value
		"mind_damage":
			stats.mind -= effect.value * delta
		"charm":
			if stats.mind < effect.threshold:
				is_player_controlled = !is_player_controlled

func _update_ai(delta):
	if is_player_controlled and current_path.size() > 0:
		return  # Following player-defined path
	
	match ai_state:
		AIState.IDLE:
			if visible_characters.size() > 0:
				_select_target()
				ai_state = AIState.ENGAGING
			elif randf() < 0.01:  # Small chance to wander
				_set_wander_destination()
				ai_state = AIState.PATROLLING
		
		AIState.ENGAGING:
			if target_enemy and target_enemy in visible_characters:
				_engage_enemy()
			else:
				target_enemy = null
				ai_state = AIState.IDLE
		
		AIState.PATROLLING:
			if visible_characters.size() > 0:
				_select_target()
				ai_state = AIState.ENGAGING
			elif current_path.size() == 0:
				ai_state = AIState.IDLE

func _select_target():
	if visible_characters.size() == 0:
		return
	
	if is_ranged and equipped_weapon:
		# Select easiest to kill
		var best_target = null
		var best_score = INF
		
		for enemy in visible_characters:
			var expected_damage = equipped_weapon.calculate_damage(enemy)
			var ttk = enemy.get_effective_health() / expected_damage
			if ttk < best_score:
				best_score = ttk
				best_target = enemy
		
		target_enemy = best_target
	else:
		# Select closest
		var closest = null
		var min_dist = INF
		
		for enemy in visible_characters:
			var dist = global_position.distance_to(enemy.global_position)
			if dist < min_dist:
				min_dist = dist
				closest = enemy
		
		target_enemy = closest

func _engage_enemy():
	if not target_enemy:
		return
	
	var distance = global_position.distance_to(target_enemy.global_position)
	
	if distance <= attack_range:
		_attack(target_enemy)
	else:
		_set_path_to(target_enemy.global_position)

func _attack(target: CharacterController):
	if equipped_weapon:
		equipped_weapon.fire(self, target)

func set_path(path: PackedVector2Array):
	current_path.clear()
	for point in path:
		current_path.append(point)
	path_index = 0

func _move_along_path(delta):
	if current_path.size() == 0:
		return
	
	if path_index >= current_path.size():
		current_path.clear()
		return
	
	var target_pos = current_path[path_index]
	var direction = (target_pos - global_position).normalized()
	
	facing_direction = direction
	
	var speed = base_speed * (stats.movement / 100.0) * current_speed_modifier
	velocity = direction * speed
	
	move_and_slide()
	
	if global_position.distance_to(target_pos) < 10:
		path_index += 1

func get_noise_level() -> float:
	if velocity.length() > 0:
		return 10.0 + velocity.length() / 20.0
	return 0.0

func get_effective_health() -> float:
	return body_parts.torso.hp + body_parts.head.hp

func _get_light_level_at(pos: Vector2) -> float:
	# Simplified - you'd check actual lighting
	return 50.0

func _is_in_cloud(pos: Vector2) -> bool:
	# Check if position is in smoke/gas cloud
	return false

func _set_path_to(target_pos: Vector2):
	# This would use your A* pathfinding
	current_path = [target_pos]
	path_index = 0

func _set_wander_destination():
	var wander_pos = global_position + Vector2(randf_range(-wander_range, wander_range), randf_range(-wander_range, wander_range))
	_set_path_to(wander_pos)

func _on_body_part_destroyed(part_name: String):
	match part_name:
		"head":
			_die()
		"eyes":
			stats.vision = 0
		"ears":
			stats.hearing = 0

func _become_unconscious():
	ai_state = AIState.IDLE
	character_unconscious.emit()
	set_physics_process(false)

func _die():
	character_died.emit()
	queue_free()

func _remove_status_effect(effect: Dictionary):
	match effect.type:
		"slow":
			current_speed_modifier = 1.0
