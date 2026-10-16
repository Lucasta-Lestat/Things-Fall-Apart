# AbilityEffect.gd
# Handles resolution of ability effects including damage, healing, conditions, and force fields
# Integrates with the condition system for trait-based modifiers
class_name AbilityEffect
extends RefCounted

## D&D 5e damage types
const DAMAGE_TYPES = [
	"acid",
	"bludgeoning",
	"cold",
	"fire",
	"force",
	"electric",
	"necrotic",
	"piercing",
	"poison",
	"psychic",
	"radiant",
	"slashing",
	"sonic",
	"true"  # Untyped/true damage (ignores resistances)
]

## Effect types
const EFFECT_TYPES = [
	"damage",           # Deal damage
	"heal",             # Restore health
	"apply_condition",  # Apply a condition
	"remove_condition", # Remove a condition
	"force_field",      # Create a force field
	"knockback",        # Apply knockback force
	"teleport",         # Move target instantly
	"summon",           # Summon an entity
	"cloud",            # Create a Cloud
	"spawn_fluid",      # Spawn fluid at target (acid, poison, etc.)
	"fluid_well",       # Gush fluid over a region for a duration (oil well)
	"compulsion_field", # Persistent point of compulsion (musk cloud, idol)
	"sound_zone",       # Create a region that damps sound (Silence)
	"custom",           # Custom effect with callback
]


## Resolve a single effect from an ability
## Returns a dictionary with results of the effect
static func resolve_effect(
	effect: Dictionary,
	caster: Node,
	targets: Array,
	ability: Ability,
	target_position: Vector2
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": effect.get("type", ""),
		"targets_affected": [],
		"total_damage": 0.0,
		"total_healing": 0.0,
		"conditions_applied": [],
		"conditions_removed": [],
		"created_objects": [],
	}
	var effect_type = effect.get("type", "")
	print("attempting to resolve ability effect")
	match effect_type:
		"damage":
			result = _resolve_damage(effect, caster, targets, ability)
		"heal":
			result = _resolve_healing(effect, caster, targets, ability)
		"apply_condition":
			print("applying condition in resolve_effect")
			result = _resolve_apply_condition(effect, caster, targets, ability)
		"remove_condition":
			result = _resolve_remove_condition(effect, caster, targets, ability)
		"force_field":
			result = _resolve_force_field(effect, caster, target_position, ability)
		"knockback":
			result = _resolve_knockback(effect, caster, targets, target_position)
		"teleport":
			result = _resolve_teleport(effect, caster, targets, target_position)
		"custom":
			result = _resolve_custom(effect, caster, targets, ability, target_position)
		"summon":
			result = _resolve_summon(effect, caster, target_position, ability)
		"cloud":
			result = _resolve_cloud(effect, caster, target_position, ability)
		"spawn_fluid":
			result = _resolve_spawn_fluid(effect, caster, target_position, ability)
		"fluid_well":
			result = _resolve_fluid_well(effect, caster, target_position)
		"compulsion_field":
			result = _resolve_compulsion_field(effect, caster, target_position)
		"sever_limb":
			result = _resolve_sever_limb(effect, caster, targets, ability)
		"sound_zone":
			result = _resolve_sound_zone(effect, caster, target_position)
		"disarm":
			result = _resolve_disarm(effect, caster, targets)
		_:
			result["success"] = false
			result["error"] = "Unknown effect type: %s" % effect_type
	
	return result

## Condition ids an effect list applies itself ({condition_id: true}), from its
## apply_condition effects. While those effects resolve, the list's damage
## doesn't add the same condition again (see
## ProceduralCharacter.begin_damage_condition_suppression).
static func explicit_condition_ids(effects: Array) -> Dictionary:
	var ids := {}
	for effect in effects:
		if not (effect is Dictionary) or effect.get("type", "") != "apply_condition":
			continue
		var cid = effect.get("condition_id", "")
		if cid != null and str(cid) != "":
			ids[str(cid)] = true
	return ids

## Resolve summon effect
static func _resolve_summon(
	effect: Dictionary,
	caster: Node,
	target_position: Vector2,
	ability: Ability
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "summon",
		"created_objects": [],
	}

	var summon_type = effect.get("summon_type", "")  # "character", "item", "structure"
	var summon_id = effect.get("summon_id", "")
	var count = effect.get("count", 1)
	var spread = effect.get("spread_radius", 32.0)
	var stack_count = effect.get("stack_count", 1)

	if summon_id.is_empty():
		result["success"] = false
		result["error"] = "No summon_id specified"
		return result

	# Get the main scene — walk up from caster to find it
	var game = _get_game_scene(caster)
	if not game:
		result["success"] = false
		result["error"] = "Could not find game scene for spawning"
		return result

	for i in range(count):
		var pos = target_position
		if i > 0 and spread > 0:
			pos += Vector2(randf_range(-spread, spread), randf_range(-spread, spread))

		var spawned = null
		match summon_type:
			"character":
				if game.has_method("_spawn_character"):
					var overrides: Dictionary = (effect.get("overrides", {}) as Dictionary).duplicate(true)
					# Ally the summon to its caster. build_character reads "faction"
					# from overrides; the live character property is faction_id.
					if not overrides.has("faction") and "faction_id" in caster:
						overrides["faction"] = caster.faction_id
					spawned = game._spawn_character(summon_id, pos, overrides)
					if spawned:
						spawned.AI_enabled = true
						if "faction_id" in caster and "faction_id" in spawned:
							spawned.faction_id = caster.faction_id
						# Law: crimes a summon commits attribute to its
						# summoner (CrimeManager.attribute walks this meta)
						# — otherwise the rats take the blame and despawn.
						spawned.set_meta("summoned_by", caster)
						# Render this combatant as a boid swarm if its template opts in.
						_attach_swarm_visual(spawned)
			"item":
				if game.has_method("create_item"):
					spawned = game.create_item(summon_id, pos, stack_count)
			"structure":
				if game.has_method("create_structure"):
					spawned = game.create_structure(summon_id, pos)
			_:
				push_warning("Unknown summon_type: %s" % summon_type)
				continue

		if spawned:
			result["created_objects"].append(spawned)

	if result["created_objects"].is_empty():
		result["success"] = false
		result["error"] = "Failed to spawn any objects"

	return result


