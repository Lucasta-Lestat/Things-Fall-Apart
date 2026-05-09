# CombatTestWindow.gd
# Debug panel for assembling two parties (player + rival) and dropping them
# into the Colosseum to fight. Toggle with F10.
extends CanvasLayer

const SLOT_SIZE := Vector2(36, 36)
const ICON_SIZE := Vector2(28, 28)

# Each entry: { "template_id": String, "abilities": Array[String], "items": Array[String] }
var _player_party: Array = []
var _rival_party: Array = []
var _override_rival_faction: bool = true
var _is_open: bool = false
var _was_paused: bool = false

var _outer_panel: PanelContainer
var _template_filter: LineEdit
var _template_list_vbox: VBoxContainer
var _player_card_container: VBoxContainer
var _rival_card_container: VBoxContainer
var _ability_list_vbox: VBoxContainer
var _item_list_vbox: VBoxContainer
var _override_checkbox: CheckBox
var _status_label: Label

func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_outer_panel.visible = false
	# Master debug toggle (F12) shows/hides the window without forcing the
	# pause-and-edit flow that F10 invokes — pausing on every F12 would be
	# too disruptive. F10 still pauses + opens for the focused setup mode.
	if typeof(DebugManager) != TYPE_NIL:
		_set_panel_visible_no_pause(DebugManager.enabled)
		if not DebugManager.enabled_changed.is_connected(_on_debug_enabled_changed):
			DebugManager.enabled_changed.connect(_on_debug_enabled_changed)

func _on_debug_enabled_changed(value: bool) -> void:
	_set_panel_visible_no_pause(value)

func _set_panel_visible_no_pause(v: bool) -> void:
	# Show/hide the window without touching get_tree().paused or the
	# population of template/ability/item lists. Lazy-populate on demand.
	if _outer_panel == null:
		return
	_is_open = v
	_outer_panel.visible = v
	if v:
		_populate_template_list()
		_populate_ability_list()
		_populate_item_list()
		_refresh_rosters()
		if _status_label:
			_status_label.text = ""

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var kc = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		if kc == KEY_F10:
			_toggle()
			get_viewport().set_input_as_handled()

func _toggle() -> void:
	_is_open = not _is_open
	_outer_panel.visible = _is_open
	if _is_open:
		_was_paused = get_tree().paused
		get_tree().paused = true
		_populate_template_list()
		_populate_ability_list()
		_populate_item_list()
		_refresh_rosters()
		_status_label.text = ""
	else:
		get_tree().paused = _was_paused

# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	_outer_panel = PanelContainer.new()
	_outer_panel.anchor_left = 0.05
	_outer_panel.anchor_top = 0.05
	_outer_panel.anchor_right = 0.95
	_outer_panel.anchor_bottom = 0.95
	_outer_panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.10, 0.12, 0.96)
	style.border_color = Color(0.4, 0.4, 0.5, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	_outer_panel.add_theme_stylebox_override("panel", style)

	var root_vbox = VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 6)
	_outer_panel.add_child(root_vbox)

	# Header
	var header = HBoxContainer.new()
	var title = Label.new()
	title.text = "Combat Test (F10)"
	title.add_theme_color_override("font_color", Color(1.0, 0.9, 0.4))
	title.add_theme_font_size_override("font_size", 16)
	header.add_child(title)
	var hspacer = Control.new()
	hspacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(hspacer)
	var close_btn = Button.new()
	close_btn.text = "Close (F10)"
	close_btn.pressed.connect(_toggle)
	header.add_child(close_btn)
	root_vbox.add_child(header)
	root_vbox.add_child(HSeparator.new())

	# Body — 4 columns
	var body_hbox = HBoxContainer.new()
	body_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_hbox.add_theme_constant_override("separation", 6)
	root_vbox.add_child(body_hbox)

	body_hbox.add_child(_build_templates_column())
	body_hbox.add_child(_build_party_column("Player Party", true))
	body_hbox.add_child(_build_party_column("Rival Party", false))
	body_hbox.add_child(_build_library_column())

	root_vbox.add_child(HSeparator.new())

	# Footer
	var footer = HBoxContainer.new()
	footer.add_theme_constant_override("separation", 12)
	_override_checkbox = CheckBox.new()
	_override_checkbox.text = "Override rival faction → rival_party"
	_override_checkbox.button_pressed = true
	_override_checkbox.toggled.connect(func(v): _override_rival_faction = v)
	footer.add_child(_override_checkbox)

	var fspacer = Control.new()
	fspacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(fspacer)

	_status_label = Label.new()
	_status_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	footer.add_child(_status_label)

	var reset_btn = Button.new()
	reset_btn.text = "Reset"
	reset_btn.pressed.connect(_on_reset)
	footer.add_child(reset_btn)

	var start_btn = Button.new()
	start_btn.text = "Start Combat in Colosseum"
	start_btn.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
	start_btn.pressed.connect(_on_start)
	footer.add_child(start_btn)

	root_vbox.add_child(footer)

	add_child(_outer_panel)

