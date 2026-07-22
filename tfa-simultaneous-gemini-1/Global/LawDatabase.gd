# LawDatabase.gd
# Autoload singleton - registered AFTER RegionDatabase in project.godot
# (it reads MapDatabase, RegionDatabase, FactionDatabase, and
# TopDownCharacterDatabase in _ready; autoload order guarantees they exist).
#
# Loads data/laws.json:
#   statutes — reusable nouns ("theft", "necromancy"), each with a verb and a
#              match block drawn from a CLOSED six-predicate vocabulary.
#   codes    — per-faction bundles with extends/overrides/repeals inheritance,
#              flattened ONCE at boot into {statute_id: severity} so runtime
#              evaluation is a dictionary scan, never a graph walk.
#   witness / standing / surrender — tuning blocks consumed by later phases.
#
# Pure queries only; no runtime state lives here. evaluate() is THE legality
# resolver (docs/law_crime_stealth_plan.md, Phase 3) — callable headless with
# no scene tree.
extends Node

var _statutes: Dictionary = {}     # statute_id -> statute def
var _codes: Dictionary = {}        # code_id -> raw code def
var _flat: Dictionary = {}         # code_id -> {statute_id: severity}
var _default_code: String = ""
var _applies_to: Array = []
var _confirm_above: int = 100
var _witness_cfg: Dictionary = {}
var _standing_cfg: Dictionary = {}
var _surrender_cfg: Dictionary = {}
var loaded: bool = false

func _ready() -> void:
	_load_database()
	if loaded:
		for code_id in _codes:
			_flatten_code(code_id)
		_validate()

func _load_database() -> void:
	var file_path := "res://data/laws.json"
	if not FileAccess.file_exists(file_path):
		push_error("Law Database not found at: " + file_path)
		return
	var file := FileAccess.open(file_path, FileAccess.READ)
	var json := JSON.new()
	var error := json.parse(file.get_as_text())
	print("====== Law Database =======")
	if error == OK:
		var data: Dictionary = json.get_data()
		_statutes = data.get("statutes", {})
		_codes = data.get("codes", {})
		_default_code = str(data.get("default_code", ""))
		_applies_to = data.get("applies_to", [])
		_confirm_above = int(data.get("confirm_above_severity", 100))
		_witness_cfg = data.get("witness", {})
		_standing_cfg = data.get("standing", {})
		_surrender_cfg = data.get("surrender", {})
		loaded = true
		print("Loaded %d statutes, %d codes" % [_statutes.size(), _codes.size()])
	else:
		push_error("Failed to parse Law JSON: " + json.get_error_message())
	print("====== End Law Database ======")

# ---------------------------------------------------------------------------
# Jurisdiction
# ---------------------------------------------------------------------------

## Position -> law faction, at map granularity. A per-map controlling_faction
## override in Maps.json wins over the region's controlling faction. The
## override is not optional sugar: Waldau — the motivating example's own
## jurisdiction — controls no region, so without it the headline feature
## (necromancy illegal in Waldau) is unreachable in shipped content.
func jurisdiction_for_map(map_id: String) -> String:
	if map_id.is_empty():
		return ""
	var map_ids: Array = MapDatabase.get_all_map_ids()
	if map_id in map_ids:
		var map_data: Dictionary = MapDatabase.get_map_data(map_id)
		var override_faction: String = str(map_data.get("controlling_faction", ""))
		if not override_faction.is_empty():
			return override_faction
	var region_id: String = RegionDatabase.get_region_for_map(map_id)
	if region_id.is_empty():
		return ""
	return RegionDatabase.get_controlling_faction(region_id)

## The code a law faction judges by: its law_code, else the global default.
## "" (no jurisdiction / unknown faction) -> "" -> evaluate returns {} —
## wilderness is lawless for free.
func code_for_faction(faction_id: String) -> String:
	if faction_id.is_empty() or not FactionDatabase.has_faction(faction_id):
		return ""
	var code: String = str(FactionDatabase.get_faction_data(faction_id).get("law_code", ""))
	if code.is_empty():
		return _default_code
	return code

