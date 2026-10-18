# ConditionManager.gd
# Component that manages all conditions on a character
# Attach this to your character node or add as a child
class_name ConditionManager
extends Node

## Reference to the TimeManager autoload
@export var time_manager_path: NodePath = "/root/TimeManager"
var time_manager: Node

## Reference to the character this manager belongs to
@export var character_path: NodePath = ".."
var character: Node

## All active condition instances, keyed by condition ID
## For stackable conditions, this holds the single instance with stack count
## For non-stackable, this is the instance itself
var conditions: Dictionary = {}  # condition_id -> ConditionInstance

## Last game_time a periodic save was rolled, keyed by condition_id.
## Only populated for conditions with save_stat != "" and save_interval > 0.
var last_save_times: Dictionary = {}  # condition_id -> float

## Last real time (msec) a resist/immune notice was shown, keyed by
## "condition_id:text". Fogs and fields re-apply on a timer, so repeats are
## throttled.
var _last_notice_ms: Dictionary = {}  # "condition_id:text" -> int
const NOTICE_REPEAT_MS := 2000
## A field, fog or cloud (any source that is not a character) re-applies on its
## own clock: fogs every second, CompulsionField every 3 s pulse. Its repeats
## wait longer, so a bystander who keeps resisting doesn't float "Resisted"
## on every pulse.
const AREA_NOTICE_REPEAT_MS := 8000
const RESIST_COLOR := Color(0.6, 0.85, 1.0)
const WORSEN_COLOR := Color(1.0, 0.45, 0.35)

## True only while triggered_effect_fired is being emitted, i.e. during a
## condition's own tick (Burning's fire, Poisoned's poison...).
var firing_triggered_effect: bool = false

## --- canceled_by_trait (cancel_by_traits is the one entry point) ---------
## Anything carrying trait X ends the conditions whose canceled_by_trait lists
## X: an ability landing (its traits), damage actually dealt (its type), a
## condition arriving (its traits), the fluid underfoot, a consumable.
## A condition a worn or drawn item grants (the Shadow Cloak's Invisible,
## Winter's Grip) is suppressed for this long instead, then the still-worn
## item restores it.
const CANCEL_SUPPRESS_SECONDS := 10.0
## ConditionInstance.custom_data keys of a windowed suppression
## (suppress_for): the absolute time it ends, and what caused it. custom_data
## is serialized, so a window survives a warp.
const SUPPRESSED_UNTIL_KEY := "suppressed_until"
const SUPPRESSED_CAUSE_KEY := "suppressed_cause"
## Traits the bearer stands in right now (ward_by_traits: the fluid
## underfoot), trait -> {"until_ms", "cause"}. While one holds, a condition it
## cancels can't land at all: water would otherwise put out a Fire Spin's
## Stuck in Fire a frame after every re-application, and each fresh instance
## ticks at once. Refreshed every frame by its source, so a short real-time
## hold.
var _ambient_traits: Dictionary = {}
const AMBIENT_TRAIT_MS := 250

## Registry of all known condition templates
## Should be populated from your data files
static var condition_registry: Dictionary = {}  # condition_id -> Condition

## Signals
signal condition_applied(instance: ConditionInstance)
signal condition_removed(instance: ConditionInstance)
signal condition_suppressed(instance: ConditionInstance)
signal condition_unsuppressed(instance: ConditionInstance)
signal condition_expired(instance: ConditionInstance)
signal condition_stacks_changed(instance: ConditionInstance, old_stacks: int, new_stacks: int)
signal triggered_effect_fired(instance: ConditionInstance, effect: Dictionary, result: Dictionary)
signal stats_recalculated()


func _ready() -> void:
	# Get TimeManager reference
	if has_node(time_manager_path):
		time_manager = get_node(time_manager_path)
	else:
		time_manager = get_node_or_null("/root/TimeManager")
	
	if not time_manager:
		push_warning("ConditionManager: TimeManager not found!")
	
	# Get character reference
	if has_node(character_path):
		character = get_node(character_path)


func _process(delta: float) -> void:
	if not time_manager:
		return
	# Corpses don't roll saves or tick. take_damage already ignores the dead,
	# but periodic saves kept rolling and would log "shakes off" for a corpse.
	if character and character.has_method("is_alive") and not character.is_alive():
		return

	# absolute_time, not game_time: game_time wraps to [0, 86400) at midnight,
	# which made any expiry beyond the current day unreachable and broke the
	# periodic-save interval across day boundaries.
	var current_time: float = time_manager.absolute_time()
	var expired_conditions: Array[String] = []
	var saved_off_conditions: Array[String] = []
	var suppression_over: Array[String] = []

	# Check for expirations and process triggered effects. Over a snapshot of
	# the ids: a tick can end other conditions (fire damage thaws Chilled), and
	# erasing the entry being visited stops a live Dictionary loop early.
	for condition_id in conditions.keys():
		var instance: ConditionInstance = conditions.get(condition_id)
		if instance == null:
			continue
		# A tick that killed the bearer ends the frame: corpses don't tick,
		# roll saves or drop blood, here as at the top of _process.
		if _bearer_dead():
			break

		# Check expiration
		if instance.is_expired(current_time):
			expired_conditions.append(condition_id)
			continue

		# A windowed suppression (suppress_for) that has run out.
		if instance.is_suppressed and instance.custom_data.has(SUPPRESSED_UNTIL_KEY) \
				and current_time >= float(instance.custom_data[SUPPRESSED_UNTIL_KEY]):
			suppression_over.append(condition_id)

		# Process triggered effects if active
		if instance.is_active():
			_process_triggered_effects(instance, current_time)

		# --- Periodic save: re-roll while the condition is on the bearer ---
		if _try_periodic_save(instance, current_time):
			# saving_throw drove stacks to 0; collect for post-loop removal so
			# we don't mutate the dictionary we're iterating.
			saved_off_conditions.append(condition_id)

	# Remove expired conditions
	for condition_id in expired_conditions:
		var instance = conditions.get(condition_id)
		if instance == null:
			continue
		_remove_condition_internal(condition_id)
		condition_expired.emit(instance)

	for condition_id in suppression_over:
		_end_timed_suppression(condition_id)

	# Remove conditions fully saved off this frame
	for condition_id in saved_off_conditions:
		var instance = conditions.get(condition_id)
		if instance:
			_remove_condition_internal(condition_id)
			condition_removed.emit(instance)


