# AbilityManager.gd
# Manages multi-step ability execution for a character.
# Attach as a child node of ProceduralCharacter (or any character node).
#
# Each ability can define a flat "effects" array (single-step) or a "steps" array
# (multi-step). Steps execute sequentially; each step can move the caster, cast for
# a duration, fire a projectile, and resolve its own set of effects independently.
#
# Example multi-step ability (dash + slam):
#   steps: [
#     { cast_time: 0.15, move_to_target: true, effects: [], visuals: {} },
#     { cast_time: 0.0,  targeting: {shape:"circle", radius:80}, effects: [damage, knockback] }
#   ]
class_name AbilityManager
extends Node

## The owning character — set automatically from parent in _ready.
var character: Node

## Currently executing ability (null when idle).
var current_ability: Ability = null

## Index of the step currently being cast or executed.
var current_step_index: int = 0

## Seconds elapsed toward the current step's cast_time.
var step_cast_progress: float = 0.0

## World-space target position for the current step.
var step_target_position: Vector2 = Vector2.ZERO

## Accumulated results from all completed steps (passed to cast_completed).
var all_results: Array = []

enum State { IDLE, CASTING }
var state: State = State.IDLE

## Cooldowns: { ability_id: time_when_available (seconds, from Time.get_ticks_msec) }
var cooldowns: Dictionary = {}

# ── Signals ──────────────────────────────────────────────────────────────────

## Emitted once when the ability starts (before any steps begin).
signal cast_started(ability: Ability, target_position: Vector2)
## Emitted once when all steps have finished.
signal cast_completed(ability: Ability, results: Array)
## Emitted if the cast is interrupted mid-execution.
signal cast_interrupted(ability: Ability, reason: String)
## Emitted when the ability cannot be started (cooldown, cost, condition, etc.).
signal cast_failed(ability: Ability, reason: String)
## Emitted at the beginning of each step.
signal step_started(ability: Ability, step_index: int)
## Emitted when a step's effects have been resolved.
signal step_completed(ability: Ability, step_index: int, results: Array)


func _ready() -> void:
	character = get_parent()


func _process(delta: float) -> void:
	if state == State.CASTING:
		_process_casting(delta)


# ── Public API ────────────────────────────────────────────────────────────────

## Attempt to start executing an ability. Returns false if it cannot be used.
func start_ability(ability: Ability, target_data: Dictionary = {}) -> bool:
	var can_use = _check_ability_usable(ability)
	if not can_use["success"]:
		cast_failed.emit(ability, can_use["reason"])
		return false

	if not _pay_ability_costs(ability):
		cast_failed.emit(ability, "Cannot pay costs")
		return false

	_start_cooldown(ability)

	current_ability = ability
	current_step_index = 0
	all_results = []

	var target_position: Vector2 = target_data.get("position", character.global_position)
	cast_started.emit(ability, target_position)

	_begin_step(0, target_position)
	return true


## Interrupt the current cast. Returns false if nothing is running or it is
## flagged as non-interruptible.
func interrupt_cast(reason: String = "Interrupted") -> bool:
	if current_ability == null and state == State.IDLE:
		return false

	if current_ability != null and not current_ability.interruptible:
		return false

	var ability = current_ability
	_reset()

	if ability:
		cast_interrupted.emit(ability, reason)

	return true


## Returns true while an ability is being cast or executed.
func is_busy() -> bool:
	return current_ability != null


## Returns true if the given ability is on cooldown.
func is_on_cooldown(ability_id: String) -> bool:
	if ability_id not in cooldowns:
		return false
	return Time.get_ticks_msec() / 1000.0 < cooldowns[ability_id]


## Returns remaining cooldown seconds (0 if not on cooldown).
func get_cooldown_remaining(ability_id: String) -> float:
	if ability_id not in cooldowns:
		return 0.0
	return max(0.0, cooldowns[ability_id] - Time.get_ticks_msec() / 1000.0)


# ── Called by character for projectile-based steps ───────────────────────────

## Called by the character's projectile spawner when the projectile for a step
## has arrived (or timed out). Resolves the step's effects at the final position.
func on_step_projectile_arrived(step_index: int, final_position: Vector2) -> void:
	if current_ability == null or step_index != current_step_index:
		return
	_resolve_step(step_index, final_position)


# ── Internal: step lifecycle ─────────────────────────────────────────────────

