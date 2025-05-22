# res://Core/CombatSystem/combat_manager.gd
extends Node
class_name CombatManager

enum CombatState { IDLE, PLANNING, EXECUTING_SLOT, BEAT_PAUSE, PAUSED, ROUND_OVER, COMBAT_ENDED }

var current_combat_state: CombatState = CombatState.IDLE
var current_round: int = 0
var current_ap_slot_being_resolved: int = 0
@export var max_ap_per_round: int = 4

var all_combatants_master_list: Array[BattleCharacter] = []
var active_combatants_list: Array[BattleCharacter] = [] # Updated dynamically

var action_execution_queue_for_current_ap_slot: Array[ExecutedActionSlice] = []

@export var execution_beat_duration: float = 0.5 # Increased slightly
var _beat_timer: Timer
var _pause_input_requested_during_beat: bool = false

signal round_started(round_number)
signal planning_phase_started
signal execution_phase_started
signal ap_slot_resolution_started(ap_slot_index)
signal ap_slot_resolution_ended(ap_slot_index)
signal combat_paused_for_replan
signal combat_resumed_after_replan
signal combat_ended_signal(winning_team_name)
signal combat_log_message(message_text, message_level)

func _ready():
	add_to_group("combat_manager_group") # Add to group for easy access by characters
	_beat_timer = Timer.new()
	_beat_timer.one_shot = true
	_beat_timer.timeout.connect(_on_beat_timer_timeout)
	add_child(_beat_timer)
	
	# It's good practice to wait for the tree to be fully ready
	# await get_tree().process_frame # or await get_tree().idle_frame

func initialize_combat():
	all_combatants_master_list.clear()
	active_combatants_list.clear()
	
	for char_node_unknown in get_tree().get_nodes_in_group("all_combatants"):
		var char_node = char_node_unknown as BattleCharacter
		if is_instance_valid(char_node):
			all_combatants_master_list.append(char_node)
			# Connect character defeated signal if not already connected
			if !char_node.character_defeated.is_connected(_on_character_defeated):
				char_node.character_defeated.connect(_on_character_defeated)
		else:
			printerr("CombatManager: Found non-BattleCharacter or invalid node in 'all_combatants' group: ", char_node_unknown)
	
	# Populate active_combatants_list initially
	_refresh_active_combatants_list()
		
	if all_combatants_master_list.is_empty():
		log_message("CombatManager: No combatants found. Initialization failed.", "ERROR")
		return

	log_message("Combat initialized with %d total combatants. Active: %d" % [all_combatants_master_list.size(), active_combatants_list.size()], "INFO")
	current_combat_state = CombatState.IDLE # Ensure clean start
	current_round = 0 # Reset round counter
	start_new_round()

func _refresh_active_combatants_list():
	active_combatants_list = all_combatants_master_list.filter(
		func(c): return is_instance_valid(c) and !c.is_defeated()
	)

func _on_character_defeated(character_node: BattleCharacter):
	log_message("%s was defeated. Removing from active list." % character_node.character_name, "DEFEAT_EVENT")
	if character_node in active_combatants_list:
		active_combatants_list.erase(character_node)
	# Combat end conditions will be checked at appropriate points (end of slot/round)

func log_message(msg: String, level: String = "INFO"):
	var datetime = Time.get_datetime_dict_from_system()
	var timestamp = "%02d:%02d:%02d" % [datetime.hour, datetime.minute, datetime.second]
	#var timestamp = Time.get_datetime_string_from_system(false, true).split("T")[1] # Get HH:MM:SS
	var formatted_msg = "[%s][%s] %s" % [timestamp, level, msg]
	print(formatted_msg) # Keep console log for debugging
	combat_log_message.emit(msg, level) # For UI

func start_new_round():
	if current_combat_state == CombatState.COMBAT_ENDED: return

	current_round += 1
	log_message("--- Starting Round %d ---" % current_round, "ROUND_EVENT")
	current_ap_slot_being_resolved = 0
	_refresh_active_combatants_list() # Ensure list is up-to-date for new round

	for char_node in all_combatants_master_list: # Reset everyone
		if is_instance_valid(char_node):
			char_node.prepare_for_new_round(max_ap_per_round)

	round_started.emit(current_round)
	enter_planning_phase()

