# res://tests/door_lock_test.gd
# Headless assertion harness for lock/key doors.
# Run:  godot --headless --path . res://tests/door_lock_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (pre-existing parse errors
# print noise; runs can flake exit 255 — rerun once).
extends Node2D

const STRUCTURE_SCENE := preload("res://Structures/Structure.tscn")
const DOOR_SCRIPT := preload("res://Structures/Door.gd")
const MAP_LOADER := preload("res://Structures/MapLoader.gd")
const INVENTORY := preload("res://Characters/inventory.gd")

# Door._get_game resolves the "game" group first (empty in production, hook for
# tests); these two mirror Game.gd's contract.
var party_chars: Array = []
var unlocked_locks: Dictionary = {}

var failures := 0

class StubChar:
	extends Node2D
	var Name := "Tester"
	var inventory: Node = null

func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])

func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(20 * 64, 20 * 64)
	_case_set_script_parity()
	await _case_open_close_idempotent()
	await _case_refcount_neighbor()
	_case_locked_sealed()
	_case_unlock_end_to_end()
	await _case_destroy()
	await _case_pathing()
	_case_maploader_pipeline()
	await _case_close_blocked()
	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

var _blank: ImageTexture

func _blank_tex() -> ImageTexture:
	if _blank == null:
		var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		_blank = ImageTexture.create_from_image(img)
	return _blank

# Mimic MapLoader's door spawn: swap script BEFORE property assignment, use the
# blank-texture path (the database texture PNG is not guaranteed to exist),
# register tiles like the loader does.
func _spawn_door(tiles: Array[Vector2i]) -> Door:
	var inst: Structure = STRUCTURE_SCENE.instantiate()
	inst.set_script(DOOR_SCRIPT)
	inst.structure_id = &"door_wood"
	inst.skip_grid_snap = true
	inst.use_custom_texture = true
	inst.custom_texture = _blank_tex()
	inst.custom_size = Vector2(8, 8)
	inst.occupied_tiles = tiles
	for t in tiles:
		GridManager.register_obstacle(t)
	add_child(inst)
	return inst as Door

# 1. SET_SCRIPT PARITY: the swapped instance is a full Structure
func _case_set_script_parity() -> void:
	var door := _spawn_door([Vector2i(3, 3), Vector2i(4, 3)] as Array[Vector2i])
	_check("parity.is-door", door is Door)
	_check("parity.starts-closed", not door.is_open)
	_check("parity.structure-layers", door.collision_layer == CollisionLayers.STRUCTURE_LAYERS,
		"layer=%d" % door.collision_layer)
	_check("parity.hp-from-db", door.max_health == 50, "hp=%d" % door.max_health)
	_check("parity.resources-applied", door.resources.has(&"wood"))
	_check("parity.tile-blocked", not GridManager.would_walk(Vector2i(3, 3)))
	door.occupied_tiles = [] as Array[Vector2i]   # leave grid state for later cases
	GridManager.unregister_obstacle(Vector2i(3, 3))
	GridManager.unregister_obstacle(Vector2i(4, 3))
	door.queue_free()

# 2. OPEN/CLOSE + IDEMPOTENCE
func _case_open_close_idempotent() -> void:
	var door := _spawn_door([Vector2i(3, 3), Vector2i(4, 3)] as Array[Vector2i])
	var occ := LightOccluder2D.new()
	occ.name = "Occluder"
	door.add_child(occ)
	door.open_door()
	_check("open.layer-interactables", door.collision_layer == CollisionLayers.INTERACTABLES)
	_check("open.tiles-walkable",
		GridManager.would_walk(Vector2i(3, 3)) and GridManager.would_walk(Vector2i(4, 3)))
	_check("open.occluder-hidden", not occ.visible)
	_check("open.art-faded", door._visual().self_modulate.a < 1.0)
	door.open_door()   # idempotent: must not double-unregister
	GridManager.register_obstacle(Vector2i(3, 3))
	_check("open.no-double-unregister", not GridManager.would_walk(Vector2i(3, 3)),
		"a second open_door() drained the refcount")
	GridManager.unregister_obstacle(Vector2i(3, 3))
	door.close_door()
	await get_tree().physics_frame
	_check("close.layer-structures", door.collision_layer == CollisionLayers.STRUCTURE_LAYERS)
	_check("close.tiles-blocked",
		not GridManager.would_walk(Vector2i(3, 3)) and not GridManager.would_walk(Vector2i(4, 3)))
	_check("close.occluder-visible", occ.visible)
	_check("close.art-restored", door._visual().self_modulate.a == 1.0)
	door.close_door()   # idempotent
	door.open_door()    # restore tiles to free for later cases
	door.queue_free()
	await get_tree().process_frame

