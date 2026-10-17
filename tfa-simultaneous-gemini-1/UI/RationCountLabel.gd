## RationCountLabel
## The food line on a downtime card for an activity that burns or hands out
## food (Burn a Ration on the camp panel, Feasting on the town board): what it
## does with food and what each party member carries, e.g. "Burns 1 food,
## cheapest first. Food carried: Ada 3, Bo none". Text from
## DowntimeEffectApplier.ration_card_line. It refreshes itself twice a second,
## so the count follows a burn, a feast or a trade without the panel being
## rebuilt. No class_name: preload it, then setup(activity) before adding it.
extends Label

const REFRESH_SEC := 0.5

var activity: Dictionary = {}
var _t: float = 0.0

func setup(p_activity: Dictionary) -> void:
	activity = p_activity
	add_theme_font_size_override("font_size", 9)
	add_theme_color_override("font_color", Color(0.40, 0.28, 0.10))
	autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Downtime runs with the game paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	refresh()

func _ready() -> void:
	refresh()

func _process(delta: float) -> void:
	_t -= delta
	if _t > 0.0:
		return
	_t = REFRESH_SEC
	refresh()

func refresh() -> void:
	var game = get_node_or_null("/root/Game") if is_inside_tree() else null
	var party: Array = game.party_chars if game != null and "party_chars" in game else []
	var line: String = DowntimeEffectApplier.ration_card_line(activity, party)
	if text != line:
		text = line
	visible = not line.is_empty()