func enter_planning_phase():
	if current_combat_state == CombatState.COMBAT_ENDED: return
	log_message("Entering Planning Phase for Round %d." % current_round, "PHASE_CHANGE")
	current_combat_state = CombatState.PLANNING
	planning_phase_started.emit()

	var player_team_nodes = get_tree().get_nodes_in_group("player_team_combatants")
	var enemy_team_nodes = get_tree().get_nodes_in_group("enemy_team_combatants")

	for char_node in active_combatants_list:
		if char_node.allegiance == AllegianceData.Allegiance.ENEMY_AI:
			char_node.decide_actions_for_round(player_team_nodes, enemy_team_nodes, active_combatants_list)
	
	log_message("AI planning complete. Player can now plan.", "INFO")

func player_confirms_plans():
	if current_combat_state != CombatState.PLANNING:
		log_message("Error: Cannot confirm plans, not in Planning state.", "ERROR")
		return
	
	log_message("Player has confirmed plans. Starting Execution Phase.", "PHASE_CHANGE")
	current_combat_state = CombatState.EXECUTING_SLOT
	current_ap_slot_being_resolved = 0
	execution_phase_started.emit()
	_resolve_current_ap_slot()

func _resolve_current_ap_slot():
	if current_combat_state == CombatState.COMBAT_ENDED: return
	if current_ap_slot_being_resolved >= max_ap_per_round:
		log_message("All AP slots for Round %d resolved." % current_round, "ROUND_EVENT")
		_end_round_processing()
		return

	current_combat_state = CombatState.EXECUTING_SLOT
	log_message("\n--- Resolving AP Slot %d (Round %d) ---" % [current_ap_slot_being_resolved + 1, current_round], "SLOT_EVENT")
	ap_slot_resolution_started.emit(current_ap_slot_being_resolved)
	
	action_execution_queue_for_current_ap_slot.clear()

	for char_node in active_combatants_list:
		if !is_instance_valid(char_node.stats_component): # Critical check
			log_message("CRITICAL: %s missing StatsComponent in _resolve_current_ap_slot. Skipping." % char_node.character_name, "ERROR")
			continue

		var ap_spent_by_char_this_round_execution = char_node.stats_component.get_max_ap_this_round() - char_node.stats_component.get_current_ap()
		
		if is_instance_valid(char_node.current_multi_ap_action_being_executed):
			var ongoing_action = char_node.current_multi_ap_action_being_executed
			char_node.ap_spent_on_current_multi_ap_action += 1
			
			var slice = ExecutedActionSlice.new(ongoing_action, current_ap_slot_being_resolved, 
												char_node.stats_component.dexterity, char_node.global_position)
			
			if char_node.ap_spent_on_current_multi_ap_action < ongoing_action.ap_cost:
				slice.is_charging_this_slice = true
			else: 
				_populate_slice_details_for_action_attempt(slice, ongoing_action)
				char_node.current_multi_ap_action_being_executed = null
				char_node.ap_spent_on_current_multi_ap_action = 0
			
			action_execution_queue_for_current_ap_slot.append(slice)
			char_node.stats_component.use_ap(1) # Actual AP cost
			continue

		if ap_spent_by_char_this_round_execution == current_ap_slot_being_resolved:
			var next_planned_action = _get_next_planned_action_for_char(char_node, ap_spent_by_char_this_round_execution)
			if is_instance_valid(next_planned_action):
				if char_node.stats_component.get_current_ap() <= 0:
					log_message("Warning: %s has no AP to start action %s in slot %d." % [char_node.character_name, next_planned_action.name, current_ap_slot_being_resolved + 1], "WARNING")
					continue

				var slice = ExecutedActionSlice.new(next_planned_action, current_ap_slot_being_resolved,
													char_node.stats_component.dexterity, char_node.global_position)
				
				if next_planned_action.ap_cost > 1:
					char_node.current_multi_ap_action_being_executed = next_planned_action
					char_node.ap_spent_on_current_multi_ap_action = 1
					slice.is_charging_this_slice = true
				else:
					_populate_slice_details_for_action_attempt(slice, next_planned_action)
				
				action_execution_queue_for_current_ap_slot.append(slice)
				char_node.stats_component.use_ap(1)
			elif char_node.stats_component.get_current_ap() > 0 : 
				var idle_action = PlannedAction.new_idle_action(char_node, 1)
				var idle_slice = ExecutedActionSlice.new(idle_action, current_ap_slot_being_resolved,
														char_node.stats_component.dexterity, char_node.global_position)
				_populate_slice_details_for_action_attempt(idle_slice, idle_action)
				action_execution_queue_for_current_ap_slot.append(idle_slice)
				char_node.stats_component.use_ap(1)
				log_message("%s is idle in AP slot %d." % [char_node.character_name, current_ap_slot_being_resolved + 1], "DEBUG")

	action_execution_queue_for_current_ap_slot.sort_custom(
		func(a, b): 
			if !is_instance_valid(a.caster) or !is_instance_valid(b.caster): return false # Safety
			if !is_instance_valid(a.caster.stats_component) or !is_instance_valid(b.caster.stats_component): return false
			return a.caster.stats_component.dexterity > b.caster.stats_component.dexterity
	)
	# Log sorted queue (optional, can be verbose)

	for exec_slice in action_execution_queue_for_current_ap_slot:
		var caster = exec_slice.caster
		var planned_action = exec_slice.original_planned_action

		if !is_instance_valid(caster) or !is_instance_valid(caster.stats_component) or caster.is_defeated() and not exec_slice.is_charging_this_slice : # Allow charging if defeated
			# log_message("LOGIC: %s cannot act (defeated/invalid)." % (caster.character_name if is_instance_valid(caster) else "UnknownChar"), "DEBUG")
			exec_slice.is_resolved_logically = true; continue

		log_message("LOGIC: %s (Dex %d) attempts '%s'." % [caster.character_name, caster.stats_component.dexterity, planned_action.name], "ACTION_ATTEMPT")
		
		exec_slice.skill_check_outcome = null

		if exec_slice.is_charging_this_slice:
			log_message("  %s is charging." % caster.character_name, "ACTION_DETAIL")
		
		elif planned_action.type == PlannedAction.ActionType.MOVE:
			caster.global_position = exec_slice.movement_target_this_slice
			log_message("  %s logically moved to %s" % [caster.character_name, caster.global_position.round()], "ACTION_DETAIL")

		elif planned_action.type == PlannedAction.ActionType.ATTACK:
			var target_char = planned_action.get_target_node(self) # Resolve target
			exec_slice.attack_target_node_this_slice = target_char # Store for animation
			if is_instance_valid(target_char) and !target_char.is_defeated():
				var skill_res = SkillCheck.perform_check(
					caster.stats_component.get_stat_value(planned_action.relevant_stat_name),
					caster.stats_component.traits, planned_action.action_domain, planned_action.is_piercing_damage
				)
				exec_slice.skill_check_outcome = skill_res
				log_message("  %s vs %s: %s" % [caster.character_name, target_char.character_name, skill_res], "ACTION_RESULT")

				if skill_res.success:
					var dmg_bonus = caster.stats_component.get_damage_bonus(planned_action.damage_bonus_stat)
					var total_base_dmg = planned_action.base_damage + dmg_bonus
					var final_dmg = int(round(total_base_dmg * skill_res.damage_multiplier))
					exec_slice.calculated_damage_this_slice = final_dmg
					
					log_message("    Dmg: Base(%d)+Bonus(%d)=%d. Mult(x%.1f). Final: %d" % [planned_action.base_damage, dmg_bonus, total_base_dmg, skill_res.damage_multiplier, final_dmg], "COMBAT_MATH")
					target_char.take_damage_from_action(final_dmg, caster, skill_res.is_critical_hit, skill_res.critical_hit_tier)
					# _on_character_defeated is signaled by character if HP hits 0
				# else handle miss/crit fail messages if needed (SkillCheckResult string does some of this)
			else:
				log_message("  Attack target %s is invalid or defeated." % (target_char.character_name if target_char else planned_action.target_node_path), "WARNING")

		elif planned_action.type == PlannedAction.ActionType.SPELL_FIREBALL:
			var skill_res = SkillCheck.perform_check(
				caster.stats_component.get_stat_value(planned_action.relevant_stat_name),
				caster.stats_component.traits, planned_action.action_domain
			)
			exec_slice.skill_check_outcome = skill_res
			log_message("  %s casts Fireball: %s" % [caster.character_name, skill_res], "ACTION_RESULT")

			if skill_res.success:
				var dmg_bonus = caster.stats_component.get_damage_bonus(planned_action.damage_bonus_stat)
				var total_base_dmg = planned_action.base_damage + dmg_bonus
				var final_dmg_target = int(round(total_base_dmg * skill_res.damage_multiplier))
				exec_slice.calculated_damage_this_slice = final_dmg_target # Damage per target

				log_message("    Fireball Dmg/Target: Base(%d)+Bonus(%d)=%d. Mult(x%.1f). Final: %d" % [planned_action.base_damage, dmg_bonus, total_base_dmg, skill_res.damage_multiplier, final_dmg_target], "COMBAT_MATH")
				
				var affected = find_characters_in_aoe(planned_action.target_position, planned_action.aoe_radius, active_combatants_list)
				log_message("    Fireball AOE hits: %s" % str(affected.map(func(c): return c.character_name)), "ACTION_DETAIL")
				for target_in_aoe in affected:
					if target_in_aoe != caster or planned_action.spell_effect_details.get("can_hit_caster", false): # Example for self-hit flag
						target_in_aoe.take_damage_from_action(final_dmg_target, caster, skill_res.is_critical_hit, skill_res.critical_hit_tier)
			# else handle fizzle message if needed

		elif planned_action.type == PlannedAction.ActionType.SPELL_HEAL:
			var target_char = planned_action.get_target_node(self)
			exec_slice.attack_target_node_this_slice = target_char # Used by animation for target
			if is_instance_valid(target_char): # Can heal anyone, even "defeated" if game allows revives
				var skill_res = SkillCheck.perform_check(
					caster.stats_component.get_stat_value(planned_action.relevant_stat_name),
					caster.stats_component.traits, planned_action.action_domain
				)
				exec_slice.skill_check_outcome = skill_res
				log_message("  %s casts Heal on %s: %s" % [caster.character_name, target_char.character_name, skill_res], "ACTION_RESULT")

				if skill_res.success:
					var heal_bonus = caster.stats_component.get_damage_bonus(planned_action.damage_bonus_stat)
					var total_base_heal = planned_action.base_heal + heal_bonus
					var final_heal = int(round(total_base_heal * skill_res.damage_multiplier)) # Heal crits use damage_multiplier
					exec_slice.calculated_heal_this_slice = final_heal

					log_message("    Heal: Base(%d)+Bonus(%d)=%d. Mult(x%.1f). Final: %d" % [planned_action.base_heal, heal_bonus, total_base_heal, skill_res.damage_multiplier, final_heal], "COMBAT_MATH")
					target_char.stats_component.heal(final_heal)
					# If healing revives, need logic here or in Stats to reset defeated state
					if target_char.is_defeated() and target_char.stats_component.current_hp > 0:
						_revive_character(target_char)


		exec_slice.is_resolved_logically = true
		if _check_and_process_combat_end_conditions(): return # Stop if combat ended mid-slot

	_play_animations_for_ap_slot_and_start_beat() # Async

