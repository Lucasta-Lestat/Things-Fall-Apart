# AbilityTargeting.gd
# Handles AoE targeting visualization and input
extends Node2D

enum TargetShape { NONE, CIRCLE, RECTANGLE, LINE, CONE, CHARACTERS }

signal targeting_started(hand: String, ability: Dictionary)
signal targeting_confirmed(hand: String, ability: Dictionary, target_position: Vector2)
signal targeting_cancelled(hand: String)

# Current targeting state
var is_targeting: bool = false
var current_hand: String = "Main"
var current_ability: Dictionary = {}
# Ability.Intent for the session in progress. Colours the LIVE preview; the queued
# ghosts carry their own copy because they outlive the session that made them.
var current_intent: int = Ability.Intent.NEUTRAL
var target_position: Vector2 = Vector2.ZERO

# Visual indicators
var circle_indicator: Node2D = null
var rectangle_indicator: Node2D = null
var line_indicator: Node2D = null
var cone_indicator: Node2D = null
var range_indicator: Node2D = null  # Outline ring of range_limit around the cast origin

# Projectile AoEs (Fireball...) burst on the first body or wall in their path.
# While targeting one, this is where it would burst (Vector2.INF = clear path);
# the live preview is drawn there, but confirm_targeting keeps the aimed point.
var _projectile_impact: Vector2 = Vector2.INF
# Matches Projectile.collision_radius and the default spawn offset in
# ProceduralCharacter._spawn_projectile (visuals.projectile_spawn_offset).
const PROJECTILE_PREVIEW_RADIUS := 4.0
const PROJECTILE_SPAWN_OFFSET := Vector2(0, -20)

# Targeting parameters (set from ability data)
var target_shape: TargetShape = TargetShape.NONE
var circle_radius: float = 50.0
var rectangle_size: Vector2 = Vector2(100, 50)
var rectangle_rotation: float = 0.0  # In radians
var line_range: float = 500.0
var line_width: float = 30.0
var caster_position: Vector2 = Vector2.ZERO
var cone_radius: float = 150.0
var cone_angle: float = 45.0  # Degrees

# Character-targeting state
var target_count: int = 1
var target_filter: String = "any"  # "any" | "allies" | "enemies"
var selected_targets: Array = []
var target_highlights: Array[Node2D] = []
var count_label: Label = null
var count_label_layer: CanvasLayer = null

# When true, the targeting indicator is anchored to the caster (self-targeted abilities)
# instead of following the mouse cursor
var lock_to_caster: bool = false

# The ability's targeting.range, measured from _origin_pos(); 0 = unlimited.
# Circle and rectangle aim points stop on the ring, line ends are clamped to
# it, and character picks beyond it are refused.
var range_limit: float = 0.0

# When set (not INF), the preview's origin (line/cone start, self/circle anchor)
# is this world position — the planned action-node position — instead of the live
# character position. Cleared on end_targeting. The ability still EXECUTES from
# the body's real position; this only corrects the planning-phase preview.
var caster_origin_override: Vector2 = Vector2.INF

# Visual settings
const INDICATOR_COLOR = Color(1, 1, 1, 0.5)  # Semi-transparent white
const INDICATOR_COLOR_VALID = Color(0, 1, 0, 0.5)  # Green when valid
const INDICATOR_COLOR_INVALID = Color(1, 0, 0, 0.5)  # Red when invalid
const INDICATOR_BORDER_WIDTH = 2.0

# Queued ability indicators (persist until executed)
var queued_indicators: Array[Node2D] = []

# --- Knockback landing preview ----------------------------------------------
# While targeting an ability that shoves, show every affected body's arrow and
# the ring it will end up in, so the player can aim the DISPLACEMENT rather than
# just the blast. Empty dict = this ability doesn't knock back and nothing draws.
var _knockback_effect: Dictionary = {}
# current_ability parsed once per targeting session. The hit set comes from the
# caster's own _find_targets_in_area so the ghosts match what will actually be
# hit — including the nested-vs-flattened targeting split (the flat dict has no
# "single" shape), which is why this is an Ability and not the raw dictionary.
var _preview_ability: Ability = null
var _knockback_layer: KnockbackPreviewDrawer = null
# _find_targets_in_area sweeps every character, item and structure in the scene,
# so recompute on cursor movement rather than unconditionally each frame.
var _knockback_last_pos: Vector2 = Vector2.INF
const KNOCKBACK_PREVIEW_RESOLUTION := 3.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	z_index = 50  # Above ground, below UI
	_create_indicators()
	# Electric abilities: tiles the current would flood (reads this node only)
	add_child(preload("res://Abilities/ElectrifyPreview.gd").new())

func _process(_delta: float) -> void:
	if is_targeting:
		if lock_to_caster:
			# Self-targeted: anchor the indicator to the caster's (possibly moving) position
			caster_position = _origin_pos()
			target_position = caster_position
		else:
			# Update target position to mouse, held inside the range ring
			target_position = _get_mouse_world_position()
			if _clamps_point():
				target_position = AbilityManager.clamp_point_to_range(_origin_pos(), target_position, range_limit)

		# For line and cone, keep caster_position in sync with the character
		if target_shape == TargetShape.LINE or target_shape == TargetShape.CONE:
			caster_position = _origin_pos()

		if target_shape == TargetShape.CHARACTERS:
			caster_position = _origin_pos()
			_update_character_targeting_visuals()
		else:
			_update_active_indicator()
		_update_range_ring()

		_update_knockback_preview()
	elif lock_to_caster and circle_indicator != null and circle_indicator.visible:
		# Self-targeted previews used to ride the caster for free by being parented
		# to it. Now that the indicators are top_level (world space) that no longer
		# happens automatically, and a self AoE resolves at the caster's EXECUTION
		# position — so keep re-pinning it to the body for the short window between
		# an immediate confirm (which drops is_targeting but leaves the preview up)
		# and the ability actually landing.
		circle_indicator.global_position = _origin_pos()

## Whether the aim point itself is held inside range_limit (circle and
## rectangle casts aimed at a point; lines clamp their end separately, cones
## reach their radius, and self casts sit on the caster).
func _clamps_point() -> bool:
	return not lock_to_caster and range_limit > 0.0 and target_shape in [TargetShape.CIRCLE, TargetShape.RECTANGLE]

