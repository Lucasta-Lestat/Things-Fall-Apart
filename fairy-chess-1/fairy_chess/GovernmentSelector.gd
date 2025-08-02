# GovernmentSelector.gd
class_name GovernmentSelector
extends Control

signal government_selected(player: int, government: FairyChessGame.Government)

@onready var white_dropdown: OptionButton = $WhiteGovernment
@onready var black_dropdown: OptionButton = $BlackGovernment

func _ready():
	setup_dropdowns()

func setup_dropdowns():
	var governments = ["Monarchy", "Anarchy", "Republic", "Theocracy", "Technocracy"]
	
	for government in governments:
		white_dropdown.add_item(government)
		black_dropdown.add_item(government)
	
	white_dropdown.item_selected.connect(_on_white_government_selected)
	black_dropdown.item_selected.connect(_on_black_government_selected)

func _on_white_government_selected(index: int):
	var government = FairyChessGame.Government.values()[index]
	government_selected.emit(1, government)

func _on_black_government_selected(index: int):
	var government = FairyChessGame.Government.values()[index]
	government_selected.emit(-1, government)
