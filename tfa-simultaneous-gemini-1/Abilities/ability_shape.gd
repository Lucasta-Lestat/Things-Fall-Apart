# ability_shape.gd
extends Node2D
class_name AbilityShape

# Matches your AbilityTargeting enum strings
enum AbilityTargetShape { NONE, CIRCLE, RECTANGLE }

@export_group("Identity")
@export var ability_id: String = "fireball"
@export var ability_name: String = "Fireball"

@export_group("Visuals")
@export var visual_scene: PackedScene
@export var cast_duration: float = 0.3

@export_group("Targeting")
@export var requires_targeting: bool = true
@export var target_shape: AbilityTargetShape = AbilityTargetShape.CIRCLE
@export var target_radius: float = 50.0
@export var target_size: Vector2 = Vector2(100, 50)
# Store the full raw data in case we need to look up costs/damage later
@export_group("Visual Positioning")
@export var hand_offset: Vector2 = Vector2()


var raw_data: Dictionary = {}

var _active_visual: Node2D

func _ready() -> void:
	if visual_scene:
		_active_visual = visual_scene.instantiate()
		add_child(_active_visual)
		activate_visuals(true)

func activate_visuals(active: bool):
	if _active_visual:
		if _active_visual is GPUParticles2D or _active_visual is CPUParticles2D:
			_active_visual.emitting = active
		elif _active_visual.has_method("set_active"):
			_active_visual.set_active(active)
		else:
			_active_visual.visible = active
	
func get_tip_local_position():
	Vector2(0, min(10.0,target_size.y / 10.0)) #looks bigger in hand based on size of spell AoE
# Converts local export vars into the Dictionary format AbilityTargeting expects
func get_ability_data() -> Dictionary:
	# 1. Start with the full original data from the database (includes visuals/effects)
	print("get ability data called")
	var data_to_send = raw_data.duplicate(true)
	print("data_to_send for targeting: ", data_to_send)
	# 2. Ensure critical fields are present if raw_data was empty (e.g. placed in Editor)
	if data_to_send.is_empty():
		data_to_send["id"] = ability_id
		data_to_send["display_name"] = ability_name
		data_to_send["visuals"] = {} # Prevent crash if missing
		
	# 3. Update Targeting data with current Node values 
	# (This allows you to tweak range/radius in the Inspector and have it apply)
	var shape_str = "none"
	match target_shape:
		AbilityTargetShape.CIRCLE: shape_str = "circle"
		AbilityTargetShape.RECTANGLE: shape_str = "rectangle"
	
	# We construct the specific targeting block expected by the system
	var targeting_override = {
		"shape": shape_str,
		"radius": target_radius,
		"size": target_size,
		"requires_targeting": requires_targeting
		# Add range if you have an export for it
	}
	
	#
	data_to_send.merge(targeting_override, true)
	print("data_to_send: ", data_to_send)
	return data_to_send

func setup_from_database(data: Dictionary) -> void:
	raw_data = data
	
	# 1. Identity
	ability_id = data.get("id", "unknown")
	ability_name = data.get("display_name", "Unknown Ability")
	
	# 2. Visuals (In-Hand)
	var visuals = data.get("visuals", {})
	var vfx_path = visuals.get("in_hand_effect", "")
	if vfx_path != "":
		# Load the particle scene dynamically
		visual_scene = load(vfx_path)
		if visual_scene:
			# Instantiate immediately for the equipment system
			_active_visual = visual_scene.instantiate()
			add_child(_active_visual)
			activate_visuals(false) # Start turned off

	# 3. Targeting Configuration
	var targeting = data.get("targeting", {})
	var shape_str = targeting.get("shape", "none")
	
	match shape_str:
		"circle": target_shape = AbilityTargetShape.CIRCLE
		"rectangle": target_shape = AbilityTargetShape.RECTANGLE
		_: target_shape = AbilityTargetShape.NONE
		
	target_radius = targeting.get("radius", 50.0)
	
	# 4. Timings
	cast_duration = data.get("cast_time", 1.0)
# The Interface Implementation
func get_grip_offset_for_hand() -> Vector2:
	# Returns the manual offset defined in the inspector
	return hand_offset
