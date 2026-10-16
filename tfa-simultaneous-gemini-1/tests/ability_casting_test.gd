# res://tests/ability_casting_test.gd
# Headless assertion harness for the casting rules: the incapacitation gate and
# free item casts, interruptible windups (F5), the projectile AoE preview,
# ability range (F6) and Concentration (F7). Drives the real game scene the
# way feedback_layer_test does; party members are the ones whose notices and
# log lines always reach the player.
# Run:  godot --headless --path . res://tests/ability_casting_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

const PC_SCENE_PATH := "res://Characters/ProceduralCharacter.tscn"

var failures := 0
var game = null
var log_lines: Array = []
var spawned: Array = []

func _check(check_name: String, cond: bool, detail = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, str(detail)])

func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

func _physics(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame

func _ready() -> void:
	TimeManager.pause_time()
	await get_tree().process_frame
	var GameScene := load("res://game.tscn")
	game = GameScene.instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _frames(2)
	game.load_map("town_square")
	await _frames(10)
	GameLog.entry_added.connect(func(text, _ts): log_lines.append(String(text)))
	# Party members stay put and don't act on their own.
	for p in game.party_chars:
		p.AI_enabled = false

	await _gate_cases()
	await _f5_cases()
	await _impact_cases()

	for c in spawned:
		if is_instance_valid(c):
			c.queue_free()
	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## A bare NPC with no AI that pays nothing for its spells.
func _spawn(char_name: String, pos: Vector2) -> Node:
	var ch = load(PC_SCENE_PATH).instantiate()
	ch.AI_enabled = false
	ch.is_player_controlled = false
	ch.Name = char_name
	game.add_child(ch)
	ch.global_position = pos
	ch.npc_unlimited_resources = true
	spawned.append(ch)
	return ch

func _despawn(ch) -> void:
	if is_instance_valid(ch):
		ch.queue_free()

func _party(i: int = 0):
	return game.party_chars[i]

## A bare test ability: no effects, the given windup.
func _windup_ability(cast_time: float, interruptible: bool = true, id: String = "test_windup") -> Ability:
	return Ability.from_dict({
		"id": id,
		"display_name": id.capitalize(),
		"cast_time": cast_time,
		"interruptible": interruptible,
		"traits": {},
		"targeting": {"type": "point", "range": 0.0, "shape": "circle", "radius": 10.0},
		"effects": [],
	})

## Records cast_interrupted / cast_completed / cast_failed on a character.
func _watch(ch) -> Dictionary:
	var rec := {"interrupted": [], "completed": 0, "failed": []}
	ch.ability_manager.cast_interrupted.connect(func(_a, reason): rec["interrupted"].append(String(reason)))
	ch.ability_manager.cast_completed.connect(func(_a, _r): rec["completed"] += 1)
	ch.ability_manager.cast_failed.connect(func(_a, reason): rec["failed"].append(String(reason)))
	return rec

func _casting(ch) -> bool:
	return ch.ability_manager.current_cast.get("state", "") == "casting"

func _logged(fragment: String) -> bool:
	for l in log_lines:
		if fragment in l:
			return true
	return false

# ---------------------------------------------------------------------------
# Incapacitation gate and free casts
# ---------------------------------------------------------------------------

func _gate_cases() -> void:
	var n = _spawn("Dazed", Vector2(3000, 3000))
	await _frames(2)
	var rec := _watch(n)
	n.condition_manager.apply_condition("stunned", null, 1, 5.0)
	_check("gate.stunned-refuses", not n.use_ability(_windup_ability(0.0), {"position": n.global_position}) and rec["failed"].has("Stunned"), rec)
	n.condition_manager.clear_all_conditions()
	n.condition_manager.apply_condition("frozen", null, 1, 5.0)
	_check("gate.frozen-refuses", not n.use_ability(_windup_ability(0.0), {"position": n.global_position}) and rec["failed"].has("Frozen"), rec)
	_check("gate.free-cast-lands-while-frozen", n.use_ability(_windup_ability(0.0), {"position": n.global_position, "free": true}), rec)
	n.condition_manager.clear_all_conditions()
	n.condition_manager.apply_condition("unconscious", null, 1, 5.0)
	_check("gate.unconscious-refuses", not n.use_ability(_windup_ability(0.0), {"position": n.global_position}) and rec["failed"].has("Unconscious"), rec)
	n.condition_manager.clear_all_conditions()
	_check("gate.clear-casts", n.use_ability(_windup_ability(0.0), {"position": n.global_position}))

	# A party member is told why.
	var p = _party()
	var saved: Dictionary = p.condition_manager.to_dict()
	p.condition_manager.apply_condition("stunned", null, 1, 5.0)
	p._last_notify_text = ""
	p.use_ability(_windup_ability(0.0, true, "test_zap"), {"position": p.global_position})
	_check("gate.party-told", p._last_notify_text == "Stunned" and _logged("%s can't use Test Zap: Stunned." % p.Name), p._last_notify_text)
	p.condition_manager.from_dict(saved)

	# A free cast pays nothing and skips requirements.
	var sage = _spawn("Payer", Vector2(3050, 3000))
	await _frames(2)
	sage.npc_unlimited_resources = false
	sage.focus = 0
	var arcane := Ability.from_dict({"id": "test_arcane", "display_name": "Test Arcane", "cast_time": 0.0,
		"traits": {"Arcane": 2}, "targeting": {"type": "point"}, "effects": []})
	var srec := _watch(sage)
	_check("free.normal-cast-needs-focus", not sage.use_ability(arcane, {"position": sage.global_position}) and srec["failed"].size() == 1, srec)
	_check("free.cast-costs-nothing", sage.use_ability(arcane, {"position": sage.global_position, "free": true}) and sage.focus == 0, sage.focus)
	var bash := Ability.from_dict(AbilityDatabase.get_ability_data("shield_bash"))
	_check("free.skips-requirements", sage.use_ability(bash, {"position": sage.global_position + Vector2(30, 0), "free": true}))
	# "Already casting" still applies to free casts.
	sage.use_ability(_windup_ability(5.0), {"position": sage.global_position})
	_check("free.still-already-casting", not sage.use_ability(arcane, {"position": sage.global_position, "free": true}) and srec["failed"].has("Already casting"), srec)
	sage.ability_manager.cancel_cast("")
	_despawn(sage)
	_despawn(n)
	await _frames(2)

# ---------------------------------------------------------------------------
# F5: interruptible casts
# ---------------------------------------------------------------------------

func _f5_cases() -> void:
	var p = _party()
	var p2 = _party(1) if game.party_chars.size() > 1 else null

	# pause.freezes-windup
	var a = _spawn("Caster", Vector2(3000, 3200))
	await _frames(2)
	a.use_ability(_windup_ability(5.0), {"position": a.global_position})
	await _frames(3)
	PauseManager.pause()
	var p0: float = float(a.ability_manager.current_cast.get("cast_progress", -1.0))
	await _frames(20)
	var p1: float = float(a.ability_manager.current_cast.get("cast_progress", -1.0))
	_check("pause.freezes-windup", _casting(a) and is_equal_approx(p0, p1), [p0, p1])
	PauseManager.unpause()
	await _frames(10)
	var p2v: float = float(a.ability_manager.current_cast.get("cast_progress", -1.0))
	_check("pause.resumes-on-unpause", p2v > p1, [p1, p2v])
	_despawn(a)

	# death.cancels-windup and nothing lands afterwards, silently
	var d = _spawn("Doomed", Vector2(3100, 3200))
	await _frames(2)
	var drec := _watch(d)
	d.use_ability(_windup_ability(0.2), {"position": d.global_position})
	d.current_health = 0
	d._check_death()
	_check("death.cancels-windup", d.ability_manager.current_cast.is_empty(), d.ability_manager.current_cast)
	await get_tree().create_timer(0.5).timeout
	_check("death.no-completion", drec["completed"] == 0, drec)
	_check("death.silent", not _logged("Doomed's Test Windup is interrupted"), log_lines)
	# Dev's dying breath: an uninterruptible windup may still finish.
	var db = _spawn("Defiant", Vector2(3150, 3200))
	await _frames(2)
	db.use_ability(_windup_ability(5.0, false), {"position": db.global_position})
	db.current_health = 0
	db._check_death()
	_check("death.uninterruptible-dying-breath", _casting(db), db.ability_manager.current_cast)
	db.ability_manager.cancel_cast("")

	# hit.interrupts, with a seen attacker's name and a log line
	var unseen = _spawn("Sniper", Vector2(6000, 6000))
	await _frames(2)
	var hrec := _watch(p)
	p.use_ability(_windup_ability(5.0), {"position": p.global_position})
	var attacker = p2 if p2 != null else unseen
	p.take_damage({"slashing": 1}, p.global_position, attacker)
	_check("hit.interrupts", not _casting(p) and hrec["interrupted"].size() == 1, hrec)
	if p2 != null:
		_check("hit.reason-names-seen-attacker", hrec["interrupted"].size() == 1 and ("hit by %s" % p2.Name) in hrec["interrupted"][0], hrec)
		_check("hit.logged", _logged("%s's Test Windup is interrupted: hit by %s." % [p.Name, p2.Name]), log_lines.slice(-3))
	_check("hit.notice", p._last_notify_text == "Interrupted!", p._last_notify_text)
	# An attacker the party can't see stays unnamed.
	p._last_notify_text = ""
	p.use_ability(_windup_ability(5.0), {"position": p.global_position})
	p.take_damage({"slashing": 1}, p.global_position, unseen)
	_check("hit.unseen-attacker-unnamed", hrec["interrupted"].size() == 2 and hrec["interrupted"][1] == "took a hit", hrec)

	# tick.no-interrupt: a real Burning tick doesn't break the windup
	p.use_ability(_windup_ability(5.0), {"position": p.global_position})
	var saved: Dictionary = p.condition_manager.to_dict()
	var burn = p.condition_manager.apply_condition("burning", null, 1, 5.0)
	var hp0: int = p.current_health
	if burn:
		burn.last_trigger_times.clear()
		p.condition_manager._process(0.016)
	_check("tick.fixture", burn != null and p.current_health < hp0, [burn, hp0, p.current_health])
	_check("tick.no-interrupt", _casting(p), p.ability_manager.current_cast)
	p.condition_manager.from_dict(saved)

	# blocked.no-interrupt: a hit soaked up entirely doesn't either
	p.condition_manager.apply_condition("shielded", null, 1, 30.0)
	var hp_before: int = p.current_health
	p.take_damage({"slashing": 3}, p.global_position, unseen)
	_check("blocked.no-interrupt", _casting(p) and p.current_health == hp_before, [p.current_health, hp_before])
	p.condition_manager.from_dict(saved)
	p.ability_manager.cancel_cast("")
	p.current_health = p.max_health

	# noninterruptible.ignores-hit, then stunned.forces-interrupt
	p.use_ability(_windup_ability(5.0, false, "test_ward"), {"position": p.global_position})
	p.take_damage({"slashing": 1}, p.global_position, unseen)
	_check("noninterruptible.ignores-hit", _casting(p), hrec)
	# notify() drops a repeat of the same float (and its log) inside 1 s.
	p._last_notify_text = ""
	p.condition_manager.apply_condition("stunned", unseen, 1, 5.0)
	_check("stunned.forces-interrupt", not _casting(p) and hrec["interrupted"].has("Stunned"), hrec)
	_check("stunned.logged", _logged("%s's Test Ward is interrupted: Stunned." % p.Name), log_lines.slice(-3))
	p.condition_manager.from_dict(saved)

	# free.never-interrupted: an item's cast ignores hits and stuns
	var f = _spawn("Drinker", Vector2(3200, 3200))
	await _frames(2)
	f.use_ability(_windup_ability(5.0), {"position": f.global_position, "free": true})
	f.take_damage({"slashing": 3}, f.global_position, unseen)
	f.condition_manager.apply_condition("stunned", unseen, 1, 5.0)
	_check("free.never-interrupted", _casting(f), f.ability_manager.current_cast)
	f.ability_manager.cancel_cast("")
	_despawn(f)

	# knockback.interrupts
	var k = _spawn("Shoved", Vector2(3300, 3200))
	await _frames(2)
	var krec := _watch(k)
	k.use_ability(_windup_ability(5.0), {"position": k.global_position})
	AbilityEffect.resolve_effect({"type": "knockback", "strength": 600}, unseen, [k], null, unseen.global_position)
	_check("knockback.interrupts", not _casting(k) and krec["interrupted"].has("knocked back"), krec)
	_despawn(k)

	# step sequences aren't windups: a hit doesn't stop them
	var st = _spawn("Stepper", Vector2(3400, 3200))
	await _frames(2)
	var steps := Ability.from_dict({"id": "test_steps", "display_name": "Test Steps", "cast_time": 0.0, "traits": {},
		"targeting": {"type": "point", "shape": "circle", "radius": 10.0},
		"steps": [{"delay": 0.0, "effects": []}, {"delay": 5.0, "effects": []}]})
	st.use_ability(steps, {"position": st.global_position})
	st.take_damage({"slashing": 1}, st.global_position, unseen)
	_check("steps.not-interrupted", st.ability_manager.current_cast.get("state", "") == "stepping", st.ability_manager.current_cast)
	st.ability_manager.cancel_cast("")
	_despawn(st)

	# shield.required: Shield Bash refuses without a shield, works with one
	var s = _spawn("Bran", Vector2(3500, 3200))
	await _frames(2)
	var srec := _watch(s)
	var bash := Ability.from_dict(AbilityDatabase.get_ability_data("shield_bash"))
	var ok_without: bool = s.use_ability(bash, {"position": s.global_position + Vector2(30, 0)})
	_check("shield.required", not ok_without and srec["failed"].has("Needs a shield"), srec)
	var shield := WeaponShape.new()
	shield.id = "iron_shield"
	s.current_off_hand_item = shield
	_check("shield.detected-by-item-type", s.has_shield())
	var ok_with: bool = s.use_ability(Ability.from_dict(AbilityDatabase.get_ability_data("shield_bash")), {"position": s.global_position + Vector2(30, 0)})
	_check("shield.allows-bash", ok_with, srec)
	shield.id = "procedural_board"
	shield.weapon_type = WeaponShape.WeaponType.SHIELD
	_check("shield.detected-by-weapon-type", s.has_shield())
	s.current_off_hand_item = null
	shield.free()
	_check("requirement.reason-text", AbilityManager.requirement_reason("has_shield") == "Needs a shield" and AbilityManager.requirement_reason("winged") == "Requires Winged")
	_despawn(s)

	# tooltips: windup and requirement lines
	var ItemTooltip = preload("res://UI/ItemTooltip.gd")
	var well_lines: PackedStringArray = ItemTooltip.ability_lines({"kind": "ability", "ability_id": "gravity_well"})
	_check("tooltip.interruptible", well_lines.has("Interruptible"), well_lines)
	var bash_lines: PackedStringArray = ItemTooltip.ability_lines({"kind": "ability", "ability_id": "shield_bash"})
	_check("tooltip.requirement", bash_lines.has("Needs a shield") and not bash_lines.has("Interruptible"), bash_lines)
	_check("tooltip.non-ability-empty", ItemTooltip.ability_lines({"kind": "item", "ability_id": "gravity_well"}).is_empty())
	_despawn(unseen)
	_despawn(d)
	_despawn(db)
	await _frames(2)

# ---------------------------------------------------------------------------
# Projectile AoE preview (abilities-17)
# ---------------------------------------------------------------------------

func _impact_cases() -> void:
	# A caster in open ground with a body along the line of fire.
	var p = _spawn("Gunner", Vector2(4000, 3600))
	var t = p.targeting_system
	var origin: Vector2 = p.global_position
	var wall = _spawn("Blocker", origin + Vector2(150, 0))
	await _physics(3)
	var burst := {"display_name": "Test Fireball", "target_shape": "circle", "radius": 40.0, "range": 0.0,
		"target_type": "point", "visuals": {"projectile": "res://vfx/fireball.tscn"},
		"targeting": {"type": "point", "shape": "circle", "radius": 40.0}}
	t.start_targeting("Main", burst, origin + Vector2(400, -20))
	t.target_position = origin + Vector2(400, -20)
	t._update_active_indicator()
	var drawer = t.circle_indicator.get_child(0)
	_check("impact.stops-at-body", t._projectile_impact != Vector2.INF and t.circle_indicator.global_position.x < origin.x + 160.0,
		[t._projectile_impact, t.circle_indicator.global_position])
	_check("impact.tinted-blocked", drawer.is_blocked)
	var res: Dictionary = t.confirm_targeting()
	_check("impact.confirm-keeps-aim", res.get("position", Vector2.INF).distance_to(origin + Vector2(400, -20)) < 0.5, res.get("position"))
	t.end_targeting()
	_check("impact.reset-on-end", t._projectile_impact == Vector2.INF)
	# Aiming at the body itself: the burst on its edge still covers the aim point.
	t.start_targeting("Main", burst, origin + Vector2(150, -20))
	t.target_position = origin + Vector2(150, -20)
	t._update_active_indicator()
	_check("impact.near-aim-not-tinted", not drawer.is_blocked, [t._projectile_impact, origin, t.target_position])
	t.end_targeting()
	# No projectile: the preview sits on the cursor.
	var plain := burst.duplicate(true)
	plain["visuals"] = {}
	t.start_targeting("Main", plain, origin + Vector2(400, -20))
	t.target_position = origin + Vector2(400, -20)
	t._update_active_indicator()
	_check("impact.plain-aoe-on-cursor", t._projectile_impact == Vector2.INF and t.circle_indicator.global_position.distance_to(origin + Vector2(400, -20)) < 0.5)
	t.end_targeting()
	_despawn(wall)
	_despawn(p)
	await _frames(2)
