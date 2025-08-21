# dragon_rider.gd
# This script now generates directional AoE attacks.

extends ChessPiece

func _init():
	piece_type = "Dragon Rider"

func get_valid_actions(board_state):
	var actions = []

	# Standard (4,1) moves
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

	# --- FIX: Create four separate "dragon_breath" actions, one for each direction ---
	actions.append({"action": "dragon_breath", "direction": Vector2.UP})
	actions.append({"action": "dragon_breath", "direction": Vector2.DOWN})
	actions.append({"action": "dragon_breath", "direction": Vector2.LEFT})
	actions.append({"action": "dragon_breath", "direction": Vector2.RIGHT})

	return actions

func is_valid_square(pos):
	return pos.x >= 0 and pos.x < 6 and pos.y >= 0 and pos.y < 6
