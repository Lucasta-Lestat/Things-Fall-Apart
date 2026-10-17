## DowntimeResolver (autoload)
## Owns the state machine: drop → preference → confirm → ability check →
## result pick → dialogue → effects → cooldown + time advance.
##
## Other code (TownServicesPanel / CampDowntimePanel / DowntimeConfirmDialog)
## calls into begin_drop / confirm / cancel; this script does the rest.
extends Node

const ConfirmDialogScript = preload("res://UI/DowntimeConfirmDialog.gd")

# In-flight resolution. Cleared after effects are applied or the user cancels.
var _pending: Dictionary = {}

func _ready() -> void:
	# Apply effects when the dialogue we launched ends. The signal fires for
	# any dialogue, so we guard with _pending["awaiting_dialogue"].
	DialogueManager.dialogue_ended.connect(_on_dialogue_ended)

# ---------------------------------------------------------------------------
# Public entry points
# ---------------------------------------------------------------------------

## Called by the activity card / camp card when a portrait is dropped on it.
func begin_drop(character, activity_id: String, region_id: String) -> void:
	print("[Downtime] DowntimeResolver.begin_drop entered: activity='%s' region='%s'" % [activity_id, region_id])
	if character == null or activity_id.is_empty():
		print("[Downtime] begin_drop early-return: character or activity_id missing")
		return
	var activity: Dictionary = DowntimeDatabase.get_activity(activity_id)
	if activity.is_empty():
		push_warning("DowntimeResolver: unknown activity '%s'" % activity_id)
		print("[Downtime] begin_drop: activity '%s' not in DowntimeDatabase" % activity_id)
		return
	# One resolution at a time: a second drop while the first one's dialog or
	# scene is still up would overwrite _pending and lose (or misapply) the
	# first result. Refuse it through the usual Unavailable dialog, which is
	# not wired to _pending, and change nothing.
	if _resolution_in_progress():
		var busy_dlg := ConfirmDialogScript.new()
		busy_dlg.populate(character, activity, 0, true, "Finish the current scene first.")
		_attach_dialog_autofree(busy_dlg)
		get_tree().root.add_child(busy_dlg)
		busy_dlg.popup_centered()
		return
	print("[Downtime] begin_drop: activity loaded, showing confirm dialog")

	# Training is booked, not chosen: only the character who owes a teacher days
	# in this region can be dropped on it. The card is on the board because
	# SOMEONE in the party can train here, which isn't necessarily this one.
	if bool(activity.get("requires_training", false)):
		var who: String = String(character.display_name) if "display_name" in character else "They"
		if not TrainingManager.can_train_here(character, region_id):
			if GameLog:
				GameLog.add_entry("%s has no teacher waiting here." % who)
			# The log starts closed: say it in the usual Unavailable dialog too.
			_show_unavailable(character, activity, "No teacher is waiting here for %s." % who)
			return
		# A day of study is a day. Unlike the four-hour activities you can stack
		# two of in an evening, training is credited per day, so a second session
		# before the day rolls over would buy a day of progress for free.
		var game_node := get_node_or_null("/root/Game")
		if game_node != null and game_node.has_method("trained_today") and game_node.trained_today(character):
			if GameLog:
				GameLog.add_entry("%s has already done today's work." % who)
			_show_unavailable(character, activity, "%s has already done today's work." % who)
			return

	var preferred: Array = activity.get("preferred_traits", [])
	var disliked: Array = activity.get("disliked_traits", [])
	var score: int = 0
	if character.has_method("rate_choice"):
		score = int(character.rate_choice(preferred, disliked))

	# Refusal check (protagonist is never asked).
	var is_protagonist: bool = bool(character.is_protagonist) if "is_protagonist" in character else false
	var refused: bool = false
	var min_favor: int = 0
	if not is_protagonist and score < 0:
		min_favor = -score * 10
		if int(character.favorability) < min_favor:
			refused = true

	# Activities that can't happen at all for this character. Shown in the
	# confirm dialog in place of the preference line, with Confirm disabled.
	var unavailable := unavailable_reason(character, activity)
	if not unavailable.is_empty():
		refused = true

	_pending = {
		"character": character,
		"activity_id": activity_id,
		"activity": activity,
		"region_id": region_id,
		"score": score,
		"refused": refused,
		"is_protagonist": is_protagonist,
		"awaiting_dialogue": false,
		"pending_effects": {},
		"pending_success_tier": 1,
	}

	# Always show the confirm dialog so the user gets the feedback even on
	# refusal. The dialog's Confirm button is disabled when refused == true.
	var dlg := ConfirmDialogScript.new()
	dlg.populate(character, activity, score, refused, unavailable, min_favor)
	dlg.confirmed.connect(_on_confirmed)
	dlg.canceled.connect(_on_canceled)
	# Godot 4: no popup_hide signal. Free on close via visibility_changed.
	_attach_dialog_autofree(dlg)
	_pending["dialog"] = dlg
	get_tree().root.add_child(dlg)
	dlg.popup_centered()

