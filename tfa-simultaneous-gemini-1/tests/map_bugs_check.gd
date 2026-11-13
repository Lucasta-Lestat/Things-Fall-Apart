# res://tests/map_bugs_check.gd
# The 2026-11-12 playtest bug pass, through the REAL game on tg_hillside_lower
# (the start map):
#  - the piazza fountain spawns as a solid Structure, not a walk-over Item
#  - item memory: a seen item stays drawn out of sight; moved/taken unseen it
#    leaves a ghost at the last-seen spot until that spot is seen again
#  - bleeding: a bleed tick leaves visible blood in the cell fluid sim; a hit's
#    spatter node is not a permanent emitter
#  - shooting a merchant: the victim panics (or, nerve held, fights back) and a
#    merchant who saw it takes a grudge; nobody searches their own feet
#  - trade: "Balance with Gold" pays a shortfall and takes change back
# Run:  godot --headless --path . res://tests/map_bugs_check.tscn
# Judge by the DONE line.
extends Node2D

var failures := 0
var checks := 0
var game = null


func _check(check_name: String, cond: bool, detail: String = "") -> void:
	checks += 1
	if cond:
		print("PASS %s %s" % [check_name, detail])
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])


func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame


func _ready() -> void:
	TimeManager.pause_time()
	await get_tree().process_frame
	var GameScene := load("res://game.tscn")
	game = GameScene.instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _frames(2)
	game.load_map("tg_hillside_lower")
	await _frames(6)
	_check("map.loaded", game.current_map_id == "tg_hillside_lower")
	_case_fountain()
	await _case_item_memory()
	await _case_bleeding()
	await _case_shoot_merchant()
	await _case_trade_balance()
	print("MAP BUGS DONE: %d checks, failures=%d" % [checks, failures])
	get_tree().quit(1 if failures > 0 else 0)


func _case_fountain() -> void:
	var prop: Structure = null
	for s in game.structures_in_scene:
		if is_instance_valid(s) and s.has_meta("prop_item_id") and str(s.get_meta("prop_item_id")) == "piazza_fountain":
			prop = s
	_check("fountain.is-structure", prop != null)
	var as_item := false
	for it in game.items_in_scene:
		if is_instance_valid(it) and str((it as Item).id) == "piazza_fountain":
			as_item = true
	_check("fountain.not-an-item", not as_item)
	if prop == null:
		return
	var t: Vector2i = GridManager.world_to_map(prop.global_position)
	_check("fountain.blocks-pathing", GridManager._obstacle_refs.has(t),
		"tile %s" % str(t))
	_check("fountain.solid-collider", prop.collision_layer != 0 and not prop.get_node("CollisionShape2D").disabled)
	_check("fountain.art", prop.get_node_or_null("Art") is Sprite2D and prop.visible)
	_check("fountain.name", prop.get_display_name() == "Fountain", prop.get_display_name())


func _far_item() -> Item:
	# an ordinary loose item the party can't see from the spawn
	var best: Item = null
	for it in game.items_in_scene:
		if not is_instance_valid(it) or not (it is Item) or (it as Item).fixed:
			continue
		if game._is_position_visible_to_party((it as Item).global_position):
			continue
		if (it as Item).get_node("Sprite").texture == null:
			continue
		best = it
		break
	return best


