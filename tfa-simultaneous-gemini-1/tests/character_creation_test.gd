# res://tests/character_creation_test.gd
# Headless assertion harness for the Scarlatti carta d'identità: the DARO stat
# roller, the human body-metric dice in races.json, and the creation data set.
# Pure data checks — no scene, no characters, no UI.
#
# The two rules worth guarding, because both are invisible when they break:
#   * a DARO total can never itself be a repdigit of the die that produced it
#     (the chain only ends on a non-double), and
#   * every stat block contains at least one score of 80+.
#
# Run:  godot --headless --path . res://tests/character_creation_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

var failures := 0
var checks_run := 0

## Every _check this harness is expected to reach. A GDScript runtime error
## aborts only the function it happens in, so without this a broken case would
## silently report zero failures — which is exactly what it did once.
const EXPECTED_CHECKS: int = 41

func _check(check_name: String, cond: bool, detail: String = "") -> void:
	checks_run += 1
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])

func _ready() -> void:
	_case_repdigits()
	_case_daro_invariants()
	_case_stat_distribution()
	_case_stat_blocks()
	_case_body_metrics_human()
	_case_body_metrics_legacy_races()
	_case_creation_data()
	_case_draft()
	_case_build_integration()
	if checks_run != EXPECTED_CHECKS:
		failures += 1
		print("FAIL harness.coverage: ran %d checks, expected %d — a case aborted"
			% [checks_run, EXPECTED_CHECKS])
	print("HARNESS DONE failures=%d checks=%d" % [failures, checks_run])
	get_tree().quit(1 if failures > 0 else 0)

# ---------------------------------------------------------------------------
# Dice
# ---------------------------------------------------------------------------

func _case_repdigits() -> void:
	_check("daro.repdigits-d33", DaroDice.repdigits_for(33) == [11, 22, 33],
		str(DaroDice.repdigits_for(33)))
	_check("daro.repdigits-d66", DaroDice.repdigits_for(66) == [11, 22, 33, 44, 55, 66],
		str(DaroDice.repdigits_for(66)))
	_check("daro.repdigits-d6", DaroDice.repdigits_for(6) == [],
		str(DaroDice.repdigits_for(6)))

func _case_daro_invariants() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260804
	var exploded: int = 0
	var bad_terminal: Array = []
	var below_one: int = 0
	for i in range(30000):
		var sides: int = 33 if i % 2 == 0 else 66
		var total: int = DaroDice.roll_daro(sides, rng)
		if total < 1:
			below_one += 1
		if total > sides:
			exploded += 1
		elif total in DaroDice.repdigits_for(sides):
			# The chain terminates only on a non-double, so a total that is
			# itself a repdigit of its own die is impossible.
			bad_terminal.append(total)
	_check("daro.no-repdigit-total", bad_terminal.is_empty(), str(bad_terminal.slice(0, 8)))
	_check("daro.always-positive", below_one == 0, "%d rolls below 1" % below_one)
	# ~1 roll in 11 explodes at least once; over 30k that is ~2700.
	_check("daro.explodes", exploded > 1500 and exploded < 4500,
		"%d of 30000 exceeded their die" % exploded)

func _case_stat_distribution() -> void:
	# E[1d33 DARO] = 18.7, E[1d66 DARO] = 36.85 -> 55.55 for the sum.
	var rng := RandomNumberGenerator.new()
	rng.seed = 991
	var total: int = 0
	var minimum: int = 1 << 30
	var samples: int = 60000
	for _i in range(samples):
		var v: int = DaroDice.roll_stat(rng)
		total += v
		minimum = mini(minimum, v)
	var mean: float = float(total) / float(samples)
	_check("daro.stat-mean", absf(mean - 55.55) < 1.0, "mean=%.2f (expected ~55.55)" % mean)
	_check("daro.stat-floor", minimum >= 2, "lowest stat seen was %d" % minimum)

