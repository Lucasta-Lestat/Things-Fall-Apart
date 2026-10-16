extends Node2D
# Tactical planning regression harness (ActionQueue, TacticalPath,
# PathInputHandler, plan abandon):
#   * the 10-action cap counts direct orders only; drawn-path steps are tagged
#     "from_path" and exempt, so a long path converts in full, and a refused
#     direct order says "Plan full" (party members only)
#   * a rotation node emits its FACE once
#   * a planned dash completes on landing and the next MOVE rejoins the route
#     ahead of the landing point (resume_nearest)
#   * planned attacks keep the hand that was clicked (queue + path nodes)
#   * character-pick abilities can be assigned to a path node
#   * an unassigned node / node targeting is dropped at unpause, before the
#     path converts
#   * a plan is abandoned, with a notice, when its character can't act; a
#     corpse's queue is cancelled
#   * a re-queued path cast that is already going doesn't announce
#     "Already casting"
# Headless-safe.  Run:  godot --headless --path . res://tests/planning_port_test.tscn
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const AQ := ActionQueue.ActionType

var fails := 0
var checks := 0

# This node stands in for Game: characters' is_party_member() reads party_chars
# off it, and ai.gd reads the scene lists through the "game" group.
var party_chars: Array = []
var characters_in_scene: Array = []
var structures_in_scene: Array = []
var items_in_scene: Array = []
var primary_selected = null
var context_menu_open := false


# AttackAnimator reports swings to the Game stand-in.
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


func _draw_path(c: ProceduralCharacter, to: Vector2, steps: int = 6) -> void:
	c.tactical_path.clear()
	c.tactical_path.add_waypoint(c.global_position)
	for i in range(1, steps + 1):
		c.tactical_path.add_waypoint(c.global_position.lerp(to, float(i) / steps))


func _log_texts() -> Array:
	return GameLog.get_entries().map(func(e): return str(e.text))


func _reset(c: ProceduralCharacter) -> void:
	c.action_queue.cancel_all()
	c.tactical_path.clear()
	c._last_notify_text = ""


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	await get_tree().process_frame
	# Planning happens paused: the ActionQueue only executes while unpaused.
	PauseManager.is_paused = true

	var a := _spawn(Vector2(200, 200), true, "Harness Planner")
	var npc := _spawn(Vector2(1200, 1200), false, "Harness Bystander")
	var t1 := _spawn(Vector2(420, 200), false, "Harness Target One")
	var t2 := _spawn(Vector2(420, 320), false, "Harness Target Two")
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("setup.party-member", a.is_party_member() and not npc.is_party_member())

	_case_queue_cap(a, npc)
	_case_long_path(a)
	_case_face_node(a)
	await _case_dash(a)
	_case_offhand(a, t1)
	await _case_node_character_pick(a, t1, t2)
	_case_stale_placing(a)
	_case_already_casting(a)
	await _case_plan_abandon(a, npc)
	await _case_death(a)

	PauseManager.is_paused = false
	print("planning_port_test: %d checks, %d failures" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)


# --- queue cap (action-planning-queue-cap-truncates-path, sweep-markers-action-queue-full)
func _case_queue_cap(a: ProceduralCharacter, npc: ProceduralCharacter) -> void:
	_reset(a)
	var aq: ActionQueue = a.action_queue
	var ok_all := true
	for i in range(10):
		ok_all = aq.queue_action(AQ.FACE, {"target_rotation": 0.0}) and ok_all
	_check("cap.ten-direct-orders-fit", ok_all and aq.get_queue_size() == 10)
	_check("cap.has_space-false-when-full", not aq.has_space())
	var n0: int = GameLog.get_entries().size()
	var refused: bool = not aq.queue_action(AQ.FACE, {"target_rotation": 0.0})
	_check("cap.eleventh-refused", refused and aq.get_queue_size() == 10)
	_check("cap.plan-full-logged", GameLog.get_entries().size() == n0 + 1 \
		and _log_texts()[-1] == "Harness Planner can't plan another action: the plan is full (10 max).",
		str(_log_texts()[-1]))
	_check("cap.plan-full-float", a._last_notify_text == "Plan full", a._last_notify_text)
	var path_ok: bool = aq.queue_action(AQ.FACE, {"target_rotation": 0.0, "from_path": true})
	_check("cap.path-step-exempt", path_ok and aq.get_queue_size() == 11)
	_check("cap.path-steps-dont-count", not aq.has_space() and aq.has_space(0))
	aq.cancel_all()
	_check("cap.has_space-n", aq.has_space(10) and not aq.has_space(11))

	# NPCs are refused silently
	npc.action_queue.cancel_all()
	for i in range(10):
		npc.action_queue.queue_action(AQ.FACE, {"target_rotation": 0.0})
	n0 = GameLog.get_entries().size()
	var npc_refused: bool = not npc.action_queue.queue_action(AQ.FACE, {"target_rotation": 0.0})
	_check("cap.npc-refused-silently", npc_refused and GameLog.get_entries().size() == n0)
	npc.action_queue.cancel_all()


