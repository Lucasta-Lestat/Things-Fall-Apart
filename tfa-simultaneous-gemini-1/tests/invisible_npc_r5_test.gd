# res://tests/invisible_npc_r5_test.gd
# Round 5, invisible-npc lane. The developer: "Invisible NPCs should be
# invisible, unless the party is aware of their presence for some reason, in
# which case they should be transparent like party members".
#   - No cue: an invisible NPC in plain view is not drawn, not seen
#     (is_seen_by_party, hostiles_in_party_los), not discovered as a service,
#     not hoverable, clickable or menu-able.
#   - Seen vanishing: "<NPC> turns invisible.", drawn at INVISIBLE_ALPHA (the
#     party's own value), hover says why and for how long, and after
#     INVISIBLE_AWARE_SECONDS of game time it fades out with one "You lose
#     track of <NPC> (invisible)." for a foe. A pause doesn't run it out.
#   - true_sight: seen while the true-sighted member has it in view.
#   - Hits both ways, a condition landing, a close noise: located; the unseen
#     hits say "hit by something invisible" / "hits something invisible". A
#     far noise only flashes it.
#   - A party summon is always located.
#   - Plans: an attack planned on it pauses ("Target lost: X is invisible."),
#     resumes when it is seen again, drops when it dies meanwhile.
#   - Invisible ending: seen at once ("Invisibility broken"), "appears" when it
#     wears off, "turns invisible." when a reveal window ends.
#   - Party members unchanged; awareness not saved (a load starts clear).
#   - Review: the aiming previews (a projectile's burst point, knockback
#     arrows) don't stop at or mark a hidden one; one dying in plain view is
#     announced ("<NPC> has died."); a blow traded while an attack's reveal
#     window holds Invisible back still locates it after; Invisible a party
#     member casts on an NPC reads "you saw it vanish", not "a hit".
# Drives the real Game on town_square.
# Run:  godot --headless --path . res://tests/invisible_npc_r5_test.tscn
# Judge by PASS/FAIL lines and "HARNESS DONE failures=0".
extends Node2D

var failures := 0
var checks := 0
var game = null
var hover = null
var p = null          # the party member who looks
var others: Array = []  # the rest of the party, facing away
var face := 0.0
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
	TimeManager.pause_time()   # the awareness clock is moved by hand
	_check("game.loaded", game.party_chars.size() > 0)
	if game.party_chars.is_empty():
		_finish()
		return
	hover = game.get_node_or_null("WorldHoverInfo")
	_setup()
	await _frames(3)

	await _case_party_unchanged()
	await _case_no_cue()
	await _case_service_discovery()
	await _case_seen_vanishing()
	await _case_true_sight()
	await _case_hits()
	await _case_condition_and_noise()
	await _case_summon()
	await _case_plan()
	await _case_invisible_ends()
	await _case_review()
	await _case_save_load()
	_finish()

func _finish() -> void:
	print("HARNESS DONE failures=%d checks=%d" % [failures, checks])
	get_tree().quit(1 if failures > 0 else 0)

# ---------------------------------------------------------------------------
# Setup and helpers
# ---------------------------------------------------------------------------

## Everyone's AI off (nobody walks, fights or turns), the leader faces a
## direction with a clear 450 px sight line, the rest stand behind facing away.
func _setup() -> void:
	for c in game.characters_in_scene:
		if is_instance_valid(c):
			c.AI_enabled = false
	p = game.party_chars[0]
	for deg in range(0, 360, 15):
		var a: float = deg_to_rad(deg)
		if GridManager.sight_line_clear(p.get_world_2d().direct_space_state, p.global_position,
				p.global_position + Vector2.UP.rotated(a) * 450.0, p.get_elevation(), 0.0):
			face = a
			break
	_turn(p, face)
	var i := 1
	for pc in game.party_chars:
		if pc == p:
			continue
		others.append(pc)
		pc.global_position = p.global_position - Vector2.UP.rotated(face) * (40.0 * i)
		_turn(pc, face + PI)
		i += 1

func _turn(c, ang: float) -> void:
	c.rotation = ang
	c.target_rotation = ang

