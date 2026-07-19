# rules.gd
# Pure, headless-testable rules engine for the simultaneous fairy chess minigame.
# Holds NO scene-tree references: the board state is plain data (Dictionaries /
# Arrays), so the same code drives the live game, the AI's lookahead, and the
# headless test suite.
#
# --- State shape ---
# state = {
#   "board": 6x6 nested Arrays; each cell is null or a piece Dictionary,
#   "ep_targets": {Vector2 square: piece id} en-passant vulnerable squares,
#   "phased_out": Array of {"piece": pdict, "turns": int} (Valkyrie death rattle),
#   "credits": {"white": {type: count}, "black": {type: count}},
#   "no_progress": int  # consecutive turns without capture/promo/convert/spawn,
#   "turn": int,
#   "next_id": int,
# }
# piece = {"id": int, "type": String, "color": String, "royal": bool,
#          "petrified": bool, "pos": Vector2, "traits": Array}
#
# --- Action shapes (all targets are Vector2 board squares) ---
# {"action": "move", "target": V2, ["is_double_move"], ["is_en_passant"], ["is_charge"]}
# {"action": "shoot", "target": V2}
# {"action": "fire_cannon"}
# {"action": "dragon_breath", "direction": V2}
# {"action": "promote", "target": V2, "promote_to": String}
# {"action": "convert", "target": V2}
# {"action": "spawn", "piece_type": String, "target": V2}
# {"action": "pass"}
#
# --- Simultaneity rules (design decisions) ---
# * Everyone's orders execute at once. Attacks (shoot / cannon / breath /
#   convert) land on their declared victims even if those victims move:
#   movement never dodges an attack.
# * Two pieces swapping squares head-on capture each other.
# * Two or more pieces arriving on the same square capture each other (and any
#   occupant that stayed put).
# * A mover whose path is stepped on by another mover's DESTINATION is blocked
#   and bounces back to its origin (it is NOT captured -- fixes the old rule).
# * A mover arriving on a square where a FRIENDLY piece unexpectedly still
#   stands (its own move got cancelled) bounces back instead of trampling it.
#   The Elephant Rider's charge tramples anything, friend or foe.

class_name Rules


const BOARD_SIZE = 6
const NO_PROGRESS_LIMIT = 24 # turns without progress before material adjudication
const HARD_TURN_LIMIT = 300

# Master table: category drives placement rules + royal status; value drives
# AI evaluation and attrition adjudication.
const PIECE_INFO = {
	# Peasants (placed on the second row)
	"Pawn":                    {"category": "peasant", "value": 1.0, "traits": ["Peasant"]},
	"Kulak":                   {"category": "peasant", "value": 1.1, "traits": ["Peasant"]},
	"Basic Automata":          {"category": "peasant", "value": 1.2, "traits": ["Peasant"]},
	"Zombie":                  {"category": "peasant", "value": 0.9, "traits": ["Peasant", "Automatic"]},
	"Raider":                  {"category": "peasant", "value": 1.3, "traits": ["Peasant", "Viking"]},
	"Cultist":                 {"category": "peasant", "value": 1.4, "traits": ["Peasant"]},
	"Werewolf (human form)":   {"category": "peasant", "value": 2.0, "traits": ["Peasant", "Shapeshifter"]},
	# Nobles (back row)
	"Anarch":                  {"category": "noble", "value": 3.0, "traits": []},
	"Bishop":                  {"category": "noble", "value": 3.0, "traits": []},
	"Cannonier":               {"category": "noble", "value": 3.0, "traits": []},
	"Centaur":                 {"category": "noble", "value": 3.5, "traits": []},
	"Devil Toad":              {"category": "noble", "value": 3.0, "traits": []},
	"Dragonrider":             {"category": "noble", "value": 5.0, "traits": []},
	"Elephant Rider":          {"category": "noble", "value": 3.5, "traits": []},
	"Gorgon":                  {"category": "noble", "value": 4.0, "traits": []},
	"Grasshopper":             {"category": "noble", "value": 2.5, "traits": []},
	"Knight":                  {"category": "noble", "value": 3.0, "traits": []},
	"Minister":                {"category": "noble", "value": 1.5, "traits": []},
	"Monk":                    {"category": "noble", "value": 3.5, "traits": []},
	"Nightrider":              {"category": "noble", "value": 4.5, "traits": []},
	"Princess":                {"category": "noble", "value": 4.5, "traits": []},
	"Queen":                   {"category": "noble", "value": 6.0, "traits": []},
	"Rifleman":                {"category": "noble", "value": 4.0, "traits": []},
	"Rook":                    {"category": "noble", "value": 4.0, "traits": []},
	"Valkyrie":                {"category": "noble", "value": 6.5, "traits": []},
	"Werewolf (wolf form)":    {"category": "noble", "value": 3.5, "traits": ["Shapeshifter"]},
	"Factory":                 {"category": "noble", "value": 3.5, "traits": ["Immobile", "Technological"]},
	"Doppelganger":            {"category": "noble", "value": 3.0, "traits": ["Mimic"]},
	"Berserker":               {"category": "noble", "value": 3.5, "traits": ["Viking"]},
	"Spymaster":               {"category": "noble", "value": 4.0, "traits": []},
	# Royals (back row; lose them all and you lose)
	"Chancellor":              {"category": "royal", "value": 4.0, "traits": []},
	"King":                    {"category": "royal", "value": 3.0, "traits": []},
	"Lady of the Lake":        {"category": "royal", "value": 4.5, "traits": []},
	"Pontifex":                {"category": "royal", "value": 4.0, "traits": []},
	"Praetor":                 {"category": "royal", "value": 4.0, "traits": ["Technological"]},
	"Chieftain":               {"category": "royal", "value": 3.5, "traits": ["Viking"]},
}

# Pieces a pawn-family unit may promote INTO when it reaches the last rank.
# Curated (non-royal nobles), strongest first so the picker and AI pruning
# lead with the marquee choices.
const PROMOTION_CHOICES = ["Valkyrie", "Queen", "Princess", "Nightrider", "Rook", "Bishop", "Knight", "Gorgon"]

const KING_DIRS = [
	Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1),
	Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1),
]
const ROOK_DIRS = [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]
const BISHOP_DIRS = [Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]
const KNIGHT_DIRS = [
	Vector2(1, 2), Vector2(1, -2), Vector2(-1, 2), Vector2(-1, -2),
	Vector2(2, 1), Vector2(2, -1), Vector2(-2, 1), Vector2(-2, -1),
]
const DRAGON_LEAPS = [
	Vector2(4, 1), Vector2(4, -1), Vector2(-4, 1), Vector2(-4, -1),
	Vector2(1, 4), Vector2(1, -4), Vector2(-1, 4), Vector2(-1, -4),
]

const WEREWOLF_TOGGLE = {
	"Werewolf (human form)": "Werewolf (wolf form)",
	"Werewolf (wolf form)": "Werewolf (human form)",
}


# =========================================================================
# State construction helpers
# =========================================================================

