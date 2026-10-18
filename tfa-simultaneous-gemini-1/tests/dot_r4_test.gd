extends Node2D
# Round 4, DoT lane: the developer's "greatly limit the amount of damage in a
# stack, and have higher amounts of damage add additional stacks", and "the
# burning condition ends whenever the first stack wears off ... should be
# fixed".
#   A. Small stacks: every damaging DoT deals single digits per stack and 2-3
#      a second at max tier (ConditionDatabase).
#   B. Stacks from damage: a fire / poison / cold / slashing-piercing hit adds
#      ceil(dealt / damage_per_stack) stacks, at least 1, at most max tier
#      (Condition.stacks_for_damage, ProceduralCharacter._apply_damage_type_condition),
#      dealt being the damage after armour.
#   C. Refresh: an application on a timed stackable moves its expiry to
#      max(expiry, now + its duration), adding stacks or at the cap
#      (ConditionManager._refresh_stackable_expiry); permanent stays permanent.
#   D. Feedback: the summary every condition display uses says what a DoT
#      deals ("Burning x3: 3 fire every 1 s (6s left)"); descriptions match the
#      data; rider stacks don't log; stack wording in the log.
#   E. A per-source totals table (printed), from the shipped data.
# The condition clock (TimeManager.absolute_time) is driven by hand in exact
# 1/16 s steps, and each ConditionManager._process is called directly.
#   godot --headless --path . res://tests/dot_r4_test.tscn
# Judge by the PASS/FAIL lines and "HARNESS DONE failures=0".

const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const HOVER = preload("res://UI/WorldHoverInfo.gd")

# --- Game stub surface (ai.gd and ProceduralCharacter touch these) ---
var characters_in_scene: Array = []
var items_in_scene: Array = []
var structures_in_scene: Array = []
var party_chars: Array = []
var selected_characters: Array = []
var stealth_mode: bool = false
var surface_manager = null
var fluid_manager = null
var fog_manager = null
var context_menu_open := false
var primary_selected = null
var current_map_id: String = "test"
var current_map_data: Dictionary = {}
const MELEE_ELEV_TOLERANCE: float = 0.5

func can_hit_target(_a: Node2D, _t: Node2D) -> bool: return true
func register_hit(_a: Node2D, _t: Node2D) -> void: pass
func register_attack_start(_a: Node2D) -> void: pass
func register_attack_end(_a: Node2D) -> void: pass
func resolve_melee_swing(_a: Node2D, _hand: String) -> void: pass
func process_weapon_hit(_a, _t, _p, _w, _v) -> void: pass
func process_object_hit(_a, _t, _p, _w, _v) -> void: pass
func trigger_hearing_pulse(_source) -> void: pass
func is_seen_by_party(c) -> bool:
	return c in party_chars

const ORIGIN := Vector2(1024, 1024)
## Exact in binary, so tick times land on whole intervals.
const STEP := 0.0625
const DOTS := ["burning", "poisoned", "bleeding", "shocked", "corroding", "stuck_in_fire", "suffocating"]

var failures := 0
var checks := 0
## The hand-driven condition clock (TimeManager.game_time; TimeManager is
## paused for the run).
var _clock := 1000.0
var _saved_paused := false
var _saved_game_time := 0.0


func _check(check_name: String, cond: bool, detail = "") -> void:
	checks += 1
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, str(detail)])


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	await get_tree().process_frame
	_saved_paused = TimeManager.is_paused
	_saved_game_time = TimeManager.game_time
	TimeManager.is_paused = true
	_clock = 1000.0 + TimeManager.game_time
	_register_test_conditions()

	_case_stacks_for_damage()
	await _case_riders()
	await _case_refresh()
	await _case_refresh_interactions()
	await _case_transform_with_refresh()
	await _case_per_stack_and_max_tier()
	await _case_spells()
	await _case_summary_text()
	await _case_no_log_flood()
	_case_descriptions_match_data()
	await _case_source_table()

	TimeManager.is_paused = _saved_paused
	TimeManager.game_time = _saved_game_time
	print("HARNESS DONE failures=%d checks=%d" % [failures, checks])
	get_tree().quit(1 if failures > 0 else 0)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _set_clock(t: float) -> void:
	_clock = t
	TimeManager.game_time = t - float(TimeManager.days_elapsed) * 86400.0


func _now() -> float:
	return TimeManager.absolute_time()


## A bare character (no gear, so no armour) with plenty of HP, its condition
## clock driven by hand.
func _dummy(char_name: String, party := false) -> ProceduralCharacter:
	var c: ProceduralCharacter = PC_SCENE.instantiate()
	c.is_player_controlled = party
	c.AI_enabled = false
	add_child(c)
	c.game = self
	c.faction_id = "player" if party else "bandits"
	c.Name = char_name
	c.global_position = ORIGIN + Vector2(randf_range(-200, 200), randf_range(-200, 200))
	characters_in_scene.append(c)
	if party:
		party_chars.append(c)
	await get_tree().process_frame
	c.constitution = 1000
	c.current_health = c.max_health
	_cm(c).set_process(false)
	_set_clock(_clock)
	return c


func _clear() -> void:
	for c in characters_in_scene:
		if is_instance_valid(c):
			c.queue_free()
	characters_in_scene = []
	party_chars = []
	await get_tree().physics_frame


func _cm(c: ProceduralCharacter) -> ConditionManager:
	return c.get_node("ConditionManager")


func _tmpl(id: String) -> Condition:
	return ConditionManager.condition_registry.get(id)


## Advance the clock `seconds` in STEPs, ticking `c`'s conditions each step.
func _run(c: ProceduralCharacter, seconds: float) -> void:
	var start := _clock
	var n := int(round(seconds / STEP))
	for i in range(1, n + 1):
		_set_clock(start + i * STEP)
		_cm(c)._process(STEP)


