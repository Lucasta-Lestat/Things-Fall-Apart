# FactionDatabase.gd
# Autoload singleton - add to Project > AutoLoad as "FactionDatabase"
extends Node

signal faction_tier_changed(faction_id: String, old_tier: int, new_tier: int)
## Fired on any change to the player's legal standing with a faction —
## adjust_player_standing, mark_outlaw, and settle all emit it. Game derives
## the `wanted` display condition from it.
signal player_standing_changed(faction_id: String, old_value: int, new_value: int)

var _factions: Dictionary = {}

# --- Player legal standing (law/crime Phase 6) ---
# The single scalar per faction (D2). _hostile_override carries D8's binary:
# an identified crime makes the offended faction hostile FULL STOP; the
# scalar tunes degree and recovery. _crime_ledger is BEHAVIOURALLY INERT —
# it answers what a fine costs and what dialogue says, and appears on no AI,
# targeting, hearing, or hostility path (the D2 mitigation; test-asserted).
var _player_standing: Dictionary = {}    # faction_id -> int
var _crime_ledger: Dictionary = {}       # faction_id -> {records: Array, days_served: float}
var _hostile_override: Dictionary = {}   # faction_id -> true

func _ready() -> void:
	_load_database()
	_validate_relations()
	# TimeManager registers after FactionDatabase; connect once the tree is up.
	call_deferred("_connect_standing_decay")

func _connect_standing_decay() -> void:
	var tm = get_node_or_null("/root/TimeManager")
	if tm != null and tm.has_signal("date_changed"):
		tm.date_changed.connect(_on_date_changed_decay)

# Negative standing creeps back toward 0 (laws.json standing.decay_per_day).
# The hostile OVERRIDE never decays — being square with the law requires
# settling, not waiting.
func _on_date_changed_decay(_d, _m, _y) -> void:
	var decay: int = int(LawDatabase.standing_cfg().get("decay_per_day", 1.0))
	if decay <= 0:
		return
	for fid in _player_standing.keys():
		var v: int = int(_player_standing[fid])
		if v < 0:
			adjust_player_standing(str(fid), mini(decay, -v))

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

# The player's stance with a faction: "hostile" | "neutral" | "friendly".
# ONE argument on purpose — a two-argument variant invites _is_enemy to pass
# NPC pairs per-frame and read the player's standing as an answer for
# bandits-vs-wildlife. Base relation (declared ally +40 / enemy −60, read
# from the faction's own lists both directions) + the runtime scalar,
# thresholded; the override carries D8's binary above all of it.
func player_stance_toward(other_faction: String) -> String:
	if bool(_hostile_override.get(other_faction, false)):
		return "hostile"
	var base: int = 0
	if are_enemies(other_faction, "player") or are_enemies("player", other_faction):
		base = -60
	elif are_allies(other_faction, "player") or are_allies("player", other_faction):
		base = 40
	var value: int = base + get_player_standing(other_faction)
	var cfg: Dictionary = LawDatabase.standing_cfg()
	if value <= int(cfg.get("hostile_at", -50)):
		return "hostile"
	if value >= int(cfg.get("friendly_at", 50)):
		return "friendly"
	return "neutral"

# How `observer_faction` regards `other_faction`: "hostile", "ally" or
# "neutral", for display (stance colours, tooltips). Derived from the oracle,
# never beside it: "hostile" exactly when are_hostile says so. Otherwise a pair
# involving the player reads player_stance_toward ("friendly" -> "ally"), so
# standing shows; any other pair is "ally" when are_friendly (same faction or
# allied either way). Symmetric, and quiet for ids factions.json doesn't define.
func get_stance(observer_faction: String, other_faction: String) -> String:
	if observer_faction == other_faction:
		return "ally"
	if are_hostile(observer_faction, other_faction):
		return "hostile"
	if observer_faction == "player" or other_faction == "player":
		var other: String = other_faction if observer_faction == "player" else observer_faction
		return "ally" if player_stance_toward(other) == "friendly" else "neutral"
	if are_friendly(observer_faction, other_faction):
		return "ally"
	return "neutral"

# ---------------------------------------------------------------------------
# Standing / ledger / override API (mirrors the tier API above)
# ---------------------------------------------------------------------------

func get_player_standing(faction_id: String) -> int:
	return int(_player_standing.get(faction_id, 0))

