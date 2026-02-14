# res://Data/Traits/TraitDatabase.gd
# A new autoload singleton for all character traits.
extends Node

var traits: Dictionary = {}

func _ready():
	_define_traits()

func _define_traits():
	var deadeye = Trait.new()
	deadeye.id = &"deadeye"
	deadeye.display_name = "Deadeye"
	deadeye.description = "Improves accuracy with ranged attacks. (+20 to target per tier)"
	traits[deadeye.id] = deadeye

	var clumsy = Trait.new()
	clumsy.id = &"clumsy"
	clumsy.display_name = "Clumsy"
	clumsy.description = "Reduces accuracy with physical actions. (-20 to target per tier)"
	traits[clumsy.id] = clumsy

func get_trait(trait_id: StringName) -> Trait:
	return traits.get(trait_id, null)
