# ConditionDatabase.gd
# Example condition definitions showing the data-driven approach
# Load this as an autoload or initialize it in your game startup
extends Node

func _ready() -> void:
	_register_all_conditions()


func _register_all_conditions() -> void:
	# Register all conditions from data
	ConditionManager.register_conditions(get_all_conditions())


func get_all_conditions() -> Array:
	return [
	{
		"id": "weakened",
		"display_name": "Weakened",
		"description": "Physical attacks deal less damage.",
		"traits": {"debuff": 1, "physical": 1},
		"stackable": true,
		"max_tier": 5,
		"duration": 30.0,
		"icon": "res://UI/UI Icons/weakened.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "res://vfx/weakened.tscn",
		"custom_sfx": "res://sfx/debuff_generic.mp3",
		"stat_modifiers": [
			{"stat": "STR", "operation": "add", "value": -2}
		],
		"immunities": {}
	},
	{
		"id": "exhausted",
		"display_name": "Exhausted",
		"description": "Severely fatigued, reducing constitution.",
		"traits": {"debuff": 1, "fatigue": 2},
		"stackable": false,
		"duration": 60.0,
		"icon": "res://UI/UI Icons/exhausted.png",
		"transforms_into": {},
		"canceled_by_trait": ["restoration"],
		"custom_vfx": "res://vfx/exhausted.tscn",
		"custom_sfx": "res://sfx/heavy_breathing.mp3",
		"stat_modifiers": [
			{"stat": "CON", "operation": "add", "value": -7}
		],
		"immunities": {}
	},
	{
		"id": "poisoned",
		"display_name": "Poisoned",
		"description": "Taking poison damage over time.",
		"traits": {"debuff": 1, "poison": 1, "persistent": 1},
		"stackable": true,
		"max_tier": 10,
		"duration": 20.0,
		"icon": "res://UI/UI Icons/poisoned.png",
		"transforms_into": {"id": "toxic_shock", "required_tier": 10},
		"canceled_by_trait": ["antidote", "purify"],
		"custom_vfx": "res://vfx/poison_bubbles.tscn",
		"custom_sfx": "res://sfx/poison_tick.mp3",
		"stat_modifiers": [],
		"triggered_effects": [
			{
				"type": "damage",
				"value": 5,
				"damage_type": "poison",
				"interval": 2.0
			}
		],
		"immunities": {}
	},
	{
		"id": "burning",
		"display_name": "Burning",
		"description": "Engulfed in flames, taking fire damage.",
		"traits": {"debuff": 1, "fire": 1, "dot": 1, "elemental": 1},
		"stackable": true,
		"max_tier": 4,
		"duration": 15.0,
		"icon": "res://UI/UI Icons/burning.png",
		"transforms_into": {},
		"canceled_by_trait": ["cold", "water"],
		"custom_vfx": "res://vfx/fire.tscn",
		"custom_sfx": "res://sfx/burning_flesh.mp3",
		"triggered_effects": [
			{
				"type": "damage",
				"value": 15,
				"damage_type": "fire",
				"interval": 1.0
			}
		],
		"immunities": {}
	},
	{
		"id": "stunned",
		"display_name": "Stunned",
		"description": "Cannot take actions.",
		"traits": {"debuff": 1, "cc": 2, "stun": 1, "incapacitate": 1},
		"stackable": false,
		"duration": 3.0,
		"icon": "res://UI/UI Icons/stunned.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "res://vfx/stun_stars.tscn",
		"custom_sfx": "res://sfx/stun_impact.mp3",
		"stat_modifiers": [
			{"stat": "EVASION", "operation": "set", "value": 0},
			{"stat": "DEX", "operation": "set", "value": 0}
		],
		"immunities": {}
	},
	{
		"id": "chilled",
		"display_name": "Chilled",
		"description": "Movement and attack speed reduced. At tier 3, you freeze.",
		"traits": {"debuff": 1, "cold": 1, "slow": 1, "elemental": 1},
		"stackable": true,
		"max_tier": 3,
		"duration": 15.0,
		"icon": "res://UI/UI Icons/chilled.png",
		"transforms_into": {"id": "frozen", "required_tier": 3},
		"canceled_by_trait": ["fire", "heat"],
		"custom_vfx": "res://vfx/frost_mist.tscn",
		"custom_sfx": "res://sfx/ice_crack.mp3",
		"stat_modifiers": [
			{"stat": "DEX", "operation": "multiply", "value": 0.85}
		],
		"immunities": {}
	},
	{
		"id": "frozen",
		"display_name": "Frozen",
		"description": "Encased in ice, unable to move.",
		"traits": {"debuff": 1, "cold": 2, "cc": 2, "incapacitate": 1, "elemental": 1},
		"stackable": false,
		"duration": 5.0,
		"icon": "res://UI/UI Icons/frozen.png",
		"transforms_into": {},
		"canceled_by_trait": ["fire", "heat"],
		"custom_vfx": "res://vfx/ice_block.tscn",
		"custom_sfx": "res://sfx/frozen_solid.mp3",
		"stat_modifiers": [
			{"stat": "DEX", "operation": "set", "value": 0}
		],
		"immunities": {
			"cold": 1,
			"slow": 1
		}
	},
	{
		"id": "might",
		"display_name": "Might",
		"description": "Increased physical power.",
		"traits": {"buff": 1, "physical": 1, "enhancement": 1},
		"stackable": false,
		"duration": 60.0,
		"icon": "res://UI/UI Icons/might.png",
		"transforms_into": {},
		"canceled_by_trait": ["curse"],
		"custom_vfx": "res://vfx/might_aura.tscn",
		"custom_sfx": "res://sfx/buff_shout.mp3",
		"stat_modifiers": [
			{"stat": "STR", "operation": "add", "value": 5},
			{"stat": "DAMAGE", "operation": "multiply", "value": 1.15}
		],
		"immunities": {}
	},
	{
		"id": "haste",
		"display_name": "Haste",
		"description": "Moving and acting faster.",
		"traits": {"buff": 1, "speed": 2, "magical": 1},
		"stackable": false,
		"duration": 30.0,
		"icon": "res://UI/UI Icons/haste.png",
		"transforms_into": {},
		"canceled_by_trait": ["slow"],
		"custom_vfx": "res://vfx/speed_trails.tscn",
		"custom_sfx": "res://sfx/haste_wind.mp3",
		"stat_modifiers": [
			{"stat": "DEX", "operation": "multiply", "value": 1.5},
			{"stat": "EVASION", "operation": "add", "value": 10}
		],
		"immunities": {
			"slow": 1
		}
	},
	{
		"id": "regenerating",
		"display_name": "Regenerating",
		"description": "Health restoring over time.",
		"traits": {"buff": 1, "healing": 1, "hot": 1},
		"stackable": true,
		"max_tier": 3,
		"duration": 20.0,
		"icon": "res://UI/UI Icons/regenerating.png",
		"transforms_into": {},
		"canceled_by_trait": ["decay", "anti-heal"],
		"custom_vfx": "res://vfx/heal_sparkles.tscn",
		"custom_sfx": "res://sfx/regen_loop.mp3",
		"triggered_effects": [
			{
				"type": "heal",
				"value": 10,
				"interval": 2.0
			}
		],
		"immunities": {}
	},
	{
		"id": "shielded",
		"display_name": "Shielded",
		"description": "Protected by a magical barrier.",
		"traits": {"buff": 1, "shield": 2, "magical": 1, "protection": 1},
		"stackable": false,
		"duration": 45.0,
		"icon": "res://UI/UI Icons/shielded.png",
		"transforms_into": {},
		"canceled_by_trait": ["shatter"],
		"custom_vfx": "res://vfx/energy_shield.tscn",
		"custom_sfx": "res://sfx/shield_hum.mp3",
		"stat_modifiers": [
			{"stat": "DR", "operation": "add", "value": 25}
		],
		"immunities": {
			"fire": 1,
			"cold": 1
		}
	}
]
