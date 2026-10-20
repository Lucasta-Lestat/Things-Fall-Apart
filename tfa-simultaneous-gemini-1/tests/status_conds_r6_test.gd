extends Node2D
# Round 6, status conditions: the developer's answers to round 5's questions.
#   A. Toxic Shock, "something more like toxic in pokemon, where the tick of
#      poison damage starts doubling over time, quickly resulting in death":
#      no duration; 1 poison every 2 s that doubles each tick, at most 32 (the
#      triggered effect's "escalate", ConditionInstance.effect_value); the step
#      survives a save and a JSON round trip; a re-dose moves it on, never
#      back; Heal, a Potion of Healing and antidote/purify end it; armour
#      doesn't touch a tick; a party member is warned once when the next tick
#      would kill; the hover gives the tick, "doubling" and the cure. Onset
#      floats "Toxic Shock!", logs the transform and the cure for a party
#      member; unseen NPCs stay quiet. Tick table printed.
#   B. Chilled, "a max tier of four": caps and freezes at 4, so 15 cold is 3
#      stacks and 16 freezes; hits to freeze per source; Dexterity per stack;
#      the transform line; the Iciclet's text.
#   C. Toxic Shock icon: Gemini answered HTTP 402 (no credit), so it keeps
#      Poisoned's art. Checks it shows that art, and that the icon_fallback
#      lookup a generated cond_toxic_shock.png would use falls back to it.
# The condition clock (TimeManager.absolute_time) is driven by hand in exact
# 1/16 s steps, and each ConditionManager._process is called directly.
#   godot --headless --path . res://tests/status_conds_r6_test.tscn
# Judge by the PASS/FAIL lines and "HARNESS DONE failures=0".

const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const GAME_SCRIPT := preload("res://Game.gd")
const HOVER := preload("res://UI/WorldHoverInfo.gd")

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
## NPCs the party "sees" (is_seen_by_party), besides its own members.
var seen_npcs: Array = []

func can_hit_target(_a: Node2D, _t: Node2D) -> bool: return true
func register_hit(_a: Node2D, _t: Node2D) -> void: pass
func register_attack_start(_a: Node2D) -> void: pass
func register_attack_end(_a: Node2D) -> void: pass
func resolve_melee_swing(_a: Node2D, _hand: String) -> void: pass
func process_weapon_hit(_a, _t, _p, _w, _v) -> void: pass
func process_object_hit(_a, _t, _p, _w, _v) -> void: pass
func trigger_hearing_pulse(_source) -> void: pass
func is_seen_by_party(c) -> bool:
	return c in party_chars or c in seen_npcs

const ORIGIN := Vector2(1024, 1024)
## Exact in binary, so tick times land on whole intervals.
const STEP := 0.0625
const DUMMY_ICON := "res://Icons/dummy_icon.png"
const POISONED_ICON := "res://UI/UI Icons/poisoned.png"
const NEW_ICON := "res://UI/UI Icons/cond_toxic_shock.png"
const CURE := "Heal or a Potion of Healing"
## Heavy armour of every type, on the torso (ticks land there).
const HEAVY := {"fire": 5, "poison": 5, "cold": 5, "acid": 5, "electric": 5,
	"slashing": 5, "piercing": 5, "bludgeoning": 5, "true": 5}

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

	_case_toxic_data()
	await _case_escalation()
	await _case_hover()
	await _case_save_load()
	await _case_redose()
	await _case_cures()
	await _case_lethal_warning()
	await _case_onset_feedback()
	await _case_tick_table()
	await _case_chilled()
	await _case_icon()

	TimeManager.is_paused = _saved_paused
	TimeManager.game_time = _saved_game_time
	print("HARNESS DONE failures=%d checks=%d" % [failures, checks])
	get_tree().quit(1 if failures > 0 else 0)


# ---------------------------------------------------------------------------
# Helpers (as tests/dot_tune_r5_test.gd)
# ---------------------------------------------------------------------------

func _set_clock(t: float) -> void:
	_clock = t
	TimeManager.game_time = t - float(TimeManager.days_elapsed) * 86400.0


func _now() -> float:
	return TimeManager.absolute_time()


## A bare character (no gear, so no armour), its condition clock driven by
## hand. CON 50 is the 30-HP average; the default is all but unkillable.
func _dummy(char_name: String, party := false, con := 100000) -> ProceduralCharacter:
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
	c.constitution = con
	c.current_health = c.max_health
	_cm(c).set_process(false)
	_set_clock(_clock)
	return c


## A character built from a template (inventory and gear slots), for the
## Game save path.
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
	seen_npcs = []
	await get_tree().physics_frame


func _cm(c: ProceduralCharacter) -> ConditionManager:
	return c.get_node("ConditionManager")


func _tmpl(id: String) -> Condition:
	return ConditionManager.condition_registry.get(id)


func _db_entry(id: String) -> Dictionary:
	for d in ConditionDatabase.get_all_conditions():
		if d.get("id", "") == id:
			return d
	return {}


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


