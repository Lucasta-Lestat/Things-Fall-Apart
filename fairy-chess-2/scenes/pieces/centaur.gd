# Centaur.gd
extends ChessPiece

func _init():
	piece_type = "Centaur"
	is_royal = false

# The get_valid_actions function MUST always return an array.
func get_valid_actions(board_state):
	# Always initialize an array to hold the actions.
	var actions = []
	var game_board = get_node("/root/FairyChess/GameBoard")

	# Define all 8 possible knight moves.
	var knight_dirs = [
		Vector2(1, 2), Vector2(1, -2), Vector2(-1, 2), Vector2(-1, -2),
		Vector2(2, 1), Vector2(2, -1), Vector2(-2, 1), Vector2(-2, -1)
	]

	for dir in knight_dirs:
		var target_pos = grid_position + dir
		if game_board.is_valid_square(target_pos):
			var occupant = board_state[target_pos.x][target_pos.y]
			# A knight can move to an empty square or capture an enemy piece.
			if occupant == null or occupant.color != color:
				actions.append({"action": "move", "target": target_pos})
				
	var king_dirs = [Vector2(1,0),Vector2(-1,0),Vector2(0,1),Vector2(0,-1),Vector2(1,1),Vector2(1,-1),Vector2(-1,1),Vector2(-1,-1)]
	for dir in king_dirs:
		var target_pos = grid_position + dir
		if game_board.is_valid_square(target_pos) and (board_state[target_pos.x][target_pos.y] == null or board_state[target_pos.x][target_pos.y].color != color):
			actions.append({"action": "move", "target": target_pos})
	
	return actions
