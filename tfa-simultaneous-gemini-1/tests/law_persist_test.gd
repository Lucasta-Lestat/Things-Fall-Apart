# res://tests/law_persist_test.gd
# Headless assertion harness for Phase 7 — persistence and surrender
# (docs/law_crime_stealth_plan.md). This one drives the REAL game scene:
# game.tscn is instantiated with an empty map id (load_map("") early-returns
# safely), promoted to current_scene so every autoload and AI binds to the
# real Game, and only then told to load real maps. Map transitions are the
# thing under test — chest state, guard death, uid schemes, the save dict.
# TimeManager is paused so the build->apply->build round-trip is
# frame-deterministic.
# Run:  godot --headless --path . res://tests/law_persist_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

var failures := 0
var game = null
var reported: Array = []

func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])

func _await_frames(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame

func _find_item(item_id: String):
	for it in game.items_in_scene:
		if is_instance_valid(it) and str(it.id) == item_id:
			return it
	return null

func _guards() -> Array:
	var out: Array = []
	for c in game.characters_in_scene:
		if is_instance_valid(c) and str(c.get_meta("template_id", "")) == "town_guard":
			out.append(c)
	return out

func _ready() -> void:
	TimeManager.pause_time()
	CrimeManager.crime_reported.connect(func(enforcer, payload): reported.append({"enforcer": enforcer, "payload": payload}))

	# Let the initial scene-ready cascade finish first: a node added to root
	# DURING it never receives NOTIFICATION_READY, so @onready vars stay null
	# and Game._ready never runs (found the hard way).
	await get_tree().process_frame
	var GameScene := load("res://game.tscn")
	game = GameScene.instantiate()
	game.current_map_id = ""   # _ready's load_map("") early-returns; we load below
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _await_frames(2)
	game.load_map("town_square")
	await _await_frames(5)

	await _case_item_persistence()
	await _case_shape_persistence()
	await _case_guard_death_persistence()
	await _case_wilderness_bucket()
	_case_save_round_trip()
	_case_surrender_implacable()
	await _case_surrender_predatory()
	await _case_surrender_lawful()
	await _case_corpse_discovery()

	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _case_item_persistence() -> void:
	# town_square ships one authored item: treasure_chest, controlling_faction
	# liziti, value 100 — the auto-fill chest that exercises THE ordering trap.
	var chest = _find_item("treasure_chest")
	_check("item.authored-chest-present", chest != null)
	if chest == null:
		return
	_check("item.chest-auto-filled", chest.contents is Array and not (chest.contents as Array).is_empty(),
		"faction chest should auto-fill at spawn")
	# Empty it (the theft), and destroy a second, loose item (the take).
	chest.contents = []
	var loose = game.create_item("treasure_chest", Vector2(1500, 1500))
	await _await_frames(1)
	var loose_count_before: int = 0
	for it in game.items_in_scene:
		if is_instance_valid(it) and str(it.id) == "treasure_chest":
			loose_count_before += 1
	_check("item.two-chests-live", loose_count_before == 2)
	loose._destroy_item()
	await _await_frames(1)
	# Warp away and back.
	game.load_map("perrow_tavern")
	await _await_frames(4)
	game.load_map("town_square")
	await _await_frames(5)
	var restored = _find_item("treasure_chest")
	_check("item.chest-restored", restored != null)
	if restored != null:
		_check("item.chest-stays-emptied", restored.contents is Array and (restored.contents as Array).is_empty(),
			"THE ordering trap: an emptied faction chest must not refill from the loot table")
	var count_after: int = 0
	for it in game.items_in_scene:
		if is_instance_valid(it) and str(it.id) == "treasure_chest":
			count_after += 1
	_check("item.taken-item-stays-gone", count_after == 1, "count=%d" % count_after)

# Revisit keeps every authored item's SHAPE (rotation, scale, scale_x/y, z)
# and a RUN's length/width/caps/seed/decor -- _capture_item_state once kept
# x/y only, so benches, stalls and banquet tables respawned at rotation 0,
# scale 1 (natural-tables lane). Damage survives too.
func _find_at(item_id: String, p: Vector2):
	for it in game.items_in_scene:
		if is_instance_valid(it) and str(it.id) == item_id and it.global_position.distance_to(p) < 0.5:
			return it
	return null

func _case_shape_persistence() -> void:
	game._spawn_items([
		{"id": "bench", "position": [1460.0, 1490.0], "rotation": 1.2, "scale": 1.3, "scale_x": 0.8, "z": 1.0},
		{"id": "long_table", "position": [1620.0, 1610.0], "rotation": 0.5, "scale": 1.0,
			"length": 300.0, "width": 50.0, "caps": 1.0, "seed": 9.0,
			"decor": [{"id": "_plate", "at": [10.0, -12.0], "rot": 0.3}]},
	])
	await _await_frames(1)
	var bench = _find_at("bench", Vector2(1460, 1490))
	var table = _find_at("long_table", Vector2(1620, 1610))
	_check("shape.spawned", bench != null and table != null)
	if bench == null or table == null:
		return
	_check("shape.run-built", table.fixed and table.get_node_or_null("RunRenderer") != null)
	_check("shape.spawn-rotation-and-scale", absf(bench.rotation - 1.2) < 1e-4 and bench.scale.distance_to(Vector2(1.04, 1.3)) < 1e-4,
		"rot %f scale %s (AnimatableBody2D: one transform write)" % [bench.rotation, str(bench.scale)])
	var full_hp: int = int(table.max_health)
	table.current_health = full_hp - 7
	game.load_map("perrow_tavern")
	await _await_frames(4)
	game.load_map("town_square")
	await _await_frames(5)
	var b2 = _find_at("bench", Vector2(1460, 1490))
	var t2 = _find_at("long_table", Vector2(1620, 1610))
	_check("shape.restored", b2 != null and t2 != null)
	if b2 == null or t2 == null:
		return
	_check("shape.plain-rotation-kept", absf(b2.rotation - 1.2) < 1e-4, "rot %f" % b2.rotation)
	_check("shape.plain-scale-kept", b2.scale.distance_to(Vector2(1.04, 1.3)) < 1e-4, str(b2.scale))
	_check("shape.plain-z-kept", int(b2.z_index) == 2, "z %d" % b2.z_index)
	_check("shape.run-rotation-kept", absf(t2.rotation - 0.5) < 1e-4, "rot %f" % t2.rotation)
	_check("shape.run-length-kept", t2.fixed and absf(float(t2.run.get("length", 0.0)) - 300.0) < 1e-4
		and absf(float(t2.run.get("width", 0.0)) - 50.0) < 1e-4 and int(t2.run.get("caps", 3)) == 1
		and int(t2.run.get("seed", 0)) == 9 and (t2.run.get("decor", []) as Array).size() == 1, str(t2.run))
	_check("shape.run-renderer-rebuilt", t2.get_node_or_null("RunRenderer") != null)
	_check("shape.damage-kept", int(t2.current_health) == full_hp - 7 and int(t2.max_health) == full_hp,
		"%d/%d" % [t2.current_health, t2.max_health])
	_check("shape.run-not-pickable", game._world_item_options(t2).is_empty())

func _case_guard_death_persistence() -> void:
	var guards: Array = _guards()
	_check("guard.two-spawned", guards.size() == 2, "count=%d" % guards.size())
	if guards.size() < 2:
		return
	# Murder one (state only — the crime pipeline is exercised elsewhere).
	guards[0].current_health = 0
	var dead_ordinal: int = int(guards[0].get_meta("spawn_ordinal", -1))
	game.load_map("perrow_tavern")
	await _await_frames(4)
	# The persisted bucket carries the ordinal uid; service NPCs keep the
	# legacy bare/named forms so the services panel keeps matching.
	var bucket: Dictionary = game.npc_state_per_region.get("perrow", {})
	_check("guard.ordinal-uid-saved", bucket.has("town_guard#%d" % dead_ordinal), str(bucket.keys()))
	_check("guard.service-uid-form-preserved", bucket.has("smith_darcy"),
		"service NPCs keep the bare template_id form: " + str(bucket.keys()))
	game.load_map("town_square")
	await _await_frames(5)
	var after: Array = _guards()
	var dead_count: int = 0
	for g in after:
		if not g.is_alive():
			dead_count += 1
	_check("guard.murdered-stays-murdered", after.size() == 2 and dead_count == 1,
		"guards=%d dead=%d" % [after.size(), dead_count])

func _case_wilderness_bucket() -> void:
	# tg_export has no region: NPC state must land in the map-keyed bucket
	# instead of being silently dropped.
	game.load_map("tg_export")
	await _await_frames(5)
	var victims: Array = []
	for c in game.characters_in_scene:
		if is_instance_valid(c) and not (c in game.party_chars) and c.is_alive():
			victims.append(c)
	if victims.is_empty():
		_check("wild.npc-present", false, "no NPCs spawned on tg_export")
		game.load_map("town_square")
		await _await_frames(5)
		return
	victims[0].current_health = 0
	game.load_map("town_square")
	await _await_frames(5)
	_check("wild.map-bucket-used", game.npc_state_per_region.has("map:tg_export"),
		str(game.npc_state_per_region.keys()))

func _case_save_round_trip() -> void:
	# No awaits between the three calls: zero frames pass, so live AI state
	# cannot drift between builds.
	var first: Dictionary = game.build_save_dict()
	game.apply_save_dict(first)
	var second: Dictionary = game.build_save_dict()
	var s1: String = JSON.stringify(first)
	var s2: String = JSON.stringify(second)
	if s1 != s2:
		for i in range(mini(s1.length(), s2.length())):
			if s1[i] != s2[i]:
				print("  save diff at %d: ...%s... vs ...%s..." % [i, s1.substr(maxi(0, i - 40), 90), s2.substr(maxi(0, i - 40), 90)])
				break
	_check("save.round-trip-identical", s1 == s2, "%d vs %d chars" % [s1.length(), s2.length()])
	# apply restores mutated stores.
	var standing_saved: int = FactionDatabase.get_player_standing("waldau")
	FactionDatabase.adjust_player_standing("waldau", -37)
	game.apply_save_dict(first)
	_check("save.apply-restores-standing", FactionDatabase.get_player_standing("waldau") == standing_saved,
		"%d" % FactionDatabase.get_player_standing("waldau"))

func _case_surrender_implacable() -> void:
	var SurrenderPanel := load("res://UI/SurrenderPanel.gd")
	var panel = SurrenderPanel.new()
	panel.game = game
	game.add_child(panel)
	_check("surrender.implacable-refuses", not panel.try_open("wildlife"),
		"it does not understand the word")
	panel.queue_free()

func _case_surrender_predatory() -> void:
	# Ten separate 10-gold entries so the greedy rob can take exactly half.
	# EVERY party inventory is cleared first — the rob is a fraction of the
	# whole party's value, so a second member's real items skew the take.
	var protagonist = game.party_chars[0]
	for c in game.party_chars:
		if is_instance_valid(c) and ("inventory" in c) and c.inventory != null:
			c.inventory.items.clear()
	for i in range(10):
		protagonist.inventory.items.append({"id": "coin_pouch_%d" % i, "cost": 10.0, "num_stacks": 1})
	var bandit = game._spawn_character("town_guard", protagonist.global_position + Vector2(200, 0), {})
	bandit.faction_id = "bandits"
	bandit.AI_enabled = true
	var SurrenderPanel := load("res://UI/SurrenderPanel.gd")
	var panel = SurrenderPanel.new()
	panel.game = game
	game.add_child(panel)
	_check("surrender.predatory-opens", panel.try_open("bandits"))
	panel._do_rob(0.5)
	var remaining: float = 0.0
	for c in game.party_chars:
		if is_instance_valid(c) and ("inventory" in c) and c.inventory != null:
			for entry in c.inventory.items:
				remaining += float(entry.get("cost", 0.0))
	_check("surrender.robbed-about-half", remaining >= 40.0 and remaining <= 60.0, "remaining=%f" % remaining)
	var bandit_ai = bandit.get_node("AI")
	_check("surrender.truce-set", bandit_ai.truce_until > TimeManager.absolute_time())
	_check("surrender.truce-holds", not bandit_ai._is_enemy(protagonist),
		"a robbed party walks away — for now")
	bandit.queue_free()
	game.characters_in_scene.erase(bandit)
	await _await_frames(1)

func _case_surrender_lawful() -> void:
	var protagonist = game.party_chars[0]
	var enforcer := Node2D.new()
	add_child(enforcer)
	CrimeManager.on_alarm_heard(enforcer, {
		"crime_id": 7001, "identified": true, "perp": protagonist,
		"crime_pos": Vector2.ZERO, "law_faction": "liziti",
		"statute": "theft", "display_name": "Theft", "severity": 25,
	})
	_check("surrender.lawful-precondition", FactionDatabase.is_outlaw_with("liziti"))
	var SurrenderPanel := load("res://UI/SurrenderPanel.gd")
	var panel = SurrenderPanel.new()
	panel.game = game
	game.add_child(panel)
	_check("surrender.lawful-opens", panel.try_open("liziti"))
	panel._do_settle("pay_fine")
	_check("surrender.lawful-settled", not FactionDatabase.is_outlaw_with("liziti"))
	_check("surrender.lawful-not-hostile", not FactionDatabase.are_hostile("player", "liziti"))
	enforcer.queue_free()
	await _await_frames(1)

func _case_corpse_discovery() -> void:
	# An unwitnessed murder discovered by an enforcer. The scene must sit on
	# a spot with a genuinely clear 300 px sight line INSIDE the map —
	# off-map space is vision-blocked (the background body), and structures
	# are wherever the map art put them — so probe candidates first.
	await _await_frames(1)
	var space := get_world_2d().direct_space_state
	var crime_spot: Vector2 = Vector2.INF
	for candidate in [Vector2(1900, 1600), Vector2(1000, 1000), Vector2(300, 700), Vector2(1500, 500)]:
		if GridManager.sight_line_clear(space, candidate + Vector2(0, 300), candidate, 0.0, 0.0):
			crime_spot = candidate
			break
	_check("corpse.clear-spot-found", crime_spot != Vector2.INF, "no unobstructed test site on town_square")
	if crime_spot == Vector2.INF:
		return
	var actor = game.party_chars[0]
	var victim = game._spawn_character("town_guard", crime_spot, {})
	victim.faction_id = "neutral"
	victim.Name = "Hermit"
	# The killing blow: health clamps to 0 before damaged_by fires in the
	# real pipeline; here we set it and report directly.
	victim.current_health = 0
	CrimeManager.report(actor, "attack", CrimeManager.attack_payload(actor, victim))
	_check("corpse.stamped", victim.has_meta("corpse_crime"),
		"a body dropped by a crime carries the charge")
	var before: int = reported.size()
	var finder = game._spawn_character("town_guard", crime_spot + Vector2(0, 300), {})
	finder.faction_id = "liziti"
	finder.rotation = 0.0   # face UP toward the corpse — spawn facing is not guaranteed
	var finder_ai = finder.get_node("AI")
	# Sub-predicate diagnosis, printed on the way in:
	print("  corpse-diag enforces=%s los=%s dist=%f rot=%f fov=%f elevs=%f/%f" % [
		LawDatabase.enforces("liziti", str(victim.get_meta("corpse_crime", {}).get("law_faction", "?"))),
		finder_ai.is_in_line_of_sight(victim.global_position, victim.get_elevation()),
		finder.global_position.distance_to(victim.global_position),
		finder.rotation, finder.effective_fov(), finder.get_elevation(), victim.get_elevation()])
	finder_ai._check_corpse_discovery()
	_check("corpse.discovery-fuse-lit", not finder_ai.pending_outcry.is_empty()
		and not bool(finder_ai.pending_outcry.get("identified", true)),
		str(finder_ai.pending_outcry))
	var standing_before: int = FactionDatabase.get_player_standing("liziti")
	if finder_ai._outcry_timer > 0.0:
		finder_ai._tick_outcry(finder_ai._outcry_timer + 0.01)
	_check("corpse.alarm-raised-unidentified", reported.size() == before + 1
		and not bool(reported.back()["payload"].get("identified", true)))
	_check("corpse.no-standing-change", FactionDatabase.get_player_standing("liziti") == standing_before,
		"the body does not name its killer")
	var info: Dictionary = victim.get_meta("corpse_crime")
	_check("corpse.alarms-once", bool(info.get("discovered", false)))
