extends ChessPiece

func _init():
	piece_type = "Kulak"
	traits.append("Peasant")

func get_valid_actions(board_state):
	var actions = []
	var game_board = get_node("/root/FairyChess/GameBoard")
	var forward_dir = -1 if color == "white" else 1

	# 1. Standard diagonal move
	for x_dir in [-1, 1]:
		var one_step = grid_position + Vector2(x_dir, forward_dir)
		if game_board.is_valid_square(one_step) and board_state[one_step.x][one_step.y] == null:
			actions.append({"action": "move", "target": one_step})

			# 2. Two-square first move
			var start_row = 4 if color == "white" else 1
			var two_steps = grid_position + Vector2(x_dir * 2, forward_dir * 2)
			if grid_position.y == start_row and game_board.is_valid_square(two_steps) and board_state[two_steps.x][two_steps.y] == null:
				# Check if path is clear
				if board_state[one_step.x][one_step.y] == null:
					actions.append({"action": "move", "target": two_steps, "is_double_move": true})

	# 3. Straight captures
	var capture_pos = grid_position + Vector2(0, forward_dir)
	if game_board.is_valid_square(capture_pos):
		var occupant = board_state[capture_pos.x][capture_pos.y]
		if occupant and occupant.color != color:
			actions.append({"action": "move", "target": capture_pos})

	# 4. En Passant (for Kulak, captures a piece that double-moved diagonally)
	# This is a custom interpretation. It assumes the en passant target is set by a double-moving Kulak.
	if game_board.en_passant_target_square != Vector2.ZERO:
		# Check if the target is diagonally adjacent
		for x_dir in [-1, 1]:
			if grid_position + Vector2(x_dir, 0) == game_board.en_passant_target_square + Vector2(0, forward_dir):
				var target_pos = game_board.en_passant_target_square
				actions.append({"action": "move", "target": target_pos, "is_en_passant": true})

	# 5. Promotion
	var promotion_row = 0 if color == "white" else 5
	if grid_position.y == promotion_row:
		actions.append({"action": "promote", "target_pawn": self, "promote_to": "Valkyrie"})
		
	return actions