# --- long paths convert in full; steps are tagged copies
func _case_long_path(a: ProceduralCharacter) -> void:
	_reset(a)
	_draw_path(a, a.global_position + Vector2(0, 600), 30)
	var nodes: Array = []
	for i in range(12):
		var p: Vector2 = a.global_position + Vector2(0, 40 + i * 45)
		var n = a.tactical_path.insert_action_node(p)
		n.action_type = AQ.FACE
		n.action_data = {"target_rotation": 0.5}
		n.facing_angle = 0.5
		nodes.append(n)
	var actions: Array = a.tactical_path.to_action_queue_actions()
	var faces := actions.filter(func(x): return x.type == AQ.FACE)
	var moves := actions.filter(func(x): return x.type == AQ.MOVE)
	_check("path.one-face-per-rotation-node", faces.size() == 12, "faces=%d" % faces.size())
	_check("path.moves-between-nodes", moves.size() == 13, "moves=%d" % moves.size())
	_check("path.all-steps-tagged", actions.all(func(x): return x.data.get("from_path", false)))
	var first_face = faces[0] if not faces.is_empty() else null
	_check("path.node-step-names-its-node", first_face != null and first_face.data.get("path_node") == nodes[0])
	_check("path.node-data-is-a-copy", first_face != null and not is_same(first_face.data, nodes[0].action_data) \
		and not nodes[0].action_data.has("from_path"))

	# Conversion at unpause queues every step (25 > the 10 cap)
	a._on_game_unpaused_convert_path()
	_check("path.long-path-not-truncated", a.action_queue.get_queue_size() == actions.size(),
		"queued=%d of %d" % [a.action_queue.get_queue_size(), actions.size()])
	_check("path.direct-order-still-fits", a.action_queue.has_space())
	_reset(a)


# --- action-planning-face-node-double-emit
func _case_face_node(a: ProceduralCharacter) -> void:
	_reset(a)
	_draw_path(a, a.global_position + Vector2(300, 0))
	var n = a.tactical_path.insert_action_node(a.global_position + Vector2(150, 0))
	n.action_type = AQ.FACE
	n.action_data = {"target_rotation": 1.0}
	n.facing_angle = 1.0
	var actions: Array = a.tactical_path.to_action_queue_actions()
	_check("face.rotation-node-emits-once", actions.size() == 3 and actions[1].type == AQ.FACE,
		"steps=%d" % actions.size())
	# A node carrying an action AND a facing still emits both
	n.action_type = AQ.ATTACK
	n.action_data = {"target_position": Vector2.ZERO}
	actions = a.tactical_path.to_action_queue_actions()
	_check("face.action-plus-facing-emits-both", actions.size() == 4 and actions[1].type == AQ.ATTACK \
		and actions[2].type == AQ.FACE, "steps=%d" % actions.size())
	_reset(a)


