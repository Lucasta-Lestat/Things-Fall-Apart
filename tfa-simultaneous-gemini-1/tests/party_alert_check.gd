extends Node2D
# Party detection sharing + chase-occlusion staleness regression harness.
# Contracts proved here:
#  (1) one party member ACQUIRING a combat target raises the whole party —
#      through walls, across the map (ai.gd _acquire_target -> game.alert_party),
#  (2) a member already fighting their own target is never redirected,
#  (3) the periodic ally share bypasses the LOS gate for party members ONLY
#      (non-party same-faction allies still need eye contact),
#  (4) a chaser whose target stays wall-occluded for TARGET_OCCLUSION_GIVE_UP
#      demotes to SEARCHING in the `?` alertness band instead of holding CHASE
#      against the wall forever (the "no question mark" complaint).
# Headless-safe.  Run:  godot --headless --path . res://tests/party_alert_check.tscn
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

# This node stands in for Game (it joins the "game" group below).
var characters_in_scene: Array = []
var structures_in_scene: Array = []
var items_in_scene: Array = []
var party_chars: Array = []
var context_menu_open := false
var primary_selected = null

var _fails := 0
var _checks := 0


func _report(check_name: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("%s %s: %s" % ["PASS" if ok else "FAIL", check_name, detail])


# Mirror of Game.alert_party — the ai.gd acquisition hook reaches it duck-typed
# via game.has_method("alert_party"). Keep semantics in lockstep with Game.gd:
# raise-to-at-least 65 (over the SEARCHING promotion gate), skip members who
# already have their own target.
func alert_party(location: Vector2) -> void:
	for pc in party_chars:
		if not is_instance_valid(pc) or not pc.has_method("is_alive") or not pc.is_alive():
			continue
		var pai = pc.get_node_or_null("AI")
		if pai == null or not pai.has_method("wake_from_at_ease"):
			continue
		if pai.current_target != null:
			continue
		pai.wake_from_at_ease(65.0, location)


func _spawn(pos: Vector2, ai_on: bool) -> ProceduralCharacter:
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	c.is_player_controlled = not ai_on
	c.AI_enabled = ai_on
	add_child(c)
	c.game = self
	c.global_position = pos
	characters_in_scene.append(c)
	return c


# Vision/movement blocker: bodies WITHOUT the occlude_top meta always block
# sight_line_clear, so a bare StaticBody2D on the structure layers is a wall.
func _wall(tiles: Array) -> void:
	var body := StaticBody2D.new()
	body.collision_layer = CollisionLayers.STRUCTURE_LAYERS
	body.collision_mask = 0
	for t in tiles:
		var cs := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(GridManager.TILE_SIZE, GridManager.TILE_SIZE)
		cs.shape = rect
		cs.position = GridManager.map_to_world(t)
		body.add_child(cs)
		GridManager.register_obstacle(t)
	add_child(body)


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)   # 32x32 tiles
	await get_tree().process_frame

	# --- 1. acquisition fans out to the whole party, regardless of LOS/range --
	var a := _spawn(GridManager.map_to_world(Vector2i(5, 5)), true)
	a.faction_id = "player"
	a.hold_position = true   # keep the scene static: face/target, don't close
	party_chars.append(a)
	var b := _spawn(GridManager.map_to_world(Vector2i(25, 25)), true)
	b.faction_id = "player"
	b.hold_position = true
	party_chars.append(b)
	var e := _spawn(GridManager.map_to_world(Vector2i(12, 5)), false)   # out of melee reach
	await get_tree().physics_frame
	var aai = a.get_node("AI")
	var bai = b.get_node("AI")
	aai._acquire_target(e)
	_report("party.acquire-fans-out",
		float(bai.alertness_value) >= 65.0 and bai.last_heard_position == e.global_position,
		"b alert=%.0f heard=%s" % [float(bai.alertness_value), str(bai.last_heard_position)])

	# --- 2. a member mid-fight keeps their own information -------------------
	var c := _spawn(GridManager.map_to_world(Vector2i(20, 5)), true)
	c.faction_id = "player"
	c.hold_position = true
	party_chars.append(c)
	var d := _spawn(GridManager.map_to_world(Vector2i(20, 12)), false)   # c's own fight
	await get_tree().physics_frame
	var cai = c.get_node("AI")
	cai._acquire_target(d)
	var sentinel := Vector2(111.0, 222.0)
	cai.last_heard_position = sentinel
	var c_alert: float = float(cai.alertness_value)
	aai.current_target = null
	# Past TARGET_REANNOUNCE_GAP, or re-finding the same target is no call-out
	# at all and alert_party's mid-fight guard goes unexercised.
	aai._time_without_target = aai.TARGET_REANNOUNCE_GAP + 0.1
	aai._acquire_target(e)   # fresh party-wide call-out
	_report("party.no-redirect-mid-fight",
		cai.last_heard_position == sentinel and float(cai.alertness_value) == c_alert,
		"c heard=%s alert=%.0f" % [str(cai.last_heard_position), float(cai.alertness_value)])
	# Re-finding the same target inside the gap (apathy nulls the target every
	# frame and acquisition re-runs) doesn't call the party out again.
	if bai.current_target == null:
		var b_sentinel := Vector2(555.0, 666.0)
		bai.last_heard_position = b_sentinel
		aai.current_target = null
		aai._acquire_target(e)
		_report("party.no-repeat-call-out-in-gap", bai.last_heard_position == b_sentinel,
			"b heard=%s" % str(bai.last_heard_position))

	# --- 3. periodic share: party bypasses LOS, non-party still needs it ------
	# b2 and f sit SOUTH of a while a faces its enemy — outside the sharer's
	# ±75° cone, so is_in_line_of_sight fails for both; only party crosses.
	var b2 := _spawn(GridManager.map_to_world(Vector2i(5, 15)), true)
	b2.faction_id = "player"
	b2.hold_position = true
	party_chars.append(b2)
	var f := _spawn(GridManager.map_to_world(Vector2i(6, 15)), true)
	f.faction_id = "player"   # same faction, NOT in party_chars
	f.hold_position = true
	await get_tree().physics_frame
	var b2ai = b2.get_node("AI")
	var fai = f.get_node("AI")
	b2ai.current_target = null
	b2ai._set_alertness_value(0.0)
	b2ai.last_heard_position = Vector2.ZERO
	fai.current_target = null
	fai._set_alertness_value(0.0)
	fai.last_heard_position = Vector2.ZERO
	var fight_pos := Vector2(333.0, 444.0)
	aai.last_heard_position = fight_pos
	aai._share_alertness_with_allies()
	_report("party.share-through-walls",
		float(b2ai.alertness_value) > 0.0 and b2ai.last_heard_position == fight_pos,
		"b2 alert=%.0f heard=%s" % [float(b2ai.alertness_value), str(b2ai.last_heard_position)])
	_report("party.share-los-still-gates-nonparty",
		float(fai.alertness_value) == 0.0,
		"f alert=%.0f" % float(fai.alertness_value))

	# --- 4. occlusion staleness: blind chase demotes to `?` SEARCHING ---------
	# 20-tile wall column; rounding it takes far longer than the give-up, so
	# the hunter cannot regain sight before the demotion fires.
	var wall_tiles: Array = []
	for y in range(4, 24):
		wall_tiles.append(Vector2i(16, y))
	_wall(wall_tiles)
	var hunter := _spawn(GridManager.map_to_world(Vector2i(14, 14)), true)
	var prey := _spawn(GridManager.map_to_world(Vector2i(18, 14)), false)
	await get_tree().physics_frame
	var hai = hunter.get_node("AI")
	hai._acquire_target(prey)
	for _i in 420:   # 7s: give-up is 5s of continuous occlusion
		await get_tree().physics_frame
	_report("occlusion.demotes-to-searching",
		hai.current_target == null and hai.current_state == hai.AIState.SEARCHING
			and hai.current_alertness == hai.Alertness.SEARCHING,
		"target=%s state=%d alert=%.0f" % [str(hai.current_target),
			hai.current_state, float(hai.alertness_value)])

	print("party_alert_check: %d checks, %d FAIL" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)