func _revive_character(char_node: BattleCharacter):
	log_message("%s has been revived!" % char_node.character_name, "REVIVE_EVENT")
	# Reset defeated visual state
	if is_instance_valid(char_node.sprite): char_node.sprite.modulate = Color.WHITE
	char_node.play_animation("idle") # Or a specific "get_up" animation
	# Add back to active_combatants_list if not already (should be handled by _refresh_active_combatants_list at round start)
	if not char_node in active_combatants_list:
		active_combatants_list.append(char_node)


func _get_next_planned_action_for_char(char_node: BattleCharacter, current_ap_spent_by_char_in_exec: int) -> PlannedAction:
	var ap_cost_sum_of_plan = 0
	for pa_idx in range(char_node.planned_actions_for_round.size()):
		var pa = char_node.planned_actions_for_round[pa_idx]
		if ap_cost_sum_of_plan == current_ap_spent_by_char_in_exec:
			# Resolve caster/target NODES on the PlannedAction resource itself before returning
			# This ensures the nodes are readily available when ExecutedActionSlice is made
			pa.caster_node = pa.get_caster_node(self) # self is CombatManager, can resolve paths globally
			if !pa.target_node_path.is_empty():
				pa.target_node = pa.get_target_node(self)
			return pa
		ap_cost_sum_of_plan += pa.ap_cost
	return null

