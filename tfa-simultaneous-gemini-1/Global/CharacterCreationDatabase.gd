# CharacterCreationDatabase.gd
# Autoload singleton — add to Project > AutoLoad as "CharacterCreationDatabase".
#
# Owns data/character_creation.json: every Italian string on the Scarlatti carta
# d'identità, the portrait pick pool, the name pools, and the background filter.
# Nothing in here draws or decides game rules — UI/CartaIdentita.gd renders, and
# DaroDice / RaceDatabase roll. This is the lookup layer between them.
#
# Depends on: BackgroundDatabase, RaceDatabase, DaroDice.
extends Node

const DATA_PATH: String = "res://data/character_creation.json"

## The race every player character is. Scarlatti issues cards to humans.
const PLAYER_RACE: String = "human"

var _data: Dictionary = {}

func _ready() -> void:
	_load_database()

func _load_database() -> void:
	if not FileAccess.file_exists(DATA_PATH):
		push_error("Character creation data not found at: " + DATA_PATH)
		return
	var file := FileAccess.open(DATA_PATH, FileAccess.READ)
	var json := JSON.new()
	print("====== Character Creation =======")
	if json.parse(file.get_as_text()) == OK:
		_data = json.get_data()
		print("Loaded carta d'identità data (%d portraits, %d names)"
				% [portraits_for("male").size() + portraits_for("female").size(),
				   name_pool("male").size() + name_pool("female").size()])
	else:
		push_error("Failed to parse character_creation.json: " + json.get_error_message())
	print("====== End Character Creation ======")

# ---------------------------------------------------------------------------
# Document strings
# ---------------------------------------------------------------------------

func document() -> Dictionary:
	return _data.get("document", {})

## A top-level document string, e.g. doc_text("title") -> "CARTA D'IDENTITA'".
func doc_text(key: String, fallback: String = "") -> String:
	return String(document().get(key, fallback))

## A labelled field caption, e.g. field_label("height") -> "STATURA".
func field_label(key: String) -> String:
	var fields: Dictionary = document().get("fields", {})
	return String(fields.get(key, key.to_upper()))

func button_label(key: String) -> String:
	var buttons: Dictionary = document().get("buttons", {})
	return String(buttons.get(key, key.to_upper()))

func exam() -> Dictionary:
	return document().get("exam", {})

func exam_text(key: String, fallback: String = "") -> String:
	return String(exam().get(key, fallback))

## "IDONEO" / "IDONEA" — the examination verdict agrees with the holder's sex.
func verdict_text(gender: String) -> String:
	var verdict: Dictionary = exam().get("verdict_pass", {})
	return String(verdict.get(gender, verdict.get("male", "IDONEO")))

# ---------------------------------------------------------------------------
# Gender
# ---------------------------------------------------------------------------

func genders() -> Array:
	return _data.get("genders", [])

func gender_ids() -> Array:
	var out: Array = []
	for entry in genders():
		out.append(String(entry.get("id", "")))
	return out

func gender_label(gender_id: String) -> String:
	for entry in genders():
		if String(entry.get("id", "")) == gender_id:
			return String(entry.get("label", gender_id))
	return gender_id

func gender_abbrev(gender_id: String) -> String:
	for entry in genders():
		if String(entry.get("id", "")) == gender_id:
			return String(entry.get("abbrev", gender_id.substr(0, 1).to_upper()))
	return gender_id.substr(0, 1).to_upper()

# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------

## [{"key": "strength", "label": "Forza"}, ...] in document order.
func stats() -> Array:
	return _data.get("stats", [])

## Just the character-property names, in the same order.
func stat_keys() -> Array:
	var out: Array = []
	for entry in stats():
		out.append(String(entry.get("key", "")))
	return out

func stat_label(stat_key: String) -> String:
	for entry in stats():
		if String(entry.get("key", "")) == stat_key:
			return String(entry.get("label", stat_key))
	return stat_key.capitalize()

# ---------------------------------------------------------------------------
# Names and document numbers
# ---------------------------------------------------------------------------

func name_pool(gender: String) -> Array:
	var names: Dictionary = _data.get("names", {})
	return names.get(gender, [])

func surname_pool() -> Array:
	var names: Dictionary = _data.get("names", {})
	return names.get("surnames", [])

func random_name(gender: String, rng: RandomNumberGenerator = null) -> String:
	var given: Array = name_pool(gender)
	var surnames: Array = surname_pool()
	if given.is_empty() or surnames.is_empty():
		return "Anonimo"
	return "%s %s" % [_pick(given, rng), _pick(surnames, rng)]

## A stable card number for a given holder. Derived from the name so reopening
## the sheet shows the same document, not a fresh one every draw.
func document_number(seed_text: String) -> String:
	var h: int = abs(seed_text.hash())
	var letters: String = "ABCDEFGHILMNPRSTVZ"  # the Italian alphabet, no J/K/W/X/Y
	var a: String = letters[h % letters.length()]
	var b: String = letters[(h >> 5) % letters.length()]
	return "%s%s %05d" % [a, b, h % 100000]