# 3. REFCOUNT NEIGHBOR: junction tile shared with an abutting wall
func _case_refcount_neighbor() -> void:
	var door := _spawn_door([Vector2i(3, 3), Vector2i(4, 3)] as Array[Vector2i])
	GridManager.register_obstacle(Vector2i(3, 3))   # the abutting wall's claim
	door.open_door()
	_check("refcount.junction-stays-blocked", not GridManager.would_walk(Vector2i(3, 3)))
	_check("refcount.own-tile-frees", GridManager.would_walk(Vector2i(4, 3)))
	door.close_door()
	await get_tree().physics_frame
	_check("refcount.closed-blocks-both",
		not GridManager.would_walk(Vector2i(3, 3)) and not GridManager.would_walk(Vector2i(4, 3)))
	GridManager.unregister_obstacle(Vector2i(3, 3))   # wall dies
	_check("refcount.door-still-holds-junction", not GridManager.would_walk(Vector2i(3, 3)))
	door.open_door()
	door.queue_free()

# 4. LOCKED / SEALED
func _case_locked_sealed() -> void:
	var door := _spawn_door([Vector2i(6, 6)] as Array[Vector2i])
	door.locked = true
	door.key_id = "iron_key"
	party_chars = []
	door.interact("Open Door")
	_check("locked.no-key-stays-closed", not door.is_open and door.locked)
	# sealed: locked with no key id, even with a keyed party
	var door2 := _spawn_door([Vector2i(7, 6)] as Array[Vector2i])
	door2.locked = true
	door2.key_id = ""
	var stub := _make_keyed_stub("iron_key")
	party_chars = [stub]
	door2.interact("Open Door")
	_check("sealed.stays-closed", not door2.is_open and door2.locked)
	party_chars = []
	door.open_door(); door2.open_door()   # free tiles
	door.queue_free(); door2.queue_free()
	stub.queue_free()

func _make_keyed_stub(key_id: String) -> StubChar:
	var stub := StubChar.new()
	var inv: Inventory = INVENTORY.new()
	stub.add_child(inv)
	stub.inventory = inv
	add_child(stub)
	inv.add_stack({"id": key_id, "display_name": "Iron Key", "num_stacks": 1})
	return stub

# 5. UNLOCK END-TO-END (retain + consume variants)
func _case_unlock_end_to_end() -> void:
	unlocked_locks.clear()
	var door := _spawn_door([Vector2i(6, 8)] as Array[Vector2i])
	door.locked = true
	door.key_id = "iron_key"
	door.lock_key = "t|door|1,1"
	var stub := _make_keyed_stub("iron_key")
	party_chars = [stub]
	door.interact("Open Door")
	_check("unlock.opened", door.is_open and not door.locked)
	_check("unlock.key-retained", stub.inventory.find_item_by_id("iron_key") != -1)
	_check("unlock.session-recorded", unlocked_locks.has("t|door|1,1"))
	var door2 := _spawn_door([Vector2i(7, 8)] as Array[Vector2i])
	door2.locked = true
	door2.key_id = "iron_key"
	door2.consume_key = true
	door2.lock_key = "t|door|2,2"
	door2.interact("Open Door")
	_check("unlock.consume-opened", door2.is_open)
	_check("unlock.key-consumed", stub.inventory.find_item_by_id("iron_key") == -1)
	party_chars = []
	door.queue_free(); door2.queue_free(); stub.queue_free()

# 6. DESTROY while open (no refcount corruption) and while closed
func _case_destroy() -> void:
	var door := _spawn_door([Vector2i(3, 12), Vector2i(4, 12)] as Array[Vector2i])
	door.open_door()
	door.take_damage({"bludgeoning": 9999})
	await get_tree().process_frame
	await get_tree().process_frame
	_check("destroy-open.tiles-walkable",
		GridManager.would_walk(Vector2i(3, 12)) and GridManager.would_walk(Vector2i(4, 12)))
	GridManager.register_obstacle(Vector2i(4, 12))
	_check("destroy-open.refcount-sane", not GridManager.would_walk(Vector2i(4, 12)))
	GridManager.unregister_obstacle(Vector2i(4, 12))
	_check("destroy-open.refcount-round-trip", GridManager.would_walk(Vector2i(4, 12)))
	var door2 := _spawn_door([Vector2i(6, 12)] as Array[Vector2i])
	var died := [false]
	door2.destroyed.connect(func(_s, _p): died[0] = true)
	door2.take_damage({"bludgeoning": 9999})
	await get_tree().process_frame
	_check("destroy-closed.signal", died[0])
	_check("destroy-closed.tile-walkable", GridManager.would_walk(Vector2i(6, 12)))