func _populate_slice_details_for_action_attempt(slice_to_populate: ExecutedActionSlice, source_planned_action: PlannedAction):
	slice_to_populate.original_planned_action = source_planned_action # Already set in ExecutedActionSlice._init
	
	match source_planned_action.type:
		PlannedAction.ActionType.IDLE: slice_to_populate.animation_to_play = "idle"
		PlannedAction.ActionType.MOVE:
			slice_to_populate.movement_target_this_slice = source_planned_action.target_position
			slice_to_populate.animation_to_play = "move"
		PlannedAction.ActionType.ATTACK:
			slice_to_populate.attack_target_node_this_slice = source_planned_action.get_target_node(self) # Ensure target node is resolved
			slice_to_populate.animation_to_play = "attack"
		PlannedAction.ActionType.SPELL_FIREBALL: slice_to_populate.animation_to_play = "cast_fireball"
		PlannedAction.ActionType.SPELL_HEAL:
			slice_to_populate.attack_target_node_this_slice = source_planned_action.get_target_node(self) # For animation target
			slice_to_populate.animation_to_play = "cast_heal"

func find_characters_in_aoe(aoe_center: Vector2, radius: float, list_to_check: Array) -> Array[BattleCharacter]:
	var chars_in_aoe: Array[BattleCharacter] = []
	for c_unknown in list_to_check:
		var c = c_unknown as BattleCharacter
		if is_instance_valid(c) and !c.is_defeated(): # Check !c.is_defeated() here
			if c.global_position.distance_squared_to(aoe_center) <= radius * radius: # Use distance_squared_to for perf
				chars_in_aoe.append(c)
	return chars_in_aoe

