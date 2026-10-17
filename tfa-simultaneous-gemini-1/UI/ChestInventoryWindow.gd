# ChestInventoryWindow.gd
# Floating overlay that displays a container's contents and supports drag/drop
# with the PartySidePanel. The container's `contents` (an Array of item dicts,
# on a chest Item or a corpse ProceduralCharacter) is mutated in place; closing
# the window does not undo any transfer.
extends PanelContainer
class_name ChestInventoryWindow

const ITEM_SLOT_SIZE := Vector2(40, 40)
const GRID_COLUMNS := 5

# Set by Game.show_chest_inventory / show_loot_window before add_child.
# Node, not Item: everything used is duck-typed (`contents`, `display_name`,
# `tree_exiting`; CrimeManager's payload guards with `in` checks), so a corpse
# works as the container.
var chest_item: Node = null

@onready var game = get_node_or_null("/root/Game")

var _title_label: Label
var _grid: GridContainer

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(320, 280)
	# Center on screen.
	anchor_left = 0.5
	anchor_top = 0.5
	anchor_right = 0.5
	anchor_bottom = 0.5
	offset_left = -160
	offset_top = -140
	offset_right = 160
	offset_bottom = 140

	var bg = StyleBoxFlat.new()
	bg.bg_color = Color(0.12, 0.12, 0.14, 0.95)
	bg.set_corner_radius_all(6)
	bg.set_border_width_all(2)
	bg.border_color = Color(0.7, 0.55, 0.2, 1.0)
	bg.set_content_margin_all(8)
	add_theme_stylebox_override("panel", bg)

	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(vbox)

	# Header row: title + close button.
	var header = HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(header)

	_title_label = Label.new()
	_title_label.text = chest_item.display_name if is_instance_valid(chest_item) else "Container"
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.add_theme_font_size_override("font_size", 16)
	header.add_child(_title_label)

	var close_btn = Button.new()
	close_btn.text = "X"
	close_btn.custom_minimum_size = Vector2(28, 28)
	close_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	close_btn.pressed.connect(_on_close_pressed)
	header.add_child(close_btn)

	# Spacer. HSeparator is STOP by default, so it forwards drops too.
	var sep = HSeparator.new()
	vbox.add_child(sep)
	_forward_dnd(sep)

	# Grid of slots.
	_grid = GridContainer.new()
	_grid.columns = GRID_COLUMNS
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_grid)

	# Coerce contents to a real array if the JSON loader left it null.
	if is_instance_valid(chest_item):
		if chest_item.contents == null or not (chest_item.contents is Array):
			chest_item.contents = []
		# Auto-close if the chest is destroyed/freed while the window is open.
		chest_item.tree_exiting.connect(_on_chest_destroyed)

	SfxManager.play_ui("chest_open")
	_populate_grid()

func _populate_grid() -> void:
	if not is_instance_valid(_grid):
		return
	for child in _grid.get_children():
		child.queue_free()
	if not is_instance_valid(chest_item) or chest_item.contents == null:
		return

	for i in range(chest_item.contents.size()):
		var item_dict = chest_item.contents[i]
		if not (item_dict is Dictionary):
			continue
		var entry = _entry_from_dict(item_dict, i)
		_grid.add_child(_create_slot(entry))

func _entry_from_dict(item_dict: Dictionary, index: int) -> Dictionary:
	var equip_slot: String = str(item_dict.get("equip_slot", ""))
	var kind := "item"
	if equip_slot == "Main Hand" or equip_slot == "Off Hand":
		kind = "weapon"
	var raw_stacks = item_dict.get("num_stacks", 1)
	return {
		"kind": kind,
		# WeaponShape.to_data() dicts (deposited or corpse weapons) carry "name".
		"display_name": item_dict.get("display_name", item_dict.get("name", item_dict.get("id", "?"))),
		"sprite_path": str(item_dict.get("sprite_path", "")) if item_dict.get("sprite_path") != null else "",
		"num_stacks": int(raw_stacks) if raw_stacks != null else 1,
		"equipped": false,
		"hand": "",
		"source_index": index,
		"raw": item_dict,
	}