## Bleeding's CON saves (on landing and every 6 s) are dice; the stack and
## damage cases turn them off so the counts are exact.
func _without_bleed_saves(f: Callable):
	var t := _tmpl("bleeding")
	var saved := t.save_stat
	t.save_stat = ""
	var out = await f.call()
	t.save_stat = saved
	return out


## DoT damage a character takes over a run (sum of every damage tick, before
## armour; the dummies wear none). `schedule` is [[seconds, Callable], ...],
## each fired on the first step at or past its time, before that step's
## conditions tick. The run lasts at least `min_seconds`, then until no
## damaging condition is left. {total, ticks, peak (stacks), lasted (s)}.
func _simulate(c: ProceduralCharacter, schedule: Array, min_seconds: float) -> Dictionary:
	var cm := _cm(c)
	var out := {"total": 0, "ticks": 0, "peak": 0, "lasted": 0.0}
	var on_tick := func(_inst, _eff, res):
		if res.has("damage"):
			out["total"] += int(res["damage"])
			out["ticks"] += 1
	cm.triggered_effect_fired.connect(on_tick)
	var start := _clock
	var pending := schedule.duplicate()
	var i := 0
	while true:
		var t := i * STEP
		_set_clock(start + t)
		while not pending.is_empty() and float(pending[0][0]) <= t + 0.0001:
			(pending.pop_front()[1] as Callable).call()
		cm._process(STEP)
		var any := false
		for inst in cm.conditions.values():
			if inst.get_dot_text() != "":
				any = true
				out["peak"] = maxi(int(out["peak"]), inst.stacks)
		if any:
			out["lasted"] = t
		if (t >= min_seconds and not any and pending.is_empty()) or t > 300.0:
			break
		i += 1
	cm.triggered_effect_fired.disconnect(on_tick)
	_set_clock(start + i * STEP + 1.0)
	return out


## Every `interval` s while standing in a hazard for `stay` s (the hazard
## timers fire first after one full interval).
func _every(interval: float, stay: float, f: Callable, first := -1.0) -> Array:
	var out: Array = []
	var t := interval if first < 0.0 else first
	while t <= stay + 0.0001:
		out.append([t, f])
		t += interval
	return out


## Applies `stacks` of `id` to `v` (no source), skipping a corpse.
func _applier(v: ProceduralCharacter, id: String, stacks: int) -> Callable:
	return func():
		if is_instance_valid(v) and v.is_alive():
			_cm(v).apply_condition(id, null, stacks)


func _json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	return d if d is Dictionary else {}


func _log_count(fragment: String) -> int:
	var n := 0
	for e in GameLog.get_entries():
		if String(e.get("text", "")).contains(fragment):
			n += 1
	return n


func _register_test_conditions() -> void:
	ConditionManager.register_conditions([{
		"id": "r4_slow_dot", "display_name": "Slow Dot", "traits": {"debuff": 1},
		"stackable": true, "max_tier": 3, "duration": 9.0, "canceled_by_trait": [],
		"triggered_effects": [{"type": "damage", "value": 2, "damage_type": "fire", "interval": 1.5}],
		"immunities": {},
	}])


# ---------------------------------------------------------------------------
# B. ceil(dealt / K), min 1, capped
# ---------------------------------------------------------------------------

func _case_stacks_for_damage() -> void:
	var cases := {
		"burning": {0.5: 0, 1: 1, 6: 1, 7: 2, 12: 2, 13: 3, 24: 3, 100: 3},
		"poisoned": {1: 1, 2: 1, 5: 1, 6: 2, 10: 2, 11: 3, 18: 4, 50: 4},
		"chilled": {1: 1, 3: 1, 4: 1, 12: 1, 13: 2, 15: 2, 24: 2, 25: 3, 99: 3},
		"bleeding": {1: 1, 9: 1, 15: 1, 20: 1, 21: 2, 40: 2, 41: 3, 200: 5},
	}
	for id in cases:
		var t := _tmpl(id)
		_check("k.%s-has-damage-per-stack" % id, t != null and t.damage_per_stack > 0.0, t.damage_per_stack if t else "missing")
		if t == null:
			continue
		for dealt in cases[id]:
			var got := t.stacks_for_damage(float(dealt))
			_check("k.%s-%s-dealt->%d" % [id, str(dealt), cases[id][dealt]], got == cases[id][dealt], got)
	# No damage_per_stack: one stack per hit, whatever its size (the old rule).
	var corr := _tmpl("corroding")
	_check("k.no-k-one-per-hit", corr.stacks_for_damage(1.0) == 1 and corr.stacks_for_damage(50.0) == 1)
	# A non-stackable never asks for more than one.
	_check("k.non-stackable-one", _tmpl("stuck_in_fire").stacks_for_damage(40.0) == 1)
	# The field reads from data, and defaults to 0.
	var c := Condition.create_from_data({"id": "x", "stackable": true, "max_tier": 9, "damage_per_stack": 4})
	_check("k.read-from-data", is_equal_approx(c.damage_per_stack, 4.0) and c.stacks_for_damage(9.0) == 3)
	_check("k.default-zero", is_equal_approx(Condition.create_from_data({"id": "y"}).damage_per_stack, 0.0))


# ---------------------------------------------------------------------------
# B. Riders through the real hit path (take_damage)
# ---------------------------------------------------------------------------

func _stacks(c: ProceduralCharacter, id: String) -> int:
	var inst = _cm(c).get_condition(id)
	return inst.stacks if inst else 0