static func new_state() -> Dictionary:
	var board = []
	board.resize(BOARD_SIZE)
	for x in range(BOARD_SIZE):
		board[x] = []
		board[x].resize(BOARD_SIZE)
		for y in range(BOARD_SIZE):
			board[x][y] = null
	return {
		"board": board,
		"ep_targets": {},
		"phased_out": [],
		"credits": {"white": {}, "black": {}},
		"no_progress": 0,
		"turn": 0,
		"next_id": 1,
		# Type of the last piece each side deliberately moved -- what a
		# Doppelganger copies at the end of the round.
		"last_moved_type": {"white": "", "black": ""},
	}


static func make_piece(state: Dictionary, type: String, color: String, pos: Vector2) -> Dictionary:
	var info = PIECE_INFO.get(type, {"category": "noble", "value": 2.0, "traits": []})
	var piece = {
		"id": state.next_id,
		"type": type,
		"color": color,
		"royal": info.category == "royal",
		"petrified": false,
		"pos": pos,
		"traits": info.traits.duplicate(),
	}
	if type == "Doppelganger":
		# Persists through every transformation, unlike traits.
		piece["mimic"] = true
	state.next_id += 1
	return piece


static func add_piece(state: Dictionary, type: String, color: String, pos: Vector2) -> Dictionary:
	var piece = make_piece(state, type, color, pos)
	state.board[int(pos.x)][int(pos.y)] = piece
	return piece


static func duplicate_state(state: Dictionary) -> Dictionary:
	return state.duplicate(true)


static func is_valid_square(pos: Vector2) -> bool:
	return pos.x >= 0 and pos.x < BOARD_SIZE and pos.y >= 0 and pos.y < BOARD_SIZE


static func promotion_choices() -> Array:
	return PROMOTION_CHOICES


# --- Action precedence -----------------------------------------------------
# Several actions can land on the SAME square: a Pontifex both promotes the
# peasant beside it and could conditionally backfill that square. The UI shows
# and declares one action per square, so rank them -- a deliberate special
# beats a plain step, and a conditional backfill ranks last because it is the
# situational option. Lower number wins.
static func action_priority(action: Dictionary) -> int:
	match action.get("action", ""):
		"promote":
			return 0
		"convert":
			return 1
		"shoot":
			return 2
		"fire_cannon", "dragon_breath":
			return 3
		"move":
			return 5 if action.get("is_conditional", false) else 4
	return 6


# Key identifying the board square/marker an action occupies in the UI.
static func action_slot(action: Dictionary) -> String:
	if action.get("action", "") == "dragon_breath":
		return "dir:" + str(action.get("direction", Vector2.ZERO))
	if action.has("target"):
		return "sq:" + str(action.target)
	return "self"


# Every action, best-first. The board keeps this full list so a square holding
# several options (e.g. promote vs. conditional backfill) can offer a choice.
static func sort_actions(actions: Array) -> Array:
	var ranked = actions.duplicate()
	ranked.sort_custom(func(a, b): return action_priority(a) < action_priority(b))
	return ranked


# Sorts by precedence and keeps only the winning action per square -- the
# marker the board draws for each square.
static func prioritize_actions(actions: Array) -> Array:
	var seen = {}
	var out = []
	for a in sort_actions(actions):
		var slot = action_slot(a)
		if seen.has(slot):
			continue
		seen[slot] = true
		out.append(a)
	return out


static func breath_cone(direction: Vector2) -> Array:
	if direction == Vector2.UP:
		return [Vector2(-1, -2), Vector2(0, -2), Vector2(1, -2), Vector2(0, -1)]
	elif direction == Vector2.DOWN:
		return [Vector2(-1, 2), Vector2(0, 2), Vector2(1, 2), Vector2(0, 1)]
	elif direction == Vector2.LEFT:
		return [Vector2(-2, -1), Vector2(-2, 0), Vector2(-2, 1), Vector2(-1, 0)]
	elif direction == Vector2.RIGHT:
		return [Vector2(2, -1), Vector2(2, 0), Vector2(2, 1), Vector2(1, 0)]
	return []


# Ids of every royal an enemy could capture or petrify NEXT turn -- i.e. "in
# check". Used by the display to make threatened royals shudder. Best-effort
# (covers moves, shots, cannon files, dragon breath, gorgon petrification); a
# threat indicator, not a legality guarantee.
static func threatened_royals(state: Dictionary) -> Dictionary:
	var threatened = {}
	for royal in all_pieces(state):
		if not royal.royal or royal.petrified:
			continue
		if _royal_is_threatened(state, royal):
			threatened[royal.id] = true
	return threatened


static func _royal_is_threatened(state: Dictionary, royal: Dictionary) -> bool:
	var enemy_color = "black" if royal.color == "white" else "white"
	for p in all_pieces(state, enemy_color):
		if p.petrified:
			continue
		# Gorgon turns adjacent enemies to stone (a royal lost). She threatens
		# any square she occupies or can step to that neighbours the royal.
		if p.type == "Gorgon":
			if _chebyshev(p.pos, royal.pos) <= 1:
				return true
			for a in get_actions_raw(state, p):
				if a.action == "move" and _chebyshev(a.target, royal.pos) <= 1:
					return true
			continue
		for a in get_actions_raw(state, p):
			match a.action:
				"move", "shoot":
					if a.get("target", Vector2(-99, -99)) == royal.pos:
						return true
				"fire_cannon":
					if royal.pos.x == p.pos.x and signf(royal.pos.y - p.pos.y) == forward_dir(p.color):
						return true
				"dragon_breath":
					for offset in breath_cone(a.direction):
						if p.pos + offset == royal.pos:
							return true
	return false


static func _chebyshev(a: Vector2, b: Vector2) -> float:
	return max(abs(a.x - b.x), abs(a.y - b.y))


static func piece_at(state: Dictionary, pos: Vector2):
	if not is_valid_square(pos):
		return null
	return state.board[int(pos.x)][int(pos.y)]


static func find_piece(state: Dictionary, id: int):
	for x in range(BOARD_SIZE):
		for y in range(BOARD_SIZE):
			var p = state.board[x][y]
			if p != null and p.id == id:
				return p
	return null


static func all_pieces(state: Dictionary, color = "") -> Array:
	var out = []
	for x in range(BOARD_SIZE):
		for y in range(BOARD_SIZE):
			var p = state.board[x][y]
			if p != null and (color == "" or p.color == color):
				out.append(p)
	return out


static func royal_count(state: Dictionary, color: String) -> int:
	var n = 0
	for p in all_pieces(state, color):
		if p.royal and not p.petrified:
			n += 1
	return n


static func material_value(state: Dictionary, color: String) -> float:
	var total = 0.0
	for p in all_pieces(state, color):
		if p.petrified:
			continue
		total += PIECE_INFO.get(p.type, {"value": 2.0}).value
	return total


# Rows where each side may place / spawn pieces.
static func back_row(color: String) -> int:
	return 5 if color == "white" else 0


static func peasant_row(color: String) -> int:
	return 4 if color == "white" else 1


static func forward_dir(color: String) -> int:
	return -1 if color == "white" else 1


# =========================================================================
# Move generation
# =========================================================================

# All actions a single piece may declare. Petrified and Automatic pieces
# return [] -- the player cannot order them around.
static func get_actions(state: Dictionary, piece: Dictionary) -> Array:
	if piece.petrified:
		return []
	if "Automatic" in piece.traits:
		return []
	return get_actions_raw(state, piece)


