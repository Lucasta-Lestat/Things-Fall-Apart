# res://tests/game_controller_test.gd
# Headless assertion harness for the Game.gd controller fixes ported from the
# player-feedback work. Drives the real game scene and locks down:
#   1. P with no player doesn't throw; the debug hotkeys stay live in debug runs.
#   2. A warp to a map that can't load says "Way closed" instead of nothing.
#   3. Party members get no "Trade" in the context menu; other non-hostiles do.
#   4. C logs what stealth mode does, and NPC cones spawned later follow it.
#   5. Pick Up logs, plays a real SFX key, leaves no salvage, and can't double-take;
#      armour (Items.json num_stacks null) picks up too.
#   6. G gathers the database waterskin (sprite, Consume), with no ownership.
#   7. Bide's payoff floats "Bide +N!" and logs it.
#   8. A party shot that runs out of range floats "Max range".
#   9. A selected swinger's cross-level melee says "Out of reach" once, which
#      replaces the generic whiff line.
#  10. Damage numbers float only over characters the party sees.
#  11. A hearing pulse never shows an unseen NPC's sight cone.
#  12. Handing control of a companion back and forth clears its stale AI glyph.
#  13. Weather changes and freezing puddles are announced, once.
#  14. School pools, luck, pending Bide and condition VFX/icons/periodic saves
#      survive a warp.
#  15. A same-map ladder moves the party instead of rebuilding the map (a member
#      caught mid-jump isn't carried back).
#  16. The Combat Test loadout isn't overwritten by the outgoing party.
# Run:  godot --headless --path . res://tests/game_controller_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

var failures := 0
var game = null
var bandit = null

func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])

func _await_frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

func _log_size() -> int:
	return GameLog.get_entries().size()

func _log_count(fragment: String, since: int) -> int:
	var n := 0
	var entries = GameLog.get_entries()
	for i in range(since, entries.size()):
		if fragment in str(entries[i].get("text", "")):
			n += 1
	return n

func _log_has(fragment: String, since: int) -> bool:
	return _log_count(fragment, since) > 0

func _count_floats(parent: Node, text: String) -> int:
	var n := 0
	for c in parent.get_children():
		if c is Label and str(c.text) == text and not c.is_queued_for_deletion():
			n += 1
	return n

func _ready() -> void:
	TimeManager.pause_time()
	# Let the initial ready cascade finish first: a node added to root DURING it
	# never gets NOTIFICATION_READY, so Game._ready would never run.
	await get_tree().process_frame
	var GameScene := load("res://game.tscn")
	game = GameScene.instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _await_frames(2)
	game.load_map("town_square")
	await _await_frames(10)
	game.select_character(game.party_chars[0], 0)
	# A hostile far outside everyone's sight for the cases that need one. Built
	# with _spawn_character only, so its AI stays off and it never moves.
	bandit = game._spawn_character("bandit", game.party_chars[0].global_position + Vector2(9000, 0), {})
	await _await_frames(2)

	_case_debug_status()
	_case_way_closed()
	await _case_trade_menu()
	_case_stealth_toggle()
	await _case_pick_up()
	_case_gather_water()
	_case_bide_payoff()
	_case_max_range()
	_case_out_of_reach()
	_case_unseen_damage_numbers()
	_case_hearing_pulse_cones()
	_case_companion_ai_reset()
	_case_weather_group_announce()
	await _case_persistence_across_warp()
	await _case_same_map_relocation()
	await _case_combat_test_loadout()

	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

# ---------------------------------------------------------------------------

func _case_debug_status() -> void:
	_check("debug.harness-is-debug-build", OS.is_debug_build(), "R/P/F9/F10/F12 are live only in debug builds")
	# P used to call the removed get_stats_string; with no player it must
	# simply do nothing (the runner counts SCRIPT ERRORs).
	var p = game.player
	game._print_status()
	game.player = null
	game._print_status()
	game.player = p
	_check("debug.print-status-survives", true)

func _case_way_closed() -> void:
	var since := _log_size()
	game.load_map("no_such_map_gc_test")
	_check("warp.unknown-map-stays-put", game.current_map_id == "town_square", game.current_map_id)
	_check("warp.unknown-map-announced", _log_has("That way leads nowhere yet.", since))

