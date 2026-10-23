extends Node2D
# Round 5, DoT tuning: the developer's answers to round 4's DoT questions.
#   A. "Let's increase max stacks for burning to four": Burning max_tier 4.
#   B. "Could we do, say, 5 damage each?": damage_per_stack 5 for Burning,
#      Poisoned, Chilled and Bleeding (a hit adds ceil(dealt / 5) stacks,
#      dealt = that type's damage after armour). Worked examples, and the
#      Bleeding and Chilled consequences printed.
#   C. "DoT should Ignore armor": a condition's damage tick skips worn armour
#      (ProceduralCharacter.take_damage), its weaknesses included; an armoured
#      and a bare bearer take the same ticks. Condition DR and immunities
#      still apply. A hit's rider still counts the hit's damage after armour.
#      Acid Rain printed for a bare and an armoured character.
#   D. "'fire conditions last x1.2' ... should not be true as a universal
#      rule": MODIFY_DURATION_BY_TRAIT is empty by default, a character's data
#      can still set it, and a saved legacy table is not restored.
#   E. "Poisoned: set the transform threshold to 4": Poisoned turns into
#      Toxic Shock at 4, with a float and a log line.
#   F. Every DoT description says armour doesn't reduce it, and the numbers
#      in the descriptions and summaries are the new ones.
#   G. The new numbers per condition and per source (printed).
# Round 6 (tests/status_conds_r6_test covers the new rules) changed two of
# these: Chilled caps and freezes at 4, so 11-15 cold is Chilled x3 and only
# 16+ freezes at once; Toxic Shock has no duration and its tick doubles (1, 2,
# 4 ... 32) until cured, a re-dose moving it on rather than restarting it,
# and no longer slows. The checks below assert the round-6 numbers.
# The condition clock (TimeManager.absolute_time) is driven by hand in exact
# 1/16 s steps, and each ConditionManager._process is called directly.
#   godot --headless --path . res://tests/dot_tune_r5_test.tscn
# Judge by the PASS/FAIL lines and "HARNESS DONE failures=0".

const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const GAME_SCRIPT := preload("res://Game.gd")

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
const K_IDS := ["burning", "poisoned", "chilled", "bleeding"]
## Every condition whose tick deals damage.
const DOTS := ["burning", "poisoned", "toxic_shock", "bleeding", "shocked", "corroding", "stuck_in_fire", "suffocating", "winters_grip_bite"]
## Heavy armour of every type a DoT deals, on the torso (ticks land there).
const HEAVY := {"fire": 5, "poison": 5, "cold": 5, "acid": 5, "electric": 5,
	"slashing": 5, "piercing": 5, "bludgeoning": 5, "true": 5}
## The table every character carried before round 5.
const LEGACY_TABLE := {"fire": 1.2, "ice": 1.5, "spell": 1.0, "aoe": 1.3, "attack": 1.0, "magical": 1.1}

var failures := 0
var checks := 0
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
	ConditionManager.register_conditions([{
		"id": "r5_every_old_trait", "display_name": "Every Old Trait",
		"traits": {"debuff": 1, "fire": 1, "ice": 1, "aoe": 1, "magical": 1, "spell": 1, "attack": 1},
		"stackable": false, "duration": 10.0, "canceled_by_trait": [], "immunities": {},
	}])

	await _case_burning_cap()
	await _case_k_five()
	await _case_ticks_ignore_armour()
	await _case_acid_rain()
	await _case_durations()
	await _case_toxic_shock()
	_case_text()
	await _case_new_numbers()

	TimeManager.is_paused = _saved_paused
	TimeManager.game_time = _saved_game_time
	print("HARNESS DONE failures=%d checks=%d" % [failures, checks])
	get_tree().quit(1 if failures > 0 else 0)


# ---------------------------------------------------------------------------
# Helpers (as tests/dot_r4_test.gd)
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


## A character built from a template (inventory and gear slots), for the
## save/restore case.
func _built(char_name: String) -> ProceduralCharacter:
	var c: ProceduralCharacter = PC_SCENE.instantiate()
	c.AI_enabled = false
	c.is_player_controlled = true
	add_child(c)
	TopDownCharacterDatabase.build_character(c, "default_human")
	c.game = self
	c.faction_id = "player"
	c.Name = char_name
	c.global_position = ORIGIN
	characters_in_scene.append(c)
	party_chars.append(c)
	await get_tree().process_frame
	_cm(c).set_process(false)
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


func _stacks(c: ProceduralCharacter, id: String) -> int:
	var inst = _cm(c).get_condition(id)
	return inst.stacks if inst else 0


func _armour(c: ProceduralCharacter, dr: Dictionary) -> void:
	c.set_limb_armor(ProceduralCharacter.LimbType.TORSO, dr.duplicate())


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