## Roll a tick save for `instance` if it's due. Returns true iff the save
## reduced stacks to 0 (caller is responsible for removing the condition).
func _try_periodic_save(instance: ConditionInstance, current_time: float) -> bool:
	var template := instance.condition
	if not template or template.save_stat == "" or template.save_interval <= 0.0:
		return false
	if not character or not character.has_method("saving_throw"):
		return false
	# The same frame's tick may just have killed the bearer.
	if _bearer_dead():
		return false

	var cond_id := template.id
	var last := float(last_save_times.get(cond_id, current_time))
	if current_time - last < template.save_interval:
		return false
	last_save_times[cond_id] = current_time

	var delta: int = character.saving_throw(template.save_stat)
	if delta == 0:
		return false

	var old_stacks := instance.stacks
	# Hidden NPCs stay quiet; the log is for saves the party is part of.
	var cond_name := _condition_name(template)
	var shown := _bearer_noticeable()
	var log_it := shown and _player_involved(instance.source)
	if delta > 0:
		instance.add_stacks(delta)
		condition_stacks_changed.emit(instance, old_stacks, instance.stacks)
		if log_it and instance.stacks > old_stacks:
			GameLog.add_entry("%s's %s worsens to %s%s." % [_bearer_name(), cond_name, _stacks_text(instance.stacks), _save_detail(template.save_stat)])
	else:
		# delta is negative; remove_stacks expects a positive amount.
		instance.remove_stacks(-delta)
		condition_stacks_changed.emit(instance, old_stacks, instance.stacks)
		if instance.stacks <= 0:
			if shown and character.has_method("notify"):
				character.notify("Shook off " + cond_name, RESIST_COLOR)
			if log_it:
				GameLog.add_entry("%s shakes off %s%s." % [_bearer_name(), cond_name, _save_detail(template.save_stat)])
			return true
		if log_it:
			GameLog.add_entry("%s's %s eases to %s%s." % [_bearer_name(), cond_name, _stacks_text(instance.stacks), _save_detail(template.save_stat)])
	return false


func _process_triggered_effects(instance: ConditionInstance, current_time: float) -> void:
	var condition = instance.condition
	if not condition:
		return
	
	for i in range(condition.triggered_effects.size()):
		# Bleeding's damage tick can kill; its blood puddle mustn't follow.
		if _bearer_dead():
			break
		var effect = condition.triggered_effects[i]
		var interval = effect.get("interval", 1.0)
		var last_time = instance.last_trigger_times.get(i, -INF)
		
		if current_time - last_time >= interval:
			instance.last_trigger_times[i] = current_time
			var result = _execute_triggered_effect(instance, effect)
			# Listeners (the bearer's damage tick) can tell a condition's own
			# tick from a fresh hit: ticks don't interrupt casts or count as
			# a sighting of whoever applied the condition.
			firing_triggered_effect = true
			triggered_effect_fired.emit(instance, effect, result)
			firing_triggered_effect = false


func _execute_triggered_effect(instance: ConditionInstance, effect: Dictionary) -> Dictionary:
	var result: Dictionary = {"success": true}
	var effect_type = effect.get("type", "")
	var base_value = effect.get("value", 0) * instance.stacks
	
	match effect_type:
		"damage":
			result["damage"] = base_value
			result["damage_type"] = effect.get("damage_type", "true")
			# Character should listen for triggered_effect_fired and apply damage
		"heal":
			result["heal"] = base_value
		"stress":
			result["stress"] = base_value
		"stat_change":
			result["stat"] = effect.get("stat", "")
			result["change"] = base_value
		"apply_condition":
			result["condition_id"] = effect.get("condition_id", "")
			result["chance"] = effect.get("chance", 1.0)
		"remove_condition":
			result["condition_id"] = effect.get("condition_id", "")
		"sever_limb":
			# Removes a limb from the bearer. The character handler reads
			# instance.target_limb (the limb this condition is pinned to) and
			# falls back to a random non-lethal limb if unset.
			result["sever_limb"] = true
		"custom":
			result["custom_type"] = effect.get("custom_type", "")
			result["custom_data"] = effect.get("custom_data", {})
	
	return result


