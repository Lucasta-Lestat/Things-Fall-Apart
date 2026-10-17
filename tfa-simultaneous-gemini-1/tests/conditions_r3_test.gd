extends Node2D
# Round 3, conditions lane:
#   A. canceled_by_trait, one entry point (ConditionManager.cancel_by_traits):
#      an ability landing (its traits), damage actually dealt (its type), a
#      condition arriving (its traits), the fluid underfoot (and its ward), a
#      consumable; equip-granted conditions are suppressed for a window, not
#      removed; every cancellation floats over the bearer and logs the
#      condition, the trait and the cause; hidden NPCs stay quiet.
#   B. DoT bugs: a tick that kills ends the frame's ticks and saves (no blood
#      or saves on a corpse); a tick that ends its own condition doesn't skip
#      the rest of the frame's conditions; Bleeding's text matches its data.
#   C. The Shadow Cloak's Invisible: attacking or casting (reveal) suppresses
#      it for the reveal window and the cloak restores it; a timed Invisible
#      ends; the AI can acquire the attacker during the window.
# Real ProceduralCharacter.tscn instances on a stub Game surface (as in
# equipment_effects_test and world_port_check). Headless-safe.
#   godot --headless --path . res://tests/conditions_r3_test.tscn
# Judge by the PASS/FAIL lines and "HARNESS DONE failures=0".

const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const BACK := EquipmentShape.EquipmentSlot.BACK

# --- Game stub surface (ai.gd and ProceduralCharacter touch these) ---
var characters_in_scene: Array = []
var items_in_scene: Array = []
var structures_in_scene: Array = []
var party_chars: Array = []
var selected_characters: Array = []
var stealth_mode: bool = false
var surface_manager = null
var fluid_manager: FluidManager = null
var fog_manager = null
var context_menu_open := false
var primary_selected = null
var current_map_id: String = "test"
var current_map_data: Dictionary = {}
const MELEE_ELEV_TOLERANCE: float = 0.5

var _seen: Dictionary = {}   # is_seen_by_party stand-in for NPCs

func can_hit_target(_a: Node2D, _t: Node2D) -> bool: return true
func register_hit(_a: Node2D, _t: Node2D) -> void: pass
func register_attack_start(_a: Node2D) -> void: pass
func register_attack_end(_a: Node2D) -> void: pass
func resolve_melee_swing(_a: Node2D, _hand: String) -> void: pass
func process_weapon_hit(_a, _t, _p, _w, _v) -> void: pass
func process_object_hit(_a, _t, _p, _w, _v) -> void: pass
func trigger_hearing_pulse(_source) -> void: pass
func is_seen_by_party(c) -> bool:
	return c in party_chars or bool(_seen.get(c, false))

const ORIGIN := Vector2(1024, 1024)

var failures := 0
var checks := 0


func _check(check_name: String, cond: bool, detail: String = "") -> void:
	checks += 1
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	fluid_manager = FluidManager.new()
	add_child(fluid_manager)   # no cell graph: the legacy flat tile sim
	await get_tree().process_frame
	_register_test_conditions()

	await _case_ability_traits()
	await _case_damage_types()
	await _case_condition_traits()
	await _case_fluids()
	await _case_consumable()
	await _case_equip_suppressed()
	await _case_dot_death_frame()
	await _case_dot_self_clear()
	_case_bleeding_text()
	await _case_cloak_reveal()
	await _case_timed_invisible()
	await _case_ai_acquires_in_window()

	print("HARNESS DONE failures=%d checks=%d" % [failures, checks])
	get_tree().quit(1 if failures > 0 else 0)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## A built character (inventory, gear slots) with no AI, at `pos`.
func _new_char(char_name: String, pos: Vector2, party := false, faction := "player") -> ProceduralCharacter:
	var c: ProceduralCharacter = PC_SCENE.instantiate()
	c.AI_enabled = false
	c.is_player_controlled = party
	add_child(c)
	TopDownCharacterDatabase.build_character(c, "default_human")
	c.game = self
	c.faction_id = faction
	c.Name = char_name
	c.global_position = pos
	characters_in_scene.append(c)
	if party:
		party_chars.append(c)
	return c


