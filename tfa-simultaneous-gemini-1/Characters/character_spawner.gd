# character_spawner.gd
# Attach to your main scene or a manager node
extends Node

const ProceduralCharacterScript = preload("res://Characters/ProceduralCharacter.gd")

@onready var fog_manager: FogManager = $FogManager

@export var characters_json_path: String = "res://data/TopDownCharacters.json"
var CharacterScene = preload("res://Characters/ProceduralCharacter.tscn")
@export var spawn_container: Node2D  # Where to spawn characters

var characters_database: Array = []
var characters_in_scene: Array = []
var party_chars: Array = [] 
var enemies: Array
var player = null
var item_scene: PackedScene = preload("res://Structures/Objects/Item.tscn")
var items_in_scene: Array = []
var structure_scene: PackedScene = preload("res://Structures/Structure.tscn")
var structures_in_scene: Array[Structure] = []

var factions: Dictionary
signal character_selected(character: ProceduralCharacter, index: int)
signal character_deselected(character: ProceduralCharacter)

# Currently selected character
var selected_character: ProceduralCharacter = null
var selected_index: int = 0

# Selection indicator
var selection_indicator: Node2D = null
const SELECTION_CIRCLE_COLOR = Color(1, 1, 1, 0.8)  # White
const SELECTION_CIRCLE_WIDTH = 1.0

'''
# ---------------------------------------------------------------------------
# NPC spawning
# ---------------------------------------------------------------------------
 
func _spawn_npcs(npc_list: Array) -> void:
	for npc_def in npc_list:
		# Check spawn conditions
		if npc_def.has("condition") and not _check_condition(npc_def["condition"]):
			continue
 
		var template_id: String = npc_def.get("template_id", "")
		var pos_arr = npc_def.get("position", [0, 0])
		var base_pos = Vector2(pos_arr[0], pos_arr[1])
		var count: int = npc_def.get("count", 1)
		var spread: float = npc_def.get("spread_radius", 0)
 
		for i in range(count):
			var pos = base_pos
			if spread > 0 and i > 0:
				pos += Vector2(randf_range(-spread, spread), randf_range(-spread, spread))
 
			var npc = _spawn_character(template_id, pos)
			if npc:
				npc.AI_enabled = true
 
				# Optional overrides from the spawn definition
				if npc_def.has("unique_name"):
					npc.display_name = npc_def["unique_name"]
				if npc_def.has("patrol_points"):
					var patrol = []
					for pt in npc_def["patrol_points"]:
						patrol.append(Vector2(pt[0], pt[1]))
					npc.set_meta("patrol_points", patrol)
 
# ---------------------------------------------------------------------------
# Core character spawn helper
# ---------------------------------------------------------------------------
 
func _spawn_character(template_id: String, pos: Vector2, overrides: Dictionary = {}) -> ProceduralCharacter:
	var character = CharacterScene.instantiate()
 
	# Position first (before body creation reads it)
	character.position = pos
 
	# Build from template — this applies race, background, stats, equipment
	CharacterDatabase.build_character(character, template_id, overrides)
 
	# Connect signals
	character.character_died.connect(_on_character_died.bind(character))
 
	# Add to scene tree and track
	add_child(character)
	characters_in_scene.append(character)
 
	return character
 

'''