func _context_options(target, actor) -> Array:
	game.show_context_menu(target, Vector2(100, 100), actor)
	var menu = game.get_node("GameUI").get_child(game.get_node("GameUI").get_child_count() - 1)
	var out: Array = []
	if menu != null and "vbox" in menu:
		for b in menu.vbox.get_children():
			if b is Button:
				out.append(str(b.text))
	menu.queue_free()
	game.context_menu_open = false
	return out

func _case_trade_menu() -> void:
	var opts: Array = _context_options(game.party_chars[1], game.party_chars[0])
	_check("menu.party-member-no-trade", not ("Trade" in opts), str(opts))
	_check("menu.party-member-keeps-wait", "Wait Here" in opts or "Resume" in opts, str(opts))
	var guard = game._spawn_character("town_guard", game.party_chars[0].global_position + Vector2(9000, 400), {})
	await _await_frames(1)
	if guard != null and not FactionDatabase.are_hostile("player", guard.faction_id):
		var gopts: Array = _context_options(guard, game.party_chars[0])
		_check("menu.non-hostile-npc-keeps-trade", "Trade" in gopts, str(gopts))
	if guard != null:
		game.characters_in_scene.erase(guard)
		guard.queue_free()

func _press_c() -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_C
	ev.pressed = true
	game._input(ev)

func _case_stealth_toggle() -> void:
	var since := _log_size()
	var was: bool = game.stealth_mode
	_press_c()
	_check("stealth.toggles-on", game.stealth_mode == not was)
	_check("stealth.on-logged", _log_has("Stealth mode [b]on[/b]", since))
	# C goes through Game.set_stealth_mode (vision-stealth), whose line says it.
	_check("stealth.on-says-what-it-does", _log_has("Relaxed onlookers who spot you sneaking become wary", since))
	_check("stealth.on-says-talk-moves-to-right-click", _log_has("right-click for Talk", since))
	# An NPC spawned while stealth is on gets a cone that shows.
	game._add_npc_line_of_sight_light(bandit)
	var cone = bandit.get_node_or_null("NPCLineOfSight")
	_check("stealth.new-cone-follows-mode", cone != null and cone.visible)
	since = _log_size()
	_press_c()
	_check("stealth.toggles-off", game.stealth_mode == was)
	_check("stealth.off-logged", _log_has("Stealth mode [b]off[/b].", since))
	_check("stealth.cone-hides-with-mode", cone != null and not cone.visible)

func _case_pick_up() -> void:
	var p = game.party_chars[0]
	game.select_character(p, 0)
	var item = game.create_item("longsword", p.global_position + Vector2(10, 0))
	await _await_frames(1)
	_check("pickup.item-has-salvage", item != null and not item.resources.is_empty(), "longsword should carry resources")
	var items_before: int = game.items_in_scene.size()
	var since := _log_size()
	var ok: bool = game.pick_up_item(item)
	_check("pickup.succeeds", ok)
	_check("pickup.logged", _log_has("picks up", since), str(GameLog.get_entries().back()))
	_check("pickup.second-take-refused", not game.pick_up_item(item), "an item already queued for free can't be taken twice")
	await _await_frames(2)
	_check("pickup.no-salvage-scattered", game.items_in_scene.size() == items_before - 1,
		"before=%d after=%d" % [items_before, game.items_in_scene.size()])
	_check("pickup.sfx-key-exists", SfxManager.sound_library.has("chest_item_in"))
	# Armour goes through add_stack with Items.json's "num_stacks": null, which
	# threw in int() before the pack ever saw it.
	var helm = game.create_item("full_face_helmet", p.global_position + Vector2(10, 0))
	await _await_frames(1)
	var inv_before: int = p.inventory.items.size()
	since = _log_size()
	_check("pickup.armour-succeeds", helm != null and game.pick_up_item(helm)
		and p.inventory.items.size() == inv_before + 1, "inv %d -> %d" % [inv_before, p.inventory.items.size()])
	_check("pickup.armour-logged", _log_has("picks up", since) and not _log_has("(x", since))
	# A full pack refuses it and leaves it on the ground.
	var helm2 = game.create_item("full_face_helmet", p.global_position + Vector2(10, 0))
	await _await_frames(1)
	var fillers: int = 0
	# slots_used: one slot per item dict; weapons are nodes and take none.
	while p.inventory.slots_used() < p.inventory.max_slots:
		p.inventory.items.append({"id": "gc_filler", "display_name": "Filler"})
		fillers += 1
	_check("pickup.armour-full-pack-refused", helm2 != null and not game.pick_up_item(helm2)
		and is_instance_valid(helm2) and not helm2.is_queued_for_deletion())
	for i in range(fillers):
		p.inventory.items.pop_back()
	if is_instance_valid(helm2):
		game.remove_world_item(helm2)

