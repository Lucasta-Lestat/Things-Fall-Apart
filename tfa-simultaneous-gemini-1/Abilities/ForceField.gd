# ForceField.gd
# Base class for force fields that affect entities with specific traits
# Attach to an Area2D node with a CollisionShape2D child defining the field's shape
class_name ForceField
extends Area2D

## Traits that entities must have to be affected by this field
## Uses the same matching logic as EffectResolver
@export var required_traits: Array[String] = []

## Trait matching mode
enum TraitMatchMode {
	ANY,  # Entity has any of the required traits
	ALL,  # Entity has all of the required traits
}
@export var trait_match_mode: TraitMatchMode = TraitMatchMode.ANY

## Traits that make an entity immune to this field
@export var immune_traits: Array[String] = []

## Base force magnitude
@export var force_magnitude: float = 500.0

## Force type determines how force is calculated
enum ForceType {
	CONSTANT,           # Same force everywhere in field
	LINEAR_FALLOFF,     # Force decreases linearly from center
	INVERSE_SQUARE,     # Force follows inverse square law (realistic gravity/magnetism)
	INVERSE_LINEAR,     # Force follows inverse linear law
	EDGE_PUSH,          # Pushes away from nearest edge
}
@export var force_type: ForceType = ForceType.CONSTANT

## Direction type determines which way force points
enum DirectionType {
	TOWARD_CENTER,      # Pull toward field center (gravity, attraction)
	AWAY_FROM_CENTER,   # Push away from field center (repulsion)
	FIXED_DIRECTION,    # Force in a fixed direction (wind, conveyor)
	VORTEX,             # Circular force around center
	CUSTOM,             # Override _calculate_direction() for custom behavior
}
@export var direction_type: DirectionType = DirectionType.TOWARD_CENTER

## Fixed direction vector (used when direction_type is FIXED_DIRECTION)
@export var fixed_direction: Vector2 = Vector2.DOWN

## Vortex settings
@export var vortex_clockwise: bool = true
@export var vortex_inward_pull: float = 0.2  # 0 = pure rotation, 1 = pure pull

## Whether the field is currently active
@export var is_active: bool = true

## Optional: conditions to apply to affected entities
@export var conditions_to_apply: Array[String] = []
@export var condition_apply_interval: float = 1.0  # How often to apply conditions

## Reference to game singleton (set this or override _get_entities())
var game: Node

## Entities currently inside the field
var _entities_in_field: Dictionary = {}  # entity -> {last_condition_time: float}

## Cached center position (updated when needed)
var _field_center: Vector2

signal entity_entered_field(entity: Node)
signal entity_exited_field(entity: Node)
signal force_applied(entity: Node, force: Vector2)


func _ready() -> void:
	# Connect area signals
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	
	# Try to find game singleton
	if not game:
		game = get_node_or_null("/root/Game")
	
	_field_center = global_position


func _physics_process(delta: float) -> void:
	if not is_active:
		return
	
	_field_center = global_position
	
	# Apply forces to all affected entities
	for entity in _entities_in_field.keys():
		if not is_instance_valid(entity):
			_entities_in_field.erase(entity)
			continue
		
		if entity is CharacterBody2D:
			var force = calculate_force(entity)
			_apply_force_to_character(entity, force, delta)
			force_applied.emit(entity, force)
		elif entity is RigidBody2D:
			var force = calculate_force(entity)
			entity.apply_central_force(force)
			force_applied.emit(entity, force)
	
	# Handle condition application
	if not conditions_to_apply.is_empty():
		_process_condition_application()


func _on_body_entered(body: Node) -> void:
	if _should_affect_entity(body):
		_entities_in_field[body] = {"last_condition_time": -INF}
		entity_entered_field.emit(body)


func _on_body_exited(body: Node) -> void:
	if body in _entities_in_field:
		_entities_in_field.erase(body)
		entity_exited_field.emit(body)


## Check if an entity should be affected by this field based on traits
func _should_affect_entity(entity: Node) -> bool:
	var entity_traits = _get_entity_traits(entity)
	
	if entity_traits.is_empty():
		return false
	
	# Check immunities first
	for immune_trait in immune_traits:
		if immune_trait in entity_traits:
			return false
	
	# Check required traits
	if required_traits.is_empty():
		return true  # No requirements = affects everything
	
	match trait_match_mode:
		TraitMatchMode.ANY:
			for req_trait in required_traits:
				if req_trait in entity_traits:
					return true
			return false
		TraitMatchMode.ALL:
			for req_trait in required_traits:
				if req_trait not in entity_traits:
					return false
			return true
	
	return false


## Get traits from an entity (override if your trait system differs)
func _get_entity_traits(entity: Node) -> Array:
	# Try common trait storage patterns
	if entity.has_method("get_traits"):
		return entity.get_traits()
	if "traits" in entity:
		return entity.traits
	if entity.has_node("CharacterStats"):
		return entity.get_node("CharacterStats").traits
	if entity.has_meta("traits"):
		return entity.get_meta("traits")
	
	return []


## Calculate the force to apply to an entity
func calculate_force(entity: Node2D) -> Vector2:
	var direction = _calculate_direction(entity)
	var magnitude = _calculate_magnitude(entity)
	return direction * magnitude