## Render a summoned combatant as a boid swarm if its template opts in via
## "swarm_visual": "<preset>" (e.g. rat_swarm). The BoidField lives under the
## scene root because it simulates in world space; a SwarmVisualController makes
## it follow the actor, hides the normal body, and despawns it on death.
static func _attach_swarm_visual(actor: Node) -> void:
	if not is_instance_valid(actor):
		return
	var template: Dictionary = TopDownCharacterDatabase.get_template(actor.template_id)
	var preset: String = String(template.get("swarm_visual", ""))
	if preset.is_empty():
		return
	var scene_root := actor.get_tree().current_scene
	if scene_root == null:
		return
	var controller := SwarmVisualController.new()
	scene_root.add_child(controller)
	controller.setup(actor, preset)


## Walk up the scene tree from a node to find the main game scene
static func _get_game_scene(node: Node) -> Node:
	# Try the tree root's main scene first
	var tree = node.get_tree()
	if tree:
		var root = tree.current_scene
		if root and root.has_method("create_item"):
			return root
		# Search children of root (in case game is a child node)
		for child in root.get_children():
			if child.has_method("create_item"):
				return child
	# Walk up from the caster
	var current = node
	while current:
		if current.has_method("create_item") and current.has_method("_spawn_character"):
			return current
		current = current.get_parent()
	return null
	
static func _resolve_cloud(
	effect: Dictionary,
	caster: Node,
	target_position: Vector2,
	ability: Ability
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "cloud",
		"created_objects": [],
	}

	var game = _get_game_scene(caster)
	if not game:
		result["success"] = false
		result["error"] = "Could not find game scene"
		return result

	var fog_manager = game.get_node_or_null("FogManager")
	if not fog_manager:
		result["success"] = false
		result["error"] = "No FogManager found"
		return result

	var cloud_color = Color(effect.get("color", "#808080"))
	var cloud_size = Vector2(
		effect.get("radius", 64.0) * 2,
		effect.get("radius", 64.0) * 2
	)
	var duration = effect.get("duration", 10.0)
	var condition_id = effect.get("condition_id", "")
	var condition_stacks = effect.get("condition_stacks", 1)
	var condition_duration = effect.get("condition_duration", -2.0)
	var apply_interval = effect.get("apply_interval", 1.0)
	var density = effect.get("density", 0.6)
	var speed = Vector2(
		effect.get("speed_x", 0.02),
		effect.get("speed_y", 0.01)
	)

	var overlay = fog_manager.create_cloud(
		cloud_color,
		cloud_size,
		duration,
		condition_id,
		condition_stacks,
		condition_duration,
		apply_interval,
		density,
		4.0,
		speed,
		target_position,
		caster
	)

	if overlay:
		result["created_objects"].append(overlay)
	else:
		result["success"] = false
		result["error"] = "Failed to create cloud"

	return result


## Resolve sound_zone effect — creates a persistent region that damps every
## sound emitted inside, heard inside, or passing through it. A `gain` of 0.0
## is total silence; higher values muffle instead of smothering, so the same
## effect covers quiet zones without new code.
static func _resolve_sound_zone(
	effect: Dictionary,
	caster: Node,
	target_position: Vector2
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "sound_zone",
		"created_objects": [],
	}

	var game = _get_game_scene(caster)
	if not game:
		result["success"] = false
		result["error"] = "Could not find game scene"
		return result

	var zone := SilenceZone.new()
	zone.radius = float(effect.get("radius", 120.0))
	zone.gain = float(effect.get("gain", 0.0))
	zone.duration = float(effect.get("duration", 20.0))

	# Parent first, then position: setting global_position before the node has
	# a parent transform silently means something different (see the note on
	# _resolve_force_field below). HearingManager registration happens in
	# SilenceZone._ready, i.e. during add_child.
	game.add_child(zone)
	zone.global_position = target_position

	result["created_objects"].append(zone)
	return result


## Resolve spawn_fluid effect — creates fluid tiles at the target position
static func _resolve_spawn_fluid(
	effect: Dictionary,
	caster: Node,
	target_position: Vector2,
	ability: Ability
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "spawn_fluid",
		"created_objects": [],
	}

	var fluid_type = effect.get("fluid_type", "water")
	var amount = effect.get("amount", 0.5)
	var spread = int(effect.get("spread", 1))  # How many tiles to fill (radius)

	# Convert world position to grid tile
	var center_tile = GridManager.world_to_map(target_position)

	var fluid_manager = _get_fluid_manager(caster)
	if not fluid_manager:
		result["success"] = false
		result["error"] = "No FluidManager found"
		return result

	# Fill tiles in a diamond/square pattern around the center
	for dx in range(-spread + 1, spread):
		for dy in range(-spread + 1, spread):
			if abs(dx) + abs(dy) < spread:
				var tile = center_tile + Vector2i(dx, dy)
				fluid_manager.register_fluid(tile, fluid_type, amount)
				result["created_objects"].append(tile)

	return result