## Who enforces a law faction's law. Authored, never derived from relations —
## Perrow's lawgiver (liziti) declares its own town guards (golden_guard) as
## enemies, by design (mob rule), so relation-derived enforcement is inert
## across most shipped maps. Defaults to the law faction itself when absent.
func policed_by(law_faction: String) -> Array:
	if not FactionDatabase.has_faction(law_faction):
		return []
	var pb: Array = FactionDatabase.get_faction_data(law_faction).get("policed_by", [])
	if pb.is_empty():
		return [law_faction]
	return pb

func enforces(hearer_faction: String, law_faction: String) -> bool:
	return hearer_faction in policed_by(law_faction)

# ---------------------------------------------------------------------------
# The resolver
# ---------------------------------------------------------------------------

## THE legality resolver. Returns {} when the act is legal under `code_id`,
## else a Verdict: {statute, display_name, severity, law_faction}.
## Highest severity wins across matching statutes, so statute ordering in the
## hand-edited JSON carries no meaning. Pure: no side effects, no scene tree.
##
## The payload keys the closed match vocabulary reads:
##   law_faction              String — the jurisdiction being evaluated under
##   owner_faction            String — for take/loot
##   victim_faction           String — for attack
##   victim_hostile_to_actor  bool   — self-defence carve-out
##   lethal                   bool
##   traits                   Dictionary — the ability's traits (tier ints)
##   item_cost                float
func evaluate(code_id: String, verb: String, payload: Dictionary) -> Dictionary:
	var flat: Dictionary = _flat.get(code_id, {})
	var best: Dictionary = {}
	var best_severity: int = -1
	for statute_id in flat:
		var statute: Dictionary = _statutes.get(statute_id, {})
		if str(statute.get("verb", "")) != verb:
			continue
		if not _matches(statute.get("match", {}), payload):
			continue
		var severity: int = int(flat[statute_id])
		if severity > best_severity:
			best_severity = severity
			best = {
				"statute": statute_id,
				"display_name": str(statute.get("display_name", statute_id)),
				"severity": severity,
				"law_faction": str(payload.get("law_faction", "")),
			}
	return best

## The match vocabulary is a CLOSED set of named predicates, each one arm
## below. Adding a statute is JSON; adding a *kind* of statute is one arm
## plus one payload key. A general expression language is explicitly refused.
## Unknown keys fail closed (no match) — the boot lint warns about them.
func _matches(match_def: Dictionary, payload: Dictionary) -> bool:
	for key in match_def:
		match String(key):
			"owner":
				var want: String = str(match_def[key])
				var owner_f: String = str(payload.get("owner_faction", ""))
				if owner_f.is_empty():
					return false
				if want == "law_faction":
					if not _protected_by(owner_f, str(payload.get("law_faction", ""))):
						return false
				elif want != "any" and owner_f != want:
					return false
			"victim_protected":
				var is_protected: bool = _protected_by(
					str(payload.get("victim_faction", "")),
					str(payload.get("law_faction", ""))
				) and not bool(payload.get("victim_hostile_to_actor", false))
				if is_protected != bool(match_def[key]):
					return false
			"lethal":
				if bool(payload.get("lethal", false)) != bool(match_def[key]):
					return false
			"traits_any":
				var traits: Dictionary = payload.get("traits", {})
				var any_hit := false
				for trait_name in match_def[key]:
					if int(traits.get(trait_name, 0)) >= 1:
						any_hit = true
						break
				if not any_hit:
					return false
			"traits_all":
				var traits2: Dictionary = payload.get("traits", {})
				for trait_name in match_def[key]:
					if int(traits2.get(trait_name, 0)) >= 1:
						continue
					return false
			"min_value":
				if float(payload.get("item_cost", 0.0)) < float(match_def[key]):
					return false
			_:
				return false
	return true

## A faction is under a law faction's protection when it is not at war with
## it (the Phase 1 oracle). Deliberate deviation from the plan's
## policed_by-based wording: policed_by answers "who ENFORCES here", and
## using it for protection would leave neutral civilians unprotected
## everywhere — the exact case (murdering a shopkeeper) the system exists
## for. Corollary: killing a bandit inside town is legal. That is intended.
func _protected_by(faction_id: String, law_faction: String) -> bool:
	if faction_id.is_empty() or law_faction.is_empty():
		return false
	return not FactionDatabase.are_hostile(faction_id, law_faction)

