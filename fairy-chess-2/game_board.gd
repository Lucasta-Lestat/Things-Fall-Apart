# game_board.gd
# Scene-side adapter for the fairy chess minigame. All game logic lives in
# rules.gd (pure data); this node owns the authoritative Rules state, maps
# state piece ids to display nodes, and translates resolution events into
# sfx / tweens / node lifecycle.

extends Node2D

# --- Signals ---
signal game_state_changed(new_state)
signal turn_resolved(moves) # {piece_node: Vector2 destination}
signal setup_state_changed()
signal turn_info_changed(message)
signal piece_spawned(piece_node, grid_pos)
signal spawn_credits_changed(white_credits, black_credits)
signal game_ended(outcome_text)
signal check_status_changed(threatened_ids) # royal state ids currently "in check"

@onready var audio_manager = get_node("../AudioManager")

# --- Constants ---
const BOARD_SIZE = 6
const MAX_PEASANTS = 4
const MAX_NON_PEASANTS = 4
const MAX_DEATH_CLAUSES = 4 # deaths named one by one in the summary before "and N more"
const ADJUDICATION_WARNING = 6 # turns before a material verdict at which the prompt warns

# --- Game State ---
var state = Rules.new_state() # authoritative rules state
var board = [] # 2D array of piece NODES, kept in sync for the display layer
var piece_nodes = {} # state id -> node
var phased_nodes = {} # state id -> node (Valkyries waiting to return)
var game_phase = "pregame" # "pregame", "setup", "playing", "game_over"
var white_pending = null # {"id": int, "action": Dictionary}
var black_pending = null
var ai_enabled = true
var last_turn_summary = "" # plain-language account of the previous resolution
# Squares the previous resolution touched, for the board to outline:
# [{"from": V2, "to": V2}] for moves, [{"attack": V2, ["hit": V2]}] for fire.
var last_turn_marks = []

# --- Setup State ---
var setup_placer = "white"
var white_placed_pieces = {"peasant": 0, "non_peasant": 0, "royal": 0}
var black_placed_pieces = {"peasant": 0, "non_peasant": 0, "royal": 0}
var placement_stack = [] # for right-click undo during setup
# Default match-up (the profile picker overrides these before setup). Deep-
# copied so a rematch or right-click undo mutates a private copy, not the
# shared roster entry.
const DEFAULT_WHITE_ID = "protagonist"
const DEFAULT_BLACK_ID = "bandit_chief"
var white_profile = _default_profile(DEFAULT_WHITE_ID)
var black_profile = _default_profile(DEFAULT_BLACK_ID)


static func _default_profile(id: String) -> Dictionary:
	var p = PlayerDatabase.get_profile(id)
	if p == null:
		p = PlayerDatabase.get_profile("god")
	return p.duplicate(true)


func _ready():
	board.resize(BOARD_SIZE)
	for x in range(BOARD_SIZE):
		board[x] = []
		board[x].resize(BOARD_SIZE)
		for y in range(BOARD_SIZE):
			board[x][y] = null
	emit_signal("game_state_changed", game_phase)
	emit_signal("turn_info_changed", "Choose your champions.")


func is_valid_square(pos) -> bool:
	return Rules.is_valid_square(pos)


# Called by the profile picker once both champions are chosen. Locks in the
# armies and opens the piece-placement (setup) phase.
func begin_setup(white_id: String, black_id: String, ai_on: bool) -> void:
	if game_phase != "pregame":
		return
	white_profile = _default_profile(white_id)
	black_profile = _default_profile(black_id)
	_register_armies()
	ai_enabled = ai_on
	game_phase = "setup"
	emit_signal("game_state_changed", "setup")
	emit_signal("turn_info_changed", "Place your pieces.")
	emit_signal("setup_state_changed")


# =========================================================================
# Setup phase
# =========================================================================

