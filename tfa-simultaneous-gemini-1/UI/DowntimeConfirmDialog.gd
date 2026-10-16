## DowntimeConfirmDialog
## Shown after the player drops a portrait onto an activity. Reports the
## character's preference (eager / willing / reluctant / refuses) and the
## ability check (if any), and gives the player a chance to back out.
##
## Emits inherited ConfirmationDialog signals:
##   - confirmed : player chose to proceed.
##   - canceled  : player backed out (or refused activities — OK is disabled).
extends ConfirmationDialog

## unavailable_reason: set when the activity can't happen at all (dead, no
## patron, feast over, another scene still playing); it replaces the
## preference line. min_favor: the favour a reluctant companion needs before
## they can be pushed into this.
func populate(character, activity: Dictionary, score: int, refused: bool, unavailable_reason: String = "", min_favor: int = 0) -> void:
	title = String(activity.get("name", "Downtime"))
	var lines: Array = []

	var who: String = String(character.display_name) if "display_name" in character else String(character.name)
	lines.append(who + ":")

	var ability_check_stat: String = String(activity.get("ability_check", ""))
	var is_prot: bool = bool(character.is_protagonist) if "is_protagonist" in character else false
	var fav: int = int(character.favorability) if "favorability" in character else 0

	if not unavailable_reason.is_empty():
		lines.append("[UNAVAILABLE] " + unavailable_reason)
	elif refused:
		lines.append("[REFUSES] Favour %d; needs %d before they can be pushed into this." % [fav, min_favor])
	elif score > 0:
		lines.append("Eager. (matches preferred traits +%d)" % score)
	elif score == 0:
		lines.append("Willing — has no strong feelings either way.")
	elif is_prot:
		# The protagonist pays no favour; a dislike only weighs on the check.
		if ability_check_stat.is_empty():
			lines.append("Reluctant (dislikes this, %d), but goes along with it." % score)
		else:
			lines.append("Reluctant (dislikes this, %d): it will weigh on the check." % score)
	else:
		lines.append("Reluctant. (matches disliked traits %d). Forcing them will cost favour: %d → %d." % [score, fav, clampi(fav + score, -100, 100)])

	var hours: int = int(activity.get("duration_hours", 0))
	if not ability_check_stat.is_empty() or hours > 0:
		lines.append("")
	if not ability_check_stat.is_empty():
		lines.append("Ability check: %s" % ability_check_stat)
	if hours > 0:
		lines.append("Takes %d hour%s." % [hours, "" if hours == 1 else "s"])

	var desc: String = String(activity.get("description", ""))
	if not desc.is_empty():
		lines.append("")
		lines.append(desc)

	dialog_text = "\n".join(lines)
	get_ok_button().disabled = refused
	if not unavailable_reason.is_empty():
		get_ok_button().text = "Unavailable"
	elif refused:
		get_ok_button().text = "Refused"
