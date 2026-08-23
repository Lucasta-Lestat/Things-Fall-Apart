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
	STUNNED,
	SEARCHING  # Investigating a sound; no confirmed enemy yet
}

# ===== ALERTNESS METER =====
# Orthogonal to AIState. Drives the UI ?/! indicators and gates whether sound
# alone is enough to chase. Per the design: sound bumps the meter but can
# never *confirm* an enemy — only LOS unlocks HOSTILE. Once HOSTILE, the AI
# assumes follow-up sounds are the known enemy.
#
# AT_EASE is a "civilian default" mode — ambient noise is ignored entirely.
# Only specific stimuli wake an AT_EASE NPC: being attacked, witnessing an
# attack in LOS, seeing a stealth-mode party member, or hearing a very loud
# sound (gunshot, explosion). Once woken this map session, never auto-returns
# to AT_EASE — the only way back is map reload.
enum Alertness { AT_EASE, UNAWARE, SUSPICIOUS, SEARCHING, HOSTILE }

const ALERTNESS_MAX: float = 100.0
const ALERTNESS_SUSPICIOUS_THRESHOLD: float = 25.0
const ALERTNESS_SEARCHING_THRESHOLD: float = 60.0
const ALERTNESS_HOSTILE_THRESHOLD: float = 90.0
# Cap on sound-driven gains so audio alone can't unlock HOSTILE.
const ALERTNESS_SOUND_CAP: float = ALERTNESS_HOSTILE_THRESHOLD - 5.0
# Per-second decay applied when no recent stimulus.
const ALERTNESS_DECAY_PER_SEC: float = 4.0
# Multiplier: loudness=1.0 sound adds this much to the meter.
const ALERTNESS_SOUND_GAIN: float = 55.0
# How long the meter sits at peak after a stimulus before decay kicks in.
const ALERTNESS_DECAY_GRACE: float = 1.5
# Ally alertness sharing — only meaningful when allies are in LOS.
const ALLY_SHARE_INTERVAL: float = 0.75
const ALLY_SHARE_FACTOR: float = 0.5
# When SEARCHING and arrived at last_heard_position, rotate-scan for this many
# seconds before giving up.
const SEARCH_LOOK_AROUND_DURATION: float = 2.5
# Hard ceiling on one SEARCHING episode, regardless of alertness. The
# alertness-driven exits can be starved indefinitely (see _process_searching).
const SEARCH_GIVE_UP_SECONDS: float = 20.0
# Alertness value an AT_EASE NPC is bumped to when woken — just into UNAWARE
# (paying attention but not alarmed). Far below SUSPICIOUS to avoid
# immediately panicking.
const WAKE_FROM_AT_EASE_VALUE: float = 5.0

var alertness_value: float = 0.0
var current_alertness: Alertness = Alertness.UNAWARE
# AT_EASE is a one-way flag (true at spawn for civilians; cleared on first
# meaningful stimulus). Separate from alertness_value so we can preserve the
# value-based state machine while still gating noise reactivity.
var is_at_ease: bool = false
var last_heard_position: Vector2 = Vector2.ZERO
var time_since_last_stimulus: float = 999.0
var ally_share_timer: float = 0.0
var _search_look_timer: float = 0.0
var _search_repath_cd: float = 0.0   # throttle repaths to an unreachable noise

signal alertness_changed(old_alertness: Alertness, new_alertness: Alertness)

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
# True when the last plan DID find a route but _advance_path refused its next
# leg for crossing fire we're not standing in. Distinguishes "wait at the
# fire's edge" from "goal sealed" — both leave nav_path empty, and _combat_move
# used to read either as sealed and lean on the straight line, grinding the
# body into whatever wall faced the target until the fire burned out.
var _path_refused_on_hazard: bool = false
# Sealed-goal press progress gate: position anchored at each empty-path repath
# cycle. A full 0.7s of straight-line pressure that moved us less than a few
# px is a head-on press, not a glide — stand down instead of sanding the wall.
# (A LOCKED door seals a room to A* and the escape flood alike — no door_pass
# — and the press otherwise re-arms is_moving every tick, so the mover's
# stuck escape can never stick: the other route into the eternal wall-grind.)
var _press_anchor := Vector2.INF
var _press_stalled := false

# Signals
signal state_changed(old_state: AIState, new_state: AIState)
signal target_acquired(target: ProceduralCharacter)
signal target_lost()
signal outcry_state_changed(active: bool, frac: float)

# ===== OUTCRY (witness pipeline, docs/law_crime_stealth_plan.md Phase 5) =====
# The fuse lives ON THE WITNESS, which is the whole design: there is no
# cancellation code because there is nothing centralised to cancel — kill the
# witness and the fire-time guard rejects, queue_free them and the timer
# never ticks, knock them out or silence them and _can_still_cry_out catches
# it. The tick is frame-driven inside process_ai, so PauseManager freezes the
# fuse with everything else: unlimited thinking time, ~2.2 s of execution
# time. Do not "fix" the fuse to keep ticking under pause.
var pending_outcry: Dictionary = {}   # {crime_id, perp, crime_pos, identified, law_faction, delay, ...}
var _outcry_timer: float = -1.0
var _outcry_total: float = 0.0
# Set by Phase 6 when an identified crime is recorded: the perp this AI
# remembers past alertness decay. Declared here so Phase 5 payloads have a
# landing site.
var manhunt_target: ProceduralCharacter = null
# Compulsion parameters, in the same shape and for the same reason as
# manhunt_target: personal, per-AI, unserialised, dies with the map. The
# CONDITION is only the clock and the saving throw; this is the "about whom".
# Deliberately not in ConditionInstance.custom_data, which to_dict() writes
# verbatim into the save -- a Node reference there would be serialised.
# Written only by CompulsionField, so every default-state test stays green.
var compel_victim: ProceduralCharacter = null
var compel_focus: Node2D = null
# Post-robbery truce (Phase 7 surrender): while active, this AI ignores
# player-faction targets — without it, a hostile_by_default bandit
# re-acquires on the next tick and being robbed is pointless.
var truce_until: float = -1.0
# Corpse-discovery sweep throttle (Phase 7).
var corpse_check_timer: float = 0.0

# True when the equipped main-hand weapon fires projectiles: engagement ranges
# stretch to the weapon and APPROACH kites instead of closing to fists.
var is_ranged_fighter: bool = false
# Combat A* re-plan throttle (see _combat_move).
var _combat_repath_timer: float = 0.0
# Fixed approach bearing around the current target (surround slots).
var _engage_ang: float = 0.0
# Ability cast cadence (see _try_cast_ability).
var _cast_timer: float = 0.0


# ===== ABILITY CASTING =====
# NPCs enumerate their AbilityShapes (granted via extra_abilities / race
# features) and cast through the same AbilityManager pipeline the player
# uses. Policy, evaluated in inventory order: heal the most-wounded nearby
# ally when someone is genuinely hurt; otherwise throw the first offensive
# ability that reaches the current target with a sight line. Cadence-gated
# so casters still weapon-attack between spells. Costs/conditions gate inside
# use_ability (NPC templates without school tiers skip the resource gate via
# npc_unlimited_resources).
func _try_cast_ability(delta: float) -> bool:
	_cast_timer -= delta
	if _cast_timer > 0.0:
		return false
	if character.attack_animator != null and character.attack_animator.is_attacking:
		return false
	var inv = character.get_node_or_null("Inventory")
	if inv == null or not ("stowed_items" in inv):
		return false
	for it in inv.stowed_items:
		if not (it is AbilityShape):
			continue
		var data: Dictionary = AbilityDatabase.get_ability_data(String(it.ability_id))
		if data.is_empty():
			continue
		var tr: Dictionary = data.get("traits", {})
		var rng_px: float = float((data.get("targeting", {}) as Dictionary).get("range", 0.0))
		if int(tr.get("healing", 0)) > 0 or int(tr.get("support", 0)) > 2:
			var patient = _most_wounded_ally(maxf(rng_px, 120.0))
			if patient != null and _cast(data, patient.global_position, patient, true):
				return true
		elif int(tr.get("attack", 0)) > 0 and current_target != null and is_instance_valid(current_target):
			var dist := character.global_position.distance_to(current_target.global_position)
			if dist <= maxf(rng_px, 90.0) \
					and not _would_self_blast(data, current_target.global_position, current_target) \
					and is_in_line_of_sight(current_target.global_position, _target_elevation()):
				if _cast(data, current_target.global_position, current_target):
					return true
	_cast_timer = 1.2   # nothing castable right now — re-check soon
	return false


func _cast(data: Dictionary, pos: Vector2, target_node, explicit := false) -> bool:
	var ab = Ability.from_dict(data)
	var params: Dictionary = {"position": pos, "anchor": target_node}
	# Area attacks pass NO explicit target list: a non-empty list routes into
	# the pick-your-targets branch, which skips the projectile AND the area
	# sweep — every AI "AoE" resolved as a single-target nuke with zero splash.
	# Position-only casts run the exact player pipeline (fireball flies its
	# projectile, the detonation sweeps everyone in radius — including the
	# caster, hence _would_self_blast). Heals and non-area shapes keep their
	# explicit target: a shape-"none" attack passed position-only would sweep
	# nobody, and an area heal would splash-heal enemies.
	var shape := String((data.get("targeting", {}) as Dictionary).get("shape", "none"))
	if explicit or not shape in ["circle", "cone", "line", "rectangle"]:
		params["targets"] = [target_node]
	var ok: bool = character.use_ability(ab, params)
	_cast_timer = randf_range(2.6, 4.2) if ok else 1.2
	return ok