func _ahead(dist: float) -> Vector2:
	return p.global_position + Vector2.UP.rotated(face) * dist

func _spawn(npc_name: String, dist: float, faction: String = "bandits"):
	var npc = game._spawn_character("default_human", _ahead(dist), {"faction": faction})
	if npc == null:
		return null
	npc.AI_enabled = false
	npc.faction_id = faction
	npc.Name = npc_name
	_turn(npc, face)
	_spawned.append(npc)
	return npc

func _despawn_all() -> void:
	for npc in _spawned:
		if is_instance_valid(npc):
			game.characters_in_scene.erase(npc)
			npc.queue_free()
	_spawned.clear()
	_turn(p, face)
	await _frames(2)

## Made invisible where the party can't see it (the leader looking away), then
## the leader faces it again: Invisible with no cue at all.
func _invisible_unseen(npc) -> void:
	_turn(p, face + PI)
	await _frames(3)
	npc.condition_manager.apply_condition("invisible", null, 1, -1.0)
	await _frames(1)
	_turn(p, face)
	await _frames(3)
	await _physics(2)

func _alpha(npc) -> float:
	return npc.modulate.a

func _raw_in_view(npc) -> bool:
	return game._is_position_visible_to_party(npc.global_position, npc.get_elevation(), npc.effective_visibility())

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

func _case_party_unchanged() -> void:
	_check("alpha.shared-constant-0.35", is_equal_approx(ProceduralCharacter.INVISIBLE_ALPHA, 0.35))
	var member = others[0] if not others.is_empty() else p
	member.condition_manager.apply_condition("invisible", null, 1, -1.0)
	await _frames(3)
	_check("party.translucent", is_equal_approx(member.modulate.a, ProceduralCharacter.INVISIBLE_ALPHA), member.modulate.a)
	_check("party.still-seen", game.is_seen_by_party(member) and member.visible)
	_check("party.no-hover-reason", game.invisible_perception_text(member) == "")
	_check("party.not-hidden-from-pickers", not game.invisible_hidden_from_party(member))
	member.condition_manager.remove_condition("invisible")
	await _frames(2)
	_check("party.solid-again", is_equal_approx(member.modulate.a, 1.0), member.modulate.a)

func _case_no_cue() -> void:
	var npc = _spawn("Shade", 300.0)
	await _frames(3)
	await _physics(2)
	_check("nocue.control-seen", game.is_seen_by_party(npc) and npc.visible and is_equal_approx(_alpha(npc), 1.0))
	_check("nocue.control-clickable", p._find_character_at(npc.global_position) == npc)
	_check("nocue.control-hostile-listed", npc in game.hostiles_in_party_los())
	var vanish_lines := _log_count("Shade turns invisible.")
	await _invisible_unseen(npc)
	_check("nocue.in-plain-view", _raw_in_view(npc), "sanity: the usual rule would see it")
	_check("nocue.not-seen", not game.is_seen_by_party(npc))
	_check("nocue.not-drawn", not npc.visible or _alpha(npc) <= 0.0, [npc.visible, _alpha(npc)])
	_check("nocue.not-in-hostiles", not (npc in game.hostiles_in_party_los()))
	_check("nocue.no-vanish-line", _log_count("Shade turns invisible.") == vanish_lines, _log_tail())
	_check("nocue.hidden-from-pickers", game.invisible_hidden_from_party(npc))
	_check("nocue.not-clickable", p._find_character_at(npc.global_position) != npc)
	_check("nocue.no-hover", hover == null or hover.pick_character(npc.global_position) != npc)
	_check("nocue.no-hover-reason", game.invisible_perception_text(npc) == "")
	# A non-hostile one: no context menu, and nothing to tell the hover cursor.
	var peddler = _spawn("Peddler", 220.0, "neutral")
	await _frames(2)
	await _physics(2)
	_check("nocue.menu-control", p._find_context_menu_target_at(peddler.global_position) == peddler)
	await _invisible_unseen(peddler)
	_check("nocue.no-menu", p._find_context_menu_target_at(peddler.global_position) != peddler)
	_check("nocue.no-talk-click", p._find_character_at(peddler.global_position) != peddler)
	# Time passing (unpaused) changes nothing without a cue.
	_advance(30.0)
	await _frames(3)
	_check("nocue.still-hidden-later", not game.is_seen_by_party(npc) and not game.is_seen_by_party(peddler))
	await _despawn_all()

