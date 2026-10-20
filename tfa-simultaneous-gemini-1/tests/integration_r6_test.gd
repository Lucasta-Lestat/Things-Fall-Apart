# res://tests/integration_r6_test.gd
# Round 6 integration: the three lanes together, on the real Game (town_square).
#   status-conds      Toxic Shock doubles each tick until cured or dead; Chilled
#                     freezes at 4 stacks.
#   unseen-targets    the player's hands only find what the party sees
#                     (Game.hidden_from_party); a plan step aimed at a target
#                     lost from sight pauses ("Target lost").
#   threat-awareness  combat music and Surrender only for hostiles the party
#                     knows about (Game.known_threats_near_party: seen now, or
#                     seen, hit or heard close by within 10 s).
# Cross-lane cases:
#   1. A remembered threat the party no longer sees: music and Surrender stay
#      for the memory, but it can't be clicked or hovered, the plan aimed at
#      it pauses with the reason, the leash goes to where it was last seen,
#      and Surrender still has it as counterparty. Forgotten, the
#      button goes but the plan stays paused (sight, not memory); seen again,
#      everything comes back.
#   2. Toxic Shock on an NPC that leaves sight: it keeps doubling and kills,
#      with no float, log line, warning or death line about it; its ticks are
#      no contact (the memory of it runs out), a null-source re-dose (a
#      transform) neither; a re-dose from the party is contact, but quiet.
#   3. Chilled to 4 stacks: Frozen, announced on a seen NPC, silent on an
#      unseen one.
#   4. Kinds of awareness: an Invisible NPC found by a hit is seen (clickable)
#      for round 5's 5 s and remembered after (music on, plan paused "is
#      invisible"); a hostile heard close behind the party is a known threat
#      but not clickable; a roof-walker in ground view is perceived (known, plan
#      goes on, leash to where it stands) but not drawn, so not clickable.
#   5. Surrender with known and unknown hostiles: the counterparty is the
#      known one even when it is out of sight; once it is forgotten, a hidden
#      hostile nearby brings neither button nor counterparty.
#   6. Map change: a party member's Toxic Shock keeps its doubling step and
#      warning; the threat memory and last-seen spots are transient.
#   7. A party member poisoned by an unseen NPC: the poisoner becomes known by
#      the dose, never named; Toxic Shock warns once, then kills ("has died.");
#      its ticks don't keep the poisoner in mind.
# Run:  godot --headless --path . res://tests/integration_r6_test.tscn
# Judge by PASS/FAIL lines and "HARNESS DONE failures=0".
extends Node2D

var failures := 0
var checks := 0
var game = null
var hover = null
var p = null            # the party member who looks
var others: Array = []  # the rest of the party, sight 0: only p sees
var saved_sight: Dictionary = {}
var p_sight := 0.0
var face := 0.0         # a direction with a clear 450 px sight line
var wall_dir := 0.0
var wall_spot := Vector2.INF   # a spot behind a vision-blocking wall
var _wall = null
var _spawned: Array = []

## Stands in for a TacticalPath action node (PathDrawer reads action_data).
class FakePlanNode:
	var action_data: Dictionary = {}