## Resolve an activity with no confirm dialog and no result popup, logging the
## outcome instead. Used when a companion picks their own activity as the day
## rolls over — three modal dialogs per night would make a four-day training
## stay unplayable.
##
## Deliberately does NOT reuse _pending: the day-advance loop runs this for
## several characters back to back, and _pending is single-slot state owned by
## the interactive drop flow. Sharing it would let one companion's effects land
## on the next.
func resolve_silently(character, activity_id: String, region_id: String) -> void:
	if character == null or not is_instance_valid(character) or activity_id.is_empty():
		return
	var activity: Dictionary = DowntimeDatabase.get_activity(activity_id)
	if activity.is_empty():
		return

	var success_tier := 1
	var check_line := ""
	var ability_check_stat: String = String(activity.get("ability_check", ""))
	if not ability_check_stat.is_empty() and character.has_method("ability_check"):
		success_tier = int(character.ability_check(ability_check_stat, {
			"advantages": activity.get("preferred_traits", []),
			"disadvantages": activity.get("disliked_traits", []),
		}))
		check_line = _check_line(character, ability_check_stat, success_tier)

	# A critical failure (-1) picks from the ordinary-failure pool; money still
	# scales on the raw tier.
	var picked: Dictionary = DowntimeDatabase.pick_result(activity, region_id, character, maxi(success_tier, 0), activity_id)
	var effects: Dictionary = {}
	var event_text := ""
	var result_id := ""
	var empty_reason := ""
	if not picked.is_empty():
		result_id = String(picked.get("id", ""))
		var data: Dictionary = picked.get("data", {})
		effects = data.get("effects", {}).duplicate(true)
		event_text = String(data.get("event_description", ""))
	elif DowntimeDatabase.last_empty_reason == "cooldown":
		empty_reason = _cooldown_reason_text()
	for k in activity.get("default_effects", {}).keys():
		if not effects.has(k):
			effects[k] = activity["default_effects"][k]
	event_text += _preresolve_random_spell(character, effects)

	if not result_id.is_empty():
		DowntimeDatabase.mark_used(DowntimeDatabase.character_uid(character), result_id, activity_id)
	var lines: Array = DowntimeEffectApplier.apply(character, effects, success_tier)

	var who: String = _who(character)
	if GameLog:
		if event_text.strip_edges().is_empty():
			GameLog.add_entry("%s spent the day at %s." % [who, String(activity.get("name", activity_id))])
		else:
			GameLog.add_entry(who + event_text)
		# The day-advance moves the clock, so no hours here.
		GameLog.add_entry(_summary_line(who, activity, check_line, empty_reason, lines, 0.0))
	# Nobody watched this one: the game log starts closed, so what they did
	# (and the first thing it changed) floats over them too.
	if character is Node2D and character.is_inside_tree():
		var shown: String = String(activity.get("name", activity_id))
		if not lines.is_empty():
			shown += ": " + str(lines[0])
		Globals.show_floating_text(shown, character.global_position, character, Color(0.8, 0.85, 1.0), 0, Globals.NOTICE_FONT_SIZE)

	var game := get_node_or_null("/root/Game")
	if game != null and game.has_method("record_downtime_assignment"):
		game.record_downtime_assignment(character, activity_id)