## Register a condition template
static func register_condition(condition: Condition) -> void:
	condition_registry[condition.id] = condition


## Register multiple conditions from an array
static func register_conditions(conditions_array: Array) -> void:
	for cond in conditions_array:
		if cond is Condition:
			register_condition(cond)
		elif cond is Dictionary:
			register_condition(Condition.create_from_data(cond))


## Apply a condition to this character
# Update apply_condition signature and the instance creation:
func apply_condition(
	condition_id: String,
	source: Node = null,
	stacks: int = 1,
	duration_override: float = -2.0,
	target_limb = null
) -> ConditionInstance:
	var template = condition_registry.get(condition_id)
	if not template:
		push_warning("Unknown condition: %s" % condition_id)
		return null
	# Corpses take no new conditions. A killing blow's rider (Fireball's
	# Burning, Ice Storm's Chilled, a bite's Bleeding) lands after the damage,
	# once _enter_corpse_state has already stripped condition VFX, and _process
	# skips corpses, so it would never expire and its flames would play on the
	# tombstone for good. Saved corpse conditions come back through from_dict.
	if character and character.has_method("is_alive") and not character.is_alive():
		return null

	# Feedback below is only for applications with a source (abilities, attacks,
	# fogs, fields). Surfaces, fire and every slashing hit's Bleeding pass null
	# and would spam.
	var immune_by: ConditionInstance = _get_immunity_source(template)
	if immune_by:
		if source != null:
			_announce_resist(condition_id, "Immune", "%s is immune to %s (%s)." % [_bearer_name(), _condition_name(template), _condition_name(immune_by.condition)], source)
		return null
	# Standing in something that cancels it (water and Burning): it can't land.
	var ward: Dictionary = _ambient_ward_for(template)
	if not ward.is_empty():
		if source != null:
			_announce_resist(condition_id, "Protected", "%s is protected from %s (%s)." % [_bearer_name(), _condition_name(template), _trait_detail(ward["trait"], ward["cause"])], source)
		return null

	# --- Saving throw (apply-time) ---
	# If the condition has a save_stat, the bearer rolls once when it lands.
	# Negative delta reduces incoming stacks (and aborts entirely if it reaches 0);
	# positive delta (crit fail) adds a stack. See ProceduralCharacter.saving_throw.
	if template.save_stat != "" and character and character.has_method("saving_throw"):
		var fear_bonus: int = int(calculate_effective_stat(0.0, "fear_save")) if int(template.traits.get("fear", 0)) > 0 else 0
		var save_delta: int = character.saving_throw(template.save_stat, fear_bonus)
		stacks += save_delta
		if stacks <= 0:
			if source != null:
				_announce_resist(condition_id, "Resisted", "%s resists %s%s." % [_bearer_name(), _condition_name(template), _save_detail(template.save_stat)], source)
			return null
		if source != null and save_delta < 0:
			_announce_resist(condition_id, "", "%s partly resists %s%s." % [_bearer_name(), _condition_name(template), _save_detail(template.save_stat)], source)
		elif source != null and save_delta > 0 and template.stackable:
			# Only stackables gain the extra stack; a non-stackable just lands as normal.
			_announce_resist(condition_id, "Critical fail", "%s critically fails against %s%s." % [_bearer_name(), _condition_name(template), _save_detail(template.save_stat)], source, WORSEN_COLOR)

	# canceled_by_trait: a condition arriving with trait X first ends what X
	# cancels on the bearer (Chilled puts out Burning, Burning thaws Chilled,
	# Courageous ends Frightened), then lands.
	if not conditions.is_empty():
		cancel_by_traits(template.traits, _condition_name(template), source, condition_id)

	var current_time: float = time_manager.absolute_time() if time_manager else 0.0
	var existing = conditions.get(condition_id)
	
	# --- Trait-based duration scaling handled internally ---
	# The bearer's own MODIFY_DURATION_BY_TRAIT: empty (neutral) unless its
	# character data gives entries (round 5 dropped the universal defaults).
	var final_duration = duration_override
	if duration_override <= -2.0 and template.duration > 0:
		final_duration = template.duration
		if character and "MODIFY_DURATION_BY_TRAIT" in character:
			for trait_key in template.traits:
				if trait_key in character.MODIFY_DURATION_BY_TRAIT:
					final_duration *= character.MODIFY_DURATION_BY_TRAIT[trait_key]
	
	if existing:
		if template.stackable:
			var old_stacks = existing.stacks
			var added = existing.add_stacks(stacks)
			# Before the transform below, which replaces the instance anyway.
			_refresh_stackable_expiry(existing, final_duration, current_time)
			if added > 0:
				condition_stacks_changed.emit(existing, old_stacks, existing.stacks)
				stats_recalculated.emit()
				return _check_transform(existing)
			# At the cap already: an instance that sits at its transform tier
			# without having turned (a save from before Poisoned turned at 4,
			# or the target was warded off then) turns now.
			return _check_transform(existing)
		else:
			# Never shorten a PERMANENT instance (equip-granted, expires_at < 0)
			# from a default-duration re-apply — a cloak's while-worn
			# invisibility must not become 30s because something re-applied the
			# condition. Only an EXPLICIT duration_override may change it.
			if existing.expires_at < 0 and duration_override <= -2.0:
				return existing
			if final_duration > -2.0:
				existing.expires_at = current_time + final_duration if final_duration > 0 else -1.0
			elif template.duration > 0:
				existing.expires_at = current_time + template.duration
			return existing
			
	# Create new instance
	var instance = ConditionInstance.new(template, source, target_limb)
	instance.stacks = min(stacks, template.max_tier) if template.stackable else 1

	# apply() stamps applied_at and the TEMPLATE expiry — it must run BEFORE
	# the override, which used to sit above it and be silently clobbered
	# (fog_overlay's condition_duration_override and the condition-copy
	# effect's duration never took effect on fresh instances).
	instance.apply(current_time)
	if final_duration > -2.0:
		instance.expires_at = current_time + final_duration if final_duration > 0.0 else -1.0

	# Triggered effects marked "delay_first" wait one full interval before
	# their first firing. The -INF seed (fire on the first frame) is right for
	# DoT ticks, but wrong for delayed-onset triggers like Winter's Grip's
	# 18-second frostbite.
	for i in range(template.triggered_effects.size()):
		if template.triggered_effects[i] is Dictionary and template.triggered_effects[i].get("delay_first", false):
			instance.last_trigger_times[i] = current_time

	conditions[condition_id] = instance

	# A condition with immunities EVICTS matching active conditions on arrival
	# (exact id match): illuminated landing strips an EXISTING 'invisible',
	# not just future applications. Trait-style immunity keys ("cold") match
	# no condition id and are unaffected.
	for immune_id in template.immunities:
		if immune_id != condition_id and conditions.has(immune_id):
			remove_condition(immune_id)

	if template.save_stat != "" and template.save_interval > 0.0:
		last_save_times[condition_id] = current_time

	# Grant any ability this condition bestows (e.g. The Jaws That Bite → natural_bite).
	# Done on first application only; we don't re-grant when stacks merely change.
	if template.grants_ability != "" and character:
		var inv = character.get_node_or_null("Inventory")
		if inv and inv.has_method("add_ability_by_id"):
			inv.add_ability_by_id(template.grants_ability)

	condition_applied.emit(instance)
	stats_recalculated.emit()

	return _check_transform(instance)