func _case_gather_water() -> void:
	var p = game.party_chars[0]
	game.select_character(p, 0)
	var inv = p.inventory
	for i in range(inv.items.size() - 1, -1, -1):
		if str(inv.items[i].get("id", "")) == "waterskin":
			inv.items.remove_at(i)
	var tile: Vector2i = GridManager.world_to_map(p.global_position)
	var had_floor: bool = GridManager.floors.has(tile)
	var old_floor = GridManager.floors.get(tile, "")
	GridManager.floors[tile] = "water"
	var since := _log_size()
	game.gather_water_at_party()
	if had_floor:
		GridManager.floors[tile] = old_floor
	else:
		GridManager.floors.erase(tile)
	var skin: Dictionary = {}
	for it in inv.items:
		if str(it.get("id", "")) == "waterskin":
			skin = it
	_check("water.gathered", not skin.is_empty() and _log_has("gathers water", since))
	_check("water.database-entry", str(skin.get("sprite_path", "")) != "" and "Consume" in skin.get("interact_options", []), str(skin))
	_check("water.unowned", not skin.has("owner_faction") and not skin.has("stolen_from"), str(skin))

func _case_bide_payoff() -> void:
	var p = game.party_chars[0]
	p.bide_pending_bonus = 5.0
	var since := _log_size()
	var floats_before: int = _count_floats(game, "Bide +5!")
	game.process_weapon_hit(p, bandit, bandit.global_position, null, 0.0)
	_check("bide.consumed", is_zero_approx(p.bide_pending_bonus))
	_check("bide.logged", _log_has("unleashes Bide: +5 damage.", since))
	_check("bide.floats", _count_floats(game, "Bide +5!") == floats_before + 1)

func _case_max_range() -> void:
	var pos: Vector2 = game.party_chars[0].global_position + Vector2(0, -700)
	var before: int = _count_floats(game, "Max range")
	game._on_weapon_projectile_expired(pos, game.party_chars[0])
	_check("range.party-shot-marked", _count_floats(game, "Max range") == before + 1)
	game._on_weapon_projectile_expired(pos + Vector2(300, 0), bandit)
	_check("range.npc-shot-unmarked", _count_floats(game, "Max range") == before + 1)

func _case_out_of_reach() -> void:
	var p = game.party_chars[0]
	game.select_character(p, 0)
	_check("reach.bandit-is-hostile", bandit.is_hostile_to_party())
	p.attack_aim_node = null
	game.register_attack_start(p)
	bandit.current_elevation = 1.0
	bandit.visible = true
	var since := _log_size()
	_check("reach.cross-level-vetoed", not game.can_hit_target(p, bandit))
	_check("reach.warned", _log_count("melee can't strike between levels", since) == 1)
	game.can_hit_target(p, bandit)
	_check("reach.warned-once-per-swing", _log_count("melee can't strike between levels", since) == 1)
	game.register_attack_end(p)
	_check("reach.replaces-generic-whiff", not _log_has("swings and connects with nothing", since))
	# An AI-driven companion's swing never warns.
	var c = game.party_chars[1]
	game.register_attack_start(c)
	since = _log_size()
	game.can_hit_target(c, bandit)
	_check("reach.unselected-swinger-silent", not _log_has("can't reach", since))
	game.active_hits.erase(c.get_instance_id())
	bandit.current_elevation = 0.0

