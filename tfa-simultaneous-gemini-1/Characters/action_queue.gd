# ActionQueue.gd
# Handles queuing and executing player actions in order
# Attach to your player character or use as a component
extends Node
class_name ActionQueue

# Action types
enum ActionType {
	MOVE,           # Move to a position
	FACE,           # Turn to face a direction
	ATTACK,         # Basic attack
	ATTACK_TARGET,  # Attack a specific target
	USE_ITEM,       # Use an item
	CYCLE_WEAPON,   # Switch weapons
	USE_ABILITY,    # Use an ability
	CUSTOM          # For extensibility
}

# Action types that AIM the character. When one of these completes, the aimed
# facing is held for a beat (ProceduralCharacter.begin_facing_hold) so the next
# MOVE segment's path-aligned facing write doesn't snap the body back instantly.
const FACING_HOLD_ACTIONS := [ActionType.FACE, ActionType.ATTACK, ActionType.ATTACK_TARGET]

# An action in the queue
class Action:
	var type: ActionType
	var data: Dictionary
	var created_at: float  # When the action was queued (for display purposes)
	var reticle: Node2D = null  # Reference to the targeting reticle for this action
	
	func _init(action_type: ActionType, action_data: Dictionary = {}) -> void:
		type = action_type
		data = action_data
		created_at = Time.get_ticks_msec() / 1000.0

signal action_queued(action: Action)
signal action_started(action: Action)
signal action_completed(action: Action)
signal action_cancelled(action: Action)
signal queue_cleared

# The queue of pending actions
var queue: Array[Action] = []

# Currently executing action
var current_action: Action = null

# Reference to the character this queue belongs to
var character: ProceduralCharacter = null

# Maximum queue size (0 = unlimited)
@export var max_queue_size: int = 10

# Whether to allow queueing while unpaused
@export var queue_only_when_paused: bool = false

# Reticle settings
@export var reticle_texture: Texture2D = preload("res://targeting icon.png")
@export var reticle_color_attack: Color = Color(1.0, 0.3, 0.3, 0.8)  # Red for attacks
@export var reticle_color_healing: Color = Color(0.3, 1.0, 0.3, 0.8)  # Green for healing
@export var reticle_scale: Vector2 = Vector2(1.0, 1.0)

# Container for reticles (created at runtime)
var reticle_container: Node2D = null

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	character = get_parent() as ProceduralCharacter
	_setup_reticle_container()

func _setup_reticle_container() -> void:
	"""Create a container node for reticles in the scene tree"""
	# We add reticles to a CanvasLayer or the main scene so they render in world space
	reticle_container = Node2D.new()
	reticle_container.name = "ReticleContainer"
	reticle_container.z_index = 10  # Render above most things
	
	# Add to the scene tree (not as child of character so reticles stay in world space)
	call_deferred("_add_reticle_container_to_tree")

func _add_reticle_container_to_tree() -> void:
	"""Deferred addition of reticle container to tree"""
	if character and character.get_tree():
		var root = character.get_tree().current_scene
		if root:
			root.add_child(reticle_container)

func _process(_delta: float) -> void:
	# Don't process actions while paused
	if PauseManager.is_paused:
		return
	
	# If no current action and queue has items, start next action
	if current_action == null and queue.size() > 0:
		_start_next_action()
	
	# Check if current action is complete
	if current_action != null:
		if _is_action_complete(current_action):
			_complete_current_action()

# ===== RETICLE MANAGEMENT =====

func _create_reticle(position: Vector2, action_type: ActionType, data: Dictionary = {}) -> Sprite2D:
	"""Create a targeting reticle at the specified position"""
	if reticle_container == null or reticle_texture == null:
		return null
	
	var reticle = Sprite2D.new()
	reticle.texture = reticle_texture
	reticle.global_position = position
	reticle.scale = reticle_scale
	
	# Set color based on action type and ability effects
	var color = reticle_color_attack  # Default to red
	
	if action_type == ActionType.USE_ABILITY:
		var ability_id = data.get("ability_id", "")
		if ability_id != "":
			var ability = AbilityDatabase.get_ability_data(ability_id)
			if not ability.is_empty() and _ability_has_healing(ability):
				color = reticle_color_healing
	
	reticle.modulate = color
	reticle_container.add_child(reticle)
	
	# Add a subtle animation (optional pulse effect)
	_add_reticle_animation(reticle)
	
	return reticle

