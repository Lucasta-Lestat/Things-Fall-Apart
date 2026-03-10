# RaceDatabase.gd
# Autoload singleton - add to Project > AutoLoad as "RaceDatabase"
extends Node

var _races: Dictionary = {}

func _ready() -> void:
	_load_database()

func _load_database() -> void:
	var file_path = "res://data/races.json"
	if not FileAccess.file_exists(file_path):
		push_error("Race Database not found at: " + file_path)
		return

	var file = FileAccess.open(file_path, FileAccess.READ)
	var content = file.get_as_text()
	var json = JSON.new()
	var error = json.parse(content)
	print("====== Race Database =======")
	if error == OK:
		var data = json.get_data()
		for entry in data.get("races", []):
			_races[entry["id"]] = entry
		print("Loaded %d races" % _races.size())
	else:
		push_error("Failed to parse Race JSON: " + json.get_error_message())
	print("====== End Race Database ======")

# ---------------------------------------------------------------------------
# Lookup helpers
# ---------------------------------------------------------------------------

func get_race_data(race_id: String) -> Dictionary:
	if _races.has(race_id):
		return _races[race_id]
	push_error("Race ID not found: " + race_id)
	return {}

func get_all_race_ids() -> Array:
	return _races.keys()

func get_races_by_creature_type(creature_type: String) -> Array:
	var results: Array = []
	for race in _races.values():
		if race.get("creature_type", "") == creature_type:
			results.append(race)
	return results

func get_races_by_size(size: String) -> Array:
	var results: Array = []
	for race in _races.values():
		if race.get("size", "") == size:
			results.append(race)
	return results

# ---------------------------------------------------------------------------
# Apply race data to a character node
# ---------------------------------------------------------------------------
# Expects `character` to own the stat vars (strength, constitution, dexterity,
# will, intelligence, charisma, body_width, skin_color, arm_length, etc.)
#
# Child nodes expected:
#   "EquipmentManager" with equip_ability_from_id(id) -> bool
#   "ConditionManager" with apply_condition(id, source, stacks, duration)
#
# `options` dict:
#   "gender"       : "male" / "female" (default "male")
#   "skin_index"   : int index into skin_colors
#   "hair_index"   : int index into hair_colors
#   "hair_style"   : HairStyle string e.g. "MOHAWK"
#   "trait_choices" : Array of trait names for races with "_choice"

func apply_race_to_character(character, race_id: String, options: Dictionary = {}) -> void:
	var race = get_race_data(race_id)
	if race.is_empty():
		push_error("Cannot apply unknown race: " + race_id)
		return

	var gender: String = options.get("gender", "male")

	# --- Core identity ---
	_set_if_exists(character, "race_id", race_id)

	# --- Ability Score Increases ---
	var asi: Dictionary = race.get("ability_score_increases", {})
	_apply_asi(character, "strength",     asi.get("Str", 0))
	_apply_asi(character, "constitution",  asi.get("Con", 0))
	_apply_asi(character, "dexterity",     asi.get("Dex", 0))
	_apply_asi(character, "will",          asi.get("Wil", 0) + asi.get("Will", 0))
	_apply_asi(character, "intelligence",  asi.get("Int", 0))
	_apply_asi(character, "charisma",      asi.get("Cha", 0))

	# --- Traits ---
	var race_traits: Dictionary = race.get("traits", {})
	if not character.get("traits") is Dictionary:
		character.traits = {}
	for trait_name in race_traits:
		if trait_name == "_choice":
			for chosen in options.get("trait_choices", []):
				character.traits[chosen] = 1
			continue
		character.traits[trait_name] = race_traits[trait_name]

	# --- Size ---
	_set_if_exists(character, "creature_size", race.get("size"))

	# --- Speed modifier (additive offset from base 30) ---
	# Halflings: -5, Centaur 60 base would be +30, etc.
	var speed_mod: float = race.get("speed_modifier", 0)
	if speed_mod != 0:
		_add_to(character, "speed_modifier", speed_mod)

	# --- Arm length bonus (from range_increase column) ---
	# Trolls +5, High-Elves +5, Bugaboos +5
	var arm_bonus: float = race.get("arm_length_bonus", 0)
	if arm_bonus != 0:
		_add_to(character, "arm_length", arm_bonus)

	# --- Body dimensions ---
	var body: Dictionary = race.get("body", {})
	_set_if_exists(character, "body_size_mod",    body.get("body_size_mod", 1.0))
	_set_if_exists(character, "body_width",        body.get("body_width"))
	_set_if_exists(character, "body_height",       body.get("body_height"))
	_set_if_exists(character, "head_width",        body.get("head_width"))
	_set_if_exists(character, "head_length",       body.get("head_length"))
	_set_if_exists(character, "shoulder_y_offset", body.get("shoulder_y_offset"))
	_set_if_exists(character, "leg_length",        body.get("leg_length"))
	_set_if_exists(character, "leg_width",         body.get("leg_width"))
	_set_if_exists(character, "leg_spacing",       body.get("leg_spacing"))

	# Recompute leg animation from body_size_mod
	var bsm: float = body.get("body_size_mod", 1.0)
	_set_if_exists(character, "leg_swing_time",   bsm * Globals.default_leg_swing_time)
	_set_if_exists(character, "leg_swing_speed",  bsm * Globals.default_leg_swing_speed)
	_set_if_exists(character, "leg_swing_amount", bsm * Globals.default_leg_swing_amount)

	# --- Appearance ---
	_apply_appearance(character, race.get("appearance", {}), options)

	# --- Stat overrides ---
	var stats: Dictionary = race.get("stat_overrides", {})
	_set_if_exists(character, "CRIT_THRESHOLD",     stats.get("crit_threshold", 5))
	_set_if_exists(character, "CRIT_FAIL_THRESHOLD", stats.get("crit_fail_threshold", 96))
	_set_if_exists(character, "mp_regen_amount",     stats.get("mp_regen_amount", 5))
	_set_if_exists(character, "mp_regen_interval",   stats.get("mp_regen_interval", 0.5))

	# --- Height / Weight (gendered) ---
	var height_data: Dictionary = race.get("height", {})
	var weight_data: Dictionary = race.get("weight", {})
	_set_if_exists(character, "race_height", height_data.get(gender, height_data.get("male")))
	_set_if_exists(character, "race_weight", weight_data.get(gender, weight_data.get("male")))

	# --- Age brackets ---
	var age_data: Dictionary = race.get("age", {})
	_set_if_exists(character, "base_age",   age_data.get("base"))
	_set_if_exists(character, "middle_age", age_data.get("middle"))
	_set_if_exists(character, "old_age",    age_data.get("old"))

	# --- Creature type ---
	_set_if_exists(character, "creature_type", race.get("creature_type"))

	# --- Equip active racial abilities ---
	_equip_racial_abilities(character, race.get("active_abilities", []))

	# --- Apply passive racial conditions ---
	_apply_racial_conditions(character, race.get("passive_conditions", []))

