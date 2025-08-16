# TopDownCharacterController.gd
extends Node2D
class_name TopDownCharacterController

# Main character controller that manages the physics body and game logic

@onready var physics_body: PhysicsCharacterBody = $PhysicsBody
@onready var vision_cone: Area2D = $VisionCone
@onready var hitbox_areas: Node2D = $PhysicsBody/HitboxAreas

# Signals
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
	"movement": 100.0,  # Determines force, not speed!
	"strength": 100.0,
	"mind": 100.0,
	"blood": 100.0
}

# Body Parts System (simplified for top-down)
var body_parts = {
	"head": {"hp": 10, "max_hp": 10, "function": 1.0, "armor": null},
	"torso": {"hp": 20, "max_hp": 20, "function": 1.0, "armor": null},
	"left_arm": {"hp": 10, "max_hp": 10, "function": 1.0, "armor": null},
	"right_arm": {"hp": 10, "max_hp": 10, "function": 1.0, "armor": null},
	"legs": {"hp": 15, "max_hp": 15, "function": 1.0, "armor": null}
}

# Vision System
@export var vision_angle: float = 90.0
@export var vision_range: float = 500.0
var visible_characters: Array = []
var vision_blocked_by_smoke: bool = false

# Hearing System  
var heard_characters: Dictionary = {}
var noise_level: float = 0.0

# Movement
var desired_movement: Vector2 = Vector2.ZERO
var current_path: Array = []
var path_index: int = 0

# AI State
enum AIState { IDLE, PATROLLING, ENGAGING, FLEEING, FOLLOWING_PATH }
var ai_state: AIState = AIState.IDLE
var target_enemy: TopDownCharacterController = null
var is_player_controlled: bool = false

# Combat
var equipped_weapon: PhysicsWeapon = null
var inventory: Inventory

# Status
var bleeding_rate: float = 0.0
var status_effects: Array = []
var external_forces: Array = []  # Track all external forces acting on character

# Environmental factors
var on_ice: bool = false
var in_wind_zone: bool = false
var wind_force: Vector2 = Vector2.ZERO

func _ready():
	add_to_group("characters")
	
	if not physics_body:
		physics_body = PhysicsCharacterBody.new()
		physics_body.name = "PhysicsBody"
		add_child(physics_body)
	
	_setup_vision_cone()
	_setup_hitboxes()
	_update_physics_stats()
	
	# Initialize inventory
	inventory = Inventory.new()
	inventory.max_weight = stats.strength
	
	# Connect physics body signals
	physics_body.external_force_received.connect(_on_external_force)
	
	set_physics_process(true)

func _setup_vision_cone():
	if not vision_cone:
		vision_cone = Area2D.new()
		vision_cone.name = "VisionCone"
		add_child(vision_cone)
	
	# Create vision cone shape
	var collision = CollisionPolygon2D.new()
	vision_cone.add_child(collision)
	
	vision_cone.collision_layer = 0
	vision_cone.collision_mask = 0b0100  # See characters
	
	# Connect detection
	vision_cone.body_entered.connect(_on_body_entered_vision)
	vision_cone.body_exited.connect(_on_body_exited_vision)

func _setup_hitboxes():
	if not hitbox_areas:
		hitbox_areas = Node2D.new()
		hitbox_areas.name = "HitboxAreas"
		physics_body.add_child(hitbox_areas)
	
	# Create simplified hitboxes for top-down view
	var hitbox_data = {
		"head": {"radius": 5, "position": Vector2(0, 0)},  # Center, since top-down
		"torso": {"radius": 12, "position": Vector2(0, 0)},
		"left_arm": {"radius": 4, "position": Vector2(-10, 0)},
		"right_arm": {"radius": 4, "position": Vector2(10, 0)},
		"legs": {"radius": 8, "position": Vector2(0, 5)}
	}
	
	for part_name in hitbox_data:
		var data = hitbox_data[part_name]
		var area = Area2D.new()
		area.name = part_name + "_hitbox"
		
		var shape = CircleShape2D.new()
		shape.radius = data.radius
		
		var collision = CollisionShape2D.new()
		collision.shape = shape
		collision.position = data.position
		
		area.add_child(collision)
		hitbox_areas.add_child(area)
		
		# Connect hit detection
		area.area_entered.connect(_on_hitbox_hit.bind(part_name))

