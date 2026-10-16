# res://tests/character_feedback_test.gd
# Headless assertion harness for the character lane of the feedback port:
# ProceduralCharacter's combat and state notices, the damage path (armour
# "-N blocked", "Blocked", elemental conditions, DoT ticks that aren't wounds),
# planning-queue fixes, unarmed planning, and the armour tooltip lines.
# Characters live under a stub Game (named /root/Game, so is_party_member()
# and _announces_to_party() read it) that is also the current scene.
# Run:  godot --headless --path . res://tests/character_feedback_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const ItemTooltip = preload("res://UI/ItemTooltip.gd")
const FT_SCRIPT = preload("res://UI/FloatingText.gd")

var failures := 0
var stub: Node2D = null
var log_lines: Array = []

class StubGame:
	extends Node2D
	var party_chars: Array = []
	var characters_in_scene: Array = []
	var structures_in_scene: Array = []
	var selected_characters: Array = []
	var primary_selected = null
	var context_menu_open: bool = false
	var stealth_mode: bool = false
	var roof_view: bool = false
	var seen: Dictionary = {}
	func is_seen_by_party(c) -> bool:
		if c in party_chars:
			return true
		return bool(seen.get(c, false))
	func register_attack_start(_a) -> void:
		pass
	func register_attack_end(_a) -> void:
		pass

func _check(check_name: String, cond: bool, detail = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, str(detail)])

func _await_frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

func _on_log(text: String, _t: String) -> void:
	log_lines.append(text)

func _logged(fragment: String) -> int:
	var n := 0
	for l in log_lines:
		if String(l).contains(fragment):
			n += 1
	return n

## Floating labels (FloatingText) directly under `parent`.
func _floats(parent: Node) -> Array:
	var out: Array = []
	for c in parent.get_children():
		if c is Label and c.get_script() == FT_SCRIPT and not c.is_queued_for_deletion():
			out.append(c.text)
	return out

func _floated(parent: Node, text: String) -> int:
	return _floats(parent).count(text)

func _spawn(pos: Vector2, party: bool = false, race: String = "human") -> ProceduralCharacter:
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	c.position = pos
	stub.add_child(c)
	RaceDatabase.apply_race_to_character(c, race, {"gender": "male"})
	c.AI_enabled = false
	c.Name = "Tester%d" % stub.characters_in_scene.size()
	stub.characters_in_scene.append(c)
	if party:
		stub.party_chars.append(c)
	return c

func _reset_notify(c) -> void:
	c._last_notify_text = ""
	c._last_notify_ms = -100000

func _ready() -> void:
	TimeManager.pause_time()
	GameLog.entry_added.connect(_on_log)
	_case_tooltips()

	await get_tree().process_frame
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	stub = StubGame.new()
	stub.name = "Game"
	stub.add_to_group("game")
	get_tree().root.add_child(stub)
	get_tree().current_scene = stub
	await _await_frames(2)

	await _case_damage_path()
	await _case_elemental()
	await _case_ticks_and_stress()
	_case_stats()
	await _case_icons()
	await _case_heal_deny_death()
	_case_souls_favour()
	await _case_custom_abilities()
	await _case_attack_refusals()
	await _case_planning()
	await _case_unarmed_and_hands()
	await _case_movement_notices()
	await _case_alertness_and_animator()
	_case_templates()

	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

# ---------------------------------------------------------------------------

func _item_entry(id: String, kind := "item") -> Dictionary:
	var data: Dictionary = ItemDatabase.get_item_data(id)
	return {"kind": kind, "display_name": data.get("display_name", id), "num_stacks": 1, "raw": data}

