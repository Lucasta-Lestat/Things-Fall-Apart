extends Node2D
# Rage: DR against physical damage AND bonus weapon damage, each equal to
# round(missing_hp / 15), tracking CURRENT missing HP rather than a cast-time
# snapshot. The live-tracking half is the crux — a stat_modifier could only ever
# freeze the value at apply time, which is why rage_bonus() is read at the two
# consumption sites instead.
# Headless-safe.  Run:  godot --headless --path . res://tests/rage_check.tscn
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

var fails := 0
var checks := 0

var characters_in_scene: Array = []
var structures_in_scene: Array = []


func _check(name: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if not ok:
		fails += 1
	print("%s %s %s" % ["PASS" if ok else "FAIL", name, detail])


func _spawn(pos: Vector2) -> ProceduralCharacter:
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	c.position = pos
	add_child(c)
	RaceDatabase.apply_race_to_character(c, "human", {"gender": "male"})
	characters_in_scene.append(c)
	return c


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	await get_tree().process_frame

	var c := _spawn(Vector2(200, 200))
	await get_tree().process_frame

	# --- the condition exists at all (it did not before: the ability applied an
	# unregistered "berserker_rage" and silently did nothing) -----------------
	_check("cond.rage-registered", ConditionManager.condition_registry.has("rage"))
	_check("cond.berserker_rage-gone", not ConditionManager.condition_registry.has("berserker_rage"))
	var tmpl = ConditionManager.condition_registry.get("rage")
	if tmpl != null:
		_check("cond.rage-is-buff", "traits" in tmpl and tmpl.traits.has("buff"),
			str(tmpl.traits if "traits" in tmpl else {}))

	# --- no rage, no bonus ----------------------------------------------------
	_check("off.no-bonus", c.rage_bonus() == 0, str(c.rage_bonus()))

	# --- rage on, at full HP the bonus is still 0 (nothing is missing) --------
	c.condition_manager.apply_condition("rage", null, 1, 60.0)
	await get_tree().process_frame
	_check("on.applied", c.condition_manager.has_active_condition("rage"))
	c.current_health = c.max_health
	_check("on.full-hp-zero-bonus", c.rage_bonus() == 0,
		"hp %d/%d -> %d" % [c.current_health, c.max_health, c.rage_bonus()])

	# --- THE CRUX: the bonus tracks CURRENT missing HP, live ------------------
	# A cast-time snapshot would stay at 0 for all of these.
	# Expressed as PERCENTAGES so the test doesn't silently re-tune itself if the
	# max_hp formula changes: +1 per full 20% missing, whatever max HP happens
	# to be.
	var seen: Array = []
	for pct_missing in [10, 20, 45, 60, 85]:
		c.current_health = maxi(1, c.max_health - int(round(c.max_health * pct_missing / 100.0)))
		var actual_missing: int = c.max_health - c.current_health
		var want: int = int(floor(float(actual_missing) / float(c.max_health) * 5.0))
		var got: int = c.rage_bonus()
		seen.append(got)
		_check("live.missing-%d%%" % pct_missing, got == want,
			"hp %d/%d, missing %d -> got %d, want %d"
			% [c.current_health, c.max_health, actual_missing, got, want])
	_check("live.bonus-actually-rises", seen.size() > 1 and seen[-1] > seen[0],
		str(seen))

	# The step lands exactly ON the fifth, not a hair before or after it.
	c.current_health = c.max_health - int(ceil(c.max_health * 0.20))
	_check("step.at-20pct-is-1", c.rage_bonus() == 1,
		"hp %d/%d -> %d" % [c.current_health, c.max_health, c.rage_bonus()])
	c.current_health = c.max_health - int(floor(c.max_health * 0.19))
	_check("step.just-under-20pct-is-0", c.rage_bonus() == 0,
		"hp %d/%d -> %d" % [c.current_health, c.max_health, c.rage_bonus()])

	# Ceiling: +5 needs 100% missing, which is death, so a living character
	# tops out at +4.
	c.current_health = 1
	_check("cap.alive-tops-out-at-4", c.rage_bonus() == 4,
		"hp 1/%d -> %d" % [c.max_health, c.rage_bonus()])

	# --- healing shrinks it again (not a one-way ratchet) ---------------------
	c.current_health = c.max_health
	_check("live.heal-restores-zero", c.rage_bonus() == 0, str(c.rage_bonus()))

	# --- never negative, even if HP somehow exceeds max ----------------------
	c.current_health = c.max_health + 20
	_check("guard.overheal-not-negative", c.rage_bonus() == 0, str(c.rage_bonus()))
	c.current_health = c.max_health

	# --- DR: physical damage is reduced while raging, non-physical is not ----
	# Compare a raging character against a non-raging twin taking the identical
	# hit at the identical missing HP, so armour and everything else cancel out.
	var twin := _spawn(Vector2(400, 200))
	await get_tree().process_frame
	# Half HP: enough missing for a non-zero bonus, but the character must stay
	# ALIVE — at 0 HP take_damage early-outs and both sides trivially lose 0,
	# which reads as a pass for the wrong reason.
	var wounded: int = maxi(2, c.max_health - 15)
	for pair in [["slashing", true], ["fire", false]]:
		var dtype: String = pair[0]
		var should_reduce: bool = pair[1]
		c.current_health = wounded
		twin.current_health = wounded
		var bonus: int = c.rage_bonus()
		c.take_damage({dtype: 12}, c.global_position, null)
		twin.take_damage({dtype: 12}, twin.global_position, null)
		var raged_lost: int = wounded - c.current_health
		var twin_lost: int = wounded - twin.current_health
		if should_reduce:
			_check("dr.%s-reduced" % dtype, raged_lost < twin_lost,
				"raging lost %d vs %d (bonus %d)" % [raged_lost, twin_lost, bonus])
		else:
			_check("dr.%s-unaffected" % dtype, raged_lost == twin_lost,
				"raging lost %d vs %d" % [raged_lost, twin_lost])

	# --- the offensive half reads the SAME helper ----------------------------
	# Both consumers must move together; a drift between them is the failure this
	# whole design exists to prevent.
	_check("api.single-helper", c.has_method("rage_bonus"))
	var game_src := FileAccess.get_file_as_string("res://Game.gd")
	_check("api.damage-site-uses-helper", game_src.find("rage_bonus()") != -1,
		"Game.gd must read rage_bonus() at the swing site")

	print("rage_check: %d checks, %d failures" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)
