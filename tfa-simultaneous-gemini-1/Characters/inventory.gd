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

## Stow an item from a hand. Weapons go back to stowed_items. Ability copies are
## queue_free'd because the canonical AbilityShape always lives in stowed_items.
func _stow_item(item: Node2D, hand: String) -> void:
	if hand == "Main":
		main_hand_item = null
		possessor.current_main_hand_item = null
	else:
		off_hand_item = null
		possessor.current_off_hand_item = null
	emit_signal("active_weapon_changed", null, hand)

	if item is AbilityShape:
		item.queue_free()
	else:
		stowed_items.append(item)
	emit_signal("weapon_unequipped", item)

## Public: move whatever is in the given hand back to stowed (or discard if ability copy).
func stow_hand(hand: String) -> void:
	var item = _get_hand_item(hand)
	if item != null:
		_stow_item(item, hand)

## Spawn a fresh AbilityShape clone of the given canonical ability. Used so the same
## ability can be wielded in both hands while a single canonical instance lives in stowed.
func _spawn_ability_copy(source: AbilityShape) -> AbilityShape:
	var copy = AbilityShape.new()
	copy.name = source.name
	copy.setup_from_database(source.raw_data)
	return copy

## Add an ability to the inventory. The canonical AbilityShape is appended to stowed_items;
## if the preferred hand is empty, a fresh copy is spawned and equipped there.
func add_ability_by_id(ability_id: String, hand: String = "Main") -> bool:
	var data = AbilityDatabase.get_ability_data(ability_id)
	if data.is_empty():
		return false

	var canonical = AbilityShape.new()
	canonical.name = data.get("display_name", "Ability")
	canonical.setup_from_database(data)
	stowed_items.append(canonical)
	emit_signal("weapon_equipped", canonical)

	if _hand_is_empty(hand):
		var copy = _spawn_ability_copy(canonical)
		equip_item(copy, hand)
	return true

func equip_ability_from_id(ability_id: String, hand: String = "Main") -> bool:
	return add_ability_by_id(ability_id, hand)

## Equip a fresh copy of an existing canonical ability (already in stowed_items) to a hand.
## Used when the player wants the same ability in both hands.
func equip_ability_to_hand(canonical: AbilityShape, hand: String) -> bool:
	if canonical == null:
		return false
	var copy = _spawn_ability_copy(canonical)
	return equip_item(copy, hand)

func equip_weapon_from_data(weapon_data: Dictionary, hand = "Main") -> WeaponShape:
	var weapon = WeaponShape.new()
	weapon.load_from_data(weapon_data)
	if equip_item(weapon, hand):
		return weapon
	else:
		weapon.queue_free()
		return null

## Reconstruct a WeaponShape from data and append it to stowed_items without auto-equipping.
## Used for cross-character weapon transfer via drag-drop in the side panel.
func stow_weapon_from_data(weapon_data: Dictionary) -> WeaponShape:
	var weapon = WeaponShape.new()
	weapon.load_from_data(weapon_data)
	stowed_items.append(weapon)
	emit_signal("weapon_equipped", weapon)
	return weapon

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

## Cycle the item in a hand. Weapons rotate exclusively (move from stowed → hand → stowed).
## Abilities behave differently: the canonical AbilityShape stays in stowed and a fresh
## copy is spawned for the hand, so the same ability can occupy both hands at once.
func cycle_weapon_for_hand(hand: String, direction: int = 1) -> void:
	if stowed_items.is_empty():
		return
	# Can't cycle off-hand while main holds a two-handed weapon
	if hand == "Off" and main_hand_item != null and _is_two_handed(main_hand_item):
		return

	var pick_index = 0 if direction >= 0 else stowed_items.size() - 1
	var picked = stowed_items[pick_index]
	stowed_items.remove_at(pick_index)

	# Two-handed weapons must live in the main hand. If the player cycled the
	# off-hand but the picked item is two-handed, redirect this whole cycle to
	# the main hand so the off-hand is properly emptied below.
	if hand == "Off" and _is_two_handed(picked):
		hand = "Main"

	var current = _get_hand_item(hand)

	# Outgoing hand item first: weapons rotate back into stowed, ability copies are
	# discarded (canonical lives in stowed).
	if current != null:
		if current is AbilityShape:
			current.queue_free()
		else:
			if direction >= 0:
				stowed_items.append(current)
			else:
				stowed_items.insert(0, current)

	# Then the picked item: abilities re-insert the canonical at the rotation tail
	# (so the next press advances past it) and equip a fresh copy. Weapons go to the hand.
	var to_equip: Node2D = picked
	if picked is AbilityShape:
		if direction >= 0:
			stowed_items.append(picked)
		else:
			stowed_items.insert(0, picked)
		to_equip = _spawn_ability_copy(picked)

	# Update hand slot reference — possessor.current_*_hand_item is set by the
	# active_weapon_changed signal handler.
	if hand == "Main":
		main_hand_item = to_equip
	else:
		off_hand_item = to_equip

	emit_signal("active_weapon_changed", to_equip, hand)

	if to_equip is WeaponShape and is_instance_valid(possessor):
		SfxManager.play("draw-steel", possessor.global_position)

	# If a two-handed weapon was cycled into main hand, stow the off-hand
	if hand == "Main" and _is_two_handed(to_equip) and off_hand_item != null:
		_stow_item(off_hand_item, "Off")

## Legacy cycle_weapon — cycles main hand by default.
func cycle_weapon(direction: int = 1) -> void:
	cycle_weapon_for_hand("Main", direction)

func holster_weapon() -> void:
	if main_hand_item:
		_stow_item(main_hand_item, "Main")

func draw_weapon() -> void:
	if main_hand_item == null and not stowed_items.is_empty():
		var item = stowed_items[0]
		if item is AbilityShape:
			# Canonical stays in stowed; spawn a fresh copy for the hand.
			var copy = _spawn_ability_copy(item)
			main_hand_item = copy
			possessor.current_main_hand_item = copy
			emit_signal("active_weapon_changed", copy, "Main")
		else:
			stowed_items.pop_front()
			main_hand_item = item
			possessor.current_main_hand_item = item
			emit_signal("active_weapon_changed", item, "Main")
			if is_instance_valid(possessor):
				SfxManager.play("draw-steel", possessor.global_position)
		if _is_two_handed(main_hand_item) and off_hand_item != null:
			_stow_item(off_hand_item, "Off")

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
		# Two-handed weapons must live in the main hand.
		if target_hand == "Off" and _is_two_handed(weapon):
			target_hand = "Main"
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
		# If a two-handed weapon ended up in the main hand, stow the off-hand.
		if target_hand == "Main" and _is_two_handed(weapon) and off_hand_item != null:
			_stow_item(off_hand_item, "Off")

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