func _ability_has_healing(ability) -> bool:
	"""Safely check if an ability has healing in its effects"""
	if ability == null:
		return false
	
	# Try to access effects safely
	var effects = null
	
	# Check if ability has effects property/method
	if "effects" in ability:
		effects = ability.effects
	if effects == null:
		return false
	# Check if healing is in effects
	if effects is Dictionary:
		return effects.has("healing")
	
	return false

func _add_reticle_animation(reticle: Sprite2D) -> void:
	"""Add a pulsing animation to the reticle"""
	var tween = create_tween()
	tween.set_loops()
	tween.tween_property(reticle, "scale", reticle_scale * 1.1, 0.5)
	tween.tween_property(reticle, "scale", reticle_scale, 0.5)

func _create_dash_aim_preview(data: Dictionary) -> AimLine:
	"""Persistent aim ribbon for a directly queued dash (shift while paused):
	the same wall-truncated, range-clamped amber line the live dash-targeting
	mode shows. Stored in action.reticle so the existing complete/cancel
	lifecycle tears it down."""
	if reticle_container == null or character == null:
		return null
	var line := AimLine.new()
	line.default_color = PathDrawer.DASH_COLOR
	reticle_container.add_child(line)
	var target: Vector2 = data.get("dash_target", character.global_position)
	var max_range: float = data.get("dash_max_range", 0.0)
	line.show_aim(character.global_position, target, CollisionLayers.STRUCTURES, max_range)
	return line

func _remove_reticle(action: Action) -> void:
	"""Remove the reticle associated with an action"""
	if action.reticle != null and is_instance_valid(action.reticle):
		action.reticle.queue_free()
		action.reticle = null

func _remove_all_reticles() -> void:
	"""Remove all reticles from the container"""
	if reticle_container != null:
		for child in reticle_container.get_children():
			child.queue_free()

# ===== PUBLIC API =====

func queue_action(type: ActionType, data: Dictionary = {}) -> bool:
	"""Add an action to the queue. Returns false if queue is full."""
	print("attempting to queue an action of type: ", type)
	# Check queue size limit
	if max_queue_size > 0 and queue.size() >= max_queue_size:
		print("exceeded queue size limit")
		return false
	
	var action = Action.new(type, data)
	
	# Create reticle for targeted actions
	if _action_needs_reticle(type, data):
		var target_pos = _get_action_target_position(type, data)
		if target_pos != Vector2.INF:
			action.reticle = _create_reticle(target_pos, type, data)
	elif type == ActionType.CUSTOM and data.get("dash_preview", false):
		action.reticle = _create_dash_aim_preview(data)
	
	queue.append(action)
	emit_signal("action_queued", action)
	return true

func _action_needs_reticle(type: ActionType, data: Dictionary) -> bool:
	"""Determine if an action type should display a targeting reticle"""
	match type:
		ActionType.ATTACK:
			return data.has("target_position")
		ActionType.ATTACK_TARGET:
			return true
		ActionType.USE_ABILITY:
			var target_pos = data.get("target_position", Vector2.INF)
			return target_pos != Vector2.INF
		_:
			return false

func _get_action_target_position(type: ActionType, data: Dictionary) -> Vector2:
	"""Get the target position for an action"""
	match type:
		ActionType.ATTACK:
			return data.get("target_position", Vector2.INF)
		ActionType.ATTACK_TARGET:
			var target = data.get("target")
			if target and is_instance_valid(target):
				return target.global_position
			return Vector2.INF
		ActionType.USE_ABILITY:
			return data.get("target_position", Vector2.INF)
		_:
			return Vector2.INF

