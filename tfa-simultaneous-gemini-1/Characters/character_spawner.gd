# character_spawner.gd
# Attach to your main scene or a manager node
extends Node

const ProceduralCharacterScript = preload("res://Characters/ProceduralCharacter.gd")

@export var characters_json_path: String = "res://data/TopDownCharacters.json"
@export var spawn_container: Node2D  # Where to spawn characters

var characters_database: Array = []
var characters_in_scene: Array = []
var enemies: Array
var player = null
var factions: Dictionary
func _ready() -> void:
	load_characters_database()
	factions = load_factions_from_json("res://data/factions.json")
	player = spawn_character_by_name("Default Human", Vector2(40.0,40.0))
	# Using new shape-based weapon system
	# METHOD 1: Equip by name (requires ItemDatabase autoload)
	# This is the cleanest way - just reference items by name from your JSON database
	player.give_weapon_by_name("Longsword")
	player.give_weapon_by_name("Battle Axe")
	player.equip_equipment_by_name("Fancy Metal Helmet")
	player.equip_equipment_by_name("Breastplate 2")
	player.set_faction("player")
	# Create enemies
	_spawn_enemy(Vector2(250, 80))
	_spawn_enemy(Vector2(300, 150))
	_spawn_enemy(Vector2(80, 220))
	
func load_factions_from_json(json_path: String):
	if not FileAccess.file_exists(json_path):
		push_warning("Factions JSON not found: " + json_path)
		return null
	
	var file = FileAccess.open(json_path, FileAccess.READ)
	var json_text = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var error = json.parse(json_text)
	if error != OK:
		push_error("Failed to parse factions JSON: " + json.get_error_message())
		return
	
	var data = json.get_data()
	if data.has("factions"):
		for faction_data in data["factions"]:
			var faction = Faction.new()
			faction.load_from_data(faction_data)
			factions[faction.faction_id] = faction
	print("factions: ", factions)
	print("Loaded ", factions.size(), " factions")
	return factions

func _create_character(pos: Vector2, faction: String, ai_enabled: bool) -> ProceduralCharacter:
	var char = ProceduralCharacter.new()
	char.position = pos
	char.faction_id = faction
	
	var skin_colors = ["#E8BEAC", "#D4A574", "#8D5524", "#C68642"]
	var hair_colors = ["#4a3728", "#2C1810", "#8B4513", "#1C1C1C"]
	
	char.load_from_data({
		"skin_color": skin_colors[randi() % skin_colors.size()],
		"hair_color": hair_colors[randi() % hair_colors.size()],
		"faction": faction
	})
	
	char.character_died.connect(_on_character_died.bind(char))
	characters_in_scene.append(char)
	return char

func _spawn_enemy(pos: Vector2, faction: String ="bandits") -> void:
	var enemy = _create_character(pos, "enemy", true)
	enemy.set_faction("bandits")
	# Random stats
	enemy.set_stats(
		randi_range(8, 14),   # STR
		randi_range(8, 12),   # CON
		randi_range(8, 14)    # DEX
	)
	add_child(enemy)

	# Random weapon
	var weapon_types = [
		"Longsword", "Dagger"
	]
	var enemy_weapon = weapon_types[randi() % weapon_types.size()]
	print("attempting to give enemy weapon: ", enemy_weapon)
	enemy.give_weapon_by_name(weapon_types[randi() % weapon_types.size()])
	
	# Light armor
	if randf() > 0.5:
		enemy.equip_equipment_by_name("Fancy Metal Helmet")
	enemy.AI_enabled = true
	enemies.append(enemy)

func _process(delta: float) -> void:
	# Check for combat collisions# Update clash cooldowns
	var to_remove = []
	for key in clash_cooldowns:
		clash_cooldowns[key] -= delta
		if clash_cooldowns[key] <= 0:
			to_remove.append(key)
	for key in to_remove:
		clash_cooldowns.erase(key)
	_check_combat_collisions()

