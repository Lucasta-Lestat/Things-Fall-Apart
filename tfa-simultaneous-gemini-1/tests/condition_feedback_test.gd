# res://tests/condition_feedback_test.gd
# Headless assertion harness for condition and condition-rider feedback:
# trait-keyed immunities, apply-time and periodic save notices (and their
# silence for hidden NPCs and corpses), transforms_into (Chilled 3 -> Frozen,
# which roots), missed chance riders and effect-level saves, Chasten's
# cleanse report, force fields (outline, Magnetic Pull's traits), and a
# throw giving its thrower away.
# Drives the real game scene the way feedback_layer_test does.
# Run:  godot --headless --path . res://tests/condition_feedback_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

const PC_SCENE_PATH := "res://Characters/ProceduralCharacter.tscn"

var failures := 0
var game = null
var spawned: Array = []

func _check(check_name: String, cond: bool, detail = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, str(detail)])

func _await_frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

func _ready() -> void:
	TimeManager.pause_time()
	await get_tree().process_frame
	var GameScene := load("res://game.tscn")
	game = GameScene.instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _await_frames(2)
	game.load_map("town_square")
	await _await_frames(10)

	await _case_immunity()
	await _case_save_notices()
	await _case_periodic_and_corpse()
	await _case_transforms()
	await _case_riders()
	await _case_lethal_rider()
	await _case_chasten()
	await _case_force_fields()
	await _case_ai_ticks()
	await _case_throw_reveal()

	for c in spawned:
		if is_instance_valid(c):
			c.queue_free()
	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## A bare NPC with no AI, placed far from the party.
func _spawn(char_name: String, pos: Vector2) -> Node:
	var ch = load(PC_SCENE_PATH).instantiate()
	ch.AI_enabled = false
	ch.is_player_controlled = false
	ch.Name = char_name
	game.add_child(ch)
	ch.global_position = pos
	spawned.append(ch)
	return ch

func _last_log() -> String:
	var entries: Array = GameLog.get_entries()
	return str(entries[-1].text) if not entries.is_empty() else ""

func _logged_since(n0: int, fragment: String) -> bool:
	var entries: Array = GameLog.get_entries()
	for i in range(n0, entries.size()):
		if fragment in str(entries[i].text):
			return true
	return false

func _reset_notices(ch) -> void:
	ch._last_notify_text = ""
	ch.condition_manager._last_notice_ms.clear()

func _party():
	return game.party_chars[0]

# ---------------------------------------------------------------------------
# Trait-keyed immunities
# ---------------------------------------------------------------------------

func _case_immunity() -> void:
	var n = _spawn("Hasty", Vector2(3000, 3000))
	await _await_frames(2)
	var cm = n.condition_manager
	cm.apply_condition("hasted", null)
	_check("immunity.hasted-blocks-slowed", cm.apply_condition("slowed", null) == null and not cm.has_condition("slowed"))
	_check("immunity.hasted-blocks-chilled", cm.apply_condition("chilled", null) == null and not cm.has_condition("chilled"))
	cm.clear_all_conditions()
	cm.apply_condition("shielded", null)
	_check("immunity.shielded-blocks-burning", cm.apply_condition("burning", null) == null)
	# A trait key wards off debuffs only: Winter's Grip (the drawn blade's item
	# condition, cold-flavoured) still lands under Shielded; its bite doesn't.
	_check("immunity.trait-spares-item-condition", cm.apply_condition("winters_grip", null) != null)
	_check("immunity.trait-blocks-item-debuff", cm.apply_condition("winters_grip_bite", null) == null)
	cm.clear_all_conditions()
	# Frozen carries the cold trait it is immune to: re-applying refreshes it.
	var f1 = cm.apply_condition("frozen", null)
	var f2 = cm.apply_condition("frozen", null)
	_check("immunity.never-blocks-itself", f1 != null and f2 == f1)
	_check("immunity.frozen-blocks-chilled", cm.apply_condition("chilled", null) == null)
	cm.clear_all_conditions()

	# The notice: a party member floats "Immune" and the log names the cause.
	var p = _party()
	var pcm = p.condition_manager
	var saved: Dictionary = pcm.to_dict()
	pcm.clear_all_conditions()
	pcm.apply_condition("hasted", null)
	_reset_notices(p)
	var n0: int = GameLog.get_entries().size()
	pcm.apply_condition("slowed", n)
	_check("immunity.notice-floats", p._last_notify_text == "Immune", p._last_notify_text)
	_check("immunity.notice-logged", _logged_since(n0, "%s is immune to Slowed (Hasted)." % p.Name), _last_log())
	# No source (surfaces, fire tiles) stays quiet.
	_reset_notices(p)
	n0 = GameLog.get_entries().size()
	pcm.apply_condition("slowed", null)
	_check("immunity.sourceless-quiet", p._last_notify_text == "" and GameLog.get_entries().size() == n0)
	pcm.from_dict(saved)

