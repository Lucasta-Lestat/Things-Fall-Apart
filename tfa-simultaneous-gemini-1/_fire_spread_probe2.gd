extends SceneTree
# Full in-game repro: boot game.tscn headless, load structured map tg_export,
# ignite open grass like a fireball impact, tick surfaces, count fire tiles.

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== probe2: full game, structured map ===")
	var game = load("res://game.tscn").instantiate()
	root.add_child(game)
	await process_frame
	await process_frame

	game.load_map("tg_export")
	await process_frame

	var gm = root.get_node("GridManager")
	var sm = game.surface_manager
	print("structures_in_scene: ", game.structures_in_scene.size())
	print("map_rect: ", gm.map_rect)

	# find an open grass tile: grass floor, no structure occupancy
	var occupied := {}
	for s in game.structures_in_scene:
		if is_instance_valid(s):
			for t in s.occupied_tiles:
				occupied[t] = true
	var target := Vector2i(-1, -1)
	for y in range(4, gm.map_rect.size.y - 4):
		for x in range(4, gm.map_rect.size.x - 4):
			var p = Vector2i(x, y)
			if gm.floors.get(p, "") != "grass":
				continue
			var clear := true
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					if occupied.has(p + Vector2i(dx, dy)):
						clear = false
			if clear:
				target = p
				break
		if target.x >= 0:
			break
	print("open grass tile: ", target, " floor_id: ", gm.floors.get(target, "?"))

	var world: Vector2 = gm.map_to_world(target)
	print("_is_tile_flammable(target, game): ", sm._is_tile_flammable(target, game))
	print("_is_floor_flammable(target): ", sm._is_floor_flammable(target))

	# fireball impact
	sm.try_ignite_area(world, 80.0)
	print("after try_ignite_area: fire tiles = ", sm.surface_grid.size())

	for i in range(4):
		sm.update_surfaces(2.1, game.characters_in_scene, game)
		print("tick %d -> fire tiles: %d" % [i, sm.surface_grid.size()])

	print("=== probe2 done ===")
	quit(0)