# Called by chessboard_display after it has instanced and placed the node.
func place_piece(piece_node, grid_pos, category := ""):
	var piece_type = piece_node.piece_type
	if category == "":
		category = Rules.PIECE_INFO.get(piece_type, {"category": "noble"}).category
	var piece = Rules.add_piece(state, piece_type, piece_node.color, grid_pos)
	piece_node.state_id = piece.id
	piece_nodes[piece.id] = piece_node
	board[int(grid_pos.x)][int(grid_pos.y)] = piece_node

	var counts = white_placed_pieces if setup_placer == "white" else black_placed_pieces
	if category == "peasant":
		counts.peasant += 1
	else:
		counts.non_peasant += 1
		if category == "royal":
			counts.royal += 1

	placement_stack.append({
		"id": piece.id,
		"piece_type": piece_type,
		"color": piece_node.color,
		"category": category,
		"placer": setup_placer,
	})
	setup_placer = "black" if setup_placer == "white" else "white"
	emit_signal("setup_state_changed")


# Right-click during setup: undo the most recent placement. In AI mode the
# AI's interleaved placements are rolled back too, so the player always
# undoes their own latest piece.
func undo_last_placement():
	if game_phase != "setup" or placement_stack.is_empty():
		return
	if not ai_enabled:
		_undo_one_placement()
		return
	# AI mode: keep undoing until the player's own most recent piece is gone.
	while not placement_stack.is_empty():
		var was_white = placement_stack.back().placer == "white"
		_undo_one_placement()
		if was_white:
			break


func _undo_one_placement():
	var entry = placement_stack.pop_back()
	var piece = Rules.find_piece(state, entry.id)
	if piece != null:
		state.board[int(piece.pos.x)][int(piece.pos.y)] = null
	var node = piece_nodes.get(entry.id)
	if node != null:
		board[int(node.grid_position.x)][int(node.grid_position.y)] = null
		node.queue_free()
		piece_nodes.erase(entry.id)
	# Restore the profile count so the icon reappears in the panel.
	var profile = white_profile if entry.color == "white" else black_profile
	var bucket = "nobles"
	if entry.category == "peasant":
		bucket = "peasants"
	elif entry.category == "royal":
		bucket = "royals"
	profile[bucket][entry.piece_type] = int(profile[bucket].get(entry.piece_type, 0)) + 1
	var counts = white_placed_pieces if entry.placer == "white" else black_placed_pieces
	if entry.category == "peasant":
		counts.peasant -= 1
	else:
		counts.non_peasant -= 1
		if entry.category == "royal":
			counts.royal -= 1
	setup_placer = entry.placer
	emit_signal("setup_state_changed")


func start_game():
	if game_phase != "setup":
		return
	audio_manager.play_music()
	game_phase = "playing"
	emit_signal("game_state_changed", game_phase)
	_emit_check_status()
	_prompt_next()


# Broadcasts which royals are currently in check (for the shudder indicator).
func _emit_check_status():
	emit_signal("check_status_changed", Rules.threatened_royals(state).keys())


func set_ai_enabled(enabled: bool):
	ai_enabled = enabled
	if game_phase == "setup":
		# Wake the AI placer / refresh the UI for the new mode.
		emit_signal("setup_state_changed")


# Called by the profile picker before setup begins. Ids index PlayerDatabase.
func set_profiles(white_id: String, black_id: String) -> void:
	if game_phase != "setup":
		return
	white_profile = _default_profile(white_id)
	black_profile = _default_profile(black_id)
	_register_armies()
	emit_signal("setup_state_changed")


# Tells the rules engine which piece types each side fields, so a promoting
# peasant is offered its own army's pieces rather than a fixed list.
func _register_armies() -> void:
	Rules.set_army(state, "white", _army_types(white_profile))
	Rules.set_army(state, "black", _army_types(black_profile))


func _army_types(profile: Dictionary) -> Array:
	var types = []
	for bucket in ["peasants", "nobles", "royals"]:
		for piece_type in profile.get(bucket, {}):
			types.append(piece_type)
	return types


# =========================================================================
# Playing phase: declaring actions
# =========================================================================

