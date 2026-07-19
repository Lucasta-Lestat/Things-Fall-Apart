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


# Autoload singletons are NOT compile-time identifiers in a fresh `--script`
# compile, so fetch PlayerDatabase from the tree at runtime instead.
func _pdb():
	return root.get_node("/root/PlayerDatabase")


func _initialize():
	var scene = load("res://fairy_chess.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene # so restart_game (reload_current_scene) works
	await process_frame
	await process_frame

	var gb = root.get_node("FairyChess/GameBoard")
	var ui = root.get_node("FairyChess/UI")
	var display = root.get_node("FairyChess/UI/CenterContainer/VBoxContainer/HBoxContainer/ChessboardDisplay")

	# --- Roster / profile validation (autoloads are live in the scene tree) --
	_validate_roster()

	# The scene opens in "pregame" with the champion picker up. Verify it, then
	# skip it: lock in the sandbox army for white (so the fixed placement plan
	# below has every piece) via the same path the picker uses.
	if gb.game_phase != "pregame":
		fail("scene did not open in pregame phase (was %s)" % gb.game_phase)
	if not ui.profile_picker.visible:
		fail("profile picker was not shown at pregame")

	# --- Profile picker mechanics ---
	var pp = ui.profile_picker
	var r = _pdb().get_roster()
	if pp._grid.get_child_count() != r.size():
		fail("picker grid has %d buttons, expected %d" % [pp._grid.get_child_count(), r.size()])
	pp._on_portrait_pressed(r[0].id) # fills White, active -> Black
	pp._on_portrait_pressed(r[1].id) # fills Black
	if pp._white_id != r[0].id or pp._black_id != r[1].id:
		fail("picker portrait clicks did not fill both slots (%s / %s)" % [pp._white_id, pp._black_id])
	if not pp.confirmed.is_connected(ui._on_profiles_confirmed):
		fail("picker 'confirmed' signal is not wired to the UI")

	# Skip the picker for the placement test: lock in the sandbox army for white
	# (so the fixed placement plan below has every piece) via the same
	# begin_setup path the picker's Start button drives.
	ui.profile_picker.cancel()
	gb.begin_setup("god", gb.DEFAULT_BLACK_ID, true)
	if gb.game_phase != "setup":
		fail("begin_setup did not enter setup phase")

	# --- Setup undo: place one piece, let the AI answer, then undo ----------
	var pawn_def = _pdb().PIECE_DEFINITIONS["Pawn"]
	var pawns_before = int(gb.white_profile.peasants.get("Pawn", 0))
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
	if int(gb.white_profile.peasants.get("Pawn", 0)) != pawns_before:
		fail("undo did not refund the pawn (%s, expected %d)" % [gb.white_profile.peasants.get("Pawn", 0), pawns_before])

	# --- Setup phase: white places, AI answers ------------------------------
	# Distinct types: the sandbox profile stocks one of every piece.
	var white_plan = [
		["Pawn", true], ["Kulak", true], ["Basic Automata", true], ["Cultist", true],
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
		var def = _pdb().PIECE_DEFINITIONS[piece_type]
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
		elif new_gb.game_phase != "pregame":
			fail("restarted game not in pregame phase")
		elif not Rules.all_pieces(new_gb.state).is_empty():
			fail("restarted game has leftover pieces")
		elif int(new_gb.white_profile.peasants.get("Pawn", 0)) < 1:
			fail("restarted game has a depleted profile")

	print("")
	print("=== SMOKE: %d turns played, phase=%s, %d failures ===" % [turns_played, final_phase, failures])
	quit(1 if failures > 0 else 0)


func _validate_roster():
	var roster = _pdb().get_roster()
	if roster.size() < 90:
		fail("roster loaded only %d characters" % roster.size())
	if _pdb().get_profile("god") == null:
		fail("god sandbox profile missing")
	var protag = _pdb().get_profile("protagonist")
	if protag == null or protag.name != "Protagonist":
		fail("protagonist profile did not resolve by id")

	var valid_types = {}
	for t in _pdb().PIECE_DEFINITIONS.keys():
		valid_types[t] = true
	var illegal = []
	var bad_type = []
	var missing_portrait = []
	for entry in roster:
		var profile = _pdb().get_profile(entry.id)
		var peasants = _sum(profile.peasants)
		var non_peasants = _sum(profile.nobles) + _sum(profile.royals)
		var royals = _sum(profile.royals)
		if peasants < 4 or non_peasants < 4 or royals < 1:
			illegal.append(entry.id)
		for bucket in [profile.peasants, profile.nobles, profile.royals]:
			for t in bucket:
				if not valid_types.has(t):
					bad_type.append("%s:%s" % [entry.id, t])
		if entry.portrait != "" and not ResourceLoader.exists(entry.portrait):
			missing_portrait.append(entry.id)
	if not illegal.is_empty():
		fail("placement-illegal rosters: %s" % str(illegal.slice(0, 5)))
	if not bad_type.is_empty():
		fail("unknown piece types: %s" % str(bad_type.slice(0, 5)))
	if not missing_portrait.is_empty():
		fail("unimportable portraits: %s" % str(missing_portrait.slice(0, 8)))
	print("ROSTER OK: %d characters, all armies legal, portraits importable" % roster.size())
	_validate_piece_assets()


# Every registered piece must have a loadable scene and art for both sides,
# otherwise it explodes the first time someone actually fields it.
func _validate_piece_assets():
	var missing_scene = []
	var missing_art = []
	var missing_rules = []
	for piece_type in _pdb().PIECE_DEFINITIONS:
		var def = _pdb().PIECE_DEFINITIONS[piece_type]
		if not ResourceLoader.exists(def.scene):
			missing_scene.append(piece_type)
		for color in ["white", "black"]:
			if not ResourceLoader.exists("res://assets/icons/%s_%s.png" % [piece_type, color]):
				missing_art.append("%s_%s" % [piece_type, color])
		if not Rules.PIECE_INFO.has(piece_type):
			missing_rules.append(piece_type)
		elif Rules.PIECE_INFO[piece_type].category != def.category:
			missing_rules.append("%s (category mismatch)" % piece_type)
	if not missing_scene.is_empty():
		fail("pieces with no scene: %s" % str(missing_scene))
	if not missing_art.is_empty():
		fail("pieces with no art: %s" % str(missing_art))
	if not missing_rules.is_empty():
		fail("pieces missing/mismatched in Rules.PIECE_INFO: %s" % str(missing_rules))
	print("ASSETS OK: %d piece types have scene + art + rules" % _pdb().PIECE_DEFINITIONS.size())

	# The sandbox profile must stock EVERY piece, including newly added ones.
	var god = _pdb().get_profile("god")
	var stocked = {}
	for bucket in [god.peasants, god.nobles, god.royals]:
		for t in bucket:
			stocked[t] = true
	var absent = []
	for piece_type in _pdb().PIECE_DEFINITIONS:
		if not stocked.has(piece_type):
			absent.append(piece_type)
	if not absent.is_empty():
		fail("god profile is missing pieces: %s" % str(absent))
	else:
		print("GOD OK: sandbox profile stocks all %d piece types" % stocked.size())


func _sum(d: Dictionary) -> int:
	var total = 0
	for k in d:
		total += int(d[k])
	return total