# An AoE dropped on a hugging-range target lands on its caster too: the area
# sweep has no self-exclusion for circles, and a fire AoE ignites the ground
# across the FULL targeting radius no matter who the damage hit — the melee
# fireball suicide from playtest. Skip any circle attack whose blast at `pos`
# reaches us; evaluation falls through to the next stowed ability, and the
# weapon swing is still there when nothing safe is castable. Cones and lines
# originate at the caster and already exclude them in _find_targets_in_area.
# Only TRUE areas (traits.aoe) are gated: melee attacks are also authored as
# small circles at the target (natural_bite r30, shield_bash r40, pounce,
# ram — none carry the aoe trait) and the caster deliberately stands a body
# width outside them; gating those would leave animals unable to bite.
func _would_self_blast(data: Dictionary, pos: Vector2, target_node = null) -> bool:
	var tgt: Dictionary = data.get("targeting", {})
	if int((data.get("traits", {}) as Dictionary).get("aoe", 0)) <= 0:
		return false
	if String(tgt.get("shape", "none")) != "circle":
		return false
	var r: float = float(tgt.get("radius", 0.0))
	if r <= 0.0:
		return false
	# margin: our body, plus slop for the step we may take before the cast lands
	var margin: float = maxf(32.0, character._body_circle_radius() + 16.0)
	# Anchored casts (projectiles) re-aim at the target's LIVE position after
	# the windup — a melee attacker charging us drags the detonation onto our
	# feet even when the snapshot distance looked safe (we plant our own feet
	# during casts, see _combat_move, so only THEIR closing speed matters).
	# Ground-placed AoEs (ice storm) stay where they were aimed: no widening.
	var cast_time: float = float(data.get("cast_time", 0.0))
	if cast_time > 0.0 and target_node is Node2D and "velocity" in target_node \
			and AbilityManager.targeting_follows_anchor(tgt, data.get("visuals", {})):
		var to_me: Vector2 = character.global_position - pos
		if to_me.length() > 0.001:
			margin += maxf(0.0, target_node.velocity.dot(to_me.normalized())) * cast_time
	return character.global_position.distance_to(pos) <= r + margin


# Most-wounded non-hostile character in range (self included), or null when
# nobody is below 72% health — shamans shouldn't top up scratches mid-fight.
func _most_wounded_ally(rng_px: float):
	var best = null
	var best_frac := 0.72
	if game == null or not ("characters_in_scene" in game):
		return null
	for ch in game.characters_in_scene:
		if not is_instance_valid(ch) or not ch.has_method("is_alive") or not ch.is_alive():
			continue
		if ch != character and (ch.faction_id != character.faction_id \
				or FactionDatabase.are_hostile(character.faction_id, ch.faction_id)):
			continue
		if character.global_position.distance_to(ch.global_position) > rng_px:
			continue
		var frac: float = float(ch.current_health) / maxf(1.0, float(ch.max_health))
		if frac < best_frac:
			best_frac = frac
			best = ch
	return best


# Engagement ranges follow the equipped MAIN-HAND item. Body size stays the
# floor for melee; a projectile weapon pushes attack_range out to its real
# reach (weapon_range is in TILES: shortbow 5.0 -> 320px) so archers/casters
# stop walking into hugging distance before firing.
func _refresh_engagement_ranges(_w = null) -> void:
	# Unarmed baseline comes from the same helper the hit test uses, so a
	# bare-handed AI stops parking at the old hardcoded 70px — well outside the
	# ~56px at which a punch can actually connect.
	attack_range = MeleeReach.reach_px(character, null)
	preferred_range = attack_range * 0.6
	too_close_range = 20.0 * character.body_size_mod
	is_ranged_fighter = false
	var w = character.current_main_hand_item
	if w == null or not ("primary_damage_type" in w):
		return
	if String(w.primary_damage_type) in ["ranged_arrow", "ranged_bullet"]:
		var wr_tiles: float = float(w.weapon_range) if ("weapon_range" in w) else 4.0
		var px: float = maxf(wr_tiles * GridManager.TILE_SIZE, 128.0)
		is_ranged_fighter = true
		attack_range = px
		preferred_range = px * 0.8
		too_close_range = px * 0.35   # target closing inside this -> back off (kite)
	elif ("weapon_range" in w) and float(w.weapon_range) > 0.0:
		# melee: the SAME reach the hit test uses (MeleeReach.reach_px), not a
		# parallel guess. The old `* 0.85` fudge was compensating for a physical
		# blade sweep that had no relationship to this number at all; now that
		# the authored range IS the reach, shrinking it just makes the AI stand
		# somewhere it cannot swing from.
		attack_range = MeleeReach.reach_px(character, w)
		preferred_range = attack_range * 0.6
		too_close_range = minf(20.0 * character.body_size_mod, attack_range * 0.35)

# Centre-to-centre distance at which two bodies actually touch. Mirrors
# ProceduralCharacter.get_separation_vector (:2074), which moved the physical
# model off the oversized `collision_radius` pair (max(body_width, head_width)/2
# + 2 = 26 for a 48-wide race) onto `_body_circle_radius()` (0.45 * body_width =
# 21.6) with the note that the old pair "repell[ed] ~14px before bodies touched".
# ai.gd never followed, so every stand-off carried ~9px of phantom gap per pair —
# which is exactly what pushed short weapons under the floor below.
func _body_gap_to(target: Node2D) -> float:
	var mine: float = character._body_circle_radius()
	var theirs: float = 0.0
	if target != null and is_instance_valid(target) and target.has_method("_body_circle_radius"):
		theirs = target._body_circle_radius()
	var sep: float = character.minimum_separation
	return mine + theirs + sep

# The distance the AI is willing to swing from, and the distance it walks to.
# These MUST NOT invert: `stand` used to be `combined + 10` while `swing` was
# `combined + 5`, so any weapon whose reach fell under the floor (authored range
# below ~1.23 tiles — sickle 0.9, dagger 0.8, shortsword 1.0, but not longsword
# or axe) parked 5px BEYOND the distance it would swing from and then only
# strafed. That is the "stands in the enemy's face doing nothing" report.
# `stand` is now clamped inside `swing` so arriving always means in range.
func _engagement_bands(target: Node2D) -> Dictionary:
	var gap: float = _body_gap_to(target)
	var swing: float
	if is_ranged_fighter:
		# A projectile's range is not a reach; keep it clear of body contact.
		swing = maxf(attack_range, gap + 5.0)
	else:
		# EXACTLY the distance Game.resolve_melee_swing will accept — same
		# helper, same numbers. No collision floor is needed here any more:
		# MeleeReach.MIN_CLEARANCE_PX guarantees this always exceeds `gap`.
		swing = MeleeReach.max_center_dist(character, target, character.current_main_hand_item)
	var stand: float = clampf(preferred_range, gap, maxf(gap, swing - 8.0))
	return {"gap": gap, "swing": swing, "stand": stand}

func _ready():
	character = get_parent()
	game = get_tree().current_scene
	detection_range = 1440.0 * character.sight
	_refresh_engagement_ranges(null)
	# ranges follow the EQUIPPED weapon (a shortbow keeps its wielder ~5 tiles
	# out); equipment lands after _ready, so refresh on every swap
	if character.has_signal("weapon_changed"):
		character.weapon_changed.connect(_refresh_engagement_ranges)
	# Default to UNAWARE; build_character calls apply_default_alertness after
	# faction is set, which may flip us to AT_EASE for civilian factions.
	# (_ready fires before build_character runs, so we can't resolve here.)
	is_at_ease = false
	current_alertness = Alertness.UNAWARE
	# When this character takes damage, wake from AT_EASE and bump alertness.
	# Being attacked is a strong stimulus — straight to SEARCHING-level so we
	# immediately start heading toward the strike location.
	if character.has_signal("damaged_by"):
		character.damaged_by.connect(_on_self_damaged)


# Called by build_character after faction is set, OR by Game.gd when reviving
# a character from save data. Accepts "at_ease" or "unaware"; anything else
# falls through to UNAWARE.
func apply_default_alertness(alertness_str: String) -> void:
	if alertness_str.to_lower() == "at_ease":
		is_at_ease = true
		var old: Alertness = current_alertness
		current_alertness = Alertness.AT_EASE
		if old != current_alertness:
			emit_signal("alertness_changed", old, current_alertness)
	else:
		is_at_ease = false
		var old2: Alertness = current_alertness
		current_alertness = Alertness.UNAWARE
		if old2 != current_alertness:
			emit_signal("alertness_changed", old2, current_alertness)


func _check_stealth_wake() -> void:
	# Called from process_ai only when is_at_ease is true. If global stealth
	# mode is on and ANY party member is in our LOS, that's enough to break
	# the trance — we wake to UNAWARE (not SEARCHING — they're not behaving
	# violently, just suspiciously).
	if not game or not ("stealth_mode" in game) or not game.stealth_mode:
		return
	var party = game.party_chars if "party_chars" in game else []
	for pc in party:
		if not is_instance_valid(pc) or not pc.has_method("is_alive") or not pc.is_alive():
			continue
		if is_in_line_of_sight(pc.global_position, pc.get_elevation()):
			wake_from_at_ease(WAKE_FROM_AT_EASE_VALUE, pc.global_position)
			return  # is_at_ease is now false; caller's early-out blocks re-entry


