# ai_controller.gd
# Black's computer opponent.
#
# Setup: places pieces automatically (peasants first, royal last, with a
# centre bias) whenever it is black's turn to place.
#
# Play: simultaneous turns mean there is no "opponent's last move" to respond
# to, so the AI builds a small payoff matrix instead: it takes its top K
# candidate actions and the opponent's top K candidate actions (ranked by a
# cheap static score), simulates every pairing through Rules.resolve, and
# picks the action with the best blend of average and worst-case outcome.
# A repetition penalty keeps it from shuffling forever.

extends Node

const MY_CANDIDATES = 12
const OPP_CANDIDATES = 10
const WORST_CASE_WEIGHT = 0.55 # 1.0 = pure paranoia, 0.0 = pure optimism
const REPETITION_PENALTY = 0.35

@onready var game_board = get_node("../GameBoard")
@onready var display = get_node("../UI/CenterContainer/VBoxContainer/HBoxContainer/ChessboardDisplay")

var _placing = false
var _thinking = false
var _recent_actions = [] # signatures of recent declarations (anti-shuffle)


func _ready():
	game_board.setup_state_changed.connect(_on_setup_state_changed)


# =========================================================================
# Setup phase
# =========================================================================

func _on_setup_state_changed():
	if not game_board.ai_enabled or game_board.game_phase != "setup":
		return
	if game_board.setup_placer != "black" or _placing:
		return
	if _black_setup_complete():
		return
	_placing = true
	await get_tree().create_timer(0.35).timeout
	_placing = false
	if not game_board.ai_enabled or game_board.game_phase != "setup" or game_board.setup_placer != "black":
		return
	_place_one_piece()


func _black_setup_complete() -> bool:
	var counts = game_board.black_placed_pieces
	return counts.peasant >= game_board.MAX_PEASANTS and counts.non_peasant >= game_board.MAX_NON_PEASANTS


func _place_one_piece():
	var profile = game_board.black_profile
	var counts = game_board.black_placed_pieces
	# Peasants first, then nobles, royal last (this also satisfies the
	# reserve-a-royal-slot rule automatically).
	var bucket = ""
	if counts.peasant < game_board.MAX_PEASANTS:
		bucket = "peasants"
	elif counts.non_peasant < game_board.MAX_NON_PEASANTS - 1 and _bucket_total(profile, "nobles") > 0:
		bucket = "nobles"
	elif counts.royal == 0 and _bucket_total(profile, "royals") > 0:
		bucket = "royals"
	elif _bucket_total(profile, "nobles") > 0:
		bucket = "nobles"
	else:
		bucket = "royals"

	var choices = []
	for piece_type in profile[bucket]:
		if int(profile[bucket][piece_type]) > 0 and PlayerDatabase.PIECE_DEFINITIONS.has(piece_type):
			choices.append(piece_type)
	if choices.is_empty():
		push_warning("AI has no pieces left to place in bucket " + bucket)
		return
	var piece_type = choices[randi() % choices.size()]

	var row = 1 if bucket == "peasants" else 0
	var col_preference = [2, 3, 1, 4, 0, 5]
	if bucket == "royals":
		col_preference = [3, 2, 4, 1, 5, 0]
	var grid_pos = Vector2(-1, -1)
	for col in col_preference:
		if game_board.board[col][row] == null:
			grid_pos = Vector2(col, row)
			break
	if grid_pos == Vector2(-1, -1):
		push_warning("AI found no empty square on row %d" % row)
		return

	var def = PlayerDatabase.PIECE_DEFINITIONS[piece_type]
	display.place_piece_on_board({
		"piece_type": piece_type,
		"color": "black",
		"is_peasant": def.category == "peasant",
		"is_royal": def.category == "royal",
		"category": def.category,
		"scene_path": def.scene,
	}, grid_pos)


func _bucket_total(profile, bucket) -> int:
	var total = 0
	for piece_type in profile[bucket]:
		total += int(profile[bucket][piece_type])
	return total


# =========================================================================
# Playing phase
# =========================================================================

func request_move():
	if _thinking or game_board.game_phase != "playing":
		return
	_thinking = true
	# A short beat so the AI feels like it is thinking (and the player's own
	# move tween has time to be perceived).
	await get_tree().create_timer(0.5).timeout
	_thinking = false
	if game_board.game_phase != "playing" or game_board.black_pending != null:
		return
	var choice = _choose_action(game_board.state)
	if choice == null:
		game_board.declare_side_action("black", {"action": "pass"})
	else:
		_remember(choice)
		game_board.declare_side_action("black", choice.action, choice.piece_id)


func _choose_action(state):
	var mine = Rules.legal_actions(state, "black")
	if mine.is_empty():
		return null
	var theirs = Rules.legal_actions(state, "white")

	var my_top = _top_candidates(state, mine, "black", MY_CANDIDATES)
	var opp_top = _top_candidates(state, theirs, "white", OPP_CANDIDATES)
	if opp_top.is_empty():
		opp_top = [null] # opponent can only pass

	var best = null
	var best_score = -INF
	for entry in my_top:
		var total = 0.0
		var worst = INF
		for opp_entry in opp_top:
			var declared = {}
			_add_to_declared(declared, entry, "black")
			if opp_entry != null:
				_add_to_declared(declared, opp_entry, "white")
			var res = Rules.resolve(state, declared)
			var v = Rules.evaluate(res.state, "black")
			total += v
			worst = min(worst, v)
		var avg = total / opp_top.size()
		var score = (1.0 - WORST_CASE_WEIGHT) * avg + WORST_CASE_WEIGHT * worst
		score += randf() * 0.05
		if _signature(entry) in _recent_actions:
			score -= REPETITION_PENALTY
		if score > best_score:
			best_score = score
			best = entry
	return best


