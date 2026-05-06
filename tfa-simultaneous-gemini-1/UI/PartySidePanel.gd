# UI/PartySidePanel.gd
# Side panel showing party character portraits, MP bars, and inventories.
# Toggle visibility with Tab. Supports drag-drop and right-click context menus.
extends PanelContainer

signal panel_visibility_changed(now_visible: bool)

const PANEL_WIDTH := 250.0
const SLIDE_DURATION := 0.3
const DUMMY_ICON_PATH := "res://Icons/dummy_icon.png"
const CONTEXT_MENU_SCENE := preload("res://UI/ContextMenu.tscn")
const ITEM_SLOT_SIZE := Vector2(40, 40)
const COND_ICON_SIZE := Vector2(16, 16)

# Health bar color thresholds (matching old dual_health_bars style)
const HP_COLOR_FULL := Color(0.2, 0.8, 0.2)
const HP_COLOR_MID := Color(0.9, 0.8, 0.1)
const HP_COLOR_LOW := Color(0.8, 0.1, 0.1)
const HP_MID_THRESHOLD := 0.5
const HP_LOW_THRESHOLD := 0.25

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
	scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(scroll)

	vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.mouse_filter = Control.MOUSE_FILTER_STOP
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
	container.mouse_filter = Control.MOUSE_FILTER_STOP

	# --- Header: Icon + Name (clickable to select character) ---
	var header = HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.mouse_filter = Control.MOUSE_FILTER_STOP

	var icon = TextureRect.new()
	icon.custom_minimum_size = Vector2(40, 40)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_load_character_icon(icon, character)
	header.add_child(icon)

	var name_label = Label.new()
	name_label.text = character.display_name
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(name_label)

	# Click header to select this character
	header.gui_input.connect(_on_header_gui_input.bind(index))

	# --- Condition icons row (next to portrait area) ---
	var cond_container = HBoxContainer.new()
	cond_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cond_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cond_container.add_theme_constant_override("separation", 2)
	header.add_child(cond_container)

	container.add_child(header)

	# --- Head Health Bar ---
	var head_label = Label.new()
	head_label.text = "Head"
	head_label.add_theme_font_size_override("font_size", 9)
	head_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.add_child(head_label)

	var head_bar = ProgressBar.new()
	head_bar.custom_minimum_size = Vector2(0, 10)
	head_bar.max_value = 100
	head_bar.value = 100
	head_bar.show_percentage = false
	head_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var head_fill = StyleBoxFlat.new()
	head_fill.bg_color = HP_COLOR_FULL
	head_bar.add_theme_stylebox_override("fill", head_fill)
	var head_bg = StyleBoxFlat.new()
	head_bg.bg_color = Color(0.3, 0.1, 0.1, 0.6)
	head_bar.add_theme_stylebox_override("background", head_bg)
	container.add_child(head_bar)

	# --- Torso Health Bar ---
	var torso_label = Label.new()
	torso_label.text = "Torso"
	torso_label.add_theme_font_size_override("font_size", 9)
	torso_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.add_child(torso_label)

	var torso_bar = ProgressBar.new()
	torso_bar.custom_minimum_size = Vector2(0, 10)
	torso_bar.max_value = 100
	torso_bar.value = 100
	torso_bar.show_percentage = false
	torso_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var torso_fill = StyleBoxFlat.new()
	torso_fill.bg_color = HP_COLOR_FULL
	torso_bar.add_theme_stylebox_override("fill", torso_fill)
	var torso_bg = StyleBoxFlat.new()
	torso_bg.bg_color = Color(0.3, 0.1, 0.1, 0.6)
	torso_bar.add_theme_stylebox_override("background", torso_bg)
	container.add_child(torso_bar)

	# --- MP Bar ---
	var mp_bar = ProgressBar.new()
	mp_bar.custom_minimum_size = Vector2(0, 14)
	mp_bar.max_value = character.max_MP
	mp_bar.value = character.MP
	mp_bar.show_percentage = false
	mp_bar.mouse_filter = Control.MOUSE_FILTER_STOP
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
	mp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.add_child(mp_label)

	# --- Inventory Grid ---
	var inv_label = Label.new()
	inv_label.text = "Inventory"
	inv_label.add_theme_font_size_override("font_size", 11)
	inv_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.add_child(inv_label)

	var inv_grid = GridContainer.new()
	inv_grid.columns = 5
	inv_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inv_grid.mouse_filter = Control.MOUSE_FILTER_STOP
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
		"head_bar": head_bar,
		"head_fill": head_fill,
		"torso_bar": torso_bar,
		"torso_fill": torso_fill,
		"condition_container": cond_container,
		"mp_bar": mp_bar,
		"mp_label": mp_label,
		"inv_grid": inv_grid,
	}

	# Connect inventory signals — any change refreshes the unified grid
	if character.inventory:
		character.inventory.item_added.connect(_on_inventory_changed.bind(data))
		character.inventory.item_removed.connect(_on_inventory_changed.bind(data))
		character.inventory.weapon_equipped.connect(_on_inventory_changed.bind(data))
		character.inventory.weapon_unequipped.connect(_on_inventory_changed.bind(data))
		character.inventory.active_weapon_changed.connect(_on_active_weapon_changed.bind(data))

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

