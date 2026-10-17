# =====================
# UI/WindIndicator.gd - Wind readout in the top-left clock cluster: Game._ready
# puts it under GameUI, where it docks just right of the date/time (TimeLabel)
# and the downtime (moon) button, centred on the clock, in the clock's font
# and size. An arrow points DOWNWIND (the way fire spreads; WeatherManager's
# wind vector is already that direction) beside "<Strength> wind toward
# <compass>". The tooltip says what that means for fire. Hidden on maps without
# a weather_group (no wind: cell fire spreads evenly there) and on the world
# map. It ignores the Tab HUD toggle (the wind is always worth knowing): with
# the clock hidden it moves into the clock's spot. Placed in a container (the
# HUD status strip) it leaves positioning to the container.
# =====================

extends Control

const POLL_SEC := 1.0
const DIAL_RADIUS := 12.0
const DIAL_CENTER := Vector2(14, 14)
const ARROW_COLOR := Color(0.95, 0.9, 0.75)
const DIAL_COLOR := Color(0.0, 0.0, 0.0, 0.55)
const DOCK_GAP := 8.0           # same gap the moon button keeps from the clock
const DOCK_LEFT := 16.0         # TimeLabel's offset_left / offset_top
const DOCK_FALLBACK_TOP := 16.0

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
	custom_minimum_size = Vector2(150, DIAL_CENTER.y * 2.0)
	# No font overrides: the clock (TimeLabel) has none either, so the wind
	# reads in the same theme font, size and colour as the date beside it.
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.position = Vector2(DIAL_CENTER.x + DIAL_RADIUS + 6, 0)
	add_child(_label)
	if not (get_parent() is Container):
		anchor_left = 0.0
		anchor_top = 0.0
		anchor_right = 0.0
		anchor_bottom = 0.0
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
	# Every frame: the clock's width changes with the date string and the
	# moon button shows and hides with the Tab toggle, neither with a signal
	# that carries the new rect.
	_dock()

## Beside the clock cluster: right of the moon button when it shows, else of
## the clock, else in the clock's own spot; centred on the clock's two lines.
func _dock() -> void:
	var parent := get_parent()
	if parent == null or parent is Container:
		return
	var clock := parent.get_node_or_null("TimeLabel") as Control
	var moon := parent.get_node_or_null("MoonToggleButton") as Control
	var left := DOCK_LEFT
	var center_y := DOCK_FALLBACK_TOP + custom_minimum_size.y * 0.5
	if clock:
		# Hidden by Tab or not, the clock keeps its rect.
		var r := clock.get_rect()
		center_y = r.position.y + r.size.y * 0.5
		if clock.visible:
			left = r.end.x + DOCK_GAP
	if moon and moon.visible:
		left = maxf(left, moon.get_rect().end.x + DOCK_GAP)
	var top := roundf(center_y - custom_minimum_size.y * 0.5)
	if is_equal_approx(offset_left, left) and is_equal_approx(offset_top, top) \
			and is_equal_approx(offset_right, left + custom_minimum_size.x):
		return
	offset_left = left
	offset_top = top
	offset_right = left + custom_minimum_size.x
	offset_bottom = top + custom_minimum_size.y

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
		var text_size: Vector2 = _label.get_combined_minimum_size()
		custom_minimum_size = Vector2(
			maxf(DIAL_CENTER.x * 2.0, _label.position.x + text_size.x + 2.0),
			maxf(DIAL_CENTER.y * 2.0, text_size.y))
		_label.position.y = roundf((custom_minimum_size.y - text_size.y) * 0.5)
		_dock()
		queue_redraw()
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
	# Centred on the widget's height, which follows the label's line height.
	var c := Vector2(DIAL_CENTER.x, maxf(DIAL_CENTER.y, custom_minimum_size.y * 0.5))
	draw_circle(c, DIAL_RADIUS, DIAL_COLOR)
	if _dir == Vector2.ZERO:
		draw_circle(c, 2.5, ARROW_COLOR)
		return
	# Arrow along +x, rotated to the wind: shaft plus a filled head.
	var rot := _dir.angle()
	var tail := c + Vector2(-8, 0).rotated(rot)
	var neck := c + Vector2(2, 0).rotated(rot)
	draw_line(tail, neck, ARROW_COLOR, 2.5, true)
	var head := PackedVector2Array([
		c + Vector2(9, 0).rotated(rot),
		c + Vector2(1, -5).rotated(rot),
		c + Vector2(1, 5).rotated(rot),
	])
	draw_colored_polygon(head, ARROW_COLOR)
