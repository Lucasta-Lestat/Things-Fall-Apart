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
var target_position: Vector2 = Vector2.ZERO

# Visual indicators
var circle_indicator: Node2D = null
var rectangle_indicator: Node2D = null
var line_indicator: Node2D = null
var cone_indicator: Node2D = null

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
var character_range: float = 0.0  # 0 = unlimited
var selected_targets: Array = []
var target_highlights: Array[Node2D] = []
var count_label: Label = null
var count_label_layer: CanvasLayer = null

# When true, the targeting indicator is anchored to the caster (self-targeted abilities)
# instead of following the mouse cursor
var lock_to_caster: bool = false

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

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	z_index = 50  # Above ground, below UI
	_create_indicators()

func _process(_delta: float) -> void:
	if is_targeting:
		if lock_to_caster:
			# Self-targeted: anchor the indicator to the caster's (possibly moving) position
			caster_position = _origin_pos()
			target_position = caster_position
		else:
			# Update target position to mouse
			target_position = _get_mouse_world_position()

		# For line and cone, keep caster_position in sync with the character
		if target_shape == TargetShape.LINE or target_shape == TargetShape.CONE:
			caster_position = _origin_pos()

		if target_shape == TargetShape.CHARACTERS:
			caster_position = _origin_pos()
			_update_character_targeting_visuals()
		else:
			_update_active_indicator()

func _create_indicators() -> void:
	"""Create the targeting indicator nodes"""
	# Circle indicator
	circle_indicator = Node2D.new()
	circle_indicator.name = "CircleIndicator"
	var circle_drawer = CircleDrawer.new()
	circle_indicator.add_child(circle_drawer)
	circle_indicator.visible = false
	add_child(circle_indicator)
	
	# Rectangle indicator
	rectangle_indicator = Node2D.new()
	rectangle_indicator.name = "RectangleIndicator"
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

func _update_active_indicator() -> void:
	"""Update the position and appearance of the active indicator"""
	#print("target_shape is : ", target_shape)
	match target_shape:
		TargetShape.CIRCLE:
			circle_indicator.global_position = target_position
			circle_indicator.visible = true
			rectangle_indicator.visible = false
			var drawer = circle_indicator.get_child(0) as CircleDrawer
			if drawer:
				drawer.radius = circle_radius
				drawer.queue_redraw()
		
		TargetShape.RECTANGLE:
			rectangle_indicator.global_position = target_position
			rectangle_indicator.rotation = rectangle_rotation
			rectangle_indicator.visible = true
			circle_indicator.visible = false
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

# ===== PUBLIC API =====

