# TradeWindow.gd
# Trade overlay paired with the existing PartySidePanel. The player drags items
# between the side panel (live party inventories) and this window's NPC grid.
# All transfers are applied to the live inventories during staging; on Cancel
# (or window close), inventories are restored from snapshots taken at open.
# On Accept, the snapshots are discarded and the transfers stand.
#
# The NPC will only accept the trade when the net flow of value into their
# inventory is non-negative (i.e., they receive at least as much gold value
# as they give up). The Accept button reflects this by enabling/disabling.
extends PanelContainer
class_name TradeWindow

const ITEM_SLOT_SIZE := Vector2(40, 40)
const GRID_COLUMNS := 5

# Set by Game.show_trade_window before add_child.
var npc = null

@onready var game = get_node_or_null("/root/Game")

var _title_label: Label
var _grid: GridContainer
var _balance_label: Label
var _accept_button: Button
var _cancel_button: Button

# Snapshots taken at open. Used both for rollback on cancel and as the
# baseline for the value-flow calculation.
# Shape: {"items": Array[Dictionary] (deep copy), "weapons": Array[{"data": Dictionary, "hand": String}]}
var _player_snapshots: Dictionary = {}  # character -> snapshot
var _npc_snapshot: Dictionary = {}
var _snapshot_npc_value: float = 0.0

var _committed: bool = false
var _handled: bool = false  # set to true on either Accept or Cancel; suppresses _exit_tree rollback

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(380, 460)
	anchor_left = 0.5
	anchor_top = 0.5
	anchor_right = 0.5
	anchor_bottom = 0.5
	offset_left = -190
	offset_top = -230
	offset_right = 190
	offset_bottom = 230

	var bg = StyleBoxFlat.new()
	bg.bg_color = Color(0.10, 0.12, 0.16, 0.95)
	bg.set_corner_radius_all(6)
	bg.set_border_width_all(2)
	bg.border_color = Color(0.4, 0.7, 0.9, 1.0)
	bg.set_content_margin_all(10)
	add_theme_stylebox_override("panel", bg)

	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(vbox)

	# Header.
	var header = HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(header)

	_title_label = Label.new()
	var npc_name: String = npc.Name if (is_instance_valid(npc) and "Name" in npc and npc.Name != "") else "Trader"
	_title_label.text = "Trade with " + npc_name
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.add_theme_font_size_override("font_size", 16)
	header.add_child(_title_label)

	var hint = Label.new()
	hint.text = "Drag items to/from the party panel"
	hint.add_theme_font_size_override("font_size", 10)
	hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(hint)

	vbox.add_child(HSeparator.new())

	# NPC inventory grid.
	var grid_label = Label.new()
	grid_label.text = npc_name + "'s Inventory"
	vbox.add_child(grid_label)

	var scroll = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	_grid = GridContainer.new()
	_grid.columns = GRID_COLUMNS
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_grid)

	# Balance row.
	vbox.add_child(HSeparator.new())
	_balance_label = Label.new()
	_balance_label.add_theme_font_size_override("font_size", 13)
	vbox.add_child(_balance_label)

	# Buttons.
	var btn_row = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	vbox.add_child(btn_row)

	_accept_button = Button.new()
	_accept_button.text = "Accept Trade"
	_accept_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_accept_button.pressed.connect(_on_accept_pressed)
	btn_row.add_child(_accept_button)

	_cancel_button = Button.new()
	_cancel_button.text = "Cancel"
	_cancel_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_cancel_button.pressed.connect(_on_cancel_pressed)
	btn_row.add_child(_cancel_button)

	# Snapshot inventories for rollback + value baseline.
	_take_snapshots()

	# Auto-refresh when NPC's inventory mutates (covers drag-out via PartySidePanel).
	if is_instance_valid(npc) and npc.inventory:
		npc.inventory.item_added.connect(_on_inventory_changed)
		npc.inventory.item_removed.connect(_on_inventory_changed)
		npc.inventory.weapon_equipped.connect(_on_inventory_changed_node)
		npc.inventory.weapon_unequipped.connect(_on_inventory_changed_node)

	# Auto-refresh balance when any party member's inventory mutates too.
	if game:
		for member in game.party_chars:
			if is_instance_valid(member) and member.inventory:
				member.inventory.item_added.connect(_on_inventory_changed)
				member.inventory.item_removed.connect(_on_inventory_changed)
				member.inventory.weapon_equipped.connect(_on_inventory_changed_node)
				member.inventory.weapon_unequipped.connect(_on_inventory_changed_node)

	SfxManager.play_ui("trade_open")
	_populate_grid()
	_recompute_balance()