func adjust_player_standing(faction_id: String, delta: int) -> void:
	if faction_id.is_empty():
		return
	var cfg: Dictionary = LawDatabase.standing_cfg()
	var old_value: int = get_player_standing(faction_id)
	var new_value: int = clampi(old_value + delta, int(cfg.get("floor", -250)), int(cfg.get("cap", 100)))
	if new_value == old_value:
		return
	_player_standing[faction_id] = new_value
	player_standing_changed.emit(faction_id, old_value, new_value)

## D8's binary: identified crime -> the offended faction is hostile, full
## stop. Cleared only by settle() or a pardon, never by time or the scalar.
func mark_outlaw(faction_id: String) -> void:
	if faction_id.is_empty() or bool(_hostile_override.get(faction_id, false)):
		return
	_hostile_override[faction_id] = true
	var v: int = get_player_standing(faction_id)
	player_standing_changed.emit(faction_id, v, v)

func is_outlaw_with(faction_id: String) -> bool:
	return bool(_hostile_override.get(faction_id, false))

func is_outlaw_anywhere() -> bool:
	return not _hostile_override.is_empty()

## Ledger entry — pricing and dialogue ONLY. Never read on a behaviour path.
func record_crime(faction_id: String, verdict: Dictionary, ctx: Dictionary = {}) -> void:
	if faction_id.is_empty():
		return
	var bucket: Dictionary = _crime_ledger.get(faction_id, {"records": [], "days_served": 0.0})
	bucket["records"].append({
		"statute": str(verdict.get("statute", "")),
		"display_name": str(verdict.get("display_name", "")),
		"severity": int(verdict.get("severity", 0)),
		"at": TimeManager.absolute_time(),
		"settled": false,
		"ctx": ctx,
	})
	_crime_ledger[faction_id] = bucket

func crime_records(faction_id: String) -> Array:
	return _crime_ledger.get(faction_id, {}).get("records", [])

func _unsettled_severity(faction_id: String) -> int:
	var total: int = 0
	for record in crime_records(faction_id):
		if not bool(record.get("settled", false)):
			total += int(record.get("severity", 0))
	return total

func fine_owed(faction_id: String) -> int:
	var per: float = float(LawDatabase.standing_cfg().get("fine_gold_per_severity", 12.0))
	return int(ceilf(float(_unsettled_severity(faction_id)) * per))

func jail_days_owed(faction_id: String) -> int:
	var per: float = float(LawDatabase.standing_cfg().get("jail_days_per_severity", 0.06))
	return int(ceilf(float(_unsettled_severity(faction_id)) * per))

## Square with the law: clears the override, FLOORS standing at 0 (square,
## not beloved), marks records settled WITHOUT deleting them — nobody has
## forgotten what you did, which is exactly the distinction the single
## scalar risked losing. Dialogue reads three states: never caught, wanted,
## did their time.
func settle(faction_id: String, mode: String = "") -> void:
	_hostile_override.erase(faction_id)
	var bucket: Dictionary = _crime_ledger.get(faction_id, {"records": [], "days_served": 0.0})
	if mode == "serve_time":
		bucket["days_served"] = float(bucket.get("days_served", 0.0)) + float(jail_days_owed(faction_id))
	for record in bucket.get("records", []):
		record["settled"] = true
	_crime_ledger[faction_id] = bucket
	var old_value: int = get_player_standing(faction_id)
	var new_value: int = maxi(old_value, 0)
	_player_standing[faction_id] = new_value
	player_standing_changed.emit(faction_id, old_value, new_value)

## Serialization (Phase 7's build_save_dict is the named caller).
func standing_to_dict() -> Dictionary:
	return {
		"player_standing": _player_standing.duplicate(true),
		"crime_ledger": _crime_ledger.duplicate(true),
		"hostile_override": _hostile_override.duplicate(true),
	}

func standing_from_dict(data: Dictionary) -> void:
	_player_standing = data.get("player_standing", {}).duplicate(true)
	_crime_ledger = data.get("crime_ledger", {}).duplicate(true)
	_hostile_override = data.get("hostile_override", {}).duplicate(true)
	for fid in _player_standing.keys():
		var v: int = int(_player_standing[fid])
		player_standing_changed.emit(str(fid), v, v)

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
