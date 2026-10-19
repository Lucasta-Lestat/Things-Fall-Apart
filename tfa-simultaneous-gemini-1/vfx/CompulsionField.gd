class_name CompulsionField
extends Node2D

# A persistent point of compulsion: something on the ground that periodically
# reaches out to everyone who can perceive it and tries to seize what they do.
#
# Shaped like vfx/FluidWell.gd and vfx/SilenceZone.gd -- self-parented,
# self-expiring, self-gated on PauseManager -- because those are the only
# persistent effect nodes in this project that survive a tactical pause
# correctly.
#
# Generic on three axes rather than authored per spell, the same way
# SilenceZone's `gain` is a float instead of a silence flag:
#   reach       -- how the audience is found (inside me / can see me)
#   affects     -- who in that audience qualifies (gender, creature type)
#   victim_rule -- what the compulsion is pointed at
# Bloodmusk, Persistent Distraction and the Erisian Apple are this one node
# with different strings.
#
# TWO THINGS ARE DELIBERATELY NOT HERE:
#
# 1. THE SAVING THROW. ConditionManager.apply_condition already rolls
#    `save_stat` at apply time and returns null when the bearer resists, so the
#    field just re-applies on every pulse and skips anyone who already holds the
#    condition. That loop -- fail, be afflicted, be immune-by-possession, expire,
#    become eligible, re-roll -- IS "periodically save or suffer", with no
#    bespoke save machinery. It is also why the condition templates carry no
#    `save_interval`: that would add a second, independent re-roll on top.
#
# 2. THE PARAMETER. "Attack THIS one" / "stare at THAT" lives on the AI node as
#    compel_victim / compel_focus, in the same shape as the existing
#    manhunt_target. It must NOT go in ConditionInstance.custom_data, which
#    to_dict() serialises verbatim into the save file -- a Node reference there
#    would be written to disk.

## Field footprint in world pixels. Used as the audience radius when
## `reach == "radius"`, and passed to the visual either way.
@export var radius: float = 256.0

## Seconds the field persists. Values <= 0 mean it never expires on its own.
@export var duration: float = 12.0

## How the audience is found: "radius" (anyone inside me) or "sight" (anyone
## with line of sight to me, out to reach_limit).
@export var reach: String = "radius"

## Hard cap on the sight sweep, in pixels. Without it, has_visual_los reaches
## 1440 * sight -- roughly 22 cells -- and a conjured trinket would compel half
## the map.
@export var reach_limit: float = 640.0

## Audience gender filter: "all", "female" or "male".
@export var affects: String = "all"

## Skip anything whose creature_type is not Humanoid. Beasts, undead and
## constructs are not moved by scent, idols or vanity.
@export var affects_humanoid_only: bool = true

## Seconds between audience sweeps -- i.e. how often an unafflicted onlooker
## gets to roll again.
@export var pulse_interval: float = 3.0

## Condition applied to those who fail: "incited" or "transfixed".
@export var condition_id: String = "incited"

## Duration override for that condition. -2.0 keeps the template's own.
@export var condition_duration: float = -2.0

## Who an incited victim turns on: "same_gender" (nearest living creature
## sharing their gender), "cohort_peer" (nearest other qualifying onlooker) or
## "none" (transfixed, which points at the field itself).
@export var victim_rule: String = "same_gender"

## How far to look for a victim under "same_gender", in pixels.
@export var victim_search_radius: float = 512.0

## Optional Node2D scene spawned as a child for the field's lifetime.
@export var visual_scene_path: String = ""

## Optional texture drawn at the field's centre -- the idol, the apple. Drawn by
## this node rather than spawned as an Item on purpose: a real Item would be
## lootable, targetable, edible, forced visible/invisible by party line of sight
## every frame, and resurrected from the save on every map revisit.
@export var sprite_path: String = ""

## On-screen WIDTH of that prop in pixels, mirroring the `base_width` convention
## data/Items.json uses for dropped items. Source art is authored at whatever
## resolution the generator produced (the idol is 449x640), so without this the
## prop draws at native size and swallows the screen. 0 keeps native size.
@export var sprite_width: float = 0.0

var _age: float = 0.0
var _pulse_accum: float = 0.0
var _built: bool = false
var _visual: Node2D = null
var _sprite: Sprite2D = null


func _ready() -> void:
	# Ground layer, under characters, like SilenceZone.
	z_index = -1
	# Pulse on the first unpaused frame rather than pulse_interval seconds in.
	_pulse_accum = pulse_interval


func _process(delta: float) -> void:
	# Game.gd sets PROCESS_MODE_ALWAYS on the Game root and process_mode is
	# INHERITED, so get_tree().paused freezes nothing parented under Game. See
	# FluidWell._process for the long version. A 30-second idol that kept
	# pulsing through the tactical planner would also expire behind the
	# player's back.
	if PauseManager.is_paused:
		return

	if not _built:
		_build()

	_age += delta
	if duration > 0.0 and _age >= duration:
		queue_free()
		return

	_pulse_accum += delta
	if _pulse_accum < pulse_interval:
		return
	_pulse_accum = 0.0
	_pulse()


# Deferred out of _ready(). AbilityEffect parents this node before positioning
# it (the documented order), so global_position is still (0, 0) during _ready
# and a sweep run there would measure from the map origin.
func _build() -> void:
	_built = true
	_spawn_sprite()
	_spawn_visual()


