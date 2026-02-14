# ConditionManager.gd
# Component that manages all conditions on a character
# Attach this to your character node or add as a child
class_name ConditionManager
extends Node

## Reference to the TimeManager autoload
@export var time_manager_path: NodePath = "/root/TimeManager"
var time_manager: Node

## Reference to the character this manager belongs to
@export var character_path: NodePath = ".."
var character: Node

## All active condition instances, keyed by condition ID
## For stackable conditions, this holds the single instance with stack count
## For non-stackable, this is the instance itself
var conditions: Dictionary = {}  # condition_id -> ConditionInstance

## Registry of all known condition templates
## Should be populated from your data files
static var condition_registry: Dictionary = {}  # condition_id -> Condition

## Signals
signal condition_applied(instance: ConditionInstance)
signal condition_removed(instance: ConditionInstance)
signal condition_suppressed(instance: ConditionInstance)
signal condition_unsuppressed(instance: ConditionInstance)
signal condition_expired(instance: ConditionInstance)
signal condition_stacks_changed(instance: ConditionInstance, old_stacks: int, new_stacks: int)
signal triggered_effect_fired(instance: ConditionInstance, effect: Dictionary, result: Dictionary)
signal stats_recalculated()


func _ready() -> void:
	# Get TimeManager reference
	if has_node(time_manager_path):
		time_manager = get_node(time_manager_path)
	else:
		time_manager = get_node_or_null("/root/TimeManager")
	
	if not time_manager:
		push_warning("ConditionManager: TimeManager not found!")
	
	# Get character reference
	if has_node(character_path):
		character = get_node(character_path)


func _process(delta: float) -> void:
	if not time_manager:
		return
	
	var current_time = time_manager.game_time
	var expired_conditions: Array[String] = []
	
	# Check for expirations and process triggered effects
	for condition_id in conditions:
		var instance: ConditionInstance = conditions[condition_id]
		
		# Check expiration
		if instance.is_expired(current_time):
			expired_conditions.append(condition_id)
			continue
		
		# Process triggered effects if active
		if instance.is_active():
			_process_triggered_effects(instance, current_time)
	
	# Remove expired conditions
	for condition_id in expired_conditions:
		var instance = conditions[condition_id]
		_remove_condition_internal(condition_id)
		condition_expired.emit(instance)


func _process_triggered_effects(instance: ConditionInstance, current_time: float) -> void:
	var condition = instance.condition
	if not condition:
		return
	
	for i in range(condition.triggered_effects.size()):
		var effect = condition.triggered_effects[i]
		var interval = effect.get("interval", 1.0)
		var last_time = instance.last_trigger_times.get(i, -INF)
		
		if current_time - last_time >= interval:
			instance.last_trigger_times[i] = current_time
			var result = _execute_triggered_effect(instance, effect)
			triggered_effect_fired.emit(instance, effect, result)


func _execute_triggered_effect(instance: ConditionInstance, effect: Dictionary) -> Dictionary:
	var result: Dictionary = {"success": true}
	var effect_type = effect.get("type", "")
	var base_value = effect.get("value", 0) * instance.stacks
	
	match effect_type:
		"damage":
			result["damage"] = base_value
			result["damage_type"] = effect.get("damage_type", "true")
			# Character should listen for triggered_effect_fired and apply damage
		"heal":
			result["heal"] = base_value
		"stat_change":
			result["stat"] = effect.get("stat", "")
			result["change"] = base_value
		"apply_condition":
			result["condition_id"] = effect.get("condition_id", "")
			result["chance"] = effect.get("chance", 1.0)
		"remove_condition":
			result["condition_id"] = effect.get("condition_id", "")
		"custom":
			result["custom_type"] = effect.get("custom_type", "")
			result["custom_data"] = effect.get("custom_data", {})
	
	return result


## Register a condition template
static func register_condition(condition: Condition) -> void:
	condition_registry[condition.id] = condition


## Register multiple conditions from an array
static func register_conditions(conditions_array: Array) -> void:
	for cond in conditions_array:
		if cond is Condition:
			register_condition(cond)
		elif cond is Dictionary:
			register_condition(Condition.create_from_data(cond))


## Apply a condition to this character
func apply_condition(
	condition_id: String,
	source: Node = null,
	stacks: int = 1,
	duration_override: float = -2.0  # -2 means use default
) -> ConditionInstance:
	var template = condition_registry.get(condition_id)
	if not template:
		push_warning("Unknown condition: %s" % condition_id)
		return null
	
	# Check for immunities
	if _is_immune_to(condition_id):
		return null
	
	var current_time = time_manager.game_time if time_manager else 0.0
	var existing = conditions.get(condition_id)
	
	if existing:
		if template.stackable:
			# Add stacks to existing
			var old_stacks = existing.stacks
			var added = existing.add_stacks(stacks)
			if added > 0:
				condition_stacks_changed.emit(existing, old_stacks, existing.stacks)
				stats_recalculated.emit()
			return existing
		else:
			# Refresh duration for non-stackable
			if duration_override > -2.0:
				existing.expires_at = current_time + duration_override if duration_override > 0 else -1.0
			elif template.duration > 0:
				existing.expires_at = current_time + template.duration
			return existing
	
	# Create new instance
	var instance = ConditionInstance.new(template, source)
	instance.stacks = min(stacks, template.max_stacks) if template.stackable else 1
	
	# Set duration
	if duration_override > -2.0:
		if duration_override > 0:
			instance.expires_at = current_time + duration_override
		else:
			instance.expires_at = -1.0
	
	instance.apply(current_time)
	conditions[condition_id] = instance
	
	condition_applied.emit(instance)
	stats_recalculated.emit()
	
	return instance


