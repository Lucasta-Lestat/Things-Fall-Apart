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
var leaf := Vector2.ZERO   # hinge -> free end, world-oriented (set by MapLoader);
                           # the visual swing pivots the Art around -leaf/2
var _swing_sign := 1.0
var _swing_tween: Tween = null

const SWING_RAD := 1.92    # ~110 degrees
const SWING_SECS := 0.22
# NPCs push through town doors constantly, so the creak sits under the
# footsteps; the AI hears a door about as far as a loud footstep.
const DOOR_SFX_DB := -8.0
const DOOR_LOUDNESS := 0.4

func _ready() -> void:
	super()
	_sync_door_pass()
	# publish the exact gap centre (== this node's position: the leaf midpoint)
	# so pathing threads the needle instead of aiming at tile centres
	for t in occupied_tiles:
		GridManager.door_gaps[t] = global_position

func get_interact_options() -> Array:
	return ["Close Door"] if is_open else ["Open Door"]

func interact(option: String) -> void:
	# Tactical pause is for planning — the world is frozen, and that includes
	# doors. Silent refusal: the context menu happens to run while paused (it
	# is the planning UI), but acting on the world mid-pause was never meant
	# to work. (Also keeps the pause-gated LOS sweeps in Game._process honest:
	# opening a door changes line of sight.)
	if PauseManager.is_paused:
		return
	match option:
		"Open Door":
			if locked:
				var game = _get_game()
				var party: Array = game.party_chars if (game != null and "party_chars" in game) else []
				var res := try_party_unlock(party, key_id, consume_key)
				if not res.ok:
					show_floating_text("Locked", Color.WHITE_SMOKE)
					GameLog.add_entry("The door is locked.")
					SfxManager.play("door_locked", global_position, Vector2(0.95, 1.05), -6.0)
					return
				locked = false
				GameLog.add_entry("%s unlocks the door with the %s." % [res.holder_name, res.key_name])
				SfxManager.play("door_unlock", global_position, Vector2(0.95, 1.05), -6.0)
				if game != null and ("unlocked_locks" in game) and lock_key != "":
					game.unlocked_locks[lock_key] = true
			open_door()
		"Close Door":
			close_door()

## `opener` is who made the noise (null = the party via the context menu):
## HearingManager skips a listener's own sounds and filters NPC-made ones
## by faction, so a townsperson shoving a door doesn't alert the guards.
func open_door(swing_sign: float = 1.0, opener: Node = null) -> void:
	if is_open:
		return
	is_open = true
	_swing_sign = swing_sign
	_apply_open_state()
	SfxManager.play("door_open", global_position, Vector2(0.92, 1.08), DOOR_SFX_DB)
	HearingManager.emit(global_position, DOOR_LOUDNESS, opener)

# Walked into by a character: an unlocked door simply gives way, swinging AWAY
# from the pusher. Locked doors stay shut (the collision stops the body as
# before). Called from ProceduralCharacter's slide-collision scan, so NPCs push
# through unlocked doors exactly like the party does.
func push_open(from_world: Vector2, pusher: Node = null) -> void:
	if is_open or locked or PauseManager.is_paused:
		return
	var side := signf(leaf.cross(from_world - global_position))
	open_door(-side if side != 0.0 else 1.0, pusher)   # rotate away from the pusher
	GameLog.add_entry("The door swings open.")

func close_door(closer: Node = null) -> void:
	if not is_open:
		return
	if _doorway_blocked_by_character():
		# Floats on the door too: the game log starts closed.
		show_floating_text("Blocked", Color.WHITE_SMOKE)
		GameLog.add_entry("Something is blocking the doorway.")
		return
	is_open = false
	_apply_open_state()
	SfxManager.play("door_close", global_position, Vector2(0.92, 1.08), DOOR_SFX_DB)
	HearingManager.emit(global_position, DOOR_LOUDNESS, closer)

# Single source of truth for the four coupled systems (physics, A* grid,
# vision-cone occluder, fire/fluid caches).
func _apply_open_state() -> void:
	if is_open:
		collision_layer = CollisionLayers.INTERACTABLES
		for t in occupied_tiles:
			GridManager.unregister_obstacle(t)   # refcounted; junction tiles shared with walls stay blocked
		# a swung-open leaf is visually unambiguous; keep it near-opaque
		# (_tint_alpha folds the fade into the damage tint, so opening or
		# closing keeps a battered door dark)
		_refresh_tint()
	else:
		collision_layer = CollisionLayers.STRUCTURE_LAYERS
		for t in occupied_tiles:
			GridManager.register_obstacle(t)
		_refresh_tint()
	_animate_swing()
	_sync_door_pass()
	# A door flip is the common way vision-blocking geometry changes: kick the
	# fog sweep's standing-still memo so the room behind reveals immediately
	# instead of on the next periodic re-test.
	ExplorationManager.notify_occlusion_changed()
	var occ: Node = get_node_or_null("Occluder")   # named by MapLoader
	if occ == null:
		for c in get_children():
			if c is LightOccluder2D:
				occ = c
				break
	if occ != null:
		occ.visible = not is_open   # hidden CanvasItems cast no 2D shadows -> cone pierces the doorway
	_invalidate_sim_caches()

# Visual swing: rotate the Art around the HINGE (inst-local -leaf/2). The
# gameplay state (collision/tiles/occluder) flips instantly in
# _apply_open_state; only the leaf's rendering sweeps. Rotating a node by
# theta around local pivot P needs position = P - P.rotated(theta).
func _animate_swing() -> void:
	var art := get_node_or_null("Art") as Node2D
	if art == null or leaf == Vector2.ZERO:
		return
	var pivot := -leaf * 0.5
	var target := SWING_RAD * _swing_sign if is_open else 0.0
	if _swing_tween != null and _swing_tween.is_valid():
		_swing_tween.kill()
	_swing_tween = create_tween()
	_swing_tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_swing_tween.tween_method(_set_swing.bind(art, pivot), art.rotation, target, SWING_SECS)


func _set_swing(a: float, art: Node2D, pivot: Vector2) -> void:
	art.rotation = a
	art.position = pivot - pivot.rotated(a)


func _tint_alpha() -> float:
	return 0.85 if is_open else 1.0


## Hover readout: "Locked" when a key exists somewhere, "Barred" when locked
## with no key (sealed, bash-only), so the player knows whether to look for one.
func get_hover_status() -> String:
	if is_open:
		return "Open"
	if locked:
		return "Locked" if key_id != "" else "Barred"
	return ""


# Closed UNLOCKED doors are pathable-with-cost (GridManager.door_pass): A*
# routes THROUGH them and the walker pushes them open on contact. Locked or
# open doors leave the set (open ones aren't obstacles at all). Idempotent —
# _ready runs before MapLoader assigns `locked`, and MapLoader re-syncs after.
var _pass_registered := false
func _sync_door_pass() -> void:
	var want := (not is_open) and (not locked)
	if want == _pass_registered:
		return
	_pass_registered = want
	for t in occupied_tiles:
		GridManager.set_door_pass(t, want)


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
	if _pass_registered:
		_pass_registered = false
		for t in occupied_tiles:
			GridManager.set_door_pass(t, false)   # a bashed-down door is just a gap
	for t in occupied_tiles:
		if GridManager.door_gaps.get(t, Vector2.INF) == global_position:
			GridManager.door_gaps.erase(t)
	if is_open:
		# Tiles were already unregistered on open; the base class unregisters
		# occupied_tiles unconditionally and would corrupt refcounts shared
		# with abutting wall segments.
		occupied_tiles = [] as Array[Vector2i]
	super()