func _make_column_panel(title_text: String) -> Dictionary:
	var col = PanelContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.custom_minimum_size = Vector2(220, 0)
	var col_style = StyleBoxFlat.new()
	col_style.bg_color = Color(0.07, 0.07, 0.08, 1.0)
	col_style.border_color = Color(0.3, 0.3, 0.35, 1.0)
	col_style.set_border_width_all(1)
	col_style.set_corner_radius_all(4)
	col_style.set_content_margin_all(6)
	col.add_theme_stylebox_override("panel", col_style)

	var col_vbox = VBoxContainer.new()
	col.add_child(col_vbox)

	var heading = Label.new()
	heading.text = title_text
	heading.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	heading.add_theme_font_size_override("font_size", 14)
	col_vbox.add_child(heading)

	return {"col": col, "vbox": col_vbox}

func _build_templates_column() -> Control:
	var pack = _make_column_panel("Templates")
	var col_vbox: VBoxContainer = pack["vbox"]

	_template_filter = LineEdit.new()
	_template_filter.placeholder_text = "Filter…"
	_template_filter.text_changed.connect(func(_t): _populate_template_list())
	col_vbox.add_child(_template_filter)

	var scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col_vbox.add_child(scroll)

	_template_list_vbox = VBoxContainer.new()
	_template_list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_template_list_vbox)

	return pack["col"]

func _build_party_column(title_text: String, is_player: bool) -> Control:
	var pack = _make_column_panel(title_text)
	var col_vbox: VBoxContainer = pack["vbox"]

	var hint = Label.new()
	hint.text = "Drop a template here"
	hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	hint.add_theme_font_size_override("font_size", 11)
	col_vbox.add_child(hint)

	var scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col_vbox.add_child(scroll)

	var card_vbox = VBoxContainer.new()
	card_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card_vbox.add_theme_constant_override("separation", 4)
	scroll.add_child(card_vbox)

	# Mark the column itself as a drop target for templates.
	var drop = _DropZone.new()
	drop.accepted_kinds = ["template"]
	drop.on_drop = func(data: Dictionary):
		var party = _player_party if is_player else _rival_party
		party.append({
			"template_id": data["template_id"],
			"abilities": [],
			"items": [],
		})
		_refresh_rosters()
	drop.add_theme_stylebox_override("panel", _make_dashed_box())
	drop.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	drop.custom_minimum_size = Vector2(0, 36)
	var add_lbl = Label.new()
	add_lbl.text = "+ add fighter"
	add_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_lbl.add_theme_color_override("font_color", Color(0.6, 0.7, 0.85))
	add_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drop.add_child(add_lbl)
	col_vbox.add_child(drop)

	if is_player:
		_player_card_container = card_vbox
	else:
		_rival_card_container = card_vbox

	return pack["col"]

