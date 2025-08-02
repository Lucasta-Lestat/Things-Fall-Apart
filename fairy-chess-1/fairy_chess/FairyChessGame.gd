# FairyChessGame.gd - Main game controller
class_name FairyChessGame
extends Node2D

# Add these variables at the top of your existing class
@onready var setup_ui: GameSetupManager = $GameSetupManager  # Add this line
@onready var board_container: Node2D = $Board      # Your existing board
@onready var game_ui: CanvasLayer = $UI            # Your existing UI

signal game_ended(winner: int, reason: String)
signal piece_moved(from_pos: Vector2i, to_pos: Vector2i, piece: ChessPiece)
signal turn_changed(player: int)

const BOARD_SIZE = 6
const TILE_SIZE = 64

@export var white_gold := 100
@export var black_gold := 100
@export var white_wager := 0
@export var black_wager := 0

var board: Array[Array] = []
var current_player := 1  # 1 = white, -1 = black
var game_state := GameState.SETUP
var selected_piece: ChessPiece = null
var valid_moves: Array[Vector2i] = []
var turn_count := 0

# Government systems
var white_government := Government.MONARCHY
var black_government := Government.MONARCHY

# Piece placement during setup
var setup_phase := SetupPhase.NON_ROYAL
var pieces_to_place := {}

enum GameState {
	SETUP,
	PLAYING,
	ENDED
}

enum SetupPhase {
	NON_ROYAL,
	ROYAL
}

enum Government {
	MONARCHY,
	ANARCHY,
	REPUBLIC,
	THEOCRACY,
	TECHNOCRACY
}

func _ready():
	initialize_board()
	
	# Initialize pieces to place dictionary
	pieces_to_place[1] = []
	pieces_to_place[-1] = []
	
	# Start with setup UI visible, game hidden
	if setup_ui:
		setup_ui.visible = true
		setup_ui.setup_complete.connect(_on_setup_complete)
	
	board_container.visible = false
	game_ui.visible = false

func initialize_board():
	board.resize(BOARD_SIZE)
	for i in BOARD_SIZE:
		board[i] = []
		board[i].resize(BOARD_SIZE)
		for j in BOARD_SIZE:
			board[i][j] = null
# Add this new function to handle setup completion
func _on_setup_complete(white_pieces: Array, black_pieces: Array, 
					   white_gov: Government, black_gov: Government,
					   white_wager: int, black_wager: int):
	# Hide setup UI
	setup_ui.visible = false
	
	# Show game UI
	board_container.visible = true
	game_ui.visible = true
	
	# Configure the game with setup results
	white_government = white_gov
	black_government = black_gov
	self.white_wager = white_wager
	self.black_wager = black_wager
	
	# Now create the board UI
	setup_ui_board()
	
	# Start the game with selected pieces
	start_game_with_pieces(white_pieces, black_pieces)

func setup_ui_board():
	# Create a GridContainer for proper tile alignment
	var board_grid = GridContainer.new()
	board_grid.columns = BOARD_SIZE
	board_grid.add_theme_constant_override("h_separation", 0)
	board_grid.add_theme_constant_override("v_separation", 0)
	board_container.add_child(board_grid)
	
	# Create board tiles in grid
	for row in BOARD_SIZE:
		for col in BOARD_SIZE:
			var tile = create_tile(Vector2i(col, row))
			board_grid.add_child(tile)
			
			# Set tile size
			tile.custom_minimum_size = Vector2(TILE_SIZE, TILE_SIZE)
			tile.size = Vector2(TILE_SIZE, TILE_SIZE)


# Update create_tile to work with GridContainer (keep your existing function but update it)
func create_tile(pos: Vector2i) -> Control:
	var tile = ChessTile.new()  # Create directly
	tile.tile_position = pos
	tile.custom_minimum_size = Vector2(TILE_SIZE, TILE_SIZE)
	tile.tile_clicked.connect(_on_tile_clicked.bind(pos))
	
	# Set up the tile appearance
	setup_tile_appearance(tile, pos)
	
	return tile
	
func setup_tile_appearance(tile: ChessTile, pos: Vector2i):
	# Create background
	var background = ColorRect.new()
	var is_light = (pos.x + pos.y) % 2 == 0
	background.color = Color.WHITE if is_light else Color(0.5, 0.3, 0.1)  # Brown for dark squares
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(background)
	
	# Create highlight overlay
	var highlight = ColorRect.new()
	highlight.color = Color.YELLOW
	highlight.modulate.a = 0.5
	highlight.visible = false
	highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(highlight)
	
	# Store references
	tile.background = background
	tile.highlight = highlight
	
	# Make sure the tile can receive clicks
	tile.mouse_filter = Control.MOUSE_FILTER_PASS
	
