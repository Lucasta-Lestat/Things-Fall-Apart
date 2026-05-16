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
			{"stat": "strength", "operation": "add", "value": -20}
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
			{"stat": "constitution", "operation": "add", "value": -7}
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
				"value": 8,
				"damage_type": "fire",
				"interval": 1.0
			}
		],
		"immunities": {}
	},
	{
		"id": "shocked",
		"display_name": "Shocked",
		"description": "Electricity arcs through your body.",
		"traits": {"debuff": 1, "electric": 1, "dot": 1, "elemental": 1},
		"stackable": true,
		"max_tier": 3,
		"duration": 1.5,
		"icon": "res://UI/UI Icons/stunned.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "res://vfx/lightning.tscn",
		"custom_sfx": "",
		"triggered_effects": [
			{
				"type": "damage",
				"value": 5,
				"damage_type": "electric",
				"interval": 0.3
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
		"duration": 0.5,
		"icon": "res://UI/UI Icons/stunned.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "res://vfx/stun_stars.tscn",
		"custom_sfx": "res://sfx/stun_impact.mp3",
		"stat_modifiers": [
			{"stat": "speed_modifier", "operation": "set", "value": -1.0},
			{"stat": "dexterity", "operation": "add", "value": -10}
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
			{"stat": "dexterity", "operation": "multiply", "value": 0.85}
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
		"icon": "res://UI/UI Icons/chilled.png",
		"transforms_into": {},
		"canceled_by_trait": ["fire", "heat"],
		"custom_vfx": "res://vfx/ice_block.tscn",
		"custom_sfx": "res://sfx/frozen_solid.mp3",
		"stat_modifiers": [
			{"stat": "dexterity", "operation": "set", "value": 0}
		],
		"immunities": {
			"cold": 1,
			"slow": 1
		}
	},
	{
		"id": "mighty",
		"display_name": "Mighty",
		"description": "Increased physical power.",
		"traits": {"buff": 1, "physical": 1},
		"stackable": false,
		"duration": 60.0,
		"icon": "res://UI/UI Icons/mighty.png",
		"transforms_into": {},
		"canceled_by_trait": ["weak"],
		"custom_vfx": "res://vfx/might_aura.tscn",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "strength", "operation": "add", "value": 20},
		],
		"immunities": {}
	},
	{
		"id": "hasted",
		"display_name": "Hasted",
		"description": "Moving and acting faster.",
		"traits": {"buff": 1, "speed": 2, "magical": 1},
		"stackable": false,
		"duration": 30.0,
		"icon": "res://UI/UI Icons/hasted.png",
		"transforms_into": {},
		"canceled_by_trait": ["slow"],
		"custom_vfx": "res://vfx/speed_trails.tscn",
		"custom_sfx": "res://sfx/haste_wind.mp3",
		"stat_modifiers": [
			{"stat": "dexterity", "operation": "multiply", "value": 1.5},
			{"stat": "evasion", "operation": "add", "value": 10}
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
			{"stat": "dr", "operation": "add", "value": 25}
		],
		"immunities": {
			"fire": 1,
			"cold": 1
		}
	},
	{
		"id": "slowed",
		"display_name": "Slowed",
		"description": "Movement speed reduced.",
		"traits": {"debuff": 1, "slow": 1},
		"stackable": false,
		"duration": 3.0,
		"icon": "res://UI/UI Icons/slowed.png",
		"transforms_into": {},
		"canceled_by_trait": ["speed", "haste"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "speed_modifier", "operation": "add", "value": -0.4}
		],
		"immunities": {}
	},
	{
		"id": "corroding",
		"display_name": "Corroding",
		"description": "Acid eats away at flesh and armor.",
		"traits": {"debuff": 1, "acid": 1, "dot": 1},
		"stackable": true,
		"max_tier": 5,
		"duration": 5.0,
		"icon": "res://UI/UI Icons/corroding.png",
		"transforms_into": {},
		"canceled_by_trait": ["purify", "water"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [],
		"triggered_effects": [
			{
				"type": "damage",
				"value": 8,
				"damage_type": "acid",
				"interval": 2.0
			}
		],
		"immunities": {}
	},
	{
		"id": "suffocating",
		"display_name": "Suffocating",
		"description": "Choking, taking damage from lack of air.",
		"traits": {"debuff": 1, "cc": 1},
		"stackable": false,
		"duration": 4.0,
		"icon": "res://UI/UI Icons/suffocating.png",
		"transforms_into": {},
		"canceled_by_trait": ["wind", "purify"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "dexterity", "operation": "multiply", "value": 0.9}
		],
		"triggered_effects": [
			{
				"type": "damage",
				"value": 6,
				"damage_type": "bludgeoning",
				"interval": 2.0
			}
		],
		"immunities": {}
	},
	{
		"id": "infatuated",
		"display_name": "Infatuated",
		"description": "Charmed by a specific creature and unwilling to attack them.",
		"traits": {"debuff": 1, "charm": 1, "mental": 1},
		"stackable": false,
		"duration": 20.0,
		"icon": "res://UI/UI Icons/stunned.png",
		"transforms_into": {},
		"canceled_by_trait": ["clarity", "purify"],
		"custom_vfx": "res://vfx/infatuated_hearts.tscn",
		"custom_sfx": "",
		"stat_modifiers": [],
		"triggered_effects": [],
		"immunities": {}
	},
	{
		"id": "confused",
		"display_name": "Confused",
		"description": "Attacks random creatures regardless of faction.",
		"traits": {"debuff": 1, "cc": 1, "mental": 1},
		"stackable": false,
		"duration": 15.0,
		"icon": "res://UI/UI Icons/stunned.png",
		"transforms_into": {},
		"canceled_by_trait": ["clarity", "purify"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "targeting_confusion", "operation": "add", "value": 50}
		],
		"triggered_effects": [],
		"immunities": {}
	},
	{
		"id": "frightened",
		"display_name": "Frightened",
		"description": "Terrified of a specific creature and compelled to flee from them.",
		"traits": {"debuff": 1, "fear": 1, "mental": 1},
		"stackable": false,
		"duration": 15.0,
		"icon": "res://UI/UI Icons/stunned.png",
		"transforms_into": {},
		"canceled_by_trait": ["courage", "purify"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "dexterity", "operation": "multiply", "value": 0.8}
		],
		"triggered_effects": [],
		"immunities": {}
	},
	{
		"id": "panicked",
		"display_name": "Panicked",
		"description": "Overcome with terror, running in random directions.",
		"traits": {"debuff": 1, "fear": 2, "mental": 1, "cc": 1},
		"stackable": false,
		"duration": 10.0,
		"icon": "res://UI/UI Icons/panicked.png",
		"transforms_into": {},
		"canceled_by_trait": ["courage", "purify"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "speed_modifier", "operation": "add", "value": 0.3}
		],
		"triggered_effects": [],
		"immunities": {}
	},
	{
		"id": "sickened",
		"display_name": "Sickened",
		"description": "Diseased, with reduced strength and constitution. May spread to nearby creatures.",
		"traits": {"debuff": 1, "disease": 1, "physical": 1},
		"stackable": true,
		"max_tier": 3,
		"duration": 30.0,
		"icon": "res://UI/UI Icons/weakened.png",
		"transforms_into": {},
		"canceled_by_trait": ["purify", "antidote"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "strength", "operation": "add", "value": -15},
			{"stat": "constitution", "operation": "add", "value": -10}
		],
		"triggered_effects": [
			{
				"type": "custom",
				"custom_type": "spread_sickness",
				"interval": 5.0,
				"custom_data": {"chance": 0.3, "radius_tiles": 2}
			}
		],
		"immunities": {}
	},
	{
		"id": "nauseated",
		"display_name": "Nauseated",
		"description": "Sickly and slow, with a chance to vomit acid instead of acting.",
		"traits": {"debuff": 1, "disease": 1, "physical": 1},
		"stackable": false,
		"duration": 20.0,
		"icon": "res://UI/UI Icons/weakened.png",
		"transforms_into": {},
		"canceled_by_trait": ["purify", "antidote"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "speed_modifier", "operation": "add", "value": -0.4}
		],
		"triggered_effects": [
			{
				"type": "custom",
				"custom_type": "vomit",
				"interval": 4.0,
				"custom_data": {"chance": 0.4, "fluid_type": "acid", "amount": 0.3}
			}
		],
		"immunities": {}
	},
	{
		"id": "animal_magnetism",
		"display_name": "Animal Magnetism",
		"description": "Exudes a supernatural aura that attracts wild animals to spawn nearby.",
		"traits": {"buff": 1, "nature": 1, "magical": 1},
		"stackable": false,
		"duration": 30.0,
		"icon": "res://UI/UI Icons/mighty.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [],
		"triggered_effects": [
			{
				"type": "custom",
				"custom_type": "spawn_animal",
				"interval": 6.0,
				"custom_data": {"templates": ["wild_wolf"], "radius_tiles": 3}
			}
		],
		"immunities": {}
	},
	{
		"id": "fatal_attraction",
		"display_name": "Fatal Attraction",
		"description": "Bound by a deadly infatuation. If either partner dies, the other dies too.",
		"traits": {"debuff": 1, "charm": 1, "mental": 1, "curse": 1},
		"stackable": false,
		"duration": 30.0,
		"icon": "res://UI/UI Icons/stunned.png",
		"transforms_into": {},
		"canceled_by_trait": ["clarity", "purify"],
		"custom_vfx": "res://vfx/infatuated_hearts.tscn",
		"custom_sfx": "",
		"stat_modifiers": [],
		"triggered_effects": [],
		"immunities": {}
	},
	{
		"id": "blinded",
		"display_name": "Blinded",
		"description": "Cannot see. Does not contribute to party visibility.",
		"traits": {"debuff": 1, "sensory": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": 10.0,
		"icon": "res://UI/UI Icons/blinded.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "sight", "operation": "set", "value": 0}
		],
		"triggered_effects": [],
		"immunities": {}
	},
	{
		"id": "unconscious",
		"display_name": "Unconscious",
		"description": "Knocked out. Cannot see or take any actions.",
		"traits": {"debuff": 1, "incapacitate": 1, "sensory": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": 30.0,
		"icon": "res://UI/UI Icons/unconscious.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "res://vfx/unconscious.tscn",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "move_speed", "operation": "set", "value": 0},
			{"stat": "sight", "operation": "set", "value": 0}
		],
		"triggered_effects": [],
		"immunities": {}
	},
	{
		"id": "thrill_of_sin",
		"display_name": "Thrill of Sin",
		"description": "Luck increases each time a criminal action is taken.",
		"traits": {"buff": 1, "racial": 1, "passive": 1},
		"stackable": true,
		"max_tier": 20,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "luck", "operation": "add", "value": 1}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {},
		"on_action_trait_stack": {"required_traits": ["criminal"]}
	},
	{
		"id": "bleeding",
		"display_name": "Bleeding",
		"description": "An open wound is bleeding, causing blood loss over time. A CON save on application reduces the tier applied; another save fires every damage tick.",
		"traits": {"debuff": 1, "physical": 1, "dot": 1, "persistent": 1},
		"stackable": true,
		"max_tier": 5,
		"duration": 30.0,
		"save_stat": "con",
		"save_interval": 6.0,
		"icon": "res://UI/UI Icons/weakened.png",
		"transforms_into": {},
		"canceled_by_trait": ["bandage", "healing"],
		"custom_vfx": "res://vfx/bleeding.tscn",
		"custom_sfx": "",
		"stat_modifiers": [],
		"triggered_effects": [
			{
				"type": "damage",
				"value": 1,
				"damage_type": "true",
				"interval": 6.0
			},
			{
				"type": "custom",
				"custom_type": "bleed_puddle",
				"interval": 2.0,
				"custom_data": {"amount": 0.05}
			}
		],
		"immunities": {}
	},
	{
		"id": "undead_resilience",
		"display_name": "Undead Resilience",
		"description": "The unliving body is immune to disease.",
		"traits": {"passive": 1, "racial": 1, "undead": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {"sickened": true, "nauseated": true}
	},
	{
		"id": "bide",
		"display_name": "Bide",
		"description": "Storing up energy from incoming attacks. The next attack after this expires deals bonus base damage equal to the physical damage absorbed.",
		"traits": {"buff": 1, "self": 1, "delayed": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": 10.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "physically_resistant",
		"display_name": "Physically Resistant",
		"description": "Hardened against physical blows; reduces incoming physical damage.",
		"traits": {"buff": 1, "physical_resistance": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": 10.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "dr", "operation": "add", "value": 25}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "apathetic",
		"display_name": "Apathetic",
		"description": "Overcome with dysthymia. Cannot take any actions except movement.",
		"traits": {"debuff": 1, "mental": 1, "cc": 2, "incapacitate": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": 8.0,
		"icon": "res://UI/UI Icons/stunned.png",
		"transforms_into": {},
		"canceled_by_trait": ["clarity", "purify"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "deny_ending",
		"display_name": "Deny Ending",
		"description": "Refuses to die. HP cannot drop below 1 while this is active.",
		"traits": {"buff": 1, "occult": 1, "holy": 1, "death_ward": 1},
		"stackable": true,
		"max_tier": 5,
		"duration": 6.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "stuck_in_fire",
		"display_name": "Stuck in Fire",
		"description": "Mired in clinging flames. Cannot move and burns over time.",
		"traits": {"debuff": 1, "fire": 1, "dot": 1, "elemental": 1, "immobilize": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": 2.0,
		"icon": "res://UI/UI Icons/burning.png",
		"transforms_into": {},
		"canceled_by_trait": ["water", "cold"],
		"custom_vfx": "res://vfx/fire.tscn",
		"custom_sfx": "res://sfx/burning_flesh.mp3",
		"stat_modifiers": [
			{"stat": "speed_modifier", "operation": "set", "value": -1.0}
		],
		"triggered_effects": [
			{"type": "damage", "value": 5, "damage_type": "fire", "interval": 1.0}
		],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "the_jaws_that_bite",
		"display_name": "The Jaws That Bite",
		"description": "Mutated maw. Your bite attacks (bound to Z) have a chance to cause bleeding; the tier of bleeding applied scales with the tier of this mutation.",
		"traits": {"mutation": 1, "mutations": 1, "passive": 1, "racial": 1},
		"stackable": true,
		"max_tier": 5,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "",
		"custom_sfx": "",
		"grants_ability": "natural_bite",
		"stat_modifiers": [],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "the_claws_that_catch",
		"display_name": "The Claws That Catch",
		"description": "Mutated talons. Your unarmed strikes have a chance to grapple, halting your foes (Str save resists).",
		"traits": {"mutation": 1, "mutations": 1, "passive": 1, "racial": 1},
		"stackable": true,
		"max_tier": 5,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "grappled",
		"display_name": "Grappled",
		"description": "Held fast. Cannot move until you break free. STR save on application reduces tier; another save fires every 2s while held.",
		"traits": {"debuff": 1, "physical": 1, "cc": 1, "immobilize": 1},
		"stackable": true,
		"max_tier": 5,
		"duration": 6.0,
		"save_stat": "str",
		"save_interval": 2.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "speed_modifier", "operation": "set", "value": -1.0}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "verdant_blessing",
		"display_name": "Verdant Blessing",
		"description": "Standing in lush growth. Movement is slower but the green restores vitality.",
		"traits": {"buff": 1, "primal": 1, "nature": 1, "regeneration": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": 7.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "speed_modifier", "operation": "add", "value": -0.5}
		],
		"triggered_effects": [
			{"type": "heal", "value": 3, "interval": 6.0}
		],
		"conditional_modifiers": [],
		"immunities": {}
	}
]