func _case_item_memory() -> void:
	game._update_item_los_visibility()
	var it: Item = _far_item()
	_check("memory.found-unseen-item", it != null)
	if it == null:
		return
	_check("memory.unseen-hidden", not it.visible)
	# pretend the party saw it where it stands
	var iid: int = it.get_instance_id()
	game._item_mem[iid] = it.global_transform
	game._item_looks[iid] = game._capture_item_look(it)
	game._update_item_los_visibility()
	_check("memory.remembered-drawn", it.visible)
	_check("memory.no-ghost-unmoved", not game._item_ghosts.has(iid))
	# moved while nobody looks: the real one hides, a ghost holds the old spot
	var old_pos: Vector2 = it.global_position
	it.global_position = old_pos + Vector2(96, 0)
	# Item is an AnimatableBody2D: a position write lands on the physics frame
	await _frames(2)
	game._update_item_los_visibility()
	var g = game._item_ghosts.get(iid)
	_check("memory.moved-hidden", not it.visible)
	_check("memory.ghost-at-last-seen", g != null and is_instance_valid(g) and (g as Node2D).global_position.distance_to(old_pos) < 1.0,
		"" if g == null else str((g as Node2D).global_position))
	# taken while nobody looks: the ghost stays
	game.items_in_scene.erase(it)
	GridManager.unregister_object(GridManager.world_to_map(it.global_position), it)
	it.queue_free()
	await _frames(1)
	game._update_item_los_visibility()
	g = game._item_ghosts.get(iid)
	_check("memory.ghost-outlives-item", g != null and is_instance_valid(g))
	# a never-seen moved item makes no ghost
	var other: Item = _far_item()
	if other != null:
		other.global_position += Vector2(64, 0)
		await _frames(2)
		game._update_item_los_visibility()
		_check("memory.never-seen-no-ghost", not game._item_ghosts.has(other.get_instance_id()) and not other.visible)


func _npcs(template: String) -> Array:
	var out: Array = []
	for c in game.characters_in_scene:
		if is_instance_valid(c) and c.is_alive() and not (c in game.party_chars) \
				and str(c.get("template_id") if "template_id" in c else "") == template:
			out.append(c)
	if out.is_empty():
		for c in game.characters_in_scene:
			if is_instance_valid(c) and c.is_alive() and not (c in game.party_chars) and str(c.faction_id) == "neutral":
				out.append(c)
	return out


func _case_bleeding() -> void:
	var ms: Array = _npcs("merchant")
	_check("bleed.found-npc", not ms.is_empty())
	if ms.is_empty():
		return
	var m = ms[0]
	var fm = game.fluid_manager
	var cell_sim: bool = fm.cell_fluid != null and fm.cell_fluid.active_sim()
	var inst = m.condition_manager.apply_condition("bleeding", null, 3)
	_check("bleed.applied", inst != null)
	m._handle_bleed_puddle(inst, {"amount": 0.3, "per_stack": 0.04})
	# the tile projection follows the cell sim's own tick
	TimeManager.resume_time()
	for i in range(40):
		await get_tree().process_frame
	TimeManager.pause_time()
	var tile: Vector2i = GridManager.world_to_map(m.global_position)
	var found := false
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if fm.get_fluid_type_at(tile + Vector2i(dx, dy)) == "blood":
				found = true
	if cell_sim:
		# the drop must sit deep enough to render (CellFluidFX.FULL ~0.35):
		# the old 0.05 deposit was invisible
		var cid: int = fm.cell_fluid.graph.cell_at(m.global_position + Vector2(0, 3))
		var deepest := 0.0
		for c in fm.cell_fluid.active:
			deepest = maxf(deepest, float(fm.cell_fluid.amount[c]))
		_check("bleed.drop-visible-depth", deepest >= 0.25, "deepest %.3f" % deepest)
	_check("bleed.blood-on-ground", found, "cell_sim=%s" % str(cell_sim))
	# a hit's spatter must not leave a live emitter behind
	m._spawn_bleed_burst(Vector2.ZERO, 2.0)
	await _frames(1)
	var live := 0
	for ch in m.get_children():
		if ch.name.begins_with("Bleeding") or (ch.get_script() != null and str(ch.get_script().resource_path).ends_with("vfx/bleeding.gd")):
			var drip = ch.get_node_or_null("DripParticles")
			if drip != null and drip.emitting and not ch.get("_persistent"):
				live += 1
	_check("bleed.burst-no-permanent-emitter", live == 0, "%d live" % live)
	m.condition_manager.remove_condition("bleeding")


