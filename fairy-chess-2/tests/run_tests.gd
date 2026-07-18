# tests/run_tests.gd
# Headless test suite for the fairy chess rules engine.
# Run with:
#   Godot_v4.6-stable_win64_console.exe --headless --path fairy-chess-2 --script res://tests/run_tests.gd
extends SceneTree

var checks = 0
var failures = 0


func _initialize():
	test_pawn_movegen()
	test_kulak_movegen()
	test_automata_movegen()
	test_monk_movegen()
	test_sliders_and_leapers()
	test_nightrider()
	test_grasshopper()
	test_rifleman()
	test_cannonier()
	test_dragonrider()
	test_elephant_rider()
	test_gorgon_movegen()
	test_anarch()
	test_devil_toad()
	test_werewolf_wolf_movegen()
	test_cultist()
	test_adjacent_promoters()
	test_basic_move_and_capture()
	test_swap_mutual_capture()
	test_multi_arrival()
	test_path_collision_kills_both()
	test_collision_denies_the_blow()
	test_committed_capture_catches_fleeing_piece()
	test_committed_capture_catches_automatic_zombie()
	test_backfill_avenges_the_queen()
	test_backfill_does_not_resolve_while_blocked()
	test_conditional_moves_are_offered()
	test_chancellor_promotes_peasants()
	test_promotion_beats_conditional_move()
	test_alternatives_are_kept_for_the_chooser()
	test_viking_valhalla()
	test_factory()
	test_praetor()
	test_doppelganger()
	test_berserker()
	test_chieftain()
	test_spymaster()
	test_shot_still_catches_a_fleeing_victim()
	test_shot_is_intercepted_and_friendly_fire()
	test_cannon_friendly_fire()
	test_dragon_breath()
	test_en_passant()
	test_promotion_royal_status()
	test_conversion()
	test_werewolf_toggle()
	test_valkyrie_phase_out_and_return()
	test_zombie_automatic()
	test_valhalla_credit()
	test_petrify()
	test_win_conditions()
	test_no_progress_adjudication()
	test_spawn()
	test_legal_actions()
	test_leaper_paths_unblockable()
	test_kulak_ep_not_shadowed()
	test_rifleman_shot_first()
	test_gorgon_standoff()
	test_petrified_valkyrie_shatters()
	test_ep_not_registered_for_the_dead()
	test_promotion_picker_choices()
	test_threatened_royals()

	print("")
	print("=== %d checks, %d failures ===" % [checks, failures])
	quit(1 if failures > 0 else 0)


