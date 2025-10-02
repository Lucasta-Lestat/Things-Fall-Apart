# res://Data/Conditions/Condition.gd
# Defines a single condition, which is a collection of effects.
extends Resource
class_name Condition

# A condition can be a temporary debuff, a permanent passive, a temporary buff, etc.
enum ConditionCategory { BUFF, DEBUFF, PASSIVE, INJURY }

@export var id: StringName
@export var display_name: String
@export_multiline var description: String
@export var category: ConditionCategory
@export var max_tier: int = 1
# Does the condition disappear after a few rounds? (0 means permanent or save-based)
@export var duration_in_rounds: int = 0

# --- NEW: Saving Throw Properties ---
# If save_stat is not empty, the character will attempt a roll-under save each round.
@export var save_stat: StringName # e.g., "constitution", "will"

# Traits that provide a bonus or penalty to the save roll.
@export var save_advantages: Array[StringName] = []
@export var save_disadvantages: Array[StringName] = []

# The list of modular effects this condition applies.
@export var effects: Array[ConditionEffect] = []