# ---------------------------------------------------------------------------
# Apply-time saves
# ---------------------------------------------------------------------------

func _case_save_notices() -> void:
	var foe = _spawn("Cutter", Vector2(3100, 3000))
	var p = _party()
	var pcm = p.condition_manager
	var saved: Dictionary = pcm.to_dict()
	var con0: int = p.constitution
	# The -500 CON fixture clamps HP to 1 when the conditions recalculate
	# (max HP is 20 + CON/5, character lane): give it back afterwards.
	var hp0: int = p.current_health
	pcm.clear_all_conditions()

	# A sure pass (margin >= 50) throws the whole application off.
	p.constitution = 500
	_reset_notices(p)
	var n0: int = GameLog.get_entries().size()
	var inst = pcm.apply_condition("bleeding", foe, 1)
	_check("save.resisted-null", inst == null)
	_check("save.resisted-floats", p._last_notify_text == "Resisted", p._last_notify_text)
	_check("save.resisted-logged-with-roll", _logged_since(n0, "%s resists Bleeding (CON save: rolled " % p.Name) and _logged_since(n0, " vs 500)."), _last_log())
	# Throttled: an identical notice inside the window is held back.
	p._last_notify_text = ""
	n0 = GameLog.get_entries().size()
	pcm.apply_condition("bleeding", foe, 1)
	_check("save.throttled", p._last_notify_text == "" and GameLog.get_entries().size() == n0)

	# A sure crit fail (margin <= -50) on a stackable adds a stack.
	p.constitution = -500
	_reset_notices(p)
	n0 = GameLog.get_entries().size()
	inst = pcm.apply_condition("bleeding", foe, 1)
	_check("save.crit-fail-extra-stack", inst != null and inst.stacks == 2, str(inst.stacks if inst else -1))
	_check("save.crit-fail-floats", p._last_notify_text == "Critical fail", p._last_notify_text)
	_check("save.crit-fail-logged", _logged_since(n0, "%s critically fails against Bleeding" % p.Name), _last_log())
	pcm.remove_condition("bleeding")

	# A field or cloud (not a character) re-applying on its pulse waits longer.
	p.constitution = 500
	var field := Node2D.new()
	add_child(field)
	_reset_notices(p)
	pcm.apply_condition("bleeding", field, 1)
	_check("save.area-source-floats", p._last_notify_text == "Resisted")
	var key := "bleeding:Resisted"
	pcm._last_notice_ms[key] = Time.get_ticks_msec() - (pcm.NOTICE_REPEAT_MS + 500)
	p._last_notify_text = ""
	pcm.apply_condition("bleeding", field, 1)
	_check("save.area-source-longer-window", p._last_notify_text == "", p._last_notify_text)
	pcm._last_notice_ms[key] = Time.get_ticks_msec() - (pcm.NOTICE_REPEAT_MS + 500)
	pcm.apply_condition("bleeding", foe, 1)
	_check("save.character-source-short-window", p._last_notify_text == "Resisted", p._last_notify_text)
	field.queue_free()

	# Hidden NPCs: no float and no log, and the throttle isn't used up.
	foe.constitution = 500
	var hidden = _spawn("Lurker", Vector2(3200, 3000))
	await _await_frames(2)
	hidden.constitution = 500
	hidden.visible = false
	# "Seen" is line of sight (Game.is_seen_by_party, via the bearer's
	# _announces_to_party), not `visible`: a hearing pulse shows unseen NPCs.
	game.characters_in_scene.append(hidden)
	game._npc_was_truly_seen[hidden] = false
	_reset_notices(hidden)
	n0 = GameLog.get_entries().size()
	hidden.condition_manager.apply_condition("bleeding", p, 1)
	_check("save.hidden-npc-quiet", hidden._last_notify_text == "" and GameLog.get_entries().size() == n0 \
		and hidden.condition_manager._last_notice_ms.is_empty())
	hidden.visible = true
	game._npc_was_truly_seen[hidden] = true
	hidden.condition_manager.apply_condition("bleeding", p, 1)
	_check("save.seen-npc-floats", hidden._last_notify_text == "Resisted", hidden._last_notify_text)
	_check("save.party-source-logs", _logged_since(n0, "Lurker resists Bleeding"), _last_log())
	game.characters_in_scene.erase(hidden)
	game._npc_was_truly_seen.erase(hidden)

	p.constitution = con0
	p.current_health = hp0
	pcm.from_dict(saved)

