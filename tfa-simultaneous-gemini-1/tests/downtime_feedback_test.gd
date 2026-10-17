# res://tests/downtime_feedback_test.gd
# Headless harness for downtime feedback: what a downtime activity tells the
# player, and the silent no-ops it used to hide.
#
# The contract under test:
#   (1) DowntimeEffectApplier.apply returns one line per change it made, and
#       money goes through the inventory API (emptied slots drop, a full pack
#       pays gold or reports what was left behind),
#   (2) remove-affliction keeps buffs, stress virtues and curses,
#   (3) downtime conditions keep their template duration (not permanent),
#   (4) Research only teaches real, unknown spells,
#   (5) cooldowns are per activity, say why a pick came back empty, and don't
#       apply to booked Training,
#   (6) the confirm dialog shows favour, the refusal threshold, the hours and
#       the Unavailable reason; the protagonist is never told about favour,
#   (7) the resolver refuses dead / patron-less / stale-feast / busy drops,
#       labels the check (roll vs target), and writes one summary log line,
#   (8) Holy "tomorrow" bonuses last one day and survive a warp,
#   (9) saint days are announced and re-applied after a map load.
#
# Run:  godot --headless --path . res://tests/downtime_feedback_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const ConfirmDialogScript := preload("res://UI/DowntimeConfirmDialog.gd")

var _fails := 0
var _checks := 0
var game = null


func _ready() -> void:
	TimeManager.pause_time()
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)

	# Drive the REAL game scene (see training_downtime_test): cooldowns live on
	# Game, the resolver reads /root/Game, and SaintCalendar walks party_chars.
	await get_tree().process_frame
	var GameScene := load("res://game.tscn")
	game = GameScene.instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _await_frames(2)
	game.load_map("town_square")
	await _await_frames(5)

	_case_hp_lines()
	_case_money()
	_case_full_pack_money()
	_case_remove_afflictions()
	_case_condition_duration()
	_case_research_pool()
	_case_cooldowns()
	_case_confirm_dialog()
	_case_unavailable()
	await _case_busy_refusal()
	_case_check_line_and_summary()
	_case_fallback_text()
	_case_silent_summary()
	_case_rations()
	_case_holy_tier_one_day()
	await _case_saint_days()
	_case_camp_card_hours()

	print("HARNESS DONE failures=%d checks=%d" % [_fails, _checks])
	get_tree().quit(1 if _fails > 0 else 0)


