# choice_picker.gd
# One reusable modal for "present N options, get one back". Used at two levels:
#   * which ACTION to take on a square (promote / conditional move / capture...)
#   * which PIECE a promotion turns into
# so the two chain naturally: choose "Promote" and the same widget re-opens
# with the piece list. Built in code to avoid a fragile nested-Control .tscn.

extends Control

signal chosen(payload)

# Three columns rather than four: Rules.promotion_choices() returns eight
# entries, so four columns fills routinely and pushes the modal very wide.
const MAX_COLUMNS = 3
# Wide enough for the longest generated label ("Capture Doppelganger").
const BUTTON_MIN = Vector2(190, 84)

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
	dim.color = get_theme_color("scrim", "Modal")
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel = PanelContainer.new()
	panel.theme_type_variation = "ModalPanel"
	center.add_child(panel)

	var vbox = VBoxContainer.new()
	panel.add_child(vbox)

	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.theme_type_variation = "ModalTitle"
	vbox.add_child(_title)

	_grid = GridContainer.new()
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
		button.theme_type_variation = "PickerButton"
		button.text = str(entry.get("label", ""))
		button.tooltip_text = str(entry.get("tooltip", ""))
		button.custom_minimum_size = BUTTON_MIN
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var icon = entry.get("icon", null)
		if icon != null:
			button.icon = icon
			button.expand_icon = true
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
