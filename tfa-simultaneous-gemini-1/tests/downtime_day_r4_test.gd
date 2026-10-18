# res://tests/downtime_day_r4_test.gd
# Headless harness for the downtime cooldown day count (round 4, the
# "New Year" fix).
#
# The contract under test:
#   (1) TimeManager.day_number counts real calendar days: across any span its
#       difference equals the days advance_days steps through, New Year and a
#       leap year's 12-day Yearturn included,
#   (2) a downtime outcome is on cooldown for exactly 7 days of play, across a
#       common New Year and across a leap year's Yearturn (the old
#       year*372 + month*36 + day index freed things at New Year and kept
#       everything blocked through Yearturn),
#   (3) Training stays exempt, and the "too often lately" line still names 7,
#   (4) a pre-fix save (entries stamped on the old index) is converted on load
#       through the calendar; entries that can't be dated are dropped,
#   (5) a save made after the fix round-trips unchanged, in memory and through
#       JSON,
#   (6) the same Yearturn fault is gone from quest day counters and recurring
#       scheduled dialogue.
#
# Run:  godot --headless --path . res://tests/downtime_day_r4_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

var _fails := 0
var _checks := 0
var game = null


class StubDialogue:
	extends Node
	var started: Array = []
	func start_dialogue(id: String) -> void:
		started.append(id)


func _ready() -> void:
	TimeManager.pause_time()
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)

	# Drive the REAL game scene: cooldowns live on Game, and the save round
	# trip goes through Game.build_save_dict / apply_save_dict.
	await get_tree().process_frame
	var GameScene := load("res://game.tscn")
	game = GameScene.instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _await_frames(2)
	game.load_map("town_square")
	await _await_frames(5)

	_case_calendar()
	_case_new_year()
	_case_yearturn()
	_case_training_exempt()
	_case_old_save_migrated()
	_case_yearturn_save_migrated()
	_case_round_trip()
	_case_quest_days()
	_case_scheduled_dialogue()

	print("HARNESS DONE failures=%d checks=%d" % [_fails, _checks])
	get_tree().quit(1 if _fails > 0 else 0)


