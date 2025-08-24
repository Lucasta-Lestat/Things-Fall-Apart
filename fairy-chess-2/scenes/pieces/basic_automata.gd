# --- basic_automata.gd ---
extends ChessPiece

func _init():
	piece_type = "Basic Automata"

func get_valid_actions(board_state):
	var actions = []
	var game_board = get_node("/root/FairyChess/GameBoard")
	var forward_dir = -1 if color == "white" else 1
	
	# --- Standard Moves (Pawn +1 range) ---
	# One-step move
	var one_step = grid_position + Vector2(0, forward_dir)
	var two_steps = grid_position + Vector2(0, forward_dir*2)
	if game_board.is_valid_square(one_step) and board_state[one_step.x][one_step.y] == null:
		actions.append({"action": "move", "target": one_step})
		# Two-step move
		two_steps = grid_position + Vector2(0, forward_dir * 2)
		if game_board.is_valid_square(two_steps) and board_state[two_steps.x][two_steps.y] == null:
			actions.append({"action": "move", "target": two_steps})

	# --- Three-square first move ---
	var start_row = 4 if color == "white" else 1
	var three_steps = grid_position + Vector2(0, forward_dir * 3)
	if grid_position.y == start_row and game_board.is_valid_square(three_steps) and board_state[three_steps.x][three_steps.y] == null:
		# Check if path is clear
		if board_state[one_step.x][one_step.y] == null and board_state[two_steps.x][two_steps.y] == null:
			actions.append({"action": "move", "target": three_steps, "is_double_move": true}) # Re-use double_move flag for en passant
			
	# --- Diagonal Captures (up to 2 squares away) ---
	for x_dir in [-1, 1]:
		for dist in [1, 2]:
			var capture_pos = grid_position + Vector2(x_dir * dist, forward_dir * dist)
			if game_board.is_valid_square(capture_pos):
				var occupant = board_state[capture_pos.x][capture_pos.y]
				if occupant and occupant.color != color:
					actions.append({"action": "move", "target": capture_pos})
				# Path is blocked for further captures in this direction
				if occupant != null:
					break
	
	# (Promotion logic would be added here if applicable)
		
	return actions