func _on_self_damaged(attacker, location: Vector2, _total_damage: float) -> void:
	# Being struck IS positive identification — you do not have to SEE someone
	# to know they just hit you. The old comment here promised "normal
	# _update_target will pick them up as a target next tick"; that is only
	# true inside the ±75° cone, so anyone stabbing this character from behind
	# was invisible to it forever. Worse, `location` is the impact point on our
	# OWN body (ProceduralCharacter.gd:6038 re-globalizes the local hit pos), so
	# the fallback below sends SEARCHING to the ground under our feet: arrive
	# instantly, spin for 2.5s, stand down, get killed.
	var foe := attacker as ProceduralCharacter
	if foe != null and is_instance_valid(foe) and foe.is_alive() and _is_enemy(foe):
		wake_from_at_ease(ALERTNESS_SEARCHING_THRESHOLD + 5.0, foe.global_position)
		last_known_target_pos = foe.global_position
		if current_target != null:
			return
		# A backstab must not auto-reveal an invisible assassin — mirror the
		# invisibility rule _update_target applies (:731-734).
		if character.traits.get("true_sight", 0) == 0:
			var foe_cm = foe.get_node_or_null("ConditionManager")
			if foe_cm and foe_cm.has_active_condition("invisible"):
				return
		# No _change_state here: _acquire_target re-arms reaction_timer (the
		# flinch delay) and IDLE/SEARCHING both promote to CHASE on their own.
		_acquire_target(foe)
		return

	# Not an enemy (friendly fire, a condition tick, falling damage): wake, but
	# nothing to fight.
	wake_from_at_ease(ALERTNESS_SEARCHING_THRESHOLD + 5.0, location)
	if attacker:
		last_known_target_pos = attacker.global_position if "global_position" in attacker else location


# Reads `default_alertness` from the character (set by spawn flow from Maps
# override or faction default in factions.json). Defaults to UNAWARE if
# neither was set. Called once in _ready.
# ===== MAIN AI LOOP =====

func process_ai(delta: float) -> void:
	# Update timers
	attack_cooldown_timer = max(0, attack_cooldown_timer - delta)
	reaction_timer = max(0, reaction_timer - delta)
	state_timer += delta
	time_since_last_stimulus += delta
	ally_share_timer -= delta
	# Outcry fuse ticks BEFORE the unconscious early-out on purpose: a
	# knocked-out witness's fuse must still reach zero so the fire-time
	# guard cancels it — a frozen fuse would scream when they wake up.
	_tick_outcry(delta)

	# Alertness decay + ally sharing
	_update_alertness(delta)
	# AT_EASE NPCs notice party members who are sneaking — but only when they
	# actually see them. Cheap early-out keeps the cost off non-civilians.
	if is_at_ease:
		_check_stealth_wake()

	# Handle unconscious — no actions possible
	var _cm = character.get_node_or_null("ConditionManager")
	if _cm and _cm.has_condition("unconscious"):
		return

	# Handle stunned state
	if current_state == AIState.STUNNED:
		if not "stunned" in character.conditions:
			_change_state(AIState.IDLE)
		return

	# Standing on damaging ground (burning cell, acid pool, electrified tile)
	# overrides everything a conscious body can override: burning stacks 1/s
	# toward 24 dmg per 1.5s, and no goal — investigation, attack, even panic —
	# is worth finishing from inside a fire (a scout burned to death mid-scan
	# in playtest because nothing ever told him to step out). Escape funnels
	# through _move_toward, so a player-held ally still stands ground.
	if _process_hazard_escape(delta):
		return

	# Handle panicked — random movement, overrides everything (including a
	# player-drawn path: see _break_player_orders)
	if _cm and _cm.has_active_condition("panicked"):
		_break_player_orders()
		_process_panicked(delta)
		return

	# Handle frightened — flee from fear source, overrides combat and orders
	if _cm and _cm.has_active_condition("frightened"):
		_break_player_orders()
		_process_frightened(delta)
		return

	# Corpse discovery (Phase 7): enforcers who see a crime-stamped body
	# raise an unidentified alarm. Throttled; skipped while incapacitated
	# states above have already returned.
	# Handle transfixed — the idol has your eyes. Sits here deliberately: BELOW
	# the incapacitating states and hazard escape above (nothing is worth burning
	# to death for) and ABOVE the apathetic clear further down, which would wipe
	# it. It tears down player orders the way fear does, because "instead of
	# whatever it had planned" is the whole point of the spell.
	if _cm and _cm.has_active_condition("transfixed"):
		_break_player_orders()
		_process_transfixed(delta)
		return
	elif compel_focus != null:
		compel_focus = null

	corpse_check_timer -= delta
	if corpse_check_timer <= 0.0:
		corpse_check_timer = 1.0
		_check_corpse_discovery()

	# Check path progress for wandering/seeking
	_check_path_progress()

	# Update combat target
	_update_target()

	# Handle apathetic — movement only, no combat. Suppress targeting and force IDLE
	# AFTER _update_target so reacquisition can't override it.
	if _cm and _cm.has_active_condition("apathetic"):
		current_target = null
		if current_state != AIState.DEAD and current_state != AIState.IDLE:
			_change_state(AIState.IDLE)

	# If alertness has crossed into SEARCHING and we have no confirmed target,
	# leave goal/idle behavior and head to the last heard position. HOSTILE
	# alertness without a target also routes through SEARCHING — the AI heads
	# to last_heard_position and acquires-by-LOS along the way.
	if current_target == null and alertness_value >= ALERTNESS_SEARCHING_THRESHOLD:
		if current_state == AIState.IDLE or current_state == AIState.PATROL:
			_change_state(AIState.SEARCHING)

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
		AIState.SEARCHING:
			_process_searching(delta)

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

func is_in_line_of_sight(target_position: Vector2, target_elev: float = 0.0) -> bool:
	# Blinded/unconscious characters see nothing — the party-side wrapper
	# (Game._has_visual_los) always checked this; now both wrappers agree.
	var cm_sight = character.get_node_or_null("ConditionManager")
	if cm_sight and (cm_sight.has_condition("blinded") or cm_sight.has_condition("unconscious")):
		return false

	var to_target = target_position - character.global_position
	var distance = to_target.length()

	if distance > get_sight_range_pixels():
		return false

	var facing = get_facing_vector()
	var angle_to_target = rad_to_deg(facing.angle_to(to_target.normalized()))
	var half_fov = character.effective_fov() / 2.0

	if abs(angle_to_target) > half_fov:
		return false

	return _has_clear_sight_line(target_position, target_elev)

func _has_clear_sight_line(target_position: Vector2, target_elev: float = 0.0) -> bool:
	var world := character.get_world_2d()
	if not world:
		return true
	# Elevation-aware: an elevated sentry sees over 1-story walls; a ground NPC
	# can't see onto decks (their occlude_top blocks a ground-level viewer).
	# Passing the target's elevation lets a street guard acquire a character
	# standing on a roof (otherwise the perimeter wall blocks every ray up).
	return GridManager.sight_line_clear(world.direct_space_state, character.global_position, target_position, character.get_elevation(), target_elev)

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
		if c != character and is_instance_valid(c) and is_in_line_of_sight(c.global_position, c.get_elevation()):
			visible_chars.append(c)
	return visible_chars


# ===== TARGET DETECTION =====

# Radius inside which _update_target stops caring which way this character is
# facing. Two tiles plus our own body: wide enough to cover every melee
# engagement band (MeleeReach tops out well inside it) and the "he was RIGHT
# THERE" complaint, narrow enough that it is peripheral awareness rather than
# omniscience. Deliberately NOT derived from attack_range — a bowman's 5-tile
# attack_range would turn this into a 7-tile all-round sensor.
const CLOSE_QUARTERS_TILES: float = 2.0

func _close_quarters_radius() -> float:
	return GridManager.TILE_SIZE * CLOSE_QUARTERS_TILES + character._body_circle_radius()


# The one carve-out from close-quarters awareness: a party member who is
# deliberately sneaking. The FOV cone IS the stealth mechanic in this game —
# slipping around behind a guard is the whole move — so peripheral awareness
# must not quietly delete it. Sneaking buys you the approach, not immunity:
# the moment you strike, _on_self_damaged acquires you by name regardless of
# angle, and stepping into the cone still gets you seen.
func _is_sneaking(other: ProceduralCharacter) -> bool:
	if game == null or not ("stealth_mode" in game) or not game.stealth_mode:
		return false
	if not ("party_chars" in game):
		return false
	return other in game.party_chars