## DoT damage a character takes over a run: {total (sum of the ticks), hp
## (HP actually lost), ticks, peak (stacks), lasted (s)}. `schedule` is
## [[seconds, Callable], ...], each fired on the first step at or past its
## time, before that step's conditions tick. The run lasts at least
## `min_seconds`, then until no damaging condition is left, or until the
## bearer dies ("died"; a corpse doesn't tick, and Toxic Shock never wears off).
func _simulate(c: ProceduralCharacter, schedule: Array, min_seconds: float) -> Dictionary:
	var cm := _cm(c)
	var out := {"total": 0, "hp": 0, "ticks": 0, "peak": 0, "lasted": 0.0, "seen": [], "died": false}
	var on_tick := func(_inst, _eff, res):
		if res.has("damage"):
			out["total"] += int(res["damage"])
			out["ticks"] += 1
	cm.triggered_effect_fired.connect(on_tick)
	var hp0 := c.current_health
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
				if not (out["seen"] as Array).has(inst.condition.id):
					(out["seen"] as Array).append(inst.condition.id)
		if any:
			out["lasted"] = t
		if not c.is_alive():
			out["died"] = true
			break
		if (t >= min_seconds and not any and pending.is_empty()) or t > 300.0:
			break
		i += 1
	cm.triggered_effect_fired.disconnect(on_tick)
	out["hp"] = hp0 - c.current_health
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


func _applier(v: ProceduralCharacter, id: String, stacks: int) -> Callable:
	return func():
		if is_instance_valid(v) and v.is_alive():
			_cm(v).apply_condition(id, null, stacks)


func _hit(v: ProceduralCharacter, type: String, amount: float) -> Callable:
	return func():
		v.take_damage({type: amount}, v.global_position)


func _ability(id: String) -> Ability:
	return Ability.from_dict(AbilityDatabase.get_ability_data(id))


## Log lines containing `fragment`, counting the repeats GameLog folds into
## one entry ("(x2)") within its 1.5 s window.
func _log_count(fragment: String) -> int:
	var n := 0
	for e in GameLog.get_entries():
		if String(e.get("text", "")).contains(fragment):
			n += int(e.get("count", 1))
	return n


## HP a character loses to `stacks` of `id` over `seconds` (the condition is
## then removed), with the ticks' own sum: {hp, ticks_total}.
func _tick_run(c: ProceduralCharacter, id: String, stacks: int, seconds: float) -> Dictionary:
	var cm := _cm(c)
	var sum := [0]
	var on_tick := func(inst, _eff, res):
		if res.has("damage") and inst.condition.id == id:
			sum[0] += int(res["damage"])
	cm.triggered_effect_fired.connect(on_tick)
	c.current_health = c.max_health
	var hp0 := c.current_health
	cm.apply_condition(id, null, stacks)
	_run(c, seconds)
	cm.triggered_effect_fired.disconnect(on_tick)
	cm.clear_all_conditions()
	return {"hp": hp0 - c.current_health, "ticks_total": sum[0]}


# ---------------------------------------------------------------------------
# A. Burning caps at 4
# ---------------------------------------------------------------------------

func _case_burning_cap() -> void:
	var t := _tmpl("burning")
	_check("cap.burning-max-4", t.max_tier == 4, t.max_tier)
	var v := await _dummy("Torch")
	var cm := _cm(v)
	cm.apply_condition("burning", null, 9)
	_check("cap.apply-held-to-4", _stacks(v, "burning") == 4, _stacks(v, "burning"))
	cm.clear_all_conditions()
	v.take_damage({"fire": 40}, v.global_position)
	_check("cap.big-fire-hit-4", _stacks(v, "burning") == 4, _stacks(v, "burning"))
	var now := _now()
	_check("cap.summary-x4", cm.get_condition("burning").get_summary(now) == "Burning x4: 4 fire every 1 s (5s left)",
		cm.get_condition("burning").get_summary(now))
	cm.clear_all_conditions()
	# Four 1-point fire hits stack to 4 (the old cap stopped at 3).
	for i in 4:
		v.take_damage({"fire": 1}, v.global_position)
	_check("cap.four-small-hits-4", _stacks(v, "burning") == 4, _stacks(v, "burning"))
	cm.clear_all_conditions()
	# A save holding Burning above the cap still loads at the cap.
	cm.from_dict({"conditions": {"burning": {"condition_id": "burning", "stacks": 9.0, "expires_at": _now() + 5.0}}})
	_check("cap.save-held-to-4", _stacks(v, "burning") == 4, _stacks(v, "burning"))
	cm.clear_all_conditions()
	await _clear()


# ---------------------------------------------------------------------------
# B. K = 5 for all four
# ---------------------------------------------------------------------------

