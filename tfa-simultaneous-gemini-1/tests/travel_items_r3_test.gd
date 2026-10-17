extends Node2D
# Round 3, travel-items lane: the developer's answers on world-map timers,
# rations and starting weapons, and the feedback each gives.
#   A. Travel and downtime conditions are authored in in-world hours, so the
#      7200x world-map clock doesn't end Force March within a frame; abilities
#      and downtime results can give duration_hours too; a party member's
#      condition running out on the world map (or any long one) is logged,
#      and companions folded into the banner expire theirs on the same clock.
#   B. Food is the ration (the "Ration" item trait): Burn a Ration burns the
#      cheapest food and refuses with "No food to burn"; Feasting hands out
#      bread; cards, the confirm dialog and tooltips show the food.
#   C. Starting weapons are their WeaponShape alone (no hidden item dict);
#      old saves drop the copies on load; give/drop/corpse loot still work;
#      an NPC picking up a weapon stows its WeaponShape (no dict either).
# Real ProceduralCharacter.tscn instances on a stub Game surface (as in
# equipment_effects_test); Game-side helpers drive a bare Game.gd instance.
#   godot --headless --path . res://tests/travel_items_r3_test.tscn
# Judge by the PASS/FAIL lines and "HARNESS DONE failures=0".

const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const ITEM_SCENE := preload("res://Structures/Objects/Item.tscn")
const GAME_SCRIPT := preload("res://Game.gd")
const ConfirmDialogScript := preload("res://UI/DowntimeConfirmDialog.gd")
const ItemTooltip = preload("res://UI/ItemTooltip.gd")
const EquipmentEffects = preload("res://Items/equipment_effects.gd")
const TravelConditionClock = preload("res://scripts/TravelConditionClock.gd")
const HOUR := 3600.0
# A template whose starting weapon is a real Items.json weapon.
const STARTER_TEMPLATE := "protagonist"
const STARTER_WEAPON := "longsword"

# ProceduralCharacter._process reads this off the game root (_process_approach).
const MELEE_ELEV_TOLERANCE: float = 0.5

# --- Game stub surface (ai.gd and ProceduralCharacter touch these) ---
var characters_in_scene: Array = []
var items_in_scene: Array = []
var structures_in_scene: Array = []
var party_chars: Array = []
var stealth_mode: bool = false
var surface_manager = null
var fluid_manager = null
var fog_manager = null
var context_menu_open := false
var primary_selected = null
var current_map_id: String = "town_square"

func can_hit_target(_a: Node2D, _t: Node2D) -> bool: return true
func register_hit(_a: Node2D, _t: Node2D) -> void: pass
func register_attack_start(_a: Node2D) -> void: pass
func register_attack_end(_a: Node2D) -> void: pass
func resolve_melee_swing(_a: Node2D, _hand: String) -> void: pass
func process_weapon_hit(_a, _t, _p, _w, _v) -> void: pass
func process_object_hit(_a, _t, _p, _w, _v) -> void: pass
func trigger_hearing_pulse(_source) -> void: pass

const ORIGIN := Vector2(2048, 2048)

var failures := 0
var checks := 0


func _check(check_name: String, cond: bool, detail = "") -> void:
	checks += 1
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, str(detail)])


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(4096, 4096)
	TimeManager.pause_time()
	await get_tree().process_frame
	# A. world-map durations
	_case_durations_in_hours()
	await _case_force_march_on_world_clock()
	_case_ability_side_hours()
	_case_downtime_result_hours()
	await _case_expiry_feedback()
	_case_banner_snapshots()
	# B. rations
	_case_ration_trait()
	_case_burn_a_ration()
	_case_feasting()
	_case_ration_display()
	# C. starting weapons
	_case_starting_weapon_no_dict()
	_case_old_save_migration()
	_case_starting_weapon_moves()
	await _case_npc_weapon_pickup()
	print("HARNESS DONE failures=%d checks=%d" % [failures, checks])
	get_tree().quit(1 if failures > 0 else 0)