# ---------------------------------------------------------------------------
# Character selection via portrait click
# ---------------------------------------------------------------------------

func _on_header_gui_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if game_node:
				var party = game_node.get_party()
				if index >= 0 and index < party.size():
					var character = party[index]
					if event.ctrl_pressed and game_node.has_method("toggle_character_selection"):
						game_node.toggle_character_selection(character)
					elif game_node.has_method("select_character_by_index"):
						game_node.select_character_by_index(index)
			get_viewport().set_input_as_handled()

# ---------------------------------------------------------------------------
# Inventory display
# ---------------------------------------------------------------------------

func _refresh_inventory(data: Dictionary) -> void:
	var grid: GridContainer = data["inv_grid"]
	var character = data["character"]

	for child in grid.get_children():
		child.queue_free()

	if not character.inventory:
		return

	var entries = _build_inventory_entries(character.inventory)
	for entry in entries:
		var slot = _create_item_slot(entry, data)
		grid.add_child(slot)

# Builds a unified list of display entries covering inventory.items, hand-equipped
# weapons/abilities, and stowed weapons/abilities. Abilities are deduped by ability_id
# so the same ability in both hands collapses to one slot with hand="Both".
func _build_inventory_entries(inventory) -> Array:
	var entries: Array = []

	# 1. Dictionary items. Skip ghost dict entries for hand-slot equipment — those
	# are also represented by a WeaponShape/AbilityShape in main_hand/off_hand/stowed
	# (TopDownCharacterDatabase calls add_item AND equip_weapon_from_data for starter
	# weapons), and we don't want both rows.
	for i in range(inventory.items.size()):
		var item: Dictionary = inventory.items[i]
		var equip_slot: String = str(item.get("equip_slot", ""))
		if equip_slot == "Main Hand" or equip_slot == "Off Hand":
			continue
		var raw_stacks = item.get("num_stacks", 1)
		entries.append({
			"kind": "item",
			"display_name": item.get("display_name", item.get("id", "?")),
			"sprite_path": str(item.get("sprite_path", "")) if item.get("sprite_path") != null else "",
			"num_stacks": int(raw_stacks) if raw_stacks != null else 1,
			"equipped": bool(item.get("_equipped", false)),
			"hand": "",
			"source_index": i,
			"raw": item,
		})

	var main = inventory.main_hand_item
	var off = inventory.off_hand_item

	# 2. Abilities — dedupe by ability_id across stowed + hands
	var ability_entries: Dictionary = {}  # ability_id -> entry dict
	var ability_order: Array = []          # preserves first-seen order
	for shape in inventory.stowed_items:
		if shape is AbilityShape:
			_ensure_ability_entry(shape, ability_entries, ability_order, false, "")
	if main is AbilityShape:
		_ensure_ability_entry(main, ability_entries, ability_order, true, "Main")
	if off is AbilityShape:
		_ensure_ability_entry(off, ability_entries, ability_order, true, "Off")
	for aid in ability_order:
		entries.append(ability_entries[aid])

	# 3. Weapons — one entry per WeaponShape instance
	if main is WeaponShape:
		var hand_label = "Both" if main.is_two_handed() else "Main"
		entries.append(_make_weapon_entry(main, hand_label, true))
	if off is WeaponShape:
		entries.append(_make_weapon_entry(off, "Off", true))
	for shape in inventory.stowed_items:
		if shape is WeaponShape:
			entries.append(_make_weapon_entry(shape, "", false))

	return entries