## Run until `n` more Toxic Shock ticks have landed on `c` (or it died).
func _ticks(c: ProceduralCharacter, n: int) -> void:
	var seen := [0]
	var on_tick := func(inst, _eff, res):
		if res.has("damage") and inst.condition.id == "toxic_shock":
			seen[0] += 1
	_cm(c).triggered_effect_fired.connect(on_tick)
	var guard := 0
	while seen[0] < n and c.is_alive() and guard < 4000:
		_set_clock(_clock + STEP)
		_cm(c)._process(STEP)
		guard += 1
	_cm(c).triggered_effect_fired.disconnect(on_tick)


func _ability(id: String) -> Ability:
	return Ability.from_dict(AbilityDatabase.get_ability_data(id))


## Log lines containing `fragment`, counting the repeats GameLog folds.
func _log_count(fragment: String) -> int:
	var n := 0
	for e in GameLog.get_entries():
		if String(e.get("text", "")).contains(fragment):
			n += int(e.get("count", 1))
	return n


func _log_tail(n := 4) -> Array:
	return GameLog.get_entries().slice(-n).map(func(e): return e.get("text", ""))


## Toxic Shock on `c`, the way play brings it: Poisoned's 4th stack.
func _shock(c: ProceduralCharacter, source: Node = null) -> ConditionInstance:
	_cm(c).apply_condition("poisoned", source, 4)
	return _cm(c).get_condition("toxic_shock")


func _next(c: ProceduralCharacter) -> int:
	var inst := _cm(c).get_condition("toxic_shock")
	return int(round(inst.effect_value(0))) if inst else -1


# ---------------------------------------------------------------------------
# A. Toxic Shock: the data
# ---------------------------------------------------------------------------

func _case_toxic_data() -> void:
	var ts := _tmpl("toxic_shock")
	_check("data.registered", ts != null)
	if ts == null:
		return
	_check("data.poisoned-turns-at-4", _tmpl("poisoned").transforms_into == {"id": "toxic_shock", "required_tier": 4}, _tmpl("poisoned").transforms_into)
	_check("data.no-duration", ts.duration < 0.0, ts.duration)
	_check("data.no-slow", ts.stat_modifiers.is_empty(), ts.stat_modifiers)
	var eff: Dictionary = ts.triggered_effects[0]
	_check("data.first-tick-1-poison-every-2s", int(eff["value"]) == 1 and str(eff["damage_type"]) == "poison" and is_equal_approx(float(eff["interval"]), 2.0), eff)
	var esc: Dictionary = eff.get("escalate", {})
	_check("data.doubles", is_equal_approx(float(esc.get("multiplier", 0.0)), 2.0), esc)
	_check("data.capped-32", int(esc.get("max_value", 0)) == 32, esc)
	_check("data.redose-one-step", int(esc.get("redose_steps", 0)) == 1, esc)
	_check("data.cure-hint", ts.cure_hint == CURE, ts.cure_hint)
	_check("data.poison-trait-heal-cures", ts.traits.has("poison") and ts.traits.has("debuff"), ts.traits)
	_check("data.canceled-by-antidote-purify", ts.canceled_by_trait.has("antidote") and ts.canceled_by_trait.has("purify"), ts.canceled_by_trait)
	var d := ts.description
	_check("text.lethal-unless-cured", d.contains("kills unless cured"), d)
	_check("text.names-cures", d.contains("Heal") and d.contains("Potion of Healing"), d)
	_check("text.doubling-numbers", d.contains("1 poison damage every 2 s") and d.contains("1, 2, 4, 8, 16, then 32"), d)
	_check("text.armour", d.contains("Armour doesn't reduce it"), d)
	_check("text.never-wears-off", d.contains("never wears off"), d)
	_check("text.no-slow-claim", not d.contains("slower"), d)
	# Poisoned's own hover warns what its 4th stack means.
	var pd := _tmpl("poisoned").description
	_check("text.poisoned-warns-lethal", pd.contains("At 4 stacks it turns into Toxic Shock, which kills unless cured."), pd)


# ---------------------------------------------------------------------------
# A. The escalation and its cap, through armour
# ---------------------------------------------------------------------------

