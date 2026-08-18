extends Node2D
# Unique-items pipeline probe: data integrity (items -> abilities -> conditions
# -> fluids), WeaponShape field round-trip, while-drawn equip conditions,
# illuminated-blocks-invisible immunity, metallacized slow, will-save arm,
# real disarm. Headless-safe.
#   godot --headless --path . res://tests/unique_items_check.tscn
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

var fails := 0
var checks := 0


func _check(name: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if not ok:
		fails += 1
	print("%s %s %s" % ["PASS" if ok else "FAIL", name, detail])


func _spawn(pos: Vector2) -> ProceduralCharacter:
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	c.position = pos
	add_child(c)
	RaceDatabase.apply_race_to_character(c, "human", {"gender": "male"})
	c.rebuild_visuals()
	return c


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	await get_tree().process_frame

	# --- 1. data chain: every unique item resolves, and its hooks resolve ---
	var expect := {
		"match_striker": {"on_hit": "match_strike"},
		"pensword": {"on_hit": "pensword_blot", "equip_cond": "inking"},
		"heartbreaker": {"on_hit": "heartbreak"},
		"ghost_buster_sword": {"vs_trait": "spectral"},
		"winters_grip": {"equip_cond": "winters_grip"},
		"chrome_smoker": {"on_hit": "chrome_smoke"},
		"prod_of_justice": {"on_hit": "prod_jolt"},
	}
	for iid in expect:
		var data: Dictionary = ItemDatabase.get_item_data(iid)
		_check("data.item.%s" % iid, not data.is_empty())
		if data.is_empty():
			continue
		var spec: Dictionary = expect[iid]
		if spec.has("on_hit"):
			_check("data.%s.on_hit_ability" % iid, str(data.get("on_hit_ability")) == spec["on_hit"])
			var ab: Dictionary = AbilityDatabase.get_ability_data(spec["on_hit"])
			_check("data.ability.%s" % spec["on_hit"], not ab.is_empty())
			for eff in ab.get("effects", []):
				if eff.get("type") == "apply_condition":
					var cid: String = str(eff.get("condition_id"))
					_check("data.condition.%s" % cid,
						ConditionManager.condition_registry.has(cid))
		if spec.has("equip_cond"):
			_check("data.%s.equip_cond" % iid,
				ConditionManager.condition_registry.has(str(data.get("adds_condition_on_equip"))))
		if spec.has("vs_trait"):
			var vs = data.get("damage_vs_trait")
			_check("data.%s.damage_vs_trait" % iid,
				vs is Dictionary and float(vs.get(spec["vs_trait"], 0.0)) == 2.0)

	# --- 2. WeaponShape round-trips the new fields ---
	var a := _spawn(Vector2(200, 200))
	var b := _spawn(Vector2(300, 200))
	await get_tree().process_frame
	a.inventory.equip_weapon_from_data(ItemDatabase.get_item_data("match_striker"))
	var held = a.current_main_hand_item
	_check("shape.on_hit_ability", held != null and held.on_hit_ability == "match_strike")
	_check("shape.to_data", held != null and held.to_data().get("on_hit_ability") == "match_strike")

	# --- 3. while-drawn conditions: pensword drips only while in hand ---
	# (empty the Main hand first: equip_item auto-routes to the OFF hand when
	# Main is occupied, and holster_weapon only stows Main)
	a.holster_weapon()
	await get_tree().process_frame
	a.inventory.equip_weapon_from_data(ItemDatabase.get_item_data("pensword"))
	await get_tree().process_frame
	_check("drawn.inking.applied", a.condition_manager.has_active_condition("inking"))
	a.holster_weapon()
	await get_tree().process_frame
	_check("drawn.inking.stripped", not a.condition_manager.has_active_condition("inking"))

	# --- 3b. winter's grip: drawn applies, stow strips grip AND bite ---
	a.inventory.equip_weapon_from_data(ItemDatabase.get_item_data("winters_grip"))
	await get_tree().process_frame
	_check("drawn.winters_grip.applied", a.condition_manager.has_active_condition("winters_grip"))
	# delay_first: the 18s frostbite trigger must NOT fire on the first frames
	# (the -INF trigger seed used to fire every triggered effect immediately)
	await get_tree().process_frame
	await get_tree().process_frame
	_check("drawn.no-instant-bite",
		not a.condition_manager.has_active_condition("winters_grip_bite"))
	# simulate the 18s trigger having fired
	a.condition_manager.apply_condition("winters_grip_bite", a, 1, -1.0)
	a.holster_weapon()
	await get_tree().process_frame
	_check("drawn.winters_grip.stripped",
		not a.condition_manager.has_active_condition("winters_grip")
		and not a.condition_manager.has_active_condition("winters_grip_bite"))

	# --- 4. illuminated blocks invisible (condition immunity) ---
	_check("inv.applies-clean", b.condition_manager.apply_condition("invisible", null, 1) != null)
	b.condition_manager.remove_condition("invisible")
	b.condition_manager.apply_condition("illuminated", null, 1)
	_check("inv.blocked-when-illuminated",
		b.condition_manager.apply_condition("invisible", null, 1) == null)
	b.condition_manager.remove_condition("illuminated")

	# --- 4b. illuminated EVICTS a pre-existing invisible (order-independent) ---
	b.condition_manager.apply_condition("invisible", null, 1)
	b.condition_manager.apply_condition("illuminated", null, 1)
	_check("inv.evicted-by-illuminated",
		not b.condition_manager.has_active_condition("invisible"))
	b.condition_manager.remove_condition("illuminated")

	# --- 4c. a permanent equip-granted instance survives default re-applies ---
	b.condition_manager.apply_condition("invisible", null, 1, -1.0)
	b.condition_manager.apply_condition("invisible", null, 1)
	var inv_inst = b.condition_manager.get_condition("invisible")
	_check("inv.permanent-not-clobbered", inv_inst != null and inv_inst.expires_at < 0,
		str(inv_inst.expires_at) if inv_inst else "gone")
	b.condition_manager.remove_condition("invisible")

	# --- 5. metallacized slows, scaling with whatever stacks survived the
	# built-in STR apply-save: speed -0.08/stack, dex -4/stack ---
	var base_dex: int = b.dexterity
	b.condition_manager.apply_condition("metallacized", null, 3)
	await get_tree().process_frame
	var inst = b.condition_manager.get_condition("metallacized")
	_check("metal.applied", inst != null and inst.stacks >= 1,
		"stacks=%s" % (str(inst.stacks) if inst else "none"))
	if inst:
		var s: int = inst.stacks
		_check("metal.speed", absf(b.speed_modifier - (-0.08 * s)) < 0.001,
			"%d stacks -> %s" % [s, str(b.speed_modifier)])
		_check("metal.dex", b.effective_dexterity() == base_dex - 4 * s,
			"%d stacks: %d -> %d" % [s, base_dex, b.effective_dexterity()])
	b.condition_manager.remove_condition("metallacized")

	# --- 6. will-save arm reads the real stat ---
	b.will = 77
	_check("save.will-arm", b.get_stat_by_name("will") == 77)

	# --- 7. real disarm: weapon leaves the hand entirely ---
	b.inventory.equip_weapon_from_data(ItemDatabase.get_item_data("prod_of_justice"))
	await get_tree().process_frame
	_check("disarm.armed", b.current_main_hand_item != null)
	var res: Dictionary = AbilityEffect.resolve_effect(
		{"type": "disarm"}, a, [b], null, b.global_position)
	await get_tree().process_frame
	_check("disarm.dropped", b.current_main_hand_item == null, str(res))

	# --- 8. ink fluid type is registered and depositable ---
	var fm := FluidManager.new()
	add_child(fm)
	await get_tree().process_frame
	fm.register_fluid(Vector2i(10, 10), "ink", 0.5)
	_check("fluid.ink", fm.get_fluid_amount(Vector2i(10, 10), "ink") > 0.0)

	print("unique_items_check: %d checks, %d FAIL" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)
