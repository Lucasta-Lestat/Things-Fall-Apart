# res://tests/foundation_api_test.gd
# Headless assertion harness for the shared query/UI APIs the feature lanes
# build on (docs: the port's foundation notes). Locks down:
#   1. Globals.SIGHT_PX_PER_POINT and format_duration_short.
#   2. FactionDatabase.get_stance agrees with are_hostile over every faction
#      pair, follows player_stance_toward for the player, and shows outlaw
#      marks and standing.
#   3. Condition.create_from_data reads duration_hours.
#   4. UI/ItemTooltip.detail_text reproduces each window's slot tooltip, and
#      its hooks ship empty.
#   5. UI/WorldHoverTooltip provider API and UI/HudStatusBar placement.
#   6. On the real Game: world_tooltip / hud_status hosts, the sight, hostility,
#      stealth and visibility queries, downtime advancing time before its
#      effects, and the party-panel condition countdown.
# Run:  godot --headless --path . res://tests/foundation_api_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

const ItemTooltip = preload("res://UI/ItemTooltip.gd")
const WorldHoverTooltip = preload("res://UI/WorldHoverTooltip.gd")
const HudStatusBar = preload("res://UI/HudStatusBar.gd")

var failures := 0
var game = null

class StubGame:
	extends Node
	var context_menu_open: bool = false

class StubWeapon:
	extends Node2D
	var cost: float = 25.0

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

	_case_globals()
	_case_stance()
	_case_duration_hours()
	_case_item_tooltip()
	await _case_world_tooltip()
	await _case_hud_status_bar()

	# Drive the REAL game scene the way law_persist_test does. Let the initial
	# ready cascade finish first: a node added to root DURING it never gets
	# NOTIFICATION_READY, so Game._ready would never run.
	await get_tree().process_frame
	var GameScene := load("res://game.tscn")
	game = GameScene.instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _await_frames(2)
	game.load_map("town_square")
	await _await_frames(10)

	_case_game_hosts()
	_case_character_queries()
	await _case_stealth_and_sight()
	_case_downtime_order()
	await _case_condition_countdown()

	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

# ---------------------------------------------------------------------------

func _case_globals() -> void:
	_check("globals.sight-px-per-point", is_equal_approx(Globals.SIGHT_PX_PER_POINT, 1440.0))
	var cases := {0.0: "0s", 0.4: "1s", 45.0: "45s", 119.0: "119s", 120.0: "2m",
		3599.0: "59m", 3600.0: "1h 00m", 7500.0: "2h 05m", 86400.0: "24h 00m", -5.0: "0s"}
	for k in cases:
		var got: String = Globals.format_duration_short(k)
		_check("globals.format-duration %s" % str(k), got == cases[k], got)

func _case_stance() -> void:
	var ids: Array = FactionDatabase.get_all_faction_ids().duplicate()
	for extra in ["player", "neutral", "druids"]:   # "druids" is undefined
		if not extra in ids:
			ids.append(extra)
	var bad_hostile := []
	var bad_sym := []
	var bad_rule := []
	for a in ids:
		for b in ids:
			var st: String = FactionDatabase.get_stance(a, b)
			if (st == "hostile") != FactionDatabase.are_hostile(a, b):
				bad_hostile.append("%s/%s" % [a, b])
			if st != FactionDatabase.get_stance(b, a):
				bad_sym.append("%s/%s" % [a, b])
			var want: String
			if a == b:
				want = "ally"
			elif FactionDatabase.are_hostile(a, b):
				want = "hostile"
			elif a == "player" or b == "player":
				var other: String = b if a == "player" else a
				want = "ally" if FactionDatabase.player_stance_toward(other) == "friendly" else "neutral"
			else:
				want = "ally" if FactionDatabase.are_friendly(a, b) else "neutral"
			if st != want:
				bad_rule.append("%s/%s=%s want %s" % [a, b, st, want])
	_check("stance.hostile-iff-are_hostile (%d ids)" % ids.size(), bad_hostile.is_empty(), str(bad_hostile.slice(0, 5)))
	_check("stance.symmetric", bad_sym.is_empty(), str(bad_sym.slice(0, 5)))
	_check("stance.rule", bad_rule.is_empty(), str(bad_rule.slice(0, 5)))
	_check("stance.same-faction-ally", FactionDatabase.get_stance("player", "player") == "ally")
	_check("stance.unknown-neutral", FactionDatabase.get_stance("druids", "spider_party") == "neutral")

	# Standing and outlaw marks show through, then everything is put back.
	var saved: Dictionary = FactionDatabase.standing_to_dict()
	var target := ""
	for f in FactionDatabase.get_all_faction_ids():
		if f != "player" and FactionDatabase.get_stance("player", f) == "neutral" \
				and not FactionDatabase._hostile_by_default(f):
			target = f
			break
	_check("stance.found-neutral-faction", target != "")
	if target != "":
		FactionDatabase.adjust_player_standing(target, 80)
		_check("stance.standing-friendly-is-ally", FactionDatabase.get_stance("player", target) == "ally",
			FactionDatabase.get_stance("player", target))
		FactionDatabase.mark_outlaw(target)
		_check("stance.outlaw-is-hostile", FactionDatabase.get_stance(target, "player") == "hostile")
	FactionDatabase.standing_from_dict(saved)
	if target != "":
		_check("stance.restored", FactionDatabase.get_stance("player", target) == "neutral")

