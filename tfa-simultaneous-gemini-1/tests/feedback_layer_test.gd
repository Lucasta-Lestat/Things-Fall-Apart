# res://tests/feedback_layer_test.gd
# Headless assertion harness for the player-feedback layer: the on-screen game
# log, notify(), floating-text stacking and colours, the PAUSED banner,
# ability cast-failure reasons, the "Inventory full" notice and partial-stack
# honesty, and template characters' Name. Drives the real game scene the way
# law_persist_test does.
# Run:  godot --headless --path . res://tests/feedback_layer_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

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
	_check("gamelog.no-test-seed", GameLog.get_entries().all(func(e): return str(e.text) != "test"))

	await get_tree().process_frame
	var GameScene := load("res://game.tscn")
	game = GameScene.instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _await_frames(2)
	game.load_map("town_square")
	await _await_frames(10)

	await _case_log_panel()
	_case_pause_banner()
	_case_floating_text()
	_case_notify()
	_case_cast_failure()
	_case_inventory_full()
	_case_pickup_partial()
	_case_names()

	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _npc():
	for c in game.characters_in_scene:
		if is_instance_valid(c) and not c in game.party_chars and c.is_alive():
			return c
	return null

func _floats_under(parent: Node) -> Array:
	var out := []
	for c in parent.get_children():
		if c is Label and c.get_script() != null and str(c.get_script().resource_path).ends_with("FloatingText.gd"):
			out.append(c)
	return out

