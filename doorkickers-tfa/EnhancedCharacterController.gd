# EnhancedCharacterController.gd
extends CharacterBody2D
class_name EnhancedCharacterController

# Integrate the original CharacterController with the new ProceduralCharacterBody

@onready var procedural_body: ProceduralCharacterBody = $ProceduralBody

# Keep all the original stats and systems from CharacterController
signal character_spotted(character)
signal character_heard(character)
signal body_part_damaged(part_name, damage)
signal character_died()
signal character_unconscious()

# Core Stats (from original)
var stats = {
	"vision": 100.0,
	"hearing": 100.0,
	"manipulation": 100.0,
	"movement": 100.0,
	"strength": 100.0,
	"mind": 100.0,
	"blood": 100.0
}

# Body Parts System with hitboxes
var body_parts = {
	"head": {"hp": 10, "max_hp": 10, "function": 1.0, "armor": null, "hitbox": null},
	"torso": {"hp": 20, "max_hp": 20, "function": 1.0, "armor": null, "hitbox": null},
	"left_arm": {"hp": 10, "max_hp": 10, "function": 1.0, "armor": null, "hitbox": null},
	"right_arm": {"hp": 10, "max_hp": 10, "function": 1.0, "armor": null, "hitbox": null},
	"left_hand": {"hp": 8, "max_hp": 8, "function": 1.0, "armor": null, "hitbox": null},
	"right_hand": {"hp": 8, "max_hp": 8, "function": 1.0, "armor": null, "hitbox": null},
	"left_leg": {"hp": 12, "max_hp": 12, "function": 1.0, "armor": null, "hitbox": null},
	"right_leg": {"hp": 12, "max_hp": 12, "function": 1.0, "armor": null, "hitbox": null},
	"eyes": {"hp": 4, "max_hp": 4, "function": 1.0, "armor": null, "hitbox": null},
	"ears": {"hp": 4, "max_hp": 4, "function": 1.0, "armor": null, "hitbox": null}
}

# Vision System
@export var vision_angle: float = 90.0
@export var vision_range: float = 500.0
@export var base_vision_stat: float = 100.0
var facing_direction: Vector2 = Vector2.RIGHT
var visible_characters: Array = []
var vision_polygon: PackedVector2Array

# Hearing System
@export var base_hearing_stat: float = 100.0
var heard_characters: Dictionary = {}

# Movement and Pathfinding
var current_path: Array = []
var path_index: int = 0
@export var base_speed: float = 200.0
var current_speed_modifier: float = 1.0

# AI State
enum AIState { IDLE, PATROLLING, ENGAGING, REPOSITIONING, FOLLOWING_PATH }
var ai_state: AIState = AIState.IDLE
var target_enemy: EnhancedCharacterController = null
var is_player_controlled: bool = false

# Combat
var equipped_weapon: PhysicsWeapon = null
var inventory: Inventory

# Status Effects
var bleeding_rate: float = 0.0
var status_effects: Array = []

# Visual customization
@export_group("Appearance")
@export var skin_tone: Color = Color(0.9, 0.75, 0.6)
@export var hair_style: String = "short"  # short, long, bald
@export var hair_color: Color = Color(0.2, 0.1, 0.05)
@export var clothing_primary: Color = Color(0.3, 0.3, 0.5)
@export var clothing_secondary: Color = Color(0.2, 0.2, 0.3)
@export var body_build: float = 1.0  # 0.8 = slim, 1.0 = normal, 1.2 = bulky

func _ready():
	add_to_group("characters")
	
	# Initialize procedural body
	if not procedural_body:
		procedural_body = ProceduralCharacterBody.new()
		add_child(procedural_body)
	
	_setup_hitboxes()
	_apply_appearance()
	_update_derived_stats()
	
	# Initialize inventory
	inventory = Inventory.new()
	inventory.max_weight = stats.strength
	
	set_physics_process(true)

