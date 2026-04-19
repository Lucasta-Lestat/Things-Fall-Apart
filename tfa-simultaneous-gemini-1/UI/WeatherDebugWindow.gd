# WeatherDebugWindow.gd
# Debug panel for viewing and overriding weather state.
# Toggle with F9. Shows random rolls, current weather, and allows overrides.
extends CanvasLayer

var _panel: PanelContainer
var _vbox: VBoxContainer
var _visible: bool = false
var _current_group: String = ""

# UI references
var _title_label: Label
var _group_label: Label
var _precip_label: Label
var _wind_speed_label: Label
var _wind_dir_label: Label
var _rolls_label: Label
var _precip_option: OptionButton
var _wind_speed_slider: HSlider
var _wind_angle_slider: HSlider
var _reroll_button: Button

func _ready() -> void:
	layer = 10
	_build_ui()
	_panel.visible = false
	WeatherManager.weather_changed.connect(_on_weather_changed)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and (event.keycode == KEY_F9 or event.physical_keycode == KEY_F9):
		_visible = !_visible
		_panel.visible = _visible
		if _visible:
			_refresh()

func set_weather_group(group: String) -> void:
	_current_group = group
	if _visible:
		_refresh()

func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(320, 0)
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 0.0
	_panel.offset_left = -330
	_panel.offset_right = -10
	_panel.offset_top = 10
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12, 0.9)
	style.border_color = Color(0.4, 0.4, 0.5, 0.8)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(10)
	_panel.add_theme_stylebox_override("panel", style)

	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 6)
	_panel.add_child(_vbox)

	# Title
	_title_label = Label.new()
	_title_label.text = "Weather Debug (F9)"
	_title_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.4))
	_vbox.add_child(_title_label)

	# Separator
	_vbox.add_child(HSeparator.new())

	# Current state labels
	_group_label = _add_label("Group: ---")
	_precip_label = _add_label("Precipitation: ---")
	_wind_speed_label = _add_label("Wind Speed: ---")
	_wind_dir_label = _add_label("Wind Direction: ---")

	_vbox.add_child(HSeparator.new())

	# Rolls section
	var rolls_title = Label.new()
	rolls_title.text = "Random Rolls:"
	rolls_title.add_theme_color_override("font_color", Color(0.7, 0.8, 1.0))
	_vbox.add_child(rolls_title)

	_rolls_label = Label.new()
	_rolls_label.text = "---"
	_rolls_label.add_theme_font_size_override("font_size", 12)
	_rolls_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_vbox.add_child(_rolls_label)

	_vbox.add_child(HSeparator.new())

	# Override controls
	var override_title = Label.new()
	override_title.text = "Override Controls:"
	override_title.add_theme_color_override("font_color", Color(1.0, 0.7, 0.4))
	_vbox.add_child(override_title)

	# Precipitation override
	var precip_hbox = HBoxContainer.new()
	var precip_lbl = Label.new()
	precip_lbl.text = "Precip: "
	precip_lbl.custom_minimum_size.x = 80
	precip_hbox.add_child(precip_lbl)
	_precip_option = OptionButton.new()
	_precip_option.custom_minimum_size.x = 150
	for precip_type in ["clear", "overcast", "rain", "heavy_rain", "snow", "heavy_snow"]:
		_precip_option.add_item(precip_type)
	_precip_option.item_selected.connect(_on_precip_selected)
	precip_hbox.add_child(_precip_option)
	_vbox.add_child(precip_hbox)

	# Wind speed slider
	var ws_hbox = HBoxContainer.new()
	var ws_lbl = Label.new()
	ws_lbl.text = "Wind Spd: "
	ws_lbl.custom_minimum_size.x = 80
	ws_hbox.add_child(ws_lbl)
	_wind_speed_slider = HSlider.new()
	_wind_speed_slider.min_value = 0
	_wind_speed_slider.max_value = 100
	_wind_speed_slider.step = 1
	_wind_speed_slider.custom_minimum_size.x = 150
	_wind_speed_slider.value_changed.connect(_on_wind_speed_changed)
	ws_hbox.add_child(_wind_speed_slider)
	_vbox.add_child(ws_hbox)

	# Wind angle slider
	var wa_hbox = HBoxContainer.new()
	var wa_lbl = Label.new()
	wa_lbl.text = "Wind Dir: "
	wa_lbl.custom_minimum_size.x = 80
	wa_hbox.add_child(wa_lbl)
	_wind_angle_slider = HSlider.new()
	_wind_angle_slider.min_value = 0
	_wind_angle_slider.max_value = 360
	_wind_angle_slider.step = 45
	_wind_angle_slider.custom_minimum_size.x = 150
	_wind_angle_slider.value_changed.connect(_on_wind_angle_changed)
	wa_hbox.add_child(_wind_angle_slider)
	_vbox.add_child(wa_hbox)

	# Reroll button
	_reroll_button = Button.new()
	_reroll_button.text = "Re-Roll Weather"
	_reroll_button.pressed.connect(_on_reroll_pressed)
	_vbox.add_child(_reroll_button)

	add_child(_panel)

