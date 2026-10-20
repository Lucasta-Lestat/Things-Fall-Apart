# res://tests/threat_awareness_r6_test.gd
# Round 6, threat-awareness lane. The developer: "No combat music or surrender
# option until the party is aware of the threat".
#   - A hostile near the party that it doesn't perceive (an invisible one in
#     plain view, an ordinary one behind everyone's back) starts no combat
#     music and shows no Surrender button (Game.known_threats_near_party).
#   - Seen: both. Lost from view (behind a wall, or the party turning away):
#     kept for THREAT_MEMORY_SECONDS of game time (a pause doesn't run it
#     out), then the button goes and the music releases COMBAT_MUSIC_RELEASE
#     later.
#   - An unseen attacker's hit on a party member makes it known at once; so
#     does a party member's hit on it, a condition either way, and a noise
#     close by; a far noise doesn't, unless the party already knew of it. A
#     damage-over-time tick is no new contact.
#   - The SurrenderPanel picks its counterparty from known threats only, and
#     a robbery's truce still covers the unseen members of that faction.
#   - Naming leaks: a damage cancellation names an attacker only when the
#     party sees it ("a hit from someone unseen"); sickness spreading,
#     vomiting, an animal appearing, a disarm and a dialogue's "Combat!" line
#     don't name NPCs the party can't see.
# Drives the real Game on town_square.
# Run:  godot --headless --path . res://tests/threat_awareness_r6_test.tscn
# Judge by PASS/FAIL lines and "HARNESS DONE failures=0".
extends Node2D

var failures := 0
var checks := 0
var game = null
var p = null           # the party member who looks
var others: Array = [] # the rest of the party, blinded so only p perceives
var face := 0.0
var _spawned: Array = []

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

func _log_tail(k: int = 4) -> String:
	var out: Array = []
	for e in GameLog.get_entries().slice(-k):
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
	TimeManager.pause_time()   # the memory clock is moved by hand
	_check("game.loaded", game.party_chars.size() > 0)
	if game.party_chars.is_empty():
		_finish()
		return
	_setup()
	await _frames(3)
	await _physics(2)

	await _case_control()
	await _case_unseen_hostiles()
	await _case_seen()
	await _case_memory()
	await _case_contacts()
	await _case_noise()
	await _case_surrender_panel()
	await _case_cancel_naming()
	await _case_custom_effects()
	await _case_disarm()
	await _case_dialogue_combat()
	_finish()

func _finish() -> void:
	for pc in others:
		if is_instance_valid(pc):
			pc.condition_manager.remove_condition("blinded")
	print("HARNESS DONE failures=%d checks=%d" % [failures, checks])
	get_tree().quit(1 if failures > 0 else 0)

# ---------------------------------------------------------------------------
# Setup and helpers
# ---------------------------------------------------------------------------

## Everyone's AI off (nobody walks, fights or turns). The leader faces a
## direction with a clear 450 px sight line; the rest stand beside it and are
## blinded, so what the party perceives is exactly what the leader sees.
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
		pc.global_position = p.global_position + Vector2.RIGHT.rotated(face) * (40.0 * i)
		_turn(pc, face)
		pc.condition_manager.apply_condition("blinded", null, 1, -1.0)
		i += 1

func _turn(c, ang: float) -> void:
	c.rotation = ang
	c.target_rotation = ang

func _ahead(dist: float) -> Vector2:
	return p.global_position + Vector2.UP.rotated(face) * dist

func _behind(dist: float) -> Vector2:
	return p.global_position - Vector2.UP.rotated(face) * dist

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
	for npc in _spawned:
		if is_instance_valid(npc):
			game.characters_in_scene.erase(npc)
			npc.queue_free()
	_spawned.clear()
	_turn(p, face)
	await _frames(2)
	_reset_awareness_ui()

## Music off and the button hidden, as before any fight.
func _reset_awareness_ui() -> void:
	game._combat_music_calm_for = game.COMBAT_MUSIC_RELEASE
	MusicManager.set_combat(false)
	game._update_surrender_button([])

## Invisible applied where the party can't see it (the leader looking away),
## then the leader faces it again: Invisible with no cue at all.
func _invisible_unseen(npc) -> void:
	_turn(p, face + PI)
	await _frames(3)
	npc.condition_manager.apply_condition("invisible", null, 1, -1.0)
	await _frames(1)
	_turn(p, face)
	await _frames(3)
	await _physics(2)

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

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

