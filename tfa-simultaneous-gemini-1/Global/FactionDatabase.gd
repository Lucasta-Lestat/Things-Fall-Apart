# FactionDatabase.gd
# Autoload singleton - add to Project > AutoLoad as "FactionDatabase"
extends Node

var _factions: Dictionary = {}

func _ready() -> void:
	_load_database()

func _load_database() -> void:
	var file_path = "res://data/factions.json"
	if not FileAccess.file_exists(file_path):
		push_error("Faction Database not found at: " + file_path)
		return

	var file = FileAccess.open(file_path, FileAccess.READ)
	var content = file.get_as_text()
	var json = JSON.new()
	var error = json.parse(content)
	print("====== Faction Database =======")
	if error == OK:
		var data = json.get_data()
		for entry in data.get("factions", []):
			_factions[entry["id"]] = entry
		print("Loaded %d factions" % _factions.size())
	else:
		push_error("Failed to parse Faction JSON: " + json.get_error_message())
	print("====== End Faction Database ======")

# ---------------------------------------------------------------------------
# Lookup
# ---------------------------------------------------------------------------

func get_faction_data(faction_id: String) -> Dictionary:
	if _factions.has(faction_id):
		return _factions[faction_id]
	push_error("Faction ID not found: " + faction_id)
	return {}

func get_all_faction_ids() -> Array:
	return _factions.keys()

# ---------------------------------------------------------------------------
# Relationship queries
# ---------------------------------------------------------------------------

func are_allies(faction_a: String, faction_b: String) -> bool:
	var data_a = get_faction_data(faction_a)
	return faction_b in data_a.get("allies", [])

func are_enemies(faction_a: String, faction_b: String) -> bool:
	var data_a = get_faction_data(faction_a)
	return faction_b in data_a.get("enemies", [])

func get_relationship(faction_a: String, faction_b: String) -> String:
	if faction_a == faction_b:
		return "same"
	if are_allies(faction_a, faction_b):
		return "ally"
	if are_enemies(faction_a, faction_b):
		return "enemy"
	return "neutral"

# ---------------------------------------------------------------------------
# Race weight helpers
# ---------------------------------------------------------------------------

func get_race_weights(faction_id: String) -> Dictionary:
	var data = get_faction_data(faction_id)
	return data.get("race_weights", {})

func roll_race_for_faction(faction_id: String) -> String:
	var weights = get_race_weights(faction_id)
	return _weighted_pick(weights)

func _weighted_pick(weights: Dictionary) -> String:
	if weights.is_empty():
		return ""
	var total: float = 0.0
	for w in weights.values():
		total += float(w)
	if total <= 0:
		return ""
	var roll: float = randf() * total
	var cumulative: float = 0.0
	for key in weights:
		cumulative += float(weights[key])
		if roll <= cumulative:
			return key
	return weights.keys().back()

# ---------------------------------------------------------------------------
# Equipment trait filtering
# ---------------------------------------------------------------------------

func item_passes_faction_filter(item_data: Dictionary, faction_id: String) -> bool:
	## Checks if an item is allowed by a faction's equipment trait rules.
	## item_data should have a "traits" dict like {"Metal": 1, "Industrial": 1}
	## as found in Items2.json entries.
	var faction = get_faction_data(faction_id)
	var equip_traits: Dictionary = faction.get("equipment_traits", {})
	var required: Dictionary = equip_traits.get("required", {})
	var forbidden: Dictionary = equip_traits.get("forbidden", {})
	var item_traits: Dictionary = item_data.get("traits", {})

	# Check required traits - item must have all at >= required tier
	for req_trait in required:
		var req_tier: int = int(required[req_trait])
		var item_tier: int = int(item_traits.get(req_trait, 0))
		if item_tier < req_tier:
			return false

	# Check forbidden traits - item must NOT have any at >= forbidden tier
	for forb_trait in forbidden:
		var forb_tier: int = int(forbidden[forb_trait])
		var item_tier: int = int(item_traits.get(forb_trait, 0))
		if item_tier >= forb_tier:
			return false

	return true

func get_default_backgrounds(faction_id: String) -> Array:
	var data = get_faction_data(faction_id)
	return data.get("default_backgrounds", [])
