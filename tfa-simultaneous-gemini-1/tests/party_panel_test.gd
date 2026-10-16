# res://tests/party_panel_test.gd
# Headless assertion harness for the party panel and the item windows around
# it (party-ui port lane):
#   1. Drag and drop really reaches the windows: real mouse input drags an item
#      between party members, into and out of a trade window, a chest and a
#      town-service card (the slots are MOUSE_FILTER_STOP, so without drag
#      forwarding Godot never called the windows' drag methods).
#   2. Transfers never eat an item: a full receiver refuses, a service
#      withdrawal says what is missing, worn flags stay with the NPC.
#   3. One trade at a time, and item moves that a trade's Cancel would undo
#      are refused while one is open.
#   4. Item menus offer only what works; Use/Consume/Throw are planned while
#      paused, keep the item when nothing happens, and a planned weapon throw
#      leaves the weapon carried until it runs.
#   5. Consumables (ActionQueue.apply_consumable): a Potion of Healing heals
#      once, cures poison and starts no cast; a dead recipient is refused.
#   6. Slot, bar, pip and condition tooltips and labels; ability slots grey
#      out when unaffordable; a school gained mid-run gets its pip row.
#   7. The downtime portrait strip: dead tint, refusal and tooltip.
#   8. The throw aim line is clamped to ProceduralCharacter.THROW_RANGE.
# Run:  godot --headless --path . res://tests/party_panel_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

const ItemTooltip = preload("res://UI/ItemTooltip.gd")
const ChestWindowScene = preload("res://UI/ChestInventoryWindow.tscn")

var failures := 0
var game = null
var psp = null

func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])

func _await_frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

func _ready() -> void:
	TimeManager.pause_time()
	# Headless windows are 64x64, which collapses the anchored HUD into the
	# corner; give the root the project's real size so the drags have room.
	get_tree().root.size = Vector2i(1900, 1080)
	await get_tree().process_frame
	var GameScene := load("res://game.tscn")
	game = GameScene.instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _await_frames(2)
	game.load_map("town_square")
	await _await_frames(10)
	psp = game.get_node("GameUI/PartySidePanel")
	if OS.get_environment("PP_DEBUG") != "":
		print("DEBUG viewport ", get_viewport().get_visible_rect(), " win ", get_tree().root.size, " ds ", DisplayServer.window_get_size(), " psp ", psp.get_global_rect())
	_check("setup.two-party-members", game.party_chars.size() >= 2, str(game.party_chars.size()))
	if game.party_chars.size() < 2:
		print("HARNESS DONE failures=%d" % failures)
		get_tree().quit(1)
		return
	# Nothing in the world should move under the test's feet.
	for c in game.party_chars:
		c.AI_enabled = false

	_case_tooltips()
	await _case_hud()
	await _case_conditions()
	await _case_resource_schools()
	_case_menu_options()
	_case_consume()
	await _case_use()
	_case_planned_weapon_throw()
	_case_throw_range()
	_case_transfers()
	await _case_drag_party_to_party()
	await _case_drag_trade()
	await _case_trade_lock()
	await _case_drag_chest()
	await _case_drag_service()
	await _case_portraits()

	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _panel(c) -> Dictionary:
	for pd in psp._character_panels:
		if pd["character"] == c:
			return pd
	return {}

func _item(id: String, stacks: int = 1) -> Dictionary:
	var d: Dictionary = game._lookup_any_item(id).duplicate(true)
	d["num_stacks"] = stacks
	return d

func _index_of(inv, id: String) -> int:
	for i in range(inv.items.size()):
		if str(inv.items[i].get("id", "")) == id:
			return i
	return -1

func _count(inv, id: String) -> int:
	var n := 0
	for it in inv.items:
		if str(it.get("id", "")) == id:
			var ns = it.get("num_stacks", 1)
			n += int(ns) if ns != null else 1
	return n

func _entry_for(inv, id: String) -> Dictionary:
	for e in psp._build_inventory_entries(inv):
		if e.get("kind", "") == "item" and str(e["raw"].get("id", "")) == id:
			return e
	return {}

func _slot_for(c, id: String):
	var pd := _panel(c)
	for s in pd["inv_grid"].get_children():
		if s.is_queued_for_deletion() or not s.has_meta("entry"):
			continue
		var e: Dictionary = s.get_meta("entry")
		var raw = e.get("raw")
		if raw is Dictionary and str(raw.get("id", "")) == id:
			return s
	return null

func _center(ctrl: Control) -> Vector2:
	return ctrl.get_global_transform_with_canvas() * (ctrl.size * 0.5)

func _last_log() -> String:
	var entries = GameLog.get_entries()
	return str(entries[-1].text) if not entries.is_empty() else ""

func _log_has(text: String, from: int) -> bool:
	var entries = GameLog.get_entries()
	for i in range(max(0, from), entries.size()):
		if str(entries[i].text).contains(text):
			return true
	return false

func _mock(src: String) -> Node:
	var s := GDScript.new()
	s.source_code = src
	s.reload()
	var n := Node.new()
	n.set_script(s)
	add_child(n)
	return n

