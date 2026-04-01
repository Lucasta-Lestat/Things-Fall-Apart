# AbilityManager.gd
# Component that manages ability execution, cooldowns, and multi-step sequencing.
# Attach as a child node of your character (similar to ConditionManager).
class_name AbilityManager
extends Node

## Reference to the character this manager belongs to
@export var character_path: NodePath = ".."
var character: Node

## All active cooldowns: ability_id -> expiry timestamp
var cooldowns: Dictionary = {}

## Current cast state
var current_cast: Dictionary = {}

## Tracks multi-step execution
var _current_step_index: int = -1
var _step_timer: float = 0.0
var _step_waiting: bool = false

## Signals
signal cast_started(ability: Ability, target_position: Vector2)
signal cast_completed(ability: Ability, results: Array)
signal cast_interrupted(ability: Ability, reason: String)
signal cast_failed(ability: Ability, reason: String)
signal step_started(ability: Ability, step_index: int, step_data: Dictionary)
signal step_completed(ability: Ability, step_index: int, results: Array)


func _ready() -> void:
	if has_node(character_path):
		character = get_node(character_path)


func _process(delta: float) -> void:
	if current_cast.is_empty():
		return

	var state = current_cast.get("state", "")

	if state == "casting":
		_process_casting(delta)
	elif state == "stepping":
		_process_stepping(delta)


## Use an ability. Entry point for all ability execution.
func use_ability(ability: Ability, target_data: Dictionary = {}) -> bool:
	var can_use = _check_ability_usable(ability)
	if not can_use["success"]:
		cast_failed.emit(ability, can_use["reason"])
		return false

	if not _pay_ability_costs(ability):
		cast_failed.emit(ability, "Cannot pay costs")
		return false

	_start_cooldown(ability)

	var target_position = target_data.get("position", character.global_position)

	if ability.cast_time <= 0:
		_execute_ability(ability, target_position)
		return true

	_start_casting(ability, target_position)
	return true


## Start the casting process (windup before execution)
func _start_casting(ability: Ability, target_position: Vector2) -> void:
	current_cast = {
		"ability": ability,
		"state": "casting",
		"target_position": target_position,
		"cast_progress": 0.0,
		"cast_time": ability.cast_time
	}

	if character and character.has_node("AttackAnimator"):
		var attack_animator = character.get_node("AttackAnimator")
		attack_animator.setup_cast_parameters(ability.cast_time, 0.2, 0.3)
		attack_animator.start_cast()

	var cast_effect_path = ability.visuals.get("cast_effect", "")
	if cast_effect_path != "" and character.has_method("_spawn_effect"):
		character._spawn_effect(cast_effect_path, character.global_position, 1.0)

	cast_started.emit(ability, target_position)

	if character and "targeting_system" in character and character.targeting_system:
		character.targeting_system.end_targeting()


## Process ongoing casting
func _process_casting(delta: float) -> void:
	if current_cast.get("state") != "casting":
		return

	current_cast["cast_progress"] += delta

	if current_cast["cast_progress"] >= current_cast["cast_time"]:
		var ability = current_cast["ability"] as Ability
		var target_pos = current_cast["target_position"]
		current_cast.clear()
		_execute_ability(ability, target_pos)


## Execute the ability after casting completes
func _execute_ability(ability: Ability, target_position: Vector2) -> void:
	if ability.is_multi_step():
		_start_step_sequence(ability, target_position)
	else:
		# Single-step: check for projectile or resolve immediately
		var projectile_path = ability.visuals.get("projectile", "")
		if projectile_path != "" and character.has_method("_spawn_projectile"):
			character._spawn_projectile(ability, target_position)
		else:
			var results = _resolve_effects(ability, ability.effects, target_position)
			if character.has_method("_spawn_ability_visuals"):
				character._spawn_ability_visuals(ability, target_position)
			cast_completed.emit(ability, results)


## Start a multi-step ability sequence
func _start_step_sequence(ability: Ability, target_position: Vector2) -> void:
	current_cast = {
		"ability": ability,
		"state": "stepping",
		"target_position": target_position,
		"step_results": [],
	}
	_current_step_index = -1
	_advance_to_next_step()


## Process multi-step timing
func _process_stepping(delta: float) -> void:
	if not _step_waiting:
		return

	_step_timer -= delta
	if _step_timer <= 0.0:
		_step_waiting = false
		_execute_current_step()


## Advance to the next step in the sequence
func _advance_to_next_step() -> void:
	_current_step_index += 1
	var ability = current_cast.get("ability") as Ability

	if not ability or _current_step_index >= ability.steps.size():
		# All steps done
		_finish_step_sequence()
		return

	var step = ability.steps[_current_step_index]
	var delay = step.get("delay", 0.0)

	if delay > 0.0:
		_step_timer = delay
		_step_waiting = true
	else:
		_execute_current_step()


## Execute the current step
func _execute_current_step() -> void:
	var ability = current_cast.get("ability") as Ability
	if not ability:
		return

	var step = ability.steps[_current_step_index]
	var base_target = current_cast.get("target_position", character.global_position)

	# Per-step targeting override
	var step_targeting = step.get("targeting", {})
	var step_target_pos = base_target
	if step_targeting.get("type", "") == "self":
		step_target_pos = character.global_position

	step_started.emit(ability, _current_step_index, step)

	# Handle dash/move_to_target
	if step.get("move_to_target", false):
		var move_speed = step.get("move_speed", 600.0)
		_dash_to_position(step_target_pos, move_speed, func():
			_resolve_step_and_advance(ability, step, step_target_pos)
		)
		return

	_resolve_step_and_advance(ability, step, step_target_pos)