func highlight_moves(moves: Array[Vector2i]):
	# Visual feedback for valid moves
	for move_pos in moves:
		var tile = get_tile_at(move_pos)
		if tile:
			tile.set_highlight(true)

func clear_highlights():
	# Clear move highlights from all tiles
	for row in BOARD_SIZE:
		for col in BOARD_SIZE:
			var tile = get_tile_at(Vector2i(col, row))
			if tile:
				tile.set_highlight(false)
				tile.set_selected(false)

# Update get_tile_at to work with the new structure
func get_tile_at(pos: Vector2i) -> ChessTile:
	# Find the GridContainer in the board container
	var grid_container = null
	for child in board_container.get_children():
		if child is GridContainer:
			grid_container = child
			break
	
	if not grid_container:
		return null
	
	# Calculate the index in the grid (row * columns + col)
	var index = pos.y * BOARD_SIZE + pos.x
	if index < grid_container.get_child_count():
		var tile = grid_container.get_child(index)
		if tile is ChessTile:
			return tile
	
	return null

# Also update the select_piece function to use visual feedback:
func select_piece(piece: ChessPiece, pos: Vector2i):
	selected_piece = piece
	valid_moves = piece.get_valid_moves(pos, board)
	
	# Highlight the selected piece
	var tile = get_tile_at(pos)
	if tile:
		tile.set_selected(true)
	
	# Highlight valid moves
	highlight_moves(valid_moves)
func _on_tile_clicked(pos: Vector2i):
	match game_state:
		GameState.SETUP:
			handle_setup_click(pos)
		GameState.PLAYING:
			handle_game_click(pos)

func handle_setup_click(pos: Vector2i):
	# Setup phase logic - place pieces on back row
	if current_player == 1 and pos.y != BOARD_SIZE - 1:
		return
	if current_player == -1 and pos.y != 0:
		return
	
	place_setup_piece(pos)

func handle_game_click(pos: Vector2i):
	var piece = get_piece_at(pos)
	
	if selected_piece == null:
		if piece and piece.player == current_player:
			select_piece(piece, pos)
	else:
		if pos in valid_moves:
			move_piece(selected_piece, pos)
		else:
			deselect_piece()


func deselect_piece():
	selected_piece = null
	valid_moves.clear()
	clear_highlights()

func move_piece(piece: ChessPiece, to_pos: Vector2i):
	var from_pos = get_piece_position(piece)
	
	# Handle capture
	var captured_piece = get_piece_at(to_pos)
	if captured_piece:
		handle_capture(captured_piece, piece)
	
	# Move piece
	set_piece_at(from_pos, null)
	set_piece_at(to_pos, piece)
	
	# Handle special piece abilities
	piece.on_move(from_pos, to_pos, board)
	
	piece_moved.emit(from_pos, to_pos, piece)
	deselect_piece()
	
	# Check win conditions
	if check_win_condition():
		return
	
	switch_turn()

func handle_capture(captured: ChessPiece, capturer: ChessPiece):
	match captured.type:
		PieceType.PEASANT_ARMY:
			# Peasant Army retreats instead of being captured
			captured.capture_count += 1
			if captured.capture_count < 3:
				var retreat_pos = find_nearest_empty_square(get_piece_position(captured))
				if retreat_pos != Vector2i(-1, -1):
					set_piece_at(retreat_pos, captured)
					return
		PieceType.WEREWOLF:
			# Captured piece becomes werewolf for capturer
			var new_werewolf = create_piece(PieceType.WEREWOLF, capturer.player)
			capturer.captured_pieces.append(new_werewolf)
	
	# Normal capture
	captured.queue_free()

func switch_turn():
	current_player *= -1
	turn_count += 1
	turn_changed.emit(current_player)

func check_win_condition() -> bool:
	var white_royals = get_royal_pieces(1)
	var black_royals = get_royal_pieces(-1)
	
	# Check if all royal pieces are captured/checkmated
	if white_royals.is_empty():
		end_game(-1, "White royals eliminated")
		return true
	elif black_royals.is_empty():
		end_game(1, "Black royals eliminated")
		return true
	
	# Anarchy special rule - all pieces captured
	if white_government == Government.ANARCHY and get_all_pieces(1).is_empty():
		end_game(-1, "All white pieces captured")
		return true
	elif black_government == Government.ANARCHY and get_all_pieces(-1).is_empty():
		end_game(1, "All black pieces captured")
		return true
	
	return false