func start_targeting(hand: String, ability: Dictionary, mouse_pos:Vector2, origin_override: Vector2 = Vector2.INF) -> void:

	"""Begin targeting for an ability"""
	print("start_targeting called for ability ", ability.display_name)
	is_targeting = true
	current_hand = hand
	current_ability = ability
	caster_origin_override = origin_override

	# Self-targeted abilities anchor the AoE preview to the caster instead of the cursor
	var target_type_str = ability.get("target_type", "point")
	lock_to_caster = (target_type_str == "self")

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
			character_range = float(ability.get("range", 0.0))
			caster_position = _origin_pos()
			selected_targets.clear()
			_clear_target_highlights()
			_ensure_count_label()
			count_label.visible = true
		_:
			target_shape = TargetShape.NONE

	# Force an immediate update to ensure visual appears this frame
	if target_shape == TargetShape.CHARACTERS:
		_update_character_targeting_visuals()
	else:
		_update_active_indicator()

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
		var result_chars = {
			"hand": current_hand,
			"ability": current_ability,
			"position": centroid,
			"shape": target_shape,
			"targets": selected_targets.duplicate(),
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
	print("targeting confirmed with position: ", target_position)
	emit_signal("targeting_confirmed", current_hand, current_ability, target_position)
	return result

func cancel_targeting() -> void:
	"""Cancel current targeting"""
	if is_targeting:
		emit_signal("targeting_cancelled", current_hand)
	end_targeting()

func end_targeting() -> void:
	"""Clean up targeting state"""
	#end targeting not getting called
	print("is end targeting being called? Yes")
	is_targeting = false
	current_ability = {}
	target_shape = TargetShape.NONE
	lock_to_caster = false
	caster_origin_override = Vector2.INF
	circle_indicator.visible = false
	rectangle_indicator.visible = false
	line_indicator.visible = false
	cone_indicator.visible = false
	_clear_target_highlights()
	selected_targets.clear()
	if count_label:
		count_label.visible = false

func create_queued_indicator(target_pos: Vector2, shape: TargetShape, radius: float = 50.0, size: Vector2 = Vector2(100, 50), rot: float = 0.0, caster_pos: Vector2 = Vector2.ZERO) -> Node2D:
	"""Create a persistent indicator for a queued ability"""
	var indicator: Node2D

	match shape:
		TargetShape.CIRCLE:
			indicator = Node2D.new()
			var drawer = CircleDrawer.new()
			drawer.radius = radius
			drawer.is_queued = true
			indicator.add_child(drawer)

		TargetShape.RECTANGLE:
			indicator = Node2D.new()
			var drawer = RectangleDrawer.new()
			drawer.rect_size = size
			drawer.is_queued = true
			indicator.add_child(drawer)

		TargetShape.LINE:
			indicator = Node2D.new()
			var drawer = LineDrawer.new()
			drawer.line_end = target_pos - caster_pos
			drawer.line_width = size.y if size != Vector2.ZERO else 30.0
			drawer.is_queued = true
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
		# Toggle off if already selected
		if collider in selected_targets:
			var idx = selected_targets.find(collider)
			selected_targets.remove_at(idx)
			_remove_highlight_for(collider)
			_update_character_targeting_visuals()
			return true
		# Validate range
		if character_range > 0.0 and caster:
			var dist = caster.global_position.distance_to(collider.global_position)
			if dist > character_range:
				return true  # consumed but rejected
		# Validate filter
		if not _passes_filter(collider, caster):
			return true
		# Validate alive
		if collider.has_method("is_alive") and not collider.is_alive():
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
	var enemies = FactionDatabase.are_enemies(caster_faction, target_faction)
	if target_filter == "enemies":
		return enemies
	if target_filter == "allies":
		return not enemies and target != caster
	return true

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


# ===== DRAWER CLASSES =====

class CircleDrawer extends Node2D:
	var radius: float = 50.0
	var is_queued: bool = false
	var num_segments: int = 32
	
	func _draw() -> void:
		var color = Color(0.5, 0.8, 1.0, 0.4) if is_queued else Color(1, 1, 1, 0.4)
		var border_color = Color(0.5, 0.8, 1.0, 0.8) if is_queued else Color(1, 1, 1, 0.8)
		
		# Fill
		draw_circle(Vector2.ZERO, radius, color)
		
		# Border
		var points = PackedVector2Array()
		for i in range(num_segments + 1):
			var angle = (float(i) / num_segments) * TAU
			points.append(Vector2(cos(angle), sin(angle)) * radius)
		
		for i in range(num_segments):
			draw_line(points[i], points[i + 1], border_color, 2.0, true)


class RectangleDrawer extends Node2D:
	var rect_size: Vector2 = Vector2(100, 50)
	var is_queued: bool = false

	func _draw() -> void:
		var color = Color(0.5, 0.8, 1.0, 0.4) if is_queued else Color(1, 1, 1, 0.4)
		var border_color = Color(0.5, 0.8, 1.0, 0.8) if is_queued else Color(1, 1, 1, 0.8)

		var rect = Rect2(-rect_size / 2, rect_size)

		# Fill
		draw_rect(rect, color, true)

		# Border
		draw_rect(rect, border_color, false, 2.0)


class LineDrawer extends Node2D:
	var line_end: Vector2 = Vector2(100, 0)
	var line_width: float = 30.0
	var is_queued: bool = false

	func _draw() -> void:
		var color = Color(0.5, 0.8, 1.0, 0.3) if is_queued else Color(1, 1, 1, 0.3)
		var border_color = Color(0.5, 0.8, 1.0, 0.7) if is_queued else Color(1, 1, 1, 0.7)

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

		# Border
		for i in range(corners.size()):
			draw_line(corners[i], corners[(i + 1) % corners.size()], border_color, 2.0, true)


class ConeDrawer extends Node2D:
	var cone_radius: float = 150.0
	var cone_angle_deg: float = 45.0
	var is_queued: bool = false
	var num_segments: int = 24

	func _draw() -> void:
		var color = Color(0.5, 0.8, 1.0, 0.3) if is_queued else Color(1, 1, 1, 0.3)
		var border_color = Color(0.5, 0.8, 1.0, 0.7) if is_queued else Color(1, 1, 1, 0.7)

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

		# Border (lines along edges)
		for i in range(points.size()):
			draw_line(points[i], points[(i + 1) % points.size()], border_color, 2.0, true)


class CharacterHighlightDrawer extends Node2D:
	var radius: float = 32.0
	var is_queued: bool = false
	var _t: float = 0.0

	func _process(delta: float) -> void:
		_t += delta
		queue_redraw()

	func _draw() -> void:
		var pulse = 0.85 + 0.15 * sin(_t * 4.0)
		var r = radius * pulse
		var color = Color(0.5, 0.8, 1.0, 0.9) if is_queued else Color(1.0, 0.9, 0.3, 0.9)
		var num_segments := 32
		var points = PackedVector2Array()
		for i in range(num_segments + 1):
			var angle = (float(i) / num_segments) * TAU
			points.append(Vector2(cos(angle), sin(angle)) * r)
		for i in range(num_segments):
			draw_line(points[i], points[i + 1], color, 3.0, true)
