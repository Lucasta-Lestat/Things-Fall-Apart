# ChessPiece.gd
class_name ChessPiece
extends Node2D

@export var type: FairyChessGame.PieceType
@export var player: int  # 1 for white, -1 for black
@export var is_royal: bool = false
@export var is_frozen: bool = false

# Special piece state
var capture_count: int = 0  # For Peasant Army
var captured_pieces: Array[ChessPiece] = []  # For Werewolf
var is_hidden: bool = false  # For Cultist
var is_away: bool = false  # For Valkyrie
var created_pits: Array[Vector2i] = []  # For Tunneler
var last_opponent_move: FairyChessGame.PieceType  # For Doppleganger

func setup(piece_type: FairyChessGame.PieceType, piece_player: int):
	type = piece_type
	player = piece_player
	is_royal = get_royal_status(piece_type)
	
	# Set visual representation
	update_sprite()

func get_royal_status(piece_type: FairyChessGame.PieceType) -> bool:
	match piece_type:
		FairyChessGame.PieceType.KING:
			return true
		FairyChessGame.PieceType.CHANCELLOR:
			return true  # In Republic
		FairyChessGame.PieceType.PONTIFEX:
			return true  # In Theocracy
		FairyChessGame.PieceType.FACTORY:
			return true  # In Technocracy
		_:
			return false

func get_valid_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	if is_frozen:
		return []
	
	var moves: Array[Vector2i] = []
	
	match type:
		FairyChessGame.PieceType.PAWN:
			moves = get_pawn_moves(from_pos, board)
		FairyChessGame.PieceType.ROOK:
			moves = get_rook_moves(from_pos, board)
		FairyChessGame.PieceType.KNIGHT:
			moves = get_knight_moves(from_pos, board)
		FairyChessGame.PieceType.BISHOP:
			moves = get_bishop_moves(from_pos, board)
		FairyChessGame.PieceType.QUEEN:
			moves = get_queen_moves(from_pos, board)
		FairyChessGame.PieceType.KING:
			moves = get_king_moves(from_pos, board)
		FairyChessGame.PieceType.ANARCH:
			moves = get_anarch_moves(from_pos, board)
		FairyChessGame.PieceType.PEASANT_ARMY:
			moves = get_pawn_moves(from_pos, board)
		FairyChessGame.PieceType.WEREWOLF:
			moves = get_werewolf_moves(from_pos, board)
		FairyChessGame.PieceType.DOPPLEGANGER:
			moves = get_doppleganger_moves(from_pos, board)
		FairyChessGame.PieceType.KULAK:
			moves = get_kulak_moves(from_pos, board)
		FairyChessGame.PieceType.VALKYRIE:
			moves = get_valkyrie_moves(from_pos, board)
		FairyChessGame.PieceType.PONTIFEX:
			moves = get_pontifex_moves(from_pos, board)
		FairyChessGame.PieceType.CHANCELLOR:
			moves = get_chancellor_moves(from_pos, board)
		FairyChessGame.PieceType.RIFLEMAN:
			moves = get_rifleman_moves(from_pos, board)
		FairyChessGame.PieceType.CANNONIER:
			moves = get_cannonier_moves(from_pos, board)
		FairyChessGame.PieceType.PRINCESS:
			moves = get_princess_moves(from_pos, board)
		FairyChessGame.PieceType.LADY_OF_THE_LAKE:
			moves = get_lady_moves(from_pos, board)
		FairyChessGame.PieceType.CENTAUR:
			moves = get_centaur_moves(from_pos, board)
		FairyChessGame.PieceType.CULTIST:
			moves = get_cultist_moves(from_pos, board)
		FairyChessGame.PieceType.NIGHTRIDER:
			moves = get_nightrider_moves(from_pos, board)
		FairyChessGame.PieceType.UNICORN:
			moves = get_unicorn_moves(from_pos, board)
		FairyChessGame.PieceType.PEGASUS:
			moves = get_pegasus_moves(from_pos, board)
		FairyChessGame.PieceType.GRASSHOPPER:
			moves = get_grasshopper_moves(from_pos, board)
		FairyChessGame.PieceType.LOCUST:
			moves = get_locust_moves(from_pos, board)
		FairyChessGame.PieceType.DRAGON_RIDER:
			moves = get_dragon_rider_moves(from_pos, board)
		FairyChessGame.PieceType.STORM_BRINGER:
			moves = get_storm_bringer_moves(from_pos, board)
		FairyChessGame.PieceType.DEVIL_TOAD:
			moves = get_devil_toad_moves(from_pos, board)
		FairyChessGame.PieceType.GRAVITURGE:
			moves = get_graviturge_moves(from_pos, board)
		FairyChessGame.PieceType.GORGON:
			moves = get_gorgon_moves(from_pos, board)
		FairyChessGame.PieceType.TUNNELER:
			moves = get_tunneler_moves(from_pos, board)
		FairyChessGame.PieceType.FACTORY:
			moves = get_factory_moves(from_pos, board)
		FairyChessGame.PieceType.GIANT:
			moves = get_giant_moves(from_pos, board)
		FairyChessGame.PieceType.CHECKER:
			moves = get_checker_moves(from_pos, board)
	
	return filter_valid_positions(moves)

