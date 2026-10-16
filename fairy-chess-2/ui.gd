# ui.gd
# Manages the user interface: setup panels, piece selection, turn labels,
# the AI toggle, and the game-over overlay.

extends CanvasLayer

# --- Nodes ---
@onready var game_board = get_node("../GameBoard")
@onready var white_piece_panel = $CenterContainer/VBoxContainer/HBoxContainer/WhiteScrollContainer/VBoxContainer
@onready var black_piece_panel = $CenterContainer/VBoxContainer/HBoxContainer/BlackScrollContainer/VBoxContainer
@onready var start_button = $GameOverlayUI/MarginContainer/VBoxContainer/BottomRowLabels/StartButton
@onready var game_state_label = $GameOverlayUI/MarginContainer/VBoxContainer/TopRowLabels/GameStateLabel
@onready var setup_turn_label = $GameOverlayUI/MarginContainer/VBoxContainer/TopRowLabels/SetupTurnLabel
@onready var player_turn_label = $GameOverlayUI/MarginContainer/VBoxContainer/TopRowLabels/PlayerTurnLabel
@onready var white_profile_display = $CenterContainer/VBoxContainer/WhiteProfileDisplay
@onready var black_profile_display = $CenterContainer/VBoxContainer/BlackProfileDisplay
@onready var ai_toggle = $GameOverlayUI/MarginContainer/VBoxContainer/BottomRowLabels/PlayerModeButton
@onready var game_over_panel = $GameOverlayUI/GameOverPanel
@onready var game_over_label = $GameOverlayUI/GameOverPanel/VBoxContainer/OutcomeLabel
@onready var choice_picker = $GameOverlayUI/ChoicePicker
@onready var profile_picker = $GameOverlayUI/ProfilePicker

var piece_icon_scene = preload("res://ui/piece_icon.tscn")
var _game_over_reason: Label # why the game ended, under the outcome title
var _last_turn_message = "" # restored after a drag shows a refusal in its place

# Minimum size of the art inside a panel icon; the name label sits below it, so
# a row ends up a little taller than this. The column's width is pinned by
# PieceIcon.custom_minimum_size in piece_icon.tscn, not by this value.
const ART_SIZE = Vector2(90, 150)


func _ready():
	game_board.game_state_changed.connect(_on_game_state_changed)
	game_board.setup_state_changed.connect(_on_setup_state_changed)
	game_board.turn_info_changed.connect(_on_turn_info_changed)
	game_board.spawn_credits_changed.connect(_on_spawn_credits_changed)
	game_board.game_ended.connect(_on_game_ended)
	profile_picker.confirmed.connect(_on_profiles_confirmed)

	game_over_panel.visible = false
	# The outcome title is a big display style; the reason sits under it in
	# body text so a long explanation stays readable.
	_game_over_reason = Label.new()
	_game_over_reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_game_over_reason.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_game_over_reason.custom_minimum_size.x = 320
	_game_over_reason.visible = false
	game_over_label.get_parent().add_child(_game_over_reason)
	game_over_label.get_parent().move_child(_game_over_reason, game_over_label.get_index() + 1)
	ai_toggle.visible = true
	ai_toggle.button_pressed = game_board.ai_enabled

	_on_game_state_changed(game_board.game_phase)


func _on_profiles_confirmed(white_id, black_id, ai_on):
	ai_toggle.button_pressed = ai_on
	game_board.begin_setup(white_id, black_id, ai_on)


# --- UI Update Functions ---
func _on_spawn_credits_changed(white_credits, black_credits):
	if game_board.game_phase != "playing":
		return
	var white_any = _any_positive(white_credits)
	var black_any = _any_positive(black_credits)
	white_piece_panel.visible = white_any
	black_piece_panel.visible = black_any
	if white_any:
		populate_piece_panels(white_piece_panel, "white", white_credits, true)
	if black_any:
		populate_piece_panels(black_piece_panel, "black", black_credits, true)


func _any_positive(credits: Dictionary) -> bool:
	for key in credits:
		if credits[key] > 0:
			return true
	return false


func _on_game_state_changed(new_state):
	game_state_label.text = "Game Phase: " + new_state.capitalize()
	match new_state:
		"pregame":
			# Champion selection happens over an otherwise-inert board.
			start_button.disabled = true
			ai_toggle.disabled = true
			white_piece_panel.visible = false
			black_piece_panel.visible = false
			setup_turn_label.visible = false
			player_turn_label.visible = true
			profile_picker.open(PlayerDatabase.get_roster(),
				game_board.DEFAULT_WHITE_ID, game_board.DEFAULT_BLACK_ID,
				game_board.ai_enabled)
		"setup":
			start_button.disabled = true
			ai_toggle.disabled = false
			white_piece_panel.visible = true
			black_piece_panel.visible = not game_board.ai_enabled
			setup_turn_label.visible = true
			player_turn_label.visible = false
			update_profile_displays()
			white_profile_display.visible = true
			black_profile_display.visible = true
			populate_piece_panels(white_piece_panel, "white", game_board.white_profile)
			populate_piece_panels(black_piece_panel, "black", game_board.black_profile)
		"playing":
			start_button.disabled = true
			ai_toggle.disabled = true
			white_piece_panel.visible = false
			black_piece_panel.visible = false
			setup_turn_label.visible = false
			player_turn_label.visible = true
			update_profile_displays()
		"game_over":
			start_button.disabled = true


func _on_turn_info_changed(message):
	_last_turn_message = message
	player_turn_label.text = message


