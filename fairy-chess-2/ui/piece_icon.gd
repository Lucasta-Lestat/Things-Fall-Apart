extends TextureRect
# piece_icon.gd
# This script should be attached to each piece icon in the selection panels.
# It handles the drag-and-drop logic for picking pieces.

# --- Piece Properties ---
# These variables will be set when the icon is created in the UI script.
var piece_type: String = ""
var category: String = ""
var color: String = ""
var is_peasant: bool = false
var is_royal: bool = false
var scene_path: String = ""

# --- Drag and Drop ---

# This function is called by the system when a drag begins on this control node.
func _get_drag_data(at_position):
	# Create a preview image that will follow the mouse cursor.
	var preview = TextureRect.new()
	preview.texture = self.texture
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.size = self.custom_minimum_size
	
	set_drag_preview(preview)
	
	var data = {
		"piece_type": piece_type,
		"color": color,
		"is_peasant": is_peasant,
		"is_royal": is_royal,
		"scene_path": scene_path,
		"category": category
	}
	
	return data
