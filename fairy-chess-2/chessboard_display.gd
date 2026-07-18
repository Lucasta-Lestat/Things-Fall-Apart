# chessboard_display.gd
# Handles drawing the board, piece nodes, and player input on the board.

extends Control

const TILE_SIZE = 100
const BOARD_SIZE = 6

@onready var game_board = get_node("../../../../../GameBoard")
@onready var ui = get_node("../../../../../UI")
@onready var audio_manager = get_node("../../../../../AudioManager")
@onready var highlight_layer = $HighlightLayer

# --- Gameplay State ---
var selected_piece = null
var valid_actions_to_show = []
var previewing = false # selection is a read-only look at a piece we can't order
var _pending_promotion_piece = null # awaiting a choice from the promotion picker
var _shudder = {} # royal state id -> looping tween (in-check tremble)


func _ready():
	game_board.turn_resolved.connect(_on_turn_resolved)
	game_board.piece_spawned.connect(_on_piece_spawned)
	game_board.check_status_changed.connect(_on_check_status_changed)
	highlight_layer.size = self.size
	highlight_layer.mouse_filter = Control.MOUSE_FILTER_PASS


# --- Input Handling for Gameplay ---
func _gui_input(event):
	# Explain conditional (backfill) moves and friendly-fire shots on hover.
	if event is InputEventMouseMotion:
		_update_hover_tooltip((event.position / TILE_SIZE).floor())
		return

	if not event is InputEventMouseButton or not event.is_pressed():
		return

	# Right-click during setup undoes the latest placement.
	if event.button_index == MOUSE_BUTTON_RIGHT and game_board.game_phase == "setup":
		game_board.undo_last_placement()
		accept_event()
		return

	if game_board.game_phase != "playing":
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return

	# The selected piece may have been captured/replaced since selection.
	if selected_piece != null and not is_instance_valid(selected_piece):
		clear_selection()

	var grid_pos = (event.position / TILE_SIZE).floor()
	if not game_board.is_valid_square(grid_pos):
		clear_selection()
		accept_event()
		return

	# 1. Did the player click one of the highlighted actions? (Only a piece we
	#    actually control can declare; a previewed enemy is read-only.)
	if not previewing:
		for action in valid_actions_to_show:
			if action.action == "dragon_breath":
				var target_square = selected_piece.grid_position + action.direction
				if target_square == grid_pos:
					game_board.declare_action(selected_piece, action)
					clear_selection()
					accept_event()
					return
			elif action.action == "promote" and action.target == selected_piece.grid_position:
				# Self-promotion: open the picker instead of declaring immediately.
				if grid_pos == selected_piece.grid_position:
					_open_promotion_picker(selected_piece)
					accept_event()
					return
			elif action.has("target") and action.target == grid_pos:
				game_board.declare_action(selected_piece, action)
				clear_selection()
				accept_event()
				return

	var clicked_piece = game_board.board[grid_pos.x][grid_pos.y]

	# 2. Clicking the selected piece itself triggers its targetless action
	#    (e.g. fire_cannon).
	if not previewing and clicked_piece != null and clicked_piece == selected_piece:
		for action in valid_actions_to_show:
			if not action.has("target") and not action.has("direction"):
				game_board.declare_action(selected_piece, action)
				clear_selection()
				accept_event()
				return

	# 3. Otherwise (re)select. A piece we control is selected to ORDER; any
	#    other piece (enemy, petrified, or ours while a move is pending) is
	#    selected to PREVIEW its moves read-only.
	if clicked_piece == null:
		clear_selection()
	elif _controllable(clicked_piece):
		select_piece(clicked_piece, false)
	else:
		select_piece(clicked_piece, true)
	accept_event()