func _build_library_column() -> Control:
	var pack = _make_column_panel("Library")
	var col_vbox: VBoxContainer = pack["vbox"]

	var tabs = TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col_vbox.add_child(tabs)

	# Abilities tab
	var ab_scroll = ScrollContainer.new()
	ab_scroll.name = "Abilities"
	tabs.add_child(ab_scroll)
	_ability_list_vbox = VBoxContainer.new()
	_ability_list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ab_scroll.add_child(_ability_list_vbox)

	# Items tab
	var it_scroll = ScrollContainer.new()
	it_scroll.name = "Items"
	tabs.add_child(it_scroll)
	_item_list_vbox = VBoxContainer.new()
	_item_list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	it_scroll.add_child(_item_list_vbox)

	return pack["col"]

func _make_dashed_box() -> StyleBoxFlat:
	var s = StyleBoxFlat.new()
	s.bg_color = Color(0.15, 0.18, 0.22, 1.0)
	s.border_color = Color(0.4, 0.5, 0.6, 1.0)
	s.set_border_width_all(1)
	s.set_corner_radius_all(4)
	s.set_content_margin_all(4)
	return s

# ---------------------------------------------------------------------------
# List population
# ---------------------------------------------------------------------------

func _populate_template_list() -> void:
	for child in _template_list_vbox.get_children():
		child.queue_free()

	var filter_text: String = _template_filter.text.strip_edges().to_lower() if _template_filter else ""
	var ids: Array = TopDownCharacterDatabase.get_all_template_ids()
	ids.sort()

	for id in ids:
		var template: Dictionary = TopDownCharacterDatabase.get_template(id)
		var display: String = template.get("name", id)
		if not filter_text.is_empty() and filter_text not in id.to_lower() and filter_text not in display.to_lower():
			continue
		var icon_path: String = template.get("icon", "")
		var row = _make_drag_row(icon_path, "%s  (%s)" % [display, id], {
			"kind": "template", "template_id": id,
		})
		_template_list_vbox.add_child(row)

func _populate_ability_list() -> void:
	for child in _ability_list_vbox.get_children():
		child.queue_free()
	var ids: Array = AbilityDatabase.get_all_ability_ids()
	ids.sort()
	for id in ids:
		var data: Dictionary = AbilityDatabase.get_ability_data(id)
		var display: String = data.get("display_name", id)
		var icon_path: String = str(data.get("icon", ""))
		var row = _make_drag_row(icon_path, display, {
			"kind": "ability", "ability_id": id,
		})
		_ability_list_vbox.add_child(row)

func _populate_item_list() -> void:
	for child in _item_list_vbox.get_children():
		child.queue_free()
	var ids: Array = []
	ids.append_array(ItemDatabase.weapons.keys())
	ids.append_array(ItemDatabase.equipment.keys())
	ids.append_array(ItemDatabase.items.keys())
	ids.sort()
	for id in ids:
		var data: Dictionary = ItemDatabase.get_item_data(id)
		var display: String = data.get("display_name", id)
		var icon_path: String = str(data.get("sprite_path", ""))
		var row = _make_drag_row(icon_path, display, {
			"kind": "item", "item_id": id,
		})
		_item_list_vbox.add_child(row)

func _make_drag_row(icon_path: String, label_text: String, drag_data: Dictionary) -> Control:
	var row = _DragRow.new()
	row.drag_data = drag_data
	row.preview_text = label_text
	row.preview_icon_path = icon_path
	row.custom_minimum_size = Vector2(0, 32)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var hbox = HBoxContainer.new()
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(hbox)

	var icon = TextureRect.new()
	icon.custom_minimum_size = ICON_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not icon_path.is_empty() and ResourceLoader.exists(icon_path):
		icon.texture = load(icon_path)
	hbox.add_child(icon)

	var lbl = Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(lbl)

	return row

