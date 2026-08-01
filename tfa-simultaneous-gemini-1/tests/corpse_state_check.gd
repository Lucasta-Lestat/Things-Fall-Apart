extends Node2D
# Corpse-state regression harness. Proves the melee-kill corpse contract:
# (1) a character killed INSIDE a physics flush (weapon-hitbox body_entered —
#     the path where body_set_shape_disabled is silently rejected) ends up
#     with NO body on the CHARACTERS layer and a queryable body on CORPSES,
# (2) corpses take no further damage (no floating numbers from lingering DoTs),
# (3) the corpse quacks like a loot container (contents aliases inventory.items,
#     the chest window renders it, the context-menu probe returns the corpse),
# (4) corpses exert zero separation push on the living.
# Run headless:  godot --headless --path . res://tests/corpse_state_check.tscn
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

var _fails := 0
var _checks := 0
var _flush_kill_fired := false


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	await get_tree().process_frame

	var victim := _spawn(Vector2(600, 600))
	var looter := _spawn(Vector2(900, 600))
	victim.inventory.add_stack({"id": "trinket", "display_name": "Test Trinket",
		"num_stacks": 1, "is_stackable": true})
	# Weapon-flatten fixtures (real Items.json weapon so WeaponShape loads):
	# db-style = dict granted AND equipped from the same data; runtime-style =
	# stowed node with NO dict. After death both must be lootable exactly once.
	var sword: Dictionary = ItemDatabase.get_item_data("longsword")
	_report("fixture.longsword-exists", not sword.is_empty(), "")
	victim.inventory.add_item(sword.duplicate())
	victim.inventory.equip_weapon_from_data(sword.duplicate(), "Main")
	victim.inventory.stow_weapon_from_data(sword.duplicate())
	await get_tree().physics_frame

	# --- 1. kill from inside a physics flush (the melee-hitbox path) ---
	var trigger := Area2D.new()
	trigger.collision_layer = 0
	trigger.collision_mask = CollisionLayers.CHARACTERS
	trigger.monitoring = true
	var cs := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 30.0
	cs.shape = circle
	trigger.add_child(cs)
	add_child(trigger)
	trigger.global_position = victim.global_position
	trigger.body_entered.connect(func(body: Node2D) -> void:
		if body == victim and victim.is_alive():
			_flush_kill_fired = true
			victim.take_damage({"slashing": 9999}, victim.global_position)
	)
	for _i in 4:
		await get_tree().physics_frame
	_report("flush-kill.fired", _flush_kill_fired, "body_entered kill executed")
	_report("flush-kill.dead", not victim.is_alive(), "hp=%d" % victim.current_health)

	# The old code read body_collision_shape.disabled == true here while the
	# physics server still served the shape — assert via QUERY, never the flag.
	var chars_hits := _point_bodies(victim.global_position, CollisionLayers.CHARACTERS)
	var corpse_hits := _point_bodies(victim.global_position, CollisionLayers.CORPSES)
	_report("corpse.off-characters-layer", not chars_hits.has(victim),
		"CHARACTERS query hits corpse: %s" % str(chars_hits.has(victim)))
	_report("corpse.on-corpses-layer", corpse_hits.has(victim),
		"CORPSES query finds corpse: %s" % str(corpse_hits.has(victim)))

	# --- 2. the dead take no damage (stale-number leak) ---
	var dealt := victim.take_damage({"true": 5}, victim.global_position)
	_report("corpse.no-further-damage", dealt == 0, "dealt=%d" % dealt)

	# --- 3. loot container contract ---
	# Weapon flatten: two sword NODES (equipped + stowed) existed at death but
	# only ONE matching dict — the flatten must append exactly one more (the
	# runtime-stowed sword) and clear the hands, so the loot window offers two
	# swords and capture/restore can't re-arm the corpse.
	var swords := 0
	for d in victim.contents:
		if d is Dictionary and String(d.get("id", "")) == "longsword":
			swords += 1
	_report("loot.weapons-flattened-deduped", swords == 2, "sword dicts: %d" % swords)
	_report("loot.hands-cleared",
		victim.inventory.main_hand_item == null and victim.inventory.stowed_items.is_empty(), "")

	var alias_ok: bool = victim.contents.size() == victim.inventory.items.size() \
		and victim.contents.size() >= 1
	victim.inventory.items.append({"id": "probe", "display_name": "Probe",
		"num_stacks": 1, "is_stackable": true})
	alias_ok = alias_ok and victim.contents.size() == victim.inventory.items.size()
	_report("loot.contents-aliases-inventory", alias_ok,
		"contents %d / items %d" % [victim.contents.size(), victim.inventory.items.size()])
	var no_equipped := true
	for d in victim.contents:
		if d is Dictionary and d.has("_equipped"):
			no_equipped = false
	_report("loot.equipped-marks-stripped", no_equipped, "")

	var ctx = looter._find_context_menu_target_at(victim.global_position)
	_report("loot.context-probe-finds-corpse", ctx == victim,
		"probe returned: %s" % str(ctx))

	var win := ChestInventoryWindow.new()
	win.chest_item = victim
	add_child(win)
	await get_tree().process_frame
	var slots := win._grid.get_child_count() if win._grid != null else -1
	_report("loot.window-renders-corpse", slots == victim.contents.size(),
		"slots=%d contents=%d" % [slots, victim.contents.size()])
	win.queue_free()

	# --- 4. corpses exert no separation push ---
	looter.global_position = victim.global_position + Vector2(10, 0)
	for _i in 2:
		await get_tree().physics_frame
	var sep: Vector2 = looter.get_separation_vector()
	_report("corpse.no-separation-push", sep.length() < 0.001, "sep=%s" % str(sep))

	print("corpse_state_check: %d checks, %d FAIL" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _spawn(pos: Vector2) -> ProceduralCharacter:
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	c.is_player_controlled = true   # AI FSM stays out of the way
	add_child(c)
	c.global_position = pos
	c.hold_position = true          # belt & braces: no AI-issued moves
	return c


func _point_bodies(world_pos: Vector2, mask: int) -> Array:
	var query := PhysicsPointQueryParameters2D.new()
	query.position = world_pos
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.collision_mask = mask
	var out: Array = []
	for hit in get_world_2d().direct_space_state.intersect_point(query, 8):
		out.append(hit.get("collider"))
	return out


func _report(name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("%s %s: %s" % ["PASS" if ok else "FAIL", name, detail])
