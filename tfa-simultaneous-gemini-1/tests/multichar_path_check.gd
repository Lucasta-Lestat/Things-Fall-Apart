extends Node2D
# Multi-character planned-path execution: EVERY character with a drawn tactical
# path converts it into ActionQueue actions at unpause, not just the one the
# player happens to have selected. Regression guard for the
# "only the selected character follows planned paths" bug, where
# _on_game_unpaused_convert_path early-returned on `is_player_controlled` while
# Game._sync_character_flags set that flag from selection alone.
#
# Also covers the co-existence contract: while player orders are outstanding the
# AI keeps its brain but loses the legs (ai.gd _movement_locked), and fear
# outranks orders entirely (_break_player_orders).
# Headless-safe.  Run:  godot --headless --path . res://tests/multichar_path_check.tscn
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

var fails := 0
var checks := 0

# This node stands in for Game (it joins the "game" group below); ai.gd reads
# these off it every tick.
var characters_in_scene: Array = []
var structures_in_scene: Array = []


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
	characters_in_scene.append(c)
	return c


## Draw a straight tactical path from the character to `to`, the way
## PathInputHandler would, without needing mouse input.
func _draw_path(c: ProceduralCharacter, to: Vector2) -> void:
	c.tactical_path.clear()
	c.tactical_path.add_waypoint(c.global_position)
	var steps := 6
	for i in range(1, steps + 1):
		c.tactical_path.add_waypoint(c.global_position.lerp(to, float(i) / steps))


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	await get_tree().process_frame

	# --- two party members, both with drawn paths, only ONE "selected" ---------
	var a := _spawn(Vector2(200, 200))
	var b := _spawn(Vector2(600, 200))
	await get_tree().process_frame

	# Exactly the flag split Game._sync_character_flags produces: A is the
	# selected one, B is an unselected party member running its AI.
	a.is_player_controlled = true
	a.AI_enabled = false
	b.is_player_controlled = false
	b.AI_enabled = true

	_draw_path(a, Vector2(200, 600))
	_draw_path(b, Vector2(600, 600))
	_check("setup.both-paths-drawn",
		not a.tactical_path.is_empty() and not b.tactical_path.is_empty())

	# Unpause: this is the moment the bug used to drop B's path on the floor.
	PauseManager.is_paused = false
	PauseManager.emit_signal("game_unpaused")
	await get_tree().process_frame

	_check("selected.path-converted", a.action_queue.get_queue_size() > 0 or a.action_queue.current_action != null,
		"queue=%d" % a.action_queue.get_queue_size())
	_check("UNSELECTED.path-converted", b.action_queue.get_queue_size() > 0 or b.action_queue.current_action != null,
		"queue=%d" % b.action_queue.get_queue_size())
	_check("selected.has-orders", a.has_player_orders())
	_check("UNSELECTED.has-orders", b.has_player_orders())

	# --- the AI keeps its brain but loses the legs -----------------------------
	# process_ai must still be reached for a path-executing character (that is
	# what lets it shoot something it walks past), so AI_enabled alone must not
	# be the gate.
	_check("orders.ai-still-ticks-for-executing-path",
		b.AI_enabled or (b.has_player_orders() and b.tactical_path.is_executing),
		"AI_enabled=%s is_executing=%s" % [b.AI_enabled, b.tactical_path.is_executing])

	var ai_node := b.get_node_or_null("AI")
	_check("ai.node-present", ai_node != null)
	if ai_node != null:
		_check("ai.movement-locked-while-orders", ai_node._movement_locked())
		# The legs are locked, but nothing else is: these are the faculties the
		# user asked to keep. Their mere presence is the contract.
		_check("ai.brain-intact", ai_node.has_method("_try_cast_ability") \
			and ai_node.has_method("_process_attack"))

		# Locked locomotion must not touch is_moving — a stray `false` reads as an
		# arrival to _is_action_complete(MOVE) and silently eats a waypoint.
		b.is_moving = true
		ai_node._move_toward(Vector2(0, 0))
		_check("ai.locked-move-does-not-clear-is_moving", b.is_moving)

	# --- characters actually travel ALONG THE DRAWN PATH ----------------------
	# NB: "did it move at all" is NOT a valid check here. With the bug present an
	# unselected character still moves — its AI drives it somewhere of the AI's
	# choosing, which is exactly the reported symptom ("keeps moving, but doesn't
	# follow their path"). So assert it CLOSED DISTANCE ON THE PATH DESTINATION.
	var a_dest := Vector2(200, 600)
	var b_dest := Vector2(600, 600)
	var a_gap0 := a.global_position.distance_to(a_dest)
	var b_gap0 := b.global_position.distance_to(b_dest)
	for i in 40:
		await get_tree().process_frame
	var a_closed := a_gap0 - a.global_position.distance_to(a_dest)
	var b_closed := b_gap0 - b.global_position.distance_to(b_dest)
	_check("selected.advanced-along-path", a_closed > 8.0, "closed %.1fpx" % a_closed)
	_check("UNSELECTED.advanced-along-path", b_closed > 8.0, "closed %.1fpx" % b_closed)

	# --- a character with NO path is untouched --------------------------------
	var c := _spawn(Vector2(1000, 200))
	c.is_player_controlled = false
	c.AI_enabled = true
	await get_tree().process_frame
	_check("no-path.no-orders", not c.has_player_orders())
	var ai_c := c.get_node_or_null("AI")
	if ai_c != null:
		_check("no-path.ai-movement-free", not ai_c._movement_locked())

	# --- fear outranks orders --------------------------------------------------
	if ai_node != null and b.condition_manager != null:
		b.condition_manager.apply_condition("panicked", null, 1, 5.0)
		await get_tree().process_frame
		ai_node._break_player_orders()
		_check("fear.breaks-orders", not b.has_player_orders(),
			"queue=%d" % b.action_queue.get_queue_size())
		_check("fear.movement-unlocked", not ai_node._movement_locked())

	print("multichar_path_check: %d checks, %d failures" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)