func end_game(winner: int, reason: String):
	game_state = GameState.ENDED
	var loser_pays_double = (turn_count == 1)  # Checkmate on turn 1
	
	if winner == 1:
		var winnings = black_wager * (2 if loser_pays_double else 1)
		white_gold += winnings
		black_gold -= winnings
	else:
		var winnings = white_wager * (2 if loser_pays_double else 1)
		black_gold += winnings
		white_gold -= winnings
	
	game_ended.emit(winner, reason)

# Utility functions
func get_piece_at(pos: Vector2i) -> ChessPiece:
	if is_valid_position(pos):
		return board[pos.y][pos.x]
	return null

func set_piece_at(pos: Vector2i, piece: ChessPiece):
	if is_valid_position(pos):
		board[pos.y][pos.x] = piece

func is_valid_position(pos: Vector2i) -> bool:
	return pos.x >= 0 and pos.x < BOARD_SIZE and pos.y >= 0 and pos.y < BOARD_SIZE

func get_piece_position(piece: ChessPiece) -> Vector2i:
	for row in BOARD_SIZE:
		for col in BOARD_SIZE:
			if board[row][col] == piece:
				return Vector2i(col, row)
	return Vector2i(-1, -1)

func get_royal_pieces(player: int) -> Array[ChessPiece]:
	var royals: Array[ChessPiece] = []
	for piece in get_all_pieces(player):
		if piece.is_royal:
			royals.append(piece)
	return royals

func get_all_pieces(player: int) -> Array[ChessPiece]:
	var pieces: Array[ChessPiece] = []
	for row in BOARD_SIZE:
		for col in BOARD_SIZE:
			var piece = board[row][col]
			if piece and piece.player == player:
				pieces.append(piece)
	return pieces

func find_nearest_empty_square(from_pos: Vector2i) -> Vector2i:
	# BFS to find nearest empty square
	var queue = [from_pos]
	var visited = {}
	visited[from_pos] = true
	
	while not queue.is_empty():
		var current = queue.pop_front()
		
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				
				var new_pos = current + Vector2i(dx, dy)
				if is_valid_position(new_pos) and not visited.has(new_pos):
					visited[new_pos] = true
					if get_piece_at(new_pos) == null:
						return new_pos
					queue.append(new_pos)
	
	return Vector2i(-1, -1)

func create_piece(type: PieceType, player: int) -> ChessPiece:
	var piece_scene = preload("res://scenes/ChessPiece.tscn")
	var piece = piece_scene.instantiate()
	piece.setup(type, player)
	return piece


# Setup and game initialization methods
func start_game_with_pieces(white_pieces: Array[PieceType], black_pieces: Array[PieceType]):
	game_state = GameState.SETUP
	
	# Store selected pieces for setup
	pieces_to_place[1] = white_pieces.duplicate()
	pieces_to_place[-1] = black_pieces.duplicate()
	
	# Setup initial pawns
	setup_initial_pawns()
	
	# Start piece placement phase
	current_player = 1
	setup_phase = SetupPhase.NON_ROYAL
	
	# Show placement instructions
	show_setup_instructions()

func show_setup_instructions():
	# Display UI showing current player's turn to place pieces
	var instruction = "White player: Place your non-royal pieces on the back row"
	if current_player == -1:
		instruction = "Black player: Place your non-royal pieces on the back row"
	elif setup_phase == SetupPhase.ROYAL:
		if current_player == 1:
			instruction = "White player: Place your royal piece"
		else:
			instruction = "Black player: Place your royal piece"
	
	print(instruction)  # Replace with actual UI update

func place_setup_piece(pos: Vector2i):
	if game_state != GameState.SETUP:
		return
	
	# Validate placement position
	var valid_row = BOARD_SIZE - 1 if current_player == 1 else 0
	if pos.y != valid_row or get_piece_at(pos) != null:
		return
	
	var pieces_list = pieces_to_place[current_player]
	if pieces_list.is_empty():
		return
	
	# Get next piece to place based on setup phase
	var piece_to_place: PieceType
	
	if setup_phase == SetupPhase.NON_ROYAL:
		# Find first non-royal piece
		for piece_type in pieces_list:
			if not is_royal_piece_type(piece_type):
				piece_to_place = piece_type
				break
	else:
		# Find royal piece
		for piece_type in pieces_list:
			if is_royal_piece_type(piece_type):
				piece_to_place = piece_type
				break
	
	if piece_to_place == null:
		return
	
	# Create and place the piece
	var piece = create_piece(piece_to_place, current_player)
	set_piece_at(pos, piece)
	add_child(piece)  # Add to scene tree
	piece.position = Vector2(pos.x * TILE_SIZE, pos.y * TILE_SIZE)
	
	pieces_list.erase(piece_to_place)
	
	# Check if player finished placing pieces
	var non_royal_remaining = count_non_royal_pieces(pieces_list)
	var royal_remaining = count_royal_pieces_in_list(pieces_list)
	
	if setup_phase == SetupPhase.NON_ROYAL and non_royal_remaining == 0:
		if royal_remaining > 0:
			setup_phase = SetupPhase.ROYAL
			show_setup_instructions()
		else:
			switch_setup_player()
	elif setup_phase == SetupPhase.ROYAL and royal_remaining == 0:
		switch_setup_player()

