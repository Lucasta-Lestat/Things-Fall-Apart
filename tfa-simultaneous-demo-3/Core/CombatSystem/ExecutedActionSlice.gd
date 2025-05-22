# res://Core/CombatSystem/executed_action_slice.gd
class_name ExecutedActionSlice

var original_planned_action: PlannedAction 
var caster: BattleCharacter 
var caster_dexterity: int
var caster_original_pos_for_slice: Vector2 
var ap_slot_index: int 

var skill_check_outcome: SkillCheck.SkillCheckResult = null 
var calculated_damage_this_slice: int = 0
var calculated_heal_this_slice: int = 0

var movement_target_this_slice: Vector2 = Vector2.ZERO 
var attack_target_node_this_slice: BattleCharacter = null # For direct animation call

var is_charging_this_slice: bool = false 
var animation_to_play: String = "" # Can be derived from planned_action.type

var is_resolved_logically: bool = false

func _init(p_planned_action: PlannedAction, p_ap_slot: int, p_caster_dex: int, p_caster_start_pos: Vector2):
	self.original_planned_action = p_planned_action
	
	if p_planned_action.caster_node is BattleCharacter:
		self.caster = p_planned_action.caster_node 
	elif is_instance_valid(p_planned_action.caster_path): # Fallback if node isn't set directly
		# This assumes ExecutedActionSlice is created in a context where get_node can resolve caster_path
		# Typically, CombatManager would resolve it before creating the slice.
		# For safety, ensure caster_node on PlannedAction is resolved first.
		var resolved_caster = p_planned_action.get_caster_node(Engine.get_main_loop().root) # Risky, better if CM resolves
		if resolved_caster is BattleCharacter:
			self.caster = resolved_caster
		else:
			printerr("ExecutedActionSlice: Caster path %s did not resolve to BattleCharacter!" % p_planned_action.caster_path)
			self.caster = null
	else:
		printerr("ExecutedActionSlice: Caster is not a BattleCharacter and no valid path!")
		self.caster = null # Or handle error appropriately

	self.caster_dexterity = p_caster_dex
	self.ap_slot_index = p_ap_slot
	self.caster_original_pos_for_slice = p_caster_start_pos