func _case_k_five() -> void:
	for id in K_IDS:
		var t := _tmpl(id)
		_check("k.%s-is-5" % id, t != null and is_equal_approx(t.damage_per_stack, 5.0), t.damage_per_stack if t else "missing")
	# ceil(dealt / 5), at least 1, at most the cap (Poisoned's 4th stack turns
	# it into Toxic Shock on landing; stacks_for_damage only counts).
	var cases := {
		"burning": {1: 1, 5: 1, 6: 2, 10: 2, 11: 3, 15: 3, 16: 4, 40: 4},
		"poisoned": {2: 1, 5: 1, 6: 2, 10: 2, 11: 3, 15: 3, 16: 4, 18: 4},
		"chilled": {3: 1, 4: 1, 5: 1, 6: 2, 10: 2, 11: 3, 15: 3, 16: 4, 40: 4},
		"bleeding": {5: 1, 6: 2, 10: 2, 12: 3, 15: 3, 16: 4, 20: 4, 21: 5, 30: 5},
	}
	for id in cases:
		for dealt in cases[id]:
			var got: int = _tmpl(id).stacks_for_damage(float(dealt))
			_check("k.%s-%d->%d" % [id, dealt, cases[id][dealt]], got == cases[id][dealt], got)

	# Through the real hit path.
	var v := await _dummy("Anvil")
	var cm := _cm(v)
	var cuts := func():
		for w in [[10.0, 2], [15.0, 3], [20.0, 4], [21.0, 5]]:
			v.take_damage({"slashing": w[0]}, v.global_position)
			_check("hit.cut-%d-bleeds-%d" % [int(w[0]), w[1]], _stacks(v, "bleeding") == w[1], _stacks(v, "bleeding"))
			cm.clear_all_conditions()
		v.take_damage({"piercing": 15.0}, v.global_position)
		_check("hit.piercing-15-bleeds-3", _stacks(v, "bleeding") == 3, _stacks(v, "bleeding"))
		cm.clear_all_conditions()
		v.current_health = v.max_health
		return true
	await _without_bleed_saves(cuts)
	# Cold: 1 stack per 5, four freeze (round 6; three in round 5).
	v.take_damage({"cold": 8}, v.global_position)
	_check("hit.cold-8-chills-2", _stacks(v, "chilled") == 2 and not cm.has_condition("frozen"), _stacks(v, "chilled"))
	cm.clear_all_conditions()
	v.take_damage({"cold": 10}, v.global_position)
	_check("hit.cold-10-still-2", _stacks(v, "chilled") == 2 and not cm.has_condition("frozen"), _stacks(v, "chilled"))
	cm.clear_all_conditions()
	v.take_damage({"cold": 11}, v.global_position)
	_check("hit.cold-11-chills-3", _stacks(v, "chilled") == 3 and not cm.has_condition("frozen"), _stacks(v, "chilled"))
	cm.clear_all_conditions()
	v.take_damage({"cold": 15}, v.global_position)
	_check("hit.iciclet-15-chills-3", _stacks(v, "chilled") == 3 and not cm.has_condition("frozen"), _stacks(v, "chilled"))
	cm.clear_all_conditions()
	v.take_damage({"cold": 16}, v.global_position)
	_check("hit.cold-16-freezes-in-one", cm.has_condition("frozen") and not cm.has_condition("chilled"))
	cm.clear_all_conditions()
	# Frost Axe 4 cold and Winter's Grip 3: a stack a hit, four hits.
	for w in [["frost-axe", 4.0], ["winters-grip", 3.0]]:
		var hits := 0
		while not cm.has_condition("frozen") and hits < 10:
			v.take_damage({"cold": w[1]}, v.global_position)
			hits += 1
		_check("hit.%s-freezes-in-4" % w[0], hits == 4, hits)
		cm.clear_all_conditions()
	# A Frost Axe at STR 100 (6 cold) brings 2 stacks: two hits.
	var hits2 := 0
	while not cm.has_condition("frozen") and hits2 < 10:
		v.take_damage({"cold": 6.0}, v.global_position)
		hits2 += 1
	_check("hit.frost-axe-str100-freezes-in-2", hits2 == 2, hits2)
	cm.clear_all_conditions()
	v.current_health = v.max_health

	print("--- Bleeding per slashing/piercing hit, before its CON save (K 20 -> 5) ---")
	print("%-10s %-14s %-14s" % ["cut", "stacks", "extra damage"])
	for cut in [5, 10, 12, 15, 18, 20, 25, 30]:
		var before: int = mini(5, maxi(1, int(ceil(cut / 20.0))))
		var after: int = _tmpl("bleeding").stacks_for_damage(float(cut))
		print("%-10d %d -> %-9d %d -> %d" % [cut, before, after, before * 4, after * 4])
	print("--- Chilled from one cold hit (K 12 -> 5; Frozen at 4 since round 6) ---")
	var freeze_at: int = int(_tmpl("chilled").transforms_into.get("required_tier", 4))
	for src in [["Winter's Grip (3 cold)", 3], ["Frost Axe (4 cold)", 4], ["Frost Axe at STR 100 (6)", 6], ["Iciclet (15 cold, thrown)", 15], ["Iciclet at STR 57+ (16)", 16], ["Iciclet at STR 30 (12)", 12]]:
		var before_c: int = mini(3, maxi(1, int(ceil(src[1] / 12.0))))
		var after_c: int = _tmpl("chilled").stacks_for_damage(float(src[1]))
		print("%-28s %d -> %d%s" % [src[0], before_c, after_c, "  FREEZES" if after_c >= freeze_at else ""])
	await _clear()


# ---------------------------------------------------------------------------
# C. Ticks ignore armour
# ---------------------------------------------------------------------------

