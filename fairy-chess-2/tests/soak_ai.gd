# tests/soak_ai.gd
# AI-vs-AI soak test at the rules level: plays full games with randomised
# armies using a compact version of the AI's payoff-matrix policy, and checks
# that every game terminates cleanly (win, loss, draw or adjudication) within
# the hard turn limit.
# Run with:
#   Godot_v4.6-stable_win64_console.exe --headless --path fairy-chess-2 --script res://tests/soak_ai.gd
extends SceneTree

const GAMES = 12
const MY_K = 8
const OPP_K = 5

var failures = 0


func _initialize():
	var outcomes = {"white": 0, "black": 0, "draw": 0}
	var total_turns = 0
	var max_turns = 0
	for i in range(GAMES):
		seed(20260716 + i * 7919)
		var result = _play_game()
		if result.outcome == "":
			failures += 1
			print("SOAK FAIL: game %d did not terminate (turns=%d)" % [i, result.turns])
			continue
		outcomes[result.outcome] += 1
		total_turns += result.turns
		max_turns = max(max_turns, result.turns)
	print("")
	print("=== SOAK: %d games | white %d / black %d / draw %d | avg turns %.1f | max %d | %d failures ===" % [
		GAMES, outcomes.white, outcomes.black, outcomes.draw,
		float(total_turns) / max(1, GAMES - failures), max_turns, failures])
	quit(1 if failures > 0 else 0)


func _play_game() -> Dictionary:
	var state = _random_setup()
	while true:
		var white_entry = _choose(state, "white")
		var black_entry = _choose(state, "black")
		var declared = {}
		if white_entry != null:
			_add(declared, white_entry, "white")
		if black_entry != null:
			_add(declared, black_entry, "black")
		var res = Rules.resolve(state, declared)
		state = res.state
		if res.outcome != "":
			return {"outcome": res.outcome, "turns": state.turn}
		if state.turn > Rules.HARD_TURN_LIMIT + 5:
			return {"outcome": "", "turns": state.turn}
	return {"outcome": "", "turns": -1}


func _random_setup() -> Dictionary:
	var state = Rules.new_state()
	var peasant_types = []
	var noble_types = []
	var royal_types = []
	for type in Rules.PIECE_INFO:
		match Rules.PIECE_INFO[type].category:
			"peasant":
				# Wolf-form-only werewolves cannot be placed directly.
				peasant_types.append(type)
			"noble":
				if type != "Werewolf (wolf form)":
					noble_types.append(type)
			"royal":
				royal_types.append(type)
	# Register a full roster for both sides. Real games always have armies
	# registered, and promotion expands over them -- a bare state would leave
	# the AI exercising only the 8-entry fallback list.
	var whole_roster = []
	for type in Rules.PIECE_INFO:
		whole_roster.append(type)
	Rules.set_army(state, "white", whole_roster)
	Rules.set_army(state, "black", whole_roster)

	for color in ["white", "black"]:
		var cols = [0, 1, 2, 3, 4, 5]
		cols.shuffle()
		for i in range(4):
			Rules.add_piece(state, peasant_types[randi() % peasant_types.size()], color, Vector2(cols[i], Rules.peasant_row(color)))
		cols.shuffle()
		for i in range(3):
			Rules.add_piece(state, noble_types[randi() % noble_types.size()], color, Vector2(cols[i], Rules.back_row(color)))
		Rules.add_piece(state, royal_types[randi() % royal_types.size()], color, Vector2(cols[3], Rules.back_row(color)))
	return state


func _add(declared, entry, color):
	if entry.action.get("action", "") == "spawn":
		declared[-2 if color == "black" else -1] = entry.action
	else:
		declared[entry.piece_id] = entry.action


func _choose(state, color):
	var mine = Rules.legal_actions(state, color)
	if mine.is_empty():
		return null
	var opp = "black" if color == "white" else "white"
	var theirs = Rules.legal_actions(state, opp)
	var my_top = _top(state, mine, color, MY_K)
	var opp_top = _top(state, theirs, opp, OPP_K)
	if opp_top.is_empty():
		opp_top = [null]
	var best = null
	var best_score = -INF
	for entry in my_top:
		var total = 0.0
		var worst = INF
		for opp_entry in opp_top:
			var declared = {}
			_add(declared, entry, color)
			if opp_entry != null:
				_add(declared, opp_entry, opp)
			var res = Rules.resolve(state, declared)
			var v = Rules.evaluate(res.state, color)
			total += v
			worst = min(worst, v)
		var score = 0.45 * (total / opp_top.size()) + 0.55 * worst + randf() * 0.1
		if score > best_score:
			best_score = score
			best = entry
	return best


func _top(state, entries, color, k):
	var scored = []
	for entry in entries:
		var s = randf() * 0.1
		var action = entry.action
		if action.get("action", "") in ["move", "shoot", "convert"] and action.has("target"):
			var occ = Rules.piece_at(state, action.target)
			if occ != null and occ.color != color:
				s += Rules.PIECE_INFO.get(occ.type, {"value": 2.0}).value
				if occ.royal:
					s += 50.0
		if action.get("action", "") == "promote":
			s += 3.0
		scored.append([s, entry])
	scored.sort_custom(func(a, b): return a[0] > b[0])
	var out = []
	for i in range(min(k, scored.size())):
		out.append(scored[i][1])
	return out