# ---------------------------------------------------------------------------
# Periodic saves; corpses don't roll
# ---------------------------------------------------------------------------

func _case_periodic_and_corpse() -> void:
	var foe = _spawn("Slasher", Vector2(3300, 3000))
	var p = _party()
	var pcm = p.condition_manager
	var saved: Dictionary = pcm.to_dict()
	var con0: int = p.constitution
	# CON swings max HP (20 + CON/5) and a recalculation clamps HP down to it
	# (character lane): keep the fixture alive and give its HP back after.
	var hp0: int = p.current_health
	pcm.clear_all_conditions()
	p.constitution = 0  # lands at a plain fail (roll 1..100 vs 0, margin > -50 mostly)
	var inst = null
	for i in 10:
		inst = pcm.apply_condition("bleeding", foe, 3)
		if inst != null:
			break
	_check("periodic.fixture", inst != null)
	if inst != null:
		p.constitution = 500
		p.current_health = p.max_health   # CON 0 above clamped HP to 20; ticks follow
		_reset_notices(p)
		var n0: int = GameLog.get_entries().size()
		var now: float = TimeManager.absolute_time()
		pcm.last_save_times["bleeding"] = now - 100.0
		# Stacks 3+ drop by 2 per sure pass: first an "eases", then "shakes off".
		pcm._process(0.016)
		# Stacks, as the summaries count them ("Bleeding x2"): 3 or 4 landed, -2.
		_check("periodic.eases-logged", _logged_since(n0, "%s's Bleeding eases to 1 stack (" % p.Name)
			or _logged_since(n0, "%s's Bleeding eases to 2 stacks (" % p.Name), _last_log())
		pcm.last_save_times["bleeding"] = now - 100.0
		pcm._process(0.016)
		if pcm.has_condition("bleeding"):
			pcm.last_save_times["bleeding"] = now - 100.0
			pcm._process(0.016)
		_check("periodic.shook-off", not pcm.has_condition("bleeding"))
		_check("periodic.shook-off-floats", p._last_notify_text == "Shook off Bleeding", p._last_notify_text)
		_check("periodic.shook-off-logged", _logged_since(n0, "%s shakes off Bleeding (CON save: rolled" % p.Name), _last_log())
	p.constitution = con0
	p.current_health = hp0
	pcm.from_dict(saved)

	# A corpse keeps its conditions but rolls nothing.
	var dead = _spawn("Corpse", Vector2(3400, 3000))
	await _await_frames(2)
	dead.constitution = 0
	var dcm = dead.condition_manager
	var dinst = null
	for i in 10:
		dinst = dcm.apply_condition("bleeding", foe, 2)
		if dinst != null:
			break
	dead.current_health = 0
	dead._check_death()
	await _await_frames(1)
	if dcm.has_condition("bleeding"):
		dcm.last_save_times["bleeding"] = -1000.0
		dcm._process(0.016)
		_check("corpse.no-periodic-save", float(dcm.last_save_times.get("bleeding", 0.0)) == -1000.0)
	else:
		_check("corpse.fixture", false, "no bleeding on the corpse")

# ---------------------------------------------------------------------------
# transforms_into
# ---------------------------------------------------------------------------

