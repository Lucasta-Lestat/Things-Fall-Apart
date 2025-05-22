# res://Scenes/CombatScene.gd (Attach to CombatScene root node)
extends Node

@onready var combat_manager: CombatManager = $CombatManager
@onready var confirm_plans_button: Button = $CombatUI/ConfirmPlansButton
@onready var resume_button: Button = $CombatUI/ResumeButton
@onready var combat_log_display: RichTextLabel = $CombatUI/CombatLogDisplay

# Player character selection for planning (simple example)
var selected_player_character: BattleCharacter = null

func _ready():
	confirm_plans_button.pressed.connect(_on_confirm_plans_pressed)
	resume_button.pressed.connect(_on_resume_button_pressed)
	
	if combat_manager:
		combat_manager.planning_phase_started.connect(_on_planning_phase_started)
		combat_manager.execution_phase_started.connect(_on_execution_phase_started)
		combat_manager.combat_paused_for_replan.connect(_on_combat_paused_for_replan)
		combat_manager.combat_resumed_after_replan.connect(_on_combat_resumed_after_replan)
		combat_manager.combat_log_message.connect(_on_combat_log_message)
		combat_manager.combat_ended_signal.connect(_on_combat_ended)

		# Wait a frame for all nodes to be ready, then initialize
		await get_tree().process_frame 
		combat_manager.initialize_combat()
	else:
		printerr("CombatScene: CombatManager node not found!")

	# Simple way to allow selecting player characters for planning
	# This would be replaced by a more robust UI for action selection
	var player_chars = get_tree().get_nodes_in_group("player_team_combatants")
	if !player_chars.is_empty():
		select_character_for_planning(player_chars[0])


func _input(event: InputEvent):
	if combat_manager.current_combat_state == CombatManager.CombatState.PLANNING or combat_manager.current_combat_state == CombatManager.CombatState.PAUSED:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.is_pressed():
			# Get mouse position in viewport coordinates
			var viewport_mouse_pos = get_viewport().get_mouse_position()

			# To interact with 2D physics objects, we need the world_2d from the viewport
			var world_2d = get_viewport().world_2d
			if !world_2d: # Should always exist in a 2D context
				printerr("CombatScene: No World2D found in viewport!")
				return

			var space_state = world_2d.direct_space_state
			if !space_state: # Should generally exist if world_2d exists
				printerr("CombatScene: No DirectSpaceState found in World2D!")
				return

			# For point intersection, we need to convert viewport mouse coordinates
			# to global 2D world coordinates if there's a camera transforming the view.
			# If your CombatScene is simple and directly viewed, viewport_mouse_pos might be okay,
			# but it's safer to use the camera's transformation.
			# Assuming you have a Camera2D in your scene (e.g., as a child of CombatScene or a global camera)
			# If not, viewport_mouse_pos can be used directly FOR THE RAYCAST ORIGIN if the camera isn't moving/zooming.
			# However, the PhysicsRayQueryParameters2D expects global coordinates.

			var camera = get_viewport().get_camera_2d() # Get the active 2D camera
			var global_mouse_position: Vector2
			if camera:
				global_mouse_position = camera.get_global_mouse_position() # This is the correct way if a camera exists
			else:
				# Fallback if no camera explicitly set, assuming 1:1 mapping for the query.
				# This might be inaccurate if the view is transformed by anything other than a Camera2D.
				global_mouse_position = viewport_mouse_pos


			var query = PhysicsRayQueryParameters2D.create(global_mouse_position, global_mouse_position)
			query.collide_with_areas = true
			query.collision_mask = 1 # Assuming your characters' Area2Ds are on collision layer 1
									 # Adjust if you use different layers.
			
			var results = space_state.intersect_point(query, 1)
			
			if !results.is_empty():
				var clicked_collider = results[0].get("collider") # Get the collider object
				if clicked_collider is Area2D:
					var clicked_node = clicked_collider.get_parent() # Assuming Area2D is direct child of Character
					if clicked_node is BattleCharacter:
						if clicked_node.allegiance == AllegianceData.Allegiance.PLAYER:
							select_character_for_planning(clicked_node)
						elif selected_player_character and clicked_node.allegiance == AllegianceData.Allegiance.ENEMY_AI:
							var attack_action = PlannedAction.new_attack_action(selected_player_character, clicked_node, 1, 10, "dexterity", "weapon_attack_melee", "strength")
							selected_player_character.plan_action(attack_action)
			else:
				if selected_player_character:
					var move_action = PlannedAction.new_move_action(selected_player_character, global_mouse_position, 1) # Use global_mouse_position for move target
					selected_player_character.plan_action(move_action)
		
		if event.is_action_pressed("ui_cancel") and selected_player_character:
			selected_player_character.clear_planned_actions()


func select_character_for_planning(character_node: BattleCharacter):
	if selected_player_character:
		selected_player_character.is_selected_for_planning = false
	selected_player_character = character_node
	if selected_player_character:
		selected_player_character.is_selected_for_planning = true
		print("Selected for planning: ", selected_player_character.character_name)


func _on_confirm_plans_pressed():
	if combat_manager: combat_manager.player_confirms_plans()

func _on_resume_button_pressed():
	if combat_manager: combat_manager.player_resumes_after_replan()

func _on_planning_phase_started():
	confirm_plans_button.visible = true
	resume_button.visible = false
	# Enable player action planning UI here

func _on_execution_phase_started():
	confirm_plans_button.visible = false
	resume_button.visible = false
	# Disable player action planning UI

func _on_combat_paused_for_replan():
	confirm_plans_button.visible = false # Or change to "Modify Plans"
	resume_button.visible = true
	# Enable limited re-planning UI

func _on_combat_resumed_after_replan():
	confirm_plans_button.visible = false
	resume_button.visible = false
	# Disable re-planning UI

func _on_combat_log_message(message: String, level: String):
	var color_tag = ""
	match level.to_lower():
		"error": color_tag = "[color=red]"
		"warning": color_tag = "[color=orange]"
		"action_result", "combat_math": color_tag = "[color=lightblue]"
		"action_attempt", "action_detail": color_tag = "[color=lightgray]"
		"round_event", "phase_change", "slot_event": color_tag = "[color=yellow]"
		"game_event", "defeat_event", "revive_event": color_tag = "[color=lightgreen]"
		"ai_debug", "planning": color_tag = "[color=violet]"
		"damage": color_tag = "[color=orangered]"
		"debug", "anim_phase", "anim_debug", "effect": color_tag = "[color=gray]"
		_: color_tag = "[color=white]" # Default for INFO etc.
	
	combat_log_display.append_text(color_tag + message + "[/color]\n")

func _on_combat_ended(winner_name: String):
	confirm_plans_button.visible = false
	resume_button.visible = false
	# Show game over screen/message
	var result_label = Label.new()
	result_label.text = "Combat Over! Winner: " + winner_name
	result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	result_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	result_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	$CombatUI.add_child(result_label) # Add to UI layer
