## DowntimeDatabase (autoload)
## Loads res://data/downtime.json once and answers the questions the downtime
## UI / resolver need:
##   - which activities are available in a region (urban / rural / faction-legal)
##   - which activities sit on the right-side camp panel
##   - which extra activities a character's abilities grant (e.g. meditation)
##   - given an activity + region + character + ability-check success tier,
##     pick a result honouring weights, required/forbidden traits, min success
##     tier, and a 7-day per-character cooldown stored on Game.
##
## All data is treated as read-only after load; cooldown state lives on
## Game.downtime_recent_events so it round-trips with the existing save flow.
extends Node

const DATA_PATH := "res://data/downtime.json"
const COOLDOWN_DAYS := 7

# Raw {activity_id: activity_dict} map.
var activities: Dictionary = {}

# Ordered list of activity ids that fill the right-side camp panel.
var camp_activity_ids: Array = []

func _ready() -> void:
	_load()

func _load() -> void:
	if not FileAccess.file_exists(DATA_PATH):
		push_warning("DowntimeDatabase: %s not found" % DATA_PATH)
		return
	var text: String = FileAccess.get_file_as_string(DATA_PATH)
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("DowntimeDatabase: failed to parse %s" % DATA_PATH)
		return
	activities = parsed.get("activities", {})
	camp_activity_ids = parsed.get("camp_activities", [])

# ---------------------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------------------

func get_activity(activity_id: String) -> Dictionary:
	return activities.get(activity_id, {})

func get_all_activity_ids() -> Array:
	return activities.keys()

## Activities that are available given the player's current region.
## - Empty region_id is treated as wilderness (no urban activities).
## - In an urban region, both urban and rural activities are eligible
##   provided their legal_title (if any) is permitted by the faction's laws.
## - Camp-stack ids are excluded — those live on the right panel.
func get_activities_for_region(region_id: String) -> Array:
	var out: Array = []
	var in_wilderness := region_id.is_empty()
	var is_urban := false
	if not in_wilderness:
		var rdata: Dictionary = RegionDatabase.get_region_data(region_id)
		is_urban = bool(rdata.get("is_urban", true))  # default true for backwards compat
	for activity_id in activities.keys():
		if activity_id in camp_activity_ids:
			continue
		var a: Dictionary = activities[activity_id]
		if in_wilderness:
			if not bool(a.get("rural", false)):
				continue
		else:
			if is_urban:
				if not bool(a.get("urban", false)):
					continue
			else:
				if not bool(a.get("rural", false)):
					continue
		# Faction legality. Only gate on activities that name a legal_title.
		var legal_title: String = String(a.get("legal_title", ""))
		if not legal_title.is_empty() and not in_wilderness:
			if not RegionDatabase.is_service_legal([legal_title], region_id):
				continue
		# Saint-day gate: activities tagged `requires_saint_day` only show on
		# days when SaintCalendar.is_saint_day() is true. The Feasting activity
		# uses this so the temple feast only appears when there's a feast to
		# attend.
		if bool(a.get("requires_saint_day", false)):
			var saint_cal = get_node_or_null("/root/SaintCalendar")
			if saint_cal == null or not saint_cal.is_saint_day():
				continue
		out.append(activity_id)
	return out

func get_camp_activities() -> Array:
	return camp_activity_ids.duplicate()

## Camp-stack activities available on a given map. An activity that declares
## a non-empty "available_maps" list only appears when the current map_id is in
## that list (e.g. mining at Argentiara's shafts); activities without the field
## remain available everywhere, preserving the previous behaviour.
func get_camp_activities_for_map(map_id: String) -> Array:
	var out: Array = []
	for aid in camp_activity_ids:
		var a: Dictionary = activities.get(String(aid), {})
		var allowed: Array = a.get("available_maps", [])
		if allowed.is_empty() or map_id in allowed:
			out.append(aid)
	return out

## Walks a character's inventory abilities and returns the set of downtime
## activity ids granted by any of them (via the optional "grants_downtime_activity"
## field on ability data).
func get_extra_activities_for_character(character) -> Array:
	var out: Array = []
	if character == null:
		return out
	var inv = character.get_node_or_null("Inventory") if character.has_method("get_node_or_null") else null
	if inv == null:
		return out
	for it in inv.stowed_items:
		if it == null or not ("raw_data" in it):
			continue
		var raw: Dictionary = it.raw_data
		var granted := String(raw.get("grants_downtime_activity", ""))
		if granted.is_empty() or granted in out:
			continue
		out.append(granted)
	return out

# ---------------------------------------------------------------------------
# Trait filtering (mirrors TopDownCharacterDatabase._item_passes_trait_filter)
# Accepts both Array["TraitName"] (tier-1 minimum) and Dict{"TraitName": tier}.
# ---------------------------------------------------------------------------

