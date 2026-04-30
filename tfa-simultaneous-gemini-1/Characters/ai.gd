extends Node

# Parent reference — set in _ready()
var character: ProceduralCharacter
var game

# ===== AI STATE MACHINE =====
enum AIState {
	DEAD,
	IDLE,
	PATROL,
	CHASE,
	APPROACH,
	ATTACK,
	RETREAT,
	STUNNED
}

# Current state
var current_state: AIState = AIState.IDLE
var state_timer: float = 0.0

# Target tracking
var current_target: ProceduralCharacter = null
var last_known_target_pos: Vector2 = Vector2.ZERO

# Goal system
var current_goal: String = "idle"
var target_item: Node = null
var goal_reassess_timer: float = 0.0
const GOAL_REASSESS_INTERVAL: float = 2.0

# Wander settings
var wander_cooldown: float = 0.0
const WANDER_COOLDOWN_TIME: float = 3.0
const WANDER_RANGE_TILES: int = 5

# Hunger
var hunger: float = 0.0
const HUNGER_THRESHOLD: float = 50.0

# Interaction
var interact_options = ["Attack", "Talk"]

# Detection settings — initialized in _ready() from character stats
var detection_range: float
var attack_range: float
var preferred_range: float
var too_close_range: float

# Line of sight — uses character.effective_fov() for FOV

# Minimum approach distance
var min_approach_distance: float:
	get: return character.collision_radius + character.minimum_separation + 10.0

# Behavior settings
@export var aggression: float = 0.7
@export var reaction_time: float = 0.15
@export var attack_cooldown: float = 0.2

# Timing
var attack_cooldown_timer: float = 0.0
var reaction_timer: float = 0.0

# Panic/fear state
var panic_direction_timer: float = 0.0
var frightened_repath_timer: float = 0.0

# Path following
var nav_path: Array[Vector2i] = []
var nav_path_index: int = 0

# Signals
signal state_changed(old_state: AIState, new_state: AIState)
signal target_acquired(target: ProceduralCharacter)
signal target_lost()

func _ready():
	character = get_parent()
	game = get_tree().current_scene
	detection_range = 1440.0 * character.sight
	attack_range = 70.0 * character.body_size_mod
	preferred_range = 40.0 * character.body_size_mod
	too_close_range = 20.0 * character.body_size_mod


# ===== MAIN AI LOOP =====

func process_ai(delta: float) -> void:
	# Update timers
	attack_cooldown_timer = max(0, attack_cooldown_timer - delta)
	reaction_timer = max(0, reaction_timer - delta)
	state_timer += delta

	# Handle unconscious — no actions possible
	var _cm = character.get_node_or_null("ConditionManager")
	if _cm and _cm.has_condition("unconscious"):
		return

	# Handle stunned state
	if current_state == AIState.STUNNED:
		if not "stunned" in character.conditions:
			_change_state(AIState.IDLE)
		return

	# Handle panicked — random movement, overrides everything
	if _cm and _cm.has_active_condition("panicked"):
		_process_panicked(delta)
		return

	# Handle frightened — flee from fear source, overrides combat
	if _cm and _cm.has_active_condition("frightened"):
		_process_frightened(delta)
		return

	# Check path progress for wandering/seeking
	_check_path_progress()

	# Update combat target
	_update_target()

	# Combat state machine
	match current_state:
		AIState.DEAD:
			pass
		AIState.IDLE:
			_process_idle(delta)
		AIState.CHASE:
			_process_chase(delta)
		AIState.APPROACH:
			_process_approach(delta)
		AIState.ATTACK:
			_process_attack(delta)
		AIState.RETREAT:
			_process_retreat(delta)

	# Goal system runs when idle with no combat target
	if current_state == AIState.IDLE and current_target == null:
		goal_reassess_timer += delta
		if goal_reassess_timer >= GOAL_REASSESS_INTERVAL:
			goal_reassess_timer = 0.0
			reassess_goals()
		if wander_cooldown > 0:
			wander_cooldown -= delta
		if not character.is_moving and nav_path.is_empty():
			execute_current_goal()


func die() -> void:
	if current_state == AIState.DEAD:
		return
	current_state = AIState.DEAD
	current_target = null
	nav_path.clear()


# ===== LINE OF SIGHT =====

func get_sight_range_pixels() -> float:
	return 1440.0 * character.sight

func get_sight_range_tiles() -> int:
	return int(ceil(get_sight_range_pixels() / GridManager.TILE_SIZE))

func get_facing_vector() -> Vector2:
	return Vector2.UP.rotated(character.rotation)

