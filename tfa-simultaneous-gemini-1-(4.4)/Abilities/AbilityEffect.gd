# AbilityEffect.gd
# Handles resolution of ability effects including damage, healing, conditions, and force fields
# Integrates with the condition system for trait-based modifiers
class_name AbilityEffect
extends RefCounted

## D&D 5e damage types
const DAMAGE_TYPES = [
	"acid",
	"bludgeoning",
	"cold",
	"fire",
	"force",
	"lightning",
	"necrotic",
	"piercing",
	"poison",
	"psychic",
	"radiant",
	"slashing",
	"thunder",
	"true"  # Untyped/true damage (ignores resistances)
]

## Effect types
const EFFECT_TYPES = [
	"damage",           # Deal damage
	"heal",             # Restore health
	"apply_condition",  # Apply a condition
	"remove_condition", # Remove a condition
	"force_field",      # Create a force field
	"knockback",        # Apply knockback force
	"teleport",         # Move target instantly
	"summon",           # Summon an entity
	"custom",           # Custom effect with callback
]


## Resolve a single effect from an ability
## Returns a dictionary with results of the effect
static func resolve_effect(
	effect: Dictionary,
	caster: Node,
	targets: Array,
	ability: Ability2,
	target_position: Vector2
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": effect.get("type", ""),
		"targets_affected": [],
		"total_damage": 0.0,
		"total_healing": 0.0,
		"conditions_applied": [],
		"conditions_removed": [],
		"created_objects": [],
	}
	
	var effect_type = effect.get("type", "")
	
	match effect_type:
		"damage":
			result = _resolve_damage(effect, caster, targets, ability)
		"heal":
			result = _resolve_healing(effect, caster, targets, ability)
		"apply_condition":
			result = _resolve_apply_condition(effect, caster, targets, ability)
		"remove_condition":
			result = _resolve_remove_condition(effect, caster, targets, ability)
		"force_field":
			result = _resolve_force_field(effect, caster, target_position, ability)
		"knockback":
			result = _resolve_knockback(effect, caster, targets, target_position)
		"teleport":
			result = _resolve_teleport(effect, caster, targets, target_position)
		"custom":
			result = _resolve_custom(effect, caster, targets, ability, target_position)
		_:
			result["success"] = false
			result["error"] = "Unknown effect type: %s" % effect_type
	
	return result


## Resolve damage effect
static func _resolve_damage(
	effect: Dictionary,
	caster: Node,
	targets: Array,
	ability: Ability2
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "damage",
		"targets_affected": [],
		"total_damage": 0.0,
		"damage_breakdown": [],
	}
	
	# Get base damage values {damage_type: amount}
	var base_damage: Dictionary = effect.get("damage", {})
	
	# Get trait requirements for damage to apply
	var required_traits = effect.get("target_traits", [])
	var immune_traits = effect.get("immune_traits", [])
	
	# Get caster's traits and condition manager
	var caster_traits = _get_entity_traits(caster)
	var caster_conditions = _get_condition_manager(caster)
	
	for target in targets:
		if not is_instance_valid(target):
			continue
		
		var target_traits = _get_entity_traits(target)
		
		# Check trait requirements
		if not required_traits.is_empty():
			var has_required = false
			for req in required_traits:
				if req in target_traits:
					has_required = true
					break
			if not has_required:
				continue
		
		# Check immunities
		var is_immune = false
		for immune in immune_traits:
			if immune in target_traits:
				is_immune = true
				break
		if is_immune:
			continue
		
		# Calculate damage with modifiers from conditions
		var final_damage = _calculate_modified_damage(
			base_damage.duplicate(),
			caster,
			target,
			caster_traits,
			target_traits,
			ability.traits,
			caster_conditions
		)
		
		# Apply target's resistances/vulnerabilities
		final_damage = _apply_target_defenses(final_damage, target, target_traits)
		
		# Deal the damage
		var damage_dealt = _deal_damage_to_target(target, final_damage)
		
		result["targets_affected"].append({
			"target": target,
			"damage": damage_dealt,
			"damage_types": final_damage.keys()
		})
		result["total_damage"] += damage_dealt
	
	return result