static func _trait_value(spec, key: String) -> int:
	if typeof(spec) == TYPE_DICTIONARY:
		return int(spec.get(key, 0))
	return 0

static func _trait_keys(spec) -> Array:
	if typeof(spec) == TYPE_DICTIONARY:
		return spec.keys()
	if typeof(spec) == TYPE_ARRAY:
		return spec
	return []

static func passes_trait_filter(character_traits: Dictionary, required, forbidden) -> bool:
	# required: every named trait must be present at >= required tier (default 1).
	for k in _trait_keys(required):
		var key := String(k)
		var req_tier: int = max(1, _trait_value(required, key))
		var have: int = int(character_traits.get(key, 0))
		if have < req_tier:
			return false
	# forbidden: every named trait must be ABSENT or below the forbidden tier.
	for k in _trait_keys(forbidden):
		var key := String(k)
		var forb_tier: int = max(1, _trait_value(forbidden, key))
		var have: int = int(character_traits.get(key, 0))
		if have >= forb_tier:
			return false
	return true

# ---------------------------------------------------------------------------
# Result picker
# ---------------------------------------------------------------------------

## Compose the candidate result pool for a (activity, region) pair. Results
## are stored under either "any_map" (always merge) or a key matching the
## region_id. Returns Array of {id, data}.
func _gather_result_candidates(activity: Dictionary, region_id: String) -> Array:
	var out: Array = []
	var results: Dictionary = activity.get("results", {})
	for bucket_key in results.keys():
		var bk := String(bucket_key)
		if bk != "any_map" and bk != region_id:
			continue
		var bucket: Dictionary = results[bucket_key]
		for rid in bucket.keys():
			out.append({"id": String(rid), "data": bucket[rid]})
	return out

func _current_day_abs() -> int:
	# Coarse absolute-day index sufficient for a 7-day cooldown comparison.
	# Yearturn (month=0) lasts 12 days; treat it as month 0 for ordering.
	var y := int(TimeManager.current_year)
	var m := int(TimeManager.current_month)
	var d := int(TimeManager.current_day)
	return y * 372 + m * 36 + d

func is_on_cooldown(character_uid: String, result_id: String) -> bool:
	var game = _game()
	if game == null:
		return false
	var bucket: Array = game.downtime_recent_events.get(character_uid, [])
	var now := _current_day_abs()
	for entry in bucket:
		if String(entry.get("result_id", "")) != result_id:
			continue
		if now - int(entry.get("day_abs", 0)) < COOLDOWN_DAYS:
			return true
	return false

func mark_used(character_uid: String, result_id: String) -> void:
	var game = _game()
	if game == null:
		return
	var bucket: Array = game.downtime_recent_events.get(character_uid, [])
	# Prune any entries older than the cooldown window so the list stays small.
	var now := _current_day_abs()
	var keep: Array = []
	for entry in bucket:
		if now - int(entry.get("day_abs", 0)) < COOLDOWN_DAYS:
			keep.append(entry)
	keep.append({"result_id": result_id, "day_abs": now})
	game.downtime_recent_events[character_uid] = keep

static func character_uid(character) -> String:
	if character == null:
		return ""
	if character.has_meta("template_id"):
		var tid := String(character.get_meta("template_id"))
		var uname := String(character.get_meta("unique_name", ""))
		return tid if uname.is_empty() else tid + "/" + uname
	if "display_name" in character:
		return String(character.display_name)
	return String(character.name)

## Pick a result. Returns {"id": ..., "data": ...} or empty dict if no
## candidate passed the filters (caller falls back to a "nothing happens" line).
func pick_result(activity: Dictionary, region_id: String, character, success_tier: int) -> Dictionary:
	var raw: Array = _gather_result_candidates(activity, region_id)
	if raw.is_empty():
		return {}
	var char_traits: Dictionary = character.traits if character != null and "traits" in character else {}
	var uid := character_uid(character)
	var filtered: Array = []
	var total_weight: int = 0
	for cand in raw:
		var data: Dictionary = cand["data"]
		if int(data.get("min_success_tier", 0)) > success_tier:
			continue
		if not passes_trait_filter(char_traits, data.get("required_traits", {}), data.get("forbidden_traits", {})):
			continue
		if is_on_cooldown(uid, String(cand["id"])):
			continue
		var weight: int = max(1, int(data.get("weight", 1)))
		filtered.append({"id": cand["id"], "data": data, "weight": weight})
		total_weight += weight
	if filtered.is_empty():
		return {}
	var roll := randi() % total_weight
	var acc := 0
	for f in filtered:
		acc += int(f["weight"])
		if roll < acc:
			return {"id": f["id"], "data": f["data"]}
	return filtered.back()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _game() -> Node:
	return get_tree().root.get_node_or_null("Game")