func _case_service_discovery() -> void:
	var region: String = RegionDatabase.get_region_for_map(game.current_map_id)
	var smith = _spawn("Ghostsmith", 260.0, "neutral")
	smith.titles = ["Ghostsmith"]
	smith.set_meta("template_id", "r5_ghostsmith")
	_turn(p, face + PI)
	await _frames(2)
	smith.condition_manager.apply_condition("invisible", null, 1, -1.0)
	_turn(p, face)
	await _frames(3)
	var known: Array = game.known_services_per_region.get(region, [])
	_check("service.region", region != "", "town_square has a region")
	_check("service.not-discovered-while-hidden", not ("r5_ghostsmith" in known), known)
	smith.condition_manager.remove_condition("invisible")
	await _frames(2)
	known = game.known_services_per_region.get(region, [])
	_check("service.discovered-once-visible", "r5_ghostsmith" in known, known)
	await _despawn_all()

func _case_seen_vanishing() -> void:
	var npc = _spawn("Wraith", 300.0)
	await _frames(3)
	await _physics(2)
	_check("vanish.control-seen", game.is_seen_by_party(npc))
	var lines := _log_count("Wraith turns invisible.")
	npc.condition_manager.apply_condition("invisible", null, 1, -1.0)
	_check("vanish.logged", _log_count("Wraith turns invisible.") == lines + 1, _log_tail())
	await _frames(3)
	await _physics(1)
	_check("vanish.seen", game.is_seen_by_party(npc))
	_check("vanish.translucent-like-party", npc.visible and is_equal_approx(_alpha(npc), ProceduralCharacter.INVISIBLE_ALPHA), _alpha(npc))
	var why: String = game.invisible_perception_text(npc)
	_check("vanish.hover-reason", why == "Invisible — you saw it vanish (5s)", why)
	var desc: String = hover.describe_character(npc) if hover != null else ""
	_check("vanish.hover-shows-reason", "you saw it vanish" in desc, desc)
	_check("vanish.hostile-listed", npc in game.hostiles_in_party_los())
	_check("vanish.clickable", p._find_character_at(npc.global_position) == npc)
	_check("vanish.not-hidden-from-pickers", not game.invisible_hidden_from_party(npc))
	_advance(3.0)
	await _frames(2)
	_check("vanish.still-seen-at-3s", game.is_seen_by_party(npc))
	why = game.invisible_perception_text(npc)
	_check("vanish.countdown", why == "Invisible — you saw it vanish (2s)", why)
	# A pause doesn't run awareness out: the clock stops with it.
	TimeManager.resume_time()
	PauseManager.pause()
	var t0: float = TimeManager.absolute_time()
	await get_tree().create_timer(0.4, true).timeout
	_check("vanish.clock-stopped-while-paused", is_equal_approx(TimeManager.absolute_time(), t0))
	_check("vanish.still-seen-while-paused", game.is_seen_by_party(npc))
	PauseManager.unpause()
	TimeManager.pause_time()
	# Lapse.
	var lost := _log_count("You lose track of Wraith (invisible).")
	_advance(2.5)
	await _frames(2)
	_check("vanish.lapsed-not-seen", not game.is_seen_by_party(npc))
	_check("vanish.lose-track-logged", _log_count("You lose track of Wraith (invisible).") == lost + 1, _log_tail())
	_check("vanish.fades-from-translucent", npc.visible and _alpha(npc) > 0.0 and _alpha(npc) <= ProceduralCharacter.INVISIBLE_ALPHA + 0.02, [npc.visible, _alpha(npc)])
	_check("vanish.fading-not-clickable", p._find_character_at(npc.global_position) != npc)
	_check("vanish.fading-not-listed", not (npc in game.hostiles_in_party_los()))
	await get_tree().create_timer(1.0, true).timeout
	await _frames(2)
	_check("vanish.faded-out", not npc.visible or _alpha(npc) <= 0.0, [npc.visible, _alpha(npc)])
	# Located again (a hit) and lost again in the same spell: no second line.
	npc.take_damage({"bludgeoning": 1}, npc.global_position, p)
	await _frames(2)
	_check("vanish.relocated-by-hit", game.is_seen_by_party(npc))
	_advance(6.0)
	await _frames(2)
	_check("vanish.relapsed", not game.is_seen_by_party(npc))
	_check("vanish.lose-track-once-per-spell", _log_count("You lose track of Wraith (invisible).") == lost + 1, _log_tail())
	await _despawn_all()

