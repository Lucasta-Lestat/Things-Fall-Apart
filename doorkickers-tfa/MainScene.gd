# MainScene.gd
extends Node2D

# Scene structure example for setting up the tactical CRPG

#@onready var game_manager: GameManager = $GameManager
@onready var vision_system: VisionSystem = $VisionSystem
@onready var pathfinding_system: PathfindingSystem = $PathfindingSystem
@onready var camera: Camera2D = $Camera2D

var test_player_character: EnhancedCharacterController
var test_enemy_character: EnhancedCharacterController

func _ready():
	_setup_camera()
	_setup_systems()
	_create_test_level()
	_spawn_test_characters()
	_setup_ui()

func _setup_camera():
	camera.zoom = Vector2(1, 1)
	camera.position = Vector2(500, 300)
	camera.enabled = true

func _setup_systems():
	# Vision system already set up
	vision_system.map_width = 50
	vision_system.map_height = 50
	
	# Pathfinding with terrain
	pathfinding_system.map_width = 50
	pathfinding_system.map_height = 50
	
	# Set up some varied terrain
	for x in range(10, 20):
		for y in range(10, 20):
			pathfinding_system.set_terrain(Vector2i(x, y), PathfindingSystem.TerrainType.WOOD_FLOOR)
	
	for x in range(25, 35):
		for y in range(15, 25):
			pathfinding_system.set_terrain(Vector2i(x, y), PathfindingSystem.TerrainType.METAL_FLOOR)

func _create_test_level():
	# Create some walls
	_create_wall(Vector2(200, 200), Vector2(50, 200))
	_create_wall(Vector2(400, 100), Vector2(200, 50))
	_create_wall(Vector2(600, 300), Vector2(50, 300))
	
	# Create some cover objects
	_create_cover(Vector2(350, 250), Vector2(100, 20))
	_create_cover(Vector2(450, 350), Vector2(20, 100))

func _create_wall(pos: Vector2, size: Vector2):
	var wall = StaticBody2D.new()
	wall.position = pos
	
	var shape = RectangleShape2D.new()
	shape.size = size
	
	var collision = CollisionShape2D.new()
	collision.shape = shape
	wall.add_child(collision)
	
	var visual = ColorRect.new()
	visual.size = size
	visual.position = -size / 2
	visual.color = Color(0.3, 0.3, 0.3)
	wall.add_child(visual)
	
	wall.collision_layer = 0b0001  # Wall layer
	add_child(wall)

func _create_cover(pos: Vector2, size: Vector2):
	var cover = StaticBody2D.new()
	cover.position = pos
	
	var shape = RectangleShape2D.new()
	shape.size = size
	
	var collision = CollisionShape2D.new()
	collision.shape = shape
	cover.add_child(collision)
	
	var visual = ColorRect.new()
	visual.size = size
	visual.position = -size / 2
	visual.color = Color(0.5, 0.4, 0.3)
	cover.add_child(visual)
	
	cover.collision_layer = 0b0010  # Cover layer
	add_child(cover)

func _spawn_test_characters():
	# Spawn player character
	test_player_character = _create_character(Vector2(100, 300), true)
	test_player_character.name = "PlayerCharacter"
	
	# Customize appearance
	test_player_character.skin_tone = Color(0.9, 0.75, 0.6)
	test_player_character.hair_color = Color(0.3, 0.2, 0.1)
	test_player_character.clothing_primary = Color(0.2, 0.3, 0.2)  # Military green
	test_player_character.body_build = 1.1
	
	# Give player a weapon
	var sword = _create_sword()
	test_player_character.equip_weapon(sword)
	
	# Spawn enemy
	test_enemy_character = _create_character(Vector2(700, 300), false)
	test_enemy_character.name = "EnemyCharacter"
	
	# Enemy appearance
	test_enemy_character.skin_tone = Color(0.85, 0.7, 0.55)
	test_enemy_character.hair_color = Color(0.8, 0.7, 0.2)  # Blonde
	test_enemy_character.clothing_primary = Color(0.5, 0.1, 0.1)  # Red
	test_enemy_character.body_build = 1.2
	
	# Give enemy a bow
	var bow = _create_bow()
	test_enemy_character.equip_weapon(bow)

