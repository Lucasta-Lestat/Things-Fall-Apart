# --- Chancellor.gd ---
extends ChessPiece

func _init():
	piece_type = "Princess"
	is_royal = false

func get_valid_actions(board_state):
	var actions = []
	var game_board = get_node("/root/FairyChess/GameBoard")

	#Bishop Moves
	var bishop_dirs = [
		Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)  # Bishop
	]
	for dir in bishop_dirs:
		var current_pos = grid_position + dir
		while game_board.is_valid_square(current_pos):
			var occupant = board_state[current_pos.x][current_pos.y]
			if occupant == null:
				actions.append({"action": "move", "target": current_pos})
			else:
				if occupant.color != color:
					actions.append({"action": "move", "target": current_pos})
				break # Path is blocked
			current_pos += dir 
	
	# Knight Moves
	var knight_dirs = [Vector2(1,2),Vector2(1,-2),Vector2(-1,2),Vector2(-1,-2),Vector2(2,1),Vector2(2,-1),Vector2(-2,1),Vector2(-2,-1)]
	for dir in knight_dirs:
		var target_pos = grid_position + dir
		if game_board.is_valid_square(target_pos):
			var occupant = board_state[target_pos.x][target_pos.y]
			if occupant == null or occupant.color != color:
				actions.append({"action": "move", "target": target_pos})
					
	return actions
