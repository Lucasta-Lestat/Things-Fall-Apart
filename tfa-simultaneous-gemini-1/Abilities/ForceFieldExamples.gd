# ForceFieldExamples.gd
# Example implementations of various force field types
# These can be instantiated via scenes or created programmatically

extends Node

## =============================================================================
## FACTORY FUNCTIONS - Create force fields programmatically
## =============================================================================

## Create a magnetic field that pulls/pushes metal objects
static func create_magnetic_field(
	position: Vector2,
	radius: float,
	polarity: MagneticField.Polarity = MagneticField.Polarity.ATTRACT,
	strength: float = 500.0
) -> MagneticField:
	var field = MagneticField.new()
	field.global_position = position
	field.polarity = polarity
	field.force_magnitude = strength
	
	# Add collision shape
	var collision = CollisionShape2D.new()
	var shape = CircleShape2D.new()
	shape.radius = radius
	collision.shape = shape
	field.add_child(collision)
	
	return field


## Create a gravity well that pulls everything toward center
static func create_gravity_well(
	position: Vector2,
	radius: float,
	strength: float = 300.0,
	affected_traits: Array[String] = []
) -> ForceField:
	var field = ForceField.new()
	field.global_position = position
	field.force_magnitude = strength
	field.direction_type = ForceField.DirectionType.TOWARD_CENTER
	field.force_type = ForceField.ForceType.INVERSE_SQUARE
	field.required_traits = affected_traits  # Empty = affects all
	
	var collision = CollisionShape2D.new()
	var shape = CircleShape2D.new()
	shape.radius = radius
	collision.shape = shape
	field.add_child(collision)
	
	return field


## Create a wind zone that pushes in a fixed direction
static func create_wind_zone(
	position: Vector2,
	size: Vector2,
	direction: Vector2,
	strength: float = 200.0,
	affected_traits: Array[String] = []
) -> ForceField:
	var field = ForceField.new()
	field.global_position = position
	field.force_magnitude = strength
	field.direction_type = ForceField.DirectionType.FIXED_DIRECTION
	field.fixed_direction = direction.normalized()
	field.force_type = ForceField.ForceType.CONSTANT
	field.required_traits = affected_traits
	
	var collision = CollisionShape2D.new()
	var shape = RectangleShape2D.new()
	shape.size = size
	collision.shape = shape
	field.add_child(collision)
	
	return field


## Create a vortex that spins entities around
static func create_vortex(
	position: Vector2,
	radius: float,
	strength: float = 400.0,
	clockwise: bool = true,
	inward_pull: float = 0.3
) -> ForceField:
	var field = ForceField.new()
	field.global_position = position
	field.force_magnitude = strength
	field.direction_type = ForceField.DirectionType.VORTEX
	field.vortex_clockwise = clockwise
	field.vortex_inward_pull = inward_pull
	field.force_type = ForceField.ForceType.LINEAR_FALLOFF
	
	var collision = CollisionShape2D.new()
	var shape = CircleShape2D.new()
	shape.radius = radius
	collision.shape = shape
	field.add_child(collision)
	
	return field


## Create a repulsion field (force shield)
static func create_repulsion_field(
	position: Vector2,
	radius: float,
	strength: float = 800.0,
	blocked_traits: Array[String] = ["projectile", "enemy"]
) -> ForceField:
	var field = ForceField.new()
	field.global_position = position
	field.force_magnitude = strength
	field.direction_type = ForceField.DirectionType.AWAY_FROM_CENTER
	field.force_type = ForceField.ForceType.INVERSE_SQUARE
	field.required_traits = blocked_traits
	field.trait_match_mode = ForceField.TraitMatchMode.ANY
	
	var collision = CollisionShape2D.new()
	var shape = CircleShape2D.new()
	shape.radius = radius
	collision.shape = shape
	field.add_child(collision)
	
	return field