## Calculate damage modified by caster's conditions
static func _calculate_modified_damage(
	base_damage: Dictionary,
	caster: Node,
	target: Node,
	caster_traits: Dictionary,
	target_traits: Dictionary,
	ability_traits: Dictionary,
	caster_conditions: ConditionManager
) -> Dictionary:
	if not caster_conditions:
		return base_damage
	
	var modified = base_damage.duplicate()
	
	# Get conditional modifiers from caster's conditions
	var modifiers = caster_conditions.get_conditional_modifiers(
		EffectResolver.TriggerType.ON_ATTACK,
		caster_traits,
		target_traits,
		ability_traits
	)
	
	# Separate flat and percent modifiers
	var flat_bonus: float = 0.0
	var percent_bonus: float = 1.0
	
	for mod in modifiers:
		var mod_type = mod.get("modifier_type")
		var value = mod.get("value", 0)
		
		if mod_type == EffectResolver.ModifierType.FLAT_DAMAGE_DEALT:
			flat_bonus += value
		elif mod_type == EffectResolver.ModifierType.PERCENT_DAMAGE_DEALT:
			percent_bonus *= (1.0 + value / 100.0)
	
	# Apply modifiers to each damage type
	# Flat bonus is distributed evenly, percent applies to each
	var num_types = max(1, modified.size())
	var flat_per_type = flat_bonus / num_types
	
	for damage_type in modified.keys():
		modified[damage_type] = (modified[damage_type] + flat_per_type) * percent_bonus
	
	return modified


## Apply target's resistances, immunities, and vulnerabilities
static func _apply_target_defenses(
	damage: Dictionary,
	target: Node,
	target_traits: Array
) -> Dictionary:
	var modified = damage.duplicate()
	
	# Get resistance/immunity/vulnerability data from target
	var resistances = _get_target_resistances(target)
	var immunities = _get_target_immunities(target)
	var vulnerabilities = _get_target_vulnerabilities(target)
	
	for damage_type in modified.keys():
		# True damage ignores all defenses
		if damage_type == "true":
			continue
		
		# Check immunity first (complete negation)
		if damage_type in immunities:
			modified[damage_type] = 0.0
			continue
		
		# Check resistance (half damage)
		if damage_type in resistances:
			modified[damage_type] *= 0.5
		
		# Check vulnerability (double damage)
		if damage_type in vulnerabilities:
			modified[damage_type] *= 2.0
	
	return modified


## Get resistances from target
static func _get_target_resistances(target: Node) -> Array:
	if target.has_method("get_resistances"):
		return target.get_resistances()
	if "resistances" in target:
		return target.resistances
	if target.has_node("CharacterStats") and "resistances" in target.get_node("CharacterStats"):
		return target.get_node("CharacterStats").resistances
	return []


## Get immunities from target
static func _get_target_immunities(target: Node) -> Array:
	if target.has_method("get_immunities"):
		return target.get_immunities()
	if "damage_immunities" in target:
		return target.damage_immunities
	if target.has_node("CharacterStats") and "damage_immunities" in target.get_node("CharacterStats"):
		return target.get_node("CharacterStats").damage_immunities
	return []


## Get vulnerabilities from target
static func _get_target_vulnerabilities(target: Node) -> Array:
	if target.has_method("get_vulnerabilities"):
		return target.get_vulnerabilities()
	if "vulnerabilities" in target:
		return target.vulnerabilities
	if target.has_node("CharacterStats") and "vulnerabilities" in target.get_node("CharacterStats"):
		return target.get_node("CharacterStats").vulnerabilities
	return []


## Actually deal damage to a target
static func _deal_damage_to_target(target: Node, damage_dict: Dictionary) -> float:
	var total = 0.0
	for damage_type in damage_dict:
		total += damage_dict[damage_type]
	
	# Call the target's damage method
	if target.has_method("take_damage"):
		target.take_damage(total, damage_dict)
	elif target.has_method("damage"):
		target.damage(total)
	elif "HP_CURRENT" in target:
		target.HP_CURRENT = max(0, target.HP_CURRENT - total)
	elif target.has_node("CharacterStats"):
		target.get_node("CharacterStats").take_damage(total)
	
	return total


