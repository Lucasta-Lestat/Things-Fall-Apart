# pontifex.gd
# Script for the Pontifex piece.
# Inherits from ChessPiece and implements its specific logic.

extends ChessPiece

func _init():
	piece_type = "Pontifex"
	is_royal = true

# The Pontifex moves like a Bishop and a King, and can promote adjacent pawns.
func get_valid_actions(board_state):
	var actions = []
	
	# --- Standard Moves (Bishop + King) ---
	var move_directions = [
		Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1), # Bishop
		Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)  # King
	]
	# Bishop-like moves
	for i in range(4):
		var current_pos = grid_position + move_directions[i]
		while is_valid_square(current_pos):
			if board_state[current_pos.x][current_pos.y] == null:
				actions.append({"action": "move", "target": current_pos})
			else:
				if board_state[current_pos.x][current_pos.y].color != color:
					actions.append({"action": "move", "target": current_pos})
				break
			current_pos += move_directions[i]
	# King-like moves
	for dir in move_directions:
		var target_pos = grid_position + dir
		if is_valid_square(target_pos):
			if board_state[target_pos.x][target_pos.y] == null or board_state[target_pos.x][target_pos.y].color != color:
				actions.append({"action": "move", "target": target_pos})

	# --- Special Action: Promote Pawn ---
	var adjacent_dirs = [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]
	for dir in adjacent_dirs:
		var adj_pos = grid_position + dir
		if is_valid_square(adj_pos):
			var piece = board_state[adj_pos.x][adj_pos.y]
			if piece and piece.color == color and piece.piece_type in ["Pawn", "Kulak"]:
				actions.append({"action": "promote", "target_pawn": piece, "promote_to": "Bishop"})
	
	return actions

func is_valid_square(pos):
	return pos.x >= 0 and pos.x < 6 and pos.y >= 0 and pos.y < 6
