# debug_display.gd
# A simple script to show live mouse coordinates for debugging.

extends Label

# We need a reference to the chessboard to get its global position.
@onready var chessboard_display = get_node("/root/FairyChess/UI/CenterContainer/HBoxContainer/ChessboardDisplay")

func _process(delta):
	# Get the three key pieces of information every frame.
	var global_mouse_pos = get_viewport().get_mouse_position()
	var board_global_pos = chessboard_display.global_position
	var local_mouse_pos = global_mouse_pos - board_global_pos
	
	# Calculate the grid position based on the local coordinates.
	var grid_pos = (local_mouse_pos / chessboard_display.TILE_SIZE).floor()
	
	# Display all the information in the label.
	self.text = """
	Global Mouse: %s
	Board Corner: %s
	Local Mouse: %s
	Calculated Grid: %s
	""" % [global_mouse_pos, board_global_pos, local_mouse_pos, grid_pos]