func _case_escalation() -> void:
	var p := await _dummy("Ada", true)
	var bare := await _dummy("Bea", true)
	_armour(p, HEAVY)
	var dealt: Array = []
	var lost: Array = []
	var hp_prev := [p.current_health]
	var on_tick := func(inst, _eff, res):
		if res.has("damage") and inst.condition.id == "toxic_shock":
			dealt.append(int(res["damage"]))
			lost.append(hp_prev[0] - p.current_health)
			hp_prev[0] = p.current_health
	_cm(p).triggered_effect_fired.connect(on_tick)
	var inst := _shock(p)
	_check("esc.onset", inst != null and not _cm(p).has_condition("poisoned"))
	_check("esc.permanent", inst != null and inst.expires_at < 0.0, inst.expires_at if inst else "none")
	_check("esc.starts-at-step-0", inst != null and inst.escalation_steps(0) == 0 and _next(p) == 1)
	_run(p, 16.0)
	_cm(p).triggered_effect_fired.disconnect(on_tick)
	_check("esc.sequence-1-2-4-8-16-then-32", dealt == [1, 2, 4, 8, 16, 32, 32, 32], dealt)
	_check("esc.every-2s", dealt.size() == 8, dealt.size())
	_check("esc.armour-ignored-each-tick", lost == dealt, [lost, dealt])
	_check("esc.still-on-after-16s", _cm(p).has_condition("toxic_shock"))
	_check("esc.step-stops-at-cap", inst.escalation_steps(0) == 5 and inst.escalation_at_peak(0), inst.escalation_steps(0))
	# The same ticks land on a bare bearer: armour plays no part.
	var dealt_bare: Array = []
	var hp0 := bare.current_health
	var on_bare := func(i2, _eff, res):
		if res.has("damage") and i2.condition.id == "toxic_shock":
			dealt_bare.append(int(res["damage"]))
	_cm(bare).triggered_effect_fired.connect(on_bare)
	_shock(bare)
	_run(bare, 16.0)
	_cm(bare).triggered_effect_fired.disconnect(on_bare)
	_check("esc.bare-same-ticks", dealt_bare == dealt and hp0 - bare.current_health == 127, [dealt_bare, hp0 - bare.current_health])
	# A bearer Deny Ending holds at 1 HP: a minute of ticks stays at 32 a tick.
	var held := await _dummy("Cid", true, 50)
	_cm(held).apply_condition("deny_ending", null, 1, -1.0)
	var big: Array = []
	var on_held := func(i3, _eff, res):
		if res.has("damage") and i3.condition.id == "toxic_shock":
			big.append(int(res["damage"]))
	_cm(held).triggered_effect_fired.connect(on_held)
	var hi := _shock(held)
	_run(held, 59.0)
	_cm(held).triggered_effect_fired.disconnect(on_held)
	_check("cap.held-alive-at-1", held.is_alive() and held.current_health == 1, held.current_health)
	_check("cap.never-over-32", big.size() == 30 and big.max() == 32 and big.slice(5).all(func(x): return x == 32), big)
	_check("cap.steps-stay-small", hi.escalation_steps(0) == 5, hi.escalation_steps(0))
	_check("cap.no-lethal-warning-under-deny-ending", _log_count("Cid will die from Toxic Shock") == 0, _log_tail())
	# Deny Ending ends: now the next tick kills, and the warning comes at once.
	_cm(held).remove_condition("deny_ending")
	_run(held, STEP)
	_check("cap.warns-once-deny-ending-ends", _log_count("Cid will die from Toxic Shock unless cured (next tick 32 poison, 1 HP left).") == 1, _log_tail())
	await _clear()


# ---------------------------------------------------------------------------
# A. Hover: what the summary, the tooltip and the world hover say
# ---------------------------------------------------------------------------

func _case_hover() -> void:
	var p := await _dummy("Ada", true)
	var inst := _shock(p)
	var now := _now()
	_check("hover.onset", inst.get_summary(now) == "Toxic Shock: 1 poison every 2 s, doubling (cure: %s)" % CURE, inst.get_summary(now))
	_ticks(p, 3)
	now = _now()
	_check("hover.after-3-ticks-8", inst.get_summary(now) == "Toxic Shock: 8 poison every 2 s, doubling (cure: %s)" % CURE, inst.get_summary(now))
	_check("hover.no-time-left", not inst.get_summary(now).contains("left"), inst.get_summary(now))
	var tip := inst.get_tooltip_text(now)
	_check("hover.tooltip-has-description", tip.begins_with(inst.get_summary(now)) and tip.contains("kills unless cured") and tip.contains("Potion of Healing"), tip)
	var hover = HOVER.new()
	var lines: PackedStringArray = hover.condition_lines(p)
	var found := false
	for l in lines:
		if l.contains("Toxic Shock: 8 poison every 2 s, doubling (cure: %s)" % CURE):
			found = true
	_check("hover.world-line", found, lines)
	var described: String = hover.describe_condition(inst, p)
	_check("hover.icon-explained", described.contains("Toxic Shock: 8 poison every 2 s, doubling") and described.contains("kills unless cured"), described)
	hover.free()
	_ticks(p, 3)
	now = _now()
	_check("hover.at-peak", inst.get_summary(now) == "Toxic Shock: 32 poison every 2 s, at its peak (cure: %s)" % CURE, inst.get_summary(now))
	await _clear()


# ---------------------------------------------------------------------------
# A. Save and load keep the step
# ---------------------------------------------------------------------------