## Resolve a step's effects and advance
func _resolve_step_and_advance(ability: Ability, step: Dictionary, target_pos: Vector2) -> void:
	var step_effects = step.get("effects", [])

	# Per-step animation
	var step_anim = step.get("animation", "")
	if step_anim != "" and character.has_method("play_animation"):
		character.play_animation(step_anim)

	# Resolve effects
	var results = _resolve_effects(ability, step_effects, target_pos)

	# Per-step visuals
	var step_visuals = step.get("visuals", {})
	if not step_visuals.is_empty():
		var impact_path = step_visuals.get("impact_effect", "")
		if impact_path != "" and character.has_method("_spawn_effect"):
			var radius = step.get("targeting", {}).get("radius", 0.0)
			var size_scale = radius / 25.0 if radius > 0 else 1.0
			character._spawn_effect(impact_path, target_pos, size_scale)

		var sfx_path = step_visuals.get("sound_impact", "")
		if sfx_path != "" and character.has_method("_play_sfx_at"):
			character._play_sfx_at(sfx_path, target_pos)

	current_cast["step_results"].append(results)
	step_completed.emit(ability, _current_step_index, results)
	_advance_to_next_step()


## Finish the entire multi-step sequence
func _finish_step_sequence() -> void:
	var ability = current_cast.get("ability") as Ability
	var all_results = current_cast.get("step_results", [])
	current_cast.clear()
	_current_step_index = -1

	if ability:
		cast_completed.emit(ability, all_results)


## Dash/move character to a position, then call a callback
func _dash_to_position(target_pos: Vector2, speed: float, on_complete: Callable) -> void:
	if not character or not character is Node2D:
		on_complete.call()
		return

	var distance = character.global_position.distance_to(target_pos)
	if distance < 1.0:
		on_complete.call()
		return

	var duration = distance / speed
	var tween = create_tween()
	tween.tween_property(character, "global_position", target_pos, duration)
	tween.finished.connect(on_complete, CONNECT_ONE_SHOT)


## Resolve an array of effects against targets
func _resolve_effects(ability: Ability, effects: Array, target_position: Vector2) -> Array:
	var targets = []
	if character.has_method("_find_targets_in_area"):
		targets = character._find_targets_in_area(ability, target_position)

	var results: Array = []
	for effect in effects:
		var result = AbilityEffect.resolve_effect(
			effect,
			character,
			targets,
			ability,
			target_position
		)
		results.append(result)

	return results


## Check if ability can be used
func _check_ability_usable(ability: Ability) -> Dictionary:
	if is_on_cooldown(ability.id):
		return {"success": false, "reason": "On cooldown"}

	for resource_name in ability.costs:
		var cost = ability.costs[resource_name]
		if character.has_method("_get_character_resource"):
			var current = character._get_character_resource(resource_name)
			if current < cost:
				return {"success": false, "reason": "Not enough %s" % resource_name}

	var reqs = ability.requirements
	var required_conditions = reqs.get("conditions", [])
	if not required_conditions.is_empty():
		var cond_manager = _get_condition_manager()
		if cond_manager:
			for cond_id in required_conditions:
				if not cond_manager.has_active_condition(cond_id):
					return {"success": false, "reason": "Missing required condition: %s" % cond_id}

	var forbidden_conditions = reqs.get("no_conditions", [])
	if not forbidden_conditions.is_empty():
		var cond_manager = _get_condition_manager()
		if cond_manager:
			for cond_id in forbidden_conditions:
				if cond_manager.has_active_condition(cond_id):
					return {"success": false, "reason": "Cannot use while: %s" % cond_id}

	if not current_cast.is_empty():
		var state = current_cast.get("state", "")
		if state == "casting" or state == "stepping":
			return {"success": false, "reason": "Already casting"}

	return {"success": true}


## Pay the costs for an ability
func _pay_ability_costs(ability: Ability) -> bool:
	for resource_name in ability.costs:
		var cost = ability.costs[resource_name]
		if character.has_method("_spend_character_resource"):
			if not character._spend_character_resource(resource_name, cost):
				return false
	return true


## Start cooldown for ability
func _start_cooldown(ability: Ability) -> void:
	if ability.cooldown > 0:
		cooldowns[ability.id] = Time.get_ticks_msec() / 1000.0 + ability.cooldown


## Check if ability is on cooldown
func is_on_cooldown(ability_id: String) -> bool:
	if ability_id not in cooldowns:
		return false
	return Time.get_ticks_msec() / 1000.0 < cooldowns[ability_id]


## Get remaining cooldown time
func get_cooldown_remaining(ability_id: String) -> float:
	if ability_id not in cooldowns:
		return 0.0
	return max(0.0, cooldowns[ability_id] - Time.get_ticks_msec() / 1000.0)


## Interrupt current cast
func interrupt_cast(reason: String = "Interrupted") -> bool:
	if current_cast.is_empty():
		return false

	var ability = current_cast.get("ability") as Ability
	if ability and not ability.interruptible:
		return false

	current_cast.clear()
	_current_step_index = -1
	_step_waiting = false

	if ability:
		cast_interrupted.emit(ability, reason)

	return true


## Whether the manager is currently executing an ability
func is_casting() -> bool:
	return not current_cast.is_empty()


## Get condition manager from character
func _get_condition_manager():
	if character and character.has_node("ConditionManager"):
		return character.get_node("ConditionManager")
	return null


## Serialize cooldowns for saving
func save_cooldowns() -> Dictionary:
	return cooldowns.duplicate()


## Load cooldowns from save
func load_cooldowns(data: Dictionary) -> void:
	cooldowns = data.duplicate()
