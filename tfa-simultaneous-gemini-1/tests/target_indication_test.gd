# res://tests/target_indication_test.gd
# Target indication: an NPC's '!' replays whenever it picks a new target (not
# every frame), and while paused a line shows whom each visible NPC is after
# (UI/TargetIntentOverlay.gd). Drives the real Game on town_square.
# Run:  godot --headless --path . res://tests/target_indication_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

var failures := 0
var game = null

func _check(check_name: String, ok: bool, detail = "") -> void:
	if ok:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, str(detail)])

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _wait_until(cond: Callable, max_frames: int) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await get_tree().process_frame
	return cond.call()

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
	game.load_map("town_square")
	await _frames(10)
	if PauseManager.is_paused:
		PauseManager.unpause()
	await _main()
	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

## A spot `dist` px from `from` that `viewer` would see clearly, or INF.
func _clear_spot(from: Vector2, dist: float) -> Vector2:
	var space := get_world_2d().direct_space_state
	for ang in [PI / 2, -PI / 2, 0.0, PI, PI / 4, 3 * PI / 4, -PI / 4, -3 * PI / 4]:
		var p: Vector2 = from + Vector2.RIGHT.rotated(ang) * dist
		if not GridManager.would_walk(GridManager.world_to_map(p)):
			continue
		if GridManager.sight_line_clear(space, p, from, 0.0, 0.0) and GridManager.sight_line_clear(space, from, p, 0.0, 0.0):
			return p
	return Vector2.INF

