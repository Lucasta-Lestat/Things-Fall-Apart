# PlayerDatabase.gd
# This is an autoload script (singleton) that manages all player profiles and piece data.
# It saves and loads player chess sets from a JSON file.

extends Node

# --- Data Storage ---
# This dictionary will hold all loaded player profiles.
var player_profiles = {
		"starter_set": {
			"name": "Protagonist",
			"portrait": "../icon.svg",
			"peasants": {"Pawn": 4},
			"nobles": {"Valkyrie": 2, "Rifleman": 1},
			"royals": {"Pontifex": 1}
		},
		"knight_heavy": {
			"name": "Gleg",
			"peasants": {"Kulak": 4},
			"nobles": {"Nightrider": 3},
			"royals": {"Chancellor": 1}
		},
		"god": {
			"name": "God",
			"portrait": "../icon.svg",
			"peasants": {"Kulak": 2, "Pawn":2},
			"nobles": { "Bishop": 1, "Cannonier":1, "Centaur":1, "Devil Toad":1, "Dragonrider": 1, "Gorgon":1, "Knight": 1,"Monk":1, "Nightrider": 1, "Princess": 1, "Queen":1, "Rifleman": 1, "Rook": 1, "Valkyrie": 1 },
			"royals": {"Chancellor": 1, "Lady of the Lake":1, "Pontifex":1, "King": 1}
		},
		"Zionis": {
			"name":"Zionis",
			"portrait":"../ui/portraits/Zionis Portrait.png",
			"peasants": {"Kulak": 4},
			"nobles": {"Cannonier":3},
			"royals": {"King":1}
		},
		
		
	}

# This dictionary acts as a master list for all piece properties.
const PIECE_DEFINITIONS = {
	#Peasants:
	"Kulak": {"scene": "res://scenes/pieces/Kulak.tscn",  "category": "peasant"},
	"Pawn": {"scene": "res://scenes/pieces/Pawn.tscn",  "category": "peasant"},
	
	#Nobles:
	"Bishop": {"scene": "res://scenes/pieces/Bishop.tscn",  "category": "noble"},
	"Cannonier": { "category": "noble", "scene": "res://scenes/pieces/Cannonier.tscn"},
	"Centaur": {"category":"noble", "scene": "res://scenes/pieces/Centaur.tscn" },
	"Devil Toad":{ "category":"noble", "scene": "res://scenes/pieces/DevilToad.tscn"},
	"Dragonrider":{ "category": "noble", "scene": "res://scenes/pieces/Dragonrider.tscn"},
	"Gorgon":{ "category": "noble", "scene": "res://scenes/pieces/Gorgon.tscn"},
	"Knight": {"category":"noble", "scene": "res://scenes/pieces/Knight.tscn"},
	"Monk": { "scene": "res://scenes/pieces/Monk.tscn", "category": "noble"},
	"Nightrider": {"scene": "res://scenes/pieces/Nightrider.tscn", "category": "noble"},
	"Princess": {"category":"noble", "scene": "res://scenes/pieces/Princess.tscn"},
	"Queen": { "category":"noble", "scene": "res://scenes/pieces/Queen.tscn"},
	"Rifleman": {"scene": "res://scenes/pieces/Rifleman.tscn", "category": "noble"},
	"Rook":{ "category": "noble", "scene": "res://scenes/pieces/Rook.tscn"},
	"Valkyrie": {"scene": "res://scenes/pieces/Valkyrie.tscn", "category": "noble"},
	#Royals:
	"Chancellor": {"scene": "res://scenes/pieces/Chancellor.tscn",  "category": "royal"},
	"King": {"category":"royal", "scene": "res://scenes/pieces/King.tscn"},
	"Lady of the Lake": { "category": "royal", "scene": "res://scenes/pieces/LadyOfTheLake.tscn"},
	"Pontifex": {"scene": "res://scenes/pieces/Pontifex.tscn",  "category": "royal"}
	
}

const SAVE_FILE_PATH = "user://player_profiles.json"

# Called when the node enters the scene tree for the first time (at game launch).
func _ready():
	create_default_profiles()
	load_profiles()

# --- Public Functions ---
func get_profile(profile_name):
	print("DEBUG: get_profile called with profile name: ", profile_name, "result: ", player_profiles.get(profile_name))
	
	return player_profiles.get(profile_name)

func get_piece_data(piece_type):
	return PIECE_DEFINITIONS.get(piece_type)

# --- Save/Load Logic ---
func save_profiles():
	var file = FileAccess.open(SAVE_FILE_PATH, FileAccess.WRITE)
	var json_string = JSON.stringify(player_profiles)
	file.store_string(json_string)
	print("Player profiles saved.")

func load_profiles():
	if FileAccess.file_exists(SAVE_FILE_PATH):
		var file = FileAccess.open(SAVE_FILE_PATH, FileAccess.READ)
		var json_string = file.get_as_text()
		var json = JSON.new()
		var error = json.parse(json_string)
		if error == OK:
			player_profiles = json.data
			print("Player profiles loaded.")
		else:
			print("Error loading player profiles: ", json.get_error_message())
			create_default_profiles()
	else:
		print("No save file found. Creating default profiles.")
		create_default_profiles()

func create_default_profiles():
	player_profiles = {
		"starter_set": {
			"name": "Protagonist",
			"portrait": "../icon.svg",
			"peasants": {"Pawn": 4},
			"nobles": {"Valkyrie": 2, "Rifleman": 1},
			"royals": {"Pontifex": 1}
		},
		"knight_heavy": {
			"peasants": {"Kulak": 4},
			"nobles": {"Nightrider": 3},
			"royals": {"Chancellor": 1}
		},
		"god": {
			"name": "God",
			"portrait": "../icon.svg",
			"peasants": {"Kulak": 2, "Pawn":2},
			"nobles": { "Bishop": 1, "Cannonier":1, "Centaur":1, "Devil Toad":1, "Dragonrider": 1, "Gorgon":1, "Knight": 1,"Monk":1, "Nightrider": 1, "Princess": 1, "Queen":1, "Rifleman": 1, "Rook": 1, "Valkyrie": 1 },
			"royals": {"Chancellor": 1, "Lady of the Lake":1, "Pontifex":1, "King": 1}
		},
		"Zionis": {
			"name":"Zionis",
			"portrait":"../ui/portraits/Zionis Portrait.png",
			"peasants": {"Kulak": 4},
			"nobles": {"Cannonier":3},
			"royals": {"King":1}
		},
		"Saratov": {
			"name":"Saratov",
			"portrait":"../ui/portraits/Saratov Portrait.png",
			"peasants": {"Basic Automata": 4},
			"nobles": {"Cannonier":2, "Rifleman": 1},
			"royals": {"Chancellor":1}
		},
		"Hanub": {
			"name":"Hanub",
			"portrait":"../ui/portraits/Hanub Portrait.png",
			"peasants": {"Kulaks": 4},
			"nobles": {"Cannonier":1, "Rifleman": 3, "Elephant": 3},
			"royals": {"Chancellor":1}
		}
		
	}
	save_profiles() # Save the defaults so the file exists next time