func _new_char(char_name: String = "Tester", template: String = "default_human") -> ProceduralCharacter:
	var c: ProceduralCharacter = PC_SCENE.instantiate()
	c.AI_enabled = false
	c.is_player_controlled = true
	add_child(c)
	TopDownCharacterDatabase.build_character(c, template)
	c.game = self
	c.Name = char_name
	c.global_position = ORIGIN
	return c


func _party(c: ProceduralCharacter) -> ProceduralCharacter:
	party_chars.append(c)
	return c


func _free(c: Node) -> void:
	party_chars.erase(c)
	c.queue_free()


func _log_size() -> int:
	return GameLog.get_entries().size()


func _log_since(n: int) -> Array:
	var out: Array = []
	var entries: Array = GameLog.get_entries()
	for i in range(n, entries.size()):
		out.append(str(entries[i].get("text", "")))
	return out


func _food(id: String, n: int) -> Dictionary:
	var d: Dictionary = ItemDatabase.get_item_data(id)
	d["num_stacks"] = n
	return d


func _clear_conditions(c: ProceduralCharacter) -> void:
	c.condition_manager.clear_all_conditions()


# ---------------------------------------------------------------------------
# A. World-map durations
# ---------------------------------------------------------------------------

func _case_durations_in_hours() -> void:
	var want := {"force_marching": 12.0, "exhausted": 24.0, "hungover": 12.0, "blessed": 24.0}
	for cid in want:
		var tmpl = ConditionManager.condition_registry.get(cid)
		_check("hours.%s-%dh" % [cid, int(want[cid])], tmpl != null and is_equal_approx(tmpl.duration, want[cid] * HOUR),
			tmpl.duration if tmpl != null else "missing")
	# Afflictions that need treatment stay permanent.
	for cid in ["pox", "scarred", "haunted", "wanted", "fatigued"]:
		var tmpl = ConditionManager.condition_registry.get(cid)
		_check("hours.%s-still-permanent" % cid, tmpl != null and tmpl.duration < 0.0, tmpl.duration if tmpl != null else "missing")
	var desc := str(AbilityDatabase.get_ability_data("force_march").get("description", ""))
	_check("hours.force-march-description", desc.contains("12 hours") and not desc.contains("minutes"), desc)


func _case_force_march_on_world_clock() -> void:
	var c := _party(_new_char("Marcher"))
	c.on_world_map = true
	_clear_conditions(c)
	var data: Dictionary = AbilityDatabase.get_ability_data("force_march")
	var ability := Ability.from_dict(data)
	for effect in data.get("effects", []):
		AbilityEffect.resolve_effect(effect, c, [c], ability, c.global_position)
	var fm: ConditionInstance = c.condition_manager.get_condition("force_marching")
	var ex: ConditionInstance = c.condition_manager.get_condition("exhausted")
	_check("march.applied-12h", fm != null and is_equal_approx(fm.expires_at - fm.applied_at, 12.0 * HOUR),
		fm.expires_at - fm.applied_at if fm else "none")
	_check("march.exhausted-24h", ex != null and is_equal_approx(ex.expires_at - ex.applied_at, 24.0 * HOUR),
		ex.expires_at - ex.applied_at if ex else "none")
	var summary: String = fm.get_summary(TimeManager.absolute_time()) if fm else ""
	_check("march.countdown-reads-hours", summary == "Force-marching (12h 00m)", summary)
	_check("march.speed-doubled", is_equal_approx(c.overland_speed_modifier, 1.0), c.overland_speed_modifier)
	# Ten frames of the world map's 7200x clock: 120 s of Force March used to
	# end inside the first one.
	var t0 := TimeManager.absolute_time()
	TimeManager.set_time_scale(7200.0)
	TimeManager.resume_time()
	for i in range(10):
		await get_tree().process_frame
	TimeManager.pause_time()
	TimeManager.set_time_scale(1.0)
	var passed := TimeManager.absolute_time() - t0
	_check("march.survives-world-frames", passed > 120.0 and c.condition_manager.has_condition("force_marching"),
		"%.0f in-world s passed" % passed)
	_free(c)


