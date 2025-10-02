# res://Data/Items/Equipment.gd
# This single Resource defines ALL equippable items, from armor to weapons.
extends Resource
class_name Equipment

# All possible equipment slots, including hands.
enum Slot { HEAD, ARMOR, GLOVES, BOOTS, CAPE, NECK, RING, MAIN_HAND, OFF_HAND }

@export var id: StringName
@export var name: String
@export_multiline var description: String
@export var slot: Slot

# --- Defensive Properties (For Armor & Shields) ---
# Positive values reduce damage, negative values increase it.
@export var damage_resistances: Dictionary = {}

# --- Offensive Properties (For Weapons) ---
@export var damage: Dictionary = {"bludgeoning": 1}
@export var primary_damage_type = "bludgeoning"
@export var range: float = 0.0
@export var aoe_shape: StringName = &"slash"
@export var aoe_size: Vector2i = Vector2i.ONE

# Paths to the textures for each direction
@export var texture_front: Texture2D
@export var texture_back: Texture2D
@export var texture_left: Texture2D
@export var texture_right: Texture2D

# NEW: Helper function to get the right texture based on the Direction enum
func get_texture_for_direction(direction: CombatCharacter.Direction) -> Texture2D:
	match direction:
		CombatCharacter.Direction.DOWN: return texture_front
		CombatCharacter.Direction.UP: return texture_back
		CombatCharacter.Direction.LEFT: return texture_left
		CombatCharacter.Direction.RIGHT: return texture_right
	return texture_front # Default fallback
