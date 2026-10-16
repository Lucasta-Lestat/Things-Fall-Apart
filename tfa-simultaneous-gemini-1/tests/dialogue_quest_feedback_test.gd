# res://tests/dialogue_quest_feedback_test.gd
# Headless harness for dialogue, quest-log and readable feedback.
#
# The contract under test:
#   (1) a dialogue whose start node isn't named after it starts at its first
#       authored node; a dialogue that can't start never leaves the manager
#       "active" (which queued every later dialogue forever),
#   (2) a missing next/branch target ends the conversation instead of
#       soft-locking the panel,
#   (3) repeated speaker lines ("Name#2") play in authored order, and every
#       next/nextNode/branch target in Dialogues.json resolves,
#   (4) quoted literals and list literals parse, so checks and quest
#       predicates get their real arguments; [[protagonist.name]] shows the
#       display name; inline [[...(...)]] actions are dropped, not shown,
#   (5) a critical-failure check (-1) and a call that can't be made both fail
#       the branch, and a dialogue check is logged with roll vs target,
#   (6) speakers resolve to in-scene characters ("narrator" has no label),
#   (7) the panel: SPACE advances without toggling pause, the continue prompt
#       always shows, an empty speaker label hides,
#   (8) the quest log: a deadline's days left, the failure reason, a failed
#       quest's checklist, and the J hints in the log lines,
#   (9) the cemetery's DEMO dialogues and the test elf are gone.
#
# Run:  godot --headless --path . res://tests/dialogue_quest_feedback_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const PANEL_SCRIPT := preload("res://dialogue_panel.gd")
const QUEST_LOG_SCRIPT := preload("res://UI/QuestLogPanel.gd")

var _fails := 0
var _checks := 0
var game: Node = null
var player = null


class StubGame:
	extends Node
	var player = null
	var characters_in_scene: Array = []
	var party_chars: Array = []
	var party_state: Array = []
	func get_party() -> Array:
		return party_chars


class CheckStub:
	extends Node
	var next_result = 1
	func ability_check(_stat, _domain = null):
		return next_result


func _ready() -> void:
	TimeManager.pause_time()
	await get_tree().process_frame
	# DialogueManager reads /root/Game; a stub keeps this harness about the
	# dialogue layer rather than map loading.
	game = StubGame.new()
	game.name = "Game"
	get_tree().root.add_child(game)
	player = CHAR_SCENE.instantiate()
	player.display_name = "Mira Vell"
	player.Name = "Mira Vell"
	player.is_protagonist = true
	game.add_child(player)
	game.player = player
	game.characters_in_scene = [player]
	game.party_chars = [player]
	await get_tree().process_frame

	_case_data_integrity()
	_case_start_nodes()
	await _case_cannot_start()
	await _case_missing_node()
	_case_repeated_speakers()
	_case_args_and_substitution()
	_case_condition_results()
	_case_speakers()
	_case_ally_reactions()
	await _case_panel()
	_case_quest_deadline_and_failure()
	_case_quest_and_note_hints()
	_case_cemetery_demo_gone()

	print("HARNESS DONE failures=%d checks=%d" % [_fails, _checks])
	get_tree().quit(1 if _fails > 0 else 0)