func _case_riders() -> void:
	var v := await _dummy("Target")
	var atk := await _dummy("Attacker")
	var cm := _cm(v)
	# Match Striker's 1 fire point: one small stack, the attacker's.
	v.take_damage({"fire": 1}, v.global_position, atk)
	_check("rider.match-striker-1-stack", _stacks(v, "burning") == 1, _stacks(v, "burning"))
	_check("rider.source-still-attacker", cm.get_condition("burning") != null and cm.get_condition("burning").source == atk)
	cm.clear_all_conditions()
	v.take_damage({"fire": 7}, v.global_position, atk)
	_check("rider.fire-7-2-stacks", _stacks(v, "burning") == 2, _stacks(v, "burning"))
	cm.clear_all_conditions()
	v.take_damage({"fire": 13}, v.global_position, atk)
	_check("rider.fire-13-3-stacks", _stacks(v, "burning") == 3, _stacks(v, "burning"))
	v.take_damage({"fire": 30}, v.global_position, atk)
	_check("rider.capped-at-max-tier", _stacks(v, "burning") == _tmpl("burning").max_tier, _stacks(v, "burning"))
	cm.clear_all_conditions()
	# Adding to an existing instance: 1 + ceil(7/6).
	v.take_damage({"fire": 1}, v.global_position, atk)
	v.take_damage({"fire": 7}, v.global_position, atk)
	_check("rider.adds-to-existing", _stacks(v, "burning") == 3, _stacks(v, "burning"))
	cm.clear_all_conditions()
	# Nothing dealt, nothing lit.
	v.take_damage({"fire": 0.5}, v.global_position, atk)
	_check("rider.sub-1-hit-no-burn", not cm.has_condition("burning"))
	# After armour: torso fire DR 5 turns a 13-point fire hit into 8 = 2 stacks.
	var torso = v.limbs.get(ProceduralCharacter.LimbType.TORSO)
	if torso != null:
		var saved_dr: Dictionary = torso.armor_dr
		torso.armor_dr = {"fire": 5}
		v.take_damage({"fire": 13}, v.global_position, atk)
		_check("rider.counts-damage-after-armour", _stacks(v, "burning") == 2, _stacks(v, "burning"))
		torso.armor_dr = saved_dr
		cm.clear_all_conditions()
	else:
		_check("rider.torso-limb-fixture", false, "no torso limb")
	# Poison: a Stiletto's 2 is 1 stack; a Poison Vial's 18 fills it.
	v.take_damage({"poison": 2}, v.global_position, atk)
	_check("rider.stiletto-1-stack", _stacks(v, "poisoned") == 1, _stacks(v, "poisoned"))
	cm.clear_all_conditions()
	v.take_damage({"poison": 18}, v.global_position, atk)
	_check("rider.poison-vial-4-stacks", _stacks(v, "poisoned") == 4, _stacks(v, "poisoned"))
	cm.clear_all_conditions()
	# Cold: a cold weapon's 4 is 1 stack, an Iciclet's 15 is 2, 25 freezes.
	v.take_damage({"cold": 4}, v.global_position, atk)
	_check("rider.frost-axe-1-chill", _stacks(v, "chilled") == 1, _stacks(v, "chilled"))
	cm.clear_all_conditions()
	v.take_damage({"cold": 15}, v.global_position, atk)
	_check("rider.iciclet-2-chill", _stacks(v, "chilled") == 2 and not cm.has_condition("frozen"), _stacks(v, "chilled"))
	v.take_damage({"cold": 4}, v.global_position, atk)
	_check("rider.iciclet-then-any-cold-freezes", cm.has_condition("frozen") and not cm.has_condition("chilled"))
	cm.clear_all_conditions()
	v.take_damage({"cold": 25}, v.global_position, atk)
	_check("rider.25-cold-freezes-in-one", cm.has_condition("frozen"))
	cm.clear_all_conditions()
	for i in 3:
		v.take_damage({"cold": 3}, v.global_position, atk)
	_check("rider.three-winters-grip-hits-freeze", cm.has_condition("frozen"))
	cm.clear_all_conditions()
	# Bleeding scales gently (20 per stack), before its CON save.
	var bleeds := func():
		v.take_damage({"slashing": 15}, v.global_position, atk)
		_check("rider.sword-cut-1-bleed", _stacks(v, "bleeding") == 1, _stacks(v, "bleeding"))
		cm.clear_all_conditions()
		v.take_damage({"piercing": 21}, v.global_position, atk)
		_check("rider.heavy-21-2-bleed", _stacks(v, "bleeding") == 2, _stacks(v, "bleeding"))
		cm.clear_all_conditions()
		v.take_damage({"slashing": 41}, v.global_position, atk)
		_check("rider.41-3-bleed", _stacks(v, "bleeding") == 3, _stacks(v, "bleeding"))
		cm.clear_all_conditions()
		v.current_health = v.max_health
		return true
	await _without_bleed_saves(bleeds)
	# A condition's own tick still adds nothing (Burning doesn't feed itself).
	cm.apply_condition("burning", null, 1)
	var inst := cm.get_condition("burning")
	cm.remove_condition("burning")
	v._on_triggered_effect_fired(inst, {"type": "damage"}, {"damage": 13, "damage_type": "fire"})
	_check("rider.tick-adds-nothing", not cm.has_condition("burning"))
	await _clear()


# ---------------------------------------------------------------------------
# C. Refresh
# ---------------------------------------------------------------------------