func _case_shoot_merchant() -> void:
	var ms: Array = _npcs("merchant")
	if ms.size() < 2:
		_check("shoot.two-merchants", false, "%d" % ms.size())
		return
	var victim = ms[0]
	var other = ms[1]
	var shooter = game.party_chars[0]
	# put the shooter in plain view of both, a few tiles off
	shooter.global_position = victim.global_position + Vector2(160, 0)
	other.global_position = victim.global_position + Vector2(0, 120)
	await _frames(3)
	# the witness faces the shooter (sight is a cone)
	other.rotation = (shooter.global_position - other.global_position).angle() + PI / 2.0
	victim.take_damage({"piercing": 4}, victim.global_position, shooter)
	await _frames(2)
	var vai = victim.get_node("AI")
	var panicked: bool = victim.condition_manager.has_active_condition("panicked")
	_check("shoot.victim-grudge", vai._holds_grudge(shooter))
	_check("shoot.victim-panics-or-fights", panicked or vai.current_target == shooter,
		"panicked=%s target=%s" % [str(panicked), str(vai.current_target)])
	_check("shoot.victim-not-searching-own-feet",
		panicked or vai.last_heard_position.distance_to(victim.global_position) > 32.0,
		str(vai.last_heard_position))
	var oai = other.get_node("AI")
	_check("shoot.witness-grudge", oai._holds_grudge(shooter),
		"other sees shooter: %s" % str(CrimeManager.has_visual_los(other, shooter.global_position, 0.0)))
	_check("shoot.is-enemy-now", oai._is_enemy(shooter) and vai._is_enemy(shooter))
	# a fellow party member is no grudge target for the shooter's side
	_check("shoot.no-grudge-on-bystander-party", not oai._holds_grudge(game.party_chars[1]) if game.party_chars.size() > 1 else true)


func _case_trade_balance() -> void:
	var ms: Array = _npcs("merchant")
	if ms.is_empty():
		_check("trade.found-npc", false)
		return
	var npc = ms[ms.size() - 1]
	# a living, calm trader: clear whatever the shooting case did to it
	npc.condition_manager.remove_condition("panicked")
	var buyer = game.party_chars[0]
	game.primary_selected = buyer
	buyer.inventory.add_stack({"id": "gold", "display_name": "Gold", "cost": 1.0, "is_stackable": true,
		"max_stack_size": 9999, "num_stacks": 500, "traits": {"Currency": 1}, "type": "item"})
	npc.inventory.add_stack({"id": "gold", "display_name": "Gold", "cost": 1.0, "is_stackable": true,
		"max_stack_size": 9999, "num_stacks": 50, "traits": {"Currency": 1}, "type": "item"})
	npc.inventory.add_item({"id": "test_vase", "display_name": "Test Vase", "cost": 37.0, "type": "item"})
	var tw := TradeWindow.new()
	tw.npc = npc
	game.add_child(tw)
	await _frames(1)
	# the buyer takes the vase without paying
	var vidx: int = npc.inventory.find_item_by_id("test_vase")
	var vase: Dictionary = npc.inventory.remove_item(vidx)
	buyer.inventory.add_item(vase)
	_check("trade.short-before", tw.net_to_npc() < 0.0, "%.1f" % tw.net_to_npc())
	var coins: int = tw.balance_with_currency()
	_check("trade.paid-shortfall", coins == 37 and absf(tw.net_to_npc()) < 0.01, "coins %d net %.1f" % [coins, tw.net_to_npc()])
	_check("trade.accept-enabled", not tw._accept_button.disabled)
	# overpay by 20, then take change back
	var gidx: int = buyer.inventory.find_item_by_id("gold")
	var overpay: Dictionary = buyer.inventory.items[gidx].duplicate(true)
	overpay["num_stacks"] = 20
	buyer.inventory.items[gidx]["num_stacks"] = int(buyer.inventory.items[gidx]["num_stacks"]) - 20
	npc.inventory.add_stack(overpay)
	_check("trade.over-before", tw.net_to_npc() >= 19.99, "%.1f" % tw.net_to_npc())
	var back: int = tw.balance_with_currency()
	_check("trade.change-returned", back == 20 and absf(tw.net_to_npc()) < 0.01, "back %d net %.1f" % [back, tw.net_to_npc()])
	tw._on_cancel_pressed()
	await _frames(1)