func _update_target() -> void:
	# Validate existing target
	if current_target:
		if not is_instance_valid(current_target):
	# Compulsion outranks the hysteresis below on purpose: a musked guard
	# mid-chase has to turn on his own kind, not finish the fight he was already
	# in. Above the apathetic suppression too -- a directed compulsion beats an
	# undirected mood.
	if _apply_compulsion():
		return
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
			if not is_in_line_of_sight(other.global_position, other.get_elevation()):
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

	# Blinded/unconscious see nothing. is_in_line_of_sight enforces that itself
	# (:578-580), but the close-quarters branch below skips that helper, so the
	# check has to be hoisted here or a blinded NPC would sense through walls of
	# its own eyelids.
	if _cm2 and (_cm2.has_condition("blinded") or _cm2.has_condition("unconscious")):
		return

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

		# Invisible targets can't be acquired — unless this viewer has the
		# true_sight trait (or the target is glowing, since the "illuminated"
		# condition blocks invisibility from applying at all).
		if character.traits.get("true_sight", 0) == 0:
			var other_cm = other.get_node_or_null("ConditionManager")
			if other_cm and other_cm.has_active_condition("invisible"):
				continue

		var dist: float = character.global_position.distance_to(other.global_position)
		# CLOSE QUARTERS — the cone does not apply. is_in_line_of_sight gates on
		# a ±75° forward arc (150° is the fov_angle_degrees default and NOTHING
		# moves it: no condition declares that stat key, so fov_modifier is
		# always 0), and the only thing in this file that ever turns the head is
		# the direction of travel — _move_toward writes target_rotation to the
		# movement bearing, and _aim_at needs a target we do not have yet. A
		# searcher jogging toward a noise is therefore PERMANENTLY blind to
		# anything at its flank or back, which is the "walks straight past
		# enemies" report: an enemy at your elbow is not a vision problem.
		# The wall ray still runs, so cover, doors and elevation are untouched;
		# only the arc is skipped.
		if dist <= _close_quarters_radius() and not _is_sneaking(other):
			if not _has_clear_sight_line(other.global_position, other.get_elevation()):
				continue
		elif not is_in_line_of_sight(other.global_position, other.get_elevation()):
			continue

		if dist < best_distance:
			best_distance = dist
			best_target = other

	if best_target:
		_acquire_target(best_target)

# FactionDatabase.are_hostile is THE hostility oracle — do not add local
# hostility logic here. (The old fallthrough "two distinct non-neutral
# factions are hostile on sight" lived here; its survivors are now authored
# True when a compulsion has seized targeting this tick.
func _apply_compulsion() -> bool:
	var cm = character.get_node_or_null("ConditionManager")
	if cm == null:
		compel_victim = null
		return false
	if not cm.has_active_condition("incited"):
		# Release explicitly. Do NOT copy what `confused` does: nothing there ever
		# clears current_target when the condition lapses, so a confused NPC keeps
		# murdering the ally it picked long after it stopped being confused.
		if compel_victim != null:
			compel_victim = null
			if current_target != null:
				_lose_target()
		return false
	if not is_instance_valid(compel_victim) or not compel_victim.is_alive():
		# Victim gone: the compulsion has nothing left to mean.
		compel_victim = null
		cm.remove_condition("incited")
		if current_target != null:
			_lose_target()
		return false
	if current_target != compel_victim:
		# _acquire_target, not character.set_target(): set_target is gated on
		# $AI._is_enemy and would silently no-op for a same-faction victim on the
		# first frame, before the _is_enemy short-circuit below has anything to
		# read. _acquire_target has no such gate.
		_acquire_target(compel_victim)
	return true


# Stand still and stare. Re-asserted every tick because _move_toward rewrites
# target_rotation to the travel bearing whenever the body moves.
func _process_transfixed(_delta: float) -> void:
	var focus: Node2D = compel_focus
	if focus == null or not is_instance_valid(focus):
		var cm = character.get_node_or_null("ConditionManager")
		if cm != null:
			cm.remove_condition("transfixed")
		compel_focus = null
		return
	if current_target != null:
		_lose_target()
	character.is_moving = false
	nav_path.clear()
	nav_path_index = 0
	# _aim_at rather than a raw target_rotation write: it already refuses to
	# stomp a running ActionType.FACE, which would otherwise stall that action's
	# queue forever waiting for a rotation that keeps being overwritten.
	_aim_at((focus.global_position - character.global_position).angle() + PI / 2)


# as hostile_by_default in factions.json.) The single exception: a manhunt
# target is personal knowledge — this enforcer HEARD the accusation — and
# survives alertness decay until the account is settled.
func _is_enemy(other: ProceduralCharacter) -> bool:
	if manhunt_target != null and is_instance_valid(manhunt_target) and other == manhunt_target:
		return true
# A compulsion is the second such exception, and is scoped the same way.
	# Post-robbery truce: they took your purse and let you live (Phase 7).
	if truce_until > 0.0 and other.faction_id == "player" \
			and TimeManager.absolute_time() < truce_until:
	# An incited creature counts its designated victim as an enemy for every
	# DOWNSTREAM gate too (AbilityTargeting's "enemies" filter, ally scans), which
	# is what lets a compulsion cross faction lines without touching
	# FactionDatabase. A field read, not a get_node, because this runs inside the
	# O(N) candidate scan. Inert unless CompulsionField wrote the field, so
	# hostility_harness's 361-pair oracle sweep is unaffected.
	if compel_victim != null and is_instance_valid(compel_victim) and other == compel_victim:
		return true
		return false
	return FactionDatabase.are_hostile(character.faction_id, other.faction_id)

func _acquire_target(target: ProceduralCharacter) -> void:
	current_target = target
	last_known_target_pos = target.global_position
	# A sighting outranks a sound. SEARCHING walks to last_heard_position, and
	# until now NOTHING in combat ever wrote that field — only sounds, the
	# AT_EASE wake and ally sharing did — so a guard who acquired purely by
	# sight and never heard anything carried the Vector2.ZERO it was born with
	# (:65) and, the moment it lost the target, marched at the map corner.
	last_heard_position = target.global_position
	# Surround slot: a fixed per-character approach bearing around the target
	# (anchored at acquisition — a live-recomputed bearing would orbit). The
	# second melee used to queue into his comrade's back on the same line.
	_engage_ang = (character.global_position - target.global_position).angle() \
		+ float((character.get_instance_id() % 5) - 2) * 0.5
	emit_signal("target_acquired", target)
	# Visual identification locks alertness to HOSTILE — sound alone can't do
	# this, only LOS via _update_target reaches here.
	_set_alertness_value(ALERTNESS_MAX)
	# Clear any wander/seek path
	nav_path.clear()
	current_goal = "idle"
	target_item = null
	reaction_timer = reaction_time

func _lose_target() -> void:
	# Investigate where they WERE, not the last unrelated bang. _acquire_target
	# pins alertness to MAX and nothing here lowers it, so the :523 gate
	# re-promotes to SEARCHING on the very next tick — which meant every kill
	# sent the AI marching off toward whatever made the last noise. This is the
	# first and only READ of last_known_target_pos, which _update_target has
	# been refreshing every frame (:670) for nobody.
	if last_known_target_pos != Vector2.ZERO:
		last_heard_position = last_known_target_pos
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
	var bands: Dictionary = _engagement_bands(current_target)
	var safe_attack_range: float = bands["swing"]

	# casters open from chase range (fireball reaches 400px)
	if _try_cast_ability(delta):
		return

	if dist <= safe_attack_range * 1.2:
		_change_state(AIState.APPROACH)
		return

	# steer for the surround slot, not the straight line — flankers circle in.
	# Snapped to walkable ground: a slot INSIDE a wall (target hugging masonry,
	# bearing pointing wallward) froze the AI forever — find_path O(1)-rejects
	# an INF goal, so it never moved and never closed to APPROACH range.
	var target_pos = _reachable_slot(current_target.global_position \
		+ Vector2.from_angle(_engage_ang) * safe_attack_range * 0.8)
	_combat_move(target_pos, delta)

func _process_approach(delta: float) -> void:
	if not current_target:
		_change_state(AIState.IDLE)
		return

	var dist = character.global_position.distance_to(current_target.global_position)
	var dir_to_target = (current_target.global_position - character.global_position).normalized()

	var bands: Dictionary = _engagement_bands(current_target)
	var safe_attack_range: float = bands["swing"]
	var safe_preferred_range: float = bands["stand"]
	var safe_too_close: float = maxf(too_close_range, float(bands["gap"]))

	# Face the target - through _aim_at so the aim survives the path's
	# set_path_facing writes instead of being stomped on the next waypoint.
	_aim_at(dir_to_target.angle() + PI / 2)

	if _try_cast_ability(delta):
		return

	if dist > safe_attack_range * 1.5:
		_change_state(AIState.CHASE)
		return

	# Melee attacks whenever in range and off cooldown — NO lower bound: the
	# old `dist >= safe_too_close` gate made a cornered enemy back up instead
	# of swinging, forever if the retreat was blocked (the "orc stands in your
	# face doing nothing" freeze). Ranged keeps the lower bound to kite first.
	# `_movement_locked()` relaxes the ranged lower bound for exactly the reason
	# the melee bound was removed: a shooter walking a player-drawn path CANNOT
	# kite (the legs belong to the ActionQueue), so keeping the bound left it
	# standing next to an enemy doing nothing until the path carried it clear.
	# It cannot retreat, so it shoots.
	if dist <= safe_attack_range and attack_cooldown_timer <= 0 \
			and (not is_ranged_fighter or dist >= safe_too_close or _movement_locked()):
		# Melee can't reach across stories (Game.can_hit_target vetoes the hit) —
		# don't enter ATTACK and whiff forever at a deck edge; path toward the
		# target instead so A*'s per-step elevation routing finds the ramp.
		if absf(character.get_elevation() - _target_elevation()) > game.MELEE_ELEV_TOLERANCE:
			_combat_move(current_target.global_position, delta)
			return
		# Ranged needs an actual firing line — a 5-tile shot into a wall face
		# just decorates the masonry. Close along the path until one opens.
		if is_ranged_fighter and not is_in_line_of_sight(current_target.global_position, _target_elevation()):
			_combat_move(current_target.global_position, delta)
			return
		_change_state(AIState.ATTACK)
		return

	# Too close — back up. RANGED ONLY. A melee fighter only ever reached this
	# branch during its own attack cooldown, and backing off then re-opens the
	# gap it just closed, so it spends the cooldown walking out and the next
	# tick walking back in — never settling inside its swing band. Melee holds
	# its ground and swings again; the soft separation push already handles
	# actual body overlap.
	# Skipped under player orders: _kite_away is a no-op then, so taking this
	# branch would `return` out of the tick having done nothing at all.
	if is_ranged_fighter and dist < safe_too_close and not _movement_locked():
		_kite_away(dir_to_target, safe_preferred_range - dist + 10.0)
		return

	# Approach the surround slot at preferred range, or strafe in place
	if dist > safe_preferred_range:
		var approach_pos = _reachable_slot(current_target.global_position \
			+ Vector2.from_angle(_engage_ang) * safe_preferred_range)
		_combat_move(approach_pos, delta)
	else:
		if randf() < 0.3 * delta:
			var strafe_dir = dir_to_target.rotated(PI / 2 * (1 if randf() > 0.5 else -1))
			_move_toward(character.global_position + strafe_dir * 30)

