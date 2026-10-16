extends Node2D
# Equipment effects: what worn gear and held weapons do beyond armour DR and
# weapon damage (Items/equipment_effects.gd and ProceduralCharacter's worn-gear
# block).
#   - worn conditions: the Dark Hood's Shrouded, the Golden Crown's Inspired;
#     a condition another source or another worn item also holds survives the
#     item coming off; one that ends while the item is on comes back
#   - warps: Game._deserialize_character re-wears the saved gear (not the
#     template's), with a worn pack's slots sized before the items go back in
#   - light: emits_light is a 0..1 level; held weapons, worn gear and dropped
#     items glow
#   - pack slots: a worn pack raises Inventory.max_slots; the hidden hand
#     dicts don't fill the bag; the side panel refuses gear changes that would
#     leave more carried than fits
#   - concealment: Shrouded halves how far the AI notices its wearer, and an
#     attack or cast reveals it for a few seconds
#   - item tooltips list all of this through ItemTooltip.effect_lines
# Real ProceduralCharacter.tscn instances on a stub Game surface (as in
# ai_engage_check); the warp case drives a bare Game.gd instance (as in
# npc_race_persistence_check). Headless-safe.
#   godot --headless --path . res://tests/equipment_effects_test.tscn
# Judge by the PASS/FAIL lines and "HARNESS DONE failures=0".

const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const ITEM_SCENE := preload("res://Structures/Objects/Item.tscn")
const GAME_SCRIPT := preload("res://Game.gd")
const EquipmentEffects = preload("res://Items/equipment_effects.gd")
const ItemTooltip = preload("res://UI/ItemTooltip.gd")
const HEAD := EquipmentShape.EquipmentSlot.HEAD
const BACK := EquipmentShape.EquipmentSlot.BACK
const FEET := EquipmentShape.EquipmentSlot.FEET

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
var current_map_id: String = "test"

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
	GridManager.initialize(4096, 4096)
	await get_tree().process_frame
	await _run_conditions()
	_run_rebuild()
	await _run_warp()
	_run_light()
	_run_pack_slots()
	await _run_concealment()
	_run_tooltips()
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


## A head item granting Hasted while worn (Hasted is a 30 s template).
func _circlet() -> Dictionary:
	return {"id": "test_circlet", "display_name": "Test Circlet", "type": "helmet",
		"equip_slot": "Head", "adds_condition_on_equip": "Hasted"}


func _boots() -> Dictionary:
	return {"id": "test_boots", "display_name": "Test Boots", "type": "boots",
		"equip_slot": "Feet", "adds_condition_on_equip": "Hasted"}


func _item(id: String) -> Dictionary:
	return ItemDatabase.get_item_data(id)


# ---------------------------------------------------------------------------
# Worn conditions
# ---------------------------------------------------------------------------

