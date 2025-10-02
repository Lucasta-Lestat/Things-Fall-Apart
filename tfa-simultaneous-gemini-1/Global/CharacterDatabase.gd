# Create a new script: res://CharacterDatabase.gd
# Note: No class_name needed for autoload singletons
extends Node

# Character data structure
var character_definitions = [
	{"name": "Protagonist", "generic":false, "Allegiance": CombatCharacter.Allegiance.PLAYER},
	{"name": "Jacana", "generic":false, "Allegiance": CombatCharacter.Allegiance.PLAYER},
	{"name": "goblin_scout", "race": "Orc", "generic": true, "Type": "Tank", "gender": "Male", "Allegiance": CombatCharacter.Allegiance.ENEMY},
	{"name": "orc_brute", "race": "Orc", "generic": true, "Type": "Basic Warrior", "gender": "Female", "Allegiance": CombatCharacter.Allegiance.ENEMY}

	
	
]
var orcish_names_male = [
	"Grimwald", "Chlodwig", "Hrothgar", "Wolfram", "Sigibert", "Adalbert", "Theudoric", "Gundohar", "Chilperic", "Arnulf"
]
var orcish_names_female = [
	"Kriemhilt", "Thusnelda", "Gerlinde", "Brunichild", "Fredegund", "Radegund", "Clothild", "Grimhild", "Theodelind", "Aldegund"
]
var names = {"Orc Male": orcish_names_male, "Orc Female": orcish_names_female}
var racial_bonuses = {"Orc":{"strength": 20}}
var greenskin_faction = {"name": "Greenskins", "Male Names": orcish_names_male, "Female Names": orcish_names_female, 
"Support Title": "Hornist", "Cavalry Title": "Rittmeister", "Elite Title": "Hauptmann", "Tank Title": "Knecht", "Basic Warrior Title": "Spiesser"  }

var basic_warrior_stats = {"constitution": 60, "dexterity":50, "strength": 65, "intelligence":45, "will":55, "charisma": 50}
var basic_warrior_abilities = [&"basic_attack", &"move"]
#The abilties database should actually define a dictionary of abilities by race and faction
var tank_stats = {"constitution": 75, "dexterity":40, "strength": 75, "intelligence":45, "will":55, "charisma": 50}
var basic_tank_abilities = [&"basic_attack",&"cleave", &"move"]
var rogue_stats = {"constitution": 50, "dexterity":65, "strength": 50, "intelligence":60, "will":45, "charisma": 55}
var dps_int_stats = {"constitution": 45, "dexterity":40, "strength": 45, "intelligence":75, "will":55, "charisma": 50}
var dps_cha_stats = {"constitution": 45, "dexterity":40, "strength": 45, "intelligence":50, "will":55, "charisma": 75}
var dps_wil_stats = {"constitution": 45, "dexterity":40, "strength": 45, "intelligence":50, "will":75, "charisma": 55}

var basic_warrior_gear = {} #when you've fleshed out items and their traits a bit more, have a list 
							#of options for each gear slot, filter based on what types of gear it would 
							#be appropriate for that type of character to have, based on faction and tier of faction

var starting_stats = {"Protagonist": 
						 {"constitution": 100, "dexterity":100, "strength": 5, "intelligence":100, "will":5, "charisma": 5}, 
					"Jacana": 
						rogue_stats
						
					}
var starting_gear = {"Protagonist":
	 					{"weapon": &"greatsword", "armor":&"iron_plate_armor", "ring1": &"ring_of_protection"}, 
					"Jacana": 
						{"weapon": &"longbow", "armor": &"iron_plate_armor"}}
var starting_abilities = {"Protagonist":
							[&"move", &"basic_attack", &"cleave", &"fireball"],
						"Jacana":
							[&"move", &"basic_attack", &"cleave", &"fireball"]
						}

class CharacterData:
	var character_id: String
	var character_name: String
	var sprite_texture_path: String
	var allegiance: CombatCharacter.Allegiance
	
	var race: String # for now
	var gender: String
	
	var icon: String
	var base_ap: int = 4
	var strength: int = 50
	var dexterity: int = 50
	var constitution: int = 50
	var will: int = 50
	var intelligence: int = 50
	var charisma: int = 50
	var max_health = 11
	var current_health = max_health
	var base_touch_range: int = 50.0
	var base_size = 128
	var icon_size: Vector2 = Vector2(100.0,100.0)
	var size_class = 1
	# --- UNIFIED EQUIPMENT SLOTS ---
	var equipped_main_hand: StringName
	var equipped_off_hand: StringName
	var equipped_head: StringName
	var equipped_armor: StringName
	var equipped_gloves: StringName
	var equipped_boots: StringName
	var equipped_cape: StringName
	var equipped_neck: StringName
	var equipped_ring1: StringName
	var equipped_ring2: StringName
	
	var damage_resistances: Dictionary
	# Traits and equipment
	var traits: Dictionary = {} # e.g. {"deadeye": 1, "clumsy": 2}
	
	var abilities: Array[String] = [] # IDs of abilities this character knows
	
	# --- NEW: Visual Definition ---
	var visual_parts: Dictionary = { "head": &"Male Head 1", "body": &"Male Body 1" }
	
	func _init(id: String = "", name: String = "", sprite: String = "", ally: CombatCharacter.Allegiance = CombatCharacter.Allegiance.PLAYER):
		character_id = id
		character_name = name
		sprite_texture_path = sprite
		allegiance = ally

# Character database
var character_data: Dictionary = {}