# Movegen without the player-controllable filter (used for zombies).
static func get_actions_raw(state: Dictionary, piece: Dictionary) -> Array:
	var actions = []
	match piece.type:
		"Pawn":
			_pawn_family(state, piece, actions, true)
		"Kulak":
			_kulak_actions(state, piece, actions)
		"Basic Automata":
			_automata_actions(state, piece, actions)
		"Zombie":
			_pawn_family(state, piece, actions, true)
		"Raider":
			_pawn_family(state, piece, actions, true)
		"Cultist":
			_pawn_family(state, piece, actions, false)
			_convert_actions(state, piece, actions)
		"Werewolf (human form)":
			_pawn_family(state, piece, actions, false)
		"Werewolf (wolf form)":
			_werewolf_wolf_actions(state, piece, actions)
		"Monk":
			_monk_actions(state, piece, actions)
		"Knight":
			_leaps(state, piece, KNIGHT_DIRS, actions)
		"Centaur":
			_leaps(state, piece, KNIGHT_DIRS, actions)
			_leaps(state, piece, KING_DIRS, actions)
		"Bishop":
			_slides(state, piece, BISHOP_DIRS, actions)
		"Rook":
			_slides(state, piece, ROOK_DIRS, actions)
		"Queen":
			_slides(state, piece, KING_DIRS, actions)
		"Valkyrie":
			_slides(state, piece, KING_DIRS, actions)
			_leaps(state, piece, KNIGHT_DIRS, actions)
		"Princess":
			_slides(state, piece, BISHOP_DIRS, actions)
			_leaps(state, piece, KNIGHT_DIRS, actions)
		"Nightrider":
			_slides(state, piece, KNIGHT_DIRS, actions)
		"Grasshopper":
			_grasshopper_actions(state, piece, actions)
		"Minister":
			_leaps(state, piece, BISHOP_DIRS, actions)
		"Rifleman":
			# Shots first: when a move and a shot share a target square the
			# UI declares the first match, and shooting is the better default.
			_rifleman_shots(state, piece, actions)
			_leaps(state, piece, KING_DIRS, actions)
		"Cannonier":
			_cannonier_actions(state, piece, actions)
		"Dragonrider":
			_leaps(state, piece, DRAGON_LEAPS, actions)
			for dir in ROOK_DIRS:
				actions.append({"action": "dragon_breath", "direction": dir})
		"Elephant Rider":
			_leaps(state, piece, KNIGHT_DIRS, actions)
			_charge_action(state, piece, actions)
		"Gorgon":
			_leaps(state, piece, KING_DIRS, actions)
		"Anarch":
			_leaps(state, piece, KING_DIRS, actions)
			_anarch_hunts(state, piece, actions)
		"Devil Toad":
			_devil_toad_actions(state, piece, actions)
		"King":
			_leaps(state, piece, KING_DIRS, actions)
		"Chieftain":
			_leaps(state, piece, KING_DIRS, actions)
		"Chancellor":
			_leaps(state, piece, KING_DIRS, actions)
			_adjacent_promotions(state, piece, actions, "Minister", [], ["Peasant"])
		"Praetor":
			_leaps(state, piece, KING_DIRS, actions)
			_adjacent_promotions(state, piece, actions, "Factory", [], ["Peasant"])
		"Factory":
			pass # bolted to the ground; it builds instead of moving
		"Doppelganger":
			# Until it has copied something it shuffles like a king; once it
			# mimics, its current form supplies the moves.
			_leaps(state, piece, KING_DIRS, actions)
		"Berserker":
			# Rook lines, but never retreats.
			var fwd = forward_dir(piece.color)
			_slides(state, piece, [Vector2(0, fwd), Vector2(1, 0), Vector2(-1, 0)], actions)
		"Spymaster":
			_spymaster_actions(state, piece, actions)
		"Lady of the Lake":
			_leaps(state, piece, KING_DIRS, actions)
			_adjacent_promotions(state, piece, actions, "King", ["Pawn", "Kulak"], [])
		"Pontifex":
			_leaps(state, piece, KING_DIRS, actions)
			_adjacent_promotions(state, piece, actions, "Bishop", [], ["Peasant"])
		_:
			_leaps(state, piece, KING_DIRS, actions)
	return dedupe_actions(actions)


# Collapses actions that mean exactly the same thing. Pieces whose movement
# retraces itself -- the Devil Toad's four bounce paths can arrive at one
# square from several directions -- would otherwise offer the same move twice
# and pop the "choose an action" dialog with identical entries.
static func dedupe_actions(actions: Array) -> Array:
	var seen = {}
	var out = []
	for a in actions:
		var key = "%s|%s|%s|%s|%s|%s|%s" % [
			a.get("action", ""),
			str(a.get("target", "")),
			str(a.get("direction", "")),
			str(a.get("promote_to", "")),
			str(a.get("convert_to", "")),
			str(a.get("is_conditional", false)),
			str(a.get("is_charge", false)) + str(a.get("is_en_passant", false)) + str(a.get("is_double_move", false)),
		]
		if seen.has(key):
			continue
		seen[key] = true
		out.append(a)
	return out


# Every action a player may declare this turn: piece actions plus spawn
# placements from credits. Entries are {"piece_id": int or -1, "action": {...}}.
static func legal_actions(state: Dictionary, color: String) -> Array:
	var out = []
	for piece in all_pieces(state, color):
		for action in get_actions(state, piece):
			# A pawn-family self-promotion is really a choice of target piece;
			# expand it so the AI can evaluate each option. Directed promotions
			# (Lady/Pontifex, target != own square) keep their fixed result.
			if action.action == "promote" and action.target == piece.pos:
				for choice in PROMOTION_CHOICES:
					var expanded = action.duplicate()
					expanded.promote_to = choice
					out.append({"piece_id": piece.id, "action": expanded})
			else:
				out.append({"piece_id": piece.id, "action": action})
	var credits = state.credits[color]
	for piece_type in credits.keys():
		if credits[piece_type] <= 0:
			continue
		var row = peasant_row(color)
		if PIECE_INFO.get(piece_type, {"category": "noble"}).category != "peasant":
			row = back_row(color)
		for x in range(BOARD_SIZE):
			var pos = Vector2(x, row)
			if piece_at(state, pos) == null:
				out.append({"piece_id": -1, "action": {"action": "spawn", "piece_type": piece_type, "target": pos, "color": color}})
	return out


# --- movegen helpers -----------------------------------------------------

static func _slides(state, piece, dirs, actions) -> void:
	for dir in dirs:
		var pos = piece.pos + dir
		while is_valid_square(pos):
			var occ = piece_at(state, pos)
			if occ == null:
				actions.append({"action": "move", "target": pos})
			else:
				if occ.color != piece.color:
					actions.append({"action": "move", "target": pos})
				else:
					# Conditional "backfill": step into your own piece's square.
					# Resolves only if that piece leaves or dies this turn, and
					# then cuts down whatever enemy claimed the square.
					actions.append({"action": "move", "target": pos, "is_conditional": true})
				break
			pos += dir


