# res://Data/Weapons/Weapon.gd
# A new Resource script to define weapons.
extends Resource
class_name Weapon

@export var id: StringName
@export var display_name: String
@export var range: float = 50.0
@export var base_damage: int = 5
@export var damage_types: Dictionary = {"Bludgeoning": 5}
@export var sprite: Texture2D