func _case_ticks_ignore_armour() -> void:
	var bare := await _dummy("Bare")
	var plate := await _dummy("Plated")
	_armour(plate, HEAVY)
	# Armour that is weak to every DoT type (negative entries): no worse either.
	var frail := await _dummy("Frail")
	var weak_to_all := {}
	for k in HEAVY:
		weak_to_all[k] = -2
	_armour(frail, weak_to_all)
	var per := {"burning": 4, "poisoned": 3, "toxic_shock": 1, "bleeding": 5, "shocked": 3, "corroding": 3,
		"stuck_in_fire": 1, "suffocating": 1, "winters_grip_bite": 1}
	var each := func():
		for id in DOTS:
			var secs := 12.5 if id == "winters_grip_bite" else 20.0
			var a := _tick_run(bare, id, per[id], secs)
			var b := _tick_run(plate, id, per[id], secs)
			var w := _tick_run(frail, id, per[id], secs)
			_check("armour.%s-same-ticks" % id, a["hp"] == b["hp"] and a["hp"] > 0, [a, b])
			_check("armour.%s-hp-is-the-ticks" % id, b["hp"] == b["ticks_total"], b)
			_check("armour.%s-weakness-adds-nothing" % id, w["hp"] == a["hp"] and w["hp"] == w["ticks_total"], [a, w])
		return true
	await _without_bleed_saves(each)
	# The immediate first tick too: Burning x4 lands 4 at once through 5 fire armour.
	plate.current_health = plate.max_health
	var hp0 := plate.current_health
	_cm(plate).apply_condition("burning", null, 4)
	_cm(plate)._process(0.0)
	_check("armour.first-tick-whole", hp0 - plate.current_health == 4, hp0 - plate.current_health)
	# What the summary says is what lands.
	var inst := _cm(plate).get_condition("burning")
	_check("armour.summary-is-what-lands", inst.get_dot_text() == "4 fire every 1 s", inst.get_dot_text())
	_cm(plate).clear_all_conditions()

	# A hit is still armoured, and its rider counts the damage after armour:
	# 13 fire through fire 5 deals 8, which lights 2 stacks (3 bare).
	plate.current_health = plate.max_health
	hp0 = plate.current_health
	plate.take_damage({"fire": 13}, plate.global_position)
	_check("rider.hit-still-armoured", hp0 - plate.current_health == 8, hp0 - plate.current_health)
	_check("rider.stacks-from-hit-after-armour", _stacks(plate, "burning") == 2, _stacks(plate, "burning"))
	bare.take_damage({"fire": 13}, bare.global_position)
	_check("rider.bare-gets-3", _stacks(bare, "burning") == 3, _stacks(bare, "burning"))
	_cm(plate).clear_all_conditions()
	_cm(bare).clear_all_conditions()
	var cut := func():
		plate.take_damage({"slashing": 15}, plate.global_position)
		_check("rider.cut-through-armour-2-bleed", _stacks(plate, "bleeding") == 2, _stacks(plate, "bleeding"))
		_cm(plate).clear_all_conditions()
		return true
	await _without_bleed_saves(cut)

	# An armour weakness (a negative entry) is armour too: it doesn't add to a
	# tick. Shocked x1 in Legionnaire's Armour (electric -1) deals the 1 a tick
	# its summary says, as bare; a hit still feels the weakness.
	var tin := await _dummy("Legionnaire")
	_armour(tin, {"slashing": 4, "bludgeoning": 3, "piercing": 3, "electric": -1})
	var r := _tick_run(tin, "shocked", 1, 1.5)
	_check("weakness.ignored-by-ticks", r["hp"] == 2 and r["ticks_total"] == 2, r)
	var tin_shock := _cm(tin).apply_condition("shocked", null, 1)
	_check("weakness.summary-is-what-lands", tin_shock != null and tin_shock.get_dot_text() == "1 electric every 1 s", tin_shock.get_dot_text() if tin_shock else "none")
	_cm(tin).clear_all_conditions()
	tin.current_health = tin.max_health
	_check("weakness.hit-still-feels-it", tin.take_damage({"electric": 3}, tin.global_position) == 4)

	# Condition DR (not armour) still takes from a physical tick: Stalwart's 1
	# off Suffocating's 6. Not from fire (it only covers physical types).
	var tough := await _dummy("Stalwart")
	_cm(tough).apply_condition("stalwart", null, 1)
	r = _tick_run(tough, "suffocating", 1, 0.5)
	_cm(tough).apply_condition("stalwart", null, 1)
	_check("dr.condition-dr-on-physical-tick", r["hp"] == 5, r)
	var rf := _tick_run(tough, "burning", 2, 0.5)
	_check("dr.not-on-fire-tick", rf["hp"] == 2, rf)
	# Immunities still apply: Shielded wards off Burning entirely.
	_cm(tough).apply_condition("shielded", null, 1)
	_check("immunity.shielded-blocks-burning", _cm(tough).apply_condition("burning", null, 2) == null and not _cm(tough).has_condition("burning"))
	_cm(tough).clear_all_conditions()
	await _clear()


# ---------------------------------------------------------------------------
# C. Acid Rain, bare and armoured (unchanged: its ticks are 1 point, which
# armour never stopped below the 1-point chip floor)
# ---------------------------------------------------------------------------

func _acid_rain_total(v: ProceduralCharacter) -> Dictionary:
	var precip: Dictionary = {}
	var f := FileAccess.open("res://data/weather.json", FileAccess.READ)
	var weather = JSON.parse_string(f.get_as_text()) if f else {}
	for k in weather:
		if weather[k] is Dictionary and weather[k].has("acid_rain"):
			precip = weather[k]
	var ar: Dictionary = precip.get("acid_rain", {})
	var cap := int(ar.get("max_stacks", 1))
	var hold := func():
		var cm := _cm(v)
		var ex = cm.conditions.get("corroding")
		if ex != null and ex.stacks >= cap:
			ex.expires_at = maxf(ex.expires_at, _now() + float(ex.condition.duration))
		else:
			cm.apply_condition("corroding", null, 1)
	return _simulate(v, _every(float(ar.get("apply_interval", 3.0)), 60.0, hold), 0.0)