func _ensure_ability_entry(node: AbilityShape, entries: Dictionary, order: Array, equipped: bool, hand: String) -> void:
	var aid: String = node.ability_id
	if not entries.has(aid):
		var icon_path: String = ""
		if node.raw_data is Dictionary and node.raw_data.has("icon"):
			icon_path = str(node.raw_data["icon"])
		entries[aid] = {
			"kind": "ability",
			"display_name": node.display_name,
			"sprite_path": icon_path,
			"num_stacks": 1,
			"equipped": equipped,
			"hand": hand,
			"source_index": -1,
			"raw": node,
		}
		order.append(aid)
		return

	var entry: Dictionary = entries[aid]
	if equipped:
		entry["equipped"] = true
		if entry["hand"] == "":
			entry["hand"] = hand
		elif entry["hand"] != hand:
			entry["hand"] = "Both"

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

func _create_item_slot(entry: Dictionary, panel_data: Dictionary) -> PanelContainer:
	var slot = PanelContainer.new()
	slot.custom_minimum_size = ITEM_SLOT_SIZE
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.tooltip_text = entry.get("display_name", "Unknown")

	var bg = StyleBoxFlat.new()
	bg.bg_color = Color(0.2, 0.2, 0.25, 0.8)
	bg.set_corner_radius_all(4)
	if entry.get("equipped", false):
		bg.set_border_width_all(2)
		bg.border_color = Color(1.0, 0.85, 0.2, 1.0)  # gold equipped highlight
	slot.add_theme_stylebox_override("panel", bg)

	# Icon, scaled to fit the slot
	var sprite_path: String = str(entry.get("sprite_path", ""))
	if not sprite_path.is_empty() and ResourceLoader.exists(sprite_path):
		var tex_rect = TextureRect.new()
		tex_rect.texture = load(sprite_path)
		tex_rect.custom_minimum_size = ITEM_SLOT_SIZE
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(tex_rect)
	else:
		var label = Label.new()
		label.text = _get_entry_short_name(entry)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 9)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(label)

	# Stack count badge
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

	# L/R hand markers — overlay labels pinned to the slot's left/right edges.
	# "Main" is the character's right hand (right_arm_joints); "Off" is the left.
	var hand: String = entry.get("hand", "")
	if hand == "Off" or hand == "Both":
		slot.add_child(_make_hand_label("L", HORIZONTAL_ALIGNMENT_LEFT))
	if hand == "Main" or hand == "Both":
		slot.add_child(_make_hand_label("R", HORIZONTAL_ALIGNMENT_RIGHT))

	slot.set_meta("entry", entry)
	slot.set_meta("panel_data", panel_data)
	slot.gui_input.connect(_on_slot_gui_input.bind(slot))
	return slot

func _make_hand_label(text: String, alignment: int) -> Label:
	var label = Label.new()
	label.text = text
	label.horizontal_alignment = alignment
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.custom_minimum_size = ITEM_SLOT_SIZE
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label

func _get_entry_short_name(entry: Dictionary) -> String:
	var n: String = entry.get("display_name", "?")
	if n.length() > 5:
		return n.substr(0, 4) + "."
	return n

# ---------------------------------------------------------------------------
# Drag and Drop
# ---------------------------------------------------------------------------