## Resolve healing effect
static func _resolve_healing(
	effect: Dictionary,
	caster: Node,
	targets: Array,
	ability: Ability2
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "heal",
		"targets_affected": [],
		"total_healing": 0.0,
	}
	
	var base_healing = effect.get("amount", 0.0)
	var caster_traits = _get_entity_traits(caster)
	var caster_conditions = _get_condition_manager(caster)
	
	for target in targets:
		if not is_instance_valid(target):
			continue
		
		var target_traits = _get_entity_traits(target)
		
		# Calculate modified healing
		var final_healing = base_healing
		
		if caster_conditions:
			var modifiers = caster_conditions.get_conditional_modifiers(
				EffectResolver.TriggerType.ON_HEAL,
				caster_traits,
				target_traits,
				ability.traits
			)
			
			for mod in modifiers:
				var mod_type = mod.get("modifier_type")
				var value = mod.get("value", 0)
				
				if mod_type == EffectResolver.ModifierType.FLAT_HEALING_DEALT:
					final_healing += value
				elif mod_type == EffectResolver.ModifierType.PERCENT_HEALING_DEALT:
					final_healing *= (1.0 + value / 100.0)
		
		# Apply healing
		var healed = _heal_target(target, final_healing)
		
		result["targets_affected"].append({
			"target": target,
			"healing": healed
		})
		result["total_healing"] += healed
	
	return result


## Actually heal a target
static func _heal_target(target: Node, amount: float) -> float:
	if target.has_method("heal"):
		return target.heal(amount)
	elif target.has_node("CharacterStats"):
		return target.get_node("CharacterStats").heal(amount)
	return 0.0


## Resolve apply condition effect
static func _resolve_apply_condition(
	effect: Dictionary,
	caster: Node,
	targets: Array,
	ability: Ability2
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "apply_condition",
		"targets_affected": [],
		"conditions_applied": [],
	}
	
	var condition_id = effect.get("condition_id", "")
	var stacks = effect.get("stacks", 1)
	var duration_override = effect.get("duration", -2.0)
	var chance = effect.get("chance", 1.0)
	
	for target in targets:
		if not is_instance_valid(target):
			continue
		
		# Check chance
		if randf() > chance:
			continue
		
		var condition_manager = _get_condition_manager(target)
		if not condition_manager:
			continue
		
		var instance = condition_manager.apply_condition(
			condition_id,
			caster,
			stacks,
			duration_override
		)
		
		if instance:
			result["targets_affected"].append(target)
			result["conditions_applied"].append({
				"target": target,
				"condition": condition_id,
				"stacks": instance.stacks
			})
	
	return result


## Resolve remove condition effect
static func _resolve_remove_condition(
	effect: Dictionary,
	caster: Node,
	targets: Array,
	ability: Ability2
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "remove_condition",
		"targets_affected": [],
		"conditions_removed": [],
	}
	
	var condition_id = effect.get("condition_id", "")
	var remove_trait = effect.get("trait", "")  # Remove all conditions with this trait
	var stacks_to_remove = effect.get("stacks", -1)  # -1 = all
	
	for target in targets:
		if not is_instance_valid(target):
			continue
		
		var condition_manager = _get_condition_manager(target)
		if not condition_manager:
			continue
		
		if remove_trait != "":
			# Remove conditions by trait
			var count = condition_manager.remove_conditions_with_trait(remove_trait)
			if count > 0:
				result["targets_affected"].append(target)
				result["conditions_removed"].append({
					"target": target,
					"trait": remove_trait,
					"count": count
				})
		elif condition_id != "":
			# Remove specific condition
			if stacks_to_remove > 0:
				var removed = condition_manager.remove_stacks(condition_id, stacks_to_remove)
				if removed > 0:
					result["targets_affected"].append(target)
					result["conditions_removed"].append({
						"target": target,
						"condition": condition_id,
						"stacks": removed
					})
			else:
				if condition_manager.remove_condition(condition_id):
					result["targets_affected"].append(target)
					result["conditions_removed"].append({
						"target": target,
						"condition": condition_id
					})
	
	return result