func _case_transforms() -> void:
	var n = _spawn("Shiver", Vector2(3500, 3000))
	await _await_frames(2)
	var cm = n.condition_manager
	var speed0: float = n.move_speed
	cm.apply_condition("chilled", null, 2)
	_check("transform.below-tier-stays", cm.has_condition("chilled") and not cm.has_condition("frozen"))
	var out = cm.apply_condition("chilled", null, 1)
	_check("transform.chilled-to-frozen", cm.has_condition("frozen") and not cm.has_condition("chilled") \
		and out != null and out.condition.id == "frozen")
	_check("frozen.roots", speed0 > 0.0 and is_equal_approx(n.move_speed, 0.0), "%s -> %s" % [speed0, n.move_speed])
	cm.clear_all_conditions()
	_check("frozen.thaws", n.move_speed > 0.0)
	var fresh = cm.apply_condition("chilled", null, 3)
	_check("transform.fresh-instance", fresh != null and fresh.condition.id == "frozen")
	cm.clear_all_conditions()
	cm.apply_condition("fatigued", null, 3)
	_check("transform.fatigued-to-exhausted", cm.has_condition("exhausted") and not cm.has_condition("fatigued"))
	cm.clear_all_conditions()
	# A transform into a condition that isn't registered is skipped and the
	# condition stays (a test condition: every shipped target is registered).
	ConditionManager.register_conditions([{"id": "cft_unreg_transform", "stackable": true, "max_tier": 2,
		"duration": 30.0, "traits": {"debuff": 1}, "canceled_by_trait": [], "immunities": {},
		"transforms_into": {"id": "no_such_condition", "required_tier": 2}}])
	var unreg = cm.apply_condition("cft_unreg_transform", null, 2)
	_check("transform.unregistered-target-skipped", unreg != null and unreg.stacks == 2 and cm.has_condition("cft_unreg_transform"))
	# Every shipped transforms_into names a registered condition at a tier its
	# condition can reach (round 4 found Poisoned's toxic_shock at tier 10, past
	# its cap of 4, and never defined; round 5 defines it and turns at 4).
	for cid in ConditionManager.condition_registry:
		var tf: Dictionary = ConditionManager.condition_registry[cid].transforms_into
		if tf.is_empty() or cid.begins_with("cft_"):
			continue
		_check("transform.%s-target-registered" % cid, ConditionManager.condition_registry.has(str(tf.get("id", ""))), tf)
		_check("transform.%s-tier-reachable" % cid, int(tf.get("required_tier", 999)) <= ConditionManager.condition_registry[cid].max_tier, tf)
	cm.apply_condition("poisoned", null, 10)
	_check("transform.poisoned-to-toxic-shock", cm.has_condition("toxic_shock") and not cm.has_condition("poisoned"), cm.get_all_condition_ids())
	cm.clear_all_conditions()

	# The party is told.
	var p = _party()
	var pcm = p.condition_manager
	var saved: Dictionary = pcm.to_dict()
	pcm.clear_all_conditions()
	_reset_notices(p)
	var n0: int = GameLog.get_entries().size()
	pcm.apply_condition("chilled", n, 3)
	_check("transform.party-floats", p._last_notify_text == "Frozen!", p._last_notify_text)
	_check("transform.party-logged", _logged_since(n0, "%s's Chilled reaches 3 stacks: Frozen." % p.Name), _last_log())
	pcm.from_dict(saved)

# ---------------------------------------------------------------------------
# Chance riders and effect-level saves
# ---------------------------------------------------------------------------

func _rider_ability(effect: Dictionary) -> Ability:
	return Ability.from_dict({
		"id": "harness_rider", "display_name": "Harness Rider", "traits": {},
		"targeting": {"type": "point", "shape": "circle", "radius": 10.0},
		"effects": [effect],
	})

