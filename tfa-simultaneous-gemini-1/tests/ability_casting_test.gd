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
	await _f6_cases()
	await _f7_cases()

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

# ---------------------------------------------------------------------------
# F6: ability range
# ---------------------------------------------------------------------------

## A targeting node on a bare host at `pos`, as ProceduralCharacter has one.
func _targeting_host(pos: Vector2) -> Node2D:
	var host := Node2D.new()
	game.add_child(host)
	host.global_position = pos
	var t = load("res://Abilities/AbilityTargeting.gd").new()
	host.add_child(t)
	return t

func _near(a: Vector2, b: Vector2) -> bool:
	return a.distance_to(b) < 0.5

## The force field a cast_completed result list created, or null.
func _field_in(got: Array):
	if got.size() == 1 and got[0].size() >= 1 and got[0][0] is Dictionary and not got[0][0].get("created_objects", []).is_empty():
		return got[0][0]["created_objects"][0]
	return null

func _f6_cases() -> void:
	# manager.clamp: the one shared clamp
	_check("manager.clamp-pulls-back", _near(AbilityManager.clamp_point_to_range(Vector2.ZERO, Vector2(1000, 0), 200.0), Vector2(200, 0)))
	_check("manager.clamp-in-range-untouched", _near(AbilityManager.clamp_point_to_range(Vector2.ZERO, Vector2(120, 50), 200.0), Vector2(120, 50)))
	_check("manager.clamp-unlimited", _near(AbilityManager.clamp_point_to_range(Vector2.ZERO, Vector2(5000, 0), 0.0), Vector2(5000, 0)))
	_check("manager.clamp-inf-untouched", AbilityManager.clamp_point_to_range(Vector2.ZERO, Vector2.INF, 200.0) == Vector2.INF)

	# targeting.circle-clamps: the aim point stops on the ring around the caster
	var o := Vector2(5000, 5000)
	var t = _targeting_host(o)
	await _frames(1)
	var burst := {"display_name": "Test Burst", "target_shape": "circle", "radius": 50.0, "range": 200.0, "target_type": "point", "visuals": {}}
	t.start_targeting("Main", burst, o + Vector2(1000, 0))
	_check("targeting.initial-point-clamped", _near(t.target_position, o + Vector2(200, 0)), t.target_position)
	_check("targeting.ring-visible", t.range_indicator.visible and _near(t.range_indicator.global_position, o), [t.range_indicator.visible, t.range_indicator.global_position])
	_check("targeting.ring-radius", is_equal_approx((t.range_indicator.get_child(0)).radius, 200.0))
	_check("targeting.ring-outline-only", not (t.range_indicator.get_child(0)).draw_fill)
	t.target_position = o + Vector2(1000, 0)
	var res: Dictionary = t.confirm_targeting()
	_check("targeting.circle-clamps", _near(res.get("position", Vector2.INF), o + Vector2(200, 0)), res.get("position"))
	_check("targeting.ring-hidden-on-confirm", not t.range_indicator.visible)
	t.end_targeting()

	# targeting.node-origin: planning from a path node measures from the node
	t.start_targeting("Main", burst, o + Vector2(1000, 0), o + Vector2(500, 0))
	_check("targeting.ring-on-node", _near(t.range_indicator.global_position, o + Vector2(500, 0)), t.range_indicator.global_position)
	t.target_position = o + Vector2(1000, 0)
	res = t.confirm_targeting()
	_check("targeting.node-origin", _near(res.get("position", Vector2.INF), o + Vector2(700, 0)), res.get("position"))
	t.end_targeting()

	# targeting.rectangle-clamps
	t.start_targeting("Main", {"display_name": "Test Wall", "target_shape": "rectangle", "size": Vector2(100, 40), "range": 150.0, "target_type": "point", "visuals": {}}, o + Vector2(0, 900))
	t.target_position = o + Vector2(0, 900)
	res = t.confirm_targeting()
	_check("targeting.rectangle-clamps", _near(res.get("position", Vector2.INF), o + Vector2(0, 150)), res.get("position"))
	t.end_targeting()

	# targeting.self-unclamped: self casts sit on the caster, no ring
	t.start_targeting("Main", {"display_name": "Test Aura", "target_shape": "circle", "radius": 80.0, "range": 200.0, "target_type": "self", "visuals": {}}, o + Vector2(1000, 0))
	_check("targeting.self-no-ring", not t.range_indicator.visible)
	res = t.confirm_targeting()
	_check("targeting.self-unclamped", _near(res.get("position", Vector2.INF), o), res.get("position"))
	t.end_targeting()

	# targeting.line-ring: lines keep their own end clamp and show a ring
	t.start_targeting("Main", {"display_name": "Test Bolt", "target_shape": "line", "size": Vector2(300, 20), "range": 300.0, "target_type": "point", "visuals": {}}, o + Vector2(1000, 0))
	_check("targeting.line-ring", t.range_indicator.visible)
	t.target_position = o + Vector2(1000, 0)
	res = t.confirm_targeting()
	_check("targeting.line-clamped", _near(res.get("position", Vector2.INF), o + Vector2(300, 0)), res.get("position"))
	t.end_targeting()

	# targeting.cone-no-ring: a cone reaches its radius
	t.start_targeting("Main", {"display_name": "Test Wave", "target_shape": "cone", "radius": 150.0, "angle": 60.0, "range": 150.0, "target_type": "point", "visuals": {}}, o + Vector2(1000, 0))
	_check("targeting.cone-no-ring", not t.range_indicator.visible)
	t.end_targeting()
	_check("targeting.ring-hidden-on-end", not t.range_indicator.visible)

	# characters: picks beyond range_limit are refused, and say why
	var far = _spawn("Faraway", o + Vector2(400, 0))
	var near = _spawn("Nearby", o + Vector2(80, 0))
	await _physics(3)
	var hitch := {"display_name": "Test Hitch", "target_shape": "characters", "range": 150.0, "target_type": "target", "target_count": 2, "target_filter": "any", "visuals": {}}
	t.start_targeting("Main", hitch, o + Vector2(80, 0))
	_check("characters.ring-visible", t.range_indicator.visible and is_equal_approx((t.range_indicator.get_child(0)).radius, 150.0))
	var consumed_far: bool = t._handle_character_click(far.global_position)
	_check("characters.reject-out-of-range", consumed_far and not (far in t.selected_targets) and far._last_notify_text == "Out of range" \
		and _logged("can't target Faraway with Test Hitch: out of range"), [consumed_far, t.selected_targets, far._last_notify_text])
	var consumed_near: bool = t._handle_character_click(near.global_position)
	_check("characters.accept-in-range", consumed_near and (near in t.selected_targets), [consumed_near, t.selected_targets])
	t.end_targeting()
	# Measured from the planned node, not the live body.
	t.start_targeting("Main", hitch, far.global_position, o + Vector2(350, 0))
	t._handle_character_click(far.global_position)
	_check("characters.node-origin-range", far in t.selected_targets, t.selected_targets)
	t.end_targeting()
	_despawn(far)
	_despawn(near)
	t.get_parent().queue_free()

	# manager.use_ability-clamps: execution clamps from where the caster stands,
	# and a party member hears that it fell short
	var c = _party()
	var start: Vector2 = c.global_position
	var got := []
	var cb := func(_a, results): got.append(results)
	c.ability_manager.cast_completed.connect(cb)
	var well := Ability.from_dict({
		"id": "test_well", "display_name": "Test Well", "cast_time": 0.0, "traits": {},
		"targeting": {"type": "point", "range": 220.0, "shape": "circle", "radius": 60.0},
		"effects": [{"type": "force_field", "field_type": "gravity", "radius": 60.0, "strength": 1.0, "duration": 2.0}],
	})
	c._last_notify_text = ""
	c.use_ability(well, {"position": start + Vector2(1000, 0)})
	var field = _field_in(got)
	_check("manager.use_ability-clamps", field != null and _near(field.global_position, start + Vector2(220, 0)), field.global_position - start if field else got)
	_check("manager.falls-short-notice", c._last_notify_text == "Out of range" and _logged("%s's Test Well falls short: the target was 1000 away, range 220." % c.Name), c._last_notify_text)
	if field and is_instance_valid(field):
		field.queue_free()
	# A small slip (within RANGE_CLAMP_NOTICE_PX) is clamped silently.
	got.clear()
	c._last_notify_text = ""
	c.use_ability(well, {"position": start + Vector2(230, 0)})
	field = _field_in(got)
	_check("manager.small-clamp-silent", field != null and _near(field.global_position, start + Vector2(220, 0)) and c._last_notify_text == "", c._last_notify_text)
	if field and is_instance_valid(field):
		field.queue_free()
	# A designated character re-aims the cast: no clamp.
	got.clear()
	var mark = _spawn("Mark", start + Vector2(600, 0))
	await _frames(1)
	c.use_ability(well, {"position": mark.global_position, "anchor": mark})
	field = _field_in(got)
	_check("manager.anchor-unclamped", field != null and _near(field.global_position, mark.global_position), field.global_position - start if field else got)
	if field and is_instance_valid(field):
		field.queue_free()
	_despawn(mark)
	# A free (item) cast isn't clamped either.
	got.clear()
	c.use_ability(well, {"position": start + Vector2(1000, 0), "free": true})
	field = _field_in(got)
	_check("manager.free-unclamped", field != null and _near(field.global_position, start + Vector2(1000, 0)))
	if field and is_instance_valid(field):
		field.queue_free()
	c.ability_manager.cast_completed.disconnect(cb)

	# manager.cone-unclamped: a cone's point only aims it, so a far cursor is
	# kept (no "falls short" notice); a point windup is clamped as it starts.
	var started := []
	var sb := func(_a, pos): started.append(pos)
	c.ability_manager.cast_started.connect(sb)
	var cone := Ability.from_dict({
		"id": "test_cone", "display_name": "Test Cone", "cast_time": 1.0, "traits": {},
		"targeting": {"type": "direction", "range": 150.0, "shape": "cone", "radius": 150.0, "angle": 60.0},
		"effects": [],
	})
	c._last_notify_text = ""
	c.use_ability(cone, {"position": start + Vector2(1000, 0)})
	_check("manager.cone-unclamped", started.size() == 1 and _near(started[0], start + Vector2(1000, 0)) and c._last_notify_text == "", started)
	c.ability_manager.cancel_cast("")
	var point_windup := Ability.from_dict({
		"id": "test_point_windup", "display_name": "Test Point", "cast_time": 1.0, "traits": {},
		"targeting": {"type": "point", "range": 150.0, "shape": "circle", "radius": 30.0},
		"effects": [],
	})
	c.use_ability(point_windup, {"position": start + Vector2(1000, 0)})
	_check("manager.point-windup-clamped", started.size() == 2 and _near(started[1], start + Vector2(150, 0)), started)
	c.ability_manager.cancel_cast("")
	c.ability_manager.cast_started.disconnect(sb)
	await _frames(2)