func _case_stat_blocks() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4354
	var keys: Array = CharacterCreationDatabase.stat_keys()
	var without_peak: int = 0
	var wrong_shape: int = 0
	for _i in range(400):
		var block: Dictionary = DaroDice.roll_stat_block(keys, DaroDice.DEFAULT_MIN_PEAK, rng)
		if block.size() != keys.size():
			wrong_shape += 1
			continue
		var peak: int = 0
		for k in keys:
			if not block.has(k):
				wrong_shape += 1
				break
			peak = maxi(peak, int(block[k]))
		if peak < DaroDice.DEFAULT_MIN_PEAK:
			without_peak += 1
	_check("stats.block-shape", wrong_shape == 0, "%d malformed blocks" % wrong_shape)
	_check("stats.peak-rule", without_peak == 0,
		"%d of 400 blocks had no stat >= %d" % [without_peak, DaroDice.DEFAULT_MIN_PEAK])

# ---------------------------------------------------------------------------
# Body metrics
# ---------------------------------------------------------------------------

# races.json, human: height = base + 2d10 cm; weight = base + height_roll *
# per_height_roll + 2d6 kg; age = 17 + 2d6.
const HUMAN_BOUNDS := {
	"male":   {"height": [162, 180], "weight": [54, 86]},
	"female": {"height": [150, 168], "weight": [46, 76]},
}

func _case_body_metrics_human() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	for gender in HUMAN_BOUNDS:
		var bounds: Dictionary = HUMAN_BOUNDS[gender]
		var out_of_range: Array = []
		var seen_heights: Dictionary = {}
		for _i in range(4000):
			var m: Dictionary = RaceDatabase.roll_body_metrics("human", String(gender), rng)
			var h: int = int(m["height"])
			var w: int = int(m["weight"])
			var a: int = int(m["age"])
			seen_heights[h] = true
			if h < int(bounds["height"][0]) or h > int(bounds["height"][1]):
				out_of_range.append("h=%d" % h)
			elif w < int(bounds["weight"][0]) or w > int(bounds["weight"][1]):
				out_of_range.append("w=%d" % w)
			elif a < 19 or a > 29:
				out_of_range.append("age=%d" % a)
		_check("metrics.human-%s-range" % gender, out_of_range.is_empty(),
			str(out_of_range.slice(0, 6)))
		# 2d10 spans 19 distinct heights; a stuck roll would show up as one.
		_check("metrics.human-%s-varies" % gender, seen_heights.size() >= 15,
			"only %d distinct heights" % seen_heights.size())

	var units: Dictionary = RaceDatabase.roll_body_metrics("human", "male")
	_check("metrics.units", String(units["height_unit"]) == "cm"
			and String(units["weight_unit"]) == "kg", str(units))

func _case_body_metrics_legacy_races() -> void:
	# Every other race still uses the flat {"male": n, "female": n} form and
	# must resolve to exactly that number, unrolled.
	var checked: int = 0
	var mismatched: Array = []
	for race_id in RaceDatabase.get_all_race_ids():
		if race_id == "human":
			continue
		var race: Dictionary = RaceDatabase.get_race_data(race_id)
		var spec = race.get("height", {}).get("male")
		if not (spec is float or spec is int):
			continue
		checked += 1
		var m: Dictionary = RaceDatabase.roll_body_metrics(race_id, "male")
		if int(m["height"]) != int(spec):
			mismatched.append("%s: %d != %d" % [race_id, int(m["height"]), int(spec)])
	_check("metrics.legacy-flat", mismatched.is_empty(), str(mismatched.slice(0, 5)))
	_check("metrics.legacy-covered", checked > 5, "only %d flat races checked" % checked)

# ---------------------------------------------------------------------------
# Creation data set
# ---------------------------------------------------------------------------

