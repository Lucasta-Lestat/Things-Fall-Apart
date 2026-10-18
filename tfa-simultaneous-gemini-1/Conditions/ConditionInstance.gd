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

## Concealment lifted until this absolute time (TimeManager.absolute_time()):
## ProceduralCharacter.reveal marks the bearer's Shrouded while an attack's
## reveal window is open, so every display of it says "(revealed 2s)" and dims
## it, as the overhead icon does. -1 = not revealed. Not saved: the window
## isn't either, and a reloaded character starts concealed.
var revealed_until: float = -1.0

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

var target_limb = null  # LimbType enum value or null

# Update _init to accept it:
func _init(p_condition: Condition = null, p_source: Node = null, p_target_limb = null) -> void:
	condition = p_condition
	source = p_source
	target_limb = p_target_limb
	instance_id = "cond_%d_%d" % [_next_id, randi()]
	_next_id += 1
	
	if condition:
		for i in range(condition.triggered_effects.size()):
			last_trigger_times[i] = -INF

# Update to_dict:
func to_dict() -> Dictionary:
	return {
		"condition_id": condition.id if condition else "",
		"stacks": stacks,
		"is_suppressed": is_suppressed,
		"applied_at": applied_at,
		"expires_at": expires_at,
		"custom_data": custom_data,
		"last_trigger_times": last_trigger_times,
		"instance_id": instance_id,
		"target_limb": target_limb if target_limb != null else -1
	}

# Update from_dict:
static func from_dict(data: Dictionary, condition_registry: Dictionary) -> ConditionInstance:
	var condition_id = data.get("condition_id", "")
	var condition_template = condition_registry.get(condition_id)
	
	if not condition_template:
		push_warning("Unknown condition ID: %s" % condition_id)
		return null
	
	var saved_limb = data.get("target_limb", -1)
	var limb_value = null if saved_limb == -1 else saved_limb
	
	var instance = ConditionInstance.new(condition_template, null, limb_value)
	instance.stacks = data.get("stacks", 1)
	# Held to today's cap, as every application is: a save from before a cap
	# came down (round 4: Poisoned 10 -> 4, Corroding 5 -> 3; Burning's 4 -> 3
	# was undone in round 5)
	# would otherwise tick and read "x10" past what the description says.
	if condition_template.stackable and condition_template.max_tier >= 1:
		instance.stacks = mini(instance.stacks, condition_template.max_tier)
	instance.is_suppressed = data.get("is_suppressed", false)
	instance.applied_at = data.get("applied_at", 0.0)
	instance.expires_at = data.get("expires_at", -1.0)
	instance.custom_data = data.get("custom_data", {})
	instance.last_trigger_times = data.get("last_trigger_times", {})
	instance.instance_id = data.get("instance_id", "cond_loaded_%d" % randi())
	
	return instance

func apply(game_time: float) -> void:
	applied_at = game_time
	if condition and condition.duration > 0:
		expires_at = game_time + condition.duration
	else:
		expires_at = -1.0

	if condition and condition.id == "bide" and not custom_data.has("absorbed"):
		custom_data["absorbed"] = 0.0
		custom_data["ratio"] = 1.0


func is_expired(game_time: float) -> bool:
	if expires_at < 0:
		return false
	return game_time >= expires_at


func get_remaining_duration(game_time: float) -> float:
	if expires_at < 0:
		return -1.0
	return max(0.0, expires_at - game_time)


func get_display_name() -> String:
	if not condition:
		return "?"
	return condition.display_name if condition.display_name != "" else condition.id.capitalize()


## One-line label, the single wording for every condition display:
## "Weakened x3 (12s) (suppressed)". Time left only for a timed instance and
## only when `now` (TimeManager.absolute_time(), the clock expires_at is on)
## is given. A damaging DoT also says what it deals now (get_dot_text):
## "Burning x3: 3 fire every 1 s (5s left)". A Shrouded an attack has lifted
## reads "Shrouded (revealed 2s)" (is_revealed).
func get_summary(now: float = -1.0) -> String:
	var text := get_display_name()
	if stacks > 1:
		text += " x%d" % stacks
	var dot := get_dot_text()
	if dot != "":
		text += ": " + dot
	if now >= 0.0 and expires_at >= 0.0:
		# "left" keeps the time apart from the tick interval just before it.
		text += (" (%s left)" if dot != "" else " (%s)") % Globals.format_duration_short(get_remaining_duration(now))
	if is_suppressed:
		# A timed suppression (ConditionManager.suppress_for) says how long.
		if now >= 0.0 and custom_data.has("suppressed_until"):
			text += " (suppressed %s)" % Globals.format_duration_short(maxf(0.0, float(custom_data["suppressed_until"]) - now))
		else:
			text += " (suppressed)"
	elif is_revealed(now):
		# A Shrouded bearer shown in full by their own attack or cast.
		text += " (revealed %s)" % Globals.format_duration_short(revealed_until - now)
	return text


## True while an attack's reveal window has lifted this concealment
## (revealed_until); false without a clock (`now` < 0).
func is_revealed(now: float) -> bool:
	return now >= 0.0 and now < revealed_until


## "3 fire every 1 s": the damage a DoT's next tick deals at the current
## stacks (value x stacks, as ConditionManager._execute_triggered_effect) and
## how often. That is what lands: ticks ignore armour (round 5,
## ProceduralCharacter.take_damage). Only an armour weakness (Legionnaire's
## electric) adds to a tick, and condition DR (Shielded, Physically Resistant,
## Stalwart, Rage) takes from a physical one (Suffocating). "" for a condition
## with no damage tick. True damage (Bleeding) reads "damage".
func get_dot_text() -> String:
	if not condition:
		return ""
	for effect in condition.triggered_effects:
		if not (effect is Dictionary) or effect.get("type", "") != "damage":
			continue
		var per_tick: int = int(effect.get("value", 0)) * stacks
		var dtype := str(effect.get("damage_type", "true"))
		var interval := float(effect.get("interval", 1.0))
		var every: String = str(int(round(interval))) if is_equal_approx(interval, round(interval)) else String.num(interval, 1)
		return "%d %s every %s s" % [per_tick, "damage" if dtype == "true" else dtype, every]
	return ""


## get_summary plus the description: conditions are explained nowhere else.
func get_tooltip_text(now: float = -1.0) -> String:
	var text := get_summary(now)
	if condition and condition.description != "":
		text += "\n" + condition.description
	return text


func add_stacks(amount: int) -> int:
	if not condition:
		return stacks
	
	var old_stacks = stacks
	stacks = min(stacks + amount, condition.max_tier)
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
