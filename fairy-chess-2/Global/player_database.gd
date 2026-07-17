# PlayerDatabase.gd
# Autoload singleton holding player chess-set profiles and the master list of
# piece scenes. Profiles are reset to defaults at launch and mirrored to disk
# so the RPG layer can later persist customised sets.

extends Node

const SAVE_FILE_PATH = "user://player_profiles.json"

# Master list of piece scenes. Categories (peasant/noble/royal) live in
# Rules.PIECE_INFO; the "category" here is kept for the UI's convenience and
# must agree with it.
const PIECE_DEFINITIONS = {
	# Peasants:
	"Basic Automata": {"scene": "res://scenes/pieces/Basic Automata.tscn", "category": "peasant"},
	"Kulak": {"scene": "res://scenes/pieces/Kulak.tscn", "category": "peasant"},
	"Pawn": {"scene": "res://scenes/pieces/pawn.tscn", "category": "peasant"},
	"Zombie": {"scene": "res://scenes/pieces/Zombie.tscn", "category": "peasant"},
	"Raider": {"scene": "res://scenes/pieces/Raider.tscn", "category": "peasant"},
	"Cultist": {"scene": "res://scenes/pieces/Cultist.tscn", "category": "peasant"},
	"Werewolf (human form)": {"scene": "res://scenes/pieces/Werewolf (human form).tscn", "category": "peasant"},
	# Nobles:
	"Anarch": {"scene": "res://scenes/pieces/Anarch.tscn", "category": "noble"},
	"Bishop": {"scene": "res://scenes/pieces/Bishop.tscn", "category": "noble"},
	"Cannonier": {"scene": "res://scenes/pieces/Cannonier.tscn", "category": "noble"},
	"Centaur": {"scene": "res://scenes/pieces/Centaur.tscn", "category": "noble"},
	"Devil Toad": {"scene": "res://scenes/pieces/DevilToad.tscn", "category": "noble"},
	"Dragonrider": {"scene": "res://scenes/pieces/DragonRider.tscn", "category": "noble"},
	"Elephant Rider": {"scene": "res://scenes/pieces/ElephantRider.tscn", "category": "noble"},
	"Gorgon": {"scene": "res://scenes/pieces/Gorgon.tscn", "category": "noble"},
	"Grasshopper": {"scene": "res://scenes/pieces/Grasshopper.tscn", "category": "noble"},
	"Knight": {"scene": "res://scenes/pieces/Knight.tscn", "category": "noble"},
	"Minister": {"scene": "res://scenes/pieces/Minister.tscn", "category": "noble"},
	"Monk": {"scene": "res://scenes/pieces/Monk.tscn", "category": "noble"},
	"Nightrider": {"scene": "res://scenes/pieces/Nightrider.tscn", "category": "noble"},
	"Princess": {"scene": "res://scenes/pieces/Princess.tscn", "category": "noble"},
	"Queen": {"scene": "res://scenes/pieces/Queen.tscn", "category": "noble"},
	"Rifleman": {"scene": "res://scenes/pieces/Rifleman.tscn", "category": "noble"},
	"Rook": {"scene": "res://scenes/pieces/Rook.tscn", "category": "noble"},
	"Valkyrie": {"scene": "res://scenes/pieces/Valkyrie.tscn", "category": "noble"},
	"Werewolf (wolf form)": {"scene": "res://scenes/pieces/Werewolf (wolf form).tscn", "category": "noble"},
	# Royals:
	"Chancellor": {"scene": "res://scenes/pieces/Chancellor.tscn", "category": "royal"},
	"King": {"scene": "res://scenes/pieces/King.tscn", "category": "royal"},
	"Lady of the Lake": {"scene": "res://scenes/pieces/LadyOfTheLake.tscn", "category": "royal"},
	"Pontifex": {"scene": "res://scenes/pieces/Pontifex.tscn", "category": "royal"},
}

# Initialised inline so it is available to any script that reads profiles
# before this autoload's _ready runs (e.g. member initialisers).
var player_profiles = _default_profiles()


func _ready():
	save_profiles()


# --- Public Functions ---
func get_profile(profile_name):
	return player_profiles.get(profile_name)


func get_piece_data(piece_type):
	return PIECE_DEFINITIONS.get(piece_type)


# --- Save/Load ---
func save_profiles():
	var file = FileAccess.open(SAVE_FILE_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(player_profiles, "\t"))


func _default_profiles() -> Dictionary:
	return {
		"starter_set": {
			"name": "Protagonist",
			"portrait": "res://icon.svg",
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
			"portrait": "res://icon.svg",
			"peasants": {"Basic Automata": 1, "Kulak": 2, "Pawn": 2, "Zombie": 2, "Raider": 1, "Cultist": 1, "Werewolf (human form)": 1},
			"nobles": {"Anarch": 1, "Bishop": 1, "Cannonier": 1, "Centaur": 1, "Devil Toad": 1, "Grasshopper": 1, "Dragonrider": 1, "Elephant Rider": 1, "Gorgon": 1, "Knight": 1, "Monk": 1, "Minister": 1, "Nightrider": 1, "Princess": 1, "Queen": 1, "Rifleman": 1, "Rook": 1, "Valkyrie": 1},
			"royals": {"Chancellor": 1, "Lady of the Lake": 1, "Pontifex": 1, "King": 1}
		},
		"Zionis": {
			"name": "Zionis",
			"portrait": "res://ui/portraits/Zionis Portrait.png",
			"peasants": {"Kulak": 4},
			"nobles": {"Cannonier": 3},
			"royals": {"King": 1}
		},
		"Hanub": {
			"name": "Hanub",
			"portrait": "res://ui/portraits/Hanub Portrait.png",
			"peasants": {"Pawn": 4},
			"nobles": {"Cannonier": 1, "Rifleman": 3, "Elephant Rider": 3, "Minister": 1},
			"royals": {"Chancellor": 1}
		},
		"Saratov": {
			"name": "Saratov",
			"portrait": "res://ui/portraits/Saratov Portrait.png",
			"peasants": {"Basic Automata": 4},
			"nobles": {"Cannonier": 3, "Rifleman": 1, "Anarch": 1},
			"royals": {"Chancellor": 1}
		},
	}
