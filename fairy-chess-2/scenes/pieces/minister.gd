# --- minister.gd  ---
extends ChessPiece

func _init():
	piece_type = "Minister"
	is_royal = false

func get_valid_actions(board_state):
	var actions = []
	var game_board = get_node("/root/FairyChess/GameBoard")

	var move_dirs = [Vector2(1,1),Vector2(1,-1),Vector2(-1,1),Vector2(-1,-1)]
	for dir in move_dirs:
		var target_pos = grid_position + dir
		if is_valid_square(target_pos) and (board_state[target_pos.x][target_pos.y] == null or board_state[target_pos.x][target_pos.y].color != color):
			actions.append({"action": "move", "target": target_pos})
	
	return actions
func is_valid_square(pos):
	return pos.x >= 0 and pos.x < 6 and pos.y >= 0 and pos.y < 6
