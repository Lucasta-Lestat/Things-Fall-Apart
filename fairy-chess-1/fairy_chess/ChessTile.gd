# ChessTile.gd
# Updated ChessTile class to work without scene files
class_name ChessTile
extends Control

signal tile_clicked(pos: Vector2i)

@export var tile_position: Vector2i
@export var is_highlighted: bool = false
@export var is_selected: bool = false

var background: ColorRect
var highlight: ColorRect
var base_color: Color
var highlight_color: Color = Color.YELLOW
var select_color: Color = Color.BLUE

func _ready():
	# Connect input
	gui_input.connect(_on_gui_input)

func _on_gui_input(event: InputEvent):
	if event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			tile_clicked.emit(tile_position)

func set_highlight(enabled: bool):
	is_highlighted = enabled
	if highlight:
		highlight.visible = enabled

func set_selected(enabled: bool):
	is_selected = enabled
	if background:
		if enabled:
			base_color = background.color
			background.color = select_color
		else:
			background.color = base_color

# Also need to update the get_tile_at function to work with GridContainer
func get_tile_at(pos: Vector2i) -> ChessTile:
	# Find the GridContainer first
	var grid_container = null
	for child in get_children():
		if child is GridContainer:
			grid_container = child
			break
	
	if not grid_container:
		return null
	
	# Calculate the index in the grid (row * columns + col)
	var index = pos.y * 6 + pos.x
	if index < grid_container.get_child_count():
		var tile = grid_container.get_child(index)
		if tile is ChessTile:
			return tile
	
	return null