func _create_character(pos: Vector2, is_player: bool) -> EnhancedCharacterController:
	var character_scene = preload("res://EnhancedCharacterController.tscn")
	var character = character_scene.instantiate()
	character.global_position = pos
	character.is_player_controlled = is_player
	
	if is_player:
		character.add_to_group("player_characters")
		#game_manager.player_characters.append(character)
	else:
		character.add_to_group("enemy_characters")
		#game_manager.enemy_characters.append(character)
	
	add_child(character)
	return character

func _create_sword() -> InventoryItem:
	var sword_item = InventoryItem.new()
	sword_item.name = "Iron Sword"
	sword_item.weight = 2.0
	sword_item.item_type = "weapon"
	sword_item.equipment_slot = "weapon"
	
	var sword_weapon = Weapon.new()
	sword_weapon.name = "Iron Sword"
	sword_weapon.damage_base = 15.0
	sword_weapon.damage_type = "slashing"
	sword_weapon.attack_range = 60.0
	sword_weapon.is_ranged = false
	sword_weapon.arc_attack = true
	sword_weapon.arc_angle = 90.0
	
	sword_item.equipment_resource = sword_weapon
	return sword_item

func _create_bow() -> InventoryItem:
	var bow_item = InventoryItem.new()
	bow_item.name = "Hunting Bow"
	bow_item.weight = 1.5
	bow_item.item_type = "weapon"
	bow_item.equipment_slot = "weapon"
	
	var bow_weapon = Weapon.new()
	bow_weapon.name = "Hunting Bow"
	bow_weapon.damage_base = 12.0
	bow_weapon.damage_type = "piercing"
	bow_weapon.attack_range = 300.0
	bow_weapon.is_ranged = true
	bow_weapon.uses_ammo = true
	bow_weapon.max_ammo = 20
	bow_weapon.current_ammo = 20
	
	bow_item.equipment_resource = bow_weapon
	return bow_item

func _setup_ui():
	# Create HUD
	var hud = CanvasLayer.new()
	add_child(hud)
	
	# Health bars for characters
	_create_health_bar(hud, test_player_character, Vector2(50, 50))
	_create_health_bar(hud, test_enemy_character, Vector2(50, 100))
	
	# Controls hint
	var controls_label = Label.new()
	controls_label.text = "Controls:\n" + \
		"Left Click - Select/Move\n" + \
		"Shift + Drag - Draw Path\n" + \
		"Right Click - Action Menu\n" + \
		"WASD - Camera\n" + \
		"Mouse Wheel - Zoom"
	controls_label.position = Vector2(20, 500)
	hud.add_child(controls_label)

func _create_health_bar(parent: Node, character: EnhancedCharacterController, pos: Vector2):
	var container = VBoxContainer.new()
	container.position = pos
	parent.add_child(container)
	
	var name_label = Label.new()
	name_label.text = character.name
	container.add_child(name_label)
	
	var health_bar = ProgressBar.new()
	health_bar.custom_minimum_size = Vector2(200, 20)
	health_bar.max_value = 100
	health_bar.value = character.stats.blood
	health_bar.show_percentage = true
	container.add_child(health_bar)
	
	# Update health bar each frame
	character.body_part_damaged.connect(func(_part, _damage):
		health_bar.value = character.stats.blood
	)

func _unhandled_input(event):
	# Test functions
	if event.is_action_pressed("ui_cancel"):
		get_tree().quit()
	
	# Test fire spread
	if event.is_action_pressed("ui_select"):
		var mouse_pos = get_global_mouse_position()
		pathfinding_system.ignite_tile(mouse_pos)
	
	# Test electricity
	if event.is_action_pressed("ui_focus_next"):
		var mouse_pos = get_global_mouse_position()
		pathfinding_system.electrify_tile(mouse_pos, 10.0)
