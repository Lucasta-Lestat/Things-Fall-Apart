# res://tests/racial_ability_speed_test.gd
# Headless assertion harness for the two Djargo (grimalkin) regressions:
#
#   1. POUNCE WAS A NO-OP. Racial actives carry a school trait for
#      classification ("Primal": 1 on pounce/ram, "Occult": 1 on beguile), which
#      the cost gate reads as "costs 1 harmony". No playable race grants a school
#      TIER, so max_harmony is 0, the gate rejects the cast, and cast_failed goes
#      nowhere visible — the player sees the AoE preview and then nothing.
#      AbilityManager._is_innate_ability now exempts them.
#
#   2. DJARGO RUBBER-BANDED ALONG PLANNED PATHS. races.json states
#      `speed_modifier` in FEET off a 30ft base (grimalkin +5), but move_speed
#      and every ConditionDatabase entry treat it as a FRACTION of base speed —
#      so +5 meant a 6x sprint, and halfling's -5 meant NEGATIVE speed. At 6x a
#      body outruns the 8px waypoint spacing of a drawn tactical path, leaving
#      its own target behind it, and oscillates.
#
# Run: godot --headless --path . res://tests/racial_ability_speed_test.tscn
# Judge by PASS/FAIL lines, not exit code (pre-existing addon parse errors print
# noise; runs can flake exit 255 — rerun once).
extends Node2D

const ABILITY_MANAGER := preload("res://Abilities/AbilityManager.gd")
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

var failures := 0

# This node stands in for Game.gd (the scene root is named "Game" so the
# characters' `/root/Game` lookup finds it). The area sweep collects bodies from
# this list.
var characters_in_scene: Array = []

func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s %s" % [check_name, detail])
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])

func _approx(a: float, b: float) -> bool:
	return absf(a - b) < 0.0001

# Minimal stand-in for a ProceduralCharacter: the innate check only reads
# `race_id`, and building a real character needs the whole rig/scene stack.
class StubCaster:
	extends Node2D
	var race_id: String = ""

func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	await get_tree().process_frame

	_test_speed_modifier_units()
	_test_innate_ability_lookup()
	_test_harmful_effect_classification()
	await _test_live_djargo()
	await _test_self_centered_burst()

	if failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


# --- 2. Racial speed is a fraction of base walking speed, not raw feet --------
func _test_speed_modifier_units() -> void:
	var grimalkin: Dictionary = RaceDatabase.get_race_data("grimalkin")
	_check("grimalkin data still carries +5 feet",
		int(grimalkin.get("speed_modifier", 0)) == 5,
		"got %s" % str(grimalkin.get("speed_modifier")))

	# The conversion the loader applies. 5ft off a 30ft base = +16.7%, i.e. the
	# move_speed getter's (1.0 + bonus) becomes 1.167x — not 6x.
	var frac: float = 5.0 / RaceDatabase.BASE_WALK_SPEED_FEET
	_check("+5ft converts to a ~1.17x multiplier",
		_approx(1.0 + frac, 1.1666667),
		"got %f" % (1.0 + frac))

	# The sign case that used to make small races walk BACKWARD: (1.0 + -5).
	var halfling: Dictionary = RaceDatabase.get_race_data("halfling")
	var slow_frac: float = float(halfling.get("speed_modifier", 0)) / RaceDatabase.BASE_WALK_SPEED_FEET
	_check("halfling stays positive-speed",
		1.0 + slow_frac > 0.0,
		"multiplier %f" % (1.0 + slow_frac))

	# The 6x sprint is what outran the path. At the corrected multiplier a
	# grimalkin's per-frame step has to stay under the 8px spacing a drawn
	# tactical path samples at, or waypoints fall behind the body again.
	var dex := 80.0  # Djargo's 65 plus the grimalkin +15 ASI
	var speed: float = GridManager.TILE_SIZE * (0.7 + dex / 100.0) * (1.0 + frac)
	var step_per_frame: float = speed / 60.0
	_check("grimalkin step/frame stays under the 8px waypoint spacing",
		step_per_frame < TacticalPath.MIN_WAYPOINT_DISTANCE,
		"%.2f px/frame at %.1f px/s" % [step_per_frame, speed])