func _case_riders() -> void:
	var p = _party()
	var npc = _spawn("Target", Vector2(3600, 3000))
	await _await_frames(2)
	# Rider notices need the target in the party's line of sight
	# (_announces_to_party), not just `visible`. Set after every await: the
	# LOS pass rewrites the cache each unpaused frame.
	game.characters_in_scene.append(npc)
	game._npc_was_truly_seen[npc] = true
	var eff := {"type": "apply_condition", "condition_id": "chilled", "chance": 0.0}
	var ab := _rider_ability(eff)
	_reset_notices(npc)
	var n0: int = GameLog.get_entries().size()
	var r: Dictionary = AbilityEffect.resolve_effect(eff, p, [npc], ab, npc.global_position)
	_check("rider.chance-miss-applies-nothing", r.get("conditions_applied", []).is_empty() and not npc.condition_manager.has_condition("chilled"))
	_check("rider.chance-miss-floats", npc._last_notify_text == "Resisted", npc._last_notify_text)
	_check("rider.chance-miss-logged", _logged_since(n0, "Target avoids Chilled from Harness Rider (0% chance: rolled "), _last_log())

	# A buff that misses says "No effect".
	var buff := {"type": "apply_condition", "condition_id": "hasted", "chance": 0.0}
	npc._last_notify_text = ""
	AbilityEffect.resolve_effect(buff, p, [npc], _rider_ability(buff), npc.global_position)
	_check("rider.buff-miss-no-effect", npc._last_notify_text == "No effect", npc._last_notify_text)
	_check("rider.buff-miss-wording", "doesn't gain Hasted" in _last_log(), _last_log())

	# Hidden targets stay quiet, even for the party's own cast: the log line
	# would name an NPC the party can't see.
	npc.visible = false
	game._npc_was_truly_seen[npc] = false
	npc._last_notify_text = ""
	n0 = GameLog.get_entries().size()
	AbilityEffect.resolve_effect(eff, p, [npc], ab, npc.global_position)
	_check("rider.hidden-target-quiet", npc._last_notify_text == "" and GameLog.get_entries().size() == n0, _last_log())
	npc.visible = true

	# NPC on NPC: floats, no log. Both in view; the caster's seen state only
	# matters as the caster.
	var other = _spawn("Bystander", Vector2(3650, 3000))
	await _await_frames(1)
	game.characters_in_scene.append(other)
	game._npc_was_truly_seen[other] = true
	game._npc_was_truly_seen[npc] = true
	npc._last_notify_text = ""
	n0 = GameLog.get_entries().size()
	AbilityEffect.resolve_effect(eff, other, [npc], ab, npc.global_position)
	_check("rider.npc-only-float-no-log", npc._last_notify_text == "Resisted" and GameLog.get_entries().size() == n0)

	# Effect-level save_stat (dev's per-application save).
	npc.constitution = 500
	var saved_eff := {"type": "apply_condition", "condition_id": "slowed", "save_stat": "con"}
	npc._last_notify_text = ""
	n0 = GameLog.get_entries().size()
	AbilityEffect.resolve_effect(saved_eff, p, [npc], _rider_ability(saved_eff), npc.global_position)
	_check("rider.effect-save-floats", npc._last_notify_text == "Resisted" and not npc.condition_manager.has_condition("slowed"), npc._last_notify_text)
	_check("rider.effect-save-logged", _logged_since(n0, "Target resists Slowed from Harness Rider (CON save: rolled "), _last_log())

	for c in [npc, other]:
		game.characters_in_scene.erase(c)
		game._npc_was_truly_seen.erase(c)

	_check("rider.display-name", AbilityEffect.condition_display_name("chilled") == "Chilled" \
		and AbilityEffect.condition_display_name("no_such_thing") == "No Such Thing")

	# Data: the riders' descriptions state their chance.
	for pair in [["ice_storm", "80%"], ["gravity_well", "60%"], ["shield_bash", "70%"], ["creepy_beam", "50%"]]:
		var desc := str(AbilityDatabase.get_ability_data(pair[0]).get("description", ""))
		_check("data.%s-states-chance" % pair[0], pair[1] in desc, desc)

# ---------------------------------------------------------------------------
# A killing blow's rider (dmg-03): Fireball's damage kills, then its own
# Burning lands on the corpse. ConditionManager refuses corpses, so no Burning
# and no flames stay on the tombstone.
# ---------------------------------------------------------------------------