# A real mouse drag: press, move in steps past Godot's drag threshold, release.
func _mouse_drag(from: Vector2, to: Vector2) -> void:
	var m0 := InputEventMouseMotion.new()
	m0.position = from
	m0.global_position = from
	Input.parse_input_event(m0)
	Input.flush_buffered_events()
	await get_tree().process_frame
	var pr := InputEventMouseButton.new()
	pr.button_index = MOUSE_BUTTON_LEFT
	pr.pressed = true
	pr.position = from
	pr.global_position = from
	pr.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(pr)
	Input.flush_buffered_events()
	await get_tree().process_frame
	for i in range(12):
		var m := InputEventMouseMotion.new()
		m.position = from.lerp(to, (i + 1) / 12.0)
		m.global_position = m.position
		m.relative = (to - from) / 12.0
		m.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(m)
		Input.flush_buffered_events()
		await get_tree().process_frame
	if OS.get_environment("PP_DEBUG") != "":
		var hov = get_viewport().gui_get_hovered_control()
		print("DEBUG drag from ", from, " to ", to, " dragging=", get_viewport().gui_is_dragging(), " hovered=", hov, " ", hov.get_path() if hov else "")
	var rl := InputEventMouseButton.new()
	rl.button_index = MOUSE_BUTTON_LEFT
	rl.pressed = false
	rl.position = to
	rl.global_position = to
	Input.parse_input_event(rl)
	Input.flush_buffered_events()
	await _await_frames(2)

func _in_view(p: Vector2) -> bool:
	return get_viewport().get_visible_rect().has_point(p)

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

func _case_tooltips() -> void:
	var a = game.party_chars[0]
	# Items: "(N gold)" priced like the trade window (stack total), then the description.
	var potion := _item("potion_of_healing", 2)
	var t: String = ItemTooltip.detail_text({"kind": "item", "display_name": "Potion of Healing", "num_stacks": 2, "raw": potion})
	var want_gold := "(%.0f gold)" % (float(potion.get("cost", 0.0)) * 2.0)
	_check("tooltip.item-value", t.begins_with("Potion of Healing " + want_gold), t)
	var desc = potion.get("description")
	if desc != null and str(desc) != "":
		_check("tooltip.item-description", t.contains(str(desc)), t)
	# Stolen goods name their owner.
	var fid: String = str(FactionDatabase.get_all_faction_ids()[0])
	var stolen := _item("apple")
	stolen["stolen_from"] = fid
	var st: String = ItemTooltip.detail_text({"kind": "item", "display_name": "Apple", "raw": stolen})
	_check("tooltip.stolen-from", st.contains("Stolen from " + str(FactionDatabase.get_faction_data(fid).get("name", fid))), st)
	# Chest context stays the bare name.
	_check("tooltip.chest-unchanged", ItemTooltip.detail_text({"kind": "item", "display_name": "Apple", "raw": stolen}, "chest") == "Apple")
	# Weapons show base damage.
	var w = WeaponShape.new()
	w.damage = {"slashing": 10}
	w.cost = 15.0
	var wt: String = ItemTooltip.detail_text({"kind": "weapon", "display_name": "Sword", "raw": w})
	_check("tooltip.weapon-damage", wt.begins_with("Sword (15 gold)") and wt.contains("Base damage: 10 slashing"), wt)
	w.free()
	# Abilities: cost from the school traits, cast time, range; no price.
	var shape = AbilityShape.new()
	shape.raw_data = AbilityDatabase.get_ability_data("fireball")
	shape.ability_id = "fireball"
	shape.display_name = "Fireball"
	var ab_entry := {"kind": "ability", "display_name": "Fireball", "raw": shape}
	psp._set_ability_costs(ab_entry, a)
	var want_costs: Dictionary = AbilityManager.school_costs_for(Ability.from_dict(shape.raw_data))
	_check("ability.costs-on-entry", ab_entry["costs"] == want_costs, str(ab_entry["costs"]))
	var at: String = ItemTooltip.detail_text(ab_entry)
	var parts: PackedStringArray = []
	for res in want_costs:
		parts.append("%d %s" % [int(want_costs[res]), String(res).capitalize()])
	_check("ability.tooltip-cost", at.contains("Cost: " + ", ".join(parts)), at)
	_check("ability.tooltip-cast-range", at.contains("Cast: 1.0s") and at.contains("Range: 400"), at)
	_check("ability.no-price", not at.contains("gold"), at)
	# A racial ability costs nothing and says so.
	var am_mock := _mock("extends Node\nfunc _is_innate_ability(_a):\n\treturn true\n")
	var racial := _mock("extends Node\nvar ability_manager\nvar npc_unlimited_resources := false\n")
	racial.ability_manager = am_mock
	var innate_entry := {"kind": "ability", "display_name": "Fireball", "raw": shape}
	psp._set_ability_costs(innate_entry, racial)
	_check("ability.innate-free", innate_entry["costs"].is_empty() and ItemTooltip.detail_text(innate_entry).contains("Cost: none (innate)"),
		ItemTooltip.detail_text(innate_entry))
	shape.free()
	# Greying: unaffordable slots dim, affordable ones stay lit.
	var dim := Control.new()
	var lit := Control.new()
	add_child(dim)
	add_child(lit)
	psp._update_ability_slots({"ability_slots": [{"slot": dim, "costs": {"focus": 999}}, {"slot": lit, "costs": {"focus": 0}}]}, a)
	_check("ability.unaffordable-grey", dim.modulate == Color(0.55, 0.55, 0.55), str(dim.modulate))
	_check("ability.affordable-lit", lit.modulate == Color.WHITE, str(lit.modulate))
	dim.queue_free()
	lit.queue_free()
	racial.queue_free()
	am_mock.queue_free()

