# res://Data/Conditions/ConditionDatabase.gd
# Autoload Singleton
# Stores all defined conditions and passive abilities for the game.
extends Node

var conditions: Dictionary = {}

func _ready():
	_define_conditions()

func get_condition(id: StringName) -> Condition:
	if conditions.has(id):
		return conditions[id]
	printerr("Condition with id '", id, "' not found in database.")
	return null

func _define_conditions():
	# --- PASSIVE ABILITIES ---
	var dragonslayer_passive = Condition.new()
	dragonslayer_passive.id = &"dragonslayer_passive"
	dragonslayer_passive.display_name = "Dragonslayer"
	dragonslayer_passive.category = Condition.ConditionCategory.PASSIVE
	var dragonslayer_effect = ConditionEffect.new()
	dragonslayer_effect.type = ConditionEffect.EffectType.BONUS_DAMAGE_VS_TRAIT
	dragonslayer_effect.params = {"trait_id": &"draconic", "bonus_damage": {"holy": 20}}
	dragonslayer_passive.effects.append(dragonslayer_effect)
	conditions[dragonslayer_passive.id] = dragonslayer_passive
	
	# --- DEBUFFS ---
	var burning_debuff = Condition.new()
	burning_debuff.id = &"burning"
	burning_debuff.display_name = "Burning"
	burning_debuff.category = Condition.ConditionCategory.DEBUFF
	burning_debuff.max_tier = 3
	burning_debuff.duration_in_rounds = 3
	# Effect 1: Take fire damage every turn
	var dot_effect = ConditionEffect.new()
	dot_effect.type = ConditionEffect.EffectType.DAMAGE_OVER_TIME
	dot_effect.params = {"damage_per_tier": {"fire": 5}}
	burning_debuff.effects.append(dot_effect)
	# Effect 2: Lower fire resistance
	var dr_effect = ConditionEffect.new()
	dr_effect.type = ConditionEffect.EffectType.MOD_DAMAGE_RESISTANCE
	dr_effect.params = {"resistance": {"fire": -10}} # Per tier
	burning_debuff.effects.append(dr_effect)
	conditions[burning_debuff.id] = burning_debuff

	var clumsy_debuff = Condition.new()
	clumsy_debuff.id = &"clumsy"
	clumsy_debuff.display_name = "Clumsy"
	clumsy_debuff.category = Condition.ConditionCategory.DEBUFF
	clumsy_debuff.max_tier = 1
	clumsy_debuff.duration_in_rounds = 2
	# Effect 1: Increase AP cost of dexterous actions
	var ap_cost_effect = ConditionEffect.new()
	ap_cost_effect.type = ConditionEffect.EffectType.MODIFY_AP_COST
	ap_cost_effect.params = {"advantage_id": &"dexterous", "cost_increase": 1}
	clumsy_debuff.effects.append(ap_cost_effect)
	# Effect 2: Lower Dexterity stat
	var dex_mod_effect = ConditionEffect.new()
	dex_mod_effect.type = ConditionEffect.EffectType.MOD_STAT
	dex_mod_effect.params = {"stat": &"dexterity", "value": -20}
	clumsy_debuff.effects.append(dex_mod_effect)
	conditions[clumsy_debuff.id] = clumsy_debuff