func _case_lethal_rider() -> void:
	var p = _party()
	var npc = _spawn("Kindling", Vector2(3700, 3000))
	await _await_frames(2)
	npc.current_health = 1
	var fb := Ability.from_dict(AbilityDatabase.get_ability_data("fireball"))
	npc.begin_damage_condition_suppression({"burning": true})
	for eff in fb.effects:
		AbilityEffect.resolve_effect(eff, p, [npc], fb, npc.global_position)
	npc.end_damage_condition_suppression()
	_check("lethal-rider.dead", not npc.is_alive())
	_check("lethal-rider.no-burning", not npc.condition_manager.has_condition("burning"))
	_check("lethal-rider.no-flames", npc._active_condition_vfx.is_empty(), npc._active_condition_vfx.keys())

# ---------------------------------------------------------------------------
# Chasten
# ---------------------------------------------------------------------------

func _case_chasten() -> void:
	var data: Dictionary = AbilityDatabase.get_ability_data("chasten")
	var eff: Dictionary = data.get("effects", [{}])[0]
	_check("chasten.by-condition-id", str(eff.get("condition_id", "")) == "infatuated" and not eff.has("trait"), str(eff))
	var chasten := Ability.from_dict(data)
	_check("chasten.reads-beneficial", Ability.classify_intent(data) == Ability.Intent.BENEFICIAL)
	var p = _party()
	var charmer = _spawn("Charmer", Vector2(3700, 3000))
	await _await_frames(2)
	var pcm = p.condition_manager
	var saved: Dictionary = pcm.to_dict()
	pcm.clear_all_conditions()
	pcm.apply_condition("infatuated", charmer, 1, 20.0)
	var had: bool = pcm.has_condition("infatuated")
	_reset_notices(p)
	var n0: int = GameLog.get_entries().size()
	for e in chasten.effects:
		AbilityEffect.resolve_effect(e, p, [p], chasten, p.global_position)
	_check("chasten.ends-infatuation", had and not pcm.has_condition("infatuated"), str(had))
	_check("chasten.cleansed-floats", p._last_notify_text == "Cleansed", p._last_notify_text)
	_check("chasten.logged", _logged_since(n0, "Chasten ends Infatuated on %s." % p.Name), _last_log())
	p._last_notify_text = ""
	for e in chasten.effects:
		AbilityEffect.resolve_effect(e, p, [p], chasten, p.global_position)
	_check("chasten.nothing-to-remove", p._last_notify_text == "No effect", p._last_notify_text)

	# A cleanse riding on another effect (Heal's poison cure) stays quiet.
	var heal := Ability.from_dict(AbilityDatabase.get_ability_data("heal"))
	_check("cleanse.heal-not-cleanse-only", not AbilityEffect._is_cleanse_only(heal))
	pcm.from_dict(saved)

# ---------------------------------------------------------------------------
# Force fields
# ---------------------------------------------------------------------------

func _case_force_fields() -> void:
	var p = _party()
	var pull: Dictionary = AbilityDatabase.get_ability_data("magnetic_pull")
	var pull_eff: Dictionary = {}
	for e in pull.get("effects", []):
		if e is Dictionary and e.get("type", "") == "force_field":
			pull_eff = e
	var r: Dictionary = AbilityEffect.resolve_effect(pull_eff, p, [], Ability.from_dict(pull), p.global_position + Vector2(0, 400))
	var objs: Array = r.get("created_objects", [])
	var mag = objs[0] if not objs.is_empty() else null
	_check("field.magnetic-created", mag != null and mag is MagneticField)
	if mag != null:
		_check("field.outline-shown", mag.show_outline)
		_check("field.magnetic-keeps-data-traits", Array(mag.required_traits) == ["metal", "armored"], str(mag.required_traits))
		_check("field.magnetic-tint", mag._field_tint() == mag.field_color)
		var metal := Node2D.new()
		metal.set_meta("traits", ["Metal"])
		add_child(metal)
		_check("field.trait-case-insensitive", mag._should_affect_entity(metal))
		var plain := Node2D.new()
		add_child(plain)
		_check("field.filtered-skips-traitless", not mag._should_affect_entity(plain))
		metal.queue_free()
		plain.queue_free()
		mag.queue_free()

	var well: Dictionary = AbilityDatabase.get_ability_data("gravity_well")
	var well_eff: Dictionary = {}
	for e in well.get("effects", []):
		if e is Dictionary and e.get("type", "") == "force_field":
			well_eff = e
	r = AbilityEffect.resolve_effect(well_eff, p, [], Ability.from_dict(well), p.global_position + Vector2(0, 600))
	objs = r.get("created_objects", [])
	var grav = objs[0] if not objs.is_empty() else null
	_check("field.gravity-outline", grav != null and grav.show_outline)
	if grav != null:
		var bare := Node2D.new()
		add_child(bare)
		_check("field.unfiltered-moves-traitless", grav._should_affect_entity(bare))
		bare.queue_free()
		grav.queue_free()
	await _await_frames(1)