func _case_hud() -> void:
	var a = game.party_chars[0]
	await _await_frames(2)
	var pd := _panel(a)
	_check("hud.hp-label", pd["hp_label"].text == "HP %d/%d" % [a.current_health, a.max_health], pd["hp_label"].text)
	_check("hud.hp-bar-pass", pd["health_bar"].mouse_filter == Control.MOUSE_FILTER_PASS)
	_check("hud.hp-row-holds-label", pd["hp_label"].get_parent() == pd["hp_row"])
	_check("hud.name-ellipsis", pd["name_label"].text_overrun_behavior == TextServer.OVERRUN_TRIM_ELLIPSIS)
	var cap: int = int(a.max_stress)
	_check("hud.stress-label", pd["stress_label"].text == "Stress %d/%d" % [int(a.stress), cap], pd["stress_label"].text)
	_check("hud.stress-tooltip", str(pd["stress_bar"].tooltip_text).contains("breakdown"), pd["stress_bar"].tooltip_text)
	var old_stress: int = a.stress
	a.stress = int(ceil(cap * ProceduralCharacter.STRESS_DANGER_RATIO))
	await _await_frames(1)
	_check("hud.stress-danger-colour", pd["stress_fill"].bg_color == psp.STRESS_DANGER_COLOR, str(pd["stress_fill"].bg_color))
	a.stress = old_stress
	await _await_frames(1)
	_check("hud.stress-colour-back", pd["stress_fill"].bg_color == psp.STRESS_COLOR)
	_check("hud.inventory-count", pd["inv_label"].text == "Inventory %d/%d" % [a.inventory.slots_used(), a.inventory.max_slots], pd["inv_label"].text)

func _case_conditions() -> void:
	var a = game.party_chars[0]
	var cm = a.condition_manager
	var pd := _panel(a)
	cm.register_condition(Condition.create_from_data({"id": "pp_test_cond", "display_name": "Testing",
		"description": "Does testing things.", "duration": 60.0, "traits": {}}))
	var inst = cm.apply_condition("pp_test_cond")
	await _await_frames(2)
	var tip := ""
	for icon in pd["condition_container"].get_children():
		if str(icon.get_meta("cond_id", "")) == "pp_test_cond":
			tip = str(icon.tooltip_text)
	_check("conditions.description", tip.contains("Testing") and tip.contains("\nDoes testing things."), tip)
	inst.is_suppressed = true
	await _await_frames(1)
	for icon in pd["condition_container"].get_children():
		if str(icon.get_meta("cond_id", "")) == "pp_test_cond":
			tip = str(icon.tooltip_text)
	_check("conditions.suppressed", tip.contains("(suppressed)"), tip)
	# More than MAX_COND_PIPS: the "+N" tag names the hidden ones.
	var extra: Array = []
	for i in range(psp.MAX_COND_PIPS + 1):
		var cid := "pp_extra_%d" % i
		cm.register_condition(Condition.create_from_data({"id": cid, "display_name": "Extra %d" % i, "duration": 60.0, "traits": {}}))
		cm.apply_condition(cid)
		extra.append(cid)
	await _await_frames(2)
	var tag_tip := ""
	for child in pd["condition_container"].get_children():
		if str(child.get_meta("cond_id", "")) == "__overflow__":
			tag_tip = str(child.tooltip_text)
	_check("conditions.overflow-lists-hidden", tag_tip.begins_with("Also: ") and tag_tip.contains("Extra"), tag_tip)
	# One more past the shown pips: no rebuild, but the "+N" count follows.
	cm.register_condition(Condition.create_from_data({"id": "pp_extra_more", "display_name": "Extra more", "duration": 60.0, "traits": {}}))
	cm.apply_condition("pp_extra_more")
	extra.append("pp_extra_more")
	await _await_frames(2)
	var tag_text := ""
	for child in pd["condition_container"].get_children():
		if str(child.get_meta("cond_id", "")) == "__overflow__" and not child.is_queued_for_deletion():
			tag_text = str(child.text)
	var want_more := "+%d" % (cm.conditions.size() - psp.MAX_COND_PIPS)
	_check("conditions.overflow-count-follows", tag_text == want_more, "%s vs %s" % [tag_text, want_more])
	cm.remove_condition("pp_test_cond")
	for cid in extra:
		cm.remove_condition(cid)
	await _await_frames(1)

func _has_row(pd: Dictionary, school: String) -> bool:
	for bar in pd["resource_bars"]:
		if bar["school"] == school:
			return true
	return false