## Remove a condition completely
func remove_condition(condition_id: String) -> bool:
	if condition_id not in conditions:
		return false
	
	var instance = conditions[condition_id]
	_remove_condition_internal(condition_id)
	condition_removed.emit(instance)
	return true


func _remove_condition_internal(condition_id: String) -> void:
	conditions.erase(condition_id)
	stats_recalculated.emit()


## Remove stacks from a condition (removes condition if stacks reach 0)
func remove_stacks(condition_id: String, amount: int) -> int:
	var instance = conditions.get(condition_id)
	if not instance:
		return 0
	
	var old_stacks = instance.stacks
	var removed = instance.remove_stacks(amount)
	
	if removed > 0:
		condition_stacks_changed.emit(instance, old_stacks, instance.stacks)
		
		if instance.stacks <= 0:
			remove_condition(condition_id)
		else:
			stats_recalculated.emit()
	
	return removed


## Suppress a condition (effects don't apply but condition persists)
func suppress_condition(condition_id: String) -> bool:
	var instance = conditions.get(condition_id)
	if not instance or instance.is_suppressed:
		return false
	
	instance.suppress()
	condition_suppressed.emit(instance)
	stats_recalculated.emit()
	return true


## Unsuppress a condition
func unsuppress_condition(condition_id: String) -> bool:
	var instance = conditions.get(condition_id)
	if not instance or not instance.is_suppressed:
		return false
	
	instance.unsuppress()
	condition_unsuppressed.emit(instance)
	stats_recalculated.emit()
	return true


## Check if character is immune to a condition
func _is_immune_to(condition_id: String) -> bool:
	for cond_id in conditions:
		var instance: ConditionInstance = conditions[cond_id]
		if instance.is_active() and condition_id in instance.condition.immunities:
			return true
	return false


## Get all active (non-suppressed) stat modifiers
func get_active_stat_modifiers() -> Array[Dictionary]:
	var all_mods: Array[Dictionary] = []
	
	for cond_id in conditions:
		var instance: ConditionInstance = conditions[cond_id]
		all_mods.append_array(instance.get_scaled_stat_modifiers())
	
	return all_mods


## Calculate the effective value of a stat with all condition modifiers
func calculate_effective_stat(base_value: float, stat_name: String) -> float:
	var flat_bonus: float = 0.0
	var multiplier: float = 1.0
	var set_value: float = NAN
	
	var mods = get_active_stat_modifiers()
	
	for mod in mods:
		if mod.get("stat") != stat_name:
			continue
		
		var value = mod.get("value", 0)
		var operation = mod.get("operation", "add")
		
		match operation:
			"add":
				flat_bonus += value
			"multiply":
				multiplier *= value
			"set":
				# Last set wins
				set_value = value
	
	# If a "set" modifier exists, use that as the base
	if not is_nan(set_value):
		return set_value
	
	return (base_value + flat_bonus) * multiplier


## Get conditional modifiers for a specific trigger
func get_conditional_modifiers(
	trigger_type: EffectResolver.TriggerType,
	source_traits: Dictionary,
	target_traits: Dictionary,
	action_traits: Dictionary
) -> Array[Dictionary]:
	var active_instances: Array[ConditionInstance] = []
	for cond_id in conditions:
		active_instances.append(conditions[cond_id])
	
	return EffectResolver.collect_modifiers(
		active_instances,
		trigger_type,
		source_traits,
		target_traits,
		action_traits
	)


## Check if character has a specific condition (active or not)
func has_condition(condition_id: String) -> bool:
	return condition_id in conditions


## Check if character has an active (non-suppressed) condition
func has_active_condition(condition_id: String) -> bool:
	var instance = conditions.get(condition_id)
	return instance != null and instance.is_active()


## Get a condition instance
func get_condition(condition_id: String) -> ConditionInstance:
	return conditions.get(condition_id)


## Get all conditions with a specific trait
func get_conditions_with_trait(Trait: String) -> Array:
	var result: Array[ConditionInstance] = []
	for cond_id in conditions:
		var instance: ConditionInstance = conditions[cond_id]
		if Trait in instance.condition.traits:
			result.append(instance)
	return result


## Remove all conditions with a specific trait
func remove_conditions_with_trait(Trait: String) -> int:
	var to_remove: Array[String] = []
	for cond_id in conditions:
		var instance: ConditionInstance = conditions[cond_id]
		if Trait in instance.condition.traits:
			to_remove.append(cond_id)
	
	for cond_id in to_remove:
		remove_condition(cond_id)
	
	return to_remove.size()


## Suppress all conditions with a specific trait
func suppress_conditions_with_trait(Trait: String) -> int:
	var count = 0
	for cond_id in conditions:
		var instance: ConditionInstance = conditions[cond_id]
		if Trait in instance.condition.traits:
			if suppress_condition(cond_id):
				count += 1
	return count


## Get all condition IDs
func get_all_condition_ids() -> Array[String]:
	var ids: Array[String] = []
	for key in conditions.keys():
		ids.append(key)
	return ids


## Clear all conditions
func clear_all_conditions() -> void:
	var all_ids = get_all_condition_ids()
	for cond_id in all_ids:
		remove_condition(cond_id)


## Serialize for saving
func to_dict() -> Dictionary:
	var saved_conditions: Dictionary = {}
	for cond_id in conditions:
		saved_conditions[cond_id] = conditions[cond_id].to_dict()
	return {"conditions": saved_conditions}


## Deserialize for loading
func from_dict(data: Dictionary) -> void:
	clear_all_conditions()
	var saved_conditions = data.get("conditions", {})
	for cond_id in saved_conditions:
		var instance = ConditionInstance.from_dict(saved_conditions[cond_id], condition_registry)
		if instance:
			conditions[cond_id] = instance
	stats_recalculated.emit()
