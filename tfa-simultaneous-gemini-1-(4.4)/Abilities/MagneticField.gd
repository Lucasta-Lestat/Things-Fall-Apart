# MagneticField.gd
# A magnetic force field that affects entities with the "metal" trait
# Can attract or repel based on polarity
class_name MagneticField
extends ForceField

enum Polarity {
	ATTRACT,  # Pull metal toward center
	REPEL,    # Push metal away from center
}

@export var polarity: Polarity = Polarity.ATTRACT

## Whether the field affects the "magnetized" condition trait as well
@export var affects_magnetized: bool = true

## Strength multiplier for magnetized entities
@export var magnetized_multiplier: float = 2.0

## Visual effect color
@export var field_color: Color = Color(0.2, 0.4, 1.0, 0.3)

## Optional: Apply "magnetized" condition to entities in field
@export var apply_magnetized_condition: bool = false


func _ready() -> void:
	# Set up default traits for magnetic field
	if required_traits.is_empty():
		required_traits = ["metal"]
		if affects_magnetized:
			required_traits.append("magnetized")
		trait_match_mode = TraitMatchMode.ANY
	
	# Set direction based on polarity
	match polarity:
		Polarity.ATTRACT:
			direction_type = DirectionType.TOWARD_CENTER
		Polarity.REPEL:
			direction_type = DirectionType.AWAY_FROM_CENTER
	
	# Magnetic fields typically follow inverse square law
	if force_type == ForceType.CONSTANT:
		force_type = ForceType.INVERSE_SQUARE
	
	# Add magnetized condition if configured
	if apply_magnetized_condition and "magnetized" not in conditions_to_apply:
		conditions_to_apply.append("magnetized")
	
	super._ready()


## Override magnitude calculation to account for magnetized multiplier
func _calculate_magnitude(entity: Node2D) -> float:
	var base_magnitude = super._calculate_magnitude(entity)
	
	# Check if entity is magnetized for bonus effect
	var entity_traits = _get_entity_traits(entity)
	if "magnetized" in entity_traits:
		base_magnitude *= magnetized_multiplier
	
	return base_magnitude


## Flip polarity
func flip_polarity() -> void:
	match polarity:
		Polarity.ATTRACT:
			polarity = Polarity.REPEL
			direction_type = DirectionType.AWAY_FROM_CENTER
		Polarity.REPEL:
			polarity = Polarity.ATTRACT
			direction_type = DirectionType.TOWARD_CENTER


## Create visual representation (call from _draw or use a shader)
func get_field_visual_data() -> Dictionary:
	return {
		"center": _field_center,
		"radius": _get_field_radius(),
		"color": field_color,
		"polarity": polarity,
		"strength": force_magnitude
	}
