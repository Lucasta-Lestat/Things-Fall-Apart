# res://tests/companion_follow_test.gd
# Headless regression harness: companions the player isn't controlling keep up
# with the party out of combat.
#
# The report: on a fresh new game in Perrow (tg_hillside_lower), the
# companions you aren't controlling never move, fight or no fight. Until
# 874c1404 (2026-10-16) an idle companion ran the civilian goal loop (random
# wander, picking up loot); that commit rightly stopped it, and nothing took
# its place, so they stood where they spawned. ai.gd _process_follow walks an
# idle, unselected companion to a slot near Game.primary_selected.
#   - the selected character walks off: each companion follows, and stops near
#     them rather than on top of them;
#   - Wait Here (hold_position) keeps a companion where it is; Resume and it
#     catches up again;
#   - a companion the player has selected too (player-controlled) doesn't
#     wander off after the primary.
# Drives the real Game on tg_hillside_lower, as a new game starts.
# Run:  godot --headless --path . res://tests/companion_follow_test.tscn
# Judge by PASS/FAIL lines and "HARNESS DONE failures=0".
extends Node2D

var failures := 0
var game = null
var lead = null
var mates: Array = []

func _check(check_name: String, ok: bool, detail = "") -> void:
	if ok:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, str(detail)])

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds, true).timeout

func _ready() -> void:
	# A SCRIPT ERROR aborts the coroutine; don't hang waiting for quit().
	get_tree().create_timer(240.0, true).timeout.connect(func():
		print("FAIL watchdog timeout (coroutine aborted?) failures=%d" % failures)
		get_tree().quit(99))
	await get_tree().process_frame
	game = load("res://game.tscn").instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _frames(2)
	game.load_map("tg_hillside_lower")
	await _frames(10)
	if PauseManager.is_paused:
		PauseManager.unpause()
	lead = game.primary_selected
	for pc in game.party_chars:
		if pc != lead:
			mates.append(pc)
	_check("setup.party-of-three", lead != null and mates.size() >= 2, "%s / %d" % [lead, mates.size()])
	if lead == null or mates.size() < 2:
		_finish()
		return
	for m in mates:
		_check("setup.%s-ai-driven" % m.Name, m.AI_enabled and not m.is_player_controlled)

	await _case_follow()
	await _case_wait_and_resume()
	await _case_selected_mate_stays()
	_finish()

func _finish() -> void:
	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _tile() -> float:
	return float(GridManager.TILE_SIZE)

## A walkable ground tile the leader can reach, `tiles` or more away from
## where they stand, picked from one bounded flood.
func _far_spot(tiles: float) -> Vector2:
	var from: Vector2i = GridManager.world_to_map(lead.global_position)
	var reach: Dictionary = GridManager.reachable_within(from, int(tiles) * 3, lead.jump_height, lead.jump_range, lead.on_roof)
	var best := Vector2.INF
	var best_d := INF
	for t in reach:
		var p: Vector2 = GridManager.map_to_world(t)
		var d: float = p.distance_to(lead.global_position)
		if d < tiles * _tile() or d > (tiles + 3.0) * _tile():
			continue
		if not GridManager.would_walk(t) or GridManager.is_hazard_tile(t):
			continue
		if d < best_d:
			best_d = d
			best = p
	return best

## Move the leader there at once (the player walking off, without the wait).
func _move_lead(tiles: float) -> bool:
	var p: Vector2 = _far_spot(tiles)
	if not p.is_finite():
		return false
	lead.global_position = p
	lead.is_moving = false
	await _frames(2)
	return true

func _dist(c) -> float:
	return c.global_position.distance_to(lead.global_position)

func _case_follow() -> void:
	var start: Dictionary = {}
	for m in mates:
		start[m] = m.global_position
	var moved: bool = await _move_lead(8.0)
	_check("follow.leader-moved", moved and _dist(mates[0]) > 6.0 * _tile(),
		"moved %s dist %.0f" % [moved, _dist(mates[0])])
	await _wait(9.0)
	for m in mates:
		_check("follow.%s-caught-up" % m.Name, _dist(m) <= 3.5 * _tile(),
			"dist %.0f (%.1f tiles), walked %.0f" % [_dist(m), _dist(m) / _tile(), m.global_position.distance_to(start[m])])
		_check("follow.%s-not-on-top" % m.Name, _dist(m) >= 0.5 * _tile(), "dist %.0f" % _dist(m))
		_check("follow.%s-settled" % m.Name, not m.is_moving and m.get_node("AI").nav_path.is_empty(),
			"moving %s path %d" % [m.is_moving, m.get_node("AI").nav_path.size()])

func _case_wait_and_resume() -> void:
	var held = mates[0]
	var free = mates[1]
	held.hold_position = true
	var held_at: Vector2 = held.global_position
	var moved: bool = await _move_lead(8.0)
	_check("wait.leader-moved", moved)
	await _wait(6.0)
	_check("wait.held-mate-stays", held.global_position.distance_to(held_at) < 0.5 * _tile(),
		"moved %.0f" % held.global_position.distance_to(held_at))
	_check("wait.free-mate-follows", _dist(free) <= 3.5 * _tile(), "dist %.0f" % _dist(free))
	held.hold_position = false
	await _wait(9.0)
	_check("resume.held-mate-catches-up", _dist(held) <= 3.5 * _tile(), "dist %.0f" % _dist(held))

func _case_selected_mate_stays() -> void:
	# Both selected: the second is the player's to move, not the AI's.
	var mate = mates[0]
	game.toggle_character_selection(mate)
	await _frames(2)
	if game.primary_selected != lead:
		game.select_character(lead)
		game.toggle_character_selection(mate)
		await _frames(2)
	_check("selected.mate-player-controlled", mate.is_player_controlled and not mate.AI_enabled \
		and game.primary_selected == lead, "ctl %s ai %s primary %s" % [mate.is_player_controlled, mate.AI_enabled, game.primary_selected])
	var at: Vector2 = mate.global_position
	var moved: bool = await _move_lead(8.0)
	_check("selected.leader-moved", moved)
	await _wait(4.0)
	_check("selected.mate-stays", mate.global_position.distance_to(at) < 0.5 * _tile(),
		"moved %.0f" % mate.global_position.distance_to(at))
	game.select_character(lead)
	await _frames(2)
