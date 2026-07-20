extends VBoxContainer
# piece_icon.gd
# One entry in a side selection panel: a piece's art with its name beneath it.
# Dragging the icon onto the board places (during setup) or spawns (during
# play) that piece.

# --- Piece Properties ---
# These are filled in by setup(), called from ui.gd.
var piece_type: String = ""
var category: String = ""
var color: String = ""
var is_peasant: bool = false
var is_royal: bool = false
var scene_path: String = ""

@onready var art = $Art
@onready var name_label = $NameLabel


func setup(data: Dictionary, type: String, side: String, art_size: Vector2) -> void:
	piece_type = type
	color = side
	category = data.category
	is_peasant = data.category == "peasant"
	is_royal = data.category == "royal"
	scene_path = data.scene

	art.texture = load("res://assets/icons/%s_%s.png" % [type, side])
	art.custom_minimum_size = art_size
	name_label.text = type
	# Long names wrap to two or three lines; the tooltip keeps the full name
	# readable at a glance either way.
	tooltip_text = type


# --- Drag and Drop ---

# Called by the system when a drag begins on this control node.
func _get_drag_data(_at_position):
	# Create a preview image that will follow the mouse cursor.
	var preview = TextureRect.new()
	preview.texture = art.texture
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.size = art.custom_minimum_size

	set_drag_preview(preview)

	return {
		"piece_type": piece_type,
		"color": color,
		"is_peasant": is_peasant,
		"is_royal": is_royal,
		"scene_path": scene_path,
		"category": category,
	}