func _run_conditions() -> void:
	_check("cond.ids-normalised", EquipmentEffects.condition_ids_for(_circlet()) == ["hasted"],
		str(EquipmentEffects.condition_ids_for(_circlet())))
	_check("cond.registered", ConditionManager.condition_registry.has("shrouded")
		and ConditionManager.condition_registry.has("inspired"))
	# Every adds_condition_on_equip in Items.json resolves now.
	var unresolved := []
	for id in ["dark_hood", "golden_crown_helm", "shadow_cloak", "pensword", "winters_grip"]:
		if EquipmentEffects.condition_ids_for(_item(id)).is_empty():
			unresolved.append(id)
	_check("cond.items-resolve", unresolved.is_empty(), str(unresolved))

	var c := _new_char()
	var cm: ConditionManager = c.condition_manager
	c.equip_equipment(_circlet())
	var inst: ConditionInstance = cm.get_condition("hasted")
	_check("cond.equip-applies-permanent", inst != null and inst.expires_at < 0.0,
		str(inst.expires_at) if inst else "none")
	c.unequip_slot(HEAD)
	_check("cond.unequip-removes", not cm.has_condition("hasted"))

	# Already on from a spell (30 s left) when the circlet goes on: taking it
	# off hands the spell's own expiry back instead of stripping it.
	var pre: ConditionInstance = cm.apply_condition("hasted", null, 1, 30.0)
	var expiry: float = pre.expires_at
	c.equip_equipment(_circlet())
	_check("cond.prior-made-permanent", pre.expires_at < 0.0)
	c.unequip_slot(HEAD)
	var post: ConditionInstance = cm.get_condition("hasted")
	_check("cond.prior-survives-unequip", post == pre)
	if post:
		_check("cond.prior-expiry-restored", is_equal_approx(post.expires_at, expiry),
			"%s vs %s" % [post.expires_at, expiry])
		_check("cond.prior-mark-cleared", not post.custom_data.has(c.EQUIP_PREV_EXPIRY_KEY))
	cm.remove_condition("hasted")

	# Two worn items grant the same condition: it stays until both are off.
	c.equip_equipment(_circlet())
	c.equip_equipment(_boots())
	c.unequip_slot(HEAD)
	_check("cond.shared-stays-while-other-worn", cm.has_condition("hasted"))
	c.unequip_slot(FEET)
	_check("cond.shared-goes-with-last", not cm.has_condition("hasted"))

	# Ended while still worn (a purge): it comes back.
	c.equip_equipment(_circlet())
	cm.remove_condition("hasted")
	await get_tree().process_frame
	_check("cond.removed-while-worn-returns", cm.has_condition("hasted"))
	c.unequip_slot(HEAD)
	await get_tree().process_frame
	_check("cond.unequipped-stays-off", not cm.has_condition("hasted"))

	# The Shadow Cloak's Invisible is dev's binary condition. Illuminated
	# evicts it; it comes back once the light is gone.
	c.equip_equipment(_item("shadow_cloak"))
	_check("cond.cloak-invisible", cm.has_active_condition("invisible"))
	_check("cond.cloak-binary-visibility", is_equal_approx(c.effective_visibility(), 1.0),
		str(c.effective_visibility()))
	cm.apply_condition("illuminated", null, 1)
	await get_tree().process_frame
	_check("cond.cloak-evicted-by-light", not cm.has_condition("invisible"))
	cm.remove_condition("illuminated")
	await get_tree().process_frame
	_check("cond.cloak-returns-after-light", cm.has_active_condition("invisible"))
	c.unequip_slot(BACK)
	await get_tree().process_frame
	_check("cond.cloak-off", not cm.has_condition("invisible"))

	# Dark Hood: Shrouded halves visibility; an attack or cast reveals.
	c.equip_equipment(_item("dark_hood"))
	_check("cond.hood-shrouded", cm.has_active_condition("shrouded"))
	_check("cond.hood-visibility", is_equal_approx(c.effective_visibility(), 0.5),
		str(c.effective_visibility()))
	c.reveal()
	_check("cond.reveal-full", is_equal_approx(c.effective_visibility(), 1.0))
	TimeManager.game_time += c.REVEAL_SECONDS + 0.5
	_check("cond.reveal-wears-off", is_equal_approx(c.effective_visibility(), 0.5),
		str(c.effective_visibility()))
	c.unequip_slot(HEAD)
	_check("cond.hood-off", not cm.has_condition("shrouded") and is_equal_approx(c.effective_visibility(), 1.0))

	# Golden Crown: Inspired is +10 Will and +10 Charisma.
	var will0: float = c.effective_will()
	var cha0: float = c.effective_charisma()
	c.equip_equipment(_item("golden_crown_helm"))
	_check("cond.crown-inspired", cm.has_active_condition("inspired"))
	_check("cond.crown-will", is_equal_approx(c.effective_will(), will0 + 10.0),
		"%s -> %s" % [will0, c.effective_will()])
	_check("cond.crown-charisma", is_equal_approx(c.effective_charisma(), cha0 + 10.0),
		"%s -> %s" % [cha0, c.effective_charisma()])
	c.unequip_slot(HEAD)
	_check("cond.crown-off", is_equal_approx(c.effective_will(), will0))
	c.queue_free()


