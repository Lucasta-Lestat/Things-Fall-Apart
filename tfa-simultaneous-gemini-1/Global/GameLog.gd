# =====================
# game_log.gd - Autoload Singleton

extends Node

signal entry_added(text: String, timestamp: String)

var entries: Array[Dictionary] = [{"text":"test","timestamp": _get_timestamp(),"game_time": _get_game_time_string()}]
var max_entries: int = 100  # Limit stored entries

func add_entry(text: String):
	var timestamp = _get_timestamp()
	var entry = {
		"text": text,
		"timestamp": timestamp,
		"game_time": _get_game_time_string()
	}
	
	entries.append(entry)
	
	# Trim old entries if needed
	if entries.size() > max_entries:
		entries.pop_front()
	
	print_rich("[color=white][LOG] ", entry.game_time, " - ", text, "[/color]")
	emit_signal("entry_added", text, entry.game_time)

func _get_timestamp() -> String:
	var time = Time.get_time_dict_from_system()
	return "%02d:%02d:%02d" % [time.hour, time.minute, time.second]

func _get_game_time_string() -> String:
	# Use your TimeManager if available
	if has_node("/root/TimeManager"):
		var tm = get_node("/root/TimeManager")
		return tm.get_time_string()
	return _get_timestamp()

func get_entries() -> Array[Dictionary]:
	return entries

func clear():
	entries.clear()
