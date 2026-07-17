# piece.gd
# Base class for all chess piece display nodes. Pieces are thin views: all
# movement and rules queries are delegated to the rules engine through the
# GameBoard, keyed by state_id.

extends Node2D

class_name ChessPiece

# --- Properties ---
var piece_type: String = "Generic"
var color: String = "white" # "white" or "black"
var is_royal: bool = false
var is_petrified: bool = false
var grid_position: Vector2 = Vector2.ZERO
var state_id: int = -1 # id of this piece in the GameBoard's Rules state


func _ready():
	add_child(Sprite2D.new())


# Actions this piece may declare, straight from the rules engine.
# (board_state parameter kept for call-site compatibility; it is unused.)
func get_valid_actions(_board_state = null) -> Array:
	var game_board = get_node_or_null("/root/FairyChess/GameBoard")
	if game_board == null:
		return []
	return game_board.get_actions_for_node(self)


# --- Setup ---
func setup_piece(p_type, p_color, p_is_royal, tile_size):
	piece_type = p_type
	color = p_color
	is_royal = p_is_royal
	if Rules.PIECE_INFO.has(p_type):
		is_royal = Rules.PIECE_INFO[p_type].category == "royal"

	var texture_path = "res://assets/icons/" + piece_type + "_" + color + ".png"
	var texture = load(texture_path)
	if texture == null:
		push_warning("Missing piece texture: " + texture_path)
		return
	$Sprite2D.texture = texture
	var desired_width = tile_size * 0.55
	var texture_scale = desired_width / texture.get_size().x
	$Sprite2D.scale = Vector2(texture_scale, texture_scale)