## Keep the range ring on the cast origin (the live caster, or the planned
## path node) at range_limit.
func _update_range_ring() -> void:
	if range_indicator == null or not range_indicator.visible:
		return
	range_indicator.global_position = _origin_pos()
	var range_drawer = range_indicator.get_child(0) as CircleDrawer
	if range_drawer and range_drawer.radius != range_limit:
		range_drawer.radius = range_limit
		range_drawer.queue_redraw()

func _create_indicators() -> void:
	"""Create the targeting indicator nodes"""
	# Circle indicator — top_level, like line/cone and the queued ghosts, so the
	# preview lives in WORLD space. This node hangs off the caster, and the caster
	# walks AND rotates: a parented indicator is only re-pinned inside _process
	# while is_targeting, and the immediate/unplanned cast clears is_targeting while
	# KEEPING the preview visible until the ability lands
	# (ProceduralCharacter._confirm_ability_target). From that moment the AoE was
	# dragged along and swung through an arc by the moving body — the "jerk". The
	# planned path never showed it because it swaps in a top_level queued ghost.
	# z is absolute: under the knockback arrows (160), over the path markers
	# (PathDrawer.Z_MARKERS 152) and the queued ghosts (49). 155 rather than the
	# old 55 so the LIVE preview clears the unexplored-fog quad
	# (UnexploredFogLayer.FOG_Z 140) — aiming into never-seen territory is
	# routine and the validity colors must survive it (VFX at 100 no longer
	# covers the live preview; accepted, the fog has to sit above VFX anyway).
	# A top_level CanvasItem is reparented to the canvas root in
	# the RenderingServer, so it would otherwise fall to z 0 and draw under bodies.
	circle_indicator = Node2D.new()
	circle_indicator.name = "CircleIndicator"
	circle_indicator.top_level = true
	circle_indicator.z_as_relative = false
	circle_indicator.z_index = 155
	var circle_drawer = CircleDrawer.new()
	circle_indicator.add_child(circle_drawer)
	circle_indicator.visible = false
	add_child(circle_indicator)

	# Rectangle indicator — top_level for the same reason, and it additionally makes
	# the preview agree with the AREA THAT ACTUALLY GETS HIT: the resolver
	# (ProceduralCharacter._find_targets_in_area, shape "rectangle") is world-axis
	# aligned — `abs(diff.x) <= half_size.x and abs(diff.y) <= half_size.y` — while a
	# caster-parented indicator drew the box rotated by the caster's facing.
	# (`rectangle_rotation` is declared but never assigned anywhere, so line 171 was
	# only ever writing 0.0 into a LOCAL rotation.)
	rectangle_indicator = Node2D.new()
	rectangle_indicator.name = "RectangleIndicator"
	rectangle_indicator.top_level = true
	rectangle_indicator.z_as_relative = false
	rectangle_indicator.z_index = 155  # matches CircleIndicator; above fog (140)
	var rect_drawer = RectangleDrawer.new()
	rectangle_indicator.add_child(rect_drawer)
	rectangle_indicator.visible = false
	add_child(rectangle_indicator)

	# Line indicator — top_level so it doesn't inherit character rotation
	line_indicator = Node2D.new()
	line_indicator.name = "LineIndicator"
	line_indicator.top_level = true
	var line_drawer = LineDrawer.new()
	line_indicator.add_child(line_drawer)
	line_indicator.visible = false
	add_child(line_indicator)

	# Cone indicator — top_level so it doesn't inherit character rotation
	cone_indicator = Node2D.new()
	cone_indicator.name = "ConeIndicator"
	cone_indicator.top_level = true
	var cone_drawer = ConeDrawer.new()
	cone_indicator.add_child(cone_drawer)
	cone_indicator.visible = false
	add_child(cone_indicator)

	# Range ring around the cast origin — outline only, it can be large. Same
	# absolute z as the live AoE preview, so it reads over the unexplored fog.
	range_indicator = Node2D.new()
	range_indicator.name = "RangeIndicator"
	range_indicator.top_level = true
	range_indicator.z_as_relative = false
	range_indicator.z_index = 155
	var range_drawer = CircleDrawer.new()
	range_drawer.draw_fill = false
	range_drawer.num_segments = 64
	range_indicator.add_child(range_drawer)
	range_indicator.visible = false
	add_child(range_indicator)

	# Knockback landing preview — top_level and pinned to the origin, so its
	# local space IS world space and the arrows don't swing with the caster's
	# facing. Drawn above the AoE fill so the shove reads over the blast.
	_knockback_layer = KnockbackPreviewDrawer.new()
	_knockback_layer.name = "KnockbackPreview"
	_knockback_layer.top_level = true
	# Absolute, not inherited: this node is two levels below a character root, and
	# the whole point is being above every body it draws an arrow over. 160 clears
	# characters (5), this node's own AoE fill (155), and the unexplored-fog quad
	# (140) — the shove preview must stay readable when aimed into fog.
	_knockback_layer.z_as_relative = false
	_knockback_layer.z_index = 160
	_knockback_layer.visible = false
	add_child(_knockback_layer)
	_knockback_layer.global_position = Vector2.ZERO