func _ready() -> void:
	load_characters_database()
	process_mode = Node.PROCESS_MODE_ALWAYS
	fog_manager.create_fog_from_params(
		Color(0.2, 0.6, 0.2, 0.4),   # green poison fog
		Vector2(512, 512),             # size in pixels
		0.95,                           # density
		6.0,                           # noise scale
		Vector2(0.63, 0.215),          # drift speed
		Vector2(600, 800)             # world position
	)
	_create_selection_indicator(Globals.default_body_width+5)
	factions = load_factions_from_json("res://data/factions.json")
	player = spawn_character_by_name("Default Human", Vector2(40.0,40.0))
	call_deferred("_select_initial_character")
	var ally = spawn_character_by_name("Default Human", Vector2(80.0,80.0), "player")
	ally.AI_enabled = true
	ally.give_weapon_by_name("Dagger")
	party_chars.append(player)
	party_chars.append(ally)
	# Using new shape-based weapon system
	# METHOD 1: Equip by name (requires ItemDatabase autoload)
	# This is the cleanest way - just reference items by name from your JSON database
	player.give_weapon_by_name("Longsword")
	#player.give_weapon_by_name("Dagger", "Off")
	player.give_ability_by_name("fireball", "Off")
	player.equip_equipment_by_name("Full Face Helmet")
	player.equip_equipment_by_name("Breastplate 2")
	player.set_faction("player")
	# Create enemies
	#var targeting = AbilityTargetingScript.new()
	#for char in party_chars:
	#	char.add_child(targeting)
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
	#fix your spawning code using updated faction JSON
	var data = json.get_data()
	if data.has("factions"):
		for faction_data in data["factions"]:
			var faction = Faction.new()
			faction.load_from_data(faction_data)
			factions[faction.faction_id] = faction
	#print("factions: ", factions)
	#print("Loaded ", factions.size(), " factions")
	return factions

func _create_character(pos: Vector2, faction: String, ai_enabled: bool) -> ProceduralCharacter:
	var char = CharacterScene.instantiate()
	#Add ConditionManager:
	var condition_manager = ConditionManager.new()
	condition_manager.name = "ConditionManager"
	char.add_child(condition_manager)
	char.position = pos
	char.faction_id = faction
	
	var skin_colors = ["#E8BEAC", "#D4A574", "#8D5524", "#C68642"]
	var hair_colors = ["#4a3728", "#2C1810", "#8B4513", "#1C1C1C"]
	var hair_types = ["bald", "balidng", "full", "combover", "pompadour", "buzz", "mohawk"]
	char.load_from_data({
		"skin_color": skin_colors[randi() % skin_colors.size()],
		"hair_color": hair_colors[randi() % hair_colors.size()],
		"hair_style": hair_types[randi() % hair_types.size()],
		"faction": faction
	})
	
	char.character_died.connect(_on_character_died.bind(char))
	characters_in_scene.append(char)
	return char

func _spawn_enemy(pos: Vector2, faction: String ="bandits") -> void:
	var enemy = _create_character(pos, "enemy", true)
	enemy.set_faction(faction)
	
	# Random stats
	enemy.set_stats(
		randi_range(40, 70),   # STR
		randi_range(40, 60),   # CON
		randi_range(40, 70)    # DEX
	)
	add_child(enemy)

	# Random weapon
	var weapon_types = [ #update to use weapon database
		"Longsword", "Dagger"
	]
	var enemy_weapon = weapon_types[randi() % weapon_types.size()]
	print("attempting to give enemy weapon: ", enemy_weapon)
	enemy.give_weapon_by_name(weapon_types[randi() % weapon_types.size()])
	
	#  armor
	if randf() > 0.5:
		enemy.equip_equipment_by_name("Fancy Metal Helmet") #update to use weapon database
	enemy.AI_enabled = true
	enemies.append(enemy)
	
func create_item(item_id: String, world_position: Vector2, stack_count: int = 1) -> Item2:
	"""Create any item (weapon, equipment, or general item) by its ID and place it in the world."""
	var item_instance = item_scene.instantiate() as Item2
	item_instance.id = item_id
	item_instance.global_position = world_position

	# Set stack count before _ready applies data
	if stack_count > 1:
		item_instance.stack_count = stack_count

	add_child(item_instance)
	items_in_scene.append(item_instance)

	# Connect signals
	item_instance.destroyed.connect(_on_item_destroyed)

	return item_instance