func _case_tooltips() -> void:
	var legion: PackedStringArray = ItemTooltip.armour_lines(_item_entry("legionnaires_armor"))
	_check("armour.torso-line", legion.size() >= 1 and legion[0] == "Armour (torso and arms): blocks 4 slashing, 3 bludgeoning, 3 piercing per hit", legion)
	_check("armour.weakness-line", legion.size() == 2 and legion[1] == "Weakness: +1 electric damage per hit", legion)
	var helm: PackedStringArray = ItemTooltip.armour_lines(_item_entry("kettle_helm"))
	_check("armour.helmet-head", helm.size() == 1 and helm[0] == "Armour (head): blocks 2 slashing, 2 bludgeoning, 2 piercing per hit", helm)
	_check("armour.zero-dr-boots-say-nothing", ItemTooltip.armour_lines(_item_entry("steel_greaves")).is_empty())
	var hood: PackedStringArray = ItemTooltip.armour_lines(_item_entry("dark_hood"))
	_check("armour.hood-elemental-and-weakness", hood.size() == 2 and hood[0] == "Armour (head): blocks 1 cold, 2 necrotic per hit" and hood[1] == "Weakness: +2 radiant damage per hit", hood)
	# Dev maps the Back slot (capes, packs) onto the torso, so they do block.
	var cape: PackedStringArray = ItemTooltip.armour_lines(_item_entry("red_travel_cape"))
	_check("armour.cape-covers-torso", cape.size() == 1 and cape[0] == "Armour (torso): blocks 2 cold per hit", cape)
	var pack: PackedStringArray = ItemTooltip.armour_lines(_item_entry("leather_backpack"))
	_check("armour.backpack-covers-torso", pack.size() == 1 and pack[0].begins_with("Armour (torso): blocks 1 slashing"), pack)
	var buckler: PackedStringArray = ItemTooltip.armour_lines(_item_entry("buckler"))
	_check("armour.shield-dict-line", buckler.size() == 1 and buckler[0] == "Shield (torso and arms, held in the off hand): blocks 2 slashing, 1 bludgeoning, 1 piercing per hit", buckler)
	var ws := WeaponShape.new()
	ws.weapon_type = WeaponShape.WeaponType.SHIELD
	ws.damage_resitances = {"slashing": 4, "piercing": 3, "fire": 0}
	var held: PackedStringArray = ItemTooltip.armour_lines({"kind": "weapon", "display_name": "Iron Shield", "raw": ws})
	_check("armour.held-shield-line", held.size() == 1 and held[0] == "Shield (torso and arms, held in the off hand): blocks 4 slashing, 3 piercing per hit", held)
	ws.weapon_type = WeaponShape.WeaponType.SWORD
	_check("armour.held-sword-none", ItemTooltip.armour_lines({"kind": "weapon", "raw": ws}).is_empty())
	ws.free()
	_check("armour.weapon-dict-none", ItemTooltip.armour_lines(_item_entry("longsword", "weapon")).is_empty() and ItemTooltip.armour_lines(_item_entry("longsword")).is_empty())
	_check("armour.potion-none", ItemTooltip.armour_lines(_item_entry("potion_of_healing")).is_empty())
	var e := _item_entry("legionnaires_armor")
	for ctx in ["", "trade", "service", "chest"]:
		var t: String = ItemTooltip.detail_text(e, ctx)
		_check("armour.in-%s-tooltip" % (ctx if ctx != "" else "party"), t.contains("\nArmour (torso and arms): blocks 4 slashing") and t.contains("\nWeakness: +1 electric"), t)
	_check("armour.limbs-text", ItemTooltip.covered_limbs_text(1) == "torso and arms" and ItemTooltip.covered_limbs_text(3) == "legs", ItemTooltip.covered_limbs_text(1))

# ---------------------------------------------------------------------------

func _case_damage_path() -> void:
	var ch := _spawn(Vector2(400, 400))
	stub.seen[ch] = true
	await get_tree().process_frame
	ch.constitution = 1000
	ch.set_limb_armor(ProceduralCharacter.LimbType.TORSO, {"bludgeoning": 3})
	ch.current_health = ch.max_health
	var dealt: int = ch.take_damage({"bludgeoning": 5.0}, Vector2.ZERO, null, ProceduralCharacter.LimbType.TORSO)
	_check("dr.partial-dealt", dealt == 2, dealt)
	_check("dr.minus-n-blocked-floats", _floated(stub, "-3 blocked") == 1, _floats(stub))
	_check("dr.number-still-floats", _floated(stub, "2") >= 1, _floats(stub))
	for c in stub.get_children():
		if c is Label and c.text == "-3 blocked":
			_check("dr.minus-n-is-small", c.get_theme_font_size("font_size") == ch.ABSORBED_FONT_SIZE)
	# Chip floor: armour 3 vs 2 still deals 1, so 1 was blocked.
	await get_tree().create_timer(0.35).timeout
	dealt = ch.take_damage({"bludgeoning": 2.0}, Vector2.ZERO, null, ProceduralCharacter.LimbType.TORSO)
	_check("dr.chip-floor", dealt == 1 and _floated(stub, "-1 blocked") == 1, [dealt, _floats(stub)])
	# Truncation is not "blocked": 4.5 vs 3 deals 1 (1.5 truncated), 3 blocked.
	await get_tree().create_timer(0.35).timeout
	var before3: int = _floated(stub, "-3 blocked")
	dealt = ch.take_damage({"bludgeoning": 4.5}, Vector2.ZERO, null, ProceduralCharacter.LimbType.TORSO)
	_check("dr.truncation-not-counted", dealt == 1 and _floated(stub, "-3 blocked") == before3 + 1, [dealt, _floats(stub)])
	var nb_before: int = _floats(stub).filter(func(t): return String(t).ends_with(" blocked")).size()
	dealt = ch.take_damage({"fire": 7.6}, Vector2.ZERO, null, ProceduralCharacter.LimbType.TORSO)
	_check("dr.unarmoured-type-no-float", dealt == 7 and _floats(stub).filter(func(t): return String(t).ends_with(" blocked")).size() == nb_before, _floats(stub))
	ch.condition_manager.clear_all_conditions()
	# DoT ticks never float "-N blocked".
	nb_before = _floats(stub).filter(func(t): return String(t).ends_with(" blocked")).size()
	ch._condition_tick_damage = true
	dealt = ch.take_damage({"bludgeoning": 5.0}, Vector2.ZERO, null, ProceduralCharacter.LimbType.TORSO)
	ch._condition_tick_damage = false
	_check("dr.tick-quiet", dealt == 2 and _floats(stub).filter(func(t): return String(t).ends_with(" blocked")).size() == nb_before, _floats(stub))
	# Condition DR soaking a hit completely: "Blocked".
	ch.condition_manager.apply_condition("physically_resistant", null, 1, 30.0)
	_reset_notify(ch)
	dealt = ch.take_damage({"slashing": 3.0}, Vector2.ZERO, null, ProceduralCharacter.LimbType.HEAD)
	_check("dr.condition-dr-blocked", dealt == 0 and _floated(stub, "Blocked") == 1, [dealt, _floats(stub)])
	# An NPC the party doesn't see shows none of it.
	stub.seen[ch] = false
	_reset_notify(ch)
	await get_tree().create_timer(0.35).timeout
	var blocked_before: int = _floated(stub, "Blocked")
	ch.take_damage({"slashing": 3.0}, Vector2.ZERO, null, ProceduralCharacter.LimbType.HEAD)
	_check("dr.unseen-quiet", _floated(stub, "Blocked") == blocked_before, _floats(stub))
	ch.condition_manager.clear_all_conditions()
	stub.seen[ch] = true