func _case_refresh() -> void:
	var v := await _dummy("Refresh")
	var cm := _cm(v)
	var t0 := _now()
	var burn_dur: float = _tmpl("burning").duration * float(v.MODIFY_DURATION_BY_TRAIT.get("fire", 1.0))
	_check("refresh.burning-lasts-6s", is_equal_approx(burn_dur, 6.0), burn_dur)
	var inst := cm.apply_condition("burning", null, 1)
	_check("refresh.first-expiry", inst != null and is_equal_approx(inst.expires_at, t0 + burn_dur), inst.expires_at - t0 if inst else -1)
	_run(v, 4.0)
	cm.apply_condition("burning", null, 1)
	_check("refresh.added-stack-refreshes", inst.stacks == 2 and is_equal_approx(inst.expires_at, t0 + 4.0 + burn_dur),
		"stacks %d, expires +%.2f" % [inst.stacks, inst.expires_at - t0])
	_run(v, 4.0)   # t0 + 8: past the FIRST stack's old end (t0 + 6)
	_check("refresh.outlives-first-stack", cm.has_condition("burning") and cm.get_condition("burning") == inst)
	cm.apply_condition("burning", null, 5)
	_check("refresh.cap", inst.stacks == 3)
	_run(v, 2.0)   # t0 + 10
	cm.apply_condition("burning", null, 1)
	_check("refresh.at-cap-refreshes-too", inst.stacks == 3 and is_equal_approx(inst.expires_at, t0 + 10.0 + burn_dur),
		"expires +%.2f" % (inst.expires_at - t0))
	# A shorter application never shortens it.
	cm.apply_condition("burning", null, 1, 1.0)
	_check("refresh.never-shortens", is_equal_approx(inst.expires_at, t0 + 10.0 + burn_dur), inst.expires_at - t0)
	# Ticks keep their own cadence: a refresh adds no extra tick.
	var ticks := [0]
	var count := func(_i, _e, r):
		if r.has("damage"):
			ticks[0] += 1
	cm.triggered_effect_fired.connect(count)
	cm.apply_condition("burning", null, 1)
	cm._process(0.0)
	_check("refresh.no-extra-tick", ticks[0] == 0, ticks[0])
	cm.triggered_effect_fired.disconnect(count)
	# It then ends 6 s after the LAST application.
	_run(v, burn_dur - STEP)
	_check("refresh.still-on-just-before", cm.has_condition("burning"))
	_run(v, STEP * 2)
	_check("refresh.ends-6s-after-last", not cm.has_condition("burning"))
	cm.clear_all_conditions()

	# Every stackable timed condition, not only DoTs: Weakened.
	t0 = _now()
	var wk := cm.apply_condition("weakened", null, 1)
	_run(v, 20.0)
	cm.apply_condition("weakened", null, 1)
	_check("refresh.weakened-too", wk.stacks == 2 and is_equal_approx(wk.expires_at, t0 + 20.0 + 30.0), wk.expires_at - t0)
	cm.clear_all_conditions()

	# Travel scale: back-to-back Force Marches keep Exhausted 24 h from the last.
	t0 = _now()
	var ex := cm.apply_condition("exhausted", null, 1)
	_set_clock(_clock + 10.0 * 3600.0)
	cm.apply_condition("exhausted", null, 1)
	_check("refresh.exhausted-24h-from-last-march", ex.stacks == 2 and is_equal_approx(ex.get_remaining_duration(_now()), 24.0 * 3600.0),
		Globals.format_duration_short(ex.get_remaining_duration(_now())))
	cm.clear_all_conditions()

	# Permanent stays permanent; a permanent application makes it permanent.
	var perm := cm.apply_condition("weakened", null, 1, -1.0)
	_check("refresh.permanent-instance", perm.expires_at < 0.0)
	cm.apply_condition("weakened", null, 1)
	_check("refresh.permanent-stays-permanent", perm.expires_at < 0.0 and perm.stacks == 2)
	cm.clear_all_conditions()
	var timed := cm.apply_condition("weakened", null, 1)
	cm.apply_condition("weakened", null, 1, -1.0)
	_check("refresh.permanent-application-makes-permanent", timed.expires_at < 0.0)
	cm.clear_all_conditions()
	# A permanent template with no duration given leaves a timed instance alone.
	var tos := cm.apply_condition("thrill_of_sin", null, 1, 30.0)
	var tos_exp := tos.expires_at
	cm.apply_condition("thrill_of_sin", null, 1)
	_check("refresh.template-permanent-default-untouched", is_equal_approx(tos.expires_at, tos_exp) and tos.stacks == 2)
	cm.clear_all_conditions()

	# Non-stackables keep their rule: a re-application resets to now + duration.
	t0 = _now()
	var sif := cm.apply_condition("stuck_in_fire", null, 1)
	_run(v, 1.0)
	cm.apply_condition("stuck_in_fire", null, 1)
	_check("refresh.non-stackable-rule-unchanged", is_equal_approx(sif.expires_at, t0 + 1.0 + 2.4), sif.expires_at - t0)
	cm.clear_all_conditions()
	await _clear()