func _case_control() -> void:
	_reset_awareness_ui()
	_check("control.no-hostiles-on-map", game.hostile_characters_near_party().is_empty(),
		str(game.hostile_characters_near_party()))
	_check("control.memory-constants", is_equal_approx(game.THREAT_MEMORY_SECONDS, 10.0) \
		and is_equal_approx(game.THREAT_HEARD_TILES, 2.0))
	var tip: String = game._surrender_button.tooltip_text if game._surrender_button else ""
	_check("control.button-tooltip-states-rule", "you know are near" in tip and "10 s" in tip, tip)
	await _poll()
	_check("control.no-button", not _button())
	_check("control.no-music", not _music())

func _case_unseen_hostiles() -> void:
	# An invisible bandit in plain view the party has no cue about.
	var ghost = _spawn("Ghost Bandit", _ahead(300.0))
	await _invisible_unseen(ghost)
	# An ordinary bandit behind everyone's back.
	var lurker = _spawn("Lurker", _behind(250.0))
	await _frames(3)
	await _physics(2)
	_check("unseen.sanity-hostile-and-near", ghost in game.hostile_characters_near_party() \
		and lurker in game.hostile_characters_near_party(), str(game.hostile_characters_near_party()))
	_check("unseen.sanity-not-perceived", not game.is_seen_by_party(ghost) and not game.is_seen_by_party(lurker))
	_check("unseen.not-known", not _known(ghost) and not _known(lurker), str(game.known_threats_near_party()))
	await _poll()
	_check("unseen.no-surrender-button", not _button())
	_check("unseen.no-combat-music", not _music())
	# Time passing changes nothing without a cue.
	_advance(30.0)
	await _poll()
	_check("unseen.still-nothing-later", not _button() and not _music())
	await _despawn_all()

func _case_seen() -> void:
	var brute = _spawn("Brute", _ahead(300.0))
	await _frames(3)
	await _physics(2)
	_check("seen.perceived", game.is_seen_by_party(brute))
	_check("seen.known", _known(brute))
	await _poll()
	_check("seen.surrender-button", _button())
	_check("seen.combat-music", _music())
	# A seen one that isn't hostile is no threat.
	var peddler = _spawn("Peddler", _ahead(200.0), "neutral")
	await _frames(3)
	_check("seen.neutral-not-a-threat", game.is_seen_by_party(peddler) and not _known(peddler))
	# Too far off (outside SURRENDER_RADIUS of every party member) isn't near.
	brute.global_position = p.global_position + Vector2.UP.rotated(face) * (game.SURRENDER_RADIUS + 200.0)
	await _frames(2)
	_check("seen.far-not-near", not _known(brute))
	await _despawn_all()

## A wall across the leader's view, `dist` ahead of it: a vision blocker
## (the town square around the party is open ground).
func _build_wall(dist: float) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.collision_layer = CollisionLayers.VISION_BLOCKERS
	body.collision_mask = 0
	var cs := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(320, 40)
	cs.shape = rect
	body.add_child(cs)
	body.rotation = face
	body.global_position = _ahead(dist)
	game.add_child(body)
	return body

