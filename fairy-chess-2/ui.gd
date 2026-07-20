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
	player_turn_label.text = message


func _on_game_ended(outcome_text):
	game_over_label.text = outcome_text
	game_over_panel.visible = true


func _on_setup_state_changed():
	var placer = game_board.setup_placer
	if game_board.ai_enabled and placer == "black":
		setup_turn_label.text = "Black (AI) is placing a piece..."
	else:
		setup_turn_label.text = placer.capitalize() + " to place a piece. (Right-click to undo.)"

	var white_counts = game_board.white_placed_pieces
	var black_counts = game_board.black_placed_pieces
	var white_complete = (white_counts.peasant == game_board.MAX_PEASANTS and
						  white_counts.non_peasant == game_board.MAX_NON_PEASANTS and
						  white_counts.royal >= 1)
	var black_complete = (black_counts.peasant == game_board.MAX_PEASANTS and
						  black_counts.non_peasant == game_board.MAX_NON_PEASANTS and
						  black_counts.royal >= 1)

	populate_piece_panels(white_piece_panel, "white", game_board.white_profile)
	populate_piece_panels(black_piece_panel, "black", game_board.black_profile)

	if white_complete and black_complete:
		start_button.disabled = false
		setup_turn_label.text = "Setup Complete! Press Start."
	else:
		start_button.disabled = true


# Populates a side panel with draggable piece icons.
func populate_piece_panels(panel, color, profile, is_spawn_credits = false):
	# Detach before freeing: queue_free() is deferred, so leaving the old icons
	# parented would have the container lay out both sets for a frame.
	for child in panel.get_children():
		panel.remove_child(child)
		child.queue_free()

	if is_spawn_credits:
		panel.add_child(_section_heading("Reserves"))
		for piece_type in profile.keys():
			for i in range(int(profile[piece_type])):
				create_piece_icon(panel, piece_type, color)
		return

	if not profile:
		return
	panel.add_child(_section_heading("Peasants"))
	for piece_type in profile.peasants:
		for i in range(int(profile.peasants[piece_type])):
			create_piece_icon(panel, piece_type, color)
	panel.add_child(_section_heading("Nobles & Royals"))
	for piece_type in profile.nobles:
		for i in range(int(profile.nobles[piece_type])):
			create_piece_icon(panel, piece_type, color)
	for piece_type in profile.royals:
		for i in range(int(profile.royals[piece_type])):
			create_piece_icon(panel, piece_type, color)


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
		return
	var icon = piece_icon_scene.instantiate()
	panel.add_child(icon)
	icon.setup(data, piece_type, color, ART_SIZE)


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