func is_in_line_of_sight(target_position: Vector2) -> bool:
	var to_target = target_position - character.global_position
	var distance = to_target.length()

	if distance > get_sight_range_pixels():
		return false

	var facing = get_facing_vector()
	var angle_to_target = rad_to_deg(facing.angle_to(to_target.normalized()))
	var half_fov = character.effective_fov() / 2.0

	if abs(angle_to_target) > half_fov:
		return false

	return _has_clear_sight_line(target_position)

func _has_clear_sight_line(target_position: Vector2) -> bool:
	var world := character.get_world_2d()
	if not world:
		return true
	var space := world.direct_space_state
	# Mask 4 = layer 3 (vision_blockers). Structures live there; characters do not.
	var params := PhysicsRayQueryParameters2D.create(character.global_position, target_position, 4)
	params.collide_with_areas = false
	params.collide_with_bodies = true
	return space.intersect_ray(params).is_empty()

func get_items_in_line_of_sight() -> Array:
	var visible_items = []
	var all_items = game.items_in_scene

	for item in all_items:
		if is_instance_valid(item) and is_in_line_of_sight(item.global_position):
			visible_items.append(item)

	return visible_items

func get_characters_in_line_of_sight() -> Array:
	var visible_chars = []
	for c in game.characters_in_scene:
		if c != character and is_instance_valid(c) and is_in_line_of_sight(c.global_position):
			visible_chars.append(c)
	return visible_chars


# ===== TARGET DETECTION =====

func _update_target() -> void:
	# Validate existing target
	if current_target:
		if not is_instance_valid(current_target):
			_lose_target()
			return

		if not current_target.is_alive():
			_lose_target()
			return

		# Hysteresis: lose target at 1.5x detection range
		var dist = character.global_position.distance_to(current_target.global_position)
		if dist > detection_range * 1.5:
			_lose_target()
			return

		last_known_target_pos = current_target.global_position
		return

	# Check for confusion — pick random target from all visible living characters
	var _cm2 = character.get_node_or_null("ConditionManager")
	if _cm2 and _cm2.has_active_condition("confused"):
		var visible_chars: Array = []
		for node in game.characters_in_scene:
			if node == character:
				continue
			var other = node as ProceduralCharacter
			if not other or not other.is_alive():
				continue
			if not is_in_line_of_sight(other.global_position):
				continue
			var dist = character.global_position.distance_to(other.global_position)
			if dist < detection_range:
				visible_chars.append(other)
		if not visible_chars.is_empty():
			_acquire_target(visible_chars[randi() % visible_chars.size()])
		return

	# Get infatuation source to exclude from targeting
	var infatuation_source: Node = null
	if _cm2 and _cm2.has_active_condition("infatuated"):
		var inf_instance = _cm2.conditions.get("infatuated")
		if inf_instance:
			infatuation_source = inf_instance.source

	# Search for new target (must be in LOS)
	var best_target: ProceduralCharacter = null
	var best_distance: float = detection_range

	for node in game.characters_in_scene:
		if node == character:
			continue

		var other = node as ProceduralCharacter
		if not other:
			continue

		if not _is_enemy(other):
			continue

		if not other.is_alive():
			continue

		# Infatuated: skip the charm source
		if infatuation_source and other == infatuation_source:
			continue

		if not is_in_line_of_sight(other.global_position):
			continue

		var dist = character.global_position.distance_to(other.global_position)
		if dist < best_distance:
			best_distance = dist
			best_target = other

	if best_target:
		_acquire_target(best_target)

func _is_enemy(other: ProceduralCharacter) -> bool:
	if character.faction_id == other.faction_id:
		return false

	var factions = game.factions
	if factions:
		if other.faction_id in factions[character.faction_id].enemies:
			return true

	return character.faction_id != "neutral" and other.faction_id != "neutral"

func _acquire_target(target: ProceduralCharacter) -> void:
	current_target = target
	last_known_target_pos = target.global_position
	emit_signal("target_acquired", target)
	# Clear any wander/seek path
	nav_path.clear()
	current_goal = "idle"
	target_item = null
	reaction_timer = reaction_time

func _lose_target() -> void:
	current_target = null
	emit_signal("target_lost")
	_change_state(AIState.IDLE)

func _change_state(new_state: AIState) -> void:
	if new_state == current_state:
		return
	var old_state = current_state
	current_state = new_state
	state_timer = 0.0
	emit_signal("state_changed", old_state, new_state)


# ===== COMBAT STATE PROCESSING =====

