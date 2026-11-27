class_name RigLibrary
extends RefCounted
## Loads and caches the data under res://Rigs: the canonical skeleton, race
## packs (with variant inheritance) and item packs. Pure data, no nodes.

const ROOT: String = "res://Rigs"

static var _skeleton: Dictionary = {}
static var _races: Dictionary = {}
static var _items: Dictionary = {}
static var _item_ids: Dictionary = {}
static var _hand_sets: Dictionary = {}


static func _read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		var d: Dictionary = parsed
		return d
	push_warning("RigLibrary: %s is not a JSON object" % path)
	return {}


static func skeleton() -> Dictionary:
	if _skeleton.is_empty():
		_skeleton = _read(ROOT + "/skeleton.json")
	return _skeleton


static func race_dir(race: String, variant: String = "default") -> String:
	return "%s/races/%s/%s" % [ROOT, race, variant]


static func has_race(race: String, variant: String = "default") -> bool:
	return FileAccess.file_exists(race_dir(race, variant) + "/race.json")


## A race pack. A variant holding only art inherits everything else from the
## variant named in "inherits"; "_dirs" lists the folders to look for files in.
static func race(race_id: String, variant: String = "default") -> Dictionary:
	var key: String = race_id + "/" + variant
	if _races.has(key):
		var cached: Dictionary = _races[key]
		return cached
	var dir: String = race_dir(race_id, variant)
	var data: Dictionary = _read(dir + "/race.json")
	if data.is_empty():
		return {}
	var dirs: Array[String] = [dir]
	if data.has("inherits"):
		var base: Dictionary = race(race_id, str(data["inherits"]))
		if base.is_empty():
			push_warning("RigLibrary: %s inherits a missing variant" % key)
			return {}
		var merged: Dictionary = base.duplicate(true)
		var base_frames: Dictionary = merged.get("frames", {})
		var own_frames: Dictionary = data.get("frames", {})
		for k: String in data.keys():
			merged[k] = data[k]
		base_frames.merge(own_frames, true)
		merged["frames"] = base_frames
		var base_dirs: Array = base["_dirs"]
		for d: String in base_dirs:
			dirs.append(d)
		data = merged
	data["_dirs"] = dirs
	_races[key] = data
	return data


## Resolve a pack-relative file through the variant chain.
static func race_file(race_data: Dictionary, file_name: String) -> String:
	var dirs: Array = race_data["_dirs"]
	for d: String in dirs:
		var p: String = d + "/" + file_name
		if ResourceLoader.exists(p):
			return p
	return ""


static func variants(race_id: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var d: DirAccess = DirAccess.open("%s/races/%s" % [ROOT, race_id])
	if d != null:
		for sub: String in d.get_directories():
			if has_race(race_id, sub):
				out.append(sub)
	return out


static func item(item_id: String) -> Dictionary:
	if _items.has(item_id):
		var cached: Dictionary = _items[item_id]
		return cached
	var dir: String = "%s/items/%s" % [ROOT, item_id]
	var data: Dictionary = _read(dir + "/item.json")
	if not data.is_empty():
		data["_dir"] = dir
	_items[item_id] = data
	return data


## Rig item id for an Items.json id ("peasant's_stained_shirt" -> "peasants_stained_shirt").
## Each item pack lists the game ids it dresses in "item_ids"; an item pack whose
## folder name IS the game id needs no list.
static func item_for_game_id(game_id: String) -> String:
	if _item_ids.is_empty():
		var d: DirAccess = DirAccess.open(ROOT + "/items")
		if d != null:
			for sub: String in d.get_directories():
				var data: Dictionary = item(sub)
				if data.is_empty():
					continue
				_item_ids[sub] = sub
				var ids: Array = data.get("item_ids", [])
				for gid: Variant in ids:
					_item_ids[str(gid)] = sub
	return str(_item_ids.get(game_id, ""))


static func clear_cache() -> void:
	_skeleton = {}
	_races = {}
	_items = {}
	_item_ids = {}
	_hand_sets = {}


## A hand set (Rigs/hands/<name>/hand.json): the shared fist every race closes its
## hand into. Empty when it is not installed.
static func hand_set(set_name: String = "humanoid") -> Dictionary:
	if _hand_sets.has(set_name):
		var cached: Dictionary = _hand_sets[set_name]
		return cached
	var dir: String = "%s/hands/%s" % [ROOT, set_name]
	var data: Dictionary = _read(dir + "/hand.json")
	if not data.is_empty():
		data["_dir"] = dir
	_hand_sets[set_name] = data
	return data


static func race_hand_set(race_data: Dictionary) -> Dictionary:
	var hands: Dictionary = skeleton().get("hands", {})
	return hand_set(str(race_data.get("hand_set", hands.get("default_set", "humanoid"))))
