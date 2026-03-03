extends Control

# Configuration - which limbs to display and their visual properties
const BAR_CONFIG: Array = [
	{
		"limb_type": 0,  # LimbType.HEAD
		"label": "Head",
		"color_full": Color(0.2, 0.8, 0.2),
		"color_mid": Color(0.9, 0.8, 0.1),
		"color_low": Color(0.8, 0.1, 0.1),
		"mid_threshold": 0.5,
		"low_threshold": 0.25,
	},
	{
		"limb_type": 1,  # LimbType.TORSO
		"label": "Torso",
		"color_full": Color(0.2, 0.8, 0.2),
		"color_mid": Color(0.9, 0.8, 0.1),
		"color_low": Color(0.8, 0.1, 0.1),
		"mid_threshold": 0.5,
		"low_threshold": 0.25,
	},
]

const BAR_WIDTH: int = 80
const BAR_HEIGHT: int = 8
const BAR_SPACING: int = 2
const LABEL_FONT_SIZE: int = 10
const DEBUG_FONT_SIZE: int = 9
const BG_COLOR: Color = Color(0.15, 0.15, 0.15, 0.8)
const BORDER_COLOR: Color = Color(0.0, 0.0, 0.0, 0.9)
const OFFSET_Y: float = -40.0  # Offset above the character

# Debug state label config: maps enum values to display names and colors

# Debug state label config: maps enum values to display names and colors
const AI_STATE_DISPLAY: Dictionary = {
	0: { "name": "DEAD", "color": Color(0.4, 0.4, 0.4) },        # AIState.DEAD
	1: { "name": "IDLE", "color": Color(0.6, 0.6, 0.6) },        # AIState.IDLE
	2: { "name": "PATROL", "color": Color(0.5, 0.8, 0.5) },      # AIState.PATROL
	3: { "name": "CHASE", "color": Color(1.0, 0.6, 0.0) },       # AIState.CHASE
	4: { "name": "APPROACH", "color": Color(0.9, 0.9, 0.2) },    # AIState.APPROACH
	5: { "name": "ATTACK", "color": Color(1.0, 0.2, 0.2) },      # AIState.ATTACK
	6: { "name": "RETREAT", "color": Color(0.3, 0.6, 1.0) },     # AIState.RETREAT
	7: { "name": "STUNNED", "color": Color(0.8, 0.3, 0.8) },     # AIState.STUNNED
}

const ATTACK_STATE_DISPLAY: Dictionary = {
	0: { "name": "IDLE", "color": Color(0.6, 0.6, 0.6) },            # AttackState.IDLE
	1: { "name": "WINDUP", "color": Color(1.0, 0.8, 0.2) },          # AttackState.WINDUP
	2: { "name": "STRIKE", "color": Color(1.0, 0.1, 0.1) },          # AttackState.STRIKE
	3: { "name": "RECOVERY", "color": Color(0.4, 0.7, 1.0) },        # AttackState.RECOVERY
	4: { "name": "CAST_WINDUP", "color": Color(0.7, 0.3, 1.0) },     # AttackState.CAST_WINDUP
	5: { "name": "CAST_RELEASE", "color": Color(1.0, 0.3, 0.7) },    # AttackState.CAST_RELEASE
	6: { "name": "CAST_RECOVERY", "color": Color(0.5, 0.5, 1.0) },   # AttackState.CAST_RECOVERY
}

var _target_node: Node2D = null
var _bar_data: Array = []  # Stores current state per bar
var _show_debug: bool = true
var _ai_state: int = 0
var _attack_state: int = 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 100
	_init_bar_data()


func _init_bar_data() -> void:
	_bar_data.clear()
	for config in BAR_CONFIG:
		_bar_data.append({
			"config": config,
			"current_percent": 1.0,
			"target_percent": 1.0,
		})


func setup(target: Node2D) -> void:
	_target_node = target


func update_from_limbs(limbs: Dictionary) -> void:
	for i in range(_bar_data.size()):
		var limb_type: int = _bar_data[i]["config"]["limb_type"]
		if limbs.has(limb_type):
			var limb = limbs[limb_type]
			_bar_data[i]["target_percent"] = limb.get_hp_percent()


func update_debug_state(ai_state: int, attack_state: int) -> void:
	_ai_state = ai_state
	_attack_state = attack_state


func set_debug_visible(enabled: bool) -> void:
	_show_debug = enabled


func _process(delta: float) -> void:
	# Smooth interpolation toward target
	for data in _bar_data:
		data["current_percent"] = lerp(data["current_percent"], data["target_percent"], delta * 8.0)

	# Follow target node
	if _target_node and is_instance_valid(_target_node):
		global_position = _target_node.global_position + Vector2(-BAR_WIDTH * 0.5, OFFSET_Y)

	queue_redraw()


func _draw() -> void:
	var total_height: int = _bar_data.size() * (BAR_HEIGHT + LABEL_FONT_SIZE + BAR_SPACING)
	if _show_debug:
		total_height += 2 + (DEBUG_FONT_SIZE + 2) * 2  # Two debug lines
	var bg_rect := Rect2(-4, -4, BAR_WIDTH + 8, total_height + 8)
	draw_rect(bg_rect, BG_COLOR)

	var y_offset: float = 0.0
	for data in _bar_data:
		var config: Dictionary = data["config"]
		var percent: float = data["current_percent"]

		# Label
		draw_string(
			ThemeDB.fallback_font,
			Vector2(0, y_offset + LABEL_FONT_SIZE),
			config["label"],
			HORIZONTAL_ALIGNMENT_LEFT,
			BAR_WIDTH,
			LABEL_FONT_SIZE,
			Color.WHITE
		)
		y_offset += LABEL_FONT_SIZE + 1

		# Bar background (empty portion)
		var bar_rect := Rect2(0, y_offset, BAR_WIDTH, BAR_HEIGHT)
		draw_rect(bar_rect, Color(0.3, 0.1, 0.1, 0.6))

		# Bar fill
		var fill_width: float = BAR_WIDTH * clampf(percent, 0.0, 1.0)
		if fill_width > 0:
			var fill_color: Color = _get_bar_color(percent, config)
			draw_rect(Rect2(0, y_offset, fill_width, BAR_HEIGHT), fill_color)

		# Border
		draw_rect(bar_rect, BORDER_COLOR, false, 1.0)

		y_offset += BAR_HEIGHT + BAR_SPACING

	# Debug: AI state and attack state labels
	if _show_debug:
		y_offset += 2
		_draw_debug_label(y_offset, "AI", _ai_state, AI_STATE_DISPLAY)
		y_offset += DEBUG_FONT_SIZE + 2
		_draw_debug_label(y_offset, "ATK", _attack_state, ATTACK_STATE_DISPLAY)


func _draw_debug_label(y: float, prefix: String, state: int, display_map: Dictionary) -> void:
	var info: Dictionary = display_map.get(state, { "name": "???", "color": Color.WHITE })
	var text: String = prefix + ": " + info["name"]
	draw_string(
		ThemeDB.fallback_font,
		Vector2(0, y + DEBUG_FONT_SIZE),
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		BAR_WIDTH,
		DEBUG_FONT_SIZE,
		info["color"]
	)


func _get_bar_color(percent: float, config: Dictionary) -> Color:
	if percent <= config["low_threshold"]:
		return config["color_low"]
	elif percent <= config["mid_threshold"]:
		return config["color_mid"]
	else:
		return config["color_full"]
