# res://tests/hostility_harness.gd
# Headless assertion harness for the Phase 1 hostility oracle
# (docs/law_crime_stealth_plan.md). Locks down:
#   1. FactionDatabase.are_hostile is symmetric for every faction pair.
#   2. The behaviour diff vs the old ai.gd fallthrough ("two distinct
#      non-neutral factions are hostile on sight") is EXACTLY the committed
#      pacification list — nothing new became hostile, and nothing was
#      pacified by accident.
#   3. ai._is_enemy agrees with the oracle for every pair (delegation intact).
#   4. Spot semantics: hostile_by_default, the neutral carve-out, the
#      player-neutral-with-guards edit, undefined-id tolerance.
# Run:  godot --headless --path . res://tests/hostility_harness.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

# Game.gd contract stubs — ai.gd resolves `game = get_tree().current_scene`,
# which is this harness when run as the CLI main scene.
var characters_in_scene: Array = []
var party_chars: Array = []
var items_in_scene: Array = []
var structures_in_scene: Array = []
var selected_characters: Array = []
var stealth_mode: bool = false

var failures := 0

# Every unordered pair the old fallthrough made hostile that the oracle now
# leaves peaceful. Regenerate deliberately (and re-review the diff) if
# factions.json relations change — this list IS the Phase 1 content decision.
const EXPECTED_PACIFIED: Array = [
	["adventurers_guild", "alamoneans"],
	["adventurers_guild", "dragatini"],
	["adventurers_guild", "golden_guard"],
	["adventurers_guild", "liziti"],
	["adventurers_guild", "patriciate"],
	["adventurers_guild", "player"],
	["adventurers_guild", "tortellini"],
	["adventurers_guild", "waldau"],
	["alamoneans", "dragatini"],
	["alamoneans", "golden_guard"],
	["alamoneans", "liziti"],
	["alamoneans", "patriciate"],
	["alamoneans", "player"],
	["alamoneans", "tortellini"],
	["alamoneans", "waldau"],
	["bandits", "pirates"],
	["cultists", "patriciate"],
	["dragatini", "golden_guard"],
	["dragatini", "liziti"],
	["dragatini", "patriciate"],
	["dragatini", "player"],
	["dragatini", "waldau"],
	["golden_guard", "player"],
	["golden_guard", "waldau"],
	["liziti", "patriciate"],
	["liziti", "player"],
	["liziti", "rebels"],
	["liziti", "tortellini"],
	["liziti", "waldau"],
	["patriciate", "player"],
	["patriciate", "tortellini"],
	["patriciate", "waldau"],
	["player", "tortellini"],
	["player", "waldau"],
	["tortellini", "undead"],
	["tortellini", "waldau"],
	["tortellini", "wildlife"],
]

func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])

func _ready() -> void:
	add_to_group("game")
	_case_database_loaded()
	_case_symmetry()
	_case_regression_diff()
	_case_spot_semantics()
	_case_undefined_ids()
	await _case_ai_agreement()
	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

# The predicate ai.gd:438 used before Phase 1, verbatim semantics.
func _old_hostile(a: String, b: String) -> bool:
	if a == b:
		return false
	return a != "neutral" and b != "neutral"

func _case_database_loaded() -> void:
	var ids: Array = FactionDatabase.get_all_faction_ids()
	_check("data.faction-count", ids.size() == 19, "got %d" % ids.size())
	_check("data.has-player", FactionDatabase.has_faction("player"))
	_check("data.has-neutral", FactionDatabase.has_faction("neutral"))

func _case_symmetry() -> void:
	var ids: Array = FactionDatabase.get_all_faction_ids()
	ids.append("spider_party")  # undefined id must not break symmetry either
	var asym := 0
	for a in ids:
		for b in ids:
			if FactionDatabase.are_hostile(a, b) != FactionDatabase.are_hostile(b, a):
				asym += 1
				if asym <= 3:
					print("  asymmetric pair: %s / %s" % [a, b])
	_check("oracle.symmetric", asym == 0, "%d asymmetric ordered pairs" % asym)