# ---------------------------------------------------------------------------
# Internal: confirm / cancel
# ---------------------------------------------------------------------------

func _on_canceled() -> void:
	_pending = {}

func _on_confirmed() -> void:
	if _pending.is_empty():
		return
	var character = _pending["character"]
	var activity: Dictionary = _pending["activity"]
	var score: int = int(_pending["score"])
	var is_protagonist: bool = bool(_pending["is_protagonist"])

	# Forced-action favour cost. score is already signed; for a disliked
	# activity score is negative and apply_favorability_delta nudges favour down.
	if not is_protagonist and score < 0:
		if character.has_method("apply_favorability_delta"):
			character.apply_favorability_delta(score, "forced_downtime")

	# Optional ability check.
	var success_tier := 1
	var ability_check_stat: String = String(activity.get("ability_check", ""))
	if not ability_check_stat.is_empty() and character.has_method("ability_check"):
		var advantages: Array = activity.get("preferred_traits", [])
		var disadvantages: Array = (activity.get("disliked_traits", []) as Array).duplicate()
		# Forced-action disadvantage: per design comment, subtract favorability
		# from the roll. We approximate with extra disadvantage entries; each
		# entry contributes ~20 points iff the character has the trait, so we
		# add the most-disliked trait several times to roughly match a
		# -favorability/20 modifier.
		if not is_protagonist and score < 0:
			var fav := int(character.favorability)
			var extra: int = max(0, int((-fav) / 20))
			for i in range(extra):
				if not disadvantages.is_empty():
					disadvantages.append(disadvantages[0])
		var domain := {"advantages": advantages, "disadvantages": disadvantages}
		success_tier = int(character.ability_check(ability_check_stat, domain))
		_pending["check_line"] = _check_line(character, ability_check_stat, success_tier)

	# A critical failure is tier -1, below every result's min_success_tier, so
	# pick from the ordinary-failure pool. Money still uses the raw tier.
	var pick_tier: int = maxi(success_tier, 0)
	var activity_id: String = String(_pending["activity_id"])
	var picked: Dictionary = DowntimeDatabase.pick_result(activity, _pending["region_id"], character, pick_tier, activity_id)
	var result_id := ""
	var effects: Dictionary = {}
	var event_text := ""
	if not picked.is_empty():
		result_id = String(picked.get("id", ""))
		var data: Dictionary = picked.get("data", {})
		effects = data.get("effects", {}).duplicate(true)
		event_text = String(data.get("event_description", ""))
	elif DowntimeDatabase.last_empty_reason == "cooldown":
		_pending["empty_reason_text"] = _cooldown_reason_text()
	# Merge in any always-on default effects declared on the activity.
	var defaults: Dictionary = activity.get("default_effects", {})
	for k in defaults.keys():
		if not effects.has(k):
			effects[k] = defaults[k]

	# Pick the spell now so the result text can name it.
	event_text += _preresolve_random_spell(character, effects)

	# Mark cooldown immediately so a re-roll triggered before time-advance
	# can't pick the same result twice in a row.
	if not result_id.is_empty():
		DowntimeDatabase.mark_used(DowntimeDatabase.character_uid(character), result_id, activity_id)

	# Stash effects until the dialogue closes.
	_pending["pending_effects"] = effects
	_pending["pending_success_tier"] = success_tier
	_pending["event_text"] = event_text

	# Try the canonical scripted dialogue first; fall back to a simple
	# AcceptDialog with the event_description text.
	var dialogue_id: String = "downtime_%s_%s" % [activity_id, result_id]
	if DialogueManager.dialogues.has(dialogue_id):
		_pending["awaiting_dialogue"] = true
		DialogueManager.start_dialogue(dialogue_id)
		# A malformed scene never starts (and never ends): show the result
		# here instead of leaving it to a dialogue_ended that won't come.
		if bool(_pending.get("awaiting_dialogue", false)) and not DialogueManager.is_active():
			_pending["awaiting_dialogue"] = false
			_show_fallback_dialogue(character, event_text)
	else:
		_show_fallback_dialogue(character, event_text)