func _case_refresh_interactions() -> void:
	var v := await _dummy("Interact")
	var cm := _cm(v)
	# Periodic saves keep their own clock: a refresh doesn't reset it.
	var bl := cm.apply_condition("bleeding", null, 5)
	if bl == null:
		bl = cm.apply_condition("bleeding", null, 5)
	if bl != null:
		var last_save := float(cm.last_save_times.get("bleeding", -1.0))
		_run(v, 1.0)
		cm.apply_condition("bleeding", null, 5)
		_check("interact.save-clock-not-reset", is_equal_approx(float(cm.last_save_times.get("bleeding", -1.0)), last_save))
		_check("interact.bleeding-refreshed", cm.has_condition("bleeding") and is_equal_approx(cm.get_condition("bleeding").get_remaining_duration(_now()), 8.0),
			cm.get_condition("bleeding").get_remaining_duration(_now()) if cm.has_condition("bleeding") else -1)
	else:
		_check("interact.bleeding-fixture", false, "two resisted landings")
	cm.clear_all_conditions()
	# A suppressed instance takes the stacks and the refresh, and stays suppressed.
	var t0 := _now()
	var burn := cm.apply_condition("burning", null, 1)
	cm.suppress_for("burning", 3.0, "test")
	_run(v, 1.0)
	cm.apply_condition("burning", null, 1)
	_check("interact.suppressed-refreshed", burn.is_suppressed and burn.stacks == 2 and is_equal_approx(burn.expires_at, t0 + 1.0 + 6.0))
	cm.clear_all_conditions()
	# Standing in water: Burning can't land, so nothing is refreshed either.
	cm.apply_condition("burning", null, 1)
	cm.ward_by_traits(["water"], "Water")
	_check("interact.water-puts-out", not cm.has_condition("burning"))
	_check("interact.ward-blocks-relight", cm.apply_condition("burning", null, 3) == null and not cm.has_condition("burning"))
	cm._ambient_traits.clear()
	# Save / load keeps the refreshed expiry.
	t0 = _now()
	cm.apply_condition("poisoned", null, 1)
	_run(v, 3.0)
	cm.apply_condition("poisoned", null, 1)
	var want := cm.get_condition("poisoned").expires_at
	var saved := cm.to_dict()
	cm.clear_all_conditions()
	cm.from_dict(saved)
	_check("interact.save-load-keeps-expiry", cm.has_condition("poisoned") and is_equal_approx(cm.get_condition("poisoned").expires_at, want) \
		and is_equal_approx(want, t0 + 3.0 + 10.0) and cm.get_condition("poisoned").stacks == 2)
	cm.clear_all_conditions()
	# A save from before the caps came down (Poisoned x10, Burning x4, as JSON
	# numbers) loads at today's cap, so it ticks and reads what the text says.
	var old_save := {"conditions": {
		"poisoned": {"condition_id": "poisoned", "stacks": 10.0, "expires_at": _now() + 12.0},
		"burning": {"condition_id": "burning", "stacks": 4.0, "expires_at": _now() + 12.0},
		"weakened": {"condition_id": "weakened", "stacks": 2.0, "expires_at": _now() + 12.0}}}
	cm.from_dict(old_save)
	var old_p := cm.get_condition("poisoned")
	_check("interact.old-save-held-to-cap", old_p != null and old_p.stacks == 4 and old_p.get_dot_text() == "4 poison every 2 s" \
		and cm.get_condition("burning") != null and cm.get_condition("burning").stacks == 3,
		[old_p.stacks if old_p else -1, cm.get_condition("burning").stacks if cm.get_condition("burning") else -1])
	_check("interact.old-save-under-cap-untouched", cm.get_condition("weakened") != null and cm.get_condition("weakened").stacks == 2)
	cm.clear_all_conditions()
	await _clear()


func _case_transform_with_refresh() -> void:
	var v := await _dummy("Shiver")
	var cm := _cm(v)
	# Three cold hits 10 s apart: before, Chilled ended 15 s after the first
	# and the third hit started over; now each hit keeps it, and it freezes.
	v.take_damage({"cold": 3}, v.global_position)
	_run(v, 10.0)
	v.take_damage({"cold": 3}, v.global_position)
	_run(v, 10.0)
	_check("transform.chill-outlives-first-hit", _stacks(v, "chilled") == 2, _stacks(v, "chilled"))
	v.take_damage({"cold": 3}, v.global_position)
	_check("transform.third-hit-freezes", cm.has_condition("frozen") and not cm.has_condition("chilled"))
	cm.clear_all_conditions()
	# Freezing Rain's cap (2) still never freezes (Game._tick_weather_conditions
	# stops adding at its cap); a direct third stack does.
	cm.apply_condition("chilled", null, 2)
	_check("transform.two-stays-chilled", cm.has_condition("chilled") and not cm.has_condition("frozen"))
	cm.apply_condition("chilled", null, 1)
	_check("transform.at-3-frozen", cm.has_condition("frozen"))
	cm.clear_all_conditions()
	await _clear()


# ---------------------------------------------------------------------------
# A. Per stack and at max tier
# ---------------------------------------------------------------------------

func _case_per_stack_and_max_tier() -> void:
	var want_per_stack := {"burning": 6, "poisoned": 5, "bleeding": 4, "shocked": 2, "corroding": 4, "stuck_in_fire": 6, "suffocating": 12}
	print("--- one stack / one application, alone ---")
	print("condition       per-tick  every  lasts   ticks  total  max-tier  max/s")
	var one_each := func():
		for id in DOTS:
			var t := _tmpl(id)
			var v := await _dummy("One " + id)
			var r := _simulate(v, [[0.0, _applier(v, id, 1)]], 0.0)
			var eff: Dictionary = t.triggered_effects[0]
			var per_s: float = float(eff["value"]) * float(t.max_tier if t.stackable else 1) / float(eff["interval"])
			var lasts: float = t.duration * (1.2 if t.traits.has("fire") else 1.0)
			print("%-15s %8d  %4.1fs  %5.1fs  %5d  %5d  %8d  %5.2f" % [id, int(eff["value"]), float(eff["interval"]), lasts, r["ticks"], r["total"], t.max_tier if t.stackable else 1, per_s])
			_check("stack.%s-one-stack-%d" % [id, want_per_stack[id]], r["total"] == want_per_stack[id], r)
			_check("stack.%s-small" % id, r["total"] <= 13, r["total"])
			if t.stackable:
				_check("stack.%s-max-tier-2-to-3-per-s" % id, per_s >= 2.0 and per_s <= 3.0, per_s)
			await _clear()
		return true
	await _without_bleed_saves(one_each)
	# HP on the bare dummy matches the ticks (no armour, one source of truth).
	var d := await _dummy("Hp")
	var hp0 := d.current_health
	var r2 := _simulate(d, [[0.0, _applier(d, "burning", 3)]], 0.0)
	_check("stack.hp-matches-ticks", hp0 - d.current_health == r2["total"] and r2["total"] == 18, [hp0 - d.current_health, r2])
	await _clear()
	# A 30-HP character held at max tier (re-applied every second) lasts about
	# 10-15 s: time to douse, cure or flee.
	var thirty := func():
		for id in ["burning", "poisoned", "bleeding", "corroding", "shocked"]:
			var v := await _dummy("Thirty " + id)
			v.current_health = 30
			var mt: int = _tmpl(id).max_tier
			var sched := _every(1.0, 60.0, _applier(v, id, mt), 0.0)
			var died_at := -1.0
			var start := _clock
			var cm := _cm(v)
			for i in range(0, int(60.0 / STEP)):
				var t := i * STEP
				_set_clock(start + t)
				while not sched.is_empty() and float(sched[0][0]) <= t + 0.0001:
					(sched.pop_front()[1] as Callable).call()
				cm._process(STEP)
				if not v.is_alive():
					died_at = t
					break
			print("max %-10s kills a 30-HP character in %.1f s" % [id, died_at])
			_check("maxtier.%s-30hp-lasts-9-to-15s" % id, died_at >= 9.0 and died_at <= 15.0, died_at)
			await _clear()
		return true
	await _without_bleed_saves(thirty)