func _case_resource_schools() -> void:
	# A school gained or lost mid-run gets (or loses) its pip row at once.
	var a = game.party_chars[0]
	var pd := _panel(a)
	var school := ""
	for entry in psp.SCHOOL_RESOURCES:
		if int(a.traits.get(entry["school"], 0)) > 0:
			school = entry["school"]
			break
	if school == "":
		school = psp.SCHOOL_RESOURCES[0]["school"]
	var had = a.traits.get(school, null)
	a.traits.erase(school)
	await _await_frames(2)
	_check("schools.lost-row-goes", not _has_row(pd, school) and not school in pd["resource_schools"], str(pd["resource_schools"]))
	a.traits[school] = had if had != null and int(had) > 0 else 1
	await _await_frames(2)
	_check("schools.gained-row-comes", _has_row(pd, school) and school in pd["resource_schools"], str(pd["resource_schools"]))
	if had == null:
		a.traits.erase(school)
	else:
		a.traits[school] = had
	await _await_frames(2)
	# Pip tooltips explain how the pool fills.
	for bar in pd["resource_bars"]:
		if not bar["pips"].is_empty():
			var ptip: String = str(bar["pips"][0].tooltip_text)
			_check("schools.pip-rule %s" % bar["resource"], ptip.contains("\n"), ptip)

func _menu_for(c, raw: Dictionary) -> Array:
	var slot := PanelContainer.new()
	psp.add_child(slot)
	slot.set_meta("entry", {"kind": "item", "display_name": str(raw.get("display_name", "?")), "raw": raw,
		"num_stacks": int(raw.get("num_stacks", 1)) if raw.get("num_stacks") != null else 1, "source_index": 0})
	slot.set_meta("panel_data", _panel(c))
	var before: Array = psp.get_children()
	psp._show_item_context_menu(slot)
	var texts: Array = []
	for child in psp.get_children():
		if child is PopupMenu and not child in before:
			for i in range(child.item_count):
				texts.append(child.get_item_text(i))
			child.hide()
			child.queue_free()
	slot.queue_free()
	game.context_menu_open = false
	return texts

func _case_menu_options() -> void:
	var a = game.party_chars[0]
	_check("menu.arrows-no-use", _menu_for(a, _item("arrow", 5)) == ["Drop", "Drop All", "Split"], str(_menu_for(a, _item("arrow", 5))))
	_check("menu.key-no-inspect", _menu_for(a, _item("iron_key")) == ["Drop"], str(_menu_for(a, _item("iron_key"))))
	_check("menu.backpack-equip-once-no-open", _menu_for(a, _item("leather_backpack")) == ["Equip", "Drop"], str(_menu_for(a, _item("leather_backpack"))))
	var worn := _item("leather_backpack")
	worn["_equipped"] = true
	_check("menu.worn-unequip", _menu_for(a, worn) == ["Unequip", "Drop"], str(_menu_for(a, worn)))
	_check("menu.potion", _menu_for(a, _item("potion_of_healing")) == ["Consume", "Throw", "Drop"], str(_menu_for(a, _item("potion_of_healing"))))
	var pauldrons := {"id": "test_pauldrons", "display_name": "Pauldrons", "equip_slot": "Shoulders", "interact_options": ["Drop", "Equip"]}
	_check("menu.unwearable-no-equip", _menu_for(a, pauldrons) == ["Drop"], str(_menu_for(a, pauldrons)))
	var soul := {"id": "soul_x", "display_name": "Soul of X", "interact_options": ["Offer to Patron", "Drop"]}
	_check("menu.soul-no-dead-option", _menu_for(a, soul) == ["Drop"], str(_menu_for(a, soul)))
	var usable := {"id": "test_usable", "display_name": "Wand", "use_ability": "fireball"}
	_check("menu.use-only-with-ability", _menu_for(a, usable) == ["Use", "Drop"], str(_menu_for(a, usable)))
	var n0: int = GameLog.get_entries().size()
	psp._equip_item(a, 0, pauldrons)
	_check("menu.cant-wear-said", _log_has("can't wear the Pauldrons", n0))

