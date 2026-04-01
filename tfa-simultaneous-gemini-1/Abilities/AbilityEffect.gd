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
	"electric",
	"necrotic",
	"piercing",
	"poison",
	"psychic",
	"radiant",
	"slashing",
	"sonic",
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
	"cloud",            # Create a Cloud
	"custom",           # Custom effect with callback
]


## Resolve a single effect from an ability
## Returns a dictionary with results of the effect
static func resolve_effect(
	effect: Dictionary,
	caster: Node,
	targets: Array,
	ability: Ability,
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
	print("attempting to resolve ability effect")
	match effect_type:
		"damage":
			result = _resolve_damage(effect, caster, targets, ability)
		"heal":
			result = _resolve_healing(effect, caster, targets, ability)
		"apply_condition":
			print("applying condition in resolve_effect")
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
		"summon":
			result = _resolve_summon(effect, caster, target_position, ability)
		"cloud":
			result = _resolve_cloud(effect, caster, target_position, ability)
		_:
			result["success"] = false
			result["error"] = "Unknown effect type: %s" % effect_type
	
	return result

## Resolve summon effect
static func _resolve_summon(
	effect: Dictionary,
	caster: Node,
	target_position: Vector2,
	ability: Ability
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "summon",
		"created_objects": [],
	}

	var summon_type = effect.get("summon_type", "")  # "character", "item", "structure"
	var summon_id = effect.get("summon_id", "")
	var count = effect.get("count", 1)
	var spread = effect.get("spread_radius", 32.0)
	var stack_count = effect.get("stack_count", 1)

	if summon_id.is_empty():
		result["success"] = false
		result["error"] = "No summon_id specified"
		return result

	# Get the main scene — walk up from caster to find it
	var game = _get_game_scene(caster)
	if not game:
		result["success"] = false
		result["error"] = "Could not find game scene for spawning"
		return result

	for i in range(count):
		var pos = target_position
		if i > 0 and spread > 0:
			pos += Vector2(randf_range(-spread, spread), randf_range(-spread, spread))

		var spawned = null
		match summon_type:
			"character":
				if game.has_method("_spawn_character"):
					var overrides = effect.get("overrides", {})
					spawned = game._spawn_character(summon_id, pos, overrides)
					if spawned:
						spawned.AI_enabled = true
						# If caster has a faction/team, ally the summon to them
						if "faction" in caster and "faction" in spawned:
							spawned.faction = caster.faction
			"item":
				if game.has_method("create_item"):
					spawned = game.create_item(summon_id, pos, stack_count)
			"structure":
				if game.has_method("create_structure"):
					spawned = game.create_structure(summon_id, pos)
			_:
				push_warning("Unknown summon_type: %s" % summon_type)
				continue

		if spawned:
			result["created_objects"].append(spawned)

	if result["created_objects"].is_empty():
		result["success"] = false
		result["error"] = "Failed to spawn any objects"

	return result


## Walk up the scene tree from a node to find the main game scene
static func _get_game_scene(node: Node) -> Node:
	# Try the tree root's main scene first
	var tree = node.get_tree()
	if tree:
		var root = tree.current_scene
		if root and root.has_method("create_item"):
			return root
		# Search children of root (in case game is a child node)
		for child in root.get_children():
			if child.has_method("create_item"):
				return child
	# Walk up from the caster
	var current = node
	while current:
		if current.has_method("create_item") and current.has_method("_spawn_character"):
			return current
		current = current.get_parent()
	return null
	
static func _resolve_cloud(
	effect: Dictionary,
	caster: Node,
	target_position: Vector2,
	ability: Ability
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "cloud",
		"created_objects": [],
	}

	var game = _get_game_scene(caster)
	if not game:
		result["success"] = false
		result["error"] = "Could not find game scene"
		return result

	var fog_manager = game.get_node_or_null("FogManager")
	if not fog_manager:
		result["success"] = false
		result["error"] = "No FogManager found"
		return result

	var cloud_color = Color(effect.get("color", "#808080"))
	var cloud_size = Vector2(
		effect.get("radius", 64.0) * 2,
		effect.get("radius", 64.0) * 2
	)
	var duration = effect.get("duration", 10.0)
	var condition_id = effect.get("condition_id", "")
	var condition_stacks = effect.get("condition_stacks", 1)
	var condition_duration = effect.get("condition_duration", -2.0)
	var apply_interval = effect.get("apply_interval", 1.0)
	var density = effect.get("density", 0.6)
	var speed = Vector2(
		effect.get("speed_x", 0.02),
		effect.get("speed_y", 0.01)
	)

	var overlay = fog_manager.create_cloud(
		cloud_color,
		cloud_size,
		duration,
		condition_id,
		condition_stacks,
		condition_duration,
		apply_interval,
		density,
		4.0,
		speed,
		target_position,
		caster
	)

	if overlay:
		result["created_objects"].append(overlay)
	else:
		result["success"] = false
		result["error"] = "Failed to create cloud"

	return result
	
	
static func _resolve_damage(
	effect: Dictionary,
	caster: Node,
	targets: Array,
	ability: Ability
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "damage",
		"targets_affected": [],
		"total_damage": 0.0,
		"damage_breakdown": [],
	}
	
	var base_damage: Dictionary = effect.get("damage", {})
	var required_traits = effect.get("target_traits", [])
	var immune_traits = effect.get("immune_traits", [])
	
	var caster_traits = _get_entity_traits(caster)
	var caster_conditions = _get_condition_manager(caster)
	
	for target in targets:
		if not is_instance_valid(target):
			continue
			
		var target_traits = _get_entity_traits(target)
		
		if not required_traits.is_empty():
			var has_required = false
			for req in required_traits:
				if req in target_traits:
					has_required = true
					break
			if not has_required:
				continue
				
		var is_immune = false
		for immune in immune_traits:
			if immune in target_traits:
				is_immune = true
				break
		if is_immune:
			continue
			
		var final_damage = _calculate_modified_damage(
			base_damage.duplicate(),
			caster,
			target,
			caster_traits,
			target_traits,
			ability.traits,
			caster_conditions
		)
		
		# DR is skipped here. target.damage_limb and target.take_damage handle it natively!
		var damage_dealt = _deal_damage_to_target(target, final_damage)
		
		result["targets_affected"].append({
			"target": target,
			"damage": damage_dealt,
			"damage_types": final_damage.keys()
		})
		result["total_damage"] += damage_dealt
		
	return result

static func _resolve_apply_condition(
	effect: Dictionary,
	caster: Node,
	targets: Array,
	ability: Ability
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
	var target_limb = effect.get("target_limb", null)
	
	for target in targets:
		if not is_instance_valid(target):
			continue
			
		var target_cond_manager = _get_condition_manager(target)
		if not target_cond_manager:
			continue
			
		# The ConditionManager scales durations internally based on target traits
		var instance = target_cond_manager.apply_condition(
			condition_id,
			caster,
			stacks,
			duration_override,
			target_limb
		)
		
		if instance:
			result["targets_affected"].append(target)
			result["conditions_applied"].append({
				"target": target,
				"condition": condition_id,
				"stacks": instance.stacks
			})
			
	return result
	
	
	
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




## Deal damage to any target type (character, item, or structure)
static func _deal_damage_to_target(target: Node, damage_dict: Dictionary) -> float:
	var total = 0.0
	for damage_type in damage_dict:
		total += damage_dict[damage_type]

	if total <= 0.0:
		return 0.0

	# Characters with limb system — pick a random limb if no hit position
	if target.has_method("damage_limb"):
		var limb_type = _pick_random_limb(target)
		# damage_limb applies its own limb-specific armor DR, so we pass
		# the already-general-DR-reduced dict. To avoid double-dipping,
		# we skip _apply_target_defenses for limbed targets upstream,
		# OR we pass the raw damage here and let damage_limb handle DR.
		# Since we already reduced by torso DR above, just call damage_limb
		# with the dict and accept minor DR approximation for abilities.
		target.damage_limb(limb_type, damage_dict, target.global_position)
	# Items use take_damage(damage_dict, success_level)
	elif target.has_method("take_damage"):
		if target is Item2 or target is Structure:
			target.take_damage(damage_dict, 0)
		else:
			# Unknown type with take_damage — try dict signature
			target.take_damage(damage_dict, 0)
	elif "HP_CURRENT" in target:
		target.HP_CURRENT = max(0, target.HP_CURRENT - total)

	return total


## Pick a random limb weighted by size (for abilities without a specific hit position)
static func _pick_random_limb(target: Node) -> int:
	# LimbType enum: HEAD=0, TORSO=1, LEFT_ARM=2, RIGHT_ARM=3, LEFT_LEG=4, RIGHT_LEG=5
	# Weight torso highest since it's the biggest target
	var weights = [0.1, 0.35, 0.1, 0.1, 0.175, 0.175]
	var roll = randf()
	var cumulative = 0.0
	for i in range(weights.size()):
		cumulative += weights[i]
		if roll <= cumulative:
			return i
	return 1  # Default to torso


## Resolve healing effect
static func _resolve_healing(
	effect: Dictionary,
	caster: Node,
	targets: Array,
	ability: Ability
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
	return 0.0


## Resolve remove condition effect
static func _resolve_remove_condition(
	effect: Dictionary,
	caster: Node,
	targets: Array,
	ability: Ability
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
	ability: Ability
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
	ability: Ability,
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
static func _get_entity_traits(entity: Node) -> Dictionary:
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