func _setup_hitboxes():
	# Create Area2D hitboxes for each body part
	var hitbox_data = {
		"head": {"size": Vector2(16, 16), "position": Vector2(0, -35)},
		"torso": {"size": Vector2(24, 30), "position": Vector2(0, 0)},
		"left_arm": {"size": Vector2(8, 24), "position": Vector2(-20, -5)},
		"right_arm": {"size": Vector2(8, 24), "position": Vector2(20, -5)},
		"left_hand": {"size": Vector2(6, 6), "position": Vector2(-20, 10)},
		"right_hand": {"size": Vector2(6, 6), "position": Vector2(20, 10)},
		"left_leg": {"size": Vector2(10, 30), "position": Vector2(-8, 25)},
		"right_leg": {"size": Vector2(10, 30), "position": Vector2(8, 25)},
		"eyes": {"size": Vector2(12, 4), "position": Vector2(0, -38)},
		"ears": {"size": Vector2(20, 6), "position": Vector2(0, -35)}
	}
	
	for part_name in hitbox_data:
		var data = hitbox_data[part_name]
		var hitbox = Area2D.new()
		hitbox.name = part_name + "_hitbox"
		
		var shape = RectangleShape2D.new()
		shape.size = data.size * body_build
		
		var collision = CollisionShape2D.new()
		collision.shape = shape
		collision.position = data.position * body_build
		
		hitbox.add_child(collision)
		add_child(hitbox)
		
		# Store reference in body_parts
		if body_parts.has(part_name):
			body_parts[part_name].hitbox = hitbox
		
		# Connect hit detection
		hitbox.area_entered.connect(_on_hitbox_entered.bind(part_name))
		hitbox.body_entered.connect(_on_hitbox_body_entered.bind(part_name))

func _apply_appearance():
	if procedural_body:
		procedural_body.skin_color = skin_tone
		procedural_body.hair_color = hair_color
		procedural_body.clothing_color = clothing_primary
		procedural_body.body_scale = body_build

func _physics_process(delta):
	_update_vision()
	_update_hearing()
	_process_bleeding(delta)
	_process_status_effects(delta)
	_update_ai(delta)
	_update_movement(delta)
	_update_procedural_animation(delta)

func _update_movement(delta):
	if current_path.size() == 0:
		# Apply friction when not moving
		velocity = velocity.lerp(Vector2.ZERO, 0.1)
	else:
		_move_along_path(delta)
	
	move_and_slide()

func _move_along_path(delta):
	if path_index >= current_path.size():
		current_path.clear()
		return
	
	var target_pos = current_path[path_index]
	var direction = (target_pos - global_position).normalized()
	
	facing_direction = direction
	
	# Get terrain speed modifier
	var pathfinding = get_node_or_null("/root/Main/PathfindingSystem")
	if pathfinding:
		current_speed_modifier = pathfinding.get_move_speed_modifier(global_position)
	
	var speed = base_speed * (stats.movement / 100.0) * current_speed_modifier
	velocity = direction * speed
	
	if global_position.distance_to(target_pos) < 10:
		path_index += 1

func _update_procedural_animation(delta):
	if procedural_body:
		# Update locomotion animation
		procedural_body.update_locomotion(velocity, delta)
		
		# Update aiming if in combat
		if target_enemy and ai_state == AIState.ENGAGING:
			procedural_body.update_aiming(target_enemy.global_position)
		
		# Rotate body to face movement direction
		if velocity.length() > 10:
			procedural_body.rotation = lerp_angle(procedural_body.rotation, velocity.angle(), 0.1)

func _update_vision():
	visible_characters.clear()
	vision_polygon.clear()
	
	var space_state = get_world_2d().direct_space_state
	var vision_points = []
	
	# Generate vision cone
	var start_angle = facing_direction.angle() - deg_to_rad(vision_angle / 2)
	var end_angle = facing_direction.angle() + deg_to_rad(vision_angle / 2)
	
	vision_points.append(global_position)
	
	for i in range(16):
		var angle = start_angle + (end_angle - start_angle) * (i / 15.0)
		var check_point = global_position + Vector2.from_angle(angle) * vision_range * (stats.vision / 100.0)
		
		var query = PhysicsRayQueryParameters2D.create(global_position, check_point)
		query.exclude = [self]
		query.collision_mask = 0b0001  # Walls layer
		
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

func _can_see_character(target) -> bool:
	if not target:
		return false
	
	var distance = global_position.distance_to(target.global_position)
	if distance > vision_range * (stats.vision / 100.0):
		return false
	
	var to_target = (target.global_position - global_position).normalized()
	var angle_to_target = rad_to_deg(acos(facing_direction.dot(to_target)))
	
	if angle_to_target > vision_angle / 2:
		return false
	
	# Line of sight check
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsRayQueryParameters2D.create(global_position, target.global_position)
	query.exclude = [self, target]
	query.collision_mask = 0b0001
	
	var result = space_state.intersect_ray(query)
	return result.is_empty()

