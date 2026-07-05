extends SceneTree

# TEMPORARY diagnostic for BUG 5 — delete after use.
# Instantiates the real Structure.tscn the same way MapLoader._spawn_geo_structure
# does (hp override AFTER add_child), then hits it with the real melee dict shape.

func _init():
	call_deferred("_run")

func _run():
	print("autoload StructureDatabase present: ", root.has_node("StructureDatabase"))
	print("autoload GridManager present: ", root.has_node("GridManager"))
	var scene: PackedScene = load("res://Structures/Structure.tscn")
	var inst = scene.instantiate()
	inst.structure_id = &"stone_wall"
	inst.skip_grid_snap = true
	inst.use_custom_texture = true
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	inst.custom_texture = ImageTexture.create_from_image(img)
	inst.custom_size = Vector2(8, 8)
	inst.position = Vector2(100, 100)
	inst.occupied_tiles = [Vector2i(1, 1)] as Array[Vector2i]
	root.add_child(inst)
	# MapLoader hp override AFTER add_child
	inst.max_health = 105
	inst.current_health = inst.max_health
	print("start: ", inst.current_health, "/", inst.max_health)

	# melee dict exactly as process_object_hit builds it (duplicate + float str bonus)
	var weapon_damage := {"slashing": 12}
	for i in 40:
		if not is_instance_valid(inst):
			print("wall freed after ", i, " hits — DIES CORRECTLY")
			break
		var attack_damage: Dictionary = weapon_damage.duplicate()
		for dtype in attack_damage:
			attack_damage[dtype] += 1.2
		inst.take_damage(attack_damage, 0)
		await process_frame  # let queue_free flush
	if is_instance_valid(inst):
		print("wall STILL ALIVE at ", inst.current_health, "/", inst.max_health)
	quit()
