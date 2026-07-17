# tests/smoke_scene.gd
# End-to-end smoke test: loads the real game scene headless, places white's
# pieces programmatically while the AI places black's, starts the game, and
# plays random-ish white moves against the AI for a number of turns.
# Run with:
#   Godot_v4.6-stable_win64_console.exe --headless --path fairy-chess-2 --script res://tests/smoke_scene.gd
extends SceneTree

var failures = 0


func fail(msg: String) -> void:
	failures += 1
	print("SMOKE FAIL: " + msg)


func _initialize():
	var scene = load("res://fairy_chess.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene # so restart_game (reload_current_scene) works
	await process_frame
	await process_frame

	var gb = root.get_node("FairyChess/GameBoard")
	var display = root.get_node("FairyChess/UI/CenterContainer/VBoxContainer/HBoxContainer/ChessboardDisplay")

	# --- Setup undo: place one piece, let the AI answer, then undo ----------
	var pawn_def = PlayerDatabase.PIECE_DEFINITIONS["Pawn"]
	display.place_piece_on_board({
		"piece_type": "Pawn", "color": "white", "is_peasant": true,
		"is_royal": false, "category": "peasant", "scene_path": pawn_def.scene,
	}, Vector2(0, 4))
	await create_timer(1.2).timeout # AI places its answer
	gb.undo_last_placement()
	await process_frame
	if gb.white_placed_pieces.peasant != 0 or gb.black_placed_pieces.peasant + gb.black_placed_pieces.non_peasant != 0:
		fail("undo did not roll back both placements: %s / %s" % [gb.white_placed_pieces, gb.black_placed_pieces])
	if gb.setup_placer != "white":
		fail("undo did not return the turn to white")
	if not Rules.all_pieces(gb.state).is_empty():
		fail("undo left pieces in the rules state")
	if int(gb.white_profile.peasants.Pawn) != 2:
		fail("undo did not refund the pawn (count=%s)" % gb.white_profile.peasants.Pawn)

	# --- Setup phase: white places, AI answers ------------------------------
	var white_plan = [
		["Pawn", true], ["Kulak", true], ["Pawn", true], ["Kulak", true],
		["Queen", false], ["Rook", false], ["Rifleman", false], ["King", false],
	]
	var peasant_col = 0
	var noble_col = 0
	for entry in white_plan:
		# Wait for our placement turn (the AI interleaves).
		var waited = 0.0
		while gb.setup_placer != "white" and waited < 10.0:
			await create_timer(0.1).timeout
			waited += 0.1
		if gb.setup_placer != "white":
			fail("timed out waiting for white's setup turn")
			break
		var piece_type = entry[0]
		var is_peasant = entry[1]
		var def = PlayerDatabase.PIECE_DEFINITIONS[piece_type]
		var pos = Vector2(peasant_col, 4) if is_peasant else Vector2(noble_col, 5)
		if is_peasant:
			peasant_col += 1
		else:
			noble_col += 1
		display.place_piece_on_board({
			"piece_type": piece_type,
			"color": "white",
			"is_peasant": is_peasant,
			"is_royal": def.category == "royal",
			"category": def.category,
			"scene_path": def.scene,
		}, pos)
		await process_frame

	# Wait for the AI to finish its 8 placements.
	var waited = 0.0
	while waited < 15.0:
		var counts = gb.black_placed_pieces
		if counts.peasant >= gb.MAX_PEASANTS and counts.non_peasant >= gb.MAX_NON_PEASANTS:
			break
		await create_timer(0.2).timeout
		waited += 0.2
	if gb.black_placed_pieces.non_peasant < gb.MAX_NON_PEASANTS:
		fail("AI did not finish setup: " + str(gb.black_placed_pieces))
	if gb.black_placed_pieces.royal < 1:
		fail("AI placed no royal")
	if Rules.all_pieces(gb.state).size() != 16:
		fail("expected 16 pieces after setup, got %d" % Rules.all_pieces(gb.state).size())

	# --- Play ----------------------------------------------------------------
	gb.start_game()
	await process_frame
	if gb.game_phase != "playing":
		fail("game did not start")

	var turns_played = 0
	var stuck = 0.0
	while gb.game_phase == "playing" and turns_played < 20 and stuck < 20.0:
		var before_turn = gb.state.turn
		if gb.white_pending == null:
			var acts = Rules.legal_actions(gb.state, "white")
			if acts.is_empty():
				# Engine should auto-pass; just wait.
				pass
			else:
				var entry = acts[randi() % acts.size()]
				gb.declare_side_action("white", entry.action, entry.piece_id)
		# Wait for the AI + resolution.
		var waited_turn = 0.0
		while gb.game_phase == "playing" and gb.state.turn == before_turn and waited_turn < 8.0:
			await create_timer(0.1).timeout
			waited_turn += 0.1
		if gb.state.turn > before_turn:
			turns_played += 1
			stuck = 0.0
		else:
			stuck += waited_turn
	if turns_played == 0 and gb.game_phase == "playing":
		fail("no turns resolved")
	if gb.game_phase == "playing" and stuck >= 20.0:
		fail("game stalled while playing (turn %d)" % gb.state.turn)

	# Consistency: every state piece has a live node on the board grid.
	for piece in Rules.all_pieces(gb.state):
		var node = gb.piece_nodes.get(piece.id)
		if node == null:
			fail("state piece %s has no node" % piece.type)
		elif node.grid_position != piece.pos:
			fail("node/state desync for %s: %s vs %s" % [piece.type, node.grid_position, piece.pos])

	# --- Restart flow ---------------------------------------------------------
	# (capture results first: restart frees gb)
	var final_phase = gb.game_phase
	if gb.game_phase == "game_over":
		var old_gb_id = gb.get_instance_id()
		gb.restart_game()
		await process_frame
		await process_frame
		await process_frame
		var new_gb = root.get_node_or_null("FairyChess/GameBoard")
		if new_gb == null:
			fail("scene did not reload after restart")
		elif new_gb.get_instance_id() == old_gb_id:
			fail("restart did not create a fresh scene")
		elif new_gb.game_phase != "setup":
			fail("restarted game not in setup phase")
		elif not Rules.all_pieces(new_gb.state).is_empty():
			fail("restarted game has leftover pieces")
		elif int(new_gb.white_profile.peasants.Pawn) != 2:
			fail("restarted game has a depleted profile")

	print("")
	print("=== SMOKE: %d turns played, phase=%s, %d failures ===" % [turns_played, final_phase, failures])
	quit(1 if failures > 0 else 0)
