# --- Grasshopper.gd ---
extends ChessPiece

func _init():
	piece_type = "Grasshopper"
	is_royal = false

func get_valid_actions(board_state):
	var actions = []
	var game_board = get_node("/root/FairyChess/GameBoard")
	
	# Grasshopper moves in all 8 directions like a Queen
	var grasshopper_dirs = [
		Vector2(1,0), Vector2(-1,0), Vector2(0,1), Vector2(0,-1),
		Vector2(1,1), Vector2(1,-1), Vector2(-1,1), Vector2(-1,-1)
	]
	
	for dir in grasshopper_dirs:
		var current_pos = grid_position + dir
		var found_hurdle = false
		
		# Search along the direction for a piece to hop over
		while game_board.is_valid_square(current_pos):
			var occupant = board_state[current_pos.x][current_pos.y]
			
			if occupant != null and not found_hurdle:
				# Found the hurdle piece - mark it and continue one more step
				found_hurdle = true
				current_pos += dir
				
				# Check if the landing square is valid
				if game_board.is_valid_square(current_pos):
					var landing_occupant = board_state[current_pos.x][current_pos.y]
					
					# Can land on empty square or capture enemy piece
					if landing_occupant == null:
						actions.append({"action": "move", "target": current_pos})
					elif landing_occupant.color != color:
						actions.append({"action": "move", "target": current_pos})
				
				# Grasshopper can only hop over one piece, so stop searching this direction
				break
			elif found_hurdle:
				# Already hopped over a piece, shouldn't reach here due to break above
				break
			else:
				# Empty square before finding hurdle - keep searching
				current_pos += dir
	
	return actions
