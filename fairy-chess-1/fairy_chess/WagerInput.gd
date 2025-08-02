# WagerInput.gd
class_name WagerInput
extends Control

signal wager_set(white_wager: int, black_wager: int)

@onready var white_wager_input: SpinBox = $WagerContainer/WhiteWager
@onready var black_wager_input: SpinBox = $WagerContainer/BlackWager
@onready var confirm_button: Button = $ConfirmWagers

func _ready():
	confirm_button.pressed.connect(_on_confirm_pressed)

func _on_confirm_pressed():
	var white_wager = int(white_wager_input.value)
	var black_wager = int(black_wager_input.value)
	wager_set.emit(white_wager, black_wager)

func set_max_wagers(white_gold: int, black_gold: int):
	white_wager_input.max_value = white_gold
	black_wager_input.max_value = black_gold
