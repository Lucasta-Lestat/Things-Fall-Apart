# choice_picker.gd
# One reusable modal for "present N options, get one back". Used at two levels:
#   * which ACTION to take on a square (promote / conditional move / capture...)
#   * which PIECE a promotion turns into
# so the two chain naturally: choose "Promote" and the same widget re-opens
# with the piece list. Built in code to avoid a fragile nested-Control .tscn.

extends Control

signal chosen(payload)
signal cancelled() # closed without a choice (Cancel button, click outside, Esc)

# Three columns rather than four: Rules.promotion_choices() returns eight
# entries, so four columns fills routinely and pushes the modal very wide.
const MAX_COLUMNS = 3
# Wide enough for the longest generated label ("Capture Doppelganger").
const BUTTON_MIN = Vector2(190, 84)
# Beyond this the grid scrolls instead of growing the modal off-screen.
const MAX_ROWS_SHOWN = 4

var _grid: GridContainer
var _scroll: ScrollContainer
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
	# Clicking anywhere outside the panel backs out, like Esc.
	dim.gui_input.connect(_on_dim_input)
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

	# Scrolled, because promotion now offers a side's whole non-royal roster --
	# the sandbox army is 30 entries, which is ten rows at three columns.
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(_scroll)

	_grid = GridContainer.new()
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_grid)

	# An on-screen way out: Esc alone is undiscoverable for a mouse player.
	var cancel_button = Button.new()
	cancel_button.text = "Cancel (Esc)"
	cancel_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	cancel_button.pressed.connect(cancel)
	vbox.add_child(cancel_button)


# entries: [{ "label": String, "icon": Texture2D or null, "payload": Variant,
#             "tooltip": String (optional) }]
func open(title: String, entries: Array) -> void:
	_title.text = title
	# Detached before freeing: queue_free is deferred, so a re-open in the same
	# frame would otherwise lay out both sets of buttons.
	for child in _grid.get_children():
		_grid.remove_child(child)
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

	# Grow with the content up to MAX_ROWS_SHOWN, then scroll rather than run
	# off the screen.
	var rows = ceili(float(entries.size()) / float(_grid.columns))
	var row_h = BUTTON_MIN.y + _grid.get_theme_constant("v_separation")
	_scroll.custom_minimum_size.y = min(rows, MAX_ROWS_SHOWN) * row_h

	visible = true


func cancel() -> void:
	if not visible:
		return
	visible = false
	cancelled.emit()


func _on_dim_input(event: InputEvent) -> void:
	# Clicks only: a wheel scroll that strays off the panel should not close it.
	if event is InputEventMouseButton and event.pressed \
			and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		cancel()


func _on_button_pressed(index: int) -> void:
	visible = false
	if index >= 0 and index < _payloads.size():
		chosen.emit(_payloads[index])