# ---------------------------------------------------------------------------
# F7: Concentration
# ---------------------------------------------------------------------------

## Arcane 2 + Concentration: a gravity field plus Slowed on the picked target.
func _conc_ability(id: String, cast_time: float = 0.0, field_duration: float = 30.0) -> Ability:
	return Ability.from_dict({
		"id": id, "display_name": id.capitalize(), "cast_time": cast_time,
		"traits": {"Arcane": 2, "Concentration": 1, "spell": 1},
		"targeting": {"type": "point", "range": 0.0, "shape": "circle", "radius": 60.0},
		"effects": [
			{"type": "force_field", "field_type": "gravity", "radius": 60.0, "strength": 1.0, "duration": field_duration},
			{"type": "apply_condition", "condition_id": "slowed", "duration": 60.0},
		],
	})

## An Arcane 3 caster with full focus (3) who pays for spells.
func _sage(char_name: String, pos: Vector2) -> Node:
	var c = _spawn(char_name, pos)
	c.npc_unlimited_resources = false
	c.traits["Arcane"] = 3
	c.focus = 3
	return c

## Casts `ab` at `enemy` and returns the force field it created (or null).
func _cast_conc(c, ab, enemy, extra: Dictionary = {}):
	var got := []
	var cb := func(_a, results): got.append(results)
	c.ability_manager.cast_completed.connect(cb)
	var data := {"position": enemy.global_position, "targets": [enemy]}
	data.merge(extra, true)
	c.use_ability(ab, data)
	c.ability_manager.cast_completed.disconnect(cb)
	if got.is_empty():
		return null
	for r in got[0]:
		if r is Dictionary and not r.get("created_objects", []).is_empty():
			return r["created_objects"][0]
	return null

