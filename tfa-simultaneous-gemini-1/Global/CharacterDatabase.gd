# Create a new script: res://CharacterDatabase.gd
#class_name CharacterDatabase
extends Resource
'''
# Character data structure
class CharacterData:
	var character_id: String
	var display_name: String
	var sprite_texture_path: String
	var allegiance: CombatCharacter.Allegiance
	var base_health: int = 100
	var base_dexterity: int = 10
	var base_ap: int = 4
	var default_abilities: Array[String] = []
	
	func _init(id: String = "", name: String = "", sprite: String = "", ally: CombatCharacter.Allegiance = CombatCharacter.Allegiance.PLAYER):
		character_id = id
		display_name = name
		sprite_texture_path = sprite
		allegiance = ally

# Static character database
static var character_data: Dictionary = {}

static func _static_init():
	# Initialize character database
	_setup_character_data()

static func _setup_character_data():
	# Player characters
	var hero_alpha = CharacterData.new("hero_alpha", "Hero Alpha", "res://hero1.png", CombatCharacter.Allegiance.PLAYER)
	hero_alpha.base_dexterity = 12
	hero_alpha.base_ap = 4
#	hero_alpha.default_abilities = ["move", "basic_attack", "heavy_strike"]
	character_data["hero_alpha"] = hero_alpha
	
	var hero_beta = CharacterData.new("hero_beta", "Hero Beta", "res://hero2.png", CombatCharacter.Allegiance.PLAYER)
	hero_beta.base_dexterity = 9
	hero_beta.base_ap = 4
	hero_beta.default_abilities = ["move", "basic_attack", "heavy_strike"]
	character_data["hero_beta"] = hero_beta
	
	# Enemy characters
	var goblin_scout = CharacterData.new("goblin_scout", "Goblin Scout", "res://goblin.png", CombatCharacter.Allegiance.ENEMY)
	goblin_scout.base_dexterity = 10
	goblin_scout.base_ap = 3
	goblin_scout.default_abilities = ["move", "basic_attack", "heavy_strike"]
	character_data["goblin_scout"] = goblin_scout
	
	var orc_brute = CharacterData.new("orc_brute", "Orc Brute", "res://orc.png", CombatCharacter.Allegiance.ENEMY)
	orc_brute.base_dexterity = 7
	orc_brute.base_ap = 3
	orc_brute.base_health = 150
	orc_brute.default_abilities = ["move", "basic_attack", "heavy_strike"]
	character_data["orc_brute"] = orc_brute

static func get_character_data(character_id: String) -> CharacterData:
	if character_data.has(character_id):
		return character_data[character_id]
	else:
		print("Warning: Character ID '", character_id, "' not found in database")
		return null

static func get_all_character_ids() -> Array[String]:
	var ids: Array[String] = []
	for key in character_data.keys():
		ids.append(key)
	return ids
'''
