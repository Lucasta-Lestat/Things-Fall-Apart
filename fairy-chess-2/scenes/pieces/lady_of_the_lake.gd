# --- lady_of_the_lake.gd ---
extends ChessPiece

func _init():
	piece_type = "Lady of the Lake"
	is_royal = true

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
				
	# --- Special Action: Promote Pawn ---
	var adjacent_dirs = [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]
	for dir in adjacent_dirs:
		var adj_pos = grid_position + dir
		if is_valid_square(adj_pos):
			print("Found valid square for promotion action for Lady of the Lake")
			var piece = board_state[adj_pos.x][adj_pos.y]
			if piece and piece.color == color and piece.piece_type in ["Pawn", "Kulak"]:
				print("Attempting to add promotion action to Lady of the Lake")
				actions.append({"action": "promote", "target_pawn": piece, "promote_to": "King"})
					
	return actions
func is_valid_square(pos):
	return pos.x >= 0 and pos.x < 6 and pos.y >= 0 and pos.y < 6