func _process_idle(delta: float) -> void:
	if current_target and reaction_timer <= 0:
		_change_state(AIState.CHASE)

func _process_chase(delta: float) -> void:
	if not current_target:
		_change_state(AIState.IDLE)
		return

	var dist = character.global_position.distance_to(current_target.global_position)
	var combined_collision_dist = character.collision_radius + current_target.collision_radius + character.minimum_separation
	var safe_attack_range = max(attack_range, combined_collision_dist + 5.0)

	if dist <= safe_attack_range * 1.2:
		_change_state(AIState.APPROACH)
		return

	var dir_to_target = (current_target.global_position - character.global_position).normalized()
	var target_pos = current_target.global_position - dir_to_target * safe_attack_range * 0.8
	_move_toward(target_pos)

func _process_approach(delta: float) -> void:
	if not current_target:
		_change_state(AIState.IDLE)
		return

	var dist = character.global_position.distance_to(current_target.global_position)
	var dir_to_target = (current_target.global_position - character.global_position).normalized()

	var combined_collision_dist = character.collision_radius + current_target.collision_radius + character.minimum_separation
	var safe_attack_range = max(attack_range, combined_collision_dist + 5.0)
	var safe_preferred_range = max(preferred_range, combined_collision_dist + 10.0)
	var safe_too_close = max(too_close_range, combined_collision_dist)

	# Face the target
	character.target_rotation = dir_to_target.angle() + PI / 2

	if dist > safe_attack_range * 1.5:
		_change_state(AIState.CHASE)
		return

	if dist <= safe_attack_range and dist >= safe_too_close and attack_cooldown_timer <= 0:
		_change_state(AIState.ATTACK)
		return

	# Too close — back up
	if dist < safe_too_close:
		var retreat_dir = -dir_to_target
		var retreat_pos = character.global_position + retreat_dir * (safe_preferred_range - dist + 10)
		_move_toward(retreat_pos)
		return

	# Approach to preferred range or strafe
	if dist > safe_preferred_range:
		var approach_pos = current_target.global_position - dir_to_target * safe_preferred_range
		_move_toward(approach_pos)
	else:
		if randf() < 0.3 * delta:
			var strafe_dir = dir_to_target.rotated(PI / 2 * (1 if randf() > 0.5 else -1))
			_move_toward(character.global_position + strafe_dir * 30)

func _process_attack(delta: float) -> void:
	var combined_collision_dist = character.collision_radius + (current_target.collision_radius if current_target else 0) + character.minimum_separation
	var safe_attack_range = max(attack_range, combined_collision_dist + 5.0)

	if not character.attack_animator.is_attacking:
		character.attack()
		if character.current_main_hand_item:
			attack_cooldown_timer = attack_cooldown / character.attack_speed_multiplier
		else:
			attack_cooldown_timer = attack_cooldown

	if not character.attack_animator.is_attacking:
		_change_state(AIState.APPROACH)
	if current_target and character.global_position.distance_to(current_target.global_position) > 1.5 * safe_attack_range:
		_change_state(AIState.APPROACH)

func _process_retreat(delta: float) -> void:
	if not current_target:
		_change_state(AIState.IDLE)
		return

	var dir_away = (character.global_position - current_target.global_position).normalized()
	var safe_retreat_dist = character.collision_radius + current_target.collision_radius + character.minimum_separation + 50.0
	_move_toward(character.global_position + dir_away * safe_retreat_dist)

	if state_timer > 1.5:
		_change_state(AIState.IDLE)


# ===== CONDITION BEHAVIOR OVERRIDES =====

func _process_panicked(delta: float) -> void:
	# Drop combat target
	if current_target:
		_lose_target()

	panic_direction_timer -= delta
	if panic_direction_timer <= 0 or (not character.is_moving and nav_path.is_empty()):
		# Pick a new random direction
		panic_direction_timer = randf_range(1.0, 2.0)
		var my_tile = GridManager.world_to_map(character.global_position)
		var angle = randf() * TAU
		var dist_tiles = randi_range(3, 5)
		var offset = Vector2(cos(angle), sin(angle)) * dist_tiles
		var target_tile = my_tile + Vector2i(int(offset.x), int(offset.y))

		# Clamp to map bounds and find walkable tile
		target_tile.x = clampi(target_tile.x, GridManager.map_rect.position.x, GridManager.map_rect.position.x + GridManager.map_rect.size.x - 1)
		target_tile.y = clampi(target_tile.y, GridManager.map_rect.position.y, GridManager.map_rect.position.y + GridManager.map_rect.size.y - 1)

		if is_tile_walkable(target_tile):
			navigate_to(GridManager.map_to_world(target_tile))
		else:
			# Try a nearby tile instead
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					var alt = target_tile + Vector2i(dx, dy)
					if is_tile_walkable(alt):
						navigate_to(GridManager.map_to_world(alt))
						return
	else:
		_check_path_progress()


