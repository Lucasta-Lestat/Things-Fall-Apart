# --- lady_of_the_lake.gd ---
extends ChessPiece

func _init():
	piece_type = "Lady of the Lake"
	is_royal = true

func get_valid_actions(board_state):
	var actions = []
	var game_board = get_node("/root/FairyChess/GameBoard")

	var move_dirs = [Vector2(1,0),Vector2(-1,0),Vector2(0,1),Vector2(0,-1),Vector2(1,1),Vector2(1,-1),Vector2(-1,1),Vector2(-1,-1)]
	for dir in move_dirs:
		var target_pos = grid_position + dir
		if is_valid_square(target_pos) and (board_state[target_pos.x][target_pos.y] == null or board_state[target_pos.x][target_pos.y].color != color):
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
