# RegionDatabase.gd
# Autoload singleton - add to Project > AutoLoad as "RegionDatabase".
# Must load AFTER MapDatabase, FactionDatabase, and TopDownCharacterDatabase.
extends Node

var _regions: Dictionary = {}        # region_id -> region dict
var _map_to_region: Dictionary = {}  # map_id -> region_id (cached on load)

func _ready() -> void:
	_load_database()

func _load_database() -> void:
	var file_path = "res://data/regions.json"
	if not FileAccess.file_exists(file_path):
		push_error("Region Database not found at: " + file_path)
		return

	var file = FileAccess.open(file_path, FileAccess.READ)
	var content = file.get_as_text()
	var json = JSON.new()
	var error = json.parse(content)
	print("====== Region Database =======")
	if error == OK:
		var data = json.get_data()
		for entry in data.get("regions", []):
			_regions[entry["id"]] = entry
			for map_id in entry.get("member_maps", []):
				_map_to_region[map_id] = entry["id"]
		print("Loaded %d regions" % _regions.size())
	else:
		push_error("Failed to parse Region JSON: " + json.get_error_message())
	print("====== End Region Database ======")

# ---------------------------------------------------------------------------
# Lookup
# ---------------------------------------------------------------------------

func get_region_data(region_id: String) -> Dictionary:
	if _regions.has(region_id):
		return _regions[region_id]
	return {}

func get_all_region_ids() -> Array:
	return _regions.keys()

func get_region_for_map(map_id: String) -> String:
	## Returns the region_id this map belongs to, or "" if it's wilderness.
	if _map_to_region.has(map_id):
		return _map_to_region[map_id]
	# Fallback: read from MapDatabase in case regions.json missed it but the
	# map JSON has a "region" field directly.
	var map_data: Dictionary = MapDatabase.get_map_data(map_id)
	return str(map_data.get("region", ""))

func get_controlling_faction(region_id: String) -> String:
	var data = get_region_data(region_id)
	return str(data.get("controlling_faction", ""))

func get_member_maps(region_id: String) -> Array:
	var data = get_region_data(region_id)
	return data.get("member_maps", [])

# ---------------------------------------------------------------------------
# Service registry
# ---------------------------------------------------------------------------
# Scans every member map's npc_spawns, picks templates with non-empty titles,
# and returns a flat list of service entries — usable without loading any map.
func get_service_npcs_in_region(region_id: String) -> Array:
	var entries: Array = []
	for map_id in get_member_maps(region_id):
		var map_data: Dictionary = MapDatabase.get_map_data(map_id)
		for spawn in map_data.get("npc_spawns", []):
			var template_id: String = str(spawn.get("template_id", ""))
			if template_id.is_empty():
				continue
			var template: Dictionary = TopDownCharacterDatabase.get_template(template_id)
			if template.is_empty():
				continue
			# Per-spawn titles override > template titles
			var titles: Array = spawn.get("titles", template.get("titles", []))
			if titles.is_empty():
				continue
			var unique_name: String = str(spawn.get("unique_name", ""))
			var display_name: String = unique_name if not unique_name.is_empty() else str(template.get("name", template_id))
			var pos_arr = spawn.get("position", [0, 0])
			var entry := {
				"template_id": template_id,
				"unique_name": unique_name,
				"npc_uid": _build_npc_uid(template_id, unique_name),
				"display_name": display_name,
				"titles": titles,
				"map_id": map_id,
				"position": Vector2(pos_arr[0], pos_arr[1]),
				"icon": str(template.get("icon", "")),
				"dialogue": str(template.get("dialogue", "")),
				"faction": str(template.get("faction", "neutral")),
			}
			entries.append(entry)
	return entries

# Stable identifier for a service NPC across save/load and map transitions.
# A unique_name is preferred; otherwise multiple instances of the same template
# share the same uid (acceptable for animals like the Houndmaster's hounds).
func _build_npc_uid(template_id: String, unique_name: String) -> String:
	if unique_name.is_empty():
		return template_id
	return template_id + "/" + unique_name

# ---------------------------------------------------------------------------
# Law / legality checks
# ---------------------------------------------------------------------------

static func title_to_id(title: String) -> String:
	return title.to_lower().replace(" ", "_").replace("/", "_").replace("-", "_")

func is_service_legal(titles: Array, region_id: String) -> bool:
	## Returns true unless any of the character's titles is illegal under the
	## controlling faction's laws.
	var faction_id: String = get_controlling_faction(region_id)
	if faction_id.is_empty():
		return true
	var faction: Dictionary = FactionDatabase.get_faction_data(faction_id)
	var laws: Array = faction.get("laws", [])
	if laws.is_empty():
		return true
	for t in titles:
		if title_to_id(str(t)) in laws:
			return false
	return true
