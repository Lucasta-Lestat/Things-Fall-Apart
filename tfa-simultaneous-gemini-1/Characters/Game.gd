# Game.gd
# Attach to your main scene or a manager node
extends Node

const ProceduralCharacterScript = preload("res://Characters/ProceduralCharacter.gd")

@onready var fog_manager: FogManager = $FogManager
@onready var map_loader: Node2D = $MapLoader
@onready var player_camera: Camera2D = $PlayerCamera


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
var structures_in_scene: Array = []
var current_map_id: String = "cemetery"
var current_map_data: Dictionary = {}
var warp_zones: Array = []
var context_menu_open: bool = false

var factions: Dictionary
signal character_selected(character: ProceduralCharacter, index: int)
signal character_deselected(character: ProceduralCharacter)
signal map_loaded(map_id: String)

# Currently selected character
var selected_character: ProceduralCharacter = null
var selected_index: int = 0

# Selection indicator
var selection_indicator: Node2D = null
const SELECTION_CIRCLE_COLOR = Color(1, 1, 1, 0.8)  # White
const SELECTION_CIRCLE_WIDTH = 1.0

# ---------------------------------------------------------------------------
# Party state — persists across map transitions and save/load
# ---------------------------------------------------------------------------
# party_state holds the player + allies as an array of dicts.
# Index 0 is always the protagonist. Each entry has:
#   "template_id" : the CharacterDatabase template
#   "overrides"   : any build_character overrides (race, gender, etc.)
#   "live_state"  : runtime snapshot (hp, mp, blood, inventory, conditions)
#                   null on first spawn, populated by save_party_state()
 # ---------------------------------------------------------------------------
# Party state management
# ---------------------------------------------------------------------------
 
var party_state: Array = [
	{"template_id": "protagonist", "overrides": {}, "live_state": null},
	{"template_id": "jacana", "overrides": {}, "live_state": null},
]

func _ready() -> void:
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
	load_map(current_map_id)
 
func save_party_state() -> void:
	## Snapshots every living party member's runtime state so it survives
	## map transitions and can be written to a save file.
	for i in range(party_state.size()):
		if i >= party_chars.size():
			break
		var character = party_chars[i]
		if not is_instance_valid(character):
			continue
		party_state[i]["live_state"] = _serialize_character(character)
 
 
func load_party_state_from_save(saved: Array) -> void:
	## Called when loading a save file. Replaces party_state entirely.
	party_state = saved
 
 
func add_party_member(template_id: String, overrides: Dictionary = {}) -> void:
	party_state.append({
		"template_id": template_id,
		"overrides": overrides,
		"live_state": null,
	})
 
 
func remove_party_member(index: int) -> void:
	if index > 0 and index < party_state.size():  # Can't remove the protagonist
		party_state.remove_at(index)

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
				# NPCs are only visible under player line-of-sight lights
				npc.light_mask = 2
				npc.visibility_layer = 2
				var light_mat = CanvasItemMaterial.new()
				light_mat.light_mode = CanvasItemMaterial.LIGHT_MODE_LIGHT_ONLY
				_apply_material_recursive(npc, light_mat)
 
# ---------------------------------------------------------------------------
# Core character spawn helper
# ---------------------------------------------------------------------------
 
func _spawn_character(template_id: String, pos: Vector2, overrides: Dictionary = {}) -> ProceduralCharacter:
	var character = CharacterScene.instantiate()
 
	# Position first (before body creation reads it)
	character.position = pos
 
	# Build from template — this applies race, background, stats, equipment
	TopDownCharacterDatabase.build_character(character, template_id, overrides)
 
	# Connect signals
	character.character_died.connect(_on_character_died.bind(character))
 
	# Add to scene tree and track
	add_child(character)
	characters_in_scene.append(character)
 
	return character
 



	
func load_map(map_id: String, from_map: String = "") -> void:
	# Save party state before cleaning up (preserves HP, inventory, etc.)
	if not party_chars.is_empty():
		save_party_state()
 
	# Clean up previous map
	_unload_current_map()
 
	# Load map data from the maps JSON
	current_map_data = MapDatabase.get_map_data(map_id)
	if current_map_data.is_empty():
		push_error("Unknown map: " + map_id)
		return
	current_map_id = map_id
 
	# 1. Tell the MapLoader to build the visual map (floors, structures)
	var images: Dictionary = current_map_data.get("images", {})
	map_loader.map_image_path = images.get("map", "")
	map_loader.mask_image_path = images.get("mask", "")
	map_loader.structure_map_image_path = images.get("structures", "")
	map_loader.structure_mask_path = images.get("structures_mask", "")
	map_loader.tile_size = current_map_data.get("tile_size", 64)
	map_loader.generate_map()
 
	# 2. Set up ambient effects (fog, music)
	setup_map_fogs(current_map_data)
	setup_map_music(current_map_data)
 
	# 3. Determine which spawn key to use based on where we came from
	var spawn_key: String = "default"
	if not from_map.is_empty():
		var from_key = "from_" + from_map
		if current_map_data.get("player_spawns", {}).has(from_key):
			spawn_key = from_key
 
	# 4. Spawn the player and party
	_spawn_player_and_party(spawn_key)
 
	# 5. Spawn NPCs
	_spawn_npcs(current_map_data.get("npc_spawns", []))
 
	# 6. Spawn items
	_spawn_items(current_map_data.get("item_spawns", []))
 
	# 7. Create warp zones
	_create_warp_zones(current_map_data.get("warp_points", []))
 
	# 8. Select the player
	call_deferred("_select_initial_character")
 
	emit_signal("map_loaded", map_id)
	print("[GameScene] Loaded map: %s (spawn: %s)" % [map_id, spawn_key])