func _case_save_load() -> void:
	var p := await _dummy("Ada", true)
	var cm := _cm(p)
	_shock(p)
	_ticks(p, 3)
	_check("save.setup-next-8", _next(p) == 8, _next(p))
	# Half a second after the 3rd tick: the 4th is due 1.5 s after a load.
	_run(p, 0.5)
	var snap: Dictionary = cm.to_dict()
	var parsed = JSON.parse_string(JSON.stringify(snap))
	var saved_at := _clock
	_ticks(p, 2)
	_check("save.live-moved-on", _next(p) == 32, _next(p))
	_check("save.snapshot-not-shared", int(snap["conditions"]["toxic_shock"]["custom_data"].get("escalate_steps_0", -1)) == 3,
		snap["conditions"]["toxic_shock"]["custom_data"])
	# JSON brings numbers back as floats: still step 3.
	cm.from_dict(parsed)
	var back := cm.get_condition("toxic_shock")
	_check("save.json-loads", back != null)
	_check("save.json-keeps-step", back != null and back.escalation_steps(0) == 3 and _next(p) == 8, back.custom_data if back else "none")
	_check("save.json-summary", back != null and back.get_summary(_now()).begins_with("Toxic Shock: 8 poison every 2 s, doubling"), back.get_summary(_now()) if back else "none")
	_check("save.json-still-permanent", back != null and back.expires_at < 0.0)
	var got: Array = []
	var got_at: Array = []
	var on_tick := func(inst, _eff, res):
		if res.has("damage") and inst.condition.id == "toxic_shock":
			got.append(int(res["damage"]))
			got_at.append(_clock)
	cm.triggered_effect_fired.connect(on_tick)
	# Back on the clock the save was taken at: the next tick keeps its time
	# (JSON's string keys used to make every tick fire at once on load).
	_set_clock(saved_at)
	_ticks(p, 2)
	cm.triggered_effect_fired.disconnect(on_tick)
	_check("save.next-ticks-8-16-not-1", got == [8, 16], got)
	_check("save.json-keeps-tick-time", got_at.size() == 2 and is_equal_approx(got_at[0] - saved_at, 1.5) and is_equal_approx(got_at[1] - got_at[0], 2.0),
		got_at.map(func(t): return t - saved_at))
	# The in-memory snapshot too (Game's map transitions).
	cm.from_dict(snap)
	_check("save.memory-keeps-step", _next(p) == 8, _next(p))
	# Through Game's character serializer.
	var game = GAME_SCRIPT.new()
	var a := await _built("Saver")
	_shock(a)
	_ticks(a, 2)
	var state: Dictionary = game._serialize_character(a)
	var b := await _built("Loader")
	game._deserialize_character(b, state)
	var bt := _cm(b).get_condition("toxic_shock")
	_check("save.game-path-keeps-step", bt != null and bt.escalation_steps(0) == 2 and int(round(bt.effect_value(0))) == 4,
		bt.custom_data if bt else "none")
	game.free()
	# The once-only warning is remembered too.
	var w := await _dummy("Wren", true)
	_cm(w).apply_condition("toxic_shock")
	_cm(w).get_condition("toxic_shock").custom_data[ConditionManager.LETHAL_WARNED_KEY] = true
	var ws = JSON.parse_string(JSON.stringify(_cm(w).to_dict()))
	_cm(w).from_dict(ws)
	_check("save.warned-flag-kept", bool(_cm(w).get_condition("toxic_shock").custom_data.get(ConditionManager.LETHAL_WARNED_KEY, false)))
	await _clear()


# ---------------------------------------------------------------------------
# A. A re-dose moves it on, never back
# ---------------------------------------------------------------------------

func _case_redose() -> void:
	var p := await _dummy("Ada", true)
	var foe := await _dummy("Foe")
	var cm := _cm(p)
	var inst := _shock(p, foe)
	_ticks(p, 3)
	_check("redose.setup-next-8", _next(p) == 8, _next(p))
	var onset0 := _log_count("Ada's Poisoned reaches 4 stacks: Toxic Shock.")
	var hint0 := _log_count("Cure Ada's Toxic Shock")
	cm.apply_condition("poisoned", foe, 2)
	_check("redose.poison-builds-beside", _stacks(p, "poisoned") == 2 and cm.get_condition("toxic_shock") == inst)
	p._last_notify_text = ""
	var line := "Ada's Poisoned reaches 4 stacks: Toxic Shock worsens (16 poison every 2 s, doubling)."
	var w0 := _log_count(line)
	cm.apply_condition("poisoned", foe, 2)
	_check("redose.same-instance", cm.get_condition("toxic_shock") == inst and not cm.has_condition("poisoned"))
	_check("redose.one-step-on", inst.escalation_steps(0) == 4 and _next(p) == 16, inst.escalation_steps(0))
	_check("redose.still-permanent", inst.expires_at < 0.0)
	_check("redose.floats-worsens", p._last_notify_text == "Toxic Shock worsens", p._last_notify_text)
	_check("redose.logs-worsens", _log_count(line) == w0 + 1, _log_tail())
	_check("redose.not-a-new-onset", _log_count("Ada's Poisoned reaches 4 stacks: Toxic Shock.") == onset0 and _log_count("Cure Ada's Toxic Shock") == hint0, _log_tail())
	# A Poison Vial on someone already in Toxic Shock: the same, one step.
	p.take_damage({"poison": 18}, p.global_position, foe)
	_check("redose.vial-steps-on", _next(p) == 32 and inst.escalation_at_peak(0), _next(p))
	# At its peak a re-dose changes nothing, and never lowers it.
	cm.apply_condition("toxic_shock", foe)
	_check("redose.at-peak-stays-32", _next(p) == 32 and inst.escalation_steps(0) == 5, [_next(p), inst.escalation_steps(0)])
	# Poisoned reaching 4 at the peak (or with redose_steps 0) changes
	# nothing, and the notice says so rather than reading as a new onset.
	p._last_notify_text = ""
	var on0 := _log_count("Ada's Poisoned reaches 4 stacks: Toxic Shock.")
	var peak_line := "Ada's Poisoned reaches 4 stacks; Toxic Shock is already on (32 poison every 2 s, at its peak)."
	var k0 := _log_count(peak_line)
	cm.apply_condition("poisoned", foe, 4)
	_check("redose.at-peak-same-instance", cm.get_condition("toxic_shock") == inst and _next(p) == 32 and not cm.has_condition("poisoned"))
	_check("redose.at-peak-floats-already-on", p._last_notify_text == "Toxic Shock (already on)", p._last_notify_text)
	_check("redose.at-peak-logged", _log_count(peak_line) == k0 + 1 and _log_count("Ada's Poisoned reaches 4 stacks: Toxic Shock.") == on0, _log_tail())
	# Any order of ticks and doses: the next tick never gets smaller.
	cm.clear_all_conditions()
	seed(6)
	_shock(p, foe)
	var last := _next(p)
	var monotonic := true
	var seq: Array = [last]
	for _k in range(40):
		match randi() % 3:
			0: _ticks(p, 1)
			1: cm.apply_condition("poisoned", foe, randi_range(1, 4))
			2: cm.apply_condition("toxic_shock", foe)
		var v := _next(p)
		seq.append(v)
		if v < last:
			monotonic = false
		last = v
	_check("redose.never-lower", monotonic and last == 32, seq)
	await _clear()


