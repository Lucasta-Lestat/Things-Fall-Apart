# res://tests/inventory_lane_test.gd
# Headless assertion harness for the inventory/trade/services feedback port:
# weapon-swap refusals, explicit "Equip to Main/Off", Inventory.can_accept and
# the full-receiver refusals (trade window, service card), the trade-cancel
# worn-gear resync, the chest window's full-pack and no-recipient feedback,
# locked containers, the world context menu's options (Talk, Inspect,
# Attack, containers) and the Attack order, Pick Up leaving no salvage, and
# the Town Services panel (new-service listing, credit, weapon refusal, warp
# menu, away weapons, downtime card text, date refresh). Drives the real game
# scene the way feedback_layer_test does.
# Run:  godot --headless --path . res://tests/inventory_lane_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

var failures := 0
var game = null

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
	await get_tree().process_frame
	var GameScene := load("res://game.tscn")
	game = GameScene.instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _await_frames(2)
	game.load_map("town_square")
	await _await_frames(10)

	_case_swap_and_explicit_equip()
	_case_can_accept()
	_case_trade_full_npc()
	_case_trade_cancel_resyncs_worn()
	await _case_chest_window()
	_case_locked_chest()
	await _case_context_menu_options()
	_case_context_attack()
	_case_pickup_no_salvage()
	await _case_services_panel()

	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _last_log() -> String:
	var e: Array = GameLog.get_entries()
	return str(e[-1].text) if not e.is_empty() else ""

func _log_size() -> int:
	return GameLog.get_entries().size()

func _lines_since(n0: int) -> Array:
	var out := []
	for e in GameLog.get_entries().slice(n0):
		out.append(str(e.text))
	return out

func _npc():
	for c in game.characters_in_scene:
		if is_instance_valid(c) and not c in game.party_chars and c.is_alive() \
				and not FactionDatabase.are_hostile("player", c.faction_id):
			return c
	return null

func _npc_by_template(template_id: String):
	for c in game.characters_in_scene:
		if is_instance_valid(c) and not c in game.party_chars and c.is_alive() \
				and str(c.get_meta("template_id", "")) == template_id:
			return c
	return null

## A throwaway character, parked far from everyone. `party` puts it in
## game.party_chars (is_party_member) until _drop_temp.
func _spawn_temp(party: bool) -> ProceduralCharacter:
	var pc: ProceduralCharacter = PC_SCENE.instantiate()
	add_child(pc)
	pc.global_position = Vector2(-20000, -20000)
	pc.Name = "Harness Temp"
	pc.AI_enabled = false
	if party:
		game.party_chars.append(pc)
	return pc

func _drop_temp(pc) -> void:
	game.party_chars.erase(pc)
	if is_instance_valid(pc):
		pc.queue_free()

func _weapon_shape(two_handed: bool) -> WeaponShape:
	for wid in ItemDatabase.weapons.keys():
		var data: Dictionary = ItemDatabase.weapons[wid]
		if str(data.get("equip_slot", "")) != "Main Hand":
			continue
		var w := WeaponShape.new()
		w.load_from_data(data)
		if w.is_two_handed() == two_handed:
			return w
		w.free()
	return null

func _fill(inv, keep: Array) -> void:
	inv.items.clear()
	for k in keep:
		inv.items.append(k)
	var i := 0
	while inv.items.size() < inv.max_slots:
		inv.items.append({"id": "harness_filler_%d" % i, "display_name": "Filler"})
		i += 1

func _restore_items(inv, saved: Array) -> void:
	inv.items.clear()
	for it in saved:
		inv.items.append(it)

func _find_child_with_script(parent: Node, script_suffix: String) -> Node:
	for i in range(parent.get_child_count() - 1, -1, -1):
		var c = parent.get_child(i)
		if c.get_script() != null and str(c.get_script().resource_path).ends_with(script_suffix) \
				and not c.is_queued_for_deletion():
			return c
	return null

# ---------------------------------------------------------------------------
# Weapon swaps and explicit equips (inventory.gd)
# ---------------------------------------------------------------------------

