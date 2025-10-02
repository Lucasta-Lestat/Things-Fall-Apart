# res://Global/CombatManager.gd
#Autoload Singleton
extends Node2D
class_name CombatManager

signal round_started
signal planning_phase_started # Player can now plan
signal player_action_pending(character: CombatCharacter, next_ap_slot: int) # UI hint for which char/slot to plan
signal resolution_phase_started # Actions are now being resolved
signal ap_slot_resolution_beat_starts(ap_slot_index: int) # Beat starts, player can pause
signal ap_slot_resolved(ap_slot_index: int) # A single AP slot's actions are done
signal all_ap_slots_resolved # All AP slots for the round are done
signal combat_started
signal combat_paused(is_beat_pause: bool)
signal combat_resumed
signal combat_ended(winner_allegiance: CombatCharacter.Allegiance)


enum CombatState { IDLE, PLANNING, RESOLVING_SLOT, BEAT_PAUSE_WINDOW, PAUSED, ROUND_OVER }

var current_combat_state: CombatState = CombatState.IDLE
var all_characters_in_combat: Array[CombatCharacter] = []
var player_party: Array[CombatCharacter] = []
var enemy_party: Array[CombatCharacter] = []
var all_structures_in_combat: Array[Structure] = [] # NEW: Tracks structures



var current_ap_slot_being_resolved: int = 0
const MAX_AP_SLOTS_PER_ROUND = 4 # Default, can be dynamic later
var beat_pause_requested_by_player: bool = false

var characters_finished_planning_round: Array[CombatCharacter] = [] # Characters who have no more AP or slots to plan this round

const ACTION_ANIMATION_DURATION = 0.3 # How long each small action animation plays
const BEAT_PAUSE_WINDOW_DURATION = 0.5 # Time player has to press space to pause

var active_player_character_planning_idx: int = 0 # For turn-based planning among player chars

# --- NEW: Structure Management ---
func register_structure(structure: Structure):
	if not structure in all_structures_in_combat:
		all_structures_in_combat.append(structure)
		print_debug("[CombatManager] Registered structure: ", structure.structure_id)

func unregister_structure(structure: Structure):
	all_structures_in_combat.erase(structure)
	print_debug("[CombatManager] Unregistered structure: ", structure.structure_id)

# --- NEW: AoE Helper Function ---
func get_entities_in_tiles(tiles: Array[Vector2i]) -> Array:
	var entities_found: Array = []
	var tile_set = {} # Use a dictionary for faster lookups
	for tile in tiles:
		tile_set[tile] = true
		
	for char in all_characters_in_combat:
		if is_instance_valid(char) and char.current_health > 0:
			var char_tile = GridManager.world_to_map(char.global_position)
			if tile_set.has(char_tile):
				entities_found.append(char)
				
	for struct in all_structures_in_combat:
		if is_instance_valid(struct) and struct.current_health > 0:
			var struct_tile = GridManager.world_to_map(struct.global_position)
			if tile_set.has(struct_tile):
				entities_found.append(struct)
				
	print_debug("[CombatManager] Found ", entities_found.size(), " entities in ", tiles.size(), " tiles.")
	return entities_found
func register_character(character: CombatCharacter):
	if not character in all_characters_in_combat:
		all_characters_in_combat.append(character)
		if character.allegiance == CombatCharacter.Allegiance.PLAYER:
			player_party.append(character)
		elif character.allegiance == CombatCharacter.Allegiance.ENEMY:
			enemy_party.append(character)
		print("party: ", player_party, " #combat #ui")
		print("enemy party: ", enemy_party, "#plan ai")
		print("all characters in combat: ", all_characters_in_combat, " #combat #ui")
		character.planned_action_for_slot.connect(_on_character_planned_action)
		character.no_more_ap_to_plan.connect(_on_character_finished_planning_round)
		character.died.connect(_on_character_died)
		print_debug("Registered: ", character.character_name, "#ui #combat")

func unregister_character(character: CombatCharacter):
	all_characters_in_combat.erase(character)
	player_party.erase(character)
	enemy_party.erase(character)

	if character.is_connected("planned_action_for_slot", Callable(self, "_on_character_planned_action")):
		character.planned_action_for_slot.disconnect(Callable(self, "_on_character_planned_action"))
	if character.is_connected("no_more_ap_to_plan", Callable(self, "_on_character_finished_planning_round")):
		character.no_more_ap_to_plan.disconnect(Callable(self, "_on_character_finished_planning_round"))
	if character.is_connected("died", Callable(self, "_on_character_died")):
		character.died.disconnect(Callable(self, "_on_character_died"))