# --- action-planning-dash-node-walk-back
func _case_dash(a: ProceduralCharacter) -> void:
	_reset(a)
	var aq: ActionQueue = a.action_queue
	_draw_path(a, a.global_position + Vector2(0, 400))
	var dn = a.tactical_path.insert_action_node(a.global_position + Vector2(0, 100))
	dn.action_type = AQ.CUSTOM
	dn.action_data = {"callable": Callable(a, "dash").bind(a.global_position + Vector2(0, 250)),
		"dash_target": a.global_position + Vector2(0, 250), "dash_max_range": a.get_dash_range()}
	var actions: Array = a.tactical_path.to_action_queue_actions()
	_check("dash.steps", actions.size() == 3, "steps=%d" % actions.size())
	if actions.size() == 3:
		_check("dash.move-before-plain", not actions[0].data.get("resume_nearest", false))
		_check("dash.move-after-resumes-nearest", actions[2].data.get("resume_nearest", false))

	var wps: Array = [Vector2(0, 0), Vector2(100, 0), Vector2(200, 0), Vector2(300, 0)]
	_check("dash.nearest-ahead-mid", aq._nearest_waypoint_ahead(wps, Vector2(150, 10)) == 2)
	_check("dash.nearest-ahead-start", aq._nearest_waypoint_ahead(wps, Vector2(0, 0)) == 1)
	_check("dash.nearest-ahead-past-end", aq._nearest_waypoint_ahead(wps, Vector2(400, 0)) == 3)

	# A MOVE flagged resume_nearest starts at the waypoint ahead of the body
	var route: Array[Vector2] = []
	for w in wps:
		route.append(a.global_position + w)
	var mv := ActionQueue.Action.new(AQ.MOVE, {"waypoints": route, "waypoint_index": 0, "resume_nearest": true,
		"target_position": route[3]})
	var saved_pos := a.global_position
	a.global_position = saved_pos + Vector2(150, 10)
	aq._execute_action(mv)
	_check("dash.move-resumes-ahead", int(mv.data.get("waypoint_index", -1)) == 2 \
		and a.target_position.is_equal_approx(route[2]), "index=%s" % str(mv.data.get("waypoint_index")))
	a.global_position = saved_pos
	a.is_moving = false
	a._nav_waypoints.clear()

	# CUSTOM completion: a dash waits for the landing, other customs are instant
	var dash_step := ActionQueue.Action.new(AQ.CUSTOM, {"dash_target": Vector2.ZERO})
	a._dash_motion_active = true
	_check("dash.incomplete-while-moving", not aq._is_action_complete(dash_step))
	a._dash_motion_active = false
	_check("dash.complete-on-landing", aq._is_action_complete(dash_step))
	_check("dash.other-custom-instant", aq._is_action_complete(ActionQueue.Action.new(AQ.CUSTOM, {})))

	# Live: a queued dash holds the queue until the body lands
	_reset(a)
	a.dash_cooldown_timer = 0.0
	aq.queue_dash(a.global_position + Vector2(150, 0))
	aq.queue_action(AQ.FACE, {"target_rotation": a.rotation})
	PauseManager.is_paused = false
	await get_tree().process_frame
	await get_tree().physics_frame
	var held: bool = aq.current_action != null and aq.current_action.type == AQ.CUSTOM and a._dash_motion_active
	_check("dash.queue-waits-for-landing", held,
		"current=%s active=%s" % [str(aq.current_action.type if aq.current_action else -1), a._dash_motion_active])
	var landed := false
	for i in range(120):
		await get_tree().process_frame
		if not a._dash_motion_active and (aq.current_action == null or aq.current_action.type != AQ.CUSTOM):
			landed = true
			break
	_check("dash.queue-moves-on-after-landing", landed)
	PauseManager.is_paused = true
	_reset(a)