func _update_hearing():
	for character in get_tree().get_nodes_in_group("characters"):
		if character != self:
			var noise_level = character.get_noise_level()
			if noise_level > 0:
				var distance = global_position.distance_to(character.global_position)
				var effective_hearing = stats.hearing - (distance / 10.0)
				
				if effective_hearing > noise_level * 0.5:
					heard_characters[character] = character.global_position
					character_heard.emit(character)

func get_noise_level() -> float:
	var base_noise = velocity.length() / 20.0 if velocity.length() > 0 else 0.0
	
	# Add terrain noise modifier
	var pathfinding = get_node_or_null("/root/Main/PathfindingSystem")
	if pathfinding:
		base_noise *= pathfinding.get_noise_modifier(global_position)
	
	return base_noise

func _on_hitbox_entered(area: Area2D, part_name: String):
	# Handle projectile hits
	if area.has_meta("damage"):
		var damage = area.get_meta("damage")
		var damage_type = area.get_meta("damage_type", "piercing")
		take_damage(damage, damage_type, part_name)
		area.queue_free()

func _on_hitbox_body_entered(body: Node2D, part_name: String):
	# Handle melee weapon hits
	if body is PhysicsWeapon:
		# Damage is calculated by the weapon based on physics
		pass

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
	
	# Update function
	part.function = part.hp / float(part.max_hp)
	
	# Start bleeding
	if damage_type in ["slashing", "piercing"] and final_damage > 0:
		bleeding_rate += final_damage * 0.1
	
	# Check if destroyed
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
			status_effects.remove_at(i)
		else:
			_apply_status_effect(effect, delta)

func _apply_status_effect(effect: Dictionary, delta):
	match effect.type:
		"slow":
			current_speed_modifier *= effect.value
		"mind_damage":
			stats.mind -= effect.value * delta

func _update_derived_stats():
	# Vision from eyes
	stats.vision = base_vision_stat * body_parts.eyes.function
	
	# Hearing from ears
	stats.hearing = base_hearing_stat * body_parts.ears.function
	
	# Movement from legs
	var leg_function = (body_parts.left_leg.function + body_parts.right_leg.function) / 2.0
	stats.movement = 100.0 * leg_function
	
	# Mind from head and blood
	stats.mind = 100.0 * body_parts.head.function * (stats.blood / 100.0)
	
	# Update inventory weight capacity
	if inventory:
		inventory.max_weight = stats.strength
	
	# Check consciousness
	if stats.mind < 25.0 and stats.mind > 0:
		_become_unconscious()
	elif stats.mind <= 0:
		_die()

func _update_ai(delta):
	if is_player_controlled and current_path.size() > 0:
		return
	
	match ai_state:
		AIState.IDLE:
			if visible_characters.size() > 0:
				_select_target()
				ai_state = AIState.ENGAGING
		
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

func _select_target():
	if visible_characters.size() == 0:
		return
	
	# Prioritize based on threat level and distance
	var best_target = null
	var best_score = INF
	
	for enemy in visible_characters:
		var distance = global_position.distance_to(enemy.global_position)
		var threat = 1.0
		
		if enemy.equipped_weapon:
			threat = 2.0 if enemy.equipped_weapon.is_ranged else 1.5
		
		var score = distance / threat
		if score < best_score:
			best_score = score
			best_target = enemy
	
	target_enemy = best_target

func _engage_enemy():
	if not target_enemy:
		return
	
	var distance = global_position.distance_to(target_enemy.global_position)
	
	if equipped_weapon:
		if equipped_weapon is RangedWeapon:
			# Ranged combat tactics
			if distance < 100:
				# Too close, back up
				_move_away_from(target_enemy.global_position)
			elif distance > equipped_weapon.attack_range:
				# Too far, move closer
				_move_toward(target_enemy.global_position)
			else:
				# Good range, attack
				_perform_ranged_attack()
		else:
			# Melee combat
			if distance <= equipped_weapon.weapon_length + 20:
				_perform_melee_attack()
			else:
				_move_toward(target_enemy.global_position)