func _spawn_ai(faction: String, pos: Vector2, char_name: String, ai_on: bool) -> ProceduralCharacter:
	var c: ProceduralCharacter = PC_SCENE.instantiate()
	c.AI_enabled = ai_on
	c.is_player_controlled = not ai_on
	add_child(c)
	TopDownCharacterDatabase.build_character(c, "default_human")
	c.game = self
	c.faction_id = faction
	c.Name = char_name
	c.global_position = pos
	c.rotation = 0.0
	c.target_rotation = 0.0
	characters_in_scene.append(c)
	return c


func _clear() -> void:
	for c in characters_in_scene:
		if is_instance_valid(c):
			c.queue_free()
	characters_in_scene = []
	party_chars = []
	_seen = {}
	await get_tree().physics_frame
	await get_tree().physics_frame


func _cm(c: ProceduralCharacter) -> ConditionManager:
	return c.get_node("ConditionManager")


## Big stack count so a landing save can't refuse it (deterministic harness).
## Chilled takes one stack: three turn it into Frozen.
func _apply(c: ProceduralCharacter, id: String, source: Node = null) -> bool:
	_cm(c).apply_condition(id, source, 1 if id == "chilled" else 10)
	return _cm(c).has_condition(id)


func _log_count(fragment: String) -> int:
	var n := 0
	for e in GameLog.get_entries():
		if String(e.get("text", "")).contains(fragment):
			n += 1
	return n


func _floats_with(text: String) -> int:
	var n := 0
	for ch in get_children():
		if ch is Label and (ch as Label).text == text:
			n += 1
	for c in characters_in_scene:
		if is_instance_valid(c):
			for ch in c.get_children():
				if ch is Label and (ch as Label).text == text:
					n += 1
	return n


## The fluid ward is held in real milliseconds; headless frames can run on a
## longer nominal delta than the wall clock, so wait on the clock itself.
func _wait_real_ms(ms: int) -> void:
	var until := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame


func _ability(id: String) -> Ability:
	return Ability.from_dict(AbilityDatabase.get_ability_data(id))


## Test-only conditions: one whose own tick removes it (the snapshot case).
func _register_test_conditions() -> void:
	ConditionManager.register_conditions([{
		"id": "r3_self_clear", "display_name": "Self Clear", "traits": {"debuff": 1},
		"stackable": false, "duration": 30.0, "canceled_by_trait": [],
		"triggered_effects": [{"type": "remove_condition", "condition_id": "r3_self_clear", "interval": 1.0}],
		"immunities": {},
	}])


# ---------------------------------------------------------------------------
# A. canceled_by_trait
# ---------------------------------------------------------------------------

func _case_ability_traits() -> void:
	var caster := _new_char("Caster", ORIGIN + Vector2(-300, 0), false, "bandits")
	var p := _new_char("Aldric", ORIGIN, true)
	_check("ability.setup-burning", _apply(p, "burning"))
	var logs := _log_count("Aldric's Burning is put out (cold: Ice Storm).")
	var floats := _floats_with("Burning put out")
	caster.ability_manager._resolve_effects(_ability("ice_storm"), _ability("ice_storm").effects, p.global_position, [p])
	_check("ability.cold-puts-out-burning", not _cm(p).has_condition("burning"))
	_check("ability.logged-with-trait-and-cause", _log_count("Aldric's Burning is put out (cold: Ice Storm).") == logs + 1,
		"log tail: %s" % str(GameLog.get_entries().slice(-3)))
	_check("ability.floats-put-out", _floats_with("Burning put out") > floats)

	# Heal's "healing" trait stops Bleeding (canceled_by_trait ["bandage", "healing"]).
	_check("ability.setup-bleeding", _apply(p, "bleeding"))
	logs = _log_count("Aldric's Bleeding ends (healing: Heal).")
	caster.ability_manager._resolve_effects(_ability("heal"), _ability("heal").effects, p.global_position, [p])
	_check("ability.healing-stops-bleeding", not _cm(p).has_condition("bleeding"))
	_check("ability.heal-logged", _log_count("Aldric's Bleeding ends (healing: Heal).") == logs + 1)

	# A trait at tier 0 is not carried, and case doesn't matter ("Fire").
	# (Ice Storm may have left Chilled x2: start from one stack.)
	_cm(p).remove_condition("chilled")
	_check("ability.setup-chilled", _apply(p, "chilled"))
	var none: Array = _cm(p).cancel_by_traits({"Fire": 0}, "Nothing")
	_check("ability.tier-zero-not-carried", none.is_empty() and _cm(p).has_condition("chilled"))
	var out: Array = _cm(p).cancel_by_traits({"Fire": 2}, "Fire Spin", caster)
	_check("ability.capitalised-trait-matches", not _cm(p).has_condition("chilled") and out.size() == 1 \
		and out[0]["condition_id"] == "chilled" and out[0]["trait"] == "fire" and not out[0]["suppressed"], str(out))
	await _clear()


