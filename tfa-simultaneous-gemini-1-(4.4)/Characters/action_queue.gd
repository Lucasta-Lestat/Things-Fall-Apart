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
			var ability = AbilityDatabase.get_ability(ability_id)
			if ability and _ability_has_healing(ability):
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
	"""Queue a move action"""
	#find path and display as a white line.
	return queue_action(ActionType.MOVE, {"target_position": target_pos})

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

func queue_cycle_weapon(direction: int) -> bool:
	"""Queue a weapon switch"""
	return queue_action(ActionType.CYCLE_WEAPON, {"direction": direction})

func queue_ability(ability_id: String, target_position: Vector2 = Vector2.INF) -> bool:
	"""Queue an ability to be used"""
	return queue_action(ActionType.USE_ABILITY, {
		"ability_id": ability_id,
		"target_position": target_position,
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
	match action.type:
		ActionType.MOVE:
			var target_pos = action.data.get("target_position", character.global_position)
			character.target_position = target_pos
			character.target_rotation = (target_pos - character.global_position).angle() + PI / 2
			character.is_moving = true
		
		ActionType.FACE:
			character.target_rotation = action.data.get("target_rotation", character.rotation)
			character.is_moving = false
		
		ActionType.ATTACK:
			var target_pos = action.data.get("target_position", null)
			if target_pos:
				character.target_rotation = (target_pos - character.global_position).angle() + PI / 2
			character.attack()
		
		ActionType.ATTACK_TARGET:
			var target = action.data.get("target")
			if target and is_instance_valid(target):
				# Face the target then attack
				character.target_rotation = (target.global_position - character.global_position).angle() + PI / 2
				character.attack()
		
		ActionType.CYCLE_WEAPON:
			var direction = action.data.get("direction", 1)
			character.inventory.cycle_weapon(direction)
		
		ActionType.USE_ITEM:
			# Implement item usage here
			print("attempting to use item in action queue, not implemented yet")
			pass
		
		ActionType.CUSTOM:
			# Custom actions can have a callable
			var callable = action.data.get("callable")
			if callable and callable.is_valid():
				callable.call()
		
		ActionType.USE_ABILITY:
			var ability_id = action.data.get("ability_id", "")
			var target_pos = action.data.get("target_position", Vector2.INF)
			var needs_targeting = action.data.get("needs_targeting", false)
			var ability = AbilityDatabase2.get_ability_data(ability_id)
			var ability_obj = Ability2.from_dict(ability)
			if ability:
				character.use_ability(ability_obj, {"position": target_pos})

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
			# Complete when we've reached the destination
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
		# Remove the reticle when action completes
		_remove_reticle(current_action)
		emit_signal("action_completed", current_action)
		current_action = null

func _exit_tree() -> void:
	"""Cleanup when the node is removed"""
	_remove_all_reticles()
	if reticle_container != null and is_instance_valid(reticle_container):
		reticle_container.queue_free()
