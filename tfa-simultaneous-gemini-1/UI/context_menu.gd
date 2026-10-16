extends PanelContainer

var target_character = null
# Who invoked the menu. Verbs that act on the target (Attack) are performed BY
# this character; null falls back to the old no-actor behaviour.
var actor_character = null
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

func setup(character, options: Array, actor = null):
	mouse_filter = Control.MOUSE_FILTER_STOP

	target_character = character
	actor_character = actor
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
			# target_spawn (when set) beats the from_<map> convention -- same-map
			# stairs land at their linked arrival marker
			game.load_map(target_map, game.current_map_id,
				target_character.get_meta("target_spawn", ""))
		queue_free()
		game.call_deferred("set", "context_menu_open", false)
		return
	match option:
		"Attack":
			# The actor attacks the target, designating them as the aim node so
			# the swing tracks them. Previously this called attack() on the
			# TARGET, i.e. the victim swung at their own facing.
			_order_attack(target_character)
		"Talk":
			# active_dialogue_id() owns the index bounds (and that the dialogue
			# exists) so this branch and the left-click talk fast path always
			# open the same conversation. An empty id (the index moved while
			# the menu was up) logs "<Name> has nothing to say." in
			# DialogueManager, the one place that line is written.
			if target_character is ProceduralCharacter:
				DialogueManager.start_dialogue(target_character.active_dialogue_id(), str(target_character.Name))
		"Trade":
			if target_character is ProceduralCharacter:
				game.show_trade_window(target_character)
		"Wait Here":
			if "hold_position" in target_character:
				target_character.hold_position = true
				GameLog.add_entry(str(target_character.Name) + " holds position.")
		"Resume":
			if "hold_position" in target_character:
				target_character.hold_position = false
				GameLog.add_entry(str(target_character.Name) + " moves out.")
		"Open":
			if target_character is Item:
				game.show_chest_inventory(target_character)
		"Search Body":
			if is_instance_valid(target_character) and target_character is ProceduralCharacter \
					and not target_character.is_alive():
				game.show_loot_window(target_character)
		_:
			if target_character.has_method("interact"):
				target_character.interact(option)
	# Close the menu — defer the flag reset so it stays true for the rest of
	# this frame, preventing _process-based input polls from acting on the click.
	queue_free()
	game.call_deferred("set", "context_menu_open", false)

# "Attack" only on a living character outside the party: not on items, doors,
# warps, corpses or a companion (Game.show_context_menu leaves it off those).
func _is_attackable(target) -> bool:
	return is_instance_valid(target) and target is ProceduralCharacter \
		and target.is_alive() and not target.is_party_member()

# The party's order to attack `target`: the menu's actor (the party member who
# right-clicked), else the primary selection, else the first living selected
# member, swings its main hand at it (a punch when that hand holds no weapon),
# exactly as a click on the target would. Paused, the swing is planned
# (queued) instead. Never the target's own swing.
func _order_attack(target) -> void:
	if not _is_attackable(target):
		return
	var actor = _attacking_party_member()
	if actor == null:
		GameLog.add_entry("No party member is selected to attack %s: select one first." % target.Name)
		return
	# Same rule as a click on the world (ProceduralCharacter._handle_input):
	# someone who can't take orders doesn't take this one either.
	if _refuses_orders(actor):
		return
	if PauseManager.is_paused:
		if actor.action_queue:
			actor.action_queue.queue_attack_target(target)
	else:
		actor.target_rotation = (target.global_position - actor.global_position).angle() + PI / 2
		actor.attack("Main", target.global_position, target)

# True (and says why) when `actor` can't take orders now, as _handle_input
# ignores a click: Unconscious, or Panicked/Frightened/Transfixed/Incited.
func _refuses_orders(actor) -> bool:
	var cm = actor.condition_manager
	if cm == null:
		return false
	var blocking_id := ""
	if cm.has_condition("unconscious"):
		blocking_id = "unconscious"
	else:
		for cid in ["panicked", "frightened", "transfixed", "incited"]:
			if cm.has_active_condition(cid):
				blocking_id = cid
				break
	if blocking_id == "":
		return false
	var inst = cm.get_condition(blocking_id)
	var blocking_name: String = inst.condition.display_name \
		if inst and inst.condition and inst.condition.display_name != "" else blocking_id.capitalize()
	actor.notify(blocking_name, Color(1.0, 0.6, 0.4), "%s can't take orders: %s." % [actor.Name, blocking_name])
	return true

# The party member who carries out an attack order: the actor that opened the
# menu, else the primary selection, else the first living selected member;
# null when there is none.
func _attacking_party_member():
	var candidates: Array = [actor_character]
	if game != null and game.has_method("get_selected"):
		candidates.append(game.get_selected())
	if game != null and game.get("selected_characters") is Array:
		candidates.append_array(game.selected_characters)
	for c in candidates:
		if is_instance_valid(c) and c is ProceduralCharacter and c.is_alive() and c.is_party_member():
			return c
	return null

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