func _case_damage_types() -> void:
	var foe := _new_char("Brigand", ORIGIN + Vector2(-200, 0), false, "bandits")
	var p := _new_char("Aldric", ORIGIN, true)
	_check("damage.setup-chilled", _apply(p, "chilled"))
	var logs := _log_count("Aldric's Chilled thaws (fire: Brigand's hit).")
	p.take_damage({"fire": 3}, p.global_position, foe)
	_check("damage.fire-thaws-chilled", not _cm(p).has_condition("chilled"))
	_check("damage.fire-logged", _log_count("Aldric's Chilled thaws (fire: Brigand's hit).") == logs + 1)
	_check("damage.fire-then-burns", _cm(p).has_condition("burning"), "the hit's own Burning lands after")
	logs = _log_count("Aldric's Burning is put out (cold: Brigand's hit).")
	p.take_damage({"cold": 3}, p.global_position, foe)
	_check("damage.cold-puts-out-burning", not _cm(p).has_condition("burning"))
	_check("damage.cold-logged", _log_count("Aldric's Burning is put out (cold: Brigand's hit).") == logs + 1)
	# Damage armour stopped entirely isn't dealt: nothing is cancelled.
	_cm(p).remove_condition("chilled")
	_check("damage.setup-burning", _apply(p, "burning"))
	p.take_damage({"cold": 0}, p.global_position, foe)
	_check("damage.zero-damage-cancels-nothing", _cm(p).has_condition("burning"))
	await _clear()


func _case_condition_traits() -> void:
	var p := _new_char("Aldric", ORIGIN, true)
	_check("cond.setup-chilled", _apply(p, "chilled"))
	var logs := _log_count("Aldric's Chilled thaws (fire: Burning).")
	_cm(p).apply_condition("burning", null, 1)
	_check("cond.burning-thaws-chilled", not _cm(p).has_condition("chilled") and _cm(p).has_condition("burning"))
	_check("cond.burning-thaw-logged", _log_count("Aldric's Chilled thaws (fire: Burning).") == logs + 1)
	logs = _log_count("Aldric's Burning is put out (cold: Chilled).")
	_cm(p).apply_condition("chilled", null, 1)
	_check("cond.chilled-puts-out-burning", not _cm(p).has_condition("burning") and _cm(p).has_condition("chilled"))
	_check("cond.chilled-logged", _log_count("Aldric's Burning is put out (cold: Chilled).") == logs + 1)
	# Courageous (a stress virtue, trait "courage") ends Frightened.
	_check("cond.setup-frightened", _apply(p, "frightened"))
	_cm(p).apply_condition("courageous", null, 1)
	_check("cond.courage-ends-fright", not _cm(p).has_condition("frightened") and _cm(p).has_condition("courageous"))
	_check("cond.courage-logged", _log_count("Aldric's Frightened ends (courage: Courageous).") >= 1)
	# A condition the bearer is immune to doesn't land, so it cancels nothing.
	_cm(p).remove_condition("chilled")
	_check("cond.setup-burning", _apply(p, "burning"))
	_cm(p).apply_condition("shielded", null, 1)   # immune to "cold" debuffs
	_cm(p).apply_condition("chilled", null, 1)
	_check("cond.immune-cancels-nothing", _cm(p).has_condition("burning") and not _cm(p).has_condition("chilled"))
	await _clear()


