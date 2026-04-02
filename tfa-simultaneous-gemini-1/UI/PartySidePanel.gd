# UI/PartySidePanel.gd
# Side panel showing party character portraits, MP bars, and inventories.
# Toggle visibility with Tab. Supports drag-drop and right-click context menus.
extends PanelContainer

const PANEL_WIDTH := 250.0
const SLIDE_DURATION := 0.3
const DUMMY_ICON_PATH := "res://Icons/dummy_icon.png"
const CONTEXT_MENU_SCENE := preload("res://UI/ContextMenu.tscn")

var game_node: Node = null
var panel_visible: bool = true
var _shown_x: float = 0.0
var _hidden_x: float = 0.0
var _tween: Tween = null
var _character_panels: Array = []  # Array of dictionaries with UI references

# Scroll container for the character list
var scroll: ScrollContainer
var vbox: VBoxContainer

func _ready() -> void:
	game_node = get_node_or_null("/root/Game")
	mouse_filter = Control.MOUSE_FILTER_STOP

	# Compute slide positions (panel anchored to right edge)
	_shown_x = -PANEL_WIDTH
	_hidden_x = 0.0

	# Build internal layout
	scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(scroll)

	vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	# Populate after a frame so characters exist
	call_deferred("_populate_party")

func _populate_party() -> void:
	if not game_node:
		return

	for child in vbox.get_children():
		child.queue_free()
	_character_panels.clear()

	for i in range(game_node.party_chars.size()):
		var character = game_node.party_chars[i]
		if not is_instance_valid(character):
			continue
		var panel_data = _create_character_panel(character, i)
		_character_panels.append(panel_data)

func _create_character_panel(character, index: int) -> Dictionary:
	var container = VBoxContainer.new()
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# --- Header: Icon + Name ---
	var header = HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var icon = TextureRect.new()
	icon.custom_minimum_size = Vector2(40, 40)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_load_character_icon(icon, character)
	header.add_child(icon)

	var name_label = Label.new()
	name_label.text = character.display_name
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(name_label)

	container.add_child(header)

	# --- MP Bar ---
	var mp_bar = ProgressBar.new()
	mp_bar.custom_minimum_size = Vector2(0, 14)
	mp_bar.max_value = character.max_MP
	mp_bar.value = character.MP
	mp_bar.show_percentage = false
	# Style the bar blue
	var fill_style = StyleBoxFlat.new()
	fill_style.bg_color = Color(0.2, 0.4, 0.9, 0.9)
	mp_bar.add_theme_stylebox_override("fill", fill_style)
	var bg_style = StyleBoxFlat.new()
	bg_style.bg_color = Color(0.15, 0.15, 0.2, 0.8)
	mp_bar.add_theme_stylebox_override("background", bg_style)
	container.add_child(mp_bar)

	var mp_label = Label.new()
	mp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mp_label.add_theme_font_size_override("font_size", 10)
	container.add_child(mp_label)

	# --- Inventory Grid ---
	var inv_label = Label.new()
	inv_label.text = "Inventory"
	inv_label.add_theme_font_size_override("font_size", 11)
	container.add_child(inv_label)

	var inv_grid = GridContainer.new()
	inv_grid.columns = 5
	inv_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(inv_grid)

	# Separator
	var sep = HSeparator.new()
	sep.custom_minimum_size = Vector2(0, 8)
	container.add_child(sep)

	vbox.add_child(container)

	var data = {
		"character": character,
		"index": index,
		"container": container,
		"icon": icon,
		"name_label": name_label,
		"mp_bar": mp_bar,
		"mp_label": mp_label,
		"inv_grid": inv_grid,
	}

	# Connect inventory signals
	if character.inventory:
		character.inventory.item_added.connect(_on_inventory_changed.bind(data))
		character.inventory.item_removed.connect(_on_inventory_changed.bind(data))

	_refresh_inventory(data)
	return data

