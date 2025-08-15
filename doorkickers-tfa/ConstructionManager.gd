# ConstructionSystem.gd
extends Node2D
class_name ConstructionSystem

# Structure types and their resource costs
var structure_costs = {
	"wood_wall": {"wood": 20},
	"metal_wall": {"metal": 20},
	"wood_floor": {"wood": 10},
	"door": {"wood": 15, "metal": 5}
}

# Player resources
var resources = {
	"wood": 100,
	"metal": 50,
	"stone": 30
}

signal structure_built(structure_type, position)
signal structure_destroyed(structure_type, position, resources_dropped)

func can_build(structure_type: String) -> bool:
	if not structure_costs.has(structure_type):
		return false
	
	var cost = structure_costs[structure_type]
	for resource in cost:
		if not resources.has(resource) or resources[resource] < cost[resource]:
			return false
	
	return true

func build_structure(structure_type: String, position: Vector2) -> bool:
	if not can_build(structure_type):
		return false
	
	# Deduct resources
	var cost = structure_costs[structure_type]
	for resource in cost:
		resources[resource] -= cost[resource]
	
	# Create structure (simplified)
	_create_structure_at(structure_type, position)
	
	structure_built.emit(structure_type, position)
	return true

func destroy_structure(structure: Node2D):
	var structure_type = structure.get_meta("structure_type", "")
	if structure_type == "":
		return
	
	# Calculate resources to drop (50% of original cost)
	var dropped_resources = {}
	if structure_costs.has(structure_type):
		var cost = structure_costs[structure_type]
		for resource in cost:
			dropped_resources[resource] = cost[resource] / 2
	
	# Spawn resource pickups
	for resource in dropped_resources:
		_spawn_resource_pickup(resource, dropped_resources[resource], structure.global_position)
	
	structure_destroyed.emit(structure_type, structure.global_position, dropped_resources)
	structure.queue_free()

func _create_structure_at(type: String, pos: Vector2):
	# This would create the actual structure node
	# For now, just a placeholder
	var structure = StaticBody2D.new()
	structure.set_meta("structure_type", type)
	structure.global_position = pos
	add_child(structure)

func _spawn_resource_pickup(resource_type: String, amount: int, position: Vector2):
	# Create pickup item on ground
	var pickup = Area2D.new()
	pickup.set_meta("resource_type", resource_type)
	pickup.set_meta("amount", amount)
	pickup.global_position = position + Vector2(randf_range(-20, 20), randf_range(-20, 20))
	add_child(pickup)

func collect_resource(resource_type: String, amount: int):
	if resources.has(resource_type):
		resources[resource_type] += amount
	else:
		resources[resource_type] = amount