func _case_unseen_damage_numbers() -> void:
	game._npc_was_truly_seen[bandit] = false
	var parent: Node = bandit.get_parent()
	var before: int = _count_floats(parent, "37")
	bandit.handle_damage_effect_based_on_type(37, "bludgeoning", ProceduralCharacter.LimbType.TORSO, bandit.global_position)
	_check("numbers.hidden-npc-no-float", _count_floats(parent, "37") == before)
	game._npc_was_truly_seen[bandit] = true
	bandit.handle_damage_effect_based_on_type(37, "bludgeoning", ProceduralCharacter.LimbType.TORSO, bandit.global_position)
	_check("numbers.seen-npc-floats", _count_floats(parent, "37") == before + 1)
	var c = game.party_chars[1]
	var cparent: Node = c.get_parent()
	var cbefore: int = _count_floats(cparent, "38")
	c.handle_damage_effect_based_on_type(38, "bludgeoning", ProceduralCharacter.LimbType.TORSO, c.global_position + Vector2(0, 1000))
	_check("numbers.party-always-floats", _count_floats(cparent, "38") == cbefore + 1)
	game._npc_was_truly_seen[bandit] = false

func _case_hearing_pulse_cones() -> void:
	game.stealth_mode = true
	game._toggle_npc_los_cones()
	var cone = bandit.get_node_or_null("NPCLineOfSight")
	if cone == null:
		game._add_npc_line_of_sight_light(bandit)
		cone = bandit.get_node_or_null("NPCLineOfSight")
	bandit.global_position = game.party_chars[0].global_position + Vector2(9000, 0)
	game._update_npc_los_visibility()
	_check("cones.unseen-npc-cone-on-in-stealth", cone != null and cone.visible, "hidden with the NPC, not by the rule")
	game._npc_ever_seen[bandit] = true
	game.trigger_hearing_pulse(bandit)
	game._update_npc_los_visibility()
	_check("cones.pulse-draws-npc", bandit.visible and bandit.modulate.a < 1.0)
	_check("cones.pulse-hides-cone", cone != null and not cone.visible)
	game._tick_hearing_pulses(5.0)
	game._update_npc_los_visibility()
	_check("cones.pulse-expiry-restores-cone", cone != null and cone.visible and not bandit.visible)
	# Spotted mid-pulse: the cone comes back at once.
	game.trigger_hearing_pulse(bandit)
	game._update_npc_los_visibility()
	var p = game.party_chars[0]
	bandit.global_position = p.global_position + Vector2.UP.rotated(p.rotation) * 60.0
	game._update_npc_los_visibility()
	if game._npc_was_truly_seen.get(bandit, false):
		_check("cones.spotted-mid-pulse-restores-cone", cone != null and cone.visible)
	else:
		print("SKIP cones.spotted-mid-pulse-restores-cone: no clear line at the test spot")
	game.stealth_mode = false
	game._toggle_npc_los_cones()
	_check("cones.off-with-stealth", cone != null and not cone.visible)
	bandit.global_position = p.global_position + Vector2(9000, 0)
	game._update_npc_los_visibility()

func _case_companion_ai_reset() -> void:
	var p = game.party_chars[0]
	var c = game.party_chars[1]
	game.select_character(p, 0)
	var ai = c.get_node("AI")
	var glyph = c.get_node_or_null("AlertnessIndicator")
	_check("companion.has-glyph", glyph != null)
	ai._set_alertness_value(ai.ALERTNESS_SEARCHING_THRESHOLD + 5.0)
	# The AI is searching, but a companion shows no ?/! (character lane,
	# character-state-12: the glyphs are for AI-driven NPCs only).
	_check("companion.ai-driven-searches-without-glyph", ai.alertness_value >= ai.ALERTNESS_SEARCHING_THRESHOLD
		and glyph != null and not glyph.visible)
	game.select_character(c, 1)
	_check("companion.take-control-clears-glyph", glyph != null and not glyph.visible)
	_check("companion.take-control-clears-alertness", ai.alertness_value < ai.ALERTNESS_SUSPICIOUS_THRESHOLD)
	# A call-out while player-driven (alert_party raises everyone)...
	ai._set_alertness_value(ai.ALERTNESS_SEARCHING_THRESHOLD + 5.0)
	game.select_character(p, 0)
	# ...doesn't send the companion SEARCHING once it is handed back.
	_check("companion.hand-back-clears-stale-search", ai.alertness_value < ai.ALERTNESS_SUSPICIOUS_THRESHOLD
		and ai.current_target == null and ai.current_state == ai.AIState.IDLE)
	_check("companion.hand-back-glyph-hidden", glyph != null and not glyph.visible)

