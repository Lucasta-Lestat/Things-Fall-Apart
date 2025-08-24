# ui.gd
# Manages the user interface, including setup, piece selection, and game state display.
# Attach this script to a CanvasLayer node.

extends CanvasLayer

# --- Nodes ---
@onready var game_board = get_node("../GameBoard")
#
@onready var white_piece_panel = $CenterContainer/VBoxContainer/HBoxContainer/WhiteScrollContainer/VBoxContainer
@onready var black_piece_panel = $CenterContainer/VBoxContainer/HBoxContainer/BlackScrollContainer/VBoxContainer
@onready var start_button = $GameOverlayUI/MarginContainer/VBoxContainer/BottomRowLabels/StartButton
@onready var game_state_label = $GameOverlayUI/MarginContainer/VBoxContainer/TopRowLabels/GameStateLabel
@onready var setup_turn_label = $GameOverlayUI/MarginContainer/VBoxContainer/TopRowLabels/SetupTurnLabel
@onready var player_turn_label = $GameOverlayUI/MarginContainer/VBoxContainer/TopRowLabels/PlayerTurnLabel 
@onready var white_profile_display = $CenterContainer/VBoxContainer/WhiteProfileDisplay
@onready var black_profile_display = $CenterContainer/VBoxContainer/BlackProfileDisplay
# --- Preload Scenes ---
var piece_icon_scene = preload("res://ui/piece_icon.tscn")

# A dictionary defining all the pieces available for selection.
#define a standard size for all icons.
const ICON_SIZE = Vector2(70,140 )

func _ready():
	# Connect to the game board's signals
	game_board.game_state_changed.connect(_on_game_state_changed)
	game_board.setup_state_changed.connect(_on_setup_state_changed)
	game_board.turn_info_changed.connect(_on_turn_info_changed)
	game_board.spawn_credits_changed.connect(_on_spawn_credits_changed)
	
	# Initial UI state
	_on_game_state_changed("setup")
	_on_setup_state_changed()
	
	# Populate piece selection panels
	#print('player_profiles: ', PlayerDatabase.player_profiles)
	populate_piece_panels(white_piece_panel, "white", game_board.white_profile) 
	populate_piece_panels(black_piece_panel, "black", game_board.black_profile)

# --- UI Update Functions ---
func _on_spawn_credits_changed(white_credits, black_credits):

		print("DEBUG: on_spawn_credits_changed called")
		if white_credits.size() > 0:
			print("DEBUG: showing white piece panel and calling populate_piece_panels")
			get_node("CenterContainer/VBoxContainer/HBoxContainer/WhiteScrollContainer/VBoxContainer").visible = true
			white_piece_panel.visible = true
			populate_piece_panels(white_piece_panel, "white", white_credits, true)
		else:
			white_piece_panel.visible = false
		if black_credits.size() > 0:
			print("DEBUG: showing black piece panel and calling populate_piece_panels")
			get_node("CenterContainer/VBoxContainer/HBoxContainer/BlackScrollContainer/VBoxContainer").visible = true
			black_piece_panel.visible = true
			populate_piece_panels(black_piece_panel, "black", black_credits, true)
		else:
			black_piece_panel.visible = false
		
func _on_game_state_changed(new_state):
	print("game state changed to: ",new_state)
	game_state_label.text = "Game Phase: " + new_state.capitalize()
	match new_state:
		"setup":
			start_button.disabled = true
			get_node("CenterContainer/VBoxContainer/HBoxContainer/WhiteScrollContainer/VBoxContainer").visible = true # Show setup panels
			get_node("CenterContainer/VBoxContainer/HBoxContainer/BlackScrollContainer/VBoxContainer").visible = true
			setup_turn_label.visible = true
			player_turn_label.visible = false
			# --- Hide profile displays during setup ---
			white_profile_display.visible = true
			black_profile_display.visible = true
		"playing":
			start_button.disabled = true
			get_node("CenterContainer/VBoxContainer/HBoxContainer/BlackScrollContainer/VBoxContainer").visible = false # Hide setup panels
			get_node("CenterContainer/VBoxContainer/HBoxContainer/WhiteScrollContainer/VBoxContainer").visible = false
			setup_turn_label.visible = false
			player_turn_label.visible = true
			update_profile_displays()
		"game_over":
			start_button.disabled = true
			player_turn_label.text = new_state # Display outcome

