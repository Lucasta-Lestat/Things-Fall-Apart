# res://Characters/character.gd
extends Node2D 
class_name BattleCharacter

@export var allegiance: AllegianceData.Allegiance = AllegianceData.Allegiance.PLAYER :
	set(value):
		allegiance = value
		if is_inside_tree(): _on_allegiance_changed()

@export var character_name: String = "Character":
	set(value):
		character_name = value
		set_meta("character_name", character_name) # Store for Stats to access
		#if name_label: name_label.text = character_name

@onready var stats_component: Stats = $Stats
@onready var sprite: Sprite2D = $Visuals/Sprite2D # Assuming Sprite2D is under a "Visuals" Node2D
@onready var animation_player: AnimationPlayer = $AnimationPlayer
#@onready var name_label: Label = $UI/NameLabel # Assuming UI elements are under a "UI" Node2D
@onready var health_bar: ProgressBar = $UI/HealthBar
@onready var ap_bar: ProgressBar = $UI/APBar
@onready var action_indicator: Node2D = $ActionIndicator
@onready var line_to_target: Line2D = $ActionIndicator/Line2D
@onready var aoe_preview: Sprite2D = $ActionIndicator/AOEPreview
@onready var action_queue_display: Label = $UI/ActionQueueDisplay
@onready var selection_indicator: Sprite2D = $UI/SelectionIndicator

var planned_actions_for_round: Array[PlannedAction] = []
var current_multi_ap_action_being_executed: PlannedAction = null
var ap_spent_on_current_multi_ap_action: int = 0

signal action_planned_on_char(character, planned_action_obj)
signal actions_cleared_for_char(character)
signal character_defeated(character_node)

var is_selected_for_planning: bool = false:
	set(value):
		is_selected_for_planning = value
		if selection_indicator: # Check if node is valid
			if allegiance == AllegianceData.Allegiance.PLAYER:
				selection_indicator.visible = is_selected_for_planning
			else:
				selection_indicator.visible = false

func _ready():
	set_meta("character_name", character_name) # Ensure meta is set early
	_on_allegiance_changed() 
	
	if stats_component:
		# Connect signals if not already connected (important for instanced scenes)
		if !stats_component.hp_changed.is_connected(_on_stats_hp_changed):
			stats_component.hp_changed.connect(_on_stats_hp_changed)
		if !stats_component.no_hp_left.is_connected(_on_no_hp_left):
			stats_component.no_hp_left.connect(_on_no_hp_left)
		if !stats_component.ap_changed.is_connected(_on_stats_ap_changed):
			stats_component.ap_changed.connect(_on_stats_ap_changed)
		
		# Initial UI updates are handled by stats_component._emit_initial_signals
		# or if stats are already init'd by the time _ready runs for character.
		if stats_component.max_hp != null: # A simple check if stats_component had its _enter_tree
			_on_stats_hp_changed(stats_component.current_hp, stats_component.max_hp)
			_on_stats_ap_changed(stats_component.current_action_points, stats_component.action_points_max_this_round)
		else: # Fallback if signals aren't caught due to timing
			stats_component.stats_initialized.connect(_initial_ui_update_from_stats, CONNECT_ONE_SHOT)


	else:
		printerr("CRITICAL: Stats component not found for ", character_name)

	#if name_label: name_label.text = character_name # Ensure name label is set
	if line_to_target: line_to_target.points = [Vector2.ZERO, Vector2.ZERO]
	update_action_queue_display()
	
	# Add to groups
	add_to_group("all_combatants")


func _initial_ui_update_from_stats():
	if stats_component:
		_on_stats_hp_changed(stats_component.current_hp, stats_component.max_hp)
		_on_stats_ap_changed(stats_component.current_action_points, stats_component.action_points_max_this_round)