func _check_combat_collisions() -> void:
	if not player or not player.is_alive():
		return
	
	# Check player attacking enemies
	if player.is_attacking():
		print("Player is attacking")
		for enemy in enemies:
			if not enemy.is_alive():
				continue
			if not can_hit_target(player, enemy):
				continue
			
			var hit = check_weapon_body_collision(player, enemy)
			print("Was there actually a hit? ", hit)
			if hit.get("hit", false):
				register_hit(player, enemy)
				process_weapon_hit(
					player, enemy, hit["position"],
					player.current_weapon, hit["velocity"]
				)
	
	# Check enemies attacking player
	for enemy in enemies:
		if not enemy.is_alive() or not enemy.is_attacking():
			continue
		if not can_hit_target(enemy, player):
			continue
		
		var hit = check_weapon_body_collision(enemy, player)
		if hit.get("hit", false):
			register_hit(enemy, player)
			process_weapon_hit(
				enemy, player, hit["position"],
				enemy.current_weapon, hit["velocity"]
			)
	
	# Check weapon clashes
	if player.is_attacking():
		for enemy in enemies:
			if not enemy.is_alive() or not enemy.is_attacking():
				continue
			
			var clash = check_weapon_weapon_collision(player, enemy)
			if clash.get("collision", false):
				process_weapon_clash(player, enemy, clash["position"])

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_R:
				# Restart
				get_tree().reload_current_scene()
			KEY_P:
				# Print status
				_print_status()
			KEY_SPACE:
				# Spawn new enemy
				_spawn_enemy(Vector2(
					randf_range(50, 350),
					randf_range(50, 250)
				))
				print("Spawned new enemy!")

# ===== COMBAT CALLBACKS =====

func _on_damage_dealt(attacker: Node2D, target: Node2D, info: Dictionary) -> void:
	var attacker_name = "Player" if attacker == player else "Enemy"
	var target_name = "Player" if target == player else "Enemy"
	print("%s hit %s's %s for %d damage (blocked %d)" % [
		attacker_name, target_name, info["limb_name"],
		info["actual_damage"], info["blocked"]
	])
	
	if info.get("limb_disabled", false):
		print("  -> %s DISABLED!" % info["limb_name"])
	if info.get("limb_severed", false):
		print("  -> %s SEVERED!" % info["limb_name"])

func _on_weapon_bounced(attacker: Node2D, target: Node2D, limb_type: int) -> void:
	print("Weapon bounced off armor!")

func _on_weapon_clash(char1: Node2D, char2: Node2D, winner: Node2D, power_diff: float) -> void:
	var winner_name = "Player" if winner == player else "Enemy"
	print("Weapon clash! %s wins (power diff: %.1f)" % [winner_name, power_diff])

func _on_weapon_disarmed(character: Node2D) -> void:
	var name = "Player" if character == player else "Enemy"
	print("%s was DISARMED!" % name)

func _on_character_died(character: ProceduralCharacter) -> void:
	var name = "Player" if character == player else "Enemy"
	print("%s has died!" % name)
	
	if character == player:
		print("\n=== GAME OVER ===")
		print("Press R to restart")

func _print_status() -> void:
	print("\n=== STATUS ===")
	print("Player: %s" % player.get_stats_string())
	print(player.limb_system.get_status_string())
	print("")
	for i in range(enemies.size()):
		var enemy = enemies[i]
		if enemy.is_alive():
			print("Enemy %d: %s" % [i+1, enemy.get_stats_string()])

	
	'''
	player.equip_equipment({
		"name": "Leather Pants",
		"type": "pants",
		"base_width": 7.0,
		"base_height": 16.0,
		"sprite_path": "res://Items//leather_pants.png"
	})

	player.equip_equipment({
		"name": "Leather Boots",
		"type": "boots",
		"base_width": 8.0,
		"base_height": 8.0,
		"sprite_path": "res://Items//leather_boots.png"
	})
	'''
func load_characters_database() -> void:
	if not FileAccess.file_exists(characters_json_path):
		push_warning("Characters JSON not found at: " + characters_json_path)
		return
	
	var file = FileAccess.open(characters_json_path, FileAccess.READ)
	var json_text = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var error = json.parse(json_text)
	
	if error != OK:
		push_error("Failed to parse characters JSON: " + json.get_error_message())
		return
	
	var data = json.get_data()
	if data is Dictionary and data.has("characters"):
		characters_database = data["characters"]
	elif data is Array:
		characters_database = data
	
	print("Loaded ", characters_database.size(), " character definitions")

