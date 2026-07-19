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
	emit_signal("setup_state_changed")


# =========================================================================
# Playing phase: declaring actions
# =========================================================================

# Actions available to a piece node (queried by the display layer).
func get_actions_for_node(piece_node) -> Array:
	var piece = Rules.find_piece(state, piece_node.state_id)
	if piece == null:
		return []
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
			emit_signal("turn_info_changed", prompt)
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
				emit_signal("turn_info_changed", "Black to move.")
			return
	if white_pending != null and black_pending != null:
		call_deferred("resolve_turn")


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
		match result.outcome:
			"white":
				end_game("White Wins!")
			"black":
				end_game("Black Wins!")
			_:
				end_game("Draw")
		return
	_prompt_next()


# A short plain-language account of what the turn actually did. Simultaneous
# resolution can quietly swallow an order -- a mark killed before the spy could
# turn it, a move bounced off a blocker -- and without a word the player just
# sees a piece vanish.
func _summarise(events: Array) -> String:
	var captured = 0
	var notes = []
	for event in events:
		match event.type:
			"capture":
				captured += 1
			"convert_failed":
				if event.get("reason", "") == "target_destroyed":
					notes.append("conversion failed: the target was killed this turn")
				else:
					notes.append("conversion failed: no valid target")
			"blocked":
				notes.append("a move was blocked and bounced back")
			"spawn_failed":
				notes.append("a reinforcement had nowhere to land")
			"petrify":
				notes.append("a piece was turned to stone")
			"phase_out":
				notes.append("a Valkyrie left the field")
			"return":
				notes.append("a Valkyrie returned")
			"convert":
				notes.append("a piece changed sides")
			"credit":
				notes.append("a fallen Viking will return")
	var parts = []
	if captured > 0:
		parts.append("%d piece%s lost" % [captured, "" if captured == 1 else "s"])
	# De-duplicate so a busy turn doesn't produce a wall of identical clauses.
	var seen = {}
	for note in notes:
		if not seen.has(note):
			seen[note] = true
			parts.append(note)
	return "" if parts.is_empty() else "Last turn: " + ", ".join(parts) + "."


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
					node.grid_position = event.to
					if not replaced.has(event.id):
						moves[node] = event.to
					_play_once(played, "move")
			"shot":
				_play_once(played, "shoot")
			"cannon":
				_play_once(played, "cannon")
			"breath":
				_play_once(played, "cannon")
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

func end_game(outcome_text: String):
	audio_manager.play_sfx("win")
	audio_manager.stop_music()
	game_phase = "game_over"
	emit_signal("game_state_changed", "game_over")
	emit_signal("turn_info_changed", outcome_text)
	emit_signal("game_ended", outcome_text)


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