func _case_regression_diff() -> void:
	var ids: Array = FactionDatabase.get_all_faction_ids()
	ids.sort()
	var pacified: Array = []
	var newly_hostile: Array = []
	for i in range(ids.size()):
		for j in range(i + 1, ids.size()):
			var a: String = ids[i]
			var b: String = ids[j]
			var old_h := _old_hostile(a, b)
			var new_h: bool = FactionDatabase.are_hostile(a, b)
			if old_h and not new_h:
				pacified.append([a, b])
			elif new_h and not old_h:
				newly_hostile.append([a, b])
	_check("diff.no-new-hostility", newly_hostile.is_empty(), str(newly_hostile))
	var expected := EXPECTED_PACIFIED.duplicate()
	var missing: Array = []
	for pair in expected:
		if not pair in pacified:
			missing.append(pair)
	var unexpected: Array = []
	for pair in pacified:
		if not pair in expected:
			unexpected.append(pair)
	_check("diff.pacified-exact", missing.is_empty() and unexpected.is_empty(),
		"missing=%s unexpected=%s (pacified=%d expected=%d)" % [
			str(missing), str(unexpected), pacified.size(), expected.size()])

func _case_spot_semantics() -> void:
	# hostile_by_default reaches over the player branch (plan step 2 warning)
	_check("spot.wildlife-attacks-player", FactionDatabase.are_hostile("wildlife", "player"))
	_check("spot.bandits-attack-player", FactionDatabase.are_hostile("bandits", "player"))
	# ...but spares unaffiliated civilians (old predicate's neutral carve-out)
	_check("spot.wildlife-spares-neutral", not FactionDatabase.are_hostile("wildlife", "neutral"))
	_check("spot.bandits-spare-neutral", not FactionDatabase.are_hostile("bandits", "neutral"))
	# ...and spares explicit allies
	_check("spot.pirates-bandits-allied", not FactionDatabase.are_hostile("pirates", "bandits"))
	_check("spot.undead-tortellini-allied", not FactionDatabase.are_hostile("undead", "tortellini"))
	# Declared enmities survive, in both directions (are_enemies is one-way in data)
	_check("spot.liziti-guard-war", FactionDatabase.are_hostile("golden_guard", "liziti"))
	_check("spot.patriciate-guard-war", FactionDatabase.are_hostile("golden_guard", "patriciate"))
	# The user-directed edit: guards start NEUTRAL to the player, not allied
	_check("spot.guard-stance-neutral",
		FactionDatabase.player_stance_toward("golden_guard") == "neutral",
		FactionDatabase.player_stance_toward("golden_guard"))
	_check("spot.guard-not-hostile", not FactionDatabase.are_hostile("player", "golden_guard"))
	_check("spot.bandit-stance-hostile",
		FactionDatabase.player_stance_toward("bandits") == "hostile")
	# Phase 6 vocabulary: hostile | neutral | friendly. A declared ally
	# carries base +40, below friendly_at (50) — earn the rest.
	_check("spot.guild-stance-not-hostile",
		FactionDatabase.player_stance_toward("adventurers_guild") != "hostile")
	# are_friendly: same faction, or allied either direction
	_check("spot.friendly-same", FactionDatabase.are_friendly("liziti", "liziti"))
	_check("spot.friendly-oneway", FactionDatabase.are_friendly("patriciate", "cultists"))

func _case_undefined_ids() -> void:
	_check("undef.has-faction-false", not FactionDatabase.has_faction("spider_party"))
	_check("undef.peaceful", not FactionDatabase.are_hostile("spider_party", "player"))
	_check("undef.vs-neutral", not FactionDatabase.are_hostile("none", "neutral"))
	_check("undef.stance-neutral", FactionDatabase.player_stance_toward("druids") == "neutral")

# Two real ProceduralCharacters; sweep every pair through ai._is_enemy and
# assert it agrees with the oracle — this is the delegation regression test.
func _case_ai_agreement() -> void:
	var pc_a: ProceduralCharacter = PC_SCENE.instantiate()
	var pc_b: ProceduralCharacter = PC_SCENE.instantiate()
	add_child(pc_a)
	add_child(pc_b)
	pc_b.global_position = Vector2(200, 0)
	characters_in_scene = [pc_a, pc_b]
	await get_tree().process_frame
	var ai_a: Node = pc_a.get_node_or_null("AI")
	_check("ai.node-present", ai_a != null)
	if ai_a == null:
		return
	var ids: Array = FactionDatabase.get_all_faction_ids()
	var mismatches := 0
	for a in ids:
		for b in ids:
			pc_a.faction_id = a
			pc_b.faction_id = b
			var expect: bool = FactionDatabase.are_hostile(a, b)
			if ai_a._is_enemy(pc_b) != expect:
				mismatches += 1
				if mismatches <= 3:
					print("  ai mismatch: %s vs %s (oracle=%s)" % [a, b, expect])
	_check("ai.agrees-with-oracle", mismatches == 0, "%d mismatching pairs" % mismatches)