func _case_duration_hours() -> void:
	_check("condition.duration_hours", is_equal_approx(Condition.create_from_data({"id": "t_h", "duration_hours": 6, "traits": {}}).duration, 21600.0))
	_check("condition.duration-still-read", is_equal_approx(Condition.create_from_data({"id": "t_s", "duration": 30.0, "traits": {}}).duration, 30.0))
	_check("condition.hours-win", is_equal_approx(Condition.create_from_data({"id": "t_b", "duration": 30.0, "duration_hours": 0.5, "traits": {}}).duration, 1800.0))
	_check("condition.no-duration-permanent", Condition.create_from_data({"id": "t_n", "traits": {}}).duration < 0.0)

# The four windows' tooltip formulas before ItemTooltip, verbatim.
func _old_cost(entry: Dictionary) -> float:
	if entry.get("kind", "") == "weapon":
		var w = entry.get("raw")
		if w != null and "cost" in w:
			return float(w.cost)
		return 0.0
	var raw = entry.get("raw", {})
	if raw is Dictionary:
		var stacks_val = raw.get("num_stacks", 1)
		var stacks: int = int(stacks_val) if stacks_val != null else 1
		return float(raw.get("cost", 0.0)) * max(stacks, 1)
	return 0.0

func _case_item_tooltip() -> void:
	var weapon := StubWeapon.new()
	var entries := [
		{"kind": "item", "display_name": "Potion", "num_stacks": 3, "raw": {"id": "potion", "cost": 12, "num_stacks": 3}},
		{"kind": "item", "display_name": "Rock", "num_stacks": 1, "raw": {"id": "rock", "cost": 0}},
		{"kind": "item", "display_name": "cape", "num_stacks": 1, "raw": {"id": "cape", "cost": 7.4, "num_stacks": null}},
		{"kind": "weapon", "display_name": "Longsword", "num_stacks": 1, "raw": weapon},
		{"kind": "weapon", "display_name": "Chest Sword", "num_stacks": 1, "raw": {"cost": 9, "equip_slot": "Main Hand"}},
		{"kind": "ability", "display_name": "Fire Bolt", "raw": null},
		{"kind": "item", "num_stacks": 1, "raw": {"id": "nameless"}},
	]
	for e in entries:
		var nm: String = str(e.get("display_name", "<none>"))
		var party: String = ItemTooltip.detail_text(e)
		var chest: String = ItemTooltip.detail_text(e, "chest")
		_check("tooltip.party " + nm, party == str(e.get("display_name", "Unknown")), party)
		_check("tooltip.chest " + nm, chest == str(e.get("display_name", "Unknown")), chest)
		if e.kind == "ability":
			continue
		var trade: String = ItemTooltip.detail_text(e, "trade")
		var service: String = ItemTooltip.detail_text(e, "service")
		var want_trade: String = "%s (%.0f gold)" % [e.get("display_name", "Unknown"), _old_cost(e)]
		var want_service: String = "%s (%.0f gold)" % [e.get("display_name", "?"), _old_cost(e)]
		_check("tooltip.trade " + nm, trade == want_trade, "%s vs %s" % [trade, want_trade])
		_check("tooltip.service " + nm, service == want_service, "%s vs %s" % [service, want_service])
	_check("tooltip.hooks-empty", ItemTooltip.armour_lines(entries[0]).is_empty() \
		and ItemTooltip.noise_lines(entries[0]).is_empty() and ItemTooltip.effect_lines(entries[0]).is_empty())
	weapon.free()