func _show_fallback_dialogue(character, event_text: String) -> void:
	var who := _who(character)
	var msg := ""
	if event_text.strip_edges().is_empty():
		msg = "%s: nothing of note came of it." % who
		var empty_reason := String(_pending.get("empty_reason_text", ""))
		if not empty_reason.is_empty():
			msg += "\n" + empty_reason
	else:
		msg = who + event_text
	var check_line := String(_pending.get("check_line", ""))
	if not check_line.is_empty():
		msg = check_line + "\n\n" + msg
	var dlg := AcceptDialog.new()
	dlg.dialog_text = msg
	dlg.title = "Downtime"
	# Either signal fires once per close (close button vs OK) — guard via _pending.
	dlg.confirmed.connect(_finish_resolution)
	dlg.canceled.connect(_finish_resolution)
	_attach_dialog_autofree(dlg)
	_pending["dialog"] = dlg
	get_tree().root.add_child(dlg)
	dlg.popup_centered()

# Frees the dialog the first time its visibility flips from shown to hidden.
# Godot 4 has no popup_hide signal; visibility_changed is the equivalent. Not
# one-shot: the first emission is the popup itself (visible), which would
# disconnect it before the hide ever arrived.
## The Unavailable dialog for a drop refused before any resolution starts (the
## busy refusal above, training without a teacher or done for the day). Not
## wired to _pending, so it changes nothing.
func _show_unavailable(character, activity: Dictionary, reason: String) -> void:
	var dlg := ConfirmDialogScript.new()
	dlg.populate(character, activity, 0, true, reason)
	_attach_dialog_autofree(dlg)
	get_tree().root.add_child(dlg)
	dlg.popup_centered()

func _attach_dialog_autofree(dlg: Window) -> void:
	dlg.visibility_changed.connect(func():
		if not dlg.visible:
			dlg.queue_free()
	)

func _on_dialogue_ended() -> void:
	if _pending.is_empty():
		return
	if not bool(_pending.get("awaiting_dialogue", false)):
		return
	_pending["awaiting_dialogue"] = false
	_finish_resolution()

func _finish_resolution() -> void:
	if _pending.is_empty():
		return
	var character = _pending["character"]
	var effects: Dictionary = _pending.get("pending_effects", {})
	var success_tier: int = int(_pending.get("pending_success_tier", 1))
	var activity: Dictionary = _pending["activity"]
	var who := _who(character) if is_instance_valid(character) else "Someone"

	# Advance in-game time by the activity's duration BEFORE applying the
	# result, so a condition it gives (Hungover) starts when the activity ends
	# rather than being half spent by the skip: expires_at is stamped on
	# TimeManager.absolute_time(), which includes game_time at once. The date
	# itself rolls over on TimeManager's next _process, as before.
	var hours := float(activity.get("duration_hours", 0))
	if hours > 0.0:
		TimeManager.game_time += hours * float(TimeManager.SECONDS_PER_MINUTE) * float(TimeManager.MINUTES_PER_HOUR)

	var lines: Array = DowntimeEffectApplier.apply(character, effects, success_tier)

	# One summary line per resolution, covering the scripted-dialogue path too
	# (those dialogues are second person and never show the numbers).
	if GameLog:
		GameLog.add_entry(_summary_line(who, activity, String(_pending.get("check_line", "")),
				String(_pending.get("empty_reason_text", "")), lines, hours))

	# A day of study counts against the commitment. Credited here rather than in
	# the day-advance so the progress lands with the event text that describes it,
	# and so a learner who studies twice in one day still only gets one day's
	# credit (record_assignment below is what enforces that).
	if bool(activity.get("requires_training", false)):
		TrainingManager.credit_day(character)

	# Book the day. Anyone the player did NOT assign gets an activity chosen for
	# them when the day rolls over (Game.advance_downtime_day).
	var game := get_node_or_null("/root/Game")
	if game != null and game.has_method("record_downtime_assignment"):
		game.record_downtime_assignment(character, String(_pending["activity_id"]))

	_pending = {}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Why this character can't do this activity at all, or "" if they can. Read