func _case_true_sight() -> void:
	var npc = _spawn("Ghost", 300.0)
	await _invisible_unseen(npc)
	_check("truesight.control-hidden", not game.is_seen_by_party(npc))
	p.traits["true_sight"] = 1
	await _frames(2)
	_check("truesight.seen", game.is_seen_by_party(npc))
	_check("truesight.translucent", npc.visible and is_equal_approx(_alpha(npc), ProceduralCharacter.INVISIBLE_ALPHA), _alpha(npc))
	var why: String = game.invisible_perception_text(npc)
	_check("truesight.hover-reason", why == "Invisible — seen by %s's true sight" % p.Name, why)
	_turn(p, face + PI)
	await _frames(2)
	_check("truesight.only-while-in-sight", not game.is_seen_by_party(npc))
	_turn(p, face)
	await _frames(2)
	_check("truesight.back-in-sight", game.is_seen_by_party(npc))
	p.traits.erase("true_sight")
	await _frames(2)
	_check("truesight.gone-with-trait", not game.is_seen_by_party(npc))
	await _despawn_all()

func _case_hits() -> void:
	# A party member strikes something it can't see.
	var lurker = _spawn("Lurker", 250.0)
	await _invisible_unseen(lurker)
	_check("hit.control-hidden", not game.is_seen_by_party(lurker))
	var lines := _log_count("%s hits something invisible." % p.Name)
	lurker.take_damage({"bludgeoning": 2}, lurker.global_position, p)
	_check("hit.party-hit-logged", _log_count("%s hits something invisible." % p.Name) == lines + 1, _log_tail())
	await _frames(2)
	_check("hit.party-hit-locates", game.is_seen_by_party(lurker))
	_check("hit.party-hit-translucent", lurker.visible and is_equal_approx(_alpha(lurker), ProceduralCharacter.INVISIBLE_ALPHA))
	var why: String = game.invisible_perception_text(lurker)
	_check("hit.hover-reason", why.begins_with("Invisible — located by a hit"), why)
	# Something it can't see strikes a party member.
	var stalker = _spawn("Stalker", 350.0)
	await _invisible_unseen(stalker)
	_check("hit.control-hidden-2", not game.is_seen_by_party(stalker))
	lines = _log_count("%s is hit by something invisible." % p.Name)
	p.take_damage({"bludgeoning": 1}, p.global_position, stalker)
	_check("hit.party-struck-logged", _log_count("%s is hit by something invisible." % p.Name) == lines + 1, _log_tail())
	await _frames(2)
	_check("hit.party-struck-locates", game.is_seen_by_party(stalker))
	# Seen once, a later unseen hit names it.
	_advance(6.0)
	await _frames(2)
	_check("hit.lapsed", not game.is_seen_by_party(stalker))
	lines = _log_count("%s is hit by Stalker (invisible)." % p.Name)
	p.take_damage({"bludgeoning": 1}, p.global_position, stalker)
	_check("hit.named-once-seen", _log_count("%s is hit by Stalker (invisible)." % p.Name) == lines + 1, _log_tail())
	# A damage-over-time tick is no new blow.
	_advance(6.0)
	await _frames(2)
	stalker._condition_tick_damage = true
	stalker.take_damage({"bludgeoning": 1}, stalker.global_position, p)
	stalker._condition_tick_damage = false
	await _frames(2)
	_check("hit.dot-tick-no-cue", not game.is_seen_by_party(stalker))
	await _despawn_all()