func _case_world_tooltip() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var tip = WorldHoverTooltip.new()
	layer.add_child(tip)
	await get_tree().process_frame
	_check("hover.always-and-ignore", tip.process_mode == Node.PROCESS_MODE_ALWAYS and tip.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	var all_ignore := true
	for c in tip.get_children():
		if c is Control and c.mouse_filter != Control.MOUSE_FILTER_IGNORE:
			all_ignore = false
	_check("hover.children-ignore", all_ignore)
	_check("hover.hidden-without-providers", not tip.visible)
	tip.add_provider("empty", func(_p): return "", false, 5)
	tip.add_provider("b", func(_p): return "B", false, 1)
	tip.add_provider("paused", func(_p): return "P", true, 10)
	tip.add_provider("d", func(_p): return "D", false, 1)
	_check("hover.first-non-empty-wins", tip._query(Vector2.ZERO) == "B", tip._query(Vector2.ZERO))
	PauseManager.is_paused = true
	_check("hover.paused-only-while-paused", tip._query(Vector2.ZERO) == "P")
	PauseManager.is_paused = false
	tip.remove_provider("b")
	_check("hover.remove-provider-and-tie-order", tip._query(Vector2.ZERO) == "D", tip._query(Vector2.ZERO))
	var got := [null]
	tip.add_provider("pos", func(p): got[0] = p; return "", false, 99)
	tip._query(Vector2(12, 34))
	_check("hover.provider-gets-world-pos", got[0] == Vector2(12, 34))
	tip.remove_provider("pos")
	tip.add_provider("b", func(_p): return "B", false, 1)
	_check("hover.replace-by-id", tip._providers.size() == 4)
	var stub := StubGame.new()
	add_child(stub)
	tip._game = stub
	stub.context_menu_open = true
	_check("hover.blocked-by-context-menu", tip._blocked())
	stub.context_menu_open = false
	_check("hover.not-blocked-over-world", not tip._blocked())
	tip._set_text("Short")
	await get_tree().process_frame
	var short_w: float = tip.size.x
	tip._set_text("A very long hover text that keeps on going well past the maximum width so that it has to wrap onto several lines instead of running off.")
	await get_tree().process_frame
	_check("hover.long-text-wraps", tip._label.autowrap_mode != TextServer.AUTOWRAP_OFF and tip.size.x <= 320.0 + 20.0, str(tip.size))
	_check("hover.short-text-narrow", short_w < 120.0, str(short_w))
	tip._game = null
	layer.queue_free()
	stub.queue_free()

func _case_hud_status_bar() -> void:
	var host := Control.new()
	host.size = Vector2(1900, 1080)
	add_child(host)
	var clock := Label.new()
	clock.name = "TimeLabel"
	clock.position = Vector2(16, 16)
	clock.size = Vector2(200, 46)
	host.add_child(clock)
	var services := PanelContainer.new()
	services.name = "TownServicesPanel"
	services.position = Vector2(0, 64)
	services.size = Vector2(250, 900)
	services.visible = false
	host.add_child(services)
	var bar = HudStatusBar.new()
	host.add_child(bar)
	await get_tree().process_frame
	_check("hud.under-clock", is_equal_approx(bar.offset_top, 66.0) and is_equal_approx(bar.offset_left, 16.0),
		"%s,%s" % [bar.offset_left, bar.offset_top])
	var stop_w := Panel.new()
	stop_w.custom_minimum_size = Vector2(40, 20)
	var pass_w := Panel.new()
	pass_w.mouse_filter = Control.MOUSE_FILTER_PASS
	bar.add_widget(stop_w)
	bar.add_widget(pass_w)
	_check("hud.add-widget-ignores-stop", stop_w.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	_check("hud.add-widget-keeps-pass", pass_w.mouse_filter == Control.MOUSE_FILTER_PASS)
	_check("hud.bar-ignore-always", bar.mouse_filter == Control.MOUSE_FILTER_IGNORE and bar.process_mode == Node.PROCESS_MODE_ALWAYS)
	_check("hud.widgets-in-order", bar.get_child(0) == stop_w and bar.get_child(1) == pass_w)
	services.visible = true
	await get_tree().process_frame
	_check("hud.steps-beside-open-services-panel", is_equal_approx(bar.offset_left, 258.0), str(bar.offset_left))
	services.position.x = -250.0   # slid out (Tab)
	await get_tree().process_frame
	_check("hud.back-when-panel-slides-out", is_equal_approx(bar.offset_left, 16.0), str(bar.offset_left))
	host.queue_free()

# ---------------------------------------------------------------------------

func _case_game_hosts() -> void:
	var ui: Node = game.get_node("GameUI")
	_check("game.world_tooltip-under-GameUI", game.world_tooltip != null and game.world_tooltip.get_parent() == ui)
	_check("game.hud_status-under-GameUI", game.hud_status != null and game.hud_status.get_parent() == ui)
	_check("game.world_tooltip-ships-empty", game.world_tooltip._providers.is_empty())
	# The stealth lane registers the STEALTH badge at boot.
	_check("game.hud_status-has-stealth-badge", game.hud_status.get_node_or_null("StealthBadge") != null)
	_check("game.hud_status-ignore", game.hud_status.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	var tl: Control = ui.get_node("TimeLabel")
	_check("game.hud_status-below-clock", is_equal_approx(game.hud_status.offset_top, tl.position.y + tl.size.y + 4.0),
		"%s vs clock %s+%s" % [game.hud_status.offset_top, tl.position.y, tl.size.y])
	# The vision lane fills it in: weather (visibility_modifier) x fog, never above 1.
	var sm: float = game.get_sight_multiplier_at(Vector2(100, 100))
	_check("game.sight-multiplier-weather-x-fog", is_equal_approx(sm, game.get_weather_visibility_mult() * game.get_fog_sight_mult_at(Vector2(100, 100))) and sm > 0.0 and sm <= 1.0, str(sm))
	_check("game.seen-null-false", not game.is_seen_by_party(null))

func _case_character_queries() -> void:
	var party: Array = game.party_chars
	_check("chars.party-present", party.size() > 0, str(party.size()))
	var npcs := []
	for c in game.characters_in_scene:
		if is_instance_valid(c) and not c in party:
			npcs.append(c)
	_check("chars.npcs-present", npcs.size() > 0, str(npcs.size()))
	for p in party:
		_check("chars.party-seen " + str(p.Name), game.is_seen_by_party(p))
	var mismatch := 0
	for n in npcs:
		if game.is_seen_by_party(n) != bool(game._npc_was_truly_seen.get(n, false)):
			mismatch += 1
	_check("chars.seen-matches-los-pass", mismatch == 0, str(mismatch))
	# Hostility: exactly the oracle, for every pair in the scene.
	var everyone: Array = party + npcs
	var bad := []
	for a in everyone:
		if a.is_hostile_to_party() != FactionDatabase.are_hostile("player", a.faction_id):
			bad.append("party/%s" % a.Name)
		for b in everyone:
			if a == b:
				continue
			if a.is_hostile_to(b) != FactionDatabase.are_hostile(a.faction_id, b.faction_id):
				bad.append("%s/%s" % [a.Name, b.Name])
	_check("chars.hostility-is-the-oracle", bad.is_empty(), str(bad.slice(0, 5)))
	var p0 = party[0]
	_check("chars.hostile-null-self-false", not p0.is_hostile_to(null) and not p0.is_hostile_to(p0))
	_check("chars.hostile-to-factionless-node-false", not p0.is_hostile_to(self))
	var saved: String = npcs[0].faction_id
	npcs[0].faction_id = "bandits"
	_check("chars.bandits-hostile-both-ways", p0.is_hostile_to(npcs[0]) == FactionDatabase.are_hostile(p0.faction_id, "bandits") \
		and npcs[0].is_hostile_to_party() == FactionDatabase.are_hostile("player", "bandits"))
	npcs[0].faction_id = saved
	for c in everyone:
		if not is_equal_approx(c.effective_visibility(), 1.0):
			_check("chars.visibility-baseline " + str(c.Name), false, str(c.effective_visibility()))

func _case_stealth_and_sight() -> void:
	var party: Array = game.party_chars
	var p0 = party[0]
	var npc = null
	for c in game.characters_in_scene:
		if is_instance_valid(c) and not c in party:
			npc = c
			break
	var was: bool = game.stealth_mode
	game.stealth_mode = false
	_check("stealth.off-nobody-sneaks", not p0.is_sneaking() and not npc.is_sneaking())
	game.stealth_mode = true
	var ai_node = npc.get_node_or_null("AI")
	_check("stealth.on-party-sneaks", p0.is_sneaking())
	_check("stealth.on-npc-doesnt", not npc.is_sneaking())
	if ai_node != null:
		_check("stealth.matches-ai", ai_node._is_sneaking(p0) == p0.is_sneaking())
	game.stealth_mode = was

	for p in party:
		# 1440 x the sight stat with its condition modifiers (Perceptive x1.2)
		# x the environment at the viewer (weather, fog).
		var want: float = 1440.0 * maxf(0.0, p.condition_manager.calculate_effective_stat(p.sight, "sight")) 			* game.get_sight_multiplier_at(p.global_position)
		_check("sight.range-1440x-sight " + str(p.Name), is_equal_approx(p.get_sight_range_px(), want),
			"%s vs sight %s (want %s)" % [p.get_sight_range_px(), p.sight, want])
	var cm = p0.condition_manager
	var inst = cm.apply_condition("blinded", null, 1, 60.0)
	if inst != null:
		_check("sight.blinded-zero", is_equal_approx(p0.get_sight_range_px(), 0.0), str(p0.get_sight_range_px()))
		cm.remove_condition("blinded")
		await get_tree().process_frame
		_check("sight.restored", p0.get_sight_range_px() > 0.0)
	else:
		print("SKIP sight.blinded-zero (blinded resisted)")

func _case_downtime_order() -> void:
	var p0 = game.party_chars[0]
	var cm = p0.condition_manager
	cm.register_condition(Condition.create_from_data({"id": "test_downtime_hours", "display_name": "dt",
		"duration_hours": 2, "traits": {}}))
	var t0: float = TimeManager.absolute_time()
	DowntimeResolver._pending = {
		"character": p0,
		"activity": {"duration_hours": 8},
		"activity_id": "test_activity",
		"pending_effects": {"add_condition": "test_downtime_hours"},
		"pending_success_tier": 1,
	}
	DowntimeResolver._finish_resolution()
	var inst = cm.conditions.get("test_downtime_hours")
	_check("downtime.time-advanced", is_equal_approx(TimeManager.absolute_time(), t0 + 8.0 * 3600.0),
		"%s -> %s" % [t0, TimeManager.absolute_time()])
	_check("downtime.condition-applied", inst != null)
	if inst != null:
		# Stamped after the skip. (DowntimeEffectApplier passes duration
		# override -1, which apply_condition reads as permanent, so expiry is
		# either -1 or the full two hours from the end of the activity.)
		_check("downtime.effect-starts-after-the-skip", is_equal_approx(inst.applied_at, t0 + 8.0 * 3600.0),
			"applied %s, want %s" % [inst.applied_at, t0 + 8.0 * 3600.0])
		_check("downtime.expiry-not-eaten-by-the-skip", inst.expires_at < 0.0 or is_equal_approx(inst.expires_at, t0 + 10.0 * 3600.0),
			"expires %s" % inst.expires_at)
		cm.remove_condition("test_downtime_hours")
	game.downtime_day_assignments.clear()

func _case_condition_countdown() -> void:
	var psp = game.get_node("GameUI/PartySidePanel")
	var p0 = game.party_chars[0]
	var cm = p0.condition_manager
	cm.register_condition(Condition.create_from_data({"id": "test_countdown", "display_name": "Countdown",
		"duration": 7500.0, "traits": {}}))
	var inst = cm.apply_condition("test_countdown")
	_check("countdown.applied", inst != null)
	await _await_frames(3)
	var tips := []
	for pd in psp._character_panels:
		if pd["character"] != p0:
			continue
		for icon in pd["condition_container"].get_children():
			tips.append(str(icon.tooltip_text))
	_check("countdown.hours-format", tips.any(func(t): return t.contains("Countdown (2h 05m)")), str(tips))
	cm.remove_condition("test_countdown")