func _get_drag_data(at_position: Vector2):
	var slot = _find_slot_at(at_position)
	if not slot:
		return null

	var entry: Dictionary = slot.get_meta("entry")
	var panel_data = slot.get_meta("panel_data")

	# Abilities are not draggable between characters
	if entry.get("kind", "") == "ability":
		return null

	set_drag_preview(_create_drag_preview_from_entry(entry))

	return {
		"source_character": panel_data["character"],
		"entry": entry,
		"source_panel": panel_data,
	}

func _create_drag_preview_from_entry(entry: Dictionary) -> Control:
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
	if not data.has("source_character"):
		return false
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
	var entry: Dictionary = data["entry"]

	match entry.get("kind", ""):
		"item":
			var item = source_char.inventory.remove_item(entry.get("source_index", -1))
			if not item.is_empty():
				target_char.inventory.add_item(item)
		"weapon":
			_transfer_weapon(source_char, target_char, entry.get("raw"))

func _transfer_weapon(source_char, target_char, weapon) -> void:
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
	target_char.inventory.stow_weapon_from_data(weapon_data)

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
		# Left clicks are NOT consumed here — they need to flow through
		# to _get_drag_data for drag-and-drop to work. The panel's
		# MOUSE_FILTER_STOP already prevents them from reaching the world.

func _show_item_context_menu(slot: PanelContainer) -> void:
	var entry: Dictionary = slot.get_meta("entry")
	var panel_data: Dictionary = slot.get_meta("panel_data")
	var character = panel_data["character"]

	var options: Array = []
	var kind: String = entry.get("kind", "")

	if kind == "item":
		var item_data: Dictionary = entry.get("raw", {})
		options = item_data.get("interact_options", ["Use", "Drop"]).duplicate()
		var equip_slot: String = item_data.get("equip_slot", "")
		if equip_slot in ["Head", "Torso", "Back", "Legs", "Feet"]:
			if item_data.get("_equipped", false):
				options.insert(0, "Unequip")
			else:
				options.insert(0, "Equip")
	elif kind == "weapon" or kind == "ability":
		if entry.get("equipped", false):
			var hand: String = entry.get("hand", "")
			if hand == "Both":
				options.append("Stow Main")
				options.append("Stow Off")
				options.append("Stow Both")
			else:
				options.append("Stow")
		else:
			options.append("Equip to Main")
			options.append("Equip to Off")

	if options.is_empty():
		return

	var menu = PopupMenu.new()
	for i in range(options.size()):
		menu.add_item(options[i], i)
	menu.id_pressed.connect(_on_item_menu_selected.bind(character, entry, options))

	if game_node:
		game_node.context_menu_open = true
	menu.popup_hide.connect(func(): game_node.call_deferred("set", "context_menu_open", false))

	add_child(menu)
	menu.popup(Rect2i(
		Vector2i(slot.get_screen_position() + Vector2(slot.size.x, 0)),
		Vector2i.ZERO
	))

func _on_item_menu_selected(id: int, character, entry: Dictionary, options: Array) -> void:
	SfxManager.play_ui("ui-click")
	var option_name = options[id] if id < options.size() else ""
	var kind: String = entry.get("kind", "")

	if kind == "item":
		var item_index: int = entry.get("source_index", -1)
		var item_data: Dictionary = entry.get("raw", {})
		match option_name:
			"Use":
				_use_item(character, item_index, item_data)
			"Consume":
				_consume_item(character, item_index, item_data)
			"Throw":
				_throw_item(character, item_index, item_data)
			"Drop":
				_drop_item(character, item_index, item_data)
			"Equip":
				_equip_item(character, item_index, item_data)
			"Unequip":
				_unequip_item(character, item_index, item_data)
			_:
				print("Unhandled item option: ", option_name)
		return

	if kind == "weapon" or kind == "ability":
		match option_name:
			"Stow":
				var hand: String = entry.get("hand", "")
				if hand == "Main" or hand == "Off":
					character.inventory.stow_hand(hand)
			"Stow Main":
				character.inventory.stow_hand("Main")
			"Stow Off":
				character.inventory.stow_hand("Off")
			"Stow Both":
				character.inventory.stow_hand("Main")
				character.inventory.stow_hand("Off")
			"Equip to Main":
				_equip_shape_to_hand(character, entry, "Main")
			"Equip to Off":
				_equip_shape_to_hand(character, entry, "Off")
			_:
				print("Unhandled shape option: ", option_name)

