# InventoryItem.gd
extends Resource
class_name InventoryItem

@export var name: String = "Item"
@export var description: String = ""
@export var weight: float = 1.0
@export var value: int = 1
@export var icon: Texture2D
@export var item_type: String = "misc"  # weapon, armor, consumable, ammo, misc
@export var stackable: bool = true
@export var max_stack: int = 99

# For equipment
@export var equipment_slot: String = ""  # helmet, chest, gloves, boots, weapon
@export var equipment_resource: Resource  # Weapon or Armor resource

# For consumables
@export var consumable_effect: String = ""  # heal, buff, etc
@export var effect_value: float = 0.0

func use(character: CharacterController) -> bool:
	if item_type == "consumable":
		return _use_consumable(character)
	elif item_type == "weapon" or item_type == "armor":
		return _equip(character)
	return false

func _use_consumable(character: CharacterController) -> bool:
	match consumable_effect:
		"heal":
			character.stats.blood = min(100, character.stats.blood + effect_value)
			character._update_derived_stats()
			return true
		"restore_mind":
			character.stats.mind = min(100, character.stats.mind + effect_value)
			character._update_derived_stats()
			return true
		"bandage":
			character.bleeding_rate = max(0, character.bleeding_rate - effect_value)
			return true
	return false

func _equip(character: CharacterController) -> bool:
	if item_type == "weapon" and equipment_resource is Weapon:
		character.equipped_weapon = equipment_resource
		character.equipment.weapon = self
		character.attack_range = equipment_resource.attack_range
		character.is_ranged = equipment_resource.is_ranged
		return true
	elif item_type == "armor" and equipment_resource is Armor:
		# Apply armor to covered body parts
		for part_name in equipment_resource.body_parts_covered:
			if character.body_parts.has(part_name):
				character.body_parts[part_name].armor = equipment_resource
		character.equipment[equipment_slot] = self
		return true
	return false