# 7. PATHING: the door is the only gap in a full-width wall
func _case_pathing() -> void:
	GridManager.initialize(10 * 64, 10 * 64)
	for x in range(10):
		if x != 4:
			GridManager.register_obstacle(Vector2i(x, 5))
	var door := _spawn_door([Vector2i(4, 5)] as Array[Vector2i])
	var closed_path := GridManager.find_path(Vector2i(4, 2), Vector2i(4, 8))
	_check("pathing.closed-no-route", closed_path.is_empty(), "%d steps" % closed_path.size())
	door.open_door()
	var open_path := GridManager.find_path(Vector2i(4, 2), Vector2i(4, 8))
	_check("pathing.open-routes-through", not open_path.is_empty())
	door.close_door()
	await get_tree().physics_frame
	var reclosed := GridManager.find_path(Vector2i(4, 2), Vector2i(4, 8))
	_check("pathing.reclosed-no-route", reclosed.is_empty())
	door.open_door()
	door.queue_free()

# 8. MAPLOADER PIPELINE: geometry JSON -> locked Door with session re-application
func _case_maploader_pipeline() -> void:
	GridManager.initialize(10 * 64, 10 * 64)
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	ml._current_map_id = "testmap"
	# hinge y=224 sits on a tile-centre row: y=192 would be a tile BOUNDARY,
	# where no tile centre falls within the door's collision reach and
	# occupied_tiles is legitimately empty
	var spec := {"kind": "door", "hinge": [192, 224], "deg": 0.0, "width": 64.0,
		"half": 6.0, "id": "door_wood", "hp": 50, "locked": true, "key_id": "iron_key"}
	var inst = ml._spawn_geo_structure(spec, null, 64)
	_check("pipeline.is-door", inst is Door)
	if not (inst is Door):
		return
	_check("pipeline.locked", inst.locked)
	_check("pipeline.key-id", inst.key_id == "iron_key")
	_check("pipeline.lock-key", inst.lock_key == "testmap|door|192,224", inst.lock_key)
	_check("pipeline.occluder-named", inst.get_node_or_null("Occluder") != null)
	_check("pipeline.occlude-top-meta", inst.has_meta("occlude_top"))
	var blocked := false
	for t in inst.occupied_tiles:
		if not GridManager.would_walk(t):
			blocked = true
	_check("pipeline.tiles-blocked", blocked and not inst.occupied_tiles.is_empty())
	# session re-application: an unlocked lock_key spawns unlocked
	unlocked_locks["testmap|door|192,224"] = true
	var inst2 = ml._spawn_geo_structure(spec, null, 64)
	_check("pipeline.session-unlock-applied", inst2 is Door and not inst2.locked)
	unlocked_locks.clear()

# 9. CLOSE-BLOCKED: a character in the doorway refuses the close
func _case_close_blocked() -> void:
	GridManager.initialize(10 * 64, 10 * 64)
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	ml._current_map_id = "testmap"
	var spec := {"kind": "door", "hinge": [192, 320], "deg": 0.0, "width": 64.0,
		"half": 6.0, "id": "door_wood", "hp": 50}
	var door = ml._spawn_geo_structure(spec, null, 64)
	door.open_door()
	var body := CharacterBody2D.new()
	body.collision_layer = CollisionLayers.CHARACTERS
	var cs := CollisionShape2D.new()
	var circ := CircleShape2D.new()
	circ.radius = 12.0
	cs.shape = circ
	body.add_child(cs)
	body.position = Vector2(224, 320)   # door center: hinge + leaf/2
	add_child(body)
	await get_tree().physics_frame
	await get_tree().physics_frame
	door.close_door()
	_check("close-blocked.refused", door.is_open)
	body.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame
	door.close_door()
	_check("close-blocked.clears-after", not door.is_open)