func _on_item_destroyed(item: Item2):
	# Remove from tracking
	items_in_scene.erase(item)

	# Spawn resource items from the destroyed item
	if item.resources.is_empty():
		return

	var spawn_offset = 0
	for resource_id in item.resources:
		var amount = int(item.resources[resource_id])
		if amount <= 0:
			continue

		# Look up the resource in the database to figure out stack sizes
		var resource_data = _lookup_any_item(resource_id)
		var max_stack = int(resource_data.get("max_stack_size", 100)) if resource_data else 100

		# Spawn in stacks up to max_stack_size
		var remaining = amount
		while remaining > 0:
			var this_stack = mini(remaining, max_stack)
			var offset = Vector2(spawn_offset * 12, 0).rotated(randf() * TAU)
			var resource_item = create_item(resource_id, item.global_position + offset, this_stack)
			remaining -= this_stack
			spawn_offset += 1

func _lookup_any_item(item_id: String) -> Dictionary:
	"""Look up item data from any category in the database."""
	var item_key = Globals.name_to_id(item_id)
	if ItemDatabase.weapons.has(item_key):
		return ItemDatabase.weapons[item_key]
	if ItemDatabase.equipment.has(item_key):
		return ItemDatabase.equipment[item_key]
	if ItemDatabase.items.has(item_key):
		return ItemDatabase.items[item_key]
	# Try raw id
	if ItemDatabase.items.has(item_id):
		return ItemDatabase.items[item_id]
	return {}
	

func create_structure(structure_id: String, world_position: Vector2) -> Structure:
	"""Create a structure by its ID and place it in the world."""
	var structure_instance = structure_scene.instantiate() as Structure
	structure_instance.structure_id = structure_id
	structure_instance.global_position = world_position

	add_child(structure_instance)
	structures_in_scene.append(structure_instance)

	structure_instance.destroyed.connect(_on_structure_destroyed)

	return structure_instance

func _on_structure_destroyed(structure: Structure, world_pos: Vector2):
	structures_in_scene.erase(structure)

	if structure.resources.is_empty():
		return

	var spawn_offset = 0
	for resource_id in structure.resources:
		var amount = int(structure.resources[resource_id])
		if amount <= 0:
			continue

		var resource_data = _lookup_any_item(resource_id)
		var max_stack = int(resource_data.get("max_stack_size", 100)) if resource_data else 100

		var remaining = amount
		while remaining > 0:
			var this_stack = mini(remaining, max_stack)
			var offset = Vector2(spawn_offset * 12, 0).rotated(randf() * TAU)
			create_item(resource_id, world_pos + offset, this_stack)
			remaining -= this_stack
			spawn_offset += 1

func _process(delta: float) -> void:
	# Check for combat collisions# Update clash cooldowns
	if not PauseManager.is_paused:
		var to_remove = []
		for key in clash_cooldowns:
			clash_cooldowns[key] -= delta
			if clash_cooldowns[key] <= 0:
				to_remove.append(key)
		for key in to_remove:
			clash_cooldowns.erase(key)
		_check_combat_collisions()
	# Tick fog effects
		if $FogManager:
			$FogManager.update_fogs(delta, characters_in_scene)
	if selected_character and is_instance_valid(selected_character) and selection_indicator:
		selection_indicator.global_position = selected_character.global_position
		if PauseManager.is_paused:
			selection_indicator.visible = true
	if selection_indicator and not PauseManager.is_paused:
		selection_indicator.visible = false

func _check_combat_collisions() -> void:
	var all_characters = characters_in_scene

	for attacker in all_characters:
		if not attacker.is_alive() or not attacker.is_attacking():
			continue

		var weapon
		if attacker.current_hand == "Main":
			weapon = attacker.current_main_hand_item
		else:
			weapon = attacker.current_off_hand_item

		# Check against other characters
		for victim in all_characters:
			if attacker == victim:
				continue
			if not victim.is_alive():
				continue
			if not can_hit_target(attacker, victim):
				continue

			var hit = check_weapon_body_collision(attacker, victim)
			if hit.get("hit", false):
				register_hit(attacker, victim)
				process_weapon_hit(attacker, victim, hit["position"], weapon, hit["velocity"])

		# Check against items
		for item in items_in_scene:
			if not is_instance_valid(item):
				continue
			if not can_hit_target(attacker, item):
				continue

			var hit = check_weapon_body_collision(attacker, item)
			if hit.get("hit", false):
				process_object_hit(attacker, item, hit["position"], weapon, hit["velocity"])

		# Check against structures
		for structure in structures_in_scene:
			if not is_instance_valid(structure):
				continue
			if not can_hit_target(attacker, structure):
				continue

			var hit = check_weapon_body_collision(attacker, structure)
			if hit.get("hit", false):
				process_object_hit(attacker, structure, hit["position"], weapon, hit["velocity"])
				