static func _leaps(state, piece, dirs, actions) -> void:
	for dir in dirs:
		var pos = piece.pos + dir
		if not is_valid_square(pos):
			continue
		var occ = piece_at(state, pos)
		if occ == null or occ.color != piece.color:
			actions.append({"action": "move", "target": pos})
		else:
			actions.append({"action": "move", "target": pos, "is_conditional": true})


# Shared pawn-style movement: forward step, double step from the peasant row,
# diagonal captures, en passant, and (optionally) promotion on the last row.
static func _pawn_family(state, piece, actions, can_promote: bool) -> void:
	var fwd = forward_dir(piece.color)
	var one_step = piece.pos + Vector2(0, fwd)
	if is_valid_square(one_step) and piece_at(state, one_step) == null:
		actions.append({"action": "move", "target": one_step})
		if piece.pos.y == peasant_row(piece.color):
			var two_steps = piece.pos + Vector2(0, fwd * 2)
			if is_valid_square(two_steps) and piece_at(state, two_steps) == null:
				actions.append({"action": "move", "target": two_steps, "is_double_move": true})
	for x_dir in [-1, 1]:
		var cap = piece.pos + Vector2(x_dir, fwd)
		if not is_valid_square(cap):
			continue
		var occ = piece_at(state, cap)
		if occ != null and occ.color != piece.color:
			actions.append({"action": "move", "target": cap})
		if occ == null and state.ep_targets.has(cap):
			actions.append({"action": "move", "target": cap, "is_en_passant": true})
	if can_promote and piece.pos.y == _promotion_row(piece.color):
		actions.append({"action": "promote", "target": piece.pos, "promote_to": "Valkyrie"})


static func _promotion_row(color: String) -> int:
	return 0 if color == "white" else 5


static func _kulak_actions(state, piece, actions) -> void:
	var fwd = forward_dir(piece.color)
	# Diagonal non-capturing moves (mirror image of a pawn). If the square is
	# an en-passant target the ep capture REPLACES the plain step (the UI
	# declares the first action matching a clicked square).
	for x_dir in [-1, 1]:
		var one_step = piece.pos + Vector2(x_dir, fwd)
		if is_valid_square(one_step) and piece_at(state, one_step) == null:
			if state.ep_targets.has(one_step):
				actions.append({"action": "move", "target": one_step, "is_en_passant": true})
			else:
				actions.append({"action": "move", "target": one_step})
			if piece.pos.y == peasant_row(piece.color):
				var two_steps = piece.pos + Vector2(x_dir * 2, fwd * 2)
				if is_valid_square(two_steps) and piece_at(state, two_steps) == null:
					actions.append({"action": "move", "target": two_steps, "is_double_move": true})
	# Straight-ahead captures.
	var cap = piece.pos + Vector2(0, fwd)
	if is_valid_square(cap):
		var occ = piece_at(state, cap)
		if occ != null and occ.color != piece.color:
			actions.append({"action": "move", "target": cap})
	if piece.pos.y == _promotion_row(piece.color):
		actions.append({"action": "promote", "target": piece.pos, "promote_to": "Valkyrie"})


static func _automata_actions(state, piece, actions) -> void:
	var fwd = forward_dir(piece.color)
	var one_step = piece.pos + Vector2(0, fwd)
	var two_steps = piece.pos + Vector2(0, fwd * 2)
	var three_steps = piece.pos + Vector2(0, fwd * 3)
	if is_valid_square(one_step) and piece_at(state, one_step) == null:
		actions.append({"action": "move", "target": one_step})
		if is_valid_square(two_steps) and piece_at(state, two_steps) == null:
			actions.append({"action": "move", "target": two_steps})
			if piece.pos.y == peasant_row(piece.color) and is_valid_square(three_steps) and piece_at(state, three_steps) == null:
				actions.append({"action": "move", "target": three_steps, "is_double_move": true})
	# Diagonal captures at range 1-2 (blocked by the first piece met).
	for x_dir in [-1, 1]:
		for dist in [1, 2]:
			var cap = piece.pos + Vector2(x_dir * dist, fwd * dist)
			if not is_valid_square(cap):
				break
			var occ = piece_at(state, cap)
			if occ != null:
				if occ.color != piece.color:
					actions.append({"action": "move", "target": cap})
				break
	if piece.pos.y == _promotion_row(piece.color):
		actions.append({"action": "promote", "target": piece.pos, "promote_to": "Valkyrie"})


static func _monk_actions(state, piece, actions) -> void:
	var fwd = forward_dir(piece.color)
	var one_step = piece.pos + Vector2(0, fwd)
	if is_valid_square(one_step) and piece_at(state, one_step) == null:
		actions.append({"action": "move", "target": one_step})
		if piece.pos.y == back_row(piece.color):
			var two_steps = piece.pos + Vector2(0, fwd * 2)
			if is_valid_square(two_steps) and piece_at(state, two_steps) == null:
				actions.append({"action": "move", "target": two_steps, "is_double_move": true})
	for x_dir in [-1, 1]:
		var cap = piece.pos + Vector2(x_dir, fwd)
		if not is_valid_square(cap):
			continue
		var occ = piece_at(state, cap)
		if occ != null and occ.color != piece.color:
			actions.append({"action": "move", "target": cap})
		if occ == null and state.ep_targets.has(cap):
			actions.append({"action": "move", "target": cap, "is_en_passant": true})
	_slides(state, piece, BISHOP_DIRS, actions)
	if piece.pos.y == _promotion_row(piece.color):
		actions.append({"action": "promote", "target": piece.pos, "promote_to": "Valkyrie"})


static func _convert_actions(state, piece, actions) -> void:
	for dir in ROOK_DIRS:
		var pos = piece.pos + dir
		var occ = piece_at(state, pos)
		if occ != null and occ.color != piece.color and "Peasant" in occ.traits:
			actions.append({"action": "convert", "target": pos, "convert_to": "Cultist"})


# The Spymaster creeps sideways and backwards along open lines, edges forward
# only one diagonal step at a time, and turns the enemy court against itself.
static func _spymaster_actions(state, piece, actions) -> void:
	var fwd = forward_dir(piece.color)
	# Rook lines to the rear and flanks (never straight ahead).
	_slides(state, piece, [Vector2(0, -fwd), Vector2(1, 0), Vector2(-1, 0)], actions)
	# A single diagonal step forward.
	_leaps(state, piece, [Vector2(1, fwd), Vector2(-1, fwd)], actions)
	_spymaster_conversions(state, piece, actions)


# Suborns any enemy piece standing next to an enemy royal -- the bodyguards,
# never the royal itself -- flipping it into one of our Pawns. Range is
# irrelevant: this is blackmail, not a knife.
static func _spymaster_conversions(state, piece, actions) -> void:
	var seen = {}
	for royal in all_pieces(state):
		if royal.color == piece.color or not royal.royal:
			continue
		for dir in KING_DIRS:
			var pos = royal.pos + dir
			var occ = piece_at(state, pos)
			if occ == null or occ.color == piece.color or occ.royal:
				continue
			if seen.has(occ.id):
				continue
			seen[occ.id] = true
			actions.append({"action": "convert", "target": pos, "convert_to": "Pawn"})