func queue_move(target_pos: Vector2) -> bool:
	"""Queue a move action with pathfinding"""
	var start_tile = GridManager.world_to_map(character.global_position)
	var end_tile = GridManager.world_to_map(target_pos)
	var tile_path = GridManager.find_path(start_tile, end_tile, character.jump_height, character.jump_range, character.on_roof)
	var waypoints: Array[Vector2] = []
	for tile in tile_path:
		waypoints.append(GridManager.map_to_world(tile))
	# Fallback: if no path found, go directly (might be same tile or unreachable)
	if waypoints.is_empty():
		waypoints.append(target_pos)
	return queue_action(ActionType.MOVE, {"target_position": target_pos, "waypoints": waypoints, "waypoint_index": 0})

func queue_move_waypoints(waypoints: PackedVector2Array) -> bool:
	"""Queue a move action using freeform waypoints (no A* pathfinding).
	Used by the tactical path system for drawn paths."""
	if waypoints.size() < 2:
		return false
	var wp_array: Array[Vector2] = []
	for wp in waypoints:
		wp_array.append(wp)
	return queue_action(ActionType.MOVE, {
		"target_position": waypoints[waypoints.size() - 1],
		"waypoints": wp_array,
		"waypoint_index": 0,
		"freeform": true,
	})

func queue_dash(target_pos: Vector2) -> bool:
	"""Queue a dash action (straight-line, no pathfinding). dash_preview asks
	queue_action for a persistent amber aim ribbon while the dash is pending —
	node-planted dashes (PathInputHandler) omit it because PathDrawer already
	draws theirs from the node position, not from where the body stands now."""
	return queue_action(ActionType.CUSTOM, {
		"callable": Callable(character, "dash").bind(target_pos),
		"dash_target": target_pos,
		"dash_max_range": character.get_dash_range(),
		"dash_preview": true,
	})

func queue_face(target_pos: Vector2) -> bool:
	"""Queue a face direction action"""
	var angle = (target_pos - character.global_position).angle() + PI / 2
	return queue_action(ActionType.FACE, {"target_rotation": angle})

func queue_attack(target_pos: Vector2) -> bool:
	"""Queue a basic attack with target position for reticle"""
	return queue_action(ActionType.ATTACK, {"target_position": target_pos})

func queue_attack_target(target: ProceduralCharacter) -> bool:
	"""Queue an attack on a specific target"""
	return queue_action(ActionType.ATTACK_TARGET, {"target": target})

func queue_cycle_weapon(direction: int, hand: String = "Main") -> bool:
	"""Queue a weapon switch for a specific hand"""
	return queue_action(ActionType.CYCLE_WEAPON, {"direction": direction, "hand": hand})

func queue_ability(ability_id: String, target_position: Vector2 = Vector2.INF, targets: Array = [], anchor = null) -> bool:
	"""Queue an ability to be used. `targets` is the explicit character list for
	character-targeting abilities. `anchor` is the designated character the aim
	point re-resolves to at execution time (see AbilityManager.ability_follows_anchor)."""
	return queue_action(ActionType.USE_ABILITY, {
		"ability_id": ability_id,
		"target_position": target_position,
		"targets": targets,
		"target_anchor": anchor,
		"needs_targeting": target_position == Vector2.INF
	})

func clear_queue() -> void:
	"""Clear all pending actions"""
	for action in queue:
		_remove_reticle(action)
		emit_signal("action_cancelled", action)
	queue.clear()
	emit_signal("queue_cleared")

func cancel_current() -> void:
	"""Cancel the currently executing action"""
	# A cancelled queue must never leave a planned-facing hold running: the
	# player's manual order (middle-click move, new attack) re-aims immediately.
	if character:
		character.clear_facing_hold()
	if current_action != null:
		_remove_reticle(current_action)
		emit_signal("action_cancelled", current_action)
		current_action = null
		character.is_moving = false