func process_object_hit(
	attacker: ProceduralCharacter,
	target: Node2D,
	hit_position: Vector2,
	weapon: Node2D,
	attack_velocity: float
) -> Dictionary:
	# Build damage dict — duplicate to avoid mutating weapon data
	var attack_damage: Dictionary
	if weapon:
		attack_damage = weapon.damage.duplicate()
		if weapon.get("traits") and "melee" in weapon.traits:
			var str_bonus = attacker.strength / 10.0
			for dtype in attack_damage:
				attack_damage[dtype] += str_bonus
	else:
		attack_damage = {
			attacker.unarmed_strike_damage_type:
				attacker.unarmed_strike_damage + attacker.strength / 10.0
		}

	# Objects use take_damage(damage_dict, success_level) and handle DR internally
	target.take_damage(attack_damage, 0)

	# Calculate total damage for penetration check
	var total_damage = 0.0
	var dr = target.damage_resistances if "damage_resistances" in target else {}
	for dtype in attack_damage:
		total_damage += max(0.0, attack_damage[dtype] - dr.get(dtype, 0))

	var penetration_result = _calculate_penetration(total_damage, attack_velocity, weapon)

	if penetration_result.state == PenetrationState.BOUNCED:
		SfxManager.play("clash", target.global_position)
	else:
		SfxManager.play("impact", target.global_position)

	# Trigger weapon ability on non-bounced hits
	if weapon and penetration_result.state != PenetrationState.BOUNCED:
		if weapon.get("use_ability") and weapon.get("ability"):
			attacker._resolve_ability_effects(weapon.ability, hit_position)

	return {
		"attacker": attacker,
		"target": target,
		"weapon": weapon,
		"raw_damage": attack_damage,
		"penetration_state": penetration_result.state,
		"penetration_depth": penetration_result.depth,
		"actual_damage": total_damage,
	}
	
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_R:
				# Restart
				get_tree().reload_current_scene()
			KEY_P:
				# Print status
				_print_status()
	# Number keys 1-9 to select party members
	if event is InputEventKey and event.pressed and not event.echo:
		var key = event.keycode
		if key >= KEY_1 and key <= KEY_9:
			var index = key - KEY_1  # 0-8
			select_character_by_index(index)
			
func _create_selection_indicator(size:int) -> void:
	"""Create the white circle selection indicator"""
	selection_indicator = Node2D.new()
	selection_indicator.name = "SelectionIndicator"
	selection_indicator.z_index = 100  # Above most things
	
	# We'll draw the circle in a custom draw node
	
	var circle_drawer = SelectionCircle.new()
	circle_drawer.radius = size
	circle_drawer.circle_color = SELECTION_CIRCLE_COLOR
	circle_drawer.line_width = SELECTION_CIRCLE_WIDTH
	selection_indicator.add_child(circle_drawer)
	
	# Add to scene tree (will be repositioned each frame)
	add_child(selection_indicator)
	selection_indicator.visible = false

func _select_initial_character() -> void:
	"""Select the first party character on startup"""
	var party = get_party()
	if party.size() > 0:
		select_character(party[0], 0)
func get_party() -> Array:
	"""Get the party characters array"""
	return party_chars
func select_character_by_index(index: int) -> bool:
	"""Select a party member by their index (0-based)"""
	var party = get_party()
	if index >= 0 and index < party.size():
		var character = party[index]
		if character and is_instance_valid(character):
			select_character(character, index)
			return true
	return false