# ---------------------------------------------------------------------------
# rebuild_worn_from_inventory
# ---------------------------------------------------------------------------

func _run_rebuild() -> void:
	var c := _new_char()
	var cm: ConditionManager = c.condition_manager
	# After a warp the body wears the template's gear; the flags say what was
	# really worn.
	c.equip_equipment({"id": "test_helm", "display_name": "Template Helm", "type": "helmet", "equip_slot": "Head"})
	var circlet := _circlet()
	circlet["_equipped"] = true
	var second := {"id": "test_hood", "display_name": "Second Hood", "type": "hood", "equip_slot": "Head", "_equipped": true}
	var nowhere := {"id": "test_pads", "display_name": "Pads", "type": "shoulder_pads", "equip_slot": "Shoulders", "_equipped": true}
	var cloak := _item("shadow_cloak")
	cloak["_equipped"] = true
	c.inventory.items.clear()
	for d in [circlet, second, nowhere, cloak]:
		c.inventory.items.append(d)
	c.rebuild_worn_from_inventory()
	var worn: Array = c.worn_item_datas()
	_check("rebuild.wears-flagged", worn.size() == 2 and worn.has(circlet) and worn.has(cloak), str(worn.map(func(d): return d.get("id"))))
	_check("rebuild.cape-on-back", c.back_equipment != null)
	_check("rebuild.conditions", cm.has_condition("hasted") and cm.has_condition("invisible"))
	_check("rebuild.clears-duplicate-slot", not second.get("_equipped", false))
	_check("rebuild.clears-unknown-slot", not nowhere.get("_equipped", false))
	circlet["_equipped"] = false
	cloak["_equipped"] = false
	c.rebuild_worn_from_inventory()
	_check("rebuild.unflagged-off", c.worn_item_datas().is_empty() and not cm.has_condition("hasted"))

	# A helmet doesn't go back on a severed head.
	circlet["_equipped"] = true
	c.severed_limbs[c.LimbType.HEAD] = true
	c.rebuild_worn_from_inventory()
	_check("rebuild.no-helmet-on-severed-head", c.head_equipment == null and not circlet.get("_equipped", false))
	c.queue_free()

	# Inventory.load_from_dict re-wears capes too.
	var d := _new_char("Loader")
	var cape := _item("shadow_cloak")
	cape["_equipped"] = true
	d.inventory.load_from_dict({"items": [cape]})
	_check("rebuild.load-from-dict-cape", d.back_equipment != null and d.condition_manager.has_condition("invisible"))
	d.queue_free()


# ---------------------------------------------------------------------------
# Warp: Game._deserialize_character
# ---------------------------------------------------------------------------

func _stone(i: int) -> Dictionary:
	return {"id": "test_stone_%d" % i, "display_name": "Stone %d" % i}


func _run_warp() -> void:
	var game = GAME_SCRIPT.new()
	var a := _new_char("Warper")
	var hood := _item("dark_hood")
	var pack := _item("leather_backpack")
	for d in [hood, pack]:
		a.inventory.add_item(d)
		d["_equipped"] = true
		a.equip_equipment(d)
	for i in range(24):
		a.inventory.add_item(_stone(i))
	var carried: int = a.inventory.slots_used()
	_check("warp.setup-carrying-over-base", carried > 20 and a.inventory.max_slots == 30,
		"%d/%d" % [carried, a.inventory.max_slots])
	await get_tree().process_frame
	var snap: Dictionary = game._serialize_character(a)

	var b := _new_char("Warper")
	game._deserialize_character(b, snap)
	await get_tree().process_frame
	var ids: Array = b.worn_item_datas().map(func(d): return str(d.get("id")))
	_check("warp.gear-re-worn", ids.has("dark_hood") and ids.has("leather_backpack"), str(ids))
	_check("warp.pack-slots", b.inventory.max_slots == 30, str(b.inventory.max_slots))
	_check("warp.nothing-refused", b.inventory.slots_used() == carried,
		"%d vs %d" % [b.inventory.slots_used(), carried])
	_check("warp.worn-condition", b.condition_manager.has_active_condition("shrouded"))
	var worn_dicts_are_inventory := true
	for d in b.worn_item_datas():
		if not b.inventory.items.has(d):
			worn_dicts_are_inventory = false
	_check("warp.worn-shapes-hold-inventory-dicts", worn_dicts_are_inventory)
	a.queue_free()
	b.queue_free()
	game.free()