func start_combat(characters: Array[CombatCharacter]):
	print_rich("[b]Combat Starting![/b] #ui #combat")
	
	all_characters_in_combat.clear() # Clear previous combatants
	player_party.clear()
	enemy_party.clear()
	
	for char in characters:
		print("Attempting to register: ", char.character_name, "#ui #combat")
		if is_instance_valid(char):
			register_character(char) # This also connects signals
		else:
			print("Didn't register as wasn't a valid character #ui #combat")
	print("combat started #ui #combat")
	emit_signal("combat_started")
	if player_party.is_empty() && enemy_party.is_empty():
		print_rich("[color=red]No characters to start combat.[/color]")
		current_combat_state = CombatState.IDLE
		return
	start_new_round()

func start_new_round():
	print_rich("[color=green]>>> New Round Starting <<<[/color]")
	current_ap_slot_being_resolved = 0
	characters_finished_planning_round.clear()
	beat_pause_requested_by_player = false
	
	for character in all_characters_in_combat:
		if is_instance_valid(character) and character.current_health > 0:
			character.start_round_reset() # Resets AP, clears planned_actions array for new round

	# AI Planning (enemies plan all their actions for the round now)
	for enemy_char in enemy_party:
		if is_instance_valid(enemy_char) and enemy_char.current_health > 0:
			# print_debug("AI ", enemy_char.character_name, " starting to plan its round.")
			enemy_char.plan_entire_round_ai(all_characters_in_combat) # AI plans all its actions
			_on_character_finished_planning_round(enemy_char) # Mark AI as done planning

	current_combat_state = CombatState.PLANNING
	active_player_character_planning_idx = 0
	emit_signal("round_started")
	emit_signal("planning_phase_started")
	
	# Prompt first player character to plan
	_prompt_next_player_character_to_plan()

func _prompt_next_player_character_to_plan():
	if current_combat_state != CombatState.PLANNING: return

	var character_to_plan = _get_next_active_player_character_for_planning()
	if character_to_plan:
		var next_slot = character_to_plan.get_next_available_ap_slot_index()
		if next_slot != -1: # If they have slots left
			print_debug("Prompting ", character_to_plan.character_name, " to plan for slot ", next_slot)
			emit_signal("player_action_pending", character_to_plan, next_slot)
		else: # This character is actually done (no slots or AP left), mark and try next
			_on_character_finished_planning_round(character_to_plan)
			_prompt_next_player_character_to_plan() # Recursive call for next
	else:
		# No more player characters can plan (all are in characters_finished_planning_round)
		# print_debug("All player characters appear to be done planning.")
		check_if_all_planning_is_complete_to_start_resolution()


func _get_next_active_player_character_for_planning() -> CombatCharacter:
	if player_party.is_empty(): return null
	for i in range(player_party.size()):
		var char_idx = (active_player_character_planning_idx + i) % player_party.size()
		var character = player_party[char_idx]
		if is_instance_valid(character) and character.current_health > 0 and \
		   not characters_finished_planning_round.has(character):
			active_player_character_planning_idx = char_idx # Update who's next
			return character
	return null # All player characters done or no active ones left

func _on_character_planned_action(character: CombatCharacter, _ap_slot_index: int, _action: PlannedAction):
	print("a character planned an action")
	if current_combat_state != CombatState.PLANNING: return
	if character.allegiance != CombatCharacter.Allegiance.PLAYER: return # AI plans upfront
	print_debug(character.character_name, " planned for slot ", _ap_slot_index)
	var next_slot = character.get_next_available_ap_slot_index()
	if next_slot != -1 and character.current_ap_for_planning > 0:
		emit_signal("player_action_pending", character, next_slot) # Still more this char can do
	else:
		# This character has finished their planning (no more AP or slots)
		_on_character_finished_planning_round(character)
		_prompt_next_player_character_to_plan() # Move to next player character

func _on_character_finished_planning_round(character: CombatCharacter):
	for char in all_characters_in_combat:
		print(char.character_name, " has ", char.current_ap_for_planning, " ap remaining. # turn resolution" )
	if not characters_finished_planning_round.has(character):
		characters_finished_planning_round.append(character)
		print_debug(character.character_name, " confirmed finished planning for the round #turn resolution.")
	
	if character.allegiance == CombatCharacter.Allegiance.PLAYER:
		var all_players_done = true
		for p_char in player_party:
			if is_instance_valid(p_char) and p_char.current_health > 0 and not characters_finished_planning_round.has(p_char):
				all_players_done = false
				break
		if all_players_done:
			print_debug("All player characters have finished planning. #turn resolution")
			check_if_all_planning_is_complete_to_start_resolution()