# Actions available to a piece node (queried by the display layer).
func get_actions_for_node(piece_node) -> Array:
	var piece = Rules.find_piece(state, piece_node.state_id)
	if piece == null:
		return []
	if "Automatic" in piece.traits:
		# Zombies can't be ordered, but show the move they will make on their
		# own (same pre-turn state resolve uses, so it is an exact prediction).
		var auto = Rules.automatic_action(state, piece)
		return [auto] if auto != null else []
	return Rules.get_actions(state, piece)


# Called by chessboard_display when the player picks an action for a piece.
func declare_action(piece_node, action_data):
	if game_phase != "playing":
		return
	if piece_node.color == "white":
		if white_pending == null:
			white_pending = {"id": piece_node.state_id, "action": action_data}
			_prompt_next()
	else:
		if black_pending == null and not ai_enabled:
			black_pending = {"id": piece_node.state_id, "action": action_data}
			_prompt_next()


# Called for spawn drops (no source node) and by the AI controller.
func declare_side_action(color: String, action: Dictionary, piece_id: int = -1):
	if game_phase != "playing":
		return
	if color == "white":
		if white_pending == null:
			white_pending = {"id": piece_id, "action": action}
			_prompt_next()
	else:
		if black_pending == null:
			black_pending = {"id": piece_id, "action": action}
			_prompt_next()


func spawn_credits(color: String) -> Dictionary:
	return state.credits[color]


# Drives the declare -> declare -> resolve loop, auto-passing stuck players.
func _prompt_next():
	if game_phase != "playing":
		return
	if white_pending == null:
		if Rules.legal_actions(state, "white").is_empty():
			white_pending = {"id": -1, "action": {"action": "pass"}}
			emit_signal("turn_info_changed", "White has no moves and passes.")
		else:
			var prompt = "White to move."
			if last_turn_summary != "":
				prompt = last_turn_summary + "   " + prompt
			emit_signal("turn_info_changed", prompt + _status_notes("white"))
			return
	if black_pending == null:
		if Rules.legal_actions(state, "black").is_empty():
			black_pending = {"id": -1, "action": {"action": "pass"}}
			emit_signal("turn_info_changed", "Black has no moves and passes.")
		else:
			var ai = get_node_or_null("../AIController") if ai_enabled else null
			if ai != null:
				emit_signal("turn_info_changed", "Black is thinking...")
				ai.request_move()
			else:
				emit_signal("turn_info_changed", "Black to move." + _status_notes("black"))
			return
	if white_pending != null and black_pending != null:
		call_deferred("resolve_turn")


# Standing warnings for the side about to declare: its royals under attack, a
# Valkyrie about to return, and the no-progress clock running out. Each starts
# with two spaces so it can be appended straight onto the prompt.
func _status_notes(color: String) -> String:
	var text = ""
	var royals = []
	for id in Rules.threatened_royals(state):
		var royal = Rules.find_piece(state, id)
		if royal != null and royal.color == color:
			royals.append(royal.type)
	if not royals.is_empty():
		text += "  %s %s %s under attack: an attack aimed at a piece kills it even if it moves away (only a Gorgon's gaze can be dodged). A slider or a rifle shot can be blocked by stepping a piece into its path (the blocker is lost)." \
			% [_owner(color, true), " and ".join(royals), "is" if royals.size() == 1 else "are"]
	for entry in state.phased_out:
		var when = "when this turn resolves" if entry.turns <= 1 else "in %d turns" % entry.turns
		# Rules.resolve keeps a fallen Valkyrie's pre-turn square, so she comes
		# back where she stood when the turn began, not where a move ended.
		text += "  %s Valkyrie returns %s, on the square she stood on before the turn she fell (or the nearest free one)." % [_owner(entry.piece.color, true), when]
	# Rules._outcome adjudicates once no_progress reaches the limit (or the
	# hard turn cap is hit) after a resolve, so "left" counts this turn too.
	var quiet_left = Rules.NO_PROGRESS_LIMIT - state.no_progress
	var turns_left = Rules.HARD_TURN_LIMIT - state.turn
	var material = "the game is decided on material (White %.1f, Black %.1f)." \
		% [Rules.material_value(state, "white"), Rules.material_value(state, "black")]
	if quiet_left <= ADJUDICATION_WARNING and quiet_left <= turns_left:
		text += "  %d quiet turn%s left: with no capture, promotion, conversion, petrification or new piece, %s" \
			% [quiet_left, "" if quiet_left == 1 else "s", material]
	elif turns_left <= ADJUDICATION_WARNING:
		text += "  %d turn%s left before the turn limit, then %s" % [turns_left, "" if turns_left == 1 else "s", material]
	return text