# ---------------------------------------------------------------------------
# Light
# ---------------------------------------------------------------------------

func _weapon(item_id: String) -> WeaponShape:
	var w := WeaponShape.new()
	w.load_from_data(_item(item_id))
	add_child(w)
	return w


func _run_light() -> void:
	var sword := _weapon("flaming_sword")
	var light: PointLight2D = sword.get_node_or_null("EmittedLight")
	_check("light.sword-has-light", light != null)
	if light:
		_check("light.sword-energy", is_equal_approx(light.energy, 1.0), str(light.energy))
		_check("light.sword-radius", is_equal_approx(light.texture_scale * EquipmentEffects.LIGHT_TEX_SIZE * 0.5, 256.0))
		_check("light.sword-fire-colour", light.color == EquipmentEffects.LIGHT_TRAIT_COLORS["fire"])
	_check("light.weapon-display-name", sword.display_name == "Flaming Sword", sword.display_name)
	var axe := _weapon("frost_axe")
	_check("light.axe-level", is_equal_approx(axe.emits_light, 0.1), str(axe.emits_light))
	_check("light.axe-roundtrip", is_equal_approx(float(axe.to_data()["emits_light"]), 0.1))
	var reloaded := WeaponShape.new()
	reloaded.load_from_data(axe.to_data())
	_check("light.roundtrip-name", reloaded.display_name == "Frost Axe", reloaded.display_name)
	reloaded.free()
	var plain := _weapon("longsword")
	_check("light.longsword-dark", plain.get_node_or_null("EmittedLight") == null)
	for w in [sword, axe, plain]:
		w.queue_free()

	var c := _new_char()
	c.equip_equipment(_item("golden_crown_helm"))
	var worn: PointLight2D = c.torso_slot.get_node_or_null("WornLight")
	_check("light.crown-worn-light", worn != null)
	if worn:
		_check("light.crown-energy", is_equal_approx(worn.energy, 0.35 + 0.65 * 0.3), str(worn.energy))
		_check("light.crown-noble-colour", worn.color == EquipmentEffects.LIGHT_TRAIT_COLORS["noble"])
	c.unequip_slot(HEAD)
	_check("light.crown-off-dark", c.torso_slot.get_node_or_null("WornLight") == null)
	c.queue_free()

	var dropped = ITEM_SCENE.instantiate()
	dropped.id = "flaming_sword"
	dropped.global_position = ORIGIN + Vector2(300, 300)
	add_child(dropped)
	_check("light.dropped-item-glows", dropped.get_node_or_null("EmittedLight") != null)
	dropped.queue_free()


# ---------------------------------------------------------------------------
# Pack slots and hidden hand dicts
# ---------------------------------------------------------------------------

