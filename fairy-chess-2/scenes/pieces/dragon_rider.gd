# --- dragon_rider.gd ---
# This script remains unchanged.
extends ChessPiece

func _init():
	piece_type = "Dragon Rider"

func get_valid_actions(board_state):
	var actions = []
	var move_dirs = [
		Vector2(4, 1), Vector2(4, -1), Vector2(-4, 1), Vector2(-4, -1),
		Vector2(1, 4), Vector2(1, -4), Vector2(-1, 4), Vector2(-1, -4)
	]
	for dir in move_dirs:
		var target_pos = grid_position + dir
		if is_valid_square(target_pos):
			var occupant = board_state[target_pos.x][target_pos.y]
			if occupant == null or occupant.color != color:
				actions.append({"action": "move", "target": target_pos})
	actions.append({"action": "dragon_breath"})
	return actions

func is_valid_square(pos):
	return pos.x >= 0 and pos.x < 6 and pos.y >= 0 and pos.y < 6