func _update_active_indicator() -> void:
	"""Update the position and appearance of the active indicator"""
	#print("target_shape is : ", target_shape)
	match target_shape:
		TargetShape.CIRCLE:
			_projectile_impact = _find_projectile_impact()
			var stopped_short := _projectile_impact != Vector2.INF
			circle_indicator.global_position = _projectile_impact if stopped_short else target_position
			circle_indicator.visible = true
			rectangle_indicator.visible = false
			line_indicator.visible = false
			cone_indicator.visible = false
			var drawer = circle_indicator.get_child(0) as CircleDrawer
			if drawer:
				drawer.radius = circle_radius
				# Aiming at a body also stops at its edge; only tint when the
				# burst no longer covers the point aimed at.
				drawer.is_blocked = stopped_short and _projectile_impact.distance_to(target_position) > circle_radius
				drawer.queue_redraw()
		
		TargetShape.RECTANGLE:
			rectangle_indicator.global_position = target_position
			rectangle_indicator.rotation = rectangle_rotation
			rectangle_indicator.visible = true
			circle_indicator.visible = false
			line_indicator.visible = false
			cone_indicator.visible = false
			var drawer = rectangle_indicator.get_child(0) as RectangleDrawer
			if drawer:
				drawer.rect_size = rectangle_size
				drawer.queue_redraw()
		
		TargetShape.LINE:
			# Line from caster to mouse, clamped to range
			line_indicator.global_position = caster_position
			var direction = target_position - caster_position
			var dist = direction.length()
			var clamped_end = target_position
			if dist > line_range:
				clamped_end = caster_position + direction.normalized() * line_range
			var drawer = line_indicator.get_child(0) as LineDrawer
			if drawer:
				drawer.line_end = clamped_end - caster_position  # Local coords
				drawer.line_width = line_width
				drawer.queue_redraw()
			line_indicator.visible = true
			circle_indicator.visible = false
			rectangle_indicator.visible = false
			cone_indicator.visible = false

		TargetShape.CONE:
			# Cone from caster toward mouse
			cone_indicator.global_position = caster_position
			var cone_dir = target_position - caster_position
			cone_indicator.rotation = cone_dir.angle()
			var drawer_c = cone_indicator.get_child(0) as ConeDrawer
			if drawer_c:
				drawer_c.cone_radius = cone_radius
				drawer_c.cone_angle_deg = cone_angle
				drawer_c.queue_redraw()
			cone_indicator.visible = true
			circle_indicator.visible = false
			rectangle_indicator.visible = false
			line_indicator.visible = false

		TargetShape.NONE:
			circle_indicator.visible = false
			rectangle_indicator.visible = false
			line_indicator.visible = false
			cone_indicator.visible = false

func _get_mouse_world_position() -> Vector2:
	"""Get mouse position in world coordinates"""
	return get_global_mouse_position()

func _origin_pos() -> Vector2:
	# Preview origin: the planned node position when overridden, else the live caster.
	if caster_origin_override != Vector2.INF:
		return caster_origin_override
	return get_parent().global_position if get_parent() else caster_position

func _find_projectile_impact() -> Vector2:
	"""Where a projectile AoE aimed at target_position would hit something first
	(the same sweep Projectile does with move_and_collide), or Vector2.INF if
	its path is clear or the ability has no projectile."""
	var visuals = current_ability.get("visuals", {})
	if lock_to_caster or not (visuals is Dictionary) or String(visuals.get("projectile", "")) == "":
		return Vector2.INF
	var space = get_world_2d().direct_space_state
	if space == null:
		return Vector2.INF
	var offset = visuals.get("projectile_spawn_offset", PROJECTILE_SPAWN_OFFSET)
	var from: Vector2 = _origin_pos() + (offset if offset is Vector2 else PROJECTILE_SPAWN_OFFSET)
	var motion: Vector2 = target_position - from
	if motion.length() < 1.0:
		return Vector2.INF
	var shape := CircleShape2D.new()
	shape.radius = PROJECTILE_PREVIEW_RADIUS
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = shape
	query.transform = Transform2D(0.0, from)
	query.motion = motion
	query.collision_mask = CollisionLayers.PROJECTILE_HIT_MASK
	var caster = get_parent()
	var excluded: Array[RID] = []
	if caster is CollisionObject2D:
		excluded.append(caster.get_rid())
	# An NPC the party can't see because it is Invisible doesn't stop the
	# preview: a burst drawn on its body would give it away (the real
	# projectile still hits it).
	var game_node = caster.get("game") if caster != null and caster.has_method("_invisible_to_party") else null
	if game_node != null and is_instance_valid(game_node):
		for c in game_node.characters_in_scene:
			if is_instance_valid(c) and c is CollisionObject2D and caster._invisible_to_party(c):
				excluded.append(c.get_rid())
	query.exclude = excluded
	var fractions: PackedFloat32Array = space.cast_motion(query)
	if fractions.size() < 2 or fractions[1] >= 1.0:
		return Vector2.INF
	return from + motion * fractions[1]

## The character the player confirmed on top of, or null over bare ground.
## Delegates to the caster's canonical probe so designation means the same thing
## here as it does in tactical planning.
func _designated_character_at(world_pos: Vector2):
	var caster = get_parent()
	if caster == null or not caster.has_method("_find_character_at"):
		return null
	return caster._find_character_at(world_pos)

## True for abilities that affect exactly one character rather than an area.
##
## Reads the NESTED targeting block on purpose. AbilityShape flattens shape names
## into a top-level `target_shape`, but its enum has no "single" member, so the
## flattened value collapses to "none" and cannot tell the two apart. The nested
## block is the authored source of truth.
func _is_single_target_ability() -> bool:
	var raw_targeting: Dictionary = current_ability.get("targeting", {})
	# Self-targeted abilities resolve on the caster no matter where the cursor
	# was, so they can never be bound to a designation. This guard has to sit
	# ABOVE the shape checks: five abilities (bide, test_animal_magnetism, rain,
	# acid_rain, freezing_rain) are authored {"type":"self","shape":"single"},
	# and binding one of those to a bystander would hand them the buff and leave
	# the caster with nothing — an explicit `targets` array bypasses
	# _find_targets_in_area's `type == "self" -> [self]` override.
	if String(raw_targeting.get("type", "")) == "self":
		return false
	var raw_shape := String(raw_targeting.get("shape", "none"))
	# Unshaped abilities have no area to speak of, so a designation is the only
	# sensible reading of the click.
	return raw_shape == "single" or raw_shape == "none"


## Whether a designation would actually be honored for this ability. Used to
## avoid recording an anchor that execution will ignore — a stored-but-unused
## anchor makes the planning UI draw a tracking leash for an ability that will
## detonate at a fixed point.
func _ability_follows_anchor() -> bool:
	return AbilityManager.targeting_follows_anchor(
		current_ability.get("targeting", {}),
		current_ability.get("visuals", {}))

# ===== PUBLIC API =====