func _run_pack_slots() -> void:
	_check("pack.slots-data", EquipmentEffects.container_slots(_item("leather_backpack")) == 10
		and EquipmentEffects.container_slots(_item("adventurer's_pack")) == 20)
	_check("pack.chest-slots-ignored", EquipmentEffects.container_slots(_item("treasure_chest")) == 0)

	var c := _new_char()
	var inv = c.inventory
	# Starting gear: a granted weapon leaves a hidden Main Hand dict behind.
	inv.items.clear()
	TopDownCharacterDatabase._grant_equipment(c, [{"id": "longsword", "slot": "main_hand"}])
	_check("pack.starting-ghost-not-counted", inv.items.size() == 1 and inv.slots_used() == 0,
		"%d of %d" % [inv.slots_used(), inv.items.size()])
	inv.items.clear()
	inv.items.append({"id": "longsword", "equip_slot": "Main Hand"})
	_check("pack.ghost-not-counted", inv.slots_used() == 0, str(inv.slots_used()))

	var pack := _item("leather_backpack")
	inv.add_item(pack)
	pack["_equipped"] = true
	c.equip_equipment(pack)
	_check("pack.cap-30", inv.max_slots == 30, str(inv.max_slots))
	for i in range(24):
		inv.add_item(_stone(i))
	_check("pack.carrying-25", inv.slots_used() == 25, str(inv.slots_used()))
	var why: String = c.worn_capacity_problem(pack)
	_check("pack.unequip-refused", why.contains("Drop 5"), why)
	var cloak := _item("shadow_cloak")
	_check("pack.cloak-swap-refused", c.worn_capacity_problem(pack, cloak) != "")
	_check("pack.bigger-pack-swap-ok", c.worn_capacity_problem(pack, _item("adventurer's_pack")) == "")

	# The panel refuses with a notice and leaves the pack on.
	var panel = load("res://UI/PartySidePanel.gd").new()
	var n0: int = GameLog.get_entries().size()
	_check("pack.panel-unequip-refused", panel._unequip_item(c, inv.items.find(pack), pack) == false)
	_check("pack.panel-refusal-logged", GameLog.get_entries().size() == n0 + 1
		and str(GameLog.get_entries()[-1].text).contains("can't take off the Leather Backpack"),
		str(GameLog.get_entries()[-1].text) if GameLog.get_entries().size() > 0 else "")
	_check("pack.still-worn", c.back_equipment != null and pack.get("_equipped", false))
	# Drop and Drop All are refused the same way (the refusal returns before
	# anything reaches the world, so this stub Game needs no create_item).
	panel.game_node = self
	panel._drop_item(c, inv.items.find(pack), pack)
	panel._drop_item_amount(c, inv.items.find(pack), pack, 1)
	_check("pack.panel-drop-refused", inv.items.has(pack) and c.back_equipment != null and pack.get("_equipped", false))
	inv.add_item(cloak)
	panel._equip_item(c, inv.items.find(cloak), cloak)
	_check("pack.panel-swap-refused", not cloak.get("_equipped", false) and c.worn_item_datas().has(pack))
	inv.items.erase(cloak)

	# Fill to the cap: add_item refuses, but a hand-weapon mirror still goes in.
	while inv.slots_used() < inv.max_slots:
		inv.add_item(_stone(100 + inv.slots_used()))
	_check("pack.full-refuses", not inv.add_item(_stone(999)))
	_check("pack.full-takes-ghost", inv.add_item({"id": "dagger", "equip_slot": "Main Hand"}))

	# Down to 20 carried: it comes off (a Drop counts the pack leaving too).
	while inv.slots_used() > 21:
		for i in range(inv.items.size() - 1, -1, -1):
			if str(inv.items[i].get("id", "")).begins_with("test_stone"):
				inv.items.remove_at(i)
				break
	_check("pack.drop-counts-the-pack", c.worn_capacity_problem(pack, {}, 1) == "" and c.worn_capacity_problem(pack) != "")
	_check("pack.panel-unequip-ok", panel._unequip_item(c, inv.items.find(pack), pack, 1) == true)
	_check("pack.cap-back-20", inv.max_slots == 20 and c.back_equipment == null)
	panel.free()
	c.queue_free()


# ---------------------------------------------------------------------------
# Concealment: the AI notices a Shrouded foe at half range
# ---------------------------------------------------------------------------

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
	await get_tree().physics_frame
	await get_tree().physics_frame


func _engaged_within(guard: ProceduralCharacter, foe: ProceduralCharacter, seconds: float) -> bool:
	var ai = guard.get_node_or_null("AI")
	var elapsed := 0.0
	while elapsed < seconds:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		if ai != null and ai.current_target == foe:
			return true
	return false