func _on_allegiance_changed():
	if selection_indicator:
		selection_indicator.visible = (allegiance == AllegianceData.Allegiance.PLAYER and is_selected_for_planning)

	if is_in_group("player_team_combatants"): remove_from_group("player_team_combatants")
	if is_in_group("enemy_team_combatants"): remove_from_group("enemy_team_combatants")

	if allegiance == AllegianceData.Allegiance.PLAYER or allegiance == AllegianceData.Allegiance.ALLY_AI:
		add_to_group("player_team_combatants")
	elif allegiance == AllegianceData.Allegiance.ENEMY_AI:
		add_to_group("enemy_team_combatants")
	
	#print("%s allegiance set to %s. Groups: %s" % [character_name, AllegianceData.Allegiance.keys()[allegiance], get_groups()])


func _on_stats_hp_changed(p_current_hp: int, p_max_hp: int):
	if health_bar:
		health_bar.max_value = p_max_hp
		health_bar.value = p_current_hp
	if sprite: # Check if sprite is valid
		if p_current_hp <= 0:
			sprite.modulate = Color(0.5, 0.5, 0.5, 0.5)
		# else: # If you want to reset modulate on heal above 0
		#     sprite.modulate = Color.WHITE 

func _on_stats_ap_changed(p_current_ap: int, p_max_ap: int):
	if ap_bar:
		ap_bar.max_value = p_max_ap
		ap_bar.value = p_current_ap

func _on_no_hp_left():
	log_combat_event("%s has been defeated!" % character_name, "DEFEAT")
	# set_process_input(false) # Not used directly by Node2D
	# set_physics_process(false) # Not used
	hide_intent_indicators()
	play_animation("dead")
	character_defeated.emit(self)

func is_defeated() -> bool:
	if !stats_component: return true # Treat as defeated if no stats
	return stats_component.current_hp <= 0

func can_plan_action(action_to_plan: PlannedAction) -> bool:
	var total_ap_cost_of_planned_actions = 0
	for pa in planned_actions_for_round:
		total_ap_cost_of_planned_actions += pa.ap_cost
	
	if !stats_component: return false
	return (total_ap_cost_of_planned_actions + action_to_plan.ap_cost <= stats_component.get_max_ap_this_round())

func plan_action(action_to_plan: PlannedAction) -> bool:
	if !can_plan_action(action_to_plan):
		log_combat_event("Cannot plan action %s for %s: Not enough AP." % [action_to_plan.name, character_name], "WARNING")
		return false
	
	action_to_plan.caster_node = self
	action_to_plan.caster_path = self.get_path()

	planned_actions_for_round.append(action_to_plan)
	action_planned_on_char.emit(self, action_to_plan)
	update_action_queue_display()
	log_combat_event("%s planned: %s (Cost: %d AP). Total planned AP: %d" % [character_name, action_to_plan.name, action_to_plan.ap_cost, get_total_planned_ap_cost()], "PLANNING")
	return true

func clear_planned_actions():
	planned_actions_for_round.clear()
	current_multi_ap_action_being_executed = null 
	ap_spent_on_current_multi_ap_action = 0
	hide_intent_indicators()
	actions_cleared_for_char.emit(self)
	update_action_queue_display()
	log_combat_event("%s cleared all planned actions." % character_name, "PLANNING")

func get_total_planned_ap_cost() -> int:
	var total_ap = 0
	for action in planned_actions_for_round:
		total_ap += action.ap_cost
	return total_ap
	
func update_action_queue_display():
	if !is_instance_valid(action_queue_display): return
	var text = "Planned Actions:\n"
	for pa in planned_actions_for_round:
		text += " (%d AP) %s" % [pa.ap_cost, pa.name]
		if pa.relevant_stat_name and !pa.relevant_stat_name.is_empty():
			text += " (%s)" % pa.relevant_stat_name.capitalize()
		
		var target_info = ""
		if pa.target_node_path and !pa.target_node_path.is_empty():
			var target_node = get_node_or_null(pa.target_node_path)
			if target_node is BattleCharacter:
				target_info = " -> " + target_node.character_name
			else:
				target_info = " -> %s" % pa.target_node_path # Fallback to path
		elif pa.type == PlannedAction.ActionType.MOVE or pa.type == PlannedAction.ActionType.SPELL_FIREBALL:
			target_info = " @ " + str(pa.target_position).replace("(", "").replace(")", "")
		text += target_info + "\n"
	action_queue_display.text = text