# outcome_text is "<title>" or "<title>\n<reason>" (see GameBoard.end_game).
func _on_game_ended(outcome_text):
	var lines = outcome_text.split("\n", true, 1)
	game_over_label.text = lines[0]
	_game_over_reason.text = lines[1] if lines.size() > 1 else ""
	_game_over_reason.visible = _game_over_reason.text != ""
	game_over_panel.visible = true


func _on_setup_state_changed():
	populate_piece_panels(white_piece_panel, "white", game_board.white_profile)
	populate_piece_panels(black_piece_panel, "black", game_board.black_profile)
	start_button.disabled = not (_setup_complete(game_board.white_placed_pieces)
		and _setup_complete(game_board.black_placed_pieces))
	refresh_setup_label()


func _setup_complete(counts) -> bool:
	return (counts.peasant == game_board.MAX_PEASANTS and
			counts.non_peasant == game_board.MAX_NON_PEASANTS and
			counts.royal >= 1)


# The setup prompt spells out the placement rules and how many slots are
# filled, since a refused drop otherwise only shows a "forbidden" cursor.
func refresh_setup_label():
	var placer = game_board.setup_placer
	if _setup_complete(game_board.white_placed_pieces) and _setup_complete(game_board.black_placed_pieces):
		setup_turn_label.text = "Setup Complete! Press Start."
	elif game_board.ai_enabled and placer == "black":
		setup_turn_label.text = "Black (AI) is placing a piece..."
	else:
		var c = game_board.white_placed_pieces if placer == "white" else game_board.black_placed_pieces
		var text = "%s to place a piece: peasants on your 2nd row (%d/%d), nobles & royals on your back row (%d/%d, at least one royal). Right-click to undo." \
			% [placer.capitalize(), c.peasant, game_board.MAX_PEASANTS, c.non_peasant, game_board.MAX_NON_PEASANTS]
		if c.non_peasant == game_board.MAX_NON_PEASANTS - 1 and c.royal == 0:
			text += " Your last back-row slot must be a royal."
		setup_turn_label.text = text


# Called by the board while a drag hovers a square it refuses: say why in the
# prompt for the current phase. restore_prompt() puts the normal text back.
func show_drop_reason(message: String):
	if game_board.game_phase == "setup":
		setup_turn_label.text = message
	else:
		player_turn_label.text = message


func restore_prompt():
	if game_board.game_phase == "setup":
		refresh_setup_label()
	else:
		player_turn_label.text = _last_turn_message


# Populates a side panel with draggable piece icons.
func populate_piece_panels(panel, color, profile, is_spawn_credits = false):
	# Detach before freeing: queue_free() is deferred, so leaving the old icons
	# parented would have the container lay out both sets for a frame.
	for child in panel.get_children():
		panel.remove_child(child)
		child.queue_free()

	if is_spawn_credits:
		panel.add_child(_section_heading("Reserves (peasants to your 2nd row, others to your back row; uses your turn)"))
		for piece_type in profile.keys():
			for i in range(int(profile[piece_type])):
				create_piece_icon(panel, piece_type, color)
		return

	if not profile:
		return
	# Icons that can't be placed right now (bucket full, or the last back-row
	# slot held for a royal) are dimmed and say why on hover.
	var counts = game_board.white_placed_pieces if color == "white" else game_board.black_placed_pieces
	var peasants_full = counts.peasant >= game_board.MAX_PEASANTS
	var back_full = counts.non_peasant >= game_board.MAX_NON_PEASANTS
	var royal_slot = not back_full and counts.royal == 0 and counts.non_peasant == game_board.MAX_NON_PEASANTS - 1
	panel.add_child(_section_heading("Peasants"))
	for piece_type in profile.peasants:
		for i in range(int(profile.peasants[piece_type])):
			_dim_icon(create_piece_icon(panel, piece_type, color), "all peasant slots are filled" if peasants_full else "")
	panel.add_child(_section_heading("Nobles & Royals"))
	for piece_type in profile.nobles:
		for i in range(int(profile.nobles[piece_type])):
			var why = ""
			if back_full:
				why = "all back-row slots are filled"
			elif royal_slot:
				why = "the last back-row slot must be a royal"
			_dim_icon(create_piece_icon(panel, piece_type, color), why)
	for piece_type in profile.royals:
		for i in range(int(profile.royals[piece_type])):
			_dim_icon(create_piece_icon(panel, piece_type, color), "all back-row slots are filled" if back_full else "")


func _dim_icon(icon, why: String):
	if icon == null or why == "":
		return
	icon.modulate.a = 0.4
	icon.tooltip_text = "%s (%s)" % [icon.piece_type, why]


# A column heading ("Reserves" / "Peasants" / "Nobles & Royals"). These are the
# only un-sized controls in the reserve column, so without autowrap their text
# width is what decides how wide the whole column gets.
func _section_heading(text: String) -> Label:
	var label = Label.new()
	label.text = text
	label.theme_type_variation = "PanelHeading"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func create_piece_icon(panel, piece_type, color):
	var data = PlayerDatabase.get_piece_data(piece_type)
	if not data:
		return null
	var icon = piece_icon_scene.instantiate()
	panel.add_child(icon)
	icon.setup(data, piece_type, color, ART_SIZE)
	return icon


func update_profile_displays():
	white_profile_display.set_profile(game_board.white_profile)
	black_profile_display.set_profile(game_board.black_profile)


# --- Button Callbacks ---
func _on_player_mode_button_toggled(button_pressed):
	game_board.set_ai_enabled(button_pressed)
	if game_board.game_phase == "setup":
		black_piece_panel.visible = not button_pressed
		_on_setup_state_changed()


func _on_start_button_pressed() -> void:
	game_board.start_game()


func _on_play_again_pressed() -> void:
	game_board.restart_game()
