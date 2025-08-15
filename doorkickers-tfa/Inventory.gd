# Inventory.gd
extends Resource
class_name Inventory

signal item_added(item, amount)
signal item_removed(item, amount)
signal weight_changed(new_weight)

@export var max_weight: float = 100.0
var current_weight: float = 0.0
var items: Dictionary = {}  # Item -> quantity

func add_item(item: InventoryItem, amount: int = 1) -> bool:
	var total_weight = item.weight * amount
	
	if current_weight + total_weight > max_weight:
		return false
	
	if items.has(item):
		items[item] += amount
	else:
		items[item] = amount
	
	current_weight += total_weight
	item_added.emit(item, amount)
	weight_changed.emit(current_weight)
	return true

func remove_item(item: InventoryItem, amount: int = 1) -> bool:
	if not items.has(item) or items[item] < amount:
		return false
	
	items[item] -= amount
	if items[item] <= 0:
		items.erase(item)
	
	current_weight -= item.weight * amount
	item_removed.emit(item, amount)
	weight_changed.emit(current_weight)
	return true

func has_item(item: InventoryItem, amount: int = 1) -> bool:
	return items.has(item) and items[item] >= amount

func get_items_of_type(type: String) -> Array:
	var filtered = []
	for item in items:
		if item.item_type == type:
			filtered.append(item)
	return filtered
	
	