func _unload_current_map() -> void:
	# Remove all spawned characters
	for character in characters_in_scene:
		if is_instance_valid(character):
			character.queue_free()
	characters_in_scene.clear()
	party_chars.clear()
	player = null
 
	# Remove warp zones
	for zone in warp_zones:
		if is_instance_valid(zone):
			zone.queue_free()
	warp_zones.clear()
 
	# Clear the MapLoader's children (floors, structures)
	for child in map_loader.get_children():
		child.queue_free()
 
	current_map_id = ""
	current_map_data = {}

# ---------------------------------------------------------------------------
# Ambient setup (fog + music)
# ---------------------------------------------------------------------------

func setup_map_fogs(map_data: Dictionary) -> void:
	if not fog_manager:
		return
	fog_manager.clear_all_fog()
	for fog_id in map_data.get("fog_ids", []):
		fog_manager.create_fog_from_id(fog_id)

func setup_map_music(map_data: Dictionary) -> void:
	var track: String = map_data.get("music_track", "")
	if not track.is_empty():
		MusicManager.play(track)
	else:
		MusicManager.stop()

# ---------------------------------------------------------------------------
# Party spawning
# ---------------------------------------------------------------------------

func _spawn_player_and_party(spawn_key: String) -> void:
	var spawns: Dictionary = current_map_data.get("player_spawns", {})
	var spawn_data = spawns.get(spawn_key, spawns.get("default", {}))
	var base_pos_arr = spawn_data.get("position", [400, 400])
	var base_pos = Vector2(base_pos_arr[0], base_pos_arr[1])

	for i in range(party_state.size()):
		var entry = party_state[i]
		var offset = Vector2(i * 40, 0)
		var character = _spawn_character(entry["template_id"], base_pos + offset, entry.get("overrides", {}))
		if not character:
			continue

		party_chars.append(character)
		character.AI_enabled = false

		# Restore live state if we have one (from map transition / save load)
		if entry.get("live_state"):
			_deserialize_character(character, entry["live_state"])

		# First party member is the player
		if i == 0:
			player = character
			character.is_protagonist = true

		# Add line-of-sight light
		_add_line_of_sight_light(character)

# ---------------------------------------------------------------------------
# Item spawning
# ---------------------------------------------------------------------------

func _spawn_items(item_list: Array) -> void:
	for item_def in item_list:
		if item_def.has("condition") and not _check_condition(item_def["condition"]):
			continue

		var item_id: String = item_def.get("id", "")
		var pos_arr = item_def.get("position", [0, 0])
		var pos = Vector2(pos_arr[0], pos_arr[1])
		var count: int = item_def.get("count", 1)

		for j in range(count):
			create_item(item_id, pos)

# ---------------------------------------------------------------------------
# Context menu
# ---------------------------------------------------------------------------

func show_context_menu(target, position: Vector2) -> void:
	var context_menu = preload("res://UI/ContextMenu.tscn").instantiate()
	context_menu.global_position = position + Vector2(16, 16)
	context_menu.z_index = 100
	context_menu_open = true

	var options: Array = []
	if target is ProceduralCharacter:
		options = target.get("interact_options") if "interact_options" in target else ["Inspect"]
	elif target is Area2D and target.has_meta("target_map"):
		options = ["Enter " + target.get_meta("label", "area")]

	context_menu.setup(target, options)
	get_tree().root.add_child(context_menu)

# ---------------------------------------------------------------------------
# Lighting helpers
# ---------------------------------------------------------------------------

func _add_line_of_sight_light(character: ProceduralCharacter) -> void:
	var light = PointLight2D.new()
	light.texture = Globals.SIGHT_TEXTURE
	light.energy = 0.3
	var master_radius = 512.0
	var desired_radius = 1440.0 * character.sight
	light.texture_scale = desired_radius / master_radius
	light.name = "LineOfSight"
	light.rotation_degrees = 90
	light.shadow_enabled = true
	light.shadow_item_cull_mask = 1
	light.z_index = 102
	character.add_child(light)