func start_targeting(hand: String, ability: Dictionary, mouse_pos:Vector2, origin_override: Vector2 = Vector2.INF) -> void:

	"""Begin targeting for an ability"""
	print("start_targeting called for ability ", ability.display_name)
	is_targeting = true
	current_hand = hand
	current_ability = ability
	caster_origin_override = origin_override

	# Intent drives the preview's colour for this whole session. It is a pure
	# function of the ability dictionary, which cannot change while targeting is
	# live, so it is resolved once here instead of on every _draw. The four
	# drawers are built once in _create_indicators and reused for every ability,
	# so the colour has to be re-stamped per session rather than set at build time
	# — otherwise the second ability you aim inherits the first one's colour.
	current_intent = Ability.classify_intent(ability)
	for indicator in [circle_indicator, rectangle_indicator, line_indicator, cone_indicator]:
		if indicator == null or indicator.get_child_count() == 0:
			continue
		var drawer = indicator.get_child(0)
		if "intent" in drawer:
			drawer.intent = current_intent
			drawer.queue_redraw()

	# Self-targeted abilities anchor the AoE preview to the caster instead of the cursor
	var target_type_str = ability.get("target_type", "point")
	lock_to_caster = (target_type_str == "self")
	range_limit = float(ability.get("range", 0.0))

	if lock_to_caster:
		caster_position = _origin_pos()
		target_position = caster_position
	else:
		# Set initial position immediately so it doesn't jump from (0,0)
		target_position = mouse_pos

	# Set shape from ability data
	var shape_str = ability.get("target_shape", "none")
	print("ability shape for this ability: ", shape_str)
	match shape_str:
		"circle":
			target_shape = TargetShape.CIRCLE
			circle_radius = ability.get("radius", 50.0)
		"rectangle":
			target_shape = TargetShape.RECTANGLE
			rectangle_size = ability.get("size", Vector2(100, 50))
		"line":
			target_shape = TargetShape.LINE
			line_range = ability.get("range", 500.0)
			var size_data = ability.get("size", Vector2(500, 30))
			line_width = size_data.y if size_data is Vector2 else float(size_data.get("y", 30))
			caster_position = _origin_pos()
		"cone":
			target_shape = TargetShape.CONE
			cone_radius = ability.get("radius", 150.0)
			cone_angle = ability.get("angle", 45.0)
			caster_position = _origin_pos()
		"characters":
			target_shape = TargetShape.CHARACTERS
			target_count = int(ability.get("target_count", 1))
			target_filter = String(ability.get("target_filter", "any"))
			caster_position = _origin_pos()
			selected_targets.clear()
			_clear_target_highlights()
			_ensure_count_label()
			count_label.visible = true
		_:
			target_shape = TargetShape.NONE

	# Knockback preview: parse once per session, then refresh as the cursor moves.
	_knockback_effect = _find_knockback_effect(ability)
	_preview_ability = Ability.from_dict(ability) if not _knockback_effect.is_empty() else null
	_knockback_last_pos = Vector2.INF

	_projectile_impact = Vector2.INF
	if _clamps_point():
		target_position = AbilityManager.clamp_point_to_range(_origin_pos(), target_position, range_limit)
	# Every ranged pick shows its reach (cones reach their radius; self casts
	# have none). Single-target abilities (Heal, Chasten...) flatten to NONE but
	# designate a character, which confirm_targeting range-checks.
	range_indicator.visible = range_limit > 0.0 and not lock_to_caster \
		and (target_shape in [TargetShape.CIRCLE, TargetShape.RECTANGLE, TargetShape.LINE, TargetShape.CHARACTERS] \
			or (target_shape == TargetShape.NONE and _is_single_target_ability()))
	_update_range_ring()

	# Force an immediate update to ensure visual appears this frame
	if target_shape == TargetShape.CHARACTERS:
		_update_character_targeting_visuals()
	else:
		_update_active_indicator()
	_update_knockback_preview()

	emit_signal("targeting_started", hand, ability)

func confirm_targeting() -> Dictionary:
	"""Confirm the current target and return targeting data"""
	if not is_targeting:
		return {}

	if target_shape == TargetShape.CHARACTERS:
		if selected_targets.size() != target_count:
			return {}  # Not yet ready to confirm
		var centroid = Vector2.ZERO
		for t in selected_targets:
			if is_instance_valid(t):
				centroid += t.global_position
		if not selected_targets.is_empty():
			centroid /= selected_targets.size()
		range_indicator.visible = false
		var result_chars = {
			"hand": current_hand,
			"ability": current_ability,
			"position": centroid,
			"shape": target_shape,
			"targets": selected_targets.duplicate(),
			# A single pick can be tracked to its live position; a centroid of
			# several cannot follow any one of them, so it stays a fixed point.
			"anchor": selected_targets[0] if selected_targets.size() == 1 else null,
			"caster_position": caster_position,
		}
		emit_signal("targeting_confirmed", current_hand, current_ability, centroid)
		return result_chars

	# For line targeting, clamp the target position to range
	var final_position = target_position
	if target_shape == TargetShape.LINE:
		var direction = target_position - caster_position
		if direction.length() > line_range:
			final_position = caster_position + direction.normalized() * line_range
	elif _clamps_point():
		final_position = AbilityManager.clamp_point_to_range(_origin_pos(), target_position, range_limit)

	# Designation: whoever the player confirmed on top of. Null over bare ground,
	# which is what preserves plain area targeting.
	var designated = _designated_character_at(final_position)

	# A single-target ability's aim point is never clamped (it has no area), and
	# its explicit target skips AbilityManager's execution clamp, so its range is
	# enforced here, as a character pick's is: refuse, say why, keep aiming.
	if designated != null and range_limit > 0.0 and _is_single_target_ability():
		var dist := _origin_pos().distance_to(designated.global_position)
		if dist > range_limit:
			_reject_target(designated, get_parent(), "Out of range", "out of range (%d / %d)" % [int(dist), int(range_limit)])
			return {}

	# The ring is only for aiming: a live cast's AoE preview stays up through
	# the windup, but the ring goes now.
	range_indicator.visible = false

	var result = {
		"hand": current_hand,
		"ability": current_ability,
		"position": final_position,
		"shape": target_shape,
		"radius": circle_radius if target_shape == TargetShape.CIRCLE else 0.0,
		"size": rectangle_size if target_shape == TargetShape.RECTANGLE else Vector2.ZERO,
		"rotation": rectangle_rotation,
		"caster_position": caster_position,
	}
	# A projectile AoE bursts on the first body or wall in its path. 'position'
	# stays the aimed point (execution fires at it); the queued ghost and the
	# path leader belong where the live preview showed the burst.
	if _projectile_impact.is_finite():
		result["burst_position"] = _projectile_impact
		result["burst_blocked"] = _projectile_impact.distance_to(final_position) > circle_radius

	# Only record an anchor the executor will actually honor. Ground AoE keeps
	# the patch of ground the player chose, so storing an anchor for it would be
	# a lie the planning UI then draws a tracking leash for.
	var anchor = designated if (designated != null and _ability_follows_anchor()) else null
	result["anchor"] = anchor

	# Single-target abilities additionally bind their effects to that one
	# character. Without this they fall into _find_targets_in_area's "none"/
	# "single" arm, which is a 50px proximity sweep — i.e. "single target"
	# spells splash whoever else happens to be standing nearby. Clicking bare
	# ground still falls back to that sweep rather than fizzling.
	if designated != null and _is_single_target_ability():
		result["targets"] = [designated]

	print("targeting confirmed with position: ", final_position)
	emit_signal("targeting_confirmed", current_hand, current_ability, final_position)
	return result