# ---------------------------------------------------------------------------
# Roster cards
# ---------------------------------------------------------------------------

func _refresh_rosters() -> void:
	_render_party(_player_party, _player_card_container, true)
	_render_party(_rival_party, _rival_card_container, false)

func _render_party(party: Array, container: VBoxContainer, is_player: bool) -> void:
	if container == null:
		return
	for child in container.get_children():
		child.queue_free()
	for i in range(party.size()):
		container.add_child(_make_fighter_card(party, i, is_player))

func _make_fighter_card(party: Array, idx: int, is_player: bool) -> Control:
	var entry: Dictionary = party[idx]
	var template_id: String = entry.get("template_id", "")
	var template: Dictionary = TopDownCharacterDatabase.get_template(template_id)

	var card = PanelContainer.new()
	var card_style = StyleBoxFlat.new()
	card_style.bg_color = Color(0.13, 0.14, 0.17, 1.0)
	card_style.border_color = Color(0.35, 0.45, 0.55, 1.0) if is_player else Color(0.55, 0.30, 0.30, 1.0)
	card_style.set_border_width_all(1)
	card_style.set_corner_radius_all(4)
	card_style.set_content_margin_all(6)
	card.add_theme_stylebox_override("panel", card_style)

	var card_vbox = VBoxContainer.new()
	card.add_child(card_vbox)

	# Header: icon + name + remove button
	var header = HBoxContainer.new()
	card_vbox.add_child(header)
	var icon_path: String = template.get("icon", "")
	var icon = TextureRect.new()
	icon.custom_minimum_size = Vector2(32, 32)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	if not icon_path.is_empty() and ResourceLoader.exists(icon_path):
		icon.texture = load(icon_path)
	header.add_child(icon)

	var name_lbl = Label.new()
	name_lbl.text = template.get("name", template_id)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(name_lbl)

	var remove_btn = Button.new()
	remove_btn.text = "x"
	remove_btn.custom_minimum_size = Vector2(22, 22)
	remove_btn.pressed.connect(func():
		party.remove_at(idx)
		_refresh_rosters()
	)
	header.add_child(remove_btn)

	# Abilities subsection
	card_vbox.add_child(_make_loadout_row(party, idx, "abilities"))

	# Items subsection
	card_vbox.add_child(_make_loadout_row(party, idx, "items"))

	return card

func _make_loadout_row(party: Array, idx: int, kind: String) -> Control:
	# kind = "abilities" or "items"
	var entry: Dictionary = party[idx]
	var ids: Array = entry.get(kind, [])

	var row = HBoxContainer.new()
	var lbl = Label.new()
	lbl.text = "Abil:" if kind == "abilities" else "Item:"
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	lbl.custom_minimum_size = Vector2(34, 0)
	row.add_child(lbl)

	var slots_grid = GridContainer.new()
	slots_grid.columns = 5
	slots_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slots_grid)

	# Existing slots
	for slot_idx in range(ids.size()):
		var id: String = ids[slot_idx]
		slots_grid.add_child(_make_loadout_slot(party, idx, kind, slot_idx, id))

	# Trailing drop zone (one per loadout row)
	var drop = _DropZone.new()
	drop.custom_minimum_size = SLOT_SIZE
	var accepted = ["ability"] if kind == "abilities" else ["item"]
	drop.accepted_kinds = accepted
	drop.on_drop = func(data: Dictionary):
		var id_field = "ability_id" if kind == "abilities" else "item_id"
		entry[kind].append(data[id_field])
		_refresh_rosters()
	var dot = Label.new()
	dot.text = "+"
	dot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dot.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	dot.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drop.add_child(dot)
	drop.add_theme_stylebox_override("panel", _make_dashed_box())
	slots_grid.add_child(drop)

	return row