func _case_consume() -> void:
	var a = game.party_chars[0]
	game.primary_selected = a
	# Potion: one +25 heal, no Heal cast, one log line, the potion is used.
	a.current_health = max(1, a.max_health - 40)
	var hp0: int = a.current_health
	a.inventory.add_item(_item("potion_of_healing"))
	var idx := _index_of(a.inventory, "potion_of_healing")
	var potion: Dictionary = a.inventory.items[idx]
	var count0 := _count(a.inventory, "potion_of_healing")
	var n0: int = GameLog.get_entries().size()
	psp._consume_item(a, idx, potion)
	_check("consume.potion-heals-once", a.current_health == min(a.max_health, hp0 + 25), "%d -> %d" % [hp0, a.current_health])
	_check("consume.potion-no-cast", not a.ability_manager.is_casting())
	_check("consume.potion-used", _count(a.inventory, "potion_of_healing") == count0 - 1)
	_check("consume.logged", _log_has("consumes the Potion of Healing", n0))
	# The potion also cures poison (inv-6), still without a Holy cast.
	a.current_health = max(1, a.max_health - 40)
	a.condition_manager.apply_condition("poisoned", null, 1, 30.0)
	a.inventory.add_item(_item("potion_of_healing"))
	idx = _index_of(a.inventory, "potion_of_healing")
	n0 = GameLog.get_entries().size()
	psp._consume_item(a, idx, a.inventory.items[idx])
	_check("consume.potion-cures-poison", not a.condition_manager.conditions.has("poisoned") and _log_has("ends Poisoned", n0), str(a.condition_manager.conditions.keys()))
	_check("consume.potion-cure-no-cast", not a.ability_manager.is_casting())
	# A dead recipient is refused and the item kept.
	a.inventory.add_item(_item("apple"))
	idx = _index_of(a.inventory, "apple")
	var apple: Dictionary = a.inventory.items[idx]
	var apples0 := _count(a.inventory, "apple")
	var corpse := _mock("extends Node\nvar Name := 'Corpse'\nfunc is_alive():\n\treturn false\n")
	n0 = GameLog.get_entries().size()
	psp._execute_consume(a, corpse, idx, apple)
	_check("consume.dead-recipient-refused", _count(a.inventory, "apple") == apples0 and _log_has("they are dead", n0))
	corpse.queue_free()
	# Nothing to apply: the item is kept, with a reason.
	var dud := {"id": "test_dud", "display_name": "Dud Vial", "use_ability": "no_such_ability_xyz"}
	a.inventory.add_item(dud)
	n0 = GameLog.get_entries().size()
	_check("consume.nothing-happens-keeps", not ActionQueue.apply_consumable(a, a, dud) and _log_has("does nothing on its own", n0))
	a.inventory.remove_item(_index_of(a.inventory, "test_dud"))
	# Paused: planned, with the recipient fixed at the click.
	PauseManager.pause()
	var q0: int = a.action_queue.get_queue_size()
	idx = _index_of(a.inventory, "apple")
	psp._consume_item(a, idx, a.inventory.items[idx])
	_check("consume.paused-planned", a.action_queue.get_queue_size() == q0 + 1 and _count(a.inventory, "apple") == apples0)
	var planned: Callable = a.action_queue.get_queue()[-1].data.get("callable")
	_check("consume.recipient-bound", planned.is_valid() and planned.get_bound_arguments().size() >= 2 and planned.get_bound_arguments()[1] == a)
	a.action_queue.clear_queue()
	PauseManager.unpause()

func _case_use() -> void:
	var a = game.party_chars[0]
	# notify() drops an identical notice inside a second, log line included.
	await get_tree().create_timer(1.1).timeout
	var trinket := {"id": "test_trinket", "display_name": "Trinket"}
	a.inventory.add_item(trinket)
	var idx := _index_of(a.inventory, "test_trinket")
	var n0: int = GameLog.get_entries().size()
	psp._use_item(a, idx, trinket)
	_check("use.nothing-happens-keeps", _index_of(a.inventory, "test_trinket") >= 0 and _log_has("does nothing on its own", n0))
	PauseManager.pause()
	var q0: int = a.action_queue.get_queue_size()
	psp._use_item(a, idx, trinket)
	_check("use.paused-planned", a.action_queue.get_queue_size() == q0 + 1)
	a.action_queue.clear_queue()
	PauseManager.unpause()
	# A planned use whose item has gone says so.
	a.inventory.remove_item(_index_of(a.inventory, "test_trinket"))
	n0 = GameLog.get_entries().size()
	psp._execute_use(a, idx, trinket)
	_check("use.item-gone", _log_has("no longer in the inventory", n0))

func _case_planned_weapon_throw() -> void:
	var a = game.party_chars[0]
	var data: Dictionary = game._lookup_any_item("dagger").duplicate(true)
	var node = a.inventory.stow_weapon_from_data(data)
	_check("throw.setup", node != null and node in a.inventory.stowed_items)
	var entry: Dictionary = psp._make_weapon_entry(node, "", false)
	PauseManager.pause()
	var q0: int = a.action_queue.get_queue_size()
	psp._throw_weapon(a, entry)
	_check("throw.planned", a.action_queue.get_queue_size() == q0 + 1)
	_check("throw.weapon-still-carried", is_instance_valid(node) and node in a.inventory.stowed_items)
	a.action_queue.clear_queue()
	_check("throw.cancel-keeps-weapon", is_instance_valid(node) and node in a.inventory.stowed_items)
	PauseManager.unpause()
	var wdata: Dictionary = node.to_data()
	psp._execute_throw(a, -1, wdata, node)
	_check("throw.runs-removes-weapon", not (node in a.inventory.stowed_items))
	var n0: int = GameLog.get_entries().size()
	psp._execute_throw(a, -1, wdata, node)
	_check("throw.gone-said", _log_has("no longer carried", n0))

func _case_throw_range() -> void:
	var a = game.party_chars[0]
	_check("throw.range-const", is_equal_approx(ProceduralCharacter.THROW_RANGE, 400.0))
	a.start_throw_targeting(-1, {"id": "rock"})
	a._update_throw_reticle(a.global_position + Vector2(5000, 0))
	var reach: float = a._aim_line._to.distance_to(a.global_position)
	_check("throw.aim-clamped", reach <= ProceduralCharacter.THROW_RANGE + 0.5, str(reach))
	a._cancel_pending_throw()

