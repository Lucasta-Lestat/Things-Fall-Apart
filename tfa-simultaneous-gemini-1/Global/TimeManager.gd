#TimeManager.gd
extends Node

# Time tracking
var game_time: float = 0.0  # Time in seconds since game start
var time_scale: float = 1.0  # How fast time passes (1.0 = real-time, 60.0 = 1 min per second)
var is_paused: bool = false

# Date/time components
var current_day: int = 1
var current_month: int = 1
var current_year: int = 2524
var current_hour: int = 0
var current_minute: int = 0
var current_second: int = 0

# Constants
const SECONDS_PER_MINUTE = 60
const MINUTES_PER_HOUR = 60
const HOURS_PER_DAY = 24
const DAYS_PER_MONTH = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
const MONTH_NAMES = ["January", "February", "March", "April", "May", "June", 
					 "July", "August", "September", "October", "November", "December"]

signal time_updated(hour, minute, second)
signal date_changed(day, month, year)

func _ready():
	# Set initial time if desired
	set_time(6, 0, 0)  # Start at 8:00 AM
	set_date(1, 10, 2524)  # June 1, 2024

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

func advance_days(days: int):
	for i in range(days):
		current_day += 1
		var days_in_month = get_days_in_month(current_month, current_year)
		
		if current_day > days_in_month:
			current_day = 1
			current_month += 1
			
			if current_month > 12:
				current_month = 1
				current_year += 1
		
		emit_signal("date_changed", current_day, current_month, current_year)

func get_days_in_month(month: int, year: int) -> int:
	if month == 2 and is_leap_year(year):
		return 29
	return DAYS_PER_MONTH[month - 1]

func is_leap_year(year: int) -> bool:
	return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0)

func set_time(hour: int, minute: int, second: int):
	current_hour = hour
	current_minute = minute
	current_second = second
	game_time = (hour * MINUTES_PER_HOUR * SECONDS_PER_MINUTE) + (minute * SECONDS_PER_MINUTE) + second
	emit_signal("time_updated", current_hour, current_minute, current_second)

func set_date(day: int, month: int, year: int):
	current_day = day
	current_month = month
	current_year = year
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

func get_date_string() -> String:
	return "%s %d, %d" % [MONTH_NAMES[current_month - 1], current_day, current_year]