func _create_slot(entry: Dictionary) -> PanelContainer:
	var slot = PanelContainer.new()
	slot.custom_minimum_size = ITEM_SLOT_SIZE
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.tooltip_text = preload("res://UI/ItemTooltip.gd").detail_text(entry, "chest")

	var bg = StyleBoxFlat.new()
	bg.bg_color = Color(0.2, 0.2, 0.25, 0.8)
	bg.set_corner_radius_all(4)
	slot.add_theme_stylebox_override("panel", bg)

	var sprite_path: String = str(entry.get("sprite_path", ""))
	if not sprite_path.is_empty() and ResourceLoader.exists(sprite_path):
		var tex = TextureRect.new()
		tex.texture = load(sprite_path)
		tex.custom_minimum_size = ITEM_SLOT_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
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
	# Per-slot input: short clicks pick up to the selected character; drags
	# are forwarded to the window's existing _get_drag_data / _drop_data so
	# all transfer paths share one implementation.
	slot.gui_input.connect(_on_slot_gui_input.bind(slot))
	slot.set_drag_forwarding(
		Callable(self, "_slot_get_drag_data").bind(entry),
		_fwd_can_drop_data.bind(slot),
		_fwd_drop_data.bind(slot),
	)
	return slot

# ---------------------------------------------------------------------------
# Click vs. drag (per-slot input)
# ---------------------------------------------------------------------------

# Pixels the cursor may move between press and release before we treat the
# interaction as a drag rather than a click. Matches Godot's own drag-start
# threshold loosely; small enough that intentional drags always exceed it.
const _CLICK_DRAG_THRESHOLD := 8.0
var _press_global_pos: Vector2 = Vector2.ZERO
var _press_slot: PanelContainer = null

func _on_slot_gui_input(event: InputEvent, slot: PanelContainer) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# Don't consume — Godot's drag detection needs the press to flow
			# through, and we decide click-vs-drag on release.
			_press_global_pos = event.global_position
			_press_slot = slot
		else:
			# Release: if the cursor barely moved, treat as a tap and transfer
			# this slot's item to the currently primary-selected character.
			# A real drag releases on the drop target's _drop_data instead.
			if _press_slot == slot and event.global_position.distance_to(_press_global_pos) < _CLICK_DRAG_THRESHOLD:
				_transfer_slot_to_selected(slot)
				get_viewport().set_input_as_handled()
			_press_slot = null

func _transfer_slot_to_selected(slot: PanelContainer) -> void:
	if not is_instance_valid(chest_item) or game == null:
		return
	var selected = _resolve_target_character()
	if selected == null:
		GameLog.add_entry("No one is free to take that.")
		# Over the container too: the game log starts closed.
		if chest_item is Node2D and chest_item.is_inside_tree():
			Globals.show_floating_text("No one free", chest_item.global_position, chest_item, Color(1.0, 0.6, 0.4), 0, Globals.NOTICE_FONT_SIZE)
		SfxManager.play_ui("trade_decline")
		return
	# A container must never receive from itself: with corpse looting the
	# container CAN be a (dead) party character, and routing its own item back
	# into `contents` merges gold into itself and then erases it (review find).
	if selected == chest_item:
		return
	var entry: Dictionary = slot.get_meta("entry")
	var item_dict = entry.get("raw")
	if not (item_dict is Dictionary) or (item_dict as Dictionary).is_empty():
		return
	if _refuse_during_trade(selected, entry, "take"):
		return
	# Transfer first; only erase from chest on success so a full inventory
	# doesn't lose the item.
	var transferred := false
	var stacks_val = item_dict.get("num_stacks", 1)
	var stacks_before: int = int(stacks_val) if stacks_val != null else 1
	if entry.get("kind", "") == "weapon":
		if selected.inventory.has_method("stow_weapon_from_data"):
			selected.inventory.stow_weapon_from_data(item_dict)
			transferred = true
	else:
		# add_stack transfers the full num_stacks (chest gold piles can be
		# 50+, and add_item would only increment by 1).
		transferred = selected.inventory.add_stack(item_dict)
	if not transferred:
		# A full pack can still have merged part of a stack into one it
		# carries; add_stack writes the remainder back into item_dict, which
		# stays here. The merged part was taken, so it is reported and shown.
		var left_val = item_dict.get("num_stacks", 1)
		if (int(left_val) if left_val != null else 1) < stacks_before:
			CrimeManager.report(selected, "loot", CrimeManager.loot_payload(chest_item))
			SfxManager.play_ui("chest_item_out")
		else:
			# Nothing fit. add_stack already announced "Inventory full" over
			# the party member (Inventory.add_failed), so no second notice;
			# the refusal sound says the click was heard.
			SfxManager.play_ui("trade_decline")
		_populate_grid()
		return
	# Law: a successful take from an owned container is a burglary. The
	# deposit side (_drop_data) is deliberately NOT gated — giving items
	# away is not a crime.
	CrimeManager.report(selected, "loot", CrimeManager.loot_payload(chest_item))
	if chest_item.contents is Array:
		chest_item.contents.erase(item_dict)
	SfxManager.play_ui("chest_item_out")
	_populate_grid()