func _case_ability_side_hours() -> void:
	var c := _new_char("Target")
	_clear_conditions(c)
	var ability := Ability.from_dict(AbilityDatabase.get_ability_data("force_march"))
	AbilityEffect.resolve_effect({"type": "apply_condition", "condition_id": "weakened", "duration_hours": 2},
		c, [c], ability, c.global_position)
	var inst: ConditionInstance = c.condition_manager.get_condition("weakened")
	_check("ability.duration-hours", inst != null and is_equal_approx(inst.expires_at - inst.applied_at, 2.0 * HOUR),
		inst.expires_at - inst.applied_at if inst else "none")
	_free(c)


func _case_downtime_result_hours() -> void:
	var c := _new_char("Sitter")
	_clear_conditions(c)
	# Meditation's "focus" result: Focused for a day, not for good.
	var focus: Dictionary = DowntimeDatabase.get_activity("meditation")["results"]["any_map"]["focus"]["effects"]
	_check("downtime.meditation-data", focus.get("add_condition") is Dictionary
		and int(focus["add_condition"].get("duration_hours", 0)) == 24, str(focus))
	var lines: Array = DowntimeEffectApplier.apply(c, {"add_condition": focus["add_condition"]})
	var inst: ConditionInstance = c.condition_manager.get_condition("focused")
	_check("downtime.focused-24h", inst != null and is_equal_approx(inst.expires_at - inst.applied_at, 24.0 * HOUR),
		inst.expires_at - inst.applied_at if inst else "none")
	_check("downtime.gained-line-says-how-long", lines == ["Gained: Focused (24h 00m)"], str(lines))
	# The stress virtue of the same name is still permanent.
	_check("downtime.virtue-focused-permanent", ConditionManager.condition_registry["focused"].duration < 0.0)
	var hung: Array = DowntimeEffectApplier.apply(c, {"add_condition": "hungover"})
	_check("downtime.hungover-line", hung == ["Gained: Hungover (12h 00m)"] or str(hung).contains("Resisted"), str(hung))
	_free(c)


func _case_expiry_feedback() -> void:
	var c := _party(_new_char("Ada"))
	_clear_conditions(c)
	# World map: even a combat-length condition running out is logged.
	c.on_world_map = true
	c.condition_manager.apply_condition("weakened", null, 1, 5.0)
	var n := _log_size()
	TimeManager.game_time += 10.0
	await get_tree().process_frame
	await get_tree().process_frame
	_check("expiry.world-map-logged", _log_since(n).has("Ada is no longer Weakened."), str(_log_since(n)))
	# Local map: a combat-length one stays quiet...
	c.on_world_map = false
	c.condition_manager.apply_condition("weakened", null, 1, 5.0)
	n = _log_size()
	TimeManager.game_time += 10.0
	await get_tree().process_frame
	await get_tree().process_frame
	_check("expiry.local-short-quiet", not c.condition_manager.has_condition("weakened") and _log_since(n).is_empty(),
		str(_log_since(n)))
	# ...but an hours-long one (a downtime hangover) is logged when it runs out.
	c.condition_manager.apply_condition("hungover", null, 1, -2.0)
	n = _log_size()
	TimeManager.game_time += 13.0 * HOUR
	await get_tree().process_frame
	await get_tree().process_frame
	_check("expiry.local-long-logged", _log_since(n).has("Ada is no longer Hungover."), str(_log_since(n)))
	# An NPC's never is.
	var npc := _new_char("Stranger")
	npc.on_world_map = true
	npc.condition_manager.apply_condition("weakened", null, 1, 5.0)
	n = _log_size()
	TimeManager.game_time += 10.0
	await get_tree().process_frame
	await get_tree().process_frame
	_check("expiry.npc-quiet", _log_since(n).filter(func(t): return t.contains("Stranger")).is_empty(), str(_log_since(n)))
	_free(npc)
	_free(c)


