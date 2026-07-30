extends Node2D
# Movement-feel harness: proves (1) a character aimed obliquely INTO a wall
# GLIDES along it at real speed instead of chunk-crawling (FLOATING stop-cone
# + stuck-abort loop, fixed by wall_min_slide_angle=0 + tangent glide +
# repath-not-freeze), (2) two characters walking opposite ways SLIP past each
# other, and (3) a follower marching behind a leader keeps net progress
# (radial-only separation used to out-push walk speed head-on).
# Run headless:  godot --headless --path . res://tests/wall_glide_check.tscn
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

var _fails := 0
var _checks := 0


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	_wall(Vector2(500, 510), Vector2(400, 20))   # top face at y=500
	await get_tree().process_frame
	await _check_glide()
	await _check_steep_glide()
	await _check_unreachable_escape()
	await _check_pass()
	await _check_follow()
	print("wall_glide_check: %d checks, %d FAIL" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _wall(center: Vector2, size: Vector2) -> void:
	var body := StaticBody2D.new()
	body.collision_layer = CollisionLayers.STRUCTURES
	var cs := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size
	cs.shape = rect
	body.add_child(cs)
	add_child(body)
	body.global_position = center


func _spawn(pos: Vector2) -> ProceduralCharacter:
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	c.is_player_controlled = true   # AI FSM stays out of the way
	add_child(c)
	c.global_position = pos
	c.hold_position = true          # belt & braces: no AI-issued moves
	return c


func _drive(c: ProceduralCharacter, dest: Vector2) -> void:
	c.target_position = dest
	c.target_rotation = (dest - c.global_position).angle() + PI / 2
	c.is_moving = true


# run until `seconds` of accumulated frame time has passed
func _run(seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		var d := get_process_delta_time()
		t += maxf(d, 0.0001)
		await get_tree().process_frame


func _report(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("%s %s: %s" % ["PASS" if ok else "FAIL", name, detail])


# (1) aim ~25 degrees into the wall face from just above it -> must glide
# along x at a healthy fraction of walk speed, not chunk-crawl
func _check_glide() -> void:
	var c := _spawn(Vector2(340, 476))
	await get_tree().process_frame
	_drive(c, Vector2(660, 560))    # dest is BELOW the wall line: pure press
	var t0 := c.global_position
	await _run(4.0)
	var dx := c.global_position.x - t0.x
	var expected := c.move_speed * 4.0
	_report("wall-glide", dx > expected * 0.45,
		"slid %.0fpx along the wall in 4s (speed %.0f, expected >= %.0f)" % [dx, c.move_speed, expected * 0.45])
	c.queue_free()


# (1b) aim STEEPLY into the wall (~63 degrees off-parallel) — the playtest
# regression: an intent-glide projection strobed press/parallel frames here
# and jittered in place forever. Pure engine slide must keep near-full speed.
func _check_steep_glide() -> void:
	var c := _spawn(Vector2(360, 476))
	await get_tree().process_frame
	_drive(c, Vector2(540, 830))    # dir ~(0.45, 0.89): mostly INTO the wall
	var t0 := c.global_position
	await _run(3.5)
	var dx := c.global_position.x - t0.x
	var expected := c.move_speed * 3.5
	_report("steep-glide", dx > expected * 0.4,
		"slid %.0fpx along the wall in 3.5s at steep incidence (expected >= %.0f)" % [dx, expected * 0.4])
	c.queue_free()


# (1c) target sits ON the wall face — physically unreachable within the 5px
# arrive radius. The magnitude-preserving slide overshoots the perpendicular
# foot at full speed and flips direction every frame: eternal vibration under
# a per-frame displacement test (the second playtest regression). The
# net-progress detector must end the move within a couple of seconds.
func _check_unreachable_escape() -> void:
	var c := _spawn(Vector2(430, 476))
	await get_tree().process_frame
	_drive(c, Vector2(560, 502))    # 2px inside the wall face, 130px along it
	await _run(3.0)
	_report("unreachable-escape", not c.is_moving,
		"is_moving=%s after 3s at an on-wall target (want false: escaped, no eternal jitter); ended at x=%.0f" \
		% [str(c.is_moving), c.global_position.x])
	c.queue_free()


# (2) two walkers head-on with a small lateral offset -> both get past
func _check_pass() -> void:
	var a := _spawn(Vector2(900, 900))
	var b := _spawn(Vector2(1100, 908))
	await get_tree().process_frame
	_drive(a, Vector2(1100, 900))
	_drive(b, Vector2(900, 908))
	await _run(7.0)
	var ok := a.global_position.x > 1040.0 and b.global_position.x < 960.0
	_report("pass-each-other", ok,
		"A at x=%.0f (want >1040), B at x=%.0f (want <960)" % [a.global_position.x, b.global_position.x])
	a.queue_free()
	b.queue_free()


# (3) follower directly behind a slower-started leader, same destination ->
# the follower must keep marching (net progress), not grind in place
func _check_follow() -> void:
	var lead := _spawn(Vector2(900, 1200))
	var tail := _spawn(Vector2(846, 1200))
	await get_tree().process_frame
	_drive(lead, Vector2(1400, 1200))
	_drive(tail, Vector2(1400, 1200))
	var t0 := tail.global_position.x
	await _run(5.0)
	var dx := tail.global_position.x - t0
	var expected := tail.move_speed * 5.0
	_report("follow-column", dx > expected * 0.5,
		"follower advanced %.0fpx in 5s (expected >= %.0f)" % [dx, expected * 0.5])
	lead.queue_free()
	tail.queue_free()
