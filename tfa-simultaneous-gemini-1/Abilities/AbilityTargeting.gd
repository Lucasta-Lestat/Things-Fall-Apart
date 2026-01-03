# AbilityTargeting.gd
# Handles AoE targeting visualization and input
extends Node2D

enum TargetShape { NONE, CIRCLE, RECTANGLE }
enum HandSlot { LEFT, RIGHT }

signal targeting_started(hand: HandSlot, ability: Dictionary)
signal targeting_confirmed(hand: HandSlot, ability: Dictionary, target_position: Vector2)
signal targeting_cancelled(hand: HandSlot)

# Current targeting state
var is_targeting: bool = false
var current_hand: HandSlot = HandSlot.RIGHT
var current_ability: Dictionary = {}
var target_position: Vector2 = Vector2.ZERO

# Visual indicators
var circle_indicator: Node2D = null
var rectangle_indicator: Node2D = null

# Targeting parameters (set from ability data)
var target_shape: TargetShape = TargetShape.NONE
var circle_radius: float = 50.0
var rectangle_size: Vector2 = Vector2(100, 50)
var rectangle_rotation: float = 0.0  # In radians

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
		# Update target position to mouse
		target_position = _get_mouse_world_position()
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

func _update_active_indicator() -> void:
	"""Update the position and appearance of the active indicator"""
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
		
		TargetShape.NONE:
			circle_indicator.visible = false
			rectangle_indicator.visible = false

func _get_mouse_world_position() -> Vector2:
	"""Get mouse position in world coordinates"""
	# This may need adjustment based on your viewport setup
	return get_global_mouse_position()

# ===== PUBLIC API =====

func start_targeting(hand: HandSlot, ability: Dictionary) -> void:
	"""Begin targeting for an ability"""
	is_targeting = true
	current_hand = hand
	current_ability = ability
	
	# Set shape from ability data
	var shape_str = ability.get("target_shape", "none")
	match shape_str:
		"circle":
			target_shape = TargetShape.CIRCLE
			circle_radius = ability.get("radius", 50.0)
		"rectangle":
			target_shape = TargetShape.RECTANGLE
			rectangle_size = ability.get("size", Vector2(100, 50))
		_:
			target_shape = TargetShape.NONE
	
	emit_signal("targeting_started", hand, ability)

func confirm_targeting() -> Dictionary:
	"""Confirm the current target and return targeting data"""
	if not is_targeting:
		return {}
	
	var result = {
		"hand": current_hand,
		"ability": current_ability,
		"position": target_position,
		"shape": target_shape,
		"radius": circle_radius if target_shape == TargetShape.CIRCLE else 0.0,
		"size": rectangle_size if target_shape == TargetShape.RECTANGLE else Vector2.ZERO,
		"rotation": rectangle_rotation
	}
	
	emit_signal("targeting_confirmed", current_hand, current_ability, target_position)
	return result

func cancel_targeting() -> void:
	"""Cancel current targeting"""
	if is_targeting:
		emit_signal("targeting_cancelled", current_hand)
	_end_targeting()

func _end_targeting() -> void:
	"""Clean up targeting state"""
	is_targeting = false
	current_ability = {}
	target_shape = TargetShape.NONE
	circle_indicator.visible = false
	rectangle_indicator.visible = false

func create_queued_indicator(target_pos: Vector2, shape: TargetShape, radius: float = 50.0, size: Vector2 = Vector2(100, 50), rot: float = 0.0) -> Node2D:
	"""Create a persistent indicator for a queued ability"""
	var indicator: Node2D
	
	match shape:
		TargetShape.CIRCLE:
			indicator = Node2D.new()
			var drawer = CircleDrawer.new()
			drawer.radius = radius
			drawer.is_queued = true  # Different color for queued
			indicator.add_child(drawer)
		
		TargetShape.RECTANGLE:
			indicator = Node2D.new()
			var drawer = RectangleDrawer.new()
			drawer.rect_size = size
			drawer.is_queued = true
			indicator.add_child(drawer)
		
		_:
			return null
	
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