func cancel_all() -> void:
	"""Cancel current action and clear queue"""
	cancel_current()
	clear_queue()

func get_queue_size() -> int:
	return queue.size()

func get_queue() -> Array[Action]:
	return queue

func peek_next() -> Action:
	"""See the next action without removing it"""
	if queue.size() > 0:
		return queue[0]
	return null

func remove_action(index: int) -> bool:
	"""Remove an action from the queue by index"""
	if index >= 0 and index < queue.size():
		var action = queue[index]
		_remove_reticle(action)
		queue.remove_at(index)
		emit_signal("action_cancelled", action)
		return true
	return false

# ===== INTERNAL =====

func _start_next_action() -> void:
	"""Pop the next action from queue and start executing it"""
	if queue.size() == 0:
		return
	
	current_action = queue.pop_front()
	emit_signal("action_started", current_action)
	_execute_action(current_action)

func _execute_action(action: Action) -> void:
	"""Begin executing an action"""
	# An explicit new aim (FACE / ATTACK / ATTACK_TARGET) cancels any running
	# planned-facing hold AND the path angle parked underneath it. Without this a
	# hold armed by the PREVIOUS aim can expire mid-turn and overwrite
	# target_rotation with the stale parked angle - which strands this action
	# forever, because _is_action_complete() compares rotation against THIS
	# angle while the integrator clamps onto the parked one instead.
	if action.type in FACING_HOLD_ACTIONS:
		character.clear_facing_hold()
	match action.type:
		ActionType.MOVE:
			# Clear any stale real-time nav waypoints so _update_movement
			# doesn't drift to old destinations while the action queue drives movement
			character._nav_waypoints.clear()
			character._nav_index = 0
			var waypoints = action.data.get("waypoints", [])
			var wp_index = action.data.get("waypoint_index", 0)
			if waypoints.size() > 0 and wp_index < waypoints.size():
				var wp = waypoints[wp_index]
				character.target_position = wp
				# Path-aligned facing: deferred while a planned turn/attack is still
				# being "held" (see ProceduralCharacter.set_path_facing).
				character.set_path_facing((wp - character.global_position).angle() + PI / 2)
				character.is_moving = true
			else:
				var target_pos = action.data.get("target_position", character.global_position)
				character.target_position = target_pos
				character.set_path_facing((target_pos - character.global_position).angle() + PI / 2)
				character.is_moving = true
		
		ActionType.FACE:
			character.target_rotation = action.data.get("target_rotation", character.rotation)
			character.is_moving = false
		
		ActionType.ATTACK:
			var target_pos = action.data.get("target_position", null)
			if target_pos:
				character.target_rotation = (target_pos - character.global_position).angle() + PI / 2
			character.attack("Main", target_pos)
		
		ActionType.ATTACK_TARGET:
			var target = action.data.get("target")
			if target and is_instance_valid(target):
				# Face the target then attack (live node: rig aim tracks its movement).
				# The position rides along as a last-known fallback, so a target
				# that dies or is freed mid-swing leaves the attack pointed where
				# it was rather than at nothing.
				character.target_rotation = (target.global_position - character.global_position).angle() + PI / 2
				character.attack("Main", target.global_position, target)
		
		ActionType.CYCLE_WEAPON:
			var direction = action.data.get("direction", 1)
			var hand = action.data.get("hand", "Main")
			character.inventory.cycle_weapon_for_hand(hand, direction)
		
		ActionType.USE_ITEM:
			var item_data = action.data.get("item_data", {})
			var item_index = action.data.get("item_index", -1)
			if item_index >= 0 and character.inventory:
				# Same rules as the party panel's Consume (apply_consumable).
				# A use that took no effect keeps the item.
				if apply_consumable(character, character, item_data):
					character.inventory.remove_item(item_index)
		
		ActionType.CUSTOM:
			# Custom actions can have a callable
			var callable = action.data.get("callable")
			if callable and callable.is_valid():
				callable.call()
		
		ActionType.USE_ABILITY:
			var ability_id = action.data.get("ability_id", "")
			var target_pos = action.data.get("target_position", Vector2.INF)
			var needs_targeting = action.data.get("needs_targeting", false)
			var queued_targets: Array = action.data.get("targets", [])
			var queued_anchor = action.data.get("target_anchor", null)
			var ability = AbilityDatabase.get_ability_data(ability_id)
			var ability_obj = Ability.from_dict(ability)
			if ability:
				character.use_ability(ability_obj, {
					"position": target_pos,
					"targets": queued_targets,
					"anchor": queued_anchor,
				})