func _case_swap_and_explicit_equip() -> void:
	var pc := _spawn_temp(true)
	var inv = pc.inventory
	for h in ["Main", "Off"]:
		inv.stow_hand(h)
	for w in inv.stowed_items:
		if is_instance_valid(w):
			w.queue_free()
	inv.stowed_items.clear()

	pc._last_notify_text = ""
	var n0 := _log_size()
	inv.cycle_weapon_for_hand("Main", 1)
	_check("swap.nothing-stowed-says-so", _last_log() == "%s can't swap weapons: nothing is stowed." % pc.Name, _last_log())

	var axe := _weapon_shape(true)
	var dagger := _weapon_shape(false)
	_check("swap.fixtures", axe != null and dagger != null)
	if axe == null or dagger == null:
		_drop_temp(pc)
		return
	inv.equip_item(axe, "Main")
	inv.stowed_items.append(dagger)
	pc._last_notify_text = ""
	inv.cycle_weapon_for_hand("Off", 1)
	_check("swap.two-hander-blocks-off", _last_log() == "%s can't swap weapons: both hands are on the %s." % [pc.Name, axe.display_name], _last_log())
	_check("swap.two-hander-off-untouched", inv.off_hand_item == null and inv.main_hand_item == axe)

	# Explicit Off with a two-hander in Main: the two-hander is stowed and the
	# one-hander goes to Off, as asked.
	inv.stowed_items.erase(dagger)
	inv.equip_item(dagger, "Off", true)
	_check("equip.explicit-off-honoured", inv.off_hand_item == dagger and inv.main_hand_item == null,
		"main=%s off=%s" % [inv.main_hand_item, inv.off_hand_item])

	# Explicit Off when Off is taken and Main is free: still Off (the old
	# _pick_hand moved it to Main). The non-explicit call keeps the old pick.
	var dagger2 := _weapon_shape(false)
	inv.equip_item(dagger2, "Off", true)
	_check("equip.explicit-off-replaces-off", inv.off_hand_item == dagger2 and inv.main_hand_item == null \
		and dagger in inv.stowed_items)
	var dagger3 := _weapon_shape(false)
	inv.equip_item(dagger3, "Off")
	_check("equip.implicit-still-picks-free-hand", inv.main_hand_item == dagger3)

	# Explicit Off with a two-hander: Main, with the reason.
	inv.stowed_items.erase(axe)
	pc._last_notify_text = ""
	inv.equip_item(axe, "Off", true)
	_check("equip.two-handed-to-main", inv.main_hand_item == axe and inv.off_hand_item == null)
	_check("equip.two-handed-explained", _last_log() == "%s can't hold the %s in the off hand: it is two-handed." % [pc.Name, axe.display_name], _last_log())

	# Ability equips from the menu are explicit by default.
	var ab_ok := false
	for aid in ["fireball", "firebolt", "heal"]:
		if not AbilityDatabase.get_ability_data(aid).is_empty():
			inv.stow_ability_from_id(aid)
			ab_ok = true
			break
	if ab_ok:
		var canonical = null
		for it in inv.stowed_items:
			if it is AbilityShape:
				canonical = it
		inv.stow_hand("Main")
		inv.equip_item(_weapon_shape(false), "Off")
		inv.equip_ability_to_hand(canonical, "Off")
		_check("equip.ability-explicit-off", inv.off_hand_item is AbilityShape and inv.main_hand_item == null,
			"main=%s off=%s" % [inv.main_hand_item, inv.off_hand_item])

	# NPCs stay quiet.
	game.party_chars.erase(pc)
	inv.stowed_items.clear()
	n0 = _log_size()
	inv.cycle_weapon_for_hand("Main", 1)
	_check("swap.npc-silent", _log_size() == n0)
	_drop_temp(pc)

# ---------------------------------------------------------------------------
# Inventory.can_accept and full receivers
# ---------------------------------------------------------------------------

func _case_can_accept() -> void:
	var pc := _spawn_temp(false)
	var inv = pc.inventory
	_fill(inv, [])
	_check("accept.full-refuses", not inv.can_accept({"id": "harness_rock"}))
	inv.items[0] = {"id": "harness_coin", "is_stackable": true, "max_stack_size": 10, "num_stacks": 9}
	_check("accept.stack-room", inv.can_accept({"id": "harness_coin", "is_stackable": true, "max_stack_size": 10}))
	inv.items[0]["num_stacks"] = 10
	_check("accept.stack-full", not inv.can_accept({"id": "harness_coin", "is_stackable": true, "max_stack_size": 10}))
	inv.items.pop_back()
	_check("accept.free-slot", inv.can_accept({"id": "harness_rock"}))
	# Agrees with add_item.
	var rock := {"id": "harness_rock"}
	_check("accept.agrees-with-add_item", inv.can_accept(rock) == inv.add_item(rock))
	_check("accept.agrees-when-full", inv.can_accept({"id": "harness_rock2"}) == false and not inv.add_item({"id": "harness_rock2"}))
	_drop_temp(pc)

