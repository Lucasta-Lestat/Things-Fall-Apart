# WeatherVFXController.gd
# Manages the fullscreen weather VFX layers (rain, snow, wind gusts).
# Add as a child of Game. Listens to WeatherManager.weather_changed.
extends Node

var _rain_scene: PackedScene = preload("res://vfx/rain.tscn")
var _snow_scene: PackedScene = preload("res://vfx/snow.tscn")
var _wind_scene: PackedScene = preload("res://vfx/wind_gust.tscn")

var _rain_node: CanvasLayer = null
var _snow_node: CanvasLayer = null
var _wind_node: CanvasLayer = null

var _current_group: String = ""

func _ready() -> void:
	WeatherManager.weather_changed.connect(_on_weather_changed)

func setup_for_map(weather_group: String) -> void:
	_current_group = weather_group
	var weather = WeatherManager.get_weather(weather_group)
	if not weather.is_empty():
		_apply_weather(weather)

func _on_weather_changed(group: String, weather_state: Dictionary) -> void:
	if group == _current_group:
		_apply_weather(weather_state)

func _apply_weather(weather: Dictionary) -> void:
	var precip = weather.get("precipitation", "clear")
	var wind_speed = weather.get("wind_speed", 0.0)
	var wind_angle = weather.get("wind_angle", 0.0)

	# --- Precipitation VFX ---
	_clear_precipitation()

	match precip:
		"rain":
			_show_rain(0.4, wind_angle)
		"heavy_rain":
			_show_rain(0.8, wind_angle)
		"snow":
			_show_snow(0.35, wind_angle)
		"heavy_snow":
			_show_snow(0.7, wind_angle)

	# --- Wind gusts (show when wind speed > 20) ---
	_clear_wind()
	if wind_speed > 20.0:
		_show_wind(wind_speed, wind_angle)

func _show_rain(density: float, wind_angle: float) -> void:
	_rain_node = _rain_scene.instantiate()
	add_child(_rain_node)
	var rect = _rain_node.get_node("ColorRect")
	if rect and rect.material is ShaderMaterial:
		var mat = rect.material.duplicate() as ShaderMaterial
		rect.material = mat
		mat.set_shader_parameter("density", density)
		mat.set_shader_parameter("wind_angle", sin(deg_to_rad(wind_angle)) * 0.5)
		mat.set_shader_parameter("intensity", clamp(density * 2.0, 0.3, 1.0))

func _show_snow(density: float, wind_angle: float) -> void:
	_snow_node = _snow_scene.instantiate()
	add_child(_snow_node)
	var rect = _snow_node.get_node("ColorRect")
	if rect and rect.material is ShaderMaterial:
		var mat = rect.material.duplicate() as ShaderMaterial
		rect.material = mat
		mat.set_shader_parameter("density", density)
		mat.set_shader_parameter("wind_offset", sin(deg_to_rad(wind_angle)) * 2.0)
		mat.set_shader_parameter("intensity", clamp(density * 1.5, 0.3, 1.0))

func _show_wind(wind_speed: float, wind_angle: float) -> void:
	_wind_node = _wind_scene.instantiate()
	add_child(_wind_node)
	var rect = _wind_node.get_node("ColorRect")
	if rect and rect.material is ShaderMaterial:
		var mat = rect.material.duplicate() as ShaderMaterial
		rect.material = mat
		mat.set_shader_parameter("wind_angle", deg_to_rad(wind_angle))
		mat.set_shader_parameter("gust_speed", remap(wind_speed, 20.0, 100.0, 2.0, 8.0))
		mat.set_shader_parameter("line_density", remap(wind_speed, 20.0, 100.0, 0.15, 0.5))
		mat.set_shader_parameter("intensity", remap(wind_speed, 20.0, 100.0, 0.3, 1.0))

func _clear_precipitation() -> void:
	if _rain_node and is_instance_valid(_rain_node):
		_rain_node.queue_free()
		_rain_node = null
	if _snow_node and is_instance_valid(_snow_node):
		_snow_node.queue_free()
		_snow_node = null

func _clear_wind() -> void:
	if _wind_node and is_instance_valid(_wind_node):
		_wind_node.queue_free()
		_wind_node = null

func clear_all() -> void:
	_clear_precipitation()
	_clear_wind()
	_current_group = ""
