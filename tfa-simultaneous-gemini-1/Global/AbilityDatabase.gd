# res://Data/Abilities/AbilityDatabase.gd
# A new autoload singleton to store and provide all defined abilities.
extends Node

var abilities: Dictionary = {}

func _ready():
	_define_abilities()

func _define_abilities():
	var move = Ability.new()
	move.id = &"move"
	move.display_name = "Move"
	move.ap_cost = 1
	move.range = 400 
	move.target_type = Ability.TargetType.GROUND
	move.effect = Ability.ActionEffect.MOVE
	abilities[move.id] = move
	
	var basic_attack = Ability.new()
	print(basic_attack)
	basic_attack.id = &"basic_attack"
	basic_attack.display_name = "Basic Attack"
	basic_attack.description = "A standard attack with your weapon."
	basic_attack.ap_cost = 2
	basic_attack.range = 150.0
	basic_attack.target_type = Ability.TargetType.ENEMY
	basic_attack.effect = Ability.ActionEffect.DAMAGE
	basic_attack.is_weapon_attack = true
	basic_attack.success_stat = &"dex" # This attack uses Dexterity to hit
	basic_attack.advantages = [&"deadeye"]
	basic_attack.disadvantages = [&"clumsy"]
	abilities[basic_attack.id] = basic_attack


func get_ability(ability_id: StringName) -> Ability:
	return abilities.get(ability_id, null)