func _play_animations_for_ap_slot_and_start_beat():
	log_message("  Playing animations for AP Slot %d..." % (current_ap_slot_being_resolved + 1), "ANIM_PHASE")
	var actual_anims_played = false
	var longest_anim_duration = 0.5 # Default beat duration if no specific anims dictate longer

	for exec_slice in action_execution_queue_for_current_ap_slot:
		if !exec_slice.is_resolved_logically: continue
		var char_node = exec_slice.caster
		if !is_instance_valid(char_node): continue

		if char_node.is_defeated() and !exec_slice.is_charging_this_slice and exec_slice.original_planned_action.type != PlannedAction.ActionType.SPELL_HEAL: # Allow heal animation on defeated target
			# log_message("    ANIM: Skipping for defeated %s." % char_node.character_name, "ANIM_DEBUG")
			continue

		actual_anims_played = true
		var planned_action = exec_slice.original_planned_action # Convenience

		if exec_slice.is_charging_this_slice:
			char_node.call_deferred("execute_charge_slice_animation", execution_beat_duration)
		elif planned_action.type == PlannedAction.ActionType.MOVE:
			char_node.call_deferred("execute_movement_slice_animation", exec_slice.caster_original_pos_for_slice, exec_slice.movement_target_this_slice, execution_beat_duration)
		elif planned_action.type == PlannedAction.ActionType.ATTACK:
			char_node.call_deferred("play_attack_animation", exec_slice.attack_target_node_this_slice, exec_slice.skill_check_outcome)
		elif planned_action.type == PlannedAction.ActionType.SPELL_FIREBALL or planned_action.type == PlannedAction.ActionType.SPELL_HEAL:
			char_node.call_deferred("play_spell_cast_animation", exec_slice, exec_slice.skill_check_outcome)
			if planned_action.type == PlannedAction.ActionType.SPELL_FIREBALL and exec_slice.skill_check_outcome and exec_slice.skill_check_outcome.success:
				_spawn_aoe_visual_effect(planned_action.target_position, planned_action.aoe_radius, "fireball_explosion") # Placeholder
		elif planned_action.type == PlannedAction.ActionType.IDLE:
			char_node.call_deferred("play_animation", "idle")
	
	var wait_duration = execution_beat_duration # Default beat duration
	if actual_anims_played:
		# If specific animations have known durations, could use max of those.
		# For now, fixed beat duration works.
		pass 
	
	if wait_duration > 0: await get_tree().create_timer(wait_duration + 0.1).timeout # Small buffer
	else: await get_tree().process_frame # Min wait if no anims/zero duration

	ap_slot_resolution_ended.emit(current_ap_slot_being_resolved)
	if _check_and_process_combat_end_conditions(): return

	current_combat_state = CombatState.BEAT_PAUSE
	_pause_input_requested_during_beat = false
	log_message("  AP Slot %d resolution complete. Beat active (%.2fs). Press Space to pause." % [current_ap_slot_being_resolved + 1, execution_beat_duration], "INFO")
	if _beat_timer: _beat_timer.start(execution_beat_duration)

