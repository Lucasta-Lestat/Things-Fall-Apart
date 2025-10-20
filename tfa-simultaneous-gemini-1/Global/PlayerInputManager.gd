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

func _ready():
	call_deferred("_setup_ui_elements")
	_set_input_active(false)


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
		
		# Check if we're already in planning state and enable input if so
		if combat_manager.current_combat_state == CombatManager.CombatState.PLANNING:
			print("DEBUG: Combat is already in PLANNING state, enabling input immediately")
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
	print("DEBUG: Combat ended - clearing selection and disabling input")
	clear_selection()
	_set_input_active(false)

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

func _unhandled_input(event: InputEvent):
	# Only print for mouse clicks to avoid spam
	if event is InputEventMouseButton and event.pressed:
		#print("DEBUG: _unhandled_input called with mouse click: ", event.button_index, " at position: ", event.position)
		pass
	# Global unpause, not tied to beat_pause re-planning
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
		#print("DEBUG: Input not active for planning, current state: ", combat_manager.current_combat_state if combat_manager else "no combat manager")
		return

	#print("DEBUG: Processing input event in planning mode")

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
			
			# Determine which character should use the ability
			var acting_char: CombatCharacter = null
			
			# Priority 1: Use primary selected character (this is what the player expects)
			if primary_selected_character and is_instance_valid(primary_selected_character):
				acting_char = primary_selected_character
				print("DEBUG: Using primary selected character: ", acting_char.character_name)
			# Priority 2: Use first selected character
			elif not selected_characters.is_empty() and is_instance_valid(selected_characters[0]):
				acting_char = selected_characters[0]
				print("DEBUG: Using first selected character: ", acting_char.character_name)
			# Priority 3: If we have a current planning character, use them (fallback)
			elif current_planning_character and is_instance_valid(current_planning_character):
				acting_char = current_planning_character
				print("DEBUG: Using current planning character: ", acting_char.character_name)
			
			if acting_char:
				print("DEBUG: Acting character: ", acting_char.character_name)
				print("DEBUG: Character has ", acting_char.abilities.size(), " abilities")
				print("DEBUG: Character current AP: ", acting_char.current_ap_for_planning)
				
				if acting_char.abilities.size() > hotkey_idx:
					var ability = acting_char.abilities[hotkey_idx]
					print("DEBUG: Trying to use ability: ", ability.display_name if ability else "null")
					
					if ability:
						# Determine which slot to plan for
						var planning_slot = acting_char.get_next_available_ap_slot_index()
						print("DEBUG: Next available slot: ", planning_slot)
						
						if planning_slot != -1 and acting_char.can_start_planning_ability(ability, planning_slot):
							print("DEBUG: Can start planning ability")
							if ability.requires_target():
								print("DEBUG: Ability requires target, starting targeting mode")
								_start_ability_targeting_mode(ability, acting_char)
							else: # Self-cast or no target needed
								print("DEBUG: Self-casting ability")
								acting_char.plan_ability_use(ability, planning_slot, acting_char) # Target self
						else:
							print("DEBUG: Cannot use ability - AP/Slot issue")
							print("DEBUG: Current AP: ", acting_char.current_ap_for_planning, " Required: ", ability.ap_cost)
							print("DEBUG: Planning slot: ", planning_slot)
							print("DEBUG: can_start_planning_ability result: ", acting_char.can_start_planning_ability(ability, planning_slot) if planning_slot != -1 else "invalid slot")
					else:
						print("DEBUG: Ability is null")
				else:
					print("DEBUG: Hotkey index out of range. Character has ", acting_char.abilities.size(), " abilities, requested index ", hotkey_idx)
			else:
				print("DEBUG: No acting character found")
			
			get_viewport().set_input_as_handled()
	
	if current_targeting_state == TargetingState.ABILITY_TARGETING:
		#print("DEBUG: In targeting mode")
		if event is InputEventMouseButton and event.pressed:
			print("DEBUG: mouse input received in targeting mode")
			if event.button_index == MOUSE_BUTTON_LEFT:
				print("DEBUG: Left mouse button click event in targeting mode")
				_handle_ability_target_click(get_viewport().get_mouse_position())
				get_viewport().set_input_as_handled()
				return
			elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
				cancel_targeting_mode()
				get_viewport().set_input_as_handled()
			return
		elif event is InputEventMouseMotion:
			# print("DEBUG: Mouse motion in targeting mode")
			if ability_caster_for_targeting and ability_being_targeted:
				var world_mouse_pos = _get_world_mouse_position()
				var next_slot = ability_caster_for_targeting.get_next_available_ap_slot_index()
				ability_caster_for_targeting.show_ability_preview(ability_being_targeted, world_mouse_pos, next_slot)
			get_viewport().set_input_as_handled()
			return
		elif event.is_action_pressed("ui_cancel"): # Escape
			cancel_targeting_mode()
			get_viewport().set_input_as_handled()
			return
		# Don't process other inputs when targeting
		return

	# --- Standard Planning Input (Selection, Hotkeys) ---
	if event is InputEventMouseButton:
		print("DEBUG: Mouse button event: ", event.button_index, " pressed: ", event.pressed)
		if event.button_index == MOUSE_BUTTON_LEFT:
			var world_mouse_pos = _get_world_mouse_position()
			print("DEBUG: World mouse position: ", world_mouse_pos)
			if event.pressed:
				just_selected_character = false  # Reset the flag
				var clicked_on_char = combat_manager.get_character_at_world_pos(world_mouse_pos) 
				print("DEBUG: Clicked on character: ", clicked_on_char.character_name if clicked_on_char else "none")
				
				if clicked_on_char and clicked_on_char.allegiance == CombatCharacter.Allegiance.PLAYER:
					print("DEBUG: Selecting player character: ", clicked_on_char.character_name)
					just_selected_character = true  # Mark that we selected a character
					if Input.is_key_pressed(KEY_SHIFT):
						_toggle_selection(clicked_on_char)
					else:
						_clear_selection_internally()
						_add_to_selection(clicked_on_char)
						primary_selected_character = clicked_on_char
						current_planning_character = clicked_on_char
					print("DEBUG: Emitting selection_changed signal with ", selected_characters.size(), " characters")
					emit_signal("selection_changed", selected_characters)
					if is_instance_valid(primary_selected_character):
						print("DEBUG: Emitting camera_recenter_request to ", primary_selected_character.global_position)
						emit_signal("camera_recenter_request", primary_selected_character.global_position)
					get_viewport().set_input_as_handled()
					return  # Important: return here to prevent drag selection from starting
				else: # Clicked on empty space or enemy
					print("DEBUG: Starting drag selection")
					drag_start_screen_pos = get_viewport().get_mouse_position()
					drag_select_active = true
					if is_instance_valid(selection_rect_visual):
						selection_rect_visual.global_position = drag_start_screen_pos
						selection_rect_visual.size = Vector2.ZERO
						selection_rect_visual.visible = true
					# If not shift clicking, clear previous selection on drag start
					if not Input.is_key_pressed(KEY_SHIFT):
						_clear_selection_internally()
						# Don't emit signal yet, wait for drag release
			else: # Mouse button released
				if drag_select_active:
					print("DEBUG: Ending drag selection")
					drag_select_active = false
					if is_instance_valid(selection_rect_visual):
						selection_rect_visual.visible = false
					var drag_end_screen_pos = get_viewport().get_mouse_position()
					_perform_drag_selection(Rect2(drag_start_screen_pos, drag_end_screen_pos - drag_start_screen_pos), Input.is_key_pressed(KEY_SHIFT))
					emit_signal("selection_changed", selected_characters) # Emit after drag
					get_viewport().set_input_as_handled()
				# Only clear selection if we didn't just select a character, didn't just finish a drag,
				# and we're not holding shift
				elif not just_selected_character and not Input.is_key_pressed(KEY_SHIFT):
					print("DEBUG: Clearing selection (clicked empty space)")
					clear_selection() # This calls _clear_selection_internally and emits
					get_viewport().set_input_as_handled()
				
				# Reset the flag after handling mouse release
				just_selected_character = false

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