# --- 1. Racial actives bypass the school-resource gate -----------------------
func _test_innate_ability_lookup() -> void:
	var mgr := ABILITY_MANAGER.new()
	var caster := StubCaster.new()
	caster.race_id = "grimalkin"
	add_child(caster)
	# Parent the manager to the caster: its _ready re-resolves `character` from
	# character_path ("..") and would otherwise overwrite anything set here.
	caster.add_child(mgr)

	var pounce := Ability.from_dict(AbilityDatabase.get_ability_data("pounce"))
	_check("pounce still tagged Primal (so the gate would have eaten it)",
		int(pounce.traits.get("Primal", 0)) > 0,
		"traits %s" % str(pounce.traits))
	_check("pounce is innate for a grimalkin",
		mgr._is_innate_ability(pounce))

	# ram is the goatmen's, not the grimalkin's — innateness must be per-race,
	# not "any racial ability anywhere".
	var ram := Ability.from_dict(AbilityDatabase.get_ability_data("ram"))
	_check("ram is NOT innate for a grimalkin",
		not mgr._is_innate_ability(ram))

	caster.race_id = "goatmen"
	_check("ram IS innate for a goatman",
		mgr._is_innate_ability(ram))

	# A learned spell must keep paying, whatever the caster's race.
	var learned := Ability.from_dict({"id": "fireball", "traits": {"Arcane": 2}})
	_check("a learned spell is not innate",
		not mgr._is_innate_ability(learned))

	caster.race_id = ""
	_check("a raceless caster has no innate abilities",
		not mgr._is_innate_ability(pounce))

	caster.queue_free()


# --- Pounce's self-centred claw burst must not shred its own caster ----------
func _test_harmful_effect_classification() -> void:
	var pounce_step: Array = AbilityDatabase.get_ability_data("pounce").get("steps", [])
	_check("pounce's damage step is self-centred",
		pounce_step.size() >= 2 \
			and String(pounce_step[1].get("targeting", {}).get("type", "")) == "self",
		"steps %s" % str(pounce_step))
	_check("pounce's damage step reads as harmful (caster excluded)",
		ABILITY_MANAGER._harms_targets(pounce_step[1].get("effects", [])))

	_check("a self-centred heal still includes its caster",
		not ABILITY_MANAGER._harms_targets([{"type": "healing", "healing": 10}]))
	_check("a mixed harm+help burst still includes its caster",
		not ABILITY_MANAGER._harms_targets([
			{"type": "damage", "damage": {"force": 5}},
			{"type": "healing", "healing": 10}]))
	_check("an empty step is not 'harmful'",
		not ABILITY_MANAGER._harms_targets([]))


# --- The real Djargo, built the way Game._spawn_character builds him ---------
func _test_live_djargo() -> void:
	var djargo: ProceduralCharacter = CHAR_SCENE.instantiate()
	add_child(djargo)
	TopDownCharacterDatabase.build_character(djargo, "djargo")
	await get_tree().process_frame

	_check("djargo is a grimalkin", djargo.race_id == "grimalkin",
		"race_id=%s" % djargo.race_id)

	# The reason pounce was dead: no playable race grants a Primal TIER, so the
	# harmony pool a Primal-tagged ability draws on is size zero.
	_check("djargo has no harmony pool at all", djargo.max_harmony == 0,
		"max_harmony=%d traits=%s" % [djargo.max_harmony, str(djargo.traits)])

	var pounce := Ability.from_dict(AbilityDatabase.get_ability_data("pounce"))
	_check("pounce would cost harmony he cannot have",
		ABILITY_MANAGER.school_costs_for(pounce).get("harmony", 0) > 0,
		"costs=%s" % str(ABILITY_MANAGER.school_costs_for(pounce)))

	var mgr = djargo.ability_manager
	_check("djargo has an AbilityManager", mgr != null)
	if mgr != null:
		var verdict: Dictionary = mgr._check_ability_usable(pounce)
		_check("pounce now passes the usability gate", verdict.get("success", false),
			"reason=%s" % str(verdict.get("reason", "")))
		_check("pounce's costs are waived rather than failing to pay",
			mgr._pay_ability_costs(pounce))
		_check("pounce is multi-step (dash then claw)", pounce.is_multi_step(),
			"steps=%d" % pounce.steps.size())

	# Racial speed survives the first stat recalculation. This used to zero out
	# the moment any condition touched the character.
	var speed_before: float = djargo.move_speed
	djargo._on_stats_recalculated()
	_check("racial speed survives a stat recalculation",
		_approx(djargo.move_speed, speed_before),
		"%.2f -> %.2f" % [speed_before, djargo.move_speed])

	# Sanity bound: the 6x bug put him at ~500px/s, over 8px per 60Hz frame and
	# past the 8px spacing of a drawn path. A believable walk is a couple of
	# tiles a second.
	_check("djargo walks at a sane speed",
		djargo.move_speed > 0.0 and djargo.move_speed < 3.0 * GridManager.TILE_SIZE,
		"%.1f px/s (%.2f tiles/s)" % [djargo.move_speed, djargo.move_speed / GridManager.TILE_SIZE])
	_check("djargo's per-frame step stays inside the path's waypoint spacing",
		djargo.move_speed / 60.0 < TacticalPath.MIN_WAYPOINT_DISTANCE,
		"%.2f px/frame" % (djargo.move_speed / 60.0))

	djargo.queue_free()