# ---------------------------------------------------------------------------
# Active abilities - equip via EquipmentManager
# These are usable skills: breath_weapon, charm_person, light_cantrip, etc.
# ---------------------------------------------------------------------------

func _equip_racial_abilities(character, ability_ids: Array) -> void:
	if ability_ids.is_empty():
		return

	var equip_mgr = _find_child_by_name(character, "Inventory")
	if not equip_mgr:
		if character.has_method("equip_ability_from_id"):
			equip_mgr = character
		else:
			push_warning("No EquipmentManager on %s - skipping racial abilities" % character.name)
			return

	for ability_id in ability_ids:
		var success = equip_mgr.equip_ability_from_id(ability_id)
		if success:
			print("[RaceDatabase] Equipped racial ability '" + ability_id + "' on " + character.name)
		else:
			push_warning("[RaceDatabase] Failed to equip ability '" + ability_id + "' on " + character.name)

# ---------------------------------------------------------------------------
# Passive conditions - apply via ConditionManager
# Always-on racial buffs: lucky, flight, tough_claws, regen, etc.
# Applied with duration -1 (permanent) and source null (innate).
# ---------------------------------------------------------------------------

func _apply_racial_conditions(character, condition_ids: Array) -> void:
	if condition_ids.is_empty():
		return

	var cond_mgr = _find_child_by_name(character, "ConditionManager")
	if not cond_mgr:
		push_warning("No ConditionManager on %s - skipping racial conditions" % character.name)
		return

	for condition_id in condition_ids:
		# source=null (innate), stacks=1, duration=-1.0 (permanent)
		var instance = cond_mgr.apply_condition(condition_id, null, 1, -1.0)
		if instance:
			print("[RaceDatabase] Applied racial condition '" + condition_id + "' on " + character.name)
		else:
			push_warning("[RaceDatabase] Condition '" + condition_id + "' not registered or " + character.name + " is immune")

# ---------------------------------------------------------------------------
# Appearance
# ---------------------------------------------------------------------------

func _apply_appearance(character, appearance: Dictionary, options: Dictionary) -> void:
	# Skin color
	var skin_colors: Array = appearance.get("skin_colors", ["#F5D6B8"])
	var skin_idx: int = options.get("skin_index", randi() % skin_colors.size())
	skin_idx = clampi(skin_idx, 0, skin_colors.size() - 1)
	character.skin_color = Color(skin_colors[skin_idx])
	character.body_color = character.skin_color.darkened(0.15)

	# Hair color
	var hair_colors: Array = appearance.get("hair_colors", [])
	if hair_colors.size() > 0:
		var hair_idx: int = options.get("hair_index", randi() % hair_colors.size())
		hair_idx = clampi(hair_idx, 0, hair_colors.size() - 1)
		character.hair_color = Color(hair_colors[hair_idx])
	else:
		character.hair_color = Color(0, 0, 0, 0)

	# Hair style
	var valid_styles: Array = appearance.get("hair_styles", ["FULL"])
	if options.has("hair_style") and options["hair_style"] in valid_styles:
		character.hair_style = _hair_style_from_string(options["hair_style"])
	elif valid_styles.size() > 0:
		character.hair_style = _hair_style_from_string(valid_styles[0])

	# Blood color
	if appearance.has("blood_color"):
		_set_if_exists(character, "blood_color", Color(appearance["blood_color"]))

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

func _apply_asi(character, stat_name: String, modifier: int) -> void:
	if modifier == 0:
		return
	if stat_name in character:
		character.set(stat_name, character.get(stat_name) + modifier)

func _add_to(character, property: String, amount: float) -> void:
	if property in character:
		character.set(property, character.get(property) + amount)

func _set_if_exists(character, property: String, value) -> void:
	if value == null:
		return
	if property in character:
		character.set(property, value)

func _find_child_by_name(node: Node, child_name: String) -> Node:
	for child in node.get_children():
		if child.name == child_name:
			return child
	return null

func _hair_style_from_string(style_name: String) -> int:
	match style_name:
		"NONE":       return 0
		"HORSESHOE":  return 1
		"FULL":       return 2
		"COMBOVER":   return 3
		"POMPADOUR":  return 4
		"BUZZCUT":    return 5
		"MOHAWK":     return 6
		_:            return 2