func _perform_drag_selection(screen_rect: Rect2, shift_modifier: bool):
	var selection_world_rect = Rect2(_get_world_mouse_position_from_screen(screen_rect.position), 
									 _get_world_mouse_position_from_screen(screen_rect.end) - _get_world_mouse_position_from_screen(screen_rect.position) ).abs()

	if not shift_modifier: # Re-clearing here because initial clear was before drag confirmed
		_clear_selection_internally()

	if combat_manager:
		for char_node in combat_manager.player_party: # Only select player characters
			var character = char_node as CombatCharacter
			if is_instance_valid(character) and character.current_health > 0:
				if selection_world_rect.intersects(character.get_sprite_rect_global()): # Use sprite bounds for check
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
	if combat_manager:
		for char_node in combat_manager.player_party:
			var character = char_node as CombatCharacter
			if is_instance_valid(character) and character.current_health > 0:
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
	caster.show_ability_preview(ability, world_mouse_pos, caster.get_next_available_ap_slot_index())
	

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
	var clicked_char_target = combat_manager.get_character_at_world_pos(target_world_pos)
	#replace with grid manager call
	print("DEBUG: Handling Ability Selection")
	var caster = ability_caster_for_targeting # The one who initiated targeting
	var ability = ability_being_targeted

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
			print("character: ", char_to_act.character_name, "wasn't able to use ability #combat")
			continue
		
		var actual_ability = char_to_act.get_ability_by_id(ability.id)
		if not actual_ability: 
			print("ability didn't exist #combat")
			continue
		
		var char_next_slot = char_to_act.get_next_available_ap_slot_index()
		print("check if can plan")
		if char_to_act.can_start_planning_ability(actual_ability, char_next_slot):
			print("can plan")
			# Use target_world_pos which will be snapped to the grid center in plan_ability_use
			char_to_act.plan_ability_use(actual_ability, char_next_slot, clicked_char_target, target_world_pos)
		else:
			print_debug(char_to_act.character_name, " cannot use '", actual_ability.display_name, "' (AP/Slot). #combat")
