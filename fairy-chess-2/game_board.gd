# game_board.gd
# Main script for handling the game logic of the synchronous fairy chess.
# This script manages the board state, piece movements, and turn resolution.

extends Node2D

# --- Signals ---
signal game_state_changed(new_state)
signal turn_resolved(moves)
signal setup_state_changed() # To update UI during setup
signal turn_info_changed(message) # New, more flexible UI signal
signal piece_spawned(piece_node, grid_pos)

signal spawn_credits_changed(white_credits, black_credits)

@onready var audio_manager = get_node("../AudioManager")
# --- Constants ---
const BOARD_SIZE = 6
const MAX_PEASANTS = 4
const MAX_NON_PEASANTS = 4

# --- Game State ---
var board = [] # 2D array representing the 6x6 board
var current_player_turn = "white" # Whose turn it is to declare moves
var game_phase = "setup" # "setup", "playing", "game_over"
var white_actions = {} # {piece: {"action": "move", "target": pos}}
var black_actions = {}
var white_spawn_credits = {} #dictionary of spawnable pieces
var black_spawn_credits = {}

# --- Setup State ---
var setup_placer = "white" # Who is currently placing a piece
var white_placed_pieces = {"peasant": 0, "non_peasant": 0, "royal": 0}
var black_placed_pieces = {"peasant": 0, "non_peasant": 0, "royal": 0}
 #Get profiles from the global PlayerDatabase 
var white_profile = PlayerDatabase.get_profile("god")
var black_profile = PlayerDatabase.get_profile("Zionis")
# --- Special Game State ---
var phased_out_pieces = {} # {piece: turns_to_return} for Valkyrie
var en_passant_target_square = Vector2.ZERO

# --- Initialization ---
func _ready():
	print("white_profile: ", white_profile)

	initialize_board()
	emit_signal("game_state_changed", game_phase)
	emit_signal("turn_info_changed", "White to move.")


func initialize_board():
	board.resize(BOARD_SIZE)
	for i in range(BOARD_SIZE):
		board[i] = []
		board[i].resize(BOARD_SIZE)
		for j in range(BOARD_SIZE):
			board[i][j] = null