static func _werewolf_wolf_actions(state, piece, actions) -> void:
	var seen = {}
	for dir in KING_DIRS:
		var pos = piece.pos + dir
		if is_valid_square(pos):
			var occ = piece_at(state, pos)
			if occ == null or occ.color != piece.color:
				if not seen.has(pos):
					seen[pos] = true
					actions.append({"action": "move", "target": pos})
	# Two king steps; may pass through any first square.
	for dir1 in KING_DIRS:
		var mid = piece.pos + dir1
		if not is_valid_square(mid):
			continue
		for dir2 in KING_DIRS:
			var pos = mid + dir2
			if not is_valid_square(pos) or pos == piece.pos or seen.has(pos):
				continue
			var occ = piece_at(state, pos)
			if occ == null or occ.color != piece.color:
				seen[pos] = true
				actions.append({"action": "move", "target": pos})


static func _grasshopper_actions(state, piece, actions) -> void:
	for dir in KING_DIRS:
		var pos = piece.pos + dir
		while is_valid_square(pos):
			if piece_at(state, pos) != null:
				var landing = pos + dir
				if is_valid_square(landing):
					var occ = piece_at(state, landing)
					if occ == null or occ.color != piece.color:
						actions.append({"action": "move", "target": landing})
				break
			pos += dir


# The rifleman fires a PROJECTILE down a rank or file. The shot is aimed in a
# direction, not at a piece: it travels until it meets the first piece standing
# there when it resolves -- so an enemy can step in to intercept it, and your
# own pieces are not safe in the line of fire.
static func _rifleman_shots(state, piece, actions) -> void:
	for dir in ROOK_DIRS:
		if not is_valid_square(piece.pos + dir):
			continue
		# Marker square for the UI: the first piece currently in the line, or
		# the far edge if the line is empty.
		var marker = piece.pos + dir
		var friendly_fire = false
		var scan = piece.pos + dir
		while is_valid_square(scan):
			var occ = piece_at(state, scan)
			if occ != null:
				marker = scan
				friendly_fire = occ.color == piece.color
				break
			marker = scan
			scan += dir
		actions.append({
			"action": "shoot", "direction": dir, "target": marker,
			"friendly_fire": friendly_fire,
		})


static func _cannonier_actions(state, piece, actions) -> void:
	var one_step = piece.pos + Vector2(0, forward_dir(piece.color))
	if is_valid_square(one_step) and piece_at(state, one_step) == null:
		actions.append({"action": "move", "target": one_step})
	actions.append({"action": "fire_cannon"})


static func _charge_action(state, piece, actions) -> void:
	var target = piece.pos + Vector2(0, forward_dir(piece.color) * 2)
	if is_valid_square(target):
		# The charge is declared blind: it tramples whatever stands there.
		actions.append({"action": "move", "target": target, "is_charge": true})


static func _anarch_hunts(state, piece, actions) -> void:
	for other in all_pieces(state):
		if other.color == piece.color or not other.royal:
			continue
		for dir in KING_DIRS:
			var pos = other.pos + dir
			if is_valid_square(pos) and piece_at(state, pos) == null:
				actions.append({"action": "move", "target": pos})


static func _devil_toad_actions(state, piece, actions) -> void:
	for start_dir in BISHOP_DIRS:
		var visited = []
		var pos = piece.pos
		var dir = start_dir
		for i in range(12):
			var next_pos = pos + dir
			if not is_valid_square(next_pos):
				var bounced = false
				if (next_pos.x < 0 and dir.x < 0) or (next_pos.x >= BOARD_SIZE and dir.x > 0):
					dir = Vector2(-dir.x, dir.y)
					bounced = true
				if (next_pos.y < 0 and dir.y < 0) or (next_pos.y >= BOARD_SIZE and dir.y > 0):
					dir = Vector2(dir.x, -dir.y)
					bounced = true
				if bounced:
					next_pos = pos + dir
					if not is_valid_square(next_pos):
						break
				else:
					break
			if next_pos in visited:
				break
			pos = next_pos
			visited.append(pos)
			var occ = piece_at(state, pos)
			if occ == null or occ.color != piece.color:
				actions.append({"action": "move", "target": pos})
			if occ != null:
				break


static func _adjacent_promotions(state, piece, actions, promote_to: String, allowed_types: Array, allowed_traits: Array) -> void:
	for dir in ROOK_DIRS:
		var pos = piece.pos + dir
		var occ = piece_at(state, pos)
		if occ == null or occ.color != piece.color:
			continue
		var matches = occ.type in allowed_types
		for t in allowed_traits:
			if t in occ.traits:
				matches = true
		if matches:
			actions.append({"action": "promote", "target": pos, "promote_to": promote_to})


# The path a move sweeps through (intermediate squares only). Used for
# mover-vs-mover blocking. Leapers return [].
static func move_path(piece_type: String, from_pos: Vector2, to_pos: Vector2) -> Array:
	# These pieces jump, bounce or teleport: their moves are never blockable,
	# even when the displacement happens to be a straight line.
	if piece_type in ["Grasshopper", "Devil Toad", "Werewolf (wolf form)", "Anarch", "Elephant Rider"]:
		return []
	var delta = to_pos - from_pos
	if piece_type == "Nightrider":
		# Intermediate knight-step landings.
		for k in KNIGHT_DIRS:
			var steps_x = 0.0
			if k.x != 0:
				steps_x = delta.x / k.x
			if steps_x >= 2 and delta == k * steps_x:
				var path = []
				for i in range(1, int(steps_x)):
					path.append(from_pos + k * i)
				return path
		return []
	# Werewolf double-steps, Devil Toad bounces, knight leaps, charges and
	# Anarch teleports all count as leaps: no blockable path.
	var is_linear = (delta.x == 0 or delta.y == 0 or abs(delta.x) == abs(delta.y))
	if not is_linear:
		return []
	var dir = delta.sign()
	var path = []
	var pos = from_pos + dir
	while pos != to_pos and is_valid_square(pos):
		path.append(pos)
		pos += dir
	return path


# =========================================================================
# Automatic pieces (zombies act on their own every turn)
# =========================================================================

static func automatic_action(state: Dictionary, piece: Dictionary):
	if piece.petrified or not "Automatic" in piece.traits:
		return null
	var actions = get_actions_raw(state, piece)
	if actions.is_empty():
		return null
	# Priority: promote > capture > en passant > shortest advance.
	for a in actions:
		if a.action == "promote":
			return a
	for a in actions:
		if a.action == "move" and piece_at(state, a.target) != null:
			return a
	for a in actions:
		if a.action == "move" and a.get("is_en_passant", false):
			return a
	for a in actions:
		if a.action == "move" and not a.get("is_double_move", false):
			return a
	return actions[0]


# =========================================================================
# Turn resolution
# =========================================================================

