# promotion_picker.gd
# A modal panel that lets the player choose what a pawn-family piece promotes
# into. Built entirely in code (no fragile nested-Control .tscn) and shown by
# the ChessboardDisplay when the player clicks a self-promotion square.

extends Control

signal picked(promote_to)

const BUTTON_SIZE = Vector2(76, 76)

var _row: HBoxContainer


func _ready():
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP # swallow clicks aimed at the board
	visible = false

	# Dimmed backdrop.
	var dim = ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	# Centered panel.
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

	var label = Label.new()
	label.text = "Promote to:"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 22)
	vbox.add_child(label)

	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 8)
	vbox.add_child(_row)


# Populate the picker for the given side and show it.
func open(color: String):
	for child in _row.get_children():
		child.queue_free()
	for piece_type in Rules.promotion_choices():
		var button = TextureButton.new()
		var tex = load("res://assets/icons/" + piece_type + "_" + color + ".png")
		if tex != null:
			button.texture_normal = tex
		button.ignore_texture_size = true
		button.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		button.custom_minimum_size = BUTTON_SIZE
		button.tooltip_text = piece_type
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.pressed.connect(_on_button_pressed.bind(piece_type))
		_row.add_child(button)
	visible = true


func cancel():
	visible = false


func _on_button_pressed(piece_type: String):
	visible = false
	picked.emit(piece_type)