# ---------------------------------------------------------------------------
# Portraits
# ---------------------------------------------------------------------------

## [{"id": ..., "path": ...}] for one gender, minus any whose art is missing —
## a portrait that fails to load would be an empty frame the player can scroll
## onto with no way to tell why.
func portraits_for(gender: String) -> Array:
	var all: Dictionary = _data.get("portraits", {})
	var listed: Array = all.get(gender, [])
	var out: Array = []
	for entry in listed:
		if ResourceLoader.exists(String(entry.get("path", ""))):
			out.append(entry)
	return out

## Resolve a saved portrait id back to its texture path, searching every gender
## (a player who switches sex mid-creation keeps a valid card either way).
func portrait_path(portrait_id: String) -> String:
	for entry in _all_portraits():
		if String(entry.get("id", "")) == portrait_id:
			return String(entry.get("path", ""))
	return ""

## How a portrait should be fitted to the photo frame. "token" crops into the
## circular artwork of an Icons/ character token; "full" uses the image as it
## stands, which is what tools/generate_creation_portraits.py produces. Token is
## the default because every seeded entry is one.
func portrait_crop(portrait_id: String) -> String:
	for entry in _all_portraits():
		if String(entry.get("id", "")) == portrait_id:
			return String(entry.get("crop", "token"))
	return "token"

## Every portrait entry, both sexes. Skips any non-Array value so the portraits
## block can grow config keys without this walking over a bare string.
func _all_portraits() -> Array:
	var out: Array = []
	var all: Dictionary = _data.get("portraits", {})
	for gender in all:
		var pool = all[gender]
		if pool is Array:
			out.append_array(pool)
	return out

# ---------------------------------------------------------------------------
# Backgrounds
# ---------------------------------------------------------------------------

## Background ids offerable to a human of this gender, sorted by display name.
func background_ids_for(gender: String) -> Array:
	var rules: Dictionary = _data.get("backgrounds", {})
	var excluded: Array = rules.get("exclude", [])
	var locked: Dictionary = rules.get("gender_locked", {})

	var ids: Array = []
	for bg_id in BackgroundDatabase.get_all_background_ids():
		if bg_id in excluded:
			continue
		if locked.has(bg_id) and String(locked[bg_id]) != gender:
			continue
		ids.append(bg_id)

	ids.sort_custom(func(a, b) -> bool:
		return background_label(a).naturalnocasecmp_to(background_label(b)) < 0)
	return ids

func background_label(bg_id: String) -> String:
	var data: Dictionary = BackgroundDatabase.get_background_data(bg_id)
	return String(data.get("name", bg_id.capitalize())).strip_edges().trim_suffix("-").strip_edges()

func background_description(bg_id: String) -> String:
	var data: Dictionary = BackgroundDatabase.get_background_data(bg_id)
	return String(data.get("description", ""))

## The background's traits, rendered for the "SEGNI PARTICOLARI" line.
func background_marks(bg_id: String) -> String:
	var data: Dictionary = BackgroundDatabase.get_background_data(bg_id)
	var traits: Dictionary = data.get("traits", {})
	var parts: Array = []
	for trait_name in traits:
		parts.append(String(trait_name).to_lower())
	if parts.is_empty():
		return doc_text("marks_none", "nessuno")
	return ", ".join(parts)

# ---------------------------------------------------------------------------
# Draft assembly
# ---------------------------------------------------------------------------

## One complete randomly-rolled draft — what the screen opens on and what the
## "roll everything" path produces. Every field is independently re-rollable by
## the screen, so this is only ever a starting point.
func roll_draft(gender: String = "", rng: RandomNumberGenerator = null) -> Dictionary:
	var chosen_gender: String = gender
	if chosen_gender.is_empty():
		var ids: Array = gender_ids()
		chosen_gender = String(_pick(ids, rng)) if not ids.is_empty() else "male"

	var portraits: Array = portraits_for(chosen_gender)
	var portrait_id: String = ""
	if not portraits.is_empty():
		portrait_id = String(_pick(portraits, rng).get("id", ""))

	var backgrounds: Array = background_ids_for(chosen_gender)
	var background_id: String = String(_pick(backgrounds, rng)) if not backgrounds.is_empty() else ""

	return {
		"name": random_name(chosen_gender, rng),
		"gender": chosen_gender,
		"background_id": background_id,
		"portrait_id": portrait_id,
		"body_metrics": RaceDatabase.roll_body_metrics(PLAYER_RACE, chosen_gender, rng),
		"stats": DaroDice.roll_stat_block(stat_keys(), DaroDice.DEFAULT_MIN_PEAK, rng),
	}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _pick(pool: Array, rng: RandomNumberGenerator):
	if pool.is_empty():
		return null
	if rng != null:
		return pool[rng.randi_range(0, pool.size() - 1)]
	return pool[randi() % pool.size()]