# ---------------------------------------------------------------------------

func _case_elemental() -> void:
	var a := _spawn(Vector2(600, 400))
	await get_tree().process_frame
	a.constitution = 1000
	a.current_health = a.max_health
	a.take_damage({"fire": 2}, a.global_position)
	_check("f4.fire-burns", a.condition_manager.has_condition("burning"))
	a.take_damage({"poison": 2}, a.global_position)
	_check("f4.poison-poisons", a.condition_manager.has_condition("poisoned"))
	a.take_damage({"cold": 2}, a.global_position)
	_check("f4.cold-chills", a.condition_manager.has_condition("chilled"))
	_check("f4.legacy-dict-untouched", not a.conditions.has("burning"), a.conditions)
	# A Burning tick doesn't re-light Burning.
	var inst = a.condition_manager.get_condition("burning")
	a.condition_manager.remove_condition("burning")
	a._on_triggered_effect_fired(inst, {"type": "damage"}, {"damage": 2, "damage_type": "fire"})
	_check("f4.tick-doesnt-feed-itself", not a.condition_manager.has_condition("burning"))
	_check("f4.tick-flag-cleared", not a._condition_tick_damage)
	# An effect list that applies Burning itself owns it.
	_check("f4.explicit-ids", AbilityEffect.explicit_condition_ids([{"type": "apply_condition", "condition_id": "burning"}, {"type": "damage", "damage": {"fire": 3}}]) == {"burning": true})
	a.begin_damage_condition_suppression({"burning": true})
	a.take_damage({"fire": 2}, a.global_position)
	_check("f4.suppressed", not a.condition_manager.has_condition("burning"))
	a.end_damage_condition_suppression()
	a.take_damage({"fire": 2}, a.global_position)
	_check("f4.suppression-ends", a.condition_manager.has_condition("burning"))
	# A hit that deals nothing burns nothing; suppression is per condition.
	a.condition_manager.clear_all_conditions()
	a.take_damage({"fire": 0.5}, a.global_position)
	_check("f4.no-damage-no-burn", not a.condition_manager.has_condition("burning"))
	a.begin_damage_condition_suppression({"burning": true})
	a.take_damage({"poison": 2}, a.global_position)
	a.end_damage_condition_suppression()
	_check("f4.suppression-per-condition", a.condition_manager.has_condition("poisoned"))
	# Abilities that apply the condition themselves own it (AbilityManager wrap).
	var caster := _spawn(Vector2(650, 400))
	await get_tree().process_frame
	a.condition_manager.clear_all_conditions()
	var fb := Ability.from_dict(AbilityDatabase.get_ability_data("fireball"))
	caster.ability_manager._resolve_effects(fb, fb.effects, a.global_position, [a])
	var burn = a.condition_manager.get_condition("burning")
	_check("f4.fireball-own-stacks", burn != null and burn.stacks == 2 and a.is_alive(), burn.stacks if burn else -1)
	_check("f4.suppression-cleared", a._suppressed_damage_conditions.is_empty())
	var worst_chill := 0
	for i in 6:
		a.condition_manager.clear_all_conditions()
		a.current_health = a.max_health
		var ice := Ability.from_dict(AbilityDatabase.get_ability_data("ice_storm"))
		caster.ability_manager._resolve_effects(ice, ice.effects, a.global_position, [a])
		var chill = a.condition_manager.get_condition("chilled")
		worst_chill = maxi(worst_chill, chill.stacks if chill else 0)
	_check("f4.ice-storm-chills-at-most-2", worst_chill <= 2, worst_chill)
	a.condition_manager.clear_all_conditions()
	a.take_damage({"fire": 2}, a.global_position)
	# Death: condition VFX and overhead icons go; the corpse takes no conditions.
	a.current_health = 1
	a.take_damage({"fire": 5}, a.global_position)
	_check("corpse.dead", not a.is_alive())
	var live_vfx := 0
	for k in a._active_condition_vfx:
		if is_instance_valid(a._active_condition_vfx[k]):
			live_vfx += 1
	_check("corpse.no-condition-vfx", live_vfx == 0, a._active_condition_vfx.keys())
	_check("corpse.icons-hidden", a._condition_display != null and not a._condition_display.visible)
	a._refresh_condition_display()
	_check("corpse.icons-stay-hidden", not a._condition_display.visible)
	a.condition_manager.remove_condition("poisoned")
	a._apply_damage_type_condition("poisoned")
	_check("corpse.no-new-conditions", not a.condition_manager.has_condition("poisoned"))