# declared: {piece_id: action} for player-ordered pieces, plus optional
# entries with negative keys for spawns ({-1: spawn_white, -2: spawn_black}).
# Returns {"state": new_state, "events": [...], "outcome": String}
# outcome: "" (game continues), "white", "black", "draw".
static func resolve(state: Dictionary, declared: Dictionary) -> Dictionary:
	var st = duplicate_state(state)
	var events = []
	var progress = false

	# All bookkeeping is keyed by piece ID (ints), never by the piece
	# Dictionaries themselves: GDScript hashes Dictionary keys by content, so
	# mutating a piece (e.g. its pos) while it is a key corrupts the map.
	var by_id = {} # id -> piece dict (in st)
	for piece in all_pieces(st):
		by_id[piece.id] = piece

	# --- Gather orders -----------------------------------------------------
	var orders = {} # id -> action
	var spawns = []
	for key in declared.keys():
		var action = declared[key]
		if action == null or action.get("action", "") == "pass":
			continue
		if action.action == "spawn":
			spawns.append(action)
			continue
		if by_id.has(key) and not by_id[key].petrified:
			orders[key] = action
	# Zombies and friends act on their own (skip any that somehow got orders).
	for piece in all_pieces(st):
		if "Automatic" in piece.traits and not orders.has(piece.id):
			var auto = automatic_action(st, piece)
			if auto != null:
				orders[piece.id] = auto

	# --- Classify ----------------------------------------------------------
	var movers = {}   # id -> move action
	var shooters = [] # [id, action]
	var aoes = []     # [id, action]
	var promotes = [] # [id, action]
	var converts = [] # [id, action]
	for id in orders.keys():
		var action = orders[id]
		match action.action:
			"move":
				movers[id] = action
			"shoot":
				shooters.append([id, action])
			"fire_cannon", "dragon_breath":
				aoes.append([id, action])
			"promote":
				promotes.append([id, action])
			"convert":
				converts.append([id, action])

	# --- Movement conflict resolution --------------------------------------
	var captured = {}  # id -> true (removed from the board)
	var cancelled = {} # id -> true (move did not happen; the piece stays put)
	var en_route = {}  # id -> true (destroyed in transit, before reaching target)
	var origin_of = {} # id -> pre-turn position
	var mover_ids = movers.keys()
	for id in mover_ids:
		origin_of[id] = by_id[id].pos

	# Split conditional "backfill" moves (ordered onto a square held by one of
	# your own pieces) from normal moves. Backfills resolve in a later wave and
	# only if that square is vacated this turn.
	var backfill_ids = []
	var normal_ids = []
	for id in mover_ids:
		var occ = piece_at(state, movers[id].target)
		if occ != null and occ.id != id and occ.color == by_id[id].color \
				and not movers[id].get("is_charge", false):
			backfill_ids.append(id)
		else:
			normal_ids.append(id)

	# 1. Head-on swaps: both die in the collision.
	for i in range(normal_ids.size()):
		for j in range(i + 1, normal_ids.size()):
			var a = normal_ids[i]
			var b = normal_ids[j]
			if movers[a].target == origin_of[b] and movers[b].target == origin_of[a]:
				captured[a] = true
				captured[b] = true

	# 2. Path collisions: a mover whose declared destination lands on another
	#    mover's path is struck in transit -- both are destroyed on that square.
	for a in normal_ids:
		var path = move_path(by_id[a].type, origin_of[a], movers[a].target)
		if path.is_empty():
			continue
		for b in mover_ids:
			if a == b or movers[b].target == movers[a].target:
				continue
			if movers[b].target in path:
				captured[a] = true
				captured[b] = true
				en_route[a] = true # died before reaching its target
				events.append({"type": "collision", "id": a, "other": b, "pos": movers[b].target})
				break

	# 3. Committed captures: a mover strikes whatever ENEMY held its target
	#    square when orders were given. Fleeing does NOT save the victim -- the
	#    only defences are to block the attacker or kill it first.
	for a in normal_ids:
		if en_route.has(a):
			continue # cut down before it could land the blow
		var victim = piece_at(state, movers[a].target)
		if victim == null or victim.id == a or not by_id.has(victim.id):
			continue
		if victim.color != by_id[a].color or movers[a].get("is_charge", false):
			captured[victim.id] = true

	# 4. Converging movers annihilate each other on the contested square.
	var by_dest = {}
	for a in normal_ids:
		if captured.has(a):
			continue
		var dest = movers[a].target
		if not by_dest.has(dest):
			by_dest[dest] = []
		by_dest[dest].append(a)
	for dest in by_dest.keys():
		var arrivers = by_dest[dest]
		if arrivers.size() > 1:
			for a in arrivers:
				captured[a] = true

	# 5. Backfill wave: a conditional move resolves only if the friendly piece
	#    holding its target square is gone (dead or moved). The backfiller then
	#    takes the square, cutting down whatever enemy claimed it, and survives
	#    -- this is the "avenge the queen" counter-attack.
	var backfill_by_dest = {}
	for a in backfill_ids:
		var d = movers[a].target
		if not backfill_by_dest.has(d):
			backfill_by_dest[d] = []
		backfill_by_dest[d].append(a)
	for a in backfill_ids:
		var dest = movers[a].target
		if backfill_by_dest[dest].size() > 1:
			cancelled[a] = true # two of your own pieces cannot both backfill
			events.append({"type": "blocked", "id": a})
			continue
		var blocker = piece_at(state, dest)
		var blocker_gone = blocker == null or not by_id.has(blocker.id) \
			or captured.has(blocker.id) \
			or (movers.has(blocker.id) and not cancelled.has(blocker.id))
		if not blocker_gone:
			cancelled[a] = true # the way is still barred: the move does not happen
			events.append({"type": "blocked", "id": a})
			continue
		for b in normal_ids:
			if b == a or captured.has(b):
				continue
			if movers[b].target == dest and by_id[b].color != by_id[a].color:
				captured[b] = true # the backfiller cuts down the claimant
		events.append({"type": "backfill", "id": a, "pos": dest})

	# 4. En passant victims die even if they ran -- and even if the ep-mover
	#    itself dies this turn (dying strikes apply to en passant too).
	for a in mover_ids:
		if cancelled.has(a):
			continue
		if movers[a].get("is_en_passant", false):
			var victim_id = state.ep_targets.get(movers[a].target, -1)
			if victim_id != -1 and by_id.has(victim_id):
				captured[victim_id] = true

	# --- Ranged attacks ------------------------------------------------------
	# Fire resolves against a square's occupant taken as the UNION of where
	# pieces started and where they moved: a piece standing in the line when
	# you fired cannot dodge out of it, and a piece that steps INTO the line
	# intercepts the shot. Friendly fire is real for all of these.
	var attack_occupant = {} # Vector2 -> piece id
	for p in all_pieces(state):
		if by_id.has(p.id):
			attack_occupant[p.pos] = p.id
	for a in mover_ids:
		if captured.has(a) or cancelled.has(a):
			continue
		var dest = movers[a].target
		if not attack_occupant.has(dest):
			attack_occupant[dest] = a

	for entry in shooters:
		var shooter = by_id[entry[0]]
		var action = entry[1]
		var victim_id = -1
		if action.has("direction"):
			# Projectile: travels until it meets the first piece, friend or foe.
			var pos = shooter.pos + action.direction
			while is_valid_square(pos):
				if attack_occupant.has(pos):
					victim_id = attack_occupant[pos]
					break
				pos += action.direction
		else:
			# Legacy targeted shot (still used by tests / saved actions).
			var target = piece_at(st, action.target)
			if target != null and target.color != shooter.color:
				victim_id = target.id
		if victim_id != -1 and victim_id != entry[0]:
			captured[victim_id] = true
			events.append({"type": "shot", "shooter": entry[0], "victim": victim_id})

	for entry in aoes:
		var attacker = by_id[entry[0]]
		var action = entry[1]
		if action.action == "fire_cannon":
			var fwd = forward_dir(attacker.color)
			for i in range(1, BOARD_SIZE):
				var q = attacker.pos + Vector2(0, i * fwd)
				if attack_occupant.has(q):
					captured[attack_occupant[q]] = true # friendly fire included
			events.append({"type": "cannon", "id": attacker.id})
		elif action.action == "dragon_breath":
			for offset in breath_cone(action.direction):
				var q = attacker.pos + offset
				if attack_occupant.has(q):
					captured[attack_occupant[q]] = true # friendly fire included
			events.append({"type": "breath", "id": attacker.id, "direction": action.direction})

	# Dying strikes need no separate pass: step 3 lands a mover's committed
	# capture whether or not the mover itself survives the turn. Only a piece
	# cut down in transit (en_route) never gets its blow in.

	# --- Necromancy / Valhalla bookkeeping ----------------------------------
	# A capture-by-movement is a mover landing on a square whose occupant dies.
	var move_capturers = []
	for a in mover_ids:
		if cancelled.has(a) or en_route.has(a):
			continue
		var occ = piece_at(st, movers[a].target)
		if occ != null and occ.id != a and captured.has(occ.id) and occ.color != by_id[a].color:
			move_capturers.append(a)
		elif movers[a].get("is_en_passant", false) and not captured.has(a):
			move_capturers.append(a)

	# --- En passant bookkeeping for NEXT turn --------------------------------
	# Only movers that actually move (not cancelled, not killed by anything,
	# including ranged fire) leave a vulnerable trail.
	var new_ep = {}
	for a in mover_ids:
		if captured.has(a) or cancelled.has(a):
			continue
		if movers[a].get("is_double_move", false):
			for sq in move_path(by_id[a].type, origin_of[a], movers[a].target):
				new_ep[sq] = a

	# --- Apply captures -----------------------------------------------------
	for id in captured.keys():
		var piece = by_id[id]
		if piece_at(st, piece.pos) == piece:
			st.board[int(piece.pos.x)][int(piece.pos.y)] = null
		progress = true
		if piece.type == "Valkyrie" and not piece.petrified:
			# Death rattle: leaves the battlefield, returns at the end of the
			# NEXT turn (turns=2 because the countdown below runs this turn).
			# A petrified Valkyrie is stone -- she shatters like anyone else.
			st.phased_out.append({"piece": piece, "turns": 2})
			events.append({"type": "phase_out", "id": id, "pos": piece.pos})
		else:
			events.append({"type": "capture", "id": id, "pos": piece.pos})

	# Valhalla: a Viking who dies on the same turn he takes a life is carried
	# home and returns as a spawn credit for his owner. Dying while killing is
	# the whole point -- surviving the kill earns nothing.
	for a in move_capturers:
		var piece = by_id[a]
		if captured.has(a) and "Viking" in piece.traits:
			var credits = st.credits[piece.color]
			credits[piece.type] = credits.get(piece.type, 0) + 1
			events.append({"type": "credit", "color": piece.color, "piece_type": piece.type})

	# --- Apply movement ------------------------------------------------------
	for a in mover_ids:
		if captured.has(a) or cancelled.has(a):
			continue
		var piece = by_id[a]
		var dest = movers[a].target
		if piece_at(st, piece.pos) == piece:
			st.board[int(piece.pos.x)][int(piece.pos.y)] = null
		piece.pos = dest
		st.board[int(dest.x)][int(dest.y)] = piece
		events.append({"type": "move", "id": a, "to": dest})
		# Only a deliberately ordered move is something a Doppelganger can
		# study -- zombies shambling on their own don't count.
		if declared.has(a):
			st.last_moved_type[piece.color] = piece.type

	# --- Promotions / conversions / transformations -------------------------
	# Blessings land on whoever stood on the target square when orders were
	# given, even if that piece has since moved (it must still be alive).
	for entry in promotes:
		var promoter = by_id[entry[0]]
		var action = entry[1]
		var pre_target = piece_at(state, action.target)
		if pre_target == null:
			continue
		if not by_id.has(pre_target.id) or captured.has(pre_target.id):
			continue
		var target = by_id[pre_target.id]
		if target.color != promoter.color:
			continue
		_replace_piece(st, target, action.promote_to, target.color, events, "promote")
		progress = true

	for entry in converts:
		var cultist = by_id[entry[0]]
		var action = entry[1]
		var pre_victim = piece_at(state, action.target)
		if pre_victim == null:
			continue
		if not by_id.has(pre_victim.id) or captured.has(pre_victim.id):
			continue
		var victim = by_id[pre_victim.id]
		if victim.color == cultist.color:
			continue
		_replace_piece(st, victim, str(action.get("convert_to", "Cultist")), cultist.color, events, "convert")
		progress = true

	# Werewolves toggle form at the end of every turn they survive.
	for piece in all_pieces(st):
		if WEREWOLF_TOGGLE.has(piece.type) and not piece.petrified:
			_replace_piece(st, piece, WEREWOLF_TOGGLE[piece.type], piece.color, events, "transform")

	# Doppelgangers take the shape of whatever the enemy last moved. The mimic
	# flag rides along through every change of form, so it keeps copying.
	for piece in all_pieces(st):
		if not piece.get("mimic", false) or piece.petrified:
			continue
		var enemy = "black" if piece.color == "white" else "white"
		var copy_type = str(st.last_moved_type.get(enemy, ""))
		if copy_type == "" or copy_type == piece.type or not PIECE_INFO.has(copy_type):
			continue
		_replace_piece(st, piece, copy_type, piece.color, events, "transform")
		piece.mimic = true # survive the change of form

	# --- Gorgon petrification (enemy pieces adjacent to her final square) ----
	# Two-phase so the outcome is symmetric: all gorgons un-petrified at the
	# start of the pass gaze simultaneously (two rival gorgons stone each
	# other rather than the board-scan winner acting first).
	var gazing = []
	for piece in all_pieces(st):
		if piece.type == "Gorgon" and not piece.petrified:
			gazing.append(piece)
	var petrify_targets = {}
	for gorgon in gazing:
		for dir in KING_DIRS:
			var occ = piece_at(st, gorgon.pos + dir)
			if occ != null and occ.color != gorgon.color and not occ.petrified:
				petrify_targets[occ.id] = occ
	for id in petrify_targets:
		petrify_targets[id].petrified = true
		progress = true
		events.append({"type": "petrify", "id": id})

	# --- Spawns (placed after movement so collisions fail cleanly) -----------
	for action in spawns:
		var color = action.get("color", "")
		if color == "":
			continue
		var credits = st.credits[color]
		if credits.get(action.piece_type, 0) <= 0:
			continue
		if piece_at(st, action.target) != null:
			events.append({"type": "spawn_failed", "color": color, "piece_type": action.piece_type})
			continue
		credits[action.piece_type] -= 1
		var piece = add_piece(st, action.piece_type, color, action.target)
		progress = true
		events.append({"type": "spawn", "id": piece.id, "piece_type": piece.type, "color": color, "pos": action.target})

	# --- Factories work a shift ----------------------------------------------
	# Every surviving factory stamps out an automaton onto an adjacent empty
	# square. Resolved after movement so this turn's traffic has cleared, and
	# in a fixed direction order so the output is deterministic.
	for piece in all_pieces(st):
		if piece.type != "Factory" or piece.petrified:
			continue
		for dir in KING_DIRS:
			var pos = piece.pos + dir
			if not is_valid_square(pos) or piece_at(st, pos) != null:
				continue
			var built = add_piece(st, "Basic Automata", piece.color, pos)
			progress = true
			events.append({"type": "spawn", "id": built.id, "piece_type": built.type,
				"color": built.color, "pos": pos})
			break

	# --- Valkyries return from the mists -------------------------------------
	var still_phased = []
	for entry in st.phased_out:
		entry.turns -= 1
		if entry.turns > 0:
			still_phased.append(entry)
			continue
		var pos = _nearest_empty(st, entry.piece.pos)
		if pos == Vector2(-1, -1):
			entry.turns = 1
			still_phased.append(entry)
			continue
		entry.piece.pos = pos
		st.board[int(pos.x)][int(pos.y)] = entry.piece
		progress = true
		events.append({"type": "return", "id": entry.piece.id, "pos": pos})
	st.phased_out = still_phased

	# --- Bookkeeping ----------------------------------------------------------
	st.ep_targets = new_ep
	st.turn += 1
	if progress:
		st.no_progress = 0
	else:
		st.no_progress += 1

	return {"state": st, "events": events, "outcome": _outcome(st)}


