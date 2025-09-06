# res://Data/Weapons/Weapon.gd
# A new Resource script to define weapons.
extends Resource
class_name Weapon

enum AttackShape { SLASH, THRUST, RECTANGLE, NONE }


@export var id: StringName
@export var display_name: String
@export var range: float = 50.0
@export var base_damage: int = 5
@export var damage_types: Dictionary = {"Slashing": 5}
@export var sprite: Texture2D

# NEW: AoE properties for this weapon
@export_group("Area of Effect")
@export var aoe_shape: AttackShape = AttackShape.SLASH
# For SLASH/THRUST, x is length. For RECTANGLE, it's width/height.
@export var aoe_size: Vector2i = Vector2i.ONE
