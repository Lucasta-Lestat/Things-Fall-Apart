# res://Global/PlayerInputManager.gd
extends Node
class_name PlayerInputManager

signal selection_changed(selected_characters: Array[CombatCharacter])
signal camera_recenter_request(target_position: Vector2) # For camera to listen to

var selected_characters: Array[CombatCharacter] = []
var primary_selected_character: CombatCharacter = null # For camera focus, ability source

var drag_select_active: bool = false
var drag_start_screen_pos: Vector2
var selection_rect_visual: ColorRect # Visual feedback for drag selection

enum TargetingState { NONE, ABILITY_TARGETING }
var current_targeting_state: TargetingState = TargetingState.NONE
var ability_being_targeted: Ability = null
var ability_caster_for_targeting: CombatCharacter = null # Primary caster for preview
var just_selected_character: bool = false
const TARGETING_CURSOR = preload("res://targeting icon.png") # <-- Adjust path to your image
const CURSOR_HOTSPOT = Vector2(32, 32) # <-- Adjust to the center of your cursor image

var current_planning_character: CombatCharacter = null # Set by CombatManager.player_action_pending
var current_planning_ap_slot: int = -1
# Add reference to CombatManager instance
var combat_manager: CombatManager
@onready var game = get_node("/root/Game") as Node2D

func _ready():
	call_deferred("_setup_ui_elements")
	_set_input_active(true) # Enable input by default for out-of-combat use
	print("game: ", game)
func _setup_ui_elements():
	print("DEBUG: Setting up UI elements")
	selection_rect_visual = ColorRect.new()
	selection_rect_visual.color = Color(0.5, 0.7, 1.0, 0.25) # Semi-transparent blue
	selection_rect_visual.mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_tree().root.add_child(selection_rect_visual) # Add to root for global visibility
	selection_rect_visual.visible = false
	print("DEBUG: Selection rect visual created and added to scene")

func setup_combat_manager_connections():
	"""Call this after combat_manager is assigned"""
	print("DEBUG: Setting up combat manager connections")
	if combat_manager:
		print("DEBUG: Combat manager found, connecting signals")
		print("DEBUG: Current combat state when connecting: ", combat_manager.current_combat_state)
		
		combat_manager.planning_phase_started.connect(_on_planning_phase_started)
		combat_manager.resolution_phase_started.connect(_on_resolution_phase_started)
		combat_manager.combat_paused.connect(_on_combat_paused)
		combat_manager.combat_resumed.connect(_on_combat_resumed)
		combat_manager.player_action_pending.connect(_on_player_action_pending)
		combat_manager.combat_ended.connect(_on_combat_ended)
		_set_input_active(true)
	else:
		print("ERROR: Combat manager not found when trying to connect signals")

func _on_planning_phase_started():
	print("DEBUG: Planning phase started - enabling input")
	_set_input_active(true)

func _on_resolution_phase_started():
	print("DEBUG: Resolution phase started - disabling input")
	_set_input_active(false)

func _on_combat_ended(_winner):
	print("DEBUG: Combat ended - clearing selection and re-enabling input for out-of-combat")
	clear_selection()
	_set_input_active(true) # Re-enable input for out-of-combat use

func _set_input_active(is_active: bool):
	print("DEBUG: Setting input active: ", is_active)
	print("DEBUG: Combat manager state: ", combat_manager.current_combat_state if combat_manager else "no combat manager")
	set_process_input(is_active)
	if not is_active:
		cancel_targeting_mode()
		if is_instance_valid(selection_rect_visual): selection_rect_visual.visible = false
		drag_select_active = false

func _on_combat_paused(is_beat_pause: bool):
	# Allow some input during beat pause for re-planning or unpausing
	if is_beat_pause:
		set_process_input(true) # Allow space to be detected for replan/resume
	else:
		_set_input_active(false) # General pause might disable all combat input

func _on_combat_resumed():
	# If resuming to PLANNING, CombatManager will emit planning_phase_started which calls _set_input_active(true)
	# If resuming to RESOLUTION, input should remain largely off.
	if combat_manager and combat_manager.current_combat_state == CombatManager.CombatState.PLANNING:
		_set_input_active(true)
	else:
		_set_input_active(false) # Ensure input is off if not resuming to planning