func _open_trade(npc) -> TradeWindow:
	game.show_trade_window(npc)
	var ui: Node = game.get_node("GameUI")
	for i in range(ui.get_child_count() - 1, -1, -1):
		var c = ui.get_child(i)
		if c is TradeWindow and not c.is_queued_for_deletion():
			return c
	return null

func _case_trade_full_npc() -> void:
	var npc = _npc()
	var p0 = game.party_chars[0]
	_check("trade.fixtures", npc != null and p0 != null)
	if npc == null:
		return
	var npc_saved: Array = npc.inventory.items.duplicate()
	var p_saved: Array = p0.inventory.items.duplicate()
	var trinket := {"id": "harness_trinket", "display_name": "Harness Trinket", "cost": 5}
	p0.inventory.items.append(trinket)
	_fill(npc.inventory, [])
	var w := _open_trade(npc)
	_check("trade.window-open", w != null)
	if w == null:
		_restore_items(npc.inventory, npc_saved)
		_restore_items(p0.inventory, p_saved)
		return
	var idx: int = p0.inventory.items.find(trinket)
	var drop := {"source_character": p0, "entry": {"kind": "item", "source_index": idx, "raw": trinket, "display_name": "Harness Trinket"}}
	p0._last_notify_text = ""
	var npc_n: int = npc.inventory.items.size()
	w._drop_data(Vector2.ZERO, drop)
	_check("trade.full-npc-refuses", p0.inventory.items.has(trinket) and npc.inventory.items.size() == npc_n)
	_check("trade.full-npc-says-why", _last_log() == "%s can't give the Harness Trinket to %s: their inventory is full." % [p0.Name, npc.Name], _last_log())
	npc.inventory.items.pop_back()
	w._drop_data(Vector2.ZERO, drop)
	_check("trade.room-moves-it", not p0.inventory.items.has(trinket) \
		and npc.inventory.items.any(func(d): return str(d.get("id", "")) == "harness_trinket"))
	w._on_cancel_pressed()
	_check("trade.cancel-restores", p0.inventory.items.any(func(d): return str(d.get("id", "")) == "harness_trinket"))
	_restore_items(npc.inventory, npc_saved)
	_restore_items(p0.inventory, p_saved)

func _case_trade_cancel_resyncs_worn() -> void:
	var npc = _npc()
	if npc == null:
		_check("worn.fixtures", false, "no npc")
		return
	var pc := _spawn_temp(true)
	var helm: Dictionary = ItemDatabase.get_item_data("kettle_helm").duplicate(true)
	var boots: Dictionary = ItemDatabase.get_item_data("leather_boots").duplicate(true)
	var shirt: Dictionary = ItemDatabase.get_item_data("padded_vest").duplicate(true)
	_check("worn.fixtures", not helm.is_empty() and not boots.is_empty() and not shirt.is_empty())
	if helm.is_empty() or boots.is_empty() or shirt.is_empty():
		_drop_temp(pc)
		return
	pc.inventory.items.clear()
	pc.inventory.items.append(helm)
	pc.equip_equipment(boots)
	boots["_equipped"] = true
	pc.inventory.items.append(boots)
	pc.equip_equipment(shirt)
	shirt["_equipped"] = true
	pc.inventory.items.append(shirt)
	var torso_before = pc.torso_equipment

	var w := _open_trade(npc)
	_check("worn.window-open", w != null)
	if w == null:
		_drop_temp(pc)
		return
	# Side-panel Equip / Unequip mid-trade (what PartySidePanel does).
	pc.equip_equipment(helm)
	helm["_equipped"] = true
	pc.unequip_slot(EquipmentShape.EquipmentSlot.FEET)
	boots["_equipped"] = false
	w._on_cancel_pressed()

	_check("worn.cancel-takes-off-mid-trade-equip", pc.head_equipment == null)
	var restored_boots = null
	var restored_shirt = null
	for d in pc.inventory.items:
		if str(d.get("id", "")) == "leather_boots":
			restored_boots = d
		elif str(d.get("id", "")) == "padded_vest":
			restored_shirt = d
	_check("worn.cancel-puts-back-unequipped", pc.feet_equipment != null and restored_boots != null \
		and is_same(pc.feet_equipment.get_meta("item_data"), restored_boots))
	_check("worn.untouched-stays-on", pc.torso_equipment == torso_before and is_instance_valid(torso_before))
	_check("worn.untouched-repointed", restored_shirt != null and is_same(pc.torso_equipment.get_meta("item_data"), restored_shirt))
	_drop_temp(pc)