# --- Repulsion Wave: "self" meaning "out of me", not "only me" ---------------
# The area sweep used to short-circuit to [self] for ANY targeting.type "self",
# so a 100px shockwave shoved and damaged nobody but the person casting it.
func _test_self_centered_burst() -> void:
	var caster: ProceduralCharacter = CHAR_SCENE.instantiate()
	caster.position = Vector2(600, 600)
	add_child(caster)
	TopDownCharacterDatabase.build_character(caster, "djargo")

	var bystander: ProceduralCharacter = CHAR_SCENE.instantiate()
	bystander.position = Vector2(660, 600)   # 60px out — inside the 100px ring
	add_child(bystander)
	TopDownCharacterDatabase.build_character(bystander, "djargo")

	var far_off: ProceduralCharacter = CHAR_SCENE.instantiate()
	far_off.position = Vector2(900, 600)     # 300px out — well outside it
	add_child(far_off)
	TopDownCharacterDatabase.build_character(far_off, "djargo")
	await get_tree().process_frame

	# The harness itself is the "game" node the sweep collects bodies from.
	characters_in_scene = [caster, bystander, far_off]

	var wave := Ability.from_dict(AbilityDatabase.get_ability_data("repulsion_wave"))
	_check("repulsion_wave is a self-centred ring",
		String(wave.targeting.get("type", "")) == "self" and float(wave.targeting.get("radius", 0.0)) > 0.0,
		"targeting=%s" % str(wave.targeting))

	var hit: Array = caster._find_targets_in_area(wave, caster.global_position)
	_check("the wave reaches a bystander inside the ring", bystander in hit,
		"hit %d bodies" % hit.size())
	_check("the wave stops at the ring's edge", not (far_off in hit),
		"hit %d bodies" % hit.size())

	# Geometry still includes the caster (they are at the centre); it's the
	# effect layer that spares them, because the wave only ever harms.
	_check("the caster is spared by the effect layer",
		AbilityManager._is_self_centered(wave.targeting) and AbilityManager._harms_targets(wave.effects))

	# ...and Force March, the other reading of "self", is untouched: no ring at
	# all, so it still resolves onto the caster alone.
	var march := Ability.from_dict(AbilityDatabase.get_ability_data("force_march"))
	var march_hit: Array = caster._find_targets_in_area(march, caster.global_position)
	_check("force_march still lands on its caster only",
		march_hit.size() == 1 and march_hit[0] == caster,
		"hit %s" % str(march_hit.size()))
	_check("force_march is not treated as a harmful burst",
		not AbilityManager._harms_targets(march.effects))

	# Rage/Bide use shape none/single with no radius — the "single" arm is a 50px
	# proximity sweep, so falling through would have grabbed the bystander.
	var rage := Ability.from_dict(AbilityDatabase.get_ability_data("rage"))
	var rage_hit: Array = caster._find_targets_in_area(rage, caster.global_position)
	_check("rage still buffs only its caster",
		rage_hit.size() == 1 and rage_hit[0] == caster,
		"hit %d" % rage_hit.size())

	characters_in_scene = []
	caster.queue_free()
	bystander.queue_free()
	far_off.queue_free()