func _await_frames(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame


func _spawn(pos: Vector2) -> ProceduralCharacter:
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	c.is_player_controlled = true
	add_child(c)
	c.global_position = pos
	c.hold_position = true
	return c


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


func _gold_count(c) -> int:
	var total := 0
	for it in c.inventory.items:
		if str(it.get("id", "")) == "gold":
			total += int(it.get("num_stacks", 1))
	return total


func _gold_dict(n: int) -> Dictionary:
	var d: Dictionary = ItemDatabase.items.get("gold", {}).duplicate(true)
	d["num_stacks"] = n
	d["is_stackable"] = true
	return d


# --- 1. HP lines -------------------------------------------------------------

func _case_hp_lines() -> void:
	var c := _spawn(Vector2(200, 200))
	c.current_health = maxi(1, c.max_health - 5)
	var heal: Array = DowntimeEffectApplier.apply(c, {"hp": 50})
	_report("hp.heal-reports-actual", heal == ["+%d HP" % 5] or (c.max_health < 6 and heal.size() == 1),
		str(heal))
	var full: Array = DowntimeEffectApplier.apply(c, {"hp": 5})
	_report("hp.heal-at-full-is-silent", full.is_empty(), str(full))
	var hurt: Array = DowntimeEffectApplier.apply(c, {"hp": -2})
	_report("hp.damage-line", hurt == ["-2 HP"], str(hurt))
	var fatal: Array = DowntimeEffectApplier.apply(c, {"hp": -100000})
	_report("hp.fatal-names-the-cause", fatal.size() == 1 and str(fatal[0]).ends_with("HP (fatal)"), str(fatal))
	c.queue_free()


# --- 1b. money -------------------------------------------------------------

func _case_money() -> void:
	var c := _spawn(Vector2(260, 200))
	c.inventory.items.clear()
	var none: Array = DowntimeEffectApplier.apply(c, {"money": -5})
	_report("money.no-coin-to-lose", none == ["No coin to lose"], str(none))

	c.inventory.add_stack(_gold_dict(12))
	var removed: Array = []
	c.inventory.item_removed.connect(func(d): removed.append(d))
	var lost: Array = DowntimeEffectApplier.apply(c, {"money": -5})
	_report("money.loss-line", lost == ["-5 Gold"], str(lost))
	_report("money.loss-through-inventory-api", removed.size() == 1 and _gold_count(c) == 7,
		"signals=%d gold=%d" % [removed.size(), _gold_count(c)])

	var all_lost: Array = DowntimeEffectApplier.apply(c, {"money": "all"})
	_report("money.all-line", all_lost == ["-7 Gold"], str(all_lost))
	_report("money.all-drops-the-slot", c.inventory.find_item_by_id("gold") < 0,
		str(c.inventory.items.size()))

	# A zero stack left by an older save is cleared, not shown as 1 gold.
	var stale := _gold_dict(1)
	stale["num_stacks"] = 0
	c.inventory.items.append(stale)
	var stale_lines: Array = DowntimeEffectApplier.apply(c, {"money": -3})
	_report("money.zero-stack-cleared", c.inventory.find_item_by_id("gold") < 0 and stale_lines == ["No coin to lose"],
		str(stale_lines))

	var gain: Array = DowntimeEffectApplier.apply(c, {"money": 10}, 3)
	_report("money.gain-scales-and-says-so", gain.size() == 1 and str(gain[0]).begins_with("+30 ")
		and str(gain[0]).ends_with("(x3 for the check)"), str(gain))
	var crit: Array = DowntimeEffectApplier.apply(c, {"money": 4}, -1)
	_report("money.crit-fail-pays-base", crit.size() == 1 and str(crit[0]).begins_with("+4 ")
		and not str(crit[0]).contains("for the check"), str(crit))
	c.queue_free()


func _case_full_pack_money() -> void:
	var c := _spawn(Vector2(320, 200))
	var inv: Inventory = c.inventory
	inv.items.clear()
	# A full pack whose only gold stack is nearly at its cap.
	var max_stack: int = int(ItemDatabase.items.get("gold", {}).get("max_stack_size", 20))
	inv.items.append(_gold_dict(max_stack - 3))
	while inv.items.size() < inv.max_slots:
		inv.items.append({"id": "test_filler_%d" % inv.items.size(), "display_name": "Filler"})
	var before: int = _gold_count(c)
	var lines: Array = DowntimeEffectApplier.apply(c, {"money": 10}, 1)
	var after: int = _gold_count(c)
	var gained: int = after - before
	_report("fullpack.merges-what-fits", gained == 3, "gained %d" % gained)
	var has_left_behind := false
	for l in lines:
		if str(l).ends_with("left behind") and str(l).begins_with("7 "):
			has_left_behind = true
	_report("fullpack.reports-left-behind", has_left_behind, str(lines))
	c.queue_free()


# --- 2. remove-affliction -----------------------------------------------------

func _case_remove_afflictions() -> void:
	var c := _spawn(Vector2(380, 200))
	var cm = c.condition_manager
	for cid in ["courageous", "blessed", "scarred", "hungover"]:
		cm.apply_condition(cid, c, 1, -1.0, null)
	var had_hungover: bool = cm.conditions.has("hungover")
	var lines: Array = DowntimeEffectApplier.apply(c, {"remove_mental_affliction": 1, "remove_physical_affliction": 1})
	_report("afflict.buffs-kept", cm.conditions.has("courageous") or not ConditionManager.condition_registry.has("courageous"),
		str(cm.conditions.keys()))
	_report("afflict.blessed-kept", cm.conditions.has("blessed") or not ConditionManager.condition_registry.has("blessed"),
		str(cm.conditions.keys()))
	_report("afflict.curse-kept", cm.conditions.has("scarred") or not ConditionManager.condition_registry.has("scarred"),
		str(cm.conditions.keys()))
	if had_hungover:
		_report("afflict.affliction-cleared", not cm.conditions.has("hungover"), str(cm.conditions.keys()))
		var cleared_line := false
		for l in lines:
			if str(l).begins_with("Cleared: "):
				cleared_line = true
		_report("afflict.cleared-line", cleared_line, str(lines))
	else:
		print("SKIP afflict.affliction-cleared (hungover resisted)")
	c.queue_free()


# --- 3. conditions keep their template duration ----------------------------

func _case_condition_duration() -> void:
	var c := _spawn(Vector2(440, 200))
	var cm = c.condition_manager
	var lines: Array = DowntimeEffectApplier.apply(c, {"add_condition": "blessed"})
	var inst = cm.conditions.get("blessed")
	if inst == null:
		_report("cond.resisted-line", lines.size() == 1 and str(lines[0]).begins_with("Resisted: "), str(lines))
	else:
		_report("cond.gained-line", lines.size() == 1 and str(lines[0]).begins_with("Gained: "), str(lines))
		var template_dur: float = float(ConditionManager.condition_registry["blessed"].duration)
		_report("cond.template-duration-not-permanent", inst.expires_at > 0.0
			and is_equal_approx(inst.expires_at - inst.applied_at, template_dur),
			"applied %s expires %s (template %s)" % [inst.applied_at, inst.expires_at, template_dur])
	c.queue_free()


# --- 4. Research -------------------------------------------------------------

func _case_research_pool() -> void:
	var c := _spawn(Vector2(500, 200))
	var seen: Dictionary = {}
	for i in range(300):
		var sid: String = DowntimeEffectApplier.pick_random_unknown_spell(c)
		if not sid.is_empty():
			seen[sid] = true
	var bad: Array = []
	for sid in seen:
		if str(sid).begins_with("test_") or sid in DowntimeEffectApplier.UNTEACHABLE_SPELLS:
			bad.append(sid)
	_report("research.teaches-something", not seen.is_empty(), str(seen.size()))
	_report("research.no-debug-or-broken-spells", bad.is_empty(), str(bad))

	# A spell held in hand counts as known.
	var one: String = str(seen.keys()[0]) if not seen.is_empty() else ""
	if not one.is_empty():
		c.inventory.add_ability_by_id(one)
		var repeat := false
		for i in range(300):
			if DowntimeEffectApplier.pick_random_unknown_spell(c) == one:
				repeat = true
				break
		_report("research.known-spell-excluded", not repeat, one)
	var learned: Array = DowntimeEffectApplier.apply(c, {"learn_spell": ""})
	_report("research.nothing-to-learn-line", learned == ["Found nothing new to learn"], str(learned))
	c.queue_free()


# --- 5. cooldowns --------------------------------------------------------------

func _case_cooldowns() -> void:
	var c := _spawn(Vector2(560, 200))
	c.set_meta("template_id", "test_cooldown_char")
	var uid := DowntimeDatabase.character_uid(c)
	game.downtime_recent_events.erase(uid)
	DowntimeDatabase.mark_used(uid, "quiet_night", "carousing")
	_report("cooldown.same-activity-blocked", DowntimeDatabase.is_on_cooldown(uid, "quiet_night", "carousing"), "")
	_report("cooldown.other-activity-free", not DowntimeDatabase.is_on_cooldown(uid, "quiet_night", "watch"), "")

	# Use up every result of an activity: the pick explains itself.
	var activity := {"results": {"any_map": {"only": {"weight": 1, "event_description": " x"}}}}
	DowntimeDatabase.mark_used(uid, "only", "test_act")
	var picked: Dictionary = DowntimeDatabase.pick_result(activity, "", c, 1, "test_act")
	_report("cooldown.empty-reason", picked.is_empty() and DowntimeDatabase.last_empty_reason == "cooldown",
		DowntimeDatabase.last_empty_reason)
	var gated: Dictionary = DowntimeDatabase.pick_result({"results": {"any_map": {"hard": {"min_success_tier": 3}}}}, "", c, 1, "test_act2")
	_report("cooldown.no-outcome-reason", gated.is_empty() and DowntimeDatabase.last_empty_reason == "no_outcome",
		DowntimeDatabase.last_empty_reason)
	activity["requires_training"] = true
	var trained: Dictionary = DowntimeDatabase.pick_result(activity, "", c, 1, "test_act")
	_report("cooldown.training-exempt", not trained.is_empty(), str(trained))
	# A critical failure (-1) still finds the ordinary-failure pool at tier 0.
	var fail_pool := {"results": {"any_map": {"plain": {"weight": 1}}}}
	_report("cooldown.crit-fail-filtered-at-raw-tier", DowntimeDatabase.pick_result(fail_pool, "", c, -1, "t3").is_empty(), "")
	_report("cooldown.crit-fail-picks-at-zero", not DowntimeDatabase.pick_result(fail_pool, "", c, maxi(-1, 0), "t3").is_empty(), "")
	game.downtime_recent_events.erase(uid)
	c.queue_free()


# --- 6. confirm dialog -----------------------------------------------------

func _dialog_text(character, activity: Dictionary, score: int, refused: bool, reason: String = "", min_favor: int = 0) -> Array:
	var dlg = ConfirmDialogScript.new()
	add_child(dlg)
	dlg.populate(character, activity, score, refused, reason, min_favor)
	var out := [str(dlg.dialog_text), str(dlg.get_ok_button().text), dlg.get_ok_button().disabled]
	dlg.queue_free()
	return out


func _case_confirm_dialog() -> void:
	var comp := _spawn(Vector2(620, 200))
	comp.is_protagonist = false
	comp.favorability = 5
	var act := {"name": "Carousing", "ability_check": "Constitution", "duration_hours": 4}
	var r: Array = _dialog_text(comp, act, -2, true, "", 20)
	_report("dialog.refusal-shows-favour", str(r[0]).contains("[REFUSES] Favour 5; needs 20"), str(r[0]))
	_report("dialog.refusal-button", r[1] == "Refused" and r[2], str(r))
	r = _dialog_text(comp, act, -2, false)
	_report("dialog.reluctant-cost", str(r[0]).contains("Forcing them will cost favour: 5 → 3."), str(r[0]))
	_report("dialog.hours", str(r[0]).contains("Takes 4 hours."), str(r[0]))
	r = _dialog_text(comp, act, 0, true, "Dead, and cannot take part in downtime.")
	_report("dialog.unavailable", str(r[0]).contains("[UNAVAILABLE] Dead, and cannot take part in downtime.")
		and r[1] == "Unavailable" and r[2], str(r))
	var prot := _spawn(Vector2(660, 200))
	prot.is_protagonist = true
	r = _dialog_text(prot, act, -1, false)
	_report("dialog.protagonist-no-favour", not str(r[0]).contains("favour")
		and str(r[0]).contains("it will weigh on the check"), str(r[0]))
	r = _dialog_text(prot, {"name": "Rest", "duration_hours": 1}, -1, false)
	_report("dialog.protagonist-no-check", str(r[0]).contains("but goes along with it") and str(r[0]).contains("Takes 1 hour."),
		str(r[0]))
	comp.queue_free()
	prot.queue_free()


# --- 7. unavailable / busy ---------------------------------------------------

func _case_unavailable() -> void:
	var c := _spawn(Vector2(700, 200))
	var souls_act: Dictionary = DowntimeDatabase.get_activity("offer_souls_to_patron")
	c.patron_id = ""
	_report("unavail.no-patron", DowntimeResolver.unavailable_reason(c, souls_act) == "Has no Occult patron to offer souls to.",
		DowntimeResolver.unavailable_reason(c, souls_act))
	c.patron_id = "test_patron"
	c.captured_souls = []
	_report("unavail.no-souls", DowntimeResolver.unavailable_reason(c, souls_act) == "Carries no souls their patron would accept.",
		DowntimeResolver.unavailable_reason(c, souls_act))
	var feast: Dictionary = DowntimeDatabase.get_activity("feasting")
	var saved := [TimeManager.current_day, TimeManager.current_month]
	TimeManager.current_month = 1
	TimeManager.current_day = 2
	_report("unavail.feast-over", DowntimeResolver.unavailable_reason(c, feast).begins_with("The feast is over"),
		DowntimeResolver.unavailable_reason(c, feast))
	TimeManager.current_day = 1
	_report("unavail.feast-today", DowntimeResolver.unavailable_reason(c, feast) == "", "")
	TimeManager.current_day = saved[0]
	TimeManager.current_month = saved[1]
	c.current_health = 0
	_report("unavail.dead", DowntimeResolver.unavailable_reason(c, {}) == "Dead, and cannot take part in downtime.",
		DowntimeResolver.unavailable_reason(c, {}))
	c.queue_free()


func _case_busy_refusal() -> void:
	var c = game.party_chars[0]
	DowntimeResolver._pending = {}
	_report("busy.idle", not DowntimeResolver._resolution_in_progress(), "")
	# An open result dialog holds the slot...
	var dlg := AcceptDialog.new()
	get_tree().root.add_child(dlg)
	dlg.popup_centered()
	DowntimeResolver._pending = {"character": c, "dialog": dlg}
	_report("busy.dialog-open", DowntimeResolver._resolution_in_progress(), "")
	# ...and a second drop is refused without touching it.
	var before: Dictionary = DowntimeResolver._pending
	DowntimeResolver.begin_drop(c, "rest", "")
	_report("busy.second-drop-keeps-pending", DowntimeResolver._pending == before, "")
	# A closed dialog is stale and doesn't lock downtime.
	dlg.hide()
	await get_tree().process_frame
	_report("busy.stale-pending-released", not DowntimeResolver._resolution_in_progress(), "")
	DowntimeResolver._pending = {}
	# Close any dialog the refused drop opened.
	for child in get_tree().root.get_children():
		if child is ConfirmationDialog:
			child.hide()
	await get_tree().process_frame


# --- 7b. check line and summary ------------------------------------------------

func _case_check_line_and_summary() -> void:
	_report("tier.labels", DowntimeResolver._tier_label(-1) == "Critical failure" and DowntimeResolver._tier_label(0) == "Failure"
		and DowntimeResolver._tier_label(1) == "Success" and DowntimeResolver._tier_label(2) == "Great success"
		and DowntimeResolver._tier_label(3) == "Exceptional success", "")
	var c := _spawn(Vector2(740, 200))
	c.ability_check("Wisdom", {})
	var last = c.get("last_check")
	_report("check.last-check-recorded", last is Dictionary and last.has("roll") and last.has("target"), str(last))
	var line: String = DowntimeResolver._check_line(c, "Wisdom", 1)
	_report("check.line-has-roll", line.begins_with("Wisdom check: Success (rolled ") and line.contains(" vs "), line)

	var p0 = game.party_chars[0]
	var n0: int = GameLog.get_entries().size()
	DowntimeResolver._pending = {
		"character": p0,
		"activity": {"name": "Test Activity", "duration_hours": 2},
		"activity_id": "test_activity",
		"check_line": "Wisdom check: Success",
		"pending_effects": {"stress": 3},
		"pending_success_tier": 1,
	}
	DowntimeResolver._finish_resolution()
	var texts: Array = _log_texts_since(n0)
	var want := "[b]%s[/b] (Test Activity): Wisdom check: Success. Stress +3. 2 hours pass." % DowntimeResolver._who(p0)
	_report("summary.one-line", want in texts, str(texts))
	game.downtime_day_assignments.clear()
	c.queue_free()


func _case_fallback_text() -> void:
	var p0 = game.party_chars[0]
	DowntimeResolver._pending = {"character": p0, "check_line": "Strength check: Failure",
		"empty_reason_text": DowntimeResolver._cooldown_reason_text()}
	DowntimeResolver._show_fallback_dialogue(p0, "")
	var dlg = DowntimeResolver._pending.get("dialog")
	var text: String = str(dlg.dialog_text) if is_instance_valid(dlg) else ""
	_report("fallback.check-on-top", text.begins_with("Strength check: Failure\n\n"), text)
	_report("fallback.not-just-a-name", text.contains(": nothing of note came of it."), text)
	_report("fallback.cooldown-reason", text.contains("too often lately"), text)
	if is_instance_valid(dlg):
		dlg.hide()
	DowntimeResolver._pending = {}


func _case_silent_summary() -> void:
	var p0 = game.party_chars[0]
	var n0: int = GameLog.get_entries().size()
	DowntimeResolver.resolve_silently(p0, "rest", RegionDatabase.get_region_for_map("town_square"))
	var texts: Array = _log_texts_since(n0)
	var summary := false
	for t in texts:
		if str(t).begins_with("[b]%s[/b] (" % DowntimeResolver._who(p0)):
			summary = true
	_report("silent.summary-logged", summary, str(texts))
	game.downtime_day_assignments.clear()


# --- rations -----------------------------------------------------------------

## Food is the ration (round 3: the "Ration" item trait; there is no ration item).
func _case_rations() -> void:
	var c := _spawn(Vector2(780, 200))
	c.inventory.items.clear()
	var none: Array = DowntimeEffectApplier.apply(c, {"ration_delta": -1})
	_report("ration.none-to-burn", none == ["No food to burn"], str(none))
	var bread: Dictionary = ItemDatabase.get_item_data("bread_loaf")
	bread["num_stacks"] = 2
	c.inventory.items.append(bread)
	var used: Array = DowntimeEffectApplier.apply(c, {"ration_delta": -1})
	_report("ration.burned", used == ["-1 Bread Loaf"] and int(c.inventory.items[0]["num_stacks"]) == 1, str(used))
	var gained: Array = DowntimeEffectApplier.apply(c, {"ration_delta": 1})
	_report("ration.gained-merges", gained == ["+1 Bread Loaf"] and int(c.inventory.items[0]["num_stacks"]) == 2, str(gained))
	DowntimeEffectApplier.apply(c, {"ration_delta": -5})
	_report("ration.empty-slot-dropped", c.inventory.find_item_by_id("bread_loaf") < 0, str(c.inventory.items))
	# A full stolen stack: the feast's bread lands in a new slot, untagged.
	var stolen: Dictionary = ItemDatabase.get_item_data("bread_loaf")
	stolen.merge({"num_stacks": 10, "max_stack_size": 10, "stolen_from": "town_guard", "stolen_value": 5}, true)
	c.inventory.items.append(stolen)
	DowntimeEffectApplier.apply(c, {"ration_delta": 1})
	var fresh: Dictionary = c.inventory.items[c.inventory.items.size() - 1]
	_report("ration.gift-not-stolen", c.inventory.items.size() == 2 and int(fresh.get("num_stacks", 0)) == 1
		and not fresh.has("stolen_from") and not fresh.has("stolen_value"), str(c.inventory.items))
	c.queue_free()


# --- 8. Holy tier lasts a day --------------------------------------------------

func _case_holy_tier_one_day() -> void:
	var c := _spawn(Vector2(820, 200))
	c.traits["Holy"] = 2
	c.vow_holy_bonus = 1   # a lasting Chastity point
	var lines: Array = DowntimeEffectApplier.apply(c, {"holy_tier_next_day": 2})
	_report("holy.queued-line", lines == ["+2 max Devotion tomorrow"], str(lines))
	VowManager._process_daily_tick(c)
	_report("holy.applied-today", c.vow_holy_bonus == 3 and c.max_devotion == 5, "bonus %d max %d" % [c.vow_holy_bonus, c.max_devotion])
	c.devotion = c.max_devotion

	# A warp re-instantiates the character from its snapshot.
	var state: Dictionary = game._serialize_character(c)
	var d := _spawn(Vector2(860, 200))
	game._deserialize_character(d, state)
	_report("holy.one-day-part-survives-warp", d.holy_tier_today == 2, str(d.holy_tier_today))

	d.devotion = d.max_devotion
	VowManager._process_daily_tick(d)
	_report("holy.expires-next-day", d.vow_holy_bonus == 1, str(d.vow_holy_bonus))
	_report("holy.devotion-clamped", d.devotion <= d.max_devotion, "%d / %d" % [d.devotion, d.max_devotion])
	c.queue_free()
	d.queue_free()


# --- 9. saint days ---------------------------------------------------------------

func _case_saint_days() -> void:
	var p0 = game.party_chars[0]
	var saved := [TimeManager.current_day, TimeManager.current_month, p0.traits.duplicate()]
	p0.traits["Catholic"] = 1
	p0.saint_day_devotion_bonus = 0
	TimeManager.current_month = 1
	TimeManager.current_day = 1
	var n0: int = GameLog.get_entries().size()
	SaintCalendar._on_date_changed(1, 1, TimeManager.current_year)
	var texts: Array = _log_texts_since(n0)
	var feast_line := false
	var observe_line := false
	for t in texts:
		if str(t).begins_with("Feast of "):
			feast_line = true
		if str(t).ends_with("observes the feast: +1 max Devotion today."):
			observe_line = true
	_report("saint.feast-announced", feast_line, str(texts))
	_report("saint.observer-announced", observe_line, str(texts))
	_report("saint.bonus-applied", p0.saint_day_devotion_bonus == 1, "")

	# A fresh party member after a map load gets it back, quietly.
	p0.saint_day_devotion_bonus = 0
	n0 = GameLog.get_entries().size()
	game.emit_signal("map_loaded", "town_square")
	_report("saint.reapplied-after-load", p0.saint_day_devotion_bonus == 1, "")
	_report("saint.reapply-is-quiet", _log_texts_since(n0).filter(func(t): return str(t).contains("observes the feast")).is_empty(),
		str(_log_texts_since(n0)))

	TimeManager.current_day = 2
	p0.devotion = p0.max_devotion
	SaintCalendar._on_date_changed(2, 1, TimeManager.current_year)
	_report("saint.bonus-cleared", p0.saint_day_devotion_bonus == 0, "")
	_report("saint.devotion-clamped", p0.devotion <= p0.max_devotion, "%d / %d" % [p0.devotion, p0.max_devotion])
	TimeManager.current_day = saved[0]
	TimeManager.current_month = saved[1]
	p0.traits = saved[2]
	p0.saint_day_devotion_bonus = 0
	await get_tree().process_frame


# --- camp cards ------------------------------------------------------------------

func _case_camp_card_hours() -> void:
	var panel = game.get_node_or_null("GameUI/CampDowntimePanel")
	if panel == null or not panel.has_method("_build_activity_card"):
		print("SKIP camp.card-hours (no CampDowntimePanel)")
		return
	var card: Control = panel._build_activity_card("rest", DowntimeDatabase.get_activity("rest"))
	var found := false
	var hours := int(DowntimeDatabase.get_activity("rest").get("duration_hours", 0))
	for l in card.find_children("*", "Label", true, false):
		if str(l.text).ends_with("%dh" % hours):
			found = true
	_report("camp.card-hours", found or hours <= 0, "rest %dh" % hours)
	card.queue_free()