## Resolve force field creation
static func _resolve_force_field(
	effect: Dictionary,
	caster: Node,
	target_position: Vector2,
	ability: Ability2
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "force_field",
		"created_objects": [],
	}
	
	var field_type = effect.get("field_type", "generic")
	var radius = effect.get("radius", 100.0)
	var strength = effect.get("strength", 500.0)
	var duration = effect.get("duration", 5.0)
	var affected_traits: Array[String] = []
	for t in effect.get("affected_traits", []):
		affected_traits.append(t)
	
	var field: ForceField = null
	
	match field_type:
		"magnetic_attract":
			field = _create_magnetic_field(target_position, radius, strength, MagneticField.Polarity.ATTRACT)
		"magnetic_repel":
			field = _create_magnetic_field(target_position, radius, strength, MagneticField.Polarity.REPEL)
		"gravity":
			field = _create_gravity_field(target_position, radius, strength, affected_traits)
		"repulsion":
			field = _create_repulsion_field(target_position, radius, strength, affected_traits)
		"vortex":
			var clockwise = effect.get("clockwise", true)
			var inward = effect.get("inward_pull", 0.3)
			field = _create_vortex_field(target_position, radius, strength, clockwise, inward)
		"wind":
			var direction = Vector2(
				effect.get("direction_x", 0),
				effect.get("direction_y", 1)
			)
			field = _create_wind_field(target_position, radius, strength, direction, affected_traits)
		_:
			field = _create_generic_field(target_position, radius, strength, affected_traits, effect)
	
	if field:
		# Add to scene
		var scene_root = caster.get_tree().current_scene
		scene_root.add_child(field)
		
		# Set up duration-based cleanup
		if duration > 0:
			var timer = Timer.new()
			timer.one_shot = true
			timer.wait_time = duration
			timer.timeout.connect(func(): 
				if is_instance_valid(field):
					field.queue_free()
			)
			field.add_child(timer)
			timer.start()
		
		result["created_objects"].append(field)
	
	return result


## Create a magnetic field
static func _create_magnetic_field(
	position: Vector2,
	radius: float,
	strength: float,
	polarity: MagneticField.Polarity
) -> MagneticField:
	var field = MagneticField.new()
	field.global_position = position
	field.polarity = polarity
	field.force_magnitude = strength
	
	var collision = CollisionShape2D.new()
	var shape = CircleShape2D.new()
	shape.radius = radius
	collision.shape = shape
	field.add_child(collision)
	
	return field


## Create a gravity field
static func _create_gravity_field(
	position: Vector2,
	radius: float,
	strength: float,
	affected_traits: Array[String]
) -> ForceField:
	var field = ForceField.new()
	field.global_position = position
	field.force_magnitude = strength
	field.direction_type = ForceField.DirectionType.TOWARD_CENTER
	field.force_type = ForceField.ForceType.INVERSE_SQUARE
	field.required_traits = affected_traits
	
	var collision = CollisionShape2D.new()
	var shape = CircleShape2D.new()
	shape.radius = radius
	collision.shape = shape
	field.add_child(collision)
	
	return field


## Create a repulsion field
static func _create_repulsion_field(
	position: Vector2,
	radius: float,
	strength: float,
	affected_traits: Array[String]
) -> ForceField:
	var field = ForceField.new()
	field.global_position = position
	field.force_magnitude = strength
	field.direction_type = ForceField.DirectionType.AWAY_FROM_CENTER
	field.force_type = ForceField.ForceType.INVERSE_SQUARE
	field.required_traits = affected_traits
	
	var collision = CollisionShape2D.new()
	var shape = CircleShape2D.new()
	shape.radius = radius
	collision.shape = shape
	field.add_child(collision)
	
	return field


