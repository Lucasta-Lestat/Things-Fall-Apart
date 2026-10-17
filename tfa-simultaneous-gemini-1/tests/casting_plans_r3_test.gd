extends Node2D
# Round 3, lane casting-plans: the developer's answers to open questions 5 and 6.
#   A. Concentration: spend and hold. The cast pays its focus cost; once it
#      lands it holds up to as much again of what is left. Recasting a held
#      spell pays again. Log: "X concentrates on Y (N focus spent, M held).";
#      the ability tooltip says it spends and holds.
#   B. Plans and stuns: pause instead of drop. Stunned / Frozen / Apathetic
#      pause the plan (queue holds, route dims with a pause badge) and it
#      resumes when the character can act; dropped, with the reason, when it
#      can't go on (target dead or gone, way blocked). Party members only are
#      announced.
# Headless-safe.  Run:  godot --headless --path . res://tests/casting_plans_r3_test.tscn
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const AQ := ActionQueue.ActionType

var fails := 0
var checks := 0

# Stand-in for Game (see planning_port_test): party_chars and the scene lists.
var party_chars: Array = []
var characters_in_scene: Array = []
var structures_in_scene: Array = []
var items_in_scene: Array = []
var primary_selected = null
var context_menu_open := false


func register_attack_start(_a: Node2D) -> void: pass
func register_attack_end(_a: Node2D) -> void: pass


