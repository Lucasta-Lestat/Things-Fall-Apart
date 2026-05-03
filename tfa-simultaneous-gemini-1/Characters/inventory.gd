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

# Hand slots — each hand holds exactly one item (weapon or ability) or null
var main_hand_item: Node2D = null
var off_hand_item: Node2D = null

# Stowed items that can be cycled into a hand (weapons and abilities not currently held)
var stowed_items: Array = []

# Reference to possessor character
var possessor: Node2D

func _ready() -> void:
	possessor = get_parent()

# ===== INVENTORY MANAGEMENT =====

func add_item(item_data: Dictionary) -> bool:
	# Try to stack with an existing item of the same id
	if item_data.get("is_stackable", false):
		var item_id = item_data.get("id", "")
		var max_stack = int(item_data.get("max_stack_size", 20))
		for i in range(items.size()):
			if items[i].get("id", "") == item_id:
				var current_stacks = int(items[i].get("num_stacks", 1))
				if current_stacks < max_stack:
					items[i]["num_stacks"] = current_stacks + 1
					emit_signal("item_added", item_data)
					return true

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
	# Decrement stack instead of removing if stacked
	var stacks_val = item.get("num_stacks", 1)
	var stacks = int(stacks_val) if stacks_val != null else 1
	if stacks > 1:
		items[index]["num_stacks"] = stacks - 1
		emit_signal("item_removed", item)
		return item

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

func _get_hand_item(hand: String) -> Node2D:
	return main_hand_item if hand == "Main" else off_hand_item

func _hand_is_empty(hand: String) -> bool:
	return _get_hand_item(hand) == null

func _is_two_handed(item: Node2D) -> bool:
	return item is WeaponShape and item.is_two_handed()

## Picks the best hand: prefers the requested hand, uses the other if occupied.
func _pick_hand(preferred: String) -> String:
	# Can't use off-hand when main hand holds a two-handed weapon
	if preferred == "Off" and main_hand_item != null and _is_two_handed(main_hand_item):
		return "Main"
	if _hand_is_empty(preferred):
		return preferred
	var other = "Off" if preferred == "Main" else "Main"
	# Don't fall back to off-hand if main is two-handed
	if other == "Off" and main_hand_item != null and _is_two_handed(main_hand_item):
		return preferred
	if _hand_is_empty(other):
		return other
	return preferred

# ===== WEAPON / ABILITY EQUIPMENT =====

## Equip an item to a hand. If the hand is occupied, the current item is stowed.
func equip_item(item: Node2D, hand: String = "Main") -> bool:
	# Two-handed weapons always go to main hand
	if _is_two_handed(item):
		hand = "Main"
	else:
		hand = _pick_hand(hand)

	# If equipping a two-handed weapon, stow off-hand first
	if _is_two_handed(item) and off_hand_item != null:
		_stow_item(off_hand_item, "Off")

	# If equipping to off-hand while main has a two-handed weapon, stow main first
	if hand == "Off" and main_hand_item != null and _is_two_handed(main_hand_item):
		_stow_item(main_hand_item, "Main")

	# Unequip whatever is currently in this hand → stow it
	var current = _get_hand_item(hand)
	if current != null:
		_stow_item(current, hand)

	# Place the new item in the hand
	if hand == "Main":
		main_hand_item = item
		possessor.current_main_hand_item = item
	else:
		off_hand_item = item
		possessor.current_off_hand_item = item

	emit_signal("weapon_equipped", item)
	emit_signal("active_weapon_changed", item, hand)
	return true

## Stow an item from a hand into the stowed_items pool (no visual, no hand ref).
func _stow_item(item: Node2D, hand: String) -> void:
	# Remove from visual holder via signal (null = nothing in that hand now)
	if hand == "Main":
		main_hand_item = null
		possessor.current_main_hand_item = null
	else:
		off_hand_item = null
		possessor.current_off_hand_item = null
	emit_signal("active_weapon_changed", null, hand)

	stowed_items.append(item)
	emit_signal("weapon_unequipped", item)

## Add an ability: equip to a hand if one is free, otherwise stow it.
func add_ability_by_id(ability_id: String, hand: String = "Main") -> bool:
	var data = AbilityDatabase.get_ability_data(ability_id)
	if data.is_empty():
		return false

	var ability_node = AbilityShape.new()
	ability_node.name = data.get("display_name", "Ability")
	ability_node.setup_from_database(data)

	# If both hands are occupied, stow instead of displacing
	if not _hand_is_empty(hand):
		var other = "Off" if hand == "Main" else "Main"
		if not _hand_is_empty(other):
			stowed_items.append(ability_node)
			return true
	return equip_item(ability_node, hand)

func equip_ability_from_id(ability_id: String, hand: String = "Main") -> bool:
	return add_ability_by_id(ability_id, hand)

func equip_weapon_from_data(weapon_data: Dictionary, hand = "Main") -> WeaponShape:
	var weapon = WeaponShape.new()
	weapon.load_from_data(weapon_data)
	if equip_item(weapon, hand):
		return weapon
	else:
		weapon.queue_free()
		return null

## Remove the item in a specific hand and return it.
func unequip_hand(hand: String) -> Node2D:
	var item = _get_hand_item(hand)
	if item == null:
		return null

	if hand == "Main":
		main_hand_item = null
		possessor.current_main_hand_item = null
	else:
		off_hand_item = null
		possessor.current_off_hand_item = null

	emit_signal("active_weapon_changed", null, hand)
	emit_signal("weapon_unequipped", item)
	return item