func _add_label(text: String) -> Label:
	var label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	_vbox.add_child(label)
	return label

func _refresh() -> void:
	if _current_group.is_empty():
		_group_label.text = "Group: (none)"
		return

	var weather = WeatherManager.get_weather(_current_group)
	if weather.is_empty():
		_group_label.text = "Group: %s (no data)" % _current_group
		return

	var precip = weather.get("precipitation", "clear")
	var precip_data = WeatherManager.get_precipitation_data(precip)
	var wind_speed = weather.get("wind_speed", 0.0)
	var wind_angle = weather.get("wind_angle", 0.0)

	_group_label.text = "Group: %s" % _current_group
	_precip_label.text = "Precipitation: %s" % precip_data.get("display_name", precip)
	_wind_speed_label.text = "Wind Speed: %.0f" % wind_speed
	_wind_dir_label.text = "Wind Direction: %.0f° (%s)" % [wind_angle, _angle_to_compass(wind_angle)]

	# Show rolls
	var rolls = weather.get("rolls", {})
	_rolls_label.text = "Precip roll: %.2f / %.0f\nWind speed roll: %.2f\nWind dir index: %d (%.0f°)" % [
		rolls.get("precipitation_roll", 0.0),
		rolls.get("precipitation_total_weight", 0.0),
		rolls.get("wind_speed_roll", 0.0),
		rolls.get("wind_direction_index", 0),
		rolls.get("wind_direction_angle", 0.0)
	]

	# Sync override controls
	var precip_types = ["clear", "overcast", "rain", "heavy_rain", "snow", "heavy_snow"]
	var idx = precip_types.find(precip)
	if idx >= 0:
		_precip_option.selected = idx
	_wind_speed_slider.set_value_no_signal(wind_speed)
	_wind_angle_slider.set_value_no_signal(wind_angle)

func _angle_to_compass(angle: float) -> String:
	var directions = ["E", "NE", "N", "NW", "W", "SW", "S", "SE"]
	var index = int(round(angle / 45.0)) % 8
	return directions[index]

func _on_weather_changed(_group: String, _weather: Dictionary) -> void:
	if _visible and _group == _current_group:
		_refresh()

func _on_precip_selected(index: int) -> void:
	if _current_group.is_empty():
		return
	var precip_types = ["clear", "overcast", "rain", "heavy_rain", "snow", "heavy_snow"]
	WeatherManager.set_precipitation(_current_group, precip_types[index])

func _on_wind_speed_changed(value: float) -> void:
	if _current_group.is_empty():
		return
	WeatherManager.set_wind_speed(_current_group, value)

func _on_wind_angle_changed(value: float) -> void:
	if _current_group.is_empty():
		return
	WeatherManager.set_wind_angle(_current_group, value)

func _on_reroll_pressed() -> void:
	if _current_group.is_empty():
		return
	WeatherManager.force_reroll(_current_group)