func _gone(obj) -> bool:
	return not is_instance_valid(obj) or obj.is_queued_for_deletion()

func _slowed_by(enemy):
	return enemy.condition_manager.conditions.get("slowed")

func _f7_cases() -> void:
	_check("data.cloud_kill-concentration", Ability.from_dict(AbilityDatabase.get_ability_data("cloud_kill")).is_concentration())
	_check("data.gravity_well-concentration", Ability.from_dict(AbilityDatabase.get_ability_data("gravity_well")).is_concentration())
	_check("data.fireball-not-concentration", not Ability.from_dict(AbilityDatabase.get_ability_data("fireball")).is_concentration())
	var ItemTooltip = preload("res://UI/ItemTooltip.gd")
	_check("tooltip.concentration", ItemTooltip.ability_lines({"kind": "ability", "ability_id": "gravity_well"}).has("Concentration"))

	var enemy = _spawn("Dummy", Vector2(4200, 4200))

	# conc.reserves: the focus is held, not spent (a party member, so the log
	# lines reach the player)
	var c = _party()
	var arcane0: int = int(c.traits.get("Arcane", 0))
	var focus0: int = c.focus
	var saved: Dictionary = c.condition_manager.to_dict()
	c.traits["Arcane"] = 3
	c.focus = 3
	await _frames(1)
	c.focus = 3
	var field = _cast_conc(c, _conc_ability("test_conc"), enemy)
	_check("conc.reserves", c.focus == 3 and c.concentration_locked_focus == 2 and c.spendable_focus == 1,
		[c.focus, c.concentration_locked_focus, c.spendable_focus])
	_check("conc.tracks-installs", field != null and not _gone(field) and _slowed_by(enemy) != null and c.get_concentration_names() == PackedStringArray(["Test Conc"]),
		[field, _slowed_by(enemy), c.get_concentration_names()])
	_check("conc.logged", _logged("%s concentrates on Test Conc (2 focus held)." % c.Name), log_lines.slice(-3))
	var plain := Ability.from_dict({"id": "test_plain", "display_name": "Test Plain", "traits": {"Arcane": 2}, "targeting": {"type": "point"}, "effects": []})
	var usable: Dictionary = c.ability_manager._check_ability_usable(plain)
	_check("conc.held-focus-not-spendable", not usable["success"] and "focus" in String(usable.get("reason", "")).to_lower(), usable)

	# panel: held focus pips are lavender, after the spendable ones, and named
	var panel = load("res://UI/PartySidePanel.gd").new()
	var blue := Color(0.3, 0.5, 0.95)
	_check("panel.pip-colours", panel._pip_color(0, 3, 2, blue) == blue and panel._pip_color(1, 3, 2, blue) == Color(0.8, 0.65, 1.0)
		and panel._pip_color(2, 3, 2, blue) == Color(0.8, 0.65, 1.0) and panel._pip_color(3, 3, 2, blue) == Color(0.3, 0.3, 0.3, 1.0))
	var tip: String = panel._held_tooltip(c, "focus")
	_check("panel.tooltip-names-held", "2 held by Concentration: Test Conc" in tip, tip)
	_check("panel.no-held-no-line", panel._held_tooltip(c, "devotion") == "")
	panel.free()

	# conc.break-on-hit: the first hit costs free focus, the second would dip
	# into held focus and breaks the spell instead
	c.take_damage({"force": 1}, c.global_position, enemy)
	_check("conc.first-hit-spends-free-focus", c.focus == 2 and c.concentration_locked_focus == 2, [c.focus, c.concentration_locked_focus])
	c._last_notify_text = ""
	c.take_damage({"force": 1}, c.global_position, enemy)
	_check("conc.break-on-hit", c.concentration_locked_focus == 0 and c.active_concentrations.is_empty() and c.focus == 2,
		[c.focus, c.concentration_locked_focus, c.active_concentrations])
	_check("conc.break-dispels-field", _gone(field))
	_check("conc.break-removes-condition", _slowed_by(enemy) == null)
	_check("conc.break-logged", c._last_notify_text == "Concentration broken" and _logged("%s loses concentration: Test Conc ends." % c.Name), log_lines.slice(-3))

	# conc.natural-end: when everything it installed is gone, the focus is free
	c.focus = 3
	var short_field = _cast_conc(c, _conc_ability("test_conc_short", 0.0, 0.2), enemy)
	_check("conc.natural-start", c.concentration_locked_focus == 2 and short_field != null)
	enemy.condition_manager.remove_condition("slowed")
	await get_tree().create_timer(0.6).timeout
	await _frames(3)
	_check("conc.natural-end", c.concentration_locked_focus == 0 and c.active_concentrations.is_empty() and c.focus == 3,
		[c.focus, c.concentration_locked_focus, c.active_concentrations])
	_check("conc.natural-end-logged", _logged("%s's Test Conc Short ends; 2 focus is free again." % c.Name), log_lines.slice(-3))

	# conc.replaced: a new Concentration spell lets the old one go; its held
	# focus counts toward the new cost
	c.focus = 3
	var first_field = _cast_conc(c, _conc_ability("test_conc_a"), enemy)
	var second_ab := _conc_ability("test_conc_b")
	_check("conc.replace-usable", c.ability_manager._check_ability_usable(second_ab)["success"])
	var second_field = _cast_conc(c, second_ab, enemy)
	_check("conc.replaced", _gone(first_field) and second_field != null and not _gone(second_field)
		and c.active_concentrations.keys() == ["test_conc_b"] and c.concentration_locked_focus == 2 and c.focus == 3,
		[c.active_concentrations.keys(), c.concentration_locked_focus, c.focus])
	_check("conc.replaced-keeps-new-condition", _slowed_by(enemy) != null and _slowed_by(enemy) == c.active_concentrations["test_conc_b"]["conditions"][0]["instance"])
	_check("conc.replaced-logged", _logged("%s lets Test Conc A go to concentrate on Test Conc B." % c.Name), log_lines.slice(-3))

	# conc.incapacitated: Stunned ends the spell
	c._last_notify_text = ""
	c.condition_manager.apply_condition("stunned", enemy, 1, 5.0)
	_check("conc.incapacitated", c.active_concentrations.is_empty() and c.concentration_locked_focus == 0 and _gone(second_field) and _slowed_by(enemy) == null,
		[c.active_concentrations, _slowed_by(enemy)])
	_check("conc.incapacitated-logged", _logged("%s is Stunned and loses concentration: Test Conc B ends." % c.Name), log_lines.slice(-3))
	c.condition_manager.from_dict(saved)
	c.traits["Arcane"] = arcane0
	c.focus = focus0

	# conc.death: dying ends it, field and all
	var d = _sage("Mortal", Vector2(4000, 4300))
	await _frames(2)
	var death_field = _cast_conc(d, _conc_ability("test_conc_d"), enemy)
	_check("conc.death-fixture", not d.active_concentrations.is_empty())
	d.current_health = 0
	d._check_death()
	_check("conc.death", d.concentration_locked_focus == 0 and d.active_concentrations.is_empty() and _gone(death_field) and _slowed_by(enemy) == null)

	# conc.focus-drop-breaks: focus pushed below the hold (max_focus shrank)
	var fdrop = _sage("Drained", Vector2(4000, 4400))
	await _frames(2)
	var drop_field = _cast_conc(fdrop, _conc_ability("test_conc_f"), enemy)
	fdrop.focus = 1
	await _frames(3)
	_check("conc.focus-drop-breaks", fdrop.active_concentrations.is_empty() and fdrop.concentration_locked_focus == 0 and _gone(drop_field))
	_despawn(fdrop)

	# conc.interrupted-windup-holds-nothing: nothing is held or spent until it lands
	var w = _sage("Slowpoke", Vector2(4000, 4500))
	await _frames(2)
	var wrec := _watch(w)
	w.use_ability(_conc_ability("test_conc_w", 1.0), {"position": enemy.global_position, "targets": [enemy]})
	w.take_damage({"force": 1}, w.global_position, enemy)
	# Only the hit's -1: committing the windup spent no focus.
	var focus_after_hit: int = w.focus
	await get_tree().create_timer(1.3).timeout
	_check("conc.interrupted-windup-holds-nothing", wrec["interrupted"].size() == 1 and wrec["completed"] == 0
		and w.concentration_locked_focus == 0 and focus_after_hit == 2 and w.active_concentrations.is_empty(),
		[wrec, focus_after_hit, w.concentration_locked_focus])
	_despawn(w)

	# conc.free-cast-no-lock: an item's cast never concentrates
	var fr = _sage("Quaffer", Vector2(4000, 4600))
	await _frames(2)
	var free_field = _cast_conc(fr, _conc_ability("test_conc_free"), enemy, {"free": true})
	_check("conc.free-cast-no-lock", free_field != null and fr.active_concentrations.is_empty() and fr.concentration_locked_focus == 0 and fr.focus == 3)
	if is_instance_valid(free_field):
		free_field.queue_free()
	enemy.condition_manager.remove_condition("slowed")
	# The same Ability cast normally afterwards does concentrate.
	var reused := _conc_ability("test_conc_reuse")
	reused.set_meta("free_cast", true)
	var reused_field = _cast_conc(fr, reused, enemy)
	_check("conc.free-flag-cleared-on-normal-cast", not fr.active_concentrations.is_empty() and reused_field != null)
	fr.end_concentration("")
	_despawn(fr)

	# conc.npc-unlimited: concentrates for free; hits don't break it, a stun does
	var npc = _spawn("Hexer", Vector2(4000, 4700))
	npc.traits["Arcane"] = 2
	await _frames(2)
	var npc_field = _cast_conc(npc, _conc_ability("test_conc_npc"), enemy)
	npc.take_damage({"force": 1}, npc.global_position, enemy)
	_check("conc.npc-unlimited-holds", not npc.active_concentrations.is_empty() and npc.concentration_locked_focus == 0 and not _gone(npc_field))
	npc.condition_manager.apply_condition("stunned", enemy, 1, 5.0)
	_check("conc.npc-stun-ends", npc.active_concentrations.is_empty() and _gone(npc_field))
	_despawn(npc)

	# conc.others-condition-kept: Slowed someone else already put on the target
	# comes back as their instance; breaking this spell must not remove it.
	var other = _spawn("Other", Vector2(4100, 4800))
	var own = _sage("Owner", Vector2(4000, 4800))
	await _frames(2)
	enemy.condition_manager.apply_condition("slowed", other, 1, 60.0)
	var others_slowed = _slowed_by(enemy)
	var own_field = _cast_conc(own, _conc_ability("test_conc_o"), enemy)
	var tracked_conditions: Array = own.active_concentrations.get("test_conc_o", {}).get("conditions", [])
	_check("conc.others-condition-untracked", not own.active_concentrations.is_empty() and tracked_conditions.is_empty(), tracked_conditions)
	own.end_concentration("broken")
	_check("conc.others-condition-kept", _gone(own_field) and others_slowed != null and _slowed_by(enemy) == others_slowed)
	enemy.condition_manager.remove_condition("slowed")
	# Only fields and clouds are dispelled: a summoned item or structure isn't
	# tracked (breaking the spell would delete it).
	var loot := Node2D.new()
	game.add_child(loot)
	var entry := {"conditions": [], "objects": []}
	own._collect_concentration_installs([{"created_objects": [loot, Vector2i(3, 4)]}], entry)
	_check("conc.items-not-tracked", entry["objects"].is_empty(), entry)
	loot.queue_free()
	_despawn(own)
	_despawn(other)

	# conc.cloud: Cloud Kill's cloud is tracked and dispelled through FogManager
	var cloud_caster = _sage("Fumer", Vector2(4000, 4900))
	await _frames(2)
	var ck := Ability.from_dict(AbilityDatabase.get_ability_data("cloud_kill"))
	var got := []
	var cb := func(_a, results): got.append(results)
	cloud_caster.ability_manager.cast_completed.connect(cb)
	# Resolve the cloud directly, as the projectile's landing does.
	cloud_caster._resolve_ability_at(ck, cloud_caster.global_position + Vector2(100, 0))
	cloud_caster.ability_manager.cast_completed.disconnect(cb)
	var overlay = null
	if not got.is_empty():
		for r in got[0]:
			if r is Dictionary and not r.get("created_objects", []).is_empty():
				overlay = r["created_objects"][0]
	var fm = game.get_node_or_null("FogManager")
	_check("conc.cloud-tracked", overlay is FogOverlay and not cloud_caster.active_concentrations.is_empty(), [overlay, cloud_caster.active_concentrations])
	cloud_caster.end_concentration("broken")
	_check("conc.cloud-dispelled", _gone(overlay) and (fm == null or not fm._active_fogs.has(overlay)))
	_despawn(cloud_caster)
	_despawn(enemy)
	await _frames(2)
