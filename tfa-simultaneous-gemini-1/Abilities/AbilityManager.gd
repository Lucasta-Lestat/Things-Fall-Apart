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

## An execution-time range clamp that moves the point further than this is
## announced (a planned cast whose caster stopped short of its node).
const RANGE_CLAMP_NOTICE_PX := 16.0

## Player-facing text for an unmet requirements.traits entry; any other id
## reads "Requires <Id>".
const REQUIREMENT_REASONS := {
	"has_shield": "Needs a shield",
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
	# Casts hold still while the game is paused, like ActionQueue. This node
	# inherits PROCESS_MODE_ALWAYS from the character, so it must check itself.
	if PauseManager.is_paused:
		return

	var state = current_cast.get("state", "")

	if state == "casting":
		_process_casting(delta)
	elif state == "stepping":
		_process_stepping(delta)


## Whether a designated character should re-aim this ability.
##
## Ground AoE deliberately does NOT follow its anchor: placing a circle/cone/line
## on a chosen patch of ground is the whole point of aiming one, and having it
## chase a character would take that control away. Everything else follows —
## single-target and unshaped abilities, plus anything with a projectile to fly,
## since a projectile aimed at a character should leave the caster pointed at
## where that character actually is. A projectile still detonates wherever it
## lands, so an anchored projectile-AoE keeps its splash at the impact point.
static func ability_follows_anchor(ability: Ability) -> bool:
	return targeting_follows_anchor(ability.targeting, ability.visuals)


## Same rule against a raw/flattened data dict, for callers that hold the JSON
## rather than a built Ability (the targeting UI decides whether to record an
## anchor before any Ability resource exists).
static func targeting_follows_anchor(targeting: Dictionary, visuals: Dictionary) -> bool:
	if String(visuals.get("projectile", "")) != "":
		return true
	var shape := String(targeting.get("shape", "none"))
	# "characters" abilities bind their effects to picked characters already;
	# following the pick keeps their visuals on the target rather than on the
	# spot it stood when the player clicked.
	return shape == "single" or shape == "none" or shape == "characters"


## Live position of a designated character, or `fallback` when there is no
## anchor, the anchor is eligible but gone, or the ability opts out of anchoring.
func _anchored_position(ability: Ability, anchor, fallback: Vector2) -> Vector2:
	if anchor == null or not is_instance_valid(anchor):
		return fallback
	if not ability_follows_anchor(ability):
		return fallback
	# A corpse stays in the scene, so validity alone does not mean "still a
	# target". Aiming at a dead body is worse than aiming where the player clicked.
	if anchor.has_method("is_alive") and not anchor.is_alive():
		return fallback
	return anchor.global_position


## Use an ability. Entry point for all ability execution.
## target_data keys: "position", "targets" (explicitly picked characters),
## "anchor" (a designated character to re-aim at) and "free" (an item's cast:
## skips the incapacitation, requirement and school-resource gates and the
## cost; the item already paid).
func use_ability(ability: Ability, target_data: Dictionary = {}) -> bool:
	if ability == null:
		push_warning("AbilityManager.use_ability: received null ability")
		return false
	var free: bool = bool(target_data.get("free", false))
	var can_use = _check_ability_usable(ability, free)
	if not can_use["success"]:
		cast_failed.emit(ability, can_use["reason"])
		return false

	var target_position = target_data.get("position", character.global_position)
	var explicit_targets: Array = target_data.get("targets", [])
	var target_anchor = target_data.get("anchor", null)

	# Designated-character re-aim. Same late-binding rationale as the "self"
	# override below: the position was captured while planning, but movement runs
	# in real time after unpause, so by the time this fires the target has walked.
	# Best-effort — a dead or freed anchor silently falls back to the planned
	# point, so the shot still goes where the player aimed it.
	target_position = _anchored_position(ability, target_anchor, target_position)

	# Self-targeted abilities always resolve at the caster's live position. A
	# queued target_position (captured while planning, where the cursor was)
	# would otherwise land the effect at a stale spot once the caster has walked
	# to the cast point. Mirrors the per-step "self" override in _execute_current_step.
	if ability.targeting.get("type", "") == "self":
		target_position = character.global_position

	# Ability range is measured from where the caster actually stands now. The
	# targeting preview already clamps to the ring around the caster (or the
	# planned node); this covers a caster who stopped short, and any caller
	# that skipped targeting. Picked characters were range-checked when picked,
	# and a designated character (anchor) re-aims the cast anyway. A cone's
	# point only aims it (its reach is its radius), so it is left alone.
	var max_range: float = float(ability.targeting.get("range", 0.0))
	var has_anchor: bool = target_anchor != null and is_instance_valid(target_anchor)
	if ability.targeting.get("type", "") != "self" and max_range > 0.0 and explicit_targets.is_empty() \
			and not has_anchor and not free and String(ability.targeting.get("shape", "")) != "cone":
		var clamped := clamp_point_to_range(character.global_position, target_position, max_range)
		if clamped != target_position and clamped.distance_to(target_position) > RANGE_CLAMP_NOTICE_PX \
				and character.has_method("is_party_member") and character.is_party_member() \
				and not (character.get("ai_cast_attempt") == true):
			character.notify("Out of range", Color(1.0, 0.6, 0.4), "%s's %s falls short: the target was %d away, range %d." % [
				character.Name, ability.display_name, int(character.global_position.distance_to(target_position)), int(max_range)])
		target_position = clamped

	# Infatuated: block offensive abilities that would hit the charm source
	if _would_hit_infatuation_source(ability, target_position):
		var cond_mgr = _get_condition_manager()
		var inf_instance = cond_mgr.conditions.get("infatuated") if cond_mgr else null
		var source_name = inf_instance.source.Name if inf_instance and is_instance_valid(inf_instance.source) else "them"
		GameLog.add_entry(character.Name + " can't use " + ability.display_name + " against " + source_name + "!")
		cast_failed.emit(ability, "Cannot harm charm source")
		return false

	# Law: a severely illegal cast asks for one cast-again confirmation per
	# map — legality is jurisdiction-dependent and invisible, and committing
	# a capital crime by misclick is worse than a prompt. Same refusal
	# protocol as the infatuation veto above. The crime report itself fires
	# on COMPLETION (ProceduralCharacter._on_ability_cast_completed), so an
	# interrupted cast is never a crime.
	var law_confirm: Dictionary = CrimeManager.cast_needs_confirmation(character, ability)
	if not law_confirm.is_empty():
		var verdict: Dictionary = law_confirm.get("verdict", {})
		GameLog.add_entry("%s here is %s — a crime under the law of %s (severity %d). Cast again if you mean to break the law." % [
			ability.display_name, str(verdict.get("display_name", "illegal")),
			str(verdict.get("law_faction", "?")), int(verdict.get("severity", 0))])
		cast_failed.emit(ability, "Illegal here: " + str(verdict.get("display_name", "")))
		return false

	if not free and not _pay_ability_costs(ability):
		cast_failed.emit(ability, "Cannot pay costs")
		return false

	if ability.cast_time <= 0:
		_execute_ability(ability, target_position, explicit_targets, target_anchor)
		return true

	_start_casting(ability, target_position, explicit_targets, target_anchor, free)
	return true


## Start the casting process (windup before execution). A free (item) cast
## is never interrupted: the item is already spent.
func _start_casting(ability: Ability, target_position: Vector2, explicit_targets: Array = [], target_anchor = null, free: bool = false) -> void:
	current_cast = {
		"ability": ability,
		"state": "casting",
		"target_position": target_position,
		"explicit_targets": explicit_targets,
		"anchor": target_anchor,
		"cast_progress": 0.0,
		"cast_time": ability.cast_time,
		"free": free,
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
		var carried_targets: Array = current_cast.get("explicit_targets", [])
		var carried_anchor = current_cast.get("anchor", null)
		# Re-aim after the windup, not before it: a long cast is exactly the
		# window in which the designated character walks out from under the point
		# captured when the cast began.
		var target_pos: Vector2 = _anchored_position(ability, carried_anchor, current_cast["target_position"])
		current_cast.clear()
		_execute_ability(ability, target_pos, carried_targets, carried_anchor)


## Execute the ability after casting completes
func _execute_ability(ability: Ability, target_position: Vector2, explicit_targets: Array = [], target_anchor = null) -> void:
	if ability.is_multi_step():
		_start_step_sequence(ability, target_position, explicit_targets, target_anchor)
	else:
		# When the ability targets specific characters, skip the projectile path
		# and resolve effects directly against the chosen targets.
		var projectile_path = ability.visuals.get("projectile", "")
		var has_explicit = not explicit_targets.is_empty()
		if not has_explicit and projectile_path != "" and character.has_method("_spawn_projectile"):
			character._spawn_projectile(ability, target_position)
		else:
			# Same rule the multi-step path applies per step: a blast centred on
			# the caster (Repulsion Wave) spares the caster, a buff centred on
			# them does not. See _resolve_step_and_advance.
			var results = _resolve_effects(ability, ability.effects, target_position, explicit_targets,
				_is_self_centered(ability.targeting) and _harms_targets(ability.effects))
			if character.has_method("_spawn_ability_visuals"):
				character._spawn_ability_visuals(ability, target_position)
			cast_completed.emit(ability, results)


## Start a multi-step ability sequence
func _start_step_sequence(ability: Ability, target_position: Vector2, explicit_targets: Array = [], target_anchor = null) -> void:
	current_cast = {
		"ability": ability,
		"state": "stepping",
		"target_position": target_position,
		"explicit_targets": explicit_targets,
		"anchor": target_anchor,
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
	var planned_target: Vector2 = current_cast.get("target_position", character.global_position)
	# Steps are separated by delays, so re-aim on every one rather than reusing
	# the position the sequence started with.
	var base_target: Vector2 = _anchored_position(ability, current_cast.get("anchor", null), planned_target)

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
	# The sequence was cancelled (the caster died) while a dash was under way.
	if current_cast.is_empty() or current_cast.get("ability") != ability:
		return
	var step_effects = step.get("effects", [])

	# Per-step animation
	var step_anim = step.get("animation", "")
	if step_anim != "" and character.has_method("play_animation"):
		character.play_animation(step_anim)

	# Resolve effects (carry explicit targets through multi-step sequences).
	# A step that recentres on the caster ("targeting": {"type": "self"}) and
	# hurts what it touches is a burst radiating FROM the body — pounce's claw
	# sweep, ram's impact. The area sweep is run against the ABILITY's targeting
	# (an ordinary circle), so without this the caster, standing exactly at the
	# centre, is the first thing their own claws land on.
	var step_explicit_targets: Array = current_cast.get("explicit_targets", [])
	var results = _resolve_effects(ability, step_effects, target_pos, step_explicit_targets,
		_is_self_centered(step.get("targeting", {})) and _harms_targets(step_effects))

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


## Whether a targeting block recentres on the caster — either a whole ability
## (Repulsion Wave) or a single step of one (pounce's claw sweep after the dash).
static func _is_self_centered(targeting: Dictionary) -> bool:
	return String(targeting.get("type", "")) == "self"


## Whether every effect in `effects` is one that damages or displaces whoever it
## lands on. Used to decide if a self-centred burst should spare its own caster —
## a self-centred HEAL obviously should not.
static func _harms_targets(effects: Array) -> bool:
	const HARMFUL := ["damage", "knockback", "sever_limb", "disarm"]
	var found_any := false
	for effect in effects:
		if not effect is Dictionary:
			continue
		if not (String(effect.get("type", "")) in HARMFUL):
			return false
		found_any = true
	return found_any


## Resolve an array of effects against targets
func _resolve_effects(ability: Ability, effects: Array, target_position: Vector2, explicit_targets: Array = [], exclude_caster: bool = false) -> Array:
	var targets = []
	if not explicit_targets.is_empty():
		# Player explicitly picked these targets — skip area sweep
		for t in explicit_targets:
			if is_instance_valid(t):
				targets.append(t)
	elif character.has_method("_find_targets_in_area"):
		targets = character._find_targets_in_area(ability, target_position)

	if exclude_caster:
		targets.erase(character)

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


## `point` pulled back along the line from `origin` to at most `max_range`
## away (unchanged when max_range <= 0 or it is already in range). The one
## clamp shared by the targeting preview, its confirm and execution.
static func clamp_point_to_range(origin: Vector2, point: Vector2, max_range: float) -> Vector2:
	if max_range <= 0.0 or not point.is_finite() or not origin.is_finite():
		return point
	var offset := point - origin
	if offset.length() <= max_range:
		return point
	return origin + offset.normalized() * max_range


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


## Whether this ability is one the caster's RACE grants (pounce, ram, beguile,
## breath_weapon...). Innate abilities skip the school-resource gate: they carry
## a school trait for classification, but no playable race grants the matching
## school TIER, so max_harmony/max_souls is 0 and the gate rejects every cast
## silently — a racial ability that can never fire. Read from race data rather
## than a flag on the character so it survives save/load for free.
func _is_innate_ability(ability: Ability) -> bool:
	if ability == null or ability.id == "":
		return false
	if not "race_id" in character:
		return false
	var rid := String(character.race_id)
	if rid == "":
		return false
	return ability.id in RaceDatabase.get_race_data(rid).get("active_abilities", [])


## Check if ability can be used. Reasons are player-facing (floated over the
## caster and logged by ProceduralCharacter._announce_cast_failure).
## A "free" cast (an item's use_ability, e.g. a potion handed to an ally) is a
## passive effect on the recipient: only the "Already casting" gate applies.
func _check_ability_usable(ability: Ability, free: bool = false) -> Dictionary:
	# Stunned / Frozen / Apathetic / Unconscious (the "incapacitate" trait): no
	# casting, though a free cast (a potion poured into a stunned ally) lands.
	var incap = null if free else _get_incapacitating_condition()
	if incap != null:
		return {"success": false, "reason": AbilityEffect.condition_display_name(incap.condition.id)}

	# Equipment / trait requirements (Shield Bash needs a shield) come before
	# the resource gate: "Needs a shield" is the reason that helps.
	if not free:
		for t in ability.requirements.get("traits", []):
			if not _meets_requirement(String(t)):
				return {"success": false, "reason": requirement_reason(String(t))}

	# NPCs without school tiers opt out of the cost gate so legacy enemies
	# don't lose their kit until their data is hand-tagged. Racial actives opt
	# out for the same reason — see _is_innate_ability.
	var skip_resource_gate: bool = free or ("npc_unlimited_resources" in character and character.npc_unlimited_resources) \
		or _is_innate_ability(ability)

	if not skip_resource_gate:
		var costs := school_costs_for(ability)
		for resource_name in costs:
			var cost: int = int(costs[resource_name])
			if character.has_method("_get_character_resource"):
				var current = character._get_character_resource(resource_name)
				if current < cost:
					return {"success": false, "reason": "Not enough %s" % resource_name}

	var reqs: Dictionary = {} if free else ability.requirements
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


## Player-facing text for an unmet requirements.traits entry.
static func requirement_reason(trait_id: String) -> String:
	if REQUIREMENT_REASONS.has(trait_id):
		return String(REQUIREMENT_REASONS[trait_id])
	return "Requires %s" % trait_id.capitalize()


## A requirements.traits entry: the character's own predicate when it has one
## (has_shield checks the hands), else its trait tier.
func _meets_requirement(trait_id: String) -> bool:
	if character.has_method("meets_ability_requirement"):
		return character.meets_ability_requirement(trait_id)
	return "traits" in character and int(character.traits.get(trait_id, 0)) > 0


## The active condition that keeps the caster from acting (Stunned, Frozen,
## Apathetic, Unconscious: the "incapacitate" trait), or null. Uses the
## character's own query when it has one.
func _get_incapacitating_condition():
	if character and character.has_method("get_incapacitating_condition"):
		return character.get_incapacitating_condition()
	var cm = _get_condition_manager()
	if cm == null:
		return null
	for inst in cm.get_conditions_with_trait("incapacitate"):
		if inst.is_active():
			return inst
	return null


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
	# Innate racial abilities are free — the gate above already let them through,
	# so charging here would fail the cast at the till instead.
	if _is_innate_ability(ability):
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


## Interrupt the current windup. Only a cast still winding up ("casting") can
## be interrupted: a multi-step sequence may be mid-dash. An item (free) cast
## never is. An "interruptible": false ability shrugs off hits and knockback,
## but `force` (an incapacitating condition) still ends it. Returns true when
## the cast was stopped; cast_interrupted carries the reason for feedback.
func interrupt_cast(reason: String = "Interrupted", force: bool = false) -> bool:
	if current_cast.get("state", "") != "casting":
		return false
	if current_cast.get("free", false):
		return false

	var ability = current_cast.get("ability") as Ability
	if ability and not ability.interruptible and not force:
		return false

	current_cast.clear()
	_current_step_index = -1
	_step_waiting = false

	if ability:
		cast_interrupted.emit(ability, reason)

	return true


## Drop any windup or step sequence outright (the caster died). With
## `keep_uninterruptible`, an "interruptible": false ability is left to finish
## (a dying breath). Still emits cast_interrupted so the character's preview and
## arm pose are cleaned up; an empty reason means no announcement.
func cancel_cast(reason: String = "", keep_uninterruptible: bool = false) -> void:
	if current_cast.is_empty():
		return
	var ability = current_cast.get("ability") as Ability
	if keep_uninterruptible and ability and not ability.interruptible:
		return
	current_cast.clear()
	_current_step_index = -1
	_step_waiting = false
	if ability:
		cast_interrupted.emit(ability, reason)


## Whether the manager is currently executing an ability
func is_casting() -> bool:
	return not current_cast.is_empty()


## Get condition manager from character
func _get_condition_manager():
	if character and character.has_node("ConditionManager"):
		return character.get_node("ConditionManager")
	return null


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
