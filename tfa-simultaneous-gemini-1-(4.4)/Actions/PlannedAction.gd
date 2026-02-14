# res://Actions/PlannedAction.gd
extends Resource
class_name PlannedAction

enum ActionType { WAIT, MOVE, USE_ABILITY }

@export var action_type: ActionType = ActionType.WAIT
var caster: CombatCharacter
@export var ability_id: StringName # If USE_ABILITY, the ID of the Ability resource
var target_character: CombatCharacter
@export var target_position: Vector2
@export var dex_snapshot: int = 0 # Caster's dexterity when action was planned

# For multi-AP abilities
@export var is_multi_ap_charge_segment: bool = false # Is this a segment just for charging?
@export var multi_ap_ability_id: StringName # The ID of the root ability being charged/executed
@export var total_ap_cost_for_ability: int = 1 # Total AP for the multi-AP ability
@export var ap_spent_on_charge: int = 0 # How many APs spent charging (on the root action)
@export var is_final_segment_of_multi_ap: bool = false # Is this the segment that executes the ability?
@export var is_part_of_resolved_multi_ap: bool = false # True for charge segments after root executed

func _init(p_caster: CombatCharacter = null, p_action_type: ActionType = ActionType.WAIT, p_dex: int = 0):
	caster = p_caster
	action_type = p_action_type
	if caster:
		dex_snapshot = caster.dexterity
	else:
		dex_snapshot = p_dex

func is_fully_charged() -> bool:
	if not is_multi_ap_charge_segment and not is_final_segment_of_multi_ap : return true # Not a multi-AP action or already the exec part
	return ap_spent_on_charge >= total_ap_cost_for_ability


func get_action_description() -> String:
	var caster_name = caster.character_name if is_instance_valid(caster) else "N/A"
	var details = ""
	match action_type:
		ActionType.MOVE: details = "Move to %s" % str(target_position.round())
		ActionType.USE_ABILITY:
			details = "Use '%s'" % ability_id
			if is_instance_valid(target_character): details += " on %s" % target_character.character_name
			elif target_position != Vector2.ZERO: details += " at %s" % str(target_position.round())
			if is_multi_ap_charge_segment: details += " (Charging %d/%d)" % [ap_spent_on_charge, total_ap_cost_for_ability]
			if is_final_segment_of_multi_ap: details += " (Final Segment)"
		ActionType.WAIT: details = "Wait"
	return "Action(%s by %s, Dex:%d, %s)" % [ActionType.keys()[action_type], caster_name, dex_snapshot, details]