# Basic piece movements
func get_pawn_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	var direction = -player  # White moves up (-1), Black moves down (1)
	var forward = from_pos + Vector2i(0, direction)
	
	# Forward move
	if is_valid_pos(forward) and board[forward.y][forward.x] == null:
		moves.append(forward)
	
	# Diagonal captures
	for dx in [-1, 1]:
		var capture_pos = from_pos + Vector2i(dx, direction)
		if is_valid_pos(capture_pos):
			var target = board[capture_pos.y][capture_pos.x]
			if target and target.player != player:
				moves.append(capture_pos)
	
	return moves

func get_rook_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	var directions = [Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0)]
	
	for direction in directions:
		var pos = from_pos + direction
		while is_valid_pos(pos):
			var piece = board[pos.y][pos.x]
			if piece == null:
				moves.append(pos)
			else:
				if piece.player != player:
					moves.append(pos)
				break
			pos += direction
	
	return moves

func get_knight_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	var knight_moves = [
		Vector2i(2, 1), Vector2i(2, -1), Vector2i(-2, 1), Vector2i(-2, -1),
		Vector2i(1, 2), Vector2i(1, -2), Vector2i(-1, 2), Vector2i(-1, -2)
	]
	
	for move in knight_moves:
		var pos = from_pos + move
		if is_valid_pos(pos):
			var piece = board[pos.y][pos.x]
			if piece == null or piece.player != player:
				moves.append(pos)
	
	return moves

func get_bishop_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	var directions = [Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]
	
	for direction in directions:
		var pos = from_pos + direction
		while is_valid_pos(pos):
			var piece = board[pos.y][pos.x]
			if piece == null:
				moves.append(pos)
			else:
				if piece.player != player:
					moves.append(pos)
				break
			pos += direction
	
	return moves

func get_queen_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	moves.append_array(get_rook_moves(from_pos, board))
	moves.append_array(get_bishop_moves(from_pos, board))
	return moves

func get_king_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			
			var pos = from_pos + Vector2i(dx, dy)
			if is_valid_pos(pos):
				var piece = board[pos.y][pos.x]
				if piece == null or piece.player != player:
					moves.append(pos)
	
	return moves

# Fairy piece movements
func get_anarch_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	
	# Normal pawn moves
	moves.append_array(get_pawn_moves(from_pos, board))
	
	# Teleport to attack Queen/King/Royal pieces
	for row in FairyChessGame.BOARD_SIZE:
		for col in FairyChessGame.BOARD_SIZE:
			var pos = Vector2i(col, row)
			var piece = board[row][col]
			if piece and piece.player != player:
				if piece.type in [FairyChessGame.PieceType.QUEEN, FairyChessGame.PieceType.KING] or piece.is_royal:
					# Check if anarch would be attacking from this position
					var attack_pos = pos + Vector2i(0, player)  # Pawn attack direction
					if attack_pos == from_pos:
						moves.append(pos)
	
	return moves

func get_werewolf_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	moves.append_array(get_pawn_moves(from_pos, board))
	moves.append_array(get_rook_moves(from_pos, board))
	return moves

func get_doppleganger_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	# Simulate moves of last opponent piece type
	var temp_type = type
	type = last_opponent_move
	var moves = get_valid_moves(from_pos, board)
	type = temp_type
	return moves

func get_kulak_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	var direction = -player
	
	# Diagonal moves (reverse of pawn)
	for dx in [-1, 1]:
		var move_pos = from_pos + Vector2i(dx, direction)
		if is_valid_pos(move_pos) and board[move_pos.y][move_pos.x] == null:
			moves.append(move_pos)
	
	# Straight captures
	var capture_pos = from_pos + Vector2i(0, direction)
	if is_valid_pos(capture_pos):
		var target = board[capture_pos.y][capture_pos.x]
		if target and target.player != player:
			moves.append(capture_pos)
	
	return moves