# ---------------------------------------------------------------------------
# A. Cures
# ---------------------------------------------------------------------------

func _case_cures() -> void:
	var p := await _dummy("Ada", true)
	var foe := await _dummy("Foe")
	var cm := _cm(p)
	# Heal (the spell): ends Toxic Shock and any Poisoned beside it.
	_shock(p, foe)
	_ticks(p, 3)
	cm.apply_condition("poisoned", foe, 1)
	var h0 := _log_count("Heal ends ")
	foe.ability_manager._resolve_effects(_ability("heal"), _ability("heal").effects, p.global_position, [p])
	_check("cure.heal", not cm.has_condition("toxic_shock") and not cm.has_condition("poisoned"))
	_check("cure.heal-logged", _log_count("Heal ends ") == h0 + 1 and _log_tail(2).any(func(t): return String(t).contains("Toxic Shock")), _log_tail())
	# A Potion of Healing (drunk): its Heal's poison cure lands with it.
	_shock(p, foe)
	_ticks(p, 4)
	var potion: Dictionary = ItemDatabase.get_item_data("potion_of_healing")
	var line := "Potion of Healing ends Toxic Shock on Ada."
	var p0 := _log_count(line)
	_check("cure.potion-used", ActionQueue.apply_consumable(p, p, potion))
	_check("cure.potion", not cm.has_condition("toxic_shock"))
	_check("cure.potion-logged", _log_count(line) == p0 + 1, _log_tail())
	# antidote / purify (canceled_by_trait; nothing carries them yet).
	_shock(p, foe)
	cm.cancel_by_trait("antidote", "Test Antidote", foe)
	_check("cure.antidote-trait", not cm.has_condition("toxic_shock"))
	_shock(p, foe)
	cm.cancel_by_trait("purify", "Test Purify", foe)
	_check("cure.purify-trait", not cm.has_condition("toxic_shock"))
	# Cured and poisoned again: a new Toxic Shock starts over at 1.
	_shock(p, foe)
	_check("cure.fresh-shock-starts-at-1", _next(p) == 1, _next(p))
	# A corpse doesn't tick on.
	var d := await _dummy("Dee", true, 50)
	_shock(d)
	_ticks(d, 10)
	var steps_at_death: int = _cm(d).get_condition("toxic_shock").escalation_steps(0)
	_run(d, 10.0)
	_check("cure.death-ends-ticks", not d.is_alive() and _cm(d).get_condition("toxic_shock").escalation_steps(0) == steps_at_death)
	await _clear()


# ---------------------------------------------------------------------------
# A. One warning when the next tick would kill a party member
# ---------------------------------------------------------------------------

func _case_lethal_warning() -> void:
	# From full, 30 HP: 1, 2, 4, 8 leave 15, and the 5th tick is 16.
	var p := await _dummy("Ada", true, 50)
	_check("warn.setup-30hp", p.max_health == 30, p.max_health)
	var line := "Ada will die from Toxic Shock unless cured (next tick 16 poison, 15 HP left). Cure: %s." % CURE
	var w0 := _log_count("Ada will die from Toxic Shock")
	_shock(p)
	_ticks(p, 3)
	_check("warn.not-yet-at-23hp", _log_count("Ada will die from Toxic Shock") == w0 and p.current_health == 23, [p.current_health, _log_tail()])
	_ticks(p, 1)
	_run(p, STEP)
	_check("warn.after-4th-tick", _log_count(line) == 1 and p.current_health == 15, [p.current_health, _log_tail()])
	_check("warn.floats", p._last_notify_text == "Toxic Shock: cure now!", p._last_notify_text)
	_ticks(p, 1)
	_check("warn.5th-tick-kills", not p.is_alive())
	_check("warn.once", _log_count("Ada will die from Toxic Shock") == w0 + 1, _log_tail())
	# A hit between ticks brings it within reach: warned before the tick.
	var b := await _dummy("Bea", true, 50)
	_shock(b)
	_ticks(b, 1)
	b.take_damage({"bludgeoning": 27}, b.global_position)
	_check("warn.setup-2hp-next-2", b.current_health == 2 and _next(b) == 2, [b.current_health, _next(b)])
	_run(b, STEP)
	_check("warn.between-ticks", _log_count("Bea will die from Toxic Shock unless cured (next tick 2 poison, 2 HP left).") == 1 and b.is_alive(), _log_tail())
	_run(b, 1.0)
	_check("warn.between-ticks-once", _log_count("Bea will die from Toxic Shock") == 1, _log_tail())
	# NPCs, seen or not, get none.
	var npc := await _dummy("Mark", false, 50)
	seen_npcs.append(npc)
	_shock(npc)
	_ticks(npc, 6)
	_check("warn.npc-dies", not npc.is_alive())
	_check("warn.none-for-npc", _log_count("Mark will die from") == 0, _log_tail())
	await _clear()


