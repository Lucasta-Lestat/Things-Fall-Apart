# =====================
# game_log.gd - Autoload Singleton

extends Node

signal entry_added(text: String, timestamp: String)
## The newest entry repeated; `count` is how many times it has now occurred.
signal entry_repeated(count: int)

var entries: Array[Dictionary] = []
var max_entries: int = 100  # Limit stored entries

# An identical line arriving this soon after the last one is folded into it
# as a count ("Goblin has died. (x2)") rather than added again, so per-frame
# refusals can't flood the panel and simultaneous events aren't under-reported.
const REPEAT_WINDOW_MS := 1500
var _last_text: String = ""
var _last_text_ms: int = -REPEAT_WINDOW_MS

func add_entry(text: String):
	var now_ms := Time.get_ticks_msec()
	if text == _last_text and now_ms - _last_text_ms < REPEAT_WINDOW_MS and not entries.is_empty():
		_last_text_ms = now_ms
		var last: Dictionary = entries[-1]
		last["count"] = int(last.get("count", 1)) + 1
		emit_signal("entry_repeated", last["count"])
		return
	_last_text = text
	_last_text_ms = now_ms
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
