# GameSetupManager.gd
class_name GameSetupManager
extends Control

signal setup_complete(white_pieces: Array, black_pieces: Array, white_gov: FairyChessGame.Government, black_gov: FairyChessGame.Government)

@export var max_pieces_per_player: int = 4

@onready var white_piece_selector: PieceSelector = $SetupContainer/PieceSelection/WhitePieceSelector
@onready var black_piece_selector: PieceSelector = $SetupContainer/PieceSelection/BlackPieceSelector
@onready var government_selector: GovernmentSelector = $SetupContainer/GovernmentSelection
@onready var wager_input: WagerInput = $SetupContainer/WagerSection

var white_selected_pieces: Array[FairyChessGame.PieceType] = []
var black_selected_pieces: Array[FairyChessGame.PieceType] = []
var white_government: FairyChessGame.Government = FairyChessGame.Government.MONARCHY
var black_government: FairyChessGame.Government = FairyChessGame.Government.MONARCHY

func _ready():
	setup_piece_selectors()
	setup_government_selector()
	setup_wager_input()

func setup_piece_selectors():
	white_piece_selector.setup(1, max_pieces_per_player)
	black_piece_selector.setup(-1, max_pieces_per_player)
	
	white_piece_selector.pieces_selected.connect(_on_white_pieces_selected)
	black_piece_selector.pieces_selected.connect(_on_black_pieces_selected)

func setup_government_selector():
	government_selector.government_selected.connect(_on_government_selected)

func setup_wager_input():
	wager_input.wager_set.connect(_on_wager_set)

func _on_white_pieces_selected(pieces: Array[FairyChessGame.PieceType]):
	white_selected_pieces = pieces
	check_setup_complete()

func _on_black_pieces_selected(pieces: Array[FairyChessGame.PieceType]):
	black_selected_pieces = pieces
	check_setup_complete()

func _on_government_selected(player: int, government: FairyChessGame.Government):
	if player == 1:
		white_government = government
	else:
		black_government = government
	
	# Update piece selectors based on government restrictions
	update_piece_restrictions()
	check_setup_complete()

func _on_wager_set(white_wager: int, black_wager: int):
	# Validate wagers and proceed
	check_setup_complete()

func update_piece_restrictions():
	white_piece_selector.set_government_restrictions(white_government)
	black_piece_selector.set_government_restrictions(black_government)

func check_setup_complete():
	if white_selected_pieces.size() == max_pieces_per_player and \
	   black_selected_pieces.size() == max_pieces_per_player and \
	   validate_piece_selections():
		setup_complete.emit(white_selected_pieces, black_selected_pieces, white_government, black_government)

func validate_piece_selections() -> bool:
	# Validate that each player has exactly one royal piece (unless anarchy)
	var white_royals = count_royal_pieces(white_selected_pieces, white_government)
	var black_royals = count_royal_pieces(black_selected_pieces, black_government)
	
	if white_government == FairyChessGame.Government.ANARCHY:
		return white_royals == 0 and validate_anarchy_pieces(white_selected_pieces)
	elif black_government == FairyChessGame.Government.ANARCHY:
		return black_royals == 0 and validate_anarchy_pieces(black_selected_pieces)
	else:
		return white_royals == 1 and black_royals == 1

func count_royal_pieces(pieces: Array[FairyChessGame.PieceType], government: FairyChessGame.Government) -> int:
	var count = 0
	for piece_type in pieces:
		if is_royal_for_government(piece_type, government):
			count += 1
	return count

func is_royal_for_government(piece_type: FairyChessGame.PieceType, government: FairyChessGame.Government) -> bool:
	match government:
		FairyChessGame.Government.MONARCHY:
			return piece_type == FairyChessGame.PieceType.KING
		FairyChessGame.Government.REPUBLIC:
			return piece_type == FairyChessGame.PieceType.CHANCELLOR
		FairyChessGame.Government.THEOCRACY:
			return piece_type == FairyChessGame.PieceType.PONTIFEX
		FairyChessGame.Government.TECHNOCRACY:
			return piece_type == FairyChessGame.PieceType.FACTORY
		FairyChessGame.Government.ANARCHY:
			return false
	return false

func validate_anarchy_pieces(pieces: Array[FairyChessGame.PieceType]) -> bool:
	var allowed_pieces = [
		FairyChessGame.PieceType.PAWN,
		FairyChessGame.PieceType.ANARCH,
		FairyChessGame.PieceType.WEREWOLF,
		FairyChessGame.PieceType.DOPPLEGANGER
	]
	
	for piece_type in pieces:
		if piece_type not in allowed_pieces:
			return false
	return true