func _check(name: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if not ok:
		fails += 1
	print("%s %s %s" % ["PASS" if ok else "FAIL", name, detail])


func _spawn(pos: Vector2, party: bool, char_name: String) -> ProceduralCharacter:
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	c.position = pos
	add_child(c)
	RaceDatabase.apply_race_to_character(c, "human", {"gender": "male"})
	c.Name = char_name
	c.game = self
	c.is_player_controlled = false
	c.AI_enabled = false
	characters_in_scene.append(c)
	if party:
		party_chars.append(c)
	return c


func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame


func _log_texts() -> Array:
	return GameLog.get_entries().map(func(e): return str(e.text))


func _logged(line: String) -> bool:
	return _log_texts().has(line)


func _draw_path(c: ProceduralCharacter, to: Vector2, steps: int = 6) -> void:
	c.tactical_path.clear()
	c.tactical_path.add_waypoint(c.global_position)
	for i in range(1, steps + 1):
		c.tactical_path.add_waypoint(c.global_position.lerp(to, float(i) / steps))


func _reset_plan(c: ProceduralCharacter) -> void:
	c.action_queue.cancel_all()
	if c.path_input_handler:
		c.path_input_handler.cancel_path()
	c.tactical_path.clear()
	c._plan_paused_by = ""
	c.is_moving = false
	c._last_notify_text = ""
	for id in ["stunned", "frozen", "unconscious"]:
		if c.condition_manager.has_condition(id):
			c.condition_manager.remove_condition(id)


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	await get_tree().process_frame
	PauseManager.is_paused = true

	await _concentration_cases()
	await _plan_pause_cases()

	PauseManager.is_paused = false
	print("casting_plans_r3_test: %d checks, %d failures" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)


# ---------------------------------------------------------------------------
# A. Concentration: spend and hold
# ---------------------------------------------------------------------------

## Arcane `tier` + Concentration: Slowed on the picked target (something to hold).
func _conc_ability(id: String, tier: int, cast_time: float = 0.0) -> Ability:
	return Ability.from_dict({
		"id": id, "display_name": id.capitalize(), "cast_time": cast_time,
		"traits": {"Arcane": tier, "Concentration": 1, "spell": 1},
		"targeting": {"type": "point", "range": 0.0, "shape": "circle", "radius": 60.0},
		"effects": [{"type": "apply_condition", "condition_id": "slowed", "duration": 60.0}],
	})


func _caster(char_name: String, pos: Vector2, arcane: int, party: bool = true) -> ProceduralCharacter:
	var c := _spawn(pos, party, char_name)
	c.npc_unlimited_resources = false
	c.traits["Arcane"] = arcane
	c.focus = arcane
	return c


func _concentration_cases() -> void:
	PauseManager.is_paused = false
	var enemy := _spawn(Vector2(1600, 1600), false, "Harness Mark")
	var c := _caster("Harness Ilse", Vector2(1400, 1600), 6)
	await _frames(2)
	c.focus = 6
	var cloud := _conc_ability("test_cloud", 3)

	# Pays the cost, then holds as much again
	c.use_ability(cloud, {"position": enemy.global_position, "targets": [enemy]})
	_check("conc.spends-then-holds", c.focus == 3 and c.concentration_locked_focus == 3 and c.spendable_focus == 0,
		"focus=%d held=%d spendable=%d" % [c.focus, c.concentration_locked_focus, c.spendable_focus])
	_check("conc.log-spent-and-held", _logged("Harness Ilse concentrates on Test Cloud (3 focus spent, 3 held)."), str(_log_texts().slice(-3)))

	# Held focus isn't spendable by another spell...
	var plain := Ability.from_dict({"id": "test_plain", "display_name": "Test Plain", "traits": {"Arcane": 1}, "targeting": {"type": "point"}, "effects": []})
	_check("conc.held-not-spendable", not c.ability_manager._check_ability_usable(plain)["success"])
	# ...but recasting the held spell releases it, so it counts toward the cost
	_check("conc.recast-affordable", c.ability_manager._check_ability_usable(cloud)["success"])
	c.use_ability(cloud, {"position": enemy.global_position, "targets": [enemy]})
	_check("conc.recast-pays-again", c.focus == 0 and c.concentration_locked_focus == 0 and not c.active_concentrations.is_empty(),
		"focus=%d held=%d active=%s" % [c.focus, c.concentration_locked_focus, str(c.active_concentrations.keys())])
	_check("conc.recast-logged", _logged("Harness Ilse lets Test Cloud go to concentrate on Test Cloud.") \
		and _logged("Harness Ilse concentrates on Test Cloud (3 focus spent, 0 held)."), str(_log_texts().slice(-3)))
	# Nothing held and no free focus: the next hit breaks it
	c._last_notify_text = ""
	c.take_damage({"force": 1}, c.global_position, enemy)
	_check("conc.zero-hold-breaks-on-hit", c.active_concentrations.is_empty() and c._last_notify_text == "Concentration broken" \
		and _logged("Harness Ilse loses concentration: Test Cloud ends."), str(_log_texts().slice(-3)))

	# Not enough for the cost: refused, nothing spent
	c.focus = 2
	_check("conc.cost-gates", not c.ability_manager._check_ability_usable(cloud)["success"])

	# Best effort: 4 focus pays 3 and holds the 1 left
	c.focus = 4
	c.use_ability(cloud, {"position": enemy.global_position, "targets": [enemy]})
	_check("conc.partial-hold", c.focus == 1 and c.concentration_locked_focus == 1, "focus=%d held=%d" % [c.focus, c.concentration_locked_focus])
	_check("conc.partial-hold-logged", _logged("Harness Ilse concentrates on Test Cloud (3 focus spent, 1 held)."))
	# Ending it frees only the held part
	c._release_concentration("test_cloud", true)
	_check("conc.end-frees-held-only", c.focus == 1 and c.concentration_locked_focus == 0 and c.spendable_focus == 1)
	_check("conc.end-logged", _logged("Harness Ilse's Test Cloud ends; 1 focus is free again."))
	if enemy.condition_manager.has_condition("slowed"):
		enemy.condition_manager.remove_condition("slowed")

	# An interrupted windup has paid, and holds nothing
	c.focus = 6
	c.use_ability(_conc_ability("test_slow_cloud", 3, 1.0), {"position": enemy.global_position, "targets": [enemy]})
	_check("conc.windup-pays-at-commit", c.focus == 3 and c.concentration_locked_focus == 0, "focus=%d" % c.focus)
	c.interrupt_cast("Harness", true)
	_check("conc.interrupted-holds-nothing", c.active_concentrations.is_empty() and c.concentration_locked_focus == 0 and c.focus == 3)

	# NPCs with unlimited resources pay and hold nothing; hits don't break theirs
	var hexer := _spawn(Vector2(1400, 1800), false, "Harness Hexer")
	hexer.npc_unlimited_resources = true
	hexer.traits["Arcane"] = 3
	hexer.focus = 3
	await _frames(1)
	var n0: int = GameLog.get_entries().size()
	hexer.use_ability(cloud, {"position": enemy.global_position, "targets": [enemy]})
	hexer.take_damage({"force": 1}, hexer.global_position, enemy)
	_check("conc.npc-unlimited-free", not hexer.active_concentrations.is_empty() and hexer.concentration_locked_focus == 0 \
		and hexer.focus >= 2)
	_check("conc.npc-silent", not _log_texts().slice(n0).any(func(t): return "concentrates" in t))
	hexer.end_concentration("")

	# Tooltips say it spends and holds
	var ItemTooltip = preload("res://UI/ItemTooltip.gd")
	var lines: PackedStringArray = ItemTooltip.ability_lines({"kind": "ability", "ability_id": "cloud_kill"})
	_check("conc.tooltip", lines.has("Concentration: spends 2 focus, then holds up to 2 more while it lasts"), str(lines))
	var panel = load("res://UI/PartySidePanel.gd").new()
	_check("conc.focus-rule-tooltip", "no free focus left" in String(panel.RESOURCE_RULES["focus"]))
	panel.free()

	# The AI still won't recast a spell it holds (it would pay again and drop it)
	var src := FileAccess.get_file_as_string("res://Characters/ai.gd")
	_check("conc.ai-skip-still-there", "recasting would pay the focus again" in src)

	if enemy.condition_manager.has_condition("slowed"):
		enemy.condition_manager.remove_condition("slowed")
	c.end_concentration("")
	PauseManager.is_paused = true


# ---------------------------------------------------------------------------
# B. Plans and stuns: pause, resume, or drop with the reason
# ---------------------------------------------------------------------------

func _plan_pause_cases() -> void:
	var a := _spawn(Vector2(300, 300), true, "Harness Aldric")
	var bandit := _spawn(Vector2(520, 300), false, "Harness Bandit")
	await _frames(2)
	await get_tree().physics_frame
	var cm: ConditionManager = a.condition_manager

	# --- visuals: a paused plan dims and shows a pause badge on the route
	_reset_plan(a)
	_draw_path(a, a.global_position + Vector2(0, 300))
	cm.apply_condition("stunned", null, 1, 30.0)
	a._on_game_unpaused_convert_path()
	# process_frame fires before the frame's _process calls: wait two.
	await _frames(2)
	var pd: PathDrawer = a.path_drawer
	_check("visual.paused", pd.is_plan_paused() and is_equal_approx(pd.self_modulate.a, PathDrawer.PAUSED_ALPHA) \
		and is_equal_approx(pd._node_layer.self_modulate.a, PathDrawer.PAUSED_ALPHA), "alpha=%.2f" % pd.self_modulate.a)
	_check("visual.pause-badge-full-strength", is_equal_approx(pd._pause_layer.self_modulate.a, 1.0))
	var badge: Vector2 = pd.pause_badge_position()
	_check("visual.badge-on-route-ahead", absf(badge.x - a.global_position.x) < 1.0 \
		and absf(badge.y - (a.global_position.y + PathDrawer.PAUSE_BADGE_AHEAD)) < 2.0, str(badge))
	var phase: float = pd._flow_phase
	await _frames(3)
	_check("visual.chevrons-still", is_equal_approx(pd._flow_phase, phase))

	# --- editing while paused: clearing the plan (Esc) leaves nothing paused,
	# and recovering then says nothing
	a.action_queue.cancel_all()
	a.path_input_handler.cancel_path()
	PauseManager.is_paused = false
	await _frames(1)
	_check("edit.cleared-not-paused", not a.is_plan_paused() and not a.has_player_orders())
	var n0: int = GameLog.get_entries().size()
	cm.remove_condition("stunned")
	await _frames(2)
	_check("edit.no-resume-line", not _log_texts().slice(n0).any(func(t): return "plan resumes" in t))
	await _frames(1)
	_check("visual.undimmed", is_equal_approx(pd.self_modulate.a, 1.0) and not pd.is_plan_paused())
	PauseManager.is_paused = true

	# --- a planned cast cut off by the stun is tried again on resume
	_reset_plan(a)
	a.npc_unlimited_resources = true
	a.action_queue.queue_ability("bide", a.global_position)
	PauseManager.is_paused = false
	await _frames(2)
	_check("cast.fixture-casting", a.ability_manager.current_cast.get("state", "") == "casting",
		str(a.ability_manager.current_cast.get("state", "")))
	cm.apply_condition("stunned", null, 1, 30.0)
	_check("cast.stun-interrupts-and-pauses", a.ability_manager.current_cast.is_empty() and a.is_plan_paused() \
		and a.action_queue.current_action != null and a.action_queue.current_action.type == AQ.USE_ABILITY)
	await _frames(3)
	_check("cast.held-while-paused", a.action_queue.current_action != null and a.action_queue.current_action.type == AQ.USE_ABILITY)
	cm.remove_condition("stunned")
	await _frames(2)
	var cast_ab = a.ability_manager.current_cast.get("ability")
	_check("cast.retried-on-resume", a.ability_manager.current_cast.get("state", "") == "casting" \
		and cast_ab != null and cast_ab.id == "bide")
	_check("cast.resume-logged", _logged("Harness Aldric recovers: plan resumes."))
	a.ability_manager.cancel_cast("")
	a.npc_unlimited_resources = false
	PauseManager.is_paused = true
	_reset_plan(a)
	for id in ["bide", "biding"]:
		if cm.has_condition(id):
			cm.remove_condition(id)

	# --- a shove while paused: the MOVE rejoins its route ahead, not behind
	_draw_path(a, a.global_position + Vector2(0, 300))
	a._on_game_unpaused_convert_path()
	PauseManager.is_paused = false
	await _frames(3)
	var origin: Vector2 = a.tactical_path.waypoints[0] if not a.tactical_path.waypoints.is_empty() else a.global_position
	cm.apply_condition("stunned", null, 1, 30.0)
	a.global_position = origin + Vector2(60, 160)
	cm.remove_condition("stunned")
	await _frames(1)
	_check("shove.rejoins-ahead", not a.is_plan_paused() and a.is_moving and a.target_position.y >= origin.y + 150.0,
		"target=%s origin=%s" % [a.target_position, origin])
	PauseManager.is_paused = true
	_reset_plan(a)
	a.global_position = Vector2(300, 300)

	# --- the target died while they were stunned: dropped, with the reason
	a.action_queue.queue_attack_target(bandit)
	cm.apply_condition("stunned", null, 1, 30.0)
	_check("dead.fixture-paused", a.is_plan_paused())
	bandit.current_health = 0
	bandit._check_death()
	cm.remove_condition("stunned")
	a._last_notify_text = ""
	PauseManager.is_paused = false
	await _frames(2)
	_check("dead.dropped", not a.has_player_orders() and not a.is_plan_paused())
	_check("dead.reason-logged", _logged("Harness Aldric recovers, but Harness Bandit is dead: plan dropped."), str(_log_texts().slice(-3)))
	_check("dead.float", a._last_notify_text == "Plan dropped", a._last_notify_text)
	_check("dead.ai-gets-legs-back", not a.get_node("AI")._movement_locked())
	PauseManager.is_paused = true
	_reset_plan(a)

	# --- the target left (freed): dropped
	var runner := _spawn(Vector2(520, 420), false, "Harness Runner")
	await _frames(1)
	a.action_queue.queue_attack_target(runner)
	cm.apply_condition("stunned", null, 1, 30.0)
	characters_in_scene.erase(runner)
	runner.queue_free()
	await _frames(1)
	cm.remove_condition("stunned")
	PauseManager.is_paused = false
	await _frames(2)
	_check("gone.reason-logged", not a.has_player_orders() \
		and _logged("Harness Aldric recovers, but the target is gone: plan dropped."), str(_log_texts().slice(-3)))
	PauseManager.is_paused = true
	_reset_plan(a)

	# --- the way is blocked now (a wall went up across the route): dropped
	_draw_path(a, a.global_position + Vector2(0, 300))
	cm.apply_condition("stunned", null, 1, 30.0)
	a._on_game_unpaused_convert_path()
	var wall := StaticBody2D.new()
	wall.collision_layer = CollisionLayers.STRUCTURES
	wall.collision_mask = 0
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(600, 40)
	shape.shape = rect
	wall.add_child(shape)
	add_child(wall)
	wall.global_position = a.global_position + Vector2(0, 150)
	await get_tree().physics_frame
	await get_tree().physics_frame
	cm.remove_condition("stunned")
	PauseManager.is_paused = false
	await _frames(2)
	_check("blocked.dropped", not a.has_player_orders() and a.tactical_path.is_empty() \
		and _logged("Harness Aldric recovers, but the way is blocked: plan dropped."), str(_log_texts().slice(-3)))
	PauseManager.is_paused = true
	_reset_plan(a)

	# --- ...but a route the wall already crossed when the stun landed (clutter
	# the walker slides past) isn't newly blocked: it resumes
	_draw_path(a, a.global_position + Vector2(0, 300))
	cm.apply_condition("stunned", null, 1, 30.0)
	a._on_game_unpaused_convert_path()
	_check("blocked.preexisting-fixture", a.is_plan_paused() and not a._plan_route_was_clear)
	cm.remove_condition("stunned")
	PauseManager.is_paused = false
	await _frames(2)
	_check("blocked.preexisting-resumes", a.has_player_orders() and not a.is_plan_paused() 		and _log_texts()[-1] == "Harness Aldric recovers: plan resumes.", str(_log_texts().slice(-2)))
	PauseManager.is_paused = true
	wall.queue_free()
	await get_tree().physics_frame
	_reset_plan(a)

	# --- Frozen pauses too; the log names it
	_draw_path(a, a.global_position + Vector2(0, 200))
	cm.apply_condition("frozen", null, 1, 30.0)
	a._on_game_unpaused_convert_path()
	_check("frozen.pauses", a.is_plan_paused() and _logged("Harness Aldric is Frozen: plan paused."))
	_reset_plan(a)

	# --- NPCs: no plan, nothing paused, the AI keeps its legs; a non-party
	# character's plan pauses and resumes without a word
	var guard := _spawn(Vector2(900, 900), false, "Harness Guard")
	guard.AI_enabled = true
	await _frames(1)
	guard.condition_manager.apply_condition("stunned", null, 1, 30.0)
	_check("npc.no-plan-not-paused", not guard.is_plan_paused() and not guard.has_player_orders() \
		and not guard.get_node("AI")._movement_locked())
	guard.condition_manager.remove_condition("stunned")
	guard.AI_enabled = false
	_draw_path(guard, guard.global_position + Vector2(0, 200))
	guard.condition_manager.apply_condition("stunned", null, 1, 30.0)
	n0 = GameLog.get_entries().size()
	guard._on_game_unpaused_convert_path()
	guard.condition_manager.remove_condition("stunned")
	PauseManager.is_paused = false
	await _frames(2)
	_check("npc.resumes-not-frozen", not guard.is_plan_paused() and guard.has_player_orders())
	_check("npc.silent", GameLog.get_entries().size() == n0, str(_log_texts().slice(n0)))
	PauseManager.is_paused = true
	_reset_plan(guard)

	# --- death while paused: nothing left paused on the corpse
	_draw_path(a, a.global_position + Vector2(0, 200))
	cm.apply_condition("stunned", null, 1, 30.0)
	a._on_game_unpaused_convert_path()
	a.current_health = 0
	a.health_changed.emit(a.current_health, a.max_health, a)
	a._check_death()
	await _frames(1)
	_check("death.not-paused", not a.is_plan_paused() and not a.has_player_orders() and not a.path_drawer.is_plan_paused())