func _case_condition_and_noise() -> void:
	# A condition a party member puts on it lands: located.
	var mark = _spawn("Marked", 300.0)
	await _invisible_unseen(mark)
	mark.condition_manager.apply_condition("mighty", p, 1)
	await _frames(2)
	_check("contact.condition-locates", game.is_seen_by_party(mark))
	await _despawn_all()
	# Heard close by (within 2 tiles): located.
	var creeper = _spawn("Creeper", 100.0)
	await _invisible_unseen(creeper)
	_check("noise.control-hidden", not game.is_seen_by_party(creeper))
	HearingManager.emit(creeper.global_position, 1.0, creeper)
	await _frames(2)
	_check("noise.close-locates", game.is_seen_by_party(creeper))
	var why: String = game.invisible_perception_text(creeper)
	_check("noise.hover-reason", why.begins_with("Invisible — heard close by"), why)
	await _despawn_all()
	# Heard farther off: only the hearing pulse's flash, as for anyone unseen.
	var walker = _spawn("Walker", 420.0)
	await _frames(3)
	_check("noise.far-control-seen-first", game.is_seen_by_party(walker))
	_turn(p, face + PI)
	await _frames(2)
	walker.condition_manager.apply_condition("invisible", null, 1, -1.0)
	_turn(p, face)
	await _frames(3)
	_check("noise.far-control-hidden", not game.is_seen_by_party(walker))
	HearingManager.emit(walker.global_position, 1.9, walker)
	await _frames(2)
	_check("noise.far-not-located", not game.is_seen_by_party(walker))
	_check("noise.far-flashes", walker.visible and _alpha(walker) > 0.0, [walker.visible, _alpha(walker)])
	await _despawn_all()

func _case_summon() -> void:
	var imp = _spawn("Imp", 260.0, "player")
	imp.set_meta("summoned_by", p)
	await _invisible_unseen(imp)
	_check("summon.located", game.is_seen_by_party(imp))
	_check("summon.translucent", imp.visible and is_equal_approx(_alpha(imp), ProceduralCharacter.INVISIBLE_ALPHA))
	var why: String = game.invisible_perception_text(imp)
	_check("summon.hover-reason", why == "Invisible — summoned by %s" % p.Name, why)
	await _despawn_all()

func _case_plan() -> void:
	var target = _spawn("Target", 220.0)
	await _frames(3)
	_check("plan.control-seen", game.is_seen_by_party(target))
	var leash_node := FakePlanNode.new()
	leash_node.action_data = {"target": target}
	_check("plan.leash-control", p.path_drawer != null and p.path_drawer._node_designated_target(leash_node) == target)
	PauseManager.pause()
	p.action_queue.queue_attack_target(target, "Main")
	target.condition_manager.apply_condition("invisible", null, 1, -1.0)
	_advance(6.0)   # past the "saw it vanish" window
	var lost_line := "Target lost: Target is invisible. %s's plan is paused." % p.Name
	var lines := _log_count(lost_line)
	PauseManager.unpause()
	TimeManager.pause_time()
	await _frames(3)
	_check("plan.target-hidden", not game.is_seen_by_party(target))
	_check("plan.paused", p.is_plan_paused() and p.plan_pause_cause() == "Target lost", p.plan_pause_cause())
	_check("plan.says-why", _log_count(lost_line) == lines + 1, _log_tail())
	_check("plan.attack-held", p.action_queue.current_action == null and p.action_queue.get_queue_size() == 1)
	_check("plan.no-leash-to-hidden", p.path_drawer._node_designated_target(leash_node) == null)
	await _frames(5)
	_check("plan.still-held", p.is_plan_paused() and p.action_queue.current_action == null)
	# Located again (it lands a hit): the plan carries on.
	var resume_line := "%s can see Target again: plan resumes." % p.Name
	lines = _log_count(resume_line)
	p.take_damage({"bludgeoning": 1}, p.global_position, target)
	await _frames(3)
	_check("plan.resumes", not p.is_plan_paused(), p.plan_pause_cause())
	_check("plan.resume-logged", _log_count(resume_line) == lines + 1, _log_tail())
	p.action_queue.cancel_all()
	await _frames(2)
	# Hidden again, then it dies: the plan is dropped, with the reason.
	_advance(6.0)
	await _frames(2)
	PauseManager.pause()
	p.action_queue.queue_attack_target(target, "Main")
	PauseManager.unpause()
	TimeManager.pause_time()
	await _frames(3)
	_check("plan.paused-again", p.is_plan_paused())
	var drop_line := "%s's plan is dropped: Target is dead." % p.Name
	lines = _log_count(drop_line)
	target.take_damage({"bludgeoning": 999}, target.global_position, null)
	await _frames(3)
	_check("plan.dropped-when-dead", not p.is_plan_paused() and not p.has_player_orders())
	_check("plan.drop-logged", _log_count(drop_line) == lines + 1, _log_tail())
	p.action_queue.cancel_all()
	await _despawn_all()

