# FactionDatabase.gd
# Autoload singleton - add to Project > AutoLoad as "FactionDatabase"
extends Node

signal faction_tier_changed(faction_id: String, old_tier: int, new_tier: int)

var _factions: Dictionary = {}

func _ready() -> void:
	_load_database()
	_validate_relations()

# Boot lint, push_warning only. are_hostile is symmetric precisely because
# this data is inconsistently mirrored — the lint nudges the data clean over
# time without a behavioural cliff.
func _validate_relations() -> void:
	var undefined: Dictionary = {}
	var unmirrored: Array = []
	for faction_id in _factions:
		var data: Dictionary = _factions[faction_id]
		for list_key in ["allies", "enemies"]:
			for other in data.get(list_key, []):
				var other_id := str(other)
				if not _factions.has(other_id):
					undefined[other_id] = true
				elif list_key == "enemies" and not faction_id in _factions[other_id].get("enemies", []):
					unmirrored.append("%s->%s" % [faction_id, other_id])
	if not undefined.is_empty():
		push_warning("FactionDatabase: relation lists name undefined factions: %s" % str(undefined.keys()))
	if not unmirrored.is_empty():
		push_warning("FactionDatabase: one-directional enemies (are_hostile treats these as mutual): %s" % str(unmirrored))

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

func has_faction(faction_id: String) -> bool:
	return _factions.has(faction_id)

# Silent variant for relation queries, which run per-frame from AI and get
# handed undefined ids by authored templates (spider_party, druids, "none").
# Unknown faction -> empty dict -> no relations -> peaceful. get_faction_data
# keeps its push_error for genuine lookups.
func _faction_or_empty(faction_id: String) -> Dictionary:
	var data: Dictionary = _factions.get(faction_id, {})
	return data

func get_all_faction_ids() -> Array:
	return _factions.keys()

# ---------------------------------------------------------------------------
# Tier mutation (emits faction_tier_changed for QuestManager etc.)
# ---------------------------------------------------------------------------

func get_faction_tier(faction_id: String) -> int:
	return int(get_faction_data(faction_id).get("tier", 0))

func set_faction_tier(faction_id: String, tier: int) -> void:
	if not _factions.has(faction_id):
		push_error("set_faction_tier: unknown faction " + faction_id)
		return
	var old_tier: int = int(_factions[faction_id].get("tier", 0))
	if old_tier == tier:
		return
	_factions[faction_id]["tier"] = tier
	emit_signal("faction_tier_changed", faction_id, old_tier, tier)

func adjust_faction_tier(faction_id: String, delta: int) -> void:
	if not _factions.has(faction_id):
		push_error("adjust_faction_tier: unknown faction " + faction_id)
		return
	set_faction_tier(faction_id, int(_factions[faction_id].get("tier", 0)) + delta)

# ---------------------------------------------------------------------------
# Relationship queries
# ---------------------------------------------------------------------------

func are_allies(faction_a: String, faction_b: String) -> bool:
	var data_a: Dictionary = _faction_or_empty(faction_a)
	return faction_b in data_a.get("allies", [])

# One-directional by design: reads only faction_a's list. For behaviour
# (combat, menus, targeting) use are_hostile below, which is symmetric.
func are_enemies(faction_a: String, faction_b: String) -> bool:
	var data_a: Dictionary = _faction_or_empty(faction_a)
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
# Hostility oracle
# ---------------------------------------------------------------------------
# THE hostility predicate. ai._is_enemy, the right-click attack-vs-menu split,
# Trade injection, and ability target filters all delegate here — keep them in
# lockstep and do not grow a second predicate elsewhere. The law/crime system
# (Phase 6 of docs/law_crime_stealth_plan.md) extends player_stance_toward;
# everything else reads this function.

func are_hostile(faction_a: String, faction_b: String) -> bool:
	if faction_a == faction_b:
		return false
	# Beasts and outlaws attack anyone not explicitly allied — INCLUDING the
	# player. This must precede the player branch or wildlife stops fighting.
	# "neutral" (unaffiliated civilians) is exempt, preserving the old
	# predicate's carve-out: bandits menace factions, not extras. Attacking
	# civilians becomes a *crime*, not an impossibility, when the law system
	# lands.
	if faction_b != "neutral" and _hostile_by_default(faction_a) and not are_friendly(faction_a, faction_b):
		return true
	if faction_a != "neutral" and _hostile_by_default(faction_b) and not are_friendly(faction_a, faction_b):
		return true
	if faction_a == "player" or faction_b == "player":
		var other: String = faction_b if faction_a == "player" else faction_a
		return player_stance_toward(other) == "hostile"
	# Symmetric on purpose: factions.json is inconsistently mirrored and
	# are_enemies reads only a's list. Fix the predicate, not 19 hand-mirrored
	# JSON entries.
	return are_enemies(faction_a, faction_b) or are_enemies(faction_b, faction_a)

# Same faction, or allied in either direction.
func are_friendly(faction_a: String, faction_b: String) -> bool:
	return faction_a == faction_b \
		or are_allies(faction_a, faction_b) \
		or are_allies(faction_b, faction_a)

func _hostile_by_default(faction_id: String) -> bool:
	return bool(_faction_or_empty(faction_id).get("hostile_by_default", false))

# The player's standing with a faction. Phase 6 of the law/crime plan derives
# this from a runtime standing scalar plus a hostile_override set by witnessed
# crimes (and cleared by paying fines / serving time). Until then it is the
# static base relation from factions.json, read in both directions.
func player_stance_toward(other_faction: String) -> String:
	if are_enemies("player", other_faction) or are_enemies(other_faction, "player"):
		return "hostile"
	if are_allies("player", other_faction) or are_allies(other_faction, "player"):
		return "ally"
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
	## as found in Items.json entries.
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


# Returns the spawn-time default alertness state for this faction as a
# string: "at_ease" or "unaware". Civilian factions (neutral, academics,
# tradespeople) opt in via a `default_alertness` field in factions.json;
# everything else (guards, hostile factions, wildlife) defaults to "unaware"
# so they pay attention to ambient noise normally.
func get_default_alertness(faction_id: String) -> String:
	if not _factions.has(faction_id):
		return "unaware"
	return String(_factions[faction_id].get("default_alertness", "unaware"))