func _process_frightened(delta: float) -> void:
	# Drop combat target
	if current_target:
		_lose_target()

	var _cm = character.get_node_or_null("ConditionManager")
	if not _cm:
		return

	var fear_instance = _cm.conditions.get("frightened")
	if not fear_instance or not is_instance_valid(fear_instance.source):
		return

	var fear_source = fear_instance.source
	var dist_to_source = character.global_position.distance_to(fear_source.global_position)

	frightened_repath_timer -= delta

	# Re-path periodically or when not moving
	if frightened_repath_timer <= 0 or (not character.is_moving and nav_path.is_empty()):
		frightened_repath_timer = 1.0
		var dir_away = (character.global_position - fear_source.global_position).normalized()
		var flee_dist_tiles = 5
		var my_tile = GridManager.world_to_map(character.global_position)
		var target_tile = my_tile + Vector2i(int(dir_away.x * flee_dist_tiles), int(dir_away.y * flee_dist_tiles))

		# Clamp to map bounds
		target_tile.x = clampi(target_tile.x, GridManager.map_rect.position.x, GridManager.map_rect.position.x + GridManager.map_rect.size.x - 1)
		target_tile.y = clampi(target_tile.y, GridManager.map_rect.position.y, GridManager.map_rect.position.y + GridManager.map_rect.size.y - 1)

		if is_tile_walkable(target_tile):
			navigate_to(GridManager.map_to_world(target_tile))
		else:
			# Try angled escape routes
			for angle_offset in [0.5, -0.5, 1.0, -1.0]:
				var alt_dir = dir_away.rotated(angle_offset)
				var alt_tile = my_tile + Vector2i(int(alt_dir.x * flee_dist_tiles), int(alt_dir.y * flee_dist_tiles))
				alt_tile.x = clampi(alt_tile.x, GridManager.map_rect.position.x, GridManager.map_rect.position.x + GridManager.map_rect.size.x - 1)
				alt_tile.y = clampi(alt_tile.y, GridManager.map_rect.position.y, GridManager.map_rect.position.y + GridManager.map_rect.size.y - 1)
				if is_tile_walkable(alt_tile):
					navigate_to(GridManager.map_to_world(alt_tile))
					break
	else:
		_check_path_progress()


# ===== MOVEMENT =====

func _move_toward(target_pos: Vector2) -> void:
	character.target_position = target_pos
	character.is_moving = true
	var dir = (target_pos - character.global_position).normalized()
	if dir.length() > 0.1:
		character.target_rotation = dir.angle() + PI / 2


# ===== PATH FOLLOWING =====

func navigate_to(world_pos: Vector2) -> void:
	var start = GridManager.world_to_map(character.global_position)
	var end_tile = GridManager.world_to_map(world_pos)
	nav_path = GridManager.find_path(start, end_tile)
	nav_path_index = 0
	if not nav_path.is_empty():
		_advance_path()

func _advance_path() -> void:
	if nav_path_index >= nav_path.size():
		nav_path.clear()
		nav_path_index = 0
		return
	var next_tile = nav_path[nav_path_index]
	var next_world = GridManager.map_to_world(next_tile)
	_move_toward(next_world)
	nav_path_index += 1

func _check_path_progress() -> void:
	if nav_path.is_empty():
		return
	if not character.is_moving:
		_advance_path()


# ===== GOAL REASSESSMENT =====

func reassess_goals():
	if character.is_moving:
		return

	# Clear invalid target item
	if target_item and not is_instance_valid(target_item):
		target_item = null
		current_goal = "idle"

	# Priority 1: hunger
	if is_hungry():
		var best_food = find_best_food_in_sight()
		if best_food:
			target_item = best_food
			current_goal = "seek_food"
			return

	# Priority 2: valuables
	var best_valuable = find_most_valuable_item_in_sight()
	if best_valuable:
		target_item = best_valuable
		current_goal = "seek_wealth"
		return

	# Default: wander
	current_goal = "wander"
	target_item = null

func is_hungry() -> bool:
	return hunger >= HUNGER_THRESHOLD

func execute_current_goal():
	match current_goal:
		"idle":
			pass
		"seek_food", "seek_wealth":
			execute_seek_item()
		"wander":
			execute_wander()


