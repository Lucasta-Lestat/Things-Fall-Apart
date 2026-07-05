extends SceneTree
# Probe 4: ignite at realistic combat spots (guard spawn, player spawn) on
# tg_export; natural ticking; report which gate blocks stalled neighbors.

func _initialize() -> void:
	call_deferred("_run")

func _gate(sm, game, p: Vector2i) -> String:
	var gm = root.get_node("GridManager")
	var fm = game.fluid_manager
	if fm and not fm.get_fluid_type_at(p).is_empty():
		return "fluid:" + fm.get_fluid_type_at(p)
	for s in game.structures_in_scene:
		if is_instance_valid(s) and p in s.occupied_tiles:
			return "structure:%s flam=%s" % [s.structure_id, s.flammable]
	var fid = gm.floors.get(p, "<none>")
	return "floor:%s flam=%s" % [fid, sm._is_floor_flammable(p)]

func _run() -> void:
	print("=== probe4 ===")
	var game = load("res://game.tscn").instantiate()
	root.add_child(game)
	await process_frame
	await process_frame
	game.load_map("tg_export")
	await process_frame

	var gm = root.get_node("GridManager")
	var sm = game.surface_manager

	for spot in [Vector2(1789, 1919), Vector2(1469, 1959), Vector2(2029, 2419)]:
		sm.clear_all_surfaces()
		sm.try_ignite_area(spot, 80.0)
		var t0 = sm.surface_grid.size()
		var t := 0.0
		while t < 8.0:
			await process_frame
			t += 1.0 / 60.0
		print("spot ", spot, " tile ", gm.world_to_map(spot),
			": initial=", t0, " after 8s=", sm.surface_grid.size())
		if sm.surface_grid.size() <= t0:
			# report the gates around the initial tiles
			for tp in sm.surface_grid.keys():
				for n in gm.get_neighboring_coords(tp):
					if not sm.surface_grid.has(n):
						print("   ", tp, " -> ", n, " : ", _gate(sm, game, n))
	print("=== probe4 done ===")
	quit(0)
