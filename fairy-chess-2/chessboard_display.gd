# chessboard_display.gd
# Handles drawing the board, pieces, and player input on the board.

extends Control 

const TILE_SIZE = 80 # Size of each square in pixels
const BOARD_SIZE = 6
const MAX_PEASANTS = 4
const MAX_NON_PEASANTS = 4

@onready var game_board = get_node("../../../../../GameBoard")
@onready var ui = get_node("../../../../../UI")
@onready var audio_manager = get_node("../../../../../AudioManager")
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
	print("DEBUG: data for place_piece_on_board: ", data)
	add_child(piece_scene)
	audio_manager.play_sfx("spawn")
	
	# Pass the TILE_SIZE to the setup function
	piece_scene.setup_piece(data.piece_type, data.color, data.get("is_royal", false), TILE_SIZE)
	
	piece_scene.grid_position = grid_pos
	piece_scene.position = grid_pos * TILE_SIZE + Vector2(TILE_SIZE / 2, TILE_SIZE / 2)
	print("color: ", data.color)
	if data.color == "white":
		print("game_board.white_profile: ", game_board.white_profile)
		if data.get("is_royal"): 
			game_board.white_profile["royals"][data.piece_type] -= 1
			game_board.white_placed_pieces["royal"] += 1
			game_board.white_placed_pieces["non_peasant"] += 1
			print("game_board.white_profile[royals][data.piece_type]: ", game_board.white_profile["royals"][data.piece_type])
		elif data.get("is_peasant"):
			print("game_board.white_profile[peasants][data.piece_type]: ", game_board.white_profile["peasants"][data.piece_type])

			game_board.white_profile["peasants"][data.piece_type] -= 1
			game_board.white_placed_pieces["peasant"] += 1
		else:
			game_board.white_profile["nobles"][data.piece_type] -= 1
			game_board.white_placed_pieces["non_peasant"] += 1
			
	else:
		if data.get("is_royal"): 
			game_board.black_profile["royals"][data.piece_type] -= 1
			game_board.black_placed_pieces["royal"] += 1
			game_board.black_placed_pieces["non_peasant"] += 1
			print("game_board.black_profile[royals][data.piece_type]: ", game_board.black_profile["royals"][data.piece_type])
		elif data.get("is_peasant"):
			print("game_board.black_profile[peasants][data.piece_type]: ", game_board.black_profile["peasants"][data.piece_type])
			game_board.black_profile["peasants"][data.piece_type] -= 1
			game_board.black_placed_pieces["peasant"] += 1
		else:
			game_board.black_profile["nobles"][data.piece_type] -= 1
			game_board.black_placed_pieces["non_peasant"] += 1
			print("game_board.black_profile[non_peasant][data.piece_type]: ", game_board.black_profile["nobles"][data.piece_type])
	if data.color == "white":
		var panel = ui.white_piece_panel
		var profile = game_board.white_profile
		ui.populate_piece_panels(panel, data.color, profile)
		
	if data.color == "black":
		var panel = ui.black_piece_panel
		var profile = game_board.black_profile
		ui.populate_piece_panels(panel, data.color, profile)
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
	#print("DEBUG: _can_drop_data called")
	#print("at_position: ", at_position )
	var global_mouse_pos = get_viewport().get_mouse_position()
	#print("global_mouse_pos in chessboard_display: ", global_mouse_pos)
	#print("self.global_position in chessboard display", self.global_position)
	var local_mouse_pos = global_mouse_pos - self.global_position
	#print("local_mouse_pos in chessboard display: ",local_mouse_pos)
	var grid_pos = (local_mouse_pos / TILE_SIZE).floor()
	#print("grid_pos in chessboard display: ", grid_pos)
	if not game_board.is_valid_square(grid_pos) or game_board.board[grid_pos.x][grid_pos.y] != null:
		#print("NOT A VALID SQUARE OR NULL AT THAT POS")
		return false
	if game_board.game_phase == "setup":
		#print("DEBUG: data: ",data)
		if not data is Dictionary : return false
		if not game_board.is_valid_square(grid_pos) or game_board.board[grid_pos.x][grid_pos.y] != null:
			print("NOT A VALID SQUARE OR NULL AT THAT POS")
			return false
		var placer = game_board.setup_placer
		var profile = game_board.white_profile if placer == "white" else game_board.black_profile
		
		var placed_pieces = game_board.white_placed_pieces if placer == "white" else game_board.black_placed_pieces
		var piece_type = data.piece_type
		print("piece_type: ", piece_type)
		var piece_data = PlayerDatabase.get_piece_data(piece_type)
		print("piece_data: ", piece_data)

		var placer_counts = game_board.white_placed_pieces if placer == "white" else game_board.black_placed_pieces
		var is_peasant = data.is_peasant
		#print("DEBUG: is_peasant: ", is_peasant, "data.category: ", data)
		var is_royal = data.is_royal
		# Define the valid rows for piece types.
		var back_row = 5 if placer == "white" else 0
		var second_row = 4 if placer == "white" else 1
		
		
		# Rule 1: The piece color MUST match the current player.
		if data.color != placer:
			return false
		# Rule 2: Check if the piece is being placed on its correct row.
		if data.is_peasant:
			if grid_pos.y != second_row:
				return false
		else:
			# All other pieces (nobles and royals) go on the back row.
			if grid_pos.y != back_row:
				print("Non-peasants must be plasced on back row")
				return false

		# Rule 3: Check piece counts to prevent placing too many.
		if is_peasant and placer_counts.peasant >= game_board.MAX_PEASANTS: return false
		if not is_peasant and placer_counts.non_peasant >= game_board.MAX_NON_PEASANTS: return false
		
		# Rule 4: "Must Place a Royal" rule for the final piece.
		var total_placed = placer_counts.peasant + placer_counts.non_peasant
		var total_allowed = game_board.MAX_PEASANTS + game_board.MAX_NON_PEASANTS
		# Check if this is the last piece to be placed
		if total_placed == total_allowed - 1:
			# If no royal has been placed yet, this piece MUST be a royal.
			if placer_counts.royal == 0 and not is_royal:
				return false
		
		return true
	elif game_board.game_phase == "playing":
		# Check if the player has credits for this piece type
		var credits = game_board.white_spawn_credits if data.color == "white" else game_board.black_spawn_credits
		if credits.get(data.piece_type, 0) <= 0: return false
		
		# Use same placement rules as setup
		var is_peasant = data.category == "peasant"
		var back_row = 5 if data.color == "white" else 0
		var second_row = 4 if data.color == "white" else 1
		if is_peasant and grid_pos.y == second_row: return true
		if not is_peasant and grid_pos.y == back_row: return true
	return false
func _drop_data(at_position, data):
	#print("DEBUG: _drop_data called")
	var reliable_mouse_pos = get_viewport().get_mouse_position()
	#print("mous pos from viewport: ", reliable_mouse_pos)
	var local_pos = reliable_mouse_pos - self.global_position
	var grid_pos = (local_pos / TILE_SIZE).floor()
	#print("local_pos: ",local_pos)
	#print("self.global_position: ", self.global_position)
	#print("grid_pos: ", grid_pos)
	if game_board.game_phase == "setup":
		place_piece_on_board(data, grid_pos)
		
	elif game_board.game_phase == "playing":
		# Declare a "spawn" action. This counts as the player's move.
		game_board.declare_action(null, {"action": "spawn", "data": data, "target": grid_pos})
