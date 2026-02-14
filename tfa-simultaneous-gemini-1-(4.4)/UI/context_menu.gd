extends PanelContainer

var target_character = null
var vbox: VBoxContainer = VBoxContainer.new()
@onready var game = get_node("/root/Game")

func _ready():
	mouse_filter = Control.MOUSE_FILTER_STOP
	vbox.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	vbox.size_flags_stretch_ratio = 0.0
	add_child(vbox)
	custom_minimum_size = Vector2(150, 30)
	size = Vector2(150,30)
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN

func setup(character, options: Array):
	mouse_filter = Control.MOUSE_FILTER_STOP

	target_character = character
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	#game.context_menu_open = true
	# Clear any existing buttons
	for child in vbox.get_children():
		child.queue_free()
	
	# Create a button for each option
	for option in options:
		var button = Button.new()
		button.text = option
		button.custom_minimum_size = Vector2(150, 30)
		button.size_flags_horizontal = Control.SIZE_FILL  # Fill the container width
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		#button.size_flags_stretch_ratio = 0.0  # Don't stretch beyond minimum
		button.pressed.connect(_on_option_selected.bind(option))
		vbox.add_child(button)

func _on_option_selected(option: String):
	# Handle the selected option
	print("on option selected for context menu")
	match option:
		"Attack":
			target_character.attack()
		"Talk":
			print("attempting to start dialogue")
			#print("target character dialogue index: ",target_character.current_dialogue_index )
			#print("target character dialogues: ", target_character.dialogues)
			DialogueManager.start_dialogue(target_character.dialogues[target_character.current_dialogue_index])
		_:
			# Generic handler - you could call a method on the character
			if target_character.has_method("interact"):
				target_character.interact(option)
	# Close the menu
	queue_free()
	game.context_menu_open = false
# Optional: close menu when clicking elsewhere
func _input(event):
	if event is InputEventMouseButton and event.pressed:
		if get_rect().has_point(get_local_mouse_position()):
			print('handling input in context menu')
			#get_viewport().set_input_as_handled()
			#game.context_menu_open = false
			