func select_character(character: ProceduralCharacter, index: int = -1) -> void:
	"""Select a specific character"""
	if selected_character == character:
		return
	
	# Deselect previous
	if selected_character:
		selected_character.AI_enabled = true
		emit_signal("character_deselected", selected_character)
	
	# Select new
	selected_character = character
	selected_index = index if index >= 0 else get_party().find(character)
	selected_character.AI_enabled = false
	emit_signal("character_selected", character, selected_index)
	print("Selected: ", character.Name, " (index ", selected_index, ")")

func select_next() -> void:
	"""Select next party member"""
	var party = get_party()
	if party.size() == 0:
		return
	var next_index = (selected_index + 1) % party.size()
	select_character_by_index(next_index)

func select_previous() -> void:
	"""Select previous party member"""
	var party = get_party()
	if party.size() == 0:
		return
	var prev_index = (selected_index - 1 + party.size()) % party.size()
	select_character_by_index(prev_index)

func get_selected() -> ProceduralCharacter:
	"""Get the currently selected character"""
	return selected_character

# ===== COMBAT CALLBACKS =====

func _on_damage_dealt(attacker: CharacterBody2D, target: CharacterBody2D, info: Dictionary) -> void:
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

func _on_weapon_bounced(attacker: CharacterBody2D, target: CharacterBody2D, limb_type: int) -> void:
	print("Weapon bounced off armor!")

func _on_weapon_clash(char1: CharacterBody2D, char2: CharacterBody2D, winner: CharacterBody2D, power_diff: float) -> void:
	var winner_name = "Player" if winner == player else "Enemy"
	print("Weapon clash! %s wins (power diff: %.1f)" % [winner_name, power_diff])

func _on_weapon_disarmed(character: CharacterBody2D) -> void:
	var name = "Player" if character == player else "Enemy"
	print("%s was DISARMED!" % name)

func _on_character_died(character: ProceduralCharacter) -> void:
	var name = "Player" if character == player else "Enemy"
	print("%s has died!" % name)
	character.current_state = character.AIState.DEAD
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

func spawn_character_by_name(char_name: String, spawn_position: Vector2, faction = null) -> ProceduralCharacter:
	for char_data in characters_database:
		if char_data.get("name", "") == char_name:
			var c = spawn_character(char_data, spawn_position)
			if faction:
				c.set_faction(faction)
			c.display_name = char_name
			return c	
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
	var character_node = CharacterScene.instantiate()
	character_node.global_position = spawn_position
	
	
	#Add ConditionManager:
	var condition_manager = ConditionManager.new()
	condition_manager.name = "ConditionManager"
	character_node.add_child(condition_manager)
	#character_node.add_child(targeting_system)
	# Load character data
	character_node.load_from_data(data)
	container.add_child(character_node)

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

signal damage_dealt(attacker: CharacterBody2D, target: CharacterBody2D, damage_info: Dictionary)
signal weapon_bounced(attacker: CharacterBody2D, target: CharacterBody2D, limb_type: int)
signal weapon_clash(char1: CharacterBody2D, char2: CharacterBody2D, winner: CharacterBody2D, power_diff: float)
signal weapon_knocked_away(character: CharacterBody2D)
signal weapon_disarmed(character: CharacterBody2D)

const CLASH_COOLDOWN: float = 0.3  # Seconds between weapon clashes	