func _case_acid_rain() -> void:
	var bare := await _dummy("Outdoors")
	var r_bare := _acid_rain_total(bare)
	var plate := await _dummy("Armoured outdoors")
	_armour(plate, {"slashing": 4, "bludgeoning": 3, "piercing": 3, "acid": 2})
	var r_plate := _acid_rain_total(plate)
	print("Acid Rain, 60 s in the open: bare %d HP, armoured (acid 2) %d HP" % [r_bare["hp"], r_plate["hp"]])
	_check("acid-rain.same-bare-and-armoured", r_bare["hp"] == r_plate["hp"] and r_bare["hp"] == r_bare["total"], [r_bare, r_plate])
	_check("acid-rain.unchanged-61", r_bare["total"] == 61, r_bare)
	# Before this change the armoured character took the same: a 1-point hit
	# through acid 2 is held to the 1-point chip floor.
	var probe := await _dummy("Probe")
	_armour(probe, {"acid": 2})
	probe.current_health = probe.max_health
	_check("acid-rain.chip-floor-made-it-1-before", probe.take_damage({"acid": 1}, probe.global_position) == 1)
	await _clear()


# ---------------------------------------------------------------------------
# D. Neutral duration multipliers
# ---------------------------------------------------------------------------

func _lasts(c: ProceduralCharacter, id: String) -> float:
	var inst := _cm(c).apply_condition(id, null, 1)
	var out := inst.expires_at - _now() if inst != null else -1.0
	_cm(c).clear_all_conditions()
	return out


func _case_durations() -> void:
	var v := await _dummy("Clock")
	_check("dur.table-empty-by-default", v.MODIFY_DURATION_BY_TRAIT.is_empty(), v.MODIFY_DURATION_BY_TRAIT)
	var want := {"burning": 5.0, "stuck_in_fire": 2.0, "chilled": 15.0, "poisoned": 10.0, "hasted": 30.0,
		"shielded": 45.0, "animal_magnetism": 30.0, "r5_every_old_trait": 10.0}
	for id in want:
		var got := _lasts(v, id)
		_check("dur.%s-%ss" % [id, str(want[id])], is_equal_approx(got, want[id]), got)
	# Burning: 5 per stack in play, matching K = 5.
	var r := _simulate(v, [[0.0, _applier(v, "burning", 1)]], 0.0)
	_check("dur.burning-5-per-stack", r["total"] == 5 and r["ticks"] == 5, r)
	# Ability impact VFX: their authored visual_duration (Fireball was x1.716).
	var fb := _ability("fireball")
	_check("dur.fireball-visual-authored", is_equal_approx(v._get_modified_visual_duration(fb), fb.visual_duration), v._get_modified_visual_duration(fb))

	# A character's data can still set its own table.
	var salamander := await _dummy("Salamander")
	salamander.load_from_data({"modify_duration_by_trait": {"fire": 2.0}})
	_check("dur.data-override-fire", is_equal_approx(_lasts(salamander, "burning"), 10.0), _lasts(salamander, "burning"))
	_check("dur.data-override-only-its-trait", is_equal_approx(_lasts(salamander, "chilled"), 15.0))
	_check("dur.data-override-visual", is_equal_approx(salamander._get_modified_visual_duration(fb), fb.visual_duration * 2.0))

	# Saves: the table isn't written, and a legacy one isn't restored.
	var game = GAME_SCRIPT.new()
	var a := await _built("Saver")
	var snap: Dictionary = game._serialize_character(a)
	_check("save.table-not-written", not snap.has("MODIFY_DURATION_BY_TRAIT"), snap.keys())
	snap["MODIFY_DURATION_BY_TRAIT"] = LEGACY_TABLE.duplicate()
	var b := await _built("Loader")
	game._deserialize_character(b, snap)
	_check("save.legacy-table-not-restored", b.MODIFY_DURATION_BY_TRAIT.is_empty(), b.MODIFY_DURATION_BY_TRAIT)
	_check("save.burning-still-5s-after-load", is_equal_approx(_lasts(b, "burning"), 5.0), _lasts(b, "burning"))
	game.free()
	await _clear()


# ---------------------------------------------------------------------------
# E. Poisoned -> Toxic Shock at 4
# ---------------------------------------------------------------------------