func _apply_material_recursive(node: Node, material: Material) -> void:
	if node is Sprite2D or node is TextureRect:
		node.material = material
	for child in node.get_children():
		_apply_material_recursive(child, material)

func create_item(item_id: String, world_position: Vector2, stack_count: int = 1) -> Item:
	"""Create any item (weapon, equipment, or general item) by its ID and place it in the world."""
	var item_instance = item_scene.instantiate() as Item
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

func _on_item_destroyed(item: Item):
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

	#register to grid
	#make sure loader uses
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
		_update_projectiles(delta)
	# Tick fog effects
		if $FogManager:
			$FogManager.update_fogs(delta, characters_in_scene)
	if selected_character and is_instance_valid(selected_character) and selection_indicator:
		selection_indicator.global_position = selected_character.global_position
		if PauseManager.is_paused:
			selection_indicator.visible = true
	if selection_indicator and not PauseManager.is_paused:
		selection_indicator.visible = false
	# Camera follows selected character
	if selected_character and is_instance_valid(selected_character) and player_camera:
		player_camera.global_position = player_camera.global_position.lerp(
			selected_character.global_position, 5.0 * delta)

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

		# Ranged weapons use the projectile system — skip melee collision entirely
		if weapon is WeaponShape and weapon.weapon_type in [WeaponShape.WeaponType.BOW, WeaponShape.WeaponType.PISTOL]:
			continue

		# Check against other characters
		#print("how many characters? ", all_characters)
		for victim in all_characters:
			if attacker == victim:
				continue
			if not victim.is_alive():
				continue
			if not can_hit_target(attacker, victim):
				continue

			var hit = check_weapon_body_collision(attacker, victim)
			print("is the weaapon hitting? ", hit)
			if hit.get("hit", false):
				register_hit(attacker, victim)
				
				process_weapon_hit(attacker, victim, hit["position"], weapon, hit["velocity"])

		# Check against items
		for item in items_in_scene:
			if not is_instance_valid(item):
				continue
			if not can_hit_target(attacker, item):
				continue

			var hit = check_weapon_object_collision(attacker, item)
			if hit.get("hit", false):
				process_object_hit(attacker, item, hit["position"], weapon, hit["velocity"])

		# Check against structures
		for structure in structures_in_scene:
			if not is_instance_valid(structure):
				continue
			if not can_hit_target(attacker, structure):
				continue

			var hit = check_weapon_object_collision(attacker, structure)
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