## Create a holy field that only affects undead
static func create_holy_field(
	position: Vector2,
	radius: float,
	strength: float = 600.0
) -> ForceField:
	var field = ForceField.new()
	field.global_position = position
	field.force_magnitude = strength
	field.direction_type = ForceField.DirectionType.AWAY_FROM_CENTER
	field.force_type = ForceField.ForceType.LINEAR_FALLOFF
	field.required_traits = ["undead", "demon", "dark"]
	field.trait_match_mode = ForceField.TraitMatchMode.ANY
	field.immune_traits = ["holy", "blessed"]
	
	# Also apply a debuff condition
	field.conditions_to_apply = ["holy_burn"]  # Define this in your ConditionDatabase
	field.condition_apply_interval = 2.0
	
	var collision = CollisionShape2D.new()
	var shape = CircleShape2D.new()
	shape.radius = radius
	collision.shape = shape
	field.add_child(collision)
	
	return field


## =============================================================================
## EXAMPLE: MAGNETIC ABILITY IMPLEMENTATION
## =============================================================================

class MagneticPullAbility:
	var caster: Node
	var field: MagneticField
	var duration: float
	var _time_remaining: float
	
	func _init(p_caster: Node, radius: float, strength: float, p_duration: float):
		caster = p_caster
		duration = p_duration
		_time_remaining = duration
		
		# Create the field at caster position
		field = ForceFieldExamples.create_magnetic_field(
			caster.global_position,
			radius,
			MagneticField.Polarity.ATTRACT,
			strength
		)
	
	func activate(parent: Node) -> void:
		parent.add_child(field)
		field.is_active = true
	
	func update(delta: float) -> bool:
		_time_remaining -= delta
		
		# Update field position to follow caster
		if field and is_instance_valid(caster):
			field.global_position = caster.global_position
		
		# Return true if ability should continue
		return _time_remaining > 0
	
	func deactivate() -> void:
		if field:
			field.queue_free()
			field = null


## =============================================================================
## EXAMPLE: ABILITY THAT CREATES A FIELD ON TARGET LOCATION
## =============================================================================

class GravityWellAbility:
	var field: ForceField
	var duration: float
	var _time_remaining: float
	var _growth_time: float = 0.5
	var _current_time: float = 0.0
	var _target_radius: float
	
	signal ability_ended
	
	func _init(target_position: Vector2, radius: float, strength: float, p_duration: float):
		duration = p_duration
		_time_remaining = duration
		_target_radius = radius
		
		# Start with small radius and grow
		field = ForceFieldExamples.create_gravity_well(
			target_position,
			1.0,  # Start tiny
			strength
		)
	
	func activate(parent: Node) -> void:
		parent.add_child(field)
		field.is_active = true
	
	func update(delta: float) -> bool:
		_current_time += delta
		_time_remaining -= delta
		
		# Grow the field over time
		if _current_time < _growth_time:
			var t = _current_time / _growth_time
			var current_radius = lerp(1.0, _target_radius, t)
			_set_field_radius(current_radius)
		
		# Shrink at end
		if _time_remaining < _growth_time:
			var t = _time_remaining / _growth_time
			var current_radius = lerp(1.0, _target_radius, t)
			_set_field_radius(current_radius)
		
		if _time_remaining <= 0:
			ability_ended.emit()
			return false
		
		return true
	
	func _set_field_radius(radius: float) -> void:
		for child in field.get_children():
			if child is CollisionShape2D:
				var shape = child.shape as CircleShape2D
				if shape:
					shape.radius = radius
	
	func deactivate() -> void:
		if field:
			field.queue_free()
			field = null


## =============================================================================
## EXAMPLE SCENE SETUP (pseudo-code for documentation)
## =============================================================================
#
# Scene: MagneticFieldAbility.tscn
# - MagneticField (MagneticField.gd)
#   - CollisionShape2D
#     - CircleShape2D (radius: 200)
#   - Sprite2D (visual effect)
#   - GPUParticles2D (particle effect)
#
# Export variables set in inspector:
#   required_traits: ["metal"]
#   polarity: ATTRACT
#   force_magnitude: 500
#   force_type: INVERSE_SQUARE