# ---------------------------------------------------------------------------

func _case_ticks_and_stress() -> void:
	var pm := _spawn(Vector2(800, 400), true)
	var ally := _spawn(Vector2(800, 350), true)   # in front of pm (facing up)
	var behind := _spawn(Vector2(800, 450), true)
	await get_tree().process_frame
	pm.rotation = 0.0
	pm.traits["Martial"] = 3
	pm.constitution = 1000
	pm.current_health = pm.max_health
	pm.stress = 0
	pm.adrenaline = 0
	pm._condition_tick_damage = true
	pm.take_damage({"fire": 2}, pm.global_position)
	pm._condition_tick_damage = false
	_check("tick.no-stress", pm.stress == 0, pm.stress)
	_check("tick.adrenaline", pm.adrenaline == 1, pm.adrenaline)
	pm.take_damage({"fire": 2}, pm.global_position)
	_check("hit.stress", pm.stress == 1, pm.stress)
	# Witnessing an ally's tick is not witnessing a wound.
	pm.stress = 0
	ally._condition_tick_damage = true
	pm._on_ally_took_damage(ally, 1)
	ally._condition_tick_damage = false
	_check("tick.witness-skipped", pm.stress == 0, pm.stress)
	pm._on_ally_took_damage(ally, 1)
	_check("hit.witnessed", pm.stress == 1, pm.stress)
	# A wound behind the witness's back isn't seen.
	pm._on_ally_took_damage(behind, 1)
	_check("hit.unseen-not-witnessed", pm.stress == 1, pm.stress)
	pm.condition_manager.clear_all_conditions()

# ---------------------------------------------------------------------------

func _case_stats() -> void:
	var c := _spawn(Vector2(1000, 400))
	var dex: int = c.dexterity
	c.condition_manager.apply_condition("hasted", null, 1, 30.0)
	_check("stats.hasted-multiplies", is_equal_approx(c.effective_dexterity(), dex * 1.5), c.effective_dexterity())
	_check("stats.check-uses-effective", c.get_stat_by_name("dex") == int(dex * 1.5), c.get_stat_by_name("dex"))
	c.condition_manager.remove_condition("hasted")
	c.condition_manager.apply_condition("frozen", null, 1, 30.0)
	_check("stats.frozen-sets-dex-0", is_equal_approx(c.effective_dexterity(), 0.0), c.effective_dexterity())
	c.condition_manager.remove_condition("frozen")
	_check("stats.back-to-base", is_equal_approx(c.effective_dexterity(), dex), c.effective_dexterity())
	c.condition_manager.apply_condition("courageous", null, 1, 30.0)
	_check("stats.wil-alias", c.get_stat_by_name("wil") == int(c.effective_will()) and c.get_stat_by_name("will") == c.will + 20, [c.get_stat_by_name("wil"), c.will])
	c.condition_manager.remove_condition("courageous")
	var mh: int = c.max_hp
	c.condition_manager.apply_condition("hypochondria", null, 1, 30.0)
	_check("stats.hypochondria-halves-hp", c.max_hp == maxi(1, int(mh * 0.5)), [mh, c.max_hp])
	_check("stats.hp-clamped", c.current_health <= c.max_hp)
	c.condition_manager.remove_condition("hypochondria")
	var mf: int = c.max_focus
	c.condition_manager.apply_condition("focused", null, 1, 30.0)
	_check("stats.focused-adds-pip", c.max_focus == mf + 1, [mf, c.max_focus])
	c.condition_manager.remove_condition("focused")

# ---------------------------------------------------------------------------

func _icon_rects(c) -> Array:
	var out: Array = []
	for r in c._condition_display.get_children():
		if not r.is_queued_for_deletion():
			out.append(r)
	return out

func _case_icons() -> void:
	var c := _spawn(Vector2(1200, 400))
	await get_tree().process_frame
	# Poisoned's VFX scene (poison_bubbles) is missing: it shows its icon.
	c.condition_manager.apply_condition("poisoned", null, 1, 30.0)
	_check("icons.missing-vfx-falls-back", _icon_rects(c).size() == 1, _icon_rects(c).size())
	c.condition_manager.apply_condition("poisoned", null, 2, 30.0)
	var rects := _icon_rects(c)
	var stack_text := ""
	if rects.size() == 1:
		for ch in rects[0].get_children():
			if ch is Label:
				stack_text = ch.text
	_check("icons.stack-count-shown", stack_text == "3", stack_text)
	c.condition_manager.clear_all_conditions()

# ---------------------------------------------------------------------------