func get_chancellor_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	moves.append_array(get_rook_moves(from_pos, board))
	moves.append_array(get_knight_moves(from_pos, board))
	return moves

func get_princess_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	moves.append_array(get_bishop_moves(from_pos, board))
	moves.append_array(get_knight_moves(from_pos, board))
	return moves

func get_centaur_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	moves.append_array(get_king_moves(from_pos, board))
	moves.append_array(get_knight_moves(from_pos, board))
	return moves

func get_unicorn_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	var unicorn_moves = [
		Vector2i(3, 1), Vector2i(3, -1), Vector2i(-3, 1), Vector2i(-3, -1),
		Vector2i(1, 3), Vector2i(1, -3), Vector2i(-1, 3), Vector2i(-1, -3)
	]
	
	for move in unicorn_moves:
		var pos = from_pos + move
		if is_valid_pos(pos):
			var piece = board[pos.y][pos.x]
			if piece == null or piece.player != player:
				moves.append(pos)
	
	return moves

func get_nightrider_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	var knight_directions = [
		Vector2i(2, 1), Vector2i(2, -1), Vector2i(-2, 1), Vector2i(-2, -1),
		Vector2i(1, 2), Vector2i(1, -2), Vector2i(-1, 2), Vector2i(-1, -2)
	]
	
	for direction in knight_directions:
		var pos = from_pos + direction
		while is_valid_pos(pos):
			var piece = board[pos.y][pos.x]
			if piece == null:
				moves.append(pos)
			else:
				if piece.player != player:
					moves.append(pos)
				break
			pos += direction
	
	return moves

func get_grasshopper_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	var directions = [
		Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)
	]
	
	for direction in directions:
		var pos = from_pos + direction
		var found_piece = false
		
		# Find the first piece to hop over
		while is_valid_pos(pos):
			if board[pos.y][pos.x] != null:
				found_piece = true
				break
			pos += direction
		
		if found_piece:
			# Land one square beyond the piece
			pos += direction
			if is_valid_pos(pos):
				var target = board[pos.y][pos.x]
				if target == null or target.player != player:
					moves.append(pos)
	
	return moves

func get_locust_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	# Similar to grasshopper but captures the hopped piece
	return get_grasshopper_moves(from_pos, board)

# Special ability handlers
func on_move(from_pos: Vector2i, to_pos: Vector2i, board: Array[Array]):
	match type:
		FairyChessGame.PieceType.GORGON:
			freeze_adjacent_pieces(to_pos, board)
		FairyChessGame.PieceType.GRAVITURGE:
			attract_enemies(to_pos, board)
		FairyChessGame.PieceType.GIANT:
			mutate_adjacent_pieces(to_pos, board)

func freeze_adjacent_pieces(pos: Vector2i, board: Array[Array]):
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			
			var adjacent_pos = pos + Vector2i(dx, dy)
			if is_valid_pos(adjacent_pos):
				var piece = board[adjacent_pos.y][adjacent_pos.x]
				if piece:
					piece.is_frozen = true

func attract_enemies(pos: Vector2i, board: Array[Array]):
	# Move enemy pieces one square closer
	for row in FairyChessGame.BOARD_SIZE:
		for col in FairyChessGame.BOARD_SIZE:
			var piece_pos = Vector2i(col, row)
			var piece = board[row][col]
			if piece and piece.player != player:
				# Check if there's an unobstructed path
				if has_clear_path(pos, piece_pos, board):
					var direction = (pos - piece_pos).normalized()
					var new_pos = piece_pos + Vector2i(int(direction.x), int(direction.y))
					if is_valid_pos(new_pos) and board[new_pos.y][new_pos.x] == null:
						board[piece_pos.y][piece_pos.x] = null
						board[new_pos.y][new_pos.x] = piece

func mutate_adjacent_pieces(pos: Vector2i, board: Array[Array]):
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			
			var adjacent_pos = pos + Vector2i(dx, dy)
			if is_valid_pos(adjacent_pos):
				var piece = board[adjacent_pos.y][adjacent_pos.x]
				if piece and randf() < 0.05:  # 1/20 chance
					# Mutate to random piece type
					var piece_types = FairyChessGame.PieceType.values()
					piece.type = piece_types[randi() % piece_types.size()]
					piece.update_sprite()

# Remaining fairy piece moves
func get_valkyrie_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	if is_away:
		return []  # Valkyrie is away for one turn
	
	var moves: Array[Vector2i] = []
	moves.append_array(get_queen_moves(from_pos, board))
	moves.append_array(get_knight_moves(from_pos, board))
	return moves

