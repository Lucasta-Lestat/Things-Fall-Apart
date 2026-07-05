extends SceneTree
# Probe 3: natural engine ticking (real Game._process path) on tg_export.
# Ignite grass, then just let frames pass and watch surface_grid.

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== probe3: natural ticking ===")
	var game = load("res://game.tscn").instantiate()
	root.add_child(game)
	await process_frame
	await process_frame
	game.load_map("tg_export")
	await process_frame

	var pm = root.get_node_or_null("PauseManager")
	print("PauseManager.is_paused after load: ", pm.is_paused if pm else "NO PauseManager NODE")

	var gm = root.get_node("GridManager")
	var sm = game.surface_manager

	# same open-grass finder as probe2 (compact)
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

	var world: Vector2 = gm.map_to_world(target)
	sm.try_ignite_area(world, 80.0)
	print("ignited at ", target, ", fire tiles = ", sm.surface_grid.size())

	# let ~9 seconds of frames pass naturally
	for sec in range(9):
		var t := 0.0
		while t < 1.0:
			await process_frame
			t += 1.0 / 60.0
		print("after ~%ds: paused=%s fire tiles=%d spread_timer=%.2f" % [
			sec + 1, str(pm.is_paused) if pm else "?", sm.surface_grid.size(), sm._spread_timer])

	print("=== probe3 done ===")
	quit(0)
