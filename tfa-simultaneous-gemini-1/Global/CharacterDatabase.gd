# Create a new script: res://CharacterDatabase.gd
# Note: No class_name needed for autoload singletons
extends Node

# Character data structure
class CharacterData:
	var character_id: String
	var character_name: String
	var sprite_texture_path: String
	var allegiance: CombatCharacter.Allegiance
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
	
	# NEW: Traits and equipment
	var traits: Dictionary = {} # e.g. {"deadeye": 1, "clumsy": 2}
	var equipped_weapon: StringName = &"short_sword"
	
	var abilities: Array[String] = [] # IDs of abilities this character knows
	
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

func _setup_character_data():
	# Player characters
	var hero_alpha = CharacterData.new("hero_alpha", "Hero Alpha", "res://hero1.png", CombatCharacter.Allegiance.PLAYER)
	hero_alpha.character_name = "Hero Alpha"
	hero_alpha.strength = 75
	hero_alpha.dexterity = 70
	hero_alpha.constitution = 60 
	hero_alpha.max_health = hero_alpha.constitution/5
	hero_alpha.current_health = hero_alpha.max_health
	hero_alpha.base_ap = 4
	print("Attempting to assign abilities #combat")
	hero_alpha.abilities.assign(["move", "basic_attack", "cleave"])
	hero_alpha.equipped_weapon = &"short_sword"
	hero_alpha.traits = {&"deadeye": 1}
	character_data["hero_alpha"] = hero_alpha
	print("hero_alpha.abilities",hero_alpha.abilities)
	var hero_beta = CharacterData.new("hero_beta", "Hero Beta", "res://hero2.png", CombatCharacter.Allegiance.PLAYER)
	hero_beta.character_name = "Hero Beta"
	hero_beta.strength = 75
	hero_beta.dexterity = 70
	hero_beta.max_health = hero_alpha.constitution/5
	hero_beta.current_health = hero_alpha.max_health
	hero_beta.base_ap = 4
	hero_beta.equipped_weapon = &"longbow"
	hero_beta.traits = {&"deadeye": 2}
	hero_beta.abilities.assign(["move", "basic_attack", &"cleave"])
	character_data["hero_beta"] = hero_beta
	print("hero_beta.abilities: ", hero_beta.abilities)
	
	# Enemy characters
	var goblin_scout = CharacterData.new("goblin_scout", "Goblin Scout", "res://Goblin.png", CombatCharacter.Allegiance.ENEMY)
	goblin_scout.character_name = "Goblin Scout"
	goblin_scout.strength = 75
	goblin_scout.dexterity = 70
	goblin_scout.max_health = hero_alpha.constitution/5
	goblin_scout.current_health = hero_alpha.max_health
	goblin_scout.base_ap = 3
	goblin_scout.traits = {&"clumsy": 2}
	goblin_scout.abilities.assign(["move", "basic_attack", "heavy_strike"])
	character_data["goblin_scout"] = goblin_scout
	
	var orc_brute = CharacterData.new("orc_brute", "Orc Brute", "res://orc.png", CombatCharacter.Allegiance.ENEMY)
	orc_brute.character_name = "Orc Brute"
	orc_brute.strength = 75
	orc_brute.dexterity = 70
	orc_brute.max_health = hero_alpha.constitution/5
	orc_brute.current_health = hero_alpha.max_health
	orc_brute.base_ap = 4
	orc_brute.abilities.assign(["move", "basic_attack", "heavy_strike"])
	
	character_data["orc_brute"] = orc_brute

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