func _physics_process(delta):
	_update_vision()
	_check_hearing()
	_process_movement(delta)
	_process_environmental_forces(delta)
	_process_bleeding(delta)
	_process_status_effects(delta)
	_update_ai(delta)

func _update_vision():
	# Update vision cone shape based on facing direction
	var collision_poly = vision_cone.get_child(0) as CollisionPolygon2D
	if not collision_poly:
		return
	
	var points = PackedVector2Array()
	points.append(Vector2.ZERO)
	
	var facing_angle = physics_body.facing_direction
	var start_angle = facing_angle - deg_to_rad(vision_angle / 2)
	var end_angle = facing_angle + deg_to_rad(vision_angle / 2)
	
	# Create vision cone polygon
	for i in range(16):
		var angle = start_angle + (end_angle - start_angle) * (i / 15.0)
		var point = Vector2.from_angle(angle) * vision_range * (stats.vision / 100.0)
		
		# Check for walls blocking vision
		var space_state = get_world_2d().direct_space_state
		var query = PhysicsRayQueryParameters2D.create(global_position, global_position + point)
		query.exclude = [physics_body]
		query.collision_mask = 0b0001  # Walls
		
		var result = space_state.intersect_ray(query)
		if result:
			points.append(physics_body.to_local(result.position))
		else:
			points.append(point)
	
	collision_poly.polygon = points
	
	# Check smoke/fog
	_check_vision_obscurance()

func _check_vision_obscurance():
	var vision_system = get_node_or_null("/root/Main/VisionSystem")
	if vision_system:
		vision_blocked_by_smoke = vision_system._is_in_smoke(global_position)

func _check_hearing():
	heard_characters.clear()
	
	for character in get_tree().get_nodes_in_group("characters"):
		if character == self:
			continue
		
		var distance = global_position.distance_to(character.global_position)
		var their_noise = character.get_noise_level()
		
		if their_noise <= 0:
			continue
		
		# Check if we can hear them
		var hearing_range = stats.hearing * 5.0  # 5 pixels per hearing point
		var effective_noise = their_noise - (distance / 10.0)
		
		if effective_noise > 0 and distance < hearing_range:
			# Check for walls muffling sound
			var muffling = _calculate_sound_muffling(character.global_position)
			effective_noise -= muffling
			
			if effective_noise > 0:
				heard_characters[character] = character.global_position
				character_heard.emit(character)

func _calculate_sound_muffling(source_pos: Vector2) -> float:
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsRayQueryParameters2D.create(global_position, source_pos)
	query.exclude = [physics_body]
	query.collision_mask = 0b0001  # Walls
	
	var result = space_state.intersect_ray(query)
	return 30.0 if result else 0.0

func _process_movement(delta):
	if current_path.size() > 0 and path_index < current_path.size():
		# Follow path
		var target = current_path[path_index]
		var direction = (target - global_position).normalized()
		desired_movement = direction
		
		if global_position.distance_to(target) < 20:
			path_index += 1
	
	# Apply movement to physics body
	physics_body.set_movement_input(desired_movement)

func _process_environmental_forces(delta):
	# Check terrain type
	var pathfinding = get_node_or_null("/root/Main/PathfindingSystem")
	if pathfinding:
		var terrain = pathfinding.get_terrain(global_position)
		if terrain:
			# Adjust physics based on terrain
			match terrain.type:
				PathfindingSystem.TerrainType.WATER:
					# Water slows movement
					physics_body.friction_coefficient = 20.0
				PathfindingSystem.TerrainType.METAL_FLOOR:
					# Metal is slippery when electrified
					if terrain.is_electrified:
						physics_body.friction_coefficient = 2.0
						take_damage(terrain.electric_charge * delta, "electric", "legs")
				PathfindingSystem.TerrainType.FIRE:
					# Fire damages and creates updraft
					if terrain.is_burning:
						take_damage(5.0 * delta, "fire", "legs")
						physics_body.apply_external_force(Vector2(randf_range(-50, 50), -100), "fire_updraft")
	
	# Apply wind if in wind zone
	if in_wind_zone:
		physics_body.apply_external_force(wind_force * delta, "wind")
	
	# Apply spell forces
	for force in external_forces:
		physics_body.apply_external_force(force.vector * delta, force.source)
		force.duration -= delta
		if force.duration <= 0:
			external_forces.erase(force)

func add_external_force(force: Vector2, duration: float, source: String):
	external_forces.append({
		"vector": force,
		"duration": duration,
		"source": source
	})

