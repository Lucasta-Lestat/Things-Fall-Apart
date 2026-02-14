# Condition.gd
# Resource class defining a condition's data and behavior
class_name Condition
extends Resource

## Unique identifier for this condition type
@export var id: String = ""

## Display name
@export var display_name: String = ""

## Description shown to player
@export var description: String = ""

## Tier/severity level (higher = more severe)
@export var tier: int = 1

## Icon for UI display
@export var icon: Texture2D

## Tags/traits this condition has (e.g., "poison", "magical", "disease")
@export var traits: Array = []

## Whether this condition stacks (multiple instances can exist)
@export var stackable: bool = false

## Maximum stacks if stackable
@export var max_stacks: int = 1

## Duration in game seconds (-1 for permanent until removed)
@export var duration: float = -1.0

## Stat modifiers this condition applies
## Format: Array of dictionaries with keys: stat, operation, value, conditions
## Operations: "add", "multiply", "set"
## Conditions (optional): trait requirements for the modifier to apply
@export var stat_modifiers: Array = []

## Triggered effects (damage over time, healing, etc.)
## Format: Array of dictionaries with keys: type, value, interval, conditions
@export var triggered_effects: Array = []

## Conditional modifiers that affect actions/combat
## Format: Array of dictionaries defining trait-based bonuses
## Keys: trigger_type, source_traits, target_traits, action_traits, modifier_type, stat, value
@export var conditional_modifiers: Array = []

## Conditions that this condition is immune to or suppresses
@export var immunities: Array = []

## Conditions this condition transforms into under certain circumstances
@export var transforms_to: Dictionary = {}  # {condition_id: {trigger: "condition", value: "..."}}


# Helper function to create a condition instance from data
static func create_from_data(data: Dictionary) -> Condition:
	var condition = Condition.new()
	condition.id = data.get("id", "")
	condition.display_name = data.get("display_name", "")
	condition.description = data.get("description", "")
	condition.tier = data.get("tier", 1)
	condition.traits = data.get("traits", [])
	condition.stackable = data.get("stackable", false)
	condition.max_stacks = data.get("max_stacks", 1)
	condition.duration = data.get("duration", -1.0)
	condition.stat_modifiers = data.get("stat_modifiers", [])
	condition.triggered_effects = data.get("triggered_effects", [])
	condition.conditional_modifiers = data.get("conditional_modifiers", [])
	condition.immunities = data.get("immunities", [])
	condition.transforms_to = data.get("transforms_to", {})
	return condition