func _case_transfers() -> void:
	var a = game.party_chars[0]
	var b = game.party_chars[1]
	# Full receiver: the giver keeps the item, the receiver says why.
	a.inventory.add_item(_item("iron_key"))
	var key_entry := _entry_for(a.inventory, "iron_key")
	var b_max: int = b.inventory.max_slots
	# max_slots sets the base; worn packs add bonus_slots on top. Hidden
	# hand-weapon dicts take no slot (slots_used).
	b.inventory.max_slots = b.inventory.slots_used() - b.inventory.bonus_slots
	var bpos: Vector2 = psp.get_global_transform().affine_inverse() * _panel(b)["container"].get_global_rect().get_center()
	var n0: int = GameLog.get_entries().size()
	var keys_a0 := _count(a.inventory, "iron_key")
	psp._drop_data(bpos, {"source_character": a, "entry": key_entry})
	_check("transfer.full-receiver-keeps-item", _count(a.inventory, "iron_key") == keys_a0 and _count(b.inventory, "iron_key") == 0)
	_check("transfer.full-receiver-said", _log_has("can't carry", n0))
	b.inventory.max_slots = b_max
	# Room: one unit moves as its own dict.
	psp._drop_data(bpos, {"source_character": a, "entry": _entry_for(a.inventory, "iron_key")})
	_check("transfer.moves", _count(a.inventory, "iron_key") == keys_a0 - 1 and _count(b.inventory, "iron_key") == 1)
	# Portrait drags (no entry) aren't item drops.
	_check("transfer.portrait-rejected", not psp._can_drop_data(bpos, {"kind": "portrait", "source_character": a}))

	# Away service NPC (snapshot): the NPC's worn flag stays behind.
	var stub_src := "extends Node\nvar credit := 0.0\nvar accept := true\nvar item := {}\n" \
		+ "func remove_snapshot_item(_u, _r, _i):\n\treturn item.duplicate(true)\n" \
		+ "func can_accept_value_loss(_u, _v):\n\treturn accept\n" \
		+ "func get_credit(_u):\n\treturn credit\n"
	var stub := _mock(stub_src)
	var cap := _item("leather_backpack")
	cap["_equipped"] = true
	stub.item = cap
	var snap_data := {"source_npc": null, "snapshot_uid": "u1", "snapshot_region": "r1", "source_window": stub,
		"entry": {"kind": "item", "display_name": "Leather Backpack", "num_stacks": 1, "source_index": 0, "raw": cap}}
	var packs0 := _count(b.inventory, "leather_backpack")
	psp._drop_data(bpos, snap_data)
	var got := _index_of(b.inventory, "leather_backpack")
	_check("service.snapshot-take-arrives", _count(b.inventory, "leather_backpack") == packs0 + 1)
	_check("service.snapshot-take-not-worn", got >= 0 and not b.inventory.items[got].get("_equipped", false))
	# Not enough credit: refused, and the log says how much more to give.
	stub.accept = false
	stub.credit = 2.0
	n0 = GameLog.get_entries().size()
	psp._drop_data(bpos, snap_data)
	_check("service.refusal-says-shortfall", _count(b.inventory, "leather_backpack") == packs0 + 1 and _log_has("gold more in goods", n0), _last_log())
	stub.queue_free()

func _case_drag_party_to_party() -> void:
	var a = game.party_chars[0]
	var b = game.party_chars[1]
	if not psp.panel_visible:
		psp._toggle_panel()
	await _await_frames(25)
	a.inventory.add_item(_item("apple"))
	await _await_frames(2)
	var slot = _slot_for(a, "apple")
	var target: Control = _panel(b)["name_label"].get_parent()
	_check("drag.setup", slot != null and _in_view(_center(slot)) and _in_view(_center(target)),
		"slot %s target %s" % [_center(slot) if slot else Vector2.ZERO, _center(target)])
	if slot == null:
		return
	var a0 := _count(a.inventory, "apple")
	var b0 := _count(b.inventory, "apple")
	await _mouse_drag(_center(slot), _center(target))
	_check("drag.party-to-party", _count(a.inventory, "apple") == a0 - 1 and _count(b.inventory, "apple") == b0 + 1,
		"a %d->%d b %d->%d" % [a0, _count(a.inventory, "apple"), b0, _count(b.inventory, "apple")])

func _trade_npc():
	for c in game.characters_in_scene:
		if is_instance_valid(c) and not c in game.party_chars and c.is_alive() and c.inventory:
			return c
	return null

func _trade_windows() -> Array:
	return get_tree().get_nodes_in_group("trade_window").filter(func(w): return not w.is_queued_for_deletion())

