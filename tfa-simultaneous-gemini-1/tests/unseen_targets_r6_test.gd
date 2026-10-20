# res://tests/unseen_targets_r6_test.gd
# Round 6, unseen-targets lane. The developer, to round 5's two questions:
#   "Ordinary out-of-sight NPCs (behind a wall, in the dark) can still be
#   clicked ... Filter all of them?"  ->  "Yes filtered for everyone"
#   "Planned attacks still follow a target that simply walks out of sight ...
#   Should leaving sight pause it too?"  ->  "Yes"
# Item A, the pickers (Game.hidden_from_party): an NPC the party doesn't see
# (behind a wall, out of range, in fog, behind the party, only flashed by a
# hearing pulse) or doesn't draw (a roof-walker in ground view) can't be
# clicked, designated, talked to, given a context menu, hovered, picked by a
# spell or marked by a preview (a projectile's burst, knockback arrows, a
# pick's highlight, the plan leash). A corpse out of sight can't be searched.
# Seen ones and party members are unchanged, and the planning pause keeps the
# set seen when the game paused.
# Item B, plans: a step about to start on a target lost for longer than
# PLAN_TARGET_LOST_GRACE pauses ("Target lost: X is out of sight. Y's plan is
# paused.", badge "Paused: Target lost"), the leash goes to where it was last
# seen, "Y can see X again: plan resumes." when it is, dropped when it dies.
# Lost for less (a blink): no pause, the step aims at the last-seen spot. A
# step under way (a swing, a spell's windup) stops homing on a target that
# leaves sight and aims at the last-seen spot, and follows it again when seen.
# A blinking target logs nothing. An attack that isn't a plan step (the AI's)
# keeps its target.
# Drives the real Game on town_square.
# Run:  godot --headless --path . res://tests/unseen_targets_r6_test.tscn
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
var wall_dir := 0.0     # a direction with a wall in the way...
var wall_spot := Vector2.INF   # ...and a spot behind it
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

func _log_tail() -> String:
	var out: Array = []
	for e in GameLog.get_entries().slice(-4):
		out.append(str(e.get("text", "")))
	return str(out)

func _advance(seconds: float) -> void:
	TimeManager.game_time += seconds

