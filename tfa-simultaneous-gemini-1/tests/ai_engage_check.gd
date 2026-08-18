# res://tests/ai_engage_check.gd
# Regression guard for THE ENGAGEMENT CONTRACT:
#
#   An AI that has a hostile enemy within arm's reach must FIGHT IT.
#   Investigating a noise is what you do when there is nobody to fight —
#   it must never outrank an enemy that is already standing next to you.
#
# The reported bug: NPCs with enemies plainly beside them walked past those
# enemies toward a distant sound and never fought back. ai.gd only ever
# acquires a target through _update_target -> is_in_line_of_sight, which is a
# 150-degree FORWARD cone; a searcher walking toward a noise has its back to
# everything it passes, and nothing else in the state machine ever looks.
#
# Real ProceduralCharacter.tscn instances, real AI ticks, real rotation —
# the FOV cone is the thing under test, so nothing about facing is stubbed.
#
# Run:  godot --headless --path . res://tests/ai_engage_check.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

# ProceduralCharacter._process reads this off the game root (_process_approach).
const MELEE_ELEV_TOLERANCE: float = 0.5

# --- Game stub surface (ai.gd touches exactly these) ---
var characters_in_scene: Array = []
var items_in_scene: Array = []
var structures_in_scene: Array = []
var party_chars: Array = []
var stealth_mode: bool = false
var surface_manager = null
var fluid_manager = null
var fog_manager = null
var context_menu_open := false
var primary_selected = null
var current_map_id: String = "test"

var failures := 0

# --- Combat-manager stub surface (ProceduralCharacter.attack reaches these) ---
func can_hit_target(_a: Node2D, _t: Node2D) -> bool: return true
func register_hit(_a: Node2D, _t: Node2D) -> void: pass
func register_attack_start(_a: Node2D) -> void: pass
func register_attack_end(_a: Node2D) -> void: pass
func resolve_melee_swing(_a: Node2D, _hand: String) -> void: pass
func process_weapon_hit(_a, _t, _p, _w, _v) -> void: pass
func process_object_hit(_a, _t, _p, _w, _v) -> void: pass
func trigger_hearing_pulse(_source) -> void: pass

# Simulated seconds each behavioural case is allowed before it must have
# engaged. Generous on purpose: the searcher gets time to walk off toward the
# noise, which is exactly the failure we want to catch.
const ENGAGE_DEADLINE_SEC: float = 4.0

# GridManager.initialize lays tiles from world (0,0) outward — negative
# coordinates are OFF the map and find_path O(1)-rejects them, which would
# freeze a searcher in place and make this harness pass for the wrong reason.
# Everything is therefore staged around the middle of a 4096px map.
const ORIGIN := Vector2(2048, 2048)
# Far enough north to be a long walk, still comfortably on-grid.
const NOISE := Vector2(2048, 548)