# --- action-planning-offhand-plans-swing-main
func _case_offhand(a: ProceduralCharacter, target: ProceduralCharacter) -> void:
	_reset(a)
	var aq: ActionQueue = a.action_queue
	aq.queue_attack(Vector2(10, 10))
	aq.queue_attack(Vector2(10, 10), "Off")
	aq.queue_attack_target(target, "Off")
	var q: Array = aq.get_queue()
	_check("hand.queue_attack-default-main", q.size() == 3 and q[0].data.get("hand") == "Main")
	_check("hand.queue_attack-off", q.size() == 3 and q[1].data.get("hand") == "Off")
	_check("hand.queue_attack_target-off", q.size() == 3 and q[2].data.get("hand") == "Off")
	_reset(a)

	# Execution sets the active hand, like a live click
	a.current_hand = "Main"
	aq._execute_action(ActionQueue.Action.new(AQ.ATTACK, {"target_position": a.global_position + Vector2(0, -60), "hand": "Off"}))
	_check("hand.attack-executes-with-hand", a.current_hand == "Off", a.current_hand)
	a.current_hand = "Main"
	aq._execute_action(ActionQueue.Action.new(AQ.ATTACK_TARGET, {"target": target, "hand": "Off"}))
	_check("hand.attack-target-executes-with-hand", a.current_hand == "Off", a.current_hand)
	a.current_hand = "Main"
	if a.attack_animator:
		a.attack_animator.interrupt_attack()

	# Path nodes store the hand
	var h: PathInputHandler = a.path_input_handler
	_draw_path(a, a.global_position + Vector2(0, 300))
	h.pending_action_node = a.tactical_path.insert_action_node(a.global_position + Vector2(0, 100))
	h._assign_attack_to_pending_node(Vector2(1800, 1800), "Off")
	var n1 = h.pending_action_node
	_check("hand.node-attack-stores-hand", n1.action_type == AQ.ATTACK and n1.action_data.get("hand") == "Off")
	h.pending_action_node = a.tactical_path.insert_action_node(a.global_position + Vector2(0, 150))
	h._assign_attack_to_pending_node(target.global_position, "Off")
	var n2 = h.pending_action_node
	_check("hand.node-attack-target-stores-hand", n2.action_type == AQ.ATTACK_TARGET \
		and n2.action_data.get("target") == target and n2.action_data.get("hand") == "Off")
	h.pending_action_node = a.tactical_path.insert_action_node(a.global_position + Vector2(0, 200))
	h.state = PathInputHandler.PathInputState.PLACING_ACTION
	var n3 = h.pending_action_node
	h._initiate_action_for_node(null, "Off", Vector2(1800, 1800))
	_check("hand.node-empty-hand-swings-main", n3.action_data.get("hand") == "Main")
	var steps: Array = a.tactical_path.to_action_queue_actions()
	var attacks := steps.filter(func(x): return x.type == AQ.ATTACK or x.type == AQ.ATTACK_TARGET)
	_check("hand.carried-into-queue-steps", attacks.size() == 3 and attacks[0].data.get("hand") == "Off")
	h.state = PathInputHandler.PathInputState.IDLE
	h.pending_action_node = null
	_reset(a)

	# The paused direct click passes its hand
	var sword: Dictionary = ItemDatabase.get_item_data("dagger")
	if sword.is_empty():
		sword = ItemDatabase.get_item_data("longsword")
	_check("hand.fixture-weapon", not sword.is_empty())
	if not sword.is_empty():
		a.inventory.equip_weapon_from_data(sword.duplicate(), "Off")
		var off = a.current_off_hand_item
		_check("hand.fixture-off-hand-weapon", off is WeaponShape)
		if off is WeaponShape:
			a._process_hand_action(off, "Off", Vector2(1800, 1800), true)
			a._process_hand_action(off, "Off", target.global_position, true)
			var dq: Array = aq.get_queue()
			_check("hand.paused-click-queues-off", dq.size() == 2 and dq[0].type == AQ.ATTACK \
				and dq[0].data.get("hand") == "Off" and dq[1].type == AQ.ATTACK_TARGET and dq[1].data.get("hand") == "Off")
	_reset(a)