func _target_elevation() -> float:
	if current_target and is_instance_valid(current_target):
		if current_target.has_method("get_elevation"):
			return current_target.get_elevation()
		return GridManager.effective_elev(GridManager.world_to_map(current_target.global_position))
	return character.get_elevation()

func _process_attack(delta: float) -> void:
	var safe_attack_range: float = float(_engagement_bands(current_target)["swing"])

	# Track the target while in ATTACK state: APPROACH stops re-facing once we
	# get here, so a strafing target used to drift out of the firing line.
	if current_target and is_instance_valid(current_target):
		_aim_at((current_target.global_position - character.global_position).angle() + PI / 2)

	if _try_cast_ability(delta):
		return
	if not character.attack_animator.is_attacking and attack_cooldown_timer <= 0.0:
		character.attack("Main", null, current_target)
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

# ===== PLAYER MOVEMENT ORDERS =====
# True while player-drawn orders are still outstanding. It revokes exactly ONE
# faculty: the right to decide where the body walks. Targeting, attacking,
# ability casting, alertness, outcry and every reaction keep running - the path
# takes the legs, not the brain. Same shape as the WAIT gate (hold_position)
# below, so the three locomotion primitives - _move_toward, navigate_to,
# _check_path_progress - stay the only doors a future AI state can walk through.
func _movement_locked() -> bool:
	return character != null and character.has_player_orders()


# Fear outranks orders. Panic/frightened are the two states whose WHOLE POINT is
# taking control away from the player, and they reach the body only through the
# gated locomotion primitives — so without this an unselected ally who broke
# would keep calmly walking its drawn path, which is worse than the bug this
# gate was added to fix. Tearing the orders down (rather than letting the AI
# fight the ActionQueue for the legs) also clears has_player_orders(), which
# releases the gate so the flee actually moves. Reuses the character's own
# teardown so the queued AoE ghosts go with it.
func _break_player_orders() -> void:
	if not _movement_locked():
		return
	if character.action_queue != null:
		character.action_queue.cancel_all()
	character._clear_tactical_path_if_executing()


# Explicit combat aim. Writes target_rotation directly (so it beats the path's
# set_path_facing, which PARKS instead of applying while a facing hold runs) and
# re-arms that hold every AI tick a target is held, so the next waypoint advance
# cannot snap the body back down the path. Never armed while a queued FACE is
# the running action: _is_action_complete(FACE) waits for `rotation` to reach
# ITS angle, so overriding it would stall the whole action queue.
const AI_AIM_FACING_HOLD: float = 0.35

func _aim_at(angle: float) -> void:
	if not _movement_locked():
		character.target_rotation = angle
		return
	var aq: ActionQueue = character.action_queue
	if aq != null and aq.current_action != null:
		if aq.current_action.type == ActionQueue.ActionType.FACE:
			return
	character.target_rotation = angle
	character.begin_facing_hold(AI_AIM_FACING_HOLD)


func _move_toward(target_pos: Vector2) -> void:
	# PLAYER ORDERS own the legs. Return WITHOUT touching is_moving /
	# target_position / target_rotation: the ActionQueue MOVE steers all three,
	# and a stray is_moving = false here reads as an arrival to
	# _is_action_complete(MOVE) and silently skips a waypoint.
	if _movement_locked():
		nav_path.clear()
		nav_path_index = 0
		return
	# WAIT command: a held ally stands ground — every AI locomotion path
	# (chase, approach, kite, strafe, wander, nav-following) funnels through
	# here, so one gate holds them all. They still face, target, and attack.
	if "hold_position" in character and character.hold_position:
		character.is_moving = false
		# drop any active path too: a held ally carrying a non-empty nav_path
		# made _check_path_progress replan (full A*) EVERY tick forever
		nav_path.clear()
		nav_path_index = 0
		var fdir = (target_pos - character.global_position).normalized()
		if fdir.length() > 0.1:
			character.target_rotation = fdir.angle() + PI / 2
		return
	character.target_position = target_pos
	character.is_moving = true
	var dir = (target_pos - character.global_position).normalized()
	if dir.length() > 0.1:
		character.target_rotation = dir.angle() + PI / 2


# Combat movement: straight-line steer while the walk line is clear (cheap,
# smooth), A* the moment a wall blocks it. CHASE/APPROACH used to steer
# blindly and grind enemies face-first into walls forever.
func _combat_move(target_pos: Vector2, delta: float) -> void:
	# Player orders own locomotion: skip the whole steer/repath layer, including
	# the cast-plant is_moving = false below (which would false-complete the
	# running MOVE). Callers already ran _try_cast_ability, so casting is
	# untouched - only the walking is.
	if _movement_locked():
		return
	# Plant feet while casting: chase used to keep converging on the target
	# through the whole windup (surround slots sit at 0.8×attack_range), which
	# walked casters into their own fireball's detonation. Standing still
	# during a windup also reads better than a walking cast.
	if character.ability_manager != null and character.ability_manager.is_casting():
		character.is_moving = false
		return
	if _walk_line_clear(target_pos):
		nav_path.clear()
		nav_path_index = 0
		_move_toward(target_pos)
		return
	_combat_repath_timer -= delta
	if _combat_repath_timer <= 0.0:
		_combat_repath_timer = 0.7
		var prev_anchor := _press_anchor
		_press_anchor = character.global_position
		navigate_to(target_pos)
		if nav_path.is_empty():
			# < 4px across the whole previous cycle = head-on, not a glide
			_press_stalled = prev_anchor != Vector2.INF \
				and prev_anchor.distance_to(character.global_position) < 4.0
			_steer_or_wait(target_pos)
		else:
			_press_anchor = Vector2.INF
			_press_stalled = false
		return
	if nav_path.is_empty():
		_steer_or_wait(target_pos)
		return
	_check_path_progress()


# Empty-nav_path arbitration for combat steering. Two very different reasons
# leave the path empty and they need opposite responses:
# - goal sealed/INF (A* returned nothing): keep pressure on the straight line
#   — wall-glide slides us along blockers — instead of re-flooding A* every
#   frame and standing frozen (the old empty-path retry).
# - a route EXISTS but its next leg crosses fire we're not standing in
#   (_advance_path's refusal): wait at the fire's edge. Straight-lining here
#   aimed the body at the target through whatever wall faced it and re-armed
#   is_moving every tick, so the mover's stuck escape could never stick —
#   the "chaser grinds into the burning building's wall forever" bug.
# The sealed-goal press itself is progress-gated (_press_stalled): once a full
# repath cycle moves us nowhere, the press is head-on and stands down until a
# repath finds a route again.
func _steer_or_wait(target_pos: Vector2) -> void:
	if _path_refused_on_hazard or _press_stalled:
		character.is_moving = false
		return
	_move_toward(target_pos)


# Retreat without wedging into walls: try straight back, then ±60°, then
# ±100°; take the first clear lane. Fully cornered -> hold ground (a kiting
# archer pinned against masonry should stand and fire, not sand the wall).
func _kite_away(dir_to_target: Vector2, dist_back: float) -> void:
	for ang in [PI, PI - 1.05, PI + 1.05, PI - 1.75, PI + 1.75]:
		var p := character.global_position + dir_to_target.rotated(ang) * dist_back
		var pt := GridManager.world_to_map(p)
		if GridManager.grid_costs.get(pt, INF) != INF \
				and not GridManager.is_hazard_tile(pt) \
				and _walk_line_clear(p):
			_move_toward(p)
			return


# Surround-slot sanitizer: steer points are target_pos + bearing*range and can
# land inside a wall / sealed interior. Snap to the nearest walkable tile, or
# fall back to the target itself (their tile is walkable — they stand on it).
func _reachable_slot(p: Vector2) -> Vector2:
	var t: Vector2i = GridManager.world_to_map(p)
	if (GridManager.grid_costs.get(t, INF) != INF or GridManager.door_pass.has(t)) \
			and not GridManager.is_hazard_tile(t):
		return p
	# nearest_walkable only reads grid_costs, and a burning tile keeps its
	# finite cost — it would hand a hazardous slot straight back. The
	# hazard-aware ring search resolves a slot beside a fire to safe ground
	# instead of collapsing every flanker onto the straight line to the target.
	var nt: Vector2i = GridManager.nearest_safe_tile(t, 3)
	if nt != Vector2i.MAX:
		return GridManager.map_to_world(nt)
	if current_target and is_instance_valid(current_target):
		return current_target.global_position
	return character.global_position