# ---------------------------------------------------------------------------
# Chest window (full pack, no recipient) and locked containers
# ---------------------------------------------------------------------------

func _open_chest(chest) -> ChestInventoryWindow:
	game.show_chest_inventory(chest)
	var ui: Node = game.get_node("GameUI")
	for i in range(ui.get_child_count() - 1, -1, -1):
		var c = ui.get_child(i)
		if c is ChestInventoryWindow and not c.is_queued_for_deletion() and c.chest_item == chest:
			return c
	return null

func _case_chest_window() -> void:
	var picker = game._resolve_pickup_character()
	_check("chest.picker", picker != null)
	if picker == null:
		return
	var chest = game.create_item("treasure_chest", picker.global_position + Vector2(8, 0))
	_check("chest.created", chest != null)
	if chest == null:
		return
	var gem := {"id": "harness_gem", "display_name": "Harness Gem", "is_stackable": true, "max_stack_size": 10, "num_stacks": 4}
	chest.contents = [gem]
	var w := _open_chest(chest)
	_check("chest.window-open", w != null)
	if w == null:
		chest._destroy_item()
		return
	var saved: Array = picker.inventory.items.duplicate()
	_fill(picker.inventory, [])
	picker._last_notify_text = ""
	var n0 := _log_size()
	w._transfer_slot_to_selected(w._grid.get_child(0))
	var lines := _lines_since(n0)
	_check("chest.full-keeps-item", chest.contents.has(gem) and int(gem["num_stacks"]) == 4)
	_check("chest.full-one-notice", lines.size() == 1 and str(lines[0]).contains("inventory full"), str(lines))
	_restore_items(picker.inventory, saved)

	# No living party member to receive it: said in the log, not push_warning.
	var party_saved: Array = game.party_chars.duplicate()
	var primary_saved = game.primary_selected
	game.party_chars.clear()
	game.primary_selected = null
	await get_tree().process_frame
	n0 = _log_size()
	if w._grid.get_child_count() > 0:
		w._transfer_slot_to_selected(w._grid.get_child(w._grid.get_child_count() - 1))
	for c in party_saved:
		game.party_chars.append(c)
	game.primary_selected = primary_saved
	_check("chest.no-recipient-logged", _lines_since(n0).has("No one is free to take that."), str(_lines_since(n0)))
	w.queue_free()
	chest._destroy_item()

func _case_locked_chest() -> void:
	var picker = game._resolve_pickup_character()
	if picker == null:
		return
	var chest = game.create_item("treasure_chest", picker.global_position + Vector2(8, 0))
	if chest == null:
		_check("lock.created", false)
		return
	chest.contents = []
	chest.key = "iron_key"
	# Nobody carries the key.
	var holders := []
	for c in game.party_chars:
		if c.inventory.find_item_by_id("iron_key") != -1:
			holders.append(c)
	_check("lock.fixture-no-key", holders.is_empty())
	var n0 := _log_size()
	var w := _open_chest(chest)
	_check("lock.locked-stays-shut", w == null)
	_check("lock.locked-logged", _lines_since(n0).has("The %s is locked." % chest.display_name), str(_lines_since(n0)))
	# With the key it opens, says who unlocked it, and stays unlocked.
	var key_data: Dictionary = ItemDatabase.get_item_data("iron_key").duplicate(true)
	picker.inventory.items.append(key_data)
	n0 = _log_size()
	w = _open_chest(chest)
	_check("lock.key-opens", w != null)
	_check("lock.unlock-logged", _lines_since(n0).has("%s unlocks the %s with the %s." % [picker.Name, chest.display_name, str(key_data.get("display_name", "iron_key"))]), str(_lines_since(n0)))
	_check("lock.stays-unlocked", chest.key == null)
	_check("lock.key-not-consumed", picker.inventory.items.has(key_data))
	picker.inventory.items.erase(key_data)
	if w != null:
		w.queue_free()
	chest._destroy_item()

