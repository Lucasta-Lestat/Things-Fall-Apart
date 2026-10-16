# res://tests/exploration_check.gd
#
# Regression guard for the unexplored-fog (Door Kickers) exploration memory.
#
# Run:  godot --headless --path . res://tests/exploration_check.tscn
#
# 1. Masks are per-map and PERSIST across begin_map switches (warp away and
#    back: cleared rooms stay cleared) — the whole point of the system.
# 2. A dimension change since the last visit (map re-authored) resets cleanly.
# 3. The reveal sweep obeys the party LOS rules: near tiles and the wall's own
#    tile reveal (pullback rule), tiles BEHIND the wall and outside the FOV
#    cone stay unexplored.
extends Node2D

var _failures: int = 0


class SightStub:
	extends Node2D
	# Duck-typed stand-in for a party ProceduralCharacter: only what
	# ExplorationManager.sweep reads.
	var sight: float = 1.0
	var fov_angle_degrees: float = 150.0

	func is_alive() -> bool:
		return true

	func get_elevation() -> float:
		return 0.0


func _check(ok: bool, label: String) -> void:
	if not ok:
		_failures += 1
	print("    %-58s %s" % [label, "OK" if ok else "FAIL"])


func _ready() -> void:
	print("=== per-map masks persist across warps ===")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(1024, 1024)  # 16x16 tiles
	ExplorationManager.clear_all()

	ExplorationManager.begin_map("test_map_a", true)
	_check(ExplorationManager.get_texture() != null, "active map has a mask texture")
	_check(ExplorationManager.get_texture().get_size() == Vector2(16, 16),
		"mask texture is one pixel per tile")
	_check(not ExplorationManager.is_explored(Vector2i(3, 3)), "fresh map: nothing explored")
	ExplorationManager.reveal_tile(Vector2i(3, 3))
	_check(ExplorationManager.is_explored(Vector2i(3, 3)), "reveal_tile marks explored")
	_check(not ExplorationManager.is_explored(Vector2i(-1, 3)), "out of bounds is never explored")
	ExplorationManager.finalize_fades()

	ExplorationManager.begin_map("test_map_b", true)
	_check(not ExplorationManager.is_explored(Vector2i(3, 3)), "map B starts fresh")
	ExplorationManager.reveal_tile(Vector2i(5, 5))
	ExplorationManager.finalize_fades()

	ExplorationManager.begin_map("test_map_a", true)
	_check(ExplorationManager.is_explored(Vector2i(3, 3)), "map A kept its explored tile across the warp")
	_check(not ExplorationManager.is_explored(Vector2i(5, 5)), "map B's tile did not leak into map A")

	ExplorationManager.begin_map("test_map_b", true)
	_check(ExplorationManager.is_explored(Vector2i(5, 5)), "map B kept its explored tile too")

	print("=== dimension change resets, disabled maps are inert ===")
	GridManager.initialize(2048, 2048)  # 32x32 now — map A was authored 16x16
	ExplorationManager.begin_map("test_map_a", true)
	_check(not ExplorationManager.is_explored(Vector2i(3, 3)),
		"re-authored dimensions discard the stale mask")

	ExplorationManager.begin_map("test_world_map", false)
	_check(ExplorationManager.get_texture() == null, "disabled map: no mask texture")
	ExplorationManager.reveal_tile(Vector2i(2, 2))  # must not crash
	_check(not ExplorationManager.is_explored(Vector2i(2, 2)), "disabled map records nothing")

	print("=== sweep geometry: FOV cone, wall reveal, wall shadow ===")
	GridManager.initialize(2048, 2048)
	ExplorationManager.begin_map("test_sweep_map", true)

	var viewer := SightStub.new()
	viewer.position = GridManager.map_to_world(Vector2i(16, 16))
	viewer.rotation = 0.0  # facing = Vector2.UP: "ahead" is -y
	add_child(viewer)

	# Wall three tiles ahead, spanning tiles x 15..17 on row y=13. No
	# occlude_top meta on purpose: meta-less bodies always block (the legacy
	# wall case in GridManager.sight_line_clear).
	var wall := StaticBody2D.new()
	wall.collision_layer = CollisionLayers.VISION_BLOCKERS
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(192, 12)
	shape.shape = rect
	wall.add_child(shape)
	wall.position = GridManager.map_to_world(Vector2i(16, 13))
	add_child(wall)
	for i in 3:
		await get_tree().physics_frame

	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	# The per-sweep ray budget intentionally spreads the initial cone over
	# several sweeps; run a handful so the whole cone settles.
	for i in 8:
		ExplorationManager.sweep([viewer], space)

	_check(ExplorationManager.is_explored(Vector2i(16, 16)), "own tile is seen")
	_check(ExplorationManager.is_explored(Vector2i(16, 14)), "open tile ahead is seen")
	_check(ExplorationManager.is_explored(Vector2i(16, 13)), "the wall tile itself is seen (pullback)")
	_check(not ExplorationManager.is_explored(Vector2i(16, 12)), "tile just past the wall is hidden")
	_check(not ExplorationManager.is_explored(Vector2i(16, 10)), "deep wall shadow is hidden")
	_check(ExplorationManager.is_explored(Vector2i(10, 10)), "diagonal tile past the wall's end is seen")
	_check(not ExplorationManager.is_explored(Vector2i(16, 20)), "directly behind is outside the FOV cone")

	# Re-sweeping must not un-explore anything, and the memory must survive a
	# warp round-trip even for tiles revealed by the sweep.
	ExplorationManager.begin_map("test_map_b", true)
	ExplorationManager.begin_map("test_sweep_map", true)
	_check(ExplorationManager.is_explored(Vector2i(16, 14)), "sweep-revealed tile survives a warp round-trip")
	_check(not ExplorationManager.is_explored(Vector2i(16, 12)), "wall shadow still hidden after the round-trip")

	print("=== spawn seeding ===")
	ExplorationManager.seed_explored(Vector2i(25, 25), 1)
	_check(ExplorationManager.is_explored(Vector2i(25, 25)), "seed_explored marks the tile instantly")
	_check(ExplorationManager.is_explored(Vector2i(26, 25)), "seed radius covers the neighbor ring")
	_check(not ExplorationManager.is_explored(Vector2i(28, 25)), "seed radius stays bounded")

	print("=== standing-still memo + occlusion invalidation ===")
	# Rebuild the viewer's memo at the settled state (round-trip cleared it),
	# then knock the wall down. WITHOUT a notify the memo must keep skipping
	# (that is the whole point of the memo); WITH it, the shadow reveals.
	for i in 2:
		ExplorationManager.sweep([viewer], space)
	wall.queue_free()
	for i in 3:
		await get_tree().physics_frame
	for i in 2:
		ExplorationManager.sweep([viewer], space)
	_check(not ExplorationManager.is_explored(Vector2i(16, 12)),
		"unchanged viewpoint: memo skips the fallen wall's shadow")
	ExplorationManager.notify_occlusion_changed()
	for i in 4:
		ExplorationManager.sweep([viewer], space)
	_check(ExplorationManager.is_explored(Vector2i(16, 12)),
		"notify_occlusion_changed: old wall shadow reveals")
	_check(ExplorationManager.is_explored(Vector2i(16, 10)),
		"deep shadow reveals too once the wall is gone")

	print("=== %s ===" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)