func _case_log_panel() -> void:
	var ui: Node = game.get_node("GameUI")
	var panel: Control = ui.get_node_or_null("LogPanel")
	_check("log.panel-under-GameUI", panel != null)
	if panel == null:
		return
	_check("log.click-through", panel.mouse_filter == Control.MOUSE_FILTER_IGNORE \
		and panel.scroll_container.mouse_filter == Control.MOUSE_FILTER_IGNORE \
		and panel.log_content.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	_check("log.scrollbar-takes-mouse", panel.scroll_container.get_v_scroll_bar().mouse_filter != Control.MOUSE_FILTER_IGNORE)
	_check("log.process-always", panel.process_mode == Node.PROCESS_MODE_ALWAYS)
	_check("log.left-of-party-panel", is_equal_approx(panel.offset_right, -260.0) and is_equal_approx(panel.anchor_left, 1.0))

	var n0: int = GameLog.get_entries().size()
	var repeats := [0]
	var on_rep := func(count): repeats[0] = count
	GameLog.entry_repeated.connect(on_rep)
	GameLog.add_entry("Feedback harness line.")
	GameLog.add_entry("Feedback harness line.")
	GameLog.add_entry("Feedback harness line.")
	GameLog.entry_repeated.disconnect(on_rep)
	_check("gamelog.repeats-fold", GameLog.get_entries().size() == n0 + 1, "%d -> %d" % [n0, GameLog.get_entries().size()])
	_check("gamelog.count-kept", int(GameLog.get_entries()[-1].get("count", 1)) == 3)
	_check("gamelog.entry_repeated", repeats[0] == 3, str(repeats[0]))
	var last: RichTextLabel = panel.log_content.get_child(panel.log_content.get_child_count() - 1)
	_check("log.label-shows-xN", last.text.contains("Feedback harness line.") and last.text.contains("(x3)"), last.text)
	_check("log.labels-ignore-mouse", last.mouse_filter == Control.MOUSE_FILTER_IGNORE)

	var psp = ui.get_node("PartySidePanel")
	var was_visible: bool = panel.visible
	psp._toggle_panel()
	_check("log.follows-tab", panel.visible == psp.panel_visible and panel.visible != was_visible)
	psp._toggle_panel()
	_check("log.follows-tab-back", panel.visible == was_visible)

	var dlg: Control = ui.get_node("DialoguePanel")
	var dlg_was: bool = dlg.visible
	dlg.visible = true
	_check("log.lifts-above-dialogue", is_equal_approx(panel.offset_bottom, -210.0), str(panel.offset_bottom))
	dlg.visible = false
	_check("log.drops-back", is_equal_approx(panel.offset_bottom, -10.0), str(panel.offset_bottom))
	dlg.visible = dlg_was
	await get_tree().process_frame

func _case_pause_banner() -> void:
	PauseManager.pause()
	_check("pause.banner-shown", PauseManager._indicator != null and PauseManager._indicator.visible)
	_check("pause.banner-text", PauseManager._indicator.text.begins_with("PAUSED"))
	PauseManager.unpause()
	_check("pause.banner-hidden", not PauseManager._indicator.visible)
	_check("pause.banner-click-through", PauseManager._indicator.mouse_filter == Control.MOUSE_FILTER_IGNORE)

func _case_floating_text() -> void:
	var host := Node2D.new()
	add_child(host)
	var pos := Vector2(500, 500)
	for i in range(5):
		Globals.show_floating_text(str(i), pos, host, Color.WHITE)
	var ys := []
	for f in _floats_under(host):
		ys.append(f.global_position.y)
	_check("float.five-spawned", ys.size() == 5, str(ys.size()))
	if ys.size() == 5:
		_check("float.stack-30px-steps", is_equal_approx(ys[0] - ys[1], 30.0) and is_equal_approx(ys[1] - ys[2], 30.0) \
			and is_equal_approx(ys[2] - ys[3], 30.0), str(ys))
		_check("float.stack-wraps-at-4", is_equal_approx(ys[4], ys[0]), str(ys))
	Globals.show_floating_text("far", pos + Vector2(200, 0), host, Color.WHITE)
	var far = _floats_under(host)[-1]
	_check("float.other-cell-not-lifted", is_equal_approx(far.global_position.y, ys[0]), "%s vs %s" % [far.global_position.y, ys[0]])
	Globals.show_floating_text("big", pos + Vector2(0, 400), host, Color.WHITE, 0, Globals.NOTICE_FONT_SIZE)
	var big = _floats_under(host)[-1]
	_check("float.font-size", big.get_theme_font_size("font_size") == 18, str(big.get_theme_font_size("font_size")))
	_check("float.unpaused-inherits", big.process_mode == Node.PROCESS_MODE_INHERIT)
	get_tree().paused = true
	Globals.show_floating_text("paused", pos + Vector2(0, 800), host, Color.WHITE)
	var pf = _floats_under(host)[-1]
	get_tree().paused = false
	_check("float.paused-always", pf.process_mode == Node.PROCESS_MODE_ALWAYS)
	host.queue_free()

	_check("colour.necrotic-readable", Globals.damage_color("necrotic") != Color.BLACK)
	_check("colour.cold-not-physical", Globals.damage_color("cold") != Color.ALICE_BLUE \
		and Globals.damage_color("cold") != Globals.damage_color("slashing"))
	_check("colour.psychic-kept", Globals.damage_color("psychic") == Color.MEDIUM_ORCHID)
	_check("colour.lightning-alias", Globals.damage_color("lightning") == Globals.damage_color("electric"))
	var item_script: Script = load("res://Items/Item.gd")
	var has_dup := false
	for m in item_script.get_script_method_list():
		if m.name == "_get_damage_color":
			has_dup = true
	_check("colour.item-duplicate-gone", not has_dup)

func _case_notify() -> void:
	var p0 = game.party_chars[0]
	_check("notify.party-member", p0.is_party_member())
	var npc = _npc()
	_check("notify.npc-not-party", npc != null and not npc.is_party_member())
	p0._last_notify_text = ""
	var parent: Node = p0.get_parent()
	var before: int = _floats_under(parent).size()
	var n0: int = GameLog.get_entries().size()
	p0.notify("Harness notice", Color.WHITE, "Harness notice log line.")
	var floats := _floats_under(parent)
	_check("notify.floats", floats.size() == before + 1)
	if floats.size() > before:
		_check("notify.notice-font", floats[-1].get_theme_font_size("font_size") == Globals.NOTICE_FONT_SIZE)
	_check("notify.logs", GameLog.get_entries().size() == n0 + 1 and GameLog.get_entries()[-1].text == "Harness notice log line.")
	p0.notify("Harness notice", Color.WHITE, "Harness notice log line.")
	_check("notify.repeat-dropped", _floats_under(parent).size() == before + 1 and GameLog.get_entries().size() == n0 + 1)
	p0.notify("Harness float only")
	_check("notify.no-log-without-log-text", GameLog.get_entries().size() == n0 + 1)
	# While paused the label hangs off the character so it still tweens.
	PauseManager.is_paused = true
	get_tree().paused = true
	var own_before: int = _floats_under(p0).size()
	p0.notify("Harness paused notice")
	get_tree().paused = false
	PauseManager.is_paused = false
	var own := _floats_under(p0)
	_check("notify.paused-host-is-character", own.size() == own_before + 1)
	if own.size() > own_before:
		_check("notify.paused-label-always", own[-1].process_mode == Node.PROCESS_MODE_ALWAYS)

func _case_cast_failure() -> void:
	var p0 = game.party_chars[0]
	var ab := Ability.new()
	ab.id = "harness_bolt"
	ab.display_name = "Harness Bolt"
	var parent: Node = p0.get_parent()
	var n0: int = GameLog.get_entries().size()
	p0._last_notify_text = ""
	var f0: int = _floats_under(parent).size()
	p0.ability_manager.cast_failed.emit(ab, "Not enough Focus")
	_check("cast.reason-logged", GameLog.get_entries().size() == n0 + 1 \
		and GameLog.get_entries()[-1].text == "%s can't use Harness Bolt: Not enough Focus." % p0.Name,
		str(GameLog.get_entries()[-1].text))
	var fl := _floats_under(parent)
	_check("cast.reason-floats", fl.size() == f0 + 1 and fl[-1].text == "Not enough Focus")
	n0 = GameLog.get_entries().size()
	p0.ability_manager.cast_failed.emit(ab, "Illegal here: Assault")
	fl = _floats_under(parent)
	_check("cast.illegal-float-only", GameLog.get_entries().size() == n0 and fl[-1].text == "Illegal here", fl[-1].text)
	p0.ability_manager.cast_failed.emit(ab, "Cannot harm charm source")
	fl = _floats_under(parent)
	_check("cast.charm-float-only", GameLog.get_entries().size() == n0 and fl[-1].text == "Charmed", fl[-1].text)
	var npc = _npc()
	if npc != null and npc.ability_manager != null:
		var nf: int = _floats_under(npc.get_parent()).size()
		npc.ability_manager.cast_failed.emit(ab, "Not enough Focus")
		_check("cast.npc-silent", GameLog.get_entries().size() == n0 and _floats_under(npc.get_parent()).size() == nf)

	# An AI-driven party member retries its own refused casts every 1.2 s
	# (ai._cast), so those refusals stay quiet; the same refusal on an ordered
	# cast is still announced. current_cast forces "Already casting".
	var ai_node = p0.get_node_or_null("AI")
	var fb: Dictionary = AbilityDatabase.get_ability_data("fireball")
	_check("cast.ai-fixture", ai_node != null and not fb.is_empty())
	if ai_node != null and not fb.is_empty():
		var saved_cast: Dictionary = p0.ability_manager.current_cast
		p0.ability_manager.current_cast = {"state": "casting"}
		p0._last_notify_text = ""
		n0 = GameLog.get_entries().size()
		var f1: int = _floats_under(parent).size()
		var ai_ok: bool = ai_node._cast(fb, p0.global_position + Vector2(200, 0), null)
		_check("cast.ai-attempt-silent", not ai_ok and GameLog.get_entries().size() == n0 \
			and _floats_under(parent).size() == f1 and not p0.ai_cast_attempt)
		var ordered_ok: bool = p0.use_ability(Ability.from_dict(fb), {"position": p0.global_position + Vector2(200, 0)})
		_check("cast.ordered-attempt-announced", not ordered_ok and GameLog.get_entries().size() == n0 + 1 \
			and str(GameLog.get_entries()[-1].text).begins_with("%s can't use" % p0.Name), str(GameLog.get_entries()[-1].text))
		p0.ability_manager.current_cast = saved_cast

func _fill(inv, keep: Array) -> void:
	inv.items.clear()
	for k in keep:
		inv.items.append(k)
	var i := 0
	while inv.items.size() < inv.max_slots:
		inv.items.append({"id": "harness_filler_%d" % i, "display_name": "Filler"})
		i += 1

func _case_inventory_full() -> void:
	var p0 = game.party_chars[0]
	var inv = p0.inventory
	var saved: Array = inv.items.duplicate()
	_fill(inv, [])
	var fails := []
	var on_fail := func(d, r): fails.append([d, r])
	inv.add_failed.connect(on_fail)
	p0._last_notify_text = ""
	var n0: int = GameLog.get_entries().size()
	var ok: bool = inv.add_item({"id": "harness_rock", "display_name": "Harness Rock"})
	_check("inv.add_item-full-refused", not ok and fails.size() == 1 and fails[0][1] == "Inventory full")
	_check("inv.full-logged", GameLog.get_entries().size() == n0 + 1 and GameLog.get_entries()[-1].text == \
		"%s can't carry the Harness Rock: inventory full (%d/%d slots)." % [p0.Name, inv.max_slots, inv.max_slots],
		str(GameLog.get_entries()[-1].text))

	# Partial merge: 3 of 5 fit an existing stack, the rest has no slot.
	var stack := {"id": "harness_coin", "display_name": "Harness Coin", "is_stackable": true, "max_stack_size": 10, "num_stacks": 7}
	_fill(inv, [stack])
	var added := [0]
	var on_add := func(_d): added[0] += 1
	inv.item_added.connect(on_add)
	var incoming := {"id": "harness_coin", "display_name": "Harness Coin", "is_stackable": true, "max_stack_size": 10, "num_stacks": 5, "stolen_from": "harness_faction"}
	p0._last_notify_text = ""
	ok = inv.add_stack(incoming)
	_check("inv.partial-returns-false", not ok)
	_check("inv.partial-merged", int(stack["num_stacks"]) == 10, str(stack["num_stacks"]))
	_check("inv.partial-remainder-written-back", int(incoming["num_stacks"]) == 2, str(incoming["num_stacks"]))
	_check("inv.partial-announced-as-added", added[0] == 1, str(added[0]))
	_check("inv.stolen-from-propagated", str(stack.get("stolen_from", "")) == "harness_faction")
	inv.item_added.disconnect(on_add)

	# Nothing merges: no item_added, no write-back change.
	var other := {"id": "harness_gem", "display_name": "Harness Gem", "is_stackable": true, "max_stack_size": 10, "num_stacks": 4}
	added[0] = 0
	inv.item_added.connect(on_add)
	ok = inv.add_stack(other)
	inv.item_added.disconnect(on_add)
	_check("inv.no-merge-no-added", not ok and added[0] == 0 and int(other["num_stacks"]) == 4)
	inv.add_failed.disconnect(on_fail)
	inv.items.clear()
	for it in saved:
		inv.items.append(it)

	# NPCs stay quiet.
	var npc = _npc()
	if npc != null and npc.inventory != null:
		var nsaved: Array = npc.inventory.items.duplicate()
		_fill(npc.inventory, [])
		n0 = GameLog.get_entries().size()
		_check("inv.npc-refused", not npc.inventory.add_item({"id": "harness_rock2", "display_name": "Rock"}))
		_check("inv.npc-silent", GameLog.get_entries().size() == n0)
		npc.inventory.items.clear()
		for it in nsaved:
			npc.inventory.items.append(it)

func _case_pickup_partial() -> void:
	var picker = game._resolve_pickup_character()
	_check("pickup.picker", picker != null)
	if picker == null:
		return
	var inv = picker.inventory
	var saved: Array = inv.items.duplicate()
	var data: Dictionary = ItemDatabase.get_item_data("alcohol").duplicate(true)
	_check("pickup.alcohol-data", not data.is_empty() and bool(data.get("is_stackable", false)))
	if data.is_empty():
		return
	var cap: int = int(data.get("max_stack_size", 10))
	data["num_stacks"] = cap - 3
	_fill(inv, [data])
	var world = game.create_item("alcohol", picker.global_position, 5)
	# _apply_item_data resets stack_count from the database row, so set it here.
	if world != null:
		world.stack_count = 5
	_check("pickup.world-stack", world != null and world.stack_count == 5, str(world.stack_count if world else -1))
	var n0: int = GameLog.get_entries().size()
	picker._last_notify_text = ""   # notify() drops a repeat within 1 s, log line included
	var ok: bool = game.pick_up_item(world)
	_check("pickup.partial-refused", not ok)
	_check("pickup.merged-into-carried", int(data["num_stacks"]) == cap, str(data["num_stacks"]))
	_check("pickup.remainder-left", is_instance_valid(world) and world.stack_count == 2, str(world.stack_count if is_instance_valid(world) else -1))
	var lines := []
	for e in GameLog.get_entries().slice(n0):
		lines.append(str(e.text))
	_check("pickup.single-full-line", lines.filter(func(t): return t.contains("full")).size() == 1, str(lines))
	if is_instance_valid(world):
		world._destroy_item()
	inv.items.clear()
	for it in saved:
		inv.items.append(it)

func _case_names() -> void:
	for c in game.characters_in_scene:
		if not is_instance_valid(c):
			continue
		if str(c.template_id) == "":
			continue
		if str(c.Name) == "" or str(c.Name) != str(c.display_name):
			_check("name.matches-display " + str(c.display_name), false, "Name '%s'" % c.Name)
			return
	_check("name.template-characters-named", true)