func _update_physics_stats():
	if physics_body:
		physics_body.movement_stat = stats.movement
		physics_body.weight = 70.0 + (stats.strength - 100.0) * 0.3
		physics_body.update_stats(stats)

func _process_bleeding(delta):
	if bleeding_rate > 0:
		stats.blood -= bleeding_rate * delta
		stats.blood = max(0, stats.blood)
		_update_derived_stats()

func _process_status_effects(delta):
	for effect in status_effects:
		effect.duration -= delta
		
		match effect.type:
			"slow":
				# Increase friction
				physics_body.friction_coefficient = physics_body.friction_coefficient * 2.0
			"knockback":
				add_external_force(effect.direction * effect.power, 0.5, "knockback")
			"levitate":
				physics_body.friction_coefficient = 0.5
		
		if effect.duration <= 0:
			status_effects.erase(effect)

func _update_ai(delta):
	if is_player_controlled:
		return
	
	match ai_state:
		AIState.IDLE:
			if visible_characters.size() > 0:
				_select_target()
				ai_state = AIState.ENGAGING
			
		AIState.ENGAGING:
			if target_enemy:
				_engage_target()
			else:
				ai_state = AIState.IDLE
		
		AIState.FLEEING:
			if target_enemy:
				_flee_from_target()

func _select_target():
	var best_target = null
	var best_priority = -INF
	
	for enemy in visible_characters:
		var distance = global_position.distance_to(enemy.global_position)
		var threat_level = enemy.get_threat_level()
		var priority = threat_level / distance
		
		if priority > best_priority:
			best_priority = priority
			best_target = enemy
	
	target_enemy = best_target

func _engage_target():
	if not target_enemy:
		return
	
	physics_body.aim_at(target_enemy.global_position)
	
	var distance = global_position.distance_to(target_enemy.global_position)
	
	if equipped_weapon:
		if distance < equipped_weapon.weapon_length + 50:
			physics_body.perform_melee_attack("slash")
		else:
			_move_toward(target_enemy.global_position)
	else:
		# Flee if unarmed
		ai_state = AIState.FLEEING

func _flee_from_target():
	if not target_enemy:
		ai_state = AIState.IDLE
		return
	
	var away_direction = (global_position - target_enemy.global_position).normalized()
	var flee_target = global_position + away_direction * 200
	_move_toward(flee_target)

func _move_toward(target_pos: Vector2):
	var pathfinding = get_node_or_null("/root/Main/PathfindingSystem")
	if pathfinding:
		current_path = pathfinding.calculate_path(global_position, target_pos)
		path_index = 0

func _on_body_entered_vision(body):
	if body != self and body.has_method("get_threat_level"):
		if not body in visible_characters:
			visible_characters.append(body)
			character_spotted.emit(body)

func _on_body_exited_vision(body):
	visible_characters.erase(body)

func _on_hitbox_hit(area: Area2D, part_name: String):
	if area.has_meta("damage"):
		var damage = area.get_meta("damage")
		var damage_type = area.get_meta("damage_type", "physical")
		take_damage(damage, damage_type, part_name)

func _on_external_force(force: Vector2, source: String):
	# Character was pushed by external force
	# Could trigger animations or state changes
	if force.length() > 500:
		# Strong force, character staggers
		ai_state = AIState.IDLE
		desired_movement = Vector2.ZERO

func take_damage(damage: float, damage_type: String, body_part: String):
	if not body_parts.has(body_part):
		body_part = "torso"  # Default
	
	var part = body_parts[body_part]
	var final_damage = damage
	
	# Apply armor
	if part.armor:
		final_damage = max(0, damage - part.armor.get_dr(damage_type))
	
	part.hp -= final_damage
	part.hp = max(0, part.hp)
	part.function = part.hp / float(part.max_hp)
	
	# Bleeding
	if damage_type in ["slashing", "piercing"]:
		bleeding_rate += final_damage * 0.1
	
	body_part_damaged.emit(body_part, final_damage)
	_update_derived_stats()
	
	# Check if part destroyed
	if part.hp <= 0:
		_on_body_part_destroyed(body_part)

