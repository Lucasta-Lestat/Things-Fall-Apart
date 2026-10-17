# inventory.gd
# Simple inventory and equipment system
extends Node
class_name Inventory

signal item_added(item_data: Dictionary)
signal item_removed(item_data: Dictionary)
signal weapon_equipped(weapon: WeaponShape)
signal weapon_unequipped(weapon: WeaponShape)
signal active_weapon_changed(weapon, hand)
## Emitted whenever add_item/add_stack refuses an item, so failures are never
## silent. Party members show "Inventory full" over their head (see _ready).
signal add_failed(item_data: Dictionary, reason: String)

const EquipmentEffects = preload("res://Items/equipment_effects.gd")
# Inventory storage
var items: Array[Dictionary] = []
## Carry cap: base_max_slots plus bonus_slots from worn packs (a Leather
## Backpack's num_slots), which ProceduralCharacter keeps current from what it
## wears. Assigning max_slots sets the base.
var base_max_slots: int = 20
var bonus_slots: int = 0
var max_slots: int:
	get:
		return base_max_slots + bonus_slots
	set(value):
		base_max_slots = value

## Slots taken toward max_slots: one per entry in `items`. Weapons and
## abilities are nodes (hands, stowed_items) and take none. Starting weapons
## no longer leave a hidden item dict beside their WeaponShape, and old saves
## drop theirs on load (migrate_hand_dicts), so nothing needs exempting.
func slots_used() -> int:
	return items.size()

# Hand slots — each hand holds exactly one item (weapon or ability) or null
var main_hand_item: Node2D = null
var off_hand_item: Node2D = null

# Stowed items that can be cycled into a hand (weapons and abilities not currently held)
var stowed_items: Array = []

# Reference to possessor character
var possessor: Node2D

func _ready() -> void:
	possessor = get_parent()
	add_failed.connect(_on_add_failed)

func _on_add_failed(item_data: Dictionary, reason: String) -> void:
	if possessor == null or not possessor.has_method("notify"):
		return
	if not possessor.has_method("is_party_member") or not possessor.is_party_member():
		return
	var item_name := String(item_data.get("display_name", item_data.get("name", "item")))
	possessor.notify(reason, Color(1.0, 0.75, 0.3),
		"%s can't carry the %s: %s (%d/%d slots)." % [possessor.Name, item_name, reason.to_lower(), slots_used(), max_slots])

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
					# As in add_stack: ownership survives the merge, or handing a
					# stolen arrow to someone carrying clean ones launders it.
					if item_data.has("stolen_from"):
						items[i]["stolen_from"] = item_data["stolen_from"]
						if item_data.has("stolen_value"):
							items[i]["stolen_value"] = item_data["stolen_value"]
					items[i]["num_stacks"] = current_stacks + 1
					emit_signal("item_added", item_data)
					return true

	if slots_used() >= max_slots:
		add_failed.emit(item_data, "Inventory full")
		return false

	items.append(item_data)
	emit_signal("item_added", item_data)
	return true

## True when add_item(item_data) would succeed: a same-id stack has room or a
## slot is free. Transfer code checks this before removing from the source, so
## a full receiver refuses the item instead of swallowing it. Mirrors add_item's
## slot test (slots_used); keep the two in step.
func can_accept(item_data: Dictionary) -> bool:
	if item_data.get("is_stackable", false):
		var item_id = item_data.get("id", "")
		var max_stack = int(item_data.get("max_stack_size", 20))
		for it in items:
			if it.get("id", "") == item_id and int(it.get("num_stacks", 1)) < max_stack:
				return true
	return slots_used() < max_slots

