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
	# Warp Area2Ds carry their destination in metadata; don't try to interact
	# with them like a character.
	if target_character is Area2D and target_character.has_meta("target_map"):
		var target_map: String = target_character.get_meta("target_map", "")
		if not target_map.is_empty():
			game.load_map(target_map, game.current_map_id)
		queue_free()
		game.call_deferred("set", "context_menu_open", false)
		return
	match option:
		"Attack":
			target_character.attack()
		"Talk":
			var dlg_idx: int = target_character.current_dialogue_index
			if dlg_idx >= 0 and dlg_idx < target_character.dialogues.size():
				DialogueManager.start_dialogue(target_character.dialogues[dlg_idx])
		"Trade":
			if target_character is ProceduralCharacter:
				game.show_trade_window(target_character)
		"Open":
			if target_character is Item:
				game.show_chest_inventory(target_character)
		_:
			if target_character.has_method("interact"):
				target_character.interact(option)
	# Close the menu — defer the flag reset so it stays true for the rest of
	# this frame, preventing _process-based input polls from acting on the click.
	queue_free()
	game.call_deferred("set", "context_menu_open", false)
# Close the menu when the user clicks outside it. Use _unhandled_input rather
# than _input so the menu's own Buttons get the click first via GUI dispatch
# — calling set_input_as_handled() from _input on a click inside the rect
# previously swallowed the event before the Button could fire its `pressed`
# signal, so "Open" never opened the chest.
func _unhandled_input(event):
	if event is InputEventMouseButton and event.pressed:
		queue_free()
		game.call_deferred("set", "context_menu_open", false)
		get_viewport().set_input_as_handled()