func _case_drag_trade() -> void:
	var a = game.party_chars[0]
	var npc = _trade_npc()
	_check("trade.setup-npc", npc != null)
	if npc == null:
		return
	a.inventory.add_item(_item("apple"))
	game.show_trade_window(npc)
	await _await_frames(3)
	var windows := _trade_windows()
	_check("trade.window-open", windows.size() == 1)
	if windows.is_empty():
		return
	var tw = windows[0]
	game.show_trade_window(npc)
	await _await_frames(2)
	_check("trade.one-at-a-time", _trade_windows().size() == 1)
	# Party slot -> trade window grid: the NPC receives it.
	var slot = _slot_for(a, "apple")
	var npc0 := _count(npc.inventory, "apple")
	var a0 := _count(a.inventory, "apple")
	var drop_at: Vector2 = _center(tw._grid) if tw._grid.size.y > 4.0 else _center(tw)
	await _mouse_drag(_center(slot), drop_at)
	_check("drag.party-to-trade", _count(npc.inventory, "apple") == npc0 + 1 and _count(a.inventory, "apple") == a0 - 1,
		"npc %d->%d a %d->%d" % [npc0, _count(npc.inventory, "apple"), a0, _count(a.inventory, "apple")])
	# Trade grid slot -> party header: back to the party.
	await _await_frames(2)
	var npc_slot = null
	for s in tw._grid.get_children():
		if s.is_queued_for_deletion() or not s.has_meta("entry"):
			continue
		var raw = s.get_meta("entry").get("raw")
		if raw is Dictionary and str(raw.get("id", "")) == "apple":
			npc_slot = s
	_check("drag.trade-slot-found", npc_slot != null)
	if npc_slot != null:
		var a1 := _count(a.inventory, "apple")
		await _mouse_drag(_center(npc_slot), _center(_panel(a)["name_label"].get_parent()))
		_check("drag.trade-to-party", _count(a.inventory, "apple") == a1 + 1, "%d -> %d" % [a1, _count(a.inventory, "apple")])
	tw._on_cancel_pressed()
	await _await_frames(2)
	_check("trade.cancel-restores", _count(npc.inventory, "apple") == npc0 and _count(a.inventory, "apple") == a0)

func _case_trade_lock() -> void:
	var a = game.party_chars[0]
	var npc = _trade_npc()
	if npc == null:
		return
	game.show_trade_window(npc)
	await _await_frames(3)
	var tw = _trade_windows()[0] if not _trade_windows().is_empty() else null
	_check("lock.window-open", tw != null)
	if tw == null:
		return
	var entry := _entry_for(a.inventory, "apple")
	var a0 := _count(a.inventory, "apple")
	var n0: int = GameLog.get_entries().size()
	psp._on_item_menu_selected(0, a, entry, ["Drop"])
	_check("lock.drop-refused", _count(a.inventory, "apple") == a0 and _log_has("can't drop the Apple while a trade is open", n0), _last_log())
	# Past notify's 1 s repeat drop and GameLog's 1.5 s repeat folding.
	await get_tree().create_timer(1.6).timeout
	n0 = GameLog.get_entries().size()
	psp._on_item_menu_selected(0, a, entry, ["Drop All"])
	_check("lock.drop-all-verb", _log_has("can't drop the Apple while", n0))
	# Taking from a chest would vanish on Cancel: refused too.
	var chest := _mock("extends Node\nvar contents: Array = []\nvar display_name := 'Box'\n")
	var loot := _item("apple")
	chest.contents.append(loot)
	var apos: Vector2 = psp.get_global_transform().affine_inverse() * _panel(a)["container"].get_global_rect().get_center()
	psp._drop_data(apos, {"source_chest": chest, "entry": {"kind": "item", "display_name": "Apple", "raw": loot}})
	_check("lock.chest-take-refused", chest.contents.size() == 1 and _count(a.inventory, "apple") == a0)
	chest.queue_free()
	tw._on_cancel_pressed()
	await _await_frames(2)
	n0 = GameLog.get_entries().size()
	psp._on_item_menu_selected(0, a, _entry_for(a.inventory, "apple"), ["Drop"])
	_check("lock.released-after-close", _count(a.inventory, "apple") == a0 - 1 and not _log_has("while a trade is open", n0))

func _case_drag_chest() -> void:
	var a = game.party_chars[0]
	var b = game.party_chars[1]
	var chest = game.create_item("treasure_chest", a.global_position + Vector2(20, 0))
	_check("chest.setup", chest != null and "contents" in chest)
	if chest == null:
		return
	if chest.contents == null or not (chest.contents is Array):
		chest.contents = []
	chest.contents.append(_item("cabbage", 2))
	var w = ChestWindowScene.instantiate()
	w.chest_item = chest
	game.get_node("GameUI").add_child(w)
	await _await_frames(3)
	# Party slot -> chest slot (STOP, forwarded): the chest receives it.
	a.inventory.add_item(_item("apple"))
	await _await_frames(2)
	var chest_slot = null
	for s in w._grid.get_children():
		if s is PanelContainer and not s.is_queued_for_deletion():
			chest_slot = s
	var a0 := _count(a.inventory, "apple")
	var c0: int = chest.contents.size()
	await _mouse_drag(_center(_slot_for(a, "apple")), _center(chest_slot))
	_check("drag.party-to-chest-slot", chest.contents.size() == c0 + 1 and _count(a.inventory, "apple") == a0 - 1,
		"chest %d->%d" % [c0, chest.contents.size()])
	# Chest slot -> party header: the party member takes the whole stack.
	await _await_frames(2)
	var cab_slot = null
	for s in w._grid.get_children():
		if s is PanelContainer and not s.is_queued_for_deletion() and str(s.get_meta("entry")["raw"].get("id", "")) == "cabbage":
			cab_slot = s
	var b0 := _count(b.inventory, "cabbage")
	await _mouse_drag(_center(cab_slot), _center(_panel(b)["name_label"].get_parent()))
	_check("drag.chest-to-party", _count(b.inventory, "cabbage") == b0 + 2, "%d -> %d" % [b0, _count(b.inventory, "cabbage")])
	w.queue_free()
	chest.queue_free()
	await _await_frames(1)