# Like add_item, but transfers the full num_stacks count from item_data
# rather than always adding 1. Use this when receiving an item dict that
# already represents a multi-count stack (chest loot, NPC drops, etc.) so
# the receiving inventory gets all the stacks, merging into existing
# matching stacks first and appending the remainder as a new stack.
#
# Returns false when what is left can't be placed (no free slot). Stacks
# merged into existing ones before that stay merged, and item_data's
# num_stacks is written back to the count still unplaced, so a caller holding
# the source dict (a chest's contents) can leave just the remainder there.
func add_stack(item_data: Dictionary) -> bool:
	# Items.json gives non-stackables (armour, helmets) "num_stacks": null, and
	# int(null) throws: a world Pick Up or chest take of one never got past here.
	var stacks_v = item_data.get("num_stacks", 1)
	var stacks := int(stacks_v) if stacks_v != null else 1
	if stacks < 1:
		stacks = 1
	var is_stackable := bool(item_data.get("is_stackable", false))
	var item_id := String(item_data.get("id", ""))

	if is_stackable:
		var max_stack := int(item_data.get("max_stack_size", 20))
		for i in range(items.size()):
			if stacks <= 0:
				break
			if String(items[i].get("id", "")) != item_id:
				continue
			var current := int(items[i].get("num_stacks", 1))
			var space := max_stack - current
			if space <= 0:
				continue
			var add_now: int = min(stacks, space)
			items[i]["num_stacks"] = current + add_now
			# Ownership must survive the merge — without this, stealing into a
			# pre-seeded matching stack silently launders the goods (the merge
			# path returns without ever appending item_data).
			if item_data.has("stolen_from"):
				items[i]["stolen_from"] = item_data["stolen_from"]
				if item_data.has("stolen_value"):
					items[i]["stolen_value"] = item_data["stolen_value"]
			stacks -= add_now
		if stacks <= 0:
			emit_signal("item_added", item_data)
			return true

	if slots_used() >= max_slots:
		# Keep the caller's dict honest about what is still left to place —
		# any stacks merged above are already in this inventory, and are
		# announced like any other addition (panels redraw, quests count it).
		if is_stackable:
			var merged_any: bool = stacks < maxi(int(item_data.get("num_stacks", 1)), 1)
			item_data["num_stacks"] = stacks
			if merged_any:
				emit_signal("item_added", item_data)
		add_failed.emit(item_data, "Inventory full")
		return false

	# Append the (possibly partial) remainder. Mutate item_data in place —
	# the caller is transferring ownership of this dict to the inventory.
	if is_stackable:
		item_data["num_stacks"] = stacks
	items.append(item_data)
	emit_signal("item_added", item_data)
	return true

func remove_item(index: int) -> Dictionary:
	if index < 0 or index >= items.size():
		push_warning("Invalid inventory index")
		return {}

	var item = items[index]
	# Decrement stack instead of removing if stacked. Return a one-unit COPY,
	# never the resident dict: every transfer UI appends the return value to
	# another container, and handing back the live dict put one Dictionary in
	# two inventories at once (both showing N-1 = net duplication; gold and
	# stackables cloned across chest/trade/corpse windows — review find).
	var stacks_val = item.get("num_stacks", 1)
	var stacks = int(stacks_val) if stacks_val != null else 1
	if stacks > 1:
		items[index]["num_stacks"] = stacks - 1
		var single: Dictionary = item.duplicate()
		single["num_stacks"] = 1
		emit_signal("item_removed", single)
		return single

	items.remove_at(index)
	emit_signal("item_removed", item)
	return item

# Remove `amount` stacks from the item at `index`. Returns the item dict (so the
# caller can spawn a world stack), or {} if invalid. If amount >= current stacks
# the whole slot is removed. Quantity-aware sibling of remove_item.
func remove_amount(index: int, amount: int) -> Dictionary:
	if index < 0 or index >= items.size():
		push_warning("Invalid inventory index")
		return {}
	var item = items[index]
	var stacks_val = item.get("num_stacks", 1)
	var stacks = int(stacks_val) if stacks_val != null else 1
	amount = clampi(amount, 1, stacks)
	if amount >= stacks:
		items.remove_at(index)
	else:
		items[index]["num_stacks"] = stacks - amount
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

func find_item_by_id(item_id: String) -> int:
	for i in range(items.size()):
		if String(items[i].get("id", "")) == item_id:
			return i
	return -1

func get_all_items() -> Array:
	return items