# ---------------------------------------------------------------------------
# Config accessors (consumed by Phases 4-7)
# ---------------------------------------------------------------------------

func witness_cfg() -> Dictionary:
	return _witness_cfg

func standing_cfg() -> Dictionary:
	return _standing_cfg

func surrender_profile(faction_id: String) -> Dictionary:
	var profiles: Dictionary = _surrender_cfg.get("profiles", {})
	var by_faction: Dictionary = _surrender_cfg.get("faction_profiles", {})
	var profile_key: String = str(by_faction.get(faction_id, _surrender_cfg.get("default_profile", "implacable")))
	return profiles.get(profile_key, {})

func applies_to() -> Array:
	return _applies_to

func confirm_threshold() -> int:
	return _confirm_above

## Read-only view of a flattened code, for tests and debug UI.
func flattened_code(code_id: String) -> Dictionary:
	var flat: Dictionary = _flat.get(code_id, {})
	return flat.duplicate()

# ---------------------------------------------------------------------------
# Code inheritance
# ---------------------------------------------------------------------------

func _flatten_code(code_id: String, _visiting: Array = []) -> Dictionary:
	if _flat.has(code_id):
		return _flat[code_id]
	if code_id in _visiting:
		push_warning("LawDatabase: 'extends' cycle at code '%s' — treating as a base code" % code_id)
		return {}
	var code: Dictionary = _codes.get(code_id, {})
	if code.is_empty():
		return {}
	_visiting.append(code_id)
	var result: Dictionary = {}
	var parent: String = str(code.get("extends", ""))
	if not parent.is_empty():
		if _codes.has(parent):
			result = _flatten_code(parent, _visiting).duplicate()
		else:
			push_warning("LawDatabase: code '%s' extends unknown code '%s'" % [code_id, parent])
	for statute_id in code.get("statutes", []):
		var statute: Dictionary = _statutes.get(statute_id, {})
		if statute.is_empty():
			push_warning("LawDatabase: code '%s' names unknown statute '%s'" % [code_id, statute_id])
			continue
		result[statute_id] = int(statute.get("severity", 0))
	var overrides: Dictionary = code.get("overrides", {})
	for statute_id in overrides:
		if result.has(statute_id):
			result[statute_id] = int(overrides[statute_id])
		else:
			push_warning("LawDatabase: code '%s' overrides absent statute '%s'" % [code_id, statute_id])
	for statute_id in code.get("repeals", []):
		result.erase(statute_id)
	_visiting.erase(code_id)
	_flat[code_id] = result
	return result

# ---------------------------------------------------------------------------
# Boot-time validation lint
# ---------------------------------------------------------------------------
# push_warning only — the game always boots. For a solo dev hand-editing JSON
# with no code review, this is the highest value-per-line in the system: it is
# what lets the schema afford to be expressive.

