# --- gorgon.gd ---
extends ChessPiece

func _init():
	piece_type = "Gorgon"
	is_royal = false

func get_valid_actions(board_state):
	# Moves as King, but freezes adjacent pieces instead of capturing
	var actions = []
	var directions = [Vector2(1,0), Vector2(-1,0), Vector2(0,1), Vector2(0,-1), Vector2(1,1), Vector2(1,-1), Vector2(-1,1), Vector2(-1,-1)]
	for dir in directions:
		var target_pos = grid_position + dir
		if is_valid_square(target_pos):
			# Gorgon can move into occupied squares, petrifying the occupant
			actions.append({"action": "move", "target": target_pos})
	return actions

func is_valid_square(pos):
	return pos.x >= 0 and pos.x < 6 and pos.y >= 0 and pos.y < 6
