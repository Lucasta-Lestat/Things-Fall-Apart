# PieceSelector.gd
class_name PieceSelector
extends Control

signal pieces_selected(pieces: Array[FairyChessGame.PieceType])

@export var player: int
@export var max_pieces: int

@onready var piece_grid: GridContainer = $ScrollContainer/PieceGrid
@onready var selected_list: VBoxContainer = $SelectedPieces

var available_pieces: Array[FairyChessGame.PieceType] = []
var selected_pieces: Array[FairyChessGame.PieceType] = []
var government_restrictions: FairyChessGame.Government = FairyChessGame.Government.MONARCHY

func setup(player_id: int, max_piece_count: int):
	player = player_id
	max_pieces = max_piece_count
	
	# Initialize all available pieces
	for piece_type in FairyChessGame.PieceType.values():
		available_pieces.append(piece_type)
	
	create_piece_buttons()

func create_piece_buttons():
	# Clear existing buttons
	for child in piece_grid.get_children():
		child.queue_free()
	
	# Create button for each available piece
	for piece_type in available_pieces:
		if can_use_piece(piece_type):
			var button = create_piece_button(piece_type)
			piece_grid.add_child(button)

func create_piece_button(piece_type: FairyChessGame.PieceType) -> Button:
	var button = Button.new()
	button.text = FairyChessGame.PieceType.keys()[piece_type]
	button.custom_minimum_size = Vector2(120, 60)
	button.pressed.connect(_on_piece_selected.bind(piece_type))
	return button

func _on_piece_selected(piece_type: FairyChessGame.PieceType):
	if piece_type in selected_pieces:
		# Deselect
		selected_pieces.erase(piece_type)
	else:
		# Select (if under limit)
		if selected_pieces.size() < max_pieces:
			selected_pieces.append(piece_type)
	
	update_selected_display()
	pieces_selected.emit(selected_pieces)

func update_selected_display():
	# Clear current display
	for child in selected_list.get_children():
		child.queue_free()
	
	# Add selected pieces
	for piece_type in selected_pieces:
		var label = Label.new()
		label.text = FairyChessGame.PieceType.keys()[piece_type]
		selected_list.add_child(label)

func set_government_restrictions(government: FairyChessGame.Government):
	government_restrictions = government
	create_piece_buttons()  # Recreate buttons with new restrictions

func can_use_piece(piece_type: FairyChessGame.PieceType) -> bool:
	match government_restrictions:
		FairyChessGame.Government.ANARCHY:
			return piece_type in [
				FairyChessGame.PieceType.PAWN,
				FairyChessGame.PieceType.ANARCH,
				FairyChessGame.PieceType.WEREWOLF,
				FairyChessGame.PieceType.DOPPLEGANGER
			]
		FairyChessGame.Government.REPUBLIC:
			return piece_type != FairyChessGame.PieceType.KING and piece_type != FairyChessGame.PieceType.QUEEN
		FairyChessGame.Government.THEOCRACY:
			return piece_type != FairyChessGame.PieceType.KING and piece_type != FairyChessGame.PieceType.QUEEN
		FairyChessGame.Government.TECHNOCRACY:
			return piece_type not in [
				FairyChessGame.PieceType.BISHOP,
				FairyChessGame.PieceType.ROOK,
				FairyChessGame.PieceType.PONTIFEX
			]
		_:
			return true