## Resolve fluid_well effect -- a point that gushes fluid for a fixed time.
##
## `spawn_fluid` paints a one-shot Manhattan diamond; this plants a self-expiring
## node that keeps topping the region up, so the pool grows outward, holds, and
## heals where it has drained. The node owns its own visual too, because
## `visuals.impact_effect` is hard-freed on the (inert) visual_duration timer at
## ~1.95s and so cannot cover a multi-second effect.
static func _resolve_fluid_well(
	effect: Dictionary,
	caster: Node,
	target_position: Vector2
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "fluid_well",
		"created_objects": [],
	}

	var game = _get_game_scene(caster)
	if not game:
		result["success"] = false
		result["error"] = "Could not find game scene"
		return result

	var well := FluidWell.new()
	well.fluid_type = String(effect.get("fluid_type", "water"))
	well.radius = float(effect.get("radius", 160.0))
	well.duration = float(effect.get("duration", 6.0))
	well.visual_scene_path = String(effect.get("vfx_scene", ""))

	# Parent first, then position -- the same rule as _resolve_sound_zone above.
	# FluidWell deliberately defers its tile/cell precompute to the first tick
	# rather than doing it in _ready(), because at add_child time global_position
	# is still (0, 0) and every tile it picked there would be wrong.
	game.add_child(well)
	well.global_position = target_position

	result["created_objects"].append(well)
	return result


## Resolve compulsion_field -- a conjured point that periodically tries to seize
## what everyone who can perceive it does.
##
## The saving throw is NOT here: the field re-applies its condition on a timer
## and ConditionManager.apply_condition rolls save_stat at apply time, so
## "periodically save or suffer" falls out of the existing machinery.
static func _resolve_compulsion_field(
	effect: Dictionary,
	caster: Node,
	target_position: Vector2
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "compulsion_field",
		"created_objects": [],
	}

	var game = _get_game_scene(caster)
	if not game:
		result["success"] = false
		result["error"] = "Could not find game scene"
		return result

	var field := CompulsionField.new()
	field.radius = float(effect.get("radius", 256.0))
	field.duration = float(effect.get("duration", 12.0))
	field.reach = String(effect.get("reach", "radius"))
	field.reach_limit = float(effect.get("reach_limit", 640.0))
	field.affects = String(effect.get("affects", "all"))
	field.affects_humanoid_only = bool(effect.get("affects_humanoid_only", true))
	field.pulse_interval = float(effect.get("pulse_interval", 3.0))
	field.condition_id = String(effect.get("condition_id", "incited"))
	field.condition_duration = float(effect.get("condition_duration", -2.0))
	field.victim_rule = String(effect.get("victim_rule", "same_gender"))
	field.victim_search_radius = float(effect.get("victim_search_radius", 512.0))
	field.visual_scene_path = String(effect.get("vfx_scene", ""))
	field.sprite_path = String(effect.get("sprite_path", ""))
	field.sprite_width = float(effect.get("sprite_width", 0.0))

	# Parent first, then position -- the same rule as _resolve_sound_zone and
	# _resolve_fluid_well. CompulsionField defers its first pulse to the first
	# unpaused tick for exactly that reason.
	game.add_child(field)
	field.global_position = target_position

	result["created_objects"].append(field)
	return result


static func _get_fluid_manager(caster: Node):
	var game = _get_game_scene(caster)
	if not game:
		return null
	return game.get_node_or_null("FluidManager")


static func _resolve_damage(
	effect: Dictionary,
	caster: Node,
	targets: Array,
	ability: Ability
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "damage",
		"targets_affected": [],
		"total_damage": 0.0,
		"damage_breakdown": [],
	}
	
	var base_damage: Dictionary = effect.get("damage", {})
	var required_traits = effect.get("target_traits", [])
	var immune_traits = effect.get("immune_traits", [])
	
	var caster_traits = _get_entity_traits(caster)
	var caster_conditions = _get_condition_manager(caster)
	
	for target in targets:
		if not is_instance_valid(target):
			continue

		var target_traits = _get_entity_traits(target)

		if not required_traits.is_empty():
			var has_required = false
			for req in required_traits:
				if req in target_traits:
					has_required = true
					break
			if not has_required:
				continue
				
		var is_immune = false
		for immune in immune_traits:
			if immune in target_traits:
				is_immune = true
				break
		if is_immune:
			continue
			
		var final_damage = _calculate_modified_damage(
			base_damage.duplicate(),
			caster,
			target,
			caster_traits,
			target_traits,
			ability.traits,
			caster_conditions
		)
		
		# DR is skipped here. target.take_damage handles armor + character DR natively.
		var damage_dealt = _deal_damage_to_target(target, final_damage, caster)
		
		result["targets_affected"].append({
			"target": target,
			"damage": damage_dealt,
			"damage_types": final_damage.keys()
		})
		result["total_damage"] += damage_dealt
		
	return result

