# --- Cultist.gd ---
extends ChessPiece

func _init():
	piece_type = "Cultist"
	is_royal = false
	traits = ["Peasant"]  # Cultist is also a peasant-like piece

func get_valid_actions(board_state):
	var actions = []
	
	# --- Pawn-like Movement ---
	# Direction depends on color (white moves up, black moves down)
	var forward_dir = Vector2(0, -1) if color == "white" else Vector2(0, 1)
	
	# Single step forward
	var forward_pos = grid_position + forward_dir
	if is_valid_square(forward_pos) and board_state[forward_pos.x][forward_pos.y] == null:
		actions.append({"action": "move", "target": forward_pos})
	
	# Double step forward from starting position
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
	
	# --- Special Action: Convert Enemy Peasants ---
	var adjacent_dirs = [Vector2(1,0), Vector2(-1,0), Vector2(0,1), Vector2(0,-1)]
	for dir in adjacent_dirs:
		var adj_pos = grid_position + dir
		if is_valid_square(adj_pos):
			var piece = board_state[adj_pos.x][adj_pos.y]
			if piece and piece.color != color and "Peasant" in piece.traits:
				actions.append({"action": "convert", "target_piece": piece})
	
	return actions