func check_if_all_planning_is_complete_to_start_resolution():
	print("checking if all planning is complete to start #turn resolution")
	if current_combat_state != CombatState.PLANNING: return
	
	var all_active_chars_finished_planning = true
	for char in all_characters_in_combat:
		if is_instance_valid(char) and char.current_health > 0: # Only consider active characters
			if not characters_finished_planning_round.has(char):
				all_active_chars_finished_planning = false
				print_debug("Waiting for: ", char.character_name, " to finish planning.")
				break
	
	print("all_active_chars have finished planning: ", all_active_chars_finished_planning)

	if all_active_chars_finished_planning:
		print_debug("All active characters finished planning. Starting # turn resolution.")
		begin_action_resolution_phase()


func begin_action_resolution_phase():
	if current_combat_state != CombatState.PLANNING: return
	print_rich("[color=orange]>>> Beginning Action Resolution Phase #turn resolution <<<[/color]")
	current_combat_state = CombatState.RESOLVING_SLOT
	current_ap_slot_being_resolved = 0
	emit_signal("resolution_phase_started")
	
	resolve_current_ap_slot_actions()

func resolve_current_ap_slot_actions():
	if current_ap_slot_being_resolved >= MAX_AP_SLOTS_PER_ROUND:
		_finish_round_resolution()
		return

	if current_combat_state != CombatState.RESOLVING_SLOT: 
		return

	print_rich("\n[color=yellow]-- Resolving AP Slot:", current_ap_slot_being_resolved + 1, "/", MAX_AP_SLOTS_PER_ROUND, "--[/color]")
	
	var actions_this_slot: Array[PlannedAction] = []
	for character in all_characters_in_combat:
		if is_instance_valid(character) and character.current_health > 0:
			if character.planned_actions.size() > current_ap_slot_being_resolved:
				var action = character.planned_actions[current_ap_slot_being_resolved]
				if action: # An action is planned here
					action.dex_snapshot = character.dexterity # Ensure dex is current for sorting
					
					# Handle multi-AP charging
					if action.is_multi_ap_charge_segment:
						var original_ability_action = character.get_multi_ap_action_root(action.multi_ap_ability_id, current_ap_slot_being_resolved)
						if original_ability_action:
							original_ability_action.ap_spent_on_charge += 1
							# print_debug(character.character_name, " charging '", original_ability_action.ability_id, "', progress: ", original_ability_action.ap_spent_on_charge, "/", original_ability_action.total_ap_cost_for_ability)
							if original_ability_action.is_fully_charged():
								print_rich("[color=violet]", character.character_name, "'s ability '", original_ability_action.ability_id, "' fully charged![/color]")
								actions_this_slot.append(original_ability_action) # Add the root action to execute
							else:
								print_rich("[color=gray]", character.character_name, " continues charging '", original_ability_action.ability_id, "'...[/color]")
						else:
							printerr("Could not find root for multi-AP charge segment: ", action.ability_id, " for ", character.character_name)
					elif not action.is_part_of_resolved_multi_ap: # If it's a normal action or the final part of multi-AP not yet added
						actions_this_slot.append(action)

	# Sort actions by dexterity (higher goes first)
	actions_this_slot.sort_custom(func(a, b): return a.dex_snapshot > b.dex_snapshot)

	# Execute actions rapidly, partially overlapping
	if not actions_this_slot.is_empty():
		await _execute_actions_with_timing(actions_this_slot)

	emit_signal("ap_slot_resolved", current_ap_slot_being_resolved)
	
	# Beat pause window starts
	if current_ap_slot_being_resolved < MAX_AP_SLOTS_PER_ROUND -1: # No beat after the last slot
		current_combat_state = CombatState.BEAT_PAUSE_WINDOW
		beat_pause_requested_by_player = false
		emit_signal("ap_slot_resolution_beat_starts", current_ap_slot_being_resolved)
		# print_debug("Beat window. Press Space to pause and re-plan. Auto-advancing in ", BEAT_PAUSE_WINDOW_DURATION, "s")
		var beat_timer = get_tree().create_timer(BEAT_PAUSE_WINDOW_DURATION, false) # process_always = false
		# Timer will call a function that checks `beat_pause_requested_by_player`
		beat_timer.timeout.connect(_on_beat_window_timer_timeout.bind(beat_timer), CONNECT_ONE_SHOT)
	else: # Last slot resolved
		current_ap_slot_being_resolved += 1 # Increment to meet MAX_AP_SLOTS_PER_ROUND
		_finish_round_resolution()