func _case_toxic_shock() -> void:
	var ts := _tmpl("toxic_shock")
	_check("toxic.registered", ts != null)
	_check("toxic.poisoned-turns-at-4", _tmpl("poisoned").transforms_into == {"id": "toxic_shock", "required_tier": 4}, _tmpl("poisoned").transforms_into)
	if ts == null:
		return
	_check("toxic.poison-trait", ts.traits.has("poison") and ts.traits.has("debuff"), ts.traits)

	var p := await _dummy("Ada", true)
	var foe := await _dummy("Foe")
	var cm := _cm(p)
	var speed0: float = p.move_speed
	cm.apply_condition("poisoned", foe, 3)
	_check("toxic.three-stays-poisoned", _stacks(p, "poisoned") == 3 and not cm.has_condition("toxic_shock"))
	p._last_notify_text = ""
	var n0 := _log_count("Ada's Poisoned reaches 4 stacks: Toxic Shock.")
	var out := cm.apply_condition("poisoned", foe, 1)
	_check("toxic.fourth-stack-turns", cm.has_condition("toxic_shock") and not cm.has_condition("poisoned") and out != null and out.condition.id == "toxic_shock")
	_check("toxic.floats", p._last_notify_text == "Toxic Shock!", p._last_notify_text)
	_check("toxic.logged-once", _log_count("Ada's Poisoned reaches 4 stacks: Toxic Shock.") == n0 + 1, GameLog.get_entries().slice(-3))
	var now := _now()
	var shock := cm.get_condition("toxic_shock")
	# Round 6: no time left to show; the tick, that it doubles, and the cure.
	_check("toxic.summary", shock.get_summary(now) == "Toxic Shock: 1 poison every 2 s, doubling (cure: Heal or a Potion of Healing)", shock.get_summary(now))
	# Round 6 dropped round 5's 30% slow: the developer's model is the damage.
	_check("toxic.no-slow", is_equal_approx(p.move_speed, speed0), "%s -> %s" % [speed0, p.move_speed])
	# More poison builds Poisoned beside it; reaching 4 again moves Toxic
	# Shock on one doubling (round 6; round 5 restarted a 10 s timer).
	_run(p, 6.0)
	cm.apply_condition("poisoned", foe, 2)
	_check("toxic.poison-builds-beside", _stacks(p, "poisoned") == 2 and cm.has_condition("toxic_shock"))
	var steps0 := shock.escalation_steps(0)
	var w0 := _log_count("Ada's Poisoned reaches 4 stacks: Toxic Shock worsens")
	cm.apply_condition("poisoned", foe, 2)
	_check("toxic.again-steps-on", cm.get_condition("toxic_shock") == shock and steps0 == 3 and shock.escalation_steps(0) == 4 \
		and shock.expires_at < 0.0 and not cm.has_condition("poisoned"), [steps0, shock.escalation_steps(0), shock.expires_at])
	_check("toxic.again-logged", _log_count("Ada's Poisoned reaches 4 stacks: Toxic Shock worsens") == w0 + 1 \
		and _log_count("Ada's Poisoned reaches 4 stacks: Toxic Shock.") == n0 + 1, GameLog.get_entries().slice(-3))
	# Heal cures both, as it cured Poisoned.
	cm.apply_condition("poisoned", foe, 1)
	foe.ability_manager._resolve_effects(_ability("heal"), _ability("heal").effects, p.global_position, [p])
	_check("toxic.heal-cures", not cm.has_condition("toxic_shock") and not cm.has_condition("poisoned"))
	_check("toxic.speed-back", is_equal_approx(p.move_speed, speed0), p.move_speed)
	cm.clear_all_conditions()

	# Round 6: ticks at 0, 2, 4, 6, 8 s deal 1, 2, 4, 8, 16, through armour.
	_armour(p, HEAVY)
	p.current_health = p.max_health
	var hp_a := p.current_health
	var got: Array = []
	var on_tick := func(inst, _eff, res):
		if res.has("damage") and inst.condition.id == "toxic_shock":
			got.append(int(res["damage"]))
	cm.triggered_effect_fired.connect(on_tick)
	cm.apply_condition("poisoned", null, 4)
	_run(p, 9.0)
	cm.triggered_effect_fired.disconnect(on_tick)
	_check("toxic.doubles-through-armour", got == [1, 2, 4, 8, 16] and hp_a - p.current_health == 31, [got, hp_a - p.current_health])
	cm.clear_all_conditions()

	# One poison hit of 16+ goes straight to Toxic Shock; 15 is Poisoned x3.
	var npc := await _dummy("Mark")
	npc.take_damage({"poison": 18}, npc.global_position, foe)
	_check("toxic.poison-vial-18-straight-to-shock", _cm(npc).has_condition("toxic_shock") and not _cm(npc).has_condition("poisoned"))
	_cm(npc).clear_all_conditions()
	npc.take_damage({"poison": 16}, npc.global_position, foe)
	_check("toxic.16-poison-shock", _cm(npc).has_condition("toxic_shock"))
	_cm(npc).clear_all_conditions()
	npc.take_damage({"poison": 15}, npc.global_position, foe)
	_check("toxic.15-poison-x3", _stacks(npc, "poisoned") == 3 and not _cm(npc).has_condition("toxic_shock"))
	_cm(npc).clear_all_conditions()
	# An unseen NPC turns quietly: no float, no log line.
	npc._last_notify_text = ""
	var quiet0 := GameLog.get_entries().size()
	_cm(npc).apply_condition("poisoned", null, 4)
	_check("toxic.unseen-npc-quiet", _cm(npc).has_condition("toxic_shock") and npc._last_notify_text == "" and GameLog.get_entries().size() == quiet0,
		[npc._last_notify_text, GameLog.get_entries().slice(quiet0)])
	_cm(npc).clear_all_conditions()
	# A save from before Poisoned turned at 4 holds Poisoned x4; the next dose turns it.
	cm.from_dict({"conditions": {"poisoned": {"condition_id": "poisoned", "stacks": 4.0, "expires_at": _now() + 8.0}}})
	_check("toxic.old-save-x4-loads", _stacks(p, "poisoned") == 4)
	cm.apply_condition("poisoned", foe, 1)
	_check("toxic.old-save-x4-turns-on-next-dose", cm.has_condition("toxic_shock") and not cm.has_condition("poisoned"))
	cm.clear_all_conditions()
	# Frozen's transform line in the same form (at 4 stacks since round 6).
	var f0 := _log_count("Ada's Chilled reaches 4 stacks: Frozen.")
	cm.apply_condition("chilled", foe, 4)
	_check("toxic.frozen-line-same-form", _log_count("Ada's Chilled reaches 4 stacks: Frozen.") == f0 + 1)
	cm.clear_all_conditions()
	await _clear()