func _main() -> void:
	var party: Array = game.party_chars.filter(func(c): return is_instance_valid(c))
	_check("party of two or more", party.size() >= 2, party.size())
	if party.size() < 2:
		return
	var pc0 = party[0]
	var pc1 = party[1]
	# Only the test bandit acts: map NPCs are parked out of the way, the party
	# holds still, and the companions stand where the bandit can't see them.
	for c in game.characters_in_scene:
		if is_instance_valid(c) and not (c in party):
			c.AI_enabled = false
			c.global_position = pc0.global_position + Vector2(-3000, -3000)
	for pc in party:
		pc.AI_enabled = false
	for i in range(1, party.size()):
		party[i].global_position = pc0.global_position + Vector2(2500 + 200 * i, 0)
	var spot: Vector2 = _clear_spot(pc0.global_position, 150.0)
	_check("found an open spot by the protagonist", spot != Vector2.INF)
	if spot == Vector2.INF:
		return
	var bandit = game._spawn_character("bandit", spot)
	_check("bandit spawned", bandit != null)
	if bandit == null:
		return
	# Face each other (rotation 0 faces up the screen).
	bandit.rotation = (pc0.global_position - spot).angle() + PI / 2
	pc0.rotation = (spot - pc0.global_position).angle() + PI / 2
	var ai = bandit.get_node("AI")
	var count := [0]
	ai.target_acquired.connect(func(_t): count[0] += 1)
	bandit.AI_enabled = true

	# ---------------- '!' on acquisition, once ----------------
	var got: bool = await _wait_until(func(): return ai.current_target != null, 180)
	_check("bandit acquires the protagonist", got and ai.current_target == pc0, ai.current_target)
	_check("acquisition announced once", count[0] == 1, count[0])
	var ind: Label = bandit._alertness_indicator
	_check("'!' shown on acquisition", ind.visible and ind.text == "!", [ind.visible, ind.text])
	await _frames(60)
	_check("holding the target doesn't re-announce", count[0] == 1, count[0])
	var flash_over: bool = await _wait_until(func(): return not ind.visible, 300)
	_check("the '!' flash ends", flash_over)

	# ---------------- a switch replays it ----------------
	ai._acquire_target(pc1)
	_check("switching target announces", count[0] == 2, count[0])
	_check("'!' replays on a switch (meter already HOSTILE)", ind.visible and ind.text == "!")
	ai._acquire_target(pc1)
	_check("re-picking the same target is quiet", count[0] == 2, count[0])
	ai._acquire_target(pc0)
	_check("switching back announces", count[0] == 3, count[0])

	# ---------------- re-find rule ----------------
	ai._lose_target()
	ai._time_without_target = 0.3
	ai._acquire_target(pc0)
	_check("re-acquiring within a second is quiet", count[0] == 3, count[0])
	ai._lose_target()
	ai._time_without_target = ai.TARGET_REANNOUNCE_GAP + 0.5
	ai._acquire_target(pc0)
	_check("re-finding after a search announces", count[0] == 4, count[0])
	# The gap is measured while targetless: out of range, the clock runs.
	var home: Vector2 = bandit.global_position
	bandit.global_position = home + Vector2(0, 6000)
	ai._lose_target()
	var waited: bool = await _wait_until(func(): return ai._time_without_target >= ai.TARGET_REANNOUNCE_GAP + 0.1, 600)
	_check("time without a target accumulates", waited, ai._time_without_target)
	bandit.global_position = home
	bandit.rotation = (pc0.global_position - home).angle() + PI / 2
	got = await _wait_until(func(): return ai.current_target == pc0, 240)
	_check("re-found the protagonist and announced it", got and count[0] == 5, [got, count[0]])

	# ---------------- party members never get the replay ----------------
	var pai = pc1.get_node_or_null("AI")
	if pai != null and pc1._alertness_indicator != null:
		pc1.AI_enabled = true
		pc1._alertness_indicator.visible = false
		pc1._on_ai_target_acquired(bandit)
		_check("no '!' replay over a party member", not pc1._alertness_indicator.visible)
		pc1.AI_enabled = false

	# ---------------- apathy doesn't spam ----------------
	var before: int = count[0]
	bandit.condition_manager.apply_condition("apathetic", null, 1)
	await _frames(90)
	_check("apathy's per-frame re-acquire stays quiet", count[0] == before, [before, count[0]])
	bandit.condition_manager.remove_condition("apathetic")
	await _wait_until(func(): return ai.current_target == pc0, 120)

	# ---------------- intent lines while paused ----------------
	var overlay = game.get_node_or_null("TargetIntentOverlay")
	_check("overlay is a child of Game", overlay != null)
	if overlay == null:
		return
	_check("no lines while the game runs", overlay.collect_lines().is_empty())
	bandit.global_position = home
	bandit.rotation = (pc0.global_position - home).angle() + PI / 2
	pc0.rotation = (home - pc0.global_position).angle() + PI / 2
	await _wait_until(func(): return ai.current_target == pc0 and game.is_seen_by_party(bandit), 120)
	PauseManager.pause()
	await _frames(3)
	var lines: Array = overlay.collect_lines()
	_check("one intent line while paused", lines.size() == 1, [lines.size(), ai.current_target, game.is_seen_by_party(bandit)])
	if lines.size() == 1:
		var l: Dictionary = lines[0]
		_check("line runs from the bandit to the protagonist", l["npc"] == bandit and l["target"] == pc0)
		_check("red toward a party member", l["color"] == overlay.COLOR_TO_PARTY)
		_check("solid while the bandit sees its target", l["seen"] == true)
		_check("line stops short of both bodies", l["from"].distance_to(bandit.global_position) > 1.0 and l["to"].distance_to(pc0.global_position) > 1.0)
	# Dashed once the chase is running on where it last saw the target.
	ai._target_occluded_time = 1.0
	lines = overlay.collect_lines()
	_check("dashed while the target is out of sight", lines.size() == 1 and lines[0]["seen"] == false)
	ai._target_occluded_time = 0.0
	# NPC against NPC: another NPC the party sees, after the bandit, draws amber.
	var other = null
	for c in game.characters_in_scene:
		if is_instance_valid(c) and c != bandit and not (c in party) and c.is_alive() and c.has_node("AI"):
			other = c
			break
	if other != null:
		var near: Vector2 = home + (home - pc0.global_position).normalized().orthogonal() * 80.0
		other.global_position = near
		other.AI_enabled = true
		var oai = other.get_node("AI")
		oai.current_target = bandit
		game._npc_was_truly_seen[other] = true
		other.visible = true
		var amber: Array = overlay.collect_lines().filter(func(x): return x["npc"] == other)
		_check("an NPC after the bandit draws an amber line", amber.size() == 1 and amber[0]["target"] == bandit and amber[0]["color"] == overlay.COLOR_TO_OTHER, amber)
		# The target must be seen too: an unseen victim draws nothing.
		game._npc_was_truly_seen[bandit] = false
		amber = overlay.collect_lines().filter(func(x): return x["npc"] == other)
		_check("no amber line toward an unseen NPC", amber.is_empty())
		game._npc_was_truly_seen[bandit] = true
		oai.current_target = null
		other.AI_enabled = false
		other.global_position = pc0.global_position + Vector2(-3000, -3000)
		game._npc_was_truly_seen[other] = false
	# An NPC the party can't see draws nothing (the LOS pass is frozen while
	# paused, so flip its cached answer).
	game._npc_was_truly_seen[bandit] = false
	_check("hidden NPCs draw no line", overlay.collect_lines().is_empty())
	game._npc_was_truly_seen[bandit] = true
	# Nobody fights on the world map: no lines there.
	game.current_map_data["is_world_map"] = true
	_check("no lines on the world map", overlay.collect_lines().is_empty())
	game.current_map_data.erase("is_world_map")
	_check("lines back off the world map", overlay.collect_lines().size() == 1)
	PauseManager.unpause()
	await _frames(2)
	_check("lines clear on unpause", overlay.collect_lines().is_empty() and not overlay._drawn)
	bandit.AI_enabled = false