func switch_setup_player():
	current_player *= -1
	setup_phase = SetupPhase.NON_ROYAL
	
	# Check if setup is complete
	if pieces_to_place[1].is_empty() and pieces_to_place[-1].is_empty():
		complete_setup()
	else:
		show_setup_instructions()

func complete_setup():
	game_state = GameState.PLAYING
	current_player = 1  # White starts
	turn_count = 0
	
	print("Setup complete! Game starting.")
	
	# Check for immediate checkmate (turn 1 rule)
	if is_in_checkmate(current_player):
		end_game(-current_player, "Checkmate on turn 1")

func is_royal_piece_type(piece_type: PieceType) -> bool:
	match piece_type:
		PieceType.KING, PieceType.CHANCELLOR, PieceType.PONTIFEX, PieceType.FACTORY:
			return true
		_:
			return false

func count_non_royal_pieces(pieces: Array) -> int:
	var count = 0
	for piece_type in pieces:
		if not is_royal_piece_type(piece_type):
			count += 1
	return count

func count_royal_pieces_in_list(pieces: Array) -> int:
	var count = 0
	for piece_type in pieces:
		if is_royal_piece_type(piece_type):
			count += 1
	return count

func is_in_checkmate(player: int) -> bool:
	# Basic checkmate detection
	var royal_pieces = get_royal_pieces(player)
	if royal_pieces.is_empty():
		return true
	
	# Check if any royal piece can move to safety
	for royal in royal_pieces:
		var pos = get_piece_position(royal)
		var moves = royal.get_valid_moves(pos, board)
		if not moves.is_empty():
			return false
	
	return true

# Government validation
func can_use_piece(piece_type: PieceType, government: Government) -> bool:
	match government:
		Government.ANARCHY:
			return piece_type in [PieceType.PAWN, PieceType.ANARCH, PieceType.WEREWOLF, PieceType.DOPPLEGANGER]
		Government.REPUBLIC:
			return piece_type != PieceType.KING and piece_type != PieceType.QUEEN
		Government.THEOCRACY:
			return piece_type != PieceType.KING and piece_type != PieceType.QUEEN
		Government.TECHNOCRACY:
			return piece_type not in [PieceType.BISHOP, PieceType.ROOK, PieceType.PONTIFEX]
		_:
			return true

# Setup initial pawns
func setup_initial_pawns():
	# Place 4 pawns in middle squares of second row for each player
	var white_row = BOARD_SIZE - 2
	var black_row = 1
	
	for i in range(1, 5):  # Middle 4 squares
		var white_pawn = create_piece(PieceType.PAWN, 1)
		var black_pawn = create_piece(PieceType.PAWN, -1)
		
		set_piece_at(Vector2i(i, white_row), white_pawn)
		set_piece_at(Vector2i(i, black_row), black_pawn)

# Piece Types Enum
enum PieceType {
	PAWN,
	ROOK,
	KNIGHT,
	BISHOP,
	QUEEN,
	KING,
	ANARCH,
	PEASANT_ARMY,
	WEREWOLF,
	DOPPLEGANGER,
	KULAK,
	VALKYRIE,
	PONTIFEX,
	CHANCELLOR,
	RIFLEMAN,
	CANNONIER,
	PRINCESS,
	LADY_OF_THE_LAKE,
	CENTAUR,
	CULTIST,
	NIGHTRIDER,
	UNICORN,
	PEGASUS,
	GRASSHOPPER,
	LOCUST,
	DRAGON_RIDER,
	STORM_BRINGER,
	DEVIL_TOAD,
	GRAVITURGE,
	GORGON,
	TUNNELER,
	FACTORY,
	GIANT,
	CHECKER
}
