# --- pawn.gd (New) ---
extends ChessPiece

func _init():
	piece_type = "Pawn"

func get_valid_actions(board_state):
	var actions = []
	var game_board = get_node("/root/FairyChess/GameBoard")
	var forward_dir = -1 if color == "white" else 1
	
	# 1. Standard one-square move
	var one_step = grid_position + Vector2(0, forward_dir)
	if game_board.is_valid_square(one_step) and board_state[one_step.x][one_step.y] == null:
		actions.append({"action": "move", "target": one_step})

		# 2. Two-square first move
		var start_row = 4 if color == "white" else 1
		var two_steps = grid_position + Vector2(0, forward_dir * 2)
		if grid_position.y == start_row and game_board.is_valid_square(two_steps) and board_state[two_steps.x][two_steps.y] == null:
			actions.append({"action": "move", "target": two_steps, "is_double_move": true})
			
	# 3. Diagonal captures
	for x_dir in [-1, 1]:
		var capture_pos = grid_position + Vector2(x_dir, forward_dir)
		if game_board.is_valid_square(capture_pos):
			var occupant = board_state[capture_pos.x][capture_pos.y]
			if occupant and occupant.color != color:
				actions.append({"action": "move", "target": capture_pos})
			
			# 4. En Passant
			if game_board.en_passant_target_square == capture_pos:
				actions.append({"action": "move", "target": capture_pos, "is_en_passant": true})

	# 5. Promotion
	var promotion_row = 0 if color == "white" else 5
	if grid_position.y == promotion_row:
		actions.append({"action": "promote", "target_pawn": self, "promote_to": "Valkyrie"}) # Default to Valkyrie
		
	return actions
