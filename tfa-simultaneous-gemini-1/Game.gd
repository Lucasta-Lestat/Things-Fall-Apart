# res://Game.gd
extends Node2D

@onready var characters_container: Node2D = $CharactersContainer
@onready var player_camera: Camera2D = $PlayerCamera

const CharacterScene = preload("res://Characters/Character.tscn")

# Create manager instances (instead of just declaring variables)
var player_input_manager: PlayerInputManager
var combat_manager: CombatManager

func _ready():
	# Initialize managers
	setup_managers()
	
	# Setup Input Map Actions if not already done (for testing)
	setup_input_actions()
	
	spawn_characters()
	
	# Collect all characters from container to start combat
	var all_spawned_chars: Array[CombatCharacter] = []
	for child in characters_container.get_children():
		if child is CombatCharacter:
			all_spawned_chars.append(child)
			# Set navigation map for each character if TileMap and NavRegion exist
			var nav_region = get_node_or_null("TileMap/NavigationRegion2D")
			if nav_region and child.nav_agent:
				child.nav_agent.set_navigation_map(nav_region.get_navigation_map())

	if not all_spawned_chars.is_empty() and combat_manager:
		combat_manager.start_combat(all_spawned_chars)
	else:
		printerr("No characters spawned or found to start combat, or CombatManager not found.")

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

func spawn_characters():
	# Create characters using the database system
	var p1 = create_character_from_database("hero_alpha", Vector2(150, 300))
	var p2 = create_character_from_database("hero_beta", Vector2(200, 350))
	var e1 = create_character_from_database("goblin_scout", Vector2(500, 300))
	var e2 = create_character_from_database("orc_brute", Vector2(550, 380))
	
	# Add all characters to the scene
	for character in [p1, p2, e1, e2]:
		if character:
			# Set combat_manager reference
			character.combat_manager = combat_manager
			characters_container.add_child(character)

func create_character_from_database(character_id: String, position: Vector2) -> CombatCharacter:
	var character = CharacterScene.instantiate() as CombatCharacter
	if not character:
		print("Error: Failed to instantiate character scene")
		return null
	
	# Set character ID - this will automatically apply all character data
	character.character_id = character_id
	character.global_position = position
	
	return character

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
