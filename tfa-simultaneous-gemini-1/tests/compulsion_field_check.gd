extends Node2D
# CompulsionField: the shared mechanism behind Bloodmusk, Persistent Distraction
# and the Erisian Apple.
#
# The load-bearing promises are (a) the audience is exactly who can perceive the
# field and qualifies for it -- gender and creature type included, (b) an
# incited creature attacks its designated victim even across faction lines,
# which is the one thing no other mechanic in the game can do, (c) releasing the
# compulsion also releases the TARGET (the bug `confused` still carries), (d) a
# tactical pause freezes the field instead of letting it burn its duration, and
# (e) nothing here perturbs _is_enemy for an uncompelled character.
# Headless-safe.  Run:  godot --headless --path . res://tests/compulsion_field_check.tscn

const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

var fails := 0
var checks := 0

# CompulsionField.audience() and AbilityEffect._get_game_scene both duck-type the
# game scene -- the first by the `characters_in_scene` property, the second by
# these two methods. Answering to all three makes this node the game.
var characters_in_scene: Array = []


func create_item(_a = null, _b = null, _c = null) -> Node:
	return null


func _spawn_character(_a = null, _b = null, _c = null) -> Node:
	return null


func _check(cname: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if not ok:
		fails += 1
	print("%s %s %s" % ["PASS" if ok else "FAIL", cname, detail])


# Drive the field by hand: _process is its only clock and headless has no stable
# frame rate to lean on.
func _pump(node: Node, seconds: float, step: float = 0.05) -> void:
	var elapsed: float = 0.0
	while elapsed < seconds and is_instance_valid(node):
		node._process(step)
		elapsed += step


func _make(pos: Vector2, gender: String, faction: String, ctype: String = "Humanoid") -> ProceduralCharacter:
	var pc: ProceduralCharacter = PC_SCENE.instantiate()
	add_child(pc)
	pc.global_position = pos
	pc.gender = gender
	pc.faction_id = faction
	pc.creature_type = ctype
	characters_in_scene.append(pc)
	return pc


func _field(cfg: Dictionary) -> CompulsionField:
	var f := CompulsionField.new()
	for k in cfg:
		f.set(String(k), cfg[k])
	add_child(f)
	f.global_position = cfg.get("_pos", Vector2.ZERO)
	return f


func _ready() -> void:
	await get_tree().process_frame

	# A crowd: two men and two women of one faction, one woman of another, and a
	# beast. All within a 256px radius of the origin.
	var man_a := _make(Vector2(40, 0), "male", "bandits")
	var man_b := _make(Vector2(120, 0), "male", "bandits")
	var woman_a := _make(Vector2(0, 40), "female", "bandits")
	var woman_b := _make(Vector2(0, 150), "female", "golden_guard")
	var beast := _make(Vector2(60, 60), "male", "wildlife", "Beast")
	var far_man := _make(Vector2(900, 0), "male", "bandits")
	await get_tree().process_frame

	# --- _is_enemy is untouched for an uncompelled character ------------------
	# MUST run before any CompulsionField exists. A field in the tree is live:
	# Godot ticks its _process and it pulses on its first frame, so a field
	# created above this point can incite man_a before the baseline is read.
	var ai_a: Node = man_a.get_node_or_null("AI")
	_check("ai.node-present", ai_a != null)
	if ai_a == null:
		_finish()
		return
	# Same faction: the oracle says no, and nothing about this feature may change
	# that until a compulsion is actually written.
	_check("enemy.same-faction-baseline", not ai_a._is_enemy(man_b),
		"'%s' vs '%s' | oracle=%s | char_is_a=%s | compel=%s | manhunt=%s truce=%.1f" % [
			man_a.faction_id, man_b.faction_id,
			str(FactionDatabase.are_hostile(man_a.faction_id, man_b.faction_id)),
			str(ai_a.character == man_a), str(ai_a.compel_victim),
			str(ai_a.manhunt_target), ai_a.truce_until])
	_check("enemy.cross-faction-baseline", ai_a._is_enemy(woman_b),
		"'%s' vs '%s'" % [man_a.faction_id, woman_b.faction_id])


	# --- audience: radius reach, humanoid filter ------------------------------
	var f_all := _field({"radius": 256.0, "reach": "radius", "affects": "all",
		"affects_humanoid_only": true, "duration": 12.0, "pulse_interval": 3.0})
	await get_tree().process_frame
	var aud: Array = f_all.audience()
	_check("audience.excludes-far", not (far_man in aud), "%d in audience" % aud.size())
	_check("audience.excludes-beast", not (beast in aud), "beast creature_type=Beast")
	_check("audience.includes-humanoids-in-range",
		man_a in aud and man_b in aud and woman_a in aud and woman_b in aud,
		"%d of 4 present" % aud.size())

	# --- audience: gender filter ---------------------------------------------
	var f_fem := _field({"radius": 256.0, "reach": "radius", "affects": "female",
		"affects_humanoid_only": true, "duration": 12.0})
	await get_tree().process_frame
	var fem: Array = f_fem.audience()
	_check("audience.female-only",
		woman_a in fem and woman_b in fem and not (man_a in fem) and not (man_b in fem),
		"%d female in range" % fem.size())

	# --- the compulsion crosses faction lines --------------------------------
	ai_a.compel_victim = man_b
	_check("enemy.compelled-ally-is-enemy", ai_a._is_enemy(man_b),
		"same-faction victim must read as an enemy")
	ai_a.compel_victim = null
	_check("enemy.release-restores-oracle", not ai_a._is_enemy(man_b))

	# --- same_gender victim selection is nearest-of-that-gender ---------------
	var f_musk := _field({"radius": 256.0, "reach": "radius", "affects": "all",
		"affects_humanoid_only": true, "duration": 12.0, "pulse_interval": 3.0,
		"condition_id": "incited", "victim_rule": "same_gender",
		"victim_search_radius": 512.0})
	await get_tree().process_frame
	var picked = f_musk._pick_victim(man_a, f_musk._nearby_living(man_a))
	_check("victim.same-gender-nearest", picked == man_b,
		"man_a -> %s (want man_b)" % (picked.name if picked else "null"))
	var picked_f = f_musk._pick_victim(woman_a, f_musk._nearby_living(woman_a))
	_check("victim.female-picks-female", picked_f == woman_b,
		"woman_a -> %s (want woman_b)" % (picked_f.name if picked_f else "null"))

	# --- a pulse applies, points, and the AI acquires across factions ---------
	# Saves are real, so force the outcome by removing the save gate for the
	# duration of this case rather than looping until the dice cooperate.
	# Reset: the audience fields above are live and have been pulsing. Clear what
	# they did so this case measures f_musk's pulse and nothing else.
	for c in characters_in_scene:
		var cmx = c.get_node_or_null("ConditionManager")
		if cmx != null:
			cmx.remove_condition("incited")
			cmx.remove_condition("transfixed")
		var aix = c.get_node_or_null("AI")
		if aix != null:
			aix.compel_victim = null
			aix.compel_focus = null
	var tmpl = ConditionManager.condition_registry.get("incited")
	var saved_stat: String = tmpl.save_stat
	tmpl.save_stat = ""
	f_musk._pulse()
	var cm_a = man_a.get_node_or_null("ConditionManager")
	_check("pulse.applies-condition", cm_a.has_active_condition("incited"))
	_check("pulse.points-at-victim", ai_a.compel_victim == man_b,
		"compel_victim = %s" % (ai_a.compel_victim.name if ai_a.compel_victim else "null"))
	ai_a._update_target()
	_check("pulse.acquires-same-faction-target", ai_a.current_target == man_b,
		"current_target = %s" % (ai_a.current_target.name if ai_a.current_target else "null"))

	# --- releasing the compulsion releases the target too ---------------------
	# This is the bug `confused` still has: it never clears current_target, so a
	# confused NPC keeps killing the ally it picked long after it stops being
	# confused.
	cm_a.remove_condition("incited")
	ai_a._update_target()
	_check("release.clears-victim", ai_a.compel_victim == null)
	_check("release.clears-target", ai_a.current_target != man_b,
		"current_target = %s" % (ai_a.current_target.name if ai_a.current_target else "null"))
	tmpl.save_stat = saved_stat

	# --- pause freezes the field ---------------------------------------------
	var age_before: float = f_all._age
	PauseManager.is_paused = true
	_pump(f_all, 3.0)
	PauseManager.is_paused = false
	_check("pause.freezes-clock", is_equal_approx(f_all._age, age_before),
		"age %.2f -> %.2f across a 3s pause" % [age_before, f_all._age])

	# --- expiry ---------------------------------------------------------------
	_pump(f_all, 13.0)
	await get_tree().process_frame
	await get_tree().process_frame
	_check("field.expires", not is_instance_valid(f_all), "freed at duration 12.0")

	_case_authored_data()
	_finish()


# The three authored spells, through the real dispatcher.
func _case_authored_data() -> void:
	var af := FileAccess.open("res://data/Abilities.json", FileAccess.READ)
	var js := JSON.new()
	var by_id: Dictionary = {}
	if af != null and js.parse(af.get_as_text()) == OK:
		for entry in js.get_data().get("abilities", []):
			if entry is Dictionary:
				by_id[String(entry.get("id", ""))] = entry

	for spell_id in ["bloodmusk", "persistent_distraction", "erisian_apple"]:
		var a: Dictionary = by_id.get(spell_id, {})
		_check("data.%s-present" % spell_id, not a.is_empty())
		if a.is_empty():
			continue
		var payload: Dictionary = a["effects"][0]
		_check("data.%s-is-compulsion" % spell_id,
			String(payload.get("type", "")) == "compulsion_field",
			"reach=%s affects=%s cond=%s" % [
				payload.get("reach", ""), payload.get("affects", ""),
				payload.get("condition_id", "")])

		# Every authored resource path must resolve: Ability.from_dict guards the
		# icon with ResourceLoader.exists and silently leaves it null on a miss,
		# and CompulsionField does the same for vfx_scene and sprite_path.
		var paths: Array = [String(a.get("icon", "")),
			String(a.get("visuals", {}).get("in_hand_effect", "")),
			String(a.get("visuals", {}).get("sound_cast", "")),
			String(payload.get("vfx_scene", ""))]
		if not String(payload.get("sprite_path", "")).is_empty():
			paths.append(String(payload["sprite_path"]))
		for p in paths:
			_check("asset.%s" % spell_id, ResourceLoader.exists(p), p)

		# The condition it applies must be registered, or apply_condition warns
		# and returns null forever and the spell is a silent no-op.
		var cid: String = String(payload.get("condition_id", ""))
		_check("cond.%s-registered" % cid,
			ConditionManager.condition_registry.has(cid), cid)

		# The in-hand scene must have a Node2D root or AbilityShape skips it.
		var hs = load(String(a.get("visuals", {}).get("in_hand_effect", "")))
		var hi = hs.instantiate() if hs != null else null
		_check("vfx.%s-hand-node2d" % spell_id, hi is Node2D, str(hi))
		if hi != null:
			hi.queue_free()
		# The field visual must answer play_field or it never starts emitting.
		var gs = load(String(payload.get("vfx_scene", "")))
		var gi = gs.instantiate() if gs != null else null
		_check("vfx.%s-field-contract" % spell_id,
			gi is Node2D and gi.has_method("play_field"), str(gi))
		if gi != null:
			gi.queue_free()

		# Dispatch: the authored payload through the real match arm.
		var res: Dictionary = AbilityEffect.resolve_effect(payload, self, [], null, Vector2(4000, 4000))
		var made: Array = res.get("created_objects", [])
		var spawned = made[0] if made.size() > 0 else null
		_check("dispatch.%s" % spell_id, spawned is CompulsionField,
			"%d objects, err=%s" % [made.size(), res.get("error", "")])
		if spawned is CompulsionField:
			_check("dispatch.%s-payload" % spell_id,
				spawned.condition_id == String(payload.get("condition_id", ""))
					and spawned.affects == String(payload.get("affects", "all")),
				"cond=%s affects=%s reach=%s" % [spawned.condition_id, spawned.affects, spawned.reach])
			spawned.queue_free()


func _finish() -> void:
	print("compulsion_field_check: %d checks, %d failures" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)
