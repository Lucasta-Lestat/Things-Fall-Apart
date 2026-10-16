# SaintCalendar.gd
# Autoload singleton — register in project.godot as "SaintCalendar".
#
# Loads data/saints.json (the catalogue of feast days) and, on every date
# rollover, refreshes the daily Devotion bonus for party characters who
# observe the church (any trait in `observer_traits`). Also answers the
# question "is today a saint day?" for the downtime UI so the Feasting
# activity only appears when one is being celebrated.
extends Node

const DATA_PATH := "res://data/saints.json"
const DAYS_PER_MONTH := 36
const MONTHS_PER_YEAR := 10
const TOTAL_DAYS := DAYS_PER_MONTH * MONTHS_PER_YEAR  # 360

var saints: Array = []                # [{id, name, day_of_year, month, day, month_name}, ...]
var observer_traits: Array = []       # [String, ...]
var _by_day: Dictionary = {}          # day_of_year (int) -> Array of saint dicts


func _ready() -> void:
	_load()
	# Autoload order isn't guaranteed; defer so TimeManager exists.
	call_deferred("_connect_signals")


func _load() -> void:
	if not FileAccess.file_exists(DATA_PATH):
		push_warning("SaintCalendar: %s not found" % DATA_PATH)
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("SaintCalendar: failed to parse %s" % DATA_PATH)
		return
	saints = parsed.get("saints", [])
	observer_traits = parsed.get("observer_traits", [])
	_by_day.clear()
	for s in saints:
		var doy := int(s.get("day_of_year", 0))
		if doy <= 0:
			continue
		if not _by_day.has(doy):
			_by_day[doy] = []
		_by_day[doy].append(s)


func _connect_signals() -> void:
	if TimeManager and not TimeManager.date_changed.is_connected(_on_date_changed):
		TimeManager.date_changed.connect(_on_date_changed)
	# Apply once at startup so day-1 saints take effect without waiting for a
	# rollover. This also hooks Game.map_loaded once Game exists.
	_refresh_party_bonuses()


# Party characters are re-instantiated on every map load and the bonus isn't
# carried across, so today's is re-applied after each load. Game isn't in the
# tree when autoloads are ready, so every refresh retries the connection.
func _connect_game_signals(game: Node) -> void:
	if game.has_signal("map_loaded") and not game.map_loaded.is_connected(_on_map_loaded):
		game.map_loaded.connect(_on_map_loaded)


func _on_map_loaded(_map_id: String) -> void:
	# Quietly: the feast was already announced for these characters today.
	_refresh_party_bonuses(false)


# ---------------------------------------------------------------------------
# Public queries
# ---------------------------------------------------------------------------

# Day-of-year (1..360) for a given (month, day). Yearturn (month == 0) is
# treated as "no saint day"; returns 0.
static func day_of_year(month: int, day: int) -> int:
	if month <= 0:
		return 0
	return (month - 1) * DAYS_PER_MONTH + day


func current_day_of_year() -> int:
	if TimeManager == null or TimeManager.is_yearturn:
		return 0
	return day_of_year(int(TimeManager.current_month), int(TimeManager.current_day))


# Saints whose feast day is today. Empty during Yearturn or on a quiet day.
func saints_today() -> Array:
	var doy := current_day_of_year()
	if doy <= 0:
		return []
	return _by_day.get(doy, [])


func is_saint_day() -> bool:
	return not saints_today().is_empty()


# A character "observes" if any of their traits is in observer_traits.
func observes_saint_day(character) -> bool:
	if character == null or not ("traits" in character):
		return false
	for t in observer_traits:
		if int(character.traits.get(String(t), 0)) > 0:
			return true
	return false


# ---------------------------------------------------------------------------
# Daily tick
# ---------------------------------------------------------------------------

func _on_date_changed(_day: int, _month: int, _year: int) -> void:
	var today := saints_today()
	if not today.is_empty():
		var names: Array = []
		for s in today:
			names.append(String(s.get("name", "")))
		GameLog.add_entry("Feast of %s today. Observers (%s) gain +1 max Devotion; the parish lays a feast table in town." % [" and ".join(names), ", ".join(observer_traits)])
	_refresh_party_bonuses()


# Clear every party character's saint-day bonus, then set it to 1 for those
# who observe (and only when today is actually a saint day). The bonus is set,
# not added, so refreshing again the same day changes nothing.
func _refresh_party_bonuses(announce: bool = true) -> void:
	var game = get_tree().root.get_node_or_null("Game") if get_tree() else null
	if game == null:
		return
	_connect_game_signals(game)
	var party: Array = game.get("party_chars") if "party_chars" in game else []
	var saint_day := is_saint_day()
	for character in party:
		if not is_instance_valid(character):
			continue
		if not ("saint_day_devotion_bonus" in character):
			continue
		var previous := int(character.saint_day_devotion_bonus)
		var new_bonus := 1 if (saint_day and observes_saint_day(character)) else 0
		if previous == new_bonus:
			continue
		character.saint_day_devotion_bonus = new_bonus
		if new_bonus == 1 and announce:
			var who: String = String(character.Name) if "Name" in character and not String(character.Name).is_empty() else String(character.display_name)
			GameLog.add_entry("%s observes the feast: +1 max Devotion today." % who)
		# Nudge the resource UI; max_devotion is a getter so just emit. When the
		# feast ends, Devotion banked above the new max goes with it.
		if "devotion" in character and "max_devotion" in character:
			if int(character.devotion) > int(character.max_devotion):
				character.devotion = int(character.max_devotion)
			character.emit_signal("resource_changed", "devotion", int(character.devotion), int(character.max_devotion))
