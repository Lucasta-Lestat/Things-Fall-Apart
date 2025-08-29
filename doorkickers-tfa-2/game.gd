# GameScene.gd - Complete integration of all systems

extends Node2D
class_name GameScene

"====="
@export var map_size: Vector2i = Vector2i(100, 100)
@export var tile_size: int = 32

var player_controller: PlayerController
var characters: Array[Character] = []
var terrain_tilemap: TileMap
var visibility_overlay: ColorRect
var cloud_system: CloudSystem
var fog_renderer: FogOfWarRenderer
var sound_visualizer: SoundVisualizer

func _ready():
	setup_scene()
	create_test_environment()
	setup_enhanced_systems()
	connect_system_signals()
	
	game_state_changed.connect(_on_game_state_changed)

func setup_scene():
	# Create terrain tilemap
	terrain_tilemap = TileMap.new()
	add_child(terrain_tilemap)
	
	# Create player controller
	player_controller = PlayerController.new()
	add_child(player_controller)
	player_controller.character_selected.connect(_on_character_selected)
	
	# Create visibility overlay
	visibility_overlay = ColorRect.new()
	add_child(visibility_overlay)
	visibility_overlay.color = Color(0, 0, 0, 0.7)  # Dark overlay
	visibility_overlay.z_index = 50
	visibility_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	# Set up terrain
	initialize_terrain()

func initialize_terrain():
	# Generate basic terrain
	for x in range(map_size.x):
		for y in range(map_size.y):
			var pos = Vector2i(x, y)
			
			# Simple terrain generation
			var noise_value = sin(x * 0.1) * cos(y * 0.1)
			
			if noise_value > 0.3:
				TerrainManager.set_terrain_at(pos, "grass")
			elif noise_value < -0.3:
				TerrainManager.set_terrain_at(pos, "stone_floor")
			else:
				TerrainManager.set_terrain_at(pos, "dirt")

func create_test_environment():
	# Create a test character
	# Create enhanced test character
	var enhanced_character = create_enhanced_test_character()
	
	# Set up sound visualization for player character
	sound_visualizer.set_listening_character(enhanced_character)
	
	# Create some test clouds
	create_test_weather_effects()
	
	# Add characters to appropriate groups
	for character in characters:
		if character.is_player_controlled:
			character.add_to_group("player_characters")
		character.add_to_group("characters")
	
	# Create some test objects
	create_test_wall(Vector2(300, 200))
	create_test_weapon(Vector2(500, 300))
	create_test_resources()
	# Set up sound visualization for player character
	sound_visualizer.set_listening_character(enhanced_character)
	
	# Create some test clouds
	create_test_weather_effects()
	
	# Add characters to appropriate groups
	for character in characters:
		if character.is_player_controlled:
			character.add_to_group("player_characters")
		character.add_to_group("characters")

func create_test_wall(position: Vector2):
	var wall = ConstructibleObject.new()
	wall.object_name = "Wooden Wall"
	wall.max_hp = 150.0
	wall.resources_required = {"wood": 20}
	wall.global_position = position
	
	# Add collision shape
	var shape = RectangleShape2D.new()
	shape.size = Vector2(32, 64)
	var collision = CollisionShape2D.new()
	collision.shape = shape
	wall.add_child(collision)
	
	# Add visual
	var sprite = ColorRect.new()
	sprite.size = Vector2(32, 64)
	sprite.color = Color.SADDLE_BROWN
	sprite.position = Vector2(-16, -32)
	wall.add_child(sprite)
	
	add_child(wall)

func create_test_weapon(position: Vector2):
	var weapon = Weapon.new()
	weapon.weapon_name = "Iron Sword"
	weapon.base_damage = 30.0
	weapon.damage_type = PhysicsManager.DamageType.SLASHING
	weapon.global_position = position
	
	# Add collision shape
	var shape = RectangleShape2D.new()
	shape.size = Vector2(8, 48)
	var collision = CollisionShape2D.new()
	collision.shape = shape
	weapon.add_child(collision)
	
	# Add visual
	var sprite = ColorRect.new()
	sprite.size = Vector2(8, 48)
	sprite.color = Color.SILVER
	sprite.position = Vector2(-4, -24)
	weapon.add_child(sprite)
	
	add_child(weapon)

func create_test_resources():
	# Scatter some resources around
	for i in range(10):
		var resource = ResourcePickup.new()
		resource.resource_type = "wood"
		resource.amount = randf_range(1, 5)
		resource.global_position = Vector2(
			randf_range(100, 700),
			randf_range(100, 500)
		)
		add_child(resource)

func _on_character_selected(character: Character):
	print("Selected character: " + character.character_name)

func _on_game_state_changed(new_state: GameManager.GameState):
	match new_state:
		GameManager.GameState.PLAYING:
			process_mode = Node.PROCESS_MODE_INHERIT
		GameManager.GameState.PAUSED:
			process_mode = Node.PROCESS_MODE_WHEN_PAUSED