func _case_memory() -> void:
	var foe = _spawn("Skulker", _ahead(120.0))
	await _frames(3)
	await _physics(2)
	_check("memory.seen-first", game.is_seen_by_party(foe))
	await _poll()
	_check("memory.button-while-seen", _button() and _music())
	# It steps behind a wall.
	var wall := _build_wall(200.0)
	await _physics(2)
	await _frames(2)
	_check("memory.wall-control-seen-in-front", game.is_seen_by_party(foe))
	foe.global_position = _ahead(320.0)
	await _frames(3)
	await _physics(2)
	_check("memory.wall-blocks-sight", not GridManager.sight_line_clear(p.get_world_2d().direct_space_state,
		p.global_position, foe.global_position, p.get_elevation(), 0.0))
	_check("memory.lost-from-view", not game.is_seen_by_party(foe))
	_check("memory.still-known", _known(foe))
	await _poll()
	_check("memory.button-kept", _button())
	_check("memory.music-kept", _music())
	_advance(9.0)
	await _frames(2)
	_check("memory.known-at-9s", _known(foe))
	# A pause doesn't run the memory out: the clock stops with it.
	TimeManager.resume_time()
	PauseManager.pause()
	var t0: float = TimeManager.absolute_time()
	await get_tree().create_timer(0.4, true).timeout
	_check("memory.clock-stopped-while-paused", is_equal_approx(TimeManager.absolute_time(), t0))
	_check("memory.known-while-paused", _known(foe))
	PauseManager.unpause()
	TimeManager.pause_time()
	_advance(1.5)
	await _frames(2)
	_check("memory.forgotten-after-10s", not _known(foe))
	await _poll()
	_check("memory.button-gone", not _button())
	_check("memory.music-holds-for-release", _music(), "COMBAT_MUSIC_RELEASE debounce")
	for i in int(ceil(game.COMBAT_MUSIC_RELEASE / 0.5)):
		game._update_combat_music(game.known_threats_near_party())
	_check("memory.music-released", not _music())
	wall.queue_free()
	await _despawn_all()

func _case_contacts() -> void:
	# An unseen attacker strikes a party member: known at once.
	var archer = _spawn("Hidden Archer", _behind(300.0))
	await _frames(3)
	await _physics(2)
	_check("contact.control-unseen", not game.is_seen_by_party(archer) and not _known(archer))
	p.take_damage({"bludgeoning": 1}, p.global_position, archer)
	_check("contact.hit-by-unseen-known-at-once", _known(archer))
	await _poll()
	_check("contact.hit-by-unseen-button", _button())
	_check("contact.hit-by-unseen-music", _music())
	_check("contact.hit-by-unseen-not-named", _log_count("Hidden Archer") == 0, _log_tail())
	await _despawn_all()
	# An invisible one: the round-5 notice, and known.
	var stalker = _spawn("Stalker", _ahead(300.0))
	await _invisible_unseen(stalker)
	var lines := _log_count("%s is hit by something invisible." % p.Name)
	p.take_damage({"bludgeoning": 1}, p.global_position, stalker)
	_check("contact.invisible-hit-notice", _log_count("%s is hit by something invisible." % p.Name) == lines + 1, _log_tail())
	_check("contact.invisible-attacker-known", _known(stalker))
	await _frames(3)
	_check("contact.invisible-located-by-hit", game.is_seen_by_party(stalker))
	# Still known once round 5's 5 s awareness of it has run out: it was
	# perceived until then, so the memory runs from that moment.
	_advance(7.0)
	await _frames(3)
	_check("contact.invisible-awareness-lapsed", not game.is_seen_by_party(stalker))
	_check("contact.invisible-still-remembered", _known(stalker))
	_advance(9.0)
	await _frames(2)
	_check("contact.invisible-remembered-9s-after-lapse", _known(stalker))
	_advance(1.5)
	await _frames(2)
	_check("contact.invisible-forgotten-later", not _known(stalker))
	await _despawn_all()
	# A party member hits something it can't see.
	var target = _spawn("Shadow", _behind(200.0))
	await _frames(3)
	target.take_damage({"bludgeoning": 1}, target.global_position, p)
	_check("contact.party-hit-makes-known", _known(target))
	await _despawn_all()
	# A condition the unseen one puts on a party member.
	var hexer = _spawn("Hexer", _behind(250.0))
	await _frames(3)
	_check("contact.condition-control", not _known(hexer))
	p.condition_manager.apply_condition("chilled", hexer, 1)
	_check("contact.condition-makes-known", _known(hexer))
	p.condition_manager.remove_condition("chilled")
	await _despawn_all()
	# A damage-over-time tick from an unseen one is no new contact.
	var burner = _spawn("Burner", _behind(250.0))
	await _frames(3)
	p._condition_tick_damage = true
	p.take_damage({"fire": 1}, p.global_position, burner)
	p._condition_tick_damage = false
	_check("contact.dot-tick-not-a-cue", not _known(burner))
	await _poll()
	_check("contact.dot-tick-no-button", not _button() and not _music())
	await _despawn_all()