func _case_heal_deny_death() -> void:
	var c := _spawn(Vector2(1400, 400))
	stub.seen[c] = true
	await get_tree().process_frame
	c.current_health = c.max_health - 5
	var healed: int = c.heal(3)
	_check("heal.number-floats", healed == 3 and _floated(stub, "+3") == 1, _floats(stub))
	stub.seen[c] = false
	c.heal(1)
	_check("heal.unseen-quiet", _floated(stub, "+1") == 0, _floats(stub))
	stub.seen[c] = true
	# Deny Ending: "Denied!", logged once.
	c.condition_manager.apply_condition("deny_ending", null, 1, 30.0)
	c.current_health = 3
	_reset_notify(c)
	c.take_damage({"fire": 10}, c.global_position)
	_check("deny.hp-stops-at-1", c.current_health == 1, c.current_health)
	_check("deny.float", _floated(stub, "Denied!") == 1, _floats(stub))
	_check("deny.logged", _logged("refuses to die (Deny Ending)") == 1)
	_reset_notify(c)
	c.take_damage({"fire": 10}, c.global_position)
	_check("deny.logged-once", _logged("refuses to die (Deny Ending)") == 1)
	c.condition_manager.clear_all_conditions()
	# One central death line; none for a death already explained.
	var n_before: int = _logged("has died.")
	c.take_damage({"fire": 50}, c.global_position)
	_check("death.logged", _logged("%s has died." % c.Name) == 1, log_lines.slice(-3))
	var d := _spawn(Vector2(1450, 400))
	stub.seen[d] = true
	await get_tree().process_frame
	d.set_meta(ProceduralCharacter.DEATH_LOGGED_META, true)
	d.take_damage({"fire": 500}, d.global_position)
	_check("death.explained-not-repeated", _logged("%s has died." % d.Name) == 0)
	var e := _spawn(Vector2(1500, 400))
	stub.seen[e] = false
	await get_tree().process_frame
	e.take_damage({"fire": 500}, e.global_position)
	_check("death.unseen-not-logged", _logged("%s has died." % e.Name) == 0 and _logged("has died.") == n_before + 1)

# ---------------------------------------------------------------------------

func _case_souls_favour() -> void:
	var pm := _spawn(Vector2(1600, 600), true)
	var corpse := _spawn(Vector2(1620, 600))
	corpse.current_health = 0
	pm.traits["Occult"] = 0
	# Overflow soul into the pack: Drop only, with a description.
	_check("soul.granted", pm._grant_soul({"id": "x1", "name": "Bob"}))
	var soul_item: Dictionary = {}
	for it in pm.inventory.items:
		if String(it.get("id", "")).begins_with("soul_"):
			soul_item = it
	_check("soul.drop-only", soul_item.get("interact_options", []) == ["Drop"], soul_item.get("interact_options"))
	_check("soul.description", String(soul_item.get("description", "")).contains("Offer Souls to Patron"))
	# Full pack: nothing recorded, the corpse keeps its soul.
	while pm.inventory.items.size() < pm.inventory.max_slots:
		pm.inventory.items.append({"id": "rock", "display_name": "Rock"})
	var souls_before: int = pm.captured_souls.size()
	var res: Dictionary = pm.bind_soul_effect({}, [corpse], null, corpse.global_position)
	_check("soul.full-pack-not-lost", res.get("souls_captured", -1) == 0 and pm.captured_souls.size() == souls_before and not corpse.has_meta("soul_bound"))
	_check("soul.full-pack-logged", _logged("has no room for the soul of") == 1)
	_reset_notify(pm)
	pm.bind_soul_effect({}, [], null, pm.global_position)
	_check("soul.none-notice", _logged("finds no unbound souls there") == 1)
	pm.inventory.items.clear()
	# Companion favour is announced; the protagonist's isn't.
	var comp := _spawn(Vector2(1700, 600), true)
	comp.apply_favorability_delta(2, "test")
	_check("favour.logged", _logged("%s approves (+2 favour, now 2)." % comp.Name) == 1)
	comp.favorability = 99
	comp.apply_favorability_delta(5, "test")
	_check("favour.clamped-amount", _logged("%s approves (+1 favour, now 100)." % comp.Name) == 1)
	comp.is_protagonist = true
	var n: int = log_lines.size()
	comp.apply_favorability_delta(-3, "test")
	_check("favour.protagonist-quiet", log_lines.size() == n)

# ---------------------------------------------------------------------------