func spawn_character_by_name(char_name: String, spawn_position: Vector2) -> ProceduralCharacter:
	for char_data in characters_database:
		if char_data.get("name", "") == char_name:
			return spawn_character(char_data, spawn_position)
	
	push_warning("Character not found: " + char_name)
	return null

func spawn_character_by_index(index: int, spawn_position: Vector2) -> ProceduralCharacter:
	if index < 0 or index >= characters_database.size():
		push_warning("Character index out of bounds: " + str(index))
		return null
	
	return spawn_character(characters_database[index], spawn_position)

func spawn_character(data: Dictionary, spawn_position: Vector2) -> ProceduralCharacter:
	var container = spawn_container if spawn_container else self
	
	# Create character node
	var character_node = Node2D.new()
	character_node.set_script(ProceduralCharacterScript)
	character_node.global_position = spawn_position
	
	container.add_child(character_node)
	
	# Load character data
	character_node.load_from_data(data)
	
	characters_in_scene.append(character_node)
	
	print("Spawned character: ", data.get("name", "Unknown"))
	return character_node

func spawn_all_characters(spacing: float = 100.0) -> void:
	var start_x = -((characters_database.size() - 1) * spacing) / 2.0
	
	for i in range(characters_database.size()):
		var pos = Vector2(start_x + i * spacing, 0)
		spawn_character_by_index(i, pos)

func get_character_by_name(char_name: String) -> ProceduralCharacter:
	for character in characters_in_scene:
		if character.character_data.get("name", "") == char_name:
			return character
	return null

func despawn_character(character: ProceduralCharacter) -> void:
	if character in characters_in_scene:
		characters_in_scene.erase(character)
		character.queue_free()

func despawn_all() -> void:
	for character in characters_in_scene:
		character.queue_free()
	characters_in_scene.clear()
	
func _toggle_weapon_debug() -> void:
	var weapon = player.get_current_weapon()
	if weapon:
		weapon.set_debug_draw(not weapon.debug_draw)
		print("Debug visualization: %s" % ("ON" if weapon.debug_draw else "OFF"))

var _torso_equipment_index: int = 0
var _torso_equipment_options: Array = [
	{"type": "torso_armor", "name": "Steel Breastplate", "base_width": 28.0, "base_height": 18.0},
	{"type": "torso_armor", "name": "Leather Armor", "base_width": 26.0, "base_height": 16.0},
	{"type": "torso_armor", "name": "Chainmail", "base_width": 28.0, "base_height": 20.0},
	null  # No torso equipment
]

func _cycle_torso_equipment() -> void:
	_torso_equipment_index = (_torso_equipment_index + 1) % _torso_equipment_options.size()
	var equip_data = _torso_equipment_options[_torso_equipment_index]
	
	if equip_data:
		player.equip_equipment(equip_data)
		print("Equipped: %s" % equip_data.get("name", "unknown"))
	else:
		player.unequip_slot(EquipmentShape.EquipmentSlot.TORSO)
		print("Removed torso equipment")
		
# Weapon penetration states
enum PenetrationState { 
	NOT_HITTING,      # No contact
	BOUNCED,          # DR too high, weapon bounced off
	PENETRATING,      # Currently sinking into flesh
	FULLY_PENETRATED, # Reached maximum depth
	STUCK             # Weapon is stuck in target
}

# Active hit tracking (prevents multiple hits per swing)
var active_hits: Dictionary = {}  # attacker_id -> { target_id -> hit_data }

# Weapon clash cooldowns
var clash_cooldowns: Dictionary = {}  # "id1_id2" -> time_remaining

signal damage_dealt(attacker: Node2D, target: Node2D, damage_info: Dictionary)
signal weapon_bounced(attacker: Node2D, target: Node2D, limb_type: int)
signal weapon_clash(char1: Node2D, char2: Node2D, winner: Node2D, power_diff: float)
signal weapon_knocked_away(character: Node2D)
signal weapon_disarmed(character: Node2D)

const CLASH_COOLDOWN: float = 0.3  # Seconds between weapon clashes	

