# chessboard_display.gd
# Handles drawing the board, pieces, and player input on the board.

extends Control # <-- CRITICAL CHANGE: Changed from Node2D to Control

const TILE_SIZE = 80 # Size of each square in pixels
const BOARD_SIZE = 6
const MAX_PEASANTS = 4
const MAX_NON_PEASANTS = 4

@onready var game_board = get_node("../../../GameBoard")
@onready var highlight_layer = $HighlightLayer

# --- Gameplay State ---
var selected_piece = null
var valid_actions_to_show = []
# --- Initialization ---
func _ready():
	game_board.turn_resolved.connect(_on_turn_resolved)
	game_board.piece_spawned.connect(_on_piece_spawned)
	highlight_layer.size = self.size
	highlight_layer.mouse_filter = Control.MOUSE_FILTER_PASS
# --- FIX: Using _gui_input for reliable mouse events on a Control node ---
# --- Input Handling for Gameplay ---
func _gui_input(event):
	if game_board.game_phase != "playing": return
		
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.is_pressed():
		var grid_pos = (event.position / TILE_SIZE).floor()
		
		if not game_board.is_valid_square(grid_pos):
			clear_selection()
			accept_event()
			return

		for action in valid_actions_to_show:
			# --- FIX: Handle clicks on directional AoE attacks ---
			if action.action == "dragon_breath":
				print("DEBUG: GB Display, attempting to show dragon breath UI")
				var target_square = selected_piece.grid_position + action.direction
				if target_square == grid_pos:
					print("DEBUG: GB Display, attempting to declare dragon breath action")
					game_board.declare_action(selected_piece, action)
					clear_selection()
					accept_event()
					return
			
			var target_pos = action.get("target", action.get("target_pawn", null))
			if target_pos:
				
				var target_grid_pos = target_pos if target_pos is Vector2 else target_pos.grid_position
				if target_grid_pos == grid_pos:
					game_board.declare_action(selected_piece, action)
					clear_selection()
					accept_event()
					return

		var clicked_piece = game_board.board[grid_pos.x][grid_pos.y]
		
		if clicked_piece and clicked_piece == selected_piece:
			for action in valid_actions_to_show:
				if not action.has("target") and not action.has("target_pawn") and not action.has("direction"):
					print("DEBUG: GB Display, attempting to declare non-dragon breath AoE")
					game_board.declare_action(selected_piece, action)
					clear_selection()
					accept_event()
					return

		var can_select = false
		if clicked_piece and not clicked_piece.is_petrified:
			if clicked_piece.color == "white" and game_board.white_actions.is_empty():
				can_select = true
			elif clicked_piece.color == "black" and game_board.black_actions.is_empty():
				can_select = true
		
		if can_select:
			select_piece(clicked_piece)
		else:
			clear_selection()
		
		accept_event()


# --- Selection & Highlighting ---
# --- FIX: These functions now update the HighlightLayer instead of this node ---
func select_piece(piece):
	selected_piece = piece
	valid_actions_to_show = piece.get_valid_actions(game_board.board)
	
	# Pass the state to the highlight layer and tell it to redraw
	highlight_layer.selected_piece = selected_piece
	highlight_layer.valid_actions_to_show = valid_actions_to_show
	highlight_layer.queue_redraw()

func clear_selection():
	selected_piece = null
	valid_actions_to_show = []
	
	# Clear the state in the highlight layer and tell it to redraw
	highlight_layer.selected_piece = null
	highlight_layer.valid_actions_to_show = []
	highlight_layer.queue_redraw()

# --- Drawing ---
# --- FIX: This node now only draws the board itself. All highlights are gone. ---
func _draw():
	for x in range(BOARD_SIZE):
		for y in range(BOARD_SIZE):
			var color = Color.WHEAT if (x + y) % 2 == 0 else Color.SADDLE_BROWN
			draw_rect(Rect2(x * TILE_SIZE, y * TILE_SIZE, TILE_SIZE, TILE_SIZE), color)