func _update_hover_tooltip(grid_pos):
	var text = ""
	if selected_piece != null and is_instance_valid(selected_piece) and not previewing:
		for action in valid_actions_to_show:
			if not action.has("target") or action.target != grid_pos:
				continue
			if action.action == "move" and action.get("is_conditional", false):
				text = "Conditional move — resolves only if your piece here moves or is killed this turn. If it is, you take the square and cut down whatever enemy claimed it."
				break
			if action.action == "shoot" and action.get("friendly_fire", false):
				text = "Friendly fire — this shot hits the first piece in the line, and right now that is your own piece. An enemy stepping into the line would intercept it instead."
				break
	if tooltip_text != text:
		tooltip_text = text


func _controllable(piece) -> bool:
	if piece.is_petrified:
		return false
	if piece.color == "white":
		return game_board.white_pending == null
	return game_board.black_pending == null and not game_board.ai_enabled


# --- Selection & Highlighting ---
# preview = true shows a piece's moves read-only (e.g. clicking an enemy to
# scout its threats); the highlights render muted and no action can be declared.
func select_piece(piece, preview := false):
	selected_piece = piece
	previewing = preview
	valid_actions_to_show = piece.get_valid_actions()
	# Annotate capture moves so the highlight layer can colour them red.
	for action in valid_actions_to_show:
		if action.action == "move" and action.has("target"):
			var occ = game_board.board[action.target.x][action.target.y]
			if occ != null and occ.color != piece.color:
				action["is_capture_hint"] = true
	highlight_layer.selected_piece = selected_piece
	highlight_layer.valid_actions_to_show = valid_actions_to_show
	highlight_layer.preview = preview
	highlight_layer.queue_redraw()


func clear_selection():
	selected_piece = null
	valid_actions_to_show = []
	previewing = false
	highlight_layer.selected_piece = null
	highlight_layer.valid_actions_to_show = []
	highlight_layer.preview = false
	highlight_layer.queue_redraw()


# --- Check indicator: threatened royals shudder ---
func _on_check_status_changed(threatened_ids):
	var want = {}
	for id in threatened_ids:
		want[id] = true
	# Stop trembling on royals no longer in check.
	for id in _shudder.keys():
		if not want.has(id):
			var tw = _shudder[id]
			if tw != null and tw.is_valid():
				tw.kill()
			var node = game_board.piece_nodes.get(id)
			if node != null and is_instance_valid(node):
				node.rotation = 0.0
			_shudder.erase(id)
	# Start trembling on newly-threatened royals.
	for id in threatened_ids:
		if _shudder.has(id):
			continue
		var node = game_board.piece_nodes.get(id)
		if node == null or not is_instance_valid(node):
			continue
		var tw = create_tween().set_loops()
		tw.tween_property(node, "rotation", 0.05, 0.07)
		tw.tween_property(node, "rotation", -0.05, 0.14)
		tw.tween_property(node, "rotation", 0.0, 0.07)
		tw.tween_interval(0.5)
		_shudder[id] = tw


# --- Promotion picker ---
func _open_promotion_picker(piece):
	_pending_promotion_piece = piece
	var picker = ui.promotion_picker
	if not picker.picked.is_connected(_on_promotion_picked):
		picker.picked.connect(_on_promotion_picked)
	picker.open(piece.color)


func _on_promotion_picked(promote_to):
	var piece = _pending_promotion_piece
	_pending_promotion_piece = null
	clear_selection()
	if piece == null or not is_instance_valid(piece):
		return
	game_board.declare_action(piece, {
		"action": "promote",
		"target": piece.grid_position,
		"promote_to": promote_to,
	})


# --- Drawing ---
func _draw():
	for x in range(BOARD_SIZE):
		for y in range(BOARD_SIZE):
			var color = Color.WHEAT if (x + y) % 2 == 0 else Color.SADDLE_BROWN
			draw_rect(Rect2(x * TILE_SIZE, y * TILE_SIZE, TILE_SIZE, TILE_SIZE), color)