# ---------------------------------------------------------------------------
# World context menu
# ---------------------------------------------------------------------------

func _menu_options(target, actor = null) -> Array:
	var ui: Node = game.get_node("GameUI")
	var before = _find_child_with_script(ui, "context_menu.gd")
	game.show_context_menu(target, Vector2(100, 100), actor)
	var menu = _find_child_with_script(ui, "context_menu.gd")
	if menu == null or menu == before:
		return ["<no menu>"]
	var out := []
	for b in menu.vbox.get_children():
		if b is Button and not b.is_queued_for_deletion():
			out.append(b.text)
	menu.queue_free()
	game.context_menu_open = false
	return out

func _case_context_menu_options() -> void:
	var p0 = game.party_chars[0]
	var npc = _npc()
	if npc == null:
		_check("menu.fixtures", false, "no npc")
		return
	var saved_opts: Array = npc.interact_options.duplicate()
	var saved_dlg: Array = npc.dialogues.duplicate()
	var saved_idx: int = npc.current_dialogue_index

	npc.interact_options = ["Talk", "Inspect"]
	npc.dialogues = ["no_such_dialogue_harness"]
	npc.current_dialogue_index = 0
	var opts := _menu_options(npc, p0)
	_check("menu.no-dead-talk", not opts.has("Talk"), str(opts))
	_check("menu.no-inspect", not opts.has("Inspect"), str(opts))
	_check("menu.trade-kept", opts.has("Trade"), str(opts))

	var real_dlg := ""
	for did in DialogueManager.dialogues.keys():
		var d = DialogueManager.dialogues[did]
		if d is Dictionary and d.get("dialogueNodes") is Dictionary and not d["dialogueNodes"].is_empty():
			real_dlg = str(did)
			break
	npc.dialogues = [real_dlg]
	opts = _menu_options(npc, p0)
	_check("menu.talk-with-dialogue", opts.has("Talk"), str(opts))

	npc.interact_options = ["Attack", "Talk"]
	opts = _menu_options(npc, p0)
	_check("menu.attack-on-npc", opts.has("Attack"), str(opts))
	var p_saved_opts: Array = p0.interact_options.duplicate()
	p0.interact_options = ["Attack", "Inspect"]
	opts = _menu_options(p0, p0)
	_check("menu.no-attack-on-companion", not opts.has("Attack") and not opts.has("Inspect"), str(opts))
	p0.interact_options = p_saved_opts

	npc.interact_options = saved_opts
	npc.dialogues = saved_dlg
	npc.current_dialogue_index = saved_idx

	# Containers: only options something handles.
	var chest = game.create_item("treasure_chest", p0.global_position + Vector2(8, 0))
	opts = _menu_options(chest, p0)
	_check("menu.chest-just-open", opts == ["Open"], str(opts))
	chest._destroy_item()
	var pack = game.create_item("leather_backpack", p0.global_position + Vector2(8, 0))
	opts = _menu_options(pack, p0)
	_check("menu.world-pack-just-open", opts == ["Open"], str(opts))
	pack._destroy_item()

	# Nothing usable: no empty box.
	var mute := _spawn_temp(false)
	mute.interact_options = ["Inspect"]
	mute.faction_id = "bandits"
	opts = _menu_options(mute, p0)
	_check("menu.empty-not-shown", opts == ["<no menu>"], str(opts))
	await get_tree().process_frame
	_check("menu.flag-reset", not game.context_menu_open)
	_drop_temp(mute)