## `user` consumes `item_data`, or gives it to `target` to drink. Shared by the
## queued USE_ITEM and the party panel's Consume so both behave the same.
## An item with flat "healing" heals by that amount only: a pure-heal
## use_ability on top (a Potion of Healing's "heal") would heal twice and start
## a cast, so it isn't cast. Any other use_ability is cast for free, on the
## target alone. Returns false when nothing took effect (the cast failed and
## there is no flat healing or satiety): the caller keeps the item, and no
## "consumes" line is logged. A failed cast is announced by the character.
static func apply_consumable(user, target, item_data: Dictionary) -> bool:
	var item_name := _consumable_name(item_data)
	var h = item_data.get("healing", 0.0)
	var healing: float = float(h) if h != null else 0.0
	var s = item_data.get("satiety", 0.0)
	var satiety: float = float(s) if s != null else 0.0
	var has_flat_effect := healing > 0 or satiety > 0

	var use_ability_id = item_data.get("use_ability", "")
	if use_ability_id is String and not use_ability_id.is_empty():
		var ability_data: Dictionary = AbilityDatabase.get_ability_data(use_ability_id)
		if not (healing > 0 and _is_pure_heal_ability(use_ability_id, ability_data)):
			var am = target.get_node_or_null("AbilityManager")
			var cast_ok := false
			if not ability_data.is_empty() and am:
				# The item pays for the spell ("free"), and it lands on the
				# recipient alone, not on everyone standing in its area.
				cast_ok = am.use_ability(Ability.from_dict(ability_data),
					{"position": target.global_position, "targets": [target], "free": true})
			elif not has_flat_effect:
				# No cast-failure notice will come from the manager: say why.
				user.notify("Nothing happens", Color(1.0, 0.6, 0.4),
					"%s can't use the %s: it does nothing on its own." % [user.Name, item_name])
				return false
			if not cast_ok and not has_flat_effect:
				return false

	if target == user:
		GameLog.add_entry("%s consumes the %s." % [user.Name, item_name])
	else:
		GameLog.add_entry("%s gives the %s to %s." % [user.Name, item_name, target.Name])
	if satiety > 0 and "hunger" in target:
		target.hunger = max(0, target.hunger - satiety)
	if healing > 0 and target.has_method("heal"):
		target.heal(int(healing))
	var condition_id = item_data.get("adds_condition_on_equip", "")
	if condition_id is String and not condition_id.is_empty():
		var cm = target.get_node_or_null("ConditionManager")
		if cm:
			cm.apply_condition(condition_id, user)
	return true

## A use_ability that only restores health: "heal" itself, or one whose
## effects are all "heal".
static func _is_pure_heal_ability(ability_id: String, ability_data: Dictionary) -> bool:
	if ability_id.to_lower() == "heal" or str(ability_data.get("id", "")).to_lower() == "heal":
		return true
	var effects = ability_data.get("effects", [])
	if not (effects is Array) or effects.is_empty():
		return false
	for effect in effects:
		if not (effect is Dictionary and str(effect.get("type", "")) == "heal"):
			return false
	return true

static func _consumable_name(item_data: Dictionary) -> String:
	var n = item_data.get("display_name")
	if n != null and str(n) != "":
		return str(n)
	return str(item_data.get("id", "item")).replace("_", " ")

