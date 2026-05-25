# AbilityManager.gd
# Component that manages ability execution and multi-step sequencing.
# Costs are paid from per-school resources derived from `ability.traits`
# (Martial→adrenaline, Arcane→focus, Primal→harmony, Holy→devotion,
# Occult→souls). Cooldowns have been removed — once a cast completes the
# next cast is gated only by resource availability.
# Attach as a child node of your character (similar to ConditionManager).
class_name AbilityManager
extends Node

const SCHOOL_RESOURCE_MAP := {
	"Martial": "adrenaline",
	"Arcane": "focus",
	"Primal": "harmony",
	"Holy": "devotion",
	"Occult": "souls",
}

## Reference to the character this manager belongs to
@export var character_path: NodePath = ".."
var character: Node

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
	if ability == null:
		push_warning("AbilityManager.use_ability: received null ability")
		return false
	var can_use = _check_ability_usable(ability)
	if not can_use["success"]:
		cast_failed.emit(ability, can_use["reason"])
		return false

	var target_position = target_data.get("position", character.global_position)
	var explicit_targets: Array = target_data.get("targets", [])

	# Infatuated: block offensive abilities that would hit the charm source
	if _would_hit_infatuation_source(ability, target_position):
		var cond_mgr = _get_condition_manager()
		var inf_instance = cond_mgr.conditions.get("infatuated") if cond_mgr else null
		var source_name = inf_instance.source.Name if inf_instance and is_instance_valid(inf_instance.source) else "them"
		GameLog.add_entry(character.Name + " can't use " + ability.display_name + " against " + source_name + "!")
		cast_failed.emit(ability, "Cannot harm charm source")
		return false

	if not _pay_ability_costs(ability):
		cast_failed.emit(ability, "Cannot pay costs")
		return false

	if ability.cast_time <= 0:
		_execute_ability(ability, target_position, explicit_targets)
		return true

	_start_casting(ability, target_position, explicit_targets)
	return true