# ===== WEAPON VS BODY COLLISION =====
func process_weapon_hit(
	attacker: ProceduralCharacter,
	target: ProceduralCharacter,
	hit_position: Vector2,
	weapon: Node2D,
	attack_velocity: float
) -> Dictionary:
	# Determine which limb was hit
	var local_hit = target.to_local(hit_position)
	var limb_type = target.get_limb_at_position(
		local_hit,
		target.body_width,
		target.body_height
	)

	# Calculate base damage — DUPLICATE to avoid mutating the weapon's data
	var attack_damage: Dictionary
	if weapon:
		attack_damage = weapon.damage.duplicate()
		if weapon.get("traits") and "melee" in weapon.traits:
			var str_bonus = attacker.strength / 10.0
			for dtype in attack_damage:
				attack_damage[dtype] += str_bonus
	else:
		attack_damage = {
			attacker.unarmed_strike_damage_type:
				attacker.unarmed_strike_damage + attacker.strength / 10.0
		}

	# damage_limb applies limb-specific armor DR internally and returns total dealt
	var final_damage = target.damage_limb(limb_type, attack_damage, local_hit)

	var limb = target.get_limb(limb_type)
	var armor_dr = target.get_limb_armor(limb_type) if limb else {}

	# Penetration uses the post-DR damage
	var penetration_result = _calculate_penetration(final_damage, attack_velocity, weapon)

	# Trigger weapon ability only if we actually penetrated
	if weapon and penetration_result.state != PenetrationState.BOUNCED:
		if weapon.get("use_ability") and weapon.get("ability"):
			attacker._resolve_ability_effects(weapon.ability, hit_position)

	var result = {
		"attacker": attacker,
		"target": target,
		"weapon": weapon,
		"limb_type": limb_type,
		"limb_name": limb.name if limb else "Unknown",
		"raw_damage": attack_damage,
		"armor_dr": armor_dr,
		"penetration_state": penetration_result.state,
		"penetration_depth": penetration_result.depth,
		"velocity_reduction": penetration_result.velocity_reduction,
		"actual_damage": final_damage,
		"blocked": 0
	}

	if penetration_result.state == PenetrationState.BOUNCED:
		result["blocked"] = attack_damage
		SfxManager.play("clash", attacker.position)
		emit_signal("weapon_bounced", attacker, target, limb_type)
	else:
		SfxManager.play("sword-on-flesh", target.position)

	return result

func _calculate_penetration(damage: float, velocity: float, weapon: WeaponShape) -> Dictionary:
	"""Calculate how deeply a weapon penetrates based on damage, armor, and velocity"""
	
	if damage <= 0.0:
		return {
			"state": PenetrationState.BOUNCED,
			"depth": 0.0,
			"velocity_reduction": 1.0  # Full stop
		}
	
	# 3. Apply velocity to the total unresisted damage
	# velocity affects initial penetration power
	var velocity_factor = clamp(velocity / 100.0, 0.5, 2.0)
	var penetration_power = damage * velocity_factor
	
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


		# Visual feedback could be added here (screen shake, etc)
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
		char2.apply_stagger(0.2) #REMOVE? Or make a condtions
		char1.apply_stagger(0.2)
	elif abs(power_diff) < 5.0:
		# Moderate difference - loser knocked back
		winner = char1 if power_diff > 0 else char2
		loser = char2 if power_diff > 0 else char1
		print("weapon clash resulted in knockback")
		result["outcome"] = "knockback"
		result["winner"] = winner
		result["loser"] = loser
		loser.apply_stagger(0.3)
		emit_signal("weapon_clash", char1, char2, winner, abs(power_diff))
	elif abs(power_diff) < 10.0:
		# Large difference - weapon knocked away
		print("weapon clash resulted in weapon being knocked away")
		winner = char1 if power_diff > 0 else char2
		loser = char2 if power_diff > 0 else char1
		result["outcome"] = "knocked_away"
		result["winner"] = winner
		result["loser"] = loser
		loser.knock_weapon_away()
		emit_signal("weapon_knocked_away", loser)
	else:
		# Massive difference - disarm
		winner = char1 if power_diff > 0 else char2
		loser = char2 if power_diff > 0 else char1
		result["outcome"] = "disarm"
		result["winner"] = winner
		result["loser"] = loser
		loser.disarm_character()
		emit_signal("weapon_disarmed", loser)
	
	return result