func cancel_targeting() -> void:
	"""Cancel current targeting"""
	if is_targeting:
		emit_signal("targeting_cancelled", current_hand)
	end_targeting()

func end_targeting() -> void:
	"""Clean up targeting state"""
	is_targeting = false
	current_ability = {}
	target_shape = TargetShape.NONE
	lock_to_caster = false
	caster_origin_override = Vector2.INF
	_projectile_impact = Vector2.INF
	_knockback_effect = {}
	_preview_ability = null
	if _knockback_layer:
		_knockback_layer.shoves = []
		_knockback_layer.visible = false
	circle_indicator.visible = false
	rectangle_indicator.visible = false
	line_indicator.visible = false
	cone_indicator.visible = false
	range_indicator.visible = false
	_clear_target_highlights()
	selected_targets.clear()
	if count_label:
		count_label.visible = false

func create_queued_indicator(target_pos: Vector2, shape: TargetShape, radius: float = 50.0, size: Vector2 = Vector2(100, 50), rot: float = 0.0, caster_pos: Vector2 = Vector2.ZERO, intent: int = Ability.Intent.NEUTRAL) -> Node2D:
	"""Create a persistent indicator for a queued ability"""
	# `intent` is trailing and defaulted so every existing six-argument call keeps
	# working: a caller that forgets to classify gets the uninformative sepia
	# ghost, never a wrong red or green one.
	var indicator: Node2D

	match shape:
		TargetShape.CIRCLE:
			indicator = Node2D.new()
			var drawer = CircleDrawer.new()
			drawer.radius = radius
			drawer.is_queued = true
			drawer.intent = intent
			indicator.add_child(drawer)

		TargetShape.RECTANGLE:
			indicator = Node2D.new()
			var drawer = RectangleDrawer.new()
			drawer.rect_size = size
			drawer.is_queued = true
			drawer.intent = intent
			indicator.add_child(drawer)

		TargetShape.LINE:
			indicator = Node2D.new()
			var drawer = LineDrawer.new()
			drawer.line_end = target_pos - caster_pos
			drawer.line_width = size.y if size != Vector2.ZERO else 30.0
			drawer.is_queued = true
			drawer.intent = intent
			indicator.add_child(drawer)
			indicator.top_level = true
			indicator.global_position = caster_pos
			indicator.z_index = 49
			add_child(indicator)
			queued_indicators.append(indicator)
			return indicator

		TargetShape.CONE:
			indicator = Node2D.new()
			var drawer = ConeDrawer.new()
			drawer.cone_radius = radius
			drawer.cone_angle_deg = size.x if size.x > 0 else 45.0
			drawer.is_queued = true
			drawer.intent = intent
			indicator.add_child(drawer)
			indicator.top_level = true
			indicator.global_position = caster_pos
			indicator.rotation = (target_pos - caster_pos).angle()
			indicator.z_index = 49
			add_child(indicator)
			queued_indicators.append(indicator)
			return indicator

		_:
			return null

	indicator.top_level = true
	indicator.global_position = target_pos
	indicator.rotation = rot
	indicator.z_index = 49  # Slightly below active indicator
	add_child(indicator)
	queued_indicators.append(indicator)

	return indicator

func remove_queued_indicator(indicator: Node2D) -> void:
	"""Remove a queued indicator when the ability executes"""
	if indicator in queued_indicators:
		queued_indicators.erase(indicator)
		indicator.queue_free()

func clear_all_queued_indicators() -> void:
	"""Remove all queued indicators"""
	for indicator in queued_indicators:
		if is_instance_valid(indicator):
			indicator.queue_free()
	queued_indicators.clear()


# ===== CHARACTER TARGETING =====

func _ensure_count_label() -> void:
	if count_label and is_instance_valid(count_label):
		return
	count_label_layer = CanvasLayer.new()
	count_label_layer.layer = 100
	add_child(count_label_layer)
	count_label = Label.new()
	# Critical: the label must not intercept mouse input — ProceduralCharacter
	# bails out of _handle_input when the cursor hovers any CanvasLayer-hosted
	# Control, which would block character picking entirely.
	count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	count_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	count_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	count_label.add_theme_constant_override("outline_size", 4)
	count_label.add_theme_font_size_override("font_size", 18)
	count_label.text = "0/0"
	count_label_layer.add_child(count_label)

func _update_character_targeting_visuals() -> void:
	# Update each highlight's position to follow its character
	for i in range(target_highlights.size() - 1, -1, -1):
		var hl = target_highlights[i]
		if not is_instance_valid(hl):
			target_highlights.remove_at(i)
			continue
		var tgt = hl.get_meta("target") if hl.has_meta("target") else null
		if tgt == null or not is_instance_valid(tgt):
			hl.queue_free()
			target_highlights.remove_at(i)
			continue
		hl.global_position = tgt.global_position
		# A pick the party has since lost to Invisible isn't marked where it is.
		var picker = get_parent()
		hl.visible = not (picker != null and picker.has_method("_invisible_to_party") and picker._invisible_to_party(tgt))

	# Drop any selected targets that became invalid
	for j in range(selected_targets.size() - 1, -1, -1):
		if not is_instance_valid(selected_targets[j]):
			selected_targets.remove_at(j)

	# Update count label position and text
	if count_label and is_instance_valid(count_label):
		var viewport = get_viewport()
		var mouse_screen = viewport.get_mouse_position() if viewport else Vector2.ZERO
		count_label.position = mouse_screen + Vector2(18, 18)
		count_label.text = "%d/%d" % [selected_targets.size(), target_count]