func _case_invisible_ends() -> void:
	# Removed while hidden: seen at once, solid.
	var npc = _spawn("Faded", 300.0)
	await _invisible_unseen(npc)
	_check("ends.control-hidden", not game.is_seen_by_party(npc))
	npc.condition_manager.remove_condition("invisible")
	_check("ends.seen-at-once", game.is_seen_by_party(npc))
	await _frames(2)
	_check("ends.solid", npc.visible and is_equal_approx(_alpha(npc), 1.0), _alpha(npc))
	await _despawn_all()
	# Wears off while hidden: it appears, and says so.
	var timed = _spawn("Fleeting", 300.0)
	_turn(p, face + PI)
	await _frames(2)
	timed.condition_manager.apply_condition("invisible", null, 1, 2.0)
	_turn(p, face)
	await _frames(3)
	_check("ends.timed-hidden", not game.is_seen_by_party(timed))
	var lines := _log_count("Fleeting appears: their invisibility wore off.")
	_advance(3.0)
	await _frames(3)
	_check("ends.timed-ran-out", not timed.condition_manager.has_condition("invisible"))
	_check("ends.appears-logged", _log_count("Fleeting appears: their invisibility wore off.") == lines + 1, _log_tail())
	_check("ends.timed-seen-solid", game.is_seen_by_party(timed) and is_equal_approx(_alpha(timed), 1.0))
	await _despawn_all()
	# Broken by its own attack while hidden: the break is announced.
	var striker = _spawn("Striker", 300.0)
	await _invisible_unseen(striker)
	lines = _log_count("Striker's invisibility breaks: attacking ends it.")
	striker.reveal()
	_check("ends.break-announced", _log_count("Striker's invisibility breaks: attacking ends it.") == lines + 1, _log_tail())
	await _frames(2)
	_check("ends.break-seen", game.is_seen_by_party(striker) and is_equal_approx(_alpha(striker), 1.0))
	await _despawn_all()
	# A reveal window ending in view: "turns invisible." again, located.
	var cloaked = _spawn("Cloaked", 300.0)
	await _invisible_unseen(cloaked)
	cloaked.condition_manager.suppress_for("invisible", 3.0, "attacking")
	await _frames(2)
	_check("ends.window-seen-solid", game.is_seen_by_party(cloaked) and is_equal_approx(_alpha(cloaked), 1.0))
	lines = _log_count("Cloaked turns invisible.")
	_advance(3.5)
	await _frames(3)
	_check("ends.window-closed", cloaked.condition_manager.has_active_condition("invisible"))
	_check("ends.window-turns-invisible-logged", _log_count("Cloaked turns invisible.") == lines + 1, _log_tail())
	_check("ends.window-located", game.is_seen_by_party(cloaked) and is_equal_approx(_alpha(cloaked), ProceduralCharacter.INVISIBLE_ALPHA))
	await _despawn_all()