func _check(check_name: String, ok: bool, detail = "") -> void:
	checks += 1
	if ok:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, str(detail)])

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _physics(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _log_count(fragment: String) -> int:
	var n := 0
	for e in GameLog.get_entries():
		if fragment in str(e.get("text", "")):
			n += 1
	return n

func _log_size() -> int:
	return GameLog.get_entries().size()

## Log lines since `since` (an earlier _log_size) that contain `fragment`.
func _log_since(since: int, fragment: String) -> Array:
	var out: Array = []
	var entries := GameLog.get_entries()
	for i in range(mini(since, entries.size()), entries.size()):
		var t := str(entries[i].get("text", ""))
		if fragment in t:
			out.append(t)
	return out

func _log_tail(k: int = 5) -> String:
	var out: Array = []
	for e in GameLog.get_entries().slice(-k):
		out.append(str(e.get("text", "")))
	return str(out)

func _advance(seconds: float) -> void:
	TimeManager.game_time += seconds

func _ready() -> void:
	# A SCRIPT ERROR aborts the coroutine; don't hang waiting for quit().
	get_tree().create_timer(400.0, true).timeout.connect(func():
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
	TimeManager.pause_time()   # game time (conditions, memory) is moved by hand
	_check("game.loaded", game.party_chars.size() > 1, "needs a party of two or more")
	if game.party_chars.size() < 2:
		_finish()
		return
	hover = game.get_node_or_null("WorldHoverInfo")
	_setup()
	_check("setup.built-a-wall", wall_spot.is_finite(), "no second clear direction for the wall")
	await _settle()
	if not wall_spot.is_finite():
		_finish()
		return

	await _case_remembered_threat_unseen()
	await _case_toxic_shock_hidden_npc()
	await _case_chilled_freeze_unseen()
	await _case_awareness_kinds()
	await _case_surrender_mix()
	await _case_map_change()
	await _case_party_member_unseen_poisoner()
	_restore()
	_finish()

func _finish() -> void:
	print("HARNESS DONE failures=%d checks=%d" % [failures, checks])
	get_tree().quit(1 if failures > 0 else 0)

# ---------------------------------------------------------------------------
# Setup and helpers
# ---------------------------------------------------------------------------

## Everyone's AI off; only the leader sees (the rest have sight 0 and stand
## behind it); the leader faces a direction with a clear 450 px sight line;
## a wall stands off to the side with a spot behind it (as
## unseen_targets_r6_test does: the square around the spawn is open).
func _setup() -> void:
	for c in game.characters_in_scene:
		if is_instance_valid(c):
			c.AI_enabled = false
	p = game.party_chars[0]
	p_sight = p.sight
	others.clear()
	saved_sight.clear()
	var space = p.get_world_2d().direct_space_state
	for deg in range(0, 360, 15):
		var a: float = deg_to_rad(deg)
		if GridManager.sight_line_clear(space, p.global_position,
				p.global_position + Vector2.UP.rotated(a) * 450.0, p.get_elevation(), 0.0):
			face = a
			break
	var i := 1
	for pc in game.party_chars:
		if pc == p:
			continue
		others.append(pc)
		saved_sight[pc] = pc.sight
		pc.sight = 0.0
		pc.global_position = p.global_position - Vector2.UP.rotated(face) * (40.0 * i)
		_turn(pc, face)
		i += 1
	_turn(p, face)
	wall_spot = Vector2.INF
	for deg in range(90, 271, 15):
		var a: float = face + deg_to_rad(deg)
		if GridManager.sight_line_clear(space, p.global_position,
				p.global_position + Vector2.UP.rotated(a) * 450.0, p.get_elevation(), 0.0):
			wall_dir = a
			wall_spot = p.global_position + Vector2.UP.rotated(a) * 300.0
			break
	if wall_spot.is_finite():
		var body := StaticBody2D.new()
		body.collision_layer = CollisionLayers.VISION_BLOCKERS
		body.collision_mask = 0
		var cs := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(240, 20)   # across the line, 150 px out
		cs.shape = rect
		body.add_child(cs)
		body.rotation = wall_dir
		game.add_child(body)
		body.global_position = p.global_position + Vector2.UP.rotated(wall_dir) * 150.0
		_wall = body

func _restore() -> void:
	if is_instance_valid(_wall):
		_wall.queue_free()
	for pc in saved_sight:
		if is_instance_valid(pc):
			pc.sight = saved_sight[pc]
	if is_instance_valid(p):
		p.sight = p_sight

func _turn(c, ang: float) -> void:
	c.rotation = ang
	c.target_rotation = ang

func _ahead(dist: float) -> Vector2:
	return p.global_position + Vector2.UP.rotated(face) * dist

func _behind(dist: float) -> Vector2:
	return p.global_position - Vector2.UP.rotated(face) * dist + Vector2.RIGHT.rotated(face) * 60.0

func _spawn(npc_name: String, pos: Vector2, faction: String = "bandits"):
	var npc = game._spawn_character("default_human", pos, {"faction": faction})
	if npc == null:
		return null
	npc.AI_enabled = false
	npc.faction_id = faction
	npc.Name = npc_name
	_turn(npc, face)
	_spawned.append(npc)
	return npc

func _despawn_all() -> void:
	if PauseManager.is_paused:
		_resume_game()
	if is_instance_valid(p):
		p.action_queue.cancel_all()
		p.ability_manager.cancel_cast("", true)
		var guard := 0
		while p.attack_animator.is_attacking and guard < 600:
			await _frames(1)
			guard += 1
	for npc in _spawned:
		if is_instance_valid(npc):
			game.characters_in_scene.erase(npc)
			npc.queue_free()
	_spawned.clear()
	_turn(p, face)
	await _frames(2)
	_reset_awareness_ui()

func _settle() -> void:
	await _frames(3)
	await _physics(2)

## Music off and the button hidden, as before any fight.
func _reset_awareness_ui() -> void:
	game._combat_music_calm_for = game.COMBAT_MUSIC_RELEASE
	MusicManager.set_combat(false)
	game._update_surrender_button([])

## Let the real 2 Hz poll (Game._process) run at least once.
func _poll() -> void:
	await get_tree().create_timer(0.65, true).timeout
	await _frames(1)

func _button() -> bool:
	return game._surrender_button != null and game._surrender_button.visible

func _music() -> bool:
	return MusicManager.is_in_combat()

func _known(npc) -> bool:
	return npc in game.known_threats_near_party()

func _clickable(npc) -> bool:
	return p._find_character_at(npc.global_position) == npc

func _hovered(npc) -> bool:
	return hover != null and hover.pick_character(npc.global_position) == npc

func _plan_attack(target) -> void:
	PauseManager.pause()
	p.action_queue.queue_attack_target(target, "Main")

func _resume_game() -> void:
	PauseManager.unpause()
	TimeManager.pause_time()

## Invisible applied where the party can't see it (the leader looking away),
## then the leader faces it again: Invisible with no cue at all.
func _invisible_unseen(npc) -> void:
	_turn(p, face + PI)
	await _frames(3)
	npc.condition_manager.apply_condition("invisible", null, 1, -1.0)
	await _frames(1)
	_turn(p, face)
	await _settle()

## Sturdy enough to take several doubling ticks: CON 400 is 100 HP.
func _sturdy(c) -> void:
	c.constitution = 400
	c.current_health = c.max_health

func _shock(c) -> ConditionInstance:
	return c.condition_manager.get_condition("toxic_shock")

## One Toxic Shock tick: two seconds of game time, then a frame for the
## ConditionManager to fire it.
func _tick() -> void:
	_advance(2.0)
	await _frames(2)

func _death_line(who: String) -> String:
	return "%s has died." % who

# ---------------------------------------------------------------------------
# 1. A remembered threat the party no longer sees
# ---------------------------------------------------------------------------

func _case_remembered_threat_unseen() -> void:
	var raider = _spawn("Raider", _ahead(220.0))
	await _settle()
	_check("memory.control-seen", game.is_seen_by_party(raider) and _known(raider))
	_check("memory.control-clickable", _clickable(raider) and _hovered(raider))
	await _poll()
	_check("memory.control-button-and-music", _button() and _music())
	var seen_at: Vector2 = raider.global_position
	_plan_attack(raider)
	raider.global_position = wall_spot   # walks off behind a wall
	_advance(1.0)                        # longer than PLAN_TARGET_LOST_GRACE
	var since := _log_size()
	_resume_game()
	await _settle()
	_check("memory.lost-from-sight", not game.is_seen_by_party(raider) and game.hidden_from_party(raider))
	_check("memory.still-a-known-threat", _known(raider))
	await _poll()
	_check("memory.button-kept", _button())
	_check("memory.music-kept", _music())
	_check("memory.not-clickable", not _clickable(raider))
	_check("memory.no-hover", not _hovered(raider))
	_check("memory.no-threat-arrow", not (raider in game.hostiles_in_party_los()))
	var lost_line := "Target lost: Raider is out of sight. %s's plan is paused." % p.Name
	_check("memory.plan-paused-says-why", p.is_plan_paused() and p.plan_pause_cause() == "Target lost"
		and _log_since(since, lost_line).size() == 1, [p.plan_pause_cause(), _log_tail()])
	var node := FakePlanNode.new()
	node.action_data = {"target": raider}
	_check("memory.leash-to-last-seen-not-body", p.path_drawer._node_designated_target(node) == null
		and p.path_drawer._node_lost_target_spot(node).distance_to(seen_at) < 1.0, p.path_drawer._node_lost_target_spot(node))
	# Surrender still has someone to give up to: the one it remembers.
	var SurrenderPanel = load("res://UI/SurrenderPanel.gd")
	var panel = SurrenderPanel.new()
	panel.game = game
	game.add_child(panel)
	_check("memory.surrender-counterparty-remembered", panel._pick_counterparty() == "bandits", panel._pick_counterparty())
	panel.queue_free()
	# Forgotten: the button goes and the music releases; the plan still waits
	# (it pauses on sight, not memory), saying nothing more.
	_advance(10.5)
	await _frames(3)
	_check("memory.forgotten", not _known(raider))
	await _poll()
	_check("memory.forgotten-button-gone", not _button())
	for i in int(ceil(game.COMBAT_MUSIC_RELEASE / 0.5)):
		game._update_combat_music(game.known_threats_near_party())
	_check("memory.forgotten-music-released", not _music())
	_check("memory.forgotten-plan-still-paused", p.is_plan_paused() and p.plan_pause_cause() == "Target lost")
	_check("memory.forgotten-no-more-lines", _log_since(since, "Raider").size() == 1, _log_tail())
	# Seen again: known again, the plan resumes and says so.
	raider.global_position = _ahead(200.0)
	await _settle()
	_check("memory.seen-again-known", game.is_seen_by_party(raider) and _known(raider) and _clickable(raider))
	_check("memory.seen-again-plan-resumes", not p.is_plan_paused()
		and _log_since(since, "%s can see Raider again: plan resumes." % p.Name).size() == 1, _log_tail())
	await _poll()
	_check("memory.seen-again-button", _button() and _music())
	await _despawn_all()

# ---------------------------------------------------------------------------
# 2. Toxic Shock on an NPC that leaves sight
# ---------------------------------------------------------------------------

func _case_toxic_shock_hidden_npc() -> void:
	var brute = _spawn("Venom Brute", _ahead(200.0))
	await _settle()
	_sturdy(brute)
	_check("toxic.control-seen", game.is_seen_by_party(brute))
	var since := _log_size()
	brute.condition_manager.apply_condition("poisoned", p, 4)
	await _frames(2)   # the onset tick
	var shock := _shock(brute)
	_check("toxic.onset", shock != null, str(brute.condition_manager.conditions.keys()))
	if shock == null:
		await _despawn_all()
		return
	_check("toxic.onset-logged-while-seen", _log_since(since, "Venom Brute's Poisoned reaches 4 stacks: Toxic Shock.").size() == 1, _log_tail())
	_check("toxic.no-cure-hint-for-npc", _log_since(since, "Cure Venom Brute").is_empty(), _log_tail())
	# It steps behind the wall.
	brute.global_position = wall_spot
	await _settle()
	_check("toxic.hidden", not game.is_seen_by_party(brute) and game.hidden_from_party(brute))
	_check("toxic.no-hover", not _hovered(brute))
	var hidden_since := _log_size()
	var steps0: int = shock.escalation_steps(0)
	var hp0: int = brute.current_health
	for i in 3:
		await _tick()
	_check("toxic.keeps-doubling-unseen", shock.escalation_steps(0) == steps0 + 3, [steps0, shock.escalation_steps(0)])
	_check("toxic.keeps-hurting-unseen", brute.current_health < hp0, [hp0, brute.current_health])
	# Its ticks are no contact: the memory of it (from when it left sight)
	# runs out while it ticks.
	for i in 3:
		await _tick()
	_check("toxic.ticks-are-no-contact", not game.is_threat_known(brute))
	# A null-source re-dose (Poisoned reaching 4 again) is a transform: it
	# moves the tick on, quietly, and is no contact either.
	var before: int = shock.escalation_steps(0)
	brute.condition_manager.apply_condition("poisoned", null, 4)
	await _frames(1)
	_check("toxic.redose-moves-on", _shock(brute) == shock and shock.escalation_steps(0) >= before + 1
		or shock.escalation_at_peak(0), [before, shock.escalation_steps(0)])
	_check("toxic.null-redose-no-contact", not game.is_threat_known(brute))
	# A re-dose from the party lands (contact: known), but nothing names it.
	brute.condition_manager.apply_condition("poisoned", p, 4)
	await _frames(1)
	_check("toxic.party-redose-is-contact", game.is_threat_known(brute))
	# Ticks until it dies, out of sight.
	var guard := 0
	while brute.is_alive() and guard < 30:
		await _tick()
		guard += 1
	_check("toxic.kills-unseen", not brute.is_alive(), brute.current_health)
	_check("toxic.no-warning-for-npc", _log_since(since, "will die from Toxic Shock").is_empty(), _log_tail())
	_check("toxic.unseen-never-named", _log_since(hidden_since, "Venom Brute").is_empty(), _log_since(hidden_since, "Venom Brute"))
	_check("toxic.no-death-line-unseen", _log_since(since, _death_line("Venom Brute")).is_empty())
	_check("toxic.corpse-stops-ticking", brute.condition_manager.conditions.is_empty() or not brute.is_alive())
	await _despawn_all()

# ---------------------------------------------------------------------------
# 3. Chilled to 4 stacks: Frozen
# ---------------------------------------------------------------------------

func _case_chilled_freeze_unseen() -> void:
	var seen_one = _spawn("Frostbitten", _ahead(200.0))
	var hidden_one = _spawn("Hidden Icicle", wall_spot)
	await _settle()
	_check("chill.control", game.is_seen_by_party(seen_one) and not game.is_seen_by_party(hidden_one))
	var since := _log_size()
	seen_one.condition_manager.apply_condition("chilled", p, 3)
	hidden_one.condition_manager.apply_condition("chilled", p, 3)
	_check("chill.three-not-frozen", seen_one.condition_manager.has_condition("chilled")
		and not seen_one.condition_manager.has_condition("frozen")
		and not hidden_one.condition_manager.has_condition("frozen"))
	seen_one.condition_manager.apply_condition("chilled", p, 1)
	hidden_one.condition_manager.apply_condition("chilled", p, 1)
	_check("chill.four-freezes-both", seen_one.condition_manager.has_condition("frozen")
		and hidden_one.condition_manager.has_condition("frozen"))
	_check("chill.seen-announced", _log_since(since, "Frostbitten's Chilled reaches 4 stacks: Frozen.").size() == 1, _log_tail())
	_check("chill.unseen-silent", _log_since(since, "Hidden Icicle").is_empty(), _log_since(since, "Hidden Icicle"))
	_check("chill.unseen-not-hoverable", not _hovered(hidden_one) and not _clickable(hidden_one))
	await _despawn_all()

# ---------------------------------------------------------------------------
# 4. Kinds of awareness
# ---------------------------------------------------------------------------

func _case_awareness_kinds() -> void:
	# An Invisible NPC found by a hit: seen for round 5's 5 s (clickable),
	# then remembered (known, music) but hidden, and a plan on it pauses
	# because it is invisible.
	var wraith = _spawn("Wraith", _ahead(240.0))
	await _invisible_unseen(wraith)
	_check("aware.invisible-control", not game.is_seen_by_party(wraith) and game.hidden_from_party(wraith)
		and not _known(wraith))
	p.take_damage({"bludgeoning": 1}, p.global_position, wraith)
	await _settle()
	_check("aware.invisible-hit-located", game.is_seen_by_party(wraith) and not game.hidden_from_party(wraith))
	_check("aware.invisible-hit-clickable", _clickable(wraith))
	_check("aware.invisible-hit-known", _known(wraith))
	_plan_attack(wraith)
	_advance(6.0)   # round 5's awareness (5 s) runs out before the step
	var since := _log_size()
	_resume_game()
	await _settle()
	_check("aware.invisible-lapsed-hidden", not game.is_seen_by_party(wraith) and not _clickable(wraith))
	_check("aware.invisible-lapsed-remembered", _known(wraith))
	_check("aware.invisible-plan-paused-says-invisible",
		_log_since(since, "Target lost: Wraith is invisible. %s's plan is paused." % p.Name).size() == 1, _log_tail())
	await _poll()
	_check("aware.invisible-remembered-button", _button() and _music())
	await _despawn_all()

	# Heard close by behind the party: a known threat, but nobody sees it, so
	# the player's hands don't find it (only the noise's flash shows it).
	var prowler = _spawn("Prowler", p.global_position - Vector2.UP.rotated(face) * 70.0 + Vector2.RIGHT.rotated(face) * 70.0)
	await _settle()
	_check("aware.heard-control-unseen", not game.is_seen_by_party(prowler) and not _known(prowler))
	HearingManager.emit(prowler.global_position, 1.0, prowler)
	await _frames(2)
	_check("aware.heard-close-known", _known(prowler))
	_check("aware.heard-still-hidden", game.hidden_from_party(prowler) and not _clickable(prowler)
		and not _hovered(prowler))
	await _poll()
	_check("aware.heard-button-and-music", _button() and _music())
	await _despawn_all()

	# A roof-walker in ground view: perceived (a known threat; a plan aimed at
	# it doesn't pause and its leash goes to where it stands) but not drawn,
	# so not clickable. Checked within the frame: Game._process re-derives
	# elevation and view.
	var roofer = _spawn("Roofer", _ahead(250.0))
	await _settle()
	var was_view: bool = game.roof_view
	roofer.on_roof = true
	game.roof_view = false
	_check("aware.roof-perceived-and-known", game.is_seen_by_party(roofer) and game.is_threat_known(roofer)
		and _known(roofer))
	_check("aware.roof-not-drawn-not-clickable", game.hidden_from_party(roofer) and not _clickable(roofer))
	_check("aware.roof-plan-target-not-lost", not p.plan_target_unseen(roofer))
	var node := FakePlanNode.new()
	node.action_data = {"target": roofer}
	var spot: Vector2 = p.path_drawer._node_lost_target_spot(node)
	_check("aware.roof-leash-to-where-it-stands", spot.is_finite() and spot.distance_to(roofer.global_position) < 1.0,
		[spot, roofer.global_position])
	game.roof_view = was_view
	roofer.on_roof = false
	await _despawn_all()

# ---------------------------------------------------------------------------
# 5. Surrender with known and unknown hostiles
# ---------------------------------------------------------------------------

func _case_surrender_mix() -> void:
	var SurrenderPanel = load("res://UI/SurrenderPanel.gd")
	var bandit = _spawn("Known Cutthroat", _ahead(220.0))
	var lurker = _spawn("Grave Lurker", _behind(200.0), "undead")
	await _settle()
	_check("mix.control", _known(bandit) and not _known(lurker)
		and lurker in game.hostile_characters_near_party())
	# The known one steps out of sight: still the counterparty.
	bandit.global_position = wall_spot
	await _settle()
	_check("mix.known-one-unseen-remembered", not game.is_seen_by_party(bandit) and _known(bandit))
	var panel = SurrenderPanel.new()
	panel.game = game
	game.add_child(panel)
	_check("mix.counterparty-is-the-known-one", panel._pick_counterparty() == "bandits", panel._pick_counterparty())
	panel.queue_free()
	# Forgotten: two hostiles near, neither known. No button, no counterparty.
	_advance(10.5)
	await _frames(3)
	_check("mix.both-unknown", not _known(bandit) and not _known(lurker)
		and game.hostile_characters_near_party().size() >= 2)
	await _poll()
	_check("mix.no-button", not _button())
	panel = SurrenderPanel.new()
	panel.game = game
	game.add_child(panel)
	var nobody := _log_count("No one to surrender to: no hostile you know of is near.")
	var refused := _log_count("Surrender refused")
	_check("mix.no-counterparty", not panel.try_open())
	_check("mix.no-counterparty-explained", _log_count("No one to surrender to: no hostile you know of is near.") == nobody + 1
		and _log_count("Surrender refused") == refused, _log_tail())
	panel.queue_free()
	_check("mix.neither-named", _log_count("Known Cutthroat") == 0 and _log_count("Grave Lurker") == 0, _log_tail())
	await _despawn_all()

# ---------------------------------------------------------------------------
# 6. Map change: Toxic Shock persists, awareness doesn't
# ---------------------------------------------------------------------------

func _case_map_change() -> void:
	var member = others[0]
	var who: String = member.Name
	_sturdy(member)
	member.condition_manager.apply_condition("poisoned", null, 4)
	await _frames(2)   # the onset tick (the clock stands still after it)
	var shock := _shock(member)
	_check("map.shock-on", shock != null)
	if shock == null:
		return
	shock.step_escalation(0, 2)
	shock.custom_data["lethal_warned"] = true
	var steps: int = shock.escalation_steps(0)
	var watcher = _spawn("Watcher", _ahead(220.0))
	await _settle()
	_turn(p, face + PI)
	await _settle()
	_check("map.memory-before", _known(watcher) and not game._threat_known_until.is_empty()
		and not game._npc_last_seen_time.is_empty())
	var save: Dictionary = game.build_save_dict()
	var save_text := JSON.stringify(save)
	_check("map.save-keeps-step", ("escalate_steps_0" in save_text), "Toxic Shock's step rides in the party snapshot")
	_check("map.save-has-no-awareness", not ("threat" in save_text.to_lower() and "known_until" in save_text.to_lower())
		and not ("last_seen" in save_text.to_lower()))
	_spawned.clear()   # the map change frees them
	game.load_map("perrow_tavern")
	await _frames(8)
	var nm = null
	for pc in game.party_chars:
		if is_instance_valid(pc) and pc.Name == who:
			nm = pc
	_check("map.member-respawned", nm != null and nm != member)
	if nm != null:
		var ns = _shock(nm)
		_check("map.shock-carried", ns != null)
		if ns != null:
			_check("map.step-kept", ns.escalation_steps(0) == steps, [steps, ns.escalation_steps(0)])
			_check("map.warning-not-repeated", bool(ns.custom_data.get("lethal_warned", false)))
		nm.condition_manager.remove_condition("toxic_shock")
	_check("map.memory-cleared", game._threat_known_until.is_empty())
	_check("map.last-seen-cleared", game._npc_last_seen_time.is_empty() and game._npc_last_seen_pos.is_empty())
	game.load_map("town_square")
	await _frames(10)
	if PauseManager.is_paused:
		PauseManager.unpause()
	TimeManager.pause_time()
	_restore()
	_setup()
	await _settle()
	_check("map.back-with-wall", wall_spot.is_finite())

# ---------------------------------------------------------------------------
# 7. A party member poisoned by an unseen NPC
# ---------------------------------------------------------------------------

func _case_party_member_unseen_poisoner() -> void:
	if not wall_spot.is_finite() or others.is_empty():
		return
	var victim = others[0]
	var who: String = victim.Name
	victim.condition_manager.remove_condition("toxic_shock")
	victim.condition_manager.remove_condition("poisoned")
	victim.constitution = 50
	victim.current_health = mini(30, victim.max_health)
	var poisoner = _spawn("Hidden Poisoner", _behind(200.0), "undead")
	await _settle()
	_check("victim.poisoner-unseen", not game.is_seen_by_party(poisoner) and not _known(poisoner))
	var since := _log_size()
	var hp_start: int = victim.current_health
	victim.condition_manager.apply_condition("poisoned", poisoner, 4)
	_check("victim.dose-makes-poisoner-known", _known(poisoner))
	await _frames(2)   # the onset tick
	_check("victim.toxic-shock", _shock(victim) != null)
	_check("victim.transform-logged", _log_since(since, "%s's Poisoned reaches 4 stacks: Toxic Shock." % who).size() == 1, _log_tail())
	_check("victim.cure-hint", _log_since(since, "Cure %s's Toxic Shock with Heal or a Potion of Healing" % who).size() == 1, _log_tail())
	var guard := 0
	while victim.is_alive() and guard < 12:
		await _tick()
		guard += 1
	_check("victim.dies", not victim.is_alive(), victim.current_health)
	_check("victim.warned-once", _log_since(since, "%s will die from Toxic Shock unless cured" % who).size() == 1, _log_tail(8))
	_check("victim.death-line", _log_since(since, _death_line(who)).size() == 1, _log_tail())
	_check("victim.poisoner-never-named", _log_since(since, "Hidden Poisoner").is_empty(), _log_since(since, "Hidden Poisoner"))
	_check("victim.ticks-kill-from-30", hp_start == 30 and guard <= 5, [hp_start, guard])
	# The ticks didn't keep the poisoner in mind: 10 s after the dose it is
	# forgotten (the death isn't contact either).
	_advance(10.5)
	await _frames(3)
	_check("victim.poisoner-forgotten", not _known(poisoner))
	await _despawn_all()
