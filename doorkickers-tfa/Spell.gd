# Spell.gd
extends Resource
class_name Spell

@export var name: String = "Spell"
@export var mind_cost: float = 20.0
@export var mind_requirement: float = 30.0  # Minimum mind needed to cast
@export var cast_time: float = 1.0
@export var range: float = 300.0
@export var area_of_effect: float = 0.0  # 0 for single target

# Damage
@export var deals_damage: bool = true
@export var damage_amount: float = 15.0
@export var damage_type: String = "fire"
@export var targets_body_part: String = ""  # Empty for random

# Status effects
@export var applies_effect: bool = false
@export var effect_type: String = ""  # "slow", "charm", "mind_damage"
@export var effect_value: float = 0.0
@export var effect_duration: float = 5.0
@export var effect_threshold: float = 0.0  # For conditional effects like charm

# Environmental effects
@export var ignites_terrain: bool = false
@export var electrifies_terrain: bool = false

func can_cast(caster: CharacterController) -> bool:
	return caster.stats.mind >= mind_requirement

func cast(caster: CharacterController, target_position: Vector2):
	if not can_cast(caster):
		return false
	
	# Reduce caster's mind
	caster.stats.mind -= mind_cost
	caster._update_derived_stats()
	
	if area_of_effect > 0:
		_cast_aoe(caster, target_position)
	else:
		_cast_single_target(caster, target_position)
	
	return true

func _cast_single_target(caster: CharacterController, target_position: Vector2):
	# Find target at position
	var target = _find_character_at(target_position)
	if not target:
		return
	
	if deals_damage:
		var body_part = targets_body_part if targets_body_part != "" else _random_body_part()
		target.take_damage(damage_amount, damage_type, body_part)
	
	if applies_effect:
		_apply_spell_effect(target)
	
	if ignites_terrain:
		var pathfinding = caster.get_node("/root/Main/PathfindingSystem")
		if pathfinding:
			pathfinding.ignite_tile(target_position)

func _cast_aoe(caster: CharacterController, center: Vector2):
	# Affect all characters in radius
	for character in caster.get_tree().get_nodes_in_group("characters"):
		var distance = character.global_position.distance_to(center)
		if distance <= area_of_effect:
			if deals_damage:
				var body_part = targets_body_part if targets_body_part != "" else _random_body_part()
				character.take_damage(damage_amount, damage_type, body_part)
			
			if applies_effect:
				_apply_spell_effect(character)
	
	# Environmental effects
	if ignites_terrain or electrifies_terrain:
		var pathfinding = caster.get_node("/root/Main/PathfindingSystem")
		if not pathfinding:
			return
		
		# Affect all tiles in radius
		var tile_radius = int(area_of_effect / pathfinding.tile_size)
		var center_tile = pathfinding.world_to_tile(center)
		
		for x in range(-tile_radius, tile_radius + 1):
			for y in range(-tile_radius, tile_radius + 1):
				var tile_pos = center_tile + Vector2i(x, y)
				var world_pos = pathfinding.tile_to_world(tile_pos)
				
				if world_pos.distance_to(center) <= area_of_effect:
					if ignites_terrain:
						pathfinding.ignite_tile(world_pos)
					if electrifies_terrain:
						pathfinding.electrify_tile(world_pos, 10.0)

func _apply_spell_effect(target: CharacterController):
	var effect = {
		"type": effect_type,
		"value": effect_value,
		"duration": effect_duration,
		"threshold": effect_threshold
	}
	
	# Check threshold for conditional effects
	if effect_type == "charm" and target.stats.mind >= effect_threshold:
		return  # Target resisted
	
	target.status_effects.append(effect)

func _find_character_at(position: Vector2) -> CharacterController:
	var min_distance = 20.0  # Tolerance
	var closest = null
	
	for character in Engine.get_main_loop().current_scene.get_tree().get_nodes_in_group("characters"):
		var dist = character.global_position.distance_to(position)
		if dist < min_distance:
			min_distance = dist
			closest = character
	
	return closest

func _random_body_part() -> String:
	var parts = ["head", "torso", "left_arm", "right_arm", "left_leg", "right_leg"]
	return parts[randi() % parts.size()]
