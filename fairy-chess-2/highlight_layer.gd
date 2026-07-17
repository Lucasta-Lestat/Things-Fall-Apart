# highlight_layer.gd
# Draws the board tiles plus all gameplay highlights for the selected piece.

extends Control

const TILE_SIZE = 100
const BOARD_SIZE = 6

@onready var promotion_icon = preload("res://ui/promotion icon.png")
@onready var attack_icon = preload("res://ui/attack icon.png")

# Set by the parent ChessboardDisplay script.
var selected_piece = null
var valid_actions_to_show = []


func _draw():
	for x in range(BOARD_SIZE):
		for y in range(BOARD_SIZE):
			var color = Color.WHEAT if (x + y) % 2 == 0 else Color.SADDLE_BROWN
			draw_rect(Rect2(x * TILE_SIZE, y * TILE_SIZE, TILE_SIZE, TILE_SIZE), color)

	if selected_piece == null:
		return

	var selected_pos = selected_piece.grid_position
	draw_rect(Rect2(selected_pos.x * TILE_SIZE, selected_pos.y * TILE_SIZE, TILE_SIZE, TILE_SIZE), Color(0, 1, 0, 0.3))

	for action in valid_actions_to_show:
		var target_pos = selected_pos
		var highlight_color = Color(0, 0.5, 1, 0.5) # blue: move
		var icon_to_draw = null

		match action.action:
			"move":
				target_pos = action.target
				if action.get("is_capture_hint", false):
					highlight_color = Color(1, 0.2, 0.1, 0.5)
			"shoot":
				target_pos = action.target
				highlight_color = Color(1, 0, 0, 0.5)
				icon_to_draw = attack_icon
			"promote":
				target_pos = action.target
				highlight_color = Color(1, 1, 0, 0.5)
				icon_to_draw = promotion_icon
			"convert":
				target_pos = action.target
				highlight_color = Color(0.7, 0.2, 0.9, 0.5)
			"dragon_breath":
				target_pos = selected_pos + action.direction
				highlight_color = Color(1, 0, 0, 0.5)
				icon_to_draw = attack_icon
			_:
				# Targetless actions (fire_cannon): shown on the piece itself.
				highlight_color = Color(1, 0.5, 0, 0.5)
				icon_to_draw = attack_icon

		var center = target_pos * TILE_SIZE + Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)
		draw_circle(center, TILE_SIZE / 4.0, highlight_color)
		if icon_to_draw != null:
			draw_texture(icon_to_draw, center - icon_to_draw.get_size() / 2.0)