func _run_concealment() -> void:
	# The foe stands at 60% of the guard's sight range, straight ahead.
	var probe := _spawn_ai("bandits", ORIGIN, "Probe", false)
	var range_px: float = probe.get_node("AI").get_sight_range_pixels()
	await _clear()

	var guard := _spawn_ai("bandits", ORIGIN + Vector2(0, 600), "Guard", true)
	var foe := _spawn_ai("player", ORIGIN + Vector2(0, 600 - range_px * 0.6), "Foe", false)
	party_chars = [foe]
	_check("conceal.control-seen-at-60pct", await _engaged_within(guard, foe, 3.0),
		"range %.0f" % range_px)
	await _clear()

	guard = _spawn_ai("bandits", ORIGIN + Vector2(0, 600), "Guard", true)
	foe = _spawn_ai("player", ORIGIN + Vector2(0, 600 - range_px * 0.6), "Foe", false)
	party_chars = [foe]
	foe.equip_equipment(_item("dark_hood"))
	_check("conceal.shrouded-unseen-at-60pct", not await _engaged_within(guard, foe, 2.0))
	foe.reveal()
	_check("conceal.revealed-is-seen", await _engaged_within(guard, foe, 3.0))
	await _clear()

	guard = _spawn_ai("bandits", ORIGIN + Vector2(0, 600), "Guard", true)
	foe = _spawn_ai("player", ORIGIN + Vector2(0, 600 - range_px * 0.4), "Foe", false)
	party_chars = [foe]
	foe.equip_equipment(_item("dark_hood"))
	_check("conceal.shrouded-seen-at-40pct", await _engaged_within(guard, foe, 3.0))
	await _clear()


# ---------------------------------------------------------------------------
# Tooltips (ItemTooltip.effect_lines) and the equip notice text
# ---------------------------------------------------------------------------

func _run_tooltips() -> void:
	var hood_tip: String = ItemTooltip.detail_text({"kind": "item", "display_name": "Dark Hood", "raw": _item("dark_hood")})
	_check("tip.hood-shrouded", hood_tip.contains("While worn: Shrouded - "), hood_tip)
	var pack_tip: String = ItemTooltip.detail_text({"kind": "item", "display_name": "Leather Backpack", "raw": _item("leather_backpack")}, "trade")
	_check("tip.pack-slots", pack_tip.begins_with("Leather Backpack (") and pack_tip.contains("While worn: +10 inventory slots"), pack_tip)
	var crown_tip: String = ItemTooltip.detail_text({"kind": "item", "display_name": "Golden Crown Helm", "raw": _item("golden_crown_helm")}, "chest")
	_check("tip.crown", crown_tip.contains("While worn: Inspired") and crown_tip.contains("While worn: glows"), crown_tip)
	var sword := _weapon("flaming_sword")
	var sword_tip: String = ItemTooltip.detail_text({"kind": "weapon", "display_name": "Flaming Sword", "raw": sword})
	_check("tip.sword-glows", sword_tip.contains("While held: glows (light radius 4.0 tiles)"), sword_tip)
	sword.queue_free()
	var pen_tip: String = ItemTooltip.detail_text({"kind": "weapon", "display_name": "The Pensword", "raw": _item("pensword")}, "chest")
	_check("tip.pensword-drawn-condition", pen_tip.contains("While held: Dripping Ink"), pen_tip)
	var potion := {"kind": "item", "display_name": "Potion", "raw": {"id": "potion", "cost": 12}}
	_check("tip.plain-item-no-lines", ItemTooltip.effect_lines(potion).is_empty())
	# A consumable's adds_condition_on_equip is not a worn effect.
	_check("tip.not-worn-no-lines", EquipmentEffects.worn_lines({"id": "x", "adds_condition_on_equip": "hasted"}).is_empty())
	_check("tip.describe-worn", EquipmentEffects.describe_worn(_item("dark_hood")) == PackedStringArray(["Shrouded"])
		and EquipmentEffects.describe_worn(_item("leather_backpack")) == PackedStringArray(["+10 inventory slots"]))
