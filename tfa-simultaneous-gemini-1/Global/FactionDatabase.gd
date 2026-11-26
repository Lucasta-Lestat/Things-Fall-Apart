# FactionDatabase.gd
# Autoload singleton - add to Project > AutoLoad as "FactionDatabase"
extends Node

signal faction_tier_changed(faction_id: String, old_tier: int, new_tier: int)
## Fired on any change to the player's legal standing with a faction —
## adjust_player_standing, mark_outlaw, and settle all emit it. Game derives
## the `wanted` display condition from it.
signal player_standing_changed(faction_id: String, old_value: int, new_value: int)
## The wanted registry changed (marked, cleared, loaded). CrimeManager
## re-derives the `wanted` icon and its per-map enforcer cache from it.
signal wanted_changed()

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
# Wanted: PER REGION, PER CULPRIT. bucket (region id, else "map:<id>" for a
# map in no region, else "" in harnesses with no map) -> perp key
# ("party:<party_index>") -> {"law_faction", "name", "since", "crimes": []}.
# Written by an IDENTIFIED report (CrimeManager.on_alarm_heard) and the
# downtime "caught" outcome; cleared by settling with / a pardon from that law
# faction. Enforcers of the law attack a wanted character on sight in that
# region only (ai._is_enemy via CrimeManager.wanted_here). Saved.
var _wanted: Dictionary = {}

# --- Runtime factions and relation changes (dialogue actions) ---
# A dialogue can turn characters against someone ("make_hostile" moves them
# into a faction made at runtime) or change how two factions regard each other
# ("set_relation"). Both are DATA that are_allies / are_enemies read, so
# are_hostile stays the one oracle; both are saved with standing_to_dict.
var _runtime_factions: Dictionary = {}    # faction_id -> data (also in _factions)
var _relation_overrides: Dictionary = {}  # "a|b" (ids sorted) -> "ally" | "enemy" | "neutral"
# The same overrides as a -> {b: relation}, both ways round, for the lookup:
# are_allies / are_enemies run per frame inside every AI's target scan, so
# they must not build a key string per call. Derived; never saved.
var _relation_index: Dictionary = {}
const _NO_RELATIONS: Dictionary = {}

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
	if not _relation_overrides.is_empty():
		var o: String = _relation_override(faction_a, faction_b)
		if o != "":
			return o == "ally"
	var data_a: Dictionary = _faction_or_empty(faction_a)
	return faction_b in data_a.get("allies", [])

# One-directional by design: reads only faction_a's list. For behaviour
# (combat, menus, targeting) use are_hostile below, which is symmetric.
# A set_relation override for the pair (always mutual) wins over the lists.
func are_enemies(faction_a: String, faction_b: String) -> bool:
	if not _relation_overrides.is_empty():
		var o: String = _relation_override(faction_a, faction_b)
		if o != "":
			return o == "enemy"
	var data_a: Dictionary = _faction_or_empty(faction_a)
	return faction_b in data_a.get("enemies", [])

# ---------------------------------------------------------------------------
# Runtime relations and factions (dialogue actions)
# ---------------------------------------------------------------------------

func _relation_key(faction_a: String, faction_b: String) -> String:
	return faction_a + "|" + faction_b if faction_a < faction_b else faction_b + "|" + faction_a

func _relation_override(faction_a: String, faction_b: String) -> String:
	var row: Dictionary = _relation_index.get(faction_a, _NO_RELATIONS)
	return row.get(faction_b, "")

func _rebuild_relation_index() -> void:
	_relation_index.clear()
	for key in _relation_overrides:
		var ids: PackedStringArray = str(key).split("|")
		if ids.size() != 2:
			continue
		var rel: String = str(_relation_overrides[key])
		if not _relation_index.has(ids[0]):
			_relation_index[ids[0]] = {}
		if not _relation_index.has(ids[1]):
			_relation_index[ids[1]] = {}
		_relation_index[ids[0]][ids[1]] = rel
		_relation_index[ids[1]][ids[0]] = rel

## How two factions regard each other from now on, both ways: "enemy",
## "ally" or "neutral" (neither). Overrides factions.json for that one pair.
## False, and nothing changes, for an unknown faction or relation.
func set_relation(faction_a: String, faction_b: String, relation: String) -> bool:
	if faction_a == faction_b or not _factions.has(faction_a) or not _factions.has(faction_b):
		return false
	if not relation in ["enemy", "ally", "neutral"]:
		return false
	_relation_overrides[_relation_key(faction_a, faction_b)] = relation
	_rebuild_relation_index()
	return true

func is_runtime_faction(faction_id: String) -> bool:
	return _runtime_factions.has(faction_id)

