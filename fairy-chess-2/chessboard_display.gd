# chessboard_display.gd
# Handles drawing the board, pieces, and player input on the board.

extends Control # <-- CRITICAL CHANGE: Changed from Node2D to Control

const TILE_SIZE = 80 # Size of each square in pixels
const BOARD_SIZE = 6
const MAX_PEASANTS = 4
const MAX_NON_PEASANTS = 4

@onready var game_board = get_node("../../../GameBoard")
# --- Gameplay State ---
var selected_piece = null
var valid_actions_to_show = []
# --- Initialization ---
func _ready():
	game_board.turn_resolved.connect(_on_turn_resolved)
	game_board.piece_spawned.connect(_on_piece_spawned)

	# Set the minimum size of this control node to match the board dimensions
	#custom_minimum_size = Vector2(TILE_SIZE * BOARD_SIZE, TILE_SIZE * BOARD_SIZE)
	#draw_board()
# --- Input Handling for Gameplay ---
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
# --- FIX: Check for clicks on promotion targets ---
		for action in valid_actions_to_show:
			if action.action == "move" and action.get("target") == grid_pos:
				print("declaring move")
				game_board.declare_action(selected_piece, action)
				clear_selection()
				accept_event()
				return
			# Check if the clicked square matches the position of a target pawn
			elif action.action == "promote" and action.get("target_pawn").grid_position == grid_pos:
				print("declaring promotion")
				game_board.declare_action(selected_piece, action)
				clear_selection()
				accept_event()
				return

		# If not a valid move, check if they clicked on a piece
		var clicked_piece = game_board.board[grid_pos.x][grid_pos.y]
		
		# Handle actions with no target (like Cannonier) by clicking the piece again
		if clicked_piece and clicked_piece == selected_piece:
			for action in valid_actions_to_show:
				if not action.has("target") and not action.has("target_pawn"):
					game_board.declare_action(selected_piece, action)
					clear_selection()
					accept_event()
				
		var can_select = false
		if clicked_piece and not clicked_piece.is_petrified:
			# Can select a white piece if white hasn't submitted a move yet.
			if clicked_piece.color == "white" and game_board.white_actions.is_empty():
				can_select = true
			# Can select a black piece if black hasn't submitted a move yet.
			elif clicked_piece.color == "black" and game_board.black_actions.is_empty():
				can_select = true
		
		if can_select:
			select_piece(clicked_piece)
		else:
			clear_selection()
		
		accept_event()


# --- Selection & Highlighting ---
func select_piece(piece):
	selected_piece = piece
	valid_actions_to_show = piece.get_valid_actions(game_board.board)
	# Request a redraw to show the new highlights
	queue_redraw()

func clear_selection():
	selected_piece = null
	valid_actions_to_show = []
	queue_redraw()

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
		
		# Highlight the valid action squares
		for action in valid_actions_to_show:
			print("action: ", action)
			var target_pos = Vector2.ZERO
			var highlight_color = Color(0, 0.5, 1, 0.5) # Blue for move

			if action.has("target"):
				target_pos = action.target
				print("target_pos updated for action")
			elif action.has("target_pawn"):
				target_pos = action.target_pawn.grid_position
				highlight_color = Color(1, 1, 0, 0.5) # Yellow for promote
			var center = target_pos * TILE_SIZE + Vector2(TILE_SIZE / 2, TILE_SIZE / 2)
			draw_circle(center, TILE_SIZE / 4, highlight_color)
			print("drawing_circle for action: ", action)

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
	if game_board.game_phase != "setup": return false
	if not data is Dictionary or not data.has("piece_type"): return false
	
	var grid_pos = (at_position / TILE_SIZE).floor()
	if not game_board.is_valid_square(grid_pos) or game_board.board[grid_pos.x][grid_pos.y] != null:
		return false
	
	var placer = game_board.setup_placer
	var placer_counts = game_board.white_placed_pieces if placer == "white" else game_board.black_placed_pieces
	
	var is_peasant = data.piece_type in ["Pawn", "Kulak"]
	var is_royal = data.get("is_royal", false)

	# --- NEW CORRECTED SETUP LOGIC ---
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

func _drop_data(at_position, data):
	var grid_pos = (at_position / TILE_SIZE).floor()
	place_piece_on_board(data, grid_pos)
