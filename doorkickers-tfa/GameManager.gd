# GameManager.gd
extends Node2D
class_name GameManager

@export var camera_speed: float = 500.0
@export var camera_zoom_speed: float = 0.1
@export var min_zoom: float = 0.5
@export var max_zoom: float = 2.0

var selected_character: CharacterController = null
var player_characters: Array = []
var enemy_characters: Array = []
var current_path_preview: Line2D

var vision_system: VisionSystem
var pathfinding_system: PathfindingSystem
var construction_system: ConstructionSystem

var is_drawing_path: bool = false
var path_points: PackedVector2Array = []

# UI References
var character_ui: Control
var inventory_ui: Control
var action_menu: PopupMenu

signal character_selected(character)
signal character_deselected()

func _ready():
	# Initialize systems
	vision_system = VisionSystem.new()
	add_child(vision_system)
	
	pathfinding_system = PathfindingSystem.new()
	add_child(pathfinding_system)
	
	construction_system = ConstructionSystem.new()
	add_child(construction_system)
	
	# Create path preview line
	current_path_preview = Line2D.new()
	current_path_preview.width = 2.0
	current_path_preview.default_color = Color(0, 1, 0, 0.5)
	add_child(current_path_preview)
	
	# Setup UI
	_setup_ui()
	
	# Connect signals
	vision_system.visibility_updated.connect(_on_visibility_updated)
	
	set_process_unhandled_input(true)

func _setup_ui():
	# Create character UI panel
	character_ui = Control.new()
	character_ui.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	character_ui.visible = false
	add_child(character_ui)
	
	# Create inventory UI
	inventory_ui = Control.new()
	inventory_ui.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	inventory_ui.visible = false
	add_child(inventory_ui)
	
	# Create action menu
	action_menu = PopupMenu.new()
	action_menu.add_item("Attack", 0)
	action_menu.add_item("Move", 1)
	action_menu.add_item("Use Item", 2)
	action_menu.add_item("Cast Spell", 3)
	action_menu.add_item("Reload", 4)
	action_menu.add_item("Wait", 5)
	action_menu.id_pressed.connect(_on_action_selected)
	add_child(action_menu)

func _unhandled_input(event):
	# Camera controls
	_handle_camera_input(event)
	
	# Character selection and commands
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_handle_left_click(event.position)
			else:
				_finish_path_drawing()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_handle_right_click(event.position)
	
	elif event is InputEventMouseMotion:
		if is_drawing_path and selected_character:
			_update_path_preview(event.position)

func _handle_camera_input(event):
	var camera = get_viewport().get_camera_2d()
	if not camera:
		return
	
	# WASD camera movement
	var move_dir = Vector2.ZERO
	if Input.is_action_pressed("camera_up"):
		move_dir.y -= 1
	if Input.is_action_pressed("camera_down"):
		move_dir.y += 1
	if Input.is_action_pressed("camera_left"):
		move_dir.x -= 1
	if Input.is_action_pressed("camera_right"):
		move_dir.x += 1
	
	if move_dir.length() > 0:
		camera.position += move_dir.normalized() * camera_speed * get_process_delta_time()
	
	# Mouse wheel zoom
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera.zoom *= (1 + camera_zoom_speed)
			camera.zoom.x = clamp(camera.zoom.x, min_zoom, max_zoom)
			camera.zoom.y = clamp(camera.zoom.y, min_zoom, max_zoom)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera.zoom *= (1 - camera_zoom_speed)
			camera.zoom.x = clamp(camera.zoom.x, min_zoom, max_zoom)
			camera.zoom.y = clamp(camera.zoom.y, min_zoom, max_zoom)

func _handle_left_click(screen_pos: Vector2):
	var world_pos = get_global_mouse_position()
	
	# Check if clicking on a character
	var character = _get_character_at_position(world_pos)
	
	if character:
		if character in player_characters:
			_select_character(character)
			# Start drawing path if shift is held
			if Input.is_key_pressed(KEY_SHIFT):
				_start_path_drawing(world_pos)
		else:
			# Clicked on enemy - attack if we have a selected character
			if selected_character and selected_character in player_characters:
				selected_character.target_enemy = character
				selected_character.ai_state = CharacterController.AIState.ENGAGING
	else:
		# Clicked on empty space
		if selected_character and Input.is_key_pressed(KEY_SHIFT):
			_start_path_drawing(world_pos)
		elif selected_character:
			# Simple move command
			var path = pathfinding_system.calculate_path(selected_character.global_position, world_pos)
			selected_character.set_path(path)
			selected_character.ai_state = CharacterController.AIState.FOLLOWING_PATH
		else:
			_deselect_character()

