extends SceneTree
# Headless probe: reproduce structured-map fire state (floor_id strings in
# GridManager.floors, zero Floor nodes) and exercise SurfaceManager spread.

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== fire spread probe ===")
	var gm = root.get_node("GridManager")
	var fdb = root.get_node("FloorDatabase")
	gm.TILE_SIZE = 64
	gm.initialize(3328, 4096)
	# structured-map style logical floors: strings only, no Floor nodes
	for y in range(0, 20):
		for x in range(0, 20):
			gm.floors[Vector2i(x, y)] = "grass"

	var sm_script = load("res://SurfaceManager.gd")
	var sm = sm_script.new()
	root.add_child(sm)
	await process_frame

	print("floor_defs has grass: ", fdb.floor_definitions.has("grass"))
	print("grass flammable: ", fdb.floor_definitions.get("grass", {}).get("flammable", "MISSING"))
	print("_is_floor_flammable(5,6): ", sm._is_floor_flammable(Vector2i(5, 6)))
	print("_is_tile_flammable(5,6, null): ", sm._is_tile_flammable(Vector2i(5, 6), null))

	sm.try_ignite(Vector2i(5, 5))
	print("after try_ignite, surface tiles: ", sm.surface_grid.size(), " keys: ", sm.surface_grid.keys())

	for i in range(4):
		sm.update_surfaces(2.1, [], null)
		print("tick %d -> surface tiles: %d" % [i, sm.surface_grid.size()])

	print("=== probe done ===")
	quit(0)