func _handle_character_click(world_pos: Vector2) -> bool:
	"""Try to add/remove a character from the selection. Returns true if click was consumed."""
	if not is_targeting or target_shape != TargetShape.CHARACTERS:
		return false
	var space = get_world_2d().direct_space_state
	if space == null:
		return false
	var caster = get_parent()
	var query = PhysicsPointQueryParameters2D.new()
	query.position = world_pos
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.collision_mask = CollisionLayers.CHARACTERS
	if caster and caster.has_method("get_rid"):
		query.exclude = [caster.get_rid()]
	var hits = space.intersect_point(query, 8)
	for hit in hits:
		var collider = hit.get("collider")
		if collider == null or not is_instance_valid(collider):
			continue
		if not (collider is ProceduralCharacter):
			continue
		if collider == caster:
			continue
		# An NPC the party can't see because it is Invisible can't be picked
		# (and isn't refused either: that would give it away).
		if caster != null and caster.has_method("_invisible_to_party") and caster._invisible_to_party(collider):
			continue
		# Toggle off if already selected
		if collider in selected_targets:
			var idx = selected_targets.find(collider)
			selected_targets.remove_at(idx)
			_remove_highlight_for(collider)
			_update_character_targeting_visuals()
			return true
		# Rejected clicks are consumed, and say why over the clicked character
		# Validate alive
		if collider.has_method("is_alive") and not collider.is_alive():
			_reject_target(collider, caster, "Already dead", "already dead")
			return true
		# Validate range, measured from the cast origin (the planned node when
		# planning a path) — the point the range ring is drawn around
		if range_limit > 0.0 and caster:
			var dist = _origin_pos().distance_to(collider.global_position)
			if dist > range_limit:
				_reject_target(collider, caster, "Out of range", "out of range (%d / %d)" % [int(dist), int(range_limit)])
				return true
		# Validate filter
		if not _passes_filter(collider, caster):
			var wanted := "Not an enemy" if target_filter == "enemies" else "Not an ally"
			_reject_target(collider, caster, wanted, wanted.to_lower())
			return true
		selected_targets.append(collider)
		_add_highlight_for(collider)
		_update_character_targeting_visuals()
		# Auto-confirm when count reached
		if selected_targets.size() >= target_count:
			# Defer to next idle so input handler can complete this frame's work
			call_deferred("_emit_auto_confirm")
		return true
	return false

func _passes_filter(target: Node, caster: Node) -> bool:
	if target_filter == "any":
		return true
	if not caster or not ("faction_id" in caster) or not ("faction_id" in target):
		return true
	var caster_faction = caster.faction_id
	var target_faction = target.faction_id
	var enemies = FactionDatabase.are_hostile(caster_faction, target_faction)
	if target_filter == "enemies":
		return enemies
	if target_filter == "allies":
		return not enemies and target != caster
	return true

func _reject_target(target: Node, caster: Node, notice: String, reason: String) -> void:
	"""Floats why a character pick was refused over that character, and logs it."""
	if not target.has_method("notify"):
		return
	var caster_name: String = str(caster.Name) if caster and "Name" in caster else "You"
	var ability_name: String = String(current_ability.get("display_name", "that ability"))
	target.notify(notice, Color(1.0, 0.6, 0.4), "%s can't target %s with %s: %s." % [caster_name, target.Name, ability_name, reason])

func _add_highlight_for(target: Node) -> void:
	var indicator = Node2D.new()
	indicator.top_level = true
	indicator.z_index = 51
	var drawer = CharacterHighlightDrawer.new()
	indicator.add_child(drawer)
	indicator.set_meta("target", target)
	indicator.global_position = target.global_position
	add_child(indicator)
	target_highlights.append(indicator)

func _remove_highlight_for(target: Node) -> void:
	for i in range(target_highlights.size() - 1, -1, -1):
		var hl = target_highlights[i]
		if not is_instance_valid(hl):
			target_highlights.remove_at(i)
			continue
		var t = hl.get_meta("target") if hl.has_meta("target") else null
		if t == target:
			hl.queue_free()
			target_highlights.remove_at(i)
			return

func _clear_target_highlights() -> void:
	for hl in target_highlights:
		if is_instance_valid(hl):
			hl.queue_free()
	target_highlights.clear()

func _emit_auto_confirm() -> void:
	if not is_targeting or target_shape != TargetShape.CHARACTERS:
		return
	if selected_targets.size() != target_count:
		return
	# Drive the cast directly through the caster's confirm flow. We skip emitting
	# `targeting_confirmed` here because confirm_targeting() emits it itself, and
	# routing through a single entry point avoids re-entrancy.
	var caster = get_parent()
	if caster and caster.has_method("_confirm_ability_target"):
		caster._confirm_ability_target(PauseManager.is_paused)


# ===== KNOCKBACK LANDING PREVIEW =====

## The first knockback effect this ability applies, or {} if it doesn't shove.
## Checks `steps` too — multi-step abilities (a dash that ends in a shove) carry
## their effects per step rather than at the top level.
func _find_knockback_effect(ability: Dictionary) -> Dictionary:
	var direct := _first_knockback_in(ability.get("effects", []))
	if not direct.is_empty():
		return direct
	for step in ability.get("steps", []):
		if step is Dictionary:
			var stepped := _first_knockback_in(step.get("effects", []))
			if not stepped.is_empty():
				return stepped
	return {}

func _first_knockback_in(effects) -> Dictionary:
	if effects is Dictionary:
		effects = [effects]
	if not (effects is Array):
		return {}
	for e in effects:
		if e is Dictionary and str(e.get("type", "")) == "knockback":
			return e
	return {}