static func _replace_piece(st: Dictionary, piece: Dictionary, new_type: String, new_color: String, events: Array, event_type: String) -> void:
	var info = PIECE_INFO.get(new_type, {"category": "noble", "traits": []})
	piece.type = new_type
	piece.color = new_color
	piece.royal = info.category == "royal"
	piece.traits = info.traits.duplicate()
	events.append({"type": event_type, "id": piece.id, "new_type": new_type, "color": new_color, "pos": piece.pos})


static func _nearest_empty(st: Dictionary, origin: Vector2) -> Vector2:
	if is_valid_square(origin) and piece_at(st, origin) == null:
		return origin
	for radius in range(1, BOARD_SIZE):
		var best = Vector2(-1, -1)
		var best_d = 999.0
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				if max(abs(dx), abs(dy)) != radius:
					continue
				var pos = origin + Vector2(dx, dy)
				if is_valid_square(pos) and piece_at(st, pos) == null:
					var d = origin.distance_squared_to(pos)
					if d < best_d:
						best_d = d
						best = pos
		if best != Vector2(-1, -1):
			return best
	return Vector2(-1, -1)


static func _outcome(st: Dictionary) -> String:
	var white_alive = royal_count(st, "white") > 0
	var black_alive = royal_count(st, "black") > 0
	# A side with a Valkyrie about to return is not fully dead if it still has
	# a phased-out royal -- royals never phase out, so no special case needed.
	if not white_alive and not black_alive:
		return "draw"
	if not black_alive:
		return "white"
	if not white_alive:
		return "black"
	if st.no_progress >= NO_PROGRESS_LIMIT or st.turn >= HARD_TURN_LIMIT:
		var white_material = material_value(st, "white")
		var black_material = material_value(st, "black")
		if abs(white_material - black_material) < 0.05:
			return "draw"
		return "white" if white_material > black_material else "black"
	return ""