# ---------------------------------------------------------------------------
# F. Text
# ---------------------------------------------------------------------------

func _case_text() -> void:
	for id in DOTS:
		var d := _tmpl(id).description
		_check("text.%s-says-armour" % id, d.contains("Armour doesn't reduce it."), d)
		_check("text.%s-no-old-armour-wording" % id, not d.contains("whatever the armour"), d)
	for id in K_IDS:
		_check("text.%s-k-5" % id, _tmpl(id).description.contains("1 stack per 5 "), _tmpl(id).description)
	var b := _tmpl("burning").description
	_check("text.burning-4-and-5s", b.contains("up to 4 stacks") and b.contains("5 s after the last"), b)
	_check("text.poisoned-names-shock", _tmpl("poisoned").description.contains("At 4 stacks it turns into Toxic Shock"), _tmpl("poisoned").description)
	_check("text.stuck-in-fire-2s", _tmpl("stuck_in_fire").description.contains("Lasts 2 s after"), _tmpl("stuck_in_fire").description)
	# Round 6: a doubling tick from 1 to 32, no slow.
	var tsd := _tmpl("toxic_shock").description
	_check("text.toxic-shock-numbers", tsd.contains("1 poison damage every 2 s") and tsd.contains("doubling") and tsd.contains("then 32 a tick") and not tsd.contains("slower"), tsd)
	# Each description's tick matches its data.
	for id in DOTS:
		var t := _tmpl(id)
		var eff: Dictionary = t.triggered_effects[0]
		var every := "every second" if is_equal_approx(float(eff["interval"]), 1.0) else "every %d s" % int(eff["interval"])
		var dtype := str(eff["damage_type"])
		var per := "%d %sdamage %s" % [int(eff["value"]), "" if dtype == "true" else dtype + " ", every]
		_check("text.%s-tick-matches-data" % id, t.description.contains(per), [per, t.description])


# ---------------------------------------------------------------------------
# G. The new numbers
# ---------------------------------------------------------------------------

## Seconds a 30-HP character lasts with `stacks` of `id` re-applied every
## second (`once`: applied once only, for Toxic Shock, which never wears off).
func _kill_time(id: String, stacks: int, once := false) -> float:
	var v := await _dummy("Thirty " + id)
	v.current_health = 30
	var sched: Array = [[0.0, _applier(v, id, stacks)]] if once else _every(1.0, 60.0, _applier(v, id, stacks), 0.0)
	var start := _clock
	var cm := _cm(v)
	var died_at := -1.0
	for i in range(0, int(60.0 / STEP)):
		var t := i * STEP
		_set_clock(start + t)
		while not sched.is_empty() and float(sched[0][0]) <= t + 0.0001:
			(sched.pop_front()[1] as Callable).call()
		cm._process(STEP)
		if not v.is_alive():
			died_at = t
			break
	await _clear()
	return died_at