func _case_banner_snapshots() -> void:
	var now := TimeManager.absolute_time()
	var bo_conds := {
		"hungover": {"condition_id": "hungover", "stacks": 1, "expires_at": now - 1.0},
		"blessed": {"condition_id": "blessed", "stacks": 1, "expires_at": now + 600.0},
		"scarred": {"condition_id": "scarred", "stacks": 1, "expires_at": -1.0},
	}
	var party_state: Array = [
		{"template_id": "leader", "live_state": {"Name": "Leader", "condition_state": {"conditions": {
			"hungover": {"condition_id": "hungover", "expires_at": now - 1.0}}}}},
		{"template_id": "bo", "live_state": {"Name": "Bo", "current_health": 30, "condition_state": {"conditions": bo_conds}}},
		{"template_id": "away", "away": {"reason": "training"}, "live_state": {"Name": "Cy", "condition_state": {"conditions": {
			"hungover": {"condition_id": "hungover", "expires_at": now - 1.0}}}}},
		{"template_id": "dead", "live_state": {"Name": "Di", "current_health": 0, "condition_state": {"conditions": {
			"hungover": {"condition_id": "hungover", "expires_at": now - 1.0}}}}},
	]
	var lines: PackedStringArray = TravelConditionClock.expire_snapshots(party_state, {0: true}, now)
	_check("banner.companion-expired-logged", Array(lines) == ["Bo is no longer Hungover."], str(lines))
	_check("banner.snapshot-trimmed", not bo_conds.has("hungover") and bo_conds.has("blessed") and bo_conds.has("scarred"), str(bo_conds.keys()))
	_check("banner.body-row-skipped", party_state[0]["live_state"]["condition_state"]["conditions"].has("hungover"))
	_check("banner.away-and-dead-skipped", party_state[2]["live_state"]["condition_state"]["conditions"].has("hungover")
		and party_state[3]["live_state"]["condition_state"]["conditions"].has("hungover"))
	# Game drives it on the world map: the leader's body ticks itself.
	var game = GAME_SCRIPT.new()
	var leader := _new_char("Leader")
	leader.set_meta("party_index", 0)
	game.party_chars = [leader]
	bo_conds["blessed"]["expires_at"] = now - 1.0
	game.party_state = party_state
	var n := _log_size()
	game._tick_banner_party_conditions()
	_check("banner.game-tick-logs", _log_since(n) == ["Bo is no longer Blessed."], str(_log_since(n)))
	game.free()
	_free(leader)


# ---------------------------------------------------------------------------
# B. Rations
# ---------------------------------------------------------------------------

func _case_ration_trait() -> void:
	for id in ["bread_loaf", "apple", "cheese_wheel", "roast_fowl", "meat_pie"]:
		_check("ration.%s-is-food" % id, ItemDatabase.is_ration(ItemDatabase.get_item_data(id)))
	for id in ["alcohol", "waterskin", "longsword", "gold"]:
		_check("ration.%s-is-not" % id, not ItemDatabase.is_ration(ItemDatabase.get_item_data(id)))
	# Food saved before the trait existed still counts (judged by its id).
	_check("ration.old-save-apple", ItemDatabase.is_ration({"id": "apple", "traits": {"Organic": 1}}))


func _case_burn_a_ration() -> void:
	var c := _party(_new_char("Burner"))
	var burn: Dictionary = DowntimeDatabase.get_activity("burn_ration")
	c.inventory.items.clear()
	var reason: String = DowntimeResolver.unavailable_reason(c, burn)
	_check("burn.refused-without-food", reason.begins_with("No food to burn"), reason)
	var dlg = ConfirmDialogScript.new()
	dlg.populate(c, burn, 0, true, reason)
	_check("burn.dialog-says-why", dlg.dialog_text.contains("[UNAVAILABLE] No food to burn")
		and dlg.get_ok_button().disabled, dlg.dialog_text)
	dlg.free()
	_check("burn.applier-none-line", DowntimeEffectApplier.apply(c, {"ration_delta": -1}) == ["No food to burn"])

	# Cheapest food first: an apple goes before a meat pie.
	c.inventory.items.append(_food("meat_pie", 1))
	c.inventory.items.append(_food("apple", 2))
	_check("burn.available-with-food", DowntimeResolver.unavailable_reason(c, burn) == "")
	dlg = ConfirmDialogScript.new()
	dlg.populate(c, burn, 0, false, "")
	_check("burn.dialog-food-line", dlg.dialog_text.contains("Food carried: 3 (Meat Pie, Apple x2). Burns one Apple, the cheapest."),
		dlg.dialog_text)
	dlg.free()
	var n := _log_size()
	DowntimeResolver.resolve_silently(c, "burn_ration", "")
	var apples := 0
	var pies := 0
	for it in c.inventory.items:
		if str(it.get("id", "")) == "apple":
			apples += int(it.get("num_stacks", 1))
		if str(it.get("id", "")) == "meat_pie":
			pies += 1
	_check("burn.one-apple-consumed", apples == 1 and pies == 1, "apples %d pies %d" % [apples, pies])
	var summary := ""
	for t in _log_since(n):
		if t.contains("(Burn a Ration)"):
			summary = t
	_check("burn.summary-logged", summary.contains("-1 Apple"), str(_log_since(n)))
	_check("burn.ration-count", DowntimeEffectApplier.ration_count(c) == 2, DowntimeEffectApplier.ration_count(c))
	_free(c)