func get_pontifex_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	moves.append_array(get_bishop_moves(from_pos, board))
	moves.append_array(get_king_moves(from_pos, board))
	
	# Add promotion moves (adjacent pawns to bishops)
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			
			var adjacent_pos = from_pos + Vector2i(dx, dy)
			if is_valid_pos(adjacent_pos):
				var piece = board[adjacent_pos.y][adjacent_pos.x]
				if piece and piece.player == player and piece.type == FairyChessGame.PieceType.PAWN:
					moves.append(adjacent_pos)  # Special promotion move
	
	return moves

func get_rifleman_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	
	# Move as pawn
	moves.append_array(get_pawn_moves(from_pos, board))
	
	# Capture as king without moving (staying in place)
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			
			var capture_pos = from_pos + Vector2i(dx, dy)
			if is_valid_pos(capture_pos):
				var piece = board[capture_pos.y][capture_pos.x]
				if piece and piece.player != player:
					# This is a ranged capture - add special handling
					moves.append(capture_pos)
	
	return moves

func get_cannonier_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	
	# Move as pawn
	moves.append_array(get_pawn_moves(from_pos, board))
	
	# Capture as rook without moving
	var directions = [Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0)]
	for direction in directions:
		var pos = from_pos + direction
		while is_valid_pos(pos):
			var piece = board[pos.y][pos.x]
			if piece:
				if piece.player != player:
					moves.append(pos)  # Ranged capture
				break
			pos += direction
	
	return moves

func get_lady_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	moves.append_array(get_princess_moves(from_pos, board))
	
	# Add king promotion moves (adjacent pawns to kings)
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			
			var adjacent_pos = from_pos + Vector2i(dx, dy)
			if is_valid_pos(adjacent_pos):
				var piece = board[adjacent_pos.y][adjacent_pos.x]
				if piece and piece.player == player and piece.type == FairyChessGame.PieceType.PAWN:
					moves.append(adjacent_pos)  # Special promotion move
	
	return moves

func get_cultist_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	
	if is_hidden:
		# Appears as pawn to opponent
		moves.append_array(get_pawn_moves(from_pos, board))
	else:
		# Revealed cultist moves
		moves.append_array(get_pawn_moves(from_pos, board))
		
		# Check for conversion opportunities
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				
				var adjacent_pos = from_pos + Vector2i(dx, dy)
				if is_valid_pos(adjacent_pos):
					var piece = board[adjacent_pos.y][adjacent_pos.x]
					if piece and piece.player != player and piece.type == FairyChessGame.PieceType.PAWN:
						moves.append(adjacent_pos)  # Conversion move
	
	return moves

func get_pegasus_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	var unicorn_directions = [
		Vector2i(3, 1), Vector2i(3, -1), Vector2i(-3, 1), Vector2i(-3, -1),
		Vector2i(1, 3), Vector2i(1, -3), Vector2i(-1, 3), Vector2i(-1, -3)
	]
	
	# Repeated (3,1) moves like nightrider
	for direction in unicorn_directions:
		var pos = from_pos + direction
		while is_valid_pos(pos):
			var piece = board[pos.y][pos.x]
			if piece == null:
				moves.append(pos)
			else:
				if piece.player != player:
					moves.append(pos)
				break
			pos += direction
	
	return moves

func get_dragon_rider_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	
	# (4,1) moves
	var dragon_moves = [
		Vector2i(4, 1), Vector2i(4, -1), Vector2i(-4, 1), Vector2i(-4, -1),
		Vector2i(1, 4), Vector2i(1, -4), Vector2i(-1, 4), Vector2i(-1, -4)
	]
	
	for move in dragon_moves:
		var pos = from_pos + move
		if is_valid_pos(pos):
			var piece = board[pos.y][pos.x]
			if piece == null or piece.player != player:
				moves.append(pos)
	
	# Cone attack (special ability move)
	var directions = [Vector2i(0, -player), Vector2i(1, -player), Vector2i(-1, -player)]  # Forward cone
	for direction in directions:
		var pos1 = from_pos + direction
		var pos2 = from_pos + direction * 2
		if is_valid_pos(pos1):
			moves.append(pos1)  # Cone attack position
		if is_valid_pos(pos2):
			moves.append(pos2)  # Cone attack position
	
	return moves

