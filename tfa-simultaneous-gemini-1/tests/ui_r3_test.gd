# res://tests/ui_r3_test.gd
# Headless assertion harness for the round-3 UI answers:
#   A. the PAUSED banner no longer says "planning";
#   B. the Town Services panel stays hidden until a service in the town is
#      discovered, and the first discovery reveals it with a notice;
#   C. the game log is closed by default, opens with its button or L, counts
#      unread entries while closed, and sits on the shared gold frame;
#   D. the wind readout sits beside the clock and the downtime button, in the
#      clock's font;
#   E. the right-click menu offers Attack on peaceful NPCs, names the crime,
#      and asks again before a severe one (as a severe cast does).
# Drives the real game scene the way feedback_layer_test does.
# Run:  godot --headless --path . res://tests/ui_r3_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const GoldFrame := preload("res://UI/GoldFrame.gd")

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

	_case_pause_banner()
	await _case_log_panel()
	await _case_wind()
	await _case_attack_menu()
	await _case_services_panel()

	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _log_size() -> int:
	return GameLog.get_entries().size()

func _lines_since(n0: int) -> Array:
	var out := []
	for e in GameLog.get_entries().slice(n0):
		out.append(str(e.text))
	return out

func _npc_by_template(template_id: String):
	for c in game.characters_in_scene:
		if is_instance_valid(c) and not c in game.party_chars and c.is_alive() \
				and str(c.get_meta("template_id", "")) == template_id:
			return c
	return null

func _peaceful_npc():
	for c in game.characters_in_scene:
		if is_instance_valid(c) and not c in game.party_chars and c.is_alive() \
				and not FactionDatabase.are_hostile("player", c.faction_id):
			return c
	return null

func _spawn_temp(faction: String) -> ProceduralCharacter:
	var pc: ProceduralCharacter = PC_SCENE.instantiate()
	add_child(pc)
	pc.global_position = Vector2(-20000, -20000)
	pc.Name = "Harness Victim"
	pc.AI_enabled = false
	pc.faction_id = faction
	return pc

func _menu(target, actor) -> Node:
	game.show_context_menu(target, Vector2(100, 100), actor)
	var ui: Node = game.get_node("GameUI")
	for i in range(ui.get_child_count() - 1, -1, -1):
		var c = ui.get_child(i)
		if c.get_script() != null and str(c.get_script().resource_path).ends_with("context_menu.gd") \
				and not c.is_queued_for_deletion():
			return c
	return null

func _menu_buttons(menu) -> Array:
	var out := []
	if menu == null:
		return out
	for b in menu.vbox.get_children():
		if b is Button and not b.is_queued_for_deletion():
			out.append(b)
	return out

func _close_menu(menu) -> void:
	if menu != null:
		menu.queue_free()
	game.context_menu_open = false

func _clear_party_queues() -> void:
	for c in game.party_chars:
		if is_instance_valid(c) and c.action_queue:
			c.action_queue.clear_queue()

# ---------------------------------------------------------------------------
# A. Pause banner
# ---------------------------------------------------------------------------

func _case_pause_banner() -> void:
	_check("banner.no-planning", not PauseManager.BANNER_PLANNING.to_lower().contains("planning"), PauseManager.BANNER_PLANNING)
	PauseManager.pause()
	_check("banner.paused-and-resume-hint", PauseManager._indicator.text == "PAUSED  ·  Space to resume", PauseManager._indicator.text)
	PauseManager.unpause()

# ---------------------------------------------------------------------------
# C. Game log: closed by default, button + L, unread count, gold frame
# ---------------------------------------------------------------------------