# ---------------------------------------------------------------------------
# A. Onset feedback
# ---------------------------------------------------------------------------

func _case_onset_feedback() -> void:
	var p := await _dummy("Ada", true)
	var foe := await _dummy("Foe")
	var cm := _cm(p)
	cm.apply_condition("poisoned", foe, 3)
	p._last_notify_text = ""
	var t0 := _log_count("Ada's Poisoned reaches 4 stacks: Toxic Shock.")
	var hint := "Cure Ada's Toxic Shock with %s; until then it deals 1 poison every 2 s, doubling." % CURE
	var c0 := _log_count(hint)
	cm.apply_condition("poisoned", foe, 1)
	_check("onset.floats", p._last_notify_text == "Toxic Shock!", p._last_notify_text)
	_check("onset.transform-line", _log_count("Ada's Poisoned reaches 4 stacks: Toxic Shock.") == t0 + 1, _log_tail())
	_check("onset.cure-hint", _log_count(hint) == c0 + 1, _log_tail())
	cm.clear_all_conditions()
	# A Poison Vial (18 poison): straight to Toxic Shock, same lines.
	var v0 := _log_count(hint)
	p.take_damage({"poison": 18}, p.global_position, foe)
	_check("onset.vial-straight-to-shock", cm.has_condition("toxic_shock") and not cm.has_condition("poisoned"))
	_check("onset.vial-cure-hint", _log_count(hint) == v0 + 1, _log_tail())
	# An NPC the party sees, poisoned by a party member: float and log, no
	# cure hint (the party isn't the one to cure it) and no warning.
	var npc := await _dummy("Mark", false, 50)
	seen_npcs.append(npc)
	npc._last_notify_text = ""
	var m0 := _log_count("Mark's Poisoned reaches 4 stacks: Toxic Shock.")
	_cm(npc).apply_condition("poisoned", p, 4)
	_check("onset.seen-npc-floats", npc._last_notify_text == "Toxic Shock!", npc._last_notify_text)
	_check("onset.seen-npc-logged", _log_count("Mark's Poisoned reaches 4 stacks: Toxic Shock.") == m0 + 1, _log_tail())
	_check("onset.no-cure-hint-for-npc", _log_count("Cure Mark's") == 0, _log_tail())
	# An NPC the party doesn't see turns quietly.
	var hidden := await _dummy("Hidden", false)
	hidden._last_notify_text = ""
	var quiet0 := GameLog.get_entries().size()
	_cm(hidden).apply_condition("poisoned", foe, 4)
	_ticks(hidden, 6)
	_check("onset.unseen-npc-quiet", _cm(hidden).has_condition("toxic_shock") and hidden._last_notify_text == "" and GameLog.get_entries().size() == quiet0,
		[hidden._last_notify_text, GameLog.get_entries().slice(quiet0)])
	await _clear()


# ---------------------------------------------------------------------------
# A. Tick table and kill times (printed)
# ---------------------------------------------------------------------------

## {died_at (s after onset, -1 if alive after 60 s), ticks} for a bearer with
## `hp` HP struck with Toxic Shock after taking `hit` damage first.
func _kill(con: int, hit := 0) -> Dictionary:
	var v := await _dummy("Victim", true, con)
	if hit > 0:
		v.current_health -= hit
	var n := [0]
	var on_tick := func(inst, _eff, res):
		if res.has("damage") and inst.condition.id == "toxic_shock":
			n[0] += 1
	_cm(v).triggered_effect_fired.connect(on_tick)
	_shock(v)
	var start := _clock
	var died := -1.0
	for i in range(0, int(60.0 / STEP)):
		_set_clock(start + i * STEP)
		_cm(v)._process(STEP)
		if not v.is_alive():
			died = i * STEP
			break
	var out := {"died_at": died, "ticks": n[0], "hp": v.max_health}
	await _clear()
	return out


func _case_tick_table() -> void:
	print("--- Toxic Shock ticks (1 poison every 2 s, doubling, at most 32) ---")
	print("%-6s %-6s %-6s %-6s" % ["tick", "at", "deals", "total"])
	var total := 0
	for k in range(9):
		var v: int = mini(32, int(pow(2.0, k)))
		total += v
		print("%-6d %-6s %-6d %-6d" % [k + 1, "%ds" % (2 * k), v, total])
	var t30 := await _kill(50)
	var t50 := await _kill(150)
	var t100 := await _kill(400)
	var vial := await _kill(50, 18)
	print("30 HP from full: dies on tick %d, %.0f s in" % [t30["ticks"], t30["died_at"]])
	print("50 HP from full: dies on tick %d, %.0f s in" % [t50["ticks"], t50["died_at"]])
	print("100 HP from full: dies on tick %d, %.0f s in" % [t100["ticks"], t100["died_at"]])
	print("30 HP after a Poison Vial's 18: dies on tick %d, %.0f s in" % [vial["ticks"], vial["died_at"]])
	_check("table.30hp-tick-5-at-8s", t30["hp"] == 30 and t30["ticks"] == 5 and is_equal_approx(t30["died_at"], 8.0), t30)
	_check("table.50hp-tick-6-at-10s", t50["hp"] == 50 and t50["ticks"] == 6 and is_equal_approx(t50["died_at"], 10.0), t50)
	_check("table.100hp-tick-8-at-14s", t100["hp"] == 100 and t100["ticks"] == 8 and is_equal_approx(t100["died_at"], 14.0), t100)
	_check("table.vial-victim-tick-4-at-6s", vial["ticks"] == 4 and is_equal_approx(vial["died_at"], 6.0), vial)


