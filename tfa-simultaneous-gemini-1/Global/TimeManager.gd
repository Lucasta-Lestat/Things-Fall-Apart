#TimeManager.gd
extends Node

# Time tracking
var game_time: float = 0.0  # Time in seconds since game start
var time_scale: float = 1.0  # How fast time passes (1.0 = real-time, 60.0 = 1 min per second)
var is_paused: bool = false

# Date/time components.
# current_day is the day-of-period: 1-36 in regular months, 1-12 during Yearturn.
# current_month is 1-10 (Frostiem..Mistumnal); ignored while is_yearturn is true.
var current_day: int = 1
var current_month: int = 1
var current_year: int = 1945
var current_hour: int = 0
var current_minute: int = 0
var current_second: int = 0
var is_yearturn: bool = false

# Constants
const SECONDS_PER_MINUTE = 60
const MINUTES_PER_HOUR = 60
const HOURS_PER_DAY = 24

const DAYS_PER_MONTH: int = 36
const MONTHS_PER_YEAR: int = 10
const DAYS_PER_WEEK: int = 12
const YEARTURN_LENGTH: int = 12
const COMMON_YEAR_DAYS: int = 360
const LEAP_YEAR_DAYS: int = 372

const MONTH_NAMES = [
	"Frostiem", "Snowiem", "Thaw", "Florivern", "Dewyvern",
	"Parchestal", "Burnestal", "Harvest", "Witherumnal", "Mistumnal"
]
const WEEKDAY_NAMES = [
	"Primiday", "Secunday", "Terceday", "Quartiday", "Quintiday", "Sextiday",
	"Septiday", "Octiday", "Noniday", "Deciday", "Unday", "Duday"
]
const YEARTURN_NAME: String = "Yearturn"

signal time_updated(hour, minute, second)
signal date_changed(day, month, year)

func _ready():
	set_time(6, 0, 0)
	set_date(1, 9, 1945)  # Witherumnal 1, 1945
	process_mode = Node.PROCESS_MODE_ALWAYS

func _process(delta):
	if is_paused:
		return

	# Advance game time
	game_time += delta * time_scale

	# Update time components
	var total_seconds = int(game_time)
	var new_second = total_seconds % SECONDS_PER_MINUTE
	var total_minutes = total_seconds / SECONDS_PER_MINUTE
	var new_minute = total_minutes % MINUTES_PER_HOUR
	var total_hours = total_minutes / MINUTES_PER_HOUR
	var new_hour = total_hours % HOURS_PER_DAY
	var total_days = total_hours / HOURS_PER_DAY

	# Check if time components changed
	if new_second != current_second or new_minute != current_minute or new_hour != current_hour:
		current_second = new_second
		current_minute = new_minute
		current_hour = new_hour
		emit_signal("time_updated", current_hour, current_minute, current_second)

	# Handle day changes
	if total_days > 0:
		advance_days(total_days)
		game_time = game_time - (total_days * HOURS_PER_DAY * MINUTES_PER_HOUR * SECONDS_PER_MINUTE)

func advance_days(days: int) -> void:
	for i in range(days):
		current_day += 1
		if is_yearturn:
			if current_day > YEARTURN_LENGTH:
				is_yearturn = false
				current_day = 1
				current_month = 1
				current_year += 1
		else:
			if current_day > DAYS_PER_MONTH:
				current_day = 1
				current_month += 1
				if current_month > MONTHS_PER_YEAR:
					if is_leap_year(current_year):
						is_yearturn = true
						current_month = 0
					else:
						current_month = 1
						current_year += 1
		emit_signal("date_changed", current_day, current_month, current_year)

func get_days_in_month(_month: int, _year: int) -> int:
	return DAYS_PER_MONTH

# Madelinian leap rule: even years, except ÷12, except ÷48, except ÷576.
func is_leap_year(year: int) -> bool:
	if year % 576 == 0: return false
	if year % 48 == 0:  return true
	if year % 12 == 0:  return false
	if year % 2 == 0:   return true
	return false

func set_time(hour: int, minute: int, second: int):
	current_hour = hour
	current_minute = minute
	current_second = second
	game_time = (hour * MINUTES_PER_HOUR * SECONDS_PER_MINUTE) + (minute * SECONDS_PER_MINUTE) + second
	emit_signal("time_updated", current_hour, current_minute, current_second)

# month == 0 indicates Yearturn.
func set_date(day: int, month: int, year: int):
	current_day = day
	current_month = month
	current_year = year
	is_yearturn = (month == 0)
	emit_signal("date_changed", current_day, current_month, current_year)

func pause_time():
	is_paused = true

func resume_time():
	is_paused = false

func toggle_pause():
	is_paused = !is_paused

func set_time_scale(scale: float):
	time_scale = scale

func get_time_string(use_12_hour: bool = false) -> String:
	if use_12_hour:
		var hour_12 = current_hour % 12
		if hour_12 == 0:
			hour_12 = 12
		var am_pm = "AM" if current_hour < 12 else "PM"
		return "%d:%02d %s" % [hour_12, current_minute, am_pm]
	else:
		return "%02d:%02d" % [current_hour, current_minute]

func get_weekday_name() -> String:
	var idx = (current_day - 1) % DAYS_PER_WEEK
	return WEEKDAY_NAMES[idx]

func get_date_string() -> String:
	var period_name: String = YEARTURN_NAME if is_yearturn else MONTH_NAMES[current_month - 1]
	return "%s, %s %d, %d" % [get_weekday_name(), period_name, current_day, current_year]