# ===== ITEM SEEKING =====

func execute_seek_item():
	if not target_item or not is_instance_valid(target_item):
		current_goal = "idle"
		return

	var my_tile = GridManager.world_to_map(character.global_position)
	var item_tile = GridManager.world_to_map(target_item.global_position)

	# Close enough to pick up
	if my_tile == item_tile or my_tile.distance_to(item_tile) <= 1:
		pickup_item(target_item)
		target_item = null
		current_goal = "idle"
		return

	# Navigate toward the item
	if nav_path.is_empty():
		navigate_to(target_item.global_position)

func find_best_food_in_sight() -> Node:
	var items = get_items_in_line_of_sight()
	var best_food: Node = null
	var best_calories: float = 0.0

	for item in items:
		if not "calories" in item or item.calories <= 0:
			continue
		if is_item_owned_by_ally(item):
			continue
		if not can_reach_item(item):
			continue
		if item.calories > best_calories:
			best_calories = item.calories
			best_food = item

	return best_food

func find_most_valuable_item_in_sight() -> Node:
	var items = get_items_in_line_of_sight()
	var best_item: Node = null
	var best_value: float = 0.0

	for item in items:
		if is_item_owned_by_ally(item):
			continue
		if not can_reach_item(item):
			continue
		var value = item.cost if "cost" in item else 0.0
		if value > best_value:
			best_value = value
			best_item = item

	return best_item

func is_item_owned_by_ally(item: Node) -> bool:
	if not "owner" in item or item.owner == null:
		return false
	if not "faction_id" in item.owner:
		return false
	var factions = game.factions
	if factions and character.faction_id in factions and item.owner.faction_id in factions:
		if item.owner.faction_id in factions[character.faction_id].allies:
			return true
	return character.faction_id == item.owner.faction_id

func can_reach_item(item: Node) -> bool:
	var start_tile = GridManager.world_to_map(character.global_position)
	var end_tile = GridManager.world_to_map(item.global_position)
	var test_path = GridManager.find_path(start_tile, end_tile)
	return not test_path.is_empty()

func pickup_item(item: Node):
	if not is_instance_valid(item):
		return

	GameLog.add_entry(character.Name + " picks up " + item.display_name)

	# If food and hungry, eat immediately
	if current_goal == "seek_food" and "calories" in item:
		eat_food(item)
	else:
		# Add to inventory if possible
		if character.inventory:
			character.inventory.add_item({"display_name": item.display_name, "id": item.id, "node": item})
		item.get_parent().remove_child(item)
		if item in game.items_in_scene:
			game.items_in_scene.erase(item)
		item.queue_free()

func eat_food(item: Node):
	if "calories" in item:
		var hunger_reduced = item.calories * 0.1
		hunger = max(0, hunger - hunger_reduced)
		GameLog.add_entry(character.Name + " eats " + item.display_name)
		if item in game.items_in_scene:
			game.items_in_scene.erase(item)
		item.queue_free()


# ===== WANDERING =====

func execute_wander():
	if wander_cooldown > 0:
		return

	var my_tile = GridManager.world_to_map(character.global_position)
	var wander_target = find_random_wander_target(my_tile)

	if wander_target != Vector2i.MIN:
		navigate_to(GridManager.map_to_world(wander_target))
		wander_cooldown = WANDER_COOLDOWN_TIME
	else:
		wander_cooldown = WANDER_COOLDOWN_TIME * 0.5

func find_random_wander_target(from_tile: Vector2i) -> Vector2i:
	var valid_tiles: Array[Vector2i] = []

	for x in range(-WANDER_RANGE_TILES, WANDER_RANGE_TILES + 1):
		for y in range(-WANDER_RANGE_TILES, WANDER_RANGE_TILES + 1):
			if x == 0 and y == 0:
				continue
			var check_tile = from_tile + Vector2i(x, y)
			if is_tile_walkable(check_tile):
				var test_path = GridManager.find_path(from_tile, check_tile)
				if not test_path.is_empty():
					valid_tiles.append(check_tile)

	if valid_tiles.is_empty():
		return Vector2i.MIN

	return valid_tiles[randi() % valid_tiles.size()]

func is_tile_walkable(tile: Vector2i) -> bool:
	if not GridManager.would_walk(tile):
		return false
	# Check if another character occupies this tile
	for c in game.characters_in_scene:
		if c != character and is_instance_valid(c):
			if GridManager.world_to_map(c.global_position) == tile:
				return false
	return true
