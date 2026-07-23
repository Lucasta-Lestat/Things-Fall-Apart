# res://tests/silence_zone_test.gd
# Headless assertion harness for sound-suppression zones (the Silence spell).
# Run:  godot --headless --path . res://tests/silence_zone_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (pre-existing parse errors
# print noise; runs can flake exit 255 — rerun once).
extends Node2D

# HearingManager._get_game() resolves get_tree().current_scene, which in this
# harness is this node. These two mirror Game.gd's contract.
var characters_in_scene: Array = []
var party_chars: Array = []

var failures := 0
var checks_run := 0

# A script error inside a case aborts that case but not the harness, so a
# silently skipped case would otherwise still print failures=0. Assert the
# count so vanished checks fail loudly instead of reading as green.
const EXPECTED_CHECKS := 28

# AbilityEffect._get_game_scene sniffs for these two methods to decide which
# node is the Game. Present so the JSON->effect->zone path can be exercised.
func create_item(_id, _pos, _count = 1):
	return null

func _spawn_character(_id, _pos, _overrides = {}):
	return null

# Minimal stand-in for ProceduralCharacter as HearingManager sees it. Note it
# is deliberately NOT a ProceduralCharacter: HearingManager only reads
# faction_id off real characters, so a stub source has no faction and skips
# the enemies-only gate, which keeps these cases about sound alone.
class StubChar:
	extends Node2D
	var hearing: float = 1.0
	func is_alive() -> bool:
		return true
	func effective_hearing() -> float:
		return hearing

class StubAI:
	extends Node
	var heard_count: int = 0
	var last_loudness: float = 0.0
	# Mirrors ai.gd's signature: Phase 5 added channel + payload (the alarm
	# pipeline); HearingManager passes all five.
	func on_sound_heard(_world_pos: Vector2, loudness: float, _source = null,
			_channel: String = "ambient", _payload: Dictionary = {}) -> void:
		heard_count += 1
		last_loudness = loudness


func _check(check_name: String, cond: bool, detail: String = "") -> void:
	checks_run += 1
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])


func _ready() -> void:
	_case_segment_geometry()
	_case_gain_is_multiplicative()
	_case_strongest_zone_wins()
	_case_emit_suppressed_end_to_end()
	_case_unregister_on_free()
	_case_clear_sound_zones()
	_case_ability_json_end_to_end()
	if checks_run != EXPECTED_CHECKS:
		failures += 1
		print("FAIL check_count: ran %d checks, expected %d — a case aborted early" % [
			checks_run, EXPECTED_CHECKS
		])
	print("HARNESS DONE failures=%d checks=%d" % [failures, checks_run])
	get_tree().quit(1 if failures > 0 else 0)


func _make_zone(pos: Vector2, radius: float, gain: float = 0.0) -> SilenceZone:
	var zone := SilenceZone.new()
	zone.radius = radius
	zone.gain = gain
	zone.duration = 0.0  # never self-expires during the test
	add_child(zone)
	zone.global_position = pos
	return zone


# A zone is dead air, not a wall: sound born inside, sound heard inside, and
# sound merely crossing it are all suppressed. All three come from the one
# segment test, so all three are asserted here.
func _case_segment_geometry() -> void:
	var zone := _make_zone(Vector2(0, 0), 100.0)

	_check("inside_to_inside",
		HearingManager.sound_gain_between(Vector2(10, 0), Vector2(-10, 0)) == 0.0,
		"a sound made and heard inside the zone must be silent")
	_check("inside_to_outside",
		HearingManager.sound_gain_between(Vector2(0, 0), Vector2(500, 0)) == 0.0,
		"a sound made inside must not escape")
	_check("outside_to_inside",
		HearingManager.sound_gain_between(Vector2(500, 0), Vector2(0, 0)) == 0.0,
		"a listener inside must not hear the world outside")
	_check("crossing_the_zone",
		HearingManager.sound_gain_between(Vector2(-500, 0), Vector2(500, 0)) == 0.0,
		"a sound whose path crosses the zone must be damped in passing")
	_check("clear_of_the_zone",
		HearingManager.sound_gain_between(Vector2(-500, 400), Vector2(500, 400)) == 1.0,
		"a path that misses the zone must be untouched")
	_check("grazing_outside_radius",
		HearingManager.sound_gain_between(Vector2(-500, 101), Vector2(500, 101)) == 1.0,
		"a path just outside the radius must be untouched")
	_check("point_query_inside",
		HearingManager.sound_gain_at(Vector2(50, 50)) == 0.0,
		"point query inside the zone must be silent")
	_check("point_query_outside",
		HearingManager.sound_gain_at(Vector2(500, 500)) == 1.0,
		"point query outside the zone must be untouched")

	zone.queue_free()
	HearingManager.clear_sound_zones()


# Gain is a multiplier, not a flag — that is what lets the same zone express
# a muffling cave as well as total silence.
func _case_gain_is_multiplicative() -> void:
	var zone := _make_zone(Vector2(0, 0), 100.0, 0.25)
	_check("partial_gain_reported",
		is_equal_approx(HearingManager.sound_gain_between(Vector2(0, 0), Vector2(0, 0)), 0.25),
		"a muffling zone must report its gain, not 0")
	_check("partial_gain_outside",
		HearingManager.sound_gain_at(Vector2(400, 0)) == 1.0,
		"a muffling zone must not affect paths outside it")
	zone.queue_free()
	HearingManager.clear_sound_zones()


