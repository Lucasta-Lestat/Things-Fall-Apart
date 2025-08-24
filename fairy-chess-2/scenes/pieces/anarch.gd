# anarch.gd
# This script defines the movement for the Anarch piece.

extends ChessPiece

func _init():
	piece_type = "Anarch"
	# This piece is powerful, but likely not royal itself.
	is_royal = false

func get_valid_actions(board_state):
	var actions = []
	var game_board = get_node("/root/FairyChess/GameBoard")# Helper to check squares

	# --- Part 1: Standard King Moves ---
	var king_move_dirs = [
		Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1),
		Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)
	]
	for dir in king_move_dirs:
		var target_pos = grid_position + dir
		if game_board.is_valid_square(target_pos):
			var occupant = board_state[target_pos.x][target_pos.y]
			# Can move to an empty square or capture an opponent.
			if occupant == null or occupant.color != self.color:
				actions.append({"action": "move", "target": target_pos})

	# --- Part 2: Special "Hunter" Moves ---
	# Find all opposing royal pieces on the board.
	for x in range(game_board.BOARD_SIZE):
		for y in range(game_board.BOARD_SIZE):
			var piece = board_state[x][y]
			# Check if there is a piece, it's an opponent, and it's royal.
			if piece and piece.color != self.color and piece.is_royal:
				# Now, check all 8 squares adjacent to that royal piece.
				for dir in king_move_dirs:
					var adjacent_to_royal_pos = piece.grid_position + dir
					# Check if the square is valid and unoccupied.
					if game_board.is_valid_square(adjacent_to_royal_pos):
						var adj_occupant = board_state[adjacent_to_royal_pos.x][adjacent_to_royal_pos.y]
						if adj_occupant == null:
							# Add this as a valid move target for the Anarch.
							actions.append({"action": "move", "target": adjacent_to_royal_pos})
	
	return actions
