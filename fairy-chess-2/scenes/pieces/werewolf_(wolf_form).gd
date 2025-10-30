# --- Werewolf.gd ---
extends ChessPiece

func _init():
	piece_type = "Werewolf (wolf form)"
	is_royal = false

func get_valid_actions(board_state):
	var actions = []
	var game_board = get_node("/root/FairyChess/GameBoard")
	
	# Werewolf moves like a King but can move twice
	var move_dirs = [Vector2(1,0), Vector2(-1,0), Vector2(0,1), Vector2(0,-1), 
					 Vector2(1,1), Vector2(1,-1), Vector2(-1,1), Vector2(-1,-1)]
	
	# First move options (all squares 1 step away)
	for dir in move_dirs:
		var target_pos = grid_position + dir
		if is_valid_square(target_pos):
			var occupant = board_state[target_pos.x][target_pos.y]
			if occupant == null or occupant.color != color:
				actions.append({"action": "move", "target": target_pos})
	
	# Second move options (all squares 2 steps away)
	# This includes both straight 2-step moves and "knight-like" combinations
	for dir1 in move_dirs:
		var intermediate_pos = grid_position + dir1
		# Can move through any square for the first step
		if is_valid_square(intermediate_pos):
			for dir2 in move_dirs:
				var target_pos = intermediate_pos + dir2
				if is_valid_square(target_pos) and target_pos != grid_position:
					var occupant = board_state[target_pos.x][target_pos.y]
					# Can only capture/land on the final square
					if occupant == null or occupant.color != color:
						# Avoid duplicate actions
						var duplicate = false
						for existing_action in actions:
							if existing_action.target == target_pos:
								duplicate = true
								break
						if not duplicate:
							actions.append({"action": "move", "target": target_pos})
	
	# Automatic transformation to human form at end of turn
	actions.append({"action": "promote", "target_pawn": self, "promote_to": "Werewolf (human form)"})
	
	# Set the transformation as automatic action
	var transform_action = actions[actions.size() - 1]
	game_board.automatic_actions[self] = transform_action
	
	return actions
