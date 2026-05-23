## DowntimeConfirmDialog
## Shown after the player drops a portrait onto an activity. Reports the
## character's preference (eager / willing / reluctant / refuses) and the
## ability check (if any), and gives the player a chance to back out.
##
## Emits inherited ConfirmationDialog signals:
##   - confirmed : player chose to proceed.
##   - canceled  : player backed out (or refused activities — OK is disabled).
extends ConfirmationDialog

func populate(character, activity: Dictionary, score: int, refused: bool) -> void:
	title = String(activity.get("name", "Downtime"))
	var lines: Array = []

	var who: String = String(character.display_name) if "display_name" in character else String(character.name)
	lines.append(who + ":")

	if refused:
		lines.append("[REFUSES] favour is too low to be pushed into this.")
	elif score > 0:
		lines.append("Eager. (matches preferred traits +%d)" % score)
	elif score == 0:
		lines.append("Willing — has no strong feelings either way.")
	else:
		lines.append("Reluctant. (matches disliked traits %d). Forcing them will cost favour." % score)

	var ability_check_stat: String = String(activity.get("ability_check", ""))
	if not ability_check_stat.is_empty():
		lines.append("")
		lines.append("Ability check: %s" % ability_check_stat)

	var desc: String = String(activity.get("description", ""))
	if not desc.is_empty():
		lines.append("")
		lines.append(desc)

	dialog_text = "\n".join(lines)
	get_ok_button().disabled = refused
	if refused:
		get_ok_button().text = "Refused"
