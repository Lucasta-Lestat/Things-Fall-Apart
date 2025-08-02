# piece.gd
# Base class for all chess pieces in the game.
# It defines common properties and methods that specific pieces will override.

extends Node2D

class_name ChessPiece

# --- Properties ---
var piece_type: String = "Generic"
var color: String = "white" # "white" or "black"
var is_royal: bool = false
var is_petrified: bool = false
var grid_position: Vector2 = Vector2.ZERO
var last_known_pos: Vector2 = Vector2.ZERO # For Valkyrie

# --- Methods to be Overridden ---
# Returns a list of valid moves/actions for the piece.
# An action is a dictionary, e.g., {"action": "move", "target": Vector2(x,y)}
func get_valid_actions(board_state):
	# This should be implemented by each specific piece's script.
	return []

# Called when this piece is captured.
func on_capture(game_board):
	# Implement death rattle effects here.
	# Pass the game_board to allow interaction with the game state.
	pass

# Called when this piece's move is being resolved.
func on_move(game_board):
	# Implement effects that trigger on move (e.g., Gorgon's freeze).
	# This is now handled centrally in game_board.gd for simplicity.
	pass

# --- Setup ---
# Initializes the piece with its type, color, and royal status.
func setup_piece(p_type, p_color, p_is_royal,tile_size):
	piece_type = p_type
	color = p_color
	is_royal = p_is_royal
	
	# Load the appropriate texture based on the piece type and color.
	# Assumes textures are named like "Valkyrie_white.png" and are in "res://assets/pieces/".
	var texture_path = "res://assets/icons/" + piece_type + "_" + color + ".png"
	var texture = load(texture_path)
	$Sprite2D.texture = texture
	# --- Automatic Resizing Logic ---
	# Get the original size of the texture.
	var texture_size = texture.get_size()
	
	# Set a desired padding, so the piece doesn't fill the entire tile (e.g., 90% of the tile size).
	var desired_width = tile_size * 0.55
	
	# Calculate the scale factor needed to match the desired width.
	var scale = desired_width / texture_size.x
	
	# Apply the scale uniformly to the Sprite2D node.
	$Sprite2D.scale = Vector2(scale, scale)

func _ready():
	# Add a sprite to visually represent the piece.
	add_child(Sprite2D.new())
