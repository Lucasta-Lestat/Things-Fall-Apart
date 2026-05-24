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
	},
	# -----------------------------------------------------------------------
	# Stress-response conditions (d100 roll table). Negative entries are tagged
	# with {"affliction": 1, "mental": 1} so the Carousing downtime activity's
	# `remove_mental_affliction` effect — which dispatches to
	# ConditionManager.remove_conditions_with_trait("mental") — can clear them.
	# -----------------------------------------------------------------------
	{
		"id": "fearful",
		"display_name": "Fearful",
		"description": "Easily shaken. Penalty to checks made against fear or panic.",
		"traits": {"debuff": 1, "affliction": 1, "mental": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": ["restoration", "courage"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "fear_save", "operation": "add", "value": -20}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "lethargic",
		"display_name": "Lethargic",
		"description": "Heavy-limbed. Movement is sluggish.",
		"traits": {"debuff": 1, "affliction": 1, "mental": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": ["restoration"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "speed_modifier", "operation": "add", "value": -0.25}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "masochistic",
		"display_name": "Masochistic",
		"description": "Seeks pain. Disadvantage on CON checks. Prayer and prostitution relieve more stress.",
		"traits": {"debuff": 1, "affliction": 1, "mental": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": ["restoration"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "constitution", "operation": "add", "value": -20}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "irrational",
		"display_name": "Irrational",
		"description": "Reasoning frays. Disadvantage on INT checks.",
		"traits": {"debuff": 1, "affliction": 1, "mental": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": ["restoration"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "intelligence", "operation": "add", "value": -20}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "paranoid",
		"display_name": "Paranoid",
		"description": "Sees enemies in friends. May lash out and shove nearby allies.",
		"traits": {"debuff": 1, "affliction": 1, "mental": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": ["restoration"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "selfish",
		"display_name": "Selfish",
		"description": "All for me. Disadvantage on CHA checks and saves.",
		"traits": {"debuff": 1, "affliction": 1, "mental": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": ["restoration"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "charisma", "operation": "add", "value": -20}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "panic",
		"display_name": "Panic",
		"description": "Blind, mindless flight. Cannot act sensibly until the panic passes.",
		"traits": {"debuff": 1, "affliction": 1, "mental": 1, "cc": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": 12.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": ["restoration", "courage"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "speed_modifier", "operation": "add", "value": 0.25}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "hopelessness",
		"display_name": "Hopelessness",
		"description": "Nothing matters. Disadvantage on Will checks.",
		"traits": {"debuff": 1, "affliction": 1, "mental": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": ["restoration"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "will", "operation": "add", "value": -20}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "mania",
		"display_name": "Mania",
		"description": "Manic episode. Unequips all gear and throws gold at the nearest creature. Cannot be dysthymic at the same time.",
		"traits": {"debuff": 1, "affliction": 1, "mental": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": ["restoration"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {"dysthymia": true}
	},
	{
		"id": "anxiety",
		"display_name": "Anxiety",
		"description": "Wound tight. Gain stress more quickly than usual.",
		"traits": {"debuff": 1, "affliction": 1, "mental": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": ["restoration"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "stress_gain_multiplier", "operation": "add", "value": 0.5}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "hypochondria",
		"display_name": "Hypochondria",
		"description": "Convinced of looming illness. Hit point maximum is halved.",
		"traits": {"debuff": 1, "affliction": 1, "mental": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": ["restoration"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "max_hp_multiplier", "operation": "add", "value": -0.5}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "narcissistic",
		"display_name": "Narcissistic",
		"description": "Always knows better. Challenges other characters' decisions when in disagreement.",
		"traits": {"debuff": 1, "affliction": 1, "mental": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": ["restoration"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	# ----- Positive stress responses (not afflictions) ---------------------
	{
		"id": "powerful",
		"display_name": "Powerful",
		"description": "Steel in the spine. +2 to all damage rolls.",
		"traits": {"buff": 1, "mental": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "damage_bonus", "operation": "add", "value": 2}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "focused",
		"display_name": "Focused",
		"description": "Clear-headed. +1 to maximum focus.",
		"traits": {"buff": 1, "mental": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "max_focus", "operation": "add", "value": 1}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "stalwart",
		"display_name": "Stalwart",
		"description": "Inured to harm. +1 DR against all damage types.",
		"traits": {"buff": 1, "mental": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "damage_resistance", "operation": "add", "value": 1}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "acute",
		"display_name": "Acute",
		"description": "Sharply observant. Advantage on INT checks.",
		"traits": {"buff": 1, "mental": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "intelligence", "operation": "add", "value": 20}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "perceptive",
		"display_name": "Perceptive",
		"description": "Sees further than most. Extended line of sight.",
		"traits": {"buff": 1, "mental": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "line_of_sight", "operation": "add", "value": 2}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "courageous",
		"display_name": "Courageous",
		"description": "Fearless. Advantage on Will checks. Suppresses the next affliction that would be rolled when going down.",
		"traits": {"buff": 1, "mental": 1, "courage": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "will", "operation": "add", "value": 20}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	# ----- Conditions referenced by downtime.json result effects -----------
	{
		"id": "hungover",
		"display_name": "Hungover",
		"description": "Pounding head, sour stomach. Disadvantage on perception until shaken off.",
		"traits": {"debuff": 1, "affliction": 1, "mental": 1, "fatigue": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": 240.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": ["restoration"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "constitution", "operation": "add", "value": -10}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "pox",
		"display_name": "Pox",
		"description": "An itch, a sore, a slow regret. A physical affliction worth treating.",
		"traits": {"debuff": 1, "affliction": 1, "physical": 1, "disease": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": ["restoration", "purify"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "charisma", "operation": "add", "value": -10}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "scarred",
		"display_name": "Scarred",
		"description": "Disfiguring wounds that ordinary healing cannot fully undo.",
		"traits": {"debuff": 1, "affliction": 1, "physical": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": ["remove_curse"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "charisma", "operation": "add", "value": -10}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "blessed",
		"display_name": "Blessed",
		"description": "Charged with quiet meaning. The world feels significant for a day.",
		"traits": {"buff": 1, "mental": 1, "blessing": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": 86400.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "will", "operation": "add", "value": 10}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "fatigued",
		"display_name": "Fatigued",
		"description": "Worn down by lost sleep or hard watch. Lighter version of exhausted.",
		"traits": {"debuff": 1, "affliction": 1, "mental": 1, "fatigue": 1},
		"stackable": true,
		"max_tier": 3,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {"id": "exhausted", "required_tier": 3},
		"canceled_by_trait": ["restoration"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "constitution", "operation": "add", "value": -5}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "haunted",
		"display_name": "Haunted",
		"description": "Something you read or saw will not leave you. Sleep is poor.",
		"traits": {"debuff": 1, "affliction": 1, "mental": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": ["restoration"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "will", "operation": "add", "value": -10}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "wanted",
		"display_name": "Wanted",
		"description": "The watch has your description. Guards in this region are hostile on sight.",
		"traits": {"debuff": 1, "affliction": 1, "social": 1, "legal": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": ["pardon"],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "stone_body",
		"display_name": "Stone Body",
		"description": "Flesh of granite. Immune to ordinary healing; can be repaired.",
		"traits": {"buff": 1, "stone": 1, "passive": 1},
		"stackable": false,
		"max_tier": 1,
		"duration": -1.0,
		"icon": "res://UI/UI Icons/dummy_icon.png",
		"transforms_into": {},
		"canceled_by_trait": [],
		"custom_vfx": "",
		"custom_sfx": "",
		"stat_modifiers": [
			{"stat": "heal_resist",  "operation": "add", "value": 100},
			{"stat": "natural_dr",   "operation": "add", "value": 3},
			{"stat": "max_hp_bonus", "operation": "add", "value": 10}
		],
		"triggered_effects": [],
		"conditional_modifiers": [],
		"immunities": {}
	},
	{
		"id": "anti_miser",
		"display_name": "Anti-miser",
		"description": "Refuses to pick up or carry gold.",
		"traits": {"flaw": 1, "psychological": 1, "passive": 1},
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
		"immunities": {}
	}
]