## A stackable condition lasts until its LAST application wears off. An
## application landing on a timed instance, whether it adds stacks or finds it
## at max tier, moves the expiry to now + that application's duration when
## that is later: Burning hit again 4 s in keeps burning 6 s from the new hit,
## not from the first, and back-to-back Force Marches keep Exhausted 24 h from
## the last one. Every stack shares the one expiry. A permanent instance stays
## permanent; a permanent application (a worn item's, an explicit -1 or 0)
## makes it permanent, as the non-stackable branch does. `final_duration` is
## apply_condition's: -2 or less means "the template's", which is permanent.
func _refresh_stackable_expiry(existing: ConditionInstance, final_duration: float, now: float) -> void:
	if existing.expires_at < 0.0 or final_duration <= -2.0:
		return
	if final_duration <= 0.0:
		existing.expires_at = -1.0
		return
	existing.expires_at = maxf(existing.expires_at, now + final_duration)


## When a stackable condition reaches its transforms_into tier (Chilled 3 ->
## Frozen, Fatigued 3 -> Exhausted, Poisoned 4 -> Toxic Shock), replace it
## with that condition. Targets that aren't registered are skipped. Returns
## the instance now on the bearer. The bearer's float names the new condition
## ("Toxic Shock!"); the log says what turned and why ("Ada's Poisoned
## reaches 4 stacks: Toxic Shock.").
func _check_transform(instance: ConditionInstance) -> ConditionInstance:
	var tf: Dictionary = instance.condition.transforms_into
	var into_id := str(tf.get("id", ""))
	if into_id == "" or not condition_registry.has(into_id):
		return instance
	if instance.stacks < int(tf.get("required_tier", 999)):
		return instance
	if _get_immunity_source(condition_registry[into_id]):
		return instance

	# The original applier may have died since; a freed source can't be passed on.
	var src: Node = instance.source if is_instance_valid(instance.source) else null
	remove_condition(instance.condition.id)
	var out := apply_condition(into_id, src)
	if out and _bearer_noticeable():
		if character.has_method("notify"):
			character.notify(_condition_name(out.condition) + "!", WORSEN_COLOR)
		if _player_involved(src):
			# "Ada's Chilled reaches 3 stacks: Frozen." Reads for a state
			# (Frozen) and a noun (Toxic Shock) alike; "is now Toxic Shock" didn't.
			GameLog.add_entry("%s's %s reaches %s: %s." % [_bearer_name(), _condition_name(instance.condition), _stacks_text(instance.stacks), _condition_name(out.condition)])
	return out


## Remove a condition completely
func remove_condition(condition_id: String) -> bool:
	if condition_id not in conditions:
		return false
	
	var instance = conditions[condition_id]
	_remove_condition_internal(condition_id)
	condition_removed.emit(instance)
	return true


func _remove_condition_internal(condition_id: String) -> void:
	conditions.erase(condition_id)
	last_save_times.erase(condition_id)
	stats_recalculated.emit()