# ===== WEAPON VS BODY COLLISION =====

func process_weapon_hit(
	attacker: ProceduralCharacter,
	target: ProceduralCharacter,
	hit_position: Vector2,  # World position of hit
	weapon: WeaponShape,
	attack_velocity: float  # Speed of the swing (affects penetration)
) -> Dictionary:
	"""Process a weapon hitting a character's body"""
	print("someone actually got hit")
	
	
	#Calculation of complex damage
	# Determine which limb was hit
	var local_hit = target.to_local(hit_position)
	var limb_type = target.get_limb_at_position(
		local_hit, 
		target.body_width, 
		target.body_height
	)
	
	# Get armor DR for that limb
	var limb = target.get_limb(limb_type)
	# Calculate base damage
	var damage = target.damage_limb(limb_type, weapon.base_damage) #need to heavily update to add damage riders
	var armor_dr = limb.armor_dr if limb else 0
	print("limb: ", limb.name)
	# Calculate penetration based on damage vs DR
	var penetration_result = _calculate_penetration(weapon.base_damage, armor_dr, attack_velocity, weapon)
	print("Is the attack actually penetrating? Penetration = ", penetration_result)
	var result = {
		"attacker": attacker,
		"target": target,
		"weapon": weapon,
		"limb_type": limb_type,
		"limb_name":limb_type,
		"raw_damage": damage,
		"armor_dr": armor_dr,
		"penetration_state": penetration_result.state,
		"penetration_depth": penetration_result.depth,
		"velocity_reduction": penetration_result.velocity_reduction,
		"actual_damage": 0,
		"blocked": 0
	}
	
	# Apply damage based on penetration
	if penetration_result.state == PenetrationState.BOUNCED:
		result["blocked"] = damage
		SfxManager.play("clash", attacker.position)
		emit_signal("weapon_bounced", attacker, target, limb_type)
	else:
		SfxManager.play("sword-on-flesh",target.position)
		# Damage scales with penetration depth
	
	return result

func _calculate_penetration(damage: Dictionary, armor_dr: Dictionary, velocity: float, weapon: WeaponShape) -> Dictionary:
	"""Calculate how deeply a weapon penetrates based on damage, armor, and velocity"""
	
	var total_effective_damage = 0.0
	
	# 1. Calculate unresisted damage for each type and sum them
	for damage_type in damage:
		var raw_val = damage[damage_type]
		var dr_val = armor_dr.get(damage_type, 0) # Default to 0 if type not in DR
		
		# Ensure we don't add negative values if armor exceeds damage
		var effective_type_damage = max(0, raw_val - dr_val)
		
		# If damage got through, trigger the condition effect
			
		total_effective_damage += effective_type_damage
	
	# 2. If armor completely blocks all types, weapon bounces
	if total_effective_damage <= 0:
		return {
			"state": PenetrationState.BOUNCED,
			"depth": 0.0,
			"velocity_reduction": 1.0  # Full stop
		}
	
	# 3. Apply velocity to the total unresisted damage
	# velocity affects initial penetration power
	var velocity_factor = clamp(velocity / 100.0, 0.5, 2.0)
	var penetration_power = total_effective_damage * velocity_factor
	
	# 4. Flesh resistance (nonlinear - gets harder to penetrate deeper)
	var max_penetration_depth = 1.0
	var flesh_resistance = 10.0  # Base resistance
	
	# Calculate depth using inverse relationship (asymptotic approach to max)
	# Formula: max * (1 - e^(-power / resistance))
	var depth = max_penetration_depth * (1.0 - exp(-penetration_power / (flesh_resistance * 3)))
	
	# 5. Velocity reduction (nonlinear)
	var velocity_reduction = depth * 0.7 + 0.1  # Always lose at least 10% velocity
	
	var state = PenetrationState.PENETRATING
	if depth >= 0.9:
		state = PenetrationState.FULLY_PENETRATED
	
	return {
		"state": state,
		"depth": depth,
		"velocity_reduction": clamp(velocity_reduction, 0.0, 1.0)
	}
# ===== WEAPON VS WEAPON COLLISION =====