func _update_knockback_preview() -> void:
	if _knockback_layer == null:
		return
	if _knockback_effect.is_empty() or _preview_ability == null:
		_knockback_layer.visible = false
		return

	# Only recompute when the aim actually moved — see KNOCKBACK_PREVIEW_RESOLUTION.
	if target_position.distance_squared_to(_knockback_last_pos) < KNOCKBACK_PREVIEW_RESOLUTION * KNOCKBACK_PREVIEW_RESOLUTION:
		return
	_knockback_last_pos = target_position

	var caster = get_parent()
	if caster == null or not caster.has_method("_find_targets_in_area"):
		_knockback_layer.visible = false
		return

	var origin: Vector2 = AbilityEffect.knockback_origin(
		_knockback_effect, caster.global_position, target_position)

	# A self-centred blast spares its caster at resolution time, so the preview
	# must not promise to shove them either (AbilityManager._resolve_effects).
	var spares_caster: bool = AbilityManager._is_self_centered(_preview_ability.targeting) \
		and AbilityManager._harms_targets(_preview_ability.effects)

	var shoves: Array = []
	for t in caster._find_targets_in_area(_preview_ability, target_position):
		if not is_instance_valid(t) or not (t is Node2D):
			continue
		if spares_caster and t == caster:
			continue
		# No arrow on an NPC the party can't see because it is Invisible: it
		# would give it away (the blast still shoves it).
		if caster.has_method("_invisible_to_party") and caster._invisible_to_party(t):
			continue
		# Only bodies that integrate an external force can be predicted.
		# _resolve_knockback gates on apply_external_force the same way, so
		# anything skipped here genuinely wouldn't move.
		if not t.has_method("predict_knockback_landing"):
			continue
		var force: Vector2 = AbilityEffect.knockback_force(
			_knockback_effect, origin, t.global_position)
		if force == Vector2.ZERO:
			continue
		var landing: Vector2 = t.predict_knockback_landing(
			force, AbilityEffect.KNOCKBACK_IMPULSE_DURATION)
		if landing.distance_squared_to(t.global_position) < 16.0:
			continue  # blocked immediately or shoved a trivial distance
		var body_radius: float = 16.0
		if "collision_radius" in t:
			body_radius = maxf(float(t.collision_radius), 8.0)
		shoves.append({"from": t.global_position, "to": landing, "radius": body_radius})

	_knockback_layer.shoves = shoves
	_knockback_layer.visible = not shoves.is_empty()
	_knockback_layer.queue_redraw()


# ===== DRAWER CLASSES =====

## Arrow + landing ring per shoved body. Positions are already world-space
## (the node is top_level and pinned to the origin), so nothing is transformed here.
class KnockbackPreviewDrawer extends Node2D:
	var shoves: Array = []  # [{from: Vector2, to: Vector2, radius: float}]
	var _t: float = 0.0

	const SHAFT_COLOR := Color(1.0, 0.62, 0.24, 0.95)
	const SHAFT_SHADOW := Color(0.08, 0.02, 0.0, 0.55)
	const RING_COLOR := Color(1.0, 0.72, 0.35, 0.85)
	const SHAFT_WIDTH := 2.6
	const HEAD_SIZE := 11.0
	const DASH_COUNT := 16  # arc segments in the landing ring (half drawn = dashed)

	func _process(delta: float) -> void:
		_t += delta
		if not shoves.is_empty():
			queue_redraw()

	func _draw() -> void:
		# Breathing alpha keeps the preview reading as a projection rather than
		# as something already on the battlefield.
		var pulse := 0.78 + 0.22 * sin(_t * 3.4)
		for s in shoves:
			var from: Vector2 = s["from"]
			var to: Vector2 = s["to"]
			var body_radius: float = s["radius"]
			var dir := (to - from).normalized()
			if dir == Vector2.ZERO:
				continue
			# Start at the body's edge so the shaft doesn't skewer the sprite.
			var start := from + dir * body_radius
			var tip := to - dir * body_radius * 0.35
			if start.distance_to(tip) < 6.0:
				continue

			var shaft := SHAFT_COLOR
			shaft.a *= pulse
			draw_line(start, tip, SHAFT_SHADOW, SHAFT_WIDTH + 2.5, true)
			draw_line(start, tip, shaft, SHAFT_WIDTH, true)

			# Arrowhead as a filled triangle — thin strokes vanish against terrain.
			var perp := dir.rotated(PI / 2.0)
			draw_colored_polygon(PackedVector2Array([
				tip + dir * HEAD_SIZE,
				tip + perp * HEAD_SIZE * 0.45,
				tip - perp * HEAD_SIZE * 0.45,
			]), shaft)

			_draw_dashed_ring(to, body_radius, pulse)

	func _draw_dashed_ring(center: Vector2, radius: float, pulse: float) -> void:
		var color := RING_COLOR
		color.a *= pulse
		var arc := TAU / float(DASH_COUNT)
		for i in range(DASH_COUNT):
			if i % 2 == 1:
				continue
			var a := float(i) * arc + _t * 0.6
			draw_arc(center, radius, a, a + arc * 0.7, 6, color, 2.2, true)

class CircleDrawer extends Node2D:
	var radius: float = 50.0
	var is_queued: bool = false
	# Ability.Intent. Stamped by start_targeting (live) or create_queued_indicator
	# (ghost); NEUTRAL is the honest default for a drawer nobody has classified.
	var intent: int = Ability.Intent.NEUTRAL
	var num_segments: int = 32
	var draw_fill: bool = true  # Off for the outline-only range ring
	# Red over the intent colours: a projectile AoE will burst too far short
	# of the cursor to reach it (AbilityTargeting._find_projectile_impact).
	var is_blocked: bool = false
	
	func _draw() -> void:
		var color: Color = Ability.intent_fill_color(intent, is_queued)
		var border_color: Color = Ability.intent_border_color(intent, is_queued)
		var border_width: float = Ability.intent_border_width(intent, is_queued)
		var dashed: bool = Ability.intent_border_dashed(intent, is_queued)
		if is_blocked:
			color = Color(1.0, 0.35, 0.3, 0.4)
			border_color = Color(1.0, 0.35, 0.3, 0.8)
		
		# Fill
		if draw_fill:
			draw_circle(Vector2.ZERO, radius, color)
		
		# Border
		var points = PackedVector2Array()
		for i in range(num_segments + 1):
			var angle = (float(i) / num_segments) * TAU
			points.append(Vector2(cos(angle), sin(angle)) * radius)
		
		# 32 segments, so dropping every other one gives 16 even dashes at any
		# radius. The dash pattern is the colour-blind-safe half of the
		# hostile/beneficial split — see the INTENT PALETTE note on Ability.
		for i in range(num_segments):
			if dashed and i % 2 == 1:
				continue
			draw_line(points[i], points[i + 1], border_color, border_width, true)


