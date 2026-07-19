# res://Structures/Door.gd
extends Structure
class_name Door
# Runtime door for structured maps. Attached by MapLoader._spawn_geo_structure
# via set_script for kind=="door"; MapLoader assigns lock fields after add_child.
#
# OPEN = collision_layer swapped to INTERACTABLES (blocks nothing, still
# point-query clickable), grid tiles unregistered (refcounted), occluder hidden,
# Art faded. CLOSED = today's solid-obstacle behavior. Bashing a closed door
# down (left-click main-hand) is untouched and remains the no-key path.
#
# Option strings are "Open Door"/"Close Door" ON PURPOSE — UI/context_menu.gd's
# "Open" arm is Item-gated and would silently swallow a plain "Open"; these
# names fall through to the default arm, which dispatches interact(option).
# Do not rename.

var is_open := false
var locked := false
var key_id := ""        # Items.json id; "" while locked => sealed, bash-only
var consume_key := false
var lock_key := ""      # "<map_id>|door|<hinge_x>,<hinge_y>" — set by MapLoader

func get_interact_options() -> Array:
	return ["Close Door"] if is_open else ["Open Door"]

func interact(option: String) -> void:
	match option:
		"Open Door":
			if locked:
				var game = _get_game()
				var party: Array = game.party_chars if (game != null and "party_chars" in game) else []
				var res := try_party_unlock(party, key_id, consume_key)
				if not res.ok:
					show_floating_text("Locked", Color.WHITE_SMOKE)
					GameLog.add_entry("The door is locked.")
					return
				locked = false
				GameLog.add_entry("%s unlocks the door with the %s." % [res.holder_name, res.key_name])
				if game != null and ("unlocked_locks" in game) and lock_key != "":
					game.unlocked_locks[lock_key] = true
			open_door()
		"Close Door":
			close_door()

func open_door() -> void:
	if is_open:
		return
	is_open = true
	_apply_open_state()

func close_door() -> void:
	if not is_open:
		return
	if _doorway_blocked_by_character():
		GameLog.add_entry("Something is blocking the doorway.")
		return
	is_open = false
	_apply_open_state()

# Single source of truth for the four coupled systems (physics, A* grid,
# vision-cone occluder, fire/fluid caches).
func _apply_open_state() -> void:
	if is_open:
		collision_layer = CollisionLayers.INTERACTABLES
		for t in occupied_tiles:
			GridManager.unregister_obstacle(t)   # refcounted; junction tiles shared with walls stay blocked
		# self_modulate, NOT modulate: take_damage's flash tween owns modulate
		_visual().self_modulate = Color(1, 1, 1, 0.35)
	else:
		collision_layer = CollisionLayers.STRUCTURE_LAYERS
		for t in occupied_tiles:
			GridManager.register_obstacle(t)
		_visual().self_modulate = Color.WHITE
	var occ: Node = get_node_or_null("Occluder")   # named by MapLoader
	if occ == null:
		for c in get_children():
			if c is LightOccluder2D:
				occ = c
				break
	if occ != null:
		occ.visible = not is_open   # hidden CanvasItems cast no 2D shadows -> cone pierces the doorway
	_invalidate_sim_caches()

func _invalidate_sim_caches() -> void:
	# Mirrors Game._on_structure_destroyed: an opened doorway changes fire fuel
	# occupancy and fluid flow edges exactly like a destroyed wall does.
	var game = _get_game()
	if game == null:
		return
	if ("surface_manager" in game) and game.surface_manager and game.surface_manager.cell_fire \
			and is_instance_valid(game.surface_manager.cell_fire):
		game.surface_manager.cell_fire.invalidate_fuel()
	if ("fluid_manager" in game) and game.fluid_manager and game.fluid_manager.cell_fluid \
			and is_instance_valid(game.fluid_manager.cell_fluid):
		game.fluid_manager.cell_fluid.invalidate_edges()

func _doorway_blocked_by_character() -> bool:
	var space := get_world_2d().direct_space_state
	if space == null:
		return false
	var q := PhysicsShapeQueryParameters2D.new()
	q.shape = collision_shape.shape
	q.transform = collision_shape.get_global_transform()
	q.collision_mask = CollisionLayers.CHARACTERS
	q.collide_with_bodies = true
	# The open door's own body is on INTERACTABLES — a CHARACTERS-mask query never self-hits.
	return not space.intersect_shape(q, 1).is_empty()

func _get_game() -> Node:
	# The "game" group has NO members in production (see MapLoader.gd);
	# current_scene fallback is the live path. The group hook exists for tests.
	var g = get_tree().get_first_node_in_group("game")
	return g if g != null else get_tree().current_scene

# Reusable party-wide key gate. Locked CONTAINERS later call this same static
# (chest gate: Door.try_party_unlock(game.party_chars, item.key, false) before
# show_chest_inventory — Item.gd already parses the dormant per-item "key"
# field). Promote to Global/LockUtil.gd if that reads badly when containers land.
static func try_party_unlock(party: Array, key_item_id: String, consume: bool) -> Dictionary:
	if key_item_id.is_empty():
		return {"ok": false, "key_name": "", "holder_name": ""}
	for c in party:
		if not is_instance_valid(c) or not ("inventory" in c) or c.inventory == null:
			continue
		# a key inside a corpse doesn't open doors — loot it first
		if c.has_method("is_alive") and not c.is_alive():
			continue
		var idx: int = c.inventory.find_item_by_id(key_item_id)
		if idx == -1:
			continue
		var key_name := String(c.inventory.get_item(idx).get("display_name", key_item_id))
		if consume:
			c.inventory.remove_item(idx)   # decrements one stack / removes slot
		var holder := String(c.Name) if ("Name" in c) else "Someone"
		return {"ok": true, "key_name": key_name, "holder_name": holder}
	return {"ok": false, "key_name": "", "holder_name": ""}

func _destroy_structure() -> void:
	if is_open:
		# Tiles were already unregistered on open; the base class unregisters
		# occupied_tiles unconditionally and would corrupt refcounts shared
		# with abutting wall segments.
		occupied_tiles = [] as Array[Vector2i]
	super()