# ---------------------------------------------------------------------------
# Snapshot / rollback
# ---------------------------------------------------------------------------

func _take_snapshots() -> void:
	if not is_instance_valid(npc):
		return
	_npc_snapshot = _snapshot_character(npc)
	_snapshot_npc_value = _compute_inventory_value(npc)
	if game:
		for member in game.party_chars:
			if is_instance_valid(member):
				_player_snapshots[member] = _snapshot_character(member)

func _snapshot_character(character) -> Dictionary:
	var inv = character.inventory
	var items_copy: Array = []
	for item in inv.items:
		items_copy.append(item.duplicate(true) if item is Dictionary else item)
	var weapons_data: Array = []
	if inv.main_hand_item is WeaponShape:
		weapons_data.append({"data": inv.main_hand_item.to_data(), "hand": "Main"})
	if inv.off_hand_item is WeaponShape:
		weapons_data.append({"data": inv.off_hand_item.to_data(), "hand": "Off"})
	for w in inv.stowed_items:
		if w is WeaponShape:
			weapons_data.append({"data": w.to_data(), "hand": "Stowed"})
	return {"items": items_copy, "weapons": weapons_data}

func _rollback_character(character, snapshot: Dictionary) -> void:
	var inv = character.inventory
	# Free current weapons (hands + stowed).
	var current_weapons = inv.get_all_equipped()
	if inv.main_hand_item != null:
		inv.unequip_hand("Main")
	if inv.off_hand_item != null:
		inv.unequip_hand("Off")
	for w in inv.stowed_items.duplicate():
		inv.stowed_items.erase(w)
		inv.emit_signal("weapon_unequipped", w)
	for w in current_weapons:
		if is_instance_valid(w):
			w.queue_free()
	inv.stowed_items.clear()

	# Restore items (signal-emitting append so the side panel refreshes).
	inv.items.clear()
	for item in snapshot.get("items", []):
		var copy = item.duplicate(true) if item is Dictionary else item
		inv.items.append(copy)
	# Force a UI refresh — PartySidePanel listens to item_added/removed.
	inv.emit_signal("item_added", {})

	# Restore weapons.
	for w_entry in snapshot.get("weapons", []):
		var w_data: Dictionary = w_entry.get("data", {})
		var hand: String = w_entry.get("hand", "Stowed")
		if hand == "Main" or hand == "Off":
			inv.equip_weapon_from_data(w_data, hand)
		else:
			inv.stow_weapon_from_data(w_data)

# ---------------------------------------------------------------------------
# Value calculation
# ---------------------------------------------------------------------------

func _compute_inventory_value(character) -> float:
	var total := 0.0
	if not is_instance_valid(character) or character.inventory == null:
		return 0.0
	for item in character.inventory.items:
		if not (item is Dictionary):
			continue
		var stacks_val = item.get("num_stacks", 1)
		var stacks: int = int(stacks_val) if stacks_val != null else 1
		total += float(item.get("cost", 0.0)) * max(stacks, 1)
	for w in character.inventory.get_all_equipped():
		if w and "cost" in w:
			total += float(w.cost)
	return total

func _recompute_balance() -> void:
	if not is_instance_valid(npc):
		return
	var current_npc_value = _compute_inventory_value(npc)
	var net_to_npc = current_npc_value - _snapshot_npc_value
	if net_to_npc >= 0.0:
		_balance_label.text = "Acceptable — NPC gains %.0f gold value" % net_to_npc
		_balance_label.add_theme_color_override("font_color", Color(0.4, 0.9, 0.4))
		_accept_button.disabled = false
	else:
		_balance_label.text = "NPC needs %.0f more gold value to accept" % abs(net_to_npc)
		_balance_label.add_theme_color_override("font_color", Color(0.9, 0.35, 0.35))
		_accept_button.disabled = true

# ---------------------------------------------------------------------------
# NPC grid rendering
# ---------------------------------------------------------------------------