func process_weapon_clash(
	char1: ProceduralCharacter,
	char2: ProceduralCharacter,
	clash_position: Vector2
) -> Dictionary:
	"""Process two weapons colliding"""
	
	# Check cooldown
	var clash_key = _get_clash_key(char1, char2)
	if clash_cooldowns.has(clash_key):
		return {"result": "cooldown"}
	
	# Set cooldown
	clash_cooldowns[clash_key] = CLASH_COOLDOWN
	
	
	# Calculate clash power (STR + partial CON for bracing)
	var power1 = char1.clash_power
	var power2 = char2.clash_power

	
	var power_diff = power1 - power2
	var winner: ProceduralCharacter = null
	var loser: ProceduralCharacter = null
	
	var result = {
		"char1": char1,
		"char2": char2,
		"power1": power1,
		"power2": power2,
		"power_diff": abs(power_diff),
		"outcome": "stalemate",
		"winner": null,
		"loser": null
	}
	
	# Determine outcome based on power difference
	if abs(power_diff) < 2.0:
		# Close match - both stagger slightly
		SfxManager.play("clash", char1.position)

		result["outcome"] = "stalemate"
		print("weapon clash resulted in stalemate")
		_apply_stagger(char1, 0.1)
		_apply_stagger(char2, 0.1)
	elif abs(power_diff) < 5.0:
		# Moderate difference - loser knocked back
		winner = char1 if power_diff > 0 else char2
		loser = char2 if power_diff > 0 else char1
		print("weapon clash resulted in knockback")
		result["outcome"] = "knockback"
		result["winner"] = winner
		result["loser"] = loser
		_apply_stagger(loser, 0.3)
		emit_signal("weapon_clash", char1, char2, winner, abs(power_diff))
	elif abs(power_diff) < 10.0:
		# Large difference - weapon knocked away
		print("weapon clash resulted in weapon being knocked away")
		winner = char1 if power_diff > 0 else char2
		loser = char2 if power_diff > 0 else char1
		result["outcome"] = "knocked_away"
		result["winner"] = winner
		result["loser"] = loser
		_knock_weapon_away(loser)
		emit_signal("weapon_knocked_away", loser)
	else:
		# Massive difference - disarm
		winner = char1 if power_diff > 0 else char2
		loser = char2 if power_diff > 0 else char1
		result["outcome"] = "disarm"
		result["winner"] = winner
		result["loser"] = loser
		_disarm_character(loser)
		emit_signal("weapon_disarmed", loser)
	
	return result

func _get_clash_key(char1: Node2D, char2: Node2D) -> String:
	var id1 = char1.get_instance_id()
	var id2 = char2.get_instance_id()
	if id1 > id2:
		return "%d_%d" % [id2, id1]
	return "%d_%d" % [id1, id2]

func _apply_stagger(character: ProceduralCharacter, intensity: float) -> void:
	"""Apply stagger effect to character (interrupts attack, brief pause)"""
	if character.attack_animator:
		# Interrupt current attack if stagger is strong enough
		if intensity >= 0.2 and character.attack_animator.is_attacking():
			character.attack_animator.interrupt_attack()
		
		# Visual feedback could be added here (screen shake, etc)

func _knock_weapon_away(character: ProceduralCharacter) -> void:
	"""Knock the weapon to the side (still held but out of position)"""
	if character.attack_animator:
		character.attack_animator.interrupt_attack()
		character.attack_animator.apply_knockback(0.4)  # Recovery time

func _disarm_character(character: ProceduralCharacter) -> void:
	"""Force character to drop their weapon"""
	if character.attack_animator:
		character.attack_animator.interrupt_attack()
	
	# TODO: Create dropped weapon entity at character position
	# For now, just holster
	character.holster_weapon()

# ===== HIT TRACKING =====

func register_attack_start(attacker: ProceduralCharacter) -> void:
	"""Called when an attack begins - resets hit tracking for this attack"""
	active_hits[attacker.get_instance_id()] = {}

func register_attack_end(attacker: ProceduralCharacter) -> void:
	"""Called when an attack ends - clears hit tracking"""
	active_hits.erase(attacker.get_instance_id())