## Force each target to drop their held main-hand weapon at their feet.
## Effect schema: {type: "disarm", chance: 0-1 (default 1), save_stat: "str"}.
## A successful save (negative saving_throw delta) resists.
static func _resolve_disarm(effect: Dictionary, _caster: Node, targets: Array) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "disarm",
		"targets_affected": [],
	}
	var chance: float = float(effect.get("chance", 1.0))
	var save_stat: String = str(effect.get("save_stat", ""))
	for target in targets:
		if not is_instance_valid(target):
			continue
		if chance < 1.0 and randf() >= chance:
			continue
		if save_stat != "" and target.has_method("saving_throw"):
			if target.saving_throw(save_stat) < 0:
				continue
		if target.has_method("drop_held_weapon"):
			var held = target.get("current_main_hand_item")
			if held != null and held is WeaponShape:
				# DEFERRED: melee disarm procs fire inside the weapon-hitbox
				# body_entered flush, where detaching the victim's WeaponShape
				# (a physics body) is rejected by the physics server — same
				# reason corpse layer changes use set_deferred.
				target.call_deferred("drop_held_weapon", "Main")
				result["targets_affected"].append(target)
	return result


static func _resolve_apply_condition(
	effect: Dictionary,
	caster: Node,
	targets: Array,
	ability: Ability
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "apply_condition",
		"targets_affected": [],
		"conditions_applied": [],
	}
	
	var condition_id = effect.get("condition_id", "")
	var stacks = effect.get("stacks", 1)
	var duration_override = effect.get("duration", -2.0)
	var target_limb = effect.get("target_limb", null)
	var chance: float = float(effect.get("chance", 1.0))
	# Effect-level save: rolls the same stack-delta as condition-level
	# save_stat, but scoped to THIS application only — the condition template
	# (and every other way it gets applied) is untouched.
	var effect_save: String = str(effect.get("save_stat", ""))
	# When set, the stacks applied equal the caster's current stack count of the
	# named condition (used for mutation-tier-scales-effect, e.g. The Jaws That Bite).
	var scale_by: String = str(effect.get("scale_stacks_by_caster_condition", ""))
	if scale_by != "" and caster and "condition_manager" in caster and caster.condition_manager:
		var src = caster.condition_manager.conditions.get(scale_by)
		if src:
			stacks = src.stacks

	for target in targets:
		if not is_instance_valid(target):
			continue

		# Looked up before the roll, so a target that can't hold conditions
		# never shows a miss notice.
		var target_cond_manager = _get_condition_manager(target)
		if not target_cond_manager:
			continue
		# Corpses take no conditions (ConditionManager refuses them); skip them
		# before the roll and the save so no "Resisted" or "No effect" floats
		# over a tombstone.
		if target.has_method("is_alive") and not target.is_alive():
			continue

		if chance < 1.0:
			var roll := randf()
			if roll >= chance:
				_announce_chance_miss(target, caster, condition_id, ability, chance, roll)
				continue

		var apply_stacks = stacks
		if effect_save != "" and target.has_method("saving_throw"):
			apply_stacks += target.saving_throw(effect_save)
			if apply_stacks <= 0:
				_announce_effect_save(target, caster, condition_id, ability, effect_save)
				continue

		# Saves and immunities inside apply_condition are reported by ConditionManager.
		# The ConditionManager scales durations internally based on target traits
		var instance = target_cond_manager.apply_condition(
			condition_id,
			caster,
			apply_stacks,
			duration_override,
			target_limb
		)
		
		if instance:
			result["targets_affected"].append(target)
			result["conditions_applied"].append({
				"target": target,
				"condition": condition_id,
				"stacks": instance.stacks,
				# The exact instance, so Concentration can tell its own
				# application from a later one.
				"instance": instance,
			})

	return result


## A condition rider that only lands some of the time ("chance": 0.8) missed:
## float "Resisted" over the target, and log the roll when the party is involved.
static func _announce_chance_miss(target: Node, caster: Node, condition_id: String, ability: Ability, chance: float, roll: float) -> void:
	var tmpl = ConditionManager.condition_registry.get(condition_id)
	var is_debuff: bool = tmpl != null and tmpl.traits.has("debuff")
	var log_text := ""
	if _involves_party(caster) or _involves_party(target):
		# Displayed as a d100: the rider lands on a roll of chance% or lower.
		log_text = "%s %s %s from %s (%d%% chance: rolled %d)." % [
			_node_name(target),
			"avoids" if is_debuff else "doesn't gain",
			condition_display_name(condition_id),
			ability.display_name if ability else "the ability",
			int(round(chance * 100.0)),
			int(roll * 100.0) + 1,
		]
	_notify_rider(target, "Resisted" if is_debuff else "No effect", log_text)


## The effect's own "save_stat" (dev's per-application save) threw the rider
## off entirely: the same notice as a missed chance, with the save named.
static func _announce_effect_save(target: Node, caster: Node, condition_id: String, ability: Ability, save_stat: String) -> void:
	var log_text := ""
	if _involves_party(caster) or _involves_party(target):
		var detail := " (%s save)" % save_stat.to_upper()
		var roll = target.get("last_save_roll")
		var target_val = target.get("last_save_target")
		if roll is int and target_val is int and roll >= 0:
			detail = " (%s save: rolled %d vs %d)" % [save_stat.to_upper(), roll, target_val]
		log_text = "%s resists %s from %s%s." % [
			_node_name(target),
			condition_display_name(condition_id),
			ability.display_name if ability else "the ability",
			detail,
		]
	_notify_rider(target, "Resisted", log_text)


## Floats a rider notice over a target the party can see, with its log line
## (only built when the party is involved). A hidden NPC stays quiet, float
## and log alike, as ConditionManager's notices do: the log would name it.
static func _notify_rider(target: Node, text: String, log_text: String, color: Color = Color(0.6, 0.85, 1.0)) -> void:
	# "Seen" is line of sight (_announces_to_party: Game.is_seen_by_party), as
	# for condition notices and damage numbers: a hearing pulse also sets
	# `visible` on an NPC the party only heard.
	var seen: bool = (target._announces_to_party() if target.has_method("_announces_to_party")
			else (target is CanvasItem and target.visible))
	if not (_involves_party(target) or seen):
		return
	if target.has_method("notify"):
		target.notify(text, color, log_text)
	elif not log_text.is_empty():
		GameLog.add_entry(log_text)


