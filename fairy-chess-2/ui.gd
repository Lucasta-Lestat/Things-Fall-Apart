# ui.gd
# Manages the user interface, including setup, piece selection, and game state display.
# Attach this script to a CanvasLayer node.

extends CanvasLayer

# --- Nodes ---
@onready var game_board = get_node("../GameBoard")
@onready var white_piece_panel = $HBoxContainer/WhiteScrollContainer/VBoxContainer
@onready var black_piece_panel = $HBoxContainer/BlackScrollContainer/VBoxContainer
@onready var start_button = $GameOverlayUI/StartButton
@onready var game_state_label = $GameOverlayUI/GameStateLabel
@onready var setup_turn_label = $GameOverlayUI/SetupTurnLabel
@onready var player_turn_label = $GameOverlayUI/PlayerTurnLabel # Add a new Label node for this

# --- Preload Scenes ---
var piece_icon_scene = preload("res://scenes/ui/piece_icon.tscn")

# A dictionary defining all the pieces available for selection.
#define a standard size for all icons.
const ICON_SIZE = Vector2(70,140 )
const PIECE_DEFINITIONS = {
	"peasants": [
		{"type": "Pawn", "scene": "res://scenes/pieces/Pawn.tscn"},
		{"type": "Kulak", "scene": "res://scenes/pieces/Kulak.tscn"}
	],
	"non_peasants": [
		{"type": "Valkyrie", "royal": false, "scene": "res://scenes/pieces/Valkyrie.tscn"},
		{"type": "Monk", "royal": false, "scene": "res://scenes/pieces/Monk.tscn"},
		{"type": "Bishop", "royal": false, "scene": "res://scenes/pieces/Bishop.tscn"},
		{"type": "Devil Toad", "royal": false, "scene": "res://scenes/pieces/DevilToad.tscn"},
		{"type": "Rook", "royal": false, "scene": "res://scenes/pieces/Rook.tscn"},
		{"type": "Knight", "royal": false, "scene": "res://scenes/pieces/Knight.tscn"},
		{"type": "Princess", "royal": false, "scene": "res://scenes/pieces/Princess.tscn"},
		{"type": "Queen", "royal": false, "scene": "res://scenes/pieces/Queen.tscn"},
		{"type": "Rifleman", "royal": false, "scene": "res://scenes/pieces/Rifleman.tscn"},
		{"type": "Cannonier", "royal": false, "scene": "res://scenes/pieces/Cannonier.tscn"},
		{"type": "Gorgon", "royal": false, "scene": "res://scenes/pieces/Gorgon.tscn"},
		{"type": "Nightrider", "royal": false, "scene": "res://scenes/pieces/Nightrider.tscn"},
		{"type": "Dragonrider", "royal": false, "scene": "res://scenes/pieces/Dragonrider.tscn"},
		
		# --- Royal Pieces ---
		{"type": "Pontifex", "royal": true, "scene": "res://scenes/pieces/Pontifex.tscn"},
		{"type": "Chancellor", "royal": true, "scene": "res://scenes/pieces/Chancellor.tscn"},
		{"type": "King", "royal": true, "scene": "res://scenes/pieces/King.tscn"}

	]
}


func _ready():
	# Connect to the game board's signals
	game_board.game_state_changed.connect(_on_game_state_changed)
	game_board.setup_state_changed.connect(_on_setup_state_changed)
	game_board.turn_info_changed.connect(_on_turn_info_changed)

	
	# Initial UI state
	_on_game_state_changed("setup")
	_on_setup_state_changed()
	
	# Populate piece selection panels
	populate_piece_panels()

# --- UI Update Functions ---

func _on_game_state_changed(new_state):
	game_state_label.text = "Game Phase: " + new_state.capitalize()
	match new_state:
		"setup":
			start_button.disabled = true
			get_node("HBoxContainer/WhiteScrollContainer").visible = true # Show setup panels
			get_node("HBoxContainer/BlackScrollContainer").visible = true
			setup_turn_label.visible = true
			player_turn_label.visible = false
		"playing":
			start_button.disabled = true
			get_node("HBoxContainer/BlackScrollContainer").visible = false # Hide setup panels
			get_node("HBoxContainer/WhiteScrollContainer").visible = false
			setup_turn_label.visible = false
			player_turn_label.visible = true
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
	
	var white_complete = (white_counts.peasant == game_board.MAX_PEASANTS and
						  white_counts.non_peasant == game_board.MAX_NON_PEASANTS and
						  white_counts.royal >= 1)
						  
	var black_complete = (black_counts.peasant == game_board.MAX_PEASANTS and
						  black_counts.non_peasant == game_board.MAX_NON_PEASANTS and
						  black_counts.royal >= 1)
	
	if white_complete and black_complete:
		start_button.disabled = false
		setup_turn_label.text = "Setup Complete! Press Start."
	else:
		start_button.disabled = true


# Populates the side panels with icons for the players to choose from.
func populate_piece_panels():
	for child in white_piece_panel.get_children(): child.queue_free()
	for child in black_piece_panel.get_children(): child.queue_free()
		
	for color in ["white", "black"]:
		var panel = white_piece_panel if color == "white" else black_piece_panel
		
		var label = Label.new()
		label.text = "Peasants"
		panel.add_child(label)
		for piece_data in PIECE_DEFINITIONS.peasants:
			create_piece_icon(panel, piece_data, color)
			
		label = Label.new()
		label.text = "Nobles & Royals"
		label.add_child(HSeparator.new())
		panel.add_child(label)
		for piece_data in PIECE_DEFINITIONS.non_peasants:
			create_piece_icon(panel, piece_data, color)

# Helper function to create and configure a single piece icon.
func create_piece_icon(panel, data, color):
	var icon = piece_icon_scene.instantiate()
	icon.piece_type = data.type
	icon.color = color
	icon.is_royal = data.get("royal", false)
	icon.scene_path = data.scene
	
	# Assumes icon textures are at a path like "res://assets/icons/Pawn_white.png"
	var texture_path = "res://assets/icons/" + data.type + "_" + color + ".png"
	icon.texture = load(texture_path)
	# --- Automatic Resizing Logic for Icons ---
	# 1. Set the expand mode. This tells the TextureRect to scale its texture
	#    to fit the node's bounding box.
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	
	# 2. Set the desired size for the icon's bounding box.
	icon.custom_minimum_size = ICON_SIZE
	
	panel.add_child(icon)

# --- Button Callbacks ---

func _on_player_mode_button_toggled(button_pressed):
	if button_pressed:
		print("2 Player Mode (Hotseat) selected.")
	else:
		print("1 Player Mode (AI) selected.")


func _on_start_button_pressed() -> void:
	game_board.start_game() # Replace with function body.
