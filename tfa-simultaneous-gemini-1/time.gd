extends Label

const TimePickerWindowScript = preload("res://UI/TimePickerWindow.gd")

@export var show_seconds: bool = false
@export var use_12_hour_format: bool = false
@export var show_date: bool = true

var _picker: CanvasLayer = null

func _ready() -> void:
	TimeManager.connect("time_updated", _on_time_updated)
	TimeManager.connect("date_changed", _on_date_changed)

	# Pin to top-left with a small margin
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 0.0
	offset_left = 16
	offset_top = 16
	grow_horizontal = Control.GROW_DIRECTION_END
	grow_vertical = Control.GROW_DIRECTION_END

	# Allow click events to land on the label so debug-mode users can
	# open the time picker. Labels default to MOUSE_FILTER_IGNORE.
	mouse_filter = Control.MOUSE_FILTER_STOP
	if not gui_input.is_connected(_on_gui_input):
		gui_input.connect(_on_gui_input)

	var panel := _find_party_panel()
	if panel:
		visible = panel.panel_visible
		panel.connect("panel_visibility_changed", _on_party_panel_toggled)

	update_display()

func _on_gui_input(event: InputEvent) -> void:
	# Only act when DebugManager is on; stay invisible/inert in normal play.
	if typeof(DebugManager) == TYPE_NIL or not DebugManager.enabled:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_open_time_picker()
		accept_event()

func _open_time_picker() -> void:
	if _picker and is_instance_valid(_picker):
		# Already open — bring forward by recreating.
		_picker.queue_free()
		_picker = null
	_picker = CanvasLayer.new()
	_picker.set_script(TimePickerWindowScript)
	_picker.name = "TimePickerWindow"
	get_tree().current_scene.add_child(_picker)

func _find_party_panel() -> Node:
	var parent := get_parent()
	if parent and parent.has_node("PartySidePanel"):
		return parent.get_node("PartySidePanel")
	return null

func _on_party_panel_toggled(now_visible: bool) -> void:
	visible = now_visible

func _on_time_updated(_hour, _minute, _second):
	update_display()

func _on_date_changed(_day, _month, _year):
	update_display()

func update_display():
	var time_str = TimeManager.get_time_string(use_12_hour_format)
	var date_str = TimeManager.get_date_string()
	if show_date:
		self.text = "%s\n%s" % [date_str, time_str]
	else:
		self.text = time_str