func _get_clash_key(char1: CharacterBody2D, char2: CharacterBody2D) -> String:
	var id1 = char1.get_instance_id()
	var id2 = char2.get_instance_id()
	if id1 > id2:
		return "%d_%d" % [id2, id1]
	return "%d_%d" % [id1, id2]

# ===== HIT TRACKING =====
func register_attack_start(attacker: Node2D) -> void:
	"""Called when an attack begins - resets hit tracking for this attack"""
	active_hits[attacker.get_instance_id()] = {}

func register_attack_end(attacker: Node2D) -> void:
	"""Called when an attack ends - clears hit tracking"""
	active_hits.erase(attacker.get_instance_id())

func can_hit_target(attacker: Node2D, target: Node2D) -> bool:
	"""Check if this attack can still hit this target (hasn't already)"""
	var attacker_id = attacker.get_instance_id()
	var target_id = target.get_instance_id()

	if not active_hits.has(attacker_id):
		return true

	return not active_hits[attacker_id].has(target_id)

func register_hit(attacker: Node2D, target: Node2D) -> void:
	"""Mark that this attack has hit this target"""
	var attacker_id = attacker.get_instance_id()
	var target_id = target.get_instance_id()

	if not active_hits.has(attacker_id):
		active_hits[attacker_id] = {}

	active_hits[attacker_id][target_id] = true
# ===== COLLISION DETECTION HELPERS =====

func get_body_hitbox_corners(character: ProceduralCharacter) -> Array:
	"""Get character's body hitbox as 4 world-space corners (handles rotation)"""
	var half_width = character.body_width / 2
	
	# The character origin is at the center of the head
	# Head front is at -head_length * 0.35
	# Legs end at shoulder_y_offset + leg_length
	var top = -character.head_length * 0.35
	var bottom = character.shoulder_y_offset + character.leg_length
	
	# Local space corners
	var local_corners = [
		Vector2(-half_width, top),      # top-left
		Vector2(half_width, top),       # top-right
		Vector2(half_width, bottom),    # bottom-right
		Vector2(-half_width, bottom)    # bottom-left
	]
	
	# Transform each corner to world space (applying rotation)
	var world_corners = []
	for corner in local_corners:
		world_corners.append(character.global_position + corner.rotated(character.rotation))
	
	return world_corners

func point_in_polygon(point: Vector2, polygon: Array) -> bool:
	"""Check if a point is inside a convex polygon using cross product method"""
	var n = polygon.size()
	if n < 3:
		return false
	
	for i in range(n):
		var a = polygon[i]
		var b = polygon[(i + 1) % n]
		var cross = (b - a).cross(point - a)
		if cross < 0:
			return false
	return true

func check_weapon_body_collision(holder, target):
	# 1. Determine the start and end points of the "hit line" in the holder's LOCAL space
	var hit_start_local: Vector2
	var hit_end_local: Vector2
	
	# Check if the holder is actually holding a weapon in the active hand
	var current_weapon
	if holder.current_hand == "Main":
		current_weapon = holder.current_main_hand_item
	else:
		current_weapon = holder.current_off_hand_item

	if current_weapon != null and not (current_weapon is AbilityShape):
		# --- WEAPON LOGIC ---
		# Get the weapon's local vectors (relative to the weapon scene)
		var tip = current_weapon.get_tip_local_position()
		var base = current_weapon.get_blade_start_local()
		
		# Convert to holder's local space by adding the weapon's position
		hit_end_local = current_weapon.position + tip
		hit_start_local = current_weapon.position + base
	else:
		# --- UNARMED / FIST LOGIC ---
		# Get the joint array for the active hand
		var joints: Array[Vector2]
		if holder.current_hand == "Main":
			# Assuming Main Hand = Right Arm based on your IK code
			joints = holder.right_arm_joints
		else:
			joints = holder.left_arm_joints
			
		# Safety check in case joints aren't initialized
		if joints.is_empty() or joints.size() < 2:
			return {"hit": false}
			
		# The last joint is the hand/tip
		hit_end_local = joints[-1]
		
		# The second to last joint is the elbow. 
		# We define the "fist" as the last 20% of the forearm.
		# This prevents the whole arm from acting like a blade.
		var elbow_local = joints[-2]
		hit_start_local = hit_end_local.lerp(elbow_local, 0.2)

	# 2. Perform the Interpolation Check (Shared Logic)
	# Use your specific helper function here
	var body_corners = get_body_hitbox_corners(target)
	var num_checks = 5
	
	for i in range(num_checks):
		var t = float(i) / float(num_checks - 1)
		
		# Interpolate in local space first
		var check_point_local = hit_end_local.lerp(hit_start_local, t)
		
		# Convert to global world space using the holder (attacker)
		var check_point_world = holder.to_global(check_point_local)
		
		if point_in_polygon(check_point_world, body_corners):
			# Convert hit position to target's local space for limb detection
			var hit_local = target.to_local(check_point_world)
			
			# Un-rotate to align with the target's limb coordinate system
			var hit_local_unrotated = hit_local.rotated(-target.rotation)
			
			var limb_type = target.get_limb_at_position(
				hit_local_unrotated,
				target.body_width,
				target.body_height
			)
			
			return {
				"hit": true,
				"position": check_point_world,
				"velocity": holder.attack_speed_multiplier, #this might only effect cooldown, not attack speed?
				"limb_type": limb_type
			}
			
	return {"hit": false}
	