func _case_custom_abilities() -> void:
	var pm := _spawn(Vector2(400, 800), true)
	var other := _spawn(Vector2(450, 800))
	await get_tree().process_frame
	_reset_notify(pm)
	var r: Dictionary = pm._copy_conditions({"duration": 5.0}, [], null, pm.global_position)
	_check("psych.no-target", not r.success and _floated(stub, "No target") >= 1 and _logged("found no one to copy") == 1)
	_reset_notify(pm)
	r = pm._copy_conditions({"duration": 5.0}, [other], null, pm.global_position)
	_check("psych.nothing-copied", r.copied.is_empty() and _logged("finds nothing in %s to mirror" % other.Name) == 1)
	other.condition_manager.apply_condition("hasted", null, 1, 30.0)
	r = pm._copy_conditions({"duration": 5.0}, [other], null, pm.global_position)
	_check("psych.copied", r.copied == ["hasted"] and pm.condition_manager.has_condition("hasted") and _logged("mirrors %s: Hasted." % other.Name) == 1, [r, log_lines.slice(-2)])
	# Confess skips the dead and says why.
	var dead := _spawn(Vector2(470, 800))
	dead.current_health = 0
	_reset_notify(pm)
	r = pm._confess({}, [dead], null, dead.global_position)
	_check("confess.dead-skipped", not r.success and not pm.condition_manager.has_condition("infatuated") and _logged("no one there to hear %s's confession" % pm.Name) == 1)
	# Stress breakdown: the affliction is named with its cause.
	var aff: Array = ConditionDatabase.get_stress_affliction_ids()
	if not aff.is_empty():
		pm._apply_stress_response(String(aff[0]), false, "stress at its limit")
		_check("stress.affliction-logged", _logged("%s breaks under the strain (stress at its limit)" % pm.Name) == 1, log_lines.slice(-2))
	pm.condition_manager.clear_all_conditions()
	pm.condition_manager.apply_condition("courageous", null, 1, 30.0)
	pm._resolve_stress_breakdown(true)
	_check("stress.courage-logged", _logged("%s's courage holds (stress at its limit)" % pm.Name) == 1 and not pm.condition_manager.has_condition("courageous"))
	# Bide reports what it stored.
	pm.condition_manager.apply_condition("bide", null, 1, 30.0)
	var bide = pm.condition_manager.get_condition("bide")
	bide.custom_data["absorbed"] = 4.0
	bide.custom_data["ratio"] = 1.0
	_reset_notify(pm)
	pm._on_condition_expired(bide)
	_check("bide.stored-notice", pm.bide_pending_bonus >= 4.0 and _logged("Bide stores 4 bonus damage") == 1)
	pm.condition_manager.clear_all_conditions()

# ---------------------------------------------------------------------------

func _case_attack_refusals() -> void:
	var pm := _spawn(Vector2(800, 800), true)
	await get_tree().process_frame
	pm.is_player_controlled = true
	pm.condition_manager.apply_condition("stunned", null, 1, 30.0)
	_reset_notify(pm)
	pm.attack("Main", pm.global_position + Vector2(0, -40))
	_check("refuse.stunned-says-why", not pm.attack_animator.is_attacking and _logged("%s can't attack: Stunned." % pm.Name) == 1)
	pm.condition_manager.clear_all_conditions()
	# An AI-driven (unselected) member's refused swing stays quiet.
	pm.is_player_controlled = false
	pm.condition_manager.apply_condition("stunned", null, 1, 30.0)
	_reset_notify(pm)
	pm.attack("Main")
	_check("refuse.ai-quiet", _logged("%s can't attack: Stunned." % pm.Name) == 1)
	pm.condition_manager.clear_all_conditions()
	pm.is_player_controlled = true
	# A bow with no arrows doesn't draw.
	var bow = pm.give_weapon(ItemDatabase.get_item_data("shortbow"), "Main")
	await get_tree().process_frame
	_reset_notify(pm)
	pm.attack("Main", pm.global_position + Vector2(0, -200))
	_check("refuse.no-ammo-no-draw", bow != null and not pm.attack_animator.is_attacking, pm.attack_animator.is_attacking)
	_check("refuse.no-ammo-says-why", _logged("can't fire the") == 1 and _logged("no arrows left") == 1, log_lines.slice(-2))
	pm.inventory.unequip_hand("Main")
	# Infatuated: one log line however many refused swings.
	var crush := _spawn(pm.global_position + Vector2(0, -50))
	pm.rotation = 0.0
	pm.condition_manager.apply_condition("infatuated", crush, 1, 30.0)
	_reset_notify(pm)
	pm.attack("Main")
	pm.attack("Main")
	pm.attack("Main")
	_check("refuse.infatuated-logged-once", _logged("can't bring themselves to attack %s" % crush.Name) == 1)
	pm.condition_manager.clear_all_conditions()
	pm.is_player_controlled = false
	# Dash cooldown says so.
	pm.dash_cooldown_timer = 1.0
	_reset_notify(pm)
	pm.dash(pm.global_position + Vector2(100, 0))
	_check("dash.recovering", _logged("%s can't dash yet" % pm.Name) == 1)
	pm.dash_cooldown_timer = 0.0

# ---------------------------------------------------------------------------

func _count(c, type: int, path_only = null) -> int:
	var n := 0
	var all: Array = c.action_queue.get_queue().duplicate()
	if c.action_queue.current_action != null:
		all.push_front(c.action_queue.current_action)
	for a in all:
		if a.type != type:
			continue
		if path_only != null and bool(a.data.get("from_path", false)) != path_only:
			continue
		n += 1
	return n

