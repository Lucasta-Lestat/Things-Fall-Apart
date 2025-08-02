# --- rifleman.gd ---
# This script remains unchanged.
extends ChessPiece

func _init():
	piece_type = "Rifleman"
	is_royal = false
	
func is_valid_square(pos):
	return pos.x >= 0 and pos.x < 6 and pos.y >= 0 and pos.y < 6
	
func get_valid_actions(board_state):
	var actions = []
	var move_dirs = [Vector2(1,0),Vector2(-1,0),Vector2(0,1),Vector2(0,-1),Vector2(1,1),Vector2(1,-1),Vector2(-1,1),Vector2(-1,-1)]
	for dir in move_dirs:
		var target_pos = grid_position + dir
		if is_valid_square(target_pos) and (board_state[target_pos.x][target_pos.y] == null or board_state[target_pos.x][target_pos.y].color != color):
			actions.append({"action": "move", "target": target_pos})

	var shoot_dirs = [Vector2(1,0),Vector2(-1,0),Vector2(0,1),Vector2(0,-1)]
	for dir in shoot_dirs:
		var current_pos = grid_position + dir
		while is_valid_square(current_pos):
			if board_state[current_pos.x][current_pos.y] != null:
				if board_state[current_pos.x][current_pos.y].color != color:
					actions.append({"action": "shoot", "target": current_pos})
				break
			current_pos += dir
	return actions
