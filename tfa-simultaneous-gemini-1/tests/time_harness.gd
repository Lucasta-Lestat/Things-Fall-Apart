# res://tests/time_harness.gd
# Headless assertion harness for Phase 2 — calendar time
# (docs/law_crime_stealth_plan.md). Locks down:
#   1. TimeManager.days_elapsed / absolute_time(): counted once per day change
#      (advance_days is the single funnel), continuous across the midnight
#      wrap of game_time, independent of set_time/direct game_time mutation.
#   2. Conditions on the absolute clock: multi-day durations survive day
#      boundaries and expire on schedule; cross-midnight expiry works; the
#      periodic save interval fires across a day boundary.
#   3. apply_condition's duration_override is honored on FRESH instances
#      (the instance.apply() re-stamp clobbered it before Phase 2).
#   4. ConditionManager.to_dict/from_dict round-trips expires_at byte-for-byte
#      and re-grants condition-bestowed abilities exactly once (dedup guard).
# Run:  godot --headless --path . res://tests/time_harness.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

const DAY: float = 86400.0

var failures := 0

class StubAbility:
	extends RefCounted
	var ability_id: String = ""
	func _init(id: String) -> void:
		ability_id = id

class StubInventory:
	extends Node
	var stowed_items: Array = []
	var equipped_weapons: Array = []
	func add_ability_by_id(id: String, _hand: String = "Main") -> bool:
		stowed_items.append(StubAbility.new(id))
		return true

class StubCharacter:
	extends Node2D
	var save_calls: int = 0
	func saving_throw(_stat: String, _bonus: int = 0) -> int:
		save_calls += 1
		return 0

func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])

var cm: ConditionManager
var stub: StubCharacter

func _ready() -> void:
	add_to_group("game")
	# Freeze the background clock: everything below drives TimeManager by hand.
	TimeManager.pause_time()

	stub = StubCharacter.new()
	add_child(stub)
	var inv := StubInventory.new()
	inv.name = "Inventory"
	stub.add_child(inv)
	cm = ConditionManager.new()
	stub.add_child(cm)
	cm.character = stub
	# _process is engine-ticked too; harmless, but all assertions drive it
	# manually so ordering is deterministic.
	_register_synthetics()

	_case_day_counter()
	_case_rollover_continuity()
	_case_multi_day_condition()
	_case_override_honored()
	_case_cross_midnight_expiry()
	_case_periodic_save_across_boundary()
	_case_remaining_duration()
	_case_round_trip_and_regrant()

	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _register_synthetics() -> void:
	# traits MUST be a Dictionary: apply_condition's fear-bonus line calls
	# template.traits.get("fear", 0), which is a crash on the Array default.
	for data in [
		{"id": "test_three_day", "display_name": "3d", "duration": 259200.0, "traits": {}},
		{"id": "test_perm_tpl", "display_name": "perm", "duration": -1.0, "traits": {}},
		{"id": "test_timed_tpl", "display_name": "50s", "duration": 50.0, "traits": {}},
		{"id": "test_four_hour", "display_name": "4h", "duration": 14400.0, "traits": {}},
		{"id": "test_save", "display_name": "save", "duration": -1.0, "traits": {},
			"save_stat": "will", "save_interval": 30000.0},
		{"id": "test_grant", "display_name": "grant", "duration": -1.0, "traits": {},
			"grants_ability": "test_granted_ability"},
	]:
		cm.register_condition(Condition.create_from_data(data))

func _case_day_counter() -> void:
	var t0: float = TimeManager.absolute_time()
	var d0: int = TimeManager.today()
	TimeManager.advance_days(3)
	var t1: float = TimeManager.absolute_time()
	_check("time.advance-days-counted-once", absf((t1 - t0) - 3.0 * DAY) < 0.001,
		"delta=%f" % (t1 - t0))
	_check("time.today-advanced", TimeManager.today() == d0 + 3,
		"today=%d d0=%d" % [TimeManager.today(), d0])