# ---------------------------------------------------------------------------
# B. Chilled caps and freezes at 4
# ---------------------------------------------------------------------------

func _case_chilled() -> void:
	var ch := _tmpl("chilled")
	_check("chill.max-4", ch.max_tier == 4, ch.max_tier)
	_check("chill.freezes-at-4", ch.transforms_into == {"id": "frozen", "required_tier": 4}, ch.transforms_into)
	_check("chill.k-still-5", is_equal_approx(ch.damage_per_stack, 5.0), ch.damage_per_stack)
	var cases := {1: 1, 3: 1, 4: 1, 5: 1, 6: 2, 10: 2, 11: 3, 15: 3, 16: 4, 40: 4}
	for dealt in cases:
		_check("chill.k-%d->%d" % [dealt, cases[dealt]], ch.stacks_for_damage(float(dealt)) == cases[dealt], ch.stacks_for_damage(float(dealt)))
	_check("chill.text-4", ch.description.contains("At 4 stacks, you freeze.") and not ch.description.contains("At 3 stacks"), ch.description)
	_check("chill.text-dex", ch.description.contains("x3 61%"), ch.description)

	var p := await _dummy("Ada", true)
	var foe := await _dummy("Foe")
	var cm := _cm(p)
	# Iciclet, 15 cold: Chilled x3, not frozen; any more cold freezes.
	p.take_damage({"cold": 15}, p.global_position, foe)
	_check("chill.iciclet-15-is-x3", _stacks(p, "chilled") == 3 and not cm.has_condition("frozen"), _stacks(p, "chilled"))
	var f0 := _log_count("Ada's Chilled reaches 4 stacks: Frozen.")
	p._last_notify_text = ""
	p.take_damage({"cold": 3}, p.global_position, foe)
	_check("chill.next-cold-freezes", cm.has_condition("frozen") and not cm.has_condition("chilled"))
	_check("chill.frozen-float", p._last_notify_text == "Frozen!", p._last_notify_text)
	_check("chill.frozen-line-4", _log_count("Ada's Chilled reaches 4 stacks: Frozen.") == f0 + 1, _log_tail())
	cm.clear_all_conditions()
	# 16 cold freezes in one hit.
	p.take_damage({"cold": 16}, p.global_position, foe)
	_check("chill.16-freezes-in-one", cm.has_condition("frozen") and not cm.has_condition("chilled"))
	cm.clear_all_conditions()
	# Hits to freeze, one source at a time.
	print("--- Cold hits to freeze (Chilled freezes at 4 now, 3 before) ---")
	var hits_of := func(cold: float) -> int:
		var n := 0
		while not cm.has_condition("frozen") and n < 10:
			p.take_damage({"cold": cold}, p.global_position, foe)
			n += 1
		cm.clear_all_conditions()
		return n
	var want := [["Winter's Grip (3 cold)", 3.0, 4, 3], ["Frost Axe (4 cold)", 4.0, 4, 3], ["Frost Axe at STR 100 (6 cold)", 6.0, 2, 2],
		["Iciclet (15 cold)", 15.0, 2, 1], ["Iciclet at STR 57+ (16 cold)", 16.0, 1, 1]]
	for w in want:
		var n: int = hits_of.call(w[1])
		print("%-32s %d -> %d hits" % [w[0], w[3], n])
		_check("chill.hits-%s" % String(w[0]).to_lower().replace(" ", "-"), n == w[2], n)
	# Thrown, the Iciclet scales with STR (0.5 + STR/100): 16 at STR 57.
	var thrower := await _dummy("Thrower", true)
	thrower.strength = 56
	_check("chill.iciclet-str56-deals-15", int(15.0 * thrower.damage_multiplier) == 15, 15.0 * thrower.damage_multiplier)
	thrower.strength = 57
	_check("chill.iciclet-str57-deals-16", int(15.0 * thrower.damage_multiplier) == 16, 15.0 * thrower.damage_multiplier)
	# Ice Storm puts 2 on (when its 80% lands): two freeze, one doesn't.
	var storm_stacks := 0
	for e in _ability("ice_storm").effects:
		if e is Dictionary and e.get("condition_id", "") == "chilled":
			storm_stacks = int(e.get("stacks", 0))
	_check("chill.ice-storm-2", storm_stacks == 2, storm_stacks)
	cm.apply_condition("chilled", foe, storm_stacks)
	_check("chill.one-ice-storm-x2", _stacks(p, "chilled") == 2 and not cm.has_condition("frozen"))
	cm.apply_condition("chilled", foe, storm_stacks)
	_check("chill.two-ice-storms-freeze", cm.has_condition("frozen"))
	cm.clear_all_conditions()
	# Freezing Rain holds at 2 (its cap) and never freezes alone; with it, a
	# small cold hit is x3, not Frozen as before, and a second freezes.
	for _i in range(15):
		var ex = cm.get_condition("chilled")
		if ex == null or ex.stacks < 2:
			cm.apply_condition("chilled", null, 1)
	_check("chill.rain-alone-x2", _stacks(p, "chilled") == 2 and not cm.has_condition("frozen"))
	p.take_damage({"cold": 3}, p.global_position, foe)
	_check("chill.rain-plus-one-cold-x3", _stacks(p, "chilled") == 3 and not cm.has_condition("frozen"))
	p.take_damage({"cold": 3}, p.global_position, foe)
	_check("chill.rain-plus-two-colds-freeze", cm.has_condition("frozen"))
	cm.clear_all_conditions()
	# Dexterity x0.85 per stack, compounding: x3 is the most it holds.
	var dex0: float = p.effective_dexterity()
	var dex_by: Array = []
	for _s in [1, 2, 3]:
		cm.apply_condition("chilled", null, 1)
		dex_by.append(p.effective_dexterity() / dex0)
	print("Chilled Dexterity: x1 %.3f, x2 %.3f, x3 %.3f of normal; x4 is Frozen (0)" % dex_by)
	_check("chill.dex-per-stack", absf(dex_by[0] - 0.85) < 0.005 and absf(dex_by[1] - 0.7225) < 0.005 and absf(dex_by[2] - 0.614) < 0.005, dex_by)
	cm.apply_condition("chilled", null, 1)
	_check("chill.x4-is-frozen-dex-0", cm.has_condition("frozen") and not cm.has_condition("chilled") and p.effective_dexterity() == 0.0, p.effective_dexterity())
	cm.clear_all_conditions()
	# An old save holding Chilled x3 loads as x3 (under the new cap) and the
	# next cold freezes.
	cm.from_dict({"conditions": {"chilled": {"condition_id": "chilled", "stacks": 3.0, "expires_at": _now() + 8.0}}})
	_check("chill.old-save-x3-stays", _stacks(p, "chilled") == 3 and not cm.has_condition("frozen"))
	p.take_damage({"cold": 1}, p.global_position, foe)
	_check("chill.old-save-next-cold-freezes", cm.has_condition("frozen"))
	cm.clear_all_conditions()
	# The Iciclet no longer says it freezes whatever it hits.
	var ice: Dictionary = ItemDatabase.get_item_data("iciclet")
	var idesc := str(ice.get("description", ""))
	_check("chill.iciclet-text", idesc.contains("chills") and not idesc.contains("freezes whatever it shatters against"), idesc)
	await _clear()


