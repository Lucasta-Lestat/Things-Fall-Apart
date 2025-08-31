# res://Data/Traits/Trait.gd
# A new Resource script to define traits like "Deadeye" or "Clumsy".
extends Resource
class_name Trait

@export var id: StringName
@export var display_name: String
@export_multiline var description: String
