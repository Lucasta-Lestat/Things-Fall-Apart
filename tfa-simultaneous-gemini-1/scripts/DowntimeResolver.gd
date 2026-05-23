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
	if character == null or activity_id.is_empty():
		return
	var activity: Dictionary = DowntimeDatabase.get_activity(activity_id)
	if activity.is_empty():
		push_warning("DowntimeResolver: unknown activity '%s'" % activity_id)
		return

	var preferred: Array = activity.get("preferred_traits", [])
	var disliked: Array = activity.get("disliked_traits", [])
	var score: int = 0
	if character.has_method("rate_choice"):
		score = int(character.rate_choice(preferred, disliked))

	# Refusal check (protagonist is never asked).
	var is_protagonist := bool(character.is_protagonist) if "is_protagonist" in character else false
	var refused := false
	if not is_protagonist and score < 0:
		var min_favor: int = -score * 10
		if int(character.favorability) < min_favor:
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
	dlg.populate(character, activity, score, refused)
	dlg.confirmed.connect(_on_confirmed)
	dlg.canceled.connect(_on_canceled)
	dlg.popup_hide.connect(dlg.queue_free)
	get_tree().root.add_child(dlg)
	dlg.popup_centered()

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

	var picked: Dictionary = DowntimeDatabase.pick_result(activity, _pending["region_id"], character, success_tier)
	var result_id := ""
	var effects: Dictionary = {}
	var event_text := ""
	if not picked.is_empty():
		result_id = String(picked.get("id", ""))
		var data: Dictionary = picked.get("data", {})
		effects = data.get("effects", {}).duplicate(true)
		event_text = String(data.get("event_description", ""))
	# Merge in any always-on default effects declared on the activity.
	var defaults: Dictionary = activity.get("default_effects", {})
	for k in defaults.keys():
		if not effects.has(k):
			effects[k] = defaults[k]

	# Mark cooldown immediately so a re-roll triggered before time-advance
	# can't pick the same result twice in a row.
	if not result_id.is_empty():
		DowntimeDatabase.mark_used(DowntimeDatabase.character_uid(character), result_id)

	# Stash effects until the dialogue closes.
	_pending["pending_effects"] = effects
	_pending["pending_success_tier"] = success_tier
	_pending["event_text"] = event_text

	# Try the canonical scripted dialogue first; fall back to a simple
	# AcceptDialog with the event_description text.
	var dialogue_id: String = "downtime_%s_%s" % [_pending["activity_id"], result_id]
	if DialogueManager.dialogues.has(dialogue_id):
		_pending["awaiting_dialogue"] = true
		DialogueManager.start_dialogue(dialogue_id)
	else:
		_show_fallback_dialogue(character, event_text)

func _show_fallback_dialogue(character, event_text: String) -> void:
	var msg := ""
	if "display_name" in character:
		msg = String(character.display_name) + event_text
	else:
		msg = event_text
	if msg.strip_edges().is_empty():
		msg = "Nothing of note happened."
	var dlg := AcceptDialog.new()
	dlg.dialog_text = msg
	dlg.title = "Downtime"
	# Either signal fires once per close (close button vs OK) — guard via _pending.
	dlg.confirmed.connect(_finish_resolution)
	dlg.canceled.connect(_finish_resolution)
	dlg.popup_hide.connect(dlg.queue_free)
	get_tree().root.add_child(dlg)
	dlg.popup_centered()

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

	DowntimeEffectApplier.apply(character, effects, success_tier)

	# Advance in-game time by the activity's duration. TimeManager advances
	# date/clock automatically as game_time crosses thresholds in _process.
	var hours := float(activity.get("duration_hours", 0))
	if hours > 0.0:
		TimeManager.game_time += hours * float(TimeManager.SECONDS_PER_MINUTE) * float(TimeManager.MINUTES_PER_HOUR)

	_pending = {}