func _on_player_action_pending(character: CombatCharacter, ap_slot_index: int):
	print("DEBUG: on_player_action_pending: ", character.name)
	if primary_selected_character != character:
		cancel_targeting_mode()
	current_planning_character = character
	current_planning_ap_slot = ap_slot_index
	# Auto-select the character whose turn it is to plan
	
	if character and character.allegiance == CombatCharacter.Allegiance.PLAYER:
		if not selected_characters.has(character) or primary_selected_character != character:
			_clear_selection_internally()
			_add_to_selection(character)
			primary_selected_character = character
			emit_signal("selection_changed", selected_characters)
			if is_instance_valid(primary_selected_character):
				emit_signal("camera_recenter_request", primary_selected_character.global_position)

func _is_in_combat() -> bool:
	if combat_manager:
		return combat_manager != null and combat_manager.current_combat_state != CombatManager.CombatState.IDLE and combat_manager.current_combat_state != CombatManager.CombatState.NONE
	else:
		return false
func _unhandled_input(event: InputEvent):
	# Only print for mouse clicks to avoid spam
	# 
	if event.is_action_pressed("ui_cancel"): # Escape key
		print("DEBUG: Escape key pressed")
		if combat_manager and combat_manager.current_combat_state == CombatManager.CombatState.PAUSED:
			if combat_manager.beat_pause_requested_by_player: # If it was a beat pause
				combat_manager.resume_normally_from_pause() # Resume resolution without replan
			else: # Generic pause (not yet implemented, but for future menu)
				combat_manager.resume_normally_from_pause() # Or toggle menu
			get_viewport().set_input_as_handled()
			return

	# Spacebar for beat pause / resume for replan
	if event.is_action_pressed("ui_accept"): # Spacebar
		print("DEBUG: Spacebar pressed")
		if combat_manager and combat_manager.current_combat_state == CombatManager.CombatState.BEAT_PAUSE_WINDOW:
			if combat_manager.request_beat_pause():
				get_viewport().set_input_as_handled()
				return
		elif combat_manager and combat_manager.current_combat_state == CombatManager.CombatState.PAUSED and combat_manager.beat_pause_requested_by_player:
			if combat_manager.resume_from_beat_pause_for_replan():
				get_viewport().set_input_as_handled()
				return

	# If input is not generally active for planning, ignore below
	if not is_processing_input(): 
		print("DEBUG: Input not active for planning, current state: ", combat_manager.current_combat_state if combat_manager else "no combat manager")
		return

	# --- Targeting Mode Input ---
	#Just put hotkeys here
	if event is InputEventKey and event.pressed:
		print("DEBUG: key pressed")
		if event.keycode == KEY_BACKSPACE:
			_select_all_player_characters()
			emit_signal("selection_changed", selected_characters)
			get_viewport().set_input_as_handled()
		
		# Hotbar keys (1-9, 0 for 10th)
		var hotkey_idx = -1
		if event.keycode >= KEY_1 and event.keycode <= KEY_9: hotkey_idx = event.keycode - KEY_1
		elif event.keycode == KEY_0: hotkey_idx = 9

		if hotkey_idx != -1:
			print("DEBUG: Hotkey pressed: ", hotkey_idx)
			print("DEBUG: current_planning_character: ", current_planning_character.character_name if current_planning_character else "<null>")
			print("DEBUG: primary_selected_character: ", primary_selected_character.character_name if primary_selected_character else "<null>")
			print("DEBUG: selected_characters count: ", selected_characters.size())
			# Determine which character(s) to use
			var actors = []
			if _is_in_combat() and is_instance_valid(current_planning_character):
				# In combat: use current_planning_character (the one whose turn it is)
				actors = [current_planning_character]
			elif is_instance_valid(primary_selected_character):
				# Out of combat or no current_planning_character: use selected character(s)
				actors = selected_characters.duplicate()
			
			if actors.is_empty():
				print("DEBUG: No actors available for ability")
				return
			
			# Check if ability exists and start targeting
			for actor in actors:
				if not is_instance_valid(actor): continue
				
				var ability = actor.abilities[hotkey_idx]
				if ability:
					print("DEBUG: Found ability: ", ability.display_name, " for actor: ", actor.character_name)
					_start_ability_targeting_mode(ability, actor)
					get_viewport().set_input_as_handled()
					return
				else:
					print("DEBUG: No ability found for hotkey ", hotkey_idx, " on actor: ", actor.character_name)
	
	if current_targeting_state == TargetingState.ABILITY_TARGETING:
		if event is InputEventMouseMotion:
			if is_instance_valid(ability_caster_for_targeting):
				var world_mouse_pos = _get_world_mouse_position()
				var ap_slot_to_use = -1
				if _is_in_combat():
					ap_slot_to_use = ability_caster_for_targeting.get_next_available_ap_slot_index()
				ability_caster_for_targeting.show_ability_preview(ability_being_targeted, world_mouse_pos, ap_slot_to_use)
			get_viewport().set_input_as_handled()
		
		elif event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT and event.pressed and not game.context_menu_open:
				_handle_ability_target_click(event.position)
				cancel_targeting_mode()
				get_viewport().set_input_as_handled()
			elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
				cancel_targeting_mode()
				get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var click_world_pos = _get_world_mouse_position()
		handle_right_click(click_world_pos)
		get_viewport().set_input_as_handled()
	# --- Character Selection ---
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not game.context_menu_open:
		print("handling selection, mouse button detected")
		if event.pressed:
			print("handling selection, event pressed")
			just_selected_character = false
			var click_world_pos = _get_world_mouse_position()
			var clicked_char: CombatCharacter = null
			
			# Get characters from appropriate source
			var characters_to_check = []
			print("is in combat: ", _is_in_combat(), "#handling selection")
			print("combat_manager==null: ",combat_manager==null, " #handling selection" )
			if _is_in_combat() and combat_manager:
				print("is_in_combat and combat_manager #handling selection")
				characters_to_check = combat_manager.player_party
			elif combat_manager == null or not _is_in_combat():
				# Out of combat: check characters_in_scene or party_chars
				if game.characters_in_scene and game.characters_in_scene is Array:
					print("handling selection, game.has characters and is array")
					characters_to_check = game.characters_in_scene
				elif game.has("party_chars") and game.party_chars is Array:
					characters_to_check = game.party_chars
			
			for char_node in characters_to_check:
				var character = char_node as CombatCharacter
				print("running characters to check #handling selection")
				if is_instance_valid(character):
					print('found valid character instance')
					if character.get_sprite_rect_global().has_point(click_world_pos):
						clicked_char = character
						break
			
			if clicked_char:
				if Input.is_key_pressed(KEY_SHIFT):
					_toggle_selection(clicked_char)
				else:
					_clear_selection_internally()
					_add_to_selection(clicked_char)
					primary_selected_character = clicked_char
				
				emit_signal("selection_changed", selected_characters)
				if is_instance_valid(primary_selected_character):
					emit_signal("camera_recenter_request", primary_selected_character.global_position)
				
				just_selected_character = true
				get_viewport().set_input_as_handled()
			else:
				drag_select_active = true
				drag_start_screen_pos = get_viewport().get_mouse_position()
				if not Input.is_key_pressed(KEY_SHIFT):
					_clear_selection_internally()
				if is_instance_valid(selection_rect_visual):
					selection_rect_visual.visible = true
				get_viewport().set_input_as_handled()
		
		elif event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			if drag_select_active:
				var end_screen_pos = get_viewport().get_mouse_position()
				var selection_rect = Rect2(drag_start_screen_pos, end_screen_pos - drag_start_screen_pos).abs()
				_perform_drag_selection(selection_rect, Input.is_key_pressed(KEY_SHIFT))
				emit_signal("selection_changed", selected_characters)
				if is_instance_valid(primary_selected_character):
					emit_signal("camera_recenter_request", primary_selected_character.global_position)
				
				drag_select_active = false
				if is_instance_valid(selection_rect_visual):
					selection_rect_visual.visible = false
				get_viewport().set_input_as_handled()
		
	elif event is InputEventMouseMotion:
		if drag_select_active:
			var current_screen_pos = get_viewport().get_mouse_position()
			var rect_pos = Vector2(min(drag_start_screen_pos.x, current_screen_pos.x), min(drag_start_screen_pos.y, current_screen_pos.y))
			var rect_size = (current_screen_pos - drag_start_screen_pos).abs()
			if is_instance_valid(selection_rect_visual):
				selection_rect_visual.global_position = rect_pos # Visual is in screen space
				selection_rect_visual.size = rect_size
			get_viewport().set_input_as_handled()