# --- Turn Resolution ---
func resolve_turn():
	var all_actions = {}
	all_actions.merge(white_actions)
	all_actions.merge(black_actions)

	# --- Phase 0: Initialization ---
	var destinations = {}
	var captures = []
	var promotions = []
	var spawns = []
	var aoe_attacks = []
	var petrify_sources = []
	en_passant_target_square = Vector2.ZERO

	# --- Phase 1: Process Actions ---
	for piece in all_actions.keys():
		var action = all_actions[piece]
		print("Actions for ", piece, " are ", action )
		match action.action:
			"move":
				audio_manager.play_sfx("move")
				destinations[piece] = action.target
				if piece.piece_type == "Gorgon": petrify_sources.append(piece)
				if action.has("is_double_move"):
					var dir = (action.target - piece.grid_position).normalized()
					en_passant_target_square = piece.grid_position + dir
				if action.has("is_en_passant"):
					var captured_pawn_pos = action.target - Vector2(0, -1 if piece.color == "white" else 1)
					if is_valid_square(captured_pawn_pos) and board[captured_pawn_pos.x][captured_pawn_pos.y]:
						captures.append(board[captured_pawn_pos.x][captured_pawn_pos.y])
			"shoot":
				var target_piece = board[action.target.x][action.target.y]
				audio_manager.play_sfx("shoot")
				if target_piece: captures.append(target_piece)
			"promote":
				promotions.append(action)
				audio_manager.play_sfx("promote")
				print("promotion appended")
			"fire_cannon" :
				action["piece"] = piece 
				audio_manager.play_sfx("cannon")
				print("DEBUG: attempting to append cannonfire to aoe_attacks")
				aoe_attacks.append(action)
			"dragon_breath":
				action["piece"] = piece 
				print("DEBUG: attempting to append dragon_breath  to aoe_attacks")
				aoe_attacks.append(action)
	# --- Phase 2: Identify Movement-Based Captures ---
	var final_positions = {}
	for piece in destinations.keys():
		var target_pos = destinations[piece]
		if not final_positions.has(target_pos):
			final_positions[target_pos] = []
		final_positions[target_pos].append(piece)

	for pos in final_positions.keys():
		var arriving_pieces = final_positions[pos]
		var original_occupant = board[pos.x][pos.y]

		if arriving_pieces.size() > 1:
			for piece in arriving_pieces:
				if not piece in captures: captures.append(piece)
		
		if original_occupant and not destinations.has(original_occupant):
			if not original_occupant in captures:
				captures.append(original_occupant)
			if arriving_pieces.size() == 1 and arriving_pieces[0].piece_type == "Nightrider":
				#spawns.append({"type": "Pawn", "color": arriving_pieces[0].color, "pos": arriving_pieces[0].grid_position})
				print("PAWN ADDED TO SPAWNS")
				if arriving_pieces[0].color == "white":
					print("DEBUG: White spawn credits updated")
					white_spawn_credits["Pawn"] = white_spawn_credits.get("Pawn", 0) + 1
					emit_signal("spawn_credits_changed", white_spawn_credits, black_spawn_credits)

				else:
					print("DEBUG: Black spawn credits updated")
					black_spawn_credits["Pawn"] = black_spawn_credits.get("Pawn", 0) + 1
					emit_signal("spawn_credits_changed", white_spawn_credits, black_spawn_credits)
	
	# --- Phase 3: Path Blocking & Swapping Resolution ---
	var blocked_pieces = []
	for piece_a in destinations.keys():
		for piece_b in destinations.keys():
			if piece_a == piece_b: continue
			
			if piece_a.grid_position == destinations.get(piece_b) and piece_b.grid_position == destinations.get(piece_a):
				if not piece_a in captures: captures.append(piece_a)
				if not piece_b in captures: captures.append(piece_b)
				continue

			var path_a = calculate_move_path(piece_a.grid_position, destinations[piece_a])
			if destinations[piece_b] in path_a:
				if not piece_a in blocked_pieces: blocked_pieces.append(piece_a)
				if not piece_b in blocked_pieces: blocked_pieces.append(piece_b)
	for piece in blocked_pieces:
		if not piece in captures: captures.append(piece)

	# --- Phase 4: Area of Effect Resolution ---
	for attack in aoe_attacks:
		var attacker = attack.piece
		if attack.action == "fire_cannon":
			var forward_dir = -1 if attacker.color == "white" else 1
			for y in range(1, BOARD_SIZE):
				var pos = attacker.grid_position + Vector2(0, y * forward_dir)
				if is_valid_square(pos) and board[pos.x][pos.y]:
					if not board[pos.x][pos.y] in captures: captures.append(board[pos.x][pos.y])
		elif attack.action == "dragon_breath":
			print("DEBUG: attack.action dragon breath in game_board")
			# Read the direction from the action and calculate the cone ---
			var direction = attack.direction
			var cone_squares = []
			if direction == Vector2.UP:
				cone_squares = [Vector2(-1,-2), Vector2(0,-2), Vector2(1,-2), Vector2(0,-1)]
			elif direction == Vector2.DOWN:
				cone_squares = [Vector2(-1,2), Vector2(0,2), Vector2(1,2), Vector2(0,1)]
			elif direction == Vector2.LEFT:
				cone_squares = [Vector2(-2,-1), Vector2(-2,0), Vector2(-2,1), Vector2(-1,0)]
			elif direction == Vector2.RIGHT:
				cone_squares = [Vector2(2,-1), Vector2(2,0), Vector2(2,1), Vector2(1,0)]
			
			for offset in cone_squares:
				var pos = attacker.grid_position + offset
				print("DEBUG: pos in dragon breath: ", pos)
				if is_valid_square(pos) and board[pos.x][pos.y]:
					print("DEBUG: attempting to append captures for dragon breath")
					if not board[pos.x][pos.y] in captures: captures.append(board[pos.x][pos.y])

	# --- Phase 5: Finalize Captures & Death Rattles ---
	var unique_captures = []
	for piece in captures:
		if not piece in unique_captures: unique_captures.append(piece)
		audio_manager.play_sfx("capture")
	for piece_to_capture in unique_captures:
		if piece_to_capture.is_inside_tree():
			piece_to_capture.on_capture(self)

	# --- Phase 6: Build Next Board State ---
	var next_board_state = []
	next_board_state.resize(BOARD_SIZE)
	for i in range(BOARD_SIZE):
		next_board_state[i] = []
		next_board_state[i].resize(BOARD_SIZE)
		for j in range(BOARD_SIZE):
			next_board_state[i][j] = null # Explicitly create a clean board

	# Iterate through the CURRENT board to find all surviving pieces
	for x in range(BOARD_SIZE):
		for y in range(BOARD_SIZE):
			var piece = board[x][y]
			# Check if a piece exists on this square and if it has not been captured
			if piece and not piece in unique_captures:
				# This piece survives. Find its final position.
				var final_pos = destinations.get(piece, piece.grid_position)
				# Place the piece reference in the new board at its final destination.
				if is_valid_square(final_pos):
					next_board_state[int(final_pos.x)][int(final_pos.y)] = piece
				else:
					print("Error: Piece %s tried to move to an invalid square %s" % [piece.piece_type, final_pos])
	# --- Phase 7: Promotions, and On-Move Effects ---

	var promoted_pawns = []
	print("promotions: ", promotions)
	
	for promo_action in promotions:
		audio_manager.play_sfx("promote")
		print("promotion loop triggered")
		var pawn = promo_action.target_pawn
		if not pawn in unique_captures:
			var pos = destinations.get(pawn, pawn.grid_position)
			var color = pawn.color
			var new_type = promo_action.promote_to
			
			var new_piece_scene = load(PlayerDatabase.PIECE_DEFINITIONS[new_type]["scene"]).instantiate()
			print("Attempted to instantiate new piece for promotion")
			new_piece_scene.add_to_group("pieces")
			new_piece_scene.setup_piece(new_type, color, false, 80)
			new_piece_scene.grid_position = pos
			next_board_state[pos.x][pos.y] = new_piece_scene
			promoted_pawns.append(pawn)
			emit_signal("piece_spawned", new_piece_scene, pos)
	

	for gorgon in petrify_sources:
		if not gorgon in unique_captures:
			var final_pos = destinations.get(gorgon)
			for dir in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT, Vector2(1,1), Vector2(1,-1), Vector2(-1,1), Vector2(-1,-1)]:
				var adj_pos = final_pos + dir
				if is_valid_square(adj_pos) and next_board_state[adj_pos.x][adj_pos.y]:
					next_board_state[adj_pos.x][adj_pos.y].is_petrified = true

	# --- Phase 8: Finalize State & Cleanup ---
	board = next_board_state
	for piece in unique_captures + promoted_pawns:
		if piece.is_inside_tree() and not phased_out_pieces.has(piece):
			piece.queue_free()

	for piece in destinations.keys():
		if piece.is_inside_tree():
			piece.grid_position = destinations[piece]
	
	emit_signal("turn_resolved", destinations)
	
	
	white_actions.clear()
	black_actions.clear()
	
	check_win_condition()
	if game_phase == "playing":
		emit_signal("turn_info_changed", "White to move.")
		
		
