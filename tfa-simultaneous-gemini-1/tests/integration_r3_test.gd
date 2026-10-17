# res://tests/integration_r3_test.gd
# Headless assertion harness for the round-3 integration review. Each lane was
# reviewed alone; these checks cover where two lanes meet:
#   - the game log now starts closed (UI lane), so feedback that only went to
#     the log must also float over someone: refused pick-ups and loot, crimes,
#     quest news, dialogue skill checks, a faction turning on the party
#     (dialogue lane), companions' conditions running out inside the world-map
#     banner (travel lane), a training drop with no teacher (Unavailable
#     dialog);
#   - a plan paused by a stun (casting-plans lane) names the stun on its badge,
#     so it doesn't read as the game's own pause (PAUSED banner, UI lane).
# Drives the real game scene the way ui_r3_test does.
# Run:  godot --headless --path . res://tests/integration_r3_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

var failures := 0
var game = null

func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])

func _await_frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

func _ready() -> void:
	TimeManager.pause_time()
	await get_tree().process_frame
	var GameScene := load("res://game.tscn")
	game = GameScene.instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _await_frames(2)
	game.load_map("town_square")
	await _await_frames(10)
	PauseManager.is_paused = false

	_check("setup.party", game.party_chars.size() >= 2, str(game.party_chars.size()))
	if game.party_chars.size() >= 2:
		_case_log_starts_closed()
		await _case_pickup_too_far()
		await _case_dialogue_check()
		await _case_quest_news()
		await _case_relation_float()
		await _case_banner_companion()
		await _case_training_unavailable()
		await _case_pause_badge_cause()
		await _case_companion_downtime()
		# Last: a crime sets witnesses running, then the party settles.
		await _case_crime_float()
		await _case_settlement_float()

	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

# --- helpers ---------------------------------------------------------------

func _log_size() -> int:
	return GameLog.get_entries().size()

func _lines_since(n0: int) -> Array:
	var out := []
	for e in GameLog.get_entries().slice(n0):
		out.append(str(e.text))
	return out

## FloatingText labels anywhere in the tree whose text is `text` (or, with
## `prefix`, starts with it).
func _floats_with(text: String, prefix: bool = false) -> int:
	return _count_labels(get_tree().root, text, prefix)

func _count_labels(node: Node, text: String, prefix: bool) -> int:
	var n := 0
	for c in node.get_children():
		if c is Label and c.get_script() != null and str(c.get_script().resource_path).ends_with("FloatingText.gd"):
			var t: String = (c as Label).text
			if t == text or (prefix and t.begins_with(text)):
				n += 1
		n += _count_labels(c, text, prefix)
	return n

# --- cases -------------------------------------------------------------------

func _case_log_starts_closed() -> void:
	var log_panel = game.get_node_or_null("GameUI/LogPanel")
	_check("log.starts-closed", log_panel != null and not log_panel.is_open(), "the premise of this harness")

func _case_pickup_too_far() -> void:
	var p0 = game.party_chars[0]
	game.primary_selected = p0
	var item = game.create_item("apple", p0.global_position + Vector2(1500, 0), 1)
	await _await_frames(2)
	var n0 := _log_size()
	var before := _floats_with("Too far")
	var ok: bool = game.pick_up_item(item)
	_check("pickup.too-far-refused", not ok)
	_check("pickup.too-far-floats", _floats_with("Too far") == before + 1, str(_floats_with("Too far")))
	_check("pickup.too-far-logged", _lines_since(n0).has("%s is too far away to reach that." % p0.Name), str(_lines_since(n0)))
	if is_instance_valid(item):
		item.queue_free()

func _case_dialogue_check() -> void:
	var p0 = game.party_chars[0]
	var n0 := _log_size()
	DialogueManager._log_ability_check(p0, ["charisma"], 1)
	DialogueManager._log_ability_check(p0, ["charisma"], 0)
	_check("check.pass-floats", _floats_with("Charisma passed") >= 1)
	_check("check.fail-floats", _floats_with("Charisma failed") >= 1)
	var lines := _lines_since(n0)
	_check("check.both-logged", lines.size() == 2 and str(lines[0]).contains("passes a Charisma check") \
		and str(lines[1]).contains("fails a Charisma check"), str(lines))

func _case_quest_news() -> void:
	var qid := ""
	for id in QuestDatabase.get_all_quest_ids():
		if not QuestManager.active.has(id) and not id in QuestManager.completed and not id in QuestManager.failed:
			qid = str(id)
			break
	_check("quest.found-one", qid != "")
	if qid == "":
		return
	var qname := str(QuestDatabase.get_quest(qid).get("display_name", qid))
	var n0 := _log_size()
	QuestManager.start_quest(qid)
	_check("quest.started-floats", _floats_with("New quest: " + qname) == 1, qname)
	_check("quest.started-logged", _lines_since(n0).any(func(t): return str(t).begins_with("Quest started: " + qname)), str(_lines_since(n0)))

