# inventory.gd
# Simple inventory and equipment system
extends Node
class_name Inventory

signal item_added(item_data: Dictionary)
signal item_removed(item_data: Dictionary)
signal weapon_equipped(weapon: WeaponShape)
signal weapon_unequipped(weapon: WeaponShape)
signal active_weapon_changed(weapon, hand)
# Inventory storage
var items: Array[Dictionary] = []
var max_slots: int = 20

# Equipment slots
var equipped_weapons: Array = []  # Can hold multiple weapons to swap between
var max_equipped_weapons: int = 4
var active_weapon_index: int = -1  # -1 means no weapon active/drawn
# 2. Track which hand each weapon is equipped to. Add this variable:
var weapon_hands: Dictionary = {}  # Maps weapon -> hand ("Main" or "Off")
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

func get_all_items() -> Array:
	return items

func clear_inventory() -> void:
	items.clear()

# ===== WEAPON EQUIPMENT =====

func equip_item(item: Node2D, hand: String = "Main") -> bool:
	if equipped_weapons.size() >= max_equipped_weapons:
		push_warning("All weapon slots full!")
		return false
	
	if hand == "Main":
		possessor.current_main_hand_item = item
	else:
		possessor.current_off_hand_item = item
	
	equipped_weapons.append(item)
	weapon_hands[item] = hand  # <-- Track which hand
	
	emit_signal("weapon_equipped", item)
	print(possessor.name, " equipped the item ", item, " to hand: ", hand)
	set_active_weapon(equipped_weapons.size() - 1, hand)  # <-- Pass hand
	
	return true
func equip_ability_from_id(ability_id: String, hand: String = "Main") -> bool:
	# 1. Fetch Data
	var data = AbilityDatabase2.get_ability_data(ability_id)
	if data.is_empty():
		return false

	# 2. Create the Node Representation
	var ability_node = AbilityShape.new()
	ability_node.name = data.get("display_name", "Ability")
	
	# 3. Configure the Node (Load VFX, set stats)
	ability_node.setup_from_database(data)
	
	# 4. Equip it using the generic system we made earlier
	# (This handles parenting to the hand and tracking the slot)
	return equip_item(ability_node, hand)
	
func equip_weapon_from_data(weapon_data: Dictionary, hand ="Main") -> WeaponShape:
	var weapon = WeaponShape.new()
	weapon.load_from_data(weapon_data)
	print("attempting to equip weapon from data: ", weapon_data.name)
	if equip_item(weapon, hand):
		print("successfully equipped weapon from data: ", weapon_data.name)
		return weapon
	else:
		print("failed to equip weapon from data")
		weapon.queue_free()
		return null

# 5. Update unequip_weapon to also pass the hand:
func unequip_weapon(index: int) -> Node2D:
	if index < 0 or index >= equipped_weapons.size():
		push_warning("Invalid weapon slot index")
		return null
	
	var weapon = equipped_weapons[index]
	var hand = weapon_hands.get(weapon, "Main")  # Get the hand before removing
	
	equipped_weapons.remove_at(index)
	weapon_hands.erase(weapon)  # Clean up tracking
	
	# Adjust active index if needed
	if active_weapon_index >= equipped_weapons.size():
		active_weapon_index = equipped_weapons.size() - 1
	if active_weapon_index == index:
		active_weapon_index = -1
		emit_signal("active_weapon_changed", null, hand)  # <-- Include hand
	
	emit_signal("weapon_unequipped", weapon)
	return weapon

func get_equipped_weapon(index: int) -> WeaponShape:
	if index < 0 or index >= equipped_weapons.size():
		return null
	return equipped_weapons[index]

func get_active_weapon() -> Node:
	if active_weapon_index < 0 or active_weapon_index >= equipped_weapons.size():
		return null
	return equipped_weapons[active_weapon_index]

func set_active_weapon(index: int, hand: String = "") -> void:
	if index < -1 or index >= equipped_weapons.size():
		push_warning("Invalid active weapon index")
		return
	
	active_weapon_index = index
	var weapon = get_active_weapon()
	
	# Determine hand - use provided hand, or look up from tracking dict
	var weapon_hand = hand
	if weapon_hand == "" and weapon != null and weapon in weapon_hands:
		weapon_hand = weapon_hands[weapon]
	elif weapon_hand == "":
		weapon_hand = "Main"  # Default fallback
	
	emit_signal("active_weapon_changed", weapon, weapon_hand)  # <-- Now includes hand!
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
		weapon_data_list.append(weapon.to_data())
	
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