func _get_world_mouse_position() -> Vector2:
	var cam = get_viewport().get_camera_2d()
	if cam:
		return cam.get_global_mouse_position() # Godot 4 Camera2D has this helper
	return get_viewport().get_mouse_position() # Fallback, might be inaccurate if not global space

func _clear_selection_internally():
	print("DEBUG: Clearing selection internally")
	for char in selected_characters:
		if is_instance_valid(char): char.is_selected = false
	selected_characters.clear()
	primary_selected_character = null

func clear_selection(): # Public version that also emits
	print("DEBUG: Clearing selection and emitting signal")
	_clear_selection_internally()
	emit_signal("selection_changed", selected_characters)

func _add_to_selection(character: CombatCharacter):
	print("DEBUG: Adding character to selection: ", character.character_name)
	if not selected_characters.has(character):
		selected_characters.append(character)
		character.is_selected = true
		
		if not primary_selected_character: # If no primary, first selected becomes primary
			primary_selected_character = character
			print("DEBUG: Set primary selected character to: ", character.character_name)

func _toggle_selection(character: CombatCharacter):
	if selected_characters.has(character):
		character.is_selected = false
		selected_characters.erase(character)
		if primary_selected_character == character: # If primary was deselected
			primary_selected_character = selected_characters.back() if not selected_characters.is_empty() else null
	else:
		_add_to_selection(character)