# --- Piece Management ---
func place_piece_on_board(data, grid_pos):
	var piece_scene = load(data.scene_path).instantiate()
	add_child(piece_scene)
	
	# Pass the TILE_SIZE to the setup function
	piece_scene.setup_piece(data.piece_type, data.color, data.get("is_royal", false), TILE_SIZE)
	
	piece_scene.grid_position = grid_pos
	piece_scene.position = grid_pos * TILE_SIZE + Vector2(TILE_SIZE / 2, TILE_SIZE / 2)
	game_board.place_piece(piece_scene, grid_pos)

# --- Signal Callbacks ---
func _on_turn_resolved(moves):
	for piece in moves.keys():
		if not piece.is_inside_tree(): continue
		var target_pos = moves[piece]
		var new_pixel_pos = target_pos * TILE_SIZE + Vector2(TILE_SIZE / 2, TILE_SIZE / 2)
		var tween = create_tween()
		tween.tween_property(piece, "position", new_pixel_pos, 0.4).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
func _on_piece_spawned(piece_node, grid_pos):
	add_child(piece_node)
	piece_node.position = grid_pos * TILE_SIZE + Vector2(TILE_SIZE / 2, TILE_SIZE / 2)
# --- Input Handling (for dropping pieces during setup) ---
func _can_drop_data(at_position, data) -> bool:
	var grid_pos = (at_position / TILE_SIZE).floor()
	if not game_board.is_valid_square(grid_pos) or game_board.board[grid_pos.x][grid_pos.y] != null:
		return false
	if game_board.game_phase == "setup":
		if not data is Dictionary or not data.has("piece_type"): return false
		if not game_board.is_valid_square(grid_pos) or game_board.board[grid_pos.x][grid_pos.y] != null:
			return false
		var placer = game_board.setup_placer
		var placer_counts = game_board.white_placed_pieces if placer == "white" else game_board.black_placed_pieces
		var is_peasant = data.piece_type in ["Pawn", "Kulak"]
		var is_royal = data.get("is_royal", false)
		# Rule: Define the valid rows for piece types.
		var back_row = 5 if placer == "white" else 0
		var second_row = 4 if placer == "white" else 1
		# Rule: Check if the piece is being placed on its correct row.
		if is_peasant:
			# Peasants go on the second row.
			if grid_pos.y != second_row:
				return false
		else:
			# All other pieces (nobles and royals) go on the back row.
			if grid_pos.y != back_row:
				return false
		# Rule: Check placement order (Royals must be placed after all other non-royal pieces).
		if is_royal:
			var non_royal_nobles_placed = placer_counts.non_peasant - placer_counts.royal
			if non_royal_nobles_placed < (game_board.MAX_NON_PEASANTS - 1) or placer_counts.peasant < game_board.MAX_PEASANTS:
				return false

		# Rule: Check piece counts to prevent placing too many of one type.
		if is_peasant and placer_counts.peasant >= game_board.MAX_PEASANTS: return false
		if not is_peasant and placer_counts.non_peasant >= game_board.MAX_NON_PEASANTS: return false
		return true
	elif game_board.game_phase == "playing":
		# Check if the player has credits for this piece type
		var credits = game_board.white_spawn_credits if data.color == "white" else game_board.black_spawn_credits
		if credits.get(data.piece_type, 0) <= 0: return false
		
		# Use same placement rules as setup
		var is_peasant = data.piece_type in ["Pawn", "Kulak"]
		var back_row = 5 if data.color == "white" else 0
		var second_row = 4 if data.color == "white" else 1
		if is_peasant and grid_pos.y == second_row: return true
		if not is_peasant and grid_pos.y == back_row: return true
	return false
func _drop_data(at_position, data):
	var grid_pos = (at_position / TILE_SIZE).floor()
	if game_board.game_phase == "setup":
		place_piece_on_board(data, grid_pos)
	elif game_board.game_phase == "playing":
		# Declare a "spawn" action. This counts as the player's move.
		game_board.declare_action(null, {"action": "spawn", "data": data, "target": grid_pos})