func _case_weather_group_announce() -> void:
	var group: String = str(game.current_map_data.get("weather_group", ""))
	if group.is_empty() or not WeatherManager.current_weather.has(group):
		print("SKIP weather.group-*: town_square has no live weather group")
		return
	var start: String = WeatherManager.get_precipitation(group)
	var first: String = "heavy_rain" if start != "heavy_rain" else "rain"
	var since := _log_size()
	game.force_weather(first)
	var shown: String = str(WeatherManager.get_precipitation_data(first).get("display_name", first))
	_check("weather.group-change-announced", _log_has("The weather turns: %s." % shown, since))
	# The same precipitation again (a daily re-roll, a wind change) says nothing.
	var n: int = _log_size()
	WeatherManager.set_wind_speed(group, WeatherManager.get_wind_speed(group) + 1.0)
	game.force_weather(first)
	_check("weather.same-precip-quiet", _log_size() == n and int(GameLog.get_entries().back().get("count", 1)) == 1)
	# Puddles (the rain just poured some) freeze under snow, and say so.
	var tile: Vector2i = GridManager.world_to_map(game.party_chars[0].global_position)
	if game.fluid_manager.get_fluid_type_at(tile) == "" and not game.surface_manager.surface_grid.has(tile):
		game.fluid_manager.register_fluid(tile, "water", 0.5)
	since = _log_size()
	game.force_weather("snow")
	_check("weather.snow-announced", _log_has("The weather turns: Snow.", since))
	_check("weather.freeze-announced", _log_has("Standing puddles freeze into slick ice.", since))
	game.force_weather(start)

func _case_persistence_across_warp() -> void:
	var p = game.party_chars[0]
	for t in ["Martial", "Arcane", "Primal", "Holy"]:
		p.traits[t] = 3
	p.adrenaline = 2
	p.focus = 1
	p.harmony = 0
	p.devotion = 1
	p.luck = 7
	p.bide_pending_bonus = 4.5
	p.condition_manager.apply_condition("weakened", null, 1, 600.0)
	p.condition_manager.apply_condition("slowed", null, 1, 600.0)
	for attempt in range(6):
		if p.condition_manager.has_condition("bleeding"):
			break
		p.condition_manager.apply_condition("bleeding", null, 3, 600.0)
	_check("persist.setup-conditions", p.condition_manager.has_condition("weakened")
		and p.condition_manager.has_condition("slowed") and p.condition_manager.has_condition("bleeding"),
		str(p.condition_manager.conditions.keys()))
	game.load_map("perrow_tavern")
	await _await_frames(4)
	var np = game.party_chars[0]
	_check("persist.respawned", np != p and is_instance_valid(np))
	_check("persist.pools", np.adrenaline == 2 and np.focus == 1 and np.harmony == 0 and np.devotion == 1,
		"adr=%d foc=%d har=%d dev=%d" % [np.adrenaline, np.focus, np.harmony, np.devotion])
	_check("persist.luck", np.luck == 7, str(np.luck))
	_check("persist.bide", is_equal_approx(np.bide_pending_bonus, 4.5), str(np.bide_pending_bonus))
	var cm = np.condition_manager
	_check("persist.conditions-restored", cm.has_condition("weakened") and cm.has_condition("slowed"), str(cm.conditions.keys()))
	# bleeding's vfx/bleeding.tscn exists (weakened's scene doesn't ship).
	if cm.has_condition("bleeding"):
		_check("persist.condition-vfx-respawned", np._active_condition_vfx.has("bleeding"))
	# An icon for every condition not shown by a VFX that actually spawned
	# (character lane: weakened's vfx scene doesn't ship, so it keeps its icon).
	var expected_icons: int = 0
	for cond_id in cm.conditions:
		if not (np._active_condition_vfx.has(cond_id) and is_instance_valid(np._active_condition_vfx[cond_id])):
			expected_icons += 1
	var icons: int = 0
	for ch in np._condition_display.get_children():
		if not ch.is_queued_for_deletion():
			icons += 1
	_check("persist.condition-icons-refilled", expected_icons > 0 and icons == expected_icons,
		"icons=%d expected=%d" % [icons, expected_icons])
	if cm.has_condition("bleeding"):
		_check("persist.periodic-save-seeded", cm.last_save_times.has("bleeding"))
	# perrow_tavern has no weather group: force_weather announces directly.
	var since := _log_size()
	game.force_weather("rain")
	_check("weather.direct-change-announced", _log_has("The weather turns: Rain.", since))
	game.force_weather("clear")
	game.load_map("town_square")
	await _await_frames(4)