func _spawn_sprite() -> void:
	if sprite_path.is_empty() or not ResourceLoader.exists(sprite_path):
		return
	var tex: Texture2D = load(sprite_path) as Texture2D
	if tex == null:
		return
	_sprite = Sprite2D.new()
	_sprite.texture = tex
	if sprite_width > 0.0:
		var native_w: float = float(tex.get_width())
		if native_w > 0.0:
			_sprite.scale = Vector2.ONE * (sprite_width / native_w)
	add_child(_sprite)
	# Absolute, not relative: this node sits at z_index -1 so its glow washes the
	# ground, but the prop itself is an object standing ON that ground and has to
	# draw above it. z_index is inherited by children, so leaving it relative
	# would bury the idol under its own light.
	_sprite.z_as_relative = false
	_sprite.z_index = 0


func _spawn_visual() -> void:
	if visual_scene_path.is_empty() or not ResourceLoader.exists(visual_scene_path):
		return
	var packed: PackedScene = load(visual_scene_path) as PackedScene
	if packed == null:
		return
	var inst: Node = packed.instantiate()
	if not (inst is Node2D):
		push_warning("CompulsionField: visual '%s' must have a Node2D root." % visual_scene_path)
		inst.queue_free()
		return
	_visual = inst as Node2D
	add_child(_visual)
	_visual.position = Vector2.ZERO
	if _visual.has_method("play_field"):
		_visual.call("play_field", radius, duration)
	elif _visual.has_method("play"):
		var base: float = 256.0
		if "vfx_base_radius" in _visual:
			base = float(_visual.vfx_base_radius)
		_visual.call("play", radius / maxf(base, 1.0))


# One sweep: find who can perceive the field, roll them, point the survivors.
func _pulse() -> void:
	var pool: Array = audience()
	for subject in pool:
		var cm = subject.get_node_or_null("ConditionManager")
		if cm == null:
			continue
		# Already gripped -- their clock is running, so they do not re-roll. This
		# possession gate is what turns a fixed-interval re-application into a
		# periodic saving throw.
		if cm.has_active_condition(condition_id):
			continue
		# THE SAVE happens in here. A null return means they resisted.
		var inst = cm.apply_condition(condition_id, self, 1, condition_duration)
		if inst == null:
			continue
		var ai = subject.get_node_or_null("AI")
		if ai == null:
			continue
		if victim_rule == "none":
			ai.compel_focus = self
			continue
		var victim = _pick_victim(subject, pool if victim_rule == "cohort_peer" else _nearby_living(subject))
		if victim == null:
			# Nobody to turn on -- do not leave them wearing a compulsion that
			# points at nothing, or _apply_compulsion would just clear it again.
			cm.remove_condition(condition_id)
			continue
		ai.compel_victim = victim


## Everyone who currently perceives the field and qualifies for its effect.
func audience() -> Array:
	var out: Array = []
	var game = get_tree().current_scene
	# Duck-typed the way ai.gd guards it, so headless harnesses without a real
	# Game node do not explode.
	if game == null or not ("characters_in_scene" in game):
		return out
	var r2: float = radius * radius
	for c in game.characters_in_scene:
		if not is_instance_valid(c):
			continue
		# Corpses stay in characters_in_scene by design (CrimeManager depends on
		# it), so every sweep has to filter them itself.
		if not c.has_method("is_alive") or not c.is_alive():
			continue
		if reach == "sight":
			if global_position.distance_squared_to(c.global_position) > reach_limit * reach_limit:
				continue
			if not CrimeManager.has_visual_los(c, global_position, NAN):
				continue
		elif global_position.distance_squared_to(c.global_position) > r2:
			continue
		if not _qualifies(c):
			continue
		out.append(c)
	return out


func _qualifies(c) -> bool:
	if not _is_humanoid(c):
		return false
	if affects == "all":
		return true
	return String(c.gender) == affects


# begins_with, not ==: races.json carries compound values like "Humanoid, Undead"
# and "Humanoid, Fey", and an == test silently drops all of them.
func _is_humanoid(c) -> bool:
	if not affects_humanoid_only:
		return true
	return String(c.creature_type).begins_with("Humanoid")


# Living creatures near `subject`, for the same-gender victim search. Deliberately
# NOT restricted to the field's own audience: a musked guard turns on the nearest
# man he can find, whether or not that man is standing in the cloud too.
func _nearby_living(subject) -> Array:
	var out: Array = []
	var game = get_tree().current_scene
	if game == null or not ("characters_in_scene" in game):
		return out
	var r2: float = victim_search_radius * victim_search_radius
	for c in game.characters_in_scene:
		if not is_instance_valid(c) or c == subject:
			continue
		if not c.has_method("is_alive") or not c.is_alive():
			continue
		# The humanoid gate applies to VICTIMS as well as to the audience. Every
		# spawn now carries a rolled gender, wildlife included, so without this a
		# musked guard would happily pick the nearest wolf as "the nearest male"
		# and the spell would read as random rather than as same-sex rivalry.
		if not _is_humanoid(c):
			continue
		if subject.global_position.distance_squared_to(c.global_position) > r2:
			continue
		out.append(c)
	return out


func _pick_victim(subject, pool: Array):
	var best = null
	var best_d: float = INF
	for other in pool:
		if other == subject or not is_instance_valid(other):
			continue
		if victim_rule == "same_gender" and String(other.gender) != String(subject.gender):
			continue
		var d: float = subject.global_position.distance_squared_to(other.global_position)
		if d < best_d:
			best_d = d
			best = other
	return best
