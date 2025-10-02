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
	move.range_type = Ability.RangeType.ABILITY
	move.ap_cost = 1
	move.range = 2100 
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
	basic_attack.range_type = Ability.RangeType.WEAPON_MELEE
	#basic_attack.target_type = Ability.TargetType.ENEMY
	basic_attack.effect = Ability.ActionEffect.DAMAGE
	basic_attack.is_weapon_attack = true
	basic_attack.success_stat = &"dex" # This attack uses Dexterity to hit
	basic_attack.advantages = [&"deadeye"]
	basic_attack.disadvantages = [&"clumsy"]
	abilities[basic_attack.id] = basic_attack

	var cleave = Ability.new()
	print(cleave)
	cleave.id = &"cleave"
	cleave.display_name = "Cleave"
	cleave.description = "hit multipLe."
	cleave.ap_cost = 3
	cleave.aoe_shape = &"slash"
	cleave.range = 350.0
	cleave.range_type = Ability.RangeType.WEAPON_MELEE
	#cleave.attack_shape = Ability.AttackShape.SLASH
	cleave.target_type = Ability.TargetType.ENEMY
	cleave.effect = Ability.ActionEffect.DAMAGE
	cleave.is_weapon_attack = true
	cleave.success_stat = &"dex" # This attack uses Dexterity to hit
	cleave.advantages = [&"deadeye"]
	cleave.disadvantages = [&"clumsy"]
	abilities[cleave.id] = cleave
	
	
	var wait = Ability.new(); wait.id = &"wait"; wait.display_name = "Wait"
	wait.effect = Ability.ActionEffect.BUFF # Technically does nothing
	wait.target_type = Ability.TargetType.SELF; wait.ap_cost = 1
	wait.success_stat = &""; abilities[&"wait"] = wait
	
	var fireball = Ability.new(); fireball.id = &"fireball"; fireball.display_name = "Fireball"
	fireball.effect = Ability.ActionEffect.DAMAGE; fireball.target_type = Ability.TargetType.GROUND
	fireball.range_type = Ability.RangeType.ABILITY; fireball.range = 1000.0 # Long range
	fireball.success_stat = &"int"; fireball.ap_cost = 3; fireball.damage = {"fire":25}
	fireball.aoe_shape = &"circle"
	fireball.aoe_size = Vector2i(3, 3) # Radius of 3
	fireball.primary_damage_type = &"fire"
	abilities[&"fireball"] = fireball

func get_ability(ability_id: StringName) -> Ability:
	return abilities.get(ability_id, null)