func _equip_shape_to_hand(character, entry: Dictionary, hand: String) -> void:
	var node = entry.get("raw")
	if node == null or not is_instance_valid(node):
		return
	if entry.get("kind", "") == "ability":
		# entry.raw is the canonical AbilityShape — spawn a copy for the hand
		character.inventory.equip_ability_to_hand(node, hand)
	else:  # weapon
		if node in character.inventory.stowed_items:
			character.inventory.stowed_items.erase(node)
		character.inventory.equip_item(node, hand)

func _use_item(character, item_index: int, item_data: Dictionary) -> void:
	var use_ability_id = item_data.get("use_ability", "")
	if use_ability_id is String and not use_ability_id.is_empty():
		var ability_data = AbilityDatabase.get_ability_data(use_ability_id)
		if not ability_data.is_empty() and character.ability_manager:
			var ability_obj = Ability.from_dict(ability_data)
			character.ability_manager.use_ability(ability_obj, {"position": character.global_position})
	# Consume the item
	character.inventory.remove_item(item_index)

func _consume_item(character, item_index: int, item_data: Dictionary) -> void:
	"""Use an item on the currently selected character (e.g. potions, food)."""
	# When paused: assign to pending action node or queue
	if PauseManager.is_paused:
		var icon: Texture2D = null
		var sprite_path = item_data.get("sprite_path", "")
		if not sprite_path.is_empty() and ResourceLoader.exists(sprite_path):
			icon = load(sprite_path)

		if character.path_input_handler and character.path_input_handler.is_placing_action():
			character.path_input_handler.assign_item_to_pending_node(
				ActionQueue.ActionType.CUSTOM,
				{"callable": Callable(self, "_execute_consume").bind(character, item_index, item_data)},
				icon
			)
		else:
			character.action_queue.queue_action(
				ActionQueue.ActionType.CUSTOM,
				{"callable": Callable(self, "_execute_consume").bind(character, item_index, item_data)}
			)
		return

	# Unpaused: consume immediately
	_execute_consume(character, item_index, item_data)

func _execute_consume(character, item_index: int, item_data: Dictionary) -> void:
	var target = game_node.selected_character if game_node and game_node.selected_character else character
	var use_ability_id = item_data.get("use_ability", "")
	if use_ability_id is String and not use_ability_id.is_empty():
		var ability_data = AbilityDatabase.get_ability_data(use_ability_id)
		if not ability_data.is_empty() and target.has_node("AbilityManager"):
			var ability_obj = Ability.from_dict(ability_data)
			target.get_node("AbilityManager").use_ability(ability_obj, {"position": target.global_position})
	# Apply satiety if the item has it
	var satiety = item_data.get("satiety", 0.0)
	if satiety > 0 and "hunger" in target:
		target.hunger = max(0, target.hunger - satiety)
	# Apply healing if the item has it
	var healing = item_data.get("healing", 0.0)
	if healing > 0 and target.has_method("heal"):
		target.heal(healing)
	# Apply conditions if the item adds any
	var condition_id = item_data.get("adds_condition_on_equip", "")
	if condition_id is String and not condition_id.is_empty():
		var cm = target.get_node_or_null("ConditionManager")
		if cm:
			cm.apply_condition(condition_id, character)
	# Remove from inventory
	character.inventory.remove_item(item_index)