func handle_right_click(click_position: Vector2):
	# Check each character for intersection with click position
	print("Handling right click")
	for character in game.characters_in_scene:
		# Get the character's collision shape or sprite bounds
		# This assumes characters have a CollisionShape2D or similar
		var character_rect = get_bounds(character)
		print("character rect: ", character_rect)
		if character_rect.has_point(click_position):
			# Found a character under the click - show context menu
			show_context_menu(character, click_position)
			return  # Only handle the first character found
	for character in game.characters_in_scene:
		if character.is_selected:
			character.move_to(click_position)
func get_bounds(character) -> Rect2:
	# Option 1: If using Area2D with CollisionShape2D
	if character.has_node("ClickArea/CollisionShape2D"):
		var collision_shape = character.get_node("ClickArea/CollisionShape2D")
		var shape = collision_shape.shape
		var pos = character.global_position

		if shape is RectangleShape2D:
			var extents = shape.size / 2
			return Rect2(pos - extents, shape.size)
		elif shape is CircleShape2D:
			var radius = shape.radius
			return Rect2(pos - Vector2(radius, radius), Vector2(radius * 2, radius * 2))
	return Rect2(character.global_position - Vector2(10, 10), Vector2(20, 20))


func show_context_menu(character, position: Vector2):
	# Create or get reference to your context menu scene
	print("showing context menu")
	var context_menu = preload("res://UI/ContextMenu.tscn").instantiate()

	# Position it near the character (offset slightly from click)
	context_menu.global_position = position + Vector2(GridManager.TILE_SIZE/4,GridManager.TILE_SIZE/4 )
	context_menu.z_index = 100
	game.context_menu_open = true  # Set flag
	print("game.context_menu_open: ", game.context_menu_open)
	# Populate the menu with the character's interact options
	context_menu.setup(character, character.interact_options)

	# Add to scene
	get_tree().root.add_child(context_menu)			
