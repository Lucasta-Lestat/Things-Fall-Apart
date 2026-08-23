extends Node2D
# AoE preview intent classification: every ability in data/Abilities.json is
# sorted into HOSTILE / BENEFICIAL / NEUTRAL, which picks the colour of its
# targeting ring (Ability.classify_intent -> intent_fill_color/intent_border_color).
# A misclassification is a LIE to the player about whether standing in a ring is
# safe, so the load-bearing cases are pinned here.
# Headless-safe.  Run:  godot --headless --path . res://tests/ability_intent_check.tscn

var fails := 0
var checks := 0


func _check(name: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if not ok:
		fails += 1
	print("%s %s %s" % ["PASS" if ok else "FAIL", name, detail])


func _name_of(intent: int) -> String:
	match intent:
		Ability.Intent.HOSTILE:
			return "HOSTILE"
		Ability.Intent.BENEFICIAL:
			return "BENEFICIAL"
	return "NEUTRAL"


func _ready() -> void:
	add_to_group("game")
	await get_tree().process_frame

	var f := FileAccess.open("res://data/Abilities.json", FileAccess.READ)
	var json := JSON.new()
	if f == null or json.parse(f.get_as_text()) != OK:
		_check("data.abilities-load", false, "could not read data/Abilities.json")
		get_tree().quit(1)
		return
	var raw = json.get_data()
	# data/Abilities.json holds a LIST of ability dicts under "abilities"; key it
	# by id so the pinned expectations below can look one up directly.
	var listed: Array = raw.get("abilities", []) if raw is Dictionary else []
	var abilities: Dictionary = {}
	for entry in listed:
		if entry is Dictionary and entry.has("id"):
			abilities[String(entry["id"])] = entry
	_check("data.abilities-load", abilities.size() > 0, "%d abilities" % abilities.size())

	# --- pinned expectations --------------------------------------------------
	# Chosen to cover each rule in the classifier, including the two that are easy
	# to get backwards: a mixed help+harm ability must read HOSTILE (the ring
	# answers "will this hurt someone standing here?"), and an ability that is
	# genuinely neither must stay NEUTRAL rather than be forced into red/green.
	var expect := {
		"fireball": Ability.Intent.HOSTILE,          # damage
		"heal": Ability.Intent.BENEFICIAL,           # heal
		"cloud_kill": Ability.Intent.HOSTILE,        # cloud -> poisoned (debuff)
		"silence": Ability.Intent.NEUTRAL,           # sound zone: a tool, not an attack
		"oil_well": Ability.Intent.HOSTILE,         # fluid_well -> oil: mires, and burns
	}
	for id in expect.keys():
		if not abilities.has(id):
			_check("intent.%s" % id, false, "ability id missing from data")
			continue
		var got: int = Ability.classify_intent(abilities[id])
		_check("intent.%s" % id, got == expect[id],
			"got %s, want %s" % [_name_of(got), _name_of(expect[id])])

	# --- whole-file sweep: nothing crashes, and report the spread -------------
	var tally := {Ability.Intent.HOSTILE: 0, Ability.Intent.BENEFICIAL: 0, Ability.Intent.NEUTRAL: 0}
	var neutrals: Array = []
	for id in abilities.keys():
		var intent: int = Ability.classify_intent(abilities[id])
		tally[intent] = int(tally[intent]) + 1
		if intent == Ability.Intent.NEUTRAL:
			neutrals.append(id)
	_check("sweep.no-crash", true, "hostile=%d beneficial=%d neutral=%d"
		% [tally[Ability.Intent.HOSTILE], tally[Ability.Intent.BENEFICIAL], tally[Ability.Intent.NEUTRAL]])
	# A damaging ability that lands in NEUTRAL would be the dangerous failure, so
	# assert the classifier never leaves an explicit `damage` effect uncoloured.
	var damaging_but_neutral: Array = []
	for id in neutrals:
		var data: Dictionary = abilities[id]
		for e in data.get("effects", []):
			if e is Dictionary and String(e.get("type", "")) == "damage":
				damaging_but_neutral.append(id)
				break
	_check("sweep.no-damaging-ability-reads-safe", damaging_but_neutral.is_empty(),
		str(damaging_but_neutral))
	print("NEUTRAL abilities (sepia ring): %s" % str(neutrals))

	# --- palette contract ------------------------------------------------------
	# Intent colouring belongs to COMMITTED rings only (queued = true). A ring
	# still following the cursor stays plain white — it is asking "where will
	# this land", not "is this safe to stand in", so it must not pre-judge a shot
	# that may never be taken.
	var hb: Color = Ability.intent_border_color(Ability.Intent.HOSTILE, true)
	var bb: Color = Ability.intent_border_color(Ability.Intent.BENEFICIAL, true)
	var hl := 0.2126 * hb.r + 0.7152 * hb.g + 0.0722 * hb.b
	var bl := 0.2126 * bb.r + 0.7152 * bb.g + 0.0722 * bb.b
	_check("palette.luminance-separated", absf(hl - bl) > 0.25,
		"hostile %.2f vs beneficial %.2f" % [hl, bl])
	_check("palette.dash-distinguishes",
		Ability.intent_border_dashed(Ability.Intent.BENEFICIAL, true)
		and not Ability.intent_border_dashed(Ability.Intent.HOSTILE, true))
	_check("palette.weight-distinguishes",
		Ability.intent_border_width(Ability.Intent.HOSTILE, true)
		> Ability.intent_border_width(Ability.Intent.BENEFICIAL, true))
	_check("palette.no-blue-remains", hb.b < hb.r and bb.b < bb.r,
		"hostile b=%.2f beneficial b=%.2f" % [hb.b, bb.b])

	# --- uncommitted rings are WHITE, whatever the intent ---------------------
	for it in [Ability.Intent.HOSTILE, Ability.Intent.BENEFICIAL, Ability.Intent.NEUTRAL]:
		var lf: Color = Ability.intent_fill_color(it, false)
		var lb: Color = Ability.intent_border_color(it, false)
		var white := lf.r == 1.0 and lf.g == 1.0 and lf.b == 1.0 \
			and lb.r == 1.0 and lb.g == 1.0 and lb.b == 1.0
		_check("live.white-intent-%d" % it, white,
			"fill %s border %s" % [str(lf), str(lb)])
	# ...and carry no shape cue either, so "aiming" reads as one uniform state.
	_check("live.no-dash", not Ability.intent_border_dashed(Ability.Intent.BENEFICIAL, false))
	_check("live.uniform-width",
		Ability.intent_border_width(Ability.Intent.HOSTILE, false)
		== Ability.intent_border_width(Ability.Intent.BENEFICIAL, false))

	print("ability_intent_check: %d checks, %d failures" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)