# --- Public Methods (Setup) ---
func place_piece(piece_scene, grid_pos):
	board[grid_pos.x][grid_pos.y] = piece_scene
	var piece_data = piece_scene
	
	var placer_counts = white_placed_pieces if setup_placer == "white" else black_placed_pieces
	
	placer_counts[piece_data.piece_type] = placer_counts.get(piece_data.piece_type, 0) + 1

	setup_placer = "black" if setup_placer == "white" else "white"
	emit_signal("setup_state_changed")
	

# --- Public Methods (Gameplay) ---

func start_game():
	audio_manager.play_music() # Add this line
	if game_phase == "setup":
		game_phase = "playing"
		emit_signal("game_state_changed", game_phase)
		emit_signal("turn_info_changed", "White to move.")

# Called by chessboard_display when a player chooses an action.
func declare_action(piece, action_data):
	if game_phase != "playing": return

	if action_data.action == "spawn":
		var color = action_data.data.color
		var piece_type = action_data.data.piece_type
		
		if color == "white" and white_spawn_credits.get(piece_type, 0) > 0:
			white_spawn_credits[piece_type] -= 1
			var new_piece = load(PlayerDatabase.PIECE_DEFINITIONS[piece_type]).instantiate()
			new_piece.setup_piece(piece_type, color, false, 80)
			new_piece.grid_position = action_data.target
			board[action_data.target.x][action_data.target.y] = new_piece
			emit_signal("piece_spawned", new_piece, action_data.target)
			emit_signal("spawn_credits_changed", white_spawn_credits, black_spawn_credits)
			white_actions[new_piece] = action_data
			emit_signal("turn_info_changed", "Black to move.")
		elif color == "black" and black_spawn_credits.get(piece_type, 0) > 0:
			black_spawn_credits[piece_type] -= 1
			var new_piece = load(PlayerDatabase.PIECE_DEFINITIONS[piece_type]).instantiate()
			new_piece.setup_piece(piece_type, color, false, 80)
			new_piece.grid_position = action_data.target
			board[action_data.target.x][action_data.target.y] = new_piece
			emit_signal("piece_spawned", new_piece, action_data.target)
			emit_signal("spawn_credits_changed", white_spawn_credits, black_spawn_credits)
			black_actions[new_piece] = action_data
			emit_signal("turn_info_changed", "Resolving turn...")
	else:
		if piece.color == "white":
			if white_actions.is_empty():
				white_actions[piece] = action_data
				emit_signal("turn_info_changed", "Black to move.")
		elif piece.color == "black":
			if black_actions.is_empty():
				black_actions[piece] = action_data
				emit_signal("turn_info_changed", "Resolving turn...")
	
	if not white_actions.is_empty() and not black_actions.is_empty():
		resolve_turn()
