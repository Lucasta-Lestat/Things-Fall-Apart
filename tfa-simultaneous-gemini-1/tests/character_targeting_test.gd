# res://tests/character_targeting_test.gd
# Headless assertion harness for designated-character targeting ("anchors").
# Run:  godot --headless --path . res://tests/character_targeting_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (pre-existing parse errors
# print noise; runs can flake exit 255 — rerun once).
#
# Covers the two predicates that encode the design decisions:
#   AbilityManager.ability_follows_anchor — which abilities re-aim vs. stay put
#   AbilityManager._anchored_position     — best-effort re-aim with ground fallback
# and AbilityTargeting._is_single_target_ability, which has to read the NESTED
# targeting block because the flattened one cannot express "single".
extends Node2D

const ABILITY_MANAGER := preload("res://Abilities/AbilityManager.gd")
const ABILITY_TARGETING := preload("res://Abilities/AbilityTargeting.gd")

var failures := 0

# Stands in for a ProceduralCharacter as an anchor: has global_position and the
# is_alive() the fallback rules key off.
class StubTarget:
	extends Node2D
	var alive := true
	func is_alive() -> bool:
		return alive

func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])

func _ability(shape: String, type: String = "point", projectile: String = "") -> Ability:
	return Ability.from_dict({
		"id": "test_%s" % shape,
		"targeting": {"type": type, "shape": shape, "radius": 40.0},
		"visuals": {"projectile": projectile} if projectile != "" else {},
	})

func _ready() -> void:
	_case_follows_anchor()
	_case_anchored_position()
	_case_single_target_detection()

	if failures == 0:
		print("ALL PASS")
	else:
		print("%d FAILURE(S)" % failures)
	get_tree().quit(1 if failures > 0 else 0)


# Which abilities let a designated character move their aim point.
func _case_follows_anchor() -> void:
	_check("single-target follows anchor",
		ABILITY_MANAGER.ability_follows_anchor(_ability("single", "target")))
	_check("unshaped follows anchor",
		ABILITY_MANAGER.ability_follows_anchor(_ability("none", "point")))

	# The carve-out the user asked for: aiming an AoE at a patch of ground is
	# the point of aiming one, so it must not chase a character.
	_check("ground circle AoE does NOT follow anchor",
		not ABILITY_MANAGER.ability_follows_anchor(_ability("circle", "point")))
	_check("cone does NOT follow anchor",
		not ABILITY_MANAGER.ability_follows_anchor(_ability("cone", "direction")))
	_check("line does NOT follow anchor",
		not ABILITY_MANAGER.ability_follows_anchor(_ability("line", "direction")))

	# ...unless it has a projectile to fly, which should leave the caster
	# pointed at where the target actually is. Splash still lands on impact.
	_check("projectile AoE DOES follow anchor",
		ABILITY_MANAGER.ability_follows_anchor(_ability("circle", "point", "res://vfx/fake.tscn")))

	# Explicitly-picked character abilities (hitch, fatal_attraction) bind their
	# effects by reference already; following keeps their visuals on the target.
	_check("characters-pick follows anchor",
		ABILITY_MANAGER.ability_follows_anchor(_ability("characters", "characters")))


# Best-effort re-aim: live target wins, everything else degrades to the
# originally-clicked point rather than fizzling.
func _case_anchored_position() -> void:
	var mgr = ABILITY_MANAGER.new()
	var planned := Vector2(100, 100)

	var target := StubTarget.new()
	add_child(target)
	target.global_position = Vector2(400, 250)

	var single := _ability("single", "target")
	var aoe := _ability("circle", "point")

	_check("live anchor re-aims to its current position",
		mgr._anchored_position(single, target, planned) == Vector2(400, 250))

	_check("no anchor keeps the planned point",
		mgr._anchored_position(single, null, planned) == planned)

	# Corpses deliberately stay in the scene (law/crime system), so validity
	# alone is not enough — a dead anchor must fall back, not steer onto a body.
	target.alive = false
	_check("dead anchor falls back to the planned point",
		mgr._anchored_position(single, target, planned) == planned)
	target.alive = true

	_check("AoE ignores its anchor and keeps the planned point",
		mgr._anchored_position(aoe, target, planned) == planned)

	var freed := StubTarget.new()
	add_child(freed)
	remove_child(freed)
	freed.free()
	_check("freed anchor falls back to the planned point",
		mgr._anchored_position(single, freed, planned) == planned)

	target.queue_free()
	mgr.free()


# The flattened dict collapses "single" to "none" (AbilityTargetShape has no
# SINGLE member), so detection must read the nested block or every single-target
# spell silently stays a 50px proximity sweep.
func _case_single_target_detection() -> void:
	var targeting = ABILITY_TARGETING.new()

	targeting.current_ability = {
		"target_shape": "none",  # what flattening produces — deliberately misleading
		"targeting": {"type": "target", "shape": "single"},
	}
	_check("single detected from nested block despite flattened 'none'",
		targeting._is_single_target_ability())

	targeting.current_ability = {"targeting": {"type": "point", "shape": "circle"}}
	_check("circle AoE is not single-target",
		not targeting._is_single_target_ability())

	# Self-buffs must never pick up a designation: binding one to an explicit
	# `targets` array bypasses _find_targets_in_area's `type == "self" -> [self]`
	# override, handing the buff to a bystander and leaving the caster with
	# nothing. Both authored spellings must be rejected — the "single" one is the
	# real-world case (bide, test_animal_magnetism, rain, acid_rain,
	# freezing_rain are all {"type":"self","shape":"single"}).
	targeting.current_ability = {"targeting": {"type": "self", "shape": "none"}}
	_check("self ability (shape none) is not single-target",
		not targeting._is_single_target_ability())

	targeting.current_ability = {"targeting": {"type": "self", "shape": "single"}}
	_check("self ability (shape single) is not single-target",
		not targeting._is_single_target_ability())

	# The anchor gate the planning leash keys off: recording an anchor the
	# executor ignores would draw a tracking line for a fixed-point detonation.
	targeting.current_ability = {"targeting": {"type": "point", "shape": "circle"}, "visuals": {}}
	_check("ground AoE does not record an anchor",
		not targeting._ability_follows_anchor())

	targeting.current_ability = {"targeting": {"type": "target", "shape": "single"}, "visuals": {}}
	_check("single-target records an anchor",
		targeting._ability_follows_anchor())

	targeting.current_ability = {"targeting": {"type": "characters", "shape": "characters"}, "visuals": {}}
	_check("characters-pick records an anchor",
		targeting._ability_follows_anchor())

	targeting.current_ability = {"targeting": {"type": "point", "shape": "circle"}, "visuals": {"projectile": "res://x.tscn"}}
	_check("projectile AoE records an anchor",
		targeting._ability_follows_anchor())

	targeting.free()