## Create a vortex field
static func _create_vortex_field(
	position: Vector2,
	radius: float,
	strength: float,
	clockwise: bool,
	inward_pull: float
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


## Create a wind field
static func _create_wind_field(
	position: Vector2,
	radius: float,
	strength: float,
	direction: Vector2,
	affected_traits: Array[String]
) -> ForceField:
	var field = ForceField.new()
	field.global_position = position
	field.force_magnitude = strength
	field.direction_type = ForceField.DirectionType.FIXED_DIRECTION
	field.fixed_direction = direction.normalized()
	field.force_type = ForceField.ForceType.CONSTANT
	field.required_traits = affected_traits
	
	var collision = CollisionShape2D.new()
	var shape = CircleShape2D.new()
	shape.radius = radius
	collision.shape = shape
	field.add_child(collision)
	
	return field


## Create a generic configurable field
static func _create_generic_field(
	position: Vector2,
	radius: float,
	strength: float,
	affected_traits: Array[String],
	effect: Dictionary
) -> ForceField:
	var field = ForceField.new()
	field.global_position = position
	field.force_magnitude = strength
	field.required_traits = affected_traits
	
	# Parse direction type
	var dir_type = effect.get("direction_type", "toward_center")
	match dir_type:
		"toward_center":
			field.direction_type = ForceField.DirectionType.TOWARD_CENTER
		"away_from_center":
			field.direction_type = ForceField.DirectionType.AWAY_FROM_CENTER
		"fixed":
			field.direction_type = ForceField.DirectionType.FIXED_DIRECTION
			field.fixed_direction = Vector2(
				effect.get("direction_x", 0),
				effect.get("direction_y", 1)
			)
		"vortex":
			field.direction_type = ForceField.DirectionType.VORTEX
	
	# Parse force type
	var force_type_str = effect.get("force_type", "constant")
	match force_type_str:
		"constant":
			field.force_type = ForceField.ForceType.CONSTANT
		"linear":
			field.force_type = ForceField.ForceType.LINEAR_FALLOFF
		"inverse_square":
			field.force_type = ForceField.ForceType.INVERSE_SQUARE
	
	var collision = CollisionShape2D.new()
	var shape = CircleShape2D.new()
	shape.radius = radius
	collision.shape = shape
	field.add_child(collision)
	
	return field


## Resolve knockback effect
static func _resolve_knockback(
	effect: Dictionary,
	caster: Node,
	targets: Array,
	target_position: Vector2
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "knockback",
		"targets_affected": [],
	}
	
	var strength = effect.get("strength", 500.0)
	var from_caster = effect.get("from_caster", true)
	var knockback_origin = caster.global_position if from_caster else target_position
	
	for target in targets:
		if not is_instance_valid(target):
			continue
		
		if not target is Node2D:
			continue
		
		var direction = (target.global_position - knockback_origin).normalized()
		var force = direction * strength
		
		if target is CharacterBody2D:
			if "velocity" in target:
				target.velocity += force
			if target.has_method("apply_external_force"):
				target.apply_external_force(force, 0.1)
		elif target is RigidBody2D:
			target.apply_central_impulse(force)
		
		result["targets_affected"].append({
			"target": target,
			"force": force
		})
	
	return result


## Resolve teleport effect
static func _resolve_teleport(
	effect: Dictionary,
	caster: Node,
	targets: Array,
	target_position: Vector2
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "teleport",
		"targets_affected": [],
	}
	
	var teleport_to = effect.get("to", "position")  # "position", "caster", "swap"
	
	for target in targets:
		if not is_instance_valid(target):
			continue
		
		if not target is Node2D:
			continue
		
		var old_position = target.global_position
		
		match teleport_to:
			"position":
				target.global_position = target_position
			"caster":
				target.global_position = caster.global_position
			"swap":
				target.global_position = caster.global_position
				caster.global_position = old_position
		
		result["targets_affected"].append({
			"target": target,
			"from": old_position,
			"to": target.global_position
		})
	
	return result


## Resolve custom effect
static func _resolve_custom(
	effect: Dictionary,
	caster: Node,
	targets: Array,
	ability: Ability2,
	target_position: Vector2
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "custom",
		"custom_type": effect.get("custom_type", ""),
	}
	
	# Custom effects can specify a method to call on caster
	var method_name = effect.get("method", "")
	if method_name != "" and caster.has_method(method_name):
		var custom_result = caster.call(method_name, effect, targets, ability, target_position)
		if custom_result is Dictionary:
			result.merge(custom_result, true)
	
	return result


## Helper: Get entity traits
static func _get_entity_traits(entity: Node) -> Array:
	return entity.traits


## Helper: Get condition manager
static func _get_condition_manager(entity: Node):
	if entity.has_node("ConditionManager"):
		return entity.get_node("ConditionManager")
	if entity.has_method("get_condition_manager"):
		return entity.get_condition_manager()
	if "condition_manager" in entity:
		return entity.condition_manager
	return null