# ---------------------------------------------------------------------------
# C. Spells keep their authored counts
# ---------------------------------------------------------------------------

func _ability(id: String) -> Ability:
	return Ability.from_dict(AbilityDatabase.get_ability_data(id))


func _case_spells() -> void:
	var caster := await _dummy("Caster")
	var v := await _dummy("Mark")
	var cm := _cm(v)
	var t0 := _now()
	caster.ability_manager._resolve_effects(_ability("fireball"), _ability("fireball").effects, v.global_position, [v])
	var burn := cm.get_condition("burning")
	_check("spell.fireball-2-burning", burn != null and burn.stacks == 2, burn.stacks if burn else -1)
	_check("spell.fireball-burns-6s", burn != null and is_equal_approx(burn.expires_at, t0 + 6.0))
	_check("spell.fireball-24-hit-no-rider-on-top", v._suppressed_damage_conditions.is_empty() and burn != null and burn.stacks == 2)
	cm.clear_all_conditions()
	caster.ability_manager._resolve_effects(_ability("acid_splash"), _ability("acid_splash").effects, v.global_position, [v])
	_check("spell.acid-splash-1-corroding", _stacks(v, "corroding") == 1, _stacks(v, "corroding"))
	cm.clear_all_conditions()
	var worst := 0
	for i in 6:
		cm.clear_all_conditions()
		caster.ability_manager._resolve_effects(_ability("ice_storm"), _ability("ice_storm").effects, v.global_position, [v])
		worst = maxi(worst, _stacks(v, "chilled"))
	_check("spell.ice-storm-at-most-2-chilled", worst <= 2 and not cm.has_condition("frozen"), worst)
	cm.clear_all_conditions()
	# The authored counts in the data.
	var counts := {}
	for id in ["fireball", "ice_storm", "acid_splash", "alms_of_the_vein"]:
		for e in AbilityDatabase.get_ability_data(id).get("effects", []):
			if e is Dictionary and e.get("type", "") == "apply_condition":
				counts[id] = int(e.get("stacks", 1))
	_check("spell.authored-counts", counts == {"fireball": 2, "ice_storm": 2, "acid_splash": 1, "alms_of_the_vein": 1}, counts)
	await _clear()


# ---------------------------------------------------------------------------
# D. Feedback
# ---------------------------------------------------------------------------

func _case_summary_text() -> void:
	var v := await _dummy("Reader", true)
	var cm := _cm(v)
	var now := _now()
	var burn := cm.apply_condition("burning", null, 3)
	_check("text.burning-x3", burn.get_summary(now) == "Burning x3: 3 fire every 1 s (6s left)", burn.get_summary(now))
	_check("text.dot-text", burn.get_dot_text() == "3 fire every 1 s", burn.get_dot_text())
	_check("text.no-clock-no-time", burn.get_summary() == "Burning x3: 3 fire every 1 s", burn.get_summary())
	var poi := cm.apply_condition("poisoned", null, 1)
	_check("text.poisoned-one", poi.get_summary(now) == "Poisoned: 1 poison every 2 s (10s left)", poi.get_summary(now))
	var sl := cm.apply_condition("r4_slow_dot", null, 2)
	_check("text.fractional-interval", sl.get_summary(now) == "Slow Dot x2: 4 fire every 1.5 s (9s left)", sl.get_summary(now))
	cm.clear_all_conditions()
	var bleed_text := func():
		var bl := cm.apply_condition("bleeding", null, 2)
		_check("text.true-damage-reads-damage", bl.get_summary(now) == "Bleeding x2: 2 damage every 2 s (8s left)", bl.get_summary(now))
		cm.clear_all_conditions()
		return true
	await _without_bleed_saves(bleed_text)
	# Stuck in Fire's 2.4 s rounds up.
	var sif := cm.apply_condition("stuck_in_fire", null, 1)
	_check("text.stuck-in-fire", sif.get_summary(now) == "Stuck in Fire: 2 fire every 1 s (3s left)", sif.get_summary(now))
	cm.clear_all_conditions()
	# Non-DoTs read as before.
	var wk := cm.apply_condition("weakened", null, 2)
	_check("text.non-dot-unchanged", wk.get_summary(now) == "Weakened x2 (30s)", wk.get_summary(now))
	cm.clear_all_conditions()
	# Suppressed and the tooltip: same line, then the description.
	burn = cm.apply_condition("burning", null, 2)
	_run(v, 1.0)
	now = _now()
	_check("text.counts-down", burn.get_summary(now) == "Burning x2: 2 fire every 1 s (5s left)", burn.get_summary(now))
	_check("text.tooltip-has-description", burn.get_tooltip_text(now) == burn.get_summary(now) + "\n" + _tmpl("burning").description)
	burn.is_suppressed = true
	_check("text.suppressed", burn.get_summary(now).ends_with("(5s left) (suppressed)"), burn.get_summary(now))
	burn.is_suppressed = false
	# The overhead icon's world-hover text and the hover's condition lines.
	var hover = HOVER.new()
	var described: String = hover.describe_condition(burn, v)
	_check("text.hover-describes-dot", described.contains("Burning x2: 2 fire every 1 s (5s left)") and described.contains("1 fire damage every second"), described)
	var lines: PackedStringArray = hover.condition_lines(v)
	_check("text.hover-lines", lines.size() == 1 and lines[0].contains("Burning x2: 2 fire every 1 s"), lines)
	hover.free()
	# The overhead icon shows the stack count (Burning shows its flames
	# instead; Poisoned's VFX scene is missing, so it shows its icon).
	cm.clear_all_conditions()
	cm.apply_condition("poisoned", null, 2)
	var label := ""
	if v._condition_display != null:
		for r in v._condition_display.get_children():
			for ch in r.get_children():
				if ch is Label:
					label = ch.text
	_check("text.icon-stack-count", label == "2", label)
	cm.clear_all_conditions()
	# The log says "stacks", as the summaries' "x3" counts them.
	_check("text.stack-word", ConditionManager._stacks_text(3) == "3 stacks" and ConditionManager._stacks_text(1) == "1 stack")
	await _clear()