## True when node is one of the player's party members.
static func _involves_party(node) -> bool:
	return node != null and is_instance_valid(node) and node.has_method("is_party_member") and node.is_party_member()


static func _node_name(node: Node) -> String:
	var n = node.get("Name")
	return str(n) if n != null and str(n) != "" else str(node.name)


## Player-facing name of a condition id: the template's display_name, else the
## id with underscores spaced out ("berserker_rage" -> "Berserker Rage").
static func condition_display_name(condition_id: String) -> String:
	var tmpl = ConditionManager.condition_registry.get(condition_id)
	if tmpl and tmpl.display_name != "":
		return tmpl.display_name
	return condition_id.capitalize()


## Sever a limb on each target. Effect schema:
##   {"type": "sever_limb", "target_limb": "RIGHT_ARM"}     # specific limb
##   {"type": "sever_limb", "random": true, "exclude_lethal": true}
##   {"type": "sever_limb"}                                 # defaults: random non-lethal
##
## HEAD/TORSO severs kill the target — enforced inside
## ProceduralCharacter._on_limb_severed, not duplicated here.
static func _resolve_sever_limb(
	effect: Dictionary,
	_caster: Node,
	targets: Array,
	_ability: Ability
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "sever_limb",
		"targets_affected": [],
		"limbs_severed": [],
	}

	# Parse target_limb: accept either a LimbType int or a string name like "RIGHT_ARM".
	var raw_target_limb = effect.get("target_limb", null)
	var explicit_limb = -1
	if raw_target_limb != null:
		if typeof(raw_target_limb) == TYPE_INT:
			explicit_limb = int(raw_target_limb)
		elif typeof(raw_target_limb) == TYPE_STRING:
			var keys: Array = ProceduralCharacter.LimbType.keys()
			var idx: int = keys.find(String(raw_target_limb).to_upper())
			if idx >= 0:
				explicit_limb = idx

	var exclude_lethal: bool = bool(effect.get("exclude_lethal", true))

	for target in targets:
		if not is_instance_valid(target):
			continue
		if not target.has_method("_on_limb_severed"):
			continue

		var limb_type: int = explicit_limb
		if limb_type < 0:
			# Random pick. _pick_random_severable_limb already excludes lethal
			# limbs and already-severed limbs.
			if target.has_method("_pick_random_severable_limb"):
				limb_type = target._pick_random_severable_limb()
			else:
				limb_type = ProceduralCharacter.LimbType.RIGHT_ARM

		if exclude_lethal and (limb_type == ProceduralCharacter.LimbType.HEAD or limb_type == ProceduralCharacter.LimbType.TORSO):
			# Caller asked for non-lethal but pointed at a lethal limb — skip.
			continue

		target._on_limb_severed(limb_type)
		result["targets_affected"].append(target)
		result["limbs_severed"].append({
			"target": target,
			"limb_type": limb_type,
		})

	return result


static func _calculate_modified_damage(
	base_damage: Dictionary,
	caster: Node,
	target: Node,
	caster_traits: Dictionary,
	target_traits: Dictionary,
	ability_traits: Dictionary,
	caster_conditions: ConditionManager
) -> Dictionary:
	if not caster_conditions:
		return base_damage
	
	var modified = base_damage.duplicate()
	
	# Get conditional modifiers from caster's conditions
	var modifiers = caster_conditions.get_conditional_modifiers(
		EffectResolver.TriggerType.ON_ATTACK,
		caster_traits,
		target_traits,
		ability_traits
	)
	# Separate flat and percent modifiers
	var flat_bonus: float = 0.0
	var percent_bonus: float = 1.0
	
	for mod in modifiers:
		var mod_type = mod.get("modifier_type")
		var value = mod.get("value", 0)
		
		if mod_type == EffectResolver.ModifierType.FLAT_DAMAGE_DEALT:
			flat_bonus += value
		elif mod_type == EffectResolver.ModifierType.PERCENT_DAMAGE_DEALT:
			percent_bonus *= (1.0 + value / 100.0)
	
	# Apply modifiers to each damage type
	# Flat bonus is distributed evenly, percent applies to each
	var num_types = max(1, modified.size())
	var flat_per_type = flat_bonus / num_types
	
	for damage_type in modified.keys():
		modified[damage_type] = (modified[damage_type] + flat_per_type) * percent_bonus
	
	return modified




## Deal damage to any target type (character, item, or structure)
static func _deal_damage_to_target(target: Node, damage_dict: Dictionary, attacker: Node = null) -> float:
	var total = 0.0
	for damage_type in damage_dict:
		total += damage_dict[damage_type]

	if total <= 0.0:
		return 0.0

	# Characters with the single-HP-pool system — pick a random limb for armor
	# DR / flavor (which armor piece resists this hit), then route through
	# take_damage which applies DR + bide + deny_ending and subtracts from
	# current_health. We check has_method("take_damage") + has("limbs") to
	# disambiguate from Item.take_damage (which takes a different signature).
	if target.has_method("take_damage") and "limbs" in target:
		var hit_limb = _pick_random_limb(target)
		# `attacker` used to be hardcoded null here, so a spell kill was never
		# attributed: the victim's AT_EASE wake never fired toward the caster
		# and the witness/crime pipeline recorded a death with no perpetrator.
		# Murder by fireball was, quite literally, the perfect crime.
		target.take_damage(damage_dict, target.global_position, attacker, hit_limb)
	# Items / Structures use take_damage(damage_dict, success_level)
	elif target.has_method("take_damage"):
		if target is Item or target is Structure:
			target.take_damage(damage_dict, 0)
		else:
			# Unknown type with take_damage — try dict signature
			target.take_damage(damage_dict, 0)
	elif "HP_CURRENT" in target:
		target.HP_CURRENT = max(0, target.HP_CURRENT - total)

	return total