func _case_noise() -> void:
	# Heard farther off than THREAT_HEARD_TILES: a flash, not a known threat.
	var walker = _spawn("Walker", _behind(300.0))
	await _frames(3)
	await _physics(2)
	_check("noise.control-unseen", not game.is_seen_by_party(walker))
	HearingManager.emit(walker.global_position, 1.9, walker)
	await _frames(2)
	_check("noise.far-not-known", not _known(walker))
	await _poll()
	_check("noise.far-no-button", not _button() and not _music())
	# Close by: known.
	walker.global_position = _behind(100.0)
	await _frames(2)
	HearingManager.emit(walker.global_position, 1.0, walker)
	await _frames(2)
	_check("noise.close-known", _known(walker))
	await _despawn_all()
	# A far noise keeps one the party already knew of in mind.
	var pacer = _spawn("Pacer", _ahead(300.0))
	await _frames(3)
	await _physics(2)
	_check("noise.pacer-seen", game.is_seen_by_party(pacer))
	_turn(p, face + PI)
	await _frames(3)
	await _physics(1)
	_check("noise.pacer-lost", not game.is_seen_by_party(pacer) and _known(pacer))
	_advance(8.0)
	HearingManager.emit(pacer.global_position, 1.9, pacer)
	await _frames(2)
	_advance(8.0)
	await _frames(2)
	_check("noise.far-noise-refreshes-known", _known(pacer))
	_advance(3.0)
	await _frames(2)
	_check("noise.then-forgotten", not _known(pacer))
	await _despawn_all()

func _case_surrender_panel() -> void:
	var SurrenderPanel = load("res://UI/SurrenderPanel.gd")
	# Only an unknown hostile near: no counterparty; a click says so.
	var dead_one = _spawn("Grave Thing", _behind(250.0), "undead")
	await _frames(3)
	await _physics(2)
	_check("panel.sanity-undead-hostile-near", dead_one in game.hostile_characters_near_party())
	_check("panel.sanity-undead-unknown", not _known(dead_one))
	var panel = SurrenderPanel.new()
	panel.game = game
	game.add_child(panel)
	var refused := _log_count("Surrender refused")
	var nobody := _log_count("No one to surrender to: no hostile you know of is near.")
	_check("panel.unknown-only-does-not-open", not panel.try_open())
	_check("panel.unknown-only-explained", _log_count("No one to surrender to: no hostile you know of is near.") == nobody + 1, _log_tail())
	_check("panel.unknown-only-not-refused-by-it", _log_count("Surrender refused") == refused,
		"the hidden undead isn't asked")
	panel.queue_free()
	# A known bandit too. The undead comes first in the scene, so the old
	# rule (any nearby hostile) asked it, and it refused.
	var bandit = _spawn("Known Bandit", _ahead(300.0))
	var hidden_bandit = _spawn("Hidden Bandit", _behind(300.0))
	await _frames(3)
	await _physics(2)
	_check("panel.bandit-known", _known(bandit) and not _known(hidden_bandit))
	panel = SurrenderPanel.new()
	panel.game = game
	game.add_child(panel)
	_check("panel.counterparty-from-known-only", panel._pick_counterparty() == "bandits", panel._pick_counterparty())
	refused = _log_count("Surrender refused")
	_check("panel.opens-predatory", panel.try_open() and panel._faction == "bandits")
	_check("panel.no-refusal-from-hidden-undead", _log_count("Surrender refused") == refused, _log_tail())
	# The accepting side: the robbery's truce covers the faction, the members
	# the party never saw included.
	for c in game.party_chars:
		if is_instance_valid(c) and c.inventory != null:
			c.inventory.items.clear()
	p.inventory.items.append({"id": "r6_coin_pouch", "cost": 10.0, "num_stacks": 1})
	panel._do_rob(0.5)
	var hb_ai = hidden_bandit.get_node("AI")
	var kb_ai = bandit.get_node("AI")
	_check("panel.truce-known-bandit", not kb_ai._is_enemy(p))
	_check("panel.truce-covers-unseen-bandit", not hb_ai._is_enemy(p))
	_check("panel.after-truce-no-bandit-threat", not _known(bandit))
	await _despawn_all()

