# res://tests/law_data_test.gd
# Headless assertion harness for Phase 3 — statutes, jurisdiction, and the
# pure resolver (docs/law_crime_stealth_plan.md). Pure data checks: no scene
# stubs, no characters. The acceptance test for the whole design is the pair:
#   evaluate("liziti_custom",           "cast", creepy_beam) == {}        (legal in Perrow)
#   evaluate("waldau_rationalist_code", "cast", creepy_beam) == necromancy (a crime in Waldau)
# Run:  godot --headless --path . res://tests/law_data_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

var failures := 0

func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])

func _ready() -> void:
	_case_loaded()
	_case_codes_resolve()
	_case_flatten()
	_case_acceptance_pair()
	_case_purity_and_verbs()
	_case_tier_rule()
	_case_severity_precedence()
	_case_property_and_person()
	_case_enforcement()
	_case_jurisdiction()
	_case_surrender_profiles()
	_case_service_legality_regression()
	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

# creepy_beam's shipped traits (data/Abilities.json): necrotic 3, Occult 2.
func _creepy_beam() -> Dictionary:
	return {"traits": {"necrotic": 3, "Occult": 2}}

func _case_loaded() -> void:
	_check("law.loaded", LawDatabase.loaded)
	_check("law.statute-count", LawDatabase.flattened_code("common_law").size() == 4,
		str(LawDatabase.flattened_code("common_law")))

func _case_codes_resolve() -> void:
	var bad: Array = []
	for faction_id in FactionDatabase.get_all_faction_ids():
		var code: String = LawDatabase.code_for_faction(faction_id)
		if code != "" and LawDatabase.flattened_code(code).is_empty() and code != "none":
			bad.append("%s->%s" % [faction_id, code])
	_check("law.every-faction-code-resolves", bad.is_empty(), str(bad))
	_check("law.default-code-applies", LawDatabase.code_for_faction("alamoneans") == "common_law",
		LawDatabase.code_for_faction("alamoneans"))
	_check("law.unknown-faction-lawless", LawDatabase.code_for_faction("spider_party") == "")

func _case_flatten() -> void:
	var waldau: Dictionary = LawDatabase.flattened_code("waldau_rationalist_code")
	_check("flatten.waldau-necromancy-90", int(waldau.get("necromancy", -1)) == 90, str(waldau))
	_check("flatten.waldau-theft-override-40", int(waldau.get("theft", -1)) == 40, str(waldau))
	_check("flatten.waldau-inherits-murder", int(waldau.get("murder", -1)) == 90)
	var liziti: Dictionary = LawDatabase.flattened_code("liziti_custom")
	_check("flatten.liziti-repeals-assault", not liziti.has("assault"), str(liziti))
	_check("flatten.liziti-inherits-murder", int(liziti.get("murder", -1)) == 90)
	var martial: Dictionary = LawDatabase.flattened_code("golden_guard_martial_law")
	_check("flatten.martial-two-level-extends",
		int(martial.get("burglary", -1)) == 55 and int(martial.get("assault", -1)) == 55
		and martial.has("occultism"), str(martial))

func _case_acceptance_pair() -> void:
	var payload: Dictionary = _creepy_beam()
	payload["law_faction"] = "liziti"
	var in_perrow: Dictionary = LawDatabase.evaluate("liziti_custom", "cast", payload)
	payload["law_faction"] = "waldau"
	var in_waldau: Dictionary = LawDatabase.evaluate("waldau_rationalist_code", "cast", payload)
	_check("accept.necromancy-legal-in-perrow", in_perrow.is_empty(), str(in_perrow))
	_check("accept.necromancy-crime-in-waldau",
		str(in_waldau.get("statute", "")) == "necromancy" and int(in_waldau.get("severity", 0)) == 90,
		str(in_waldau))
	_check("accept.verdict-carries-law-faction", str(in_waldau.get("law_faction", "")) == "waldau")

func _case_purity_and_verbs() -> void:
	var payload: Dictionary = _creepy_beam()
	payload["law_faction"] = "waldau"
	var first: Dictionary = LawDatabase.evaluate("waldau_rationalist_code", "cast", payload)
	var second: Dictionary = LawDatabase.evaluate("waldau_rationalist_code", "cast", payload)
	_check("pure.same-payload-same-verdict", first == second)
	_check("pure.verb-gated", LawDatabase.evaluate("waldau_rationalist_code", "take", payload).is_empty(),
		"cast payload must not match take statutes")

func _case_tier_rule() -> void:
	# test_confused authors "Occult": 0 — key presence must NOT criminalise it.
	var zero: Dictionary = {"law_faction": "golden_guard", "traits": {"Occult": 0}}
	var one: Dictionary = {"law_faction": "golden_guard", "traits": {"Occult": 1}}
	_check("tier.zero-tier-not-a-crime",
		LawDatabase.evaluate("golden_guard_martial_law", "cast", zero).is_empty())
	var verdict: Dictionary = LawDatabase.evaluate("golden_guard_martial_law", "cast", one)
	_check("tier.tier-one-is", str(verdict.get("statute", "")) == "occultism", str(verdict))

func _case_severity_precedence() -> void:
	# necrotic(90) + charm(40) together: highest severity wins, order-free.
	var payload: Dictionary = {"law_faction": "waldau", "traits": {"necrotic": 1, "charm": 1}}
	var verdict: Dictionary = LawDatabase.evaluate("waldau_rationalist_code", "cast", payload)
	_check("severity.highest-wins", str(verdict.get("statute", "")) == "necromancy", str(verdict))