func _spawn_aoe_visual_effect(global_pos: Vector2, radius: float, effect_name: String):
	log_message("SPAWN_EFFECT: %s at %s, radius %.1f" % [effect_name, global_pos.round(), radius], "EFFECT")
	# Example: var effect_instance = load("res://Effects/FireballExplosionEffect.tscn").instantiate()
	# get_tree().current_scene.add_child(effect_instance) # Or a dedicated effects layer
	# effect_instance.global_position = global_pos
	# effect_instance.set_radius(radius) # Custom method on effect scene to scale/configure
	# effect_instance.play()

func _on_beat_timer_timeout():
	if current_combat_state != CombatState.BEAT_PAUSE: return
	if _pause_input_requested_during_beat:
		_pause_input_requested_during_beat = false
		_enter_pause_for_replan_state()
	else:
		current_ap_slot_being_resolved += 1
		_resolve_current_ap_slot()

func _enter_pause_for_replan_state():
	if current_combat_state == CombatState.COMBAT_ENDED: return
	current_combat_state = CombatState.PAUSED
	log_message("Combat Paused. Player can re-plan remaining actions.", "PHASE_CHANGE")
	combat_paused_for_replan.emit()
	# UI needs to handle re-planning for player characters:
	# - For each player char, find AP already committed to actions in slots <= current_ap_slot_being_resolved.
	# - AP available for re-planning for future slots: char.stats.current_action_points.
	# - Allow clearing planned_actions from the point of (current_ap_slot_being_resolved + 1) onwards.
	# - Player re-plans using their remaining char.stats.current_action_points.

func player_resumes_after_replan():
	if current_combat_state != CombatState.PAUSED: return
	log_message("Player has re-planned. Resuming combat execution.", "PHASE_CHANGE")
	current_combat_state = CombatState.EXECUTING_SLOT
	combat_resumed_after_replan.emit()
	current_ap_slot_being_resolved += 1 # Move to next slot AFTER pause
	_resolve_current_ap_slot()

func _unhandled_input(event: InputEvent):
	if current_combat_state == CombatState.BEAT_PAUSE and event.is_action_pressed("ui_accept") and !event.is_echo():
		if get_viewport().gui_get_focus_owner() is LineEdit or get_viewport().gui_get_focus_owner() is TextEdit: return # Don't steal from text input

		get_viewport().set_input_as_handled()
		_pause_input_requested_during_beat = true
		if _beat_timer and !_beat_timer.is_stopped(): _beat_timer.stop()
		_on_beat_timer_timeout() 
			
	elif current_combat_state == CombatState.PAUSED and event.is_action_pressed("ui_accept") and !event.is_echo():
		if get_viewport().gui_get_focus_owner() is LineEdit or get_viewport().gui_get_focus_owner() is TextEdit: return

		get_viewport().set_input_as_handled()
		player_resumes_after_replan()

func _end_round_processing():
	current_combat_state = CombatState.ROUND_OVER
	log_message("--- Round %d Ended ---" % current_round, "ROUND_EVENT")
	if _check_and_process_combat_end_conditions(): return
	# Delay before starting new round if needed, e.g., for round summary UI
	# await get_tree().create_timer(1.0).timeout 
	start_new_round()

func _check_and_process_combat_end_conditions() -> bool:
	var alive_players = 0
	for p_char_node_unknown in get_tree().get_nodes_in_group("player_team_combatants"):
		var p_char_node = p_char_node_unknown as BattleCharacter
		if is_instance_valid(p_char_node) and !p_char_node.is_defeated():
			alive_players += 1
	
	var alive_enemies = 0
	for e_char_node_unknown in get_tree().get_nodes_in_group("enemy_team_combatants"):
		var e_char_node = e_char_node_unknown as BattleCharacter
		if is_instance_valid(e_char_node) and !e_char_node.is_defeated():
			alive_enemies += 1

	var game_over = false
	var winner = "Draw"

	if alive_players == 0 and active_combatants_list.size() > 0: # Check active_combatants to ensure it's not a pre-combat check
		winner = "Enemies"
		game_over = true
	elif alive_enemies == 0 and active_combatants_list.size() > 0:
		winner = "Players"
		game_over = true
	elif alive_players == 0 and alive_enemies == 0 and all_combatants_master_list.size() > 0: # Check master list for initial combatants
		 # This handles mutual destruction if active_combatants_list became empty
		winner = "Draw" 
		game_over = true
	
	if game_over:
		current_combat_state = CombatState.COMBAT_ENDED
		log_message("--- COMBAT ENDED! Winner: %s ---" % winner, "GAME_EVENT")
		combat_ended_signal.emit(winner)
		return true
	return false