## Pick a random limb weighted by size (for abilities without a specific hit position)
static func _pick_random_limb(target: Node) -> int:
	# LimbType enum: HEAD=0, TORSO=1, LEFT_ARM=2, RIGHT_ARM=3, LEFT_LEG=4, RIGHT_LEG=5
	# Weight torso highest since it's the biggest target
	var weights = [0.1, 0.35, 0.1, 0.1, 0.175, 0.175]
	var roll = randf()
	var cumulative = 0.0
	for i in range(weights.size()):
		cumulative += weights[i]
		if roll <= cumulative:
			return i
	return 1  # Default to torso


## Resolve healing effect
static func _resolve_healing(
	effect: Dictionary,
	caster: Node,
	targets: Array,
	ability: Ability
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "heal",
		"targets_affected": [],
		"total_healing": 0.0,
	}
	
	var base_healing = effect.get("amount", 0.0)
	var caster_traits = _get_entity_traits(caster)
	var caster_conditions = _get_condition_manager(caster)
	
	for target in targets:
		if not is_instance_valid(target):
			continue
		
		var target_traits = _get_entity_traits(target)
		
		# Calculate modified healing
		var final_healing = base_healing
		
		if caster_conditions:
			var modifiers = caster_conditions.get_conditional_modifiers(
				EffectResolver.TriggerType.ON_HEAL,
				caster_traits,
				target_traits,
				ability.traits
			)
			
			for mod in modifiers:
				var mod_type = mod.get("modifier_type")
				var value = mod.get("value", 0)
				
				if mod_type == EffectResolver.ModifierType.FLAT_HEALING_DEALT:
					final_healing += value
				elif mod_type == EffectResolver.ModifierType.PERCENT_HEALING_DEALT:
					final_healing *= (1.0 + value / 100.0)
		
		# Apply healing
		var healed = _heal_target(target, final_healing)
		
		result["targets_affected"].append({
			"target": target,
			"healing": healed
		})
		result["total_healing"] += healed
	
	return result


## Actually heal a target
static func _heal_target(target: Node, amount: float) -> float:
	if target.has_method("heal"):
		return target.heal(amount)
	return 0.0


## Resolve remove condition effect
static func _resolve_remove_condition(
	effect: Dictionary,
	caster: Node,
	targets: Array,
	ability: Ability
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "remove_condition",
		"targets_affected": [],
		"conditions_removed": [],
	}
	
	var condition_id = effect.get("condition_id", "")
	var remove_trait = effect.get("trait", "")  # Remove all conditions with this trait
	var stacks_to_remove = effect.get("stacks", -1)  # -1 = all
	# A pure cleanse (Chasten) says "No effect" when there was nothing to remove;
	# a cleanse riding on another effect (Heal's poison cure) stays quiet then.
	var cleanse_only := _is_cleanse_only(ability)

	for target in targets:
		if not is_instance_valid(target):
			continue

		var condition_manager = _get_condition_manager(target)
		if not condition_manager:
			continue

		var removed_names: Array[String] = []
		if remove_trait != "":
			# Remove conditions by trait
			var before: Array = condition_manager.conditions.keys()
			var count = condition_manager.remove_conditions_with_trait(remove_trait)
			if count > 0:
				for cid in before:
					if not condition_manager.conditions.has(cid):
						removed_names.append(condition_display_name(cid))
				result["targets_affected"].append(target)
				result["conditions_removed"].append({
					"target": target,
					"trait": remove_trait,
					"count": count
				})
		elif condition_id != "":
			# Remove specific condition
			if stacks_to_remove > 0:
				var removed = condition_manager.remove_stacks(condition_id, stacks_to_remove)
				if removed > 0:
					removed_names.append(condition_display_name(condition_id))
					result["targets_affected"].append(target)
					result["conditions_removed"].append({
						"target": target,
						"condition": condition_id,
						"stacks": removed
					})
			else:
				if condition_manager.remove_condition(condition_id):
					removed_names.append(condition_display_name(condition_id))
					result["targets_affected"].append(target)
					result["conditions_removed"].append({
						"target": target,
						"condition": condition_id
					})

		if not target.has_method("notify"):
			continue
		if not removed_names.is_empty():
			var log_text := ""
			if _involves_party(caster) or _involves_party(target):
				log_text = "%s ends %s on %s." % [
					ability.display_name if ability else "A cleanse",
					", ".join(removed_names),
					_node_name(target),
				]
			_notify_rider(target, "Cleansed", log_text)
		elif cleanse_only:
			_notify_rider(target, "No effect", "", Color(0.75, 0.75, 0.75))

	return result


## True when every effect of the ability is a remove_condition (e.g. Chasten).
static func _is_cleanse_only(ability: Ability) -> bool:
	if ability == null or ability.effects.is_empty():
		return false
	for e in ability.effects:
		if not (e is Dictionary) or e.get("type", "") != "remove_condition":
			return false
	return true


