# res://Core/CombatSystem/Reaction.gd
# Defines a reaction a character can perform.
extends Resource
class_name Reaction

enum ReactionEffectType {
	CAST_SPELL,         # Casts a specific spell
	MODIFY_DAMAGE,      # Modifies incoming damage (e.g., percentage reduction, flat reduction)
	ATTEMPT_LEARN_SPELL # Attempts to learn the triggering spell
	# Add more types as needed (e.g., GAIN_STATUS_EFFECT, INTERRUPT_ACTION)
}

@export var reaction_name: String = "Reaction"
@export_multiline var description: String = "A reactive ability."
@export var icon: Texture2D = null

@export_group("Trigger Conditions")
# Traits the *triggering action* must have (at least one from this list)
@export var triggering_action_tags_any_of: Array[String] = []
# Types of the *triggering action* (e.g., ATTACK, SPELL_FIREBALL) (at least one)
@export var triggering_action_types_any_of: Array[PlannedAction.ActionType] = []
# Is the character performing this reaction the direct target of the triggering action?
@export var must_be_target: bool = false
# Is the character performing this reaction *NOT* the target?
@export var must_not_be_target: bool = false
# Allegiance of the caster of the triggering action (e.g., only react to ENEMY_AI)
@export var triggering_caster_allegiance: Array[AllegianceData.Allegiance] = [] # Empty means any allegiance

@export_group("Costs")
@export var reaction_point_cost: int = 1
# Add other costs like AP, Mana if reactions can consume them

@export_group("Effect")
@export var effect_type: ReactionEffectType = ReactionEffectType.CAST_SPELL
@export var effect_details: Dictionary = {}
# Examples for effect_details:
# For CAST_SPELL: {"spell_resource_path": "res://Spells/MyShieldSpell.tres"}
# For MODIFY_DAMAGE: {"percentage_reduction": 0.5, "flat_reduction": 10, "damage_type_filter": ["fire"]}
# For ATTEMPT_LEARN_SPELL: {"required_class_trait_for_spell": "Arcane", "success_message": "Learned %s!", "fail_message": "Failed to learn %s."}

@export_group("UI")
@export var confirmation_prompt: String = "Use %s?" # %s will be reaction_name

# Method to check if this reaction is triggered by a given action against a specific character
func can_trigger(potential_reactor: BattleCharacter, triggering_action: PlannedAction, triggering_caster: BattleCharacter) -> bool:
	if potential_reactor == triggering_caster:
		return false # Typically can't react to your own immediate actions this way

	# Check action types
	if !triggering_action_types_any_of.is_empty():
		var type_match = false
		for action_type_enum_val in triggering_action_types_any_of:
			if triggering_action.type == action_type_enum_val:
				type_match = true
				break
		if !type_match:
			return false

	# Check action tags (traits)
	if !triggering_action_tags_any_of.is_empty():
		var tag_match = false
		for tag in triggering_action_tags_any_of:
			if triggering_action.action_tags.has(tag): # Requires action_tags on PlannedAction
				tag_match = true
				break
		if !tag_match:
			return false
	
	# Check target condition
	if must_be_target:
		var is_target = false
		if is_instance_valid(triggering_action.target_node) and triggering_action.target_node == potential_reactor:
			is_target = true
		elif triggering_action.type == PlannedAction.ActionType.SPELL_FIREBALL: # Example for AoE
			# This check is simplified; a real AoE check would be more robust
			if potential_reactor.global_position.distance_to(triggering_action.target_position) <= triggering_action.aoe_radius:
				is_target = true # Considered "targeted" if in AoE
		if !is_target:
			return false
			
	if must_not_be_target:
		var is_target = false
		if is_instance_valid(triggering_action.target_node) and triggering_action.target_node == potential_reactor:
			is_target = true
		elif triggering_action.type == PlannedAction.ActionType.SPELL_FIREBALL:
			if potential_reactor.global_position.distance_to(triggering_action.target_position) <= triggering_action.aoe_radius:
				is_target = true
		if is_target: # If they ARE the target, but mustn't be
			return false

	# Check caster allegiance
	if !triggering_caster_allegiance.is_empty():
		if !triggering_caster_allegiance.has(triggering_caster.allegiance):
			return false
			
	return true