func _throw_item(character, item_index: int, item_data: Dictionary) -> void:
	if not game_node:
		return

	# When paused: assign to pending action node on tactical path, or queue to ActionQueue
	if PauseManager.is_paused:
		var icon: Texture2D = null
		var sprite_path = item_data.get("sprite_path", "")
		if not sprite_path.is_empty() and ResourceLoader.exists(sprite_path):
			icon = load(sprite_path)

		var throw_data = {
			"item_index": item_index,
			"item_data": item_data.duplicate(),
			"character": character,
		}

		# Check if the character has a pending action node on their tactical path
		if character.path_input_handler and character.path_input_handler.is_placing_action():
			character.path_input_handler.assign_item_to_pending_node(
				ActionQueue.ActionType.CUSTOM,
				{"callable": Callable(self, "_execute_throw").bind(character, item_index, item_data)},
				icon
			)
		else:
			# Queue directly to action queue
			character.action_queue.queue_action(
				ActionQueue.ActionType.CUSTOM,
				{"callable": Callable(self, "_execute_throw").bind(character, item_index, item_data)}
			)
		return

	# Unpaused: enter throw targeting mode on the character
	character.start_throw_targeting(item_index, item_data)

func _execute_throw(character, item_index: int, item_data: Dictionary) -> void:
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

	# If item is currently equipped, unequip it first
	if item_data.get("_equipped", false):
		_unequip_item(character, item_index, item_data)

	var item = character.inventory.remove_item(item_index)
	if item.is_empty():
		return

	game_node.create_item(item.get("id", ""), character.global_position)

	if item.has("primary_damage_type"):
		SfxManager.play("sword-fall", character.global_position)

# Map equip_slot strings to EquipmentShape.EquipmentSlot enum values
const _EQUIP_SLOT_MAP: Dictionary = {
	"Head": 0,   # EquipmentShape.EquipmentSlot.HEAD
	"Torso": 1,  # EquipmentShape.EquipmentSlot.TORSO
	"Back": 2,   # EquipmentShape.EquipmentSlot.BACK
	"Legs": 3,   # EquipmentShape.EquipmentSlot.LEGS
	"Feet": 4,   # EquipmentShape.EquipmentSlot.FEET
}

func _equip_item(character, item_index: int, item_data: Dictionary) -> void:
	"""Equip an equipment item from inventory onto the character."""
	var equip_slot: String = item_data.get("equip_slot", "")
	if equip_slot.is_empty() or equip_slot not in _EQUIP_SLOT_MAP:
		return

	# Unequip whatever is currently in that slot first, returning it to inventory
	var slot_enum: int = _EQUIP_SLOT_MAP[equip_slot]
	_unequip_current_in_slot(character, slot_enum)

	# Equip the new item
	if character.has_method("equip_equipment"):
		character.equip_equipment(item_data)

	# Mark this inventory item as equipped
	item_data["_equipped"] = true

	# Refresh UI to show the change
	_refresh_all_inventories()

func _unequip_item(character, item_index: int, item_data: Dictionary) -> void:
	"""Unequip an equipped item, keeping it in inventory."""
	var equip_slot: String = item_data.get("equip_slot", "")
	if equip_slot.is_empty() or equip_slot not in _EQUIP_SLOT_MAP:
		return

	var slot_enum: int = _EQUIP_SLOT_MAP[equip_slot]
	if character.has_method("unequip_slot"):
		character.unequip_slot(slot_enum)

	# Clear equipped flag on the inventory item
	item_data["_equipped"] = false

	# Refresh UI
	_refresh_all_inventories()

func _unequip_current_in_slot(character, slot_enum: int) -> void:
	"""If something is already equipped in the given slot, clear its _equipped flag."""
	# Find any inventory item marked as equipped in this slot
	for item in character.inventory.items:
		if item.get("_equipped", false):
			var item_slot_str: String = item.get("equip_slot", "")
			if _EQUIP_SLOT_MAP.get(item_slot_str, -1) == slot_enum:
				item["_equipped"] = false
				break

func _refresh_all_inventories() -> void:
	"""Refresh all character inventory displays."""
	for panel_data in _character_panels:
		_refresh_inventory(panel_data)

# ---------------------------------------------------------------------------
# Inventory change callback
# ---------------------------------------------------------------------------

func _on_inventory_changed(_payload, panel_data: Dictionary) -> void:
	_refresh_inventory(panel_data)

func _on_active_weapon_changed(_weapon, _hand, panel_data: Dictionary) -> void:
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

	SfxManager.play_ui("ui-navigation")

	emit_signal("panel_visibility_changed", panel_visible)