# --- Piece Management (setup placement + AI placement) ---
func place_piece_on_board(data, grid_pos):
	var piece_scene = load(data.scene_path).instantiate()
	add_child(piece_scene)
	audio_manager.play_sfx("spawn")
	piece_scene.setup_piece(data.piece_type, data.color, data.get("is_royal", false), TILE_SIZE)
	piece_scene.grid_position = grid_pos
	piece_scene.position = grid_pos * TILE_SIZE + Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)

	var category = "noble"
	if data.get("is_royal", false):
		category = "royal"
	elif data.get("is_peasant", false):
		category = "peasant"

	# Spend the piece from the owner's profile.
	var profile = game_board.white_profile if data.color == "white" else game_board.black_profile
	var bucket = {"peasant": "peasants", "noble": "nobles", "royal": "royals"}[category]
	profile[bucket][data.piece_type] = int(profile[bucket].get(data.piece_type, 0)) - 1

	game_board.place_piece(piece_scene, grid_pos, category)

	var panel = ui.white_piece_panel if data.color == "white" else ui.black_piece_panel
	ui.populate_piece_panels(panel, data.color, profile)


# --- Signal Callbacks ---
func _on_turn_resolved(moves):
	clear_selection() # actions computed before the resolution are stale now
	for piece in moves.keys():
		if not piece.is_inside_tree():
			continue
		var new_pixel_pos = moves[piece] * TILE_SIZE + Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)
		var tween = create_tween()
		tween.tween_property(piece, "position", new_pixel_pos, 0.4).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)


func _on_piece_spawned(piece_node, grid_pos):
	add_child(piece_node)
	piece_node.position = grid_pos * TILE_SIZE + Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)


# --- Drag & drop (setup placement and credit spawns) ---
func _can_drop_data(_at_position, data) -> bool:
	if not data is Dictionary:
		return false
	var global_mouse_pos = get_viewport().get_mouse_position()
	var local_mouse_pos = global_mouse_pos - self.global_position
	var grid_pos = (local_mouse_pos / TILE_SIZE).floor()
	if not game_board.is_valid_square(grid_pos) or game_board.board[grid_pos.x][grid_pos.y] != null:
		return false

	var color = data.color
	var is_peasant = data.get("is_peasant", false)
	var is_royal = data.get("is_royal", false)
	var back_row = 5 if color == "white" else 0
	var second_row = 4 if color == "white" else 1

	# Row rules are shared by setup and credit spawns.
	if is_peasant and grid_pos.y != second_row:
		return false
	if not is_peasant and grid_pos.y != back_row:
		return false

	if game_board.game_phase == "setup":
		var placer = game_board.setup_placer
		if color != placer:
			return false
		if game_board.ai_enabled and placer == "black":
			return false # the AI places its own pieces
		var counts = game_board.white_placed_pieces if placer == "white" else game_board.black_placed_pieces
		if is_peasant and counts.peasant >= game_board.MAX_PEASANTS:
			return false
		if not is_peasant:
			if counts.non_peasant >= game_board.MAX_NON_PEASANTS:
				return false
			# Reserve the last non-peasant slot for a royal, otherwise the
			# setup can become impossible to complete.
			if not is_royal and counts.royal == 0 and counts.non_peasant == game_board.MAX_NON_PEASANTS - 1:
				return false
		return true

	elif game_board.game_phase == "playing":
		if color == "black" and game_board.ai_enabled:
			return false
		if color == "white" and game_board.white_pending != null:
			return false
		if color == "black" and game_board.black_pending != null:
			return false
		return game_board.spawn_credits(color).get(data.piece_type, 0) > 0

	return false


func _drop_data(_at_position, data):
	var reliable_mouse_pos = get_viewport().get_mouse_position()
	var local_pos = reliable_mouse_pos - self.global_position
	var grid_pos = (local_pos / TILE_SIZE).floor()
	if game_board.game_phase == "setup":
		place_piece_on_board(data, grid_pos)
	elif game_board.game_phase == "playing":
		clear_selection()
		game_board.declare_side_action(data.color, {
			"action": "spawn",
			"piece_type": data.piece_type,
			"target": grid_pos,
			"color": data.color,
		})