func _case_review() -> void:
	# A projectile AoE's preview: no burst on a hidden body in the line of fire.
	var veil = _spawn("Veil", 150.0)
	await _frames(3)
	await _physics(2)
	var t = p.targeting_system
	var aim: Vector2 = _ahead(400.0)
	var burst := {"display_name": "Test Fireball", "target_shape": "circle", "radius": 40.0, "range": 0.0,
		"target_type": "point", "visuals": {"projectile": "res://vfx/fireball.tscn"},
		"targeting": {"type": "point", "shape": "circle", "radius": 40.0}}
	t.start_targeting("Main", burst, aim)
	t.target_position = aim
	t._update_active_indicator()
	_check("review.preview-control-visible-body", t._projectile_impact != Vector2.INF, t._projectile_impact)
	t.end_targeting()
	await _invisible_unseen(veil)
	_check("review.preview-control-hidden", not game.is_seen_by_party(veil))
	t.start_targeting("Main", burst, aim)
	t.target_position = aim
	t._update_active_indicator()
	_check("review.preview-burst-not-on-hidden", t._projectile_impact == Vector2.INF
		and t.circle_indicator.global_position.distance_to(aim) < 0.5, [t._projectile_impact, t.circle_indicator.global_position])
	# Located (a hit): it stops the preview as anyone seen does.
	veil.take_damage({"bludgeoning": 1}, veil.global_position, p)
	await _frames(2)
	t.target_position = aim   # the frames in between aimed it at the (headless) mouse
	t._update_active_indicator()
	_check("review.preview-burst-on-located", game.is_seen_by_party(veil) and t._projectile_impact != Vector2.INF
		and t._projectile_impact.distance_to(veil.global_position) < 60.0, t._projectile_impact)
	t.end_targeting()
	await _despawn_all()
	# Knockback arrows: none on a hidden body inside the blast.
	var brush = _spawn("Brush", 60.0)
	await _invisible_unseen(brush)
	var wave: Dictionary = AbilityDatabase.get_ability_data("repulsion_wave")
	_check("review.knockback-ability", not wave.is_empty())
	if not wave.is_empty():
		t.start_targeting("Main", wave, p.global_position)
		t.target_position = p.global_position
		t._knockback_last_pos = Vector2.INF
		t._update_knockback_preview()
		_check("review.knockback-no-arrow-on-hidden", not _shoves_from(t, brush), t._knockback_layer.shoves)
		brush.take_damage({"bludgeoning": 1}, brush.global_position, p)
		await _frames(2)
		t.target_position = p.global_position
		t._knockback_last_pos = Vector2.INF
		t._update_knockback_preview()
		_check("review.knockback-arrow-on-located", _shoves_from(t, brush), t._knockback_layer.shoves)
		t.end_targeting()
	await _despawn_all()
	# Dying in plain view while hidden: announced, the body seen at once.
	var doomed = _spawn("Doomed", 250.0)
	await _invisible_unseen(doomed)
	var died := _log_count("Doomed has died.")
	doomed.take_damage({"bludgeoning": 999}, doomed.global_position, p)
	_check("review.death-announced", _log_count("Doomed has died.") == died + 1, _log_tail())
	await _frames(2)
	_check("review.corpse-seen-solid", game.is_seen_by_party(doomed) and doomed.visible and is_equal_approx(_alpha(doomed), 1.0), _alpha(doomed))
	# Out of the party's view: still quiet.
	var unwatched = _spawn("Unwatched", 250.0)
	await _invisible_unseen(unwatched)
	_turn(p, face + PI)
	await _frames(2)
	died = _log_count("Unwatched has died.")
	unwatched.take_damage({"bludgeoning": 999}, unwatched.global_position, null)
	_check("review.unseen-death-quiet", _log_count("Unwatched has died.") == died, _log_tail())
	_turn(p, face)
	await _despawn_all()
	# A blow traded while an attack's reveal window holds Invisible back (the
	# party looking away): no "something invisible" (it wasn't), but the party
	# still knows where it is when the cloak has it back.
	var cloak = _spawn("Cloak", 300.0)
	await _invisible_unseen(cloak)
	_turn(p, face + PI)
	await _frames(2)
	cloak.condition_manager.suppress_for("invisible", 3.0, "attacking")
	var odd := _log_count("is hit by something invisible.")
	p.take_damage({"bludgeoning": 1}, p.global_position, cloak)
	_check("review.window-hit-not-called-invisible", _log_count("is hit by something invisible.") == odd, _log_tail())
	_advance(3.5)
	await _frames(3)
	_check("review.window-over", cloak.condition_manager.has_active_condition("invisible"))
	_turn(p, face)
	await _frames(2)
	_check("review.window-hit-locates", game.is_seen_by_party(cloak) and is_equal_approx(_alpha(cloak), ProceduralCharacter.INVISIBLE_ALPHA), _alpha(cloak))
	var why: String = game.invisible_perception_text(cloak)
	_check("review.window-hit-reason", why.begins_with("Invisible — located by a hit"), why)
	await _despawn_all()
	# Invisible a party member puts on an NPC in view: "saw it vanish".
	var ward = _spawn("Ward", 300.0, "neutral")
	await _frames(3)
	await _physics(1)
	ward.condition_manager.apply_condition("invisible", p, 1, -1.0)
	await _frames(2)
	why = game.invisible_perception_text(ward)
	_check("review.cast-invisible-reason", why.begins_with("Invisible — you saw it vanish"), why)
	await _despawn_all()

