# piece.gd
# Base class for all chess piece display nodes. Pieces are thin views: all
# movement and rules queries are delegated to the rules engine through the
# GameBoard, keyed by state_id.

extends Node2D

class_name ChessPiece

# --- Art sizing ---
# Pieces are scaled by their VISIBLE content height (transparent padding
# ignored) to a consistent on-screen height, so wildly different source
# aspect ratios all read as the same-sized figurine on the board. 1.1 matches
# the look of the classic pieces (Pawn/Knight/King) at the old width-based
# scale. Per-piece multipliers fine-tune outliers.
const ART_HEIGHT_FACTOR := 1.10
const ART_SCALE_OVERRIDE := {
	# "Cultist": 0.95,
}

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

	# Measure the visible content (non-transparent pixels) so padding in the
	# source art doesn't shrink the figure or throw off vertical placement.
	var tex_size = texture.get_size()
	var content_h = tex_size.y
	var content_center_y = tex_size.y / 2.0
	var image = texture.get_image()
	if image != null:
		var used = image.get_used_rect()
		if used.size.y > 0:
			content_h = used.size.y
			content_center_y = used.position.y + used.size.y / 2.0

	var factor = ART_HEIGHT_FACTOR * float(ART_SCALE_OVERRIDE.get(piece_type, 1.0))
	var texture_scale = (tile_size * factor) / content_h
	$Sprite2D.scale = Vector2(texture_scale, texture_scale)
	# Shift the sprite so the CONTENT (not the padded texture) is centered on
	# the tile. Sprite2D.offset is in texture pixels, applied before scale.
	$Sprite2D.offset = Vector2(0, (tex_size.y / 2.0) - content_center_y)
