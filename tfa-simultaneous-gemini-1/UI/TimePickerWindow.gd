# TimePickerWindow.gd
# Debug-mode picker for jumping the in-game clock to a specific date and time.
# Opened by clicking the TimeLabel while DebugManager is enabled (F12).
extends CanvasLayer

var _panel: PanelContainer
var _hour_spin: SpinBox
var _minute_spin: SpinBox
var _day_spin: SpinBox
var _month_spin: SpinBox
var _year_spin: SpinBox
var _yearturn_check: CheckBox
var _status_label: Label

func _ready() -> void:
	layer = 12
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_load_current_values()

func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(280, 0)
	_panel.anchor_left = 0.0
	_panel.anchor_top = 0.0
	_panel.offset_left = 16
	_panel.offset_top = 80
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12, 0.95)
	style.border_color = Color(0.4, 0.4, 0.5, 0.9)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(10)
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	_panel.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "Set Time (debug)"
	title.add_theme_color_override("font_color", Color(1.0, 0.9, 0.4))
	vbox.add_child(title)

	vbox.add_child(HSeparator.new())

	# Time row
	var time_row := HBoxContainer.new()
	vbox.add_child(time_row)
	time_row.add_child(_make_label("Hour"))
	_hour_spin = _make_spin(0, 23)
	time_row.add_child(_hour_spin)
	time_row.add_child(_make_label(" Min"))
	_minute_spin = _make_spin(0, 59)
	time_row.add_child(_minute_spin)

	# Date row
	var date_row := HBoxContainer.new()
	vbox.add_child(date_row)
	date_row.add_child(_make_label("Day"))
	_day_spin = _make_spin(1, 36)
	date_row.add_child(_day_spin)
	date_row.add_child(_make_label(" Mo"))
	_month_spin = _make_spin(1, 10)
	date_row.add_child(_month_spin)

	var year_row := HBoxContainer.new()
	vbox.add_child(year_row)
	year_row.add_child(_make_label("Year"))
	_year_spin = _make_spin(1, 9999)
	year_row.add_child(_year_spin)

	_yearturn_check = CheckBox.new()
	_yearturn_check.text = "Yearturn (12-day intercalary period)"
	vbox.add_child(_yearturn_check)

	vbox.add_child(HSeparator.new())

	# Buttons
	var button_row := HBoxContainer.new()
	vbox.add_child(button_row)

	var apply_btn := Button.new()
	apply_btn.text = "Apply"
	apply_btn.pressed.connect(_on_apply_pressed)
	button_row.add_child(apply_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "Close"
	cancel_btn.pressed.connect(_on_close_pressed)
	button_row.add_child(cancel_btn)

	_status_label = Label.new()
	_status_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(_status_label)

func _make_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	return lbl

func _make_spin(min_v: int, max_v: int) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = 1
	s.custom_minimum_size = Vector2(60, 0)
	return s

func _load_current_values() -> void:
	_hour_spin.value = TimeManager.current_hour
	_minute_spin.value = TimeManager.current_minute
	_day_spin.value = TimeManager.current_day
	# Yearturn is encoded as month=0; show month=1 in the spin and check the box.
	if TimeManager.is_yearturn:
		_month_spin.value = 1
		_yearturn_check.button_pressed = true
	else:
		_month_spin.value = max(1, TimeManager.current_month)
		_yearturn_check.button_pressed = false
	_year_spin.value = TimeManager.current_year

func _on_apply_pressed() -> void:
	var hour := int(_hour_spin.value)
	var minute := int(_minute_spin.value)
	var day := int(_day_spin.value)
	var month := 0 if _yearturn_check.button_pressed else int(_month_spin.value)
	var year := int(_year_spin.value)

	TimeManager.set_date(day, month, year)
	TimeManager.set_time(hour, minute, 0)
	# Reset the floating-point clock so the next _process tick doesn't
	# immediately roll us forward by the leftover seconds.
	TimeManager.game_time = float(
		hour * TimeManager.MINUTES_PER_HOUR * TimeManager.SECONDS_PER_MINUTE
		+ minute * TimeManager.SECONDS_PER_MINUTE
	)

	_status_label.text = "Applied %02d:%02d on day %d, month %d, year %d" % [hour, minute, day, month, year]

func _on_close_pressed() -> void:
	queue_free()