func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(4096, 4096)   # 64x64 open tiles, all walkable
	print("=== AI engagement contract ===")
	await _case_enemy_in_front()
	await _case_enemy_behind_while_searching()
	await _case_attacked_from_behind()
	await _case_enemy_behind_after_kill()
	print("=== %s ===" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
	get_tree().quit(1 if failures > 0 else 0)


# rotation 0 faces UP (-Y). "Behind" is therefore +Y.
func _spawn(faction: String, pos: Vector2, char_name: String,
		ai_on: bool, facing: float = 0.0) -> ProceduralCharacter:
	var c: ProceduralCharacter = PC_SCENE.instantiate()
	c.AI_enabled = ai_on
	c.is_player_controlled = not ai_on
	add_child(c)
	TopDownCharacterDatabase.build_character(c, "default_human")
	c.game = self
	c.faction_id = faction
	c.Name = char_name
	c.global_position = pos
	c.rotation = facing
	c.target_rotation = facing
	characters_in_scene.append(c)
	return c


func _settle(frames: int = 30) -> void:
	for i in frames:
		await get_tree().process_frame


func _clear() -> void:
	for c in characters_in_scene:
		if is_instance_valid(c):
			c.queue_free()
	characters_in_scene = []
	party_chars = []
	await get_tree().physics_frame
	await get_tree().physics_frame


func _ai(pc: ProceduralCharacter):
	return pc.get_node_or_null("AI")


# Run real frames until the AI acquires `foe`, or the deadline expires.
# Returns the elapsed simulated seconds, or -1.0 on timeout.
func _run_until_engaged(pc: ProceduralCharacter, foe: ProceduralCharacter) -> float:
	var ai = _ai(pc)
	var elapsed: float = 0.0
	while elapsed < ENGAGE_DEADLINE_SEC:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		if ai != null and ai.current_target == foe:
			return elapsed
	return -1.0


# --- Case 1: control. Enemy straight ahead, no competing noise. -------------
# If this ever fails, the harness itself is broken (faction wiring, build,
# grid) — not the behaviour under test.
func _case_enemy_in_front() -> void:
	var guard := _spawn("bandits", ORIGIN, "Guard", true)
	var foe := _spawn("player", ORIGIN + Vector2(0, -200), "Foe", false)
	party_chars = [foe]
	await _settle()
	var t: float = await _run_until_engaged(guard, foe)
	_check("control.enemy-in-front-is-engaged", t >= 0.0,
		"never acquired an enemy 200px dead ahead in %.1fs" % ENGAGE_DEADLINE_SEC)
	await _clear()


# --- Case 2: the reported bug. --------------------------------------------
# Guard faces north, enemy stands right behind it, a loud noise goes off far
# to the north. The guard must fight the enemy at its heels, not stroll north.
func _case_enemy_behind_while_searching() -> void:
	var guard := _spawn("bandits", ORIGIN, "Guard", true)
	var foe := _spawn("player", ORIGIN + Vector2(0, 110), "Foe", false)
	party_chars = [foe]
	await _settle()

	var ai = _ai(guard)
	# Straight to SEARCHING, aimed a long way north.
	ai.on_sound_heard(NOISE, 1.4, null, "ambient", {})
	_check("searching.state-entered",
		ai.alertness_value >= ai.ALERTNESS_SEARCHING_THRESHOLD,
		"alertness=%.1f" % ai.alertness_value)

	var t: float = await _run_until_engaged(guard, foe)
	var drift: float = guard.global_position.distance_to(ORIGIN)
	# The searcher must actually have been walking — a frozen guard would make
	# this case pass for the wrong reason (see the ORIGIN note above).
	_check("searching.actually-walked", t >= 0.0 or drift > 32.0,
		"never moved (%.0fpx): the noise goal is unreachable, harness geometry is wrong" % drift)
	_check("bug.enemy-behind-beats-the-noise", t >= 0.0,
		"walked %.0fpx toward the noise without ever engaging a foe 110px behind it" % drift)
	await _clear()


# --- Case 3: struck from an unseen angle. ---------------------------------
# Being hit is not a rumour — you know where it came from well enough to turn
# around. Today _on_self_damaged only bumps alertness, so the victim
# investigates the ground under its own feet while being cut down.
func _case_attacked_from_behind() -> void:
	var guard := _spawn("bandits", ORIGIN, "Guard", true)
	var foe := _spawn("player", ORIGIN + Vector2(0, 110), "Foe", false)
	party_chars = [foe]
	await _settle()

	guard.take_damage({"slashing": 8}, guard.global_position + Vector2(0, 20), foe)
	var t: float = await _run_until_engaged(guard, foe)
	_check("bug.struck-from-behind-turns-and-fights", t >= 0.0,
		"took a hit from a foe 110px behind and never acquired it in %.1fs" % ENGAGE_DEADLINE_SEC)
	await _clear()


# --- Case 4: the second enemy. --------------------------------------------
# The AI kills what it was facing; a second enemy is at its back. _lose_target
# drops it to IDLE, alertness is still pinned at MAX by combat noise, so the
# next tick promotes it to SEARCHING and it wanders off to the last bang while
# the survivor stabs its kidneys.
func _case_enemy_behind_after_kill() -> void:
	var guard := _spawn("bandits", ORIGIN, "Guard", true)
	var dying := _spawn("player", ORIGIN + Vector2(0, -180), "First", false)
	party_chars = [dying]
	await _settle()

	var ai = _ai(guard)
	var t1: float = await _run_until_engaged(guard, dying)
	_check("kill.first-enemy-acquired", t1 >= 0.0, "never engaged the enemy in front")

	# A second enemy arrives at the guard's back only once the fight is joined,
	# so the guard genuinely acquires the front one first.
	var second := _spawn("player", guard.global_position + Vector2(0, 130), "Second", false)
	party_chars = [dying, second]

	# Kill the one it was facing, and make a noise a long way north.
	var corpse_pos: Vector2 = dying.global_position
	dying.current_health = 0
	dying._check_death()
	ai.on_sound_heard(NOISE, 1.4, null, "ambient", {})

	var t2: float = await _run_until_engaged(guard, second)
	_check("bug.second-enemy-behind-is-engaged", t2 >= 0.0,
		"after its target died it investigated the noise instead of the foe 130px behind it")

	# And the breadcrumb: had there been no second enemy, the search should head
	# for the corpse it was just fighting, not the unrelated bang up the road.
	_check("kill.search-breadcrumb-is-the-fight",
		ai.last_heard_position.distance_to(corpse_pos) < ai.last_heard_position.distance_to(NOISE),
		"post-kill search goal %s is nearer the noise %s than the corpse %s"
			% [ai.last_heard_position, NOISE, corpse_pos])
	await _clear()