func show_intent_move(target_global_pos: Vector2):
	hide_intent_indicators()
	if !line_to_target: return
	line_to_target.default_color = Color.GREEN
	line_to_target.points[0] = Vector2.ZERO 
	line_to_target.points[1] = to_local(target_global_pos) 
	line_to_target.visible = true

func show_intent_attack(target_char_node: Node):
	hide_intent_indicators()
	if !line_to_target: return
	if is_instance_valid(target_char_node):
		line_to_target.default_color = Color.RED
		line_to_target.points[0] = Vector2.ZERO
		line_to_target.points[1] = to_local(target_char_node.global_position)
		line_to_target.visible = true

func show_intent_aoe(center_global_pos: Vector2, radius: float):
	hide_intent_indicators()
	if !aoe_preview: return
	aoe_preview.global_position = center_global_pos 
	if is_instance_valid(aoe_preview.texture):
		var texture_size = aoe_preview.texture.get_size()
		var texture_radius = texture_size.x / 2.0 if texture_size.x > 0 else 1.0 # Avoid div by zero
		var scale_factor = radius / texture_radius
		aoe_preview.scale = Vector2(scale_factor, scale_factor)
	else:
		aoe_preview.scale = Vector2.ONE 
	aoe_preview.visible = true
	
func hide_intent_indicators():
	if line_to_target: line_to_target.visible = false
	if aoe_preview: aoe_preview.visible = false

func play_animation(anim_name: String, custom_speed: float = 1.0, backwards: bool = false):
	if animation_player and animation_player.has_animation(anim_name):
		animation_player.play(anim_name, -1, custom_speed, backwards)
	# else:
		# log_combat_event("Animation '%s' not found for %s" % [anim_name, character_name], "WARNING")

func execute_movement_slice_animation(start_pos: Vector2, target_pos: Vector2, duration: float):
	global_position = start_pos 
	play_animation("move", 1.0 / duration if duration > 0 else 1.0)
	
	var tween = get_tree().create_tween()
	if tween: # Ensure tween is valid
		tween.tween_property(self, "global_position", target_pos, duration).set_trans(Tween.TRANS_LINEAR)
		tween.chain().tween_callback(func(): play_animation("idle"))

func play_attack_animation(target_char: BattleCharacter, attack_outcome: SkillCheck.SkillCheckResult):
	if is_instance_valid(target_char) and sprite:
		var direction_to_target = (target_char.global_position - global_position).normalized()
		if direction_to_target.x < -0.1 and !sprite.flip_h: # Target is to the left
			sprite.flip_h = true
		elif direction_to_target.x > 0.1 and sprite.flip_h: # Target is to the right
			sprite.flip_h = false
	
	play_animation("attack") 
	# log_combat_event("%s animates attack vs %s. Outcome: %s" % [character_name, target_char.character_name if target_char else "target", attack_outcome], "ANIMATION")

func take_damage_from_action(amount: int, attacker: BattleCharacter, is_crit: bool, crit_tier: int):
	if is_defeated(): return
	
	var damage_text = str(amount)
	if is_crit: damage_text = "CRIT! " + damage_text + " (T%d)" % crit_tier
	
	log_combat_event("%s takes %s damage from %s." % [character_name, damage_text, attacker.character_name if attacker else "an action"], "DAMAGE")
	if stats_component: stats_component.take_damage(amount)
	
	# Spawn damage number visual (implementation pending)

	if !is_defeated(): play_animation("hit")

