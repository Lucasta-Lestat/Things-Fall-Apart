# item_database.gd
# Singleton database for looking up weapons and equipment by name
# Add to AutoLoad in Project Settings as "ItemDatabase"
extends Node
class_name ItemDatabaseClass

# Cached data from JSON files
var weapons: Dictionary = {}      # name -> weapon data
var equipment: Dictionary = {}    # name -> equipment data

# File paths (can be customized)
var weapons_json_path: String = "res://data/weapons_shapes.json"
var equipment_json_path: String = "res://data/equipment_shapes.json"

signal database_loaded
signal database_load_failed(error: String)

func _ready() -> void:
	# Auto-load databases on startup
	load_databases()

func load_databases() -> void:
	"""Load all item databases from JSON files"""
	var success = true
	
	if not _load_weapons_database():
		success = false
	
	if not _load_equipment_database():
		success = false
	
	if success:
		emit_signal("database_loaded")
		print("ItemDatabase: Loaded %d weapons, %d equipment" % [weapons.size(), equipment.size()])

func _load_weapons_database() -> bool:
	if not FileAccess.file_exists(weapons_json_path):
		push_warning("ItemDatabase: Weapons file not found at %s" % weapons_json_path)
		return false
	
	var file = FileAccess.open(weapons_json_path, FileAccess.READ)
	if not file:
		push_error("ItemDatabase: Failed to open weapons file")
		return false
	
	var json = JSON.new()
	var error = json.parse(file.get_as_text())
	file.close()
	
	if error != OK:
		push_error("ItemDatabase: Failed to parse weapons JSON: %s" % json.get_error_message())
		return false
	
	var data = json.get_data()
	if data.has("weapons"):
		for weapon_data in data["weapons"]:
			var name = weapon_data.get("name", "")
			if name:
				weapons[name.to_lower()] = weapon_data
	
	return true

func _load_equipment_database() -> bool:
	if not FileAccess.file_exists(equipment_json_path):
		push_warning("ItemDatabase: Equipment file not found at %s" % equipment_json_path)
		return false
	
	var file = FileAccess.open(equipment_json_path, FileAccess.READ)
	if not file:
		push_error("ItemDatabase: Failed to open equipment file")
		return false
	
	var json = JSON.new()
	var error = json.parse(file.get_as_text())
	file.close()
	
	if error != OK:
		push_error("ItemDatabase: Failed to parse equipment JSON: %s" % json.get_error_message())
		return false
	
	var data = json.get_data()
	if data.has("equipment"):
		for equip_data in data["equipment"]:
			var id = equip_data.get("id", "")
			if id:
				equipment[id] = equip_data
	
	return true

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
		names.append(weapons[key].get("name", key))
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
	var key = Globals.name_to_id(equipment_name)
	if equipment.has(key):
		return equipment[key].duplicate()
	push_warning("ItemDatabase: Equipment '%s' not found" % equipment_name)
	return {}

func get_equipment_names() -> Array:
	"""Get list of all equipment names"""
	var names = []
	for key in equipment:
		names.append(equipment[key].get("name", key))
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

func set_database_paths(weapons_path: String, equipment_path: String) -> void:
	"""Set custom paths for database files"""
	weapons_json_path = weapons_path
	equipment_json_path = equipment_path

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
