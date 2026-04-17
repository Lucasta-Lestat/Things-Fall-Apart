# WeatherManager.gd
# Autoload that rolls random weather each day per weather group.
# Tracks precipitation type, wind speed, and wind direction.
extends Node

signal weather_changed(group: String, weather_state: Dictionary)

# Loaded from weather.json
var _weather_groups: Dictionary = {}
var _precipitation_types: Dictionary = {}

# Current weather per group: Dictionary[String, Dictionary]
# Each entry: { "precipitation": String, "wind_speed": float, "wind_direction": Vector2,
#                "wind_angle": float, "rolls": Dictionary }
var current_weather: Dictionary = {}

# Track which day we last rolled for each group
var _last_roll_day: Dictionary = {}

func _ready() -> void:
	_load_weather_database()
	TimeManager.date_changed.connect(_on_date_changed)
	# Roll weather for all groups on startup
	for group_id in _weather_groups:
		_roll_weather(group_id)

func _load_weather_database() -> void:
	var file_path = "res://data/weather.json"
	if not FileAccess.file_exists(file_path):
		push_error("WeatherManager: weather.json not found at " + file_path)
		return
	var file = FileAccess.open(file_path, FileAccess.READ)
	var json = JSON.new()
	if json.parse(file.get_as_text()) == OK:
		var data = json.get_data()
		_weather_groups = data.get("weather_groups", {})
		_precipitation_types = data.get("precipitation_types", {})
	else:
		push_error("WeatherManager: Failed to parse weather.json")

func _on_date_changed(day: int, month: int, year: int) -> void:
	for group_id in _weather_groups:
		_roll_weather(group_id)

func _roll_weather(group_id: String) -> void:
	var group_data = _weather_groups.get(group_id, {})
	if group_data.is_empty():
		return

	# --- Precipitation roll ---
	var precip_table = group_data.get("precipitation_table", [])
	var total_weight: float = 0.0
	for entry in precip_table:
		total_weight += entry.get("weight", 0)

	var precip_roll = randf() * total_weight
	var precip_type: String = "clear"
	var accumulated: float = 0.0
	for entry in precip_table:
		accumulated += entry.get("weight", 0)
		if precip_roll <= accumulated:
			precip_type = entry.get("type", "clear")
			break

	# --- Wind speed roll ---
	var wind_range = group_data.get("wind_speed_range", [0, 100])
	var wind_min: float = wind_range[0] if wind_range.size() > 0 else 0.0
	var wind_max: float = wind_range[1] if wind_range.size() > 1 else 100.0
	var wind_speed_roll = randf()
	var wind_speed: float = lerp(wind_min, wind_max, wind_speed_roll)

	# --- Wind direction roll ---
	var direction_angles = group_data.get("wind_direction_angles", [0, 45, 90, 135, 180, 225, 270, 315])
	var dir_roll_index = randi() % direction_angles.size()
	var wind_angle: float = float(direction_angles[dir_roll_index])
	var wind_direction = Vector2.RIGHT.rotated(deg_to_rad(wind_angle))

	var weather_state = {
		"precipitation": precip_type,
		"wind_speed": wind_speed,
		"wind_direction": wind_direction,
		"wind_angle": wind_angle,
		"rolls": {
			"precipitation_roll": precip_roll,
			"precipitation_total_weight": total_weight,
			"wind_speed_roll": wind_speed_roll,
			"wind_direction_index": dir_roll_index,
			"wind_direction_angle": wind_angle
		}
	}

	current_weather[group_id] = weather_state
	emit_signal("weather_changed", group_id, weather_state)
	print("[WeatherManager] Rolled weather for '%s': %s, wind %.0f @ %.0f°" % [
		group_id, precip_type, wind_speed, wind_angle
	])

# --- Public API ---

func get_weather(group_id: String) -> Dictionary:
	return current_weather.get(group_id, {})

func get_precipitation(group_id: String) -> String:
	return current_weather.get(group_id, {}).get("precipitation", "clear")

func get_wind_speed(group_id: String) -> float:
	return current_weather.get(group_id, {}).get("wind_speed", 0.0)

func get_wind_direction(group_id: String) -> Vector2:
	return current_weather.get(group_id, {}).get("wind_direction", Vector2.ZERO)

func get_wind_angle(group_id: String) -> float:
	return current_weather.get(group_id, {}).get("wind_angle", 0.0)

func get_precipitation_data(precip_type: String) -> Dictionary:
	return _precipitation_types.get(precip_type, {})

func get_rolls(group_id: String) -> Dictionary:
	return current_weather.get(group_id, {}).get("rolls", {})

# --- Debug / Override API ---

func set_precipitation(group_id: String, precip_type: String) -> void:
	if current_weather.has(group_id):
		current_weather[group_id]["precipitation"] = precip_type
		emit_signal("weather_changed", group_id, current_weather[group_id])

func set_wind_speed(group_id: String, speed: float) -> void:
	if current_weather.has(group_id):
		current_weather[group_id]["wind_speed"] = speed
		emit_signal("weather_changed", group_id, current_weather[group_id])

func set_wind_angle(group_id: String, angle: float) -> void:
	if current_weather.has(group_id):
		current_weather[group_id]["wind_angle"] = angle
		current_weather[group_id]["wind_direction"] = Vector2.RIGHT.rotated(deg_to_rad(angle))
		emit_signal("weather_changed", group_id, current_weather[group_id])

func force_reroll(group_id: String) -> void:
	_roll_weather(group_id)