func _perform_drag_selection(screen_rect: Rect2, shift_modifier: bool):
	var selection_world_rect = Rect2(_get_world_mouse_position_from_screen(screen_rect.position), 
									 _get_world_mouse_position_from_screen(screen_rect.end) - _get_world_mouse_position_from_screen(screen_rect.position) ).abs()

	if not shift_modifier: # Re-clearing here because initial clear was before drag confirmed
		_clear_selection_internally()

	# Get characters from appropriate source
	var characters_to_check = []
	if _is_in_combat() and combat_manager:
		characters_to_check = combat_manager.player_party
	elif game.combat_manager == null or not _is_in_combat():
		if game.characters_in_scene and game.characters_in_scene is Array:
			characters_to_check = game.characters_in_scene
		elif game.characters_in_scene and game.party_chars is Array:
			characters_to_check = game.party_chars
	
	for char_node in characters_to_check:
		var character = char_node as CombatCharacter
		if is_instance_valid(character) and character.allegiance == CombatCharacter.Allegiance.PLAYER and character.current_health > 0:
			if selection_world_rect.intersects(character.get_sprite_rect_global()):
				_add_to_selection(character)
	
	if not selected_characters.is_empty() and not primary_selected_character:
		primary_selected_character = selected_characters[0]

func _get_world_mouse_position_from_screen(screen_pos: Vector2) -> Vector2:
	var cam = get_viewport().get_camera_2d()
	if cam:
		return cam.get_canvas_transform().affine_inverse() * screen_pos
	return screen_pos # Fallback

func _select_all_player_characters():
	_clear_selection_internally()
	
	# Get characters from appropriate source
	var characters_to_check = []
	if _is_in_combat() and combat_manager:
		characters_to_check = combat_manager.player_party
	elif game.combat_manager == null or not _is_in_combat():
		if game.has("characters_in_scene") and game.characters_in_scene is Array:
			characters_to_check = game.characters_in_scene
		elif game.has("party_chars") and game.party_chars is Array:
			characters_to_check = game.party_chars
	
	for char_node in characters_to_check:
		var character = char_node as CombatCharacter
		if is_instance_valid(character) and character.allegiance == CombatCharacter.Allegiance.PLAYER and character.current_health > 0:
			_add_to_selection(character)
	
	if not selected_characters.is_empty():
		primary_selected_character = selected_characters[0]
		if is_instance_valid(primary_selected_character):
			emit_signal("camera_recenter_request", primary_selected_character.global_position)

# --- Targeting Mode Logic ---
func _start_ability_targeting_mode(ability: Ability, caster: CombatCharacter):
	current_targeting_state = TargetingState.ABILITY_TARGETING
	ability_being_targeted = ability
	ability_caster_for_targeting = caster
	print_debug("Started targeting for: ", ability.display_name, " by ", caster.character_name)
	# --- UI FEEDBACK ADDED HERE ---
	# 1. Change the mouse cursor to your custom targeting icon.
	Input.set_custom_mouse_cursor(TARGETING_CURSOR, Input.CURSOR_ARROW, CURSOR_HOTSPOT)
	# 2. Show the ability preview immediately at the current mouse position.
	# This provides instant feedback on range and/or AOE.
	var world_mouse_pos = _get_world_mouse_position()
	var ap_slot_to_use = -1
	if _is_in_combat():
		ap_slot_to_use = caster.get_next_available_ap_slot_index()
	caster.show_ability_preview(ability, world_mouse_pos, ap_slot_to_use)
	
func cancel_targeting_mode():
	if current_targeting_state == TargetingState.ABILITY_TARGETING:
		if is_instance_valid(ability_caster_for_targeting):
			ability_caster_for_targeting.hide_previews()
		current_targeting_state = TargetingState.NONE
		ability_being_targeted = null
		ability_caster_for_targeting = null
		# --- UI FEEDBACK ADDED HERE ---
		# Reset the cursor to the default system cursor.
		Input.set_custom_mouse_cursor(null)
		# --- END OF ADDED UI FEEDBACK ---
		print_debug("Targeting cancelled.")