func _move_toward(target_pos: Vector2):
	var pathfinding = get_node_or_null("/root/Main/PathfindingSystem")
	if pathfinding:
		current_path = pathfinding.calculate_path(global_position, target_pos)
		path_index = 0

func _move_away_from(threat_pos: Vector2):
	var away_direction = (global_position - threat_pos).normalized()
	var retreat_pos = global_position + away_direction * 150
	_move_toward(retreat_pos)

func _perform_melee_attack():
	if not equipped_weapon or not procedural_body:
		return
	
	var attack_type = "slash" if equipped_weapon.damage_type == "slashing" else "thrust"
	procedural_body.perform_attack(attack_type, target_enemy.global_position)

func _perform_ranged_attack():
	if not equipped_weapon:
		return
	
	if equipped_weapon is BowWeapon:
		var bow = equipped_weapon as BowWeapon
		if not bow.is_drawing:
			bow.start_draw()
			# Hold for a moment
			await get_tree().create_timer(0.5).timeout
			bow.release_draw()
	elif equipped_weapon is RangedWeapon:
		equipped_weapon.fire(stats.strength)

func equip_weapon(weapon_item: InventoryItem):
	if not weapon_item.equipment_resource is Weapon:
		return
	
	# Create physics weapon from resource
	var weapon_res = weapon_item.equipment_resource
	var physics_weapon: PhysicsWeapon
	
	if weapon_res.is_ranged:
		if weapon_res.name.contains("Bow"):
			physics_weapon = BowWeapon.new()
		else:
			physics_weapon = RangedWeapon.new()
	else:
		physics_weapon = PhysicsWeapon.new()
	
	# Configure weapon properties
	physics_weapon.weapon_name = weapon_res.name
	physics_weapon.base_damage_multiplier = weapon_res.damage_base
	physics_weapon.damage_type = weapon_res.damage_type
	physics_weapon.weapon_length = weapon_res.attack_range
	
	equipped_weapon = physics_weapon
	
	# Attach to procedural body
	if procedural_body:
		procedural_body.equip_weapon(physics_weapon)

func set_path(path: PackedVector2Array):
	current_path.clear()
	for point in path:
		current_path.append(point)
	path_index = 0
	ai_state = AIState.FOLLOWING_PATH

func _on_body_part_destroyed(part_name: String):
	match part_name:
		"head":
			_die()
		"eyes":
			stats.vision = 0
		"ears":
			stats.hearing = 0
		"left_leg", "right_leg":
			# Severe movement penalty
			stats.movement *= 0.3
		"left_arm", "right_arm":
			# Can't use two-handed weapons
			if equipped_weapon and equipped_weapon.weapon_weight > 3.0:
				equipped_weapon.queue_free()
				equipped_weapon = null

func _become_unconscious():
	ai_state = AIState.IDLE
	character_unconscious.emit()
	set_physics_process(false)
	
	# Ragdoll effect
	if procedural_body:
		for child in procedural_body.get_children():
			if child is RigidBody2D:
				child.freeze = false

func _die():
	character_died.emit()
	
	# Full ragdoll
	if procedural_body:
		for child in procedural_body.get_children():
			if child is RigidBody2D:
				child.freeze = false
				child.apply_impulse(Vector2(randf_range(-100, 100), randf_range(-100, 100)))
	
	# Drop items
	if inventory:
		for item in inventory.items:
			_drop_item(item)
	
	# Remove from groups
	remove_from_group("characters")
	remove_from_group("player_characters")
	remove_from_group("enemy_characters")
	
	# Disable processing but keep visual
	set_physics_process(false)
	set_process(false)

func _drop_item(item: InventoryItem):
	# Create pickup on ground
	var pickup = Area2D.new()
	pickup.position = global_position + Vector2(randf_range(-20, 20), randf_range(-20, 20))
	pickup.set_meta("item", item)
	pickup.set_meta("quantity", inventory.items[item])
	
	var shape = CircleShape2D.new()
	shape.radius = 10
	var collision = CollisionShape2D.new()
	collision.shape = shape
	pickup.add_child(collision)
	
	var sprite = Sprite2D.new()
	if item.icon:
		sprite.texture = item.icon
	pickup.add_child(sprite)
	
	get_parent().add_child(pickup)