func _begin_step(step_index: int, target_position: Vector2) -> void:
	if current_ability == null:
		return

	var steps = current_ability.get_steps()
	if step_index >= steps.size():
		# All steps done — complete the ability.
		var ability = current_ability
		_reset()
		cast_completed.emit(ability, all_results)
		return

	current_step_index = step_index
	step_target_position = target_position
	step_cast_progress = 0.0

	var step: Dictionary = steps[step_index]
	step_started.emit(current_ability, step_index)

	# Spawn the cast effect for this step (if any).
	var cast_effect: String = step.get("visuals", {}).get("cast_effect", "")
	if cast_effect != "":
		character._spawn_effect(cast_effect, character.global_position, 1.0)

	var cast_time: float = step.get("cast_time", 0.0)
	if cast_time <= 0.0:
		_execute_step(step_index)
	else:
		state = State.CASTING


func _process_casting(delta: float) -> void:
	if current_ability == null:
		state = State.IDLE
		return

	var steps = current_ability.get_steps()
	if current_step_index >= steps.size():
		state = State.IDLE
		return

	var step: Dictionary = steps[current_step_index]
	step_cast_progress += delta

	if step_cast_progress >= step.get("cast_time", 0.0):
		state = State.IDLE
		_execute_step(current_step_index)


func _execute_step(step_index: int) -> void:
	if current_ability == null:
		return

	var step: Dictionary = current_ability.get_steps()[step_index]
	var projectile_path: String = step.get("visuals", {}).get("projectile", "")

	if projectile_path != "":
		# Hand off to the character to spawn and move the projectile.
		# When it arrives, it will call back on_step_projectile_arrived().
		character._spawn_projectile_for_step(
			current_ability, step, step_target_position, step_index
		)
	else:
		_resolve_step(step_index, step_target_position)


func _resolve_step(step_index: int, target_position: Vector2) -> void:
	if current_ability == null:
		return

	var step: Dictionary = current_ability.get_steps()[step_index]

	# Optionally teleport the caster to the target position (dash-like behaviour).
	if step.get("move_to_target", false):
		character.global_position = target_position

	# Determine which targeting dict to use for finding targets.
	var step_targeting: Dictionary = step.get("targeting", {})
	if step_targeting.is_empty() or step_targeting.get("shape", "none") == "none":
		step_targeting = current_ability.targeting

	var targets = character._find_targets_in_area_with_targeting(step_targeting, target_position)

	# Resolve each effect in this step.
	var step_results: Array = []
	for effect in step.get("effects", []):
		var result = AbilityEffect.resolve_effect(
			effect,
			character,
			targets,
			current_ability,
			target_position
		)
		step_results.append(result)

	all_results.append_array(step_results)

	# Spawn per-step impact visuals.
	character._spawn_step_visuals(step, target_position)

	step_completed.emit(current_ability, step_index, step_results)

	# Advance to the next step using the same target position.
	_begin_step(step_index + 1, target_position)


# ── Internal: cost / cooldown / usability ────────────────────────────────────

func _check_ability_usable(ability: Ability) -> Dictionary:
	if is_on_cooldown(ability.id):
		return {"success": false, "reason": "On cooldown"}

	for resource_name in ability.costs:
		var cost = ability.costs[resource_name]
		var current = character._get_character_resource(resource_name)
		if current < cost:
			return {"success": false, "reason": "Not enough %s" % resource_name}

	var reqs = ability.requirements

	var required_conditions = reqs.get("conditions", [])
	if not required_conditions.is_empty():
		var cond_manager = character._get_condition_manager()
		if cond_manager:
			for cond_id in required_conditions:
				if not cond_manager.has_active_condition(cond_id):
					return {"success": false, "reason": "Missing required condition: %s" % cond_id}

	var forbidden_conditions = reqs.get("no_conditions", [])
	if not forbidden_conditions.is_empty():
		var cond_manager = character._get_condition_manager()
		if cond_manager:
			for cond_id in forbidden_conditions:
				if cond_manager.has_active_condition(cond_id):
					return {"success": false, "reason": "Cannot use while: %s" % cond_id}

	if is_busy():
		return {"success": false, "reason": "Already casting"}

	return {"success": true}


func _pay_ability_costs(ability: Ability) -> bool:
	for resource_name in ability.costs:
		var cost = ability.costs[resource_name]
		if not character._spend_character_resource(resource_name, cost):
			return false
	return true


func _start_cooldown(ability: Ability) -> void:
	if ability.cooldown > 0:
		cooldowns[ability.id] = Time.get_ticks_msec() / 1000.0 + ability.cooldown


func _reset() -> void:
	current_ability = null
	current_step_index = 0
	step_cast_progress = 0.0
	all_results = []
	state = State.IDLE