func check_weapon_weapon_collision(
	char1: ProceduralCharacter,
	char2: ProceduralCharacter
) -> Dictionary:
	"""Check if two weapons are colliding"""
	var weapon1
	var weapon2
	var holder1
	var holder2
	
	# Both must be attacking
	if not char1.attack_animator or not char1.attack_animator.is_attacking:
		return {"collision": false}
	if not char2.attack_animator or not char2.attack_animator.is_attacking:
		return {"collision": false}
	if char1.current_hand == "Main":
		weapon1 = char1.current_main_hand_item
		holder1 = char1.main_hand_holder
	else: 
		weapon1 = char1.current_off_hand_item
		holder1 = char1.off_hand_holder
		
	if char2.current_hand == "Main":
		weapon2 = char2.current_main_hand_item
		holder2 = char2.main_hand_holder
	else:
		weapon2 = char2.current_off_hand_item
		holder2 = char2.off_hand_holder
	
	# Get blade points for both weapons
	var tip1_local = weapon1.get_tip_local_position()
	var blade_start1_local = weapon1.get_blade_start_local()
	var tip2_local = weapon2.get_tip_local_position()
	var blade_start2_local = weapon2.get_blade_start_local()
	
	# Check multiple points along each blade against each other
	var num_checks = 3
	var collision_radius = 8.0  # How close blades need to be to "clash"
	
	for i in range(num_checks):
		var t1 = float(i) / float(num_checks - 1)
		var point1_local = tip1_local.lerp(blade_start1_local, t1)
		var point1_world = holder1.to_global(weapon1.position + point1_local)
		
		for j in range(num_checks):
			var t2 = float(j) / float(num_checks - 1)
			var point2_local = tip2_local.lerp(blade_start2_local, t2)
			var point2_world = holder2.to_global(weapon2.position + point2_local)
			
			if point1_world.distance_to(point2_world) < collision_radius:
				return {
					"collision": true,
					"position": (point1_world + point2_world) / 2
				}
	
	return {"collision": false}

# ===== SELECTION CIRCLE DRAWER =====

class SelectionCircle extends Node2D:
	var radius: float = 85.0
	var circle_color: Color = Color.WHITE
	var line_width: float = 1.0
	var num_segments: int = 32
	
	func _draw() -> void:
		# Draw circle outline
		var points = PackedVector2Array()
		for i in range(num_segments + 1):
			var angle = (float(i) / num_segments) * TAU
			points.append(Vector2(cos(angle), sin(angle)) * radius)
		
		for i in range(num_segments):
			draw_line(points[i], points[i + 1], circle_color, line_width, true)
		