func _case_cancel_naming() -> void:
	var a = p
	var b = others[0] if not others.is_empty() else null
	# Seen attacker: named.
	var seen_foe = _spawn("Frostbrand", _ahead(250.0))
	await _frames(3)
	await _physics(2)
	_check("cancel.seen-control", game.is_seen_by_party(seen_foe))
	a.condition_manager.apply_condition("burning", null, 1)
	var line := "%s's Burning is put out (cold: Frostbrand's hit)." % a.Name
	var n := _log_count(line)
	a.take_damage({"cold": 3}, a.global_position, seen_foe)
	_check("cancel.seen-attacker-named", _log_count(line) == n + 1, _log_tail())
	# Unseen attacker: not named.
	var hidden_foe = _spawn("Icehand", _behind(250.0))
	await _frames(3)
	await _physics(2)
	_check("cancel.unseen-control", not game.is_seen_by_party(hidden_foe))
	if b != null:
		b.condition_manager.apply_condition("burning", null, 1)
		line = "%s's Burning is put out (cold: a hit from someone unseen)." % b.Name
		n = _log_count(line)
		b.take_damage({"cold": 3}, b.global_position, hidden_foe)
		_check("cancel.unseen-attacker-neutral", _log_count(line) == n + 1, _log_tail())
		_check("cancel.unseen-attacker-not-named", _log_count("Icehand") == 0, _log_tail())
	await _despawn_all()
	for pc in game.party_chars:
		pc.condition_manager.remove_condition("chilled")
		pc.condition_manager.remove_condition("burning")

func _case_custom_effects() -> void:
	# Sickness: an unseen carrier (at the leader's back) isn't named; the
	# party member it reaches is.
	var carrier = _spawn("Plague Carrier", _behind(40.0))
	await _frames(3)
	await _physics(2)
	_check("sick.carrier-unseen", not game.is_seen_by_party(carrier))
	p.condition_manager.remove_condition("sickened")
	var n := _log_count("Sickness spreads to %s" % p.Name)
	carrier._handle_spread_sickness(null, {"chance": 1.0, "radius_tiles": 2})
	_check("sick.unseen-carrier-neutral", _log_count("Sickness spreads to %s" % p.Name) == n + 1, _log_tail())
	_check("sick.unseen-carrier-not-named", _log_count("Plague Carrier") == 0, _log_tail())
	await _despawn_all()
	for pc in game.party_chars:
		pc.condition_manager.remove_condition("sickened")
	# A seen carrier is named; an unseen catcher next to it isn't.
	var seen_carrier = _spawn("Coughing Monk", _ahead(64.0))
	var catcher = _spawn("Unseen Catcher", _ahead(128.0))
	await _invisible_unseen(catcher)
	await _frames(2)
	_check("sick.seen-carrier-control", game.is_seen_by_party(seen_carrier) and not game.is_seen_by_party(catcher))
	n = _log_count("Coughing Monk's sickness spreads to %s" % p.Name)
	seen_carrier._handle_spread_sickness(null, {"chance": 1.0, "radius_tiles": 2})
	_check("sick.seen-carrier-named", _log_count("Coughing Monk's sickness spreads to %s" % p.Name) == n + 1, _log_tail())
	_check("sick.catcher-caught-quietly", catcher.condition_manager.has_condition("sickened") \
		and _log_count("Unseen Catcher") == 0, _log_tail())
	await _despawn_all()
	for pc in game.party_chars:
		pc.condition_manager.remove_condition("sickened")
	# Vomiting: only where the party sees it.
	var hurler = _spawn("Hidden Hurler", _behind(200.0))
	var seen_hurler = _spawn("Green Hurler", _ahead(200.0))
	await _frames(3)
	await _physics(2)
	hurler._handle_vomit(null, {"chance": 1.0, "fluid_type": "acid", "amount": 0.1})
	_check("vomit.unseen-quiet", _log_count("Hidden Hurler vomits") == 0, _log_tail())
	n = _log_count("Green Hurler vomits acid!")
	seen_hurler._handle_vomit(null, {"chance": 1.0, "fluid_type": "acid", "amount": 0.1})
	_check("vomit.seen-logged", _log_count("Green Hurler vomits acid!") == n + 1, _log_tail())
	await _despawn_all()
	# An animal appearing (radius 0: on the bearer's own tile).
	var beckoner = _spawn("Hidden Beckoner", _behind(250.0))
	await _frames(3)
	var before: int = game.characters_in_scene.size()
	n = _log_count("appears")
	beckoner._handle_spawn_animal(null, {"templates": ["wild_wolf"], "radius_tiles": 0})
	print("INFO animal: out-of-view bearer spawned %d" % (game.characters_in_scene.size() - before))
	_track_new_animals(before)
	_check("animal.out-of-view-quiet", _log_count("appears") == n and _log_count("Hidden Beckoner") == 0, _log_tail())
	var cloaked = _spawn("Cloaked Beckoner", _ahead(250.0))
	await _invisible_unseen(cloaked)
	before = game.characters_in_scene.size()
	n = _log_count("A wild wolf appears!")
	cloaked._handle_spawn_animal(null, {"templates": ["wild_wolf"], "radius_tiles": 0})
	_track_new_animals(before)
	_check("animal.in-view-bearer-unnamed", _log_count("A wild wolf appears!") == n + 1 \
		and _log_count("Cloaked Beckoner") == 0, _log_tail())
	var open_beckoner = _spawn("Open Beckoner", _ahead(200.0))
	await _frames(3)
	await _physics(2)
	before = game.characters_in_scene.size()
	n = _log_count("A wild wolf appears near Open Beckoner!")
	open_beckoner._handle_spawn_animal(null, {"templates": ["wild_wolf"], "radius_tiles": 0})
	_track_new_animals(before)
	_check("animal.seen-bearer-named", _log_count("A wild wolf appears near Open Beckoner!") == n + 1, _log_tail())
	await _despawn_all()

