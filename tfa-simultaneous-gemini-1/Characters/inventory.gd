# inventory.gd
# Simple inventory and equipment system
extends Node
class_name Inventory

signal item_added(item_data: Dictionary)
signal item_removed(item_data: Dictionary)
signal weapon_equipped(weapon: Weapon)
signal weapon_unequipped(weapon: Weapon)
signal active_weapon_changed(weapon: Weapon)

# Inventory storage
var items: Array[Dictionary] = []
var max_slots: int = 20

# Equipment slots
var equipped_weapons: Array[Weapon] = []  # Can hold multiple weapons to swap between
var max_equipped_weapons: int = 4
var active_weapon_index: int = -1  # -1 means no weapon active/drawn

# Reference to possessor character
var possessor: Node2D

func _ready() -> void:
	possessor = get_parent()

# ===== INVENTORY MANAGEMENT =====

func add_item(item_data: Dictionary) -> bool:
	if items.size() >= max_slots:
		push_warning("Inventory full!")
		return false
	
	items.append(item_data)
	emit_signal("item_added", item_data)
	return true

func remove_item(index: int) -> Dictionary:
	if index < 0 or index >= items.size():
		push_warning("Invalid inventory index")
		return {}
	
	var item = items[index]
	items.remove_at(index)
	emit_signal("item_removed", item)
	return item

func get_item(index: int) -> Dictionary:
	if index < 0 or index >= items.size():
		return {}
	return items[index]

func find_item_by_name(item_name: String) -> int:
	for i in range(items.size()):
		if items[i].get("name", "") == item_name:
			return i
	return -1

func get_all_items() -> Array[Dictionary]:
	return items

func clear_inventory() -> void:
	items.clear()

# ===== WEAPON EQUIPMENT =====

func equip_weapon(weapon: Weapon) -> bool:
	if equipped_weapons.size() >= max_equipped_weapons:
		push_warning("All weapon slots full!")
		return false
	
	equipped_weapons.append(weapon)
	emit_signal("weapon_equipped", weapon)
	
	# If this is the first weapon, make it active
	if equipped_weapons.size() == 1:
		set_active_weapon(0)
	
	return true

func equip_weapon_from_data(weapon_data: Dictionary) -> Weapon:
	var weapon = Weapon.new()
	weapon.load_from_data(weapon_data)
	
	if equip_weapon(weapon):
		return weapon
	else:
		weapon.queue_free()
		return null

func unequip_weapon(index: int) -> Weapon:
	if index < 0 or index >= equipped_weapons.size():
		push_warning("Invalid weapon slot index")
		return null
	
	var weapon = equipped_weapons[index]
	equipped_weapons.remove_at(index)
	
	# Adjust active index if needed
	if active_weapon_index >= equipped_weapons.size():
		active_weapon_index = equipped_weapons.size() - 1
	if active_weapon_index == index:
		active_weapon_index = -1
		emit_signal("active_weapon_changed", null)
	
	emit_signal("weapon_unequipped", weapon)
	return weapon

func get_equipped_weapon(index: int) -> Weapon:
	if index < 0 or index >= equipped_weapons.size():
		return null
	return equipped_weapons[index]

func get_active_weapon() -> Weapon:
	if active_weapon_index < 0 or active_weapon_index >= equipped_weapons.size():
		return null
	return equipped_weapons[active_weapon_index]

func set_active_weapon(index: int) -> void:
	if index < -1 or index >= equipped_weapons.size():
		push_warning("Invalid active weapon index")
		return
	
	active_weapon_index = index
	var weapon = get_active_weapon()
	emit_signal("active_weapon_changed", weapon)

func cycle_weapon(direction: int = 1) -> void:
	if equipped_weapons.size() == 0:
		return
	
	if active_weapon_index == -1:
		# No weapon drawn, draw the first one
		set_active_weapon(0)
	else:
		var new_index = (active_weapon_index + direction) % equipped_weapons.size()
		if new_index < 0:
			new_index = equipped_weapons.size() - 1
		set_active_weapon(new_index)

func holster_weapon() -> void:
	set_active_weapon(-1)

func draw_weapon() -> void:
	if equipped_weapons.size() > 0 and active_weapon_index == -1:
		set_active_weapon(0)

func get_equipped_weapon_count() -> int:
	return equipped_weapons.size()

# ===== SERIALIZATION =====

func save_to_dict() -> Dictionary:
	var weapon_data_list = []
	for weapon in equipped_weapons:
		weapon_data_list.append({
			"type": Weapon.WeaponType.keys()[weapon.weapon_type].to_lower(),
			"name": weapon.weapon_name,
			"blade_color": weapon.blade_color.to_html(),
			"handle_color": weapon.handle_color.to_html(),
			"accent_color": weapon.accent_color.to_html()
		})
	
	return {
		"items": items,
		"equipped_weapons": weapon_data_list,
		"active_weapon_index": active_weapon_index
	}

func load_from_dict(data: Dictionary) -> void:
	# Clear current inventory
	clear_inventory()
	for weapon in equipped_weapons:
		weapon.queue_free()
	equipped_weapons.clear()
	
	# Load items
	if data.has("items"):
		for item in data["items"]:
			add_item(item)
	
	# Load weapons
	if data.has("equipped_weapons"):
		for weapon_data in data["equipped_weapons"]:
			equip_weapon_from_data(weapon_data)
	
	# Set active weapon
	if data.has("active_weapon_index"):
		active_weapon_index = data["active_weapon_index"]