# True if every ~24px sample between us and target sits on a pathable tile
# (finite cost, or a pushable closed door via door_pass) AND every tile
# transition along the way is elevation-steppable — a scarp/deck edge between
# finite-cost tiles used to read as "clear", so combat steer never fell back
# to A* (whose per-step elevation routing finds the ramp) and ground the body
# against the cliff lip forever. Samples the centre line PLUS two lines
# offset by most of the body radius: a clear centre line used to steer the
# body's shoulder straight into jamb corners the tile test called clear.
# Doorways fail the offset lines -> A* takes over and threads the exact gap
# centre, which is the right division of labour.
func _walk_line_clear(target_pos: Vector2) -> bool:
	var dv := target_pos - character.global_position
	if dv.length() < 1.0:
		return true
	var side := Vector2(-dv.y, dv.x).normalized() * character._body_circle_radius() * 0.8
	var steps := int(dv.length() / 24.0) + 1
	for off in [Vector2.ZERO, side, -side]:
		var prev_t: Vector2i = GridManager.world_to_map(character.global_position + off)
		for i in range(1, steps + 1):
			var t: Vector2i = GridManager.world_to_map(character.global_position + off + dv * (float(i) / float(steps)))
			if GridManager.grid_costs.get(t, INF) == INF and not GridManager.door_pass.has(t):
				return false
			# damaging ground reads as blocked: straight-line combat steer used
			# to walk through fire whenever the line was geometrically clear —
			# failing here hands the leg to A*, whose hazard weights detour
			if GridManager.is_hazard_tile(t):
				return false
			if t != prev_t and not GridManager.can_step(prev_t, t):
				return false
			prev_t = t
	return true


# ===== HAZARD AVOIDANCE =====
# Route planning reads the tile map GridManager.hazard_costs (A* detour weights
# + is_hazard_tile gates in the steering helpers). The STANDING check below is
# stricter: it re-asks the fire sim for the exact cell under our feet, because
# a burning cell can straddle a tile border and damage us from a tile whose
# centroid never registered as hazardous.

var _hazard_escape_tile := Vector2i.MAX   # committed exit; MAX = not escaping
var _hazard_repath_cd: float = 0.0
var _hazard_search_cd: float = 0.0        # backoff after a failed exit search


# The fire sim under this character's map, or null (legacy tile maps, menus).
func _cell_fire():
	if game != null and ("surface_manager" in game) and game.surface_manager != null:
		var cf = game.surface_manager.cell_fire
		if cf != null and is_instance_valid(cf) and cf.active():
			return cf
	return null


func _standing_in_hazard() -> bool:
	if "on_roof" in character and character.on_roof:
		return false   # ground fire/fluids never reach roof-walkers
	if GridManager.is_hazard_tile(GridManager.world_to_map(character.global_position)):
		return true
	var cf = _cell_fire()
	# burning.is_empty() guard: cell_at is a ~9-bucket centroid scan, far too
	# dear to pay per NPC per frame on a map with no fire anywhere
	if cf != null and not cf.burning.is_empty():
		return cf.burning.has(cf.graph.cell_at(character.global_position))
	return false


# The standing test is CELL-exact, so exit validation must be too: a burning
# cell whose centroid maps into the neighbouring tile can own THIS tile's
# centre (nearest-centroid cells straddle tile borders). A tile-only test
# committed escapees to exits the standing check still flagged — locking them
# in the flames with the whole state machine suppressed.
func _tile_safe(tile: Vector2i) -> bool:
	if GridManager.is_hazard_tile(tile):
		return false
	var cf = _cell_fire()
	if cf != null and not cf.burning.is_empty():
		return not cf.burning.has(cf.graph.cell_at(GridManager.map_to_world(tile)))
	return true


# Nearest REACHABLE safe tile (bounded flood, same primitive wander uses — a
# safe tile across a wall is no exit). Two-tier: the cheap 5-step scan covers
# the common ember-underfoot case, and only when EVERYTHING in it burns do we
# pay a 10-step sweep — a room deeper than 5 steps, or fire spilling past the
# doorway, used to read as "sea of flame" while safe ground sat 6-8 steps out
# (door tiles can't be destinations, so a door k steps away needs k+1 reach).
# Vector2i.MAX when even the wide sweep finds nothing; both tiers sit behind
# _hazard_search_cd, so the worst case stays bounded.
func _find_escape_tile(from_tile: Vector2i) -> Vector2i:
	var best := _escape_scan(from_tile, 5)
	if best == Vector2i.MAX:
		best = _escape_scan(from_tile, 10)
	return best


func _escape_scan(from_tile: Vector2i, max_steps: int) -> Vector2i:
	var reach: Dictionary = GridManager.reachable_within(from_tile, max_steps,
		character.jump_height, character.jump_range, character.on_roof)
	var best := Vector2i.MAX
	var best_steps := 999
	for tile in reach:
		if not GridManager.would_walk(tile) or not _tile_safe(tile):
			continue
		if int(reach[tile]) < best_steps:
			best_steps = int(reach[tile])
			best = tile
	return best


func _process_hazard_escape(delta: float) -> bool:
	if current_state == AIState.DEAD or not character.is_alive():
		return false
	# A held ally stands where the player put them — even in fire. The WAIT
	# contract is "still face, target, and attack"; returning true here would
	# turn a tank holding a burning choke into a passive statue (and re-flood
	# A* every 0.4s for a move the hold gate discards anyway).
	if "hold_position" in character and character.hold_position:
		return false
	# Same contract for player-drawn orders: the path is the order, including
	# where it crosses fire. Returning true here would swallow the ENTIRE AI tick
	# (targeting, attacking, casting) for a move the gate discards anyway.
	if _movement_locked():
		return false
	_hazard_repath_cd -= delta
	_hazard_search_cd -= delta
	if not _standing_in_hazard():
		_hazard_escape_tile = Vector2i.MAX
		return false
	# Commit to one exit until we're out — re-rolling every tick dithers on
	# tile borders while the fire keeps stacking. Re-roll if the committed
	# exit stops being safe (fire spread onto it, or its covering cell burns).
	if _hazard_escape_tile == Vector2i.MAX or not _tile_safe(_hazard_escape_tile):
		if _hazard_search_cd > 0.0:
			return false   # recent search found nothing; don't re-flood per frame
		_hazard_escape_tile = _find_escape_tile(
			GridManager.world_to_map(character.global_position))
		if _hazard_escape_tile == Vector2i.MAX:
			_hazard_search_cd = 0.5
			return false   # sea of flame — let the state machine act instead
		# drop whatever route we were on — including the in-flight leg, which
		# may point deeper into the fire — the exit is the only destination now
		nav_path.clear()
		nav_path_index = 0
		character.is_moving = false
	if not character.is_moving and nav_path.is_empty():
		if _hazard_repath_cd <= 0.0:
			_hazard_repath_cd = 0.4
			navigate_to(GridManager.map_to_world(_hazard_escape_tile))
			if nav_path.is_empty():
				# A* refused (exit raced shut) — straight line; it's ≤5 tiles out
				_move_toward(GridManager.map_to_world(_hazard_escape_tile))
	else:
		_check_path_progress()
	return true


# ===== PATH FOLLOWING =====

func navigate_to(world_pos: Vector2) -> void:
	# Don't pay a full A* for a route the movement gate would discard.
	if _movement_locked():
		nav_path.clear()
		nav_path_index = 0
		return
	var start = GridManager.world_to_map(character.global_position)
	var end_tile = GridManager.world_to_map(world_pos)
	_path_refused_on_hazard = false
	nav_path = GridManager.find_path(start, end_tile, character.jump_height, character.jump_range, character.on_roof)
	nav_path_index = 0
	if not nav_path.is_empty():
		_advance_path()

func _advance_path() -> void:
	if nav_path_index >= nav_path.size():
		nav_path.clear()
		nav_path_index = 0
		return
	var next_tile = nav_path[nav_path_index]
	# Never FOLLOW a leg onto damaging ground unless we're already standing on
	# some (escape routes legitimately cross fire on the way out). A* only
	# routes through cores when the goal is in or behind the fire — chasing a
	# target who stands in flames used to dip in, get yanked out by the escape
	# override, and dip again, stacking a burn tick on every dip until death.
	# Waiting at the edge is the behaviour a player expects to see.
	if GridManager.is_hazard_tile(next_tile) and not _standing_in_hazard():
		nav_path.clear()
		nav_path_index = 0
		character.is_moving = false
		# tell _combat_move this was an edge-wait, not a sealed goal — its
		# empty-path fallback must NOT lean on the straight line here
		_path_refused_on_hazard = true
		return
	# door tiles route through the door's exact gap centre, not the tile centre
	var next_world: Vector2 = GridManager.door_gaps.get(next_tile, GridManager.map_to_world(next_tile))
	_move_toward(next_world)
	nav_path_index += 1

func _check_path_progress() -> void:
	# A nav_path left over from before the plan phase must not advance a leg
	# while the player's queue is driving (_advance_path can also write
	# is_moving = false on a hazard tile). Drop it; the AI re-plans on release.
	if _movement_locked():
		nav_path.clear()
		nav_path_index = 0
		return
	if nav_path.is_empty():
		return
	if not character.is_moving:
		# is_moving=false means the leg ENDED — but arrived and gave-up look
		# identical (the mover's wall-stuck escape emits a fake arrival).
		# Advancing on a give-up used to SKIP a waypoint and aim the next leg
		# deeper into the wall (the chunk-crawl). Not near the leg's target?
		# Replan from where we actually stand.
		var leg_i: int = nav_path_index - 1
		if leg_i >= 0 and leg_i < nav_path.size():
			var leg_tile: Vector2i = nav_path[leg_i]
			var leg_world: Vector2 = GridManager.door_gaps.get(leg_tile, GridManager.map_to_world(leg_tile))
			if character.global_position.distance_to(leg_world) > 24.0:
				var dest_tile: Vector2i = nav_path[nav_path.size() - 1]
				navigate_to(GridManager.map_to_world(dest_tile))
				return
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
	# Player-controlled characters (e.g. the world-map banner) shouldn't auto-
	# wander or auto-pick up — the human drives those decisions.
	if character.is_player_controlled:
		return
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

