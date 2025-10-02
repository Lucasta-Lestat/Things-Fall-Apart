# res://Data/Characters/BodyPart.gd
# A new Resource to define a visual part of a character, like a head or body.
extends Resource
class_name BodyPart

@export var id: StringName
@export var type: String # e.g., "head", "body"

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
