# res://Game.gd
extends Node2D

@onready var characters_container: Node2D = $CharactersContainer
@onready var player_camera: Camera2D = $PlayerCamera

const CharacterScene = preload("res://Characters/Character.tscn")

# Add references to manager instances
var player_input_manager: PlayerInputManager
var combat_manager: CombatManager

func _ready():
	# Get references to manager instances
	#player_input_manager = get_node("/root/Globals/PlayerInputManager") # Adjust path as needed
	#combat_manager = get_node("/root/Globals/CombatManager") # Adjust path as needed
	# Or if they are autoload singletons: 
	# player_input_manager = PlayerInputManager
	# combat_manager = CombatManager

	# Connect camera to PlayerInputManager signals
	if player_input_manager:
		player_input_manager.selection_changed.connect(_on_player_selection_changed_for_camera)
		player_input_manager.camera_recenter_request.connect(_on_camera_recenter_request)

	# Setup Input Map Actions if not already done (for testing)
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

	spawn_characters()
	
	# Collect all characters from container to start combat
	var all_spawned_chars: Array[CombatCharacter] = []
	for child in characters_container.get_children():
		if child is CombatCharacter:
			all_spawned_chars.append(child)
			# Set navigation map for each character if TileMap and NavRegion exist
			var nav_region = get_node_or_null("TileMap/NavigationRegion2D") # Adjust path if your TileMap is elsewhere
			if nav_region and child.nav_agent:
				child.nav_agent.set_navigation_map(nav_region.get_navigation_map())

	if not all_spawned_chars.is_empty() and combat_manager:
		combat_manager.start_combat(all_spawned_chars)
	else:
		printerr("No characters spawned or found to start combat, or CombatManager not found.")


func spawn_characters():
	var p1 = CharacterScene.instantiate() as CombatCharacter
	p1.character_name = "Hero Alpha"
	p1.allegiance = CombatCharacter.Allegiance.PLAYER
	p1.global_position = Vector2(150, 300)
	p1.dexterity = 12
	p1.max_ap_per_round = 4
	p1.abilities.assign([
	load("res://Abilities/Move.tres") as Ability,
	load("res://Abilities/BasicAttack.tres") as Ability, 
	load("res://Abilities/HeavyStrike.tres") as Ability
])
	#p1.abilities = [load("res://Abilities/Move.tres"), load("res://Abilities/BasicAttack.tres"), load("res://Abilities/HeavyStrike.tres")]
	#p1.move_ability_res = load("res://Abilities/Move.tres")
	characters_container.add_child(p1)

	var p2 = CharacterScene.instantiate() as CombatCharacter
	p2.character_name = "Hero Beta"
	p2.allegiance = CombatCharacter.Allegiance.PLAYER
	p2.global_position = Vector2(200, 350)
	p2.dexterity = 9
	p2.max_ap_per_round = 4
	p2.abilities.assign([
	load("res://Abilities/Move.tres") as Ability,
	load("res://Abilities/BasicAttack.tres") as Ability, 
	load("res://Abilities/HeavyStrike.tres") as Ability
])
	characters_container.add_child(p2)

	var e1 = CharacterScene.instantiate() as CombatCharacter
	e1.character_name = "Goblin Scout"
	e1.allegiance = CombatCharacter.Allegiance.ENEMY
	e1.global_position = Vector2(500, 300)
	e1.dexterity = 10
	e1.max_ap_per_round = 3
	e1.abilities.assign([
	load("res://Abilities/Move.tres") as Ability,
	load("res://Abilities/BasicAttack.tres") as Ability, 
	load("res://Abilities/HeavyStrike.tres") as Ability
])
	#e1.sprite = load("res://orc.png")

	characters_container.add_child(e1)
	
	var e2 = CharacterScene.instantiate() as CombatCharacter
	e2.character_name = "Orc Brute"
	e2.allegiance = CombatCharacter.Allegiance.ENEMY
	e2.global_position = Vector2(550, 380)
	e2.dexterity = 7
	e2.max_ap_per_round = 3
	e2.abilities.assign([
	load("res://Abilities/Move.tres") as Ability,
	load("res://Abilities/BasicAttack.tres") as Ability, 
	load("res://Abilities/HeavyStrike.tres") as Ability
])
	# Now safely set the sprite texture
	if e2.sprite and is_instance_valid(e2.sprite):
		e2.sprite.texture = load("res://orc.png")
	else:
		print("Warning: Could not set sprite texture for ", e2.character_name)
	characters_container.add_child(e2)


func _on_player_selection_changed_for_camera(selected_chars: Array[CombatCharacter]):
	if not selected_chars.is_empty() and player_input_manager and is_instance_valid(player_input_manager.primary_selected_character):
		# Camera follows primary selected character
		_set_camera_target(player_input_manager.primary_selected_character)
	elif not selected_chars.is_empty() and is_instance_valid(selected_chars[0]): # Fallback to first if no primary
		_set_camera_target(selected_chars[0])
	else:
		_clear_camera_target()


func _on_camera_recenter_request(target_pos: Vector2):
	# If a character is explicitly selected, follow them. Otherwise, lerp to position.
	if player_input_manager and is_instance_valid(player_input_manager.primary_selected_character):
		_set_camera_target(player_input_manager.primary_selected_character)
	else: # Just move camera to position (e.g. if nothing selected, center on party average)
		# This part could be more complex, for now, it just sets target_position
		if not _is_following_node: # Only if not already following a node
			player_camera.position = player_camera.position.lerp(target_pos, 0.1) # Smooth move
			# For an immediate jump: player_camera.global_position = target_pos

var _camera_follow_target: Node2D = null
var _is_following_node: bool = false

func _set_camera_target(node: Node2D):
	_camera_follow_target = node
	_is_following_node = true
	player_camera.set_process(true) # Ensure camera _process runs for following

func _clear_camera_target():
	_camera_follow_target = null
	_is_following_node = false
	player_camera.set_process(false) # Stop camera _process if not following

func _process(delta): # For camera following
	if _is_following_node and is_instance_valid(_camera_follow_target):
		player_camera.global_position = _camera_follow_target.global_position
	elif _is_following_node: # Target became invalid
		_clear_camera_target()