## Old saves: starting weapons used to leave a hidden copy of their item dict
## ("equip_slot": "Main Hand"/"Off Hand") in `items` beside the WeaponShape
## (TopDownCharacterDatabase granted both). Run once after a save's items and
## weapons are back, on a living character. A hand dict whose weapon is held
## or stowed (same id, one dict per weapon) was that copy and is dropped. One
## with no weapon is either the leftover copy of a starting weapon since given
## away (drop_unmatched, a party member's: dropped, or it would come back as a
## free duplicate) or a weapon an NPC picked up before pick-ups stowed weapons
## (stowed as the WeaponShape it should have been, so it shows and can be
## traded). Returns how many dicts left `items`. No signal: no window ever
## listed them.
func migrate_hand_dicts(drop_unmatched: bool) -> int:
	var unclaimed := {}   # weapon id -> held/stowed weapons not yet matched
	for node in get_all_equipped():
		if is_instance_valid(node) and node is WeaponShape:
			var wid := str(node.id)
			unclaimed[wid] = int(unclaimed.get(wid, 0)) + 1
	var moved := 0
	for i in range(items.size() - 1, -1, -1):
		var it = items[i]
		if not EquipmentEffects.is_hand_ghost(it):
			continue
		var iid := str(it.get("id", ""))
		items.remove_at(i)
		moved += 1
		if int(unclaimed.get(iid, 0)) > 0:
			unclaimed[iid] = int(unclaimed[iid]) - 1
		elif not drop_unmatched:
			stow_weapon_from_data(it)
	return moved

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
	# Normalize any unknown hand string (e.g. "Stowed" leaking in from save data)
	# to "Main" so we never silently equip to the off-hand for an unrelated label.
	if preferred != "Main" and preferred != "Off":
		preferred = "Main"
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
## explicit = the player chose this hand ("Equip to Main/Off"), so honour it
## instead of letting _pick_hand move the item to whichever hand is free.
func equip_item(item: Node2D, hand: String = "Main", explicit: bool = false) -> bool:
	# Two-handed weapons always go to main hand
	if _is_two_handed(item):
		if explicit and hand == "Off" and possessor and possessor.has_method("notify") \
				and possessor.has_method("is_party_member") and possessor.is_party_member():
			possessor.notify("Two-handed", Color(1.0, 0.6, 0.4),
				"%s can't hold the %s in the off hand: it is two-handed." % [possessor.Name, item.display_name])
		hand = "Main"
	elif explicit:
		hand = hand if hand == "Off" else "Main"
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

## Add an ability to stowed without equipping it. Used by save/load restore so
## an ability serialized as "Stowed" doesn't get auto-equipped to a hand.
func stow_ability_from_id(ability_id: String) -> bool:
	var data = AbilityDatabase.get_ability_data(ability_id)
	if data.is_empty():
		return false
	var canonical = AbilityShape.new()
	canonical.name = data.get("display_name", "Ability")
	canonical.setup_from_database(data)
	stowed_items.append(canonical)
	emit_signal("weapon_equipped", canonical)
	return true

## Equip a fresh copy of an existing canonical ability (already in stowed_items) to a hand.
## Used when the player wants the same ability in both hands. The hand is the
## player's explicit menu choice, so it isn't redirected to a free hand.
func equip_ability_to_hand(canonical: AbilityShape, hand: String, explicit: bool = true) -> bool:
	if canonical == null:
		return false
	var copy = _spawn_ability_copy(canonical)
	return equip_item(copy, hand, explicit)

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

## Corpse flatten: fold hand/stowed weapon NODES into the `items` dict-array so
## the loot window (which only reads dicts) can offer them, then free the nodes.
## Every weapon is its node alone (starting weapons no longer leave an item
## dict beside it), so each node's data is appended once. Ability shapes are
## not goods — freed without serializing. Idempotent: a second call finds
## empty hands and appends nothing.
func flatten_for_corpse() -> void:
	for node in get_all_equipped():
		if is_instance_valid(node) and node is WeaponShape and node.has_method("to_data"):
			items.append(node.to_data())
		if is_instance_valid(node):
			node.queue_free()
	main_hand_item = null
	off_hand_item = null
	stowed_items.clear()
	if possessor != null:
		possessor.current_main_hand_item = null
		possessor.current_off_hand_item = null

## equip_slot -> EquipmentShape.EquipmentSlot, as PartySidePanel._EQUIP_SLOT_MAP
## (capes share the back slot).
const _WORN_SLOT_BY_NAME := {"Head": 0, "Torso": 1, "Back": 2, "Legs": 3, "Feet": 4, "Cape": 2}
## The possessor's worn-shape property per EquipmentShape.EquipmentSlot value.
const _WORN_SLOT_PROPS := ["head_equipment", "torso_equipment", "back_equipment", "legs_equipment", "feet_equipment"]