func _key(keycode: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.physical_keycode = keycode
	ev.pressed = true
	return ev

func _case_log_panel() -> void:
	var ui: Node = game.get_node("GameUI")
	var panel = ui.get_node_or_null("LogPanel")
	_check("log.panel", panel != null)
	if panel == null:
		return
	var btn: Button = ui.get_node_or_null("LogButton")
	_check("log.button-in-hud", btn != null and btn == panel.toggle_button)
	if btn == null:
		return
	_check("log.closed-by-default", not panel.visible and not panel.is_open())
	_check("log.button-shown", btn.visible)
	_check("log.button-takes-clicks", btn.mouse_filter == Control.MOUSE_FILTER_STOP)
	_check("log.button-never-focused", btn.focus_mode == Control.FOCUS_NONE)
	_check("log.button-says-hotkey", btn.tooltip_text.contains("(L)"), btn.tooltip_text)
	_check("log.panel-click-through", panel.mouse_filter == Control.MOUSE_FILTER_IGNORE \
		and panel.scroll_container.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	_check("log.scrollbar-takes-mouse", panel.scroll_container.get_v_scroll_bar().mouse_filter != Control.MOUSE_FILTER_IGNORE)
	_check("log.button-beside-log", is_equal_approx(btn.offset_right, panel.offset_right) and btn.offset_top > panel.offset_bottom,
		"btn %s..%s log bottom %s" % [btn.offset_top, btn.offset_right, panel.offset_bottom])

	# The same gold frame as the Town Services panel, not the old paper.
	var tsp: Control = ui.get_node("TownServicesPanel")
	var log_box = panel.get_theme_stylebox("panel")
	var tsp_box = tsp.get_theme_stylebox("panel")
	_check("log.gold-frame", log_box is StyleBoxFlat and tsp_box is StyleBoxFlat \
		and log_box.border_color == tsp_box.border_color and log_box.bg_color == tsp_box.bg_color \
		and log_box.border_width_left == tsp_box.border_width_left and log_box.border_color == GoldFrame.BORDER_COLOR,
		"%s / %s" % [log_box, tsp_box])
	var btn_box = btn.get_theme_stylebox("normal")
	_check("log.button-gold-frame", btn_box is StyleBoxFlat and btn_box.border_color == GoldFrame.BORDER_COLOR)

	# Plain L is free in the InputMap (Godot's own ui_* text actions use
	# Ctrl+L / Ctrl+Shift+L, which the log ignores).
	var l_bound := []
	for action in InputMap.get_actions():
		for ev in InputMap.action_get_events(action):
			if ev is InputEventKey and (ev.keycode == KEY_L or ev.physical_keycode == KEY_L) \
					and not (ev.ctrl_pressed or ev.alt_pressed or ev.meta_pressed or ev.command_or_control_autoremap):
				l_bound.append(action)
	_check("log.L-unbound-elsewhere", l_bound.is_empty(), str(l_bound))
	var ctrl_l := _key(KEY_L)
	ctrl_l.ctrl_pressed = true
	panel._input(ctrl_l)
	_check("log.ctrl-L-not-the-hotkey", not panel.is_open())

	# Unread count while closed.
	panel.unread_count = 0
	panel._update_button()
	GameLog.add_entry("R3 harness: first unseen line.")
	GameLog.add_entry("R3 harness: second unseen line.")
	await get_tree().process_frame
	_check("log.unread-counts", panel.unread_count == 2, str(panel.unread_count))
	_check("log.unread-badge", panel.unread_badge.visible and panel.unread_badge.text == "2", "%s '%s'" % [panel.unread_badge.visible, panel.unread_badge.text])
	_check("log.unread-in-tooltip", btn.tooltip_text.contains("2 new entries"), btn.tooltip_text)
	GameLog.add_entry("R3 harness: second unseen line.")   # a repeat folds into its line
	_check("log.repeat-not-unread", panel.unread_count == 2, str(panel.unread_count))

	# L opens it (through the real input pipeline) and marks everything read.
	Input.parse_input_event(_key(KEY_L))
	await _await_frames(2)
	_check("log.L-opens", panel.visible and panel.is_open())
	_check("log.open-clears-unread", panel.unread_count == 0 and not panel.unread_badge.visible)
	_check("log.button-shows-open", btn.button_pressed)
	GameLog.add_entry("R3 harness: seen line.")
	_check("log.open-no-unread", panel.unread_count == 0)

	# The button closes it again.
	btn.button_pressed = false
	_check("log.button-closes", not panel.visible and not panel.is_open())
	btn.button_pressed = true
	_check("log.button-opens", panel.visible and panel.is_open())

	# Typing L into a text field is not the hotkey.
	var field := LineEdit.new()
	ui.add_child(field)
	field.grab_focus()
	await get_tree().process_frame
	Input.parse_input_event(_key(KEY_L))
	await _await_frames(2)
	_check("log.L-ignored-while-typing", panel.is_open())
	field.queue_free()
	await get_tree().process_frame

	# Tab hides the button with the rest of the HUD; the log stays as left.
	var psp = ui.get_node("PartySidePanel")
	psp._toggle_panel()
	_check("log.tab-hides-button", not btn.visible and panel.visible)
	psp._toggle_panel()
	_check("log.tab-shows-button", btn.visible)

	Input.parse_input_event(_key(KEY_L))
	await _await_frames(2)
	_check("log.L-closes", not panel.visible and not panel.is_open())

# ---------------------------------------------------------------------------
# D. Wind beside the clock and the downtime (moon) button
# ---------------------------------------------------------------------------

func _case_wind() -> void:
	var ui: Node = game.get_node("GameUI")
	var wind = ui.get_node_or_null("WindIndicator")
	_check("wind.in-clock-cluster", wind != null)
	_check("wind.not-on-status-strip", game.hud_status.get_node_or_null("WindIndicator") == null)
	if wind == null:
		return
	var clock: Control = ui.get_node("TimeLabel")
	var moon: Control = ui.get_node("MoonToggleButton")
	var wgrp: String = WeatherManager.current_weather.keys()[0] if not WeatherManager.current_weather.is_empty() else ""
	if wgrp == "":
		print("SKIP wind placement (no weather group rolled)")
		return
	var had_group: bool = game.current_map_data.has("weather_group")
	var old_group = game.current_map_data.get("weather_group")
	var old_speed: float = WeatherManager.get_wind_speed(wgrp)
	var old_angle: float = WeatherManager.get_wind_angle(wgrp)
	game.current_map_data["weather_group"] = wgrp
	WeatherManager.set_wind_speed(wgrp, 25.0)
	WeatherManager.set_wind_angle(wgrp, 225.0)
	wind.refresh()
	await _await_frames(3)
	_check("wind.shown", wind.visible and wind._label.text == "Moderate wind toward NW", wind._label.text)
	var clock_rect: Rect2 = clock.get_rect()
	var moon_rect: Rect2 = moon.get_rect()
	_check("wind.right-of-moon", moon.visible and is_equal_approx(wind.offset_left, moon_rect.end.x + 8.0),
		"wind %s moon end %s" % [wind.offset_left, moon_rect.end.x])
	var wind_mid: float = wind.offset_top + wind.size.y * 0.5
	var clock_mid: float = clock_rect.position.y + clock_rect.size.y * 0.5
	_check("wind.centred-on-clock", absf(wind_mid - clock_mid) <= 1.0, "%s vs %s" % [wind_mid, clock_mid])
	_check("wind.above-side-panels", wind.offset_top + wind.size.y <= 64.0, str(wind.offset_top + wind.size.y))
	var lbl: Label = wind._label
	_check("wind.clock-font-size", not lbl.has_theme_font_size_override("font_size") \
		and lbl.get_theme_font_size("font_size") == clock.get_theme_font_size("font_size"),
		"%d vs %d" % [lbl.get_theme_font_size("font_size"), clock.get_theme_font_size("font_size")])
	_check("wind.clock-font", lbl.get_theme_font("font") == clock.get_theme_font("font"))
	_check("wind.clock-styling", not lbl.has_theme_constant_override("outline_size") and not lbl.has_theme_color_override("font_color"))
	_check("wind.keeps-tooltip", wind.mouse_filter == Control.MOUSE_FILTER_PASS and wind.tooltip_text.contains("Wind 25"), wind.tooltip_text)
	_check("wind.covers-label", wind.size.x >= lbl.position.x + lbl.size.x, "%s %s %s" % [wind.size, lbl.position, lbl.size])

	# Tab hides the clock and moon; the wind stays and takes the clock's spot.
	var psp = ui.get_node("PartySidePanel")
	psp._toggle_panel()
	await _await_frames(2)
	_check("wind.stays-on-tab", wind.visible and not clock.visible and not moon.visible)
	_check("wind.takes-clock-spot", is_equal_approx(wind.offset_left, 16.0), str(wind.offset_left))
	psp._toggle_panel()
	await _await_frames(2)
	_check("wind.back-beside-moon", is_equal_approx(wind.offset_left, moon.get_rect().end.x + 8.0), str(wind.offset_left))

	WeatherManager.set_wind_speed(wgrp, old_speed)
	WeatherManager.set_wind_angle(wgrp, old_angle)
	if had_group:
		game.current_map_data["weather_group"] = old_group
	else:
		game.current_map_data.erase("weather_group")
	wind.refresh()

# ---------------------------------------------------------------------------
# E. Right-click Attack on a peaceful NPC
# ---------------------------------------------------------------------------

func _case_attack_menu() -> void:
	var p0 = game.party_chars[0]
	var npc = _peaceful_npc()
	if npc == null or p0.action_queue == null:
		_check("attack.fixtures", false)
		return

	# Offered on a peaceful NPC, last (never the first thing under the cursor).
	var menu = _menu(npc, p0)
	var buttons: Array = _menu_buttons(menu)
	var texts: Array = buttons.map(func(b): return str(b.text))
	_check("attack.offered-on-peaceful", texts.size() > 0 and str(texts[-1]).begins_with("Attack"), str(texts))
	# Perrow (Liziti custom) repealed assault: no crime, plain "Attack".
	_check("attack.legal-here-plain", texts.has("Attack"), str(texts))
	if not buttons.is_empty():
		_check("attack.legal-tooltip", str(buttons[-1].tooltip_text).contains("Not a crime here"), str(buttons[-1].tooltip_text))
	_close_menu(menu)
	# Never on a companion.
	menu = _menu(game.party_chars[1] if game.party_chars.size() > 1 else p0, p0)
	texts = _menu_buttons(menu).map(func(b): return str(b.text))
	_check("attack.not-on-companion", not texts.any(func(t): return str(t).begins_with("Attack")), str(texts))
	_close_menu(menu)
	await get_tree().process_frame

	# Severe crime (Martial Law: Assault 55 >= the confirm threshold 50):
	# named on the menu, refused once with the reason, then confirmed.
	var victim := _spawn_temp("golden_guard")
	var saved_map: String = str(game.current_map_id)
	MapDatabase._maps["__r3_martial"] = {"id": "__r3_martial", "controlling_faction": "golden_guard"}
	game.current_map_id = "__r3_martial"
	CrimeManager._pending_attack_confirms.clear()
	CrimeManager._confirmed_attack_maps.clear()
	menu = _menu(victim, p0)
	buttons = _menu_buttons(menu)
	texts = buttons.map(func(b): return str(b.text))
	_check("attack.names-crime", texts.has("Attack (Assault)"), str(texts))
	var atk_btn: Button = null
	for b in buttons:
		if str(b.text).begins_with("Attack"):
			atk_btn = b
	if atk_btn != null:
		_check("attack.crime-tooltip", atk_btn.tooltip_text.contains("Golden Guard") and atk_btn.tooltip_text.contains("severity 55"), atk_btn.tooltip_text)
	_check("attack.option-still-matches", menu != null and menu.has_method("_order_attack"))

	var sel_saved: Array = game.selected_characters.duplicate()
	var prim_saved = game.primary_selected
	game.selected_characters.clear()
	game.selected_characters.append(p0)
	game.primary_selected = p0
	_clear_party_queues()
	PauseManager.is_paused = true
	p0._last_notify_text = ""
	var n0 := _log_size()
	menu._order_attack(victim)
	_check("attack.severe-refused-once", p0.action_queue.queue.is_empty(), str(p0.action_queue.queue.size()))
	var lines: Array = _lines_since(n0)
	var want := "Attacking Harness Victim here is Assault — a crime under the law of Golden Guard (severity 55). Choose Attack on them again if you mean to break the law."
	_check("attack.severe-says-why", lines.has(want), str(lines))
	_check("attack.severe-floats", p0._last_notify_text == "Illegal here: Assault", p0._last_notify_text)
	menu._order_attack(victim)
	var q: Array = p0.action_queue.queue
	_check("attack.choose-again-confirms", q.size() == 1 and q[0].data.get("target") == victim, str(q.size()))
	_clear_party_queues()
	menu._order_attack(victim)
	_check("attack.confirmation-holds-on-map", p0.action_queue.queue.size() == 1)
	_clear_party_queues()
	_close_menu(menu)

	# Below the threshold (Patrician law: Assault 40): named, but no prompt.
	MapDatabase._maps["__r3_patrician"] = {"id": "__r3_patrician", "controlling_faction": "patriciate"}
	game.current_map_id = "__r3_patrician"
	victim.faction_id = "patriciate"
	menu = _menu(victim, p0)
	texts = _menu_buttons(menu).map(func(b): return str(b.text))
	_check("attack.minor-crime-named", texts.has("Attack (Assault)"), str(texts))
	menu._order_attack(victim)
	_check("attack.minor-crime-no-prompt", p0.action_queue.queue.size() == 1)
	_clear_party_queues()

	# Everyone selected takes the order, as a left-click on a hostile does.
	if game.party_chars.size() > 1 and is_instance_valid(game.party_chars[1]) and game.party_chars[1].action_queue:
		var p1 = game.party_chars[1]
		game.selected_characters.append(p1)
		menu._order_attack(victim)
		_check("attack.all-selected-attack", p0.action_queue.queue.size() == 1 and p1.action_queue.queue.size() == 1,
			"%d %d" % [p0.action_queue.queue.size(), p1.action_queue.queue.size()])
		_clear_party_queues()
	_close_menu(menu)
	PauseManager.is_paused = false

	game.selected_characters.clear()
	for c in sel_saved:
		game.selected_characters.append(c)
	game.primary_selected = prim_saved
	game.current_map_id = saved_map
	MapDatabase._maps.erase("__r3_martial")
	MapDatabase._maps.erase("__r3_patrician")
	CrimeManager._pending_attack_confirms.clear()
	CrimeManager._confirmed_attack_maps.clear()
	victim.queue_free()
	await get_tree().process_frame

# ---------------------------------------------------------------------------
# B. Town Services: hidden until a service is discovered
# ---------------------------------------------------------------------------

func _case_services_panel() -> void:
	var ui: Node = game.get_node("GameUI")
	var panel = ui.get_node_or_null("TownServicesPanel")
	var log_panel = ui.get_node_or_null("LogPanel")
	var smith = _npc_by_template("smith_darcy")
	_check("svc.fixtures", panel != null and smith != null)
	if panel == null or smith == null:
		return
	var region_id: String = RegionDatabase.get_region_for_map(game.current_map_id)
	var uid: String = game._build_npc_uid(str(smith.get_meta("template_id", "")), str(smith.get_meta("unique_name", "")))
	panel.mode = "services"

	# Nothing discovered here: no panel at all.
	game.known_services_per_region[region_id] = []
	panel._repopulate()
	_check("svc.hidden-until-discovered", not panel.visible and panel._cards.is_empty())

	# The first discovery reveals it, with a notice over the NPC and in the log.
	if log_panel:
		log_panel.set_open(false)
		log_panel.unread_count = 0
	smith._last_notify_text = ""
	var n0 := _log_size()
	game.mark_service_seen(smith)
	await _await_frames(2)
	_check("svc.first-discovery-shows", panel.visible and panel._cards.size() >= 1)
	_check("svc.header-names-town", panel.header_label.text.ends_with("— Services"), panel.header_label.text)
	var title: String = ""
	for e in RegionDatabase.get_service_npcs_in_region(region_id):
		if e["npc_uid"] == uid:
			title = str(e["titles"][0])
	var lines: Array = _lines_since(n0)
	var announced := false
	for l in lines:
		if str(l).begins_with("New service discovered: %s" % title) and str(l).ends_with("It is listed under Town Services."):
			announced = true
	_check("svc.discovery-logged", announced, str(lines))
	_check("svc.discovery-floats", smith._last_notify_text == "New service: " + title, smith._last_notify_text)
	if log_panel:
		_check("svc.discovery-counts-unread", log_panel.unread_count >= 1, str(log_panel.unread_count))

	# Seen again: no second notice.
	n0 = _log_size()
	game.mark_service_seen(smith)
	await _await_frames(2)
	_check("svc.announced-once", not _lines_since(n0).any(func(l): return str(l).begins_with("New service discovered")), str(_lines_since(n0)))

	# Downtime keeps its board regardless; back to services, hidden again
	# when nothing is known.
	game.known_services_per_region[region_id] = []
	panel._repopulate()
	game.set_downtime_mode(true)
	_check("svc.downtime-board-shows", panel.visible and panel.mode == "downtime")
	game.set_downtime_mode(false)
	_check("svc.back-to-services-hidden", not panel.visible, "%s cards %d" % [panel.visible, panel._cards.size()])

	# A save load (apply + map load) re-checks: known services show the panel.
	var d: Dictionary = game.build_save_dict()
	d["known_services"] = {region_id: [uid]}
	game.load_save(d)
	await _await_frames(12)
	var listed := false
	for card in panel._cards:
		if card.get("entry", {}).get("npc_uid", "") == uid:
			listed = true
	_check("svc.load-reevaluates", panel.visible and listed, "%s %s" % [panel.visible, listed])
	_check("svc.visible-iff-listed", panel.visible == not panel._cards.is_empty())
