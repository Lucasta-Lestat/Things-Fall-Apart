# tests/promotion_ui.gd
# Drives the real scene's promotion picker: places a white pawn one step from
# promotion, marches it onto the last rank, then exercises the picker exactly
# as the ChessboardDisplay would and checks the pawn becomes the chosen piece.
# Run with:
#   Godot_v4.6-stable_win64_console.exe --headless --path fairy-chess-2 --script res://tests/promotion_ui.gd
extends SceneTree

var failures = 0


func fail(msg: String) -> void:
	failures += 1
	print("PROMO FAIL: " + msg)


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

	var gb = root.get_node("FairyChess/GameBoard")
	var ui = root.get_node("FairyChess/UI")
	var display = root.get_node("FairyChess/UI/CenterContainer/VBoxContainer/HBoxContainer/ChessboardDisplay")

	# Verify the picker node resolved through the UI's @onready reference.
	if ui.choice_picker == null:
		fail("ui.choice_picker did not resolve")
		_done()
		return

	# Dismiss the pre-game champion picker; this test builds its own position.
	ui.profile_picker.cancel()
	gb.set_ai_enabled(false) # hotseat so we control both sides deterministically

	# Build a minimal legal position directly in the rules state, bypassing the
	# drag-drop setup: a white pawn at (2,1) about to promote, both kings.
	gb.state = Rules.new_state()
	gb.piece_nodes = {}
	# Register a distinctive army so this exercises the real path: the picker
	# must offer THESE pieces, not the curated fallback list.
	Rules.set_army(gb.state, "white", ["Pawn", "Devil Toad", "Rifleman", "Gorgon", "King"])
	var wk = _spawn(gb, display, "King", "white", Vector2(0, 5))
	var bk = _spawn(gb, display, "King", "black", Vector2(5, 0))
	var pawn = _spawn(gb, display, "Pawn", "white", Vector2(2, 1))
	var pawn_id = pawn.state_id # capture: the pawn node is freed when it promotes
	gb._sync_board_nodes()
	gb.game_phase = "playing"
	await process_frame

	# Turn 1: white pawn steps (2,1)->(2,0); black king shuffles.
	gb.declare_side_action("white", {"action": "move", "target": Vector2(2, 0)}, pawn.state_id)
	gb.declare_side_action("black", {"action": "move", "target": Vector2(5, 1)}, bk.state_id)
	await _settle()

	var pawn_state = Rules.find_piece(gb.state, pawn_id)
	if pawn_state == null or pawn_state.pos != Vector2(2, 0):
		fail("pawn did not reach the last rank (pos=%s)" % [pawn_state.pos if pawn_state else "gone"])
		_done()
		return

	# Select the pawn: its only action should be the self-promotion.
	display.select_piece(pawn)
	var has_self_promo = false
	for a in display.valid_actions_to_show:
		if a.action == "promote" and a.target == pawn.grid_position:
			has_self_promo = true
	if not has_self_promo:
		fail("selected last-rank pawn has no self-promotion action")

	# Simulate clicking the pawn's own square: opens the picker.
	display._open_promotion_picker(pawn)
	await process_frame
	if not ui.choice_picker.visible:
		fail("promotion picker did not become visible")
	var buttons = 0
	for child in ui.choice_picker._grid.get_children():
		buttons += 1
	# Compare against the same call the picker makes, so this keeps working once
	# the choices come from a registered army rather than the fixed list.
	var expected = Rules.promotion_choices(gb.state, "white", "Pawn").size()
	if buttons != expected:
		fail("picker shows %d buttons, expected %d" % [buttons, expected])

	# The registered army has no Queen, so the picker must not offer one --
	# this is what proves the choices follow the army and not the fixed list.
	var labels = []
	for child in ui.choice_picker._grid.get_children():
		labels.append(child.text)
	if "Queen" in labels:
		fail("picker offered a Queen, which is not in this side's army: %s" % [labels])
	if not ("Gorgon" in labels and "Devil Toad" in labels):
		fail("picker did not offer the army's own pieces: %s" % [labels])

	# Choose "Gorgon" by pressing its button, exactly as a real click would
	# (the button handler hides the picker and emits `picked`).
	var gorgon_button = null
	for child in ui.choice_picker._grid.get_children():
		if child.text == "Gorgon":
			gorgon_button = child
	if gorgon_button == null:
		fail("no Gorgon button in the picker")
		_done()
		return
	gorgon_button.pressed.emit()
	await process_frame
	if ui.choice_picker.visible:
		fail("picker stayed visible after a choice")

	# White has now declared its promotion; give black a move so the turn resolves.
	gb.declare_side_action("black", {"action": "move", "target": Vector2(5, 0)}, bk.state_id)
	await _settle()

	var promoted = Rules.find_piece(gb.state, pawn_id)
	if promoted == null:
		fail("promoted piece vanished")
	elif promoted.type != "Gorgon":
		fail("pawn promoted to %s, expected Gorgon" % promoted.type)
	elif promoted.royal:
		fail("promoted Gorgon wrongly royal")
	# The display node should have been swapped to a Queen too.
	var node = gb.piece_nodes.get(pawn_id)
	if node == null:
		fail("no display node for promoted piece")
	elif node.piece_type != "Gorgon":
		fail("display node still shows %s" % node.piece_type)

	_done()


func _spawn(gb, display, type, color, pos):
	var def = _pdb().PIECE_DEFINITIONS[type]
	var node = load(def.scene).instantiate()
	display.add_child(node)
	node.setup_piece(type, color, def.category == "royal", 100)
	node.grid_position = pos
	node.position = pos * 100 + Vector2(50, 50)
	var piece = Rules.add_piece(gb.state, type, color, pos)
	node.state_id = piece.id
	gb.piece_nodes[piece.id] = node
	return node


func _settle():
	for i in range(40):
		await process_frame
		if gb_idle():
			return


var gb_ref = null
func gb_idle() -> bool:
	var gb = root.get_node_or_null("FairyChess/GameBoard")
	return gb != null and gb.white_pending == null and gb.black_pending == null


func _done():
	print("")
	print("=== PROMO UI: %d failures ===" % failures)
	quit(1 if failures > 0 else 0)