func _case_no_log_flood() -> void:
	var p := await _dummy("Ada", true)
	var foe := await _dummy("Foe")
	var n0 := GameLog.get_entries().size()
	for i in 6:
		p.take_damage({"fire": 4}, p.global_position, foe)
		p.take_damage({"poison": 3}, p.global_position, foe)
		_run(p, 0.5)
	var added: Array = GameLog.get_entries().slice(n0)
	var dot_lines := 0
	for e in added:
		var s := String(e.get("text", ""))
		if s.contains("Burning") or s.contains("Poisoned"):
			dot_lines += 1
	_check("log.rider-stacks-dont-log", dot_lines == 0, added)
	_check("log.rider-stacks-landed", _stacks(p, "burning") == 3 and _stacks(p, "poisoned") == 4, [_stacks(p, "burning"), _stacks(p, "poisoned")])
	# A save that worsens or eases logs once, in stacks (condition_feedback_test
	# covers the dice); here the wording only.
	var cm := _cm(p)
	cm.clear_all_conditions()
	var n1 := GameLog.get_entries().size()
	cm.apply_condition("chilled", foe, 3)
	_check("log.transform-says-stacks", _log_count("Ada is now Frozen (Chilled reached 3 stacks).") == 1, GameLog.get_entries().slice(n1))
	cm.clear_all_conditions()
	await _clear()


func _case_descriptions_match_data() -> void:
	# Each DoT's text names its own numbers, so data and text can't drift apart.
	for id in ["burning", "poisoned", "corroding", "shocked", "bleeding"]:
		var t := _tmpl(id)
		var eff: Dictionary = t.triggered_effects[0]
		var every := "every second" if is_equal_approx(float(eff["interval"]), 1.0) else "every %d s" % int(eff["interval"])
		var dtype := str(eff["damage_type"])
		var per := "deals %d %sdamage %s" % [int(eff["value"]), "" if dtype == "true" else dtype + " ", every]
		_check("desc.%s-tick" % id, t.description.contains(per), [per, t.description])
		_check("desc.%s-max" % id, t.description.contains("up to %d stacks" % t.max_tier), t.description)
		var lasts := t.duration * (1.2 if t.traits.has("fire") else 1.0)
		_check("desc.%s-refresh" % id, t.description.contains("%d s after the last" % int(round(lasts))) or t.description.contains("lasts %d s after the last" % int(round(lasts))), t.description)
		if t.damage_per_stack > 0.0:
			_check("desc.%s-k" % id, t.description.contains("1 stack per %d" % int(t.damage_per_stack)), t.description)
	var ch := _tmpl("chilled")
	_check("desc.chilled", ch.description.contains("1 stack per 12 cold damage") and ch.description.contains("15 s after the last") and ch.description.contains("At 3 stacks, you freeze"), ch.description)
	_check("desc.bleeding-save-interval", _tmpl("bleeding").description.contains("every %d seconds" % int(_tmpl("bleeding").save_interval)))
	_check("desc.stuck-in-fire", _tmpl("stuck_in_fire").description.contains("2 fire damage every second") and _tmpl("stuck_in_fire").description.contains("2.4 s"))


# ---------------------------------------------------------------------------
# E. Per-source totals, from the shipped data
# ---------------------------------------------------------------------------

var _rows: Array = []


func _row(source: String, applies: String, r: Dictionary) -> void:
	_rows.append([source, applies, r])


func _hit(v: ProceduralCharacter, type: String, amount: float) -> Callable:
	return func():
		v.take_damage({type: amount}, v.global_position)


func _caster(caster: ProceduralCharacter, v: ProceduralCharacter, ability: Ability) -> Callable:
	return func():
		caster.ability_manager._resolve_effects(ability, ability.effects, v.global_position, [v])