func _populate_grid() -> void:
	if not is_instance_valid(_grid):
		return
	for child in _grid.get_children():
		child.queue_free()
	if not is_instance_valid(npc) or npc.inventory == null:
		return

	# Items first (preserve source_index for remove_item).
	for i in range(npc.inventory.items.size()):
		var item: Dictionary = npc.inventory.items[i]
		var equip_slot: String = str(item.get("equip_slot", ""))
		# Skip ghost item dicts that mirror equipped weapons (TopDownCharacterDatabase
		# adds both an item dict and a WeaponShape for starter weapons).
		if equip_slot == "Main Hand" or equip_slot == "Off Hand":
			continue
		var raw_stacks = item.get("num_stacks", 1)
		var entry := {
			"kind": "item",
			"display_name": item.get("display_name", item.get("id", "?")),
			"sprite_path": str(item.get("sprite_path", "")) if item.get("sprite_path") != null else "",
			"num_stacks": int(raw_stacks) if raw_stacks != null else 1,
			"equipped": false,
			"hand": "",
			"source_index": i,
			"raw": item,
		}
		_grid.add_child(_create_slot(entry))

	# Weapons (one entry per WeaponShape).
	if npc.inventory.main_hand_item is WeaponShape:
		_grid.add_child(_create_slot(_make_weapon_entry(npc.inventory.main_hand_item, "Main", true)))
	if npc.inventory.off_hand_item is WeaponShape:
		_grid.add_child(_create_slot(_make_weapon_entry(npc.inventory.off_hand_item, "Off", true)))
	for w in npc.inventory.stowed_items:
		if w is WeaponShape:
			_grid.add_child(_create_slot(_make_weapon_entry(w, "", false)))

func _make_weapon_entry(node: WeaponShape, hand: String, equipped: bool) -> Dictionary:
	var sprite_path = node.sprite_path if "sprite_path" in node else ""
	return {
		"kind": "weapon",
		"display_name": node.display_name,
		"sprite_path": str(sprite_path) if sprite_path != null else "",
		"num_stacks": 1,
		"equipped": equipped,
		"hand": hand,
		"source_index": -1,
		"raw": node,
	}

func _create_slot(entry: Dictionary) -> PanelContainer:
	var slot = PanelContainer.new()
	slot.custom_minimum_size = ITEM_SLOT_SIZE
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.tooltip_text = "%s (%.0f gold)" % [entry.get("display_name", "Unknown"), _entry_cost(entry)]

	var bg = StyleBoxFlat.new()
	bg.bg_color = Color(0.2, 0.2, 0.25, 0.85)
	bg.set_corner_radius_all(4)
	if entry.get("equipped", false):
		bg.set_border_width_all(2)
		bg.border_color = Color(1.0, 0.85, 0.2, 1.0)
	slot.add_theme_stylebox_override("panel", bg)

	var sprite_path: String = str(entry.get("sprite_path", ""))
	if not sprite_path.is_empty() and ResourceLoader.exists(sprite_path):
		var tex = TextureRect.new()
		tex.texture = load(sprite_path)
		tex.custom_minimum_size = ITEM_SLOT_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(tex)
	else:
		var label = Label.new()
		var disp_name: String = entry.get("display_name", "?")
		label.text = disp_name.substr(0, 4) if disp_name.length() > 4 else disp_name
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 9)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(label)

	var num_stacks: int = int(entry.get("num_stacks", 1))
	if num_stacks > 1:
		var stack_label = Label.new()
		stack_label.text = str(num_stacks)
		stack_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		stack_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		stack_label.add_theme_font_size_override("font_size", 10)
		stack_label.add_theme_color_override("font_color", Color.WHITE)
		stack_label.add_theme_color_override("font_shadow_color", Color.BLACK)
		stack_label.add_theme_constant_override("shadow_offset_x", 1)
		stack_label.add_theme_constant_override("shadow_offset_y", 1)
		stack_label.custom_minimum_size = ITEM_SLOT_SIZE
		stack_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(stack_label)

	slot.set_meta("entry", entry)
	return slot

func _entry_cost(entry: Dictionary) -> float:
	if entry.get("kind", "") == "weapon":
		var w = entry.get("raw")
		if w and "cost" in w:
			return float(w.cost)
		return 0.0
	var raw: Dictionary = entry.get("raw", {})
	var stacks_val = raw.get("num_stacks", 1)
	var stacks: int = int(stacks_val) if stacks_val != null else 1
	return float(raw.get("cost", 0.0)) * max(stacks, 1)

# ---------------------------------------------------------------------------
# Drag and drop
# ---------------------------------------------------------------------------

func _get_drag_data(at_position: Vector2):
	var slot = _find_slot_at(at_position)
	if not slot:
		return null
	var entry: Dictionary = slot.get_meta("entry")
	set_drag_preview(_create_drag_preview(entry))
	return {
		"source_npc": npc,
		"entry": entry,
		"source_window": self,
	}