# Possessive for a side in player-facing text: "your" for the human's pieces
# against the AI, otherwise "White's" / "Black's".
func _owner(color: String, capital := false) -> String:
	if ai_enabled and color == "white":
		return "Your" if capital else "your"
	return color.capitalize() + "'s"


# =========================================================================
# Turn resolution
# =========================================================================

func resolve_turn():
	if game_phase != "playing":
		return
	if white_pending == null or black_pending == null:
		return
	var declared = {}
	_add_declared(declared, white_pending, -1)
	_add_declared(declared, black_pending, -2)
	white_pending = null
	black_pending = null

	var result = Rules.resolve(state, declared)
	state = result.state
	_apply_events(result.events)
	_sync_board_nodes()

	emit_signal("spawn_credits_changed", state.credits.white, state.credits.black)
	_emit_check_status()
	last_turn_summary = _summarise(result.events)

	if result.outcome != "":
		var reason = _outcome_reason()
		match result.outcome:
			"white":
				end_game("White Wins!", reason)
			"black":
				end_game("Black Wins!", reason)
			_:
				end_game("Draw", reason)
		return
	_prompt_next()


# Why the game just ended, read off the final state (mirrors Rules._outcome).
func _outcome_reason() -> String:
	var white_left = Rules.royal_count(state, "white")
	var black_left = Rules.royal_count(state, "black")
	if white_left == 0 and black_left == 0:
		return "Both sides lost their last royal."
	if black_left == 0:
		return "Black has no royal left standing%s." % (" (turned to stone)" if _royal_stoned("black") else "")
	if white_left == 0:
		return "White has no royal left standing%s." % (" (turned to stone)" if _royal_stoned("white") else "")
	var why = "Turn limit reached" if state.turn >= Rules.HARD_TURN_LIMIT \
		else "%d turns without progress" % Rules.NO_PROGRESS_LIMIT
	return "%s: decided on material, White %.1f vs Black %.1f." \
		% [why, Rules.material_value(state, "white"), Rules.material_value(state, "black")]


# A petrified royal still stands on the board but no longer counts as one.
func _royal_stoned(color: String) -> bool:
	for piece in Rules.all_pieces(state, color):
		if piece.royal and piece.petrified:
			return true
	return false