func _case_planning() -> void:
	var pm := _spawn(Vector2(1000, 1000), true)
	await get_tree().process_frame
	PauseManager.is_paused = true
	# A direct paused order (no reticle) is confirmed.
	pm.action_queue.queue_cycle_weapon(1, "Main")
	_check("plan.swap-confirmed", _logged("%s will swap main-hand weapon." % pm.Name) == 1)
	# A drawn path converts around the direct order and is tagged.
	pm.tactical_path.clear()
	pm.tactical_path.add_waypoint(pm.global_position)
	pm.tactical_path.add_waypoint(pm.global_position + Vector2(64, 0))
	pm.tactical_path.add_waypoint(pm.global_position + Vector2(128, 0))
	pm._on_game_unpaused_convert_path()
	_check("plan.direct-order-kept", _count(pm, ActionQueue.ActionType.CYCLE_WEAPON) == 1)
	var moves: int = _count(pm, ActionQueue.ActionType.MOVE, true)
	_check("plan.path-steps-tagged", moves >= 1 and _count(pm, ActionQueue.ActionType.MOVE, false) == 0, moves)
	pm._on_game_unpaused_convert_path()
	_check("plan.reconvert-no-duplicates", _count(pm, ActionQueue.ActionType.CYCLE_WEAPON) == 1 and _count(pm, ActionQueue.ActionType.MOVE, true) == moves)
	_check("plan.direct-order-runs-first", pm.action_queue.get_queue().size() > 0 and pm.action_queue.get_queue()[0].type == ActionQueue.ActionType.CYCLE_WEAPON)
	# A step that ran consumes its own node; a direct order consumes none.
	var node = pm.tactical_path.insert_action_node(pm.global_position + Vector2(96, 0))
	var nodes_before: int = pm.tactical_path.action_nodes.size()
	var direct := ActionQueue.Action.new(ActionQueue.ActionType.FACE, {"target_rotation": 0.0})
	pm._on_tactical_action_completed(direct)
	_check("plan.direct-consumes-no-node", pm.tactical_path.action_nodes.size() == nodes_before)
	var step := ActionQueue.Action.new(ActionQueue.ActionType.FACE, {"target_rotation": 0.0, "from_path": true, "path_node": node})
	pm._on_tactical_action_completed(step)
	_check("plan.step-consumes-its-node", not pm.tactical_path.action_nodes.has(node))
	# A planned cast re-queued while that same cast still runs isn't a failure.
	var fb := Ability.from_dict(AbilityDatabase.get_ability_data("fireball"))
	var saved_cast: Dictionary = pm.current_cast
	pm.current_cast = {"ability": fb}
	var saved_current = pm.action_queue.current_action
	pm.action_queue.current_action = ActionQueue.Action.new(ActionQueue.ActionType.USE_ABILITY, {"ability_id": "fireball", "from_path": true})
	_reset_notify(pm)
	pm._announce_cast_failure(Ability.from_dict(AbilityDatabase.get_ability_data("fireball")), "Already casting")
	_check("cast.requeued-step-quiet", _logged("%s can't use Fireball: Already casting." % pm.Name) == 0)
	pm.action_queue.current_action = ActionQueue.Action.new(ActionQueue.ActionType.USE_ABILITY, {"ability_id": "fireball"})
	_reset_notify(pm)
	pm._announce_cast_failure(Ability.from_dict(AbilityDatabase.get_ability_data("fireball")), "Already casting")
	_check("cast.direct-recast-announced", _logged("%s can't use Fireball: Already casting." % pm.Name) == 1, log_lines.slice(-2))
	pm.action_queue.current_action = saved_current
	pm.current_cast = saved_cast
	# Losing control on ice drops the whole plan, with a notice.
	_reset_notify(pm)
	pm._begin_ice_slide(Vector2.RIGHT)
	_check("ice.plan-dropped", pm.action_queue.current_action == null and pm.action_queue.get_queue_size() == 0 and not pm.has_player_orders())
	_check("ice.path-cleared", pm.tactical_path.is_empty())
	_check("ice.logged", _logged("%s slips on the ice; the rest of their plan is cancelled." % pm.Name) == 1)
	pm.is_ice_sliding = false
	# Multi-select: a press on another selected member's body is theirs.
	var other := _spawn(Vector2(1100, 1000), true)
	await get_tree().process_frame
	stub.selected_characters = [pm, other]
	Input.action_press("left_click")
	var a_defers: bool = pm._click_belongs_to_other_selected(other.global_position)
	var b_keeps: bool = not other._click_belongs_to_other_selected(other.global_position)
	var ground_free: bool = not pm._click_belongs_to_other_selected(pm.global_position + Vector2(0, 300))
	pm.pending_dash = true
	var aiming_keeps: bool = not pm._click_belongs_to_other_selected(other.global_position)
	pm.pending_dash = false
	Input.action_release("left_click")
	_check("multiselect.other-body-deferred", a_defers)
	_check("multiselect.own-body-kept", b_keeps)
	_check("multiselect.ground-not-deferred", ground_free)
	_check("multiselect.aiming-confirm-kept", aiming_keeps)
	stub.selected_characters = []
	PauseManager.is_paused = false

# ---------------------------------------------------------------------------

