# ConditionInstance.gd
# Represents an active instance of a condition on a character
class_name ConditionInstance
extends RefCounted

## The condition template this instance is based on
var condition: Condition

## Current stack count
var stacks: int = 1

## Whether this condition is currently suppressed
var is_suppressed: bool = false

## Time when this condition was applied (game_time from TimeManager)
var applied_at: float = 0.0

## Time when this condition expires (-1 for permanent)
var expires_at: float = -1.0

## Source of the condition (who/what applied it)
var source: Node = null

## Custom data for special conditions
var custom_data: Dictionary = {}

## Last time a triggered effect was executed (for intervals)
var last_trigger_times: Dictionary = {}  # effect_index -> last_game_time

## Unique instance ID for tracking
var instance_id: String = ""

static var _next_id: int = 0


func _init(p_condition: Condition = null, p_source: Node = null) -> void:
	condition = p_condition
	source = p_source
	instance_id = "cond_%d_%d" % [_next_id, randi()]
	_next_id += 1
	
	if condition:
		# Initialize trigger times for all triggered effects
		for i in range(condition.triggered_effects.size()):
			last_trigger_times[i] = -INF


func apply(game_time: float) -> void:
	applied_at = game_time
	if condition and condition.duration > 0:
		expires_at = game_time + condition.duration
	else:
		expires_at = -1.0


func is_expired(game_time: float) -> bool:
	if expires_at < 0:
		return false
	return game_time >= expires_at


func get_remaining_duration(game_time: float) -> float:
	if expires_at < 0:
		return -1.0
	return max(0.0, expires_at - game_time)


func add_stacks(amount: int) -> int:
	if not condition:
		return stacks
	
	var old_stacks = stacks
	stacks = min(stacks + amount, condition.max_stacks)
	return stacks - old_stacks  # Return actual stacks added


func remove_stacks(amount: int) -> int:
	var old_stacks = stacks
	stacks = max(0, stacks - amount)
	return old_stacks - stacks  # Return actual stacks removed


func suppress() -> void:
	is_suppressed = true


func unsuppress() -> void:
	is_suppressed = false


func is_active() -> bool:
	return not is_suppressed and stacks > 0


func get_scaled_stat_modifiers() -> Array[Dictionary]:
	"""Returns stat modifiers scaled by stack count."""
	if not condition or is_suppressed:
		return []
	
	var scaled: Array[Dictionary] = []
	for mod in condition.stat_modifiers:
		var scaled_mod = mod.duplicate()
		# Scale value by stacks for additive modifiers
		if scaled_mod.get("operation", "add") == "add":
			scaled_mod["value"] = scaled_mod.get("value", 0) * stacks
		elif scaled_mod.get("operation") == "multiply":
			# For multiplicative, compound the effect: (1 + (mult-1))^stacks
			var base_mult = scaled_mod.get("value", 1.0)
			scaled_mod["value"] = pow(base_mult, stacks)
		scaled.append(scaled_mod)
	
	return scaled


func to_dict() -> Dictionary:
	"""Serialize to dictionary for saving."""
	return {
		"condition_id": condition.id if condition else "",
		"stacks": stacks,
		"is_suppressed": is_suppressed,
		"applied_at": applied_at,
		"expires_at": expires_at,
		"custom_data": custom_data,
		"last_trigger_times": last_trigger_times,
		"instance_id": instance_id
	}


static func from_dict(data: Dictionary, condition_registry: Dictionary) -> ConditionInstance:
	"""Deserialize from dictionary."""
	var condition_id = data.get("condition_id", "")
	var condition_template = condition_registry.get(condition_id)
	
	if not condition_template:
		push_warning("Unknown condition ID: %s" % condition_id)
		return null
	
	var instance = ConditionInstance.new(condition_template, null)
	instance.stacks = data.get("stacks", 1)
	instance.is_suppressed = data.get("is_suppressed", false)
	instance.applied_at = data.get("applied_at", 0.0)
	instance.expires_at = data.get("expires_at", -1.0)
	instance.custom_data = data.get("custom_data", {})
	instance.last_trigger_times = data.get("last_trigger_times", {})
	instance.instance_id = data.get("instance_id", "cond_loaded_%d" % randi())
	
	return instance
