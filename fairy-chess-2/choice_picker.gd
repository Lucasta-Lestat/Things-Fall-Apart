# choice_picker.gd
# One reusable modal for "present N options, get one back". Used at two levels:
#   * which ACTION to take on a square (promote / conditional move / capture...)
#   * which PIECE a promotion turns into
# so the two chain naturally: choose "Promote" and the same widget re-opens
# with the piece list. Built in code to avoid a fragile nested-Control .tscn.

extends Control

signal chosen(payload)

const MAX_COLUMNS = 4
const BUTTON_MIN = Vector2(150, 84)
const ICON_MAX = Vector2(56, 56)

var _grid: GridContainer
var _title: Label
var _payloads = []


func _ready():
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP # swallow clicks aimed at the board
	visible = false
	_build_ui()


func _build_ui():
	var dim = ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
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

	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(_title)

	_grid = GridContainer.new()
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	vbox.add_child(_grid)


# entries: [{ "label": String, "icon": Texture2D or null, "payload": Variant,
#             "tooltip": String (optional) }]
func open(title: String, entries: Array) -> void:
	_title.text = title
	for child in _grid.get_children():
		child.queue_free()
	_payloads = []
	_grid.columns = max(1, min(entries.size(), MAX_COLUMNS))

	for i in range(entries.size()):
		var entry = entries[i]
		var button = Button.new()
		button.text = str(entry.get("label", ""))
		button.tooltip_text = str(entry.get("tooltip", ""))
		button.custom_minimum_size = BUTTON_MIN
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var icon = entry.get("icon", null)
		if icon != null:
			button.icon = icon
			button.expand_icon = true
			button.add_theme_constant_override("icon_max_width", int(ICON_MAX.x))
		_payloads.append(entry.get("payload"))
		button.pressed.connect(_on_button_pressed.bind(i))
		_grid.add_child(button)

	visible = true


func cancel() -> void:
	visible = false


func _on_button_pressed(index: int) -> void:
	visible = false
	if index >= 0 and index < _payloads.size():
		chosen.emit(_payloads[index])