func _case_creation_data() -> void:
	for gender in ["male", "female"]:
		var portraits: Array = CharacterCreationDatabase.portraits_for(String(gender))
		# portraits_for already drops entries whose art is missing, so an empty
		# or short list means the manifest has rotted against Icons/.
		_check("data.portraits-%s" % gender, portraits.size() >= 8,
			"%d usable portraits" % portraits.size())
		var unresolvable: Array = []
		for entry in portraits:
			var id_str: String = String(entry.get("id", ""))
			if CharacterCreationDatabase.portrait_path(id_str) != String(entry.get("path", "")):
				unresolvable.append(id_str)
		_check("data.portrait-ids-%s" % gender, unresolvable.is_empty(),
			str(unresolvable.slice(0, 5)))

	var male_bgs: Array = CharacterCreationDatabase.background_ids_for("male")
	var female_bgs: Array = CharacterCreationDatabase.background_ids_for("female")
	_check("data.bg-excluded", not ("foppish_elf" in male_bgs)
			and not ("foppish_elf" in female_bgs), "elf background still offered")
	_check("data.bg-gender-lock",
		("oriental_dancing_girl" in female_bgs) and not ("oriental_dancing_girl" in male_bgs),
		"female-locked background leaked")
	_check("data.bg-count", male_bgs.size() > 30, "%d backgrounds offered" % male_bgs.size())

	var labelled: bool = true
	for bg_id in male_bgs:
		if CharacterCreationDatabase.background_label(String(bg_id)).is_empty():
			labelled = false
	_check("data.bg-labels", labelled, "a background has no display name")

	var keys: Array = CharacterCreationDatabase.stat_keys()
	_check("data.stat-keys", keys.size() == 6 and "strength" in keys and "charisma" in keys,
		str(keys))
	var crop_default_ok: bool = CharacterCreationDatabase.portrait_crop("no_such_id") == "token"
	var seeded_ok: bool = true
	for gender in ["male", "female"]:
		for entry in CharacterCreationDatabase.portraits_for(String(gender)):
			var want: String = String(entry.get("crop", "token"))
			if CharacterCreationDatabase.portrait_crop(String(entry.get("id", ""))) != want:
				seeded_ok = false
	_check("data.portrait-crop", crop_default_ok and seeded_ok,
		"default=%s seeded=%s" % [crop_default_ok, seeded_ok])

	_check("data.verdict-gendered",
		CharacterCreationDatabase.verdict_text("male")
			!= CharacterCreationDatabase.verdict_text("female"),
		CharacterCreationDatabase.verdict_text("female"))

	# The card number has to be a function of the holder, not of the moment.
	var a: String = CharacterCreationDatabase.document_number("Aurelio Vermincelli")
	var b: String = CharacterCreationDatabase.document_number("Aurelio Vermincelli")
	var c: String = CharacterCreationDatabase.document_number("Bianca Sbarra")
	_check("data.document-number-stable", a == b, "%s vs %s" % [a, b])
	_check("data.document-number-distinct", a != c, "%s == %s" % [a, c])

func _case_draft() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1861
	var text_keys: Array[String] = ["name", "gender", "background_id",
			"portrait_id"]
	var dict_keys: Array[String] = ["body_metrics", "stats"]
	var missing: Array = []
	for _i in range(50):
		var draft: Dictionary = CharacterCreationDatabase.roll_draft("", rng)
		for key in text_keys:
			if not draft.has(key) or String(draft[key]).strip_edges().is_empty():
				missing.append(key)
		for key in dict_keys:
			var sub = draft.get(key)
			if not (sub is Dictionary) or (sub as Dictionary).is_empty():
				missing.append(key)
		# A draft must be internally consistent: its portrait and profession
		# both have to be legal for the sex it rolled.
		var gender: String = String(draft["gender"])
		if not (draft["background_id"] in CharacterCreationDatabase.background_ids_for(gender)):
			missing.append("background/gender mismatch")
		var found: bool = false
		for entry in CharacterCreationDatabase.portraits_for(gender):
			if String(entry.get("id", "")) == String(draft["portrait_id"]):
				found = true
		if not found:
			missing.append("portrait/gender mismatch")
	_check("draft.complete", missing.is_empty(), str(missing.slice(0, 6)))