# Pick the party character that should receive a clicked item. Primary-selected
# wins; falls back to the first valid party member so the click still works
# when nobody has been actively selected yet. Receivers must be ALIVE and must
# not be the container itself — a dead primary_selected (nothing clears
# selection on death) otherwise loots its own corpse into oblivion.
func _resolve_target_character() -> Node:
	if game == null:
		return null
	var candidate = game.get("primary_selected")
	if _can_receive(candidate):
		return candidate
	var party = game.get("party_chars")
	if party is Array:
		for c in party:
			if _can_receive(c):
				return c
	return null

func _can_receive(c) -> bool:
	if not (is_instance_valid(c) and ("inventory" in c) and c.inventory != null):
		return false
	if c == chest_item:
		return false
	return not c.has_method("is_alive") or c.is_alive()

# ---------------------------------------------------------------------------
# Drag and drop
# ---------------------------------------------------------------------------

# Window-level _get_drag_data is kept as a fallback for drags that originate
# on the chest window's empty areas (between slots). Slot drags are handled
# by _slot_get_drag_data via set_drag_forwarding so each slot's `entry` is
# bound directly — avoids needing _find_slot_at to re-derive it from coords.
func _get_drag_data(at_position: Vector2):
	var slot = _find_slot_at(at_position)
	if not slot:
		return null
	var entry: Dictionary = slot.get_meta("entry")
	set_drag_preview(_create_drag_preview(entry))
	return {
		"source_chest": chest_item,
		"entry": entry,
		"source_window": self,
	}

func _slot_get_drag_data(at_position: Vector2, entry: Dictionary) -> Variant:
	set_drag_preview(_create_drag_preview(entry))
	return {
		"source_chest": chest_item,
		"entry": entry,
		"source_window": self,
	}

# Godot looks for a drop target at the control under the cursor and climbs to
# its parents only through MOUSE_FILTER_PASS controls, so STOP controls (the
# slots, the separator) hand drops to the window's own methods, with the
# position moved into the window's space.
func _forward_dnd(ctrl: Control) -> void:
	ctrl.set_drag_forwarding(Callable(), _fwd_can_drop_data.bind(ctrl), _fwd_drop_data.bind(ctrl))

func _to_window_local(ctrl: Control, pos: Vector2) -> Vector2:
	return get_global_transform_with_canvas().affine_inverse() * (ctrl.get_global_transform_with_canvas() * pos)

func _fwd_can_drop_data(at_position: Vector2, data, ctrl: Control) -> bool:
	return _can_drop_data(_to_window_local(ctrl, at_position), data)