func _case_source_table() -> void:
	var surfaces: Dictionary = _json("res://data/surfaces.json").get("surfaces", {})
	var fluids: Dictionary = _json("res://data/fluids.json").get("fluids", {})
	var weather: Dictionary = _json("res://data/weather.json")
	var v: ProceduralCharacter

	# Weapon and thrown riders (Items.json elemental damage, STR 50).
	for w in [["Match Striker (1 fire)", "fire", 1.0], ["Flaming Sword (5 fire)", "fire", 5.0],
			["Stiletto (2 poison)", "poison", 2.0], ["Poison Vial (18 poison)", "poison", 18.0]]:
		v = await _dummy("Rider")
		var r := _simulate(v, [[0.0, _hit(v, w[1], w[2])]], 0.0)
		_row(w[0], "%s x%d" % [DOTS[0] if w[1] == "fire" else "poisoned", r["peak"]], r)
		await _clear()
	var cuts := func():
		for w in [["Longsword cut (15 slashing)", "slashing", 15.0], ["Heavy blow (30 slashing)", "slashing", 30.0]]:
			var b := await _dummy("Rider")
			var r := _simulate(b, [[0.0, _hit(b, w[1], w[2])]], 0.0)
			_row(w[0] + ", no CON save", "bleeding x%d" % r["peak"], r)
			await _clear()
		return true
	await _without_bleed_saves(cuts)
	_check("table.match-striker-6", _rows[0][2]["total"] == 6, _rows[0][2])
	_check("table.poison-vial-20", _rows[3][2]["total"] == 20, _rows[3][2])

	# Spells.
	v = await _dummy("Mark")
	var caster := await _dummy("Caster")
	var fb := _ability("fireball")
	var r_fb := _simulate(v, [[0.0, _caster(caster, v, fb)]], 0.0)
	_row("Fireball (24 fire + 2 Burning)", "burning x2", r_fb)
	_check("table.fireball-12", r_fb["total"] == 12, r_fb)
	await _clear()
	v = await _dummy("Mark")
	caster = await _dummy("Caster")
	var asp := _ability("acid_splash")
	_row("Acid Splash (16 acid + 1 Corroding)", "corroding x1", _simulate(v, [[0.0, _caster(caster, v, asp)]], 0.0))
	await _clear()
	var ck_raw = AbilityDatabase.get_ability_data("cloud_kill").get("effects", {})
	var ck: Dictionary = {}
	if ck_raw is Dictionary:
		ck = ck_raw
	elif ck_raw is Array and not ck_raw.is_empty():
		ck = ck_raw[0]
	var ck_int := float(ck.get("apply_interval", 2.0))
	var ck_dur := float(ck.get("duration", 15.0))
	v = await _dummy("Cloud")
	_row("Cloud Kill, the whole %d s" % int(ck_dur), "poisoned", _simulate(v, _every(ck_int, ck_dur, _applier(v, "poisoned", 1)), 0.0))
	await _clear()
	v = await _dummy("Cloud")
	_row("Cloud Kill, out after 4 s", "poisoned", _simulate(v, _every(ck_int, 4.0, _applier(v, "poisoned", 1)), 0.0))
	await _clear()

	# Surfaces.
	var fire: Dictionary = surfaces.get("fire", {})
	for stay in [1.0, 3.0, 10.0]:
		v = await _dummy("Walker")
		_row("Burning ground, %d s in it" % int(stay), "burning", _simulate(v, _every(float(fire.get("apply_interval", 1.0)), stay, _applier(v, "burning", int(fire.get("condition_stacks", 1)))), 0.0))
		await _clear()
	var spin: Dictionary = surfaces.get("fire_spin", {})
	v = await _dummy("Spun")
	var r_spin := _simulate(v, _every(float(spin.get("apply_interval", 0.5)), float(spin.get("base_duration", 6.0)), _applier(v, "stuck_in_fire", 1), 0.0), 0.0)
	_row("Fire Spin, the whole %d s (rooted)" % int(spin.get("base_duration", 6.0)), "stuck_in_fire", r_spin)
	_check("table.fire-spin-about-18", r_spin["total"] >= 16 and r_spin["total"] <= 20, r_spin)
	await _clear()
	var elec: Dictionary = surfaces.get("electrified", {})
	v = await _dummy("Wet")
	_row("Electrified water (%.1f s)" % float(elec.get("base_duration", 1.2)), "shocked", _simulate(v, _every(float(elec.get("apply_interval", 0.3)), float(elec.get("base_duration", 1.2)), _applier(v, "shocked", int(elec.get("condition_stacks", 1)))), 0.0))
	await _clear()

	# Fluids underfoot.
	for f in [["acid", 3.0], ["poison", 6.0]]:
		var fd: Dictionary = fluids.get(f[0], {})
		var cid := str(fd.get("condition_id", ""))
		v = await _dummy("Wader")
		_row("%s puddle, %d s in it" % [str(f[0]).capitalize(), int(f[1])], cid, _simulate(v, _every(float(fd.get("apply_interval", 1.0)), f[1], _applier(v, cid, int(fd.get("condition_stacks", 1)))), 0.0))
		await _clear()

	# Fogs (fogs.json: 1 stack a second; no shipped map uses these two).
	for f in [["Poison fog", "poisoned"], ["Acidic mist", "corroding"]]:
		v = await _dummy("Fogged")
		_row("%s, 5 s in it" % f[0], f[1], _simulate(v, _every(1.0, 5.0, _applier(v, f[1], 1)), 0.0))
		await _clear()

	# Weather: applies every apply_interval out in the open up to max_stacks,
	# then only holds it (Game._tick_weather_conditions).
	var precip: Dictionary = {}
	for k in weather:
		if weather[k] is Dictionary and weather[k].has("acid_rain"):
			precip = weather[k]
	var ar: Dictionary = precip.get("acid_rain", {})
	v = await _dummy("Outdoors")
	var cap := int(ar.get("max_stacks", 1))
	var hold := func():
		var cm := _cm(v)
		var ex = cm.conditions.get("corroding")
		if ex != null and ex.stacks >= cap:
			ex.expires_at = maxf(ex.expires_at, _now() + float(ex.condition.duration))
		else:
			cm.apply_condition("corroding", null, 1)
	var r_rain := _simulate(v, _every(float(ar.get("apply_interval", 3.0)), 60.0, hold), 0.0)
	_row("Acid Rain, 60 s in the open", "corroding x%d" % cap, r_rain)
	await _clear()
	var fr: Dictionary = precip.get("freezing_rain", {})
	_check("table.freezing-rain-cap-below-freeze", int(fr.get("max_stacks", 0)) < int(_tmpl("chilled").transforms_into.get("required_tier", 3)), fr)

	print("--- DoT totals per source (after the hit itself; no armour; Bleeding without its CON saves) ---")
	print("%-42s %-16s %6s %6s %8s" % ["source", "applies", "total", "peak", "lasts"])
	for row in _rows:
		var r: Dictionary = row[2]
		print("%-42s %-16s %6d %6d %7.1fs" % [row[0], row[1], r["total"], r["peak"], float(r["lasted"])])
	_check("table.printed", _rows.size() >= 16, _rows.size())