func _handle_ability_target_click(_mouse_screen_pos: Vector2): # mouse_screen_pos is not used, using _get_world_mouse_position
	var target_world_pos = _get_world_mouse_position()
	var clicked_char_target: CombatCharacter = null
	
	# Get character at position
	if _is_in_combat() and combat_manager:
		clicked_char_target = combat_manager.get_character_at_world_pos(target_world_pos)
	else:
		# Out of combat: check all characters in scene
		var characters_to_check = []
		if game.characters_in_scene and game.characters_in_scene is Array:
			characters_to_check = game.characters_in_scene
		elif game.party_chars and game.party_chars is Array:
			characters_to_check = game.party_chars
		
		for char_node in characters_to_check:
			var character = char_node as CombatCharacter
			if is_instance_valid(character) and character.current_health > 0:
				if character.get_sprite_rect_global().has_point(target_world_pos):
					clicked_char_target = character
					break
	
	print("DEBUG: Handling Ability Selection")
	var caster = ability_caster_for_targeting # The one who initiated targeting
	var ability = ability_being_targeted
	print("handling selection: ability type: ", typeof(ability))

	# Distance check (use clicked_char_target pos if available, otherwise mouse world pos)
	# --- NEW: Grid-based range check ---
	var start_tile = GridManager.world_to_map(caster.global_position)
	var end_tile = GridManager.world_to_map(target_world_pos)
	var range_in_tiles = caster.get_effective_range(ability)
	var is_in_range = true

	# Apply to all selected characters that are able and have this ability
	for char_to_act in selected_characters:
		if not is_instance_valid(char_to_act) or char_to_act.current_health <= 0: continue

		# Each character uses their own version of the ability (if they know it)
		# For simplicity, assume they are using the same ability 'type' (ID) as `ability_being_targeted`
		var actual_ability_for_char = char_to_act.get_ability_by_id(ability.id)
		if not actual_ability_for_char:
			print_debug(char_to_act.character_name, " doesn't know '", ability.id, "'")
			continue
		
		# In combat: check for available AP slot
		if _is_in_combat():
			var char_next_ap_slot = char_to_act.get_next_available_ap_slot_index()
			if char_next_ap_slot == -1: # No slots for this character
				print_debug(char_to_act.character_name, " has no AP slots to plan.")
				continue
		
		if ability.effect == Ability.ActionEffect.MOVE:
			var path = GridManager.find_path(start_tile, end_tile)
			is_in_range = not path.is_empty() and path.size() <= range_in_tiles
			print("attempting to move after target click in playerinputmanager", " Is in range: ", is_in_range)

		else: # Manhattan distance for attacks/spells
			print("Manhattan? why")
			var distance = abs(start_tile.x - end_tile.x) + abs(start_tile.y - end_tile.y)
			is_in_range = distance <= range_in_tiles

	#if not is_in_range:
		#print_debug("Target out of range for '", ability.display_name, "'")
		#return # Let player try again

	# Apply to all selected characters (logic is now grid-aware)
	for char_to_act in selected_characters:
		if not is_instance_valid(char_to_act) or char_to_act.current_health <= 0: 
			print("character: ", char_to_act.character_name, "wasn't able to use ability")
			continue
		
		var actual_ability = char_to_act.get_ability_by_id(ability.id)
		if not actual_ability: 
			print("ability didn't exist")
			continue
		
		# Different behavior based on combat state
		if _is_in_combat():
			# In combat: plan the ability
			var char_next_slot = char_to_act.get_next_available_ap_slot_index()
			print("check if can plan")
			if char_to_act.can_start_planning_ability(actual_ability, char_next_slot):
				print("can plan")
				# Use target_world_pos which will be snapped to the grid center in plan_ability_use
				char_to_act.plan_ability_use(actual_ability, char_next_slot, clicked_char_target, target_world_pos)
			else:
				print_debug(char_to_act.character_name, " cannot use '", actual_ability.display_name, "' (AP/Slot). #combat")
		else:
			# Out of combat: immediately resolve the ability
			print("Immediately resolving ability out of combat")
			# Call the ability's immediate resolution
			# You may need to add a method to CombatCharacter like:
			# char_to_act.use_ability_immediately(actual_ability, clicked_char_target, target_world_pos)
			# For now, this is a placeholder - implement based on your character's ability system
			if char_to_act.has_method("use_ability_immediately"):
				char_to_act.use_ability_immediately(actual_ability,target_world_pos)
			else:
				print("WARNING: Character doesn't have immediate ability resolution method")