func _create_drag_preview(entry: Dictionary) -> Control:
	var sprite_path: String = str(entry.get("sprite_path", ""))
	if not sprite_path.is_empty() and ResourceLoader.exists(sprite_path):
		var tex = TextureRect.new()
		tex.texture = load(sprite_path)
		tex.custom_minimum_size = ITEM_SLOT_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		return tex
	var label = Label.new()
	label.text = entry.get("display_name", "Item")
	label.add_theme_font_size_override("font_size", 12)
	return label

func _can_drop_data(at_position: Vector2, data) -> bool:
	if data is not Dictionary:
		return false
	# Accept party-member drops (player giving items to NPC).
	return data.has("source_character")

func _drop_data(at_position: Vector2, data) -> void:
	if not is_instance_valid(npc):
		return
	var entry: Dictionary = data.get("entry", {})
	var source_char = data.get("source_character")
	if not is_instance_valid(source_char):
		return
	match entry.get("kind", ""):
		"item":
			var item = source_char.inventory.remove_item(entry.get("source_index", -1))
			if not item.is_empty():
				npc.inventory.add_item(item)
		"weapon":
			var weapon = entry.get("raw")
			if weapon == null or not is_instance_valid(weapon):
				return
			var weapon_data = weapon.to_data()
			var src_inv = source_char.inventory
			if weapon == src_inv.main_hand_item:
				src_inv.unequip_hand("Main")
			elif weapon == src_inv.off_hand_item:
				src_inv.unequip_hand("Off")
			else:
				src_inv.stowed_items.erase(weapon)
				src_inv.emit_signal("weapon_unequipped", weapon)
			weapon.queue_free()
			npc.inventory.stow_weapon_from_data(weapon_data)
	SfxManager.play_ui("coin_pickup")
	# Auto-refresh via inventory signals will fire _on_inventory_changed.

func _find_slot_at(pos: Vector2) -> PanelContainer:
	var global_pos = get_global_transform() * pos
	for child in _grid.get_children():
		if child is PanelContainer and child.get_global_rect().has_point(global_pos):
			return child
	return null

# ---------------------------------------------------------------------------
# Inventory-change reactor (fires after any drop on either side)
# ---------------------------------------------------------------------------

func _on_inventory_changed(_unused = null) -> void:
	_populate_grid()
	_recompute_balance()

func _on_inventory_changed_node(_unused = null) -> void:
	_populate_grid()
	_recompute_balance()

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _on_accept_pressed() -> void:
	if _accept_button.disabled:
		return
	_committed = true
	_handled = true
	_disconnect_inventory_signals()
	SfxManager.play_ui("trade_accept")
	queue_free()

func _on_cancel_pressed() -> void:
	_handled = true
	_rollback_all()
	SfxManager.play_ui("trade_decline")
	queue_free()

func _rollback_all() -> void:
	# Disconnect inventory signals first so the rollback's emit_signal calls
	# don't reenter _populate_grid / _recompute_balance on this (closing) window.
	_disconnect_inventory_signals()
	if is_instance_valid(npc):
		_rollback_character(npc, _npc_snapshot)
	for member in _player_snapshots.keys():
		if is_instance_valid(member):
			_rollback_character(member, _player_snapshots[member])

func _disconnect_inventory_signals() -> void:
	if is_instance_valid(npc) and npc.inventory:
		_safe_disconnect(npc.inventory, "item_added", _on_inventory_changed)
		_safe_disconnect(npc.inventory, "item_removed", _on_inventory_changed)
		_safe_disconnect(npc.inventory, "weapon_equipped", _on_inventory_changed_node)
		_safe_disconnect(npc.inventory, "weapon_unequipped", _on_inventory_changed_node)
	for member in _player_snapshots.keys():
		if is_instance_valid(member) and member.inventory:
			_safe_disconnect(member.inventory, "item_added", _on_inventory_changed)
			_safe_disconnect(member.inventory, "item_removed", _on_inventory_changed)
			_safe_disconnect(member.inventory, "weapon_equipped", _on_inventory_changed_node)
			_safe_disconnect(member.inventory, "weapon_unequipped", _on_inventory_changed_node)

func _safe_disconnect(obj: Object, sig: String, callable: Callable) -> void:
	if obj.is_connected(sig, callable):
		obj.disconnect(sig, callable)

func _exit_tree() -> void:
	# If the window was closed without explicit accept/cancel (e.g. parent freed),
	# treat it as a cancel: rollback to keep state consistent.
	if not _handled:
		_rollback_all()
		SfxManager.play_ui("trade_close")