## Legacy unequip by global index — finds the item and unequips from its hand.
func unequip_weapon(index: int) -> Node2D:
	# Try to match by checking hands then stowed
	var all_equipped = get_all_equipped()
	if index < 0 or index >= all_equipped.size():
		return null
	var weapon = all_equipped[index]

	if weapon == main_hand_item:
		return unequip_hand("Main")
	elif weapon == off_hand_item:
		return unequip_hand("Off")
	else:
		# It's in stowed
		stowed_items.erase(weapon)
		emit_signal("weapon_unequipped", weapon)
		return weapon

# ===== GETTERS =====

func get_active_weapon() -> Node:
	return main_hand_item

func get_active_weapon_for_hand(hand: String) -> Node:
	return _get_hand_item(hand)

## Returns a flat list of all equipped items (hands + stowed) for legacy compat.
func get_all_equipped() -> Array:
	var result: Array = []
	if main_hand_item:
		result.append(main_hand_item)
	if off_hand_item:
		result.append(off_hand_item)
	result.append_array(stowed_items)
	return result

## Legacy: the old equipped_weapons array — now computed dynamically.
var equipped_weapons: Array:
	get:
		return get_all_equipped()

func get_equipped_weapon(index: int) -> WeaponShape:
	var all = get_all_equipped()
	if index < 0 or index >= all.size():
		return null
	return all[index]

func get_equipped_weapon_count() -> int:
	return get_all_equipped().size()

# ===== CYCLING =====

## Cycle the item in a hand: stow the current item, pull next stowed item in.
func cycle_weapon_for_hand(hand: String, direction: int = 1) -> void:
	if stowed_items.is_empty():
		return
	# Can't cycle off-hand while main holds a two-handed weapon
	if hand == "Off" and main_hand_item != null and _is_two_handed(main_hand_item):
		return

	var current = _get_hand_item(hand)

	# Pick the next stowed item (direction determines which end we pull from)
	var pick_index = 0 if direction >= 0 else stowed_items.size() - 1
	var next_item = stowed_items[pick_index]
	stowed_items.remove_at(pick_index)

	# Stow current hand item (if any) — add to opposite end for round-robin
	if current != null:
		if direction >= 0:
			stowed_items.append(current)
		else:
			stowed_items.insert(0, current)

	# Update hand slot reference — DON'T set possessor references here,
	# the signal handler (_on_active_weapon_changed) manages visual attach/detach
	# and sets possessor.current_*_hand_item.
	if hand == "Main":
		main_hand_item = next_item
	else:
		off_hand_item = next_item

	emit_signal("active_weapon_changed", next_item, hand)

	if next_item is WeaponShape and is_instance_valid(possessor):
		SfxManager.play("draw-steel", possessor.global_position)

	# If a two-handed weapon was cycled into main hand, stow the off-hand
	if hand == "Main" and _is_two_handed(next_item) and off_hand_item != null:
		_stow_item(off_hand_item, "Off")

## Legacy cycle_weapon — cycles main hand by default.
func cycle_weapon(direction: int = 1) -> void:
	cycle_weapon_for_hand("Main", direction)

func holster_weapon() -> void:
	if main_hand_item:
		_stow_item(main_hand_item, "Main")

func draw_weapon() -> void:
	if main_hand_item == null and not stowed_items.is_empty():
		var item = stowed_items.pop_front()
		main_hand_item = item
		possessor.current_main_hand_item = item
		emit_signal("active_weapon_changed", item, "Main")
		if item is WeaponShape and is_instance_valid(possessor):
			SfxManager.play("draw-steel", possessor.global_position)

# Legacy compatibility property for save/load and Game.gd references
var active_weapon_index: int:
	get:
		return 0 if main_hand_item != null else -1
	set(value):
		pass  # No-op for legacy compat

## Legacy: set active weapon by global index (used by Game.gd save/load).
func set_active_weapon(index: int, hand: String = "") -> void:
	var all = get_all_equipped()
	if index < 0 or index >= all.size():
		return
	var weapon = all[index]
	if weapon in stowed_items:
		var target_hand = hand if hand != "" else "Main"
		stowed_items.erase(weapon)
		var current = _get_hand_item(target_hand)
		if current:
			stowed_items.append(current)
		if target_hand == "Main":
			main_hand_item = weapon
			possessor.current_main_hand_item = weapon
		else:
			off_hand_item = weapon
			possessor.current_off_hand_item = weapon
		emit_signal("active_weapon_changed", weapon, target_hand)

# ===== SERIALIZATION =====

func save_to_dict() -> Dictionary:
	var weapon_data_list = []
	for weapon in get_all_equipped():
		weapon_data_list.append(weapon.to_data())

	return {
		"items": items,
		"equipped_weapons": weapon_data_list,
		"active_weapon_index": 0 if main_hand_item else -1,
	}

func load_from_dict(data: Dictionary) -> void:
	# Clear current inventory
	clear_inventory()
	for item in get_all_equipped():
		item.queue_free()
	main_hand_item = null
	off_hand_item = null
	stowed_items.clear()

	# Load items
	if data.has("items"):
		for item in data["items"]:
			add_item(item)

	# Load weapons
	if data.has("equipped_weapons"):
		for weapon_data in data["equipped_weapons"]:
			equip_weapon_from_data(weapon_data)