## Remove stacks from a condition (removes condition if stacks reach 0)
func remove_stacks(condition_id: String, amount: int) -> int:
	var instance = conditions.get(condition_id)
	if not instance:
		return 0
	
	var old_stacks = instance.stacks
	var removed = instance.remove_stacks(amount)
	
	if removed > 0:
		condition_stacks_changed.emit(instance, old_stacks, instance.stacks)
		
		if instance.stacks <= 0:
			remove_condition(condition_id)
		else:
			stats_recalculated.emit()
	
	return removed


## Suppress a condition (effects don't apply but condition persists)
func suppress_condition(condition_id: String) -> bool:
	var instance = conditions.get(condition_id)
	if not instance or instance.is_suppressed:
		return false
	
	instance.suppress()
	condition_suppressed.emit(instance)
	stats_recalculated.emit()
	return true


## Unsuppress a condition
func unsuppress_condition(condition_id: String) -> bool:
	var instance = conditions.get(condition_id)
	if not instance or not instance.is_suppressed:
		return false
	
	# Lifting it by hand also ends a suppress_for window.
	instance.custom_data.erase(SUPPRESSED_UNTIL_KEY)
	instance.custom_data.erase(SUPPRESSED_CAUSE_KEY)
	instance.unsuppress()
	condition_unsuppressed.emit(instance)
	stats_recalculated.emit()
	return true


## Suppress `condition_id` for `seconds` on the condition clock; _process
## lifts it again when the window ends (_end_timed_suppression). Asked again
## while the window runs, it stretches the window. Built on suppress_condition,
## so the suppressed signal, the stats and the AI (has_active_condition) all
## see it. `cause` is kept for the record. True when it newly suppressed it.
func suppress_for(condition_id: String, seconds: float, cause: String = "") -> bool:
	var instance: ConditionInstance = conditions.get(condition_id)
	if instance == null or seconds <= 0.0:
		return false
	var until: float = _clock_now() + seconds
	if instance.is_suppressed:
		# Already down in a window: stretch it. A suppression without one
		# (someone else's, open-ended) is left alone.
		if instance.custom_data.has(SUPPRESSED_UNTIL_KEY):
			instance.custom_data[SUPPRESSED_UNTIL_KEY] = maxf(float(instance.custom_data[SUPPRESSED_UNTIL_KEY]), until)
		return false
	instance.custom_data[SUPPRESSED_UNTIL_KEY] = until
	instance.custom_data[SUPPRESSED_CAUSE_KEY] = cause
	return suppress_condition(condition_id)


## Seconds left on a suppress_for window (0 when there is none).
func suppression_time_left(condition_id: String) -> float:
	var instance: ConditionInstance = conditions.get(condition_id)
	if instance == null or not instance.is_suppressed or not instance.custom_data.has(SUPPRESSED_UNTIL_KEY):
		return 0.0
	return maxf(0.0, float(instance.custom_data[SUPPRESSED_UNTIL_KEY]) - _clock_now())


## A suppress_for window ran out: the condition is back, and the bearer's log
## says so, naming the worn or drawn item that holds it ("Aldric's Invisible
## returns (Shadow Cloak).").
func _end_timed_suppression(condition_id: String) -> void:
	var instance: ConditionInstance = conditions.get(condition_id)
	if instance == null or not instance.is_suppressed:
		return
	# A tick earlier in the same frame may have killed the bearer: nothing
	# "returns" on a corpse.
	if _bearer_dead():
		return
	# A delayed-onset trigger waits its full interval again: Winter's Grip's
	# frostbite comes 18 s after the cold returns, not the moment it does.
	var now: float = _clock_now()
	var tmpl: Condition = instance.condition
	for i in range(tmpl.triggered_effects.size()):
		if tmpl.triggered_effects[i] is Dictionary and tmpl.triggered_effects[i].get("delay_first", false):
			instance.last_trigger_times[i] = now
	unsuppress_condition(condition_id)
	if not _bearer_noticeable():
		return
	var cond_name := _condition_name(tmpl)
	var item: String = str(character.equip_source_name(condition_id)) if character.has_method("equip_source_name") else ""
	var log_text := ""
	if _player_involved(null):
		log_text = "%s's %s returns%s." % [_bearer_name(), cond_name, (" (%s)" % item) if item != "" and item != cond_name else ""]
	if character.has_method("notify"):
		character.notify(cond_name + " returns", RESIST_COLOR, log_text)
	elif log_text != "":
		GameLog.add_entry(log_text)


## canceled_by_trait, the one entry point. Every condition on the bearer whose
## canceled_by_trait lists one of `traits_in` (trait names, or a traits
## Dictionary whose zero tiers don't count; case doesn't matter) ends. One a
## worn or drawn item grants is suppressed for CANCEL_SUPPRESS_SECONDS instead
## (suppress_for), and the still-held item has it back after. Each is
## announced on the bearer: "Burning put out" and "Aldric's Burning is put out
## (water: Splash)." `cause_label` is what carried the trait (an ability, an
## item, a condition, a fluid), `source` the character behind it, if any (it
## decides the log line and the repeat window), and `exclude_id` is spared
## (the condition being applied). Returns what it ended or suppressed:
## [{condition_id, name, trait, suppressed}].
func cancel_by_traits(traits_in, cause_label: String = "", source = null, exclude_id: String = "") -> Array:
	var out: Array = []
	if conditions.is_empty() or _bearer_dead():
		return out
	var carried: Array = _trait_names(traits_in)
	if carried.is_empty():
		return out
	for cid in conditions.keys():
		if cid == exclude_id:
			continue
		var instance: ConditionInstance = conditions.get(cid)
		if instance == null or instance.condition == null:
			continue
		var hit: String = _canceling_trait(instance.condition, carried)
		if hit == "":
			continue
		var suppressed := _is_equip_granted(cid)
		if suppressed:
			# Already held down: the window stretches, nothing new to say.
			if not suppress_for(cid, CANCEL_SUPPRESS_SECONDS, cause_label):
				continue
		else:
			remove_condition(cid)
		out.append({"condition_id": cid, "name": _condition_name(instance.condition), "trait": hit, "suppressed": suppressed})
		_announce_cancel(instance, hit, cause_label, source, suppressed)
	return out