func _ready() -> void:
	# A SCRIPT ERROR aborts the coroutine; don't hang waiting for quit().
	get_tree().create_timer(300.0, true).timeout.connect(func():
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
	TimeManager.pause_time()   # game time is moved by hand
	_check("game.loaded", game.party_chars.size() > 0)
	if game.party_chars.is_empty():
		_finish()
		return
	hover = game.get_node_or_null("WorldHoverInfo")
	_setup()
	_check("setup.built-a-wall", wall_spot.is_finite(), "no second clear direction for the wall")
	await _frames(3)
	await _physics(2)
	if wall_spot.is_finite():
		_check("setup.wall-blocks-the-line", not GridManager.sight_line_clear(p.get_world_2d().direct_space_state,
			p.global_position, wall_spot, p.get_elevation(), 0.0))

	await _case_party_unchanged()
	await _case_behind_wall()
	await _case_out_of_range()
	await _case_fog()
	await _case_behind_party_and_pulse()
	await _case_roof_walker()
	await _case_paused_planning_keeps_seen()
	await _case_corpse()
	await _case_previews()
	await _case_leash()
	await _case_plan_pause_resume_drop()
	await _case_plan_blink_aims_last_seen()
	await _case_plan_swing_under_way()
	await _case_plan_cast_under_way()
	await _case_plan_no_flicker()
	await _case_ai_attack_unchanged()
	_restore()
	_finish()

func _finish() -> void:
	print("HARNESS DONE failures=%d checks=%d" % [failures, checks])
	get_tree().quit(1 if failures > 0 else 0)

# ---------------------------------------------------------------------------
# Setup and helpers
# ---------------------------------------------------------------------------

## Everyone's AI off; only the leader sees (the rest have sight 0 and stand
## behind them); the leader faces a direction with a clear 450 px sight line.
## A wall is built off to the side with a spot behind it.
func _setup() -> void:
	for c in game.characters_in_scene:
		if is_instance_valid(c):
			c.AI_enabled = false
	p = game.party_chars[0]
	p_sight = p.sight
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
	# A wall off to the side (the town square is open): a vision blocker 150 px
	# out along another clear direction, at least 90 degrees from `face` so the
	# lines ahead stay clear, with the spot behind it 300 px out.
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
		p.sight = p_sight
		# A swing still under way would stand in for the next case's.
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

func _settle() -> void:
	await _frames(3)
	await _physics(2)

## Everything the player's hands could do to `npc`, as one answer each.
func _clickable(npc) -> bool:
	return p._find_character_at(npc.global_position) == npc

func _menu(npc) -> bool:
	return p._find_context_menu_target_at(npc.global_position) == npc

func _hovered(npc) -> bool:
	return hover != null and hover.pick_character(npc.global_position) == npc

## The leader's sight scaled so its range is `px` (weather and fog aside).
func _set_range(px: float) -> void:
	var now: float = p.get_sight_range_px()
	if now > 0.0:
		p.sight = p.sight * (px / now)

## A picks-characters spell taking two picks (no auto-confirm on the first).
func _pick_ability() -> Dictionary:
	return {"display_name": "Test Pick", "target_shape": "characters", "target_count": 2, "range": 0.0,
		"target_type": "characters", "visuals": {}, "targeting": {"type": "characters", "shape": "characters"}}

# ---------------------------------------------------------------------------
# Item A: what the player's hands can find
# ---------------------------------------------------------------------------

func _case_party_unchanged() -> void:
	var member = others[0] if not others.is_empty() else null
	if member == null:
		_check("party.has-a-second-member", false, "town_square party of one")
		return
	_check("party.member-not-seen-by-leader", not p.can_see_point(member.global_position), "sanity: behind the leader")
	_check("party.never-hidden", not game.hidden_from_party(member))
	_check("party.still-clickable", p._find_character_at(member.global_position) == member)

func _case_behind_wall() -> void:
	if not wall_spot.is_finite():
		return
	var lurker = _spawn("Lurker", wall_spot)
	# Parked far off until it's its turn at the spot (one body there at a time).
	var talker = _spawn("Wallflower", _ahead(-5000.0), "neutral")
	talker.interact_options = ["Talk"]
	talker.dialogues = ["guard_greet"]
	talker.current_dialogue_index = 0
	_turn(p, wall_dir)
	await _settle()
	var range_px: float = p.get_sight_range_px()
	_check("wall.sanity-in-range-and-cone", p.global_position.distance_to(wall_spot) < range_px, [range_px, p.global_position.distance_to(wall_spot)])
	_check("wall.not-seen", not game.is_seen_by_party(lurker))
	_check("wall.not-drawn", not lurker.visible or lurker.modulate.a <= 0.0)
	_check("wall.hidden-from-party", game.hidden_from_party(lurker))
	_check("wall.not-clickable", not _clickable(lurker))
	_check("wall.no-hover-info", not _hovered(lurker))
	_check("wall.no-right-click-swing-target", p._find_context_menu_target_at(lurker.global_position) == null)
	# A peaceful one behind the wall: no talk click, no menu (Talk, Trade,
	# round 3's Attack).
	lurker.global_position = _ahead(-5000.0)
	talker.global_position = wall_spot
	await _settle()
	_check("wall.peaceful-not-seen", not game.is_seen_by_party(talker))
	_check("wall.no-talk-click", not _clickable(talker))
	_check("wall.no-menu", not _menu(talker))
	# The same two in plain view: everything works.
	talker.global_position = _ahead(220.0)
	lurker.global_position = _ahead(300.0)
	_turn(p, face)
	await _settle()
	_check("wall.control-seen", game.is_seen_by_party(lurker) and game.is_seen_by_party(talker))
	_check("wall.control-clickable", _clickable(lurker) and _clickable(talker))
	_check("wall.control-hover", _hovered(lurker))
	_check("wall.control-talker-would-talk", p._would_talk_to(talker))
	_check("wall.control-menu", _menu(talker))
	await _despawn_all()

func _case_out_of_range() -> void:
	var far = _spawn("Faraway", _ahead(300.0))
	await _settle()
	_check("range.control-seen", game.is_seen_by_party(far) and _clickable(far))
	_set_range(200.0)
	await _settle()
	_check("range.sanity-out-of-range", p.get_sight_range_px() < 300.0, p.get_sight_range_px())
	_check("range.not-seen", not game.is_seen_by_party(far))
	_check("range.not-clickable", not _clickable(far))
	_check("range.no-hover", not _hovered(far))
	_check("range.hidden-from-party", game.hidden_from_party(far))
	await _despawn_all()

func _case_fog() -> void:
	var spot := _ahead(300.0)
	var misty = _spawn("Misty", spot)
	_set_range(450.0)
	await _settle()
	_check("fog.control-seen", game.is_seen_by_party(misty) and _clickable(misty))
	var fog_ovs: Array = game.fog_manager.create_fog_from_id("thick_fog", spot)
	await _settle()
	_check("fog.sanity-fog-shortens-sight", p.get_sight_range_px_to(spot) < 300.0, p.get_sight_range_px_to(spot))
	_check("fog.not-seen", not game.is_seen_by_party(misty))
	_check("fog.not-clickable", not _clickable(misty))
	_check("fog.no-hover", not _hovered(misty))
	for o in fog_ovs:
		game.fog_manager.remove_fog(o)
	await _despawn_all()

func _case_behind_party_and_pulse() -> void:
	var sneak = _spawn("Sneak", _ahead(250.0))
	await _settle()
	_check("behind.control-seen", game.is_seen_by_party(sneak) and _clickable(sneak))
	_turn(p, face + PI)
	await _settle()
	_check("behind.not-seen", not game.is_seen_by_party(sneak))
	_check("behind.not-clickable", not _clickable(sneak))
	# Heard: the hearing pulse flashes it, but a flash isn't sight.
	game.trigger_hearing_pulse(sneak)
	await _frames(2)
	_check("pulse.flashes", sneak.visible and sneak.modulate.a > 0.0, [sneak.visible, sneak.modulate.a])
	_check("pulse.still-not-seen", not game.is_seen_by_party(sneak))
	_check("pulse.not-clickable", not _clickable(sneak))
	_check("pulse.no-hover", not _hovered(sneak))
	await _despawn_all()

func _case_roof_walker() -> void:
	var roofer = _spawn("Roofer", _ahead(250.0))
	await _settle()
	_check("roof.control-seen", game.is_seen_by_party(roofer) and not game.hidden_from_party(roofer))
	# Perceived but on the higher layer: ground view doesn't draw it. Checked
	# within the frame (Game._process re-derives the view and elevation).
	roofer.on_roof = true
	var was_view: bool = game.roof_view
	game.roof_view = false
	_check("roof.ground-view-hides", game.hidden_from_party(roofer) and not _clickable(roofer))
	game.roof_view = true
	_check("roof.roof-view-shows", game.is_seen_by_party(roofer) and not game.hidden_from_party(roofer))
	game.roof_view = was_view
	roofer.on_roof = false
	await _despawn_all()

func _case_paused_planning_keeps_seen() -> void:
	var watcher = _spawn("Watcher", _ahead(250.0))
	await _settle()
	_check("paused.control-seen", game.is_seen_by_party(watcher) and _clickable(watcher))
	PauseManager.pause()
	_turn(p, face + PI)   # the LOS pass is frozen while paused
	await _frames(3)
	_check("paused.still-seen", game.is_seen_by_party(watcher))
	_check("paused.still-clickable", _clickable(watcher))
	_check("paused.still-hovered", _hovered(watcher))
	PauseManager.unpause()
	TimeManager.pause_time()
	await _settle()
	_check("paused.unpaused-then-hidden", not game.is_seen_by_party(watcher) and not _clickable(watcher))
	await _despawn_all()

func _case_corpse() -> void:
	var fallen = _spawn("Fallen", _ahead(200.0))
	await _settle()
	fallen.take_damage({"bludgeoning": 999}, fallen.global_position, null)
	await _settle()
	_check("corpse.dead", not fallen.is_alive())
	_check("corpse.control-search-body", _menu(fallen))
	_turn(p, face + PI)
	await _settle()
	_check("corpse.out-of-sight", not game.is_seen_by_party(fallen))
	_check("corpse.no-search-body", not _menu(fallen))
	_check("corpse.no-hover", not _hovered(fallen))
	await _despawn_all()

func _case_previews() -> void:
	var t = p.targeting_system
	# A projectile AoE's burst doesn't stop on a body out of sight.
	var veil = _spawn("Veil", _ahead(150.0))
	await _settle()
	var aim: Vector2 = _ahead(400.0)
	var burst := {"display_name": "Test Fireball", "target_shape": "circle", "radius": 40.0, "range": 0.0,
		"target_type": "point", "visuals": {"projectile": "res://vfx/fireball.tscn"},
		"targeting": {"type": "point", "shape": "circle", "radius": 40.0}}
	t.start_targeting("Main", burst, aim)
	t.target_position = aim
	t._update_active_indicator()
	_check("preview.burst-control-on-seen-body", t._projectile_impact != Vector2.INF
		and t._projectile_impact.distance_to(veil.global_position) < 60.0, t._projectile_impact)
	t.end_targeting()
	_set_range(100.0)
	await _settle()
	_check("preview.burst-target-hidden", not game.is_seen_by_party(veil))
	t.start_targeting("Main", burst, aim)
	t.target_position = aim
	t._update_active_indicator()
	_check("preview.burst-not-on-hidden", t._projectile_impact == Vector2.INF, t._projectile_impact)
	t.end_targeting()
	await _despawn_all()
	# Knockback arrows: none on a body out of sight inside the blast.
	var brush = _spawn("Brush", _ahead(60.0))
	await _settle()
	var wave: Dictionary = AbilityDatabase.get_ability_data("repulsion_wave")
	_check("preview.knockback-ability", not wave.is_empty())
	if not wave.is_empty():
		t.start_targeting("Main", wave, p.global_position)
		t.target_position = p.global_position
		t._knockback_last_pos = Vector2.INF
		t._update_knockback_preview()
		_check("preview.knockback-control-arrow", _shoves_from(t, brush), t._knockback_layer.shoves)
		t.end_targeting()
		_turn(p, face + PI)
		await _settle()
		_check("preview.knockback-target-hidden", not game.is_seen_by_party(brush))
		t.start_targeting("Main", wave, p.global_position)
		t.target_position = p.global_position
		t._knockback_last_pos = Vector2.INF
		t._update_knockback_preview()
		_check("preview.knockback-no-arrow-on-hidden", not _shoves_from(t, brush), t._knockback_layer.shoves)
		t.end_targeting()
	await _despawn_all()
	# A spell's character picks: a seen one is picked and marked; out of
	# sight, its mark hides; one out of sight can't be picked (nor refused).
	var picked = _spawn("Picked", _ahead(200.0))
	var unseen = _spawn("Unseen", _ahead(260.0))
	await _settle()
	t.start_targeting("Main", _pick_ability(), picked.global_position)
	_check("pick.control-picks-seen", t._handle_character_click(picked.global_position) and picked in t.selected_targets)
	var hl = _highlight_for(t, picked)
	_check("pick.control-highlight", hl != null and hl.visible)
	_set_range(150.0)
	await _settle()
	_check("pick.targets-hidden", not game.is_seen_by_party(picked) and not game.is_seen_by_party(unseen))
	t._update_character_targeting_visuals()
	_check("pick.highlight-hidden", hl != null and is_instance_valid(hl) and not hl.visible)
	var notices := _log_count("can't target Unseen")
	_check("pick.hidden-not-picked", not t._handle_character_click(unseen.global_position) and not (unseen in t.selected_targets))
	_check("pick.hidden-not-refused", _log_count("can't target Unseen") == notices, _log_tail())
	t.end_targeting()
	await _despawn_all()

func _shoves_from(t, who) -> bool:
	for s in t._knockback_layer.shoves:
		if (s.get("from", Vector2.INF) as Vector2).distance_to(who.global_position) < 1.0:
			return true
	return false

func _highlight_for(t, who):
	for hl in t.target_highlights:
		if is_instance_valid(hl) and hl.has_meta("target") and hl.get_meta("target") == who:
			return hl
	return null

func _case_leash() -> void:
	var quarry = _spawn("Quarry", _ahead(220.0))
	await _settle()
	var node := FakePlanNode.new()
	node.action_data = {"target": quarry}
	_check("leash.control-to-body", p.path_drawer._node_designated_target(node) == quarry)
	var seen_at: Vector2 = quarry.global_position
	_turn(p, face + PI)
	await _settle()
	quarry.global_position = _ahead(260.0)   # moved on, unseen
	_check("leash.target-hidden", not game.is_seen_by_party(quarry))
	_check("leash.none-to-body", p.path_drawer._node_designated_target(node) == null)
	var spot: Vector2 = p.path_drawer._node_lost_target_spot(node)
	_check("leash.to-last-seen-spot", spot.is_finite() and spot.distance_to(seen_at) < 1.0, [spot, seen_at])
	await _despawn_all()

# ---------------------------------------------------------------------------
# Item B: plans and targets that leave sight
# ---------------------------------------------------------------------------

func _plan_attack(target, n: int = 1) -> void:
	PauseManager.pause()
	for i in n:
		p.action_queue.queue_attack_target(target, "Main")

func _resume_game() -> void:
	PauseManager.unpause()
	TimeManager.pause_time()

## Frames until the plan's step is under way (the tree takes a frame to
## unpause): a swing begun, or a cast's windup.
func _until_under_way(max_frames: int = 10) -> void:
	for i in max_frames:
		await _frames(1)
		if p.attack_animator.is_attacking or not p.ability_manager.current_cast.is_empty():
			return

func _case_plan_pause_resume_drop() -> void:
	if not wall_spot.is_finite():
		return
	var bandit = _spawn("Bandit", _ahead(220.0))
	await _settle()
	_check("plan.control-seen", game.is_seen_by_party(bandit))
	var seen_at: Vector2 = bandit.global_position
	_plan_attack(bandit)
	bandit.global_position = wall_spot   # walks off behind a wall
	_advance(1.0)                        # longer than the grace
	var lost_line := "Target lost: Bandit is out of sight. %s's plan is paused." % p.Name
	var lines := _log_count(lost_line)
	_resume_game()
	await _frames(3)
	_check("plan.target-hidden", not game.is_seen_by_party(bandit))
	_check("plan.paused", p.is_plan_paused() and p.plan_pause_cause() == "Target lost", p.plan_pause_cause())
	_check("plan.badge", p.path_drawer.pause_badge_text() == "Paused: Target lost", p.path_drawer.pause_badge_text())
	_check("plan.says-why", _log_count(lost_line) == lines + 1, _log_tail())
	_check("plan.attack-held", p.action_queue.current_action == null and p.action_queue.get_queue_size() == 1)
	var node := FakePlanNode.new()
	node.action_data = {"target": bandit}
	_check("plan.leash-to-last-seen", p.path_drawer._node_designated_target(node) == null
		and p.path_drawer._node_lost_target_spot(node).distance_to(seen_at) < 1.0, p.path_drawer._node_lost_target_spot(node))
	_advance(2.0)
	await _frames(5)
	_check("plan.still-held", p.is_plan_paused() and p.action_queue.current_action == null)
	_check("plan.one-log-per-pause", _log_count(lost_line) == lines + 1, _log_tail())
	# Back in sight: the plan carries on, said once.
	var resume_line := "%s can see Bandit again: plan resumes." % p.Name
	lines = _log_count(resume_line)
	bandit.global_position = _ahead(200.0)
	await _frames(3)
	_check("plan.resumes", not p.is_plan_paused(), p.plan_pause_cause())
	_check("plan.resume-logged", _log_count(resume_line) == lines + 1, _log_tail())
	_check("plan.attack-goes-ahead", p.action_queue.current_action != null or p.action_queue.get_queue_size() == 0)
	p.action_queue.cancel_all()
	await _frames(2)
	# Lost again, then it dies out of sight: the plan is dropped, with why.
	_plan_attack(bandit)
	bandit.global_position = wall_spot
	_advance(1.0)
	_resume_game()
	await _frames(3)
	_check("plan.paused-again", p.is_plan_paused())
	var drop_line := "%s's plan is dropped: Bandit is dead." % p.Name
	lines = _log_count(drop_line)
	bandit.take_damage({"bludgeoning": 999}, bandit.global_position, null)
	await _frames(3)
	_check("plan.dropped-when-dead", not p.is_plan_paused() and not p.has_player_orders())
	_check("plan.drop-logged", _log_count(drop_line) == lines + 1, _log_tail())
	await _despawn_all()

func _case_plan_blink_aims_last_seen() -> void:
	if not wall_spot.is_finite():
		return
	var dodger = _spawn("Dodger", _ahead(220.0))
	await _settle()
	_plan_attack(dodger)
	var seen_at: Vector2 = game.party_last_seen_position(dodger)
	_check("blink.sanity-last-seen-where-it-stood", seen_at.distance_to(dodger.global_position) < 40.0, [seen_at, dodger.global_position])
	dodger.global_position = wall_spot   # lost the moment the step comes up
	var lost := _log_count("Target lost: Dodger")
	_resume_game()
	await _until_under_way()
	_check("blink.target-hidden", not game.is_seen_by_party(dodger))
	_check("blink.no-pause", not p.is_plan_paused(), p.plan_pause_cause())
	_check("blink.no-log", _log_count("Target lost: Dodger") == lost, _log_tail())
	var step = p.action_queue.current_action
	_check("blink.step-started-on-last-seen", step != null and step.data.get("aim_lost", false), step.data if step != null else "no step")
	var want: float = (seen_at - p.global_position).angle() + PI / 2
	var not_want: float = (wall_spot - p.global_position).angle() + PI / 2
	_check("blink.faces-last-seen", absf(wrapf(p.target_rotation - want, -PI, PI)) < 0.05
		and absf(wrapf(p.target_rotation - not_want, -PI, PI)) > 0.05, [p.target_rotation, want, not_want])
	_check("blink.aim-not-on-body", p.attack_aim_node != dodger)
	if p.attack_animator.is_attacking:
		var aim = p.get_attack_aim_point()
		_check("blink.aim-at-last-seen", aim is Vector2 and (aim as Vector2).distance_to(seen_at) < 1.0, [aim, seen_at, wall_spot])
	else:
		_check("blink.swing-started", false, "the step's swing never started")
	await _despawn_all()

func _case_plan_swing_under_way() -> void:
	if not wall_spot.is_finite():
		return
	var mover = _spawn("Mover", _ahead(90.0))
	await _settle()
	_plan_attack(mover)
	_resume_game()
	await _until_under_way()
	var step = p.action_queue.current_action
	var swinging: bool = step != null and step.type == ActionQueue.ActionType.ATTACK_TARGET and p.attack_animator.is_attacking
	_check("swing.started-on-seen-target", swinging and p.attack_aim_node == mover, [step != null, p.attack_animator.is_attacking])
	if not swinging:
		await _despawn_all()
		return
	var seen_at: Vector2 = game.party_last_seen_position(mover)
	mover.global_position = wall_spot   # steps out of sight mid-swing
	await _frames(1)
	_check("swing.target-hidden", not game.is_seen_by_party(mover))
	_check("swing.still-swinging", p.attack_animator.is_attacking)
	_check("swing.aim-leaves-body", p.attack_aim_node == null)
	var aim = p.get_attack_aim_point()
	_check("swing.aims-at-last-seen", aim is Vector2 and (aim as Vector2).distance_to(seen_at) < 1.0, [aim, seen_at, wall_spot])
	mover.global_position = _ahead(110.0)   # back in sight before it lands
	await _frames(1)
	if p.attack_animator.is_attacking:
		_check("swing.follows-again-when-seen", p.attack_aim_node == mover and (p.get_attack_aim_point() as Vector2).distance_to(mover.global_position) < 1.0)
	_check("swing.no-pause", not p.is_plan_paused())
	await _despawn_all()

func _case_plan_cast_under_way() -> void:
	if not wall_spot.is_finite():
		return
	var penitent = _spawn("Penitent", _ahead(150.0))
	await _settle()
	var had_unlimited = p.get("npc_unlimited_resources")
	p.npc_unlimited_resources = true
	PauseManager.pause()
	p.action_queue.queue_ability("chasten", penitent.global_position, [penitent], penitent)
	_resume_game()
	await _until_under_way()
	var cast: Dictionary = p.ability_manager.current_cast
	var casting: bool = not cast.is_empty() and cast.get("state", "") == "casting"
	_check("cast.windup-on-seen-target", casting and cast.get("anchor") == penitent, cast.keys())
	if casting:
		var seen_at: Vector2 = game.party_last_seen_position(penitent)
		penitent.global_position = wall_spot
		await _frames(1)
		cast = p.ability_manager.current_cast
		_check("cast.target-hidden", not game.is_seen_by_party(penitent))
		_check("cast.anchor-dropped", not cast.is_empty() and cast.get("anchor") == null, cast.get("anchor"))
		_check("cast.aims-at-last-seen", (cast.get("target_position", Vector2.INF) as Vector2).distance_to(seen_at) < 1.0, cast.get("target_position"))
		_check("cast.single-target-lands-on-the-spot", (cast.get("explicit_targets", [null]) as Array).is_empty(), cast.get("explicit_targets"))
		penitent.global_position = _ahead(170.0)
		await _frames(1)
		cast = p.ability_manager.current_cast
		if not cast.is_empty():
			_check("cast.follows-again-when-seen", cast.get("anchor") == penitent and cast.get("explicit_targets", []) == [penitent], [cast.get("anchor"), cast.get("explicit_targets")])
	p.npc_unlimited_resources = had_unlimited
	p.ability_manager.cancel_cast("", true)
	await _despawn_all()

func _case_plan_no_flicker() -> void:
	if not wall_spot.is_finite():
		return
	# Three attacks on a target that ducks out of sight (a pillar) exactly as
	# each step comes up, and is back once it is under way: each unseen spell
	# is a frame, 0.1 s of game time, shorter than the grace.
	var blinker = _spawn("Blinker", _ahead(120.0))
	await _settle()
	_plan_attack(blinker, 3)
	var lost := _log_count("Target lost: Blinker")
	var back := _log_count("can see Blinker again")
	var starts := {"all": 0, "unseen": 0}
	var on_start := func(action):
		starts["all"] += 1
		if game.is_seen_by_party(blinker) == false:
			starts["unseen"] += 1
	p.action_queue.action_started.connect(on_start)
	_resume_game()
	var paused_seen := false
	var i := 0
	while (p.action_queue.current_action != null or p.action_queue.get_queue_size() > 0) and i < 3000:
		blinker.global_position = wall_spot if p.action_queue.current_action == null else _ahead(120.0)
		_advance(0.1)
		await _frames(1)
		if p.is_plan_paused():
			paused_seen = true
		i += 1
	p.action_queue.action_started.disconnect(on_start)
	_check("flicker.all-three-steps-ran", starts["all"] == 3 and not p.has_player_orders(), [starts, i])
	_check("flicker.steps-began-while-unseen", starts["unseen"] >= 2, starts)
	_check("flicker.never-paused", not paused_seen)
	_check("flicker.no-lost-lines", _log_count("Target lost: Blinker") == lost, _log_tail())
	_check("flicker.no-resume-lines", _log_count("can see Blinker again") == back, _log_tail())
	await _despawn_all()

func _case_ai_attack_unchanged() -> void:
	var ghost = _spawn("Ghost", _ahead(90.0))
	await _settle()
	_turn(p, face + PI)
	await _settle()
	_check("ai.target-hidden", not game.is_seen_by_party(ghost))
	# Not a plan step (the AI's own swing): its target stays its target.
	p.action_queue.cancel_all()
	p.attack("Main", ghost.global_position, ghost)
	await _frames(2)
	if p.attack_animator.is_attacking:
		_check("ai.swing-keeps-its-target", p.attack_aim_node == ghost)
	else:
		_check("ai.swing-started", false, "the unplanned swing never started")
	await _despawn_all()
