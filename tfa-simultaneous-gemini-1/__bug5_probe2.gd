extends SceneTree

# TEMPORARY diagnostic for BUG 5 — delete after use.
# Boots the real game scene (current_map_id = tg_export), grabs the first party
# character + their real equipped weapon, then drives Game.process_object_hit
# against a real wall Structure repeatedly, printing everything.

func _init():
	call_deferred("_run")

func _run():
	var game_scene: PackedScene = load("res://game.tscn")
	var game = game_scene.instantiate()
	root.add_child(game)
	current_scene = game
	# let _ready + map load + spawns settle
	for i in 30:
		await process_frame

	print("=== map: ", game.current_map_id, "  structures: ", game.structures_in_scene.size())
	var wall = null
	for s in game.structures_in_scene:
		if is_instance_valid(s) and String(s.structure_id) == "stone_wall":
			wall = s
			break
	if wall == null:
		print("NO WALL FOUND"); quit(); return

	var party: Array = game.get_party()
	if party.is_empty():
		print("NO PARTY"); quit(); return
	var attacker = party[0]
	var weapon = attacker.current_main_hand_item
	print("attacker: ", attacker.name, "  weapon: ", weapon)
	if weapon != null:
		print("weapon.damage BEFORE: ", weapon.damage, "  traits: ", weapon.get("traits"))
	print("wall start: ", wall.current_health, "/", wall.max_health, "  resist: ", wall.damage_resistances)

	for i in 60:
		if not is_instance_valid(wall):
			print(">>> wall FREED after ", i, " hits — dies correctly via real path")
			break
		if weapon == null or not is_instance_valid(weapon):
			print("weapon invalid at hit ", i)
			break
		game.process_object_hit(attacker, wall, wall.global_position, weapon, 5.0)
		if i % 5 == 0 and is_instance_valid(wall):
			print("hit ", i, ": weapon.damage=", weapon.damage, " wall hp=", wall.current_health, "/", wall.max_health)
		await process_frame
	if is_instance_valid(wall):
		print(">>> wall STILL ALIVE: ", wall.current_health, "/", wall.max_health, "  weapon.damage AFTER: ", weapon.damage if is_instance_valid(weapon) else "?")
	quit()