# ---------------------------------------------------------------------------
# C. Toxic Shock icon
# ---------------------------------------------------------------------------

func _case_icon() -> void:
	var ts := _tmpl("toxic_shock")
	var d := _db_entry("toxic_shock")
	var path: String = ts.icon.resource_path if ts and ts.icon else "null"
	if FileAccess.file_exists(NEW_ICON):
		print("NOTE cond_toxic_shock.png is in the project now; point toxic_shock's icon at it (icon_fallback: poisoned.png)")
	_check("icon.data", str(d.get("icon", "")) in [POISONED_ICON, NEW_ICON], d.get("icon", ""))
	if str(d.get("icon", "")) == NEW_ICON:
		_check("icon.data-fallback", str(d.get("icon_fallback", "")) == POISONED_ICON, d.get("icon_fallback", ""))
	var want := NEW_ICON if str(d.get("icon", "")) == NEW_ICON and ResourceLoader.exists(NEW_ICON) else POISONED_ICON
	_check("icon.registered", path == want, "%s (want %s)" % [path, want])
	_check("icon.not-placeholder", path != DUMMY_ICON, path)
	# The lookup a generated icon would go through: until the PNG is in the
	# project and imported, the fallback shows, never the placeholder.
	var future := d.duplicate(true)
	future["icon"] = "res://UI/UI Icons/_r6_never_there_toxic_shock.png"
	future["icon_fallback"] = POISONED_ICON
	var c := Condition.create_from_data(future)
	_check("icon.fallback-while-missing", c.icon != null and c.icon.resource_path == POISONED_ICON, c.icon.resource_path if c.icon else "null")
	# What the player sees: the overhead row and the hover line.
	var p := await _dummy("Ada", true)
	var inst := _shock(p)
	await get_tree().process_frame
	var row_tex: Texture2D = null
	var display = p.get_node_or_null("ConditionDisplay")
	if display:
		for chd in display.get_children():
			if chd is TextureRect and not chd.is_queued_for_deletion() and chd.get_meta("cond_id", "") == "toxic_shock":
				row_tex = chd.texture
	_check("icon.row", row_tex != null and row_tex.resource_path == want, row_tex.resource_path if row_tex else "no icon in the row")
	var bb: String = HOVER._icon_bb(inst)
	_check("icon.hover", bb.contains(want) and not bb.contains(DUMMY_ICON), bb)
	await _clear()
