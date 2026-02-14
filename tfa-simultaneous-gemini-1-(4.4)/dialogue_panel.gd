extends Panel

# References to UI elements
@onready var character_portrait: TextureRect = $MarginContainer/HBoxContainer/Portrait
@onready var speaker_name_label: Label = $MarginContainer/HBoxContainer/DialogueVBox/SpeakerName
@onready var dialogue_text: RichTextLabel = $MarginContainer/HBoxContainer/DialogueVBox/DialogueText
@onready var choices_container: VBoxContainer = $MarginContainer/HBoxContainer/DialogueVBox/ChoicesContainer
@onready var continue_indicator: Label = $MarginContainer/HBoxContainer/DialogueVBox/ContinueIndicator

# Choice button scene (we'll create this)
const CHOICE_BUTTON = preload("res://choice_button.tscn")

# Reference to dialogue manager
var dialogue_manager: Node

func _ready():
	# Hide panel by default
	hide()
	
	# Hide continue indicator initially
	continue_indicator.hide()
	
	# Find and connect to dialogue manager
	# Adjust the path based on your node structure
	dialogue_manager = get_node("/root/DialogueManager")
	
	if dialogue_manager:
		dialogue_manager.dialogue_updated.connect(_on_dialogue_updated)
		dialogue_manager.choices_available.connect(_on_choices_available)
		dialogue_manager.dialogue_ended.connect(_on_dialogue_ended)

func _input(event):
	# Only process input when panel is visible and no choices are shown
	if visible and choices_container.get_child_count() == 0:
		if event.is_action_pressed("ui_accept") or (event is InputEventKey and event.pressed and event.keycode == KEY_SPACE):
			# Advance dialogue
			if dialogue_manager:
				dialogue_manager.advance_line()

func _on_dialogue_updated(speaker_name: String, portrait: Texture2D, text: String, has_next: bool):
	# Show the panel
	show()
	
	# Update speaker name
	speaker_name_label.text = speaker_name
	
	# Update portrait
	if portrait:
		character_portrait.texture = portrait
		character_portrait.show()
	else:
		character_portrait.hide()
	
	# Update dialogue text
	dialogue_text.text = text
	
	# Clear any existing choices
	_clear_choices()
	
	# Show/hide continue indicator
	if has_next:
		continue_indicator.show()
		continue_indicator.text = "Press SPACE to continue..."
	else:
		continue_indicator.hide()

func _on_choices_available(choices: Array):
	# Clear existing choices
	_clear_choices()
	
	# Hide continue indicator when choices are shown
	continue_indicator.hide()
	
	# Create button for each choice
	for i in range(choices.size()):
		var choice = choices[i]
		var button = CHOICE_BUTTON.instantiate()
		button.text = choice["text"]
		
		# Connect button press to choice selection
		button.pressed.connect(_on_choice_selected.bind(i))
		
		choices_container.add_child(button)

func _on_choice_selected(choice_index: int):
	# Tell dialogue manager which choice was selected
	if dialogue_manager:
		dialogue_manager.select_choice(choice_index)

func _on_dialogue_ended():
	# Hide the panel
	hide()
	
	# Clear choices
	_clear_choices()

func _clear_choices():
	# Remove all choice buttons
	for child in choices_container.get_children():
		child.queue_free()
