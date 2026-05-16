# EventScheduler.gd
# Autoload. Drives time-based dialogue triggers off TimeManager's
# `time_updated(hour, minute, second)` signal.
#
# Two pools of triggers:
#   - Global   : loaded once from data/ScheduledDialogues.json (key "triggers")
#   - MapScope : per-map array Maps.json[map].dialogue_time_triggers, swapped
#                in/out by Game.load_map via on_map_entered / on_map_exited.
#
# A trigger fires when (hour, minute) matches `when` AND its scope matches the
# current map. Triggers are deduplicated per (map_id, trigger_id) via
# MapTriggerState; one-shots stay marked forever, recurring triggers stamp the
# last day they fired so they don't fire twice on the same in-game minute.
#
# Trigger shape:
#   {
#     "id":            "campfire_night1",
#     "dialogue":      "campfire_chat",
#     "when":          { "hour": 22, "minute": 0 },
#     "recurrence":    "once" | "daily" | { "every_days": N },
#     "scope":         "global" | { "map": "<map_id>" },
#     "prerequisites": [ ... ]
#   }
extends Node

const GLOBAL_KEY := "__global__"
const SCHEDULED_PATH := "res://data/ScheduledDialogues.json"

var _global_triggers: Array = []
var _map_triggers: Array = []          # active for the current map only
var _current_map_id: String = ""
# Per-trigger last-fired-day, keyed by "<map_id>::<trigger_id>". Used by
# recurring triggers to skip same-day double-fires.
var _last_fired_day: Dictionary = {}

@onready var _dialogue = get_node_or_null("/root/DialogueManager")
@onready var _trigger_state = get_node_or_null("/root/MapTriggerState")
@onready var _time = get_node_or_null("/root/TimeManager")

func _ready() -> void:
	_load_global_triggers()
	if _time:
		_time.time_updated.connect(_on_time_updated)

func _load_global_triggers() -> void:
	if not FileAccess.file_exists(SCHEDULED_PATH):
		return
	var f := FileAccess.open(SCHEDULED_PATH, FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		push_error("EventScheduler: failed to parse " + SCHEDULED_PATH + " - " + json.get_error_message())
		return
	var data = json.data
	if data is Dictionary:
		_global_triggers = data.get("triggers", [])
	else:
		_global_triggers = []

# Called from Game.load_map after the map is built.
func on_map_entered(map_id: String, triggers: Array) -> void:
	_current_map_id = map_id
	_map_triggers = triggers if triggers != null else []

func on_map_exited(_map_id: String) -> void:
	_current_map_id = ""
	_map_triggers = []

# TimeManager fires this every wall-clock second. We dedup on (hour, minute,
# day) so a trigger lands at most once per matching minute even though the
# signal arrives multiple times within that minute.
func _on_time_updated(hour: int, minute: int, _second: int) -> void:
	if _dialogue == null:
		return
	var day_stamp := _today_stamp()
	for t in _global_triggers:
		_maybe_fire(t, hour, minute, day_stamp, GLOBAL_KEY)
	for t in _map_triggers:
		_maybe_fire(t, hour, minute, day_stamp, _current_map_id)

func _maybe_fire(trigger: Dictionary, hour: int, minute: int, day_stamp: int, fallback_key: String) -> void:
	var when = trigger.get("when", {})
	if int(when.get("hour", -1)) != hour or int(when.get("minute", -1)) != minute:
		return
	if not _scope_matches(trigger.get("scope", "global")):
		return

	# Resolve the dedup map_id we'll record under. Map-scoped triggers go under
	# the actual map id; global triggers go under GLOBAL_KEY.
	var dedup_map: String = _dedup_map_for(trigger, fallback_key)
	var tid: String = str(trigger.get("id", ""))
	if tid.is_empty():
		return

	var recurrence = trigger.get("recurrence", "once")
	if recurrence == "once":
		if _trigger_state and _trigger_state.has_fired(dedup_map, tid):
			return
	else:
		# Recurring: enforce the cadence via _last_fired_day.
		var key := dedup_map + "::" + tid
		var last_day: int = int(_last_fired_day.get(key, -10000000))
		var min_gap := 1
		if recurrence is Dictionary and recurrence.has("every_days"):
			min_gap = max(1, int(recurrence["every_days"]))
		# else "daily" -> min_gap stays 1
		if day_stamp - last_day < min_gap:
			return

	var prereqs = trigger.get("prerequisites", [])
	if _dialogue.has_method("evaluate_prerequisites"):
		if not _dialogue.evaluate_prerequisites(prereqs):
			return

	_dialogue.start_dialogue(str(trigger.get("dialogue", "")))

	if recurrence == "once":
		if _trigger_state:
			_trigger_state.mark_fired(dedup_map, tid)
	else:
		_last_fired_day[dedup_map + "::" + tid] = day_stamp

func _scope_matches(scope) -> bool:
	if scope == "global" or scope == null:
		return true
	if scope is Dictionary and scope.has("map"):
		return _current_map_id == str(scope["map"])
	return true

func _dedup_map_for(trigger: Dictionary, fallback_key: String) -> String:
	var scope = trigger.get("scope", "global")
	if scope is Dictionary and scope.has("map"):
		return str(scope["map"])
	if scope == "global":
		return GLOBAL_KEY
	return fallback_key

# Pack the current in-game date into a single comparable integer so cadence
# math is straightforward across month/year boundaries.
func _today_stamp() -> int:
	if _time == null:
		return 0
	return int(_time.current_year) * 10000 \
		+ int(_time.current_month) * 100 \
		+ int(_time.current_day)
