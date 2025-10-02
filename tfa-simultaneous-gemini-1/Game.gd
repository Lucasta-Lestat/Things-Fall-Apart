# res://Game.gd
extends Node2D

@onready var characters_container: Node2D = $CharactersContainer
# NEW: A container for our structure objects
@onready var structures_container: Node2D = $StructuresContainer
@onready var floors_container: Node2D = $FloorsContainer
@onready var player_camera: Camera2D = $PlayerCamera
@onready var game_ui: GameUI = $GameUI
# UPDATED: We now just need the ground layer for coordinate conversion
@onready var ground_layer: TileMapLayer = $GridContainer/GroundLayer
@onready var highlights_layer: TileMapLayer = $GridContainer/HighlightsLayer # Add this line

const CharacterScene = preload("res://Characters/Character.tscn")
const StructureScene = preload("res://Structures/Structure.tscn")
const FloorScene = preload("res://Structures/Floors/floor.tscn")

var player_input_manager: PlayerInputManager
var combat_manager: CombatManager

var is_active_combat = false
var party_ids = ["Protagonist", "Jacana"]
var characters_in_scene = []
var rotations = generate_random_array(1,4,100, 12345)
var color_offsets = generate_random_float_array(1.0, 1.0, 100, 48273)

func _ready():
	# UPDATED: Initialize the GridManager with the ground layer
	GridManager.initialize(ground_layer, highlights_layer)
	setup_managers()
	setup_input_actions()
	
	# NEW: Spawn structures before characters
	load_map("perrow","Route 1")
		
	# Setup Input Map Actions if not already done (for testing)
	setup_input_actions()
	
	combat_manager.combat_started.connect(_on_combat_started)
	combat_manager.combat_ended.connect(_on_combat_ended)
	# Collect all characters from container to start combat

	#if not all_spawned_chars.is_empty() and combat_manager:
	#	combat_manager.start_combat(all_spawned_chars)
	#else:
	#	printerr("No characters spawned or found to start combat, or CombatManager not found.")
func _on_combat_started():
	is_active_combat = true
func _on_combat_ended():
	is_active_combat = false
	
func load_map(map_id: StringName, coming_from: String):
	#print("Map definitions: ", MapDatabase.map_definitions)
	GridManager.active_map = map_id
	var Map = MapDatabase.map_definitions[map_id]
	for spawn_point in Map.pc_spawn_points:
		print("spawn point: ", )
		if coming_from == spawn_point.coming_from:
			#create_character_from_database("Protagonist", Vector2i(spawn_point.party_member_1.x, spawn_point.party_member_1.y))
			var offset = 1
			for character_id in party_ids:
				#claude: add safety check for this square already being occupied
				var c = create_character_from_database(character_id, Vector2i(spawn_point.party_member_1.x+offset, spawn_point.party_member_1.y))
				print("attempting to spawn: ", character_id, " at: ", Vector2i(spawn_point.party_member_1.x+offset, spawn_point.party_member_1.y))
				characters_container.add_child(c)
				offset += 1
	print("spawned party successfully #map-loading")
	var x = 0
	var y = 0
	var end_x = Map.size_x 
	var end_y = Map.size_y 
	while x < end_x:
		y = 0
		while y < end_y:
			var rotation_index = int(x*y)
			var rotation_amount = rotations[rotation_index%100]
			var color_change = color_offsets[rotation_index%100]
			if not x % 15 and not y % 15:
				print("x,y locations of floor: ", Vector2i(x,y))
			create_floor(Map.base_floor_type,Vector2i(x,y), rotation_amount, color_change)
			y += 1
		x += 1
	print("spawned base floor successfully")
	#print("attempting to spawn regions: ", Map.regions)
	for region in Map.regions:
		x = region.x
		y = region.y
		end_x = x + region.size_x 
		end_y = y + region.size_y 
		 
		if region.floor_type:
			while x < end_x:
				y = region.y
				while y < end_y:
					var rotation_index = int(x*y)
					var rotation_amount = rotations[rotation_index%100]
					#print("rotation: ",rotation)
					var color_change = color_offsets[rotation_index%100]
					#print("color change: ", color_change)
					create_floor(region.floor_type,Vector2i(x,y), rotation_amount,color_change)
					y += 1
				x += 1
		print("spawned first region's floor")
		if "wall_type" in region.keys():
			# Top and bottom walls
			var y_top = region.y
			var y_bottom = end_y - 1
			x = region.x
			while x < end_x:
				var door = check_for_door(region, Vector2i(x, y_top))
				if door:
					create_structure(door.type, Vector2i(x, y_top))      # Top wall
				else: 
					create_structure(region.wall_type, Vector2i(x, y_top))      # Top wall
					print("spawning wall: ",region.wall_type)
				door = check_for_door(region, Vector2i(x, y_bottom))
				if door:
					create_structure(door.type, Vector2i(x, y_bottom))  
				else:
					create_structure(region.wall_type, Vector2i(x, y_bottom))   # Bottom wall
					print("spawning wall: ",region.wall_type)
				x += 1
			# Left and right walls
			var x_left = region.x 
			var x_right = region.x + region.size_x
			y = region.y
			while y < end_y:
				var door = check_for_door(region, Vector2i(x_left, y))
				if door:
					create_structure(door.type, Vector2i(x_left, y))
				else: 
					create_structure(region.wall_type, Vector2i(x_left, y))     # Left wall
					print("spawning wall: ",region.wall_type)

				door = check_for_door(region, Vector2i(x_right, y))
				if door:
					create_structure(door.type, Vector2i(x_right, y))
				else:
					create_structure(region.wall_type, Vector2i(x_right, y))    # Right wall
					#print("spawning wall: ",region.wall_type)
				y += 1
		print("spawned walls and doors")
		if "structures" in region.keys():	
			for structure in region.structures:
				print("attempting to spawn")
				create_structure(structure.id, Vector2i(structure.x,structure.y))
		#print("#spawning: ",region.keys())
		if "characters" in region.keys():	
			for character in region.characters:
				print("Attempting to spawn: ", character.id, " at ", Vector2i(character.x,character.y))
				create_character_from_database(character.id, Vector2i(character.x,character.y))
			