func _case_property_and_person() -> void:
	# theft: owner "law_faction" = owner under the law faction's protection.
	var owned: Dictionary = {"law_faction": "liziti", "owner_faction": "liziti"}
	var unowned: Dictionary = {"law_faction": "liziti", "owner_faction": ""}
	var outlaw_stash: Dictionary = {"law_faction": "liziti", "owner_faction": "bandits"}
	var guard_property: Dictionary = {"law_faction": "liziti", "owner_faction": "golden_guard"}
	_check("theft.own-jurisdiction", str(LawDatabase.evaluate("common_law", "take", owned).get("statute", "")) == "theft")
	_check("theft.unowned-is-legal", LawDatabase.evaluate("common_law", "take", unowned).is_empty())
	_check("theft.outlaw-stash-is-legal", LawDatabase.evaluate("common_law", "take", outlaw_stash).is_empty())
	# liziti and golden_guard are declared enemies (mob rule) — guard property
	# is NOT under liziti protection. Documented consequence of the
	# protection-via-hostility rule.
	_check("theft.enemy-faction-property-unprotected",
		LawDatabase.evaluate("common_law", "take", guard_property).is_empty())
	# assault/murder: victim protection + the self-defence carve-out.
	var civilian_lethal: Dictionary = {"law_faction": "liziti", "victim_faction": "neutral",
		"victim_hostile_to_actor": false, "lethal": true}
	var civilian_brawl: Dictionary = {"law_faction": "liziti", "victim_faction": "neutral",
		"victim_hostile_to_actor": false, "lethal": false}
	var self_defence: Dictionary = {"law_faction": "liziti", "victim_faction": "neutral",
		"victim_hostile_to_actor": true, "lethal": true}
	var wolf: Dictionary = {"law_faction": "liziti", "victim_faction": "wildlife",
		"victim_hostile_to_actor": false, "lethal": true}
	_check("murder.civilian", str(LawDatabase.evaluate("common_law", "attack", civilian_lethal).get("statute", "")) == "murder")
	_check("assault.civilian", str(LawDatabase.evaluate("common_law", "attack", civilian_brawl).get("statute", "")) == "assault")
	_check("assault.repealed-in-perrow",
		LawDatabase.evaluate("liziti_custom", "attack", civilian_brawl).is_empty(),
		"duelling is a private matter")
	_check("murder.not-repealed-in-perrow",
		str(LawDatabase.evaluate("liziti_custom", "attack", civilian_lethal).get("statute", "")) == "murder",
		"killing is not")
	_check("murder.self-defence-carve-out", LawDatabase.evaluate("common_law", "attack", self_defence).is_empty())
	_check("murder.wolf-is-legal", LawDatabase.evaluate("common_law", "attack", wolf).is_empty())

func _case_enforcement() -> void:
	_check("enforce.guards-police-perrow", LawDatabase.enforces("golden_guard", "liziti"))
	_check("enforce.liziti-police-themselves", LawDatabase.enforces("liziti", "liziti"))
	_check("enforce.bandits-do-not", not LawDatabase.enforces("bandits", "liziti"))
	_check("enforce.default-self-policing", LawDatabase.enforces("alamoneans", "alamoneans"),
		"policed_by defaults to [law_faction]")

func _case_jurisdiction() -> void:
	_check("jur.town-square-is-liziti", LawDatabase.jurisdiction_for_map("town_square") == "liziti",
		LawDatabase.jurisdiction_for_map("town_square"))
	# Per-map controlling_faction override wins over the region. No shipped
	# map authors one yet, so inject a synthetic map and clean up after.
	MapDatabase._maps["__law_test_map"] = {"id": "__law_test_map", "controlling_faction": "waldau"}
	_check("jur.map-override-wins", LawDatabase.jurisdiction_for_map("__law_test_map") == "waldau")
	MapDatabase._maps.erase("__law_test_map")
	_check("jur.empty-map-lawless", LawDatabase.jurisdiction_for_map("") == "")

func _case_surrender_profiles() -> void:
	var guard: Dictionary = LawDatabase.surrender_profile("golden_guard")
	var bandit: Dictionary = LawDatabase.surrender_profile("bandits")
	var wolf: Dictionary = LawDatabase.surrender_profile("wildlife")
	var unknown: Dictionary = LawDatabase.surrender_profile("spider_party")
	_check("surrender.guards-accept", bool(guard.get("accepts", false)) and "pay_fine" in guard.get("options", []))
	_check("surrender.bandits-rob", bool(bandit.get("accepts", false)) and "rob" in bandit.get("options", []))
	_check("surrender.wildlife-refuses", not bool(wolf.get("accepts", true)))
	_check("surrender.unknown-defaults-implacable", not bool(unknown.get("accepts", true)))

func _case_service_legality_regression() -> void:
	# The profession-law system (faction["laws"]) must be byte-for-byte
	# unaffected by Phase 3. NOTE the plan's own example was wrong here:
	# hedge_witch is golden_guard law, and argentiara is patriciate-controlled
	# — so hedge witches are LEGAL there, while slavecatchers are not.
	_check("services.slavecatcher-illegal-in-argentiara",
		not RegionDatabase.is_service_legal(["slavecatcher"], "argentiara"))
	_check("services.hedge-witch-legal-in-argentiara",
		RegionDatabase.is_service_legal(["hedge witch"], "argentiara"))
	_check("services.everything-legal-in-perrow",
		RegionDatabase.is_service_legal(["slavecatcher"], "perrow"),
		"liziti laws array is empty")
