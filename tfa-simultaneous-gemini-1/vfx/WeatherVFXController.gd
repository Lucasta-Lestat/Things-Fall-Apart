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

var _weather_audio: AudioStreamPlayer = null
var _wind_audio: AudioStreamPlayer = null

# Maps a precipitation type to the looped audio stream + playback volume.
# heavy_rain / heavy_snow reuse the gentler stream at higher volume.
const PRECIP_LOOPS := {
	"rain":          {"path": "res://sfx/weather_rain_loop.mp3",          "volume_db": -8.0},
	"heavy_rain":    {"path": "res://sfx/weather_rain_loop.mp3",          "volume_db": -2.0},
	"snow":          {"path": "res://sfx/weather_snow_loop.mp3",          "volume_db": -10.0},
	"heavy_snow":    {"path": "res://sfx/weather_snow_loop.mp3",          "volume_db": -4.0},
	"acid_rain":     {"path": "res://sfx/weather_acid_rain_loop.mp3",     "volume_db": -6.0},
	"freezing_rain": {"path": "res://sfx/weather_freezing_rain_loop.mp3", "volume_db": -6.0},
}
const WIND_LOOP_PATH := "res://sfx/weather_wind_loop.mp3"

var _current_group: String = ""
var _audio_cache: Dictionary = {}

func _ready() -> void:
	WeatherManager.weather_changed.connect(_on_weather_changed)
	_weather_audio = AudioStreamPlayer.new()
	_weather_audio.bus = "SFX"
	add_child(_weather_audio)
	_wind_audio = AudioStreamPlayer.new()
	_wind_audio.bus = "SFX"
	add_child(_wind_audio)

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

	_apply_weather_audio(precip, wind_speed)


func _apply_weather_audio(precip: String, wind_speed: float) -> void:
	# Precipitation loop
	if PRECIP_LOOPS.has(precip):
		var entry: Dictionary = PRECIP_LOOPS[precip]
		var stream := _get_looped_stream(entry["path"])
		if stream:
			if _weather_audio.stream != stream:
				_weather_audio.stop()
				_weather_audio.stream = stream
				_weather_audio.volume_db = entry["volume_db"]
				_weather_audio.play()
			else:
				_weather_audio.volume_db = entry["volume_db"]
				if not _weather_audio.playing:
					_weather_audio.play()
	else:
		_weather_audio.stop()

	# Wind loop, scaled by speed
	if wind_speed > 20.0:
		var wind_stream := _get_looped_stream(WIND_LOOP_PATH)
		if wind_stream:
			if _wind_audio.stream != wind_stream:
				_wind_audio.stop()
				_wind_audio.stream = wind_stream
			if not _wind_audio.playing:
				_wind_audio.play()
			_wind_audio.volume_db = lerp(-18.0, -4.0, clamp((wind_speed - 20.0) / 80.0, 0.0, 1.0))
	else:
		_wind_audio.stop()


func _get_looped_stream(path: String) -> AudioStream:
	if _audio_cache.has(path):
		return _audio_cache[path]
	if not ResourceLoader.exists(path):
		push_warning("WeatherVFXController: missing audio %s" % path)
		_audio_cache[path] = null
		return null
	var stream := load(path) as AudioStream
	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	elif stream is AudioStreamWAV:
		(stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
	_audio_cache[path] = stream
	return stream

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
		mat.set_shader_parameter("gust_speed", clamp(remap(wind_speed, 20.0, 100.0, 2.0, 6.0), 2.0, 6.0))
		mat.set_shader_parameter("line_density", clamp(remap(wind_speed, 20.0, 100.0, 0.08, 0.25), 0.08, 0.25))
		mat.set_shader_parameter("intensity", clamp(remap(wind_speed, 20.0, 100.0, 0.3, 0.7), 0.3, 0.7))

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
	if _weather_audio:
		_weather_audio.stop()
	if _wind_audio:
		_wind_audio.stop()
	_current_group = ""
