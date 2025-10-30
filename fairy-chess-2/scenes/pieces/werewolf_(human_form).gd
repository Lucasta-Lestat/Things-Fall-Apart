# --- WerewolfHuman.gd ---
extends ChessPiece

func _init():
	piece_type = "Werewolf (human form)"
	is_royal = false
	traits = ["Peasant"]  # Optional: if you want it to be convertible/promotable

func get_valid_actions(board_state):
	var actions = []
	var game_board = get_node("/root/FairyChess/GameBoard")
	
	# --- Pawn-like Movement ---
	var forward_dir = Vector2(0, -1) if color == "white" else Vector2(0, 1)
	
	# Single step forward
	var forward_pos = grid_position + forward_dir
	if is_valid_square(forward_pos) and board_state[forward_pos.x][forward_pos.y] == null:
		actions.append({"action": "move", "target": forward_pos})
	
	# Double step forward from starting position (optional, depends on your design)
	var starting_row = 6 if color == "white" else 1
	if grid_position.y == starting_row:
		var double_forward_pos = grid_position + forward_dir * 2
		if is_valid_square(double_forward_pos) and board_state[double_forward_pos.x][double_forward_pos.y] == null and board_state[forward_pos.x][forward_pos.y] == null:
			actions.append({"action": "move", "target": double_forward_pos})
	
	# --- Pawn-like Captures (diagonal) ---
	var capture_dirs = [forward_dir + Vector2(1, 0), forward_dir + Vector2(-1, 0)]
	for capture_dir in capture_dirs:
		var capture_pos = grid_position + capture_dir
		if is_valid_square(capture_pos):
			var target_piece = board_state[capture_pos.x][capture_pos.y]
			if target_piece != null and target_piece.color != color:
				actions.append({"action": "move", "target": capture_pos})
	
	# Automatic transformation back to wolf form at end of turn
	actions.append({"action": "promote", "target_pawn": self, "promote_to": "Werewolf (wolf form)"})
	
	# Set the transformation as automatic action
	var transform_action = actions[actions.size() - 1]
	game_board.automatic_actions[self] = transform_action
	
	return actions