func _case_context_attack() -> void:
	var p0 = game.party_chars[0]
	var npc = _npc()
	if npc == null or p0.action_queue == null:
		_check("attack.fixtures", false)
		return
	var menu = preload("res://UI/ContextMenu.tscn").instantiate()
	game.get_node("GameUI").add_child(menu)
	menu.setup(npc, ["Attack"], p0)
	_check("attack.not-on-companion", not menu._is_attackable(p0))
	_check("attack.on-npc", menu._is_attackable(npc))

	# Planning: the order is queued on the actor, not swung by the target.
	p0.action_queue.clear_queue()
	PauseManager.is_paused = true
	menu._order_attack(npc)
	PauseManager.is_paused = false
	var q: Array = p0.action_queue.queue
	_check("attack.paused-queues", q.size() == 1 and q[0].data.get("target") == npc, str(q.size()))
	p0.action_queue.clear_queue()

	# No actor and nobody selected: the log says so.
	menu.actor_character = null
	var sel_saved: Array = game.selected_characters.duplicate()
	var prim_saved = game.primary_selected
	game.selected_characters.clear()
	game.primary_selected = null
	var n0 := _log_size()
	menu._order_attack(npc)
	_check("attack.no-actor-logged", _lines_since(n0).has("No party member is selected to attack %s: select one first." % npc.Name), str(_lines_since(n0)))
	for c in sel_saved:
		game.selected_characters.append(c)
	game.primary_selected = prim_saved

	# Someone who can't take orders refuses, with the reason.
	var pc := _spawn_temp(true)
	menu.actor_character = pc
	# Frightened carries an apply-time save, so a few tries may be needed.
	var applied := false
	for attempt in range(20):
		if pc.condition_manager.apply_condition("frightened", null, 1) != null:
			applied = true
			break
	if applied:
		pc._last_notify_text = ""
		if pc.action_queue:
			pc.action_queue.clear_queue()
		PauseManager.is_paused = true
		menu._order_attack(npc)
		PauseManager.is_paused = false
		_check("attack.frightened-refuses", pc.action_queue == null or pc.action_queue.queue.is_empty())
		_check("attack.frightened-says-why", _last_log().begins_with("%s can't take orders:" % pc.Name), _last_log())
		pc.condition_manager.remove_condition("frightened")
	else:
		_check("attack.frightened-fixture", false, "apply_condition(frightened) failed")
	_drop_temp(pc)
	menu.queue_free()
	game.context_menu_open = false

# ---------------------------------------------------------------------------
# Pick Up leaves no salvage (Game.remove_world_item)
# ---------------------------------------------------------------------------

func _case_pickup_no_salvage() -> void:
	var picker = game._resolve_pickup_character()
	if picker == null:
		_check("pickup.picker", false)
		return
	var data: Dictionary = ItemDatabase.get_item_data("longsword")
	_check("pickup.fixture-has-resources", not data.is_empty() and not (data.get("resources", {}) as Dictionary).is_empty())
	var sword = game.create_item("longsword", picker.global_position + Vector2(4, 0))
	if sword == null:
		_check("pickup.created", false)
		return
	var destroyed := [false]
	sword.destroyed.connect(func(_i): destroyed[0] = true)
	var n_items: int = game.items_in_scene.size()
	var stowed_before: int = picker.inventory.stowed_items.size()
	var ok: bool = game.pick_up_item(sword)
	_check("pickup.ok", ok)
	_check("pickup.no-salvage", game.items_in_scene.size() == n_items - 1, "%d -> %d" % [n_items, game.items_in_scene.size()])
	_check("pickup.no-destroyed-signal", not destroyed[0])
	_check("pickup.leaves-world", not game.items_in_scene.has(sword) and sword.is_queued_for_deletion())
	# Clean up the stowed copy.
	if picker.inventory.stowed_items.size() > stowed_before:
		var w = picker.inventory.stowed_items.pop_back()
		if is_instance_valid(w):
			w.queue_free()

# ---------------------------------------------------------------------------
# Town Services panel
# ---------------------------------------------------------------------------

func _card_for(panel, uid: String) -> Dictionary:
	for card in panel._cards:
		var e = card.get("entry")
		if e is Dictionary and e.get("npc_uid", "") == uid:
			return card
	return {}