func _fwd_drop_data(at_position: Vector2, data, ctrl: Control) -> void:
	_drop_data(_to_window_local(ctrl, at_position), data)

func _create_drag_preview(entry: Dictionary) -> Control:
	var sprite_path: String = str(entry.get("sprite_path", ""))
	if not sprite_path.is_empty() and ResourceLoader.exists(sprite_path):
		var tex = TextureRect.new()
		tex.texture = load(sprite_path)
		tex.custom_minimum_size = ITEM_SLOT_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		return tex
	var label = Label.new()
	label.text = entry.get("display_name", "Item")
	label.add_theme_font_size_override("font_size", 12)
	return label

func _can_drop_data(at_position: Vector2, data) -> bool:
	if data is not Dictionary:
		return false
	# Downtime portrait drags carry a source_character but no item entry.
	if not (data.get("entry") is Dictionary):
		return false
	# Drop from a party member's slot in the side panel. A corpse's own panel
	# row must not deposit into its own loot window (same-inventory transfer
	# destroys the stack — review find).
	if data.has("source_character"):
		return data["source_character"] != chest_item
	# Drop from another chest.
	if data.has("source_chest") and data["source_chest"] != chest_item:
		return true
	return false

func _drop_data(at_position: Vector2, data) -> void:
	if not is_instance_valid(chest_item):
		return
	var entry: Dictionary = data.get("entry", {})

	if data.has("source_character"):
		var source_char = data["source_character"]
		if not is_instance_valid(source_char):
			return
		if _refuse_during_trade(source_char, entry, "put away"):
			return
		match entry.get("kind", ""):
			"item":
				# Moving only the inventory entry would leave worn armour on
				# the body as well as in the chest.
				var worn = entry.get("raw", {})
				if worn is Dictionary and worn.get("_equipped", false):
					source_char.notify("Unequip it first", Color(1.0, 0.6, 0.4),
						"%s can't put the %s away while wearing it." % [source_char.Name, entry.get("display_name", "item")])
					SfxManager.play_ui("trade_decline")
					return
				var item = source_char.inventory.remove_item(entry.get("source_index", -1))
				if not item.is_empty():
					chest_item.contents.append(item)
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
				chest_item.contents.append(weapon_data)
		SfxManager.play_ui("chest_item_in")
		_populate_grid()
		return

	if data.has("source_chest"):
		var other_chest = data["source_chest"]
		if not is_instance_valid(other_chest) or other_chest == chest_item:
			return
		var item_dict = entry.get("raw", {})
		if other_chest.contents is Array:
			other_chest.contents.erase(item_dict)
		chest_item.contents.append(item_dict)
		SfxManager.play_ui("chest_item_in")
		_populate_grid()
		var src_window = data.get("source_window")
		if src_window != null and is_instance_valid(src_window) and src_window.has_method("_populate_grid"):
			src_window._populate_grid()
		return

# An open TradeWindow puts every party inventory back from its snapshot on
# Cancel, so an item moved between the party and this chest meanwhile would be
# duplicated or lost. Refuse those moves until the trade is closed.
func _refuse_during_trade(character, entry: Dictionary, verb: String) -> bool:
	for w in get_tree().get_nodes_in_group("trade_window"):
		if not w.is_queued_for_deletion():
			SfxManager.play_ui("trade_decline")
			if character.has_method("notify"):
				character.notify("Finish the trade first", Color(1.0, 0.6, 0.4),
					"%s can't %s the %s while a trade is open: accept or cancel it first." % [character.Name, verb, entry.get("display_name", "item")])
			return true
	return false

func _find_slot_at(pos: Vector2) -> PanelContainer:
	var global_pos = get_global_transform() * pos
	for child in _grid.get_children():
		if child is PanelContainer and child.get_global_rect().has_point(global_pos):
			return child
	return null

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _on_close_pressed() -> void:
	SfxManager.play_ui("chest_close")
	queue_free()

func _on_chest_destroyed() -> void:
	# Don't play close SFX here — the chest's own destruction effects already fire.
	queue_free()
