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
	CUSTOM          # For extensibility
}

# An action in the queue
class Action:
	var type: ActionType
	var data: Dictionary
	var created_at: float  # When the action was queued (for display purposes)
	
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

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	character = get_parent() as ProceduralCharacter

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

# ===== PUBLIC API =====

func queue_action(type: ActionType, data: Dictionary = {}) -> bool:
	"""Add an action to the queue. Returns false if queue is full."""
	print("attempting to queue an action of type: ", type)
	# Check if we should only queue when paused
	if queue_only_when_paused and not PauseManager.is_paused:
		# Execute immediately instead of queueing
		_execute_action_immediate(type, data)
		return true
	
	# Check queue size limit
	if max_queue_size > 0 and queue.size() >= max_queue_size:
		print("exceeded queue size limit")
		return false
	
	var action = Action.new(type, data)
	queue.append(action)
	emit_signal("action_queued", action)
	return true

func queue_move(target_pos: Vector2) -> bool:
	"""Queue a move action"""
	return queue_action(ActionType.MOVE, {"target_position": target_pos})

func queue_face(target_pos: Vector2) -> bool:
	"""Queue a face direction action"""
	var angle = (target_pos - character.global_position).angle() + PI / 2
	return queue_action(ActionType.FACE, {"target_rotation": angle})

func queue_attack() -> bool:
	"""Queue a basic attack"""
	return queue_action(ActionType.ATTACK)

func queue_attack_target(target: ProceduralCharacter) -> bool:
	"""Queue an attack on a specific target"""
	return queue_action(ActionType.ATTACK_TARGET, {"target": target})

func queue_cycle_weapon(direction: int) -> bool:
	"""Queue a weapon switch"""
	return queue_action(ActionType.CYCLE_WEAPON, {"direction": direction})

func clear_queue() -> void:
	"""Clear all pending actions"""
	for action in queue:
		emit_signal("action_cancelled", action)
	queue.clear()
	emit_signal("queue_cleared")

func cancel_current() -> void:
	"""Cancel the currently executing action"""
	if current_action != null:
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
			pass
		
		ActionType.CUSTOM:
			# Custom actions can have a callable
			var callable = action.data.get("callable")
			if callable and callable.is_valid():
				callable.call()

func _execute_action_immediate(type: ActionType, data: Dictionary) -> void:
	"""Execute an action immediately without queueing"""
	var temp_action = Action.new(type, data)
	_execute_action(temp_action)
	
	# For instant actions, complete immediately
	if type in [ActionType.ATTACK, ActionType.CYCLE_WEAPON, ActionType.USE_ITEM, ActionType.CUSTOM]:
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
	
	return true

func _complete_current_action() -> void:
	"""Called when current action finishes"""
	if current_action != null:
		emit_signal("action_completed", current_action)
		current_action = null
