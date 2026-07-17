# profile_picker.gd
# Pre-game modal: choose which characters field armies as White (the player)
# and Black (the opponent), pulled from the main game's character roster.
# Built in code to avoid a fragile nested-Control .tscn.

extends Control

signal confirmed(white_id, black_id, ai_enabled)

const GRID_COLUMNS = 8
const THUMB = Vector2(64, 64)
const SLOT_PORTRAIT = Vector2(88, 88)

var _roster = []                 # [{id, name, title, faction, portrait}]
var _by_id = {}                  # id -> entry
var _white_id = ""
var _black_id = ""
var _active = "white"            # which slot the next portrait click fills

var _white_button: Button
var _black_button: Button
var _white_portrait: TextureRect
var _black_portrait: TextureRect
var _ai_checkbox: CheckBox
var _start_button: Button
var _placeholder: Texture2D


func _ready():
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_placeholder = load("res://icon.svg")
	_build_ui()


func _build_ui():
	var dim = ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel = PanelContainer.new()
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.16, 0.13, 0.11, 0.98)
	style.border_color = Color(0.85, 0.72, 0.4)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	var title = Label.new()
	title.text = "Choose Your Champions"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	vbox.add_child(title)

	# --- Two slots (White / Black) ---
	var slots = HBoxContainer.new()
	slots.add_theme_constant_override("separation", 24)
	slots.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(slots)

	var white_col = VBoxContainer.new()
	white_col.alignment = BoxContainer.ALIGNMENT_CENTER
	_white_portrait = TextureRect.new()
	_white_portrait.custom_minimum_size = SLOT_PORTRAIT
	_white_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_white_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	white_col.add_child(_white_portrait)
	_white_button = Button.new()
	_white_button.pressed.connect(func(): _set_active("white"))
	white_col.add_child(_white_button)
	slots.add_child(white_col)

	var vs = Label.new()
	vs.text = "vs"
	vs.add_theme_font_size_override("font_size", 20)
	slots.add_child(vs)

	var black_col = VBoxContainer.new()
	black_col.alignment = BoxContainer.ALIGNMENT_CENTER
	_black_portrait = TextureRect.new()
	_black_portrait.custom_minimum_size = SLOT_PORTRAIT
	_black_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_black_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	black_col.add_child(_black_portrait)
	_black_button = Button.new()
	_black_button.pressed.connect(func(): _set_active("black"))
	black_col.add_child(_black_button)
	slots.add_child(black_col)

	var hint = Label.new()
	hint.text = "Click a portrait to fill the highlighted side."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hint)

	# --- Scrollable roster grid ---
	var scroll = ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(GRID_COLUMNS * (THUMB.x + 8) + 24, 280)
	vbox.add_child(scroll)
	var grid = GridContainer.new()
	grid.name = "Grid"
	grid.columns = GRID_COLUMNS
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	scroll.add_child(grid)

	# --- Bottom row: AI toggle + Start ---
	var bottom = HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 20)
	bottom.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(bottom)
	_ai_checkbox = CheckBox.new()
	_ai_checkbox.text = "Black played by AI"
	_ai_checkbox.button_pressed = true
	bottom.add_child(_ai_checkbox)
	_start_button = Button.new()
	_start_button.text = "Start Match"
	_start_button.pressed.connect(_on_start_pressed)
	bottom.add_child(_start_button)

	_grid = grid


var _grid: GridContainer


func open(roster: Array, white_id: String, black_id: String, ai_enabled: bool):
	_roster = roster
	_by_id = {}
	for entry in roster:
		_by_id[entry.id] = entry
	_white_id = white_id if _by_id.has(white_id) else (roster[0].id if roster.size() > 0 else "")
	_black_id = black_id if _by_id.has(black_id) else (roster[-1].id if roster.size() > 0 else "")
	_active = "white"
	_ai_checkbox.button_pressed = ai_enabled

	for child in _grid.get_children():
		child.queue_free()
	for entry in roster:
		var button = TextureButton.new()
		button.texture_normal = _portrait_for(entry)
		button.ignore_texture_size = true
		button.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		button.custom_minimum_size = THUMB
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var label = entry.name
		if entry.title != "":
			label += " — " + entry.title
		button.tooltip_text = label
		button.pressed.connect(_on_portrait_pressed.bind(entry.id))
		_grid.add_child(button)

	_refresh_slots()
	visible = true


func cancel():
	visible = false


func _portrait_for(entry) -> Texture2D:
	if entry.portrait != "" and ResourceLoader.exists(entry.portrait):
		return load(entry.portrait)
	return _placeholder


func _set_active(side: String):
	_active = side
	_refresh_slots()


func _on_portrait_pressed(id: String):
	if _active == "white":
		_white_id = id
		_active = "black"
	else:
		_black_id = id
		_active = "white"
	_refresh_slots()


func _refresh_slots():
	var w = _by_id.get(_white_id, {})
	var b = _by_id.get(_black_id, {})
	_white_button.text = "White (You): " + str(w.get("name", "—"))
	_black_button.text = "Black: " + str(b.get("name", "—"))
	_white_portrait.texture = _portrait_for(w) if not w.is_empty() else _placeholder
	_black_portrait.texture = _portrait_for(b) if not b.is_empty() else _placeholder
	# Highlight the active slot.
	_white_button.modulate = Color(1, 0.9, 0.4) if _active == "white" else Color(1, 1, 1)
	_black_button.modulate = Color(1, 0.9, 0.4) if _active == "black" else Color(1, 1, 1)
	_start_button.disabled = _white_id == "" or _black_id == ""


func _on_start_pressed():
	visible = false
	confirmed.emit(_white_id, _black_id, _ai_checkbox.button_pressed)