# A short plain-language account of what the turn actually did. Simultaneous
# resolution can quietly swallow an order -- a mark killed before the spy could
# turn it, a capture that lands on a piece that ran -- and without a word the
# player just sees a piece vanish. Reads `state`, which is already the
# post-resolution state when resolve_turn calls this.
func _summarise(events: Array) -> String:
	var deaths = {} # clause -> how many pieces it covers (insertion-ordered)
	var notes = []
	var hints = [] # rule explanations, appended once as full sentences
	for event in events:
		match event.type:
			"capture", "phase_out":
				var clause = _death_clause(event)
				if event.type == "phase_out":
					clause += " (she will return)"
				deaths[clause] = int(deaths.get(clause, 0)) + 1
				if event.get("cause", "") in ["struck", "trampled"] and event.get("fled", false):
					hints.append("A declared capture lands even if the target moves away.")
			"collision":
				hints.append("Stepping into a moving piece's path destroys both pieces.")
			"backfill":
				notes.append("a conditional move triggered and took the vacated square")
			"blocked":
				notes.append("a conditional move did not trigger (the square was not vacated), so the piece stayed put")
			"convert_failed":
				if event.get("reason", "") == "target_destroyed":
					notes.append("conversion failed: the target was killed this turn")
				else:
					notes.append("conversion failed: no valid target")
			"promote_failed":
				notes.append("promotion failed: the %s was killed this turn" % event.get("target_type", "piece"))
			"shot_missed":
				notes.append("%s shot found no target" % _owner(str(event.get("color", ""))))
			"spawn_failed":
				notes.append("a reinforcement had nowhere to land")
			"petrify":
				var stone = Rules.find_piece(state, event.id)
				if stone != null:
					notes.append("%s %s was turned to stone by a Gorgon" % [_owner(stone.color), stone.type])
				else:
					notes.append("a piece was turned to stone")
			"return":
				var valkyrie = Rules.find_piece(state, event.id)
				notes.append("%s Valkyrie returned" % (_owner(valkyrie.color) if valkyrie != null else "a"))
			"convert":
				var old_side = "black" if event.color == "white" else "white"
				notes.append("%s %s changed sides (now %s %s)" % [_owner(old_side), event.get("old_type", "piece"), _owner(event.color), event.new_type])
			"promote":
				notes.append("%s %s was promoted to %s" % [_owner(event.color), event.get("old_type", "piece"), event.new_type])
			"transform":
				var old_type = str(event.get("old_type", ""))
				if Rules.WEREWOLF_TOGGLE.has(old_type) and Rules.WEREWOLF_TOGGLE.has(event.new_type):
					# "Werewolf (wolf form)" -> "wolf form"
					notes.append("%s Werewolf shifted to %s" % [_owner(event.color), event.new_type.get_slice("(", 1).trim_suffix(")")])
				else:
					notes.append("%s Doppelganger took the form of %s" % [_owner(event.color), _a(event.new_type)])
			"spawn":
				if event.piece_type == "Basic Automata":
					notes.append("%s Factory built a Basic Automata" % _owner(event.color))
				else:
					notes.append("%s %s returned from reserves" % [_owner(event.color), event.piece_type])
			"credit":
				var row = "2nd row" if Rules.PIECE_INFO.get(event.piece_type, {}).get("category", "") == "peasant" else "back row"
				var how = ""
				if event.color == "white" or not ai_enabled:
					how = " (drag it from Reserves onto an empty square on the %s to bring it back; that uses the turn)" % row
				notes.append("a fallen %s joined %s reserves%s" % [event.piece_type, _owner(event.color), how])
			"move":
				# Reaching the far row does not promote by itself: promotion
				# is a separate order (zombies excepted -- they do it alone).
				# Only a human side is told how; the AI's peasant is just noted.
				var mover = Rules.find_piece(state, event.id)
				if mover != null and "Peasant" in mover.traits and not "Automatic" in mover.traits \
						and mover.pos.y == Rules._promotion_row(mover.color) \
						and not Rules.promotion_choices(state, mover.color, mover.type).is_empty():
					var how = ": select it and click it to promote (that uses a turn)"
					if mover.color == "black" and ai_enabled:
						how = " and can promote"
					notes.append("%s %s reached the far row%s" % [_owner(mover.color), mover.type, how])
	var parts = []
	# One clause per death; identical ones (a cannon raking two Pawns) merge.
	var lost = 0
	for clause in deaths:
		if parts.size() >= MAX_DEATH_CLAUSES:
			lost += deaths[clause]
			continue
		parts.append(clause if deaths[clause] == 1 else "%s (x%d)" % [clause, deaths[clause]])
	if lost > 0:
		parts.append("and %d more piece%s lost" % [lost, "" if lost == 1 else "s"])
	# De-duplicate so a busy turn doesn't produce a wall of identical clauses.
	var seen = {}
	for note in notes:
		if not seen.has(note):
			seen[note] = true
			parts.append(note)
	if parts.is_empty():
		return ""
	var text = "Last turn: " + "; ".join(parts) + "."
	for hint in hints:
		if not seen.has(hint):
			seen[hint] = true
			text += " " + hint
	return text