func _case_portraits() -> void:
	var cpp = game.get_node("GameUI/CenterPartyPortraits")
	cpp.visible = true
	cpp._rebuild_portraits()
	var corpse := _mock("extends Node\nvar display_name := 'Fallen'\nvar current_health := 0\nvar max_health := 30\n" \
		+ "var stress := 2\nvar max_stress := 10\nfunc is_alive():\n\treturn false\n")
	var rect := TextureRect.new()
	rect.custom_minimum_size = cpp.PORTRAIT_SIZE
	cpp._row.add_child(rect)
	cpp._portraits.append({"rect": rect, "character": corpse})
	cpp._tint_if_dead(rect, corpse)
	_check("portraits.dead-tint", rect.modulate == cpp.DEAD_TINT)
	await _await_frames(3)
	var pos: Vector2 = cpp.get_global_transform().affine_inverse() * rect.get_global_rect().get_center()
	var n0: int = GameLog.get_entries().size()
	_check("portraits.dead-not-draggable", cpp._get_drag_data(pos) == null and _log_has("is dead and can't take part in downtime", n0))
	var tip: String = cpp._get_tooltip(pos)
	_check("portraits.tooltip", tip.contains("Fallen (dead)") and tip.contains("HP 0/30") and tip.contains("Stress 2/10"), tip)
	var live = game.party_chars[0]
	cpp._rebuild_portraits()
	await _await_frames(3)
	var live_pos: Vector2 = cpp.get_global_transform().affine_inverse() * cpp._portraits[0]["rect"].get_global_rect().get_center()
	var lt: String = cpp._get_tooltip(live_pos)
	_check("portraits.live-tooltip", lt.contains("HP %d/%d" % [live.current_health, live.max_health]), lt)
	cpp.visible = false
	corpse.queue_free()

func _case_drag_service() -> void:
	var a = game.party_chars[0]
	var tsp = game.get_node("GameUI/TownServicesPanel")
	var region_id: String = RegionDatabase.get_region_for_map(str(game.current_map_id))
	var uids: Array = []
	for e in RegionDatabase.get_service_npcs_in_region(region_id):
		uids.append(e["npc_uid"])
	game.known_services_per_region[region_id] = uids
	tsp._repopulate()
	tsp._repopulate()  # twice: the second must not leave the NPC wired to a freed card
	tsp._set_panel_open(true, false)
	await _await_frames(4)
	# Prefer a service NPC standing on this map (the live-inventory path).
	var card: Dictionary = {}
	for c in tsp._cards:
		if c.has("inv_grid") and is_instance_valid(c["inv_grid"]):
			if card.is_empty() or (card["live_npc"] == null and c["live_npc"] != null):
				card = c
	print("service card: %s live=%s" % [str(card.get("entry", {}).get("display_name", "?")), str(card.get("live_npc") != null)])
	_check("service.setup-card", not card.is_empty() and tsp.visible, "cards %d visible %s" % [tsp._cards.size(), tsp.visible])
	if card.is_empty():
		return
	var npc = card["live_npc"]
	if npc != null and npc.inventory:
		# Bound callables compare by method, so without the disconnect in
		# _repopulate the new card's connect was refused and the NPC kept
		# refreshing the first (freed) card.
		var wired := 0
		var to_current := false
		for conn in npc.inventory.item_added.get_connections():
			var cb: Callable = conn["callable"]
			if cb.get_method() == "_on_live_inventory_changed":
				wired += 1
				var bound: Array = cb.get_bound_arguments()
				to_current = not bound.is_empty() and is_same(bound[0], card)
		_check("service.repopulate-rewires-current-card", wired == 1 and to_current, "%d %s" % [wired, to_current])
	# Party slot -> service card header: the service receives it.
	a.inventory.add_item(_item("apple"))
	await _await_frames(2)
	var given0 := _count(a.inventory, "apple")
	var held0: int = 0
	for it in tsp._get_service_inventory(card["entry"], npc):
		if str(it.get("id", "")) == "apple":
			held0 += 1
	var header: Control = card["header"]
	await _mouse_drag(_center(_slot_for(a, "apple")), _center(header))
	var held1: int = 0
	for it in tsp._get_service_inventory(card["entry"], npc):
		if str(it.get("id", "")) == "apple":
			held1 += 1
	_check("drag.party-to-service", _count(a.inventory, "apple") == given0 - 1 and held1 == held0 + 1,
		"party %d->%d service %d->%d" % [given0, _count(a.inventory, "apple"), held0, held1])
	# Service slot -> party header: what was given can be taken back.
	await _await_frames(2)
	var svc_slot = null
	for sl in card["inv_grid"].get_children():
		if sl.is_queued_for_deletion() or not sl.has_meta("slot_entry"):
			continue
		var raw = sl.get_meta("slot_entry").get("raw")
		if raw is Dictionary and str(raw.get("id", "")) == "apple":
			svc_slot = sl
	_check("service.slot-found", svc_slot != null)
	if svc_slot != null:
		var back0 := _count(a.inventory, "apple")
		await _mouse_drag(_center(svc_slot), _center(_panel(a)["name_label"].get_parent()))
		_check("drag.service-to-party", _count(a.inventory, "apple") == back0 + 1, "%d -> %d" % [back0, _count(a.inventory, "apple")])