# ---------------------------------------------------------------------------
# Per-frame updates (MP bars etc.)
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	for data in _character_panels:
		var character = data["character"]
		if not is_instance_valid(character):
			continue

		# Selection highlight
		var container = data["container"]
		if game_node:
			if game_node.primary_selected == character:
				container.modulate = Color(1.0, 1.0, 1.0, 1.0)
			elif game_node.is_character_selected(character):
				container.modulate = Color(0.8, 0.9, 1.0, 1.0)
			else:
				container.modulate = Color(0.6, 0.6, 0.6, 1.0)

		# Red-tint the portrait when the character is dead
		var icon: TextureRect = data.get("icon")
		if icon:
			icon.modulate = Color(1.0, 0.3, 0.3, 1.0) if not character.is_alive() else Color.WHITE

		# Update health bars
		_update_health_bar(data, "head_bar", "head_fill", 0, character)
		_update_health_bar(data, "torso_bar", "torso_fill", 1, character)

		# Update conditions display
		_update_conditions(data, character)

		var mp_bar: ProgressBar = data["mp_bar"]
		mp_bar.max_value = character.max_MP
		mp_bar.value = character.MP

		var mp_label: Label = data["mp_label"]
		mp_label.text = "%d / %d MP" % [character.MP, character.max_MP]

func _update_health_bar(data: Dictionary, bar_key: String, fill_key: String, limb_type: int, character) -> void:
	var bar: ProgressBar = data[bar_key]
	var fill_style: StyleBoxFlat = data[fill_key]
	if character.limbs.has(limb_type):
		var pct: float = character.limbs[limb_type].get_hp_percent()
		bar.value = pct * 100.0
		if pct <= HP_LOW_THRESHOLD:
			fill_style.bg_color = HP_COLOR_LOW
		elif pct <= HP_MID_THRESHOLD:
			fill_style.bg_color = HP_COLOR_MID
		else:
			fill_style.bg_color = HP_COLOR_FULL

func _update_conditions(data: Dictionary, character) -> void:
	var cond_container: HBoxContainer = data["condition_container"]
	var cm = character.get_node_or_null("ConditionManager")
	if not cm:
		return

	var conditions: Dictionary = cm.conditions
	var existing_children = cond_container.get_children()

	# Quick check: if count matches and IDs match, just update tooltips
	var cond_ids: Array = conditions.keys()
	var needs_rebuild := existing_children.size() != cond_ids.size()
	if not needs_rebuild:
		for i in range(cond_ids.size()):
			if i >= existing_children.size() or existing_children[i].get_meta("cond_id", "") != cond_ids[i]:
				needs_rebuild = true
				break

	if needs_rebuild:
		for child in existing_children:
			child.queue_free()
		for cond_id in cond_ids:
			var instance = conditions[cond_id]
			var cond_res = instance.condition
			var icon_tex = cond_res.icon if cond_res else null
			var tex_rect = TextureRect.new()
			tex_rect.custom_minimum_size = COND_ICON_SIZE
			tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tex_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
			tex_rect.mouse_filter = Control.MOUSE_FILTER_STOP
			if icon_tex and icon_tex is Texture2D:
				tex_rect.texture = icon_tex
			tex_rect.set_meta("cond_id", cond_id)
			cond_container.add_child(tex_rect)

	# Update tooltips with current stacks/duration
	var time_manager = get_node_or_null("/root/TimeManager")
	var game_time: float = time_manager.game_time if time_manager else 0.0
	var children = cond_container.get_children()
	for i in range(children.size()):
		if i >= cond_ids.size():
			break
		var cond_id = cond_ids[i]
		var instance = conditions[cond_id]
		var cond_res = instance.condition
		var display_name = cond_res.display_name if cond_res and cond_res.display_name else cond_id
		var tip = display_name
		if instance.stacks > 1:
			tip += " x%d" % instance.stacks
		if instance.expires_at > 0 and cond_res.duration > 0:
			var time_left = max(0.0, instance.expires_at - game_time)
			tip += " (%.0fs)" % time_left
		children[i].tooltip_text = tip