func _execute_actions_with_timing(actions_this_slot: Array[PlannedAction]):
	for action_to_execute in actions_this_slot:
		if is_instance_valid(action_to_execute.caster) and action_to_execute.caster.current_health > 0:
			# Check target validity just before execution
			if action_to_execute.target_character and (not is_instance_valid(action_to_execute.target_character) or action_to_execute.target_character.current_health <= 0):
				print_rich("[color=gray]", action_to_execute.caster.character_name, "'s target '", action_to_execute.target_character.character_name if is_instance_valid(action_to_execute.target_character) else "Unknown Target", "' defeated. Action fizzles.[/color]")
			else:
				action_to_execute.caster.execute_planned_action(action_to_execute)
				if ACTION_ANIMATION_DURATION > 0: # Simulate animation time
					await get_tree().create_timer(ACTION_ANIMATION_DURATION, false).timeout # process_always = false (respects game pause)
		elif is_instance_valid(action_to_execute.caster):
			print_rich("[color=gray]", action_to_execute.caster.character_name, " was defeated before acting. Action fizzles.[/color]")


func _on_beat_window_timer_timeout(timer: SceneTreeTimer):
	if is_instance_valid(timer): # Disconnect if timer still valid
		timer.timeout.disconnect(Callable(self, "_on_beat_window_timer_timeout"))

	if current_combat_state == CombatState.PAUSED and beat_pause_requested_by_player:
		# Player paused during the window, stay paused. CombatManager.resume_from_beat_pause() will handle next step.
		print_debug("Beat window ended. Game is PAUSED by player request.")
		return

	if current_combat_state == CombatState.BEAT_PAUSE_WINDOW: # If still in window and not paused by player
		print_debug("Beat window timer timeout. Auto-advancing to next AP slot resolution.")
		current_ap_slot_being_resolved += 1
		current_combat_state = CombatState.RESOLVING_SLOT
		resolve_current_ap_slot_actions()

func request_beat_pause():
	if current_combat_state == CombatState.BEAT_PAUSE_WINDOW:
		beat_pause_requested_by_player = true
		current_combat_state = CombatState.PAUSED
		get_tree().paused = true # Pause the entire scene tree (physics, _process)
		print_rich("[color=cyan][b]Combat PAUSED during beat. Press Space to resume planning or another key to unpause normally.[/b][/color]")
		emit_signal("combat_paused", true) # true for is_beat_pause
		return true
	return false

func resume_from_beat_pause_for_replan():
	if current_combat_state == CombatState.PAUSED and beat_pause_requested_by_player:
		get_tree().paused = false
		beat_pause_requested_by_player = false # Reset flag
		print_rich("[color=cyan][b]Resuming to PLANNING from beat pause.[/b][/color]")
		
		# Clear future planned actions for player characters from current_ap_slot_being_resolved + 1
		var next_slot_to_plan_from = current_ap_slot_being_resolved + 1
		for p_char in player_party:
			if is_instance_valid(p_char) and p_char.current_health > 0:
				p_char.clear_planned_actions_from_slot(next_slot_to_plan_from, true) # Refund AP
				if characters_finished_planning_round.has(p_char):
					characters_finished_planning_round.erase(p_char) # Allow them to plan again
		
		current_combat_state = CombatState.PLANNING
		active_player_character_planning_idx = 0 # Start player planning cycle again
		emit_signal("combat_resumed")
		emit_signal("planning_phase_started") # Re-enter planning
		_prompt_next_player_character_to_plan() # Start prompting from the first player char for remaining slots
		return true
	return false

func resume_normally_from_pause(): # Generic unpause if not a replan
	if get_tree().paused:
		get_tree().paused = false
		# Figure out what state to return to.
		# If it was PAUSED due to beat_pause_requested_by_player, but player chose not to replan:
		if beat_pause_requested_by_player: # They unpaused but didn't choose the "replan" option
			beat_pause_requested_by_player = false
			print_rich("[color=cyan][b]Resuming resolution.[/b][/color]")
			current_combat_state = CombatState.RESOLVING_SLOT # Set state to continue resolution
			current_ap_slot_being_resolved += 1 # Move to next slot
			call_deferred("resolve_current_ap_slot_actions") # Resolve next slot
		else: # Generic pause (e.g. main menu)
			# current_combat_state should be restored to what it was before pausing if tracked.
			# For now, assume it might go back to resolving if it was in BEAT_PAUSE_WINDOW or RESOLVING_SLOT
			if current_combat_state == CombatState.BEAT_PAUSE_WINDOW or current_combat_state == CombatState.PAUSED: # Check if it was a general pause during resolution
				print_rich("[color=cyan][b]Combat Resumed (Normal).[/b][/color]")
				current_combat_state = CombatState.RESOLVING_SLOT # Default to trying to resolve
				# If it was paused exactly in BEAT_PAUSE_WINDOW, the timer might have expired.
				# This needs careful state restoration. For now, we'll try to advance.
				current_ap_slot_being_resolved += 1
				call_deferred("resolve_current_ap_slot_actions")

		emit_signal("combat_resumed")
		return true
	return false

