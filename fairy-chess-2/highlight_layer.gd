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
var preview = false # read-only look at an enemy's moves: render muted
var multi_option_squares = {} # squares offering more than one action -> true


# Board and marker colours all live in the theme's "Chessboard" type, so they
# can be retuned from tools/build_theme.gd without touching draw code.
func _tint(name: String) -> Color:
	return get_theme_color(name, "Chessboard")


func _draw():
	var light = _tint("tile_light")
	var dark = _tint("tile_dark")
	for x in range(BOARD_SIZE):
		for y in range(BOARD_SIZE):
			var color = light if (x + y) % 2 == 0 else dark
			draw_rect(Rect2(x * TILE_SIZE, y * TILE_SIZE, TILE_SIZE, TILE_SIZE), color)

	if selected_piece == null:
		return

	var selected_pos = selected_piece.grid_position
	# Green for a piece you control, amber for a read-only enemy preview.
	var select_tint = _tint("select_preview") if preview else _tint("select_own")
	draw_rect(Rect2(selected_pos.x * TILE_SIZE, selected_pos.y * TILE_SIZE, TILE_SIZE, TILE_SIZE), select_tint)

	for action in valid_actions_to_show:
		var target_pos = selected_pos
		var highlight_color = _tint("move")
		var icon_to_draw = null
		var conditional = false

		match action.action:
			"move":
				target_pos = action.target
				if action.get("is_conditional", false):
					# Backfill: only resolves if the blocker leaves. Drawn as a
					# hollow ring so it reads as "not guaranteed".
					conditional = true
					highlight_color = _tint("move_conditional")
				elif action.get("is_capture_hint", false):
					highlight_color = _tint("capture_hint")
			"shoot":
				target_pos = action.target
				# Amber warns that this shot would strike your own piece.
				highlight_color = _tint("friendly_fire") if action.get("friendly_fire", false) else _tint("shoot")
				icon_to_draw = attack_icon
			"promote":
				target_pos = action.target
				highlight_color = _tint("promote")
				icon_to_draw = promotion_icon
			"convert":
				target_pos = action.target
				highlight_color = _tint("convert")
			"dragon_breath":
				target_pos = selected_pos + action.direction
				highlight_color = _tint("shoot")
				icon_to_draw = attack_icon
			_:
				# Targetless actions (fire_cannon): shown on the piece itself.
				highlight_color = _tint("cannon")
				icon_to_draw = attack_icon

		# Muted, smaller markers when merely previewing an enemy's reach.
		if preview:
			highlight_color = Color(highlight_color.r, highlight_color.g, highlight_color.b, 0.28)
		var center = target_pos * TILE_SIZE + Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)
		var radius = TILE_SIZE / 6.0 if preview else TILE_SIZE / 4.0
		if conditional:
			draw_arc(center, radius * 1.15, 0.0, TAU, 28, highlight_color, 3.0)
		else:
			draw_circle(center, radius, highlight_color)
		if icon_to_draw != null and not preview:
			draw_texture(icon_to_draw, center - icon_to_draw.get_size() / 2.0)
		# A thin outer ring flags a square that offers more than one action;
		# clicking it opens the chooser instead of declaring immediately.
		if not preview and multi_option_squares.has(target_pos):
			# Two passes, dark under light: a single pale ring measured only
			# ~2.3:1 against a light square and effectively vanished there.
			draw_arc(center, radius + 7.0, 0.0, TAU, 28, _tint("ring_shadow"), 4.0)
			draw_arc(center, radius + 7.0, 0.0, TAU, 28, _tint("ring"), 2.0)