func _make_loadout_slot(party: Array, fighter_idx: int, kind: String, slot_idx: int, id: String) -> Control:
	var slot = PanelContainer.new()
	slot.custom_minimum_size = SLOT_SIZE
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.18, 0.20, 0.24, 1.0)
	style.border_color = Color(0.45, 0.50, 0.60, 1.0)
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	slot.add_theme_stylebox_override("panel", style)

	var icon_path: String = ""
	var tooltip: String = id
	if kind == "abilities":
		var data: Dictionary = AbilityDatabase.get_ability_data(id)
		icon_path = str(data.get("icon", ""))
		tooltip = data.get("display_name", id)
	else:
		var data: Dictionary = ItemDatabase.get_item_data(id)
		icon_path = str(data.get("sprite_path", ""))
		tooltip = data.get("display_name", id)
	slot.tooltip_text = tooltip

	if not icon_path.is_empty() and ResourceLoader.exists(icon_path):
		var tex = TextureRect.new()
		tex.texture = load(icon_path)
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(tex)
	else:
		var lbl = Label.new()
		lbl.text = id.substr(0, 3)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.add_theme_font_size_override("font_size", 10)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(lbl)

	# Right-click to remove. Use a closure to capture the indices.
	slot.gui_input.connect(func(ev):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT:
			party[fighter_idx][kind].remove_at(slot_idx)
			_refresh_rosters()
	)

	return slot

# ---------------------------------------------------------------------------
# Action buttons
# ---------------------------------------------------------------------------

func _on_reset() -> void:
	_player_party.clear()
	_rival_party.clear()
	_refresh_rosters()
	_status_label.text = "Cleared."

func _on_start() -> void:
	if _player_party.is_empty() and _rival_party.is_empty():
		_status_label.text = "Add at least one fighter first."
		return
	var game = get_parent()
	if game == null or not game.has_method("start_combat_test"):
		_status_label.text = "ERROR: start_combat_test not available on parent."
		return
	# Hide the panel and unpause before spawning.
	_is_open = false
	_outer_panel.visible = false
	get_tree().paused = false
	game.start_combat_test(_player_party, _rival_party, _override_rival_faction)

# ---------------------------------------------------------------------------
# Inner classes
# ---------------------------------------------------------------------------

class _DragRow extends PanelContainer:
	var drag_data: Dictionary = {}
	var preview_text: String = ""
	var preview_icon_path: String = ""

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		var hover_style = StyleBoxFlat.new()
		hover_style.bg_color = Color(0.18, 0.20, 0.25, 1.0)
		hover_style.set_corner_radius_all(3)
		hover_style.set_content_margin_all(2)
		add_theme_stylebox_override("panel", hover_style)

	func _get_drag_data(_at_position: Vector2):
		set_drag_preview(_make_preview())
		return drag_data

	func _make_preview() -> Control:
		var c = PanelContainer.new()
		var s = StyleBoxFlat.new()
		s.bg_color = Color(0.12, 0.12, 0.14, 0.95)
		s.set_border_width_all(1)
		s.border_color = Color(1.0, 0.9, 0.4, 1.0)
		s.set_corner_radius_all(3)
		s.set_content_margin_all(4)
		c.add_theme_stylebox_override("panel", s)
		var hb = HBoxContainer.new()
		c.add_child(hb)
		if not preview_icon_path.is_empty() and ResourceLoader.exists(preview_icon_path):
			var t = TextureRect.new()
			t.texture = load(preview_icon_path)
			t.custom_minimum_size = Vector2(28, 28)
			t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			t.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
			hb.add_child(t)
		var l = Label.new()
		l.text = preview_text
		hb.add_child(l)
		return c

class _DropZone extends PanelContainer:
	var accepted_kinds: Array = []
	var on_drop: Callable

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _can_drop_data(_at_position: Vector2, data) -> bool:
		if not (data is Dictionary):
			return false
		var k = data.get("kind", "")
		return k in accepted_kinds

	func _drop_data(_at_position: Vector2, data) -> void:
		if on_drop.is_valid():
			on_drop.call(data)