func _handle_right_click(screen_pos: Vector2):
	var world_pos = get_global_mouse_position()
	
	# Show action menu for selected character
	if selected_character:
		action_menu.position = screen_pos
		action_menu.popup()

func _start_path_drawing(start_pos: Vector2):
	is_drawing_path = true
	path_points.clear()
	path_points.append(selected_character.global_position)
	current_path_preview.points = path_points

func _update_path_preview(current_pos: Vector2):
	if not is_drawing_path or not selected_character:
		return
	
	var world_pos = get_global_mouse_position()
	
	# Add point if far enough from last point
	if path_points.size() == 0 or world_pos.distance_to(path_points[-1]) > 20:
		path_points.append(world_pos)
		current_path_preview.points = path_points

func _finish_path_drawing():
	if is_drawing_path and selected_character and path_points.size() > 1:
		# Convert path points to actual pathfinding path
		var final_path = PackedVector2Array()
		
		for i in range(1, path_points.size()):
			var segment_path = pathfinding_system.calculate_path(path_points[i-1], path_points[i])
			for point in segment_path:
				final_path.append(point)
		
		selected_character.set_path(final_path)
		selected_character.ai_state = CharacterController.AIState.FOLLOWING_PATH
	
	is_drawing_path = false
	path_points.clear()
	current_path_preview.clear_points()

func _select_character(character: CharacterController):
	if selected_character:
		_deselect_character()
	
	selected_character = character
	character_selected.emit(character)
	
	# Update UI
	character_ui.visible = true
	inventory_ui.visible = true
	_update_character_ui()

func _deselect_character():
	if selected_character:
		character_deselected.emit()
	
	selected_character = null
	character_ui.visible = false
	inventory_ui.visible = false

func _get_character_at_position(pos: Vector2) -> CharacterController:
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsPointQueryParameters2D.new()
	query.position = pos
	query.collision_mask = 0b0100  # Character layer
	
	var results = space_state.intersect_point(query)
	for result in results:
		if result.collider is CharacterController:
			return result.collider
	
	return null

func _on_action_selected(id: int):
	if not selected_character:
		return
	
	match id:
		0:  # Attack
			# Enter targeting mode
			pass
		1:  # Move
			# Already handled by left click
			pass
		2:  # Use Item
			# Open item selection
			pass
		3:  # Cast Spell
			# Open spell selection
			pass
		4:  # Reload
			if selected_character.equipped_weapon:
				selected_character.equipped_weapon.reload()
		5:  # Wait
			selected_character.ai_state = CharacterController.AIState.IDLE

func _update_character_ui():
	# Update character stats display
	# This would be connected to actual UI elements
	pass

func _on_visibility_updated():
	# Hide enemies that are not visible
	for enemy in enemy_characters:
		if enemy:
			var is_visible = false
			for player in player_characters:
				if player and enemy in player.visible_characters:
					is_visible = true
					break
			
			enemy.visible = is_visible
			
			# Show ghost if heard but not seen
			if not is_visible:
				for player in player_characters:
					if player and enemy in player.heard_characters:
						enemy.modulate = Color(0.5, 0.5, 0.5, 0.3)
						enemy.visible = true
						break

func add_player_character(character: CharacterController):
	character.is_player_controlled = true
	character.add_to_group("player_characters")
	player_characters.append(character)
	add_child(character)

func add_enemy_character(character: CharacterController):
	character.is_player_controlled = false
	character.add_to_group("enemy_characters")
	enemy_characters.append(character)
	add_child(character)

func spawn_character(position: Vector2, is_player: bool = true) -> CharacterController:
	var character = preload("res://EnhancedCharacterController.tscn").instantiate()
	character.global_position = position
	
	if is_player:
		add_player_character(character)
	else:
		add_enemy_character(character)
	
	return character