## Calculate force direction based on direction_type
func _calculate_direction(entity: Node2D) -> Vector2:
	var to_center = _field_center - entity.global_position
	var distance = to_center.length()
	
	if distance < 0.001:
		return Vector2.ZERO
	
	var normalized_to_center = to_center / distance
	
	match direction_type:
		DirectionType.TOWARD_CENTER:
			return normalized_to_center
		DirectionType.AWAY_FROM_CENTER:
			return -normalized_to_center
		DirectionType.FIXED_DIRECTION:
			return fixed_direction.normalized()
		DirectionType.VORTEX:
			var tangent = Vector2(-normalized_to_center.y, normalized_to_center.x)
			if not vortex_clockwise:
				tangent = -tangent
			return (tangent + normalized_to_center * vortex_inward_pull).normalized()
		DirectionType.CUSTOM:
			return _custom_direction(entity)
	
	return Vector2.ZERO


## Override this for custom direction logic
func _custom_direction(entity: Node2D) -> Vector2:
	return Vector2.ZERO


## Calculate force magnitude based on force_type
func _calculate_magnitude(entity: Node2D) -> float:
	var distance = entity.global_position.distance_to(_field_center)
	var max_distance = _get_field_radius()
	
	if max_distance <= 0:
		return force_magnitude
	
	# Clamp distance to avoid division issues
	distance = max(distance, 1.0)
	
	match force_type:
		ForceType.CONSTANT:
			return force_magnitude
		ForceType.LINEAR_FALLOFF:
			var t = 1.0 - clamp(distance / max_distance, 0.0, 1.0)
			return force_magnitude * t
		ForceType.INVERSE_SQUARE:
			var normalized_dist = distance / max_distance
			return force_magnitude / (normalized_dist * normalized_dist)
		ForceType.INVERSE_LINEAR:
			var normalized_dist = distance / max_distance
			return force_magnitude / normalized_dist
		ForceType.EDGE_PUSH:
			# Stronger near edges, weaker in center
			var t = clamp(distance / max_distance, 0.0, 1.0)
			return force_magnitude * t
	
	return force_magnitude


## Get the approximate radius of the field (from collision shape)
func _get_field_radius() -> float:
	for child in get_children():
		if child is CollisionShape2D:
			var shape = child.shape
			if shape is CircleShape2D:
				return shape.radius
			elif shape is RectangleShape2D:
				return max(shape.size.x, shape.size.y) / 2.0
			elif shape is CapsuleShape2D:
				return max(shape.radius, shape.height / 2.0)
	return 100.0  # Default fallback


## Apply force to a CharacterBody2D (they don't have apply_force)
func _apply_force_to_character(character: CharacterBody2D, force: Vector2, delta: float) -> void:
	# Option 1: Direct velocity modification
	if "velocity" in character:
		character.velocity += force * delta
	
	# Option 2: If character has a custom method for external forces
	if character.has_method("apply_external_force"):
		character.apply_external_force(force, delta)


## Process condition application on interval
func _process_condition_application() -> void:
	var current_time = Time.get_ticks_msec() / 1000.0
	
	for entity in _entities_in_field.keys():
		if not is_instance_valid(entity):
			continue
		
		var data = _entities_in_field[entity]
		if current_time - data["last_condition_time"] >= condition_apply_interval:
			data["last_condition_time"] = current_time
			_apply_conditions_to_entity(entity)


## Apply conditions to an entity
func _apply_conditions_to_entity(entity: Node) -> void:
	var condition_manager = _get_condition_manager(entity)
	if not condition_manager:
		return
	
	for condition_id in conditions_to_apply:
		condition_manager.apply_condition(condition_id, self)


## Get condition manager from entity
func _get_condition_manager(entity: Node) :
	if entity.has_node("ConditionManager"):
		return entity.get_node("ConditionManager")
	if entity.has_method("get_condition_manager"):
		return entity.get_condition_manager()
	if "condition_manager" in entity:
		return entity.condition_manager
	return null


## Utility: Check if a specific entity is currently affected
func is_affecting(entity: Node) -> bool:
	return entity in _entities_in_field


## Utility: Get all currently affected entities
func get_affected_entities() -> Array:
	return _entities_in_field.keys()


## Utility: Activate/deactivate the field
func set_active(active: bool) -> void:
	is_active = active
	if not active:
		# Clear entities when deactivated (they'll re-enter when reactivated)
		_entities_in_field.clear()


## Utility: Manually refresh which entities should be affected
## Call this if entity traits change while inside the field
func refresh_affected_entities() -> void:
	# Check current entities
	var to_remove: Array = []
	for entity in _entities_in_field.keys():
		if not _should_affect_entity(entity):
			to_remove.append(entity)
	
	for entity in to_remove:
		_entities_in_field.erase(entity)
		entity_exited_field.emit(entity)
	
	# Check for new entities via overlapping bodies
	for body in get_overlapping_bodies():
		if body not in _entities_in_field and _should_affect_entity(body):
			_entities_in_field[body] = {"last_condition_time": -INF}
			entity_entered_field.emit(body)