func _case_same_map_relocation() -> void:
	game.load_map("tg_castle_keep")
	await _await_frames(6)
	var spawns: Dictionary = game.current_map_data.get("player_spawns", {})
	_check("relocate.map-has-ladder-spawn", spawns.has("ladder_1_top"))
	# A wounded onlooker of our own: a full reload would free it (and respawn
	# authored NPCs at full health).
	var onlooker = game._spawn_character("town_guard", game.party_chars[0].global_position + Vector2(9000, 0), {})
	var onlooker_id: int = 0
	if onlooker != null:
		onlooker.current_health = maxi(1, onlooker.current_health - 3)
		onlooker_id = onlooker.get_instance_id()
	await _await_frames(1)
	var npcs: Array = []
	for c in game.characters_in_scene:
		if is_instance_valid(c) and not (c in game.party_chars):
			npcs.append(c)
	var party_before: Array = game.party_chars.duplicate()
	# One member caught mid-jump: the arc re-lerps from its takeoff every frame.
	var jumper = game.party_chars[game.party_chars.size() - 1]
	var jump_mask: int = jumper.collision_mask
	jumper._jump_from = jumper.global_position
	jumper._jump_to_world = jumper.global_position + Vector2(-600, 0)
	jumper._jump_duration = 5.0
	jumper._jump_elapsed = 0.0
	jumper._jump_saved_mask = jump_mask
	jumper.collision_mask = jump_mask & ~CollisionLayers.STRUCTURES
	jumper._jump_active = true
	var loads: Array = [0]
	var on_loaded := func(_id): loads[0] += 1
	game.map_loaded.connect(on_loaded)
	game.load_map("tg_castle_keep", "tg_castle_keep", "ladder_1_top")
	await _await_frames(2)
	for i in range(3):
		await get_tree().physics_frame
	game.map_loaded.disconnect(on_loaded)
	var same_npcs: bool = true
	for c in npcs:
		if not is_instance_valid(c) or c.is_queued_for_deletion() or not (c in game.characters_in_scene):
			same_npcs = false
	_check("relocate.npcs-not-respawned", same_npcs and not npcs.is_empty(), "npcs=%d" % npcs.size())
	_check("relocate.wounded-npc-keeps-hp", onlooker_id != 0 and is_instance_id_valid(onlooker_id)
		and onlooker.current_health < onlooker.max_health)
	_check("relocate.same-party-nodes", game.party_chars == party_before)
	_check("relocate.no-map-loaded", loads[0] == 0)
	var pos_arr: Array = spawns.get("ladder_1_top", {}).get("position", [0, 0])
	var target := Vector2(pos_arr[0], pos_arr[1])
	_check("relocate.party-at-marker", game.party_chars[0].global_position.distance_to(target) < 200.0,
		"%s vs %s" % [game.party_chars[0].global_position, target])
	_check("relocate.warps-rebuilt", not game.warp_zones.is_empty())
	_check("relocate.jump-cancelled", not jumper._jump_active and jumper.collision_mask == jump_mask)
	_check("relocate.jumper-stays-at-marker", jumper.global_position.distance_to(target) < 200.0,
		"%s vs %s (paused=%s)" % [jumper.global_position, target, PauseManager.is_paused])

func _case_combat_test_loadout() -> void:
	var p = game.party_chars[0]
	p.inventory.items.append({"id": "gc_test_marker", "display_name": "GC Marker"})
	game.start_combat_test([{"template_id": "protagonist", "abilities": [], "items": []}], [], false)
	await _await_frames(4)
	_check("combat-test.loaded", game.current_map_id == "colosseum", game.current_map_id)
	var np = game.party_chars[0] if not game.party_chars.is_empty() else null
	var leaked: bool = false
	if np != null:
		for it in np.inventory.items:
			if str(it.get("id", "")) == "gc_test_marker":
				leaked = true
	_check("combat-test.loadout-not-overwritten", np != null and not leaked)
	_check("combat-test.no-away-stamp", game.party_state.size() == 1 and not game.is_party_member_away(game.party_state[0]))
	_check("combat-test.skip-flag-cleared", not game._skip_party_save)