func _case_fluids() -> void:
	var fm := fluid_manager
	var wt := Vector2i(20, 20)
	fm.register_fluid(wt, "water", 0.3)
	var p := _new_char("Aldric", GridManager.map_to_world(wt), true)
	var foe := _new_char("Brigand", GridManager.map_to_world(wt) + Vector2(-200, 0), false, "bandits")
	_check("fluid.setup-burning", _apply(p, "burning"))
	var logs := _log_count("Aldric's Burning is put out (water).")
	fm.update_fluid_conditions(0.05, [p])
	_check("fluid.water-puts-out-burning", not _cm(p).has_condition("burning"))
	_check("fluid.logged", _log_count("Aldric's Burning is put out (water).") == logs + 1)
	_check("fluid.floats", _floats_with("Burning put out") >= 1)
	# While standing in it, what water cancels can't land: a Fire Spin's
	# Stuck in Fire (null source) refused quietly; Burning from a character
	# refused with a notice.
	_cm(p).apply_condition("stuck_in_fire", null, 1)
	_check("fluid.ward-blocks-stuck-in-fire", not _cm(p).has_condition("stuck_in_fire"))
	logs = _log_count("Aldric is protected from Burning (water).")
	fm.update_fluid_conditions(0.05, [p])   # the game refreshes the ward every frame
	_cm(p).apply_condition("burning", foe, 1)
	_check("fluid.ward-blocks-burning", not _cm(p).has_condition("burning"))
	_check("fluid.ward-logged", _log_count("Aldric is protected from Burning (water).") == logs + 1)
	# Acid washes off too (Corroding: canceled_by_trait ["purify", "water"]).
	# The ward has to lapse first, or Corroding can't land to begin with.
	await _wait_real_ms(ConditionManager.AMBIENT_TRAIT_MS + 100)
	_check("fluid.setup-corroding", _apply(p, "corroding"))
	fm.update_fluid_conditions(0.05, [p])
	_check("fluid.water-washes-corroding", not _cm(p).has_condition("corroding"))
	# Out of the water the ward lapses.
	p.global_position = GridManager.map_to_world(Vector2i(5, 5))
	await _wait_real_ms(ConditionManager.AMBIENT_TRAIT_MS + 100)
	_check("fluid.ward-lapses", _apply(p, "burning"))
	# An NPC the party doesn't see is put out silently.
	var q := _new_char("Hidden", GridManager.map_to_world(wt), false, "bandits")
	_check("fluid.setup-npc-burning", _apply(q, "burning"))
	var floats := _floats_with("Burning put out")
	logs = _log_count("Hidden's Burning")
	fm.update_fluid_conditions(0.05, [q])
	_check("fluid.unseen-npc-quiet", not _cm(q).has_condition("burning") \
		and _floats_with("Burning put out") == floats and _log_count("Hidden's Burning") == logs)
	fm.remove_fluid_tile(wt)
	await _clear()


func _case_consumable() -> void:
	var p := _new_char("Aldric", ORIGIN, true)
	_check("item.setup-bleeding", _apply(p, "bleeding"))
	var potion: Dictionary = ItemDatabase.get_item_data("potion_of_healing")
	var logs := _log_count("Aldric's Bleeding ends (healing: Potion of Healing).")
	var ok: bool = ActionQueue.apply_consumable(p, p, potion)
	_check("item.potion-used", ok)
	_check("item.healing-trait-stops-bleeding", not _cm(p).has_condition("bleeding"))
	_check("item.logged", _log_count("Aldric's Bleeding ends (healing: Potion of Healing).") == logs + 1)
	await _clear()