func _case_feasting() -> void:
	var c := _party(_new_char("Guest"))
	c.inventory.items.clear()
	var feast: Dictionary = DowntimeDatabase.get_activity("feasting")
	_check("feast.data-gives-food", DowntimeEffectApplier.ration_delta_of(feast) == 1)
	var lines: Array = DowntimeEffectApplier.apply(c, (feast["default_effects"] as Dictionary).duplicate(true))
	_check("feast.gives-bread", lines == ["+1 Bread Loaf"] and c.inventory.find_item_by_id("bread_loaf") >= 0, str(lines))
	_check("feast.bread-is-a-ration", DowntimeEffectApplier.ration_count(c) == 1)
	var dlg = ConfirmDialogScript.new()
	dlg.populate(c, feast, 0, false, "")
	_check("feast.dialog-food-line", dlg.dialog_text.contains("Food carried: 1 (Bread Loaf). The parish gives 1 Bread Loaf."), dlg.dialog_text)
	dlg.free()
	# A full pack: said, not silently dropped.
	c.inventory.items.clear()
	while c.inventory.slots_used() < c.inventory.max_slots:
		c.inventory.items.append({"id": "tr3_filler_%d" % c.inventory.items.size(), "display_name": "Filler"})
	var n := _log_size()
	var full: Array = DowntimeEffectApplier.apply(c, {"ration_delta": 1})
	_check("feast.full-pack-said", full == ["No room for the Bread Loaf"], str(full))
	_check("feast.full-pack-logged", "
".join(_log_since(n)).contains("can't carry the Bread Loaf"), str(_log_since(n)))
	_free(c)


func _case_ration_display() -> void:
	var a := _party(_new_char("Ada"))
	var b := _party(_new_char("Bo"))
	a.inventory.items.clear()
	b.inventory.items.clear()
	a.inventory.items.append(_food("apple", 2))
	a.inventory.items.append(_food("cheese_wheel", 1))
	var burn: Dictionary = DowntimeDatabase.get_activity("burn_ration")
	var line: String = DowntimeEffectApplier.ration_card_line(burn, [a, b])
	_check("display.burn-card-line", line == "Burns 1 food, cheapest first. Food carried: Ada 3, Bo none", line)
	var feast_line: String = DowntimeEffectApplier.ration_card_line(DowntimeDatabase.get_activity("feasting"), [a, b])
	_check("display.feast-card-line", feast_line == "Gives 1 Bread Loaf. Food carried: Ada 3, Bo none", feast_line)
	_check("display.other-cards-quiet", DowntimeEffectApplier.ration_card_line(DowntimeDatabase.get_activity("rest"), [a, b]) == "")
	# The camp card carries a food label; the Rest card doesn't.
	var panel = load("res://UI/CampDowntimePanel.gd").new()
	var card: Control = panel._build_activity_card("burn_ration", burn)
	var found := false
	for l in card.find_children("*", "Label", true, false):
		if str(l.text).begins_with("Burns 1 food"):
			found = true
	_check("display.camp-card-food-label", found)
	var rest_card: Control = panel._build_activity_card("rest", DowntimeDatabase.get_activity("rest"))
	var rest_food := false
	for l in rest_card.find_children("*", "Label", true, false):
		if str(l.text).contains("food"):
			rest_food = true
	_check("display.rest-card-no-food-label", not rest_food)
	card.free()
	rest_card.free()
	panel.free()
	# Tooltips: food says it counts as a ration; a sword doesn't.
	var tip := ItemTooltip.detail_text({"kind": "item", "display_name": "Apple", "raw": _food("apple", 1)})
	_check("display.food-tooltip", tip.contains("Ration: Burn a Ration"), tip)
	var sword_tip := ItemTooltip.detail_text({"kind": "item", "display_name": "Longsword", "raw": ItemDatabase.get_item_data("longsword")})
	_check("display.non-food-tooltip", not sword_tip.contains("Ration"), sword_tip)
	_free(a)
	_free(b)


# ---------------------------------------------------------------------------
# C. Starting weapons
# ---------------------------------------------------------------------------

func _weapons(c, id: String) -> int:
	var n := 0
	for w in c.inventory.get_all_equipped():
		if w is WeaponShape and str(w.id) == id:
			n += 1
	return n


func _weapon_node(c, id: String):
	for w in c.inventory.get_all_equipped():
		if w is WeaponShape and str(w.id) == id:
			return w
	return null


func _hand_dicts(c) -> int:
	var n := 0
	for d in c.inventory.items:
		if EquipmentEffects.is_hand_ghost(d):
			n += 1
	return n


func _case_starting_weapon_no_dict() -> void:
	# The protagonist template starts with a longsword (and a bow and a pistol;
	# the last one granted ends up in the main hand, the rest stowed).
	var c := _new_char("Recruit", STARTER_TEMPLATE)
	_check("start.sword-is-a-shape", _weapons(c, STARTER_WEAPON) == 1, _weapons(c, STARTER_WEAPON))
	_check("start.no-hidden-dict", _hand_dicts(c) == 0 and c.inventory.find_item_by_id(STARTER_WEAPON) < 0, str(c.inventory.items))
	_check("start.slots-count-every-dict", c.inventory.slots_used() == c.inventory.items.size())
	# Two daggers: one in hand, one stowed, still no dict.
	TopDownCharacterDatabase._grant_equipment(c, [{"id": "dagger", "slot": "off_hand", "quantity": 2}])
	var daggers := 0
	for w in c.inventory.get_all_equipped():
		if w is WeaponShape and str(w.id) == "dagger":
			daggers += 1
	_check("start.quantity-two-shapes", daggers == 2 and _hand_dicts(c) == 0, "daggers %d dicts %d" % [daggers, _hand_dicts(c)])
	_free(c)


func _case_old_save_migration() -> void:
	var game = GAME_SCRIPT.new()
	var a := _new_char("Veteran", STARTER_TEMPLATE)
	var snap: Dictionary = game._serialize_character(a)
	var sword: Dictionary = ItemDatabase.get_item_data(STARTER_WEAPON)
	var dagger: Dictionary = ItemDatabase.get_item_data("dagger")
	# A pre-fix snapshot: the held sword's hidden copy, plus the copy of a
	# dagger given away long ago, beside a real apple.
	var ghost := sword.duplicate()
	ghost["source"] = "starting_equipment"
	snap["inventory_items"] = [ghost, dagger.duplicate(), _food("apple", 1)]
	snap["faction_id"] = "player"
	var b := _new_char("Veteran", STARTER_TEMPLATE)
	game._deserialize_character(b, snap)
	_check("migrate.party-ghosts-dropped", _hand_dicts(b) == 0 and b.inventory.items.size() == 1
		and str(b.inventory.items[0].get("id")) == "apple", str(b.inventory.items))
	_check("migrate.party-sword-still-carried", _weapons(b, STARTER_WEAPON) == 1, _weapons(b, STARTER_WEAPON))
	var b_daggers := 0
	for w in b.inventory.get_all_equipped():
		if w is WeaponShape and str(w.id) == "dagger":
			b_daggers += 1
	_check("migrate.party-no-free-duplicate", b_daggers == 0, b_daggers)
	# An NPC's unmatched hand dict was a weapon it picked up: stowed, not lost.
	snap["faction_id"] = "bandits"
	var npc := _new_char("Bandit", STARTER_TEMPLATE)
	game._deserialize_character(npc, snap)
	var npc_daggers := 0
	for w in npc.inventory.stowed_items:
		if w is WeaponShape and str(w.id) == "dagger":
			npc_daggers += 1
	_check("migrate.npc-pickup-stowed", npc_daggers == 1 and _hand_dicts(npc) == 0, "daggers %d dicts %d" % [npc_daggers, _hand_dicts(npc)])
	# A corpse keeps its weapon dicts: they are its loot.
	snap["current_health"] = 0
	snap["equipped_weapons"] = []
	snap["inventory_items"] = [sword.duplicate()]
	var corpse := _new_char("Corpse", STARTER_TEMPLATE)
	game._deserialize_character(corpse, snap)
	_check("migrate.corpse-loot-kept", corpse.inventory.find_item_by_id(STARTER_WEAPON) >= 0, str(corpse.inventory.items))
	game.free()
	_free(a)
	_free(b)
	_free(npc)
	_free(corpse)


func _case_starting_weapon_moves() -> void:
	var a := _party(_new_char("Giver", STARTER_TEMPLATE))
	var b := _party(_new_char("Taker", STARTER_TEMPLATE))
	var panel = load("res://UI/PartySidePanel.gd").new()
	var items_before: int = a.inventory.items.size()
	var sword = _weapon_node(a, STARTER_WEAPON)
	panel._transfer_weapon(a, b, sword)
	var b_swords := 0
	for w in b.inventory.get_all_equipped():
		if w is WeaponShape and str(w.id) == STARTER_WEAPON:
			b_swords += 1
	_check("moves.give-starting-sword", _weapons(a, STARTER_WEAPON) == 0 and b_swords == 2
		and a.inventory.items.size() == items_before, "taker swords %d" % b_swords)
	# Drop: the shape leaves and nothing is left behind in the pack.
	var held = b.inventory.main_hand_item
	_check("moves.drop-starting-sword", held != null and panel._remove_weapon_from_inventory(b.inventory, held) and _hand_dicts(b) == 0)
	if held != null:
		held.queue_free()
	# Unequip: the starting sword goes to stowed and back.
	var c := _new_char("Holster", STARTER_TEMPLATE)
	c.inventory.holster_weapon()
	_check("moves.holster", c.inventory.main_hand_item == null and c.inventory.stowed_items.size() >= 1)
	c.inventory.draw_weapon()
	_check("moves.draw", c.inventory.main_hand_item is WeaponShape and _hand_dicts(c) == 0)
	# Death: the starting sword is looted exactly once.
	c.inventory.flatten_for_corpse()
	var swords := 0
	for d in c.inventory.items:
		if str(d.get("id", "")) == STARTER_WEAPON:
			swords += 1
	_check("moves.corpse-one-sword", swords == 1, swords)
	panel.free()
	_free(a)
	_free(b)
	_free(c)


func _case_npc_weapon_pickup() -> void:
	var npc := _new_char("Scavenger")
	await get_tree().physics_frame
	var lai = npc.get_node_or_null("AI")
	if lai == null or not lai.has_method("pickup_item"):
		print("SKIP pickup.npc-weapon-stowed (no AI node)")
		_free(npc)
		return
	var it: Item = ITEM_SCENE.instantiate()
	it.id = "dagger"
	it.global_position = ORIGIN + Vector2(40, 0)
	add_child(it)
	items_in_scene.append(it)
	var dicts_before: int = npc.inventory.items.size()
	var daggers_before := _weapons(npc, "dagger")
	lai.current_goal = "seek_wealth"
	lai.pickup_item(it)
	_check("pickup.npc-weapon-stowed", _weapons(npc, "dagger") == daggers_before + 1
		and npc.inventory.items.size() == dicts_before and _hand_dicts(npc) == 0,
		"daggers %d -> %d, dicts %d -> %d" % [daggers_before, _weapons(npc, "dagger"), dicts_before, npc.inventory.items.size()])
	_check("pickup.item-left-the-ground", not is_instance_valid(it) or it.is_queued_for_deletion())
	_free(npc)