# Correct for the first time in Phase 4: reads Item.owner_faction (the old
# version read Godot's built-in Node.owner — always null for runtime items).
func is_item_owned_by_ally(item: Node) -> bool:
	if not ("owner_faction" in item) or item.owner_faction == "":
		return false
	return FactionDatabase.are_friendly(character.faction_id, item.owner_faction)

func can_reach_item(item: Node) -> bool:
	var start_tile = GridManager.world_to_map(character.global_position)
	var end_tile = GridManager.world_to_map(item.global_position)
	var test_path = GridManager.find_path(start_tile, end_tile, character.jump_height, character.jump_range, character.on_roof)
	return not test_path.is_empty()

func pickup_item(item: Node):
	if not is_instance_valid(item):
		return
	# Refusal, not report: guards don't loot their own barracks and allies
	# don't loot each other. (find_most_valuable_item_in_sight also filters,
	# but seek-goal paths can hand us an item directly.)
	if is_item_owned_by_ally(item):
		return
	# Law: instrumented now so enabling NPC crime later is a JSON edit
	# (laws.json applies_to). For player-faction summons this already
	# attributes the theft to the summoner today.
	CrimeManager.report(character, "take", CrimeManager.take_payload(item))

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
	# ONE bounded flood, not a full A* per candidate. This used to run up to 120
	# complete find_path() searches per re-roll, every WANDER_COOLDOWN_TIME, for
	# every idle NPC — and each candidate that walls had sealed off cost a whole
	# connected-component exhaustion, because A* only learns a goal is
	# unreachable by failing to find it. On structured maps that measured in the
	# hundreds of milliseconds in a single frame, which is exactly where the
	# "movement gets sluggish near buildings" hitch came from: _update_movement
	# runs off _process, so an AI stall freezes whoever the player is steering.
	#
	# The step budget is deliberately 2x the box radius: a target around a corner
	# still qualifies, but one that needs a long trek around a building no longer
	# does — which is better wander behaviour anyway, not just cheaper.
	var reach := GridManager.reachable_within(from_tile, WANDER_RANGE_TILES * 2,
		character.jump_height, character.jump_range, character.on_roof)
	var valid_tiles: Array[Vector2i] = []
	for tile: Vector2i in reach:
		var d: Vector2i = tile - from_tile
		if absi(d.x) > WANDER_RANGE_TILES or absi(d.y) > WANDER_RANGE_TILES:
			continue
		if is_tile_walkable(tile):
			valid_tiles.append(tile)

	if valid_tiles.is_empty():
		return Vector2i.MIN

	return valid_tiles[randi() % valid_tiles.size()]

func is_tile_walkable(tile: Vector2i) -> bool:
	if not GridManager.would_walk(tile):
		return false
	# wander/panic/flee destinations never land on damaging ground
	if GridManager.is_hazard_tile(tile):
		return false
	# Elevation gate ONLY for directly adjacent candidates: can_step is defined
	# for single-tile transitions. Distant flee/wander targets legitimately
	# differ by more than one step's elevation — A* (elevation-aware per step
	# via _get_neighbors) decides whether a graded route exists.
	var cur_t := GridManager.world_to_map(character.global_position)
	var dt := tile - cur_t
	if absi(dt.x) + absi(dt.y) == 1 and not GridManager.can_step(cur_t, tile):
		return false
	# Check if another character occupies this tile
	for c in game.characters_in_scene:
		if c != character and is_instance_valid(c):
			if GridManager.world_to_map(c.global_position) == tile:
				return false
	return true


# ===== ALERTNESS =====

func _update_alertness(delta: float) -> void:
	# Decay only after a grace period so brief stimuli don't immediately reset.
	if time_since_last_stimulus > ALERTNESS_DECAY_GRACE and alertness_value > 0.0:
		_set_alertness_value(alertness_value - ALERTNESS_DECAY_PER_SEC * delta)

	# Periodic ally alertness sync (only if I'm at all alert — no point waking
	# up an UNAWARE neighbor with my own UNAWARE).
	if ally_share_timer <= 0.0:
		ally_share_timer = ALLY_SHARE_INTERVAL
		if alertness_value > ALERTNESS_SUSPICIOUS_THRESHOLD * 0.5:
			_share_alertness_with_allies()


func _set_alertness_value(new_value: float) -> void:
	alertness_value = clamp(new_value, 0.0, ALERTNESS_MAX)
	var new_state := _classify_alertness(alertness_value)
	if new_state != current_alertness:
		var old = current_alertness
		current_alertness = new_state
		emit_signal("alertness_changed", old, new_state)


func _classify_alertness(v: float) -> Alertness:
	if v >= ALERTNESS_HOSTILE_THRESHOLD:
		return Alertness.HOSTILE
	if v >= ALERTNESS_SEARCHING_THRESHOLD:
		return Alertness.SEARCHING
	if v >= ALERTNESS_SUSPICIOUS_THRESHOLD:
		return Alertness.SUSPICIOUS
	# Below SUSPICIOUS threshold: still AT_EASE if we've never been woken.
	if is_at_ease:
		return Alertness.AT_EASE
	return Alertness.UNAWARE


# Public entry point for the AT_EASE wake triggers (damage, witness, stealth,
# loud sound). Clears the is_at_ease flag if set and bumps alertness to at
# least `target_value` (defaults to just-into-UNAWARE). Optional `location`
# updates last_heard_position so SEARCHING behavior can pick it up later if
# the meter climbs further.
func wake_from_at_ease(target_value: float = WAKE_FROM_AT_EASE_VALUE, location: Vector2 = Vector2.INF) -> void:
	if is_at_ease:
		is_at_ease = false
	if location != Vector2.INF:
		last_heard_position = location
		time_since_last_stimulus = 0.0
	if alertness_value < target_value:
		_set_alertness_value(target_value)
	else:
		# Force reclassification in case clearing is_at_ease alone changes state.
		_set_alertness_value(alertness_value)


# Called by HearingManager when this character hears a sound it should react
# to. Sound never confirms enemy identity — it caps below HOSTILE. If we are
# already HOSTILE with a known target, sounds also update where we expect
# that enemy to be.
func on_sound_heard(world_pos: Vector2, loudness: float, _source = null,
		channel: String = "ambient", payload: Dictionary = {}) -> void:
	if current_state == AIState.DEAD:
		return

	# Alarm channel: a scream for the guard. Handled BEFORE the AT_EASE
	# filter — a civilian hearing a murder scream is not filing it away as
	# city ambience. Arousal uses the normal sound math (1.35 scream × 55
	# gain = 74.25 → SEARCHING clear; ×0.45 per wall → SUSPICIOUS / nothing),
	# so walls degrade the town's response exactly like any other sound.
	if channel == "alarm":
		wake_from_at_ease(minf(loudness * ALERTNESS_SOUND_GAIN, ALERTNESS_SOUND_CAP), world_pos)
		# Enforcers act on the report; bystanders just startle.
		var law_faction: String = str(payload.get("law_faction", ""))
		if law_faction != "" and LawDatabase.enforces(character.faction_id, law_faction):
			CrimeManager.on_alarm_heard(character, payload)
			# Knowledge outlives arousal: alertness decays at 4/sec and this
			# guard stops actively searching in ~11 s, but he does not FORGET.
			# manhunt_target is per-listener (every enforcer who hears the
			# alarm remembers), cleared by settle or a pardon, never by time.
			var perp = payload.get("perp")
			if bool(payload.get("identified", false)) \
					and perp is ProceduralCharacter and is_instance_valid(perp):
				manhunt_target = perp
		return

	# AT_EASE civilians ignore ambient noise entirely. Only an unusually loud
	# sound (gunshot, explosion) cuts through — and then we wake to UNAWARE
	# rather than jumping straight to SEARCHING. Anything quieter is filed
	# away as "city ambience".
	if is_at_ease:
		if loudness < HearingManager.LOUD_SOUND_THRESHOLD:
			return
		wake_from_at_ease(WAKE_FROM_AT_EASE_VALUE, world_pos)
		return

	last_heard_position = world_pos
	time_since_last_stimulus = 0.0

	var gain := loudness * ALERTNESS_SOUND_GAIN
	if current_alertness == Alertness.HOSTILE:
		# Already alarmed and probably chasing — sounds inform position but
		# don't need to bump meter further.
		if current_target:
			last_known_target_pos = world_pos
		return

	var new_value: float = min(alertness_value + gain, ALERTNESS_SOUND_CAP)
	_set_alertness_value(max(alertness_value, new_value))


# ===== OUTCRY =====