## cancel_by_traits for a single trait (a damage type, "water").
func cancel_by_trait(trait_name: String, cause_label: String = "", source = null) -> Array:
	return cancel_by_traits([trait_name], cause_label, source)


## The bearer stands in something carrying `traits_in` (the fluid underfoot,
## refreshed every frame): cancel_by_traits now, and for AMBIENT_TRAIT_MS the
## conditions those traits cancel can't land (apply_condition refuses them).
func ward_by_traits(traits_in, cause_label: String = "") -> Array:
	var until: int = Time.get_ticks_msec() + AMBIENT_TRAIT_MS
	for t in _trait_names(traits_in):
		_ambient_traits[t] = {"until_ms": until, "cause": cause_label if cause_label != "" else t}
	return cancel_by_traits(traits_in, cause_label, null)


## {trait, cause} of a ward_by_traits trait still underfoot that cancels
## `template`, or {} when none does.
func _ambient_ward_for(template: Condition) -> Dictionary:
	if _ambient_traits.is_empty() or template.canceled_by_trait.is_empty():
		return {}
	var now: int = Time.get_ticks_msec()
	for t in _ambient_traits.keys():
		var w: Dictionary = _ambient_traits[t]
		if now > int(w["until_ms"]):
			_ambient_traits.erase(t)
			continue
		if _canceling_trait(template, [t]) != "":
			return {"trait": t, "cause": str(w["cause"])}
	return {}


## Lower-case trait names from an Array, a single String or a traits
## Dictionary (tier <= 0 skipped: a trait at tier 0 isn't carried).
static func _trait_names(traits_in) -> Array:
	var out: Array = []
	var pairs: Array = []
	if traits_in is Dictionary:
		for k in traits_in:
			var v = traits_in[k]
			if (v is int or v is float) and float(v) <= 0.0:
				continue
			pairs.append(k)
	elif traits_in is Array or traits_in is PackedStringArray:
		pairs = Array(traits_in)
	elif traits_in is String or traits_in is StringName:
		pairs = [traits_in]
	for k in pairs:
		var key := str(k).strip_edges().to_lower()
		if key != "" and not key in out:
			out.append(key)
	return out


## The first of `template`'s canceled_by_trait entries in `carried`, or "".
static func _canceling_trait(template: Condition, carried: Array) -> String:
	for t in template.canceled_by_trait:
		var key := str(t).to_lower()
		if key in carried:
			return key
	return ""


## True when a worn item or a drawn weapon holds `condition_id` on the bearer
## (ProceduralCharacter.is_condition_equip_granted).
func _is_equip_granted(condition_id: String) -> bool:
	return character != null and is_instance_valid(character) \
		and character.has_method("is_condition_equip_granted") and character.is_condition_equip_granted(condition_id)


## Float and log one cancellation (cancel_by_traits). Over a bearer the party
## can notice only; the log line when the party is involved. Repeats of the
## same condition and trait wait out the resist notices' windows (a source
## that isn't a character, such as a fluid, waits the longer one).
func _announce_cancel(instance: ConditionInstance, trait_name: String, cause_label: String, source, suppressed: bool) -> void:
	if not _bearer_noticeable():
		return
	var tmpl: Condition = instance.condition
	var key := tmpl.id + ":cancel:" + trait_name
	var now := Time.get_ticks_msec()
	var window: int = NOTICE_REPEAT_MS if is_instance_valid(source) and source is ProceduralCharacter else AREA_NOTICE_REPEAT_MS
	if _last_notice_ms.has(key) and now - int(_last_notice_ms[key]) < window:
		return
	_last_notice_ms[key] = now
	var cond_name := _condition_name(tmpl)
	var detail := _trait_detail(trait_name, cause_label)
	var text := cond_name + " ended"
	var phrase := "ends"
	if suppressed:
		text = cond_name + " suppressed"
		phrase = "is suppressed for %d s" % int(round(CANCEL_SUPPRESS_SECONDS))
	elif tmpl.traits.has("fire") and trait_name in ["water", "cold"]:
		text = cond_name + " put out"
		phrase = "is put out"
	elif tmpl.traits.has("cold") and trait_name in ["fire", "heat"]:
		text = cond_name + " thawed"
		phrase = "thaws"
	var log_text := ""
	if _player_involved(source):
		log_text = "%s's %s %s (%s)." % [_bearer_name(), cond_name, phrase, detail]
		if suppressed and character.has_method("equip_source_name"):
			var item := str(character.equip_source_name(tmpl.id))
			# Winter's Grip's condition shares the blade's name: "the Winter's
			# Grip brings it back" would read as the condition restoring itself.
			if item != "" and item != cond_name:
				log_text = log_text.trim_suffix(".") + "; %s brings it back after." % item
			elif item != "":
				log_text = log_text.trim_suffix(".") + "; it comes back after."
	# A lost buff or a suppressed item reads as bad news, an ended debuff as good.
	var color: Color = WORSEN_COLOR if suppressed or tmpl.traits.has("buff") else RESIST_COLOR
	if character.has_method("notify"):
		character.notify(text, color, log_text)
	elif log_text != "":
		GameLog.add_entry(log_text)