func get_storm_bringer_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	
	# (5,1) leap
	var storm_moves = [
		Vector2i(5, 1), Vector2i(5, -1), Vector2i(-5, 1), Vector2i(-5, -1),
		Vector2i(1, 5), Vector2i(1, -5), Vector2i(-1, 5), Vector2i(-1, -5)
	]
	
	for move in storm_moves:
		var pos = from_pos + move
		if is_valid_pos(pos):
			var piece = board[pos.y][pos.x]
			if piece == null or piece.player != player:
				moves.append(pos)
	
	# Adjacent capture (special ability - captures all adjacent)
	# This is handled as a special move type
	moves.append(from_pos)  # Stay in place but capture all adjacent
	
	return moves

func get_devil_toad_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	var directions = [Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]
	
	for direction in directions:
		var pos = from_pos + direction
		while true:
			if pos.x < 0 or pos.x >= FairyChessGame.BOARD_SIZE:
				# Bounce off vertical edges
				direction.x *= -1
				pos.x = clamp(pos.x, 0, FairyChessGame.BOARD_SIZE - 1)
			
			if pos.y < 0 or pos.y >= FairyChessGame.BOARD_SIZE:
				# Bounce off horizontal edges  
				direction.y *= -1
				pos.y = clamp(pos.y, 0, FairyChessGame.BOARD_SIZE - 1)
			
			if not is_valid_pos(pos):
				break
			
			var piece = board[pos.y][pos.x]
			if piece == null:
				moves.append(pos)
			else:
				if piece.player != player:
					moves.append(pos)
				break
			
			pos += direction
	
	return moves

func get_graviturge_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	# Moves as king but has special ability to attract enemies
	return get_king_moves(from_pos, board)

func get_gorgon_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	# Moves as king but freezes instead of capturing
	return get_king_moves(from_pos, board)

func get_tunneler_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	
	# Normal king moves
	moves.append_array(get_king_moves(from_pos, board))
	
	# Teleport between pits
	for pit_pos in created_pits:
		if pit_pos != from_pos:
			moves.append(pit_pos)
	
	return moves

func get_factory_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	
	# Factory cannot move, but can create pieces
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			
			var adjacent_pos = from_pos + Vector2i(dx, dy)
			if is_valid_pos(adjacent_pos) and board[adjacent_pos.y][adjacent_pos.x] == null:
				moves.append(adjacent_pos)  # Position to create new piece
	
	return moves

func get_giant_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	moves.append_array(get_queen_moves(from_pos, board))
	moves.append_array(get_knight_moves(from_pos, board))
	return moves

func get_checker_moves(from_pos: Vector2i, board: Array[Array]) -> Array[Vector2i]:
	var moves: Array[Vector2i] = []
	
	# Diagonal moves like checkers
	var directions = [Vector2i(1, player), Vector2i(-1, player)]  # Forward diagonals
	
	for direction in directions:
		var pos = from_pos + direction
		if is_valid_pos(pos):
			var piece = board[pos.y][pos.x]
			if piece == null:
				moves.append(pos)
			elif piece.player != player:
				# Jump over enemy piece
				var jump_pos = pos + direction
				if is_valid_pos(jump_pos) and board[jump_pos.y][jump_pos.x] == null:
					moves.append(jump_pos)
	
	return moves

# Utility functions
func is_valid_pos(pos: Vector2i) -> bool:
	return pos.x >= 0 and pos.x < FairyChessGame.BOARD_SIZE and pos.y >= 0 and pos.y < FairyChessGame.BOARD_SIZE

func filter_valid_positions(moves: Array[Vector2i]) -> Array[Vector2i]:
	var valid_moves: Array[Vector2i] = []
	for move in moves:
		if is_valid_pos(move):
			valid_moves.append(move)
	return valid_moves

func has_clear_path(from_pos: Vector2i, to_pos: Vector2i, board: Array[Array]) -> bool:
	var diff = to_pos - from_pos
	var step = Vector2i(sign(diff.x), sign(diff.y))
	var pos = from_pos + step
	
	while pos != to_pos:
		if not is_valid_pos(pos) or board[pos.y][pos.x] != null:
			return false
		pos += step
	
	return true

func update_sprite():
	# Update visual representation based on type and player
	# This would load appropriate sprite/texture for the piece
	pass

func can_be_captured_by(attacker: ChessPiece) -> bool:
	# Special rules for certain pieces
	match type:
		FairyChessGame.PieceType.UNICORN:
			return attacker.type == FairyChessGame.PieceType.PRINCESS or is_completely_surrounded()
		_:
			return true

func is_completely_surrounded() -> bool:
	# Check if all 8 adjacent squares are occupied by enemy pieces
	# Implementation would check the board state
	return false
