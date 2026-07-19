# item_database.gd
# Singleton database for looking up weapons and equipment by name
# Add to AutoLoad in Project Settings as "ItemDatabase"
extends Node
class_name ItemDatabaseClass

# Cached data from JSON files
var weapons: Dictionary = {}	# name -> weapon data
var equipment: Dictionary = {}	# name -> equipment data
var items: Dictionary = {}		# name -> general item data
# File paths (can be customized)
var items_json_path: String = "res://data/Items.json"

signal database_loaded
signal database_load_failed(error: String)

func _ready() -> void:
	# Auto-load databases on startup
	load_databases()

func load_databases() -> void:
	"""Load all item databases from the unified JSON file"""
	var success = _load_items_database()
	
	if success:
		emit_signal("database_loaded")
		#print("ItemDatabase: Loaded %d weapons, %d equipment" % [weapons.size(), equipment.size()])

func _load_items_database() -> bool:
	if not FileAccess.file_exists(items_json_path):
		var err_msg = "ItemDatabase: Items file not found at %s" % items_json_path
		push_warning(err_msg)
		emit_signal("database_load_failed", err_msg)
		return false
	
	var file = FileAccess.open(items_json_path, FileAccess.READ)
	if not file:
		var err_msg = "ItemDatabase: Failed to open items file"
		push_error(err_msg)
		emit_signal("database_load_failed", err_msg)
		return false
	
	var json = JSON.new()
	var error = json.parse(file.get_as_text())
	file.close()
	
	if error != OK:
		var err_msg = "ItemDatabase: Failed to parse items JSON: %s" % json.get_error_message()
		push_error(err_msg)
		emit_signal("database_load_failed", err_msg)
		return false
	
	var data = json.get_data()
	
	# Support both formats:
	# Old: {"weapons": [...], "equipment": [...]}
	# New: flat array [{"type": "sword", ...}, {"equip_slot": "Chest", ...}, ...]
	if data is Array:
		_parse_flat_item_list(data)
	elif data is Dictionary:
		if data.has("weapons"):
			for weapon_data in data["weapons"]:
				var weapon_name = weapon_data.get("name", "")
				if weapon_name:
					weapons[weapon_name.to_lower()] = weapon_data
		if data.has("equipment"):
			for equip_data in data["equipment"]:
				var equip_name = equip_data.get("name", "")
				if equip_name:
					equipment[equip_name.to_lower()] = equip_data
		# Also handle flat list inside a dictionary wrapper
		if data.has("items"):
			_parse_flat_item_list(data["items"])
	
	return true

func _parse_flat_item_list(item_list: Array) -> void:
	"""Sort a flat array of items into weapons, equipment, and general items by type."""
	var weapon_types = ["sword", "longsword", "axe", "dagger", "spear", "mace", "bow", "weapon", "pistol", "gun", "club", "hammer", "staff", "glaive", "pike"]
	var equipment_types = ["armor", "helmet", "shield", "boots", "gloves", "ring", "amulet", "cloak", "belt", "hood", "cape", "backpack", "pants", "leggings", "greaves", "breastplate"]
	for item_data in item_list:
		var item_name = item_data.get("display_name", item_data.get("name", ""))
		if not item_name:
			continue
		var item_key = Globals.name_to_id(item_name)
		var item_type = item_data.get("type", "").to_lower()
		var target: Dictionary = items
		if item_type in weapon_types:
			target = weapons
		elif item_type in equipment_types:
			target = equipment
		target[item_key] = item_data
		# ALSO register under the JSON "id": structure resource drops and map
		# item_spawns look items up by id ("wood"), but display-name keying
		# stores "Wood Log" as "wood_log" -- the id lookup missed, so drops
		# spawned as invisible textureless ghosts. Alias shares the same dict.
		var id_key = str(item_data.get("id", ""))
		if id_key != "" and id_key != item_key and not target.has(id_key):
			target[id_key] = item_data

# ===== CURRENCY =====

func is_currency(data: Dictionary) -> bool:
	"""True if an item-data dict is flagged with the Currency trait (gold,
	cigarette, or anything else tagged {"Currency": >=1})."""
	var item_traits = data.get("traits", {})
	if not (item_traits is Dictionary):
		return false
	var cv = item_traits.get("Currency", 0)
	return cv != null and int(cv) >= 1

func currency_item_datas() -> Array:
	"""All item-data dicts with the Currency trait. Payout systems (chest change,
	downtime pay) draw money from this pool, so any Currency-tagged item can
	circulate as currency without hardcoding an id."""
	var result: Array = []
	for key in items:
		var data = items[key]
		if data is Dictionary and is_currency(data):
			result.append(data)
	return result

func currency_item_ids() -> Array:
	"""Ids of all Currency-trait items."""
	var ids: Array = []
	for data in currency_item_datas():
		ids.append(str(data.get("id", "")))
	return ids