# --- Helper Functions ---
func get_profile_piece_counts(profile):
	var counts = {"peasant": 0, "non_peasant": 0}
	if not profile: return counts # Safety check
	
	for piece_type in profile.peasants:
		counts.peasant += profile.peasants[piece_type]
	for piece_type in profile.nobles:
		counts.non_peasant += profile.nobles[piece_type]
	for piece_type in profile.royals:
		counts.non_peasant += profile.royals[piece_type]
	return counts

func calculate_move_path(start_pos, end_pos):
	var path = []
	var delta = end_pos - start_pos
	
	# Check if the move is linear (straight or diagonal)
	var is_linear = (delta.x == 0 or delta.y == 0 or abs(delta.x) == abs(delta.y))
	
	# If not linear (e.g., a Knight move), return an empty path as it doesn't block.
	if not is_linear:
		return []

	var direction = delta.sign()
	var current_pos = start_pos + direction
	while current_pos != end_pos:
		path.append(current_pos)
		current_pos += direction
	return path
	
func capture_piece(piece):
	if piece and piece.is_inside_tree():
		board[piece.grid_position.x][piece.grid_position.y] = null
		piece.queue_free()

# --- FIX: Implemented win condition logic ---
func check_win_condition():
	var white_royals = 0
	var black_royals = 0

	# Iterate through the final board state to count remaining royals
	for x in range(BOARD_SIZE):
		for y in range(BOARD_SIZE):
			var piece = board[x][y]
			if piece and piece.is_royal and not piece.is_petrified:
				if piece.color == "white":
					white_royals += 1
				else:
					black_royals += 1
	
	var white_lost = white_royals == 0
	var black_lost = black_royals == 0

	if white_lost and black_lost:
		end_game("Draw")
	elif black_lost:
		end_game("White Wins!")
	elif white_lost:
		end_game("Black Wins!")

func is_valid_square(pos):
	return pos.x >= 0 and pos.x < BOARD_SIZE and pos.y >= 0 and pos.y < BOARD_SIZE
# Ends the game and sets the final state.
func end_game(outcome):
	audio_manager.play_sfx("win") # Add this line
	audio_manager.stop_music() # Optional: stop the music
	game_phase = "game_over"
	emit_signal("game_state_changed", "Game Over: " + outcome)