# "your Knight was taken by a Rook" -- why one piece died, from the cause
# Rules.resolve records on its capture / phase_out event.
func _death_clause(event: Dictionary) -> String:
	var who = "%s %s" % [_owner(str(event.get("color", ""))), event.get("piece_type", "piece")]
	var by = str(event.get("by_type", ""))
	match event.get("cause", ""):
		"struck":
			if event.get("fled", false):
				return "%s was struck by %s even though it moved away" % [who, _a(by)]
			return "%s was taken by %s" % [who, _a(by)]
		"trampled":
			if event.get("fled", false):
				return "%s was trampled by %s's charge even though it moved away" % [who, _a(by)]
			return "%s was trampled by %s's charge" % [who, _a(by)]
		"swap":
			return "%s died in a head-on clash with %s" % [who, _a(by)]
		"collision":
			return "%s was struck in transit when %s stepped into its path" % [who, _a(by)]
		"intercept":
			return "%s died stepping into the path of %s" % [who, _a(by)]
		"clash":
			return "%s collided with another piece arriving on the same square" % who
		"backfill":
			return "%s was cut down by %s's conditional move" % [who, _a(by)]
		"en_passant":
			return "%s was taken en passant by %s" % [who, _a(by)]
		"shot":
			return "%s was shot by %s" % [who, _a(by)]
		"cannon":
			return "%s was caught in %s's cannon fire" % [who, _a(by)]
		"breath":
			return "%s was burned by %s's breath" % [who, _a(by)]
	return "%s was lost" % who


# Piece type with its indefinite article: "a Rook", "an Elephant Rider".
func _a(piece_type: String) -> String:
	if piece_type == "":
		return "a piece"
	return ("an " if piece_type[0].to_lower() in "aeiou" else "a ") + piece_type


func _add_declared(declared: Dictionary, pending, spawn_key: int) -> void:
	if pending == null:
		return
	if pending.action.get("action", "") == "spawn":
		declared[spawn_key] = pending.action
	elif pending.id >= 0:
		declared[pending.id] = pending.action


func _apply_events(events: Array) -> void:
	var moves = {} # node -> destination (for tweening)
	var played = {} # dedupe sfx
	last_turn_marks = []
	# Pieces replaced later in this batch (promote/convert/transform) get a
	# fresh node at the final position, so don't tween the doomed old node.
	var replaced = {}
	for event in events:
		if event.type in ["promote", "convert", "transform"]:
			replaced[event.id] = true
	for event in events:
		match event.type:
			"capture":
				_play_once(played, "capture")
				var node = piece_nodes.get(event.id)
				if node != null:
					node.queue_free()
					piece_nodes.erase(event.id)
			"phase_out":
				_play_once(played, "capture")
				var node = piece_nodes.get(event.id)
				if node != null:
					if node.get_parent() != null:
						node.get_parent().remove_child(node)
					phased_nodes[event.id] = node
					piece_nodes.erase(event.id)
			"return":
				var node = phased_nodes.get(event.id)
				if node != null:
					phased_nodes.erase(event.id)
					piece_nodes[event.id] = node
					node.grid_position = event.pos
					emit_signal("piece_spawned", node, event.pos)
					_play_once(played, "spawn")
			"move":
				var node = piece_nodes.get(event.id)
				if node != null:
					last_turn_marks.append({"from": node.grid_position, "to": event.to})
					node.grid_position = event.to
					if not replaced.has(event.id):
						moves[node] = event.to
					_play_once(played, "move")
			"shot":
				# Fire events precede the captures, so shooter nodes still exist.
				_play_once(played, "shoot")
				if piece_nodes.has(event.shooter):
					var mark = {"attack": piece_nodes[event.shooter].grid_position}
					if event.has("pos"):
						mark["hit"] = event.pos
					last_turn_marks.append(mark)
			"shot_missed":
				_play_once(played, "shoot")
				if piece_nodes.has(event.shooter):
					last_turn_marks.append({"attack": piece_nodes[event.shooter].grid_position})
			"cannon", "breath":
				_play_once(played, "cannon")
				if piece_nodes.has(event.id):
					last_turn_marks.append({"attack": piece_nodes[event.id].grid_position})
			"promote", "convert", "transform":
				if event.type == "promote":
					_play_once(played, "promote")
				_replace_node(event.id, event.new_type, event.color, event.pos)
			"petrify":
				var node = piece_nodes.get(event.id)
				if node != null:
					node.is_petrified = true
					node.modulate = Color(0.55, 0.55, 0.65)
			"spawn":
				_play_once(played, "spawn")
				_create_node(event.id, event.piece_type, event.color, event.pos)
			"blocked":
				# Bounced mover: give a little shake so the player sees why
				# their piece stayed put.
				var node = piece_nodes.get(event.id)
				if node != null:
					var origin = node.position
					var tw = create_tween()
					tw.tween_property(node, "position", origin + Vector2(7, 0), 0.05)
					tw.tween_property(node, "position", origin - Vector2(7, 0), 0.08)
					tw.tween_property(node, "position", origin, 0.05)
			"credit", "spawn_failed":
				pass
	# Always emit (even with no moves) so the display can clear stale
	# selections after every resolution.
	emit_signal("turn_resolved", moves)