func check_for_door(region, pos: Vector2i):
	if region.has("doors"):
					for door in region.doors:
						var door_pos = Vector2i(door.x , door.y)
						if door_pos == pos:
							return door
	return false
func add_characters_to_combat():
	for character in characters_in_scene:
		if character:
			character.combat_manager = combat_manager
			characters_container.add_child(character)

func generate_random_array(min_val: int, max_val: int, size: int, seed_value: int) -> Array:
	var rng = RandomNumberGenerator.new()
	rng.seed = seed_value  # Set the seed for deterministic results

	var result = []
	for i in range(size):
		result.append(90*rng.randi_range(min_val, max_val))
	return result

func generate_random_float_array(min_val: float, max_val: float, size: int, seed_value: int):
	var rng = RandomNumberGenerator.new()
	rng.seed = seed_value  # Set the seed for deterministic results

	var result = []
	for i in range(size):
		result.append(rng.randf_range(min_val, max_val))
	return result
func setup_managers():
	print("DEBUG: Setting up managers")
	
	# Create and setup CombatManager
	combat_manager = CombatManager.new()
	add_child(combat_manager)
	print("DEBUG: CombatManager created and added")
	
	# Create and setup PlayerInputManager
	player_input_manager = PlayerInputManager.new()
	add_child(player_input_manager)
	print("DEBUG: PlayerInputManager created and added")
	
	# Wait a frame to ensure both managers are fully ready
	await get_tree().process_frame
	
	# Connect managers to each other
	player_input_manager.combat_manager = combat_manager
	player_input_manager.setup_combat_manager_connections()
	print("DEBUG: Managers connected to each other")
	
	# Connect camera to PlayerInputManager signals
	player_input_manager.selection_changed.connect(_on_player_selection_changed_for_camera)
	player_input_manager.camera_recenter_request.connect(_on_camera_recenter_request)
	print("DEBUG: Camera signals connected")
	
	# NEW: Setup GameUI
	game_ui.setup(combat_manager, player_input_manager)
	print("DEBUG: GameUI setup")
	# Set combat_manager reference in characters (will be done when characters are spawned)

func setup_input_actions():
	if not InputMap.has_action("ui_accept"): 
		InputMap.add_action("ui_accept")
		var accept_event = InputEventKey.new()
		accept_event.keycode = KEY_SPACE
		InputMap.action_add_event("ui_accept", accept_event)
	if not InputMap.has_action("ui_cancel"): 
		InputMap.add_action("ui_cancel")
		var cancel_event = InputEventKey.new()
		cancel_event.keycode = KEY_ESCAPE
		InputMap.action_add_event("ui_cancel", cancel_event)

func create_character_from_database(character_id: String, position: Vector2) -> CombatCharacter:
	var character = CharacterScene.instantiate() as CombatCharacter
	if not character:
		print("Error: Failed to instantiate character scene")
		return null
	
	# Set character ID - this will automatically apply all character data
	character.character_id = character_id
	character.global_position =  GridManager.map_to_world(position)
	characters_in_scene.append(character)
	characters_container.add_child(character)
	#add as a child of characters container
	return character
