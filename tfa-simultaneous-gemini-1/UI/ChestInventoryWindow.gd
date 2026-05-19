# ChestInventoryWindow.gd
# Floating overlay that displays a chest's contents and supports drag/drop with
# the PartySidePanel. The chest's contents (an Array on the Item node) are
# mutated in place; closing the window does not undo any transfer.
extends PanelContainer
class_name ChestInventoryWindow

const ITEM_SLOT_SIZE := Vector2(40, 40)
const GRID_COLUMNS := 5

# Set by Game.show_chest_inventory before add_child.
var chest_item: Item = null

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

	# Spacer.
	var sep = HSeparator.new()
	vbox.add_child(sep)

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
		"display_name": item_dict.get("display_name", item_dict.get("id", "?")),
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
	slot.tooltip_text = entry.get("display_name", "Unknown")

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
	# Per-slot input: short clicks pick up to the selected character; drags
	# are forwarded to the window's existing _get_drag_data / _drop_data so
	# all transfer paths share one implementation.
	slot.gui_input.connect(_on_slot_gui_input.bind(slot))
	slot.set_drag_forwarding(
		Callable(self, "_slot_get_drag_data").bind(entry),
		Callable(self, "_slot_can_drop_data"),
		Callable(self, "_slot_drop_data"),
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
		push_warning("ChestInventoryWindow: no party character available to receive item")
		return
	var entry: Dictionary = slot.get_meta("entry")
	var item_dict = entry.get("raw")
	if not (item_dict is Dictionary) or (item_dict as Dictionary).is_empty():
		return
	# Transfer first; only erase from chest on success so a full inventory
	# doesn't lose the item.
	var transferred := false
	if entry.get("kind", "") == "weapon":
		if selected.inventory.has_method("stow_weapon_from_data"):
			selected.inventory.stow_weapon_from_data(item_dict)
			transferred = true
	else:
		# add_stack transfers the full num_stacks (chest gold piles can be
		# 50+, and add_item would only increment by 1).
		transferred = selected.inventory.add_stack(item_dict)
	if not transferred:
		return
	if chest_item.contents is Array:
		chest_item.contents.erase(item_dict)
	SfxManager.play_ui("chest_item_out")
	_populate_grid()

# Pick the party character that should receive a clicked item. Primary-selected
# wins; falls back to the first valid party member so the click still works
# when nobody has been actively selected yet.
func _resolve_target_character() -> Node:
	if game == null:
		return null
	var candidate = game.get("primary_selected")
	if _has_inventory(candidate):
		return candidate
	var party = game.get("party_chars")
	if party is Array:
		for c in party:
			if _has_inventory(c):
				return c
	return null

func _has_inventory(c) -> bool:
	return is_instance_valid(c) and ("inventory" in c) and c.inventory != null

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

func _slot_can_drop_data(at_position: Vector2, data) -> bool:
	return _can_drop_data(at_position, data)

func _slot_drop_data(at_position: Vector2, data) -> void:
	_drop_data(at_position, data)

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
	# Drop from a party member's slot in the side panel.
	if data.has("source_character"):
		return true
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
		match entry.get("kind", ""):
			"item":
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