# Live projectiles spawned by ranged weapons
var active_projectiles: Array = []

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
	print("processing weapon hit
	
	")
	# Calculate base damage — DUPLICATE to avoid mutating the weapon's data
	var attack_damage: Dictionary
	if weapon:
		attack_damage = weapon.damage.duplicate()
		print("attack_damage: ", attack_damage)
		if weapon.get("traits") and "melee" in weapon.traits:
			var str_bonus = attacker.strength / 10.0
			# Get all damage type keys (e.g., ["physical", "fire"])
			var damage_types = attack_damage.keys()
			# Apply to the first one available, provided the dictionary isn't empty
			if damage_types.size() > 0:
				var first_type = damage_types[0]
				attack_damage[first_type] += str_bonus
	else:
		attack_damage = {
			attacker.unarmed_strike_damage_type:
				attacker.unarmed_strike_damage + attacker.strength / 10.0
		}

	# damage_limb applies limb-specific armor DR internally and returns total dealt
	var final_damage = target.damage_limb(limb_type, attack_damage, local_hit)
	print("final damage: ", final_damage)
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

func check_weapon_body_collision(holder, target: ProceduralCharacter):
	# 1. Determine the start and end points of the "hit line" in the holder's LOCAL space
	var hit_start_local: Vector2
	var hit_end_local: Vector2
	
	# Check if the holder is actually holding a weapon in the active hand
	var current_weapon
	if holder.current_hand == "Main":
		current_weapon = holder.current_main_hand_item
	else:
		current_weapon = holder.current_off_hand_item
	#print("current weapon: ", current_weapon.display_name)
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
	# DEBUG — add these lines temporarily
	var tip_world = holder.to_global(hit_end_local)
	var base_world = holder.to_global(hit_start_local)
	print("weapon line: ", tip_world, " -> ", base_world)
	print("target corners: ", body_corners)
	print("target pos: ", target.global_position, " rot: ", target.rotation)
	
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
	
func check_weapon_object_collision(holder: ProceduralCharacter, target: Node2D) -> Dictionary:
	"""Collision check for items and structures using their collision shape bounds"""
	var hit_start_local: Vector2
	var hit_end_local: Vector2

	var current_weapon
	if holder.current_hand == "Main":
		current_weapon = holder.current_main_hand_item
	else:
		current_weapon = holder.current_off_hand_item

	if current_weapon != null and not (current_weapon is AbilityShape):
		var tip = current_weapon.get_tip_local_position()
		var base = current_weapon.get_blade_start_local()
		hit_end_local = current_weapon.position + tip
		hit_start_local = current_weapon.position + base
	else:
		var joints: Array[Vector2]
		if holder.current_hand == "Main":
			joints = holder.right_arm_joints
		else:
			joints = holder.left_arm_joints
		if joints.is_empty() or joints.size() < 2:
			return {"hit": false}
		hit_end_local = joints[-1]
		var elbow_local = joints[-2]
		hit_start_local = hit_end_local.lerp(elbow_local, 0.2)

	# Use the target's sprite size as a simple bounding box
	var target_rect: Rect2
	if "sprite" in target and target.sprite and target.sprite.texture:
		var tex_size = target.sprite.texture.get_size() * target.sprite.scale
		var half = tex_size / 2.0
		target_rect = Rect2(target.global_position - half, tex_size)
	elif "size" in target:
		var half = target.size / 2.0
		target_rect = Rect2(target.global_position - half, target.size)
	else:
		return {"hit": false}

	var num_checks = 5
	for i in range(num_checks):
		var t = float(i) / float(num_checks - 1)
		var check_point_local = hit_end_local.lerp(hit_start_local, t)
		var check_point_world = holder.to_global(check_point_local)

		if target_rect.has_point(check_point_world):
			return {
				"hit": true,
				"position": check_point_world,
				"velocity": holder.attack_speed_multiplier
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

# ===== PROJECTILE SYSTEM =====

func spawn_projectile(shooter: ProceduralCharacter, direction: Vector2, weapon: WeaponShape) -> Node2D:
	"""Create a projectile node and register it for per-frame collision tracking."""
	var proj = Node2D.new()
	proj.name = "Projectile"
	proj.z_index = 3

	var sprite = Sprite2D.new()
	if weapon.projectile_texture_path != "" and ResourceLoader.exists(weapon.projectile_texture_path):
		sprite.texture = load(weapon.projectile_texture_path)
	else:
		# Fallback: draw a small rectangle so something is visible
		var img = Image.create(4, 12, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		sprite.texture = ImageTexture.create_from_image(img)
	proj.add_child(sprite)

	# Spawn slightly ahead of the shooter so it doesn't immediately collide with them
	proj.global_position = shooter.global_position + direction.normalized() * 20.0
	# Rotate so the sprite's up-axis points along the travel direction
	proj.rotation = direction.angle() + PI / 2.0

	var is_pistol = weapon.weapon_type == WeaponShape.WeaponType.PISTOL
	var speed = 600.0 if is_pistol else 380.0
	var max_range = 700.0 if is_pistol else 900.0

	get_tree().current_scene.add_child(proj)

	active_projectiles.append({
		"node": proj,
		"shooter": shooter,
		"direction": direction.normalized(),
		"weapon": weapon,
		"speed": speed,
		"max_range": max_range,
		"distance_traveled": 0.0,
	})
	return proj

func _update_projectiles(delta: float) -> void:
	var to_remove: Array = []

	for proj_data in active_projectiles:
		var proj: Node2D = proj_data["node"]
		if not is_instance_valid(proj):
			to_remove.append(proj_data)
			continue

		var move_vec: Vector2 = proj_data["direction"] * proj_data["speed"] * delta
		proj.global_position += move_vec
		proj_data["distance_traveled"] += move_vec.length()

		if proj_data["distance_traveled"] >= proj_data["max_range"]:
			# Drop thrown items at landing position
			if proj_data.get("thrown_item_data"):
				var item_id = proj_data["thrown_item_data"].get("id", "")
				if not item_id.is_empty():
					create_item(item_id, proj.global_position)
			proj.queue_free()
			to_remove.append(proj_data)
			continue

		var hit := false

		# --- Character collision ---
		for target in characters_in_scene:
			if not is_instance_valid(target) or not target.is_alive():
				continue
			if target == proj_data["shooter"]:
				continue
			var body_corners = get_body_hitbox_corners(target)
			if point_in_polygon(proj.global_position, body_corners):
				if proj_data["weapon"]:
					_process_projectile_hit_character(proj_data["shooter"], target, proj.global_position, proj_data["weapon"])
				elif proj_data.get("thrown_item_data"):
					# Thrown item hit
					var dmg = proj_data.get("thrown_damage", {"bludgeoning": 2})
					var local_hit = target.to_local(proj.global_position)
					var limb_type = target.get_limb_at_position(local_hit, target.body_width, target.body_height)
					target.damage_limb(limb_type, dmg.duplicate(), local_hit)
					# Drop the item at hit location
					var item_id = proj_data["thrown_item_data"].get("id", "")
					if not item_id.is_empty():
						create_item(item_id, proj.global_position)
				proj.queue_free()
				to_remove.append(proj_data)
				hit = true
				break

		if hit:
			continue

		# --- Structure collision ---
		for structure in structures_in_scene:
			if not is_instance_valid(structure):
				continue
			var target_rect: Rect2
			if "sprite" in structure and structure.sprite and structure.sprite.texture:
				var tex_size = structure.sprite.texture.get_size() * structure.sprite.scale
				target_rect = Rect2(structure.global_position - tex_size / 2.0, tex_size)
			elif "size" in structure:
				target_rect = Rect2(structure.global_position - structure.size / 2.0, structure.size)
			else:
				continue
			if target_rect.has_point(proj.global_position):
				if proj_data["weapon"]:
					_process_projectile_hit_object(proj_data["shooter"], structure, proj.global_position, proj_data["weapon"])
				elif proj_data.get("thrown_item_data"):
					var dmg = proj_data.get("thrown_damage", {"bludgeoning": 2})
					if structure.has_method("take_damage"):
						structure.take_damage(dmg.duplicate(), 0)
					var item_id = proj_data["thrown_item_data"].get("id", "")
					if not item_id.is_empty():
						create_item(item_id, proj.global_position)
				proj.queue_free()
				to_remove.append(proj_data)
				hit = true
				break

	for proj_data in to_remove:
		active_projectiles.erase(proj_data)

func _process_projectile_hit_character(
	shooter: ProceduralCharacter,
	target: ProceduralCharacter,
	hit_position: Vector2,
	weapon: WeaponShape
) -> void:
	var local_hit = target.to_local(hit_position)
	var limb_type = target.get_limb_at_position(local_hit, target.body_width, target.body_height)
	var attack_damage = weapon.damage.duplicate()
	target.damage_limb(limb_type, attack_damage, local_hit)

	if weapon.weapon_type == WeaponShape.WeaponType.PISTOL:
		SfxManager.play("sword-on-flesh", hit_position)
	else:
		SfxManager.play("arrow-body-impact", hit_position)

func _process_projectile_hit_object(
	_shooter: ProceduralCharacter,
	target: Node2D,
	hit_position: Vector2,
	weapon: WeaponShape
) -> void:
	if target.has_method("take_damage"):
		target.take_damage(weapon.damage.duplicate(), 0)

	if weapon.weapon_type == WeaponShape.WeaponType.PISTOL:
		SfxManager.play("armor-impact", hit_position)
	else:
		SfxManager.play("arrow-wall-impact", hit_position)

# ===== THROWN ITEM PROJECTILES =====

func _add_thrown_projectile(proj_data: Dictionary) -> void:
	# Create a simple visual for the thrown item
	var proj = Sprite2D.new()
	var item_data = proj_data.get("item_data", {})
	var item_id = item_data.get("id", "")

	# Try to load a sprite for the item
	var sprite_path = item_data.get("sprite_path", "")
	if sprite_path.is_empty():
		var item_db_data = _lookup_any_item(item_id)
		sprite_path = item_db_data.get("sprite_path", "")
	if not sprite_path.is_empty() and ResourceLoader.exists(sprite_path):
		proj.texture = load(sprite_path)
	else:
		# Fallback: small colored square
		var img = Image.create(12, 12, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.7, 0.5, 0.3))
		proj.texture = ImageTexture.create_from_image(img)

	proj.global_position = proj_data["position"]
	proj.rotation = proj_data["velocity"].angle() + PI / 2.0
	proj.z_index = 50
	get_tree().current_scene.add_child(proj)

	active_projectiles.append({
		"node": proj,
		"shooter": proj_data["shooter"],
		"direction": proj_data["velocity"].normalized(),
		"speed": proj_data["velocity"].length(),
		"max_range": proj_data.get("max_range", 400.0),
		"distance_traveled": 0.0,
		"weapon": null,
		"thrown_item_data": item_data,
		"thrown_damage": proj_data.get("damage", {"bludgeoning": 2}),
	})

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
			
			
func _create_warp_zones(warp_list: Array) -> void:
	for warp_def in warp_list:
		# Check warp conditions (e.g. need a key)
		if warp_def.has("condition") and not _check_condition(warp_def["condition"]):
			continue
 
		var pos_arr = warp_def.get("position", [0, 0])
		var size_arr = warp_def.get("size", [30, 30])
		var pos = Vector2(pos_arr[0], pos_arr[1])
		var size = Vector2(size_arr[0], size_arr[1])
 
		# Create an Area2D with a collision shape
		var area = Area2D.new()
		area.name = "Warp_" + warp_def.get("id", "unknown")
		area.position = pos
		area.set_meta("target_map", warp_def.get("target_map", ""))
		area.set_meta("target_spawn", warp_def.get("target_spawn", "default"))
		area.set_meta("label", warp_def.get("label", ""))
 
		var shape = CollisionShape2D.new()
		var rect_shape = RectangleShape2D.new()
		rect_shape.size = size
		shape.shape = rect_shape
		area.add_child(shape)
 
		# Set collision to detect the player for proximity checks
		area.collision_layer = 0
		area.collision_mask = 1  # Assumes player is on layer 1
		# Warp zones are interacted with via right-click context menu,
		# not by walking into them. The input manager detects clicks on
		# Area2Ds and calls show_context_menu().
		area.input_pickable = true
		area.input_event.connect(_on_warp_input.bind(area))
 
		add_child(area)
		warp_zones.append(area)
 
func _on_warp_input(viewport: Node, event: InputEvent, shape_idx: int, area: Area2D) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		show_context_menu(area, event.global_position)
		
func _check_condition(condition_key: String, condition_value = true):
	if Globals.world_state.has(condition_key):
		if Globals.world_state.condition_key == condition_value:
			return true
		else:
			return false
	else:
		push_error("Missing world_state condition: ",condition_key)
# ---------------------------------------------------------------------------
# Character state serialization (for party persistence)
# ---------------------------------------------------------------------------
 
func _serialize_character(character: ProceduralCharacter) -> Dictionary:
	## Captures all mutable runtime state that can diverge from the template.
	var state: Dictionary = {}
 
	# --- Identity ---
	state["Name"] = character.Name
	state["display_name"] = character.display_name
	state["faction_id"] = character.faction_id
	state["race_id"] = character.race_id
	state["creature_size"] = character.creature_size
	state["racial_features"] = character.racial_features.duplicate()
	state["traits"] = character.traits.duplicate()
	state["is_protagonist"] = character.is_protagonist
	state["AI_enabled"] = character.AI_enabled
 
	# --- Core attributes ---
	state["strength"] = character.strength
	state["constitution"] = character.constitution
	state["dexterity"] = character.dexterity
	state["will"] = character.will
	state["intelligence"] = character.intelligence
	state["charisma"] = character.charisma
 
	# --- Attribute modifiers (permanent buffs/debuffs applied outside conditions) ---
	state["strength_modifier"] = character.strength_modifier
	state["constitution_modifier"] = character.constitution_modifier
	state["dexterity_modifier"] = character.dexterity_modifier
	state["will_modifier"] = character.will_modifier
	state["intelligence_modifier"] = character.intelligence_modifier
	state["charisma_modifier"] = character.charisma_modifier
	state["sight_modifier"] = character.sight_modifier
	state["hearing_modifier"] = character.hearing_modifier
	state["fov_modifier"] = character.fov_modifier
	state["mp_regen_modifier"] = character.mp_regen_modifier
	state["crit_threshold_modifier"] = character.crit_threshold_modifier
	state["crit_fail_modifier"] = character.crit_fail_modifier
	state["speed_modifier"] = character.speed_modifier
 
	# --- Vitals ---
	state["blood_amount"] = character.blood_amount
	state["MP"] = character.MP
 
	# --- Appearance ---
	state["skin_color"] = character.skin_color.to_html()
	state["hair_color"] = character.hair_color.to_html()
	state["hair_style"] = character.hair_style  # enum int
	state["body_size_mod"] = character.body_size_mod
 
	# --- Body dimensions ---
	state["body_width"] = character.body_width
	state["body_height"] = character.body_height
	state["head_width"] = character.head_width
	state["head_length"] = character.head_length
	state["shoulder_y_offset"] = character.shoulder_y_offset
 
	# --- Combat stats ---
	state["unarmed_strike_damage"] = character.unarmed_strike_damage
	state["unarmed_strike_damage_type"] = character.unarmed_strike_damage_type
	state["CRIT_THRESHOLD"] = character.CRIT_THRESHOLD
	state["CRIT_FAIL_THRESHOLD"] = character.CRIT_FAIL_THRESHOLD
	state["bonus_damage"] = character.bonus_damage
	state["bonus_damage_against_trait"] = character.bonus_damage_against_trait.duplicate()
	state["restricted_actions_by_trait"] = character.restricted_actions_by_trait.duplicate()
	state["MODIFY_DURATION_BY_TRAIT"] = character.MODIFY_DURATION_BY_TRAIT.duplicate()
	state["targeting_confusion"] = character.targeting_confusion
 
	# --- Sensory ---
	state["sight"] = character.sight
	state["hearing"] = character.hearing
	state["fov_angle_degrees"] = character.fov_angle_degrees
 
	# --- MP regen ---
	state["mp_regen_amount"] = character.mp_regen_amount
	state["mp_regen_interval"] = character.mp_regen_interval
 
	# --- Dialogue ---
	state["dialogue_id"] = character.get("dialogue_id") if "dialogue_id" in character else ""
 
	# --- Severed limbs / wound state ---
	state["severed_limbs"] = character.severed_limbs.duplicate()
 
	# --- Inventory contents ---
	if character.inventory:
		state["inventory_items"] = []
		for item in character.inventory.items:
			if item is Dictionary:
				state["inventory_items"].append(item.duplicate())
 
	# --- Equipped weapons ---
	# Save weapon data so we can reconstruct them on load.
	# We serialize each equipped weapon's exportable data + which hand it's in.
	if character.inventory:
		state["equipped_weapons"] = []
		for weapon in character.inventory.equipped_weapons:
			var weapon_entry: Dictionary = {}
			# Determine hand
			weapon_entry["hand"] = character.inventory.weapon_hands.get(weapon, "Main")
 
			if weapon is WeaponShape and weapon.has_method("to_data"):
				weapon_entry["type"] = "weapon"
				weapon_entry["data"] = weapon.to_data()
			elif weapon is AbilityShape:
				weapon_entry["type"] = "ability"
				weapon_entry["data"] = {"ability_id": weapon.ability_id if "ability_id" in weapon else ""}
			else:
				# Generic fallback — store whatever we can
				weapon_entry["type"] = "unknown"
				weapon_entry["data"] = {}
			state["equipped_weapons"].append(weapon_entry)
 
		state["active_weapon_index"] = character.inventory.active_weapon_index
 
	# --- Active conditions ---
	if character.condition_manager:
		state["active_conditions"] = []
		for cond_id in character.condition_manager.conditions:
			var instance = character.condition_manager.conditions[cond_id]
			state["active_conditions"].append({
				"id": cond_id,
				"stacks": instance.stacks,
				"expires_at": instance.expires_at if instance.get("expires_at") != null else -1.0,
			})
 
	# --- Cooldowns (ability cooldowns with remaining time) ---
	if character.cooldowns.size() > 0:
		state["cooldowns"] = character.cooldowns.duplicate()
 
	return state
 
 
func _deserialize_character(character: ProceduralCharacter, state: Dictionary) -> void:
	## Restores a character's runtime state from a previously saved snapshot.
	## Called AFTER build_character / load_from_data so the template is already applied.
	if state.is_empty():
		return
 
	# --- Identity ---
	if state.has("Name"):
		character.Name = state["Name"]
	if state.has("display_name"):
		character.display_name = state["display_name"]
	if state.has("faction_id"):
		character.faction_id = state["faction_id"]
	if state.has("race_id"):
		character.race_id = state["race_id"]
	if state.has("creature_size"):
		character.creature_size = state["creature_size"]
	if state.has("racial_features"):
		character.racial_features = state["racial_features"]
	if state.has("traits"):
		character.traits = state["traits"]
	if state.has("is_protagonist"):
		character.is_protagonist = state["is_protagonist"]
	if state.has("AI_enabled"):
		character.AI_enabled = state["AI_enabled"]
 
	# --- Core attributes ---
	if state.has("strength"):    character.strength = state["strength"]
	if state.has("constitution"): character.constitution = state["constitution"]
	if state.has("dexterity"):   character.dexterity = state["dexterity"]
	if state.has("will"):        character.will = state["will"]
	if state.has("intelligence"): character.intelligence = state["intelligence"]
	if state.has("charisma"):    character.charisma = state["charisma"]
 
	# --- Attribute modifiers ---
	if state.has("strength_modifier"):     character.strength_modifier = state["strength_modifier"]
	if state.has("constitution_modifier"): character.constitution_modifier = state["constitution_modifier"]
	if state.has("dexterity_modifier"):    character.dexterity_modifier = state["dexterity_modifier"]
	if state.has("will_modifier"):         character.will_modifier = state["will_modifier"]
	if state.has("intelligence_modifier"): character.intelligence_modifier = state["intelligence_modifier"]
	if state.has("charisma_modifier"):     character.charisma_modifier = state["charisma_modifier"]
	if state.has("sight_modifier"):        character.sight_modifier = state["sight_modifier"]
	if state.has("hearing_modifier"):      character.hearing_modifier = state["hearing_modifier"]
	if state.has("fov_modifier"):          character.fov_modifier = state["fov_modifier"]
	if state.has("mp_regen_modifier"):     character.mp_regen_modifier = state["mp_regen_modifier"]
	if state.has("crit_threshold_modifier"): character.crit_threshold_modifier = state["crit_threshold_modifier"]
	if state.has("crit_fail_modifier"):    character.crit_fail_modifier = state["crit_fail_modifier"]
	if state.has("speed_modifier"):        character.speed_modifier = state["speed_modifier"]
 
	# --- Vitals ---
	if state.has("blood_amount"): character.blood_amount = state["blood_amount"]
	if state.has("MP"):           character.MP = state["MP"]
 
	# --- Appearance ---
	if state.has("skin_color"):
		character.skin_color = Color.html(state["skin_color"])
		character.body_color = character.skin_color.darkened(0.15)
	if state.has("hair_color"):
		character.hair_color = Color.html(state["hair_color"])
	if state.has("hair_style"):
		character.hair_style = state["hair_style"] as ProceduralCharacter.HairStyle
	if state.has("body_size_mod"):
		character.body_size_mod = state["body_size_mod"]
 
	# --- Body dimensions ---
	if state.has("body_width"):        character.body_width = state["body_width"]
	if state.has("body_height"):       character.body_height = state["body_height"]
	if state.has("head_width"):        character.head_width = state["head_width"]
	if state.has("head_length"):       character.head_length = state["head_length"]
	if state.has("shoulder_y_offset"): character.shoulder_y_offset = state["shoulder_y_offset"]
 
	# --- Combat stats ---
	if state.has("unarmed_strike_damage"):
		character.unarmed_strike_damage = state["unarmed_strike_damage"]
	if state.has("unarmed_strike_damage_type"):
		character.unarmed_strike_damage_type = state["unarmed_strike_damage_type"]
	if state.has("CRIT_THRESHOLD"):
		character.CRIT_THRESHOLD = state["CRIT_THRESHOLD"]
	if state.has("CRIT_FAIL_THRESHOLD"):
		character.CRIT_FAIL_THRESHOLD = state["CRIT_FAIL_THRESHOLD"]
	if state.has("bonus_damage"):
		character.bonus_damage = state["bonus_damage"]
	if state.has("bonus_damage_against_trait"):
		character.bonus_damage_against_trait = state["bonus_damage_against_trait"]
	if state.has("restricted_actions_by_trait"):
		character.restricted_actions_by_trait = state["restricted_actions_by_trait"]
	if state.has("MODIFY_DURATION_BY_TRAIT"):
		character.MODIFY_DURATION_BY_TRAIT = state["MODIFY_DURATION_BY_TRAIT"]
	if state.has("targeting_confusion"):
		character.targeting_confusion = state["targeting_confusion"]
 
	# --- Sensory ---
	if state.has("sight"):            character.sight = state["sight"]
	if state.has("hearing"):          character.hearing = state["hearing"]
	if state.has("fov_angle_degrees"): character.fov_angle_degrees = state["fov_angle_degrees"]
 
	# --- MP regen ---
	if state.has("mp_regen_amount"):   character.mp_regen_amount = state["mp_regen_amount"]
	if state.has("mp_regen_interval"): character.mp_regen_interval = state["mp_regen_interval"]
 
	# --- Dialogue ---
	if state.has("dialogue_id") and "dialogue_id" in character:
		character.dialogue_id = state["dialogue_id"]
 
	# --- Severed limbs ---
	if state.has("severed_limbs"):
		character.severed_limbs = state["severed_limbs"]
 
	# --- Inventory: clear template items, restore saved ones ---
	if character.inventory and state.has("inventory_items"):
		character.inventory.items.clear()
		for item_data in state["inventory_items"]:
			character.inventory.add_item(item_data)
 
	# --- Equipped weapons: reconstruct and equip ---
	if character.inventory and state.has("equipped_weapons"):
		# Clear any template-granted equipment first
		while character.inventory.equipped_weapons.size() > 0:
			var removed = character.inventory.unequip_weapon(0)
			if removed and removed is Node:
				removed.queue_free()
 
		for weapon_entry in state["equipped_weapons"]:
			var hand: String = weapon_entry.get("hand", "Main")
			var wtype: String = weapon_entry.get("type", "unknown")
			var data: Dictionary = weapon_entry.get("data", {})
 
			match wtype:
				"weapon":
					if not data.is_empty():
						character.inventory.equip_weapon_from_data(data, hand)
				"ability":
					var ability_id = data.get("ability_id", "")
					if ability_id != "":
						character.inventory.equip_ability_from_id(ability_id, hand)
 
		# Restore active weapon selection
		if state.has("active_weapon_index"):
			var idx = state["active_weapon_index"]
			if idx >= -1 and idx < character.inventory.equipped_weapons.size():
				character.inventory.set_active_weapon(idx)
 
	# --- Conditions: reapply saved conditions ---
	if character.condition_manager and state.has("active_conditions"):
		for cond_entry in state["active_conditions"]:
			var cond_id: String = cond_entry.get("id", "")
			var stacks: int = cond_entry.get("stacks", 1)
			var expires: float = cond_entry.get("expires_at", -1.0)
			if cond_id != "":
				character.condition_manager.apply_condition(cond_id, null, stacks, expires)
 
	# --- Cooldowns ---
	if state.has("cooldowns"):
		character.cooldowns = state["cooldowns"]
 
	# Refresh visuals after all state is restored
	if character.has_method("_update_colors"):
		character._update_colors()