# --- NEW: Spawning and Managing Structures ---
	
	
func create_floor(floor_id: StringName, grid_pos: Vector2i, rotation_amount, color_change):
	var floor = FloorScene.instantiate() as Floor
	if floor_id != "floor_grass":
		floor.get_node("Sprite").rotation_degrees = rotation_amount
	floor.get_node("Sprite").modulate = Color(color_change,color_change,color_change)
	
	
	
	floor.global_position = GridManager.map_to_world(grid_pos)
	# The floor tells the GridManager how walkable it is
	GridManager.register_floor(grid_pos, floor)
	var base_pos = GridManager.map_to_world(grid_pos)
	
	
	# 5. Tiny scale variation
	
	# Connect to its destroyed signal to update pathfinding
	floor.destroyed.connect(_on_floor_destroyed)
	floor.floor_id = floor_id
	floors_container.add_child(floor)
	if floor_id == "dirt_floor":
		#floor.get_node("Sprite").scale = Vector2.ONE * randf_range(.99, 1.01)
		#var offset = Vector2(randf_range(-1.5, 1.5), randf_range(-1.0, 1.0))
		#floor.global_position = base_pos + offset
		pass

func create_structure(structure_id: StringName, grid_pos: Vector2i):
	var structure = StructureScene.instantiate() as Structure
	structure.structure_id = structure_id
	structure.global_position = GridManager.map_to_world(grid_pos)
	
	# The structure tells the GridManager it's an obstacle
	GridManager.register_obstacle(grid_pos)
	
	# Connect to its destroyed signal to update pathfinding
	structure.destroyed.connect(_on_structure_destroyed)
	
	structures_container.add_child(structure)

func _on_structure_destroyed(structure: Structure, grid_position: Vector2i):
	# When a structure is destroyed, it tells the GridManager its tile is now open
	GridManager.unregister_obstacle(grid_position)
	
func _on_floor_destroyed(floor: Floor, grid_position: Vector2i):
	# When a structure is destroyed, it tells the GridManager its tile is now open
	GridManager.unregister_floor(grid_position)
	#claude: find floor at that grid_position now that this one is gone and reregister it.
	
# Alternative method if you want to override specific properties
func create_custom_character(character_id: String, position: Vector2, overrides: Dictionary = {}) -> CombatCharacter:
	var character = create_character_from_database(character_id, position)
	if not character:
		return null
	
	# Apply any custom overrides
	for property in overrides.keys():
		if character.get(property) != null:
			character.set(property, overrides[property])
		else:
			print("Warning: Property '", property, "' not found on character")
	
	return character

func _on_player_selection_changed_for_camera(selected_chars: Array[CombatCharacter]):
	print("DEBUG: Camera selection changed. Selected chars count: ", selected_chars.size())
	for character in characters_container.get_children():
		character._update_selection_visual()
	if not selected_chars.is_empty() and player_input_manager and is_instance_valid(player_input_manager.primary_selected_character):
		print("DEBUG: Following primary selected character: ", player_input_manager.primary_selected_character.character_name)
		_set_camera_target(player_input_manager.primary_selected_character)
	elif not selected_chars.is_empty() and is_instance_valid(selected_chars[0]):
		print("DEBUG: Following first selected character: ", selected_chars[0].character_name)
		_set_camera_target(selected_chars[0])
	else:
		print("DEBUG: Clearing camera target")
		_clear_camera_target()

func _on_camera_recenter_request(target_pos: Vector2):
	print("DEBUG: Camera recenter requested to position: ", target_pos)
	
	if player_input_manager and is_instance_valid(player_input_manager.primary_selected_character):
		print("DEBUG: Recentering on primary character: ", player_input_manager.primary_selected_character.character_name)
		_set_camera_target(player_input_manager.primary_selected_character)
	else:
		print("DEBUG: Moving camera to specific position: ", target_pos)
		if not _is_following_node:
			var tween = create_tween()
			tween.tween_property(player_camera, "global_position", target_pos, 0.3)


var _camera_follow_target: Node2D = null
var _is_following_node: bool = false

func _set_camera_target(node: Node2D):
	print("DEBUG: Setting camera target to: ", node.name if node else "null")
	_camera_follow_target = node
	_is_following_node = true

func _clear_camera_target():
	print("DEBUG: Clearing camera target")
	_camera_follow_target = null
	_is_following_node = false

func _process(delta): # For camera following
	if _is_following_node and is_instance_valid(_camera_follow_target):
		# Smooth camera following
		var target_pos = _camera_follow_target.global_position
		player_camera.global_position = player_camera.global_position.lerp(target_pos, 5.0 * delta)
	elif _is_following_node: # Target became invalid
		_clear_camera_target()