func _update_derived_stats():
	# Vision from head (eyes are part of head in top-down)
	stats.vision = 100.0 * body_parts.head.function
	
	# Hearing from head
	stats.hearing = 100.0 * body_parts.head.function
	
	# Movement from legs
	stats.movement = 100.0 * body_parts.legs.function
	
	# Manipulation from arms
	var arm_function = (body_parts.left_arm.function + body_parts.right_arm.function) / 2.0
	stats.manipulation = 100.0 * arm_function
	
	# Strength from torso and arms
	stats.strength = 100.0 * body_parts.torso.function * arm_function
	
	# Mind from head and blood
	stats.mind = 100.0 * body_parts.head.function * (stats.blood / 100.0)
	
	# Update physics body
	_update_physics_stats()
	
	# Check consciousness
	if stats.mind < 25.0 and stats.mind > 0:
		_become_unconscious()
	elif stats.mind <= 0:
		_die()

func _on_body_part_destroyed(part_name: String):
	match part_name:
		"head":
			_die()
		"legs":
			# Can't walk, only crawl
			stats.movement = 10.0
			physics_body.max_velocity = 30.0
		"left_arm", "right_arm":
			# Can't use two-handed weapons
			if equipped_weapon and equipped_weapon.weapon_weight > 3.0:
				drop_weapon()

func _become_unconscious():
	ai_state = AIState.IDLE
	desired_movement = Vector2.ZERO
	physics_body.set_movement_input(Vector2.ZERO)
	character_unconscious.emit()
	set_physics_process(false)

func _die():
	character_died.emit()
	
	# Stop all movement
	physics_body.set_movement_input(Vector2.ZERO)
	physics_body.linear_velocity = Vector2.ZERO
	
	# Drop all items
	if equipped_weapon:
		drop_weapon()
	
	# Become physics object (corpse)
	physics_body.lock_rotation = false
	physics_body.angular_damp = 1.0
	
	remove_from_group("characters")
	set_physics_process(false)

func get_noise_level() -> float:
	if not physics_body:
		return 0.0
	
	# Noise based on movement speed
	var base_noise = physics_body.linear_velocity.length() / 10.0
	
	# Terrain affects noise
	var pathfinding = get_node_or_null("/root/Main/PathfindingSystem")
	if pathfinding:
		base_noise *= pathfinding.get_noise_modifier(global_position)
	
	# Combat makes noise
	if equipped_weapon and physics_body.is_moving:
		base_noise += 5.0
	
	return base_noise

func get_threat_level() -> float:
	var threat = 10.0
	
	if equipped_weapon:
		threat += equipped_weapon.base_damage_multiplier
		if equipped_weapon is RangedWeapon:
			threat += 20.0
	
	threat *= (stats.mind / 100.0)  # Injured enemies less threatening
	
	return threat

func equip_weapon(weapon: PhysicsWeapon):
	if equipped_weapon:
		drop_weapon()
	
	equipped_weapon = weapon
	physics_body.equip_weapon(weapon)

func drop_weapon():
	if not equipped_weapon:
		return
	
	equipped_weapon.get_parent().remove_child(equipped_weapon)
	get_parent().add_child(equipped_weapon)
	equipped_weapon.global_position = global_position + Vector2(randf_range(-20, 20), randf_range(-20, 20))
	equipped_weapon = null

func set_player_controlled(controlled: bool):
	is_player_controlled = controlled
	if controlled:
		add_to_group("player_characters")
		remove_from_group("enemy_characters")
	else:
		remove_from_group("player_characters")
		add_to_group("enemy_characters")

func apply_spell(spell_type: String, caster_stats: Dictionary):
	match spell_type:
		"gust":
			# Wind spell pushes character
			var wind_force = Vector2(500, 0).rotated(randf() * TAU)
			add_external_force(wind_force, 1.0, "spell_gust")
		
		"attract":
			# Magnetic pull toward caster
			if caster_stats.has("position"):
				var pull_direction = (caster_stats.position - global_position).normalized()
				var pull_force = pull_direction * 300
				add_external_force(pull_force, 2.0, "spell_attract")
		
		"ice_surface":
			# Create ice under character
			var pathfinding = get_node_or_null("/root/Main/PathfindingSystem")
			if pathfinding:
				# Temporarily reduce friction on this tile
				physics_body.friction_coefficient = 0.5
				get_tree().create_timer(5.0).timeout.connect(func():
					physics_body.friction_coefficient = 10.0
				)
		
		"levitate":
			# Remove friction
			status_effects.append({
				"type": "levitate",
				"duration": 3.0
			})
		
		"slow":
			# Increase friction/reduce movement
			status_effects.append({
				"type": "slow", 
				"duration": 5.0
			})