func can_hit_target(attacker: ProceduralCharacter, target: ProceduralCharacter) -> bool:
	"""Check if this attack can still hit this target (hasn't already)"""
	var attacker_id = attacker.get_instance_id()
	var target_id = target.get_instance_id()
	
	if not active_hits.has(attacker_id):
		return true
	
	return not active_hits[attacker_id].has(target_id)

func register_hit(attacker: ProceduralCharacter, target: ProceduralCharacter) -> void:
	"""Mark that this attack has hit this target"""
	var attacker_id = attacker.get_instance_id()
	var target_id = target.get_instance_id()
	
	if not active_hits.has(attacker_id):
		active_hits[attacker_id] = {}
	
	active_hits[attacker_id][target_id] = true

# ===== COLLISION DETECTION HELPERS =====

func get_weapon_hitbox(character: ProceduralCharacter) -> Array:
	"""Get the weapon's current hitbox as an array of world-space points"""
	if not character.current_weapon:
		return []
	
	var weapon = character.current_weapon
	var weapon_holder = character.weapon_holder
	
	# Get weapon collision rect in local space
	var rect = weapon.get_blade_collision_rect()
	
	# Transform to world space
	var points = [
		weapon_holder.to_global(weapon.position + rect.position),
		weapon_holder.to_global(weapon.position + rect.position + Vector2(rect.size.x, 0)),
		weapon_holder.to_global(weapon.position + rect.position + rect.size),
		weapon_holder.to_global(weapon.position + rect.position + Vector2(0, rect.size.y))
	]
	
	return points

func get_body_hitbox(character: ProceduralCharacter) -> Rect2:
	"""Get character's body hitbox in world space"""
	var half_width = character.body_width / 2
	var half_height = character.body_height / 2 + character.head_length
	
	var local_rect = Rect2(
		Vector2(-half_width, -half_height),
		Vector2(character.body_width, half_height * 2 + character.leg_length)
	)
	
	# For simplicity, return axis-aligned rect (rotation handled separately)
	return Rect2(
		character.global_position + local_rect.position.rotated(character.rotation),
		local_rect.size
	)

func check_weapon_body_collision(
	attacker: ProceduralCharacter,
	target: ProceduralCharacter
) -> Dictionary:
	"""Check if attacker's weapon is hitting target's body"""
	
	if not attacker.current_weapon:
		return {"hit": false}
	
	if not attacker.attack_animator or not attacker.attack_animator.is_attacking():
		return {"hit": false}
	
	# Simple rect-based collision for now
	var weapon_tip = attacker.weapon_holder.to_global(
		attacker.current_weapon.position + attacker.current_weapon.get_tip_local_position()
	)
	
	var body_rect = get_body_hitbox(target)
	
	if body_rect.has_point(weapon_tip):
		return {
			"hit": true,
			"position": weapon_tip,
			"velocity": 100.0  # TODO: Calculate actual velocity from animation
		}
	
	return {"hit": false}

func check_weapon_weapon_collision(
	char1: ProceduralCharacter,
	char2: ProceduralCharacter
) -> Dictionary:
	"""Check if two weapons are colliding"""
	
	if not char1.current_weapon or not char2.current_weapon:
		return {"collision": false}
	
	# Both must be attacking
	if not char1.attack_animator or not char1.attack_animator.is_attacking():
		return {"collision": false}
	if not char2.attack_animator or not char2.attack_animator.is_attacking():
		return {"collision": false}
	
	# Get weapon blade rects
	var rect1 = char1.current_weapon.get_blade_collision_rect()
	var rect2 = char2.current_weapon.get_blade_collision_rect()
	
	# Transform to world space (simplified - just use tip positions and a radius)
	var tip1 = char1.weapon_holder.to_global(
		char1.current_weapon.position + char1.current_weapon.get_tip_local_position()
	)
	var tip2 = char2.weapon_holder.to_global(
		char2.current_weapon.position + char2.current_weapon.get_tip_local_position()
	)
	
	# Check if tips are close (crude but fast)
	var collision_radius = 15.0
	if tip1.distance_to(tip2) < collision_radius:
		return {
			"collision": true,
			"position": (tip1 + tip2) / 2
		}
	
	return {"collision": false}
