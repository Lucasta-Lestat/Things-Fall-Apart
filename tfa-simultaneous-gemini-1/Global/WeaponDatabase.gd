# res://Data/Weapons/WeaponDatabase.gd
# A new autoload singleton for all your game's weapons.
extends Node

var weapons: Dictionary = {}

func _ready():
	_define_weapons()

func _define_weapons():
	var short_sword = Weapon.new()
	short_sword.id = &"short_sword"
	short_sword.display_name = "Short Sword"
	short_sword.base_damage = 10
	weapons[short_sword.id] = short_sword

	var longbow = Weapon.new()
	longbow.id = &"longbow"
	longbow.display_name = "Longbow"
	longbow.base_damage = 12
	weapons[longbow.id] = longbow
	
	var rusty_dagger = Weapon.new()
	rusty_dagger.id = &"rusty_dagger"
	rusty_dagger.display_name = "Rusty Dagger"
	rusty_dagger.base_damage = 4
	weapons[rusty_dagger.id] = rusty_dagger

func get_weapon(weapon_id: StringName) -> Weapon:
	return weapons.get(weapon_id, null)