func check(cond: bool, name: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		print("FAIL: " + name)


func targets(actions: Array, kind: String = "move") -> Array:
	var out = []
	for a in actions:
		if a.action == kind and a.has("target"):
			out.append(a.target)
	return out


func has_action(actions: Array, kind: String) -> bool:
	for a in actions:
		if a.action == kind:
			return true
	return false


func alive_types(state: Dictionary, color: String) -> Array:
	var out = []
	for p in Rules.all_pieces(state, color):
		out.append(p.type)
	out.sort()
	return out


# ==========================================================================
# Movegen
# ==========================================================================

func test_pawn_movegen():
	var st = Rules.new_state()
	var pawn = Rules.add_piece(st, "Pawn", "white", Vector2(2, 4))
	var acts = Rules.get_actions(st, pawn)
	var t = targets(acts)
	check(Vector2(2, 3) in t, "pawn single step")
	check(Vector2(2, 2) in t, "pawn double step from start row")
	check(t.size() == 2, "pawn has exactly 2 moves on empty board")
	# Captures
	Rules.add_piece(st, "Rook", "black", Vector2(1, 3))
	Rules.add_piece(st, "Rook", "white", Vector2(3, 3))
	acts = Rules.get_actions(st, pawn)
	t = targets(acts)
	check(Vector2(1, 3) in t, "pawn captures diagonally")
	check(not Vector2(3, 3) in t, "pawn cannot capture friendly")
	# Promotion action offered on the last row
	var st2 = Rules.new_state()
	var promo_pawn = Rules.add_piece(st2, "Pawn", "white", Vector2(0, 0))
	check(has_action(Rules.get_actions(st2, promo_pawn), "promote"), "pawn offers promotion on last row")


func test_kulak_movegen():
	var st = Rules.new_state()
	var kulak = Rules.add_piece(st, "Kulak", "white", Vector2(2, 4))
	Rules.add_piece(st, "Pawn", "black", Vector2(2, 3))
	var acts = Rules.get_actions(st, kulak)
	var t = targets(acts)
	check(Vector2(1, 3) in t and Vector2(3, 3) in t, "kulak diagonal moves")
	check(Vector2(0, 2) in t and Vector2(4, 2) in t, "kulak diagonal double from start row")
	check(Vector2(2, 3) in t, "kulak captures straight ahead")


func test_automata_movegen():
	var st = Rules.new_state()
	var bot = Rules.add_piece(st, "Basic Automata", "white", Vector2(2, 4))
	var t = targets(Rules.get_actions(st, bot))
	check(Vector2(2, 3) in t and Vector2(2, 2) in t and Vector2(2, 1) in t, "automata 1/2/3 forward from start")
	Rules.add_piece(st, "Pawn", "black", Vector2(0, 2))
	Rules.add_piece(st, "Pawn", "black", Vector2(4, 2))
	Rules.add_piece(st, "Pawn", "white", Vector2(3, 3))
	t = targets(Rules.get_actions(st, bot))
	check(Vector2(0, 2) in t, "automata range-2 diagonal capture")
	check(not Vector2(4, 2) in t, "automata capture blocked by friendly on the way")


func test_monk_movegen():
	var st = Rules.new_state()
	var monk = Rules.add_piece(st, "Monk", "white", Vector2(2, 5))
	var t = targets(Rules.get_actions(st, monk))
	check(Vector2(2, 4) in t and Vector2(2, 3) in t, "monk forward + double from back row")
	check(Vector2(0, 3) in t and Vector2(5, 2) in t, "monk bishop slides")


func test_sliders_and_leapers():
	var st = Rules.new_state()
	var rook = Rules.add_piece(st, "Rook", "white", Vector2(2, 2))
	check(targets(Rules.get_actions(st, rook)).size() == 10, "rook has 10 moves from (2,2)")
	var st2 = Rules.new_state()
	var knight = Rules.add_piece(st2, "Knight", "white", Vector2(2, 2))
	check(targets(Rules.get_actions(st2, knight)).size() == 8, "knight has 8 moves from (2,2)")
	var st3 = Rules.new_state()
	var queen = Rules.add_piece(st3, "Queen", "white", Vector2(0, 0))
	check(targets(Rules.get_actions(st3, queen)).size() == 15, "queen has 15 moves from corner")
	var st4 = Rules.new_state()
	var valk = Rules.add_piece(st4, "Valkyrie", "white", Vector2(2, 2))
	check(targets(Rules.get_actions(st4, valk)).size() == 27, "valkyrie = queen + knight moves")


func test_nightrider():
	var st = Rules.new_state()
	var nr = Rules.add_piece(st, "Nightrider", "white", Vector2(0, 0))
	var t = targets(Rules.get_actions(st, nr))
	check(Vector2(2, 4) in t, "nightrider extends knight line")
	Rules.add_piece(st, "Pawn", "white", Vector2(1, 2))
	var acts = Rules.get_actions(st, nr)
	t = targets(acts)
	check(not Vector2(2, 4) in t, "nightrider cannot leap past a friendly on its line")
	var onto_friendly = null
	for a in acts:
		if a.action == "move" and a.target == Vector2(1, 2):
			onto_friendly = a
	check(onto_friendly != null and onto_friendly.get("is_conditional", false),
		"the friendly's own square is offered only as a conditional backfill")
	var path = Rules.move_path("Nightrider", Vector2(0, 0), Vector2(2, 4))
	check(path == [Vector2(1, 2)], "nightrider path = intermediate landings")


func test_grasshopper():
	var st = Rules.new_state()
	var gh = Rules.add_piece(st, "Grasshopper", "white", Vector2(2, 2))
	check(targets(Rules.get_actions(st, gh)).is_empty(), "grasshopper needs a hurdle")
	Rules.add_piece(st, "Pawn", "black", Vector2(2, 4))
	var t = targets(Rules.get_actions(st, gh))
	check(t == [Vector2(2, 5)], "grasshopper lands just past the hurdle")


func test_rifleman():
	var st = Rules.new_state()
	var rifle = Rules.add_piece(st, "Rifleman", "white", Vector2(2, 2))
	Rules.add_piece(st, "Pawn", "black", Vector2(2, 5))
	Rules.add_piece(st, "Pawn", "white", Vector2(2, 0))
	Rules.add_piece(st, "Pawn", "black", Vector2(5, 2))
	var acts = Rules.get_actions(st, rifle)
	var shots = targets(acts, "shoot")
	# A rifleman aims a DIRECTION, so it can fire down any of the four lines --
	# including one occupied by a friendly (flagged as friendly fire).
	check(Vector2(2, 5) in shots, "rifleman fires down the file")
	check(Vector2(5, 2) in shots, "rifleman fires across the rank")
	check(Vector2(2, 0) in shots, "rifleman may fire into its own piece")
	var ff = null
	for a in acts:
		if a.action == "shoot" and a.target == Vector2(2, 0):
			ff = a
	check(ff != null and ff.get("friendly_fire", false), "line onto a friendly is flagged as friendly fire")
	var free_line = null
	for a in acts:
		if a.action == "shoot" and a.direction == Vector2(-1, 0):
			free_line = a
	check(free_line != null and not free_line.get("friendly_fire", false), "empty line is not friendly fire")


func test_cannonier():
	var st = Rules.new_state()
	var can = Rules.add_piece(st, "Cannonier", "white", Vector2(3, 4))
	var acts = Rules.get_actions(st, can)
	check(has_action(acts, "fire_cannon"), "cannonier can always fire")
	check(Vector2(3, 3) in targets(acts), "cannonier walks forward")


func test_dragonrider():
	var st = Rules.new_state()
	var dr = Rules.add_piece(st, "Dragonrider", "white", Vector2(0, 5))
	var acts = Rules.get_actions(st, dr)
	check(Vector2(4, 4) in targets(acts) and Vector2(1, 1) in targets(acts), "dragonrider (4,1) leaps")
	var breaths = 0
	for a in acts:
		if a.action == "dragon_breath":
			breaths += 1
	check(breaths == 4, "dragonrider has 4 breath directions")


func test_elephant_rider():
	var st = Rules.new_state()
	var el = Rules.add_piece(st, "Elephant Rider", "white", Vector2(2, 4))
	var charge_found = false
	for a in Rules.get_actions(st, el):
		if a.action == "move" and a.get("is_charge", false):
			charge_found = a.target == Vector2(2, 2)
	check(charge_found, "elephant rider charges 2 forward")


func test_gorgon_movegen():
	var st = Rules.new_state()
	var gorgon = Rules.add_piece(st, "Gorgon", "white", Vector2(2, 2))
	Rules.add_piece(st, "Pawn", "white", Vector2(2, 3))
	Rules.add_piece(st, "Pawn", "black", Vector2(3, 3))
	var gorgon_acts = Rules.get_actions(st, gorgon)
	var t = targets(gorgon_acts)
	var onto_friend = null
	for a in gorgon_acts:
		if a.action == "move" and a.target == Vector2(2, 3):
			onto_friend = a
	check(onto_friend != null and onto_friend.get("is_conditional", false),
		"gorgon's friendly square is only a conditional backfill")
	check(Vector2(3, 3) in t, "gorgon can move onto enemy")


func test_anarch():
	var st = Rules.new_state()
	var anarch = Rules.add_piece(st, "Anarch", "white", Vector2(0, 5))
	Rules.add_piece(st, "King", "black", Vector2(4, 1))
	var t = targets(Rules.get_actions(st, anarch))
	check(Vector2(4, 2) in t and Vector2(3, 0) in t, "anarch teleports next to enemy royal")


func test_devil_toad():
	var st = Rules.new_state()
	var toad = Rules.add_piece(st, "Devil Toad", "white", Vector2(0, 0))
	var t = targets(Rules.get_actions(st, toad))
	check(Vector2(5, 5) in t, "devil toad slides the long diagonal")
	check(t.size() > 5, "devil toad bounces off edges")


func test_werewolf_wolf_movegen():
	var st = Rules.new_state()
	var wolf = Rules.add_piece(st, "Werewolf (wolf form)", "white", Vector2(2, 2))
	var t = targets(Rules.get_actions(st, wolf))
	check(Vector2(4, 4) in t and Vector2(2, 4) in t and Vector2(3, 4) in t, "wolf reaches 2-step ring")
	check(not Vector2(2, 2) in t, "wolf cannot stand still")
	for i in range(t.size()):
		for j in range(i + 1, t.size()):
			if t[i] == t[j]:
				check(false, "wolf has duplicate targets")
				return


func test_cultist():
	var st = Rules.new_state()
	var cultist = Rules.add_piece(st, "Cultist", "white", Vector2(2, 2))
	Rules.add_piece(st, "Pawn", "black", Vector2(3, 2))
	Rules.add_piece(st, "Rook", "black", Vector2(1, 2))
	var acts = Rules.get_actions(st, cultist)
	var converts = targets(acts, "convert")
	check(Vector2(3, 2) in converts, "cultist converts adjacent enemy peasant")
	check(not Vector2(1, 2) in converts, "cultist cannot convert non-peasants")


func test_adjacent_promoters():
	var st = Rules.new_state()
	var lady = Rules.add_piece(st, "Lady of the Lake", "white", Vector2(2, 5))
	Rules.add_piece(st, "Pawn", "white", Vector2(2, 4))
	var acts = Rules.get_actions(st, lady)
	var found = false
	for a in acts:
		if a.action == "promote" and a.target == Vector2(2, 4) and a.promote_to == "King":
			found = true
	check(found, "lady of the lake promotes adjacent pawn to King")
	var st2 = Rules.new_state()
	var pont = Rules.add_piece(st2, "Pontifex", "white", Vector2(2, 5))
	Rules.add_piece(st2, "Cultist", "white", Vector2(3, 5))
	var found2 = false
	for a in Rules.get_actions(st2, pont):
		if a.action == "promote" and a.target == Vector2(3, 5) and a.promote_to == "Bishop":
			found2 = true
	check(found2, "pontifex promotes any adjacent peasant to Bishop")


# ==========================================================================
# Resolution
# ==========================================================================

func test_basic_move_and_capture():
	var st = Rules.new_state()
	var rook = Rules.add_piece(st, "Rook", "white", Vector2(0, 0))
	var victim = Rules.add_piece(st, "Pawn", "black", Vector2(0, 4))
	var res = Rules.resolve(st, {rook.id: {"action": "move", "target": Vector2(0, 4)}})
	var new_rook = Rules.find_piece(res.state, rook.id)
	check(new_rook != null and new_rook.pos == Vector2(0, 4), "rook moved")
	check(Rules.find_piece(res.state, victim.id) == null, "stationary victim captured")


func test_swap_mutual_capture():
	var st = Rules.new_state()
	var a = Rules.add_piece(st, "Rook", "white", Vector2(0, 0))
	var b = Rules.add_piece(st, "Rook", "black", Vector2(0, 5))
	var res = Rules.resolve(st, {
		a.id: {"action": "move", "target": Vector2(0, 5)},
		b.id: {"action": "move", "target": Vector2(0, 0)},
	})
	check(Rules.find_piece(res.state, a.id) == null and Rules.find_piece(res.state, b.id) == null,
		"head-on swap kills both")


func test_multi_arrival():
	var st = Rules.new_state()
	var a = Rules.add_piece(st, "Knight", "white", Vector2(0, 0))
	var b = Rules.add_piece(st, "Knight", "black", Vector2(4, 0))
	var res = Rules.resolve(st, {
		a.id: {"action": "move", "target": Vector2(2, 1)},
		b.id: {"action": "move", "target": Vector2(2, 1)},
	})
	check(Rules.find_piece(res.state, a.id) == null and Rules.find_piece(res.state, b.id) == null,
		"same-square arrival kills both")


func test_path_collision_kills_both():
	# A piece stepping into a slider's path is struck in transit: both die.
	var st = Rules.new_state()
	var rook = Rules.add_piece(st, "Rook", "white", Vector2(0, 2))
	var knight = Rules.add_piece(st, "Knight", "black", Vector2(4, 0))
	var res = Rules.resolve(st, {
		rook.id: {"action": "move", "target": Vector2(5, 2)},
		knight.id: {"action": "move", "target": Vector2(3, 2)},
	})
	check(Rules.find_piece(res.state, rook.id) == null, "slider dies on the piece that cut its path")
	check(Rules.find_piece(res.state, knight.id) == null, "the intruder dies in the collision too")


func test_collision_denies_the_blow():
	# A slider cut down in transit never lands its committed capture.
	var st = Rules.new_state()
	var rook = Rules.add_piece(st, "Rook", "white", Vector2(0, 2))
	var victim = Rules.add_piece(st, "Pawn", "black", Vector2(5, 2))
	var blocker = Rules.add_piece(st, "Knight", "black", Vector2(4, 0))
	var res = Rules.resolve(st, {
		rook.id: {"action": "move", "target": Vector2(5, 2)},
		blocker.id: {"action": "move", "target": Vector2(3, 2)},
	})
	check(Rules.find_piece(res.state, rook.id) == null, "rook died in transit")
	check(Rules.find_piece(res.state, victim.id) != null, "its intended victim survives (blow never landed)")


func test_committed_capture_catches_fleeing_piece():
	# The reported case: a target cannot escape a declared capture by moving.
	var st = Rules.new_state()
	var rook = Rules.add_piece(st, "Rook", "white", Vector2(0, 0))
	var king = Rules.add_piece(st, "King", "black", Vector2(0, 4))
	Rules.add_piece(st, "King", "white", Vector2(5, 5))
	var res = Rules.resolve(st, {
		rook.id: {"action": "move", "target": Vector2(0, 4)},
		king.id: {"action": "move", "target": Vector2(1, 5)}, # tries to slip away
	})
	check(Rules.find_piece(res.state, king.id) == null, "fleeing king is still cut down")
	check(Rules.find_piece(res.state, rook.id).pos == Vector2(0, 4), "attacker takes the square")


func test_committed_capture_catches_automatic_zombie():
	# The automaton/zombie case: the zombie advances on its own, but the
	# declared capture still lands.
	# Attack from (3,4) so the zombie has no counter-capture and simply
	# advances -- otherwise the two would trade in a mutual strike.
	var st = Rules.new_state()
	var bot = Rules.add_piece(st, "Basic Automata", "white", Vector2(3, 4))
	var zombie = Rules.add_piece(st, "Zombie", "black", Vector2(1, 2))
	var res = Rules.resolve(st, {bot.id: {"action": "move", "target": Vector2(1, 2)}})
	check(Rules.find_piece(res.state, zombie.id) == null, "advancing zombie is caught by the capture")
	check(Rules.find_piece(res.state, bot.id).pos == Vector2(1, 2), "automaton takes the zombie's square")


func test_backfill_avenges_the_queen():
	# Order the rook into your own queen's square. It waits; when the knight
	# takes her, the rook moves in, kills the knight, and survives.
	var st = Rules.new_state()
	var queen = Rules.add_piece(st, "Queen", "white", Vector2(3, 3))
	var rook = Rules.add_piece(st, "Rook", "white", Vector2(3, 0))
	var knight = Rules.add_piece(st, "Knight", "black", Vector2(4, 5))
	var res = Rules.resolve(st, {
		knight.id: {"action": "move", "target": Vector2(3, 3)},
		rook.id: {"action": "move", "target": Vector2(3, 3), "is_conditional": true},
	})
	check(Rules.find_piece(res.state, queen.id) == null, "the queen falls to the knight")
	check(Rules.find_piece(res.state, knight.id) == null, "the backfilling rook cuts down the knight")
	var avenger = Rules.find_piece(res.state, rook.id)
	check(avenger != null and avenger.pos == Vector2(3, 3), "the rook survives and holds the square")


func test_backfill_does_not_resolve_while_blocked():
	var st = Rules.new_state()
	var queen = Rules.add_piece(st, "Queen", "white", Vector2(3, 3))
	var rook = Rules.add_piece(st, "Rook", "white", Vector2(3, 0))
	var res = Rules.resolve(st, {
		rook.id: {"action": "move", "target": Vector2(3, 3), "is_conditional": true},
	})
	check(Rules.find_piece(res.state, queen.id) != null, "the queen is unharmed by her ally")
	check(Rules.find_piece(res.state, rook.id).pos == Vector2(3, 0), "blocked backfill does not happen")


func test_conditional_moves_are_offered():
	var st = Rules.new_state()
	var rook = Rules.add_piece(st, "Rook", "white", Vector2(3, 0))
	Rules.add_piece(st, "Queen", "white", Vector2(3, 3))
	var found = null
	for a in Rules.get_actions(st, rook):
		if a.action == "move" and a.target == Vector2(3, 3):
			found = a
	check(found != null, "a move onto your own piece's square is offered")
	check(found != null and found.get("is_conditional", false), "and it is flagged conditional")


func test_chancellor_promotes_peasants():
	var st = Rules.new_state()
	var chancellor = Rules.add_piece(st, "Chancellor", "white", Vector2(1, 5))
	var pawn = Rules.add_piece(st, "Pawn", "white", Vector2(1, 4))
	var promo = null
	for a in Rules.get_actions(st, chancellor):
		if a.action == "promote" and a.target == Vector2(1, 4):
			promo = a
	check(promo != null, "chancellor offers to promote the peasant beside it")
	check(promo != null and promo.promote_to == "Minister", "and the promotion is to Minister")
	var res = Rules.resolve(st, {chancellor.id: {"action": "promote", "target": Vector2(1, 4), "promote_to": "Minister"}})
	var promoted = Rules.find_piece(res.state, pawn.id)
	check(promoted != null and promoted.type == "Minister", "the pawn becomes a Minister")
	# Only peasants: a noble beside the chancellor is not promotable.
	var st2 = Rules.new_state()
	var chan2 = Rules.add_piece(st2, "Chancellor", "white", Vector2(1, 5))
	Rules.add_piece(st2, "Rook", "white", Vector2(1, 4))
	var found_noble = false
	for a in Rules.get_actions(st2, chan2):
		if a.action == "promote":
			found_noble = true
	check(not found_noble, "chancellor cannot promote a non-peasant")


func test_promotion_beats_conditional_move():
	# Regression guard: a conditional backfill onto the same square must not
	# shadow the promotion (the UI declares one action per square).
	for promoter in ["Chancellor", "Pontifex", "Lady of the Lake"]:
		var st = Rules.new_state()
		var royal = Rules.add_piece(st, promoter, "white", Vector2(1, 5))
		Rules.add_piece(st, "Pawn", "white", Vector2(1, 4))
		var ranked = Rules.prioritize_actions(Rules.get_actions(st, royal))
		var on_square = null
		for a in ranked:
			if a.has("target") and a.target == Vector2(1, 4):
				on_square = a
		check(on_square != null and on_square.action == "promote",
			"%s: promotion wins the peasant's square over a backfill" % promoter)
		# And exactly one action occupies that square after prioritisation.
		var count = 0
		for a in ranked:
			if a.has("target") and a.target == Vector2(1, 4):
				count += 1
		check(count == 1, "%s: only one action is offered per square" % promoter)


func test_alternatives_are_kept_for_the_chooser():
	# The board draws one marker per square, but BOTH options must survive so
	# clicking that square can offer a choice.
	var st = Rules.new_state()
	var chancellor = Rules.add_piece(st, "Chancellor", "white", Vector2(1, 5))
	Rules.add_piece(st, "Pawn", "white", Vector2(1, 4))
	var raw = Rules.get_actions(st, chancellor)
	var all_sorted = Rules.sort_actions(raw)
	var drawn = Rules.prioritize_actions(raw)

	var on_square_all = []
	for a in all_sorted:
		if a.has("target") and a.target == Vector2(1, 4):
			on_square_all.append(a)
	var on_square_drawn = []
	for a in drawn:
		if a.has("target") and a.target == Vector2(1, 4):
			on_square_drawn.append(a)

	check(on_square_all.size() == 2, "both promote and conditional move are kept (got %d)" % on_square_all.size())
	check(on_square_drawn.size() == 1, "only one marker is drawn for that square")
	check(on_square_all[0].action == "promote", "the chooser lists promotion first")
	var has_conditional = false
	for a in on_square_all:
		if a.action == "move" and a.get("is_conditional", false):
			has_conditional = true
	check(has_conditional, "the conditional backfill is still selectable via the chooser")
	# sort_actions must not drop anything.
	check(all_sorted.size() == raw.size(), "sort_actions preserves every action")


func test_viking_valhalla():
	# Dying on the same turn you take a life sends you home to be re-fielded.
	var st = Rules.new_state()
	var raider = Rules.add_piece(st, "Raider", "white", Vector2(2, 3))
	Rules.add_piece(st, "Pawn", "black", Vector2(1, 2))
	var rifle = Rules.add_piece(st, "Rifleman", "black", Vector2(2, 0))
	var res = Rules.resolve(st, {
		raider.id: {"action": "move", "target": Vector2(1, 2)},
		rifle.id: {"action": "shoot", "target": Vector2(2, 3)},
	})
	check(Rules.find_piece(res.state, raider.id) == null, "raider died taking the pawn")
	check(res.state.credits.white.get("Raider", 0) == 1, "raider who died killing returns as a credit")
	check(res.state.credits.white.get("Zombie", 0) == 0, "raider no longer raises zombies")

	# Surviving the kill earns nothing -- you have to die for it.
	var st2 = Rules.new_state()
	var raider2 = Rules.add_piece(st2, "Raider", "white", Vector2(2, 3))
	Rules.add_piece(st2, "Pawn", "black", Vector2(1, 2))
	var res2 = Rules.resolve(st2, {raider2.id: {"action": "move", "target": Vector2(1, 2)}})
	check(Rules.find_piece(res2.state, raider2.id) != null, "raider survived")
	check(res2.state.credits.white.get("Raider", 0) == 0, "a surviving viking earns no credit")
	check(res2.state.credits.white.get("Zombie", 0) == 0, "and still raises no zombies")


func test_factory():
	var st = Rules.new_state()
	var factory = Rules.add_piece(st, "Factory", "white", Vector2(2, 2))
	check(Rules.get_actions(st, factory).is_empty(), "a factory cannot be ordered to move")
	var res = Rules.resolve(st, {})
	var built = 0
	for p in Rules.all_pieces(res.state, "white"):
		if p.type == "Basic Automata":
			built += 1
	check(built == 1, "factory stamps out one automaton per turn (got %d)" % built)
	check(Rules.find_piece(res.state, factory.id) != null, "factory stays put")

	# Boxed in on every side, it produces nothing.
	var st2 = Rules.new_state()
	var boxed = Rules.add_piece(st2, "Factory", "white", Vector2(0, 0))
	for pos in [Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
		Rules.add_piece(st2, "Pawn", "white", pos)
	var before = Rules.all_pieces(st2).size()
	var res2 = Rules.resolve(st2, {})
	check(Rules.all_pieces(res2.state).size() == before, "a walled-in factory builds nothing")


func test_praetor():
	var st = Rules.new_state()
	var praetor = Rules.add_piece(st, "Praetor", "white", Vector2(1, 5))
	var pawn = Rules.add_piece(st, "Pawn", "white", Vector2(1, 4))
	check(praetor.royal, "praetor is royal")
	var promo = null
	for a in Rules.get_actions(st, praetor):
		if a.action == "promote" and a.target == Vector2(1, 4):
			promo = a
	check(promo != null and promo.promote_to == "Factory", "praetor turns a peasant into a factory")
	var res = Rules.resolve(st, {praetor.id: {"action": "promote", "target": Vector2(1, 4), "promote_to": "Factory"}})
	check(Rules.find_piece(res.state, pawn.id).type == "Factory", "the peasant became a factory")


func test_doppelganger():
	var st = Rules.new_state()
	var doppel = Rules.add_piece(st, "Doppelganger", "white", Vector2(0, 5))
	var rook = Rules.add_piece(st, "Rook", "black", Vector2(5, 0))
	var res = Rules.resolve(st, {rook.id: {"action": "move", "target": Vector2(5, 1)}})
	var copy = Rules.find_piece(res.state, doppel.id)
	check(copy.type == "Rook", "doppelganger copies the enemy's last moved piece (got %s)" % copy.type)
	check(copy.color == "white", "the copy stays on our side")
	check(copy.get("mimic", false), "it remains a mimic after transforming")
	# It keeps copying on later rounds.
	var knight = Rules.add_piece(res.state, "Knight", "black", Vector2(0, 0))
	var res2 = Rules.resolve(res.state, {knight.id: {"action": "move", "target": Vector2(2, 1)}})
	check(Rules.find_piece(res2.state, doppel.id).type == "Knight", "and copies again next round")


func test_berserker():
	var st = Rules.new_state()
	var zerk = Rules.add_piece(st, "Berserker", "white", Vector2(2, 3))
	var t = targets(Rules.get_actions(st, zerk))
	check(Vector2(2, 0) in t and Vector2(2, 2) in t, "berserker charges forward like a rook")
	check(Vector2(0, 3) in t and Vector2(5, 3) in t, "and sweeps sideways")
	check(not Vector2(2, 4) in t and not Vector2(2, 5) in t, "but never retreats")
	check("Viking" in zerk.traits, "berserker is a viking")


func test_chieftain():
	var st = Rules.new_state()
	var chief = Rules.add_piece(st, "Chieftain", "white", Vector2(2, 2))
	check(chief.royal, "chieftain is royal")
	check("Viking" in chief.traits, "chieftain is a viking")
	check(targets(Rules.get_actions(st, chief)).size() == 8, "chieftain moves as a king")
	var has_promote = false
	for a in Rules.get_actions(st, chief):
		if a.action == "promote":
			has_promote = true
	check(not has_promote, "chieftain promotes nobody")


func test_spymaster():
	var st = Rules.new_state()
	var spy = Rules.add_piece(st, "Spymaster", "white", Vector2(2, 3))
	var t = targets(Rules.get_actions(st, spy))
	check(Vector2(2, 4) in t and Vector2(2, 5) in t, "spymaster slips backwards along the file")
	check(Vector2(0, 3) in t and Vector2(5, 3) in t, "and sideways along the rank")
	check(Vector2(1, 2) in t and Vector2(3, 2) in t, "and one diagonal step forward")
	check(not Vector2(2, 2) in t, "but never straight ahead")

	# Suborns the guards around an enemy royal, wherever it stands.
	var st2 = Rules.new_state()
	var spy2 = Rules.add_piece(st2, "Spymaster", "white", Vector2(0, 5))
	Rules.add_piece(st2, "King", "black", Vector2(4, 1))
	var guard = Rules.add_piece(st2, "Knight", "black", Vector2(4, 2))
	var far = Rules.add_piece(st2, "Rook", "black", Vector2(0, 0))
	var converts = targets(Rules.get_actions(st2, spy2), "convert")
	check(Vector2(4, 2) in converts, "spymaster turns a royal's bodyguard at range")
	check(not Vector2(0, 0) in converts, "but not pieces away from the royal")
	check(not Vector2(4, 1) in converts, "and never the royal itself")
	var res = Rules.resolve(st2, {spy2.id: {"action": "convert", "target": Vector2(4, 2), "convert_to": "Pawn"}})
	var turned = Rules.find_piece(res.state, guard.id)
	check(turned.type == "Pawn" and turned.color == "white", "the guard becomes our pawn")


func test_shot_still_catches_a_fleeing_victim():
	var st = Rules.new_state()
	var rifle = Rules.add_piece(st, "Rifleman", "white", Vector2(2, 2))
	var runner = Rules.add_piece(st, "Knight", "black", Vector2(2, 5))
	var res = Rules.resolve(st, {
		rifle.id: {"action": "shoot", "direction": Vector2(0, 1), "target": Vector2(2, 5)},
		runner.id: {"action": "move", "target": Vector2(0, 4)},
	})
	check(Rules.find_piece(res.state, runner.id) == null, "a piece in the line cannot dodge out of it")


func test_shot_is_intercepted_and_friendly_fire():
	# Your rifleman fires toward your own king; an anarch steps into the line.
	var st = Rules.new_state()
	var rifle = Rules.add_piece(st, "Rifleman", "white", Vector2(2, 5))
	var king = Rules.add_piece(st, "King", "white", Vector2(2, 1))
	var anarch = Rules.add_piece(st, "Anarch", "black", Vector2(0, 3))
	Rules.add_piece(st, "King", "black", Vector2(5, 0))
	var shot = {"action": "shoot", "direction": Vector2(0, -1), "target": Vector2(2, 1)}
	# Anarch steps into the line -> it intercepts, the king lives.
	var res = Rules.resolve(st, {rifle.id: shot, anarch.id: {"action": "move", "target": Vector2(2, 3)}})
	check(Rules.find_piece(res.state, anarch.id) == null, "the anarch walks into the shot and dies")
	check(Rules.find_piece(res.state, king.id) != null, "and the king is spared")
	# Anarch stays away -> the round carries to your own king.
	var res2 = Rules.resolve(st, {rifle.id: shot})
	check(Rules.find_piece(res2.state, king.id) == null, "with the line clear, friendly fire kills the king")
	check(Rules.find_piece(res2.state, anarch.id) != null, "the distant anarch is untouched")


func test_cannon_friendly_fire():
	var st = Rules.new_state()
	var can = Rules.add_piece(st, "Cannonier", "white", Vector2(3, 5))
	var friend = Rules.add_piece(st, "Pawn", "white", Vector2(3, 3))
	var foe = Rules.add_piece(st, "Pawn", "black", Vector2(3, 1))
	var res = Rules.resolve(st, {can.id: {"action": "fire_cannon"}})
	check(Rules.find_piece(res.state, friend.id) == null, "cannon hits friendlies")
	check(Rules.find_piece(res.state, foe.id) == null, "cannon hits enemies")
	check(Rules.find_piece(res.state, can.id) != null, "cannonier survives firing")


func test_dragon_breath():
	var st = Rules.new_state()
	var dr = Rules.add_piece(st, "Dragonrider", "white", Vector2(2, 3))
	var v1 = Rules.add_piece(st, "Pawn", "black", Vector2(2, 2))
	var v2 = Rules.add_piece(st, "Pawn", "black", Vector2(1, 1))
	var safe = Rules.add_piece(st, "Pawn", "black", Vector2(4, 3))
	var res = Rules.resolve(st, {dr.id: {"action": "dragon_breath", "direction": Vector2.UP}})
	check(Rules.find_piece(res.state, v1.id) == null, "breath hits square ahead")
	check(Rules.find_piece(res.state, v2.id) == null, "breath hits cone corner")
	check(Rules.find_piece(res.state, safe.id) != null, "breath misses outside cone")


func test_en_passant():
	var st = Rules.new_state()
	var black_pawn = Rules.add_piece(st, "Pawn", "black", Vector2(3, 1))
	var white_pawn = Rules.add_piece(st, "Pawn", "white", Vector2(2, 3))
	var res = Rules.resolve(st, {black_pawn.id: {"action": "move", "target": Vector2(3, 3), "is_double_move": true}})
	check(res.state.ep_targets.has(Vector2(3, 2)), "double move registers en passant square")
	var st2 = res.state
	var wp = Rules.find_piece(st2, white_pawn.id)
	var acts = Rules.get_actions(st2, wp)
	var ep_action = null
	for a in acts:
		if a.get("is_en_passant", false):
			ep_action = a
	check(ep_action != null and ep_action.target == Vector2(3, 2), "pawn sees en passant capture")
	var res2 = Rules.resolve(st2, {white_pawn.id: ep_action})
	check(Rules.find_piece(res2.state, black_pawn.id) == null, "en passant kills the double mover")
	check(Rules.find_piece(res2.state, white_pawn.id).pos == Vector2(3, 2), "capturer lands on the passed square")


func test_promotion_royal_status():
	var st = Rules.new_state()
	var pawn = Rules.add_piece(st, "Pawn", "white", Vector2(0, 0))
	Rules.add_piece(st, "King", "white", Vector2(5, 5)) # keep a royal alive
	var res = Rules.resolve(st, {pawn.id: {"action": "promote", "target": Vector2(0, 0), "promote_to": "Valkyrie"}})
	var promoted = Rules.find_piece(res.state, pawn.id)
	check(promoted.type == "Valkyrie" and not promoted.royal, "pawn promoted to Valkyrie")
	# Lady of the Lake makes new royals.
	var st2 = Rules.new_state()
	var lady = Rules.add_piece(st2, "Lady of the Lake", "white", Vector2(2, 5))
	var pawn2 = Rules.add_piece(st2, "Pawn", "white", Vector2(2, 4))
	var res2 = Rules.resolve(st2, {lady.id: {"action": "promote", "target": Vector2(2, 4), "promote_to": "King"}})
	var new_king = Rules.find_piece(res2.state, pawn2.id)
	check(new_king.type == "King" and new_king.royal, "lady-made King counts as royal")
	check(Rules.royal_count(res2.state, "white") == 2, "royal count includes promoted King")


func test_conversion():
	var st = Rules.new_state()
	var cultist = Rules.add_piece(st, "Cultist", "white", Vector2(2, 2))
	var victim = Rules.add_piece(st, "Pawn", "black", Vector2(3, 2))
	var res = Rules.resolve(st, {cultist.id: {"action": "convert", "target": Vector2(3, 2)}})
	var converted = Rules.find_piece(res.state, victim.id)
	check(converted.type == "Cultist" and converted.color == "white", "victim converted to white cultist")


func test_werewolf_toggle():
	var st = Rules.new_state()
	var wolf = Rules.add_piece(st, "Werewolf (wolf form)", "white", Vector2(2, 2))
	var res = Rules.resolve(st, {})
	check(Rules.find_piece(res.state, wolf.id).type == "Werewolf (human form)", "wolf becomes human at turn end")
	var res2 = Rules.resolve(res.state, {})
	check(Rules.find_piece(res2.state, wolf.id).type == "Werewolf (wolf form)", "human becomes wolf again")


func test_valkyrie_phase_out_and_return():
	var st = Rules.new_state()
	var valk = Rules.add_piece(st, "Valkyrie", "white", Vector2(3, 3))
	var rook = Rules.add_piece(st, "Rook", "black", Vector2(3, 0))
	var res = Rules.resolve(st, {rook.id: {"action": "move", "target": Vector2(3, 3)}})
	check(Rules.find_piece(res.state, valk.id) == null, "captured valkyrie leaves the board")
	check(res.state.phased_out.size() == 1, "valkyrie is phased out, not dead")
	var res2 = Rules.resolve(res.state, {})
	var returned = Rules.find_piece(res2.state, valk.id)
	check(returned != null, "valkyrie returns next turn")
	check(returned.pos != Vector2(3, 3), "return square dodges the occupier")
	check(res2.state.phased_out.is_empty(), "phase-out list cleared")


func test_zombie_automatic():
	var st = Rules.new_state()
	var zombie = Rules.add_piece(st, "Zombie", "white", Vector2(2, 3))
	var res = Rules.resolve(st, {})
	check(Rules.find_piece(res.state, zombie.id).pos == Vector2(2, 2), "zombie shambles forward on its own")
	# Prefers to eat.
	var st2 = Rules.new_state()
	var zombie2 = Rules.add_piece(st2, "Zombie", "white", Vector2(2, 3))
	var meal = Rules.add_piece(st2, "Pawn", "black", Vector2(1, 2))
	var res2 = Rules.resolve(st2, {})
	check(Rules.find_piece(res2.state, zombie2.id).pos == Vector2(1, 2), "zombie prefers to capture")
	check(Rules.find_piece(res2.state, meal.id) == null, "zombie ate the pawn")
	check(Rules.get_actions(st2, zombie2).is_empty(), "players cannot order zombies around")


func test_valhalla_credit():
	var st = Rules.new_state()
	var raider = Rules.add_piece(st, "Raider", "white", Vector2(2, 3))
	Rules.add_piece(st, "Pawn", "black", Vector2(1, 2))
	var rifle = Rules.add_piece(st, "Rifleman", "black", Vector2(1, 0))
	var res = Rules.resolve(st, {
		raider.id: {"action": "move", "target": Vector2(1, 2)},
		rifle.id: {"action": "shoot", "target": Vector2(2, 3)},
	})
	check(Rules.find_piece(res.state, raider.id) == null, "raider died mid-raid")
	check(res.state.credits.white.get("Raider", 0) == 1, "barbarian who died capturing goes to valhalla")


func test_petrify():
	var st = Rules.new_state()
	var gorgon = Rules.add_piece(st, "Gorgon", "white", Vector2(2, 2))
	var foe = Rules.add_piece(st, "Rook", "black", Vector2(2, 4))
	var friend = Rules.add_piece(st, "Rook", "white", Vector2(2, 3)) # adjacent after move? no - keep away
	friend.pos = Vector2(0, 0)
	st.board[2][3] = null
	st.board[0][0] = friend
	var res = Rules.resolve(st, {gorgon.id: {"action": "move", "target": Vector2(2, 3)}})
	var stoned = Rules.find_piece(res.state, foe.id)
	check(stoned.petrified, "enemy adjacent to gorgon is petrified")
	check(not Rules.find_piece(res.state, friend.id).petrified, "friends are safe from the gorgon")
	check(Rules.get_actions(res.state, stoned).is_empty(), "petrified pieces cannot act")


func test_win_conditions():
	var st = Rules.new_state()
	var wk = Rules.add_piece(st, "King", "white", Vector2(0, 5))
	var bk = Rules.add_piece(st, "King", "black", Vector2(0, 0))
	Rules.add_piece(st, "Rook", "white", Vector2(5, 0))
	var rook = st.board[5][0]
	var res = Rules.resolve(st, {rook.id: {"action": "move", "target": Vector2(0, 0)}})
	check(res.outcome == "white", "capturing the last royal wins")
	# Mutual destruction = draw.
	var st2 = Rules.new_state()
	var wk2 = Rules.add_piece(st2, "King", "white", Vector2(2, 2))
	var bk2 = Rules.add_piece(st2, "King", "black", Vector2(2, 4))
	var res2 = Rules.resolve(st2, {
		wk2.id: {"action": "move", "target": Vector2(2, 3)},
		bk2.id: {"action": "move", "target": Vector2(2, 3)},
	})
	check(res2.outcome == "draw", "mutual royal annihilation is a draw")
	# Petrified royal counts as lost.
	var st3 = Rules.new_state()
	var gorgon = Rules.add_piece(st3, "Gorgon", "white", Vector2(2, 2))
	Rules.add_piece(st3, "King", "white", Vector2(5, 5))
	var bk3 = Rules.add_piece(st3, "King", "black", Vector2(2, 4))
	var res3 = Rules.resolve(st3, {gorgon.id: {"action": "move", "target": Vector2(2, 3)}})
	check(Rules.find_piece(res3.state, bk3.id).petrified, "royal petrified")
	check(res3.outcome == "white", "petrifying the last royal wins")


func test_no_progress_adjudication():
	var st = Rules.new_state()
	Rules.add_piece(st, "King", "white", Vector2(0, 5))
	Rules.add_piece(st, "King", "black", Vector2(0, 0))
	Rules.add_piece(st, "Queen", "white", Vector2(5, 5))
	st.no_progress = Rules.NO_PROGRESS_LIMIT - 1
	var res = Rules.resolve(st, {})
	check(res.outcome == "white", "stalled game adjudicated on material")


func test_spawn():
	var st = Rules.new_state()
	Rules.add_piece(st, "King", "white", Vector2(0, 5))
	Rules.add_piece(st, "King", "black", Vector2(0, 0))
	st.credits.white["Zombie"] = 1
	var res = Rules.resolve(st, {-1: {"action": "spawn", "piece_type": "Zombie", "target": Vector2(3, 4), "color": "white"}})
	check("Zombie" in alive_types(res.state, "white"), "spawned zombie on board")
	check(res.state.credits.white["Zombie"] == 0, "spawn consumed the credit")
	# Spawning onto an occupied square fails and keeps the credit.
	var st2 = Rules.new_state()
	Rules.add_piece(st2, "King", "white", Vector2(0, 5))
	Rules.add_piece(st2, "Pawn", "black", Vector2(3, 4))
	st2.credits.white["Zombie"] = 1
	var res2 = Rules.resolve(st2, {-1: {"action": "spawn", "piece_type": "Zombie", "target": Vector2(3, 4), "color": "white"}})
	check(not "Zombie" in alive_types(res2.state, "white"), "blocked spawn fails")
	check(res2.state.credits.white["Zombie"] == 1, "failed spawn keeps the credit")


func test_leaper_paths_unblockable():
	check(Rules.move_path("Grasshopper", Vector2(2, 2), Vector2(2, 5)).is_empty(), "grasshopper hop has no blockable path")
	check(Rules.move_path("Elephant Rider", Vector2(2, 4), Vector2(2, 2)).is_empty(), "charge has no blockable path")
	check(Rules.move_path("Werewolf (wolf form)", Vector2(2, 2), Vector2(2, 4)).is_empty(), "wolf double-step has no blockable path")
	check(Rules.move_path("Devil Toad", Vector2(0, 0), Vector2(3, 3)).is_empty(), "toad run has no blockable path")
	check(Rules.move_path("Anarch", Vector2(0, 0), Vector2(0, 4)).is_empty(), "anarch teleport has no blockable path")
	check(Rules.move_path("Rook", Vector2(0, 0), Vector2(0, 3)).size() == 2, "rook path still blockable")


func test_kulak_ep_not_shadowed():
	var st = Rules.new_state()
	var black_pawn = Rules.add_piece(st, "Pawn", "black", Vector2(3, 1))
	var kulak = Rules.add_piece(st, "Kulak", "white", Vector2(2, 3))
	var res = Rules.resolve(st, {black_pawn.id: {"action": "move", "target": Vector2(3, 3), "is_double_move": true}})
	var kk = Rules.find_piece(res.state, kulak.id)
	var to_ep_square = []
	for a in Rules.get_actions(res.state, kk):
		if a.action == "move" and a.target == Vector2(3, 2):
			to_ep_square.append(a)
	check(to_ep_square.size() == 1, "kulak has exactly one action on the ep square")
	check(to_ep_square.size() > 0 and to_ep_square[0].get("is_en_passant", false), "and it is the ep capture (not a plain step)")


func test_rifleman_shot_first():
	var st = Rules.new_state()
	var rifle = Rules.add_piece(st, "Rifleman", "white", Vector2(2, 2))
	Rules.add_piece(st, "Pawn", "black", Vector2(2, 1))
	var first_on_target = null
	for a in Rules.get_actions(st, rifle):
		if a.has("target") and a.target == Vector2(2, 1):
			first_on_target = a
			break
	check(first_on_target != null and first_on_target.action == "shoot", "adjacent enemy: shoot comes before the move")


func test_gorgon_standoff():
	var st = Rules.new_state()
	var g1 = Rules.add_piece(st, "Gorgon", "white", Vector2(2, 2))
	var g2 = Rules.add_piece(st, "Gorgon", "black", Vector2(2, 3))
	var res = Rules.resolve(st, {})
	check(Rules.find_piece(res.state, g1.id).petrified, "white gorgon petrified in standoff")
	check(Rules.find_piece(res.state, g2.id).petrified, "black gorgon petrified in standoff")


func test_petrified_valkyrie_shatters():
	var st = Rules.new_state()
	var valk = Rules.add_piece(st, "Valkyrie", "white", Vector2(3, 3))
	valk.petrified = true
	var rook = Rules.add_piece(st, "Rook", "black", Vector2(3, 0))
	var res = Rules.resolve(st, {rook.id: {"action": "move", "target": Vector2(3, 3)}})
	check(Rules.find_piece(res.state, valk.id) == null, "petrified valkyrie is captured")
	check(res.state.phased_out.is_empty(), "petrified valkyrie does not phase out")


func test_ep_not_registered_for_the_dead():
	var st = Rules.new_state()
	var black_pawn = Rules.add_piece(st, "Pawn", "black", Vector2(3, 1))
	var rifle = Rules.add_piece(st, "Rifleman", "white", Vector2(3, 4))
	var res = Rules.resolve(st, {
		black_pawn.id: {"action": "move", "target": Vector2(3, 3), "is_double_move": true},
		rifle.id: {"action": "shoot", "target": Vector2(3, 1)},
	})
	check(Rules.find_piece(res.state, black_pawn.id) == null, "double-mover shot dead")
	check(res.state.ep_targets.is_empty(), "no ep square registered for a dead double-mover")


func test_promotion_picker_choices():
	var st = Rules.new_state()
	var pawn = Rules.add_piece(st, "Pawn", "white", Vector2(0, 0))
	Rules.add_piece(st, "King", "white", Vector2(5, 5))
	# get_actions (human display) offers a single promote action.
	var promo_count = 0
	for a in Rules.get_actions(st, pawn):
		if a.action == "promote":
			promo_count += 1
	check(promo_count == 1, "display sees one promote action (picker supplies the rest)")
	# legal_actions (AI) expands into one per choice.
	var offered = {}
	for e in Rules.legal_actions(st, "white"):
		if e.piece_id == pawn.id and e.action.action == "promote":
			offered[e.action.promote_to] = true
	check(offered.size() == Rules.promotion_choices().size(), "legal_actions expands every promotion choice")
	check(offered.has("Queen") and offered.has("Valkyrie") and offered.has("Knight"), "choices include Queen/Valkyrie/Knight")
	check(not offered.has("King"), "cannot promote to a royal")
	# Resolving a chosen promotion yields that piece.
	var res = Rules.resolve(st, {pawn.id: {"action": "promote", "target": Vector2(0, 0), "promote_to": "Queen"}})
	var promoted = Rules.find_piece(res.state, pawn.id)
	check(promoted != null and promoted.type == "Queen", "pawn promotes to the chosen Queen")
	check(not promoted.royal, "promoted Queen is not royal")


func test_threatened_royals():
	# Rook bearing down an open file threatens the enemy king.
	var st = Rules.new_state()
	var wk = Rules.add_piece(st, "King", "white", Vector2(2, 2))
	Rules.add_piece(st, "Rook", "black", Vector2(2, 5))
	var t = Rules.threatened_royals(st)
	check(t.has(wk.id), "king in an enemy rook's open file is in check")
	# Block the file: no longer threatened.
	Rules.add_piece(st, "Pawn", "black", Vector2(2, 4))
	check(not Rules.threatened_royals(st).has(wk.id), "blocked rook does not threaten the king")

	# A safe king is not flagged.
	var st2 = Rules.new_state()
	var wk2 = Rules.add_piece(st2, "King", "white", Vector2(0, 5))
	Rules.add_piece(st2, "King", "black", Vector2(5, 0))
	check(not Rules.threatened_royals(st2).has(wk2.id), "distant king is not in check")

	# Adjacent enemy Gorgon threatens to petrify a royal.
	var st3 = Rules.new_state()
	var wk3 = Rules.add_piece(st3, "King", "white", Vector2(2, 2))
	Rules.add_piece(st3, "Gorgon", "black", Vector2(2, 3))
	check(Rules.threatened_royals(st3).has(wk3.id), "royal beside an enemy gorgon is in check")

	# Rifleman with a clear shot threatens a royal.
	var st4 = Rules.new_state()
	var wk4 = Rules.add_piece(st4, "King", "white", Vector2(4, 2))
	Rules.add_piece(st4, "Rifleman", "black", Vector2(0, 2))
	check(Rules.threatened_royals(st4).has(wk4.id), "royal in a rifleman's line is in check")


func test_legal_actions():
	var st = Rules.new_state()
	Rules.add_piece(st, "King", "white", Vector2(2, 5))
	var zombie = Rules.add_piece(st, "Zombie", "white", Vector2(2, 4))
	var stone = Rules.add_piece(st, "Rook", "white", Vector2(0, 0))
	stone.petrified = true
	st.credits.white["Raider"] = 1
	var acts = Rules.legal_actions(st, "white")
	var has_spawn = false
	var zombie_orders = 0
	var stone_orders = 0
	for entry in acts:
		if entry.action.action == "spawn":
			has_spawn = true
		if entry.piece_id == zombie.id:
			zombie_orders += 1
		if entry.piece_id == stone.id:
			stone_orders += 1
	check(has_spawn, "legal actions include credit spawns")
	check(zombie_orders == 0, "no orders for automatic pieces")
	check(stone_orders == 0, "no orders for petrified pieces")
	check(acts.size() > 0, "king has legal actions")
