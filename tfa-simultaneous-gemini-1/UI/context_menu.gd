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
		if option == "Attack":
			_label_attack(button, character)
		vbox.add_child(button)

# The Attack entry says when attacking is a crime here, "Attack (Assault)",
# with the law in its tooltip, so the player knows before choosing it. The
# option itself stays "Attack" (that is what _on_option_selected matches).
func _label_attack(button: Button, target) -> void:
	if not _is_attackable(target):
		return
	var verdict: Dictionary = _attack_verdict(target)
	# A fight that kills is judged again as a killing (Murder): say so too, or
	# "not a crime" in Perrow (assault repealed, killing not) would mislead.
	var kill_verdict: Dictionary = _attack_verdict(target, true)
	var kill_line := ""
	if not kill_verdict.is_empty():
		kill_line = "Killing them would be %s (severity %d)." % [
			str(kill_verdict.get("display_name", "a crime")), int(kill_verdict.get("severity", 0))]
	if verdict.is_empty():
		if kill_line.is_empty():
			button.tooltip_text = "Attack %s. Not a crime here." % target.Name
		else:
			button.tooltip_text = "Attack %s. Fighting is not a crime here under the law of %s, but %s" % [
				target.Name, _law_name(kill_verdict), kill_line.substr(0, 1).to_lower() + kill_line.substr(1)]
		return
	button.text = "Attack (%s)" % str(verdict.get("display_name", "crime"))
	button.tooltip_text = "Attack %s. Here that is %s, a crime under the law of %s (severity %d): witnesses will report it." % [
		target.Name, str(verdict.get("display_name", "a crime")),
		_law_name(verdict), int(verdict.get("severity", 0))]
	if not kill_line.is_empty():
		button.tooltip_text += "\n" + kill_line

# What attacking `target` would be under the law here ({} = no crime), judged
# for the party member who would carry it out; `lethal` judges a killing blow.
func _attack_verdict(target, lethal: bool = false) -> Dictionary:
	var actor = _attacking_party_member()
	if actor == null:
		return {}
	var payload: Dictionary = CrimeManager.attack_payload(actor, target)
	if lethal:
		payload["lethal"] = true
	return CrimeManager.preview(actor, "attack", payload)

func _law_name(verdict: Dictionary) -> String:
	var law_faction: String = str(verdict.get("law_faction", ""))
	if FactionDatabase.has_faction(law_faction):
		return str(FactionDatabase.get_faction_data(law_faction).get("name", law_faction))
	return law_faction if law_faction != "" else "this place"

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
# right-clicked) and every other selected member swing their main hand at it
# (a punch when that hand holds no weapon), exactly as a left-click on a
# hostile does for each selected member. Paused, the swing is planned (queued)
# instead. Never the target's own swing. When the attack would be a severe
# crime here it is refused once with the reason, and choosing Attack on them
# again confirms: the same protocol as a severe cast
# (CrimeManager.attack_needs_confirmation).
func _order_attack(target) -> void:
	if not _is_attackable(target):
		return
	var attackers: Array = _attacking_party_members()
	if attackers.is_empty():
		GameLog.add_entry("No party member is selected to attack %s: select one first." % target.Name)
		return
	# Same rule as a click on the world (ProceduralCharacter._handle_input):
	# someone who can't take orders doesn't take this one either.
	var able: Array = []
	for actor in attackers:
		if not _refuses_orders(actor):
			able.append(actor)
	if able.is_empty():
		return
	var law_confirm: Dictionary = CrimeManager.attack_needs_confirmation(able[0], target)
	if not law_confirm.is_empty():
		var verdict: Dictionary = law_confirm.get("verdict", {})
		var crime: String = str(verdict.get("display_name", "a crime"))
		able[0].notify("Illegal here: " + crime, Color(1.0, 0.6, 0.4),
			"Attacking %s here is %s — a crime under the law of %s (severity %d). Choose Attack on them again if you mean to break the law." % [
				target.Name, crime, _law_name(verdict), int(verdict.get("severity", 0))])
		return
	for actor in able:
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
	var members: Array = _attacking_party_members()
	return members[0] if not members.is_empty() else null

# Everyone who carries out an attack order, the menu's actor first, then the
# primary selection and the rest of the selection; each living party member
# once.
func _attacking_party_members() -> Array:
	var candidates: Array = [actor_character]
	if game != null and game.has_method("get_selected"):
		candidates.append(game.get_selected())
	if game != null and game.get("selected_characters") is Array:
		candidates.append_array(game.selected_characters)
	var out: Array = []
	for c in candidates:
		if is_instance_valid(c) and c is ProceduralCharacter and c.is_alive() and c.is_party_member() \
				and not c in out:
			out.append(c)
	return out

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