func _case_services_panel() -> void:
	var panel = game.get_node_or_null("GameUI/TownServicesPanel")
	_check("svc.panel", panel != null)
	if panel == null:
		return
	var smith = _npc_by_template("smith_darcy")
	_check("svc.smith-on-map", smith != null)
	if smith == null:
		return
	var region_id: String = RegionDatabase.get_region_for_map(game.current_map_id)
	var uid: String = game._build_npc_uid(str(smith.get_meta("template_id", "")), str(smith.get_meta("unique_name", "")))
	panel.mode = "services"

	# A service met while the panel is up is listed at once, alone: other
	# cards keep their trade baselines.
	if game.known_services_per_region.has(region_id):
		game.known_services_per_region[region_id].erase(uid)
	panel._repopulate()
	await _await_frames(2)
	_check("svc.visible", panel.visible)
	_check("svc.unseen-not-listed", _card_for(panel, uid).is_empty())
	panel._value_baseline["harness_other"] = 42.0
	game.mark_service_seen(smith)
	await _await_frames(2)
	var listed := 0
	for card in panel._cards:
		if card.get("entry", {}).get("npc_uid", "") == uid:
			listed += 1
	_check("svc.newly-seen-listed", listed == 1, str(listed))
	_check("svc.other-baselines-kept", float(panel._value_baseline.get("harness_other", -1.0)) == 42.0)
	var card: Dictionary = _card_for(panel, uid)
	if card.is_empty():
		return

	# Credit: value dropped beyond what was taken back.
	var current: float = panel._compute_inventory_value(panel._get_service_inventory(card["entry"], smith))
	panel._value_baseline[uid] = current - 7.0
	_check("svc.credit", is_equal_approx(panel.get_credit(uid), 7.0), str(panel.get_credit(uid)))
	panel._value_baseline[uid] = current

	# Drops onto the card: items and weapons are accepted (weapons only to be
	# refused with a reason); anything else isn't.
	await get_tree().process_frame
	var center: Vector2 = (card["container"] as Control).get_global_rect().get_center()
	var local: Vector2 = panel.get_global_transform().affine_inverse() * center
	var p0 = game.party_chars[0]
	_check("svc.card-found-at-point", not panel._find_card_at(local).is_empty())
	_check("svc.drop-item-ok", panel._can_drop_data(local, {"source_character": p0, "entry": {"kind": "item"}}))
	_check("svc.drop-weapon-ok", panel._can_drop_data(local, {"source_character": p0, "entry": {"kind": "weapon"}}))
	_check("svc.drop-ability-no", not panel._can_drop_data(local, {"source_character": p0, "entry": {"kind": "ability"}}))
	_check("svc.drop-no-entry-no", not panel._can_drop_data(local, {"source_character": p0, "kind": "portrait"}))
	var n0 := _log_size()
	p0._last_notify_text = ""
	panel._drop_data(local, {"source_character": p0, "entry": {"kind": "weapon", "display_name": "Harness Blade"}})
	_check("svc.weapon-refused-with-reason", _last_log() == "Weapons can't be traded on a service card; trade with %s in person instead." % str(card["entry"].get("display_name", "")), _last_log())

	# A full live NPC refuses an item rather than swallow it.
	var s_saved: Array = smith.inventory.items.duplicate()
	var p_saved: Array = p0.inventory.items.duplicate()
	var trinket := {"id": "harness_trinket", "display_name": "Harness Trinket", "cost": 5}
	p0.inventory.items.append(trinket)
	_fill(smith.inventory, [])
	p0._last_notify_text = ""
	panel._drop_data(local, {"source_character": p0, "entry": {"kind": "item", "source_index": p0.inventory.items.find(trinket), "raw": trinket, "display_name": "Harness Trinket"}})
	_check("svc.full-npc-refuses", p0.inventory.items.has(trinket))
	_check("svc.full-npc-says-why", _last_log() == "%s can't give the Harness Trinket to %s: their inventory is full." % [p0.Name, smith.Name], _last_log())
	_restore_items(smith.inventory, s_saved)
	_restore_items(p0.inventory, p_saved)
	panel._refresh_inventory(card)

	# Warp menu: no "Warp to" the current map; Talk only with a dialogue.
	panel._show_warp_menu(card)
	var menu: PopupMenu = null
	for c in panel.get_children():
		if c is PopupMenu and not c.is_queued_for_deletion():
			menu = c
	_check("svc.menu-shown", menu != null)
	if menu != null:
		var texts := []
		for i in range(menu.item_count):
			texts.append(menu.get_item_text(i))
		_check("svc.menu-no-warp-here", not texts.any(func(t): return str(t).begins_with("Warp to")), str(texts))
		_check("svc.menu-trade", texts.has("Trade"), str(texts))
		_check("svc.menu-no-dead-talk", (smith.active_dialogue_id() != "") == texts.has("Talk"), str(texts))
		menu.queue_free()
	game.context_menu_open = false
	# A local card whose NPC is gone: nothing to offer, said in the log.
	var gone := {"entry": card["entry"], "live_npc": null}
	n0 = _log_size()
	var kids: int = panel.get_child_count()
	panel._show_warp_menu(gone)
	_check("svc.gone-no-menu", panel.get_child_count() == kids)
	_check("svc.gone-logged", _last_log() == "%s isn't here right now." % str(card["entry"].get("display_name", "")), _last_log())
	game.context_menu_open = false

	# Away NPC: the snapshot's weapons show greyed and can't be dragged.
	var away_map := ""
	for m in RegionDatabase.get_member_maps(region_id):
		if str(m) != game.current_map_id:
			away_map = str(m)
			break
	# What Game._serialize_character stores: WeaponShape.to_data().
	var away_weapon := _weapon_shape(false)
	var dagger_data: Dictionary = away_weapon.to_data() if away_weapon else {}
	if away_weapon:
		away_weapon.free()
	var away_entry := {"npc_uid": "harness_away", "map_id": away_map, "display_name": "Harness Away", "titles": ["Smith"], "template_id": "harness", "unique_name": ""}
	if not game.npc_state_per_region.has(region_id):
		game.npc_state_per_region[region_id] = {}
	game.npc_state_per_region[region_id]["harness_away"] = {"inventory_items": [],
		"equipped_weapons": [{"hand": "Main", "type": "weapon", "data": dagger_data}, {"hand": "Stowed", "type": "ability", "data": {}}]}
	var grid := GridContainer.new()
	var away_card := {"entry": away_entry, "live_npc": null, "inv_grid": grid}
	panel._refresh_inventory(away_card)
	_check("svc.away-weapon-shown", grid.get_child_count() == 1, str(grid.get_child_count()))
	if grid.get_child_count() == 1:
		var slot = grid.get_child(0)
		_check("svc.away-weapon-display-only", slot.has_meta("display_only") and slot.modulate.a < 1.0)
		_check("svc.away-weapon-tooltip", str(slot.tooltip_text).begins_with("%s (" % str(dagger_data.get("name", ""))) \
			and str(slot.tooltip_text).contains("gold) - visit to trade"), slot.tooltip_text)
	panel.vbox.add_child(grid)
	panel._cards.append(away_card)
	await _await_frames(2)
	if grid.get_child_count() == 1:
		var slot_center: Vector2 = grid.get_child(0).get_global_rect().get_center()
		_check("svc.away-weapon-not-draggable", panel._find_slot_at(panel.get_global_transform().affine_inverse() * slot_center) == null)
	panel._cards.erase(away_card)
	grid.queue_free()
	game.npc_state_per_region[region_id].erase("harness_away")

	# Downtime cards: long text cut with an ellipsis, all of it in the tooltip.
	var long_desc := "x".repeat(200)
	var dcard = panel._build_downtime_card("harness_activity", {"name": "Harness", "description": long_desc})
	var desc_label: Label = dcard.get_child(0).get_child(1)
	_check("svc.desc-ellipsis", desc_label.text.length() == 140 and desc_label.text.ends_with("…"), str(desc_label.text.length()))
	_check("svc.desc-tooltip", dcard.tooltip_text == long_desc)
	var short_card = panel._build_downtime_card("harness_short", {"name": "Harness", "description": "Short."})
	_check("svc.desc-short-intact", short_card.get_child(0).get_child(1).text == "Short.")
	dcard.free()
	short_card.free()

	# The board follows the date in downtime mode only.
	_check("svc.date-hooked", TimeManager.date_changed.is_connected(panel._on_date_changed))
	panel._cards.append({"harness_marker": true})
	panel._on_date_changed(1, 1, 1)
	_check("svc.date-ignored-in-services", panel._cards.any(func(c): return c.has("harness_marker")))
	panel.mode = "downtime"
	panel._on_date_changed(1, 1, 1)
	_check("svc.date-repopulates-downtime", not panel._cards.any(func(c): return c.has("harness_marker")))
	panel.mode = "services"
	panel._repopulate()
	await _await_frames(2)
	panel._repopulate()
	await _await_frames(2)
	# Rebuilt cards listen to their NPC once, through the live card.
	var hooks := 0
	var hooked_live_card := false
	var live_card: Dictionary = _card_for(panel, uid)
	for conn in smith.inventory.item_added.get_connections():
		if conn.callable.get_object() == panel:
			hooks += 1
			var bound: Array = conn.callable.get_bound_arguments()
			hooked_live_card = not bound.is_empty() and is_same(bound[0], live_card)
	_check("svc.repopulate-rehooks-once", hooks == 1, str(hooks))
	_check("svc.repopulate-hooks-live-card", hooked_live_card)
