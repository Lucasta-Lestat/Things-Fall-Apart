# Armor.gd
extends Resource
class_name Armor

@export var name: String = "Armor"
@export var body_parts_covered: Array[String] = []
@export var damage_reduction: Dictionary = {
	"slashing": 0,
	"piercing": 0,
	"bludgeoning": 0,
	"fire": 0,
	"electric": 0
}

func get_dr(damage_type: String) -> float:
	if damage_reduction.has(damage_type):
		return damage_reduction[damage_type]
	return 0.0