# Overlapping zones must not compound: two half-muffles are still a half-muffle,
# otherwise stacking zones would quietly become stronger than any of them.
func _case_strongest_zone_wins() -> void:
	var a := _make_zone(Vector2(0, 0), 100.0, 0.5)
	var b := _make_zone(Vector2(20, 0), 100.0, 0.5)
	_check("overlap_does_not_compound",
		is_equal_approx(HearingManager.sound_gain_at(Vector2(10, 0)), 0.5),
		"two 0.5 zones must give 0.5, not 0.25")
	var c := _make_zone(Vector2(10, 0), 100.0, 0.1)
	_check("quietest_zone_wins",
		is_equal_approx(HearingManager.sound_gain_at(Vector2(10, 0)), 0.1),
		"the strongest suppressor must win")
	a.queue_free()
	b.queue_free()
	c.queue_free()
	HearingManager.clear_sound_zones()


# The whole point: HearingManager.emit must stop reaching AI listeners.
func _case_emit_suppressed_end_to_end() -> void:
	var listener := StubChar.new()
	var ai := StubAI.new()
	ai.name = "AI"
	listener.add_child(ai)
	add_child(listener)
	listener.global_position = Vector2(120, 0)
	characters_in_scene = [listener]

	# Baseline: a loud sound close by is heard.
	HearingManager.emit(Vector2(0, 0), 1.0, null)
	_check("baseline_sound_heard",
		ai.heard_count == 1,
		"expected the listener to hear an unsuppressed sound, heard_count=%d" % ai.heard_count)

	# Same sound, now with the emitter smothered.
	var zone := _make_zone(Vector2(0, 0), 60.0)
	HearingManager.emit(Vector2(0, 0), 1.0, null)
	_check("silenced_sound_not_heard",
		ai.heard_count == 1,
		"a silenced sound must not reach the AI, heard_count=%d" % ai.heard_count)

	# And with the listener smothered instead of the emitter.
	zone.global_position = Vector2(120, 0)
	HearingManager.emit(Vector2(600, 0), 1.5, null)
	_check("deaf_listener_hears_nothing",
		ai.heard_count == 1,
		"a listener inside the zone must be deaf, heard_count=%d" % ai.heard_count)

	# Removing the zone restores hearing — suppression must not be sticky.
	HearingManager.clear_sound_zones()
	HearingManager.emit(Vector2(0, 0), 1.0, null)
	_check("hearing_restored_after_zone_gone",
		ai.heard_count == 2,
		"hearing must resume once the zone is gone, heard_count=%d" % ai.heard_count)

	characters_in_scene = []
	listener.queue_free()


# A freed zone must deregister itself, or HearingManager would keep silencing
# the map from a dangling entry.
func _case_unregister_on_free() -> void:
	var zone := _make_zone(Vector2(0, 0), 100.0)
	_check("zone_active_while_alive",
		HearingManager.sound_gain_at(Vector2.ZERO) == 0.0,
		"zone should suppress while in the tree")
	remove_child(zone)
	zone.free()
	_check("zone_inactive_after_free",
		HearingManager.sound_gain_at(Vector2.ZERO) == 1.0,
		"a freed zone must stop suppressing")


# Map unload calls this; it must both free the nodes and empty the registry.
func _case_clear_sound_zones() -> void:
	var zone := _make_zone(Vector2(0, 0), 100.0)
	HearingManager.clear_sound_zones()
	_check("clear_empties_registry",
		HearingManager.sound_gain_at(Vector2.ZERO) == 1.0,
		"clear_sound_zones must stop all suppression")
	_check("clear_frees_the_node",
		not is_instance_valid(zone) or zone.is_queued_for_deletion(),
		"clear_sound_zones must free the zone node so it cannot leak across maps")


# The authored ability all the way through: JSON -> Ability -> effect resolver
# -> a live zone that actually silences.
func _case_ability_json_end_to_end() -> void:
	var data: Dictionary = AbilityDatabase.get_ability_data("silence")
	_check("ability_in_database",
		not data.is_empty(),
		"silence must be present in data/Abilities.json")
	if data.is_empty():
		return

	var ability := Ability.from_dict(data)
	_check("ability_icon_loads",
		ability.icon != null,
		"res://UI/UI Icons/ability_silence.png must exist and import")
	_check("ability_is_occult",
		int(ability.traits.get("Occult", 0)) > 0,
		"silence must cost Occult souls like its school-mates")
	_check("ability_targets_a_point",
		String(ability.targeting.get("type", "")) == "point",
		"silence is ground-targeted")

	var caster := StubChar.new()
	add_child(caster)
	caster.global_position = Vector2.ZERO

	var result: Dictionary = AbilityEffect.resolve_effect(
		ability.effects[0], caster, [], ability, Vector2(300, 300)
	)
	_check("effect_resolves",
		bool(result.get("success", false)),
		"sound_zone effect failed: %s" % str(result.get("error", "")))
	_check("effect_creates_a_zone",
		(result.get("created_objects", []) as Array).size() == 1,
		"the effect must create exactly one zone")
	_check("zone_silences_where_cast",
		HearingManager.sound_gain_at(Vector2(300, 300)) == 0.0,
		"the cast zone must silence its target position")
	_check("zone_leaves_the_rest_alone",
		HearingManager.sound_gain_at(Vector2(-800, -800)) == 1.0,
		"the cast zone must not silence the whole map")

	HearingManager.clear_sound_zones()
	caster.queue_free()