func _execute_action_immediate(type: ActionType, data: Dictionary) -> void:
	"""Execute an action immediately without queueing"""
	var temp_action = Action.new(type, data)
	_execute_action(temp_action)
	
	# For instant actions, complete immediately
	emit_signal("action_completed", temp_action)

func _is_action_complete(action: Action) -> bool:
	"""Check if the current action has finished"""
	match action.type:
		ActionType.MOVE:
			# Advance through waypoints
			var waypoints = action.data.get("waypoints", [])
			var wp_index = action.data.get("waypoint_index", 0)
			if waypoints.size() > 0 and wp_index < waypoints.size():
				# 12px arrival: drawn tactical samples beside walls needn't be
				# pressed to the exact pixel (5px forced bodies into jambs).
				# Consume EVERY waypoint already reached, not just one per frame:
				# a drawn tactical path samples at 8px spacing (TacticalPath.
				# MIN_WAYPOINT_DISTANCE), so a quick character covers more ground
				# in a frame than a single advance gives back. The target then
				# sits BEHIND the body, which turns around to reach it, overshoots
				# again, and rubber-bands back and forth along its own path.
				var advanced := false
				while wp_index < waypoints.size() \
						and character.global_position.distance_to(waypoints[wp_index]) < 12.0:
					wp_index += 1
					advanced = true
				# Fake-arrival contract: a body that stopped moving (wall stuck,
				# cliff veto) still advances one waypoint so the MOVE terminates.
				if not advanced and not character.is_moving:
					wp_index += 1
					advanced = true
				if advanced:
					action.data["waypoint_index"] = wp_index
					if wp_index < waypoints.size():
						var next_wp = waypoints[wp_index]
						character.target_position = next_wp
						character.set_path_facing((next_wp - character.global_position).angle() + PI / 2)
						character.is_moving = true
						return false
					else:
						return true
				return false
			# Fallback: no waypoints
			var dist = character.global_position.distance_to(action.data.get("target_position", character.global_position))
			return dist < 5.0 or not character.is_moving
		
		ActionType.FACE:
			# Complete when we've finished rotating (close enough to target)
			var target_rot = action.data.get("target_rotation", character.rotation)
			var diff = abs(wrapf(character.rotation - target_rot, -PI, PI))
			return diff < 0.1
		
		ActionType.ATTACK:
			# Complete when attack animation is done
			if character.attack_animator:
				return not character.attack_animator.is_attacking
			return true
		
		ActionType.ATTACK_TARGET:
			# Same as regular attack
			if character.attack_animator:
				return not character.attack_animator.is_attacking
			return true
		
		ActionType.CYCLE_WEAPON, ActionType.USE_ITEM, ActionType.CUSTOM:
			# These are instant actions
			return true
		
		ActionType.USE_ABILITY:
			return character.current_cast.is_empty()
	
	return true

func _complete_current_action() -> void:
	"""Called when current action finishes"""
	if current_action != null:
		# Stop character movement when a MOVE action completes
		if current_action.type == ActionType.MOVE:
			character.is_moving = false
			character._nav_waypoints.clear()
			character._nav_index = 0
			# End of the path: nothing left to align to, so drop any parked path
			# angle rather than letting it fire a spontaneous turn a beat after
			# the character has already come to a stop.
			if queue.size() == 0:
				character.clear_facing_hold()
		elif current_action.type in FACING_HOLD_ACTIONS:
			# A planned turn/attack just AIMED the body. Hold that facing for a
			# beat, measured from the moment the turn actually landed, so the next
			# MOVE segment can't snap it back down the path on the following frame.
			character.begin_facing_hold()
		# Remove the reticle when action completes
		_remove_reticle(current_action)
		emit_signal("action_completed", current_action)
		current_action = null

func _exit_tree() -> void:
	"""Cleanup when the node is removed"""
	_remove_all_reticles()
	if reticle_container != null and is_instance_valid(reticle_container):
		reticle_container.queue_free()