## A faction made during play, copied from `base_id`: it keeps the base's
## friends and foes and counts the base itself as an ally, but holds no law
## (no law_code / policed_by). True if it exists afterwards.
func create_runtime_faction(faction_id: String, base_id: String, display_name: String = "") -> bool:
	if faction_id.is_empty():
		return false
	if _factions.has(faction_id):
		return true
	var data: Dictionary = _factions.get(base_id, {}).duplicate(true)
	data.erase("law_code")
	data.erase("policed_by")
	data["id"] = faction_id
	if not display_name.is_empty():
		data["name"] = display_name
	elif not data.has("name"):
		data["name"] = faction_id.capitalize()
	var allies: Array = data.get("allies", []).duplicate()
	if _factions.has(base_id) and not base_id in allies:
		allies.append(base_id)
	data["allies"] = allies
	data["enemies"] = data.get("enemies", []).duplicate()
	data["runtime_base"] = base_id
	_factions[faction_id] = data
	_runtime_factions[faction_id] = data
	return true

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

## Where a wanted entry lives for `map_id`: the map's region, else
## "map:<id>" (wilderness maps have no region), else "" (no map: harnesses).
func wanted_bucket(map_id: String) -> String:
	if map_id.is_empty():
		return ""
	var region_id: String = RegionDatabase.get_region_for_map(map_id)
	return region_id if not region_id.is_empty() else "map:" + map_id

func mark_wanted(bucket: String, perp_key: String, perp_name: String, law_faction: String, crime_name: String = "") -> void:
	if perp_key.is_empty() or law_faction.is_empty():
		return
	var region: Dictionary = _wanted.get(bucket, {})
	var entry: Dictionary = region.get(perp_key, {"law_faction": law_faction, "name": perp_name,
		"since": TimeManager.absolute_time(), "crimes": []})
	entry["law_faction"] = law_faction
	entry["name"] = perp_name
	if not crime_name.is_empty():
		(entry["crimes"] as Array).append(crime_name)
	region[perp_key] = entry
	_wanted[bucket] = region
	wanted_changed.emit()

func wanted_entry(bucket: String, perp_key: String) -> Dictionary:
	return (_wanted.get(bucket, {}) as Dictionary).get(perp_key, {})

func is_wanted(bucket: String, perp_key: String) -> bool:
	return not wanted_entry(bucket, perp_key).is_empty()

## Every wanted entry in a region: perp key -> entry.
func wanted_in(bucket: String) -> Dictionary:
	return (_wanted.get(bucket, {}) as Dictionary).duplicate(true)

## Whether `law_faction` wants anyone, in any region (a debt to settle).
func has_wanted_for_law(law_faction: String) -> bool:
	for bucket in _wanted:
		for key in _wanted[bucket]:
			if str((_wanted[bucket][key] as Dictionary).get("law_faction", "")) == law_faction:
				return true
	return false

## Squared with (or pardoned by) a law faction: every region's wanted entry
## under that law goes.
func clear_wanted_for_law(law_faction: String) -> void:
	var changed := false
	for bucket in _wanted.keys():
		var region: Dictionary = _wanted[bucket]
		for key in region.keys():
			if str((region[key] as Dictionary).get("law_faction", "")) == law_faction:
				region.erase(key)
				changed = true
		if region.is_empty():
			_wanted.erase(bucket)
	if changed:
		wanted_changed.emit()

## A party row left (Game.remove_party_member): its wanted entries go with
## it, and every later row's entries shift up one, as party_index does.
func party_row_removed(row: int) -> void:
	var changed := false
	for bucket in _wanted.keys():
		var region: Dictionary = _wanted[bucket]
		var rekeyed: Dictionary = {}
		for key in region.keys():
			var k: String = str(key)
			if not k.begins_with("party:"):
				rekeyed[k] = region[key]
				continue
			var n: int = int(k.substr(6))
			if n == row:
				changed = true
				continue
			if n > row:
				changed = true
				rekeyed["party:%d" % (n - 1)] = region[key]
			else:
				rekeyed[k] = region[key]
		if rekeyed.is_empty():
			_wanted.erase(bucket)
		else:
			_wanted[bucket] = rekeyed
	if changed:
		wanted_changed.emit()

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
		"runtime_factions": _runtime_factions.duplicate(true),
		"relation_overrides": _relation_overrides.duplicate(true),
		"wanted": _wanted.duplicate(true),
	}

func standing_from_dict(data: Dictionary) -> void:
	_player_standing = data.get("player_standing", {}).duplicate(true)
	_crime_ledger = data.get("crime_ledger", {}).duplicate(true)
	_hostile_override = data.get("hostile_override", {}).duplicate(true)
	for fid in _runtime_factions.keys():
		_factions.erase(fid)
	_runtime_factions = data.get("runtime_factions", {}).duplicate(true)
	for fid in _runtime_factions.keys():
		_factions[fid] = _runtime_factions[fid]
	_relation_overrides = data.get("relation_overrides", {}).duplicate(true)
	_rebuild_relation_index()
	for fid in _player_standing.keys():
		var v: int = int(_player_standing[fid])
		player_standing_changed.emit(str(fid), v, v)
	_wanted = data.get("wanted", {}).duplicate(true)
	wanted_changed.emit()

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