func _add_to_declared(declared, entry, color):
	if entry.action.get("action", "") == "spawn":
		declared[-2 if color == "black" else -1] = entry.action
	else:
		declared[entry.piece_id] = entry.action


# Cheap static ranking used to prune the candidate lists before simulating.
func _top_candidates(state, entries, color, k):
	var scored = []
	for entry in entries:
		scored.append([_static_score(state, entry, color), entry])
	scored.sort_custom(func(a, b): return a[0] > b[0])
	var out = []
	for i in range(min(k, scored.size())):
		out.append(scored[i][1])
	return out


func _static_score(state, entry, color) -> float:
	var action = entry.action
	var score = randf() * 0.1
	match action.get("action", ""):
		"move":
			var occ = Rules.piece_at(state, action.target)
			if occ != null and occ.color != color:
				score += Rules.PIECE_INFO.get(occ.type, {"value": 2.0}).value
				if occ.royal:
					score += 50.0
			if action.get("is_en_passant", false):
				score += 1.0
			# A backfill only pays off if the blocker actually dies, so keep
			# these from crowding out real moves during pruning; the payoff
			# simulation still surfaces one when it genuinely wins a trade.
			if action.get("is_conditional", false):
				score -= 0.6
			# Nudge toward the enemy royal.
			var piece = Rules.find_piece(state, entry.piece_id)
			if piece != null:
				var enemy_royal = _nearest_enemy_royal(state, color, action.target)
				if enemy_royal != null:
					var before = _chebyshev(piece.pos, enemy_royal.pos)
					var after = _chebyshev(action.target, enemy_royal.pos)
					score += 0.1 * (before - after)
		"shoot":
			var occ = Rules.piece_at(state, action.target)
			if occ != null:
				var v = Rules.PIECE_INFO.get(occ.type, {"value": 2.0}).value
				if occ.color == color:
					score -= v + 1.0 # do not casually shoot our own line
				else:
					score += v + 0.5
					if occ.royal:
						score += 50.0
		"promote":
			score += 3.0 + Rules.PIECE_INFO.get(action.get("promote_to", "Valkyrie"), {"value": 2.0}).value
		"convert":
			var occ = Rules.piece_at(state, action.target)
			if occ != null:
				score += 2.0 * Rules.PIECE_INFO.get(occ.type, {"value": 2.0}).value
		"fire_cannon":
			score += _aoe_estimate(state, entry, color, "cannon")
		"dragon_breath":
			score += _aoe_estimate(state, entry, color, "breath")
		"spawn":
			score += 0.5
	return score


func _aoe_estimate(state, entry, color, kind) -> float:
	var piece = Rules.find_piece(state, entry.piece_id)
	if piece == null:
		return 0.0
	var value = 0.0
	var squares = []
	if kind == "cannon":
		var fwd = Rules.forward_dir(color)
		for i in range(1, Rules.BOARD_SIZE):
			squares.append(piece.pos + Vector2(0, i * fwd))
	else:
		var dir = entry.action.direction
		if dir == Vector2.UP:
			squares = [Vector2(-1, -2), Vector2(0, -2), Vector2(1, -2), Vector2(0, -1)]
		elif dir == Vector2.DOWN:
			squares = [Vector2(-1, 2), Vector2(0, 2), Vector2(1, 2), Vector2(0, 1)]
		elif dir == Vector2.LEFT:
			squares = [Vector2(-2, -1), Vector2(-2, 0), Vector2(-2, 1), Vector2(-1, 0)]
		else:
			squares = [Vector2(2, -1), Vector2(2, 0), Vector2(2, 1), Vector2(1, 0)]
		var offset_squares = []
		for s in squares:
			offset_squares.append(piece.pos + s)
		squares = offset_squares
	for pos in squares:
		var occ = Rules.piece_at(state, pos)
		if occ == null:
			continue
		var v = Rules.PIECE_INFO.get(occ.type, {"value": 2.0}).value
		if occ.royal:
			v += 50.0
		value += v if occ.color != color else -v
	return value


func _nearest_enemy_royal(state, color, from_pos):
	var best = null
	var best_d = 999.0
	for p in Rules.all_pieces(state):
		if p.color == color or not p.royal or p.petrified:
			continue
		var d = _chebyshev(from_pos, p.pos)
		if d < best_d:
			best_d = d
			best = p
	return best


func _chebyshev(a: Vector2, b: Vector2) -> float:
	return max(abs(a.x - b.x), abs(a.y - b.y))


func _signature(entry) -> String:
	return "%d:%s:%s" % [entry.piece_id, entry.action.get("action", ""), str(entry.action.get("target", entry.action.get("direction", "")))]


func _remember(entry):
	_recent_actions.append(_signature(entry))
	if _recent_actions.size() > 4:
		_recent_actions.pop_front()