func play_spell_cast_animation(p_slice: ExecutedActionSlice, cast_outcome: SkillCheck.SkillCheckResult):
	# Use specific animation if defined in PlannedAction, else generic "cast"
	var anim_name = "cast"
	if p_slice.original_planned_action.type == PlannedAction.ActionType.SPELL_FIREBALL:
		anim_name = "cast_fireball" # Assuming you have this animation
	elif p_slice.original_planned_action.type == PlannedAction.ActionType.SPELL_HEAL:
		anim_name = "cast_heal"
	play_animation(anim_name)
	# log_combat_event("%s animates casting %s. Outcome: %s" % [character_name, p_slice.original_planned_action.name, cast_outcome], "ANIMATION")

func execute_charge_slice_animation(duration: float):
	play_animation("charge") 
	log_combat_event("%s is charging action..." % character_name, "ANIMATION")

func decide_actions_for_round(player_team_chars: Array[BattleCharacter], enemy_team_chars: Array[BattleCharacter], all_combatants: Array[BattleCharacter]):
	if allegiance != AllegianceData.Allegiance.ENEMY_AI or is_defeated() or (stats_component and stats_component.get_current_ap() == 0):
		return

	clear_planned_actions()
	log_combat_event("--- %s (AI Controlled) deciding actions ---" % character_name, "AI_DEBUG")

	if !stats_component: 
		log_combat_event("%s AI: Missing stats component!" % character_name, "ERROR")
		return

	var available_ap = stats_component.get_max_ap_this_round()
	var current_ap_cost_planned = 0

	var living_player_targets = player_team_chars.filter(
		func(p_char): return is_instance_valid(p_char) and p_char is BattleCharacter and !p_char.is_defeated()
	)

	if living_player_targets.is_empty():
		log_combat_event("%s AI: No living player targets." % character_name, "AI_DEBUG")
		var idle_action = PlannedAction.new_idle_action(self, 1)
		if can_plan_action(idle_action): plan_action(idle_action)
		return

	var target_player = living_player_targets[randi() % living_player_targets.size()] # Attack random living player

	while current_ap_cost_planned < available_ap:
		var attack_ap_cost = 1 
		var base_damage = 8 # Example base weapon damage
		# AI uses Strength for melee attack bonus, Dexterity for the check
		var attack_action = PlannedAction.new_attack_action(
			self, target_player, attack_ap_cost, base_damage,
			"dexterity", "weapon_attack_melee", "strength", false 
		)
		
		if current_ap_cost_planned + attack_action.ap_cost > available_ap: break # Can't afford

		if plan_action(attack_action):
			current_ap_cost_planned += attack_action.ap_cost
			if get_total_planned_ap_cost() == attack_action.ap_cost: # Only show primary intent
				show_intent_attack(target_player)
		else:
			log_combat_event("%s AI: Failed to plan attack for %d AP (already planned %d/%d)." % [character_name, attack_action.ap_cost, current_ap_cost_planned, available_ap], "AI_WARNING")
			break
	
	log_combat_event("%s (AI) finished planning. Total AP in plan: %d" % [character_name, get_total_planned_ap_cost()], "AI_DEBUG")

func prepare_for_new_round(max_ap_for_round: int):
	if stats_component: stats_component.reset_ap_for_new_round(max_ap_for_round)
	clear_planned_actions() 
	current_multi_ap_action_being_executed = null
	ap_spent_on_current_multi_ap_action = 0
	
	if sprite: # Check valid sprite
		if is_defeated(): 
			sprite.modulate = Color(0.5, 0.5, 0.5, 0.5)
			play_animation("dead") 
		else: 
			sprite.modulate = Color.WHITE
			play_animation("idle")

var _combat_manager_ref = null # Cache reference
func log_combat_event(message: String, level: String = "INFO"):
	if !_combat_manager_ref:
		var cm_node = get_tree().get_first_node_in_group("combat_manager_group")
		if cm_node is CombatManager: # Check type
			_combat_manager_ref = cm_node

	if _combat_manager_ref:
		_combat_manager_ref.log_message(message, level)
	# else:
		# print("[%s] %s: %s" % [level, character_name, message])
