# res://Data/Weapons/WeaponDatabase.gd
# An autoload singleton for all your game's weapons.
extends Node
'''
var weapons: Dictionary = {}

func _ready():
	_define_weapons()

func _define_weapons():
	var short_sword = Weapon.new()
	short_sword.id = &"short_sword"
	short_sword.display_name = "Short Sword"
	short_sword.base_damage = 4
	short_sword.aoe_shape = &"slash"
	short_sword.aoe_size = Vector2i(1, 1) # Affects a 1-tile L-shape
	weapons[short_sword.id] = short_sword

	var greatsword = Weapon.new()
	greatsword.id = &"greatsword"; greatsword.display_name = "Greatsword"
	greatsword.base_damage = 7; greatsword.range = 120.0
	greatsword.aoe_shape = &"slash"
	greatsword.aoe_size = Vector2i(2, 2) # Affects a 2-tile L-shape
	weapons[&"greatsword"] = greatsword
	
	var longbow = Weapon.new()
	longbow.id = &"longbow"; longbow.display_name = "Longbow"
	longbow.base_damage = 6; longbow.range = 1000.0
	longbow.aoe_shape = &"thrust" # A single arrow hits one tile
	longbow.aoe_size = Vector2i(1, 1)
	weapons[&"longbow"] = longbow

func get_weapon(weapon_id: StringName) -> Weapon:
	return weapons.get(weapon_id, null)
'''