## "water" or "fire: Fireball": the trait, and what carried it when that
## says more than the trait itself (the Water fluid is just "water").
static func _trait_detail(trait_name: String, cause_label: String) -> String:
	if cause_label == "" or cause_label.to_lower() == trait_name:
		return trait_name
	return "%s: %s" % [trait_name, cause_label]


func _clock_now() -> float:
	return time_manager.absolute_time() if time_manager else 0.0


## True when the bearer is a character that has died.
func _bearer_dead() -> bool:
	return character != null and is_instance_valid(character) and character.has_method("is_alive") and not character.is_alive()


## Return the active condition that makes the character immune to `template`,
## or null. Immunity keys may be condition ids ("sickened") or traits ("cold",
## "slow"), so Hasted blocks Slowed and Chilled, and Shielded blocks Burning.
## A trait key only wards off debuffs: Shielded's "cold" stops Chilled, not
## Winter's Grip, the drawn blade's own (cold-flavoured) item condition.
func _get_immunity_source(template: Condition) -> ConditionInstance:
	var harmful: bool = template.traits.has("debuff")
	for cond_id in conditions:
		var instance: ConditionInstance = conditions[cond_id]
		# A condition never blocks itself (Frozen has the "cold" trait it is
		# immune to); re-applying it refreshes it instead.
		if not instance.is_active() or instance.condition.id == template.id:
			continue
		for key in instance.condition.immunities:
			if key == template.id or (harmful and template.traits.has(key)):
				return instance
	return null


## Float `text` over the bearer and, when the player is involved, log
## `log_text`. Throttled per condition and text so re-applying fogs and fields
## don't spam (see AREA_NOTICE_REPEAT_MS).
func _announce_resist(condition_id: String, text: String, log_text: String, source: Node, color: Color = RESIST_COLOR) -> void:
	# Checked before the throttle stamp, so a hidden NPC doesn't use up the window.
	if not _bearer_noticeable():
		return
	var key := condition_id + ":" + text
	var now := Time.get_ticks_msec()
	var window: int = NOTICE_REPEAT_MS if is_instance_valid(source) and source is ProceduralCharacter else AREA_NOTICE_REPEAT_MS
	if _last_notice_ms.has(key) and now - int(_last_notice_ms[key]) < window:
		return
	_last_notice_ms[key] = now
	if text != "" and character and character.has_method("notify"):
		character.notify(text, color)
	if log_text != "" and _player_involved(source):
		GameLog.add_entry(log_text)


## True when the bearer or `source` is in the player's party. Untyped because a
## condition's stored source may already be freed.
func _player_involved(source) -> bool:
	for c in [character, source]:
		if is_instance_valid(c) and c.has_method("is_party_member") and c.is_party_member():
			return true
	return false


## True when notices about the bearer may be shown: a party member, or an NPC
## the party can currently see. Hidden NPCs stay quiet, so a notice never gives
## one away. "See" is the bearer's _announces_to_party (Game.is_seen_by_party,
## line of sight), the same test as the damage numbers on the same hit: a
## hearing pulse also sets `visible` on an NPC the party only heard.
func _bearer_noticeable() -> bool:
	if not is_instance_valid(character):
		return false
	if character.has_method("_announces_to_party"):
		return character._announces_to_party()
	if character.has_method("is_party_member") and character.is_party_member():
		return true
	return character is CanvasItem and character.visible


func _bearer_name() -> String:
	var n = character.get("Name") if character else null
	if n != null and str(n) != "":
		return str(n)
	return str(character.name) if character else "Someone"


func _condition_name(template: Condition) -> String:
	return template.display_name if template.display_name != "" else template.id.capitalize()


## "3 stacks" / "1 stack". Stacks are the one counter (ConditionInstance.stacks,
## capped by max_tier, "x3" in every summary); the log calls them stacks too.
static func _stacks_text(n: int) -> String:
	return "%d stack%s" % [n, "" if n == 1 else "s"]


## " (STR save: rolled 12 vs 55)" for the save the bearer just made. The roll
## and target are shown when the bearer's saving_throw records them.
func _save_detail(stat_name: String) -> String:
	var roll = character.get("last_save_roll") if character else null
	var target = character.get("last_save_target") if character else null
	if roll is int and target is int and roll >= 0:
		return " (%s save: rolled %d vs %d)" % [stat_name.to_upper(), roll, target]
	return " (%s save)" % stat_name.to_upper()