func _await_frames(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame


func _report(check_name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("%s %s: %s" % ["PASS" if ok else "FAIL", check_name, detail])


# Set the date quietly, the way Game.apply_save_dict does (no date_changed).
func _set_date(day: int, month: int, year: int) -> void:
	TimeManager.current_day = day
	TimeManager.current_month = month
	TimeManager.current_year = year
	TimeManager.is_yearturn = month == 0


# The pre-fix cooldown index, kept here only to build old saves and to show
# what the old code would have done on the same dates.
static func _old_index(day: int, month: int, year: int) -> int:
	return year * 372 + month * 36 + day


# is_on_cooldown after each of `days` single advance_days steps.
func _cooling_by_day(uid: String, result_id: String, activity_id: String, days: int) -> Array:
	var out: Array = []
	for i in range(days):
		TimeManager.advance_days(1)
		out.append(DowntimeDatabase.is_on_cooldown(uid, result_id, activity_id))
	return out


const COOLING_7 := [true, true, true, true, true, true, false]


# --- 1. the calendar -----------------------------------------------------------

func _case_calendar() -> void:
	_report("calendar.1945-common", not TimeManager.is_leap_year(1945), "")
	_report("calendar.1946-leap", TimeManager.is_leap_year(1946), "")

	# The closed-form leap count agrees with is_leap_year year by year.
	var count := 0
	var bad: Array = []
	for y in range(1, 2400):
		if TimeManager.is_leap_year(y):
			count += 1
		if TimeManager.leap_years_through(y) != count:
			bad.append(y)
	_report("calendar.leap-count-matches-rule", bad.is_empty(), str(bad.slice(0, 5)))

	# day_number moves exactly one per advance_days step for 460 days from
	# Witherumnal 1, 1946: through the 1946 Yearturn and the 1947 New Year.
	_set_date(1, 9, 1946)
	var start := TimeManager.day_number(1, 9, 1946)
	var saw_yearturn := false
	var saw_new_year := false
	var first_bad := ""
	for i in range(1, 461):
		TimeManager.advance_days(1)
		saw_yearturn = saw_yearturn or TimeManager.is_yearturn
		saw_new_year = saw_new_year or (TimeManager.current_year == 1948)
		var n := TimeManager.day_number(TimeManager.current_day, TimeManager.current_month, TimeManager.current_year)
		if n - start != i and first_bad.is_empty():
			first_bad = "step %d: %s gave %d" % [i, TimeManager.get_date_string(), n - start]
	_report("calendar.day-number-tracks-advance-days", first_bad.is_empty() and saw_yearturn and saw_new_year,
		"%s yearturn=%s new_year=%s" % [first_bad, saw_yearturn, saw_new_year])
	_report("calendar.yearturn-after-mistumnal",
		TimeManager.day_number(1, 0, 1946) == TimeManager.day_number(36, 10, 1946) + 1
		and TimeManager.day_number(1, 1, 1947) == TimeManager.day_number(12, 0, 1946) + 1, "")
	_report("calendar.common-new-year",
		TimeManager.day_number(1, 1, 1946) == TimeManager.day_number(36, 10, 1945) + 1, "")


# --- 2. cooldowns across New Year and Yearturn -----------------------------------

func _case_new_year() -> void:
	var uid := "r4_new_year"
	game.downtime_recent_events.erase(uid)
	# Used on Mistumnal 33, 1945 (a common year): New Year's Day is 4 days on.
	_set_date(33, 10, 1945)
	var used_old := _old_index(33, 10, 1945)
	DowntimeDatabase.mark_used(uid, "hangover", "drinking")
	var cooling := _cooling_by_day(uid, "hangover", "drinking", 7)
	_report("new-year.cooling-exactly-7-days", cooling == COOLING_7, str(cooling))
	_report("new-year.ends-on-frostiem-4",
		TimeManager.current_day == 4 and TimeManager.current_month == 1 and TimeManager.current_year == 1946,
		TimeManager.get_date_string())
	# The old index called New Year's Day 16 "days" after Mistumnal 33.
	_report("new-year.old-index-freed-it-early", _old_index(1, 1, 1946) - used_old >= DowntimeDatabase.COOLDOWN_DAYS,
		str(_old_index(1, 1, 1946) - used_old))
	game.downtime_recent_events.erase(uid)


func _case_yearturn() -> void:
	var uid := "r4_yearturn"
	game.downtime_recent_events.erase(uid)

	# Into Yearturn: used Mistumnal 34, 1946 (leap), free on Yearturn 5.
	_set_date(34, 10, 1946)
	DowntimeDatabase.mark_used(uid, "hangover", "drinking")
	var cooling := _cooling_by_day(uid, "hangover", "drinking", 7)
	_report("yearturn.into-cooling-exactly-7-days", cooling == COOLING_7, str(cooling))
	_report("yearturn.into-ends-on-yearturn-5", TimeManager.is_yearturn and TimeManager.current_day == 5,
		TimeManager.get_date_string())

	# Out of Yearturn: used Yearturn 9, free on Frostiem 4, 1947.
	_set_date(9, 0, 1946)
	DowntimeDatabase.mark_used(uid, "belligerent", "drinking")
	cooling = _cooling_by_day(uid, "belligerent", "drinking", 7)
	_report("yearturn.out-cooling-exactly-7-days", cooling == COOLING_7, str(cooling))
	_report("yearturn.out-ends-on-frostiem-4",
		not TimeManager.is_yearturn and TimeManager.current_day == 4 and TimeManager.current_year == 1947,
		TimeManager.get_date_string())

	# Used in Mistumnal long before: Yearturn no longer blocks it. The old index
	# put every Yearturn day below Mistumnal, so it stayed blocked all 12 days.
	game.downtime_recent_events.erase(uid)
	_set_date(20, 10, 1946)
	DowntimeDatabase.mark_used(uid, "gossip", "drinking")
	TimeManager.advance_days(17)
	_report("yearturn.reached", TimeManager.is_yearturn and TimeManager.current_day == 1, TimeManager.get_date_string())
	_report("yearturn.old-use-is-free", not DowntimeDatabase.is_on_cooldown(uid, "gossip", "drinking"), "")
	_report("yearturn.old-index-blocked-it",
		_old_index(1, 0, 1946) - _old_index(20, 10, 1946) < DowntimeDatabase.COOLDOWN_DAYS,
		str(_old_index(1, 0, 1946) - _old_index(20, 10, 1946)))

	# Pruning keeps only what is still cooling.
	DowntimeDatabase.mark_used(uid, "hangover", "drinking")
	var bucket: Array = game.downtime_recent_events.get(uid, [])
	_report("yearturn.prune-drops-expired", bucket.size() == 1 and String(bucket[0].get("result_id", "")) == "drinking:hangover"
		and int(bucket[0].get("day", -1)) == TimeManager.today(), str(bucket))
	game.downtime_recent_events.erase(uid)


# --- 3. Training -------------------------------------------------------------------

func _case_training_exempt() -> void:
	var c := Node.new()
	c.set_meta("template_id", "r4_trainee")
	add_child(c)
	var uid := DowntimeDatabase.character_uid(c)
	game.downtime_recent_events.erase(uid)
	_set_date(34, 10, 1946)
	var activity := {"results": {"any_map": {"only": {"weight": 1}}}}
	DowntimeDatabase.mark_used(uid, "only", "r4_act")
	var picked: Dictionary = DowntimeDatabase.pick_result(activity, "", c, 1, "r4_act")
	_report("training.ordinary-activity-cooling", picked.is_empty() and DowntimeDatabase.last_empty_reason == "cooldown",
		DowntimeDatabase.last_empty_reason)
	activity["requires_training"] = true
	picked = DowntimeDatabase.pick_result(activity, "", c, 1, "r4_act")
	_report("training.exempt", String(picked.get("id", "")) == "only", str(picked))
	# Across Yearturn the training outcome still repeats day after day.
	var repeats := 0
	for i in range(4):
		TimeManager.advance_days(1)
		DowntimeDatabase.mark_used(uid, "only", "r4_act")
		if String(DowntimeDatabase.pick_result(activity, "", c, 1, "r4_act").get("id", "")) == "only":
			repeats += 1
	_report("training.exempt-through-yearturn", repeats == 4 and TimeManager.is_yearturn, "%d %s" % [repeats, TimeManager.get_date_string()])
	_report("training.cooldown-line-says-7-days",
		DowntimeResolver._cooldown_reason_text().contains("refresh after 7 days"), DowntimeResolver._cooldown_reason_text())
	game.downtime_recent_events.erase(uid)
	c.queue_free()


# --- 4. old saves --------------------------------------------------------------------

func _case_old_save_migrated() -> void:
	var d: Dictionary = game.build_save_dict()
	# Saved on Frostiem 2, 1946, 500 days into the game.
	d["date"] = [2, 1, 1946]
	d["days_elapsed"] = 500
	d["downtime_recent_events"] = {
		"r4_old": [
			# 3 days before, across New Year: the old index said 15.
			{"result_id": "drinking:hangover", "day_abs": _old_index(35, 10, 1945)},
			# Yesterday.
			{"result_id": "drinking:belligerent", "day_abs": _old_index(1, 1, 1946)},
			# No date has this index (25-36 past a year boundary).
			{"result_id": "drinking:gossip", "day_abs": 1946 * 372 + 30},
			# After the save's own date.
			{"result_id": "carousing:quiet_night", "day_abs": _old_index(5, 1, 1946)},
			# Not a number.
			{"result_id": "watch:close_call", "day_abs": "soon"},
			# Long over: nothing to keep.
			{"result_id": "carousing:brawl", "day_abs": _old_index(1, 3, 1945)},
		],
		"r4_empty": [],
	}
	game.apply_save_dict(d)
	var bucket: Array = game.downtime_recent_events.get("r4_old", [])
	var want := [
		{"result_id": "drinking:hangover", "day": 497},
		{"result_id": "drinking:belligerent", "day": 499},
	]
	_report("migrate.converted-through-calendar", var_to_str(bucket) == var_to_str(want), str(bucket))
	_report("migrate.unreadable-dropped", bucket.size() == 2, "kept %d of 6" % bucket.size())
	_report("migrate.empty-bucket-kept", game.downtime_recent_events.get("r4_empty", null) == [], "")
	_report("migrate.date-restored-first", TimeManager.today() == 500 and TimeManager.current_day == 2, TimeManager.get_date_string())
	_report("migrate.hangover-still-cooling", DowntimeDatabase.is_on_cooldown("r4_old", "hangover", "drinking"), "")
	# The old code compared old indexes directly: Frostiem 2 minus Mistumnal 35.
	_report("migrate.old-code-had-freed-it", _old_index(2, 1, 1946) - _old_index(35, 10, 1945) >= DowntimeDatabase.COOLDOWN_DAYS,
		str(_old_index(2, 1, 1946) - _old_index(35, 10, 1945)))
	_report("migrate.dropped-ones-free", not DowntimeDatabase.is_on_cooldown("r4_old", "gossip", "drinking")
		and not DowntimeDatabase.is_on_cooldown("r4_old", "quiet_night", "carousing"), "")
	TimeManager.advance_days(4)
	_report("migrate.hangover-free-on-day-7", not DowntimeDatabase.is_on_cooldown("r4_old", "hangover", "drinking")
		and DowntimeDatabase.is_on_cooldown("r4_old", "belligerent", "drinking"), TimeManager.get_date_string())
	TimeManager.advance_days(2)
	_report("migrate.belligerent-free-on-day-7", not DowntimeDatabase.is_on_cooldown("r4_old", "belligerent", "drinking"), "")
	game.downtime_recent_events.erase("r4_old")
	game.downtime_recent_events.erase("r4_empty")


func _case_yearturn_save_migrated() -> void:
	# Yearturn 1 and Mistumnal 13 of the year before share an old index; the
	# recent one is meant.
	_report("migrate-yt.index-is-ambiguous", _old_index(1, 0, 1946) == _old_index(13, 10, 1945), "")
	var d: Dictionary = game.build_save_dict()
	d["date"] = [3, 0, 1946]
	d["days_elapsed"] = 800
	d["downtime_recent_events"] = {
		"r4_yt": [
			{"result_id": "drinking:hangover", "day_abs": _old_index(1, 0, 1946)},
			{"result_id": "drinking:belligerent", "day_abs": _old_index(34, 10, 1946)},
			# A JSON-loaded save has floats.
			{"result_id": "drinking:gossip", "day_abs": float(_old_index(2, 0, 1946))},
		],
	}
	game.apply_save_dict(d)
	var bucket: Array = game.downtime_recent_events.get("r4_yt", [])
	var want := [
		{"result_id": "drinking:hangover", "day": 798},
		{"result_id": "drinking:belligerent", "day": 795},
		{"result_id": "drinking:gossip", "day": 799},
	]
	_report("migrate-yt.yearturn-entries-dated", var_to_str(bucket) == var_to_str(want), str(bucket))
	_report("migrate-yt.is-yearturn", TimeManager.is_yearturn, TimeManager.get_date_string())
	game.downtime_recent_events.erase("r4_yt")


# --- 5. round trip ----------------------------------------------------------------------

func _case_round_trip() -> void:
	game.downtime_recent_events.erase("r4_trip")
	_set_date(35, 10, 1946)
	DowntimeDatabase.mark_used("r4_trip", "hangover", "drinking")
	TimeManager.advance_days(2)
	DowntimeDatabase.mark_used("r4_trip", "quiet_night", "carousing")
	var first: Dictionary = game.build_save_dict()
	var before := var_to_str(game.downtime_recent_events)
	game.apply_save_dict(first)
	var second: Dictionary = game.build_save_dict()
	_report("round-trip.unchanged", var_to_str(game.downtime_recent_events) == before, str(game.downtime_recent_events.get("r4_trip")))
	_report("round-trip.f11-byte-identical", JSON.stringify(first) == JSON.stringify(second), "")

	# Through JSON (numbers come back as floats): untouched, still cooling.
	var third: Dictionary = game.build_save_dict()
	third["downtime_recent_events"] = JSON.parse_string(JSON.stringify(third["downtime_recent_events"]))
	var json_before := JSON.stringify(third["downtime_recent_events"])
	game.apply_save_dict(third)
	_report("round-trip.json-unchanged", JSON.stringify(game.downtime_recent_events) == json_before, json_before)
	_report("round-trip.json-still-cooling", DowntimeDatabase.is_on_cooldown("r4_trip", "hangover", "drinking")
		and DowntimeDatabase.is_on_cooldown("r4_trip", "quiet_night", "carousing"), "")
	TimeManager.advance_days(5)
	_report("round-trip.json-frees-on-day-7", not DowntimeDatabase.is_on_cooldown("r4_trip", "hangover", "drinking")
		and DowntimeDatabase.is_on_cooldown("r4_trip", "quiet_night", "carousing"), TimeManager.get_date_string())
	game.downtime_recent_events.erase("r4_trip")


# --- 6. the same fault elsewhere ----------------------------------------------------------

func _case_quest_days() -> void:
	var qm = QuestManager
	var s := func(y: int, m: int, dd: int) -> int: return qm._today_stamp_from(y, m, dd)
	_report("quest-days.same-month", qm._days_between(s.call(1945, 3, 5), s.call(1945, 3, 9)) == 4, "")
	_report("quest-days.month-end", qm._days_between(s.call(1945, 2, 36), s.call(1945, 3, 1)) == 1, "")
	_report("quest-days.common-new-year", qm._days_between(s.call(1945, 10, 30), s.call(1946, 1, 1)) == 7, "")
	_report("quest-days.into-yearturn", qm._days_between(s.call(1946, 10, 30), s.call(1946, 0, 2)) == 8,
		str(qm._days_between(s.call(1946, 10, 30), s.call(1946, 0, 2))))
	_report("quest-days.through-yearturn", qm._days_between(s.call(1946, 10, 30), s.call(1947, 1, 1)) == 19,
		str(qm._days_between(s.call(1946, 10, 30), s.call(1947, 1, 1))))
	# Against the live clock.
	_set_date(30, 10, 1946)
	var start: int = qm._today_stamp()
	TimeManager.advance_days(19)
	_report("quest-days.live-through-yearturn", qm._days_between(start, qm._today_stamp()) == 19, TimeManager.get_date_string())


func _case_scheduled_dialogue() -> void:
	var sched = EventScheduler
	var real_dialogue = sched._dialogue
	var stub := StubDialogue.new()
	add_child(stub)
	sched._dialogue = stub
	var daily := {"id": "r4_daily_probe", "dialogue": "r4_probe", "when": {"hour": 22, "minute": 0},
		"recurrence": "daily", "scope": "global"}

	# A daily trigger fires on Mistumnal 36 and keeps firing through Yearturn.
	_set_date(36, 10, 1946)
	sched._maybe_fire(daily, 22, 0, sched._today_stamp(), sched.GLOBAL_KEY)
	sched._maybe_fire(daily, 22, 0, sched._today_stamp(), sched.GLOBAL_KEY)
	_report("schedule.daily-once-a-day", stub.started.size() == 1, str(stub.started.size()))
	for i in range(3):
		TimeManager.advance_days(1)
		sched._maybe_fire(daily, 22, 0, sched._today_stamp(), sched.GLOBAL_KEY)
	_report("schedule.daily-through-yearturn", stub.started.size() == 4 and TimeManager.is_yearturn,
		"%d %s" % [stub.started.size(), TimeManager.get_date_string()])

	# every_days 3 across a month end: not before the third day.
	stub.started.clear()
	var every3 := {"id": "r4_every3_probe", "dialogue": "r4_probe", "when": {"hour": 22, "minute": 0},
		"recurrence": {"every_days": 3}, "scope": "global"}
	_set_date(35, 2, 1946)
	var fired: Array = []
	for i in range(4):
		var before := stub.started.size()
		sched._maybe_fire(every3, 22, 0, sched._today_stamp(), sched.GLOBAL_KEY)
		fired.append(stub.started.size() > before)
		TimeManager.advance_days(1)
	_report("schedule.every-3-days-across-month-end", fired == [true, false, false, true], str(fired))

	# A map-scoped trigger (the documented {"map": id} scope) is checked
	# without a script error, and fires only on its own map.
	stub.started.clear()
	var real_map: String = sched._current_map_id
	var on_map := {"id": "r4_map_probe", "dialogue": "r4_probe", "when": {"hour": 22, "minute": 0},
		"recurrence": "daily", "scope": {"map": "r4_probe_map"}}
	sched._current_map_id = "r4_other_map"
	sched._maybe_fire(on_map, 22, 0, sched._today_stamp(), sched._current_map_id)
	var off_map_quiet: bool = stub.started.is_empty()
	sched._current_map_id = "r4_probe_map"
	sched._maybe_fire(on_map, 22, 0, sched._today_stamp(), sched._current_map_id)
	_report("schedule.map-scope-checked", off_map_quiet and stub.started.size() == 1, str(stub.started.size()))
	sched._current_map_id = real_map

	sched._last_fired_day.erase(sched.GLOBAL_KEY + "::r4_daily_probe")
	sched._last_fired_day.erase(sched.GLOBAL_KEY + "::r4_every3_probe")
	sched._last_fired_day.erase("r4_probe_map::r4_map_probe")
	sched._dialogue = real_dialogue
	stub.queue_free()
