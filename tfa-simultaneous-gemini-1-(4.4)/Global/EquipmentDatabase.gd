# res://Data/Items/EquipmentDatabase.gd
# AUTOLOAD this script as "EquipmentDatabase", replacing the old ones.
extends Node
'''
var body_size = 70
var head_size = 40
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
	short_sword.aoe_shape = &"thrust"
	short_sword.aoe_size = Vector2i(1, 1)
	equipment_data[short_sword.id] = short_sword

	var greatsword = Equipment.new()
	greatsword.id = &"greatsword"
	greatsword.name = "Greatsword"
	greatsword.slot = Equipment.Slot.MAIN_HAND # Could be two-handed later
	greatsword.damage = {&"slashing": 7}
	greatsword.primary_damage_type = "slashing"
	greatsword.aoe_shape =&"slash"
	greatsword.aoe_size = Vector2i(2, 2)
	equipment_data[greatsword.id] = greatsword
	
	var longbow = Equipment.new()
	longbow.id = &"longbow"
	longbow.name = "Longbow"
	longbow.slot = Equipment.Slot.MAIN_HAND # Requires both hands in reality, simple for now
	longbow.range = 1024
	longbow.aoe_shape = "rectangle" # A single arrow hits one tile
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
	iron_shield.aoe_shape = "rectangle"
	iron_shield.aoe_size = Vector2i(1, 1)
	# Note: No damage properties, so it's not a weapon.
	equipment_data[iron_shield.id] = iron_shield
	

func get_equipment(equipment_id: StringName) -> Equipment:
	if not equipment_id: return null
	if equipment_data.has(equipment_id):
		return equipment_data[equipment_id]
	print_rich("[color=red]Warning: Equipment ID '", equipment_id, "' not found in database.[/color]")
	return null

func _define_body_parts(body_part_names: Array):
	const path_to_body_parts = "res://Characters/Assets/"
	for name in body_part_names:
		var body_part = BodyPart.new()
		body_part.id = name
		
		var path_to_front = path_to_body_parts + name + " Front.png"
		var path_to_back = path_to_body_parts + name + " Back.png"
		var path_to_left = path_to_body_parts + name + " Left.png"
		var path_to_right = path_to_body_parts + name + " Right.png"
		print("path to this part: ", path_to_front)
		
		body_part.texture_front = load(path_to_front)
		body_part.texture_back = load(path_to_back)
		body_part.texture_left = load(path_to_left)
		body_part.texture_right = load(path_to_right)
		if "Head" in name:
			body_part.type = "head"
			#resize 
			var image = body_part.texture_front.get_image()
			image = image.duplicate()
			image.resize(head_size,head_size, Image.INTERPOLATE_LANCZOS)
			var new_texture = ImageTexture.create_from_image(image)
			body_part.texture_front = new_texture
			
			var original_image = body_part.texture_back.get_image()
			image = original_image.duplicate()
			image.resize(head_size,head_size, Image.INTERPOLATE_LANCZOS)
			new_texture = ImageTexture.create_from_image(image)
			body_part.texture_back = new_texture
			
			image = body_part.texture_left.get_image()
			image.resize(head_size,head_size)
			image.resize(head_size,head_size, Image.INTERPOLATE_LANCZOS)
			new_texture = ImageTexture.create_from_image(image)
			body_part.texture_left = new_texture
			
			image = body_part.texture_right.get_image()
			image.resize(head_size,head_size)
			image.resize(head_size,head_size, Image.INTERPOLATE_LANCZOS)
			new_texture = ImageTexture.create_from_image(image)
			body_part.texture_right = new_texture
			
		elif "Armor" in name:
			body_part.type = "Armor"
			#resize
			var image = body_part.texture_front.get_image()
			image = image.duplicate()
			image.resize(body_size,body_size, Image.INTERPOLATE_LANCZOS)
			var new_texture =  ImageTexture.create_from_image(image)
			body_part.texture_front = new_texture
			
			image = body_part.texture_back.get_image()
			image = image.duplicate()
			image.resize(body_size,body_size, Image.INTERPOLATE_LANCZOS)
			new_texture =  ImageTexture.create_from_image(image)
			body_part.texture_back = new_texture
			
			image = body_part.texture_left.get_image()
			image = image.duplicate()
			image.resize(body_size,body_size, Image.INTERPOLATE_LANCZOS)
			new_texture =  ImageTexture.create_from_image(image)
			body_part.texture_left = new_texture
			
			image = body_part.texture_right.get_image()
			image = image.duplicate()
			image.resize(body_size,body_size, Image.INTERPOLATE_LANCZOS)
			new_texture =  ImageTexture.create_from_image(image)
			body_part.texture_right = new_texture
			
'''
