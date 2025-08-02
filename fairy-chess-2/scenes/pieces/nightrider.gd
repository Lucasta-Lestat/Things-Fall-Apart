# --- nightrider.gd ---
extends ChessPiece

func _init():
	piece_type = "Nightrider"
	is_royal = false

func get_valid_actions(board_state):
	# Repeated Knight moves
	var actions = []
	var knight_dirs = [Vector2(1,2), Vector2(1,-2), Vector2(-1,2), Vector2(-1,-2), Vector2(2,1), Vector2(2,-1), Vector2(-2,1), Vector2(-2,-1)]
	
	for move_dir in knight_dirs:
		var current_pos = grid_position + move_dir
		while is_valid_square(current_pos):
			if board_state[current_pos.x][current_pos.y] == null:
				actions.append({"action": "move", "target": current_pos})
			else:
				if board_state[current_pos.x][current_pos.y].color != color:
					actions.append({"action": "move", "target": current_pos})
				break
			current_pos += move_dir
	return actions

func is_valid_square(pos):
	return pos.x >= 0 and pos.x < 6 and pos.y >= 0 and pos.y < 6