func _load_character_icon(tex_rect: TextureRect, character) -> void:
	var template = TopDownCharacterDatabase.get_template(
		character.get("template_id") if "template_id" in character else character.display_name.to_lower()
	)
	var icon_path: String = template.get("icon", "")
	if not icon_path.is_empty() and ResourceLoader.exists(icon_path):
		tex_rect.texture = load(icon_path)
	elif ResourceLoader.exists(DUMMY_ICON_PATH):
		tex_rect.texture = load(DUMMY_ICON_PATH)
	else:
		# Create a colored placeholder
		var img = Image.create(40, 40, false, Image.FORMAT_RGBA8)
		img.fill(character.skin_color if "skin_color" in character else Color.GRAY)
		tex_rect.texture = ImageTexture.create_from_image(img)

func _refresh_inventory(data: Dictionary) -> void:
	var grid: GridContainer = data["inv_grid"]
	var character = data["character"]

	for child in grid.get_children():
		child.queue_free()

	if not character.inventory:
		return

	for i in range(character.inventory.items.size()):
		var item = character.inventory.items[i]
		var slot = _create_item_slot(item, i, data)
		grid.add_child(slot)

func _create_item_slot(item_data: Dictionary, item_index: int, panel_data: Dictionary) -> PanelContainer:
	var slot = PanelContainer.new()
	slot.custom_minimum_size = Vector2(40, 40)
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.tooltip_text = item_data.get("name", item_data.get("id", "Unknown"))

	var bg = StyleBoxFlat.new()
	bg.bg_color = Color(0.2, 0.2, 0.25, 0.8)
	bg.set_corner_radius_all(4)
	slot.add_theme_stylebox_override("panel", bg)

	var label = Label.new()
	label.text = _get_item_short_name(item_data)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 9)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(label)

	# Store metadata for drag-drop and right-click
	slot.set_meta("item_index", item_index)
	slot.set_meta("item_data", item_data)
	slot.set_meta("panel_data", panel_data)

	# Connect input for right-click context menu
	slot.gui_input.connect(_on_slot_gui_input.bind(slot))

	return slot

func _get_item_short_name(item_data: Dictionary) -> String:
	var n = item_data.get("name", item_data.get("id", "?"))
	if n.length() > 5:
		return n.substr(0, 4) + "."
	return n

# ---------------------------------------------------------------------------
# Drag and Drop
# ---------------------------------------------------------------------------

func _get_drag_data(at_position: Vector2):
	# Find which slot is under the cursor
	var slot = _find_slot_at(at_position)
	if not slot:
		return null

	var item_data = slot.get_meta("item_data")
	var panel_data = slot.get_meta("panel_data")
	var item_index = slot.get_meta("item_index")

	# Create drag preview
	var preview = Label.new()
	preview.text = item_data.get("name", item_data.get("id", "Item"))
	preview.add_theme_font_size_override("font_size", 12)
	set_drag_preview(preview)

	return {
		"source_character": panel_data["character"],
		"item_index": item_index,
		"item_data": item_data,
		"source_panel": panel_data,
	}

func _can_drop_data(at_position: Vector2, data) -> bool:
	if data is not Dictionary:
		return false
	if not data.has("source_character"):
		return false
	# Find which character panel we're over
	var target_panel = _find_panel_at(at_position)
	if not target_panel:
		return false
	# Can't drop onto same character
	return target_panel["character"] != data["source_character"]

func _drop_data(at_position: Vector2, data) -> void:
	var target_panel = _find_panel_at(at_position)
	if not target_panel:
		return

	var source_char = data["source_character"]
	var target_char = target_panel["character"]
	var item_index = data["item_index"]

	# Remove from source
	var item = source_char.inventory.remove_item(item_index)
	if item.is_empty():
		return

	# Add to target
	target_char.inventory.add_item(item)

func _find_slot_at(pos: Vector2) -> PanelContainer:
	for panel_data in _character_panels:
		var grid: GridContainer = panel_data["inv_grid"]
		for child in grid.get_children():
			if child is PanelContainer and child.get_global_rect().has_point(get_global_transform() * pos):
				return child
	return null

func _find_panel_at(pos: Vector2) -> Dictionary:
	var global_pos = get_global_transform() * pos
	for panel_data in _character_panels:
		var container = panel_data["container"]
		if container.get_global_rect().has_point(global_pos):
			return panel_data
	return {}

# ---------------------------------------------------------------------------
# Right-click context menu
# ---------------------------------------------------------------------------

