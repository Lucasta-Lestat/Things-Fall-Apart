# highlight_layer.gd
# This script is responsible for drawing all gameplay highlights and icons
# on top of the board and pieces.

extends Control

const TILE_SIZE = 80
const BOARD_SIZE = 6
# --- Textures for UI Highlights ---
@onready var promotion_icon = preload("res://ui/promotion icon.png")
@onready var attack_icon = preload("res://ui/attack icon.png")

# --- State Variables ---
# These will be set by the parent ChessboardDisplay script.
var selected_piece = null
var valid_actions_to_show = []

# --- Drawing ---
func _draw():
	# Draw the board first
	for x in range(BOARD_SIZE):
		for y in range(BOARD_SIZE):
			var color = Color.WHEAT if (x + y) % 2 == 0 else Color.SADDLE_BROWN
			draw_rect(Rect2(x * TILE_SIZE, y * TILE_SIZE, TILE_SIZE, TILE_SIZE), color)
			
	# Draw highlights for the selected piece's moves
	if selected_piece:
		# Highlight the selected piece's square
		var selected_pos = selected_piece.grid_position
		draw_rect(Rect2(selected_pos.x * TILE_SIZE, selected_pos.y * TILE_SIZE, TILE_SIZE, TILE_SIZE), Color(0, 1, 0, 0.3))
		var center
		# Highlight the valid action squares
		for action in valid_actions_to_show:
			print("action: ", action)
			var target_pos = Vector2.ZERO
			var highlight_color = Color(0, 0.5, 1, 0.5) # Blue for move
			var icon_to_draw = null

			if action.has("target"):
				target_pos = action.target
				print("target_pos updated for action")
				if action.action == "shoot":
					highlight_color = Color(1, 0, 0, 0.5) # Red for attack
			elif action.has("target_pawn"):
				target_pos = action.target_pawn.grid_position
				print("DEBUG: target_pawn.grid_position: ", action.target_pawn.grid_position)
				highlight_color = Color(1, 1, 0, 0.5) # Yellow for promote
				icon_to_draw = promotion_icon
			elif not action.has("target") and not action.has("target_pawn") and not action.action == "dragon_breath": # AoE attack
				print("DEBUG: AoE action =  ", action.action)
				target_pos = selected_piece.grid_position
				highlight_color = Color(1, 0, 0, 0.3)
				print("DEBUG: Attempting to draw highlight for AOE")
				icon_to_draw = attack_icon
			# The target to click is the square adjacent to the piece
			elif action.action == "dragon_breath":
				center = selected_piece.grid_position * TILE_SIZE + Vector2(TILE_SIZE / 2, TILE_SIZE / 2) 
				print("DEBUG: AoE action dragon breath? =  ", action.action)
				print("DEBUG: action.direction: ", action.direction)
				target_pos = center + action.direction * TILE_SIZE - Vector2(TILE_SIZE/4, TILE_SIZE/4)
				highlight_color = Color(1, 0, 0, 0.5) # Red for attack
				icon_to_draw = attack_icon
				draw_texture(icon_to_draw, target_pos)
				
			if not action.has("target") and not action.has("target_pawn"):
					target_pos = selected_piece.grid_position
					highlight_color = Color(1, 0.5, 0, 0.5) # red
					icon_to_draw = attack_icon
					
			center = target_pos * TILE_SIZE + Vector2(TILE_SIZE / 2, TILE_SIZE / 2)
			draw_circle(center, TILE_SIZE / 4, highlight_color)
			print("drawing_circle for action: ", action)
			if icon_to_draw:
				print("DEBUG: Attempting to draw icon")
				var icon_size = icon_to_draw.get_size()
				var icon_pos = center - icon_size / 2
				if action.action == "promote":
					print("DEBUG: icon is a promotion icon")
					# Move it to the right edge of the highlight circle
					icon_pos.x += TILE_SIZE/3
					icon_pos.y -= TILE_SIZE/4 
				draw_texture(icon_to_draw, icon_pos)