# New function to handle turn display
func _on_turn_info_changed(message):
	player_turn_label.text = message
	
# Update the label indicating whose turn it is to place a piece and check if setup is done.
func _on_setup_state_changed():
	var placer = game_board.setup_placer
	setup_turn_label.text = placer.capitalize() + " to place a piece."
	
	# Check if both players have completed their setup
	var white_counts = game_board.white_placed_pieces
	var black_counts = game_board.black_placed_pieces
	print("DEBUG:white_counts: ", white_counts)
	print("DEBUG: black_counts: ", black_counts)
	
	var white_complete = (white_counts.peasant == game_board.MAX_PEASANTS and
						  white_counts.non_peasant == game_board.MAX_NON_PEASANTS and
						  white_counts.royal >= 1)
						  
	var black_complete = (black_counts.peasant == game_board.MAX_PEASANTS and
						  black_counts.non_peasant == game_board.MAX_NON_PEASANTS and
						  black_counts.royal >= 1)
	# Re-calculate and display the remaining pieces for both players
	populate_piece_panels(white_piece_panel, "white", game_board.white_profile)
	populate_piece_panels(black_piece_panel, "black", game_board.black_profile)
	
	if white_complete and black_complete:
		start_button.disabled = false
		setup_turn_label.text = "Setup Complete! Press Start."
	else:
		start_button.disabled = true


# Populates the side panels with icons for the players to choose from.
func populate_piece_panels(panel, color, profile, is_spawn_credits=false):
	for child in panel.get_children(): child.queue_free()
	
	if is_spawn_credits:
		# piece_source is a dictionary like {"Pawn": 1}
		for piece_type in profile.keys():
			var count = profile[piece_type]
			if count > 0:
				# Find the full data for this piece type
					# Create an icon for each available spawn
					for i in range(count):
						create_piece_icon(panel, piece_type, color)
	else:
		
		if not profile: return
		var placed_pieces
		'''
		if color =="white": 
			placed_pieces = game_board.white_placed_pieces
		else:
			placed_pieces = game_board.white_placed_pieces
		for piece_type in placed_pieces:
			if piece_type != "royal" and piece_type != "non_peasant" and piece_type != "peasant":
				pass
		'''		
		var label = Label.new()
		label.text = "Peasants"
		panel.add_child(label)
		print("DEBUG: profile: ", profile)
		
		
		for piece_type in profile.peasants:
			for i in range(profile.peasants[piece_type]):
				create_piece_icon(panel, piece_type, color)
		
		label = Label.new()
		label.text = "Nobles & Royals"
		
		panel.add_child(label)
		for piece_type in profile.nobles:
			for i in range(profile.nobles[piece_type]):
				create_piece_icon(panel, piece_type, color)
		for piece_type in profile.royals:
			for i in range(profile.royals[piece_type]):
				create_piece_icon(panel, piece_type, color)


# Helper function to create and configure a single piece icon.
func create_piece_icon(panel, piece_type, color):
	var data = PlayerDatabase.get_piece_data(piece_type)
	if not data: return
	
	var icon = piece_icon_scene.instantiate()
	icon.piece_type = piece_type
	icon.color = color
	#icon.is_royal = data.get("royal", false)
	icon.is_peasant = data.category == "peasant"
	icon.is_royal = data.category =="royal"
	icon.scene_path = data.scene
	var texture_path = "res://assets/icons/" + piece_type + "_" + color + ".png"
	icon.texture = load(texture_path)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.custom_minimum_size = ICON_SIZE
	panel.add_child(icon)

func update_profile_displays():
	white_profile_display.set_profile(game_board.white_profile)
	black_profile_display.set_profile(game_board.black_profile)

# --- Button Callbacks ---
func _on_player_mode_button_toggled(button_pressed):
	if button_pressed:
		print("2 Player Mode (Hotseat) selected.")
	else:
		print("1 Player Mode (AI) selected.")


func _on_start_button_pressed() -> void:
	game_board.start_game() # Replace with function body.
