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
@export var traits: Dictionary = {}

## Whether this condition stacks (multiple instances can exist)
@export var stackable: bool = false

## Maximum tier if stackable
@export var max_tier: int = 1

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
@export var immunities: Dictionary = {}

## Conditions this condition transforms into under certain circumstances
@export var transforms_into: Dictionary = {}  # {condition_id: {trigger: "condition", value: "..."}}

## When non-empty, this condition gains +1 stack each time the bearer uses an
## ability whose traits contain ALL of the listed required_traits.
## Format: {"required_traits": ["criminal"]}
@export var on_action_trait_stack: Dictionary = {}

@export var canceled_by_trait: Array = []
@export var custom_vfx: String = ""
@export var custom_sfx: String = ""

## Optional saving throw. If non-empty, the bearer rolls a save against this stat
## ("str", "dex", "con", "int", "wis", "cha") when the condition is applied;
## see ProceduralCharacter.saving_throw for the success-level rules. The returned
## tier delta is added to incoming stacks — fully successful saves reduce stacks
## to 0 and the application is skipped entirely.
@export var save_stat: String = ""

## If > 0 and save_stat is set, the bearer re-rolls a save every save_interval
## seconds while the condition is active. Negative delta removes stacks (and the
## condition entirely if stacks fall to 0); positive delta adds stacks (capped at max_tier).
@export var save_interval: float = 0.0

## Ability ID that should be added to the bearer's inventory the first time this
## condition is applied (used by mutations like The Jaws That Bite that grant a
## new attack option). Empty string = no ability granted.
@export var grants_ability: String = ""

# Helper function to create a condition instance from data
static func create_from_data(data: Dictionary) -> Condition:
	var condition = Condition.new()
	condition.id = data.get("id", "")
	condition.display_name = data.get("display_name", "")
	condition.description = data.get("description", "")
	condition.tier = data.get("tier", 1)
	condition.traits = data.get("traits", [])
	condition.stackable = data.get("stackable", false)
	condition.max_tier = data.get("max_tier", 1) ####
	condition.duration = data.get("duration", -1.0)
	condition.icon = load(data.get("icon","dummy_icon.png")) ####
	condition.transforms_into = data.get("transforms_into", {})
	condition.canceled_by_trait = data.get("canceled_by_trait", []) ####
	condition.on_action_trait_stack = data.get("on_action_trait_stack", {})
	condition.custom_vfx = data.get("custom_vfx", "no vfx scene") ####
	condition.custom_sfx = data.get("custom_sfx", "no sfx scene") ####
	
	condition.stat_modifiers = data.get("stat_modifiers", [])
	condition.triggered_effects = data.get("triggered_effects", [])
	condition.conditional_modifiers = data.get("conditional_modifiers", [])
	condition.immunities = data.get("immunities", [])
	condition.save_stat = data.get("save_stat", "")
	condition.save_interval = data.get("save_interval", 0.0)
	condition.grants_ability = data.get("grants_ability", "")

	return condition
