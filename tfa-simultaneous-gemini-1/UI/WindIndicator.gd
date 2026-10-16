# =====================
# UI/WindIndicator.gd - Wind readout for the HUD status strip (Game.hud_status):
# an arrow pointing DOWNWIND (the way fire spreads; WeatherManager's wind
# vector is already that direction) and "<Strength> wind toward <compass>".
# The tooltip says what that means for fire. Hidden on maps without a
# weather_group (no wind: cell fire spreads evenly there) and on the world map.
# =====================

extends Control

const POLL_SEC := 1.0
const DIAL_RADIUS := 12.0
const DIAL_CENTER := Vector2(14, 14)
const ARROW_COLOR := Color(0.95, 0.9, 0.75)
const DIAL_COLOR := Color(0.0, 0.0, 0.0, 0.55)
const LABEL_FONT_SIZE := 12

var _label: Label
var _game: Node = null
var _dir: Vector2 = Vector2.ZERO
var _speed: float = 0.0
var _poll_left: float = 0.0

func _init() -> void:
	# PASS before HudStatusBar.add_widget looks, so it keeps the tooltip.
	mouse_filter = Control.MOUSE_FILTER_PASS

func _ready() -> void:
	name = "WindIndicator"
	process_mode = Node.PROCESS_MODE_ALWAYS
	# PASS (not IGNORE) so the tooltip shows; HudStatusBar.add_widget keeps it.
	mouse_filter = Control.MOUSE_FILTER_PASS
	custom_minimum_size = Vector2(150, 28)
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.position = Vector2(DIAL_CENTER.x + DIAL_RADIUS + 6, 5)
	_label.add_theme_font_size_override("font_size", LABEL_FONT_SIZE)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 3)
	add_child(_label)
	_game = get_node_or_null("/root/Game")
	if not WeatherManager.weather_changed.is_connected(_on_weather_changed):
		WeatherManager.weather_changed.connect(_on_weather_changed)
	if _game and _game.has_signal("map_loaded"):
		_game.connect("map_loaded", _on_map_loaded)
	refresh()

func _process(delta: float) -> void:
	# Polled too: the debug window and weather rolls emit, but a map change
	# swaps the group without any weather signal.
	_poll_left -= delta
	if _poll_left <= 0.0:
		_poll_left = POLL_SEC
		refresh()

func _on_weather_changed(_group: String, _state: Dictionary) -> void:
	refresh()

func _on_map_loaded(_map_id: String) -> void:
	refresh()

func _weather_group() -> String:
	if _game == null or not is_instance_valid(_game):
		_game = get_node_or_null("/root/Game")
	if _game == null:
		return ""
	var md = _game.get("current_map_data")
	if not (md is Dictionary) or md.get("is_world_map", false):
		return ""
	return str(md.get("weather_group", ""))

func refresh() -> void:
	var grp := _weather_group()
	if grp == "" or WeatherManager.get_weather(grp).is_empty():
		visible = false
		return
	var spd: float = WeatherManager.get_wind_speed(grp)
	var dir: Vector2 = WeatherManager.get_wind_direction(grp)
	var word: String = Globals.wind_strength_word(spd)
	var calm := word == "Calm" or dir.length() < 0.01
	var text := "Calm" if calm else "%s wind toward %s" % [word, Globals.compass_name(dir)]
	var tip := describe(spd, dir)
	visible = true
	if text != _label.text:
		_label.text = text
		# The label is placed by hand, so size the widget to it: the strip's
		# next widget must start after the text, and the tooltip covers it all.
		custom_minimum_size.x = maxf(DIAL_CENTER.x * 2.0, _label.position.x + _label.get_combined_minimum_size().x + 2.0)
	if tip != tooltip_text:
		tooltip_text = tip
	var new_dir := Vector2.ZERO if calm else dir.normalized()
	if new_dir != _dir or not is_equal_approx(spd, _speed):
		_dir = new_dir
		_speed = spd
		queue_redraw()

## Tooltip text for a wind of `speed` (0-100) blowing toward `dir`. The fire
## numbers follow CellFire._spread: the downwind weight saturates at speed 15
## (about x2 downwind, x0.15 upwind).
func describe(speed: float, dir: Vector2) -> String:
	var word: String = Globals.wind_strength_word(speed)
	if word == "Calm" or dir.length() < 0.01:
		return "Wind %d (Calm).\nFire spreads evenly in every direction." % int(round(speed))
	var head := "Wind %d (%s), blowing toward the %s." % [int(round(speed)), word, Globals.compass_name(dir)]
	if word == "Light":
		return head + "\nFire leans downwind: it spreads faster that way and slower upwind."
	return head + "\nFire spreads about twice as fast downwind and almost never upwind."

func _draw() -> void:
	draw_circle(DIAL_CENTER, DIAL_RADIUS, DIAL_COLOR)
	if _dir == Vector2.ZERO:
		draw_circle(DIAL_CENTER, 2.5, ARROW_COLOR)
		return
	# Arrow along +x, rotated to the wind: shaft plus a filled head.
	var rot := _dir.angle()
	var tail := DIAL_CENTER + Vector2(-8, 0).rotated(rot)
	var neck := DIAL_CENTER + Vector2(2, 0).rotated(rot)
	draw_line(tail, neck, ARROW_COLOR, 2.5, true)
	var head := PackedVector2Array([
		DIAL_CENTER + Vector2(9, 0).rotated(rot),
		DIAL_CENTER + Vector2(1, -5).rotated(rot),
		DIAL_CENTER + Vector2(1, 5).rotated(rot),
	])
	draw_colored_polygon(head, ARROW_COLOR)