# ---------------------------------------------------------------------------
# End to end: a convalidated card -> a built protagonist
# ---------------------------------------------------------------------------

## The overrides below mirror Game.apply_character_draft. If that function and
## this one drift apart the card stops reaching the character — silently, since
## build_character ignores keys it doesn't recognise — so this case is the thing
## keeping them honest.
func _case_build_integration() -> void:
	var draft: Dictionary = {
		"name": "Ottavio Barbagianni",
		"gender": "male",
		"background_id": "judge_for_hire",
		"portrait_id": "senator_titus",
		"body_metrics": {
			"height": 177, "weight": 81, "age": 26,
			"height_unit": "cm", "weight_unit": "kg",
		},
		"stats": {
			"strength": 84, "constitution": 51, "dexterity": 47,
			"will": 62, "intelligence": 70, "charisma": 38,
		},
	}
	var overrides: Dictionary = {
		"unique_name": String(draft["name"]),
		"gender": String(draft["gender"]),
		"race": CharacterCreationDatabase.PLAYER_RACE,
		"background": String(draft["background_id"]),
		"stats": (draft["stats"] as Dictionary).duplicate(),
		"icon": CharacterCreationDatabase.portrait_path(String(draft["portrait_id"])),
		"options": {
			"gender": String(draft["gender"]),
			"body_metrics": (draft["body_metrics"] as Dictionary).duplicate(),
		},
	}

	var pc = PC_SCENE.instantiate()
	add_child(pc)
	TopDownCharacterDatabase.build_character(pc, "protagonist", overrides)

	_check("build.name", String(pc.display_name) == String(draft["name"]),
		String(pc.display_name))
	_check("build.gender", String(pc.gender) == "male", String(pc.gender))
	_check("build.race", String(pc.race_id) == "human", String(pc.race_id))
	_check("build.background", String(pc.background_id) == "judge_for_hire",
		String(pc.background_id))
	# The template ships strength 55 / charisma 50; the card must win.
	_check("build.stats-overridden", pc.strength == 84 and pc.charisma == 38,
		"str=%d cha=%d" % [pc.strength, pc.charisma])
	# The whole point of routing metrics through options: no re-measuring.
	_check("build.metrics-honoured",
		pc.race_height == 177 and pc.race_weight == 81 and pc.age == 26,
		"h=%d w=%d age=%d" % [pc.race_height, pc.race_weight, pc.age])
	_check("build.icon", String(pc.icon_path).ends_with("senator_titus_icon.png"),
		String(pc.icon_path))
	# The race's age brackets used to be dropped on the floor (no property to
	# land on); they are what tells the sheet whether 26 is young or old.
	# max_health is derived from constitution and the Martial trait, both of
	# which build_character sets AFTER ProceduralCharacter._ready has already
	# seeded current_health from the @export defaults. Without an explicit
	# refill the protagonist spawns wounded.
	_check("build.full-health",
		pc.current_health == pc.max_health and pc.current_health > 0,
		"%d/%d (con=%d martial=%d)" % [pc.current_health, pc.max_health,
			pc.constitution, int(pc.traits.get("Martial", 0))])

	_check("build.age-brackets",
		pc.base_age == 20 and pc.middle_age == 40 and pc.old_age == 60,
		"%d/%d/%d" % [pc.base_age, pc.middle_age, pc.old_age])

	pc.queue_free()

	# The same defect in the other direction: djargo's constitution of 40 is
	# BELOW the @export default of 50, so _ready seeded 30 HP against a final
	# maximum of 28 and it spawned over its own cap. Any template whose
	# constitution differs from the default exercises this.
	var low = PC_SCENE.instantiate()
	add_child(low)
	TopDownCharacterDatabase.build_character(low, "djargo", {})
	_check("build.full-health-low-con",
		low.current_health == low.max_health and low.current_health > 0,
		"%d/%d (con=%d)" % [low.current_health, low.max_health, low.constitution])
	low.queue_free()