func _on_slot_gui_input(event: InputEvent, slot: PanelContainer) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_show_item_context_menu(slot)
			get_viewport().set_input_as_handled()

func _show_item_context_menu(slot: PanelContainer) -> void:
	var item_data: Dictionary = slot.get_meta("item_data")
	var panel_data: Dictionary = slot.get_meta("panel_data")
	var item_index: int = slot.get_meta("item_index")
	var character = panel_data["character"]

	var options: Array = item_data.get("interact_options", ["Use", "Drop"])
	var menu = PopupMenu.new()
	for i in range(options.size()):
		menu.add_item(options[i], i)
	menu.id_pressed.connect(_on_item_menu_selected.bind(character, item_index, item_data, options))

	add_child(menu)
	menu.popup(Rect2i(
		Vector2i(slot.get_screen_position() + Vector2(slot.size.x, 0)),
		Vector2i.ZERO
	))

func _on_item_menu_selected(id: int, character, item_index: int, item_data: Dictionary, options: Array) -> void:
	var option_name = options[id] if id < options.size() else ""
	match option_name:
		"Use":
			_use_item(character, item_index, item_data)
		"Throw":
			_throw_item(character, item_index, item_data)
		"Drop":
			_drop_item(character, item_index, item_data)
		_:
			print("Unhandled item option: ", option_name)

func _use_item(character, item_index: int, item_data: Dictionary) -> void:
	var use_ability_id = item_data.get("use_ability", "")
	if use_ability_id is String and not use_ability_id.is_empty():
		var ability_data = AbilityDatabase.get_ability_data(use_ability_id)
		if not ability_data.is_empty() and character.ability_manager:
			character.ability_manager.use_ability(ability_data, character, character.global_position)
	# Consume the item
	character.inventory.remove_item(item_index)

func _throw_item(character, item_index: int, item_data: Dictionary) -> void:
	if not game_node:
		return

	# Remove from inventory
	var item = character.inventory.remove_item(item_index)
	if item.is_empty():
		return

	# Get mouse position in world space
	var mouse_pos = character.get_global_mouse_position()
	var direction = (mouse_pos - character.global_position).normalized()
	var speed = 600.0

	# Create a thrown projectile
	var projectile = {
		"type": "thrown_item",
		"item_data": item,
		"position": character.global_position,
		"velocity": direction * speed,
		"shooter": character,
		"max_range": 400.0,
		"distance_traveled": 0.0,
		"damage": item.get("damage", {"bludgeoning": 2}),
		"size": Vector2(8, 8),
	}

	# Use the game's projectile system if available
	if game_node.has_method("_add_thrown_projectile"):
		game_node._add_thrown_projectile(projectile)
	else:
		# Fallback: just drop the item at mouse position
		game_node.create_item(item.get("id", ""), mouse_pos)

func _drop_item(character, item_index: int, item_data: Dictionary) -> void:
	if not game_node:
		return

	var item = character.inventory.remove_item(item_index)
	if item.is_empty():
		return

	game_node.create_item(item.get("id", ""), character.global_position)

# ---------------------------------------------------------------------------
# Inventory change callback
# ---------------------------------------------------------------------------

func _on_inventory_changed(_item_data: Dictionary, panel_data: Dictionary) -> void:
	_refresh_inventory(panel_data)

# ---------------------------------------------------------------------------
# Tab toggle with slide tween
# ---------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_TAB:
			_toggle_panel()
			get_viewport().set_input_as_handled()

func _toggle_panel() -> void:
	if _tween and _tween.is_running():
		_tween.kill()

	panel_visible = not panel_visible
	var target_x: float = _shown_x if panel_visible else _hidden_x

	_tween = create_tween()
	_tween.tween_property(self, "offset_left", target_x, SLIDE_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

# ---------------------------------------------------------------------------
# Per-frame updates (MP bars etc.)
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	for data in _character_panels:
		var character = data["character"]
		if not is_instance_valid(character):
			continue

		var mp_bar: ProgressBar = data["mp_bar"]
		mp_bar.max_value = character.max_MP
		mp_bar.value = character.MP

		var mp_label: Label = data["mp_label"]
		mp_label.text = "%d / %d MP" % [character.MP, character.max_MP]
