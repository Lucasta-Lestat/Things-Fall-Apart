# --- Rook.gd ---
extends ChessPiece

func _init():
	piece_type = "Rook"
	is_royal = false

func get_valid_actions(board_state):
	var actions = []
	var game_board = get_node("/root/FairyChess/GameBoard")

	# Rook Moves
	var rook_dirs = [Vector2(1,0),Vector2(-1,0),Vector2(0,1),Vector2(0,-1)]
	for dir in rook_dirs:
		var current_pos = grid_position + dir
		while game_board.is_valid_square(current_pos):
			var occupant = board_state[current_pos.x][current_pos.y]
			if occupant == null:
				actions.append({"action": "move", "target": current_pos})
			else:
				if occupant.color != color:
					actions.append({"action": "move", "target": current_pos})
				break
			current_pos += dir
	return actions