## Resolve force field creation
static func _resolve_force_field(
	effect: Dictionary,
	caster: Node,
	target_position: Vector2,
	ability: Ability
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "force_field",
		"created_objects": [],
	}
	
	var field_type = effect.get("field_type", "generic")
	var radius = effect.get("radius", 100.0)
	var strength = effect.get("strength", 500.0)
	var duration = effect.get("duration", 5.0)
	var affected_traits: Array[String] = []
	for t in effect.get("affected_traits", []):
		affected_traits.append(t)
	
	var field: ForceField = null
	
	match field_type:
		"magnetic_attract":
			field = _create_magnetic_field(target_position, radius, strength, MagneticField.Polarity.ATTRACT, affected_traits)
		"magnetic_repel":
			field = _create_magnetic_field(target_position, radius, strength, MagneticField.Polarity.REPEL, affected_traits)
		"gravity":
			field = _create_gravity_field(target_position, radius, strength, affected_traits)
		"repulsion":
			field = _create_repulsion_field(target_position, radius, strength, affected_traits)
		"vortex":
			var clockwise = effect.get("clockwise", true)
			var inward = effect.get("inward_pull", 0.3)
			field = _create_vortex_field(target_position, radius, strength, clockwise, inward)
		"wind":
			var direction = Vector2(
				effect.get("direction_x", 0),
				effect.get("direction_y", 1)
			)
			field = _create_wind_field(target_position, radius, strength, direction, affected_traits)
		_:
			field = _create_generic_field(target_position, radius, strength, affected_traits, effect)
	
	if field:
		# Visible for its whole duration, not just while the impact VFX plays
		field.show_outline = true
		# Add to scene
		var scene_root = caster.get_tree().current_scene
		scene_root.add_child(field)
		
		# Set up duration-based cleanup
		if duration > 0:
			var timer = Timer.new()
			timer.one_shot = true
			timer.wait_time = duration
			timer.timeout.connect(func(): 
				if is_instance_valid(field):
					field.queue_free()
			)
			field.add_child(timer)
			timer.start()
		
		result["created_objects"].append(field)
	
	return result


## Create a magnetic field
static func _create_magnetic_field(
	position: Vector2,
	radius: float,
	strength: float,
	polarity: MagneticField.Polarity,
	affected_traits: Array[String] = []
) -> MagneticField:
	var field = MagneticField.new()
	field.global_position = position
	field.polarity = polarity
	field.force_magnitude = strength
	# MagneticField._ready only falls back to its default ["metal", "magnetized"]
	# when this is still empty.
	if not affected_traits.is_empty():
		field.required_traits = affected_traits
	
	var collision = CollisionShape2D.new()
	var shape = CircleShape2D.new()
	shape.radius = radius
	collision.shape = shape
	field.add_child(collision)
	
	return field


## Create a gravity field
static func _create_gravity_field(
	position: Vector2,
	radius: float,
	strength: float,
	affected_traits: Array[String]
) -> ForceField:
	var field = ForceField.new()
	field.global_position = position
	field.force_magnitude = strength
	field.direction_type = ForceField.DirectionType.TOWARD_CENTER
	field.force_type = ForceField.ForceType.INVERSE_SQUARE
	field.required_traits = affected_traits
	
	var collision = CollisionShape2D.new()
	var shape = CircleShape2D.new()
	shape.radius = radius
	collision.shape = shape
	field.add_child(collision)
	
	return field


## Create a repulsion field
static func _create_repulsion_field(
	position: Vector2,
	radius: float,
	strength: float,
	affected_traits: Array[String]
) -> ForceField:
	var field = ForceField.new()
	field.global_position = position
	field.force_magnitude = strength
	field.direction_type = ForceField.DirectionType.AWAY_FROM_CENTER
	field.force_type = ForceField.ForceType.INVERSE_SQUARE
	field.required_traits = affected_traits
	
	var collision = CollisionShape2D.new()
	var shape = CircleShape2D.new()
	shape.radius = radius
	collision.shape = shape
	field.add_child(collision)
	
	return field


## Create a vortex field
static func _create_vortex_field(
	position: Vector2,
	radius: float,
	strength: float,
	clockwise: bool,
	inward_pull: float
) -> ForceField:
	var field = ForceField.new()
	field.global_position = position
	field.force_magnitude = strength
	field.direction_type = ForceField.DirectionType.VORTEX
	field.vortex_clockwise = clockwise
	field.vortex_inward_pull = inward_pull
	field.force_type = ForceField.ForceType.LINEAR_FALLOFF
	
	var collision = CollisionShape2D.new()
	var shape = CircleShape2D.new()
	shape.radius = radius
	collision.shape = shape
	field.add_child(collision)
	
	return field


## Create a wind field
static func _create_wind_field(
	position: Vector2,
	radius: float,
	strength: float,
	direction: Vector2,
	affected_traits: Array[String]
) -> ForceField:
	var field = ForceField.new()
	field.global_position = position
	field.force_magnitude = strength
	field.direction_type = ForceField.DirectionType.FIXED_DIRECTION
	field.fixed_direction = direction.normalized()
	field.force_type = ForceField.ForceType.CONSTANT
	field.required_traits = affected_traits
	
	var collision = CollisionShape2D.new()
	var shape = CircleShape2D.new()
	shape.radius = radius
	collision.shape = shape
	field.add_child(collision)
	
	return field