class RectangleDrawer extends Node2D:
	var rect_size: Vector2 = Vector2(100, 50)
	var is_queued: bool = false
	var intent: int = Ability.Intent.NEUTRAL

	func _draw() -> void:
		var color: Color = Ability.intent_fill_color(intent, is_queued)
		var border_color: Color = Ability.intent_border_color(intent, is_queued)
		var border_width: float = Ability.intent_border_width(intent, is_queued)
		var dashed: bool = Ability.intent_border_dashed(intent, is_queued)

		var rect = Rect2(-rect_size / 2, rect_size)

		# Fill
		draw_rect(rect, color, true)

		# Border
		if not dashed:
			draw_rect(rect, border_color, false, border_width)
			return
		# draw_rect cannot gap a stroke, and there are only four sides here — so
		# alternating whole SIDES the way the circle alternates segments would
		# delete half the outline. Each side is broken once, at its own midpoint.
		var corners = PackedVector2Array([
			rect.position,
			rect.position + Vector2(rect.size.x, 0.0),
			rect.position + rect.size,
			rect.position + Vector2(0.0, rect.size.y),
		])
		for i in range(corners.size()):
			var a: Vector2 = corners[i]
			var b: Vector2 = corners[(i + 1) % corners.size()]
			draw_line(a, a.lerp(b, 0.42), border_color, border_width, true)
			draw_line(a.lerp(b, 0.58), b, border_color, border_width, true)


class LineDrawer extends Node2D:
	var line_end: Vector2 = Vector2(100, 0)
	var line_width: float = 30.0
	var is_queued: bool = false
	var intent: int = Ability.Intent.NEUTRAL

	func _draw() -> void:
		# A line sweeps a long swath, so its fill is thinned to 0.75 of the
		# circle/rectangle value and its border to 0.875 — exactly the 0.3-vs-0.4
		# and 0.7-vs-0.8 relationship the old hardcoded colours carried, preserved
		# so this change stays purely chromatic.
		var color: Color = Ability.intent_fill_color(intent, is_queued)
		color.a *= 0.75
		var border_color: Color = Ability.intent_border_color(intent, is_queued)
		border_color.a *= 0.875
		var border_width: float = Ability.intent_border_width(intent, is_queued)
		var dashed: bool = Ability.intent_border_dashed(intent, is_queued)

		if line_end.length() < 1.0:
			return

		var direction = line_end.normalized()
		var perpendicular = direction.rotated(PI / 2.0) * line_width * 0.5

		# Build rotated rectangle as polygon
		var corners = PackedVector2Array([
			-perpendicular,
			line_end - perpendicular,
			line_end + perpendicular,
			perpendicular,
		])

		# Fill
		draw_colored_polygon(corners, color)

		# Border — four long sides, gapped at their midpoints when dashed (see
		# RectangleDrawer for why whole sides are never skipped).
		for i in range(corners.size()):
			var a: Vector2 = corners[i]
			var b: Vector2 = corners[(i + 1) % corners.size()]
			if dashed:
				draw_line(a, a.lerp(b, 0.42), border_color, border_width, true)
				draw_line(a.lerp(b, 0.58), b, border_color, border_width, true)
			else:
				draw_line(a, b, border_color, border_width, true)


class ConeDrawer extends Node2D:
	var cone_radius: float = 150.0
	var cone_angle_deg: float = 45.0
	var is_queued: bool = false
	var intent: int = Ability.Intent.NEUTRAL
	var num_segments: int = 24

	func _draw() -> void:
		# Same 0.75 / 0.875 swath thinning as LineDrawer.
		var color: Color = Ability.intent_fill_color(intent, is_queued)
		color.a *= 0.75
		var border_color: Color = Ability.intent_border_color(intent, is_queued)
		border_color.a *= 0.875
		var border_width: float = Ability.intent_border_width(intent, is_queued)
		var dashed: bool = Ability.intent_border_dashed(intent, is_queued)

		var half_angle = deg_to_rad(cone_angle_deg) / 2.0

		# Build cone polygon: origin → arc points → back to origin
		var points = PackedVector2Array()
		points.append(Vector2.ZERO)
		for i in range(num_segments + 1):
			var t = float(i) / num_segments
			var angle = -half_angle + t * cone_angle_deg * PI / 180.0
			points.append(Vector2(cos(angle), sin(angle)) * cone_radius)

		# Fill
		draw_colored_polygon(points, color)

		# Border (lines along edges). Only the ARC dashes: index 0 and the last
		# index are the two straight flanks, and with 26 points the last index is
		# ODD — alternating blindly would delete one whole flank of the cone.
		var last := points.size() - 1
		for i in range(points.size()):
			if dashed and i > 0 and i < last and i % 2 == 1:
				continue
			draw_line(points[i], points[(i + 1) % points.size()], border_color, border_width, true)


class CharacterHighlightDrawer extends Node2D:
	var radius: float = 32.0
	var is_queued: bool = false
	var intent: int = Ability.Intent.NEUTRAL
	var _t: float = 0.0

	func _process(delta: float) -> void:
		_t += delta
		queue_redraw()

	func _draw() -> void:
		var pulse = 0.85 + 0.15 * sin(_t * 4.0)
		var r = radius * pulse
		# The queued branch is currently unreachable (_add_highlight_for never sets
		# is_queued), but it carried the same blue the AoE ghosts used to, so it is
		# pointed at the shared palette rather than left as a literal waiting to
		# reintroduce the one cool colour on the battlefield.
		var color = Ability.intent_border_color(intent, true) if is_queued else Color(1.0, 0.9, 0.3, 0.9)
		var num_segments := 32
		var points = PackedVector2Array()
		for i in range(num_segments + 1):
			var angle = (float(i) / num_segments) * TAU
			points.append(Vector2(cos(angle), sin(angle)) * r)
		for i in range(num_segments):
			draw_line(points[i], points[i + 1], color, 3.0, true)
