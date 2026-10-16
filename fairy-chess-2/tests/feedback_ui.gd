# tests/feedback_ui.gd
# Player-feedback checks against the real scene: the turn summary, the
# game-over reason and the prompt's standing warnings (GameBoard), the board's
# selection, chooser, marker and hover behaviour (ChessboardDisplay), and the
# setup prompt, dimmed icons and drop refusals (UI). Positions are built by
# hand on the live board, so no AI turn is ever played.
# Run with:
#   Godot_v4.6-stable_win64_console.exe --headless --path fairy-chess-2 --script res://tests/feedback_ui.gd
extends SceneTree

var checks = 0
var failures = 0
var gb
var ui
var display


func check(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		print("FEEDBACK FAIL: " + msg)


# Autoload singletons are NOT compile-time identifiers in a fresh `--script`
# compile, so fetch PlayerDatabase from the tree at runtime instead.
func _pdb():
	return root.get_node("/root/PlayerDatabase")


func _initialize():
	var scene = load("res://fairy_chess.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	await process_frame
	await process_frame
	gb = root.get_node("FairyChess/GameBoard")
	ui = root.get_node("FairyChess/UI")
	display = root.get_node("FairyChess/UI/CenterContainer/VBoxContainer/HBoxContainer/ChessboardDisplay")
	ui.profile_picker.cancel()

	_test_setup_prompt_and_drop_reasons()
	_start_hand_built_game()
	_test_summary_names_deaths()
	_test_summary_other_events()
	_test_status_notes()
	_test_selection_and_chooser()
	_test_markers_and_tooltips()
	_test_zombie_factory_and_stone()
	_test_last_turn_marks()
	_test_rules_text_and_royalty()
	_test_game_over_reason()

	print("")
	print("=== FEEDBACK UI: %d checks, %d failures ===" % [checks, failures])
	quit(1 if failures > 0 else 0)


# --- Setup (fairy-chess-18, drop reasons) ----------------------------------

func _test_setup_prompt_and_drop_reasons():
	gb.begin_setup("god", gb.DEFAULT_BLACK_ID, true)
	var text = ui.setup_turn_label.text
	check("peasants on your 2nd row (0/4)" in text and "back row (0/4, at least one royal)" in text,
		"setup prompt states the row rules and filled counts: '%s'" % text)

	# One back-row slot left and no royal yet: nobles are held back for a royal.
	var counts = gb.white_placed_pieces
	counts.peasant = gb.MAX_PEASANTS
	counts.non_peasant = gb.MAX_NON_PEASANTS - 1
	ui._on_setup_state_changed()
	check("Your last back-row slot must be a royal." in ui.setup_turn_label.text,
		"setup prompt warns about the royal slot: '%s'" % ui.setup_turn_label.text)
	var dim_peasant = false
	var dim_noble = false
	var lit_royal = false
	var undescribed = []
	for icon in ui.white_piece_panel.get_children():
		if icon is Label or icon.is_queued_for_deletion():
			continue
		var tip = icon.tooltip_text.replace("\n", " ")
		var category = Rules.PIECE_INFO.get(icon.piece_type, {}).get("category", "")
		if category == "peasant" and icon.modulate.a < 1.0 and "all peasant slots are filled" in tip:
			dim_peasant = true
		elif category == "noble" and icon.modulate.a < 1.0 and "the last back-row slot must be a royal" in tip:
			dim_noble = true
		elif category == "royal" and icon.modulate.a == 1.0:
			lit_royal = true
		# A dimmed icon keeps its rules text next to the reason (I12).
		if not Rules.PIECE_DESC.get(icon.piece_type, "?") in tip:
			undescribed.append(icon.piece_type)
	check(dim_peasant, "peasant icons are dimmed with a reason once the peasant slots are full")
	check(dim_noble, "noble icons are dimmed with a reason while the last slot is held for a royal")
	check(lit_royal, "royal icons stay placeable for the held slot")
	check(undescribed.is_empty(), "dimmed icons still describe their piece (%s)" % [undescribed])
	counts.peasant = 0
	counts.non_peasant = 0
	ui._on_setup_state_changed()

	# A refused drop explains itself in the prompt, once per reason, and the
	# prompt comes back when the drag ends.
	var normal = ui.setup_turn_label.text
	display._reject("Peasants go on your 2nd row.")
	check(ui.setup_turn_label.text == "Peasants go on your 2nd row.", "a refused drop shows its reason during setup")
	display._notification(Control.NOTIFICATION_DRAG_END)
	check(ui.setup_turn_label.text == normal, "ending the drag restores the setup prompt")

	# Whose piece it is is checked before the row rules.
	_hover_mouse(Vector2(0, 4)) # a white 2nd-row square, empty
	var black_pawn = {"color": "black", "piece_type": "Pawn", "is_peasant": true, "is_royal": false}
	var white_rook = {"color": "white", "piece_type": "Rook", "is_peasant": false, "is_royal": false}
	if _mouse_grid() == Vector2(0, 4):
		check(not display._can_drop_data(Vector2.ZERO, black_pawn) and "turn to place" in ui.setup_turn_label.text,
			"dropping the other side's piece names whose turn it is: '%s'" % ui.setup_turn_label.text)
		check(not display._can_drop_data(Vector2.ZERO, white_rook) and ui.setup_turn_label.text == "Nobles and royals go on your back row.",
			"a noble on the 2nd row names the row rule: '%s'" % ui.setup_turn_label.text)
		var white_pawn = {"color": "white", "piece_type": "Pawn", "is_peasant": true, "is_royal": false}
		check(display._can_drop_data(Vector2.ZERO, white_pawn) and ui.setup_turn_label.text == normal,
			"a legal square puts the normal prompt back: '%s'" % ui.setup_turn_label.text)
	else:
		print("FEEDBACK NOTE: headless mouse could not be placed (at %s); _can_drop_data ordering not checked" % _mouse_grid())
	display._notification(Control.NOTIFICATION_DRAG_END)


# Moves the (headless) mouse over a board square, the way _can_drop_data reads
# it: the viewport's mouse position.
func _hover_mouse(grid: Vector2) -> void:
	var motion = InputEventMouseMotion.new()
	var pos = display.global_position + grid * display.TILE_SIZE + Vector2(50, 50)
	motion.position = pos
	motion.global_position = pos
	Input.parse_input_event(motion)
	Input.flush_buffered_events()


func _mouse_grid() -> Vector2:
	return ((display.get_viewport().get_mouse_position() - display.global_position) / display.TILE_SIZE).floor()


# --- Hand-built positions ---------------------------------------------------

func _start_hand_built_game():
	gb.game_phase = "playing"
	gb.ai_enabled = true
	gb.white_pending = null
	gb.black_pending = null
	_clear_board()


func _clear_board():
	display.clear_selection()
	for node in gb.piece_nodes.values():
		if is_instance_valid(node):
			node.free()
	gb.piece_nodes = {}
	gb.state = Rules.new_state()
	var army = Rules.PIECE_INFO.keys()
	Rules.set_army(gb.state, "white", army)
	Rules.set_army(gb.state, "black", army)
	gb._sync_board_nodes()


# A display node plus its rules piece, like a placement during setup.
func _spawn(type: String, color: String, pos: Vector2):
	var def = _pdb().PIECE_DEFINITIONS[type]
	var node = load(def.scene).instantiate()
	display.add_child(node)
	node.setup_piece(type, color, def.category == "royal", display.TILE_SIZE)
	node.grid_position = pos
	node.position = pos * display.TILE_SIZE + Vector2(50, 50)
	var piece = Rules.add_piece(gb.state, type, color, pos)
	node.state_id = piece.id
	gb.piece_nodes[piece.id] = node
	gb._sync_board_nodes()
	return node


# Resolves on gb.state (as resolve_turn would) and returns the summary.
func _resolve_and_summarise(declared: Dictionary) -> String:
	var res = Rules.resolve(gb.state, declared)
	gb.state = res.state
	return gb._summarise(res.events)


func _kings():
	Rules.add_piece(gb.state, "King", "white", Vector2(5, 5))
	Rules.add_piece(gb.state, "King", "black", Vector2(5, 0))


# --- Turn summary (fairy-chess-01, 02, 10, 11, 12, 16, 17, 23) --------------

func _test_summary_names_deaths():
	# A Knight that ran is still struck by the Rook that declared the capture.
	gb.state = Rules.new_state()
	_kings()
	var knight = Rules.add_piece(gb.state, "Knight", "white", Vector2(2, 3))
	var rook = Rules.add_piece(gb.state, "Rook", "black", Vector2(2, 0))
	var text = _resolve_and_summarise({
		knight.id: {"action": "move", "target": Vector2(4, 4)},
		rook.id: {"action": "move", "target": Vector2(2, 3)},
	})
	check("your Knight was struck by a Rook even though it moved away" in text, "a fled piece's death is explained: '%s'" % text)
	check("A declared capture lands even if the target moves away." in text, "and the rule is spelled out: '%s'" % text)
	check(not "pieces lost" in text, "no bare 'N pieces lost' count: '%s'" % text)

	# A cannon names whose pieces it took, and merges identical deaths.
	gb.state = Rules.new_state()
	_kings()
	var can = Rules.add_piece(gb.state, "Cannonier", "white", Vector2(2, 5))
	Rules.add_piece(gb.state, "Pawn", "white", Vector2(2, 4))
	Rules.add_piece(gb.state, "Pawn", "black", Vector2(2, 2))
	Rules.add_piece(gb.state, "Pawn", "black", Vector2(2, 1))
	text = _resolve_and_summarise({can.id: {"action": "fire_cannon"}})
	check("your Pawn was caught in a Cannonier's cannon fire" in text, "cannon friendly fire is named: '%s'" % text)
	check("Black's Pawn was caught in a Cannonier's cannon fire (x2)" in text, "identical deaths merge with a count: '%s'" % text)

	# A path collision is explained, and both deaths are named.
	gb.state = Rules.new_state()
	_kings()
	var slider = Rules.add_piece(gb.state, "Rook", "white", Vector2(0, 5))
	var leaper = Rules.add_piece(gb.state, "Knight", "black", Vector2(2, 1))
	text = _resolve_and_summarise({
		slider.id: {"action": "move", "target": Vector2(0, 0)},
		leaper.id: {"action": "move", "target": Vector2(0, 2)},
	})
	check("your Rook was struck in transit when a Knight stepped into its path" in text, "a collision victim is named: '%s'" % text)
	check("Black's Knight died stepping into the path of a Rook" in text, "the interceptor is named: '%s'" % text)
	check("Stepping into a moving piece's path destroys both pieces." in text, "collisions explain the rule: '%s'" % text)

	# A Valkyrie's death says she comes back.
	gb.state = Rules.new_state()
	_kings()
	Rules.add_piece(gb.state, "Valkyrie", "white", Vector2(4, 4))
	var bkn = Rules.add_piece(gb.state, "Knight", "black", Vector2(3, 2))
	text = _resolve_and_summarise({bkn.id: {"action": "move", "target": Vector2(4, 4)}})
	check("your Valkyrie was taken by a Knight (she will return)" in text, "a fallen Valkyrie is reported: '%s'" % text)

	# Beyond MAX_DEATH_CLAUSES the rest are counted.
	var events = []
	for t in ["Pawn", "Rook", "Knight", "Bishop", "Queen", "Monk"]:
		events.append({"type": "capture", "id": 0, "pos": Vector2.ZERO, "cause": "clash", "by_type": "",
			"piece_type": t, "color": "black", "fled": true})
	text = gb._summarise(events)
	check("and 2 more pieces lost" in text and not "Monk" in text, "a busy turn caps the named deaths: '%s'" % text)


func _test_summary_other_events():
	gb.state = Rules.new_state()
	_kings()
	var text = gb._summarise([
		{"type": "backfill", "id": 1, "pos": Vector2.ZERO},
		{"type": "blocked", "id": 2},
		{"type": "promote_failed", "id": 3, "color": "white", "target_type": "Pawn", "reason": "target_destroyed"},
		{"type": "shot_missed", "shooter": 4, "color": "white"},
		{"type": "promote", "id": 5, "new_type": "Minister", "old_type": "Pawn", "color": "white", "pos": Vector2.ZERO},
		{"type": "transform", "id": 6, "new_type": "Werewolf (wolf form)", "old_type": "Werewolf (human form)", "color": "black", "pos": Vector2.ZERO},
		{"type": "transform", "id": 7, "new_type": "Elephant Rider", "old_type": "Doppelganger", "color": "white", "pos": Vector2.ZERO},
		{"type": "spawn", "id": 8, "piece_type": "Basic Automata", "color": "black", "pos": Vector2.ZERO},
		{"type": "spawn", "id": 9, "piece_type": "Raider", "color": "white", "pos": Vector2.ZERO},
		{"type": "convert", "id": 10, "new_type": "Cultist", "old_type": "Pawn", "color": "white", "pos": Vector2.ZERO},
		{"type": "credit", "color": "white", "piece_type": "Raider"},
		{"type": "credit", "color": "black", "piece_type": "Berserker"},
	])
	for want in [
		"a conditional move triggered and took the vacated square",
		"a conditional move did not trigger (the square was not vacated), so the piece stayed put",
		"promotion failed: the Pawn was killed this turn",
		"your shot found no target",
		"your Pawn was promoted to Minister",
		"Black's Werewolf shifted to wolf form",
		"your Doppelganger took the form of an Elephant Rider",
		"Black's Factory built a Basic Automata",
		"your Raider returned from reserves",
		"Black's Pawn changed sides (now your Cultist)",
		"a fallen Raider joined your reserves (drag it from Reserves onto an empty square on the 2nd row",
		"a fallen Berserker joined Black's reserves.",
	]:
		check(want in text, "summary says '%s': '%s'" % [want, text])
	check(not "bounced back" in text, "a blocked conditional move is not described as bouncing back")

	# Reaching the far row: the player is told how to promote; the AI is not.
	gb.state = Rules.new_state()
	_kings()
	var wp = Rules.add_piece(gb.state, "Pawn", "white", Vector2(1, 1))
	var bp = Rules.add_piece(gb.state, "Pawn", "black", Vector2(3, 4))
	text = _resolve_and_summarise({
		wp.id: {"action": "move", "target": Vector2(1, 0)},
		bp.id: {"action": "move", "target": Vector2(3, 5)},
	})
	check("your Pawn reached the far row: select it and click it to promote (that uses a turn)" in text,
		"the player's peasant on the far row says how to promote: '%s'" % text)
	check("Black's Pawn reached the far row and can promote" in text, "the AI's peasant is only noted: '%s'" % text)


# --- Prompt notes (fairy-chess-04, 06, 16) ----------------------------------

func _test_status_notes():
	gb.state = Rules.new_state()
	Rules.add_piece(gb.state, "King", "white", Vector2(2, 5))
	Rules.add_piece(gb.state, "Rook", "black", Vector2(2, 0))
	Rules.add_piece(gb.state, "King", "black", Vector2(5, 0))
	var notes = gb._status_notes("white")
	check("Your King is under attack" in notes and "can be blocked" in notes, "a royal in check is named and explained: '%s'" % notes)
	check(not "quiet turn" in notes, "no adjudication warning far from the limit: '%s'" % notes)
	gb.state.no_progress = Rules.NO_PROGRESS_LIMIT - 4
	notes = gb._status_notes("white")
	check("4 quiet turns left" in notes and "decided on material (White " in notes, "the no-progress clock warns with both scores: '%s'" % notes)

	gb.state = Rules.new_state()
	_kings()
	Rules.add_piece(gb.state, "Valkyrie", "white", Vector2(4, 4))
	var bkn = Rules.add_piece(gb.state, "Knight", "black", Vector2(3, 2))
	_resolve_and_summarise({bkn.id: {"action": "move", "target": Vector2(4, 4)}})
	notes = gb._status_notes("white")
	check("Your Valkyrie returns when this turn resolves, on the square she stood on before the turn she fell" in notes,
		"a phased-out Valkyrie's return is announced: '%s'" % notes)


# --- Selection and the chooser (fairy-chess-05, 07, 09, 20) -----------------

func _click(grid: Vector2) -> void:
	var ev = InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = grid * display.TILE_SIZE + Vector2(50, 50)
	display._gui_input(ev)


func _picker_labels() -> Array:
	var labels = []
	for child in ui.choice_picker._grid.get_children():
		labels.append(child.text)
	return labels


func _test_selection_and_chooser():
	_clear_board()
	var king = _spawn("King", "white", Vector2(0, 5))
	var elephant = _spawn("Elephant Rider", "white", Vector2(1, 5))
	var own_pawn = _spawn("Pawn", "white", Vector2(1, 3))
	var cannonier = _spawn("Cannonier", "white", Vector2(3, 5))
	_spawn("King", "black", Vector2(5, 0))
	var picker = ui.choice_picker

	# Clicking another of your pieces asks, with "Select" first.
	display.select_piece(king, false)
	_click(Vector2(1, 5))
	var labels = _picker_labels()
	check(picker.visible and labels.size() >= 2 and labels[0] == "Select Elephant Rider",
		"clicking your own piece offers to select it first: %s" % [labels])
	check(gb.white_pending == null, "and no conditional move was declared")
	picker._on_button_pressed(0)
	check(display.selected_piece == elephant and not display.previewing and gb.white_pending == null,
		"choosing Select selects that piece and gives no order")

	# An Elephant charge onto your own piece asks too.
	_click(Vector2(1, 3))
	labels = _picker_labels()
	check(picker.visible and labels.size() == 2 and labels[0] == "Select Pawn" and labels[1] == "Charge (tramples your Pawn)",
		"a charge onto your own piece asks first: %s" % [labels])
	check(gb.white_pending == null, "and does not trample at once")

	# The chooser backs out on Cancel, on a click outside, and on Esc.
	var cancels = [0]
	picker.cancelled.connect(func(): cancels[0] += 1)
	var cancel_button = null
	for node in picker.find_children("*", "Button", true, false):
		if node.text == "Cancel (Esc)":
			cancel_button = node
	check(cancel_button != null, "the chooser has a Cancel (Esc) button")
	if cancel_button != null:
		cancel_button.pressed.emit()
	check(not picker.visible and cancels[0] == 1 and display._picker_mode == "", "Cancel closes the chooser and clears its state")
	picker.cancel()
	check(cancels[0] == 1, "cancelling a closed chooser does nothing")

	# Clicking a selected Cannonier again asks rather than firing.
	display.select_piece(cannonier, false)
	_click(Vector2(3, 5))
	labels = _picker_labels()
	check(picker.visible and labels == ["Fire cannon"] and gb.white_pending == null,
		"re-clicking the Cannonier opens the chooser instead of firing: %s" % [labels])
	var outside = InputEventMouseButton.new()
	outside.button_index = MOUSE_BUTTON_LEFT
	outside.pressed = true
	picker._on_dim_input(outside)
	check(not picker.visible and cancels[0] == 2 and gb.white_pending == null, "a click outside the chooser backs out")
	var wheel = InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	display._open_action_picker(display._actions_for_square(cannonier.grid_position))
	picker._on_dim_input(wheel)
	check(picker.visible, "a stray wheel scroll does not close the chooser")
	picker.cancel()
	display.clear_selection()


# --- Markers and hover text (fairy-chess-07, 08, 21, 22) --------------------

func _find(actions: Array, pred: Callable):
	for action in actions:
		if pred.call(action):
			return action
	return null


func _test_markers_and_tooltips():
	_clear_board()
	var elephant = _spawn("Elephant Rider", "white", Vector2(1, 5))
	_spawn("Pawn", "white", Vector2(1, 3))
	var cannonier = _spawn("Cannonier", "white", Vector2(3, 5))
	_spawn("Pawn", "white", Vector2(3, 2))
	var dragon = _spawn("Dragonrider", "white", Vector2(5, 5))
	_spawn("King", "black", Vector2(5, 0))

	display.select_piece(elephant, false)
	var charge = _find(display.valid_actions_to_show, func(a): return a.get("is_charge", false))
	check(charge != null and charge.get("friendly_fire", false), "a charge onto your own piece is flagged as friendly fire")
	if charge != null:
		check(display._action_label(charge) == "Charge (tramples your Pawn)", "and labelled as trampling it")
		check(display._action_tooltip(charge).begins_with("Charge: tramples whatever stands on this square"), "and explained")

	display.select_piece(cannonier, false)
	var fire = _find(display.valid_actions_to_show, func(a): return a.action == "fire_cannon")
	check(fire != null and fire.own_hits == 1 and fire.friendly_fire, "the cannon counts your own piece in its column")
	if fire != null:
		check("(1 of yours there now)" in display._action_tooltip(fire), "and its tooltip says so")
	display._update_hover_tooltip(cannonier.grid_position)
	check(display.tooltip_text.begins_with("Cannon: destroys every piece in the column ahead"),
		"hovering the cannon marker explains it: '%s'" % display.tooltip_text)

	display.select_piece(dragon, false)
	var breaths = display._all_actions.filter(func(a): return a.action == "dragon_breath")
	check(breaths.size() == 2, "a cornered Dragonrider only offers the two breaths that face the board (%d)" % breaths.size())
	check(breaths.all(func(a): return Rules.is_valid_square(dragon.grid_position + a.direction)), "every breath marker is on the board")
	var burn = _find(breaths, func(a): return a.direction == Vector2(0, -1))
	if burn != null:
		check("of yours there now" in display._action_tooltip(burn), "a breath tooltip counts your pieces in the cone")

	# En passant: a black pawn has just double-stepped from (1, 1) past (1, 2).
	_clear_board()
	var pawn = _spawn("Pawn", "white", Vector2(0, 3))
	var passer = _spawn("Pawn", "black", Vector2(1, 3))
	_spawn("King", "white", Vector2(5, 5))
	_spawn("King", "black", Vector2(5, 0))
	gb.state.ep_targets = {Vector2(1, 2): passer.state_id}
	display.select_piece(pawn, false)
	var ep = _find(display.valid_actions_to_show, func(a): return a.get("is_en_passant", false))
	check(ep != null and ep.get("is_capture_hint", false), "an en passant move gets the capture tint")
	if ep != null:
		check(display._action_label(ep) == "Capture en passant", "and its own label")
		check(display._action_tooltip(ep).begins_with("En passant:"), "and a tooltip")
	display.clear_selection()


# --- Self-driven and stone pieces (fairy-chess-15) ---------------------------

func _test_zombie_factory_and_stone():
	_clear_board()
	var zombie = _spawn("Zombie", "white", Vector2(4, 4))
	var factory = _spawn("Factory", "white", Vector2(2, 5))
	var rook = _spawn("Rook", "white", Vector2(0, 5))
	_spawn("King", "white", Vector2(5, 5))
	_spawn("King", "black", Vector2(5, 0))
	check(not display._controllable(zombie) and not display._controllable(factory), "Zombies and Factories take no orders")
	var predicted = zombie.get_valid_actions()
	check(predicted.size() == 1 and predicted[0].target == Vector2(4, 3), "a Zombie's preview shows the move it will make (%s)" % [predicted])
	_click(Vector2(4, 4))
	check(display.selected_piece == zombie and display.previewing, "clicking a Zombie opens a read-only preview")
	display._update_hover_tooltip(Vector2(4, 4))
	check("acts on its own every turn" in display.tooltip_text.replace("\n", " "), "hovering it explains it: '%s'" % display.tooltip_text)
	check("never moves" in display._self_tooltip(factory), "a Factory explains itself")
	rook.is_petrified = true
	check(display._self_tooltip(rook).begins_with("Turned to stone"), "a stone piece explains itself")
	rook.is_petrified = false
	display.clear_selection()


# --- Last turn outlined (fairy-chess-19) -------------------------------------

func _test_last_turn_marks():
	_clear_board()
	var pawn = _spawn("Pawn", "white", Vector2(0, 4))
	var rifle = _spawn("Rifleman", "white", Vector2(3, 5))
	var cannonier = _spawn("Cannonier", "white", Vector2(4, 5))
	_spawn("King", "white", Vector2(5, 5))
	_spawn("King", "black", Vector2(5, 0))
	gb._apply_events([
		{"type": "shot", "shooter": rifle.state_id, "victim": -1, "pos": Vector2(3, 1)},
		{"type": "shot_missed", "shooter": cannonier.state_id, "color": "white"},
		{"type": "move", "id": pawn.state_id, "to": Vector2(0, 3)},
	])
	var marks = display.highlight_layer.last_turn_marks
	check({"attack": Vector2(3, 5), "hit": Vector2(3, 1)} in marks, "a shot outlines the shooter and the square hit (%s)" % [marks])
	check({"attack": Vector2(4, 5)} in marks, "a miss outlines the shooter")
	check({"from": Vector2(0, 4), "to": Vector2(0, 3)} in marks, "a move outlines where it came from and went")


# --- Rules text and royal changes (R2 I12) ----------------------------------

func _test_rules_text_and_royalty():
	_clear_board()
	_spawn("Rook", "black", Vector2(2, 0))
	var bishop = _spawn("Bishop", "white", Vector2(0, 5))
	var king = _spawn("King", "white", Vector2(5, 5))
	_spawn("Pawn", "white", Vector2(4, 5))
	_spawn("King", "black", Vector2(5, 0))
	display.clear_selection()
	display._update_hover_tooltip(Vector2(2, 0))
	var tip = display.tooltip_text.replace("\n", " ")
	check(tip.begins_with("Black's Rook") and Rules.PIECE_DESC["Rook"] in tip,
		"hovering an enemy piece with nothing selected describes it: '%s'" % tip)
	check(Array(display.tooltip_text.split("\n")).all(func(line): return line.length() <= 56), "board hover text is wrapped")
	bishop.is_petrified = true
	display._update_hover_tooltip(Vector2(0, 5))
	tip = display.tooltip_text.replace("\n", " ")
	check(tip.begins_with("Your Bishop") and "Turned to stone" in tip, "a stone piece's hover gives its status: '%s'" % tip)
	bishop.is_petrified = false
	# A marker's own explanation still wins over the piece standing under it.
	display.select_piece(king, false)
	display._update_hover_tooltip(Vector2(4, 5))
	check(display.tooltip_text.begins_with("Conditional move:"), "a marker's tooltip beats the piece description: '%s'" % display.tooltip_text)
	display.clear_selection()

	# Crowning a peasant names the new royal.
	gb.state = Rules.new_state()
	_kings()
	var lady = Rules.add_piece(gb.state, "Lady of the Lake", "white", Vector2(2, 5))
	Rules.add_piece(gb.state, "Pawn", "white", Vector2(2, 4))
	var text = _resolve_and_summarise({lady.id: {"action": "promote", "target": Vector2(2, 4), "promote_to": "King"}})
	check("your Pawn was promoted to King (a new royal)" in text, "crowning a peasant says it is a new royal: '%s'" % text)


# --- Game over (fairy-chess-03) ----------------------------------------------

func _test_game_over_reason():
	gb.state = Rules.new_state()
	Rules.add_piece(gb.state, "King", "white", Vector2(2, 5))
	var stone = Rules.add_piece(gb.state, "King", "black", Vector2(5, 0))
	stone.petrified = true
	var reason = gb._outcome_reason()
	check(reason == "Black has no royal left standing (turned to stone).", "a stoned last royal is named: '%s'" % reason)
	gb.state = Rules.new_state()
	Rules.add_piece(gb.state, "King", "white", Vector2(2, 5))
	Rules.add_piece(gb.state, "King", "black", Vector2(5, 0))
	Rules.add_piece(gb.state, "Rook", "black", Vector2(4, 0))
	reason = gb._outcome_reason()
	check(reason.begins_with("%d turns without progress: decided on material, White " % Rules.NO_PROGRESS_LIMIT),
		"a material verdict gives both scores: '%s'" % reason)

	gb.last_turn_summary = "Last turn: your King was taken by a Rook."
	gb.end_game("Black Wins!", "White has no royal left standing.")
	check(ui.game_over_label.text == "Black Wins!", "the title stays short: '%s'" % ui.game_over_label.text)
	check(ui._game_over_reason.visible and ui._game_over_reason.text == "White has no royal left standing.",
		"the reason sits under the title: '%s'" % ui._game_over_reason.text)
	check("White has no royal left standing." in ui.player_turn_label.text and "your King was taken by a Rook" in ui.player_turn_label.text,
		"the HUD keeps the reason and the final turn's summary: '%s'" % ui.player_turn_label.text)