# ---------------------------------------------------------------------------
# AI: damage-over-time ticks are no sighting of whoever applied them
# ---------------------------------------------------------------------------

func _case_ai_ticks() -> void:
	var victim = _spawn("Guard", Vector2(3800, 3000))
	var foe = _spawn("Poisoner", Vector2(3900, 3000))
	await _await_frames(2)
	victim.faction_id = "golden_guard"
	foe.faction_id = "bandits"
	var ai = victim.get_node("AI")
	_check("ai.fixture-enemies", ai._is_enemy(foe))
	# Already chasing the poisoner, who has slipped out of sight.
	ai._acquire_target(foe)
	foe.global_position = Vector2(4400, 3400)
	ai._target_occluded_time = 1.5
	var seen_at: Vector2 = ai.last_known_target_pos
	var burn = victim.condition_manager.apply_condition("poisoned", foe, 1, 10.0)
	_check("ai.tick-fixture", burn != null)
	if burn != null:
		var hp0: int = victim.current_health
		burn.last_trigger_times.clear()
		victim.condition_manager._process(0.016)
		_check("ai.tick-dealt-damage", victim.current_health < hp0, [hp0, victim.current_health])
		_check("ai.tick-keeps-last-known", ai.last_known_target_pos == seen_at, [ai.last_known_target_pos, seen_at])
		_check("ai.tick-keeps-occlusion-clock", is_equal_approx(ai._target_occluded_time, 1.5), ai._target_occluded_time)
	# A real hit from them is still identification.
	victim.take_damage({"slashing": 1}, victim.global_position, foe)
	_check("ai.hit-refreshes", ai.last_known_target_pos == foe.global_position and is_equal_approx(ai._target_occluded_time, 0.0),
		[ai.last_known_target_pos, ai._target_occluded_time])

	# A victim with no target isn't handed one by a tick.
	var bystander = _spawn("Watchman", Vector2(3800, 3200))
	await _await_frames(2)
	bystander.faction_id = "golden_guard"
	var bai = bystander.get_node("AI")
	var p2 = bystander.condition_manager.apply_condition("poisoned", foe, 1, 10.0)
	if p2 != null:
		p2.last_trigger_times.clear()
		bystander.condition_manager._process(0.016)
	_check("ai.tick-no-acquire", bai.current_target == null, bai.current_target)
	_check("ai.tick-still-wakes", bai.alertness_value >= bai.ALERTNESS_SEARCHING_THRESHOLD, bai.alertness_value)
	_check("ai.flag-cleared", not bystander.condition_manager.firing_triggered_effect)

# ---------------------------------------------------------------------------
# A throw gives a concealed thrower away (R2-final-1). reveal() itself comes
# from the equipment lane's concealment; a stub stands in for it here.
# ---------------------------------------------------------------------------

class RevealStub extends CharacterBody2D:
	var reveals: int = 0
	func reveal(_seconds: float = 3.0) -> void:
		reveals += 1

func _case_throw_reveal() -> void:
	var stub := RevealStub.new()
	game.add_child(stub)
	stub.global_position = Vector2(5000, 3000)
	game._add_thrown_projectile({
		"type": "thrown_item", "item_data": {"id": "dagger"},
		"position": stub.global_position, "velocity": Vector2(300, 0),
		"shooter": stub, "max_range": 400.0, "damage": {"piercing": 1},
	})
	_check("throw.reveals-thrower", stub.reveals == 1, stub.reveals)
	# Clear the flight before it lands, so no dagger is dropped in the scene.
	for n in get_tree().current_scene.get_children():
		if n.name.begins_with("ThrownProjectile"):
			n.queue_free()
	stub.queue_free()
	await _await_frames(1)