func _case_rollover_continuity() -> void:
	# Mirror DowntimeResolver's idiom: mutate game_time directly, let
	# _process wrap it. No engine frame runs between these lines.
	TimeManager.game_time = DAY - 1.0
	var a0: float = TimeManager.absolute_time()
	var d0: int = TimeManager.today()
	TimeManager.resume_time()
	TimeManager._process(2.0)
	TimeManager.pause_time()
	var a1: float = TimeManager.absolute_time()
	_check("time.rollover-continuous", absf((a1 - a0) - 2.0) < 0.01,
		"a1-a0=%f" % (a1 - a0))
	_check("time.rollover-wrapped", TimeManager.game_time < DAY,
		"game_time=%f" % TimeManager.game_time)
	_check("time.rollover-day-counted", TimeManager.today() == d0 + 1)

func _case_multi_day_condition() -> void:
	var inst: ConditionInstance = cm.apply_condition("test_three_day")
	_check("cond.applied", inst != null)
	TimeManager.advance_days(2)
	cm._process(0.0)
	_check("cond.survives-two-days", cm.has_condition("test_three_day"))
	TimeManager.advance_days(2)
	cm._process(0.0)
	_check("cond.expired-after-four", not cm.has_condition("test_three_day"))

func _case_override_honored() -> void:
	var now: float = TimeManager.absolute_time()
	var a: ConditionInstance = cm.apply_condition("test_perm_tpl", null, 1, 100.0)
	_check("override.timed-on-permanent-template",
		a != null and a.expires_at > 0.0 and absf(a.expires_at - (now + 100.0)) < 0.01,
		"expires_at=%f now=%f" % [a.expires_at if a else -999.0, now])
	var b: ConditionInstance = cm.apply_condition("test_timed_tpl", null, 1, -1.0)
	_check("override.permanent-on-timed-template",
		b != null and b.expires_at == -1.0,
		"expires_at=%f" % (b.expires_at if b else -999.0))
	cm.remove_condition("test_perm_tpl")
	cm.remove_condition("test_timed_tpl")

func _case_cross_midnight_expiry() -> void:
	# 23:00, apply a 4-hour buff, jump 8 hours (downtime idiom) across midnight.
	TimeManager.game_time = 23.0 * 3600.0
	var inst: ConditionInstance = cm.apply_condition("test_four_hour")
	_check("midnight.applied", inst != null)
	TimeManager.game_time += 8.0 * 3600.0
	TimeManager.resume_time()
	TimeManager._process(0.0)
	TimeManager.pause_time()
	cm._process(0.0)
	_check("midnight.expired-across-boundary", not cm.has_condition("test_four_hour"))

func _case_periodic_save_across_boundary() -> void:
	var inst: ConditionInstance = cm.apply_condition("test_save")
	_check("save.applied", inst != null)
	var calls_before: int = stub.save_calls
	TimeManager.advance_days(1)
	cm._process(0.0)
	_check("save.fires-across-day-boundary", stub.save_calls == calls_before + 1,
		"calls before=%d after=%d" % [calls_before, stub.save_calls])
	cm.remove_condition("test_save")

func _case_remaining_duration() -> void:
	var inst: ConditionInstance = cm.apply_condition("test_four_hour")
	var remaining: float = inst.get_remaining_duration(TimeManager.absolute_time())
	_check("remaining.sane-after-rollovers",
		remaining > 14399.0 and remaining <= 14400.0,
		"remaining=%f" % remaining)
	cm.remove_condition("test_four_hour")

func _case_round_trip_and_regrant() -> void:
	var inv: StubInventory = stub.get_node("Inventory")
	var timed: ConditionInstance = cm.apply_condition("test_three_day")
	var granted: ConditionInstance = cm.apply_condition("test_grant")
	_check("rt.applied", timed != null and granted != null)
	_check("rt.grant-on-apply", inv.stowed_items.size() == 1,
		"stowed=%d" % inv.stowed_items.size())
	var expires_before: float = timed.expires_at
	var snapshot: Dictionary = cm.to_dict()
	cm.from_dict(snapshot)
	var restored: ConditionInstance = cm.conditions.get("test_three_day")
	_check("rt.expires-byte-for-byte",
		restored != null and restored.expires_at == expires_before,
		"before=%f after=%f" % [expires_before, restored.expires_at if restored else -999.0])
	_check("rt.regrant-deduped", inv.stowed_items.size() == 1,
		"stowed=%d" % inv.stowed_items.size())
	# Inventory wiped (fresh character on restore) -> regrant refills exactly once.
	inv.stowed_items.clear()
	cm.from_dict(snapshot)
	_check("rt.regrant-refills-empty-inventory", inv.stowed_items.size() == 1,
		"stowed=%d" % inv.stowed_items.size())