# --- action-planning-node-character-targeting-unsupported
func _case_node_character_pick(a: ProceduralCharacter, t1: ProceduralCharacter, t2: ProceduralCharacter) -> void:
	_reset(a)
	var h: PathInputHandler = a.path_input_handler
	var ts = a.targeting_system
	var pick_ability := {"id": "harness_pick", "display_name": "Harness Pick", "target_shape": "characters",
		"target_count": 2, "target_filter": "any", "range": 0.0, "effects": []}
	_draw_path(a, a.global_position + Vector2(0, 300))
	var node = a.tactical_path.insert_action_node(a.global_position + Vector2(0, 100))
	h.pending_action_node = node
	h.state = PathInputHandler.PathInputState.PLACING_ACTION
	ts.start_targeting("Main", pick_ability, t1.global_position, node.world_position)
	h._targeting_for_node = true
	_check("pick.fixture-characters-shape", ts.target_shape == ts.TargetShape.CHARACTERS)

	Input.action_press("left_click")
	var consumed: bool = h.handle_input(t1.global_position)
	Input.action_release("left_click")
	_check("pick.first-click-toggles", consumed and ts.selected_targets.size() == 1 and not node.has_action(),
		"picked=%d" % ts.selected_targets.size())
	await get_tree().process_frame
	Input.action_press("left_click")
	h.handle_input(t2.global_position)
	Input.action_release("left_click")
	_check("pick.count-reached-assigns", node.action_type == AQ.USE_ABILITY \
		and node.action_data.get("ability_id") == "harness_pick" \
		and node.action_data.get("targets", []).size() == 2)
	_check("pick.targeting-ended", not ts.is_targeting and not h._targeting_for_node \
		and h.state == PathInputHandler.PathInputState.IDLE)
	await get_tree().process_frame
	await get_tree().process_frame
	_check("pick.auto-confirm-did-not-cast-or-queue", a.action_queue.get_queue_size() == 0 \
		and a.current_cast.is_empty())

	# The other button cancels targeting and leaves the node pending
	var node2 = a.tactical_path.insert_action_node(a.global_position + Vector2(0, 200))
	h.pending_action_node = node2
	h.state = PathInputHandler.PathInputState.PLACING_ACTION
	ts.start_targeting("Main", pick_ability, t1.global_position, node2.world_position)
	h._targeting_for_node = true
	await get_tree().process_frame
	Input.action_press("right_click")
	h.handle_input(t1.global_position)
	Input.action_release("right_click")
	_check("pick.other-button-cancels", not ts.is_targeting and not h._targeting_for_node \
		and h.pending_action_node == node2 and not node2.has_action())
	h.abort_pending_input()
	_reset(a)


# --- action-planning-stale-placing-state
func _case_stale_placing(a: ProceduralCharacter) -> void:
	_reset(a)
	var h: PathInputHandler = a.path_input_handler
	_draw_path(a, a.global_position + Vector2(0, 300))
	var orphan = a.tactical_path.insert_action_node(a.global_position + Vector2(0, 150))
	h.pending_action_node = orphan
	h.state = PathInputHandler.PathInputState.PLACING_ACTION
	h._awaiting_node_press_release = true
	PauseManager.emit_signal("game_unpaused")
	_check("stale.orphan-node-dropped", not (orphan in a.tactical_path.action_nodes))
	_check("stale.handler-idle", h.state == PathInputHandler.PathInputState.IDLE \
		and h.pending_action_node == null and not h._awaiting_node_press_release)
	# Dropped before conversion: one unsplit MOVE, not two
	var q: Array = a.action_queue.get_queue()
	_check("stale.dropped-before-conversion", q.size() == 1 and q[0].type == AQ.MOVE, "queued=%d" % q.size())
	_reset(a)


# --- R1F-castfail follow-up: from_path "Already casting"
func _case_already_casting(a: ProceduralCharacter) -> void:
	_reset(a)
	var ab := Ability.new()
	ab.id = "harness_bolt"
	ab.display_name = "Harness Bolt"
	var saved_cast: Dictionary = a.ability_manager.current_cast
	a.ability_manager.current_cast = {"state": "casting", "ability": ab}
	a.action_queue.current_action = ActionQueue.Action.new(AQ.USE_ABILITY, {"ability_id": "harness_bolt", "from_path": true})
	var n0: int = GameLog.get_entries().size()
	var again := Ability.new()
	again.id = "harness_bolt"
	again.display_name = "Harness Bolt"
	a.ability_manager.cast_failed.emit(again, "Already casting")
	_check("cast.requeued-path-step-silent", GameLog.get_entries().size() == n0)
	a.action_queue.current_action = ActionQueue.Action.new(AQ.USE_ABILITY, {"ability_id": "harness_bolt"})
	a._last_notify_text = ""
	a.ability_manager.cast_failed.emit(again, "Already casting")
	_check("cast.direct-order-still-announced", GameLog.get_entries().size() == n0 + 1)
	a.action_queue.current_action = null
	a.ability_manager.current_cast = saved_cast
	_reset(a)