func _case_equip_suppressed() -> void:
	var p := _new_char("Aldric", ORIGIN, true)
	p.equip_equipment(ItemDatabase.get_item_data("shadow_cloak"))
	var cm := _cm(p)
	_check("equip.cloak-invisible", cm.has_active_condition("invisible"))
	var logs := _log_count("Aldric's Invisible is suppressed for 10 s (revealing: Test Lamp); Shadow Cloak brings it back after.")
	var out: Array = cm.cancel_by_trait("revealing", "Test Lamp", null)
	_check("equip.suppressed-not-removed", cm.has_condition("invisible") and not cm.has_active_condition("invisible"))
	_check("equip.result-says-suppressed", out.size() == 1 and out[0]["suppressed"], str(out))
	_check("equip.suppress-logged", _log_count("Aldric's Invisible is suppressed for 10 s (revealing: Test Lamp); Shadow Cloak brings it back after.") == logs + 1,
		"log tail: %s" % str(GameLog.get_entries().slice(-2)))
	_check("equip.floats-suppressed", _floats_with("Invisible suppressed") >= 1)
	var now: float = TimeManager.absolute_time()
	_check("equip.summary-shows-window", cm.get_condition("invisible").get_summary(now).contains("(suppressed 10s)"),
		cm.get_condition("invisible").get_summary(now))
	# A second hit inside the window says nothing new.
	logs = _log_count("Invisible is suppressed")
	cm.cancel_by_trait("revealing", "Test Lamp", null)
	_check("equip.repeat-quiet", _log_count("Invisible is suppressed") == logs)
	# The worn cloak has it back after the window.
	logs = _log_count("Aldric's Invisible returns (Shadow Cloak).")
	TimeManager.game_time += ConditionManager.CANCEL_SUPPRESS_SECONDS + 0.5
	await get_tree().process_frame
	await get_tree().process_frame
	_check("equip.restored", cm.has_active_condition("invisible"))
	_check("equip.restore-logged", _log_count("Aldric's Invisible returns (Shadow Cloak).") == logs + 1)
	_check("equip.window-cleared", not cm.get_condition("invisible").custom_data.has(ConditionManager.SUPPRESSED_UNTIL_KEY))
	p.unequip_slot(BACK)
	await get_tree().process_frame
	_check("equip.cloak-off", not cm.has_condition("invisible"))
	await _clear()


# ---------------------------------------------------------------------------
# B. DoT bugs
# ---------------------------------------------------------------------------

## A bare character (no gear: no armour on the tick).
func _bare(char_name: String, pos: Vector2) -> ProceduralCharacter:
	var c: ProceduralCharacter = PC_SCENE.instantiate()
	c.is_player_controlled = false
	c.AI_enabled = false
	add_child(c)
	c.game = self
	c.faction_id = "bandits"
	c.Name = char_name
	c.global_position = pos
	characters_in_scene.append(c)
	return c


func _case_dot_death_frame() -> void:
	var c := _bare("Victim", ORIGIN)
	await get_tree().process_frame
	var cm := _cm(c)
	cm.set_process(false)   # drive the frames by hand
	_check("dot.setup-burning", _apply(c, "burning"))
	_check("dot.setup-bleeding", _apply(c, "bleeding"))
	c.current_health = 1
	var fired: Array = []
	cm.triggered_effect_fired.connect(func(inst, eff, _res): fired.append([inst.condition.id, str(eff.get("type", ""))]))
	cm._process(0.016)
	_check("dot.burning-tick-kills", not c.is_alive(), "hp %d" % c.current_health)
	var bleed_after: Array = fired.filter(func(f): return f[0] == "bleeding")
	_check("dot.no-ticks-after-death-same-frame", bleed_after.is_empty(), str(fired))
	await _clear()


func _case_dot_self_clear() -> void:
	var c := _bare("Victim", ORIGIN)
	await get_tree().process_frame
	var cm := _cm(c)
	cm.set_process(false)
	cm.apply_condition("r3_self_clear", null, 1)
	_check("dot.setup-poisoned", _apply(c, "poisoned"))
	cm._process(0.016)
	var poisoned: ConditionInstance = cm.get_condition("poisoned")
	_check("dot.self-clear-gone", not cm.has_condition("r3_self_clear"))
	_check("dot.next-condition-still-ticks-same-frame", poisoned != null and float(poisoned.last_trigger_times.get(0, -INF)) > -1e30,
		"a tick that ends its own condition used to stop the frame's loop")
	await _clear()


func _case_bleeding_text() -> void:
	var tmpl: Condition = ConditionManager.condition_registry.get("bleeding")
	_check("dot.bleeding-text-matches-save-interval", tmpl != null and is_equal_approx(tmpl.save_interval, 6.0) \
		and tmpl.description.contains("every 6 seconds") and not tmpl.description.contains("every damage tick"),
		tmpl.description if tmpl else "missing")


# ---------------------------------------------------------------------------
# C. The Shadow Cloak's Invisible vs attacking
# ---------------------------------------------------------------------------