func random_currency_data(fallback_id: String = "gold") -> Dictionary:
	"""A random Currency-trait item's data, for minting a payout. Falls back to
	the fallback id's data (then {}) if nothing is tagged."""
	var pool := currency_item_datas()
	if pool.is_empty():
		var fb: Dictionary = items.get(fallback_id, {})
		return fb
	var chosen: Dictionary = pool[randi() % pool.size()]
	return chosen

# ===== WEAPON LOOKUPS =====

func get_weapon_data(weapon_name: String) -> Dictionary:
	"""Get weapon data by name (case-insensitive)"""
	var key = weapon_name.to_lower()
	if weapons.has(key):
		return weapons[key].duplicate()
	push_warning("ItemDatabase: Weapon '%s' not found" % weapon_name)
	return {}

func get_weapon_names() -> Array:
	"""Get list of all weapon names"""
	var names = []
	for key in weapons:
		names.append(weapons[key].get("display_name", key))
	return names

func find_weapons_by_type(weapon_type: String) -> Array:
	"""Get all weapons of a specific type (sword, axe, etc.)"""
	var results = []
	for key in weapons:
		if weapons[key].get("type", "").to_lower() == weapon_type.to_lower():
			results.append(weapons[key].duplicate())
	return results

func find_weapons_by_damage_type(damage_type: String) -> Array:
	"""Get all weapons with a specific damage type (slashing, piercing, bludgeoning)"""
	var results = []
	for key in weapons:
		if weapons[key].get("damage_type", "").to_lower() == damage_type.to_lower():
			results.append(weapons[key].duplicate())
	return results

# ===== EQUIPMENT LOOKUPS =====

func get_equipment_data(equipment_name: String) -> Dictionary:
	"""Get equipment data by name (case-insensitive)"""
	var key = equipment_name.to_lower()
	if equipment.has(key):
		return equipment[key].duplicate()
	push_warning("ItemDatabase: Equipment '%s' not found" % equipment_name)
	return {}

func get_equipment_names() -> Array:
	"""Get list of all equipment names"""
	var names = []
	for key in equipment:
		names.append(equipment[key].get("display_name", key))
	return names

func find_equipment_by_type(equip_type: String) -> Array:
	"""Get all equipment of a specific type (helmet, torso_armor, etc.)"""
	var results = []
	for key in equipment:
		if equipment[key].get("type", "").to_lower() == equip_type.to_lower():
			results.append(equipment[key].duplicate())
	return results

func find_equipment_by_slot(slot_name: String) -> Array:
	"""Get all equipment for a specific slot (head, torso, back, legs, feet)"""
	var type_mapping = {
		"head": ["helmet", "hood"],
		"torso": ["torso_armor", "breastplate", "chestplate", "armor"],
		"back": ["cape", "cloak", "backpack"],
		"legs": ["pants", "leggings"],
		"feet": ["boots", "greaves"]
	}
	
	var results = []
	var valid_types = type_mapping.get(slot_name.to_lower(), [])
	
	for key in equipment:
		var item_type = equipment[key].get("type", "").to_lower()
		if item_type in valid_types:
			results.append(equipment[key].duplicate())
	
	return results

# ===== UTILITY =====

func reload_databases() -> void:
	"""Force reload of all databases"""
	weapons.clear()
	equipment.clear()
	load_databases()

func set_database_path(items_path: String) -> void:
	"""Set custom path for the unified database file"""
	items_json_path = items_path

func get_item_data(item_id: String) -> Dictionary:
	"""Get any item data by id, searching all categories (items, weapons, equipment)"""
	var key = Globals.name_to_id(item_id)
	if items.has(key):
		return items[key].duplicate()
	if weapons.has(key):
		return weapons[key].duplicate()
	if equipment.has(key):
		return equipment[key].duplicate()
	push_warning("ItemDatabase: Item '%s' not found" % item_id)
	return {}

func has_weapon(weapon_name: String) -> bool:
	return weapons.has(weapon_name.to_lower())

func has_equipment(equipment_name: String) -> bool:
	return equipment.has(equipment_name.to_lower())

# ===== DIRECT CREATION =====

func create_weapon(weapon_name: String) -> WeaponShape:
	"""Create a WeaponShape instance directly from database"""
	var data = get_weapon_data(weapon_name)
	if data.is_empty():
		return null
	
	var weapon = WeaponShape.new()
	weapon.load_from_data(data)
	return weapon

func create_equipment(equipment_name: String) -> EquipmentShape:
	"""Create an EquipmentShape instance directly from database"""
	var data = get_equipment_data(equipment_name)
	if data.is_empty():
		return null
	
	var equip = EquipmentShape.new()
	equip.load_from_data(data)
	return equip