func _case_new_numbers() -> void:
	print("--- per condition: one stack alone, and held at its most (re-applied every second) ---")
	print("%-18s %9s %9s %9s %14s" % ["condition", "per stack", "max", "max HP/s", "kills 30 HP in"])
	# [id, its most stacks, stacks re-applied each second for the kill time].
	# Poisoned can't be held at 3: any more turns it into Toxic Shock, so its
	# kill time is a dose a second (a poison fog), Toxic Shock and all.
	# Toxic Shock itself (round 6) has no per-stack total: it never wears off
	# and doubles until cured, so it gets its own line below.
	var rows := [["burning", 4, 4], ["poisoned", 3, 1], ["bleeding", 5, 5], ["corroding", 3, 3], ["shocked", 3, 3], ["stuck_in_fire", 1, 1]]
	var kill := {}
	var per_stack := {}
	var all := func():
		for row in rows:
			var id: String = row[0]
			var t := _tmpl(id)
			var v := await _dummy("One " + id)
			var r := _simulate(v, [[0.0, _applier(v, id, 1)]], 0.0)
			await _clear()
			per_stack[id] = r["total"]
			var eff: Dictionary = t.triggered_effects[0]
			var per_s: float = float(eff["value"]) * float(row[1]) / float(eff["interval"])
			kill[id] = await _kill_time(id, row[2])
			print("%-18s %9d %9d %9.2f %13.1fs" % [id, r["total"], row[1], per_s, kill[id]])
		return true
	await _without_bleed_saves(all)
	_check("num.burning-5-per-stack", per_stack.get("burning", 0) == 5, per_stack)
	_check("num.poisoned-5-per-stack", per_stack.get("poisoned", 0) == 5, per_stack)
	kill["toxic_shock"] = await _kill_time("toxic_shock", 1, true)
	print("%-18s %9s %9s %9s %13.1fs" % ["toxic_shock", "1,2,4..", "32", "16.00", kill["toxic_shock"]])
	_check("num.toxic-shock-kills-30hp-in-8s", is_equal_approx(kill["toxic_shock"], 8.0), kill)
	_check("num.stuck-in-fire-4-a-catch", per_stack.get("stuck_in_fire", 0) == 4, per_stack)
	_check("num.burning-max-kills-30hp-in-7s", is_equal_approx(kill.get("burning", -1.0), 7.0), kill)
	_check("num.every-max-kill-takes-time", kill.values().all(func(x): return x >= 6.0), kill)

	print("--- per source (DoT after the hit itself; no armour; Bleeding without its CON saves) ---")
	print("%-40s %-22s %6s %6s %8s" % ["source", "applies", "total", "peak", "lasts"])
	var src_rows: Array = []
	var v: ProceduralCharacter
	for w in [["Match Striker (1 fire)", "fire", 1.0], ["Flaming Sword (5 fire)", "fire", 5.0],
			["Stiletto (2 poison)", "poison", 2.0], ["Poison Vial (18 poison)", "poison", 18.0]]:
		v = await _dummy("Rider")
		src_rows.append([w[0], _simulate(v, [[0.0, _hit(v, w[1], w[2])]], 0.0), v])
		await _clear()
	var cut := func():
		for w in [["Sword cut (15 slashing)", 15.0], ["Greatsword (30 slashing)", 30.0]]:
			var b := await _dummy("Rider")
			src_rows.append([w[0] + ", no CON save", _simulate(b, [[0.0, _hit(b, "slashing", w[1])]], 0.0), b])
			await _clear()
		return true
	await _without_bleed_saves(cut)
	v = await _dummy("Mark")
	var caster := await _dummy("Caster")
	var fb := _ability("fireball")
	src_rows.append(["Fireball (24 fire + 2 Burning)", _simulate(v, [[0.0, func(): caster.ability_manager._resolve_effects(fb, fb.effects, v.global_position, [v])]], 0.0), v])
	await _clear()
	var ck_raw = AbilityDatabase.get_ability_data("cloud_kill").get("effects", {})
	var ck: Dictionary = ck_raw if ck_raw is Dictionary else (ck_raw[0] if ck_raw is Array and not ck_raw.is_empty() else {})
	v = await _dummy("Cloud")
	src_rows.append(["Cloud Kill, the whole %d s" % int(ck.get("duration", 15.0)), _simulate(v, _every(float(ck.get("apply_interval", 2.0)), float(ck.get("duration", 15.0)), _applier(v, "poisoned", 1)), 0.0), v])
	await _clear()
	v = await _dummy("Walker")
	src_rows.append(["Burning ground, 3 s in it", _simulate(v, _every(1.0, 3.0, _applier(v, "burning", 1)), 0.0), v])
	await _clear()
	v = await _dummy("Spun")
	src_rows.append(["Fire Spin, the whole 6 s (rooted)", _simulate(v, _every(0.5, 6.0, _applier(v, "stuck_in_fire", 1), 0.0), 0.0), v])
	await _clear()
	var by_name := {}
	for row in src_rows:
		var r: Dictionary = row[1]
		by_name[row[0]] = r
		print("%-40s %-22s %6d %6d %7.1fs" % [row[0], " + ".join(PackedStringArray(r["seen"])), r["total"], r["peak"], float(r["lasted"])])
	_check("src.match-striker-5", by_name["Match Striker (1 fire)"]["total"] == 5, by_name["Match Striker (1 fire)"])
	_check("src.flaming-sword-5", by_name["Flaming Sword (5 fire)"]["total"] == 5, by_name["Flaming Sword (5 fire)"])
	# Round 6: Toxic Shock doubles until cured, so uncured it is lethal.
	_check("src.poison-vial-shock-lethal", by_name["Poison Vial (18 poison)"]["died"] and by_name["Poison Vial (18 poison)"]["seen"] == ["toxic_shock"], by_name["Poison Vial (18 poison)"])
	_check("src.cloud-kill-turns", (by_name["Cloud Kill, the whole 15 s"]["seen"] as Array).has("toxic_shock"), by_name["Cloud Kill, the whole 15 s"])
	_check("src.sword-cut-12", by_name["Sword cut (15 slashing), no CON save"]["total"] == 12, by_name["Sword cut (15 slashing), no CON save"])
	_check("src.greatsword-20", by_name["Greatsword (30 slashing), no CON save"]["total"] == 20, by_name["Greatsword (30 slashing), no CON save"])
	_check("src.fireball-10", by_name["Fireball (24 fire + 2 Burning)"]["total"] == 10, by_name["Fireball (24 fire + 2 Burning)"])
	_check("src.fire-spin-about-16", by_name["Fire Spin, the whole 6 s (rooted)"]["total"] == 16, by_name["Fire Spin, the whole 6 s (rooted)"])
	# Iciclet: no damage over time; one hit is Chilled x3 (round 6: Frozen at
	# 4), and the next cold freezes (Frozen 5 s).
	v = await _dummy("Iced")
	v.take_damage({"cold": 15}, v.global_position)
	var iced := _stacks(v, "chilled")
	v.take_damage({"cold": 1}, v.global_position)
	var frozen := _cm(v).get_condition("frozen")
	print("Iciclet (15 cold): Chilled x%d (Frozen in one hit in round 5); the next cold freezes for %.0f s" % [iced, frozen.get_remaining_duration(_now()) if frozen else -1.0])
	_check("src.iciclet-chills-3", iced == 3)
	_check("src.iciclet-then-cold-freezes", frozen != null and is_equal_approx(frozen.get_remaining_duration(_now()), 5.0))
	await _clear()