## Worn armour on the body (the possessor's EquipmentShapes, with their
## while-worn conditions and DR) follows equip_equipment / unequip_slot, not
## the items' `_equipped` flags. After `items` is replaced wholesale (a
## cancelled trade restores it from deep-copied snapshots), bring the body back
## in line with the flags: a slot with no flagged dict is emptied, a slot whose
## worn piece matches a flagged dict (same id) keeps it and re-points its
## item_data at the restored dict, and any other flagged dict is put on. Gear
## nobody touched is therefore not taken off and put back on, which would strip
## and re-apply its conditions.
func resync_worn_from_items() -> void:
	if possessor == null or not possessor.has_method("equip_equipment") \
			or not possessor.has_method("unequip_slot"):
		return
	# Corpses don't dress or undress: death strips the `_equipped` marks but
	# leaves the worn pieces on the body (as PartySidePanel._equip_item), so
	# a dead party member must not be stripped by an unrelated trade's cancel.
	if possessor.has_method("is_alive") and not possessor.is_alive():
		return
	var flagged := {}  # slot -> Array of flagged armour dicts, in items order
	for item in items:
		if not (item is Dictionary) or not item.get("_equipped", false):
			continue
		var raw_slot = item.get("equip_slot", "")
		var slot: int = _WORN_SLOT_BY_NAME.get(str(raw_slot) if raw_slot != null else "", -1)
		if slot == -1:
			continue
		if not flagged.has(slot):
			flagged[slot] = []
		flagged[slot].append(item)
	for slot in range(_WORN_SLOT_PROPS.size()):
		var shape = possessor.get(_WORN_SLOT_PROPS[slot])
		var worn = shape if (shape != null and is_instance_valid(shape)) else null
		var wanted: Array = flagged.get(slot, [])
		if wanted.is_empty():
			if worn != null:
				possessor.unequip_slot(slot)
			continue
		var keep = null
		if worn != null and worn.has_meta("item_data"):
			var worn_data = worn.get_meta("item_data")
			var worn_id := str(worn_data.get("id", "")) if worn_data is Dictionary else ""
			for d in wanted:
				if worn_id != "" and str(d.get("id", "")) == worn_id:
					keep = d
					break
		if keep != null:
			worn.set_meta("item_data", keep)
		else:
			possessor.equip_equipment(wanted[0])

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
		_notify_swap_refused("Nothing to swap", "nothing is stowed")
		return
	# Can't cycle off-hand while main holds a two-handed weapon
	if hand == "Off" and main_hand_item != null and _is_two_handed(main_hand_item):
		_notify_swap_refused("Both hands on %s" % main_hand_item.display_name,
			"both hands are on the %s" % main_hand_item.display_name)
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

## Swap keys (and queued swaps) come only from the player, so a refused swap
## says why over the party member instead of doing nothing.
func _notify_swap_refused(text: String, reason: String) -> void:
	if not is_instance_valid(possessor) or not possessor.has_method("notify"):
		return
	if not possessor.has_method("is_party_member") or not possessor.is_party_member():
		return
	possessor.notify(text, Color(1.0, 0.6, 0.4), "%s can't swap weapons: %s." % [possessor.Name, reason])

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

	# Load items verbatim, as Game._deserialize_character does: add_item would
	# cap (a worn pack's overflow) and fold a second stack of one id into the
	# first +1 at a time, dropping a stolen tag. Re-wearing below sets the cap.
	# Announced per item as add_item did (panels, quest and vow listeners).
	if data.has("items"):
		for item in data["items"]:
			if item is Dictionary:
				items.append(item)
				item_added.emit(item)

	# Load weapons
	if data.has("equipped_weapons"):
		for weapon_data in data["equipped_weapons"]:
			equip_weapon_from_data(weapon_data)

	# A save from before starting weapons stopped leaving a hidden item dict.
	var alive: bool = possessor == null or not possessor.has_method("is_alive") or possessor.is_alive()
	if alive:
		migrate_hand_dicts(possessor != null and str(possessor.get("faction_id")) == "player")

	# Re-equip worn armor: items keep their _equipped flag through save, but
	# nothing rebuilt the EquipmentShape (no visuals, no DR, no boot-step
	# noise after a load). Route back through equip_equipment.
	var _armor_slots := ["Head", "Torso", "Back", "Legs", "Feet", "Cape"]
	for item in items:
		if item is Dictionary and item.get("_equipped", false) 				and str(item.get("equip_slot", "")) in _armor_slots 				and possessor and possessor.has_method("equip_equipment"):
			possessor.equip_equipment(item)