func _finish_round_resolution():
	print_rich("[color=lightgreen]>>> All AP Slots Resolved for this Round <<<[/color]")
	emit_signal("all_ap_slots_resolved")
	
	if check_combat_over_conditions():
		# end_combat() handled by check_combat_over_conditions if it returns true
		return
	else:
		current_combat_state = CombatState.ROUND_OVER # Intermediate state before new round
		# Short delay before starting new round or simply call start_new_round()
		# await get_tree().create_timer(0.5, false).timeout
		start_new_round()

func check_combat_over_conditions() -> bool:
	var live_players = 0
	for p_char in player_party:
		if is_instance_valid(p_char) and p_char.current_health > 0:
			live_players += 1
	
	var live_enemies = 0
	for e_char in enemy_party:
		if is_instance_valid(e_char) and e_char.current_health > 0:
			live_enemies += 1

	if live_players == 0 and not player_party.is_empty(): # Check player_party not empty to ensure combat had players
		print_rich("[b][color=red]All player characters defeated! GAME OVER.[/color][/b]")
		end_combat(CombatCharacter.Allegiance.ENEMY)
		return true
	if live_enemies == 0 and not enemy_party.is_empty(): # Check enemy_party not empty
		print_rich("[b][color=green]All enemies defeated! VICTORY![/color][/b]")
		end_combat(CombatCharacter.Allegiance.PLAYER)
		return true
	return false

func _on_character_died(character: CombatCharacter):
	print_rich("[b]", character.character_name, " has died.[/b]")
	# Optional: Immediately check for combat over if a key character dies
	# if check_combat_over_conditions(): return
	# If the character was the one currently planning, need to advance planner
	if character.allegiance == CombatCharacter.Allegiance.PLAYER and \
	   current_combat_state == CombatState.PLANNING and \
	   player_party[active_player_character_planning_idx] == character:
		_prompt_next_player_character_to_plan()


func end_combat(winner_allegiance: CombatCharacter.Allegiance):
	print_rich("[b][color=lightblue]Combat Ended. Winner: ", CombatCharacter.Allegiance.keys()[winner_allegiance], "[/color][/b]")
	current_combat_state = CombatState.IDLE
	# Clean up character signal connections
	var chars_to_unregister = all_characters_in_combat.duplicate()
	for char_node in chars_to_unregister:
		var char = char_node as CombatCharacter
		if is_instance_valid(char):
			unregister_character(char)
	emit_signal("combat_ended", winner_allegiance)

# Replace the get_character_at_world_pos function in your CombatManager.gd with this:

func get_character_at_world_pos(world_pos: Vector2) -> CombatCharacter:
	print("DEBUG: CombatManager looking for character at world pos: ", world_pos)
	
	# Use physics query to find character at position (like the ClickTest showed works)
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsPointQueryParameters2D.new()
	query.position = world_pos
	query.collision_mask = 0xFFFFFFFF  # Check all layers
	
	var results = space_state.intersect_point(query)
	print("DEBUG: Physics query found ", results.size(), " bodies")
	
	for result in results:
		var collider = result.collider
		print("DEBUG: Checking collider: ", collider.name, " (", collider.get_class(), ")")
		
		# Check if this is a CharacterBody2D (the character itself)
		if collider is CombatCharacter:
			print("DEBUG: Found CombatCharacter directly: ", collider.character_name)
			return collider
		
		# Check if this is a ClickArea that belongs to a character
		if collider is Area2D and collider.name == "ClickArea":
			var parent = collider.get_parent()
			if parent is CombatCharacter:
				print("DEBUG: Found CombatCharacter via ClickArea: ", parent.character_name)
				return parent
		
		# Check if the collider's parent is a CombatCharacter (in case of nested collision shapes)
		var parent = collider.get_parent()
		if parent is CombatCharacter:
			print("DEBUG: Found CombatCharacter as parent: ", parent.character_name)
			return parent
	
	print("DEBUG: No CombatCharacter found at world pos: ", world_pos)
	return null