## True when the knockback preview draws an arrow from `who`.
func _shoves_from(t, who) -> bool:
	for s in t._knockback_layer.shoves:
		if (s.get("from", Vector2.INF) as Vector2).distance_to(who.global_position) < 1.0:
			return true
	return false

func _case_save_load() -> void:
	var npc = _spawn("Remembered", 300.0)
	await _frames(3)
	npc.condition_manager.apply_condition("invisible", null, 1, -1.0)
	await _frames(2)
	_check("save.aware-before", game.is_seen_by_party(npc) and not game._invisible_aware_until.is_empty())
	p.condition_manager.apply_condition("invisible", null, 1, -1.0)
	var d: Dictionary = game.build_save_dict()
	_check("save.no-awareness-saved", not JSON.stringify(d).contains("aware"))
	game.load_save(d)
	await _frames(10)
	if PauseManager.is_paused:
		PauseManager.unpause()
	TimeManager.pause_time()
	_check("load.awareness-cleared", game._invisible_aware_until.is_empty() and game._invisible_lost_said.is_empty())
	_spawned.clear()
	others.clear()
	_setup()
	await _frames(3)
	var leader = p
	_check("load.party-invisible-still-translucent", leader.condition_manager.has_active_condition("invisible")
		and is_equal_approx(leader.modulate.a, ProceduralCharacter.INVISIBLE_ALPHA), leader.modulate.a)
	leader.condition_manager.remove_condition("invisible")
	# A service NPC that was invisible when saved: back invisible and, in
	# plain view, hidden until a cue.
	var darcy = null
	for c in game.characters_in_scene:
		if is_instance_valid(c) and not (c in game.party_chars) and str(c.get_meta("template_id", "")) == "smith_darcy":
			darcy = c
	if darcy == null:
		print("SKIP load.darcy (no smith_darcy on the map)")
		return
	darcy.condition_manager.apply_condition("invisible", null, 1, -1.0)
	var d2: Dictionary = game.build_save_dict()
	game.load_save(d2)
	await _frames(10)
	if PauseManager.is_paused:
		PauseManager.unpause()
	TimeManager.pause_time()
	others.clear()
	_setup()
	darcy = null
	for c in game.characters_in_scene:
		if is_instance_valid(c) and not (c in game.party_chars) and str(c.get_meta("template_id", "")) == "smith_darcy":
			darcy = c
	_check("load.darcy-back", darcy != null)
	if darcy == null:
		return
	_check("load.darcy-still-invisible", darcy.condition_manager.has_active_condition("invisible"))
	darcy.global_position = _ahead(260.0)
	await _frames(3)
	_check("load.in-view-hidden-without-cue", _raw_in_view(darcy) and not game.is_seen_by_party(darcy))
	darcy.take_damage({"bludgeoning": 1}, darcy.global_position, p)
	await _frames(2)
	_check("load.cue-locates", game.is_seen_by_party(darcy))
	darcy.condition_manager.remove_condition("invisible")