## Wolves the animal handler spawned: still and cleaned up with the rest.
func _track_new_animals(before: int) -> void:
	for i in range(before, game.characters_in_scene.size()):
		var c = game.characters_in_scene[i]
		if is_instance_valid(c):
			c.AI_enabled = false
			_spawned.append(c)

func _case_disarm() -> void:
	var hidden_duelist = _spawn("Hidden Duelist", _behind(200.0))
	var seen_duelist = _spawn("Open Duelist", _ahead(200.0))
	for d in [hidden_duelist, seen_duelist]:
		d.inventory.equip_weapon_from_data(ItemDatabase.get_item_data("prod_of_justice"))
	await _frames(3)
	await _physics(2)
	_check("disarm.armed", hidden_duelist.current_main_hand_item != null and seen_duelist.current_main_hand_item != null)
	_check("disarm.unseen-dropped", hidden_duelist.drop_held_weapon("Main"))
	_check("disarm.unseen-not-named", _log_count("Hidden Duelist is disarmed") == 0, _log_tail())
	var n := _log_count("Open Duelist is disarmed")
	_check("disarm.seen-dropped", seen_duelist.drop_held_weapon("Main"))
	_check("disarm.seen-named", _log_count("Open Duelist is disarmed") == n + 1, _log_tail())
	await _despawn_all()

func _case_dialogue_combat() -> void:
	var api = DialogueManager.actions_api
	_check("combat.api", api != null)
	if api == null:
		return
	var ambusher = _spawn("Ambusher", _behind(250.0), "neutral")
	await _frames(3)
	await _physics(2)
	_check("combat.ambusher-unseen", not game.is_seen_by_party(ambusher))
	var n := _log_count("Combat! Someone unseen attacks you.")
	api.run({"type": "start_combat", "attackers": "Ambusher", "pause": false}, "test")
	_check("combat.unseen-unnamed", _log_count("Combat! Someone unseen attacks you.") == n + 1 \
		and _log_count("Ambusher") == 0, _log_tail())
	_check("combat.unseen-turned-hostile", ambusher.is_hostile_to_party())
	_check("combat.unseen-no-music-yet", not _known(ambusher))
	var thug = _spawn("Thug", _ahead(250.0), "neutral")
	await _frames(3)
	await _physics(2)
	n = _log_count("Combat! Thug attacks you.")
	api.run({"type": "start_combat", "attackers": ["Thug", "Ambusher"], "pause": false}, "test")
	_check("combat.seen-named-unseen-left-out", _log_count("Combat! Thug attacks you.") == n + 1 \
		and _log_count("Ambusher") == 0, _log_tail())
	api.pause_requested = false
	await _despawn_all()
