# PlayerDatabase.gd
# Autoload singleton holding chess-set profiles and the master list of piece
# scenes.
#
# Profiles come from the main game: tools/generate_fairy_chess.py exports
# res://data/character_roster.json (each character's identity + army + portrait),
# which this database loads into `player_profiles` keyed by character id. When
# the minigame is later embedded in the RPG, swap load_roster() for a builder
# fed by TopDownCharacterDatabase.get_chess_set() -- see build_profile().
#
# A synthetic "god" profile (every piece) is always injected for testing.

extends Node

const ROSTER_PATH = "res://data/character_roster.json"

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

# profile id -> {name, title, portrait, faction, peasants, nobles, royals}
var player_profiles = {}
# Ordered list of profile ids for the picker (roster order = sorted by name).
var roster_order = []
var _loaded = false


func _ready():
	_ensure_loaded()


# The roster is loaded lazily: member initializers of other nodes (e.g. the
# GameBoard's default profiles) can run before this autoload's _ready in
# --script/headless mode, so any accessor must load on first use.
func _ensure_loaded() -> void:
	if not _loaded:
		load_roster()


# --- Public Functions ---
func get_profile(profile_name):
	_ensure_loaded()
	return player_profiles.get(profile_name)


func get_piece_data(piece_type):
	return PIECE_DEFINITIONS.get(piece_type)


# Ordered list of {id, name, title, faction, portrait} for the profile picker.
func get_roster() -> Array:
	_ensure_loaded()
	var out = []
	for id in roster_order:
		var p = player_profiles[id]
		out.append({
			"id": id,
			"name": p.get("name", id),
			"title": p.get("title", ""),
			"faction": p.get("faction", ""),
			"portrait": p.get("portrait", ""),
		})
	return out


# --- Roster loading ---
func load_roster() -> void:
	_loaded = true
	player_profiles = {"god": _god_profile()}
	roster_order = []
	if not FileAccess.file_exists(ROSTER_PATH):
		push_warning("Character roster not found at %s -- using the 'god' test profile only." % ROSTER_PATH)
		return
	var file = FileAccess.open(ROSTER_PATH, FileAccess.READ)
	var json = JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("Failed to parse character roster: " + json.get_error_message())
		return
	var data = json.get_data()
	for entry in data.get("roster", []):
		var id = entry.get("id", "")
		if id == "":
			continue
		player_profiles[id] = build_profile(
			entry.get("name", id), entry.get("title", ""),
			entry.get("portrait", ""), entry.get("faction", ""),
			entry.get("chess_set", {}))
		roster_order.append(id)


# Source-agnostic profile builder. When embedded in the RPG, call this with
# TopDownCharacterDatabase.get_chess_set(id) instead of a roster entry.
func build_profile(name: String, title: String, portrait: String, faction: String, chess_set: Dictionary) -> Dictionary:
	return {
		"name": name,
		"title": title,
		"portrait": portrait,
		"faction": faction,
		"peasants": (chess_set.get("peasants", {}) as Dictionary).duplicate(),
		"nobles": (chess_set.get("nobles", {}) as Dictionary).duplicate(),
		"royals": (chess_set.get("royals", {}) as Dictionary).duplicate(),
	}


# A synthetic profile stocking every piece, for headless tests and sandbox play.
func _god_profile() -> Dictionary:
	return {
		"name": "God (Sandbox)",
		"title": "",
		"portrait": "res://icon.svg",
		"faction": "",
		"peasants": {"Basic Automata": 1, "Kulak": 2, "Pawn": 2, "Zombie": 2, "Raider": 1, "Cultist": 1, "Werewolf (human form)": 1},
		"nobles": {"Anarch": 1, "Bishop": 1, "Cannonier": 1, "Centaur": 1, "Devil Toad": 1, "Grasshopper": 1, "Dragonrider": 1, "Elephant Rider": 1, "Gorgon": 1, "Knight": 1, "Monk": 1, "Minister": 1, "Nightrider": 1, "Princess": 1, "Queen": 1, "Rifleman": 1, "Rook": 1, "Valkyrie": 1},
		"royals": {"Chancellor": 1, "Lady of the Lake": 1, "Pontifex": 1, "King": 1}
	}
