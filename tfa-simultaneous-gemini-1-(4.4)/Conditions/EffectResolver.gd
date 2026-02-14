# EffectResolver.gd
# Handles resolution of conditional effects based on traits
# This is the core of the flexible trait-based modifier system
class_name EffectResolver
extends RefCounted


## Trigger types for conditional modifiers
enum TriggerType {
	ON_ATTACK,          # When this character attacks
	ON_DEFEND,          # When this character is attacked
	ON_ABILITY_USE,     # When using an ability
	ON_DAMAGE_DEALT,    # After dealing damage
	ON_DAMAGE_TAKEN,    # After taking damage
	ON_HEAL,            # When healing
	ON_CONDITION_APPLY, # When applying a condition
	ON_CONDITION_RESIST,# When resisting a condition
	PASSIVE,            # Always active (for stat mods)
}


## Modifier types
enum ModifierType {
	FLAT_DAMAGE_DEALT,        # Add flat damage. Will have to consider type, also by trait
	FLAT_DAMAGE_TAKEN,
	PERCENT_DAMAGE_DEALT,     # Multiply damage,
	PERCENT_DAMAGE_TAKEN,
	DR_IGNORED_SELF,
	DR_IGNORED_OTHER,
	ACTION_SPEED_BY_TRAIT,
	TARGET_LOCATION_CHANGE,
	TARGET_TRAIT_RESTRICTION, #e.g., cannot target females
	ACTION_TRAIT_RESTRICTION, #e.g., cannot take actions with the auditory trait while silenced
	RANGE_OF_ACTION_WITH_TRAIT, #e.g., extended spell increases range with spell attacks.
	SPELL_FAILURE_CHANCE,
	ABILITIES_FORGOTTEN,
	MAX_HEALTH,
	FLAT_HEALING_DEALT,       # Add flat healing
	FLAT_HEALING_TAKEN,
	PERCENT_HEALING_DEALT,    # Multiply healing
	PERCENT_HEALING_TAKEN,
	STAT_BONUS,         # Modify a stat.  Can be dictionary?
	DURATION_BONUS,     # Modify condition duration
	STACK_BONUS,        # Modify condition stacks
	CRITICAL_CHANCE,    # Modify crit chance
	CRITICAL_DAMAGE,    # Modify crit multiplier
	ACCURACY,           # Modify hit chance
	EVASION,            # Modify dodge chance
	CUSTOM,             # For custom effect handlers
}


## Check if traits match requirements
## Requirements can be: String (single trait), Array (any of these), or Dictionary (complex logic)
static func traits_match(entity_traits: Dictionary, requirements) -> bool:
	if requirements == null or (requirements is Array and requirements.is_empty()):
		return true
	
	if requirements is String:
		return requirements in entity_traits
	
	if requirements is Array:
		# Any of these traits
		for req in requirements:
			if req in entity_traits:
				return true
		return false
	
	if requirements is Dictionary:
		# Complex logic: {"all": [...], "any": [...], "none": [...]}
		var all_reqs = requirements.get("all", [])
		var any_reqs = requirements.get("any", [])
		var none_reqs = requirements.get("none", [])
		#var at_least_tier_req = requirements.
		
		# Check "all" - every trait must be present
		for req in all_reqs:
			if req not in entity_traits.keys():
				return false
		
		# Check "any" - at least one must be present (if specified)
		if not any_reqs.is_empty():
			var any_match = false
			for req in any_reqs:
				if req in entity_traits.keys():
					any_match = true
					break
			if not any_match:
				return false
		
		# Check "none" - none of these can be present
		for req in none_reqs:
			if req in entity_traits.keys():
				return false
		
		return true
	
	return false


## Evaluate a conditional modifier
## Returns null if conditions not met, or the modifier value/data if met
## 
static func evaluate_modifier(
	modifier: Dictionary,
	source_traits: Dictionary,
	target_traits: Dictionary,
	action_traits: Dictionary
) -> Variant:
	# Check source trait requirements
	var source_reqs = modifier.get("source_traits")
	if source_reqs != null and not traits_match(source_traits, source_reqs):
		return null
	
	# Check target trait requirements
	var target_reqs = modifier.get("target_traits")
	if target_reqs != null and not traits_match(target_traits, target_reqs):
		return null
	
	# Check action trait requirements
	var action_reqs = modifier.get("action_traits")
	if action_reqs != null and not traits_match(action_traits, action_reqs):
		return null
	
	# All conditions met - return the modifier data
	return {
		"modifier_type": modifier.get("modifier_type", ModifierType.FLAT_DAMAGE_DEALT),
		"stat": modifier.get("stat", ""),
		"value": modifier.get("value", 0),
		"custom_handler": modifier.get("custom_handler", ""),
		"custom_data": modifier.get("custom_data", {})
	}
## Collect all applicable modifiers from a list of conditions
static func collect_modifiers(
	conditions: Array[ConditionInstance],
	trigger_type: TriggerType,
	source_traits: Dictionary,
	target_traits: Dictionary,
	action_traits: Dictionary
) -> Array[Dictionary]:
	var applicable_mods: Array[Dictionary] = []
	
	for cond_instance in conditions:
		if not cond_instance.is_active():
			continue
		
		var condition = cond_instance.condition
		if not condition:
			continue
		
		for mod in condition.conditional_modifiers:
			# Check trigger type
			var mod_trigger = mod.get("trigger_type", TriggerType.PASSIVE)
			if mod_trigger != trigger_type and mod_trigger != TriggerType.PASSIVE:
				continue
			
			# Evaluate the modifier
			var result = evaluate_modifier(mod, source_traits, target_traits, action_traits)
			if result != null:
				# Scale by stacks if applicable
				if mod.get("scales_with_stacks", true):
					result["value"] = result["value"] * cond_instance.stacks
				result["source_condition"] = condition.id
				result["source_instance"] = cond_instance.instance_id
				applicable_mods.append(result)
	
	return applicable_mods

## Apply collected modifiers to a base value
static func apply_modifiers_to_value(
	base_value: float,
	modifiers: Array[Dictionary],
	modifier_type: ModifierType
) -> float:
	var flat_bonus: float = 0.0
	var percent_bonus: float = 1.0
	
	for mod in modifiers:
		if mod.get("modifier_type") != modifier_type:
			continue
		
		var value = mod.get("value", 0)
		
		match modifier_type:
			ModifierType.FLAT_DAMAGE_DEALT, ModifierType.FLAT_HEALING_DEALT:
				flat_bonus += value
			ModifierType.PERCENT_DAMAGE_DEALT, ModifierType.PERCENT_HEALING_DEALT:
				percent_bonus *= (1.0 + value / 100.0)
			_:
				flat_bonus += value
	
	return (base_value + flat_bonus) * percent_bonus

## Create a modifier definition helper
static func create_modifier(
	trigger: TriggerType,
	mod_type: ModifierType,
	value: float,
	source_traits = null,
	target_traits = null,
	action_traits = null,
	stat: String = "",
	scales_with_stacks: bool = true
) -> Dictionary:
	return {
		"trigger_type": trigger,
		"modifier_type": mod_type,
		"value": value,
		"source_traits": source_traits,
		"target_traits": target_traits,
		"action_traits": action_traits,
		"stat": stat,
		"scales_with_stacks": scales_with_stacks
	}
