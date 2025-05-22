# res://Core/CombatSystem/domain_trait_modifiers.gd
extends Node

const DOMAIN_DATA = {
	"default": {"positive_traits": [], "negative_traits": []},
	"weapon_attack_melee": {
		"positive_traits": ["martial_focus", "strong_grip", "melee_adept", "berserker_rage"],
		"negative_traits": ["clumsy", "frail_arms", "pacifist_oath"]
	},
	"weapon_attack_ranged": {
		"positive_traits": ["sharpshooter", "keen_eye", "ranged_adept", "steady_hands"],
		"negative_traits": ["shaky_hands", "poor_depth_perception", "bulky_armor"]
	},
	"spell_cast_fire": {
		"positive_traits": ["fire_attunement", "pyromancer_bloodline", "elemental_scholar_fire"],
		"negative_traits": ["water_logged", "fear_of_fire", "arcane_dampening"]
	},
	"spell_cast_healing": {
		"positive_traits": ["healers_touch", "empathetic", "life_affinity"],
		"negative_traits": ["callous", "necrotic_aura"]
	},
	"spell_cast_general": {
		"positive_traits": ["arcane_scholar", "focused_caster", "mana_adept"],
		"negative_traits": ["mana_sensitive", "easily_distracted", "wild_magic_interference"]
	},
	"dodge_check": {
		"positive_traits": ["agile", "nimble", "precognitive_reflexes"],
		"negative_traits": ["encumbered", "slow_reflexes", "flat_footed"]
	},
	"perception_check": {
		"positive_traits": ["keen_senses", "observant", "danger_sense"],
		"negative_traits": ["oblivious", "poor_eyesight", "distracted_mind"]
	}
}
const TRAIT_MODIFIER_VALUE: int = 20

static func get_trait_modifier_for_check(character_traits: Array[String], domain_name: String) -> int:
	var modifier: int = 0
	var domain_info = DOMAIN_DATA.get(domain_name, DOMAIN_DATA["default"])

	for trait_key in domain_info.positive_traits: # Iterate over keys (trait names)
		if trait_key in character_traits:
			modifier += TRAIT_MODIFIER_VALUE
	for trait_key in domain_info.negative_traits:
		if trait_key in character_traits:
			modifier -= TRAIT_MODIFIER_VALUE
	return modifier