## Start the casting process (windup before execution)
func _start_casting(ability: Ability, target_position: Vector2, explicit_targets: Array = []) -> void:
	current_cast = {
		"ability": ability,
		"state": "casting",
		"target_position": target_position,
		"explicit_targets": explicit_targets,
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

	var sound_cast_path = ability.visuals.get("sound_cast", "")
	if sound_cast_path != "" and character.has_method("_play_sfx_at"):
		character._play_sfx_at(sound_cast_path, character.global_position)

	cast_started.emit(ability, target_position)

	# Don't end targeting here — the preview should persist until the ability
	# actually lands (cast_completed). Cleanup happens in _on_ability_cast_completed.


## Process ongoing casting
func _process_casting(delta: float) -> void:
	if current_cast.get("state") != "casting":
		return

	current_cast["cast_progress"] += delta

	if current_cast["cast_progress"] >= current_cast["cast_time"]:
		var ability = current_cast["ability"] as Ability
		var target_pos = current_cast["target_position"]
		var carried_targets: Array = current_cast.get("explicit_targets", [])
		current_cast.clear()
		_execute_ability(ability, target_pos, carried_targets)


## Execute the ability after casting completes
func _execute_ability(ability: Ability, target_position: Vector2, explicit_targets: Array = []) -> void:
	if ability.is_multi_step():
		_start_step_sequence(ability, target_position, explicit_targets)
	else:
		# When the ability targets specific characters, skip the projectile path
		# and resolve effects directly against the chosen targets.
		var projectile_path = ability.visuals.get("projectile", "")
		var has_explicit = not explicit_targets.is_empty()
		if not has_explicit and projectile_path != "" and character.has_method("_spawn_projectile"):
			character._spawn_projectile(ability, target_position)
		else:
			var results = _resolve_effects(ability, ability.effects, target_position, explicit_targets)
			if character.has_method("_spawn_ability_visuals"):
				character._spawn_ability_visuals(ability, target_position)
			cast_completed.emit(ability, results)


## Start a multi-step ability sequence
func _start_step_sequence(ability: Ability, target_position: Vector2, explicit_targets: Array = []) -> void:
	current_cast = {
		"ability": ability,
		"state": "stepping",
		"target_position": target_position,
		"explicit_targets": explicit_targets,
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

	# Resolve effects (carry explicit targets through multi-step sequences)
	var step_explicit_targets: Array = current_cast.get("explicit_targets", [])
	var results = _resolve_effects(ability, step_effects, target_pos, step_explicit_targets)

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


## Dash/move character to a position, then call a callback. Routes through
## ProceduralCharacter.dash_to so the dash uses move_and_slide and respects
## structures (no more wall-phasing).
func _dash_to_position(target_pos: Vector2, speed: float, on_complete: Callable) -> void:
	if not character or not character.has_method("dash_to"):
		on_complete.call()
		return
	character.dash_to(target_pos, speed, on_complete)


## Resolve an array of effects against targets
func _resolve_effects(ability: Ability, effects: Array, target_position: Vector2, explicit_targets: Array = []) -> Array:
	var targets = []
	if not explicit_targets.is_empty():
		# Player explicitly picked these targets — skip area sweep
		for t in explicit_targets:
			if is_instance_valid(t):
				targets.append(t)
	elif character.has_method("_find_targets_in_area"):
		targets = character._find_targets_in_area(ability, target_position)

	var results: Array = []
	var dealt_fire_damage = false
	for effect in effects:
		var result = AbilityEffect.resolve_effect(
			effect,
			character,
			targets,
			ability,
			target_position
		)
		results.append(result)
		# Check if this effect dealt fire damage
		if result.get("effect_type") == "damage" and result.get("total_damage", 0) > 0:
			for target_info in result.get("targets_affected", []):
				if "fire" in target_info.get("damage_types", []):
					dealt_fire_damage = true
					break
		# Also check if the effect definition itself has fire damage
		if not dealt_fire_damage and effect.get("type") == "damage":
			var dmg = effect.get("damage", {})
			if dmg.has("fire") and dmg["fire"] > 0:
				dealt_fire_damage = true

	# If fire damage was dealt, try to ignite floors/fluids in the AoE
	if dealt_fire_damage:
		var game = character.get_tree().get_first_node_in_group("game")
		if not game:
			game = character.get_tree().current_scene
		if game and "surface_manager" in game and game.surface_manager:
			var radius = ability.targeting.get("radius", 0.0)
			if radius > 0:
				game.surface_manager.try_ignite_area(target_position, radius)
			else:
				# Single-target fire: ignite just the target tile
				var tile = GridManager.world_to_map(target_position)
				game.surface_manager.try_ignite(tile)

	return results


## Build the per-school resource cost dict for an ability from its trait tags.
## { "Arcane": 2, "Fire": 3 } → { "focus": 2 } (Fire is not a school tag).
static func school_costs_for(ability: Ability) -> Dictionary:
	var costs: Dictionary = {}
	for trait_name in ability.traits:
		if SCHOOL_RESOURCE_MAP.has(trait_name):
			var tier := int(ability.traits[trait_name])
			if tier > 0:
				costs[SCHOOL_RESOURCE_MAP[trait_name]] = tier
	return costs


## Check if ability can be used
func _check_ability_usable(ability: Ability) -> Dictionary:
	var cm = _get_condition_manager()
	if cm and (cm.has_active_condition("apathetic") or cm.has_active_condition("stunned")):
		return {"success": false, "reason": "Cannot act"}

	# NPCs without school tiers opt out of the cost gate so legacy enemies
	# don't lose their kit until their data is hand-tagged.
	var skip_resource_gate: bool = "npc_unlimited_resources" in character and character.npc_unlimited_resources

	if not skip_resource_gate:
		var costs := school_costs_for(ability)
		for resource_name in costs:
			var cost: int = int(costs[resource_name])
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


## Check if an ability would offensively affect the caster's infatuation source
func _would_hit_infatuation_source(ability: Ability, target_position: Vector2) -> bool:
	var cond_mgr = _get_condition_manager()
	if not cond_mgr or not cond_mgr.has_active_condition("infatuated"):
		return false

	var inf_instance = cond_mgr.conditions.get("infatuated")
	if not inf_instance or not is_instance_valid(inf_instance.source):
		return false

	# Check if ability has offensive effects (damage or debuff conditions)
	var is_offensive = false
	var effects = ability.effects if ability.effects is Array else [ability.effects]
	for effect in effects:
		if not effect is Dictionary:
			continue
		var effect_type = effect.get("type", "")
		if effect_type == "damage" or effect_type == "knockback":
			is_offensive = true
			break
		if effect_type == "apply_condition":
			# Check if the condition being applied is a debuff
			var cond_id = effect.get("condition_id", "")
			var cond_template = ConditionManager.condition_registry.get(cond_id)
			if cond_template and cond_template.traits.has("debuff"):
				is_offensive = true
				break
	if not is_offensive:
		return false

	# Check if the infatuation source is in the ability's target area
	if character.has_method("_find_targets_in_area"):
		var targets = character._find_targets_in_area(ability, target_position)
		return inf_instance.source in targets

	return false


## Pay the costs for an ability — drains the school resources implied by the
## ability's traits (Martial→adrenaline, Arcane→focus, ...). NPCs flagged
## with `npc_unlimited_resources` pay nothing.
func _pay_ability_costs(ability: Ability) -> bool:
	if "npc_unlimited_resources" in character and character.npc_unlimited_resources:
		return true
	var costs := school_costs_for(ability)
	# Concentration spells lock the focus they pay until the spell ends.
	var concentration: bool = ability.traits.has("Concentration") or ability.traits.has("concentration")
	for resource_name in costs:
		var cost: int = int(costs[resource_name])
		if character.has_method("_spend_character_resource"):
			if not character._spend_character_resource(resource_name, cost):
				return false
	if concentration and costs.has("focus") and character.has_method("_begin_concentration"):
		character._begin_concentration(ability.id, int(costs["focus"]))
	return true


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


## Check if any active conditions should gain stacks based on the ability's traits.
## Called after a successful ability cast. Conditions with on_action_trait_stack
## gain +1 stack when ALL required_traits are present in the ability's traits dict.
func _check_action_trait_stacking(ability: Ability) -> void:
	if not ability or ability.traits.is_empty():
		return

	var cond_mgr = _get_condition_manager()
	if not cond_mgr:
		return

	for cond_id in cond_mgr.conditions:
		var instance: ConditionInstance = cond_mgr.conditions[cond_id]
		if not instance.is_active():
			continue

		var stack_config: Dictionary = instance.condition.on_action_trait_stack
		if stack_config.is_empty():
			continue

		var required: Array = stack_config.get("required_traits", [])
		if required.is_empty():
			continue

		# All required traits must be present on the ability
		var all_match := true
		for trait_name in required:
			if trait_name not in ability.traits:
				all_match = false
				break

		if all_match:
			cond_mgr.apply_condition(cond_id, null, 1, -1.0)