## Create a generic configurable field
static func _create_generic_field(
	position: Vector2,
	radius: float,
	strength: float,
	affected_traits: Array[String],
	effect: Dictionary
) -> ForceField:
	var field = ForceField.new()
	field.global_position = position
	field.force_magnitude = strength
	field.required_traits = affected_traits
	
	# Parse direction type
	var dir_type = effect.get("direction_type", "toward_center")
	match dir_type:
		"toward_center":
			field.direction_type = ForceField.DirectionType.TOWARD_CENTER
		"away_from_center":
			field.direction_type = ForceField.DirectionType.AWAY_FROM_CENTER
		"fixed":
			field.direction_type = ForceField.DirectionType.FIXED_DIRECTION
			field.fixed_direction = Vector2(
				effect.get("direction_x", 0),
				effect.get("direction_y", 1)
			)
		"vortex":
			field.direction_type = ForceField.DirectionType.VORTEX
	
	# Parse force type
	var force_type_str = effect.get("force_type", "constant")
	match force_type_str:
		"constant":
			field.force_type = ForceField.ForceType.CONSTANT
		"linear":
			field.force_type = ForceField.ForceType.LINEAR_FALLOFF
		"inverse_square":
			field.force_type = ForceField.ForceType.INVERSE_SQUARE
	
	var collision = CollisionShape2D.new()
	var shape = CircleShape2D.new()
	shape.radius = radius
	collision.shape = shape
	field.add_child(collision)
	
	return field


# --- Knockback: shared between resolution and the targeting preview ----------
# The planning UI draws where each target will LAND, so the impulse maths has to
# have exactly one definition. If the preview re-derived it, the first tune of
# `strength` semantics would silently make every ghost a lie.

## Impulse window converting a JSON `strength` (px/s² of impulse) into a velocity
## change: ~0.25 × strength. At strength=800 that's ~200 px/s, decaying to zero
## under ProceduralCharacter.knockback_friction=150 for ~130 px of displacement.
const KNOCKBACK_IMPULSE_DURATION := 0.25

## Point a knockback radiates from — the caster for `from_caster`, else the AoE centre.
static func knockback_origin(effect: Dictionary, caster_position: Vector2, target_position: Vector2) -> Vector2:
	return caster_position if effect.get("from_caster", true) else target_position

## The impulse one target receives. Returns ZERO for a target standing exactly on
## the origin — normalized() has no direction to give there, so it doesn't move.
static func knockback_force(effect: Dictionary, origin: Vector2, target_position: Vector2) -> Vector2:
	var strength: float = float(effect.get("strength", 500.0))
	return (target_position - origin).normalized() * strength

## Resolve knockback effect
static func _resolve_knockback(
	effect: Dictionary,
	caster: Node,
	targets: Array,
	target_position: Vector2
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "knockback",
		"targets_affected": [],
	}

	var origin := knockback_origin(effect, caster.global_position, target_position)

	for target in targets:
		if not is_instance_valid(target):
			continue

		if not target is Node2D:
			continue

		var force := knockback_force(effect, origin, target.global_position)

		# CharacterBody2D characters expose apply_external_force (defined on
		# ProceduralCharacter) which integrates the force into knockback
		# velocity. RigidBody2D targets receive a direct impulse.
		if target.has_method("apply_external_force"):
			target.apply_external_force(force, KNOCKBACK_IMPULSE_DURATION)
			# Being knocked back breaks a windup. Hooked here, not in
			# apply_external_force, which force fields call every frame.
			if force != Vector2.ZERO and target.has_method("interrupt_cast"):
				target.interrupt_cast("knocked back")
		elif target is RigidBody2D:
			target.apply_central_impulse(force)

		result["targets_affected"].append({
			"target": target,
			"force": force
		})

	return result

## Resolve teleport effect
static func _resolve_teleport(
	effect: Dictionary,
	caster: Node,
	targets: Array,
	target_position: Vector2
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "teleport",
		"targets_affected": [],
	}
	
	var teleport_to = effect.get("to", "position")  # "position", "caster", "swap"
	
	for target in targets:
		if not is_instance_valid(target):
			continue
		
		if not target is Node2D:
			continue
		
		var old_position = target.global_position
		
		match teleport_to:
			"position":
				target.global_position = target_position
			"caster":
				target.global_position = caster.global_position
			"swap":
				target.global_position = caster.global_position
				caster.global_position = old_position
		
		result["targets_affected"].append({
			"target": target,
			"from": old_position,
			"to": target.global_position
		})
	
	return result


## Resolve custom effect
static func _resolve_custom(
	effect: Dictionary,
	caster: Node,
	targets: Array,
	ability: Ability,
	target_position: Vector2
) -> Dictionary:
	var result = {
		"success": true,
		"effect_type": "custom",
		"custom_type": effect.get("custom_type", ""),
	}
	
	# Custom effects can specify a method to call on caster
	var method_name = effect.get("method", "")
	if method_name != "" and caster.has_method(method_name):
		var custom_result = caster.call(method_name, effect, targets, ability, target_position)
		if custom_result is Dictionary:
			result.merge(custom_result, true)
	
	return result


## Helper: Get entity traits
static func _get_entity_traits(entity: Node) -> Dictionary:
	# AoE sweeps pick up bare wall colliders (StaticBody2D with no script) --
	# anything without a traits Dictionary reads as traitless, not a crash.
	if "traits" in entity and entity.traits is Dictionary:
		return entity.traits
	return {}


## Helper: Get condition manager
static func _get_condition_manager(entity: Node):
	if entity.has_node("ConditionManager"):
		return entity.get_node("ConditionManager")
	if entity.has_method("get_condition_manager"):
		return entity.get_condition_manager()
	if "condition_manager" in entity:
		return entity.condition_manager
	return null