func _case_unarmed_and_hands() -> void:
	var pm := _spawn(Vector2(1200, 1000), true)
	await get_tree().process_frame
	pm.inventory.unequip_hand("Main")
	pm.inventory.unequip_hand("Off")
	pm.action_queue.cancel_all()
	PauseManager.is_paused = true
	var spot: Vector2 = pm.global_position + Vector2(300, 0)
	pm._process_hand_action(null, "Off", spot, true)
	var q: Array = pm.action_queue.get_queue()
	_check("unarmed.paused-click-queues", q.size() == 1 and q[0].type == ActionQueue.ActionType.ATTACK, q.size())
	_check("unarmed.keeps-its-hand", q.size() == 1 and q[0].data.get("hand", "") == "Off")
	pm.action_queue.cancel_all()
	# An empty off hand beside a two-hander swings the two-hander.
	var maul = pm.give_weapon(ItemDatabase.get_item_data("maul"), "Main")
	await get_tree().process_frame
	if maul != null and maul.is_two_handed():
		pm._process_hand_action(pm.current_off_hand_item, "Off", spot, true)
		q = pm.action_queue.get_queue()
		_check("twohander.off-swings-main", q.size() == 1 and q[0].data.get("hand", "") == "Main", q.size())
	else:
		_check("twohander.maul-is-two-handed", false, maul)
	pm.action_queue.cancel_all()
	pm.inventory.unequip_hand("Main")
	PauseManager.is_paused = false
	await get_tree().process_frame
	# Executing a planned off-hand attack swings the off hand.
	var act := ActionQueue.Action.new(ActionQueue.ActionType.ATTACK, {"target_position": spot, "hand": "Off"})
	pm.action_queue._execute_action(act)
	_check("unarmed.planned-off-hand-swings", pm.current_hand == "Off" and pm.attack_animator.is_attacking)
	# Paused: the swing holds still.
	PauseManager.is_paused = true
	var t0: float = pm.attack_animator.attack_timer
	var s0 = pm.attack_animator.current_state
	await _await_frames(5)
	_check("animator.frozen-while-paused", is_equal_approx(pm.attack_animator.attack_timer, t0) and pm.attack_animator.current_state == s0, [t0, pm.attack_animator.attack_timer])
	PauseManager.is_paused = false
	await _await_frames(5)
	_check("animator.resumes", pm.attack_animator.attack_timer != t0 or pm.attack_animator.current_state != s0)

# ---------------------------------------------------------------------------

func _case_movement_notices() -> void:
	var pm := _spawn(Vector2(1400, 1000), true)
	await get_tree().process_frame
	pm.is_player_controlled = true
	_reset_notify(pm)
	pm._announce_move_blocked("Too steep", "the ground is too steep")
	_check("move.blocked-logged", _logged("%s can't go that way: the ground is too steep." % pm.Name) == 1)
	# Forced (fleeing) movement isn't an order.
	var will0: int = pm.will
	pm.will = -1000   # frightened rolls a Will save on arrival: make it fail
	pm._on_stats_recalculated()
	pm.condition_manager.apply_condition("frightened", null, 1, 30.0, null)
	pm.will = will0
	_check("move.frightened-applied", pm.condition_manager.has_active_condition("frightened"))
	_reset_notify(pm)
	pm._announce_move_blocked()
	_check("move.forced-quiet", _logged("%s can't go that way: something is in the way." % pm.Name) == 0)
	# A click on the world while fleeing says why no order is taken.
	_reset_notify(pm)
	Input.action_press("left_click")
	pm._handle_input()
	Input.action_release("left_click")
	_check("input.blocked-says-why", _logged("%s can't take orders: Frightened." % pm.Name) == 1, log_lines.slice(-2))
	pm.condition_manager.clear_all_conditions()
	# An NPC's movement never announces.
	var npc := _spawn(Vector2(1450, 1000))
	npc._announce_move_blocked()
	_check("move.npc-quiet", _logged("%s can't go that way" % npc.Name) == 0)
	pm.is_player_controlled = false
	# Falls are named.
	pm.constitution = 1000
	pm.current_health = pm.max_health
	_reset_notify(pm)
	pm._apply_fall_damage(GridManager.FALL_SAFE_STORIES + 3.0)
	_check("fall.named", _logged("%s takes" % pm.Name) == 1 and _logged("damage from the fall.") >= 1, log_lines.slice(-2))

# ---------------------------------------------------------------------------

func _case_alertness_and_animator() -> void:
	var pm := _spawn(Vector2(1600, 1000), true)
	var npc := _spawn(Vector2(1650, 1000))
	await get_tree().process_frame
	pm.AI_enabled = true
	npc.AI_enabled = true
	pm._on_alertness_changed(0, 3)
	npc._on_alertness_changed(0, 3)
	_check("alert.companion-no-question-mark", pm._alertness_indicator != null and not pm._alertness_indicator.visible)
	_check("alert.npc-question-mark", npc._alertness_indicator != null and npc._alertness_indicator.visible)
	pm.AI_enabled = false
	npc.AI_enabled = false

# ---------------------------------------------------------------------------

func _case_templates() -> void:
	var wolf: ProceduralCharacter = CHAR_SCENE.instantiate()
	stub.add_child(wolf)
	TopDownCharacterDatabase.build_character(wolf, "wild_wolf")
	_check("template.wolf-bites", String(wolf.unarmed_strike_damage_type) == "piercing" and int(wolf.unarmed_strike_damage) == 6, [wolf.unarmed_strike_damage_type, wolf.unarmed_strike_damage])
	var human: ProceduralCharacter = CHAR_SCENE.instantiate()
	stub.add_child(human)
	TopDownCharacterDatabase.build_character(human, "protagonist")
	_check("template.no-block-keeps-punch", String(human.unarmed_strike_damage_type) == "bludgeoning", human.unarmed_strike_damage_type)
