# res://Data/Conditions/ConditionEffect.gd
# Defines a single, modular effect that a Condition can apply.
extends Resource
class_name ConditionEffect

enum EffectType {
	# Stat & Attribute Mods
	MOD_STAT,
	MOD_DAMAGE_RESISTANCE,
	MOD_MOVESPEED,
	MOD_MAX_AP,
	MOD_TOUCH_RANGE,
	MOD_WEAPON_ATTACK_SIZE,
	MOD_CRIT_CHANCE_ROLL,

	# Trait & Condition Interactions
	ADD_TRAIT,
	REMOVE_TRAIT,
	APPLY_CONDITION,
	SET_IMMUNITY,

	# Turn-Based & Action-Based Effects
	DAMAGE_OVER_TIME,
	MODIFY_AP_COST,
	BONUS_DAMAGE_VS_TRAIT,
	
	# --- NEW EFFECTS ---
	FORCE_UNEQUIP,          # Force a piece of gear to be unequipped.
	SCRAMBLE_TARGET,        # Cause attacks to target a random nearby tile.
	RESTRICT_ACTION_TRAIT   # Prevent actions with a specific trait (e.g., "auditory").
}

@export var type: EffectType
@export var params: Dictionary