# --- R1-repair-pc-1: plan abandon
func _case_plan_abandon(a: ProceduralCharacter, npc: ProceduralCharacter) -> void:
	_reset(a)
	var cm: ConditionManager = a.condition_manager
	# Blocked at unpause: the plan is dropped, not converted
	_draw_path(a, a.global_position + Vector2(0, 300))
	cm.apply_condition("stunned", null, 1, 30.0)
	var n0: int = GameLog.get_entries().size()
	a._on_game_unpaused_convert_path()
	_check("abandon.at-unpause", not a.has_player_orders() and a.tactical_path.is_empty())
	_check("abandon.notice-logged", GameLog.get_entries().size() == n0 + 1 \
		and _log_texts()[-1] == "Harness Planner abandons their plan: Stunned.", str(_log_texts()[-1]))
	_check("abandon.notice-float", a._last_notify_text == "Can't follow plan")
	cm.remove_condition("stunned")

	# No blocker: converts as usual
	_reset(a)
	_draw_path(a, a.global_position + Vector2(0, 300))
	a._on_game_unpaused_convert_path()
	_check("abandon.no-blocker-converts", a.has_player_orders() and a.tactical_path.is_executing)

	# Mid-plan: a compulsion lands while the plan runs
	PauseManager.is_paused = false
	await get_tree().process_frame
	a._last_notify_text = ""
	n0 = GameLog.get_entries().size()
	cm.apply_condition("transfixed", null, 1, 30.0)
	await get_tree().process_frame
	await get_tree().process_frame
	_check("abandon.mid-plan", not a.has_player_orders() and a.tactical_path.is_empty(),
		"queue=%d" % a.action_queue.get_queue_size())
	_check("abandon.mid-plan-notice", _log_texts().slice(n0).has("Harness Planner abandons their plan: Transfixed."),
		str(_log_texts().slice(n0)))
	PauseManager.is_paused = true
	cm.remove_condition("transfixed")
	a.is_moving = false

	# Frozen counts through the "incapacitate" trait
	cm.apply_condition("frozen", null, 1, 30.0)
	var blocker = a._get_plan_blocking_condition()
	_check("abandon.incapacitate-trait", blocker != null and blocker.condition.id == "frozen")
	cm.remove_condition("frozen")
	_check("abandon.clear-when-able", a._get_plan_blocking_condition() == null)

	# Not a party member: dropped silently
	npc.tactical_path.clear()
	_draw_path(npc, npc.global_position + Vector2(0, 200))
	npc.condition_manager.apply_condition("stunned", null, 1, 30.0)
	n0 = GameLog.get_entries().size()
	npc._on_game_unpaused_convert_path()
	_check("abandon.non-party-silent", npc.tactical_path.is_empty() and GameLog.get_entries().size() == n0)
	npc.condition_manager.remove_condition("stunned")
	_reset(a)


# --- R1-repair-pc-1 (death half): a corpse's queue is cancelled
func _case_death(a: ProceduralCharacter) -> void:
	_reset(a)
	a.action_queue.queue_attack(a.global_position + Vector2(0, -50))
	a.action_queue.queue_face(a.global_position + Vector2(50, 0))
	_check("death.fixture-queued", a.action_queue.get_queue_size() == 2)
	a.current_health = 0
	a.health_changed.emit(a.current_health, a.max_health, a)
	a._check_death()
	await get_tree().process_frame
	_check("death.queue-cancelled", not a.is_alive() and a.action_queue.get_queue_size() == 0 \
		and a.action_queue.current_action == null)