func _case_relation_float() -> void:
	var n0 := _log_size()
	var api = DialogueManager.actions_api
	api.run_list([{"type": "set_relation", "faction": "player", "other": "liziti", "relation": "ally"}], "integration")
	var fname: String = str(FactionDatabase.get_faction_data("liziti").get("name", "liziti"))
	_check("relation.floats", _floats_with("%s: ally" % fname) == 1, fname)
	_check("relation.logged", _lines_since(n0).has("%s now counts you as an ally." % fname), str(_lines_since(n0)))
	api.run_list([{"type": "set_relation", "faction": "player", "other": "liziti", "relation": "neutral"}], "integration")

func _case_banner_companion() -> void:
	# A companion folded into the world-map banner has only a snapshot: its
	# Hungover running out must float over the banner, not just log.
	var now: float = TimeManager.absolute_time()
	var row := {"template_id": "harness_bo", "live_state": {"Name": "Harness Bo", "current_health": 20,
		"condition_state": {"conditions": {"hungover": {"condition_id": "hungover", "expires_at": now - 1.0}}}}}
	game.party_state.append(row)
	var n0 := _log_size()
	game._banner_conditions_wait = 0.0
	game._tick_banner_party_conditions(0.0)
	game.party_state.erase(row)
	_check("banner.companion-logged", _lines_since(n0).has("Harness Bo is no longer Hungover."), str(_lines_since(n0)))
	_check("banner.companion-floats", _floats_with("Harness Bo is no longer Hungover") == 1)

func _case_training_unavailable() -> void:
	var p1 = game.party_chars[1]
	var n0 := _log_size()
	var dialogs_before := _unavailable_dialogs()
	DowntimeResolver.begin_drop(p1, "training", "no_such_region")
	await _await_frames(1)
	_check("training.no-teacher-logged", _lines_since(n0).any(func(t): return str(t).ends_with("has no teacher waiting here.")), str(_lines_since(n0)))
	var dialogs := _unavailable_dialogs()
	_check("training.no-teacher-dialog", dialogs.size() == dialogs_before.size() + 1, str(dialogs.size()))
	for d in dialogs:
		if not d in dialogs_before:
			_check("training.dialog-says-why", str(d.dialog_text).contains("[UNAVAILABLE] No teacher is waiting here"), str(d.dialog_text))
			d.hide()

func _unavailable_dialogs() -> Array:
	var out := []
	for c in get_tree().root.get_children():
		if c is ConfirmationDialog and c.visible and c.get_ok_button().text == "Unavailable":
			out.append(c)
	return out

func _case_pause_badge_cause() -> void:
	var a = game.party_chars[1]
	var pd = a.path_drawer
	_check("badge.plain-without-cause", pd.pause_badge_text() == "Paused", pd.pause_badge_text())
	a.condition_manager.apply_condition("stunned", null, 1, 30.0)
	a.action_queue.queue_attack_target(game.party_chars[0])
	a._update_plan_pause()
	_check("badge.paused", a.is_plan_paused())
	_check("badge.names-cause", pd.pause_badge_text() == "Paused: Stunned", pd.pause_badge_text())
	a.action_queue.cancel_all()
	a.condition_manager.remove_condition("stunned")
	a._update_plan_pause()

func _case_companion_downtime() -> void:
	# Next Day: a companion picks their own downtime and nobody watches; what
	# they did floats over them as well as going in the log.
	var p1 = game.party_chars[1]
	var n0 := _log_size()
	DowntimeResolver.resolve_silently(p1, "meditation", RegionDatabase.get_region_for_map("town_square"))
	_check("downtime.companion-logged", _lines_since(n0).any(func(t): return str(t).contains("(Meditation)")), str(_lines_since(n0)))
	_check("downtime.companion-floats", _floats_with("Meditation", true) >= 1)

func _case_crime_float() -> void:
	var p0 = game.party_chars[0]
	var n0 := _log_size()
	var verdict: Dictionary = CrimeManager.accuse(p0, "murder", [], "")
	_check("crime.accused", not verdict.is_empty(), "murder is a crime under Liziti custom")
	if verdict.is_empty():
		return
	var crime := str(verdict.get("display_name", ""))
	_check("crime.floats", _floats_with("Crime: " + crime) == 1, crime)
	_check("crime.logged", _lines_since(n0).any(func(t): return str(t).begins_with("%s commits %s" % [p0.Name, crime])), str(_lines_since(n0)))

func _case_settlement_float() -> void:
	var n0 := _log_size()
	CrimeManager.settle_with("liziti", "pay_fine")
	var lname: String = str(FactionDatabase.get_faction_data("liziti").get("name", "liziti"))
	_check("settle.logged", _lines_since(n0).has("You are square with liziti. Nobody has forgotten."), str(_lines_since(n0)))
	_check("settle.floats", _floats_with("Square with " + lname) == 1, lname)
