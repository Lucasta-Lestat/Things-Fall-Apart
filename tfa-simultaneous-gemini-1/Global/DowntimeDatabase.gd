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

# Why the last pick_result came back empty: "cooldown" when eligible results
# existed but were all used recently, "no_outcome" otherwise, "" on a pick.
var last_empty_reason: String = ""

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
		# Training gate. Unlike every other filter here this one is party-relative
		# rather than world-relative: the card only makes sense when somebody in
		# the party actually owes a teacher days IN THIS REGION. It has to appear
		# on the board for any of them (the card is a drop target), so we test the
		# whole party here and DowntimeResolver refuses the drop for a specific
		# character who has no commitment.
		if bool(a.get("requires_training", false)):
			if not any_party_member_can_train(region_id):
				continue
		out.append(activity_id)
	return out

## True when at least one live party member has an open training commitment
## whose teacher is in `region_id`.
func any_party_member_can_train(region_id: String) -> bool:
	var training = get_node_or_null("/root/TrainingManager")
	if training == null:
		return false
	var game = get_node_or_null("/root/Game")
	if game == null or not ("party_chars" in game):
		return false
	for c in game.party_chars:
		if c != null and is_instance_valid(c) and training.can_train_here(c, region_id):
			return true
	return false

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

## Today as a whole-day count: TimeManager.today(), the days lived since the
## game began. Cooldown entries are {"result_id", "day"} on this count, so 7
## days is 7 days across New Year and a leap year's Yearturn alike.
func _current_day() -> int:
	return int(TimeManager.today())

# Cooldowns are keyed per activity so results sharing an id across activities
# (quiet_night, the_pox, close_call) don't block each other.
static func _cooldown_key(activity_id: String, result_id: String) -> String:
	return result_id if activity_id.is_empty() else activity_id + ":" + result_id

func is_on_cooldown(character_uid: String, result_id: String, activity_id: String = "") -> bool:
	var game = _game()
	if game == null:
		return false
	var key := _cooldown_key(activity_id, result_id)
	var bucket: Array = game.downtime_recent_events.get(character_uid, [])
	var now := _current_day()
	for entry in bucket:
		if String(entry.get("result_id", "")) != key or not entry.has("day"):
			continue
		if now - int(entry["day"]) < COOLDOWN_DAYS:
			return true
	return false

func mark_used(character_uid: String, result_id: String, activity_id: String = "") -> void:
	var game = _game()
	if game == null:
		return
	var bucket: Array = game.downtime_recent_events.get(character_uid, [])
	# Prune any entries older than the cooldown window so the list stays small.
	var now := _current_day()
	var keep: Array = []
	for entry in bucket:
		if entry.has("day") and now - int(entry["day"]) < COOLDOWN_DAYS:
			keep.append(entry)
	keep.append({"result_id": _cooldown_key(activity_id, result_id), "day": now})
	game.downtime_recent_events[character_uid] = keep

# ---------------------------------------------------------------------------
# Save migration: the old day index
# ---------------------------------------------------------------------------
# Before the day-count fix an entry was {"result_id", "day_abs"} with day_abs =
# year*372 + month*36 + day. That is not a day count: it jumped 13 at New Year
# (so anything used in a year's last 6 days came back on New Year's Day) and
# put a leap year's Yearturn (month 0) below every other day of that year (so
# every recent entry stayed blocked through all 12 Yearturn days).

## Convert a loaded downtime_recent_events to the day count. Game.apply_save_dict
## calls this after it has restored the saved date and day count. Entries
## already on the day count ("day") pass through untouched, so a save made
## after the fix round-trips unchanged. An old entry is decoded back to its
## calendar date and its age taken through TimeManager.day_number. Entries
## whose 7 days are already over are dropped (they block nothing); so are
## entries that can't be read (no date has that index, or it is later than the
## save's own date): at worst that outcome can come up again early.
func migrate_recent_events(events: Dictionary) -> Dictionary:
	var today_number: int = TimeManager.day_number(int(TimeManager.current_day),
		int(TimeManager.current_month), int(TimeManager.current_year))
	var now := _current_day()
	var unreadable := 0
	var out: Dictionary = {}
	for uid in events.keys():
		var bucket = events[uid]
		if not (bucket is Array):
			out[uid] = bucket
			continue
		var kept: Array = []
		for entry in bucket:
			if not (entry is Dictionary) or entry.has("day") or not entry.has("day_abs"):
				kept.append(entry)
				continue
			var age := _old_index_age(entry["day_abs"], today_number)
			if age < 0:
				unreadable += 1
			elif age < COOLDOWN_DAYS:
				kept.append({"result_id": String(entry.get("result_id", "")), "day": now - age})
		out[uid] = kept
	if unreadable > 0:
		push_warning("DowntimeDatabase: dropped %d downtime cooldown entr%s from this save that could not be dated; those outcomes are available again." % [unreadable, "y" if unreadable == 1 else "ies"])
	return out

## Days between the date an old index (year*372 + month*36 + day) stood for
## and today_number (a TimeManager.day_number), or -1 when it can't be read.
## The old index is ambiguous: Mistumnal 12-36 spilled into the next year's
## range, where a leap year's Yearturn days also sit. Of the dates it can
## stand for, the most recent one not after today is taken.
func _old_index_age(raw, today_number: int) -> int:
	if not (raw is int or raw is float):
		return -1
	var index := int(raw)
	if index <= 0:
		return -1
	var year: int = index / 372
	var r: int = index % 372
	var dates: Array = []  # [day, month, year]
	if r >= 37:
		var month: int = (r - 1) / 36
		dates.append([r - month * 36, month, year])
	if r <= 24:
		dates.append([r + 12, 10, year - 1])
	if r >= 1 and r <= TimeManager.YEARTURN_LENGTH and TimeManager.is_leap_year(year):
		dates.append([r, 0, year])
	var best := -1
	for dmy in dates:
		var age: int = today_number - TimeManager.day_number(dmy[0], dmy[1], dmy[2])
		if age >= 0 and (best < 0 or age < best):
			best = age
	return best

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
## candidate passed the filters (caller falls back to a "nothing happens" line
## and can read last_empty_reason to say why).
func pick_result(activity: Dictionary, region_id: String, character, success_tier: int, activity_id: String = "") -> Dictionary:
	last_empty_reason = ""
	var raw: Array = _gather_result_candidates(activity, region_id)
	if raw.is_empty():
		last_empty_reason = "no_outcome"
		return {}
	var char_traits: Dictionary = character.traits if character != null and "traits" in character else {}
	var uid := character_uid(character)
	# Training is a booked run of consecutive days with a handful of outcomes;
	# the 7-day variety cooldown would use them up partway through a stay.
	var use_cooldown: bool = not bool(activity.get("requires_training", false))
	var filtered: Array = []
	var total_weight: int = 0
	var cooled_down: int = 0
	for cand in raw:
		var data: Dictionary = cand["data"]
		if int(data.get("min_success_tier", 0)) > success_tier:
			continue
		if not passes_trait_filter(char_traits, data.get("required_traits", {}), data.get("forbidden_traits", {})):
			continue
		if use_cooldown and is_on_cooldown(uid, String(cand["id"]), activity_id):
			cooled_down += 1
			continue
		var weight: int = max(1, int(data.get("weight", 1)))
		filtered.append({"id": cand["id"], "data": data, "weight": weight})
		total_weight += weight
	if filtered.is_empty():
		last_empty_reason = "cooldown" if cooled_down > 0 else "no_outcome"
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
