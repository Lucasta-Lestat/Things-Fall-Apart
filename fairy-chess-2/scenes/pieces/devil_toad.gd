# --- devil_toad.gd (New) ---
extends ChessPiece

func _init():
	piece_type = "Devil Toad"
	is_royal = false

func get_valid_actions(board_state):
	var actions = []
	var start_dirs = [Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]

	for start_dir in start_dirs:
		var path_visited = [] # Prevents infinite loops for this specific path
		var current_pos = grid_position
		var current_dir = start_dir
		
		# Limit path length as a safety measure against unforeseen infinite loops
		for i in range(12): 
			var next_pos = current_pos + current_dir

			# --- Bounce Logic ---
			if not is_valid_square(next_pos):
				var bounced = false
				# Bounce off X edge
				if (next_pos.x < 0 and current_dir.x < 0) or (next_pos.x > 5 and current_dir.x > 0):
					current_dir.x *= -1
					bounced = true
				
				# Bounce off Y edge
				if (next_pos.y < 0 and current_dir.y < 0) or (next_pos.y > 5 and current_dir.y > 0):
					current_dir.y *= -1
					bounced = true
				
				# If a bounce occurred, the next position is calculated from the same spot
				# but with the new direction.
				if bounced:
					next_pos = current_pos + current_dir
				else: # Should not happen with standard diagonal moves
					break

			# Check for infinite loops within a single path
			if next_pos in path_visited:
				break
			
			current_pos = next_pos
			path_visited.append(current_pos)
			
			var occupant = board_state[current_pos.x][current_pos.y]
			if occupant == null or occupant.color != color:
				actions.append({"action": "move", "target": current_pos})

			# Path is blocked if it hits any piece
			if occupant != null:
				break
				
	return actions

func is_valid_square(pos):
	return pos.x >= 0 and pos.x < 6 and pos.y >= 0 and pos.y < 6
