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
		# === DEBUFFS / NEGATIVE CONDITIONS ===
		
		# Simple stat reduction
		{
			"id": "weakened",
			"display_name": "Weakened",
			"description": "Physical attacks deal less damage.",
			"tier": 1,
			"traits": ["debuff", "physical"],
			"stackable": true,
			"max_stacks": 5,
			"duration": 30.0,
			"stat_modifiers": [
				{"stat": "STR", "operation": "add", "value": -2}
			]
		},
		
		# Constitution reduction (your example)
		{
			"id": "exhausted",
			"display_name": "Exhausted",
			"description": "Severely fatigued, reducing constitution.",
			"tier": 2,
			"traits": ["debuff", "fatigue"],
			"stackable": false,
			"duration": 60.0,
			"stat_modifiers": [
				{"stat": "CON", "operation": "add", "value": -7}
			]
		},
		
		# Damage over time - Poison
		{
			"id": "poisoned",
			"display_name": "Poisoned",
			"description": "Taking poison damage over time.",
			"tier": 1,
			"traits": ["debuff", "poison", "dot"],
			"stackable": true,
			"max_stacks": 10,
			"duration": 20.0,
			"stat_modifiers": [],
			"triggered_effects": [
				{
					"type": "damage",
					"value": 5,  # Per stack
					"damage_type": "poison",
					"interval": 2.0  # Every 2 seconds
				}
			]
		},
		
		# Damage over time - Burning (more severe)
		{
			"id": "burning",
			"display_name": "Burning",
			"description": "Engulfed in flames, taking fire damage.",
			"tier": 2,
			"traits": ["debuff", "fire", "dot", "elemental"],
			"stackable": true,
			"max_stacks": 5,
			"duration": 10.0,
			"triggered_effects": [
				{
					"type": "damage",
					"value": 15,
					"damage_type": "fire",
					"interval": 1.0
				}
			]
		},
		
		# Crowd control - Stun
		{
			"id": "stunned",
			"display_name": "Stunned",
			"description": "Cannot take actions.",
			"tier": 3,
			"traits": ["debuff", "cc", "stun", "incapacitate"],
			"stackable": false,
			"duration": 3.0,
			"stat_modifiers": [
				{"stat": "EVASION", "operation": "set", "value": 0},
				{"stat": "SPEED", "operation": "set", "value": 0}
			]
		},
		
		# Slow effect
		{
			"id": "chilled",
			"display_name": "Chilled",
			"description": "Movement and attack speed reduced.",
			"tier": 1,
			"traits": ["debuff", "cold", "slow", "elemental"],
			"stackable": true,
			"max_stacks": 3,
			"duration": 15.0,
			"stat_modifiers": [
				{"stat": "SPEED", "operation": "multiply", "value": 0.85}  # 15% slow per stack (compounds)
			]
		},
		
		# Frozen (upgraded chill)
		{
			"id": "frozen",
			"display_name": "Frozen",
			"description": "Encased in ice, unable to move.",
			"tier": 3,
			"traits": ["debuff", "cold", "cc", "incapacitate", "elemental"],
			"stackable": false,
			"duration": 5.0,
			"stat_modifiers": [
				{"stat": "SPEED", "operation": "set", "value": 0},
				{"stat": "EVASION", "operation": "set", "value": 0}
			],
			"immunities": ["chilled"]  # Can't be chilled while frozen
		},
		
		# === BUFFS / POSITIVE CONDITIONS ===
		
		# Strength buff
		{
			"id": "might",
			"display_name": "Might",
			"description": "Increased physical power.",
			"tier": 1,
			"traits": ["buff", "physical", "enhancement"],
			"stackable": false,
			"duration": 60.0,
			"stat_modifiers": [
				{"stat": "STR", "operation": "add", "value": 5},
				{"stat": "DAMAGE", "operation": "multiply", "value": 1.15}
			]
		},
		
		# Haste - speed buff
		{
			"id": "haste",
			"display_name": "Haste",
			"description": "Moving and acting faster.",
			"tier": 2,
			"traits": ["buff", "speed", "magical"],
			"stackable": false,
			"duration": 30.0,
			"stat_modifiers": [
				{"stat": "SPEED", "operation": "multiply", "value": 1.5},
				{"stat": "EVASION", "operation": "add", "value": 10}
			]
		},
		
		# Regeneration
		{
			"id": "regenerating",
			"display_name": "Regenerating",
			"description": "Health restoring over time.",
			"tier": 1,
			"traits": ["buff", "healing", "hot"],
			"stackable": true,
			"max_stacks": 3,
			"duration": 20.0,
			"triggered_effects": [
				{
					"type": "heal",
					"value": 10,
					"interval": 2.0
				}
			]
		},
		
		# Shield / Barrier
		{
			"id": "shielded",
			"display_name": "Shielded",
			"description": "Protected by a magical barrier.",
			"tier": 2,
			"traits": ["buff", "shield", "magical", "protection"],
			"stackable": false,
			"duration": 45.0,
			"stat_modifiers": [
				{"stat": "ARMOR", "operation": "add", "value": 25}
			],
			"immunities": ["burning", "chilled"]  # Shield blocks elemental effects
		},
		
		# === TRAIT-BASED CONDITIONAL MODIFIERS ===
		
		# Giantslayer - bonus damage vs giants
		{
			"id": "giantslayer",
			"display_name": "Giantslayer",
			"description": "Attacks deal +5 damage against giants.",
			"tier": 2,
			"traits": ["buff", "slayer", "racial"],
			"stackable": false,
			"duration": -1,  # Permanent until removed
			"stat_modifiers": [],
			"conditional_modifiers": [
				{
					"trigger_type": 0,  # ON_ATTACK
					"modifier_type": 0,  # FLAT_DAMAGE
					"value": 5,
					"target_traits": "giant",  # Only vs giants
					"action_traits": ["attack"],
					"scales_with_stacks": false
				}
			]
		},
		
		# Dragonbane - percentage damage vs dragons
		{
			"id": "dragonbane",
			"display_name": "Dragonbane",
			"description": "Attacks deal 25% more damage against dragons.",
			"tier": 3,
			"traits": ["buff", "slayer", "racial"],
			"stackable": false,
			"duration": -1,
			"conditional_modifiers": [
				{
					"trigger_type": 0,  # ON_ATTACK
					"modifier_type": 1,  # PERCENT_DAMAGE
					"value": 25,  # 25% more
					"target_traits": "dragon",
					"action_traits": null,  # Any action
					"scales_with_stacks": false
				}
			]
		},
		
		# Arcane Amplification - bonus damage with spells
		{
			"id": "arcane_amplification",
			"display_name": "Arcane Amplification",
			"description": "Spell attacks deal 15% more damage.",
			"tier": 2,
			"traits": ["buff", "magical", "enhancement"],
			"stackable": true,
			"max_stacks": 3,
			"duration": 30.0,
			"conditional_modifiers": [
				{
					"trigger_type": 0,  # ON_ATTACK
					"modifier_type": 1,  # PERCENT_DAMAGE
					"value": 15,
					"source_traits": null,
					"target_traits": null,
					"action_traits": "spell",  # Only for spells
					"scales_with_stacks": true  # 15% per stack
				}
			]
		},
		
		# Undead Bane - holy damage bonus vs undead
		{
			"id": "holy_weapon",
			"display_name": "Holy Weapon",
			"description": "Weapon deals bonus holy damage to undead.",
			"tier": 2,
			"traits": ["buff", "holy", "weapon_enchant"],
			"stackable": false,
			"duration": 120.0,
			"conditional_modifiers": [
				{
					"trigger_type": 0,  # ON_ATTACK
					"modifier_type": 0,  # FLAT_DAMAGE
					"value": 20,
					"target_traits": "undead",
					"action_traits": ["attack", "melee"],
					"scales_with_stacks": false
				}
			]
		},
		
		# Defensive stance - damage reduction when defending
		{
			"id": "defensive_stance",
			"display_name": "Defensive Stance",
			"description": "Taking 20% less damage from all attacks.",
			"tier": 1,
			"traits": ["buff", "stance", "defensive"],
			"stackable": false,
			"duration": -1,  # Until stance changes
			"stat_modifiers": [
				{"stat": "SPEED", "operation": "multiply", "value": 0.7}  # 30% slower
			],
			"conditional_modifiers": [
				{
					"trigger_type": 1,  # ON_DEFEND
					"modifier_type": 1,  # PERCENT_DAMAGE (negative = reduction)
					"value": -20,  # 20% reduction
					"source_traits": null,
					"target_traits": null,
					"action_traits": null,
					"scales_with_stacks": false
				}
			]
		},
		
		# Magic resistance - reduced magical damage
		{
			"id": "magic_resistance",
			"display_name": "Magic Resistance",
			"description": "Resistant to magical attacks.",
			"tier": 2,
			"traits": ["buff", "resistance", "magical"],
			"stackable": true,
			"max_stacks": 5,
			"duration": 60.0,
			"conditional_modifiers": [
				{
					"trigger_type": 1,  # ON_DEFEND
					"modifier_type": 1,  # PERCENT_DAMAGE
					"value": -10,  # 10% reduction per stack
					"action_traits": "magical",
					"scales_with_stacks": true
				}
			]
		},
		
		# Berserker rage - damage boost when HP low
		# (Note: This would need special handling to check HP percentage)
		{
			"id": "berserker_rage",
			"display_name": "Berserker Rage",
			"description": "Increased damage but reduced defense.",
			"tier": 2,
			"traits": ["buff", "rage", "stance"],
			"stackable": false,
			"duration": 15.0,
			"stat_modifiers": [
				{"stat": "DAMAGE", "operation": "multiply", "value": 1.5},
				{"stat": "ARMOR", "operation": "multiply", "value": 0.5},
				{"stat": "CRIT_CHANCE", "operation": "add", "value": 20}
			]
		},
		
		# === COMPLEX CONDITIONS ===
		
		# Marked for Death - makes target take more damage from all sources
		{
			"id": "marked_for_death",
			"display_name": "Marked for Death",
			"description": "Taking 15% increased damage from all sources.",
			"tier": 2,
			"traits": ["debuff", "mark", "vulnerability"],
			"stackable": false,
			"duration": 20.0,
			"conditional_modifiers": [
				{
					"trigger_type": 1,  # ON_DEFEND
					"modifier_type": 1,  # PERCENT_DAMAGE (positive = increased)
					"value": 15,  # 15% MORE damage taken
					"scales_with_stacks": false
				}
			]
		},
		
		# Vampiric Touch - applies lifesteal to attacks
		{
			"id": "vampiric_touch",
			"display_name": "Vampiric Touch",
			"description": "Attacks heal for 20% of damage dealt.",
			"tier": 3,
			"traits": ["buff", "lifesteal", "dark", "magical"],
			"stackable": false,
			"duration": 45.0,
			"conditional_modifiers": [
				{
					"trigger_type": 3,  # ON_DAMAGE_DEALT
					"modifier_type": 10,  # CUSTOM - needs special handler
					"custom_handler": "lifesteal",
					"custom_data": {"percent": 20},
					"scales_with_stacks": false
				}
			]
		},
		
		# Thorns - reflect damage to attackers
		{
			"id": "thorns",
			"display_name": "Thorns",
			"description": "Attackers take 10 damage when hitting you.",
			"tier": 2,
			"traits": ["buff", "reflect", "physical"],
			"stackable": true,
			"max_stacks": 5,
			"duration": 60.0,
			"conditional_modifiers": [
				{
					"trigger_type": 4,  # ON_DAMAGE_TAKEN
					"modifier_type": 10,  # CUSTOM
					"custom_handler": "reflect_damage",
					"custom_data": {"flat_damage": 10},
					"scales_with_stacks": true
				}
			]
		}
	]