## Called by CrimeManager's witness fan-out. The payload carries everything
## the eventual alarm needs (crime_id, identified, law_faction, delay, ...);
## this node only owns the fuse.
func begin_outcry(payload: Dictionary) -> void:
	if current_state == AIState.DEAD or not character.is_alive():
		return
	if not _can_still_cry_out():
		return
	if _outcry_timer > 0.0:
		# One fuse at a time. An identified sighting upgrades a pending
		# unidentified one; otherwise the first crime keeps the fuse.
		if bool(payload.get("identified", false)) and not bool(pending_outcry.get("identified", false)):
			pending_outcry = payload
		return
	pending_outcry = payload
	_outcry_total = maxf(float(payload.get("delay", 2.2)), 0.05)
	_outcry_timer = _outcry_total
	# The audible tell that a fuse just lit (pairs with the alertness bump).
	SfxManager.play("witness_huh", character.global_position, Vector2(0.9, 1.1))
	wake_from_at_ease(float(payload.get("witness_alert", 70.0)),
		payload.get("crime_pos", character.global_position))
	outcry_state_changed.emit(true, 0.0)

## Guard the FIRE, not the tick site: nothing sets AI_enabled = false on
## death and the DEAD match arm sits after the timer block, so without this
## a corpse would scream.
func _tick_outcry(delta: float) -> void:
	if _outcry_timer <= 0.0:
		return
	_outcry_timer -= delta
	var frac: float = 1.0 - (_outcry_timer / maxf(_outcry_total, 0.001))
	outcry_state_changed.emit(true, clampf(frac, 0.0, 1.0))
	if _outcry_timer > 0.0:
		return
	_outcry_timer = -1.0
	if not _can_still_cry_out():
		# Silenced in the window — the crime tracker hears about it (this is
		# how "no one raised the alarm" and the thrill grant resolve).
		CrimeManager.on_outcry_resolved(int(pending_outcry.get("crime_id", -1)), false)
		pending_outcry = {}
		outcry_state_changed.emit(false, 0.0)
		return
	CrimeManager.fire_outcry(character, pending_outcry)
	pending_outcry = {}
	outcry_state_changed.emit(false, 0.0)

# Phase 7: an enforcer finding a crime-stamped corpse starts its own outcry,
# unidentified — killing the witness buys time and anonymity, not absolution.
# One body alarms once (the discovered flag), and a crime whose alarm already
# escaped dedups away inside on_alarm_heard via the shared crime_id.
func _check_corpse_discovery() -> void:
	if current_state == AIState.DEAD or not character.is_alive():
		return
	for c in game.characters_in_scene:
		if not is_instance_valid(c) or c == character:
			continue
		if c.has_method("is_alive") and c.is_alive():
			continue
		if not c.has_meta("corpse_crime"):
			continue
		var info: Dictionary = c.get_meta("corpse_crime")
		if bool(info.get("discovered", false)):
			continue
		if not LawDatabase.enforces(character.faction_id, str(info.get("law_faction", ""))):
			continue
		if not is_in_line_of_sight(c.global_position, c.get_elevation()):
			continue
		info["discovered"] = true
		c.set_meta("corpse_crime", info)
		begin_outcry(CrimeManager.discovery_payload(c, character, info))
		return

func _can_still_cry_out() -> bool:
	if current_state == AIState.DEAD or not character.is_alive():
		return false
	var cm = character.get_node_or_null("ConditionManager")
	if cm != null:
		for cond_id in CrimeManager.outcry_cancel_conditions():
			if cm.has_condition(str(cond_id)):
				return false
	return true

func _share_alertness_with_allies() -> void:
	for other_char in game.characters_in_scene:
		if other_char == character or not is_instance_valid(other_char):
			continue
		if not other_char.has_method("is_alive") or not other_char.is_alive():
			continue
		if other_char.faction_id != character.faction_id:
			continue
		var other_ai = other_char.get_node_or_null("AI")
		if not other_ai:
			continue
		# LOS required — eye contact, not telepathy.
		if not is_in_line_of_sight(other_char.global_position, other_char.get_elevation()):
			continue
		if alertness_value > other_ai.alertness_value:
			# Transfer half the gap; tag last_heard_position so they look the
			# same direction we were looking. Sharing never pushes another AI
			# above the audio-only cap unless they already saw an enemy.
			var transfer: float = (alertness_value - float(other_ai.alertness_value)) * ALLY_SHARE_FACTOR
			var cap: float = ALERTNESS_SOUND_CAP if other_ai.current_alertness != Alertness.HOSTILE else ALERTNESS_MAX
			var new_val: float = min(float(other_ai.alertness_value) + transfer, cap)
			# Never redirect an ally who is already fighting someone: their own
			# target is better information than our second-hand rumour, and
			# _lose_target now reads this field to decide where to search.
			if other_ai.current_target == null:
				other_ai.last_heard_position = last_heard_position
			# `other_ai.time_since_last_stimulus = 0.0` used to sit here, and it
			# was a permanent decay holiday: this runs every ALLY_SHARE_INTERVAL
			# (0.75s) against ALERTNESS_DECAY_GRACE (1.5s), so the receiver's
			# decay branch (:1627) was unreachable and one alert fighter pinned
			# every ally in eyeshot at the sound cap (85) — above the SEARCHING
			# promotion threshold (60) and above the give-up floor (36) — for as
			# long as the fight lasted. That is a whole faction locked into
			# investigation. Sharing raises their meter; only their OWN stimuli
			# postpone their decay.
			other_ai._set_alertness_value(new_val)


# ===== SEARCHING STATE =====

var _search_goal_cache := Vector2.INF
var _search_goal_for := Vector2.INF   # the last_heard_position the cache serves
var _search_goal_cd: float = 0.0


# Where SEARCHING actually walks: the noise itself, or the nearest safe
# standoff when the noise sits on damaging ground; Vector2.INF when the whole
# 6-tile neighbourhood burns. The ring search only changes when the hazard
# map does, so it is cached on a 0.5s cadence instead of paid per frame.
func _search_goal(delta: float) -> Vector2:
	_search_goal_cd -= delta
	if _search_goal_cd > 0.0 and _search_goal_for == last_heard_position:
		return _search_goal_cache
	_search_goal_cd = 0.5
	_search_goal_for = last_heard_position
	var heard_tile := GridManager.world_to_map(last_heard_position)
	if not GridManager.is_hazard_tile(heard_tile):
		_search_goal_cache = last_heard_position
	else:
		var safe := GridManager.nearest_safe_tile(heard_tile, 6)
		_search_goal_cache = GridManager.map_to_world(safe) if safe != Vector2i.MAX \
			else Vector2.INF
	return _search_goal_cache


func _process_searching(delta: float) -> void:
	# Acquired a real target while heading over there — switch to combat.
	if current_target:
		_change_state(AIState.CHASE)
		return

	# Alertness decayed below the threshold — give up and return to normal.
	if alertness_value < ALERTNESS_SEARCHING_THRESHOLD * 0.6:
		_change_state(AIState.IDLE)
		return

	# Wall-clock backstop. Every alertness-derived exit above can be starved: an
	# unreachable goal keeps us in the en-route branch, which resets
	# _search_look_timer every tick and never reaches the arrived-scan bleed,
	# while any ongoing fight nearby keeps re-zeroing time_since_last_stimulus
	# so the meter never decays either. Without this, SEARCHING is terminal.
	if state_timer > SEARCH_GIVE_UP_SECONDS:
		_set_alertness_value(ALERTNESS_SEARCHING_THRESHOLD - 1.0)
		_change_state(AIState.IDLE)
		return

	# Never investigate INTO damaging ground: the noise position can sit inside
	# a fire (burning structures crackle, victims scream from the flames) and a
	# scout who walked all the way to it burned to death mid-scan in playtest.
	# Scan from the nearest safe tile instead — LOS from one tile out is just
	# as good, and alertness decay handles the rest.
	var goal := _search_goal(delta)
	# Vector2.INF: the noise is deep inside a blaze with no safe standoff
	# within 6 tiles. Fall through to the arrived-scan branch (slow turn,
	# alertness decay, stand down) instead of pathing in — A* would still
	# reach the tile (hazard is a weight, not a wall) and the escape override
	# would just eject us for another burn-collecting lap at the fire's edge.
	var dist: float = 0.0 if goal == Vector2.INF \
		else character.global_position.distance_to(goal)
	if dist > GridManager.TILE_SIZE * 0.75:
		# Still en route to the noise.
		_search_repath_cd -= delta
		if not character.is_moving and nav_path.is_empty():
			if _search_repath_cd <= 0.0:
				navigate_to(goal)
				# Unreachable noise (e.g. a roof-walker's footsteps land on a
				# tile a ground NPC can't path to): find_path returned empty and
				# we're not moving, so without a cooldown this re-floods a
				# full-map A* every frame. Back off and let alertness decay.
				if nav_path.is_empty():
					_search_repath_cd = 0.6
		else:
			_check_path_progress()
		_search_look_timer = 0.0
		return

	# Arrived — rotate slowly to scan, give LOS a chance to find the enemy.
	# Under player orders the body is walking and facing down the path: neither
	# the stop nor the scan-turn is ours to write. The alertness bleed below
	# still runs, so a searcher on a path stands down on the same schedule.
	if not _movement_locked():
		character.is_moving = false
		character.target_rotation += delta * 1.8  # slow continuous turn
	_search_look_timer += delta

	if _search_look_timer >= SEARCH_LOOK_AROUND_DURATION:
		# Found nothing — decay alertness faster and stand down.
		_search_look_timer = 0.0
		_set_alertness_value(alertness_value - 15.0)
		if alertness_value < ALERTNESS_SEARCHING_THRESHOLD:
			_change_state(AIState.IDLE)