## by begin_drop (the Unavailable dialog) and by Game._auto_pick_downtime, so a
## companion never picks something that would do nothing.
func unavailable_reason(character, activity: Dictionary) -> String:
	if character.has_method("is_alive") and not character.is_alive():
		return "Dead, and cannot take part in downtime."
	# The board only repopulates when downtime mode opens, so a feast card can
	# outlive its saint day once the clock passes midnight.
	if bool(activity.get("requires_saint_day", false)):
		var saint_cal = get_node_or_null("/root/SaintCalendar")
		if saint_cal == null or not saint_cal.is_saint_day():
			return "The feast is over; the parish tables have been cleared."
	if (activity.get("default_effects", {}) as Dictionary).has("soul_exchange"):
		var patron_id: String = String(character.patron_id) if "patron_id" in character else ""
		if patron_id.is_empty():
			return "Has no Occult patron to offer souls to."
		var souls: Array = character.captured_souls if "captured_souls" in character else []
		if PatronDatabase.eligible_souls(patron_id, souls).is_empty():
			return "Carries no souls their patron would accept."
	# Food is the ration: Burn a Ration needs one food item in this pack.
	if DowntimeEffectApplier.ration_delta_of(activity) < 0 and DowntimeEffectApplier.ration_count(character) <= 0:
		return "No food to burn. Bread, cheese, fruit and other food count as rations; this character carries none."
	return ""

# Whether an earlier drop is still being resolved: its confirm or result
# dialog is open, or a scene is playing (ours, or one ours would queue behind
# and be resolved early by). A _pending whose dialog has closed and whose scene
# is over is stale and doesn't count, so it can't lock downtime for good.
func _resolution_in_progress() -> bool:
	if DialogueManager.is_active():
		return true
	if _pending.is_empty():
		return false
	var dlg = _pending.get("dialog")
	return is_instance_valid(dlg) and dlg.visible

# A "random_spell" result is resolved before the result is shown, so the text
# can name the spell. Rewrites effects.learn_spell to the picked id ("" when
# nothing is left to learn) and returns the sentence to append to the text.
func _preresolve_random_spell(character, effects: Dictionary) -> String:
	if String(effects.get("learn_spell", "")) != "random_spell":
		return ""
	var spell_id := DowntimeEffectApplier.pick_random_unknown_spell(character)
	effects["learn_spell"] = spell_id
	if spell_id.is_empty():
		return " Sadly, nothing in it was new to them."
	return " It held a working new to them: %s." % String(AbilityDatabase.get_ability_data(spell_id).get("display_name", spell_id))

func _cooldown_reason_text() -> String:
	return "They have done this too often lately (outcomes refresh after %d days)." % DowntimeDatabase.COOLDOWN_DAYS

# "Wisdom check: Success (rolled 34 vs 55)". The roll and target appear when
# the character records its last check as `last_check` {"roll", "target"}.
func _check_line(character, stat: String, tier: int) -> String:
	var line := "%s check: %s" % [stat, _tier_label(tier)]
	var last = character.get("last_check")
	if last is Dictionary and last.has("roll") and last.has("target"):
		line += " (rolled %d vs %d)" % [int(last["roll"]), int(last["target"])]
	return line

# "[b]Name[/b] (Activity): <check>. <changes>. N hours pass."
func _summary_line(who: String, activity: Dictionary, check_line: String, empty_reason: String, lines: Array, hours: float) -> String:
	var parts: Array = []
	if not check_line.is_empty():
		parts.append(check_line)
	if not empty_reason.is_empty():
		parts.append(empty_reason.trim_suffix("."))
	parts.append(", ".join(lines) if not lines.is_empty() else "No lasting effect")
	if hours > 0.0:
		parts.append("1 hour passes" if int(hours) == 1 else "%d hours pass" % int(hours))
	return "[b]%s[/b] (%s): %s." % [who, String(activity.get("name", "Downtime")), ". ".join(parts)]

func _who(character) -> String:
	if "Name" in character and not String(character.Name).is_empty():
		return String(character.Name)
	if "display_name" in character:
		return String(character.display_name)
	return String(character.name)

static func _tier_label(tier: int) -> String:
	if tier < 0:
		return "Critical failure"
	match tier:
		0:
			return "Failure"
		1:
			return "Success"
		2:
			return "Great success"
	return "Exceptional success"
