# --- elephant.gd ---
extends ChessPiece

func _init():
	piece_type = "Elephant"

func get_valid_actions(board_state):
	var actions = []
	var game_board = get_node("/root/FairyChess/GameBoard")

	# --- Standard Knight Moves ---
	var knight_dirs = [
		Vector2(1, 2), Vector2(1, -2), Vector2(-1, 2), Vector2(-1, -2),
		Vector2(2, 1), Vector2(2, -1), Vector2(-2, 1), Vector2(-2, -1)
	]
	for dir in knight_dirs:
		var target_pos = grid_position + dir
		if game_board.is_valid_square(target_pos):
			var occupant = board_state[target_pos.x][target_pos.y]
			if occupant == null or occupant.color != color:
				actions.append({"action": "move", "target": target_pos})
	
	# --- Special "Charge" Move ---
	var forward_dir = -1 if color == "white" else 1
	var charge_target = grid_position + Vector2(0, forward_dir * 2)
	if game_board.is_valid_square(charge_target):
		# The charge can happen even if the destination is occupied.
		actions.append({"action": "charge", "target": charge_target})

	return actions