## Get all active (non-suppressed) stat modifiers
func get_active_stat_modifiers() -> Array[Dictionary]:
	var all_mods: Array[Dictionary] = []
	
	for cond_id in conditions:
		var instance: ConditionInstance = conditions[cond_id]
		# Ensure suppressed conditions are ignored during math calculations
		if not instance.is_suppressed:
			all_mods.append_array(instance.get_scaled_stat_modifiers())
			
	return all_mods


## Calculate the effective value of a stat with all condition modifiers
func calculate_effective_stat(base_value: float, stat_name: String) -> float:
	var flat_bonus: float = 0.0
	var multiplier: float = 1.0
	var set_value: float = NAN
	
	var mods = get_active_stat_modifiers()
	
	for mod in mods:
		if mod.get("stat") != stat_name:
			continue
		
		var value = mod.get("value", 0)
		var operation = mod.get("operation", "add")
		
		match operation:
			"add":
				flat_bonus += value
			"multiply":
				multiplier *= value
			"set":
				# Last set wins
				set_value = value
	
	# If a "set" modifier exists, use that as the base
	if not is_nan(set_value):
		return set_value
	
	return (base_value + flat_bonus) * multiplier


## Get conditional modifiers for a specific trigger
func get_conditional_modifiers(
	trigger_type: EffectResolver.TriggerType,
	source_traits: Dictionary,
	target_traits: Dictionary,
	action_traits: Dictionary
) -> Array[Dictionary]:
	var active_instances: Array[ConditionInstance] = []
	for cond_id in conditions:
		active_instances.append(conditions[cond_id])
	
	return EffectResolver.collect_modifiers(
		active_instances,
		trigger_type,
		source_traits,
		target_traits,
		action_traits
	)


## Check if character has a specific condition (active or not)
func has_condition(condition_id: String) -> bool:
	return condition_id in conditions


## Check if character has an active (non-suppressed) condition
func has_active_condition(condition_id: String) -> bool:
	var instance = conditions.get(condition_id)
	return instance != null and instance.is_active()


## Get a condition instance
func get_condition(condition_id: String) -> ConditionInstance:
	return conditions.get(condition_id)


## Get all conditions with a specific trait
func get_conditions_with_trait(Trait: String) -> Array:
	var result: Array[ConditionInstance] = []
	for cond_id in conditions:
		var instance: ConditionInstance = conditions[cond_id]
		if Trait in instance.condition.traits:
			result.append(instance)
	return result


## Remove all conditions with a specific trait
func remove_conditions_with_trait(Trait: String) -> int:
	var to_remove: Array[String] = []
	for cond_id in conditions:
		var instance: ConditionInstance = conditions[cond_id]
		if Trait in instance.condition.traits:
			to_remove.append(cond_id)
	
	for cond_id in to_remove:
		remove_condition(cond_id)
	
	return to_remove.size()


## Suppress all conditions with a specific trait
func suppress_conditions_with_trait(Trait: String) -> int:
	var count = 0
	for cond_id in conditions:
		var instance: ConditionInstance = conditions[cond_id]
		if Trait in instance.condition.traits:
			if suppress_condition(cond_id):
				count += 1
	return count


## Get all condition IDs
func get_all_condition_ids() -> Array[String]:
	var ids: Array[String] = []
	for key in conditions.keys():
		ids.append(key)
	return ids


## Clear all conditions
func clear_all_conditions() -> void:
	var all_ids = get_all_condition_ids()
	for cond_id in all_ids:
		remove_condition(cond_id)


## Serialize for saving
func to_dict() -> Dictionary:
	var saved_conditions: Dictionary = {}
	for cond_id in conditions:
		saved_conditions[cond_id] = conditions[cond_id].to_dict()
	return {"conditions": saved_conditions}


## Deserialize for loading. ConditionInstance.from_dict restores expires_at
## byte-for-byte (absolute time) and never calls apply(), so timed conditions
## keep their true remaining duration across a round-trip.
func from_dict(data: Dictionary) -> void:
	clear_all_conditions()
	var saved_conditions = data.get("conditions", {})
	for cond_id in saved_conditions:
		var instance = ConditionInstance.from_dict(saved_conditions[cond_id], condition_registry)
		if instance:
			conditions[cond_id] = instance
	_regrant_condition_abilities()
	stats_recalculated.emit()


## from_dict rebuilds instances without apply-time side effects, so abilities
## bestowed by conditions (grants_ability) must be re-granted here — mirroring
## apply_condition's grant block. Guarded by an inventory scan because
## add_ability_by_id does not dedup and granted abilities also round-trip
## through the weapon serializer (restore order: inventory first, then this).
func _regrant_condition_abilities() -> void:
	if not character:
		return
	var inv = character.get_node_or_null("Inventory")
	if inv == null or not inv.has_method("add_ability_by_id"):
		return
	for cond_id in conditions:
		var template: Condition = conditions[cond_id].condition
		if template == null or template.grants_ability == "":
			continue
		if _inventory_has_ability(inv, template.grants_ability):
			continue
		inv.add_ability_by_id(template.grants_ability)


func _inventory_has_ability(inv: Node, ability_id: String) -> bool:
	var pools: Array = []
	if "stowed_items" in inv:
		pools.append_array(inv.stowed_items)
	if "equipped_weapons" in inv:
		pools.append_array(inv.equipped_weapons)
	for it in pools:
		if it != null and ("ability_id" in it) and it.ability_id == ability_id:
			return true
	return false