func _play_once(played: Dictionary, sfx: String) -> void:
	if not played.has(sfx):
		played[sfx] = true
		audio_manager.play_sfx(sfx)


func _create_node(id: int, piece_type: String, color: String, pos) -> void:
	var def = PlayerDatabase.PIECE_DEFINITIONS.get(piece_type)
	if def == null:
		push_warning("No scene registered for piece type: " + piece_type)
		return
	var node = load(def.scene).instantiate()
	node.add_to_group("pieces")
	node.state_id = id
	node.grid_position = pos
	piece_nodes[id] = node
	emit_signal("piece_spawned", node, pos)
	node.setup_piece(piece_type, color, Rules.PIECE_INFO.get(piece_type, {"category": "noble"}).category == "royal", 100)


func _replace_node(id: int, new_type: String, color: String, pos) -> void:
	var old_node = piece_nodes.get(id)
	if old_node != null:
		old_node.queue_free()
		piece_nodes.erase(id)
	_create_node(id, new_type, color, pos)


# Rebuild the node grid from the authoritative state.
func _sync_board_nodes() -> void:
	for x in range(BOARD_SIZE):
		for y in range(BOARD_SIZE):
			board[x][y] = null
	for piece in Rules.all_pieces(state):
		var node = piece_nodes.get(piece.id)
		if node != null:
			node.grid_position = piece.pos
			board[int(piece.pos.x)][int(piece.pos.y)] = node


# =========================================================================
# Game over
# =========================================================================

# reason: why it ended (see _outcome_reason). The HUD line also keeps the final
# turn's summary, which would otherwise never be shown.
func end_game(outcome_text: String, reason: String = ""):
	audio_manager.play_sfx("win")
	audio_manager.stop_music()
	game_phase = "game_over"
	emit_signal("game_state_changed", "game_over")
	var info = outcome_text
	if reason != "":
		info += "  " + reason
	if last_turn_summary != "":
		info += "  " + last_turn_summary
	emit_signal("turn_info_changed", info)
	# Title and reason travel together; the game-over panel splits them at "\n".
	emit_signal("game_ended", outcome_text if reason == "" else outcome_text + "\n" + reason)


func restart_game():
	get_tree().reload_current_scene()


func _exit_tree():
	# Phased-out Valkyrie nodes live outside the scene tree; free them so a
	# restart or game exit does not leak them.
	for id in phased_nodes:
		var node = phased_nodes[id]
		if is_instance_valid(node):
			node.queue_free()
	phased_nodes.clear()
