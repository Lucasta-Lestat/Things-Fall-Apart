# res://Data/Items/EquipmentDatabase.gd
# AUTOLOAD this script as "EquipmentDatabase", replacing the old ones.
extends Node

var equipment_data: Dictionary = {}

func _ready():
	_setup_equipment_data()
	print_debug("Unified EquipmentDatabase initialized with ", equipment_data.size(), " items.")

func _setup_equipment_data():
	# --- ARMOR ---
	var iron_plate_armor = Equipment.new()
	iron_plate_armor.id = &"iron_plate_armor"
	iron_plate_armor.name = "Iron Plate Armor"
	iron_plate_armor.slot = Equipment.Slot.ARMOR
	iron_plate_armor.damage_resistances = { &"slashing": 3, &"piercing": 3, &"bludgeoning": 3, &"fire": -2, &"electric": -2 }
	equipment_data[iron_plate_armor.id] = iron_plate_armor
	
	# --- RINGS ---
	var ring_of_protection = Equipment.new()
	ring_of_protection.id = &"ring_of_protection"
	ring_of_protection.name = "Ring of Protection"
	ring_of_protection.slot = Equipment.Slot.RING
	ring_of_protection.damage_resistances = {&"slashing": 1, &"piercing": 1, &"bludgeoning": 1}
	equipment_data[ring_of_protection.id] = ring_of_protection
	
	# --- WEAPONS (now defined as Equipment) ---
	var short_sword = Equipment.new()
	short_sword.id = &"shortsword"
	short_sword.name = "Short Sword"
	short_sword.slot = Equipment.Slot.MAIN_HAND
	short_sword.damage = { &"piercing": 4}
	short_sword.primary_damage_type = "piercing"
	short_sword.aoe_shape = Ability.AttackShape.THRUST
	short_sword.aoe_size = Vector2i(1, 1)
	equipment_data[short_sword.id] = short_sword

	var greatsword = Equipment.new()
	greatsword.id = &"greatsword"
	greatsword.name = "Greatsword"
	greatsword.slot = Equipment.Slot.MAIN_HAND # Could be two-handed later
	greatsword.damage = {&"slashing": 7}
	greatsword.primary_damage_type = "slashing"
	greatsword.aoe_shape = Ability.AttackShape.SLASH
	greatsword.aoe_size = Vector2i(2, 2)
	equipment_data[greatsword.id] = greatsword
	
	var longbow = Equipment.new()
	longbow.id = &"longbow"
	longbow.name = "Longbow"
	longbow.slot = Equipment.Slot.MAIN_HAND # Requires both hands in reality, simple for now
	longbow.range = 1024
	longbow.aoe_shape = Weapon.AttackShape.RECTANGLE # A single arrow hits one tile
	longbow.aoe_size = Vector2i(1, 1)
	longbow.damage = {&"piercing": 6}
	longbow.primary_damage_type = "piercing"
	equipment_data[longbow.id] = longbow
	
	# --- SHIELDS (new item type) ---
	var iron_shield = Equipment.new()
	iron_shield.id = &"iron_shield"
	iron_shield.name = "Iron Shield"
	iron_shield.slot = Equipment.Slot.OFF_HAND
	iron_shield.damage_resistances = {&"slashing": 2, &"piercing": 2, &"bludgeoning": 2, &"electric": -1, &"fire": -1}
	iron_shield.damage = {&"bludgeoning": 2}
	iron_shield.primary_damage_type = "bludgeoning"
	iron_shield.aoe_shape = Ability.AttackShape.SLASH
	iron_shield.aoe_size = Vector2i(1, 1)
	# Note: No damage properties, so it's not a weapon.
	equipment_data[iron_shield.id] = iron_shield
	

func get_equipment(equipment_id: StringName) -> Equipment:
	if not equipment_id: return null
	if equipment_data.has(equipment_id):
		return equipment_data[equipment_id]
	print_rich("[color=red]Warning: Equipment ID '", equipment_id, "' not found in database.[/color]")
	return null
