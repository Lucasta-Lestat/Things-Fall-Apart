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
var max_equipped_weapons: int = 8
var weapon_hands: Dictionary = {}  # Maps weapon -> hand ("Main" or "Off")

# Per-hand active tracking: index into the hand-filtered list, -1 = holstered
var _active_main_index: int = -1
var _active_off_index: int = -1

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

# ===== HAND HELPERS =====

## Returns all equipped weapons/abilities assigned to the given hand.
func _get_hand_weapons(hand: String) -> Array:
	var result: Array = []
	for weapon in equipped_weapons:
		if weapon_hands.get(weapon, "Main") == hand:
			result.append(weapon)
	return result

## Returns true if the given hand has no weapons equipped to it.
func _hand_is_empty(hand: String) -> bool:
	for weapon in equipped_weapons:
		if weapon_hands.get(weapon, "Main") == hand:
			return false
	return true

## Picks the best hand for a new equip: prefers the requested hand,
## but if it's occupied and the other hand is free, uses the other hand.
func _pick_hand(preferred: String) -> String:
	if _hand_is_empty(preferred):
		return preferred
	var other = "Off" if preferred == "Main" else "Main"
	if _hand_is_empty(other):
		return other
	# Both occupied — add to the preferred hand's pool for cycling
	return preferred

# ===== WEAPON EQUIPMENT =====

func equip_item(item: Node2D, hand: String = "Main") -> bool:
	if equipped_weapons.size() >= max_equipped_weapons:
		push_warning("All weapon slots full!")
		return false

	# Smart hand assignment: use unoccupied hand when possible
	hand = _pick_hand(hand)

	equipped_weapons.append(item)
	weapon_hands[item] = hand

	emit_signal("weapon_equipped", item)
	# Activate this weapon in its hand
	_set_active_for_hand(hand, item)

	return true

func add_ability_by_id(ability_id: String, hand: String = "Main") -> bool:
	return equip_ability_from_id(ability_id, hand)

func equip_ability_from_id(ability_id: String, hand: String = "Main") -> bool:
	var data = AbilityDatabase.get_ability_data(ability_id)
	if data.is_empty():
		return false

	var ability_node = AbilityShape.new()
	ability_node.name = data.get("display_name", "Ability")
	ability_node.setup_from_database(data)
	return equip_item(ability_node, hand)

func equip_weapon_from_data(weapon_data: Dictionary, hand = "Main") -> WeaponShape:
	var weapon = WeaponShape.new()
	weapon.load_from_data(weapon_data)
	if equip_item(weapon, hand):
		return weapon
	else:
		weapon.queue_free()
		return null

func unequip_weapon(index: int) -> Node2D:
	if index < 0 or index >= equipped_weapons.size():
		push_warning("Invalid weapon slot index")
		return null

	var weapon = equipped_weapons[index]
	var hand = weapon_hands.get(weapon, "Main")

	equipped_weapons.remove_at(index)
	weapon_hands.erase(weapon)

	# If the removed weapon was the active one for its hand, clear it
	var hand_weapons = _get_hand_weapons(hand)
	if hand == "Main":
		if hand_weapons.is_empty():
			_active_main_index = -1
			possessor.current_main_hand_item = null
			emit_signal("active_weapon_changed", null, "Main")
		else:
			_active_main_index = clampi(_active_main_index, 0, hand_weapons.size() - 1)
			_set_active_for_hand("Main", hand_weapons[_active_main_index])
	else:
		if hand_weapons.is_empty():
			_active_off_index = -1
			possessor.current_off_hand_item = null
			emit_signal("active_weapon_changed", null, "Off")
		else:
			_active_off_index = clampi(_active_off_index, 0, hand_weapons.size() - 1)
			_set_active_for_hand("Off", hand_weapons[_active_off_index])

	emit_signal("weapon_unequipped", weapon)
	return weapon

func get_equipped_weapon(index: int) -> WeaponShape:
	if index < 0 or index >= equipped_weapons.size():
		return null
	return equipped_weapons[index]

func get_active_weapon() -> Node:
	return get_active_weapon_for_hand("Main")

func get_active_weapon_for_hand(hand: String) -> Node:
	var hand_weapons = _get_hand_weapons(hand)
	var idx = _active_main_index if hand == "Main" else _active_off_index
	if idx < 0 or idx >= hand_weapons.size():
		return null
	return hand_weapons[idx]

func _set_active_for_hand(hand: String, weapon) -> void:
	var hand_weapons = _get_hand_weapons(hand)
	var idx = hand_weapons.find(weapon)
	if idx == -1:
		return
	if hand == "Main":
		_active_main_index = idx
		possessor.current_main_hand_item = weapon
	else:
		_active_off_index = idx
		possessor.current_off_hand_item = weapon
	emit_signal("active_weapon_changed", weapon, hand)

## Legacy: set active weapon by global index (used by Game.gd save/load).
func set_active_weapon(index: int, hand: String = "") -> void:
	if index < 0 or index >= equipped_weapons.size():
		return
	var weapon = equipped_weapons[index]
	var weapon_hand = hand if hand != "" else weapon_hands.get(weapon, "Main")
	_set_active_for_hand(weapon_hand, weapon)

## Cycle through weapons equipped to a specific hand.
func cycle_weapon_for_hand(hand: String, direction: int = 1) -> void:
	var hand_weapons = _get_hand_weapons(hand)
	if hand_weapons.is_empty():
		return

	var current_idx = _active_main_index if hand == "Main" else _active_off_index

	if current_idx == -1:
		# Nothing active in this hand, activate the first one
		_set_active_for_hand(hand, hand_weapons[0])
	else:
		var new_idx = (current_idx + direction) % hand_weapons.size()
		if new_idx < 0:
			new_idx = hand_weapons.size() - 1
		_set_active_for_hand(hand, hand_weapons[new_idx])

## Legacy cycle_weapon — cycles main hand by default.
func cycle_weapon(direction: int = 1) -> void:
	cycle_weapon_for_hand("Main", direction)

func holster_weapon() -> void:
	_active_main_index = -1
	possessor.current_main_hand_item = null
	emit_signal("active_weapon_changed", null, "Main")

func draw_weapon() -> void:
	var main_weapons = _get_hand_weapons("Main")
	if not main_weapons.is_empty() and _active_main_index == -1:
		_set_active_for_hand("Main", main_weapons[0])

func get_equipped_weapon_count() -> int:
	return equipped_weapons.size()

# Legacy compatibility property for save/load and Game.gd references
var active_weapon_index: int:
	get:
		return _active_main_index
	set(value):
		_active_main_index = value

# ===== SERIALIZATION =====

func save_to_dict() -> Dictionary:
	var weapon_data_list = []
	for weapon in equipped_weapons:
		weapon_data_list.append(weapon.to_data())

	return {
		"items": items,
		"equipped_weapons": weapon_data_list,
		"active_weapon_index": _active_main_index,
		"active_off_index": _active_off_index
	}

func load_from_dict(data: Dictionary) -> void:
	# Clear current inventory
	clear_inventory()
	for weapon in equipped_weapons:
		weapon.queue_free()
	equipped_weapons.clear()
	weapon_hands.clear()

	# Load items
	if data.has("items"):
		for item in data["items"]:
			add_item(item)

	# Load weapons
	if data.has("equipped_weapons"):
		for weapon_data in data["equipped_weapons"]:
			equip_weapon_from_data(weapon_data)

	# Set active weapons
	if data.has("active_weapon_index"):
		_active_main_index = data["active_weapon_index"]
	if data.has("active_off_index"):
		_active_off_index = data["active_off_index"]
