# --- cannonier.gd ---
# This script remains unchanged.
extends ChessPiece

func _init():
	piece_type = "Cannonier"

func get_valid_actions(board_state):
	var actions = []
	var forward_dir = -1 if color == "white" else 1

	var one_step = grid_position + Vector2(0, forward_dir)
	if is_valid_square(one_step) and board_state[one_step.x][one_step.y] == null:
		actions.append({"action": "move", "target": one_step})

	actions.append({"action": "fire_cannon"})
	return actions

func is_valid_square(pos):
	return pos.x >= 0 and pos.x < 6 and pos.y >= 0 and pos.y < 6