func _validate() -> void:
	var known_match_keys := ["owner", "victim_protected", "lethal", "traits_any", "traits_all", "min_value"]

	# Every faction law_code resolves; policed_by ids are defined factions.
	for faction_id in FactionDatabase.get_all_faction_ids():
		var fdata: Dictionary = FactionDatabase.get_faction_data(faction_id)
		var code: String = str(fdata.get("law_code", ""))
		if not code.is_empty() and not _codes.has(code):
			push_warning("LawDatabase: faction '%s' has unknown law_code '%s'" % [faction_id, code])
		for enforcer in fdata.get("policed_by", []):
			if not FactionDatabase.has_faction(str(enforcer)):
				push_warning("LawDatabase: faction '%s' policed_by unknown faction '%s'" % [faction_id, enforcer])
	if not _default_code.is_empty() and not _codes.has(_default_code):
		push_warning("LawDatabase: default_code '%s' does not exist" % _default_code)

	# Statute sanity: known match keys; owner arms name real factions; trait
	# names actually appear on some ability at tier >= 1 (catches Necrotic vs
	# necrotic in a file that already ships Fire/fire, Martial/martial).
	var live_traits: Dictionary = _collect_ability_traits()
	for statute_id in _statutes:
		var match_def: Dictionary = _statutes[statute_id].get("match", {})
		for key in match_def:
			if not String(key) in known_match_keys:
				push_warning("LawDatabase: statute '%s' uses unknown match key '%s' (fails closed)" % [statute_id, key])
		var owner_want: String = str(match_def.get("owner", ""))
		if not owner_want.is_empty() and owner_want != "law_faction" and owner_want != "any" \
				and not FactionDatabase.has_faction(owner_want):
			push_warning("LawDatabase: statute '%s' owner names unknown faction '%s'" % [statute_id, owner_want])
		if not live_traits.is_empty():
			for list_key in ["traits_any", "traits_all"]:
				for trait_name in match_def.get(list_key, []):
					if not live_traits.has(trait_name):
						push_warning("LawDatabase: statute '%s' trait '%s' matches no ability at tier >= 1 — typo?" % [statute_id, trait_name])

	# Surrender profile references.
	var profiles: Dictionary = _surrender_cfg.get("profiles", {})
	if not profiles.has(str(_surrender_cfg.get("default_profile", ""))):
		push_warning("LawDatabase: surrender default_profile is not a defined profile")
	var by_faction: Dictionary = _surrender_cfg.get("faction_profiles", {})
	for faction_id in by_faction:
		if not FactionDatabase.has_faction(str(faction_id)):
			push_warning("LawDatabase: surrender faction_profiles names unknown faction '%s'" % faction_id)
		if not profiles.has(str(by_faction[faction_id])):
			push_warning("LawDatabase: surrender profile '%s' (faction '%s') is not defined" % [by_faction[faction_id], faction_id])

	# Jurisdictions with no possible enforcer: for each region with at least
	# one existing member map, some policed_by faction of its controlling
	# faction must appear among those maps' npc_spawns. This is the check
	# that would have caught the Perrow/golden_guard mismatch before it
	# shipped. Regions whose maps are all unbuilt are skipped, with one
	# aggregate warning for the missing-map count.
	var all_maps: Array = MapDatabase.get_all_map_ids()
	var missing_map_refs: int = 0
	for region_id in RegionDatabase.get_all_region_ids():
		var law_faction: String = RegionDatabase.get_controlling_faction(region_id)
		if law_faction.is_empty():
			continue
		var enforcers: Array = policed_by(law_faction)
		var live_maps: Array = []
		for map_id in RegionDatabase.get_member_maps(region_id):
			if map_id in all_maps:
				live_maps.append(map_id)
			else:
				missing_map_refs += 1
		if live_maps.is_empty():
			continue
		var found := false
		for map_id in live_maps:
			var map_data: Dictionary = MapDatabase.get_map_data(map_id)
			for spawn in map_data.get("npc_spawns", []):
				var template: Dictionary = TopDownCharacterDatabase.get_template(str(spawn.get("template_id", "")))
				if str(template.get("faction", "")) in enforcers:
					found = true
					break
			if found:
				break
		if not found:
			push_warning("LawDatabase: region '%s' (law faction '%s') has no enforcer (%s) on any existing member map — its law is unenforceable" % [region_id, law_faction, str(enforcers)])
	if missing_map_refs > 0:
		push_warning("LawDatabase: regions.json references %d member maps that do not exist in Maps.json" % missing_map_refs)

## All trait names appearing on any ability at tier >= 1, read straight from
## data/Abilities.json so the lint has no load-order coupling.
func _collect_ability_traits() -> Dictionary:
	var out: Dictionary = {}
	var file_path := "res://data/Abilities.json"
	if not FileAccess.file_exists(file_path):
		return out
	var json := JSON.new()
	if json.parse(FileAccess.open(file_path, FileAccess.READ).get_as_text()) != OK:
		return out
	var data = json.get_data()
	var ability_list: Array = data.get("abilities", []) if data is Dictionary else data
	for ability in ability_list:
		if not ability is Dictionary:
			continue
		var traits = ability.get("traits", {})
		if not traits is Dictionary:
			continue
		for trait_name in traits:
			if int(traits[trait_name]) >= 1:
				out[trait_name] = true
	return out