func setup_enhanced_systems():
	# Add cloud system
	cloud_system = CloudSystem.new()
	cloud_system.name = "CloudSystem"
	add_child(cloud_system)
	
	# Add fog of war renderer
	fog_renderer = FogOfWarRenderer.new()
	fog_renderer.name = "FogOfWarRenderer"
	fog_renderer.map_size = map_size
	fog_renderer.tile_size = tile_size
	add_child(fog_renderer)
	
	# Add sound visualizer
	sound_visualizer = SoundVisualizer.new()
	sound_visualizer.name = "SoundVisualizer"
	add_child(sound_visualizer)
	
	# Set up physics objects group for wind effects
	for child in get_children():
		if child is RigidBody2D:
			child.add_to_group("physics_objects")
			
func connect_system_signals():
	# Connect weather to cloud system
	WeatherManager.weather_changed.connect(_on_weather_changed)
	WeatherManager.wind_changed.connect(_on_wind_changed)
	
	# Connect hearing system to character actions
	HearingManager.sound_detected.connect(_on_sound_detected)
	
	# Connect fog of war updates
	FogOfWarManager.visibility_updated.connect(_on_visibility_updated)
	
func create_enhanced_test_character() -> EnhancedCharacter:
	var character = EnhancedCharacter.new()
	character.character_name = "Enhanced Hero"
	character.is_player_controlled = true
	character.global_position = Vector2(400, 300)
	
	# Set up procedural appearance
	character.procedural_renderer.skin_color = Color(0.9, 0.7, 0.6)
	character.procedural_renderer.hair_color = Color(0.6, 0.3, 0.1)
	character.procedural_renderer.clothing_color = Color(0.2, 0.4, 0.8)
	
	add_child(character)
	characters.append(character)
	
	# Equip a test weapon
	var sword = WeaponFactory.create_sword("Hero's Blade")
	sword.global_position = character.global_position + Vector2(20, 0)
	add_child(sword)
	character.equip_weapon(sword)
	
	# Connect movement sounds
	character.procedural_renderer.connect("movement_changed", _on_character_movement_changed.bind(character))
	
	return character

func create_test_weather_effects():
	# Create some initial weather
	WeatherManager.set_weather(WeatherManager.WeatherType.CLEAR)
	
	# Add a test cloud
	cloud_system.create_cloud(Vector2(300, 200), 80.0, 0.7)
	
	# Create a small wind zone
	WeatherManager.create_wind_zone(Vector2(500, 300), 150.0, Vector2(30, 10), 30.0)

func _on_weather_changed(weather_type: WeatherManager.WeatherType):
	print("Weather changed to: ", WeatherManager.WeatherType.keys()[weather_type])

func _on_wind_changed(wind_vector: Vector2):
	# Wind affects all physics objects
	cloud_system.queue_redraw()  # Update cloud rendering

func _on_sound_detected(listener: EnhancedCharacter, detected_sounds: Array):
	if listener.is_player_controlled:
		# Show sound indicators for player character
		print("Character heard ", detected_sounds.size(), " sounds")

func _on_visibility_updated(visible_tiles: Dictionary, partially_visible_tiles: Dictionary):
	# Update character visibility based on fog of war
	update_character_visibility(visible_tiles, partially_visible_tiles)

func update_character_visibility(visible_tiles: Dictionary, partially_visible_tiles: Dictionary):
	# Hide/show characters based on visibility
	var all_characters = get_tree().get_nodes_in_group("characters")
	
	for character in all_characters:
		var char_tile_pos = Vector2i(character.global_position / tile_size)
		
		if char_tile_pos in visible_tiles:
			# Fully visible
			character.modulate = Color.WHITE
			character.show()
		elif char_tile_pos in partially_visible_tiles:
			# Partially visible - show dimmed
			var visibility = partially_visible_tiles[char_tile_pos]
			character.modulate = Color(1, 1, 1, visibility)
			character.show()
		else:
			# Not visible to any player character
			if not character.is_player_controlled:
				character.hide()

"--------------------------------"


	






func _on_character_movement_changed(character: EnhancedCharacter):
	# Create footstep sounds when character moves
	if character.is_walking and character.is_conscious:
		var current_time = GameManager.game_time
		var last_step_time = character.get_meta("last_footstep_time", 0.0)
		var step_interval = 0.6  # Seconds between footsteps
		
		if current_time - last_step_time >= step_interval:
			HearingManager.create_footstep_sound(character)
			character.set_meta("last_footstep_time", current_time)

# Override input handling to add fog of war interactions
func _input(event):
	super._input(event)
	
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_F:  # Toggle fog of war (debug)
				fog_renderer.visible = !fog_renderer.visible
			KEY_W:  # Change weather (debug)
				var current = WeatherManager.current_weather
				var next = (current + 1) % WeatherManager.WeatherType.size()
				WeatherManager.set_weather(next)
			KEY_C:  # Create cloud at mouse position (debug)
				var mouse_pos = get_global_mouse_position()
				cloud_system.create_cloud(mouse_pos, 60.0, 0.8)
				
