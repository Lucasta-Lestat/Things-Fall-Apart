# PatronDatabase.gd
# Autoload singleton — register in project.godot as "PatronDatabase".
# Loads data/patrons.json and exposes lookup + soul-scoring helpers used by the
# Occult patron-exchange downtime action.
extends Node

var _patrons: Dictionary = {}

func _ready() -> void:
	_load()

func _load() -> void:
	var path := "res://data/patrons.json"
	if not FileAccess.file_exists(path):
		push_warning("PatronDatabase: %s not found" % path)
		return
	var file = FileAccess.open(path, FileAccess.READ)
	var json := JSON.new()
	var err := json.parse(file.get_as_text())
	file.close()
	if err != OK:
		push_error("PatronDatabase: failed to parse %s — %s" % [path, json.get_error_message()])
		return
	var data = json.get_data()
	_patrons = data.get("patrons", {})
	print("PatronDatabase: loaded %d patrons" % _patrons.size())

func get_patron(patron_id: String) -> Dictionary:
	return _patrons.get(patron_id, {})

func list_patron_ids() -> Array:
	return _patrons.keys()

# Higher score = closer match between this soul and the patron's preferences.
# Returns 0 for souls that don't match any preference field, 1 for any positive
# match, and adds a small intelligence bonus where Lucifer-style preferences apply.
func score_soul(patron_id: String, soul_record: Dictionary) -> float:
	var patron := get_patron(patron_id)
	if patron.is_empty():
		return 0.0
	var prefs: Dictionary = patron.get("prefers", {})
	if prefs.is_empty():
		return 1.0  # No preferences — every soul is equally accepted
	var score := 0.0
	if prefs.has("gender") and String(soul_record.get("gender", "")) == String(prefs["gender"]):
		score += 1.0
	if prefs.has("min_intelligence"):
		var int_val := int(soul_record.get("intelligence", 0))
		var threshold := int(prefs["min_intelligence"])
		if int_val >= threshold:
			score += 1.0 + (float(int_val - threshold) / 100.0)
	if prefs.has("race") and String(soul_record.get("race", "")) == String(prefs["race"]):
		score += 1.0
	return score

# Returns the subset of `souls` the patron will accept, ordered by score desc.
func eligible_souls(patron_id: String, souls: Array) -> Array:
	var scored: Array = []
	for soul in souls:
		var s := score_soul(patron_id, soul)
		if s > 0.0:
			scored.append({"soul": soul, "score": s})
	scored.sort_custom(func(a, b): return float(a["score"]) > float(b["score"]))
	var result: Array = []
	for entry in scored:
		result.append(entry["soul"])
	return result