func _case_cloak_reveal() -> void:
	var p := _new_char("Aldric", ORIGIN, true)
	p.equip_equipment(ItemDatabase.get_item_data("shadow_cloak"))
	var cm := _cm(p)
	_check("cloak.invisible", cm.has_active_condition("invisible") and is_equal_approx(p.modulate.a, 0.35))
	var logs := _log_count("Aldric's invisibility breaks: attacking gives them away for 3 s; the Shadow Cloak restores it after.")
	p.reveal()
	_check("cloak.attack-suppresses", cm.has_condition("invisible") and not cm.has_active_condition("invisible"))
	_check("cloak.float", _floats_with("Invisibility broken") >= 1)
	_check("cloak.logged", _log_count("Aldric's invisibility breaks: attacking gives them away for 3 s; the Shadow Cloak restores it after.") == logs + 1,
		"log tail: %s" % str(GameLog.get_entries().slice(-2)))
	_check("cloak.drawn-solid", is_equal_approx(p.modulate.a, 1.0))
	_check("cloak.window-is-reveal-window", is_equal_approx(cm.suppression_time_left("invisible"), p.REVEAL_SECONDS),
		str(cm.suppression_time_left("invisible")))
	var icon_dim := false
	for ch in p._condition_display.get_children():
		if ch.has_meta("cond_id") and ch.get_meta("cond_id") == "invisible" and ch.modulate.a < 1.0:
			icon_dim = true
	_check("cloak.icon-dims", icon_dim)
	# Another swing inside the window stretches it, quietly.
	logs = _log_count("invisibility breaks")
	TimeManager.game_time += 1.0
	p.reveal()
	_check("cloak.second-swing-quiet", _log_count("invisibility breaks") == logs)
	_check("cloak.second-swing-stretches", is_equal_approx(cm.suppression_time_left("invisible"), p.REVEAL_SECONDS),
		str(cm.suppression_time_left("invisible")))
	# A cast reveals as Shrouded does (use_ability -> reveal(..., "casting")).
	logs = _log_count("Aldric's Invisible returns (Shadow Cloak).")
	TimeManager.game_time += p.REVEAL_SECONDS + 0.5
	await get_tree().process_frame
	await get_tree().process_frame
	_check("cloak.restored", cm.has_active_condition("invisible") and is_equal_approx(p.modulate.a, 0.35))
	_check("cloak.restore-logged", _log_count("Aldric's Invisible returns (Shadow Cloak).") == logs + 1)
	p.reveal(p.REVEAL_SECONDS, "casting")
	_check("cloak.cast-suppresses", not cm.has_active_condition("invisible"))
	_check("cloak.cast-logged", _log_count("Aldric's invisibility breaks: casting gives them away") >= 1)
	await _clear()


func _case_timed_invisible() -> void:
	var p := _new_char("Aldric", ORIGIN, true)
	var cm := _cm(p)
	cm.apply_condition("invisible", null, 1)
	_check("timed.invisible", cm.has_active_condition("invisible") and cm.get_condition("invisible").expires_at > 0.0)
	var logs := _log_count("Aldric's invisibility breaks: attacking ends it.")
	p.reveal()
	_check("timed.attack-ends-it", not cm.has_condition("invisible"))
	_check("timed.logged", _log_count("Aldric's invisibility breaks: attacking ends it.") == logs + 1)
	_check("timed.solid", is_equal_approx(p.modulate.a, 1.0))
	await _clear()


func _case_ai_acquires_in_window() -> void:
	TimeManager.pause_time()   # the reveal window stays open while the guard reacts
	var guard := _spawn_ai("bandits", ORIGIN + Vector2(0, 300), "Guard", true)
	var foe := _spawn_ai("player", ORIGIN, "Foe", false)
	party_chars = [foe]
	foe.equip_equipment(ItemDatabase.get_item_data("shadow_cloak"))
	var ai = guard.get_node("AI")
	_check("ai.cloaked-not-seen", not ai.can_see_character(foe))
	_check("ai.cloaked-not-acquired", not await _engaged_within(guard, foe, 1.5))
	foe.reveal()
	_check("ai.seen-in-window", ai.can_see_character(foe))
	_check("ai.acquires-attacker-in-window", await _engaged_within(guard, foe, 3.0))
	TimeManager.resume_time()
	await _clear()


func _engaged_within(guard: ProceduralCharacter, foe: ProceduralCharacter, seconds: float) -> bool:
	var ai = guard.get_node_or_null("AI")
	var elapsed := 0.0
	while elapsed < seconds:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		if ai != null and ai.current_target == foe:
			return true
	return false