# =========================================================================
# Evaluation (used by the AI, exposed here for tests)
# =========================================================================

static func evaluate(state: Dictionary, color: String) -> float:
	var opp = "black" if color == "white" else "white"
	var my_royals = royal_count(state, color)
	var opp_royals = royal_count(state, opp)
	if my_royals == 0 and opp_royals == 0:
		return 0.0
	if my_royals == 0:
		return -1000.0
	if opp_royals == 0:
		return 1000.0
	var score = material_value(state, color) - material_value(state, opp)
	score += 0.5 * (my_royals - opp_royals)
	# Phased-out Valkyries still count a little (they come back).
	for entry in state.phased_out:
		var v = PIECE_INFO.get(entry.piece.type, {"value": 2.0}).value * 0.8
		if entry.piece.color == color:
			score += v
		else:
			score -= v
	# Credits in hand are worth a fraction of the piece.
	for c in ["white", "black"]:
		var sign_mult = 1.0 if c == color else -1.0
		for piece_type in state.credits[c]:
			score += sign_mult * 0.5 * state.credits[c][piece_type] * PIECE_INFO.get(piece_type, {"value": 2.0}).value
	# Royal safety: enemy pieces adjacent to my royal are scary.
	for p in all_pieces(state, color):
		if not p.royal or p.petrified:
			continue
		for dir in KING_DIRS:
			var occ = piece_at(state, p.pos + dir)
			if occ != null and occ.color == opp and not occ.petrified:
				score -= 0.6
	for p in all_pieces(state, opp):
		if not p.royal or p.petrified:
			continue
		for dir in KING_DIRS:
			var occ = piece_at(state, p.pos + dir)
			if occ != null and occ.color == color and not occ.petrified:
				score += 0.6
	# Ranged threats are lethal here (attacks always land), so a royal in a
	# firing line is in mortal danger and the AI must respect that.
	score -= 4.0 * _royal_ranged_threats(state, color)
	score += 2.0 * _royal_ranged_threats(state, opp)
	# Small advancement bonus keeps peasants marching.
	for p in all_pieces(state, color):
		if "Peasant" in p.traits and not p.petrified:
			var adv = (peasant_row(color) - p.pos.y) * forward_dir(color) * -1.0
			score += 0.03 * adv
	return score


# Number of enemy ranged pieces currently able to hit victim_color's royals.
static func _royal_ranged_threats(state: Dictionary, victim_color: String) -> int:
	var attacker_color = "black" if victim_color == "white" else "white"
	var threats = 0
	for royal in all_pieces(state, victim_color):
		if not royal.royal or royal.petrified:
			continue
		for p in all_pieces(state, attacker_color):
			if p.petrified:
				continue
			match p.type:
				"Rifleman":
					if _clear_orthogonal_ray(state, p.pos, royal.pos):
						threats += 1
				"Cannonier":
					# The cannon rakes its whole forward column, unblockable.
					if p.pos.x == royal.pos.x and sign(royal.pos.y - p.pos.y) == forward_dir(p.color):
						threats += 1
				"Dragonrider":
					var d = royal.pos - p.pos
					if (abs(d.x) <= 1 and abs(d.y) == 2) or (abs(d.y) <= 1 and abs(d.x) == 2) \
							or (abs(d.x) + abs(d.y) == 1):
						threats += 1
	return threats


static func _clear_orthogonal_ray(state: Dictionary, from_pos: Vector2, to_pos: Vector2) -> bool:
	if from_pos.x != to_pos.x and from_pos.y != to_pos.y:
		return false
	var dir = (to_pos - from_pos).sign()
	var pos = from_pos + dir
	while pos != to_pos:
		if piece_at(state, pos) != null:
			return false
		pos += dir
	return true