func _ready():
	# Initialize character database
	_setup_character_data()
	for id in character_data:
		print(character_data[id])
func _setup_character_data():
	var character
	for char_def in character_definitions:
		if char_def.Allegiance == CombatCharacter.Allegiance.PLAYER: 
			character = CharacterData.new(char_def["name"], char_def["name"], "res://hero1.png", CombatCharacter.Allegiance.PLAYER)
		else:
			character = CharacterData.new(char_def["name"], char_def["name"], "res://hero1.png", CombatCharacter.Allegiance.ENEMY)

		if char_def["name"] and not char_def.generic:
			print("char name: ", char_def["name"], "being created")
			var body_id = char_def["name"] + " Body"
			print("body_id in character database: ", body_id)
			var head_id = char_def["name"] + " Head"
			if BodyPartDatabase.body_parts.has(body_id):
				character.visual_parts["body"] = body_id
			else:
				character.visual_parts["body"] = "Male Body 1"
				
			if BodyPartDatabase.body_parts.has(head_id):
				character.visual_parts["head"] = head_id
			else:
				print("didn't find head: ", head_id)
				character.visual_parts["head"] = "Male Head 1"
		var specific_racial_bonuses = {"constituion": 0, "dexterity":0, "strength":0, "intelligence":0, "will":0, "charisma":0}
		if char_def.has("race"):
			for bonus in racial_bonuses[char_def["race"]]:
				specific_racial_bonuses[bonus] += racial_bonuses[char_def["race"]][bonus]
		if char_def.has("gender"):
			character.gender = char_def.gender
		else:
			character.gender = "Male"
		if char_def.has("race"):
			character.race  = char_def.race
		
		if char_def["generic"]:
			
			print("race: ", character.race)
			var body_id = char_def["gender"] + " " + char_def["race"] + " Body 1"
			if BodyPartDatabase.body_parts.has(body_id):
				character.visual_parts["body"] = body_id
			else:
				character.visual_parts["body"] = "Male Body 1"
			var head_id = char_def["gender"] + " " + char_def["race"]  + " Head 1"
			if BodyPartDatabase.body_parts.has(head_id):
				character.visual_parts["head"] = head_id
			else:
				print("didn't find head: ", head_id)
				character.visual_parts["head"] = "Male Head 1"

			#character.character_name = names[character.race + " " + character.gender].pick_random()
			print("character: ", character.character_name, " is being created")
			if char_def["Type"] == "Tank":
				character.strength = tank_stats.strength + specific_racial_bonuses.strength
				character.dexterity = tank_stats.dexterity + specific_racial_bonuses.dexterity
				character.constitution = tank_stats.constitution +specific_racial_bonuses.constituion
				character.will = tank_stats.will + specific_racial_bonuses.will 
				character.intelligence = tank_stats.intelligence + specific_racial_bonuses.intelligence
				character.charisma = tank_stats.charisma + specific_racial_bonuses.charisma
				character.equipped_main_hand = &"greatsword"
				character.equipped_armor = &"iron_plate_armor"
				character.equipped_ring1 = &"ring_of_protection"
				#combine with list of abilities per race
				#create that after you've redefined the combat system and know how you want them to work.
				character.abilities.assign(basic_tank_abilities)
			elif char_def["Type"] == "Basic Warrior":
				character.strength = basic_warrior_stats.strength + specific_racial_bonuses.strength
				character.dexterity = basic_warrior_stats.dexterity + specific_racial_bonuses.dexterity
				character.constitution = basic_warrior_stats.constitution + specific_racial_bonuses.constituion
				character.will = basic_warrior_stats.will + specific_racial_bonuses.will 
				character.intelligence = basic_warrior_stats.intelligence + specific_racial_bonuses.intelligence
				character.charisma = basic_warrior_stats.charisma + specific_racial_bonuses.charisma
				character.equipped_main_hand = &"shortsword"
				character.equipped_armor = &"iron_plate_armor"
				character.abilities.assign(basic_warrior_abilities)
		else:
			#Find the starting stats and equipment based on that character's name
			character.strength = starting_stats[character.character_name].strength + specific_racial_bonuses.strength
			character.dexterity = starting_stats[character.character_name].dexterity + specific_racial_bonuses.dexterity
			character.constitution = starting_stats[character.character_name].constitution +specific_racial_bonuses.constituion
			character.will = starting_stats[character.character_name].will + specific_racial_bonuses.will 
			character.intelligence = starting_stats[character.character_name].intelligence + specific_racial_bonuses.intelligence
			character.charisma = starting_stats[character.character_name].charisma + specific_racial_bonuses.charisma
			character.equipped_main_hand = starting_gear[character.character_name].weapon
			character.equipped_armor = starting_gear[character.character_name].armor
			if starting_gear[character.character_name].has("ring1"):
				character.equipped_ring1 = &"ring_of_protection"
			#for gear in starting_gear[character.name]:
			#come up with a good safe for loop some other time
			print("Attempting to assign abilities #combat")
			character.abilities.assign(starting_abilities[character.character_name])
				
		character.base_ap = 4
		character.max_health = character.constitution/5
		character.current_health = character.max_health
		character_data[character.character_name] = character

func get_character_data(character_id: String) -> CharacterData:
	if character_data.has(character_id):
		return character_data[character_id]
	else:
		print("Warning: Character ID '", character_id, "' not found in database")
		return null

func get_all_character_ids() -> Array[String]:
	var ids: Array[String] = []
	for key in character_data.keys():
		ids.append(key)
	return ids