func _report(check_name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("%s %s: %s" % ["PASS" if ok else "FAIL", check_name, detail])


func _log_texts_since(n: int) -> Array:
	var out: Array = []
	var entries: Array = GameLog.get_entries()
	for i in range(n, entries.size()):
		out.append(str(entries[i].get("text", "")))
	return out


func _reset_dialogue() -> void:
	DialogueManager._pending_dialogues.clear()
	if DialogueManager.is_active():
		DialogueManager.end_dialogue()
	DialogueManager._pending_dialogues.clear()


# --- 3b. every target resolves ----------------------------------------------

func _case_data_integrity() -> void:
	var missing: Array = []
	var non_string: Array = []
	for did in DialogueManager.dialogues:
		var nodes: Dictionary = DialogueManager.dialogues[did].get("dialogueNodes", {})
		for nid in nodes:
			var node: Dictionary = nodes[nid]
			var targets: Array = []
			if node.has("next"):
				targets.append(node["next"])
			if node.has("nextNode"):
				missing.append("%s/%s node-level nextNode" % [did, nid])
			if node.get("branch") is Dictionary:
				targets.append_array(node["branch"].values())
			for c in node.get("choices", []):
				if str(c.get("nextNode", "")) != "":
					targets.append(c["nextNode"])
				if c.get("branch") is Dictionary:
					targets.append_array(c["branch"].values())
			for t in targets:
				if not nodes.has(str(t)):
					missing.append("%s/%s -> %s" % [did, nid, t])
			for k in node:
				if not (k in DialogueManager.RESERVED_KEYS) and not (node[k] is String):
					non_string.append("%s/%s/%s" % [did, nid, k])
	_report("data.every-target-resolves", missing.is_empty(), str(missing))
	_report("data.no-misspelled-reserved-keys", non_string.is_empty(), str(non_string))
	var text: String = FileAccess.get_file_as_string("res://data/Dialogues.json")
	_report("data.no-game-protagonist-path", not text.contains("game.protagonist"), "")


# --- 1. start nodes -----------------------------------------------------------

func _case_start_nodes() -> void:
	_reset_dialogue()
	DialogueManager.start_dialogue("Federica_greet")
	_report("start.first-authored-node", DialogueManager.is_active() and DialogueManager.current_node_id == "Federica_intro",
		DialogueManager.current_node_id)
	_reset_dialogue()
	DialogueManager.start_dialogue("Jacana_greet")
	_report("start.named-node", DialogueManager.current_node_id == "Jacana_greet", DialogueManager.current_node_id)
	_reset_dialogue()


func _case_cannot_start() -> void:
	_reset_dialogue()
	DialogueManager.dialogues["test_empty_dialogue"] = {"dialogueNodes": {}}
	var n0: int = GameLog.get_entries().size()
	DialogueManager.start_dialogue("test_empty_dialogue", "Test Elf")
	_report("start.empty-not-active", not DialogueManager.is_active(), DialogueManager.current_dialogue_id)
	_report("start.empty-says-nothing-to-say", "Test Elf has nothing to say." in _log_texts_since(n0), str(_log_texts_since(n0)))
	DialogueManager.start_dialogue("test_no_such_dialogue")
	_report("start.unknown-not-active", not DialogueManager.is_active(), "")
	# The queue still works afterwards.
	DialogueManager.start_dialogue("Jacana_greet")
	_report("start.later-dialogue-plays", DialogueManager.is_active() and DialogueManager.current_dialogue_id == "Jacana_greet",
		DialogueManager.current_dialogue_id)
	DialogueManager.dialogues.erase("test_empty_dialogue")
	_reset_dialogue()
	await get_tree().process_frame


# --- 2. missing node ------------------------------------------------------------

func _case_missing_node() -> void:
	_reset_dialogue()
	DialogueManager.dialogues["test_dangling"] = {"dialogueNodes": {"test_dangling": {"narrator": "One line.", "next": "nowhere"}}}
	var ended := [0]
	var cb := func(): ended[0] += 1
	DialogueManager.dialogue_ended.connect(cb)
	DialogueManager.start_dialogue("test_dangling")
	DialogueManager.start_dialogue("Jacana_greet")   # queued behind it
	var n0: int = GameLog.get_entries().size()
	DialogueManager.advance_line()
	_report("missing.ends-dialogue", ended[0] == 1 and DialogueManager.current_dialogue_id != "test_dangling",
		"ended %d, current %s" % [ended[0], DialogueManager.current_dialogue_id])
	_report("missing.trails-off-logged", "[i]The conversation trails off.[/i]" in _log_texts_since(n0), str(_log_texts_since(n0)))
	await get_tree().process_frame
	_report("missing.queue-flushed", DialogueManager.current_dialogue_id == "Jacana_greet", DialogueManager.current_dialogue_id)
	DialogueManager.dialogue_ended.disconnect(cb)
	DialogueManager.dialogues.erase("test_dangling")
	_reset_dialogue()
	# advance_line with nothing playing is a no-op, not a crash.
	DialogueManager.advance_line()
	_report("missing.advance-when-idle", not DialogueManager.is_active(), "")


# --- 3. repeated speakers -------------------------------------------------------

func _case_repeated_speakers() -> void:
	_reset_dialogue()
	DialogueManager.start_dialogue("Zak_greet")
	var speakers: Array = []
	for l in DialogueManager.current_node_lines:
		speakers.append(l["speaker"])
	_report("lines.all-restored", speakers == ["Narrator", "Jacana", "ZAKARIAH", "ZAKARIAH", "Jacana"], str(speakers))
	_reset_dialogue()

	DialogueManager.dialogues["test_nonstring"] = {"dialogueNodes": {"test_nonstring": {"guard": "Hm.", "choice": [{"text": "x"}]}}}
	DialogueManager.start_dialogue("test_nonstring")
	_report("lines.non-string-skipped", DialogueManager.current_node_lines.size() == 1, str(DialogueManager.current_node_lines))
	DialogueManager.dialogues.erase("test_nonstring")
	_reset_dialogue()


# --- 4. arguments and substitution ---------------------------------------------

func _case_args_and_substitution() -> void:
	var args: Array = DialogueManager.parse_function_args("'charisma', ['secular', 'occult', 'persuasive']")
	_report("args.quoted-and-list", args == ["charisma", ["secular", "occult", "persuasive"]], str(args))
	var q_args: Array = DialogueManager.parse_function_args("'guild_bounty_bandit_chief', protagonist")
	_report("args.quest-id-and-object", q_args.size() == 2 and q_args[0] == "guild_bounty_bandit_chief" and q_args[1] == player,
		str(q_args))
	var named: String = DialogueManager.substitute_variables("My name is [[protagonist.name]].")
	_report("subst.protagonist-name", named == "My name is Mira Vell.", named)
	var stripped: String = DialogueManager.substitute_variables("Torchlight. [[spawn_character_from_name('golden_guard',4)]]")
	_report("subst.action-token-dropped", stripped == "Torchlight. ", stripped)


# --- 5. condition results --------------------------------------------------------

func _case_condition_results() -> void:
	var stub := CheckStub.new()
	stub.name = "TestCheckStub"
	get_tree().root.add_child(stub)
	stub.next_result = -1
	_report("cond.crit-fail-fails", not DialogueManager.evaluate_condition("TestCheckStub.ability_check('charisma', 15)"), "")
	stub.next_result = 0
	_report("cond.fail-fails", not DialogueManager.evaluate_condition("TestCheckStub.ability_check('charisma', 15)"), "")
	stub.next_result = 2
	_report("cond.success-passes", DialogueManager.evaluate_condition("TestCheckStub.ability_check('charisma', 15)"), "")
	_report("cond.unresolvable-fails", not DialogueManager.evaluate_condition("NoSuchRoot.ability_check('charisma', 15)"), "")
	stub.queue_free()
	_report("cond.quest-predicate-real-id", DialogueManager.evaluate_condition("QuestManager.is_quest_active('tutorial_quest')")
		== QuestManager.is_quest_active("tutorial_quest"), "")

	var n0: int = GameLog.get_entries().size()
	DialogueManager.evaluate_condition("protagonist.ability_check('charisma', ['secular', 'occult', 'persuasive'])")
	var logged := false
	for t in _log_texts_since(n0):
		if str(t).begins_with("Mira Vell ") and str(t).contains(" a Charisma check (rolled ") and str(t).contains(" vs "):
			logged = true
	_report("cond.check-logged-with-roll", logged, str(_log_texts_since(n0)))


# --- 6. speakers -------------------------------------------------------------------

func _case_speakers() -> void:
	_report("speaker.narrator-unlabelled", DialogueManager._resolve_speaker_name("narrator") == ""
		and DialogueManager._resolve_speaker_name("Narrator") == "", "")
	_report("speaker.protagonist-named", DialogueManager._resolve_speaker_name("Protagonist") == "Mira Vell",
		DialogueManager._resolve_speaker_name("Protagonist"))
	var fed = CHAR_SCENE.instantiate()
	fed.display_name = "Surgeon Captain Federica"
	fed.template_id = "surgeon_captain_federica"
	game.add_child(fed)
	game.characters_in_scene.append(fed)
	_report("speaker.hyphen-insensitive", DialogueManager._find_speaker_character("Surgeon-Captain Federica") == fed, "")
	_report("speaker.unknown-kept", DialogueManager._resolve_speaker_name("THE KNIGHT") == "THE KNIGHT", "")
	var portrait = DialogueManager.get_character_portrait("Surgeon-Captain Federica")
	_report("speaker.portrait-lookup-safe", portrait == null or portrait is Texture2D, str(portrait))
	_report("speaker.no-portrait-for-stranger", DialogueManager.get_character_portrait("THE KNIGHT") == null, "")
	game.characters_in_scene.erase(fed)
	fed.queue_free()


func _case_ally_reactions() -> void:
	var ally = CHAR_SCENE.instantiate()
	ally.display_name = "Djargo"
	ally.is_protagonist = false
	ally.traits["Aggressive"] = 2
	game.add_child(ally)
	game.party_chars.append(ally)
	var reactions: Array = DialogueManager._compute_ally_reactions(["Aggressive"], [])
	_report("allies.party-seen", reactions.size() == 1 and int(reactions[0].get("net_rating", 0)) == 2, str(reactions))
	game.party_chars.erase(ally)
	ally.queue_free()


# --- 7. the panel ---------------------------------------------------------------------

func _build_panel() -> Panel:
	var panel := Panel.new()
	var margin := MarginContainer.new()
	margin.name = "MarginContainer"
	panel.add_child(margin)
	var hbox := HBoxContainer.new()
	hbox.name = "HBoxContainer"
	margin.add_child(hbox)
	var portrait := TextureRect.new()
	portrait.name = "Portrait"
	hbox.add_child(portrait)
	var vbox := VBoxContainer.new()
	vbox.name = "DialogueVBox"
	hbox.add_child(vbox)
	for n in ["TitleLabel", "SpeakerName", "ContinueIndicator"]:
		var l := Label.new()
		l.name = n
		vbox.add_child(l)
	var rtl := RichTextLabel.new()
	rtl.name = "DialogueText"
	vbox.add_child(rtl)
	var choices := VBoxContainer.new()
	choices.name = "ChoicesContainer"
	vbox.add_child(choices)
	panel.set_script(PANEL_SCRIPT)
	return panel


func _case_panel() -> void:
	_reset_dialogue()
	var panel := _build_panel()
	add_child(panel)
	await get_tree().process_frame
	var indicator: Label = panel.get_node("MarginContainer/HBoxContainer/DialogueVBox/ContinueIndicator")
	var speaker: Label = panel.get_node("MarginContainer/HBoxContainer/DialogueVBox/SpeakerName")

	DialogueManager.dialogues["test_panel"] = {"dialogueNodes": {"test_panel": {"narrator": "First.", "guard": "Second."}}}
	DialogueManager.start_dialogue("test_panel")
	_report("panel.shown", panel.visible, "")
	_report("panel.narrator-label-hidden", not speaker.visible, speaker.text)
	_report("panel.prompt-shows", indicator.visible, "")

	var was_paused: bool = PauseManager.is_paused
	var ev := InputEventAction.new()
	ev.action = "pause"
	ev.pressed = true
	Input.parse_input_event(ev)
	await get_tree().process_frame
	await get_tree().process_frame
	_report("panel.space-advances", DialogueManager.current_line_index == 1, str(DialogueManager.current_line_index))
	_report("panel.space-does-not-pause", PauseManager.is_paused == was_paused, "paused %s -> %s" % [was_paused, PauseManager.is_paused])
	_report("panel.prompt-on-last-line", indicator.visible, "")
	_report("panel.speaker-label-shown", speaker.visible and speaker.text == "guard", speaker.text)
	var release := InputEventAction.new()
	release.action = "pause"
	release.pressed = false
	Input.parse_input_event(release)
	await get_tree().process_frame

	DialogueManager.dialogues.erase("test_panel")
	_reset_dialogue()
	if PauseManager.is_paused != was_paused:
		if was_paused:
			PauseManager.pause()
		else:
			PauseManager.unpause()
	panel.queue_free()
	await get_tree().process_frame


# --- 8. quest log -------------------------------------------------------------------------

func _case_quest_deadline_and_failure() -> void:
	var qid := "tutorial_quest"
	if not QuestManager.is_quest_active(qid):
		QuestManager.active.erase(qid)
		QuestManager.failed.erase(qid)
		QuestManager.completed.erase(qid)
		QuestManager.start_quest(qid)
	Globals.world_state["quest_days::" + qid] = 3
	var checklist: Array = QuestManager.get_quest_checklist(qid)
	var current: Dictionary = {}
	for e in checklist:
		if e.get("status") == "current":
			current = e
	_report("quest.deadline-days-left", int(current.get("days_left", -99)) == 4, str(current))

	var log_panel = QUEST_LOG_SCRIPT.new()
	_report("quest.days-left-text", log_panel._format_days_left(4) == "4 days left" and log_panel._format_days_left(1) == "1 day left"
		and log_panel._format_days_left(0) == "out of time", "")
	log_panel.free()

	# On the stage whose failure is a dead guard.
	QuestManager.active[qid] = "retrieve_sword"
	Globals.world_state.erase("item_picked::longsword")
	var stage_before: String = "retrieve_sword"
	var n0: int = GameLog.get_entries().size()
	Globals.world_state["char_dead::town_guard"] = true
	QuestManager._reevaluate(qid, {})
	var failed_line := false
	for t in _log_texts_since(n0):
		if str(t).begins_with("Quest failed: ") and str(t).ends_with(" — A town guard was killed."):
			failed_line = true
	_report("quest.fail-reason-logged", failed_line, str(_log_texts_since(n0)))
	_report("quest.fail-reason-kept", QuestManager.get_fail_reason(qid) == "A town guard was killed.", QuestManager.get_fail_reason(qid))
	var failed_rows: Array = QuestManager.get_quest_checklist(qid)
	_report("quest.failed-keeps-checklist", not failed_rows.is_empty() and str(failed_rows.back().get("status")) == "failed"
		and str(failed_rows.back().get("stage_id")) == stage_before, str(failed_rows))

	var saved: Dictionary = QuestManager.get_save_data()
	QuestManager._failed_at.clear()
	QuestManager._fail_reasons.clear()
	QuestManager.load_save_data(saved)
	_report("quest.fail-state-saved", QuestManager.get_fail_reason(qid) == "A town guard was killed."
		and not QuestManager.get_quest_checklist(qid).is_empty(), "")
	_report("quest.generated-reason", QuestManager._describe_fail({"conditions": {"quest_days::x": ">=3"}}) == "Time ran out.",
		QuestManager._describe_fail({"conditions": {"quest_days::x": ">=3"}}))
	Globals.world_state.erase("char_dead::town_guard")


func _case_quest_and_note_hints() -> void:
	var qid := "guild_bounty_bandit_chief"
	QuestManager.active.erase(qid)
	QuestManager.completed.erase(qid)
	QuestManager.failed.erase(qid)
	var n0: int = GameLog.get_entries().size()
	QuestManager.start_quest(qid)
	var hint := false
	for t in _log_texts_since(n0):
		if str(t).begins_with("Quest started: ") and str(t).ends_with("[color=gray](press J for the quest log)[/color]"):
			hint = true
	_report("hint.quest-started", hint, str(_log_texts_since(n0)))
	QuestManager.active.erase(qid)

	var ids: Array = ReadableDatabase.get_all_readable_ids()
	if ids.is_empty():
		print("SKIP hint.notes (no readables)")
		return
	var rid := str(ids[0])
	ReadableManager.collected.erase(rid)
	n0 = GameLog.get_entries().size()
	ReadableManager.collect(rid)
	var note := false
	for t in _log_texts_since(n0):
		if str(t).begins_with("Added to your notes: ") and str(t).ends_with("(press J, Notes tab)[/color]"):
			note = true
	_report("hint.notes", note, str(_log_texts_since(n0)))


# --- 9. cemetery ----------------------------------------------------------------------

func _case_cemetery_demo_gone() -> void:
	for did in ["demo_cemetery_on_load", "demo_cemetery_zone", "demo_scheduled_dialogue"]:
		_report("cemetery.no-" + did, not DialogueManager.dialogues.has(did), "")
	var cem: Dictionary = MapDatabase.get_map_data("cemetery")
	_report("cemetery.no-demo-triggers", not cem.has("dialogue_triggers_on_load") and not cem.has("dialogue_zones")
		and not cem.has("dialogue_time_triggers"), str(cem.keys()))
	var elf := false
	for s in cem.get("npc_spawns", []):
		if str(s.get("template_id", "")) == "test_male_elf":
			elf = true
	_report("cemetery.no-test-elf", not elf, "")
