# character.gd
# Attach to a Node2D that will be the character root
extends CharacterBody2D
class_name ProceduralCharacter
@onready var game2 = get_node("/root/TopDownCharacterScene")
# Character data
var character_data: Dictionary = {}
var Name = ""
var skin_color: Color = Color.BEIGE
var hair_color: Color = Color("#4a3728")  # Default brown hair
var body_color: Color  # Derived from skin_color, slightly darker
var traits = ["Male"]
# Faction
var faction_id: String = "neutral"
var is_protagonist = false
var AI_enabled = false
var action_queue: ActionQueue = null
# Body parts
var body: Line2D
var head: Line2D
var hair: Line2D
var left_arm: Line2D
var right_arm: Line2D
var left_leg: Line2D
var right_leg: Line2D

var current_hand = "Main"
#Shaking
# --- NEW: Shake & Push Variables ---
var current_shake_intensity: float = 0.0
var shake_decay_rate: float = 10.0
var current_shake_offset: Vector2 = Vector2.ZERO
@export var body_size_mod = 1.1
# Leg animation
var leg_swing_time: float = body_size_mod * Globals.default_leg_swing_time
@export var leg_swing_speed: float = body_size_mod *Globals.default_leg_swing_speed  # How fast legs oscillate
@export var leg_swing_amount: float = body_size_mod * Globals.default_leg_swing_amount  # How far legs swing
@export var leg_length: float = body_size_mod *Globals.default_leg_length       # Length of each leg
@export var leg_width: float = body_size_mod *Globals.default_leg_width         # Thickness of legs
@export var leg_spacing: float =body_size_mod * Globals.default_leg_spacing       # Distance between legs (left-right)

# Equipment slots (using new shape-based system)
var head_equipment: EquipmentShape = null
var torso_equipment: EquipmentShape = null  # Breastplate, armor covering body
var back_equipment: EquipmentShape = null   # Cape, backpack
var legs_equipment: EquipmentShape = null   # Pants
var feet_equipment: EquipmentShape = null   # Boots

# Equipment holders (Node2D attachment points)
var head_slot: Node2D
var torso_slot: Node2D
var back_slot: Node2D
var legs_slot: Node2D
var feet_slot: Node2D

enum HairStyle {
	NONE,
	HORSESHOE,      # Original balding/receding hairline
	FULL,           # Normal full head of hair
	COMBOVER,       # Side-swept comb over
	POMPADOUR,      # High volume front swept back
	BUZZCUT,        # Very short all over
	MOHAWK          # Strip down the middle
}
var hair_style: HairStyle = HairStyle.FULL
# Inventory and weapons (using new shape-based system)
var inventory: Inventory
var current_main_hand_weapon: WeaponShape = null
var current_off_hand_weapon: WeaponShape = null
var main_hand_holder: Node2D
var off_hand_holder: Node2D
var unarmed_strike_damage_type = "bludgeoning"
var unarmed_strike_damage = 1
# Attack system
var attack_animator: AttackAnimator

# Movement
var target_position: Vector2
var target_rotation: float = 0.0
var is_moving: bool = false


var CRIT_FAIL_THRESHOLD = 96
var CRIT_THRESHOLD = 5

# Arm IK settings (smaller for top-down proportions)
var ARM_SEGMENT_LENGTHS: Array = Globals.DEFAULT_ARM_SEGMENT_LENGTHS.map(func(length): return length * body_size_mod)
const ARM_JOINT_CONSTRAINTS: Array[Vector2] = [
	Vector2(-135, 135),  # Shoulder
	Vector2(0, 145),      # Elbow
	Vector2(-45, 45)      # Wrist
]
const IK_ITERATIONS: int = 10

# Arm state
var left_arm_joints: Array[Vector2] = []
var right_arm_joints: Array[Vector2] = []
var left_arm_target: Vector2
var right_arm_target: Vector2

# Base attributes (1-1000 scale, 10 is average human)
@export var strength: int = 50      # Damage multiplier, weapon clash power
@export var constitution: int = 50  # HP multiplier, stagger resistance
@export var dexterity: int = 50     # Speed multiplier (move + attack)
@export var move_speed: = 150.0
# Blood drop texture - set this in _ready or via export
@export var blood_drop_texture: Texture2D

# Configuration
@export_group("Wound Lines")
@export var wound_line_color: Color = Color(0.6, 0.0, 0.0, 0.9)  # Dark red
@export var wound_line_width: float = 2.0
@export var wound_line_min_length: float = 8.0
@export var wound_line_max_length: float = 20.0

@export_group("Blood Drops")
@export var blood_drops_min: int = 3
@export var blood_drops_max: int = 8
@export var blood_drop_min_scale: float = 0.3
@export var blood_drop_max_scale: float = 0.8
@export var blood_drop_speed_min: float = 50.0
@export var blood_drop_speed_max: float = 150.0
@export var blood_drop_fade_time: float = 1.5
@export var blood_drop_gravity: float = 0.0  # Set > 0 for top-down gravity effect

@export_group("Severing")
@export var sever_blood_multiplier: float = 3.0  # More blood when severed
@export var stump_color: Color = Color(0.5, 0.0, 0.0, 1.0)  # Dark red stump

# Active wound lines on each limb (LimbType -> Array of Line2D)
var wound_lines: Dictionary = {}

# Pool for blood drop sprites
var blood_pool: Array[Sprite2D] = []
var active_blood_drops: Array[Dictionary] = []

# Track severed limbs for visual updates
var severed_limbs: Dictionary = {}  # LimbType -> bool

var conditions = {}
# Derived stats (calculated from attributes)
var max_hp: int:
	get: return 6 + (constitution)/10 
var max_blood_amount = max_hp
var blood_amount = max_hp

@export var rotation_speed: float:
	get: return 8.0 * (dexterity/50)
	
var consciousness: int:
	get: return blood_amount

var damage_multiplier: float:
	get: return 0.5 + (strength / 100.0)  # 0.5 at STR 0, 1.5 at STR 100

var speed_multiplier: float:
	get: return 0.5 + (dexterity / 100.0)  # Same scaling as damage

var attack_speed_multiplier: float:
	get: return 0.5 + (dexterity / 100.0)  

var clash_power: float:
	get: return strength + (constitution * 0.3)  # STR is main, CON helps brace

# Load from dictionary

func to_data() -> Dictionary:
	return {
		"strength": strength,
		"constitution": constitution,
		"dexterity": dexterity
	}

# Body dimensions (top-down view: width is left-right, height is front-back)
@export var body_width: float = Globals.default_body_width   # Shoulder width (horizontal)
@export var body_height: float = Globals.default_body_height  # Body depth/thickness (vertical in top-down)
@export var head_width: float = Globals.default_head_width   # Head width (left-right)
@export var head_length: float = Globals.default_head_length  # Head length (front-back, oval shape)
@export var shoulder_y_offset: float = Globals.default_shoulder_y_offset # How far back shoulders are from head center (positive = back)

# Collision settings
@export var collision_enabled: bool = true
var collision_radius: float:
	get: return max(body_width, head_width) / 2.0 + 2.0  # Derived from body size
@export var minimum_separation: float = 5.0  # Extra buffer between characters
var collision_shape: CollisionShape2D
var collision_area: Area2D

signal character_reached_target
signal weapon_changed(weapon: WeaponShape)
signal attack_hit(damage: int, damage_type: int)

func _ready() -> void:
	target_position = global_position
	blood_drop_texture = load("res://vfx/blood drop.png")
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_inventory()
	_setup_equipment_slots()
	_setup_attack_system()
	_setup_collision()
	_create_body_parts()
	_initialize_arms()
	initialize_limbs(constitution)
	TimeManager.time_updated.connect(_on_time_updated)

# Add this to your _ready() function:
func _setup_action_queue() -> void:
	action_queue = ActionQueue.new()
	action_queue.name = "ActionQueue"
	add_child(action_queue)
	
	# Configure queue behavior
	action_queue.max_queue_size = 10
	action_queue.queue_only_when_paused = false  # Set true if you only want queueing while paused
	
	# Optional: connect to signals for UI feedback
	action_queue.action_queued.connect(_on_action_queued)
	action_queue.action_started.connect(_on_action_started)
	action_queue.action_completed.connect(_on_action_completed)

# Optional signal handlers for UI feedback
func _on_action_queued(action: ActionQueue.Action) -> void:
	print("Action queued: ", ActionQueue.ActionType.keys()[action.type])

func _on_action_started(action: ActionQueue.Action) -> void:
	print("Action started: ", ActionQueue.ActionType.keys()[action.type])

func _on_action_completed(action: ActionQueue.Action) -> void:
	print("Action completed: ", ActionQueue.ActionType.keys()[action.type])

func _setup_inventory() -> void:
	inventory = Inventory.new()
	inventory.name = "Inventory"
	add_child(inventory)
	
	# Connect to weapon change signals
	inventory.active_weapon_changed.connect(_on_active_weapon_changed)
	
	# Create weapon holder (attaches to right hand position)
	main_hand_holder = Node2D.new()
	off_hand_holder = Node2D.new()
	main_hand_holder.name = "WeaponHolder"
	off_hand_holder.name = "OffHandHolder"
	#look here for updating to dual hand system.
	add_child(main_hand_holder)
	add_child(off_hand_holder)

func _setup_equipment_slots() -> void:
	# Create holder nodes for each equipment slot
	back_slot = Node2D.new()
	back_slot.name = "BackSlot"
	back_slot.z_index = -3  # Behind everything
	add_child(back_slot)
	
	# Legs slot (pants) - behind body but above back
	legs_slot = Node2D.new()
	legs_slot.name = "LegsSlot"
	legs_slot.z_index = -3  # Same level as legs
	add_child(legs_slot)
	
	# Feet slot (boots) - at leg level
	feet_slot = Node2D.new()
	feet_slot.name = "FeetSlot"
	feet_slot.z_index = -3
	add_child(feet_slot)
	
	# Torso slot (breastplate, armor) - covers body, above arms
	torso_slot = Node2D.new()
	torso_slot.name = "TorsoSlot"
	torso_slot.z_index = 0  # At body level, above arms
	add_child(torso_slot)
	
	head_slot = Node2D.new()
	head_slot.name = "HeadSlot"
	head_slot.z_index = 2  # Above head
	add_child(head_slot)

func _setup_attack_system() -> void:
	attack_animator = AttackAnimator.new()
	attack_animator.name = "AttackAnimator"
	add_child(attack_animator)
	
	# Connect attack signals
	attack_animator.attack_hit_frame.connect(_on_attack_hit)
	attack_animator.attack_finished.connect(_on_attack_finished)

func _setup_collision() -> void:
	if not collision_enabled:
		return
	
	# Create Area2D for collision detection
	collision_area = Area2D.new()
	collision_area.name = "CollisionArea"
	collision_area.collision_layer = 2  # Character collision layer
	collision_area.collision_mask = 2   # Detect other characters
	add_child(collision_area)
	
	# Create polygon collision shape based on body dimensions
	collision_shape = CollisionShape2D.new()
	collision_shape.name = "CollisionShape"
	var polygon = ConvexPolygonShape2D.new()
	polygon.points = _get_body_collision_points()
	collision_shape.shape = polygon
	collision_area.add_child(collision_shape)

func _update_collision_shape() -> void:
	# Call this if body dimensions change at runtime
	if collision_shape and collision_shape.shape is ConvexPolygonShape2D:
		collision_shape.shape.points = _get_body_collision_points()

func _get_body_collision_points() -> PackedVector2Array:
	"""Get the local-space collision polygon points matching body hitbox"""
	var half_width = body_width / 2
	var top = -head_length * 0.35
	var bottom = shoulder_y_offset + leg_length
	
	# Return points in clockwise or counter-clockwise order
	return PackedVector2Array([
		Vector2(-half_width, top),      # top-left
		Vector2(half_width, top),       # top-right
		Vector2(half_width, bottom),    # bottom-right
		Vector2(-half_width, bottom)    # bottom-left
	])

func get_overlapping_characters() -> Array[ProceduralCharacter]:
	"""Get all characters currently overlapping with this one"""
	var result: Array[ProceduralCharacter] = []
	if not collision_area:
		return result
	
	for area in collision_area.get_overlapping_areas():
		var parent = area.get_parent()
		if parent is ProceduralCharacter and parent != self:
			result.append(parent)
	return result

func get_separation_vector() -> Vector2:
	"""Calculate a vector to push this character away from overlapping characters"""
	var separation = Vector2.ZERO
	var overlapping = get_overlapping_characters()
	
	for other in overlapping:
		var to_self = global_position - other.global_position
		var distance = to_self.length()
		var min_dist = collision_radius + other.collision_radius + minimum_separation
		
		if distance < min_dist and distance > 0.01:
			# Calculate push strength (stronger when closer)
			var overlap = min_dist - distance
			var push_dir = to_self.normalized()
			separation += push_dir * overlap
		elif distance <= 0.01:
			# Characters are at same position, push in random direction
			separation += Vector2(randf() - 0.5, randf() - 0.5).normalized() * min_dist
	
	return separation

# Updated load_from_data function
func load_from_data(data: Dictionary) -> void:
	character_data = data
	if data.has("name"):
		Name = data["name"]
	# Parse skin color
	if data.has("skin_color"):
		skin_color = Color.html(data["skin_color"])
	
	# Parse hair color
	if data.has("hair_color"):
		hair_color = Color.html(data["hair_color"])
	
	# Parse hair style
	if data.has("hair_style"):
		hair_style = _parse_hair_style(data["hair_style"])
	
	# Parse faction
	if data.has("faction"):
		faction_id = data["faction"]
	
	# Body is darker to appear "below" head
	body_color = skin_color.darkened(0.15)
	
	# Apply other properties
	if data.has("move_speed"):
		move_speed = data["move_speed"]
	
	if data.has("body_width"):
		if data.has("size"):
			if data.size == "default":
				pass
			else:
				body_width = data["body_width"]
	
	if data.has("body_height"):
		if data.has("size"):
			if data.size == "default":
				pass
			else:
				body_height = data["body_height"]
	
	if data.has("head_width"):
		if data.has("size"):
			if data.size == "default":
				pass
			else:
				head_width = data["head_width"]
	
	if data.has("head_length"):
		if data.has("size"):
			if data.size == "default":
				pass
			else:
				head_length = data["head_length"]
	if data.has("strength"): strength = data["strength"]
	if data.has("constitution"): constitution = data["constitution"]
	if data.has("dexterity"): dexterity = data["dexterity"]
	# Also accept short forms
	if data.has("str"): strength = data["str"]
	if data.has("con"): constitution = data["con"]
	if data.has("dex"): dexterity = data["dex"]
	# Update visuals
	_update_colors()

func _parse_hair_style(style_name: String) -> HairStyle:
	match style_name.to_lower():
		"none", "bald":
			return HairStyle.NONE
		"horseshoe", "balding", "receding":
			return HairStyle.HORSESHOE
		"full", "normal", "default":
			return HairStyle.FULL
		"combover", "comb_over", "comb-over":
			return HairStyle.COMBOVER
		"pompadour", "pomp":
			return HairStyle.POMPADOUR
		"buzzcut", "buzz", "short":
			return HairStyle.BUZZCUT
		"mohawk":
			return HairStyle.MOHAWK
		_:
			return HairStyle.FULL

func _create_body_parts() -> void:
	# Create legs first (behind everything else)
	left_leg = _create_leg("LeftLeg")
	left_leg.z_index = -3
	add_child(left_leg)
	
	right_leg = _create_leg("RightLeg")
	right_leg.z_index = -3
	add_child(right_leg)
	
	# Create arms (behind body)
	left_arm = _create_arm("LeftArm")
	left_arm.z_index = -2
	add_child(left_arm)
	
	right_arm = _create_arm("RightArm")
	right_arm.z_index = -2
	add_child(right_arm)
	
	# Create body (horizontal capsule for top-down view - shoulders)
	body = Line2D.new()
	body.name = "Body"
	body.width = body_height  # Height becomes the "thickness" in top-down
	body.default_color = skin_color  # Same color as head - uniform body color
	body.begin_cap_mode = Line2D.LINE_CAP_ROUND
	body.end_cap_mode = Line2D.LINE_CAP_ROUND
	body.z_index = -1  # Behind head
	add_child(body)
	
	# Body is a horizontal line (left shoulder to right shoulder), positioned behind head
	body.add_point(Vector2(-body_width / 2, shoulder_y_offset))
	body.add_point(Vector2(body_width / 2, shoulder_y_offset))
	
	# Create hair based on style
	_create_hair()
	
	# Create head (oval shape - vertical line with width for left-right dimension)
	head = Line2D.new()
	head.name = "Head"
	head.width = head_width  # Width of the oval (left-right)
	head.default_color = skin_color
	head.begin_cap_mode = Line2D.LINE_CAP_ROUND
	head.end_cap_mode = Line2D.LINE_CAP_ROUND
	head.z_index = 1  # On top of hair
	add_child(head)
	
	# Head is an oval - line goes front to back, width gives left-right dimension
	# Negative Y = front (face), Positive Y = back of head
	head.add_point(Vector2(0, -head_length * 0.35))  # Front of head (face)
	head.add_point(Vector2(0, head_length * 0.25))   # Back of head (covered by hair)

func _create_hair() -> void:
	# Remove existing hair if any
	if hair:
		hair.queue_free()
		hair = null
	
	# Remove any additional hair components
	for child in get_children():
		if child.name.begins_with("Hair"):
			child.queue_free()
	
	if hair_style == HairStyle.NONE:
		return
	
	match hair_style:
		HairStyle.HORSESHOE:
			_create_horseshoe_hair()
		HairStyle.FULL:
			_create_full_hair()
		HairStyle.COMBOVER:
			_create_combover_hair()
		HairStyle.POMPADOUR:
			_create_pompadour_hair()
		HairStyle.BUZZCUT:
			_create_buzzcut_hair()
		HairStyle.MOHAWK:
			_create_mohawk_hair()

func _create_horseshoe_hair() -> void:
	# Original hair style - receding/balding with hair on sides and back
	hair = Line2D.new()
	hair.name = "Hair"
	hair.width = head_width + 4  # Slightly wider than head
	hair.default_color = hair_color
	hair.begin_cap_mode = Line2D.LINE_CAP_ROUND
	hair.end_cap_mode = Line2D.LINE_CAP_ROUND
	hair.z_index = 0  # Behind head
	add_child(hair)
	
	# Hair covers only the back portion of the head
	hair.add_point(Vector2(0, -head_length * 0.1))
	hair.add_point(Vector2(0, head_length * 0.4))

func _create_full_hair() -> void:
	# Full head of hair - covers most of the head from top-down view
	hair = Line2D.new()
	hair.name = "Hair"
	hair.width = head_width + 6  # Wider than head for full coverage
	hair.default_color = hair_color
	hair.begin_cap_mode = Line2D.LINE_CAP_ROUND
	hair.end_cap_mode = Line2D.LINE_CAP_ROUND
	hair.z_index = 0  # Behind head
	add_child(hair)
	
	# Hair extends from front to back, covering most of the head
	hair.add_point(Vector2(0, -head_length * 0.3))  # Near front
	hair.add_point(Vector2(0, head_length * 0.45))  # Past back

func _create_combover_hair() -> void:
	# Comb over - hair swept from one side to the other
	# Main hair mass on one side
	hair = Line2D.new()
	hair.name = "Hair"
	hair.width = head_width * 0.7
	hair.default_color = hair_color
	hair.begin_cap_mode = Line2D.LINE_CAP_ROUND
	hair.end_cap_mode = Line2D.LINE_CAP_ROUND
	hair.z_index = 0
	add_child(hair)
	
	# Hair sweeps from left side across the top
	hair.add_point(Vector2(-head_width * 0.35, -head_length * 0.1))
	hair.add_point(Vector2(head_width * 0.2, -head_length * 0.25))
	hair.add_point(Vector2(head_width * 0.35, head_length * 0.1))
	
	# Back portion of hair
	var hair_back = Line2D.new()
	hair_back.name = "HairBack"
	hair_back.width = head_width + 2
	hair_back.default_color = hair_color
	hair_back.begin_cap_mode = Line2D.LINE_CAP_ROUND
	hair_back.end_cap_mode = Line2D.LINE_CAP_ROUND
	hair_back.z_index = -1  # Further behind
	add_child(hair_back)
	
	hair_back.add_point(Vector2(0, head_length * 0.1))
	hair_back.add_point(Vector2(0, head_length * 0.4))

func _create_pompadour_hair() -> void:
	# Pompadour - high volume at the front swept back
	# Main pompadour volume at front
	hair = Line2D.new()
	hair.name = "Hair"
	hair.width = head_width + 8  # Extra wide for volume
	hair.default_color = hair_color
	hair.begin_cap_mode = Line2D.LINE_CAP_ROUND
	hair.end_cap_mode = Line2D.LINE_CAP_ROUND
	hair.z_index = 1  # In front of head for the pomp
	add_child(hair)
	
	# High front portion that extends forward
	hair.add_point(Vector2(0, -head_length * 0.5))  # Extends past front of head
	hair.add_point(Vector2(0, -head_length * 0.2))
	
	# Side and back hair
	var hair_back = Line2D.new()
	hair_back.name = "HairBack"
	hair_back.width = head_width + 4
	hair_back.default_color = hair_color.darkened(0.1)  # Slightly darker for depth
	hair_back.begin_cap_mode = Line2D.LINE_CAP_ROUND
	hair_back.end_cap_mode = Line2D.LINE_CAP_ROUND
	hair_back.z_index = 0  # Behind head
	add_child(hair_back)
	
	hair_back.add_point(Vector2(0, -head_length * 0.15))
	hair_back.add_point(Vector2(0, head_length * 0.45))

func _create_buzzcut_hair() -> void:
	# Buzzcut - very short hair all over, just a slight texture on the head
	hair = Line2D.new()
	hair.name = "Hair"
	hair.width = head_width + 2  # Just slightly wider than head
	hair.default_color = hair_color.darkened(0.2)  # Darker because it's so short
	hair.begin_cap_mode = Line2D.LINE_CAP_ROUND
	hair.end_cap_mode = Line2D.LINE_CAP_ROUND
	hair.z_index = 0  # Behind head
	add_child(hair)
	
	# Covers the whole head tightly
	hair.add_point(Vector2(0, -head_length * 0.32))
	hair.add_point(Vector2(0, head_length * 0.35))

func _create_mohawk_hair() -> void:
	# Mohawk - strip of hair down the middle
	hair = Line2D.new()
	hair.name = "Hair"
	hair.width = head_width * 0.35  # Narrow strip
	hair.default_color = hair_color
	hair.begin_cap_mode = Line2D.LINE_CAP_ROUND
	hair.end_cap_mode = Line2D.LINE_CAP_ROUND
	hair.z_index = 1  # On top of head
	add_child(hair)
	
	# Strip from front to back, slightly elevated
	hair.add_point(Vector2(0, -head_length * 0.45))  # Front spike
	hair.add_point(Vector2(0, head_length * 0.35))   # Back

# Add this to your _update_colors function if you have one, or create it
func _update_hair_colors() -> void:
	if hair:
		if hair_style == HairStyle.BUZZCUT:
			hair.default_color = hair_color.darkened(0.2)
		else:
			hair.default_color = hair_color
	
	# Update any secondary hair components
	var hair_back = get_node_or_null("HairBack")
	if hair_back:
		if hair_style == HairStyle.POMPADOUR:
			hair_back.default_color = hair_color.darkened(0.1)
		else:
			hair_back.default_color = hair_color
func _create_leg(leg_name: String) -> Line2D:
	var leg = Line2D.new()
	leg.name = leg_name
	leg.default_color = skin_color
	leg.begin_cap_mode = Line2D.LINE_CAP_ROUND
	leg.end_cap_mode = Line2D.LINE_CAP_ROUND
	leg.width = leg_width
	
	# Initial leg position (will be updated by animation)
	# Legs extend backward from the body (positive Y)
	var is_left = leg_name == "LeftLeg"
	var x_offset = -leg_spacing if is_left else leg_spacing
	leg.add_point(Vector2(x_offset, shoulder_y_offset + 2))  # Hip
	leg.add_point(Vector2(x_offset, shoulder_y_offset + 2 + leg_length))  # Foot
	
	return leg

func _create_arm(arm_name: String) -> Line2D:
	var arm = Line2D.new()
	arm.name = arm_name
	arm.default_color = skin_color
	arm.begin_cap_mode = Line2D.LINE_CAP_ROUND
	arm.end_cap_mode = Line2D.LINE_CAP_ROUND
	
	# Create width curve for arm (thicker at shoulder, thinner at hand)
	var curve = Curve.new()
	curve.add_point(Vector2(0.0, 1.0))    # Shoulder: full width
	curve.add_point(Vector2(0.4, 0.85))   # Upper arm
	curve.add_point(Vector2(0.6, 0.7))    # Forearm
	curve.add_point(Vector2(1.0, 0.5))    # Hand: half width
	arm.width_curve = curve
	arm.width = 7.0*Globals.default_body_scale  # Smaller for top-down view
	
	return arm

func _initialize_arms() -> void:
	# Initialize joint arrays
	left_arm_joints.clear()
	right_arm_joints.clear()
	
	# Shoulders are at the BACK of the body (positive Y = behind)
	# Left arm extends to the LEFT (negative X)
	var left_shoulder = Vector2(-body_width / 2, shoulder_y_offset)
	left_arm_joints.append(left_shoulder)
	var pos = left_shoulder
	for length in ARM_SEGMENT_LENGTHS:
		pos += Vector2(-length, 0)  # Extend left
		left_arm_joints.append(pos)
	left_arm_target = left_arm_joints[-1]
	
	# Right arm extends to the RIGHT (positive X)
	var right_shoulder = Vector2(body_width / 2, shoulder_y_offset)
	right_arm_joints.append(right_shoulder)
	pos = right_shoulder
	for length in ARM_SEGMENT_LENGTHS:
		pos += Vector2(length, 0)  # Extend right
		right_arm_joints.append(pos)
	right_arm_target = right_arm_joints[-1]
	
	_update_arm_visuals()

func _update_colors() -> void:
	if body:
		body.default_color = skin_color  # Same as head
	if head:
		head.default_color = skin_color
	if hair:
		hair.default_color = hair_color
	if left_arm:
		left_arm.default_color = skin_color
	if right_arm:
		right_arm.default_color = skin_color
	if left_leg:
		left_leg.default_color = skin_color
	if right_leg:
		right_leg.default_color = skin_color

func _process(delta: float) -> void:
	_handle_input()
	if not PauseManager.is_paused:
		handle_visual_shake(delta)
		_update_movement(delta)
		_update_leg_animation(delta)
		_update_body_rotation()
		_update_arm_ik()
		_update_arm_visuals()
		_update_weapon_position()
		_update_blood_drops(delta)
		_update_severed_limb_visuals()
		# Update timers
		attack_cooldown_timer = max(0, attack_cooldown_timer - delta)
		reaction_timer = max(0, reaction_timer - delta)
		stun_timer = max(0, stun_timer - delta)
		state_timer += delta
		# Add check if the character is AI controlled
		if AI_enabled:
			# Handle stunned state
			if current_state == AIState.STUNNED:
				if stun_timer <= 0:
					_change_state(AIState.IDLE)
				return
			
			# Update target
			_update_target()
			
			# State machine
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
func handle_visual_shake(delta) -> void:
	if current_shake_intensity > 0:
		print("Im literally shaking: ", current_shake_intensity)
		current_shake_intensity = move_toward(current_shake_intensity, 0, shake_decay_rate * delta)
		# Generate random jitter based on intensity
		current_shake_offset = Vector2(
			randf_range(-1.0, 1.0),
			randf_range(-1.0, 1.0)
		) * current_shake_intensity
	else:
		current_shake_offset = Vector2.ZERO	
func shake_body(intensity: float) -> void:
	"""
	Applies a visual shake to the character.
	intensity: How many pixels to offset (e.g., 5.0 is a mild hit, 15.0 is a heavy hit)
	"""
	current_shake_intensity = intensity
func get_shake_offset() -> Vector2:
	"""Add this to your character sprite's position in your main script"""
	return current_shake_offset	
func _update_body_rotation() -> void:
	# Apply body rotation during attacks
	var body_rotation = 0.0
	if attack_animator and attack_animator.is_attacking:
		body_rotation = attack_animator.get_body_rotation()
	
	# Update body line (shoulders)
	if body:
		var left_shoulder = Vector2(-body_width / 2, shoulder_y_offset).rotated(body_rotation)
		var right_shoulder = Vector2(body_width / 2, shoulder_y_offset).rotated(body_rotation)
		body.clear_points()
		body.add_point(left_shoulder)
		body.add_point(right_shoulder)
	
	# Update head position/rotation (head follows body slightly)
	if head:
		var head_rotation = body_rotation * 0.5  # Head follows less than body
		head.rotation = head_rotation
	
	# Update hair to follow head
	if hair:
		hair.rotation = head.rotation if head else 0.0

func _update_leg_animation(delta: float) -> void:
	if is_moving:
		# Advance leg swing time while moving
		leg_swing_time += delta * leg_swing_speed
	else:
		# Smoothly return to rest when stopped - wrap to nearest multiple of 2*PI first
		# This prevents the stutter by finding the nearest rest position
		var target_time = round(leg_swing_time / TAU) * TAU
		leg_swing_time = lerpf(leg_swing_time, target_time, delta * 5.0)
		# Snap when very close to avoid endless tiny movements
		if abs(leg_swing_time - target_time) < 0.01:
			leg_swing_time = target_time
	
	# Calculate swing offset using sine wave
	var swing = sin(leg_swing_time) * leg_swing_amount
	
	# Update leg positions
	# In top-down view: -Y is FORWARD (toward top of screen when character faces up)
	# Legs should extend forward (-Y direction) from hips
	var hip_y = shoulder_y_offset + 2
	
	# Calculate leg positions - feet go FORWARD (negative Y)
	var left_hip = Vector2(-leg_spacing, hip_y)
	var left_foot = Vector2(-leg_spacing + swing * 0.3, hip_y - leg_length + swing)  # -leg_length = forward
	var right_hip = Vector2(leg_spacing, hip_y)
	var right_foot = Vector2(leg_spacing - swing * 0.3, hip_y - leg_length - swing)  # -leg_length = forward
	
	if left_leg:
		left_leg.clear_points()
		left_leg.add_point(left_hip)
		left_leg.add_point(left_foot)
	
	if right_leg:
		right_leg.clear_points()
		right_leg.add_point(right_hip)
		right_leg.add_point(right_foot)
	
	# Update leg equipment (pants and boots)
	if legs_equipment:
		legs_equipment.update_leg_positions(left_hip, left_foot, right_hip, right_foot)
	if feet_equipment:
		feet_equipment.update_leg_positions(left_hip, left_foot, right_hip, right_foot)

func _handle_input() -> void:
	if AI_enabled:
		return
	
	var mouse_pos = _get_adjusted_mouse_position()
	var paused = PauseManager.is_paused
	
	# When paused: queue actions
	# When unpaused: execute immediately (queue processes automatically)
	
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		current_hand = "Off"
		if paused:
			action_queue.queue_face(mouse_pos)
			action_queue.queue_attack()
			
		else:
			target_rotation = (mouse_pos - global_position).angle() + PI / 2
			attack()
			
	
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Input.is_key_pressed(KEY_B):
		current_hand = "Main"
		print("attack key pressed, checking if this works while paused")
		if paused:
			action_queue.queue_attack()
		else:
			target_rotation = (mouse_pos - global_position).angle() + PI / 2
			attack()
			
	
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE) :
		if paused:
			action_queue.queue_move(mouse_pos)
		else:
			target_position = mouse_pos
			target_rotation = (mouse_pos - global_position).angle() + PI / 2
			is_moving = true
	
	if Input.is_action_just_pressed("ui_focus_next"):
		if paused:
			action_queue.queue_cycle_weapon(1)
		else:
			inventory.cycle_weapon(1)
	
	if Input.is_action_just_pressed("ui_focus_prev"):
		if paused:
			action_queue.queue_cycle_weapon(-1)
		else:
			inventory.cycle_weapon(-1)
	
	# Queue management (only when paused)
	if paused:
		if Input.is_action_just_pressed("ui_cancel"):
			action_queue.cancel_all()

func _get_adjusted_mouse_position() -> Vector2:
	# Check if we're inside a SubViewport
	var vp = get_viewport()
	var parent = vp.get_parent()
	
	if parent is SubViewportContainer:
		# Get mouse position relative to the container
		var container = parent as SubViewportContainer
		var screen_mouse = DisplayServer.mouse_get_position()
		var window_pos = get_window().position
		var local_mouse = Vector2(screen_mouse) - Vector2(window_pos)
		
		# Account for container position and scaling
		local_mouse -= container.global_position
		
		# Scale factor between container and viewport
		var scale_factor = Vector2(vp.size) / container.size
		local_mouse *= scale_factor
		
		# Convert to global coords within the SubViewport
		# We need to account for camera/transform
		var canvas_transform = vp.canvas_transform
		return canvas_transform.affine_inverse() * local_mouse
	else:
		# Regular viewport, use standard method
		return get_global_mouse_position()

func _update_movement(delta: float) -> void:
	# Smoothly rotate toward target
	var angle_diff = wrapf(target_rotation - rotation, -PI, PI)
	rotation += sign(angle_diff) * min(abs(angle_diff), rotation_speed * delta)
	
	# Move toward target if moving
	if is_moving:
		var to_target = target_position - global_position
		var distance = to_target.length()
		
		if distance > 5.0:
			var move_dir = to_target.normalized()
			global_position += move_dir * min(move_speed * delta, distance)
		else:
			is_moving = false
			emit_signal("character_reached_target")
	
	# Apply collision separation
	if collision_enabled:
		var separation = get_separation_vector()
		if separation.length() > 0.1:
			# Apply separation force (scaled by delta for smooth movement)
			global_position += separation * min(1.0, delta * 10.0)

func _update_arm_ik() -> void:
	# Shoulder positions - at the sides and toward the back
	var left_shoulder = Vector2(-body_width / 2, shoulder_y_offset)
	var right_shoulder = Vector2(body_width / 2, shoulder_y_offset)
	var arm_length = ARM_SEGMENT_LENGTHS[0] + ARM_SEGMENT_LENGTHS[1] + ARM_SEGMENT_LENGTHS[2]
	
	# Get attack animation offset and body rotation if attacking
	var attack_offset = Vector2.ZERO
	var body_rotation = 0.0
	
	# Determine which hand is currently active/dominant
	var is_off_hand = current_hand == "Off"
	
	if attack_animator and attack_animator.is_attacking:
		attack_offset = attack_animator.get_arm_offset()
		body_rotation = attack_animator.get_body_rotation()
	
	# Apply body rotation to shoulders
	if body_rotation != 0.0:
		left_shoulder = left_shoulder.rotated(body_rotation)
		right_shoulder = right_shoulder.rotated(body_rotation)
	
	# Check if we are in a "combat state" (attacking or holding a weapon)
	# (Updated condition to check for EITHER weapon or active attack)
	var in_combat_stance = (current_main_hand_weapon != null) or (current_off_hand_weapon != null) or (attack_animator and attack_animator.is_attacking)

	if in_combat_stance:
		# Define the "Active" arm base target (bent arm close to body)
		# If Off-Hand, we flip the X offset to the left side
		var active_base_x = -arm_length * 0.05 if is_off_hand else arm_length * 0.05
		var base_target = Vector2(active_base_x, -arm_length * 0.5)
		
		# Apply body rotation to the base target
		if body_rotation != 0.0:
			base_target = base_target.rotated(body_rotation)
		
		# Define the "Ready" arm base (the non-attacking hand)
		# If Off-Hand is active, Right arm is "Ready". If Main is active, Left arm is "Ready".
		var ready_shoulder = right_shoulder if is_off_hand else left_shoulder
		
		# Flip the X offset for the ready position if we are checking the Right arm
		var ready_x_offset = -arm_length * 0.2 if is_off_hand else arm_length * 0.2
		var ready_base = ready_shoulder + Vector2(ready_x_offset, -arm_length * 0.5)
		
		if body_rotation != 0.0:
			ready_base = ready_base.rotated(body_rotation * 0.3)
		
		# ASSIGN TARGETS BASED ON HAND
		if is_off_hand:
			# Left Arm gets the Attack Offset
			left_arm_target = base_target + attack_offset
			# Right Arm is in Ready position
			right_arm_target = ready_base
		else:
			# Right Arm gets the Attack Offset
			right_arm_target = base_target + attack_offset
			# Left Arm is in Ready position
			left_arm_target = ready_base
			
	else:
		# Rest positions: arms curling forward and inward (hands near front of body)
		left_arm_target = left_shoulder + Vector2(arm_length * 0.3, -arm_length * 0.6)
		right_arm_target = right_shoulder + Vector2(-arm_length * 0.3, -arm_length * 0.6)
	
	# Solve IK for both arms
	_solve_arm_ik(left_arm_joints, left_arm_target, true)
	_solve_arm_ik(right_arm_joints, right_arm_target, false)

func _solve_arm_ik(joints: Array[Vector2], target: Vector2, is_left: bool) -> void:
	var shoulder_pos = Vector2(-body_width / 2, shoulder_y_offset) if is_left else Vector2(body_width / 2, shoulder_y_offset)
	
	for _iter in range(IK_ITERATIONS):
		# Forward pass: end to base
		joints[-1] = target
		for i in range(ARM_SEGMENT_LENGTHS.size() - 1, -1, -1):
			var dir = (joints[i] - joints[i + 1]).normalized()
			joints[i] = joints[i + 1] + dir * ARM_SEGMENT_LENGTHS[i]
		
		# Backward pass: base to end
		joints[0] = shoulder_pos
		for i in range(ARM_SEGMENT_LENGTHS.size()):
			var dir = (joints[i + 1] - joints[i]).normalized()
			var constrained = _apply_arm_constraint(joints, i, dir, is_left)
			joints[i + 1] = joints[i] + constrained * ARM_SEGMENT_LENGTHS[i]

func _apply_arm_constraint(joints: Array[Vector2], joint_idx: int, direction: Vector2, is_left: bool) -> Vector2:
	var angle = direction.angle()
	
	# Get parent angle
	var parent_angle: float
	if joint_idx == 0:
		# Shoulder: default arm direction is outward horizontally
		if is_left:
			parent_angle = PI  # 180 degrees (pointing left)
		else:
			parent_angle = 0.0  # 0 degrees (pointing right)
	else:
		var parent_dir = joints[joint_idx] - joints[joint_idx - 1]
		parent_angle = parent_dir.angle()
	
	var relative_angle = angle - parent_angle
	
	# Normalize
	while relative_angle > PI:
		relative_angle -= TAU
	while relative_angle < -PI:
		relative_angle += TAU
	
	# Apply constraints
	var constraint = ARM_JOINT_CONSTRAINTS[joint_idx]
	var min_ang = deg_to_rad(constraint.x)
	var max_ang = deg_to_rad(constraint.y)
	
	if is_left:
		# Mirror the constraints for left arm
		var temp = -max_ang
		max_ang = -min_ang
		min_ang = temp
	
	relative_angle = clamp(relative_angle, min_ang, max_ang)
	
	return Vector2.from_angle(parent_angle + relative_angle)

func _update_arm_visuals() -> void:
	if left_arm:
		left_arm.clear_points()
		for joint in left_arm_joints:
			left_arm.add_point(joint)
	
	if right_arm:
		right_arm.clear_points()
		for joint in right_arm_joints:
			right_arm.add_point(joint)

func _update_weapon_position() -> void:
	#look here for dual hand updates
	# Position weapon at the right hand (last joint of right arm)
	if left_arm_joints.size() > 0:
		var off_hand_pos = left_arm_joints[-1]
		off_hand_holder.position = off_hand_pos
		var off_hand_attack_rotation = 0.0
		if attack_animator and attack_animator.is_attacking:
			off_hand_attack_rotation = attack_animator.get_weapon_rotation()
		
	if right_arm_joints.size() > 0:
		var main_hand_pos = right_arm_joints[-1]
		main_hand_holder.position = main_hand_pos
		
		# Apply attack animation rotation if attacking
		var main_hand_attack_rotation = 0.0
		if attack_animator and attack_animator.is_attacking:
			main_hand_attack_rotation = attack_animator.get_weapon_rotation()
		
		main_hand_holder.rotation = main_hand_attack_rotation

func _on_active_weapon_changed(weapon, hand) -> void:
	# Remove old weapon from holder
	if hand == "Main":
		if current_main_hand_weapon != null:
			main_hand_holder.remove_child(current_main_hand_weapon)
			# Don't free it - it's still in the inventory
		
		current_main_hand_weapon = weapon
		
		# Add new weapon to holder
		if current_main_hand_weapon != null:
			main_hand_holder.add_child(current_main_hand_weapon)
			# Position weapon so the grip aligns with the hand
			# The sprite's origin is at center, but we want the grip point at holder origin
			# grip_position is 0-1 where 0=tip, 1=pommel
			# For a vertical weapon sprite: grip is at (grip_position) from top
			# We need to offset the sprite so that grip point is at (0,0)
			var grip_offset = current_main_hand_weapon.get_grip_offset_for_hand()
			current_main_hand_weapon.position = grip_offset
			current_main_hand_weapon.z_index = 2  # Above character
	if hand	== "Off":
		if current_off_hand_weapon != null:
			off_hand_holder.remove_child(current_off_hand_weapon)
			# Don't free it - it's still in the inventory
		
		current_off_hand_weapon = weapon
		
		# Add new weapon to holder
		if current_off_hand_weapon != null:
			off_hand_holder.add_child(current_off_hand_weapon)
			# Position weapon so the grip aligns with the hand
			# The sprite's origin is at center, but we want the grip point at holder origin
			# grip_position is 0-1 where 0=tip, 1=pommel
			# For a vertical weapon sprite: grip is at (grip_position) from top
			# We need to offset the sprite so that grip point is at (0,0)
			var grip_offset = current_off_hand_weapon.get_grip_offset_for_hand()
			current_off_hand_weapon.position = grip_offset
			current_off_hand_weapon.z_index = 2  # Above character
	emit_signal("weapon_changed", weapon)

func _on_attack_hit(ability) -> void:
	if ability== "Main":
	# Called when attack hits (at the impact frame)
		emit_signal("attack_hit", current_main_hand_weapon.base_damage, current_main_hand_weapon.primary_damage_type)
	if ability == "Off":
		emit_signal("attack_hit", current_off_hand_weapon.base_damage, current_off_hand_weapon.primary_damage_type)

func _on_attack_finished() -> void:
	# Called when attack animation completes
	pass

# ===== PUBLIC ATTACK API =====

func attack(Ability:String= "Main") -> void:
	"""Perform an attack with current weapon"""
	if Ability == "Main": 
		if attack_animator.is_attacking:
			return  # Already attacking
		
		# Get damage type from weapon and start appropriate animation
		var damage_type
		if current_main_hand_weapon != null:
			damage_type = current_main_hand_weapon.primary_damage_type
		else:
			damage_type = unarmed_strike_damage_type
		if damage_type == "slashing":
			SfxManager.play("slash",position)
		attack_animator.start_attack(damage_type)
	if Ability == "Off": 
		if attack_animator.is_attacking:
			return  # Already attacking
		# Get damage type from weapon and start appropriate animation
		var damage_type
		if current_off_hand_weapon != null:
			damage_type = current_off_hand_weapon.primary_damage_type
		else:
			damage_type = unarmed_strike_damage_type
		if damage_type == "slashing":
			SfxManager.play("slash",position)
		attack_animator.start_attack(damage_type)

func is_attacking() -> bool:
	"""Check if currently performing an attack"""
	#print("Does character think they're attacking? ", attack_animator.is_attacking)
	return attack_animator.is_attacking

# ===== PUBLIC WEAPON API =====

func give_weapon(weapon_data: Dictionary, hand = "Main") -> WeaponShape:
	"""Give the character a weapon from data and equip it"""
	print("give weapon being run with: ", weapon_data.name, "in hand ", hand)
	return inventory.equip_weapon_from_data(weapon_data, hand)

func give_weapon_by_name(weapon_name: String, hand:String = "Main") -> WeaponShape:
	"""Give the character a weapon by looking up its name in the database"""
	var db = ProceduralItemDatabase.weapons
	print("giving weapon by name: ", weapon_name)
	#print("weapon database: ", db )
	if db:
		print("weapon database exists")
		#print("the fucking data is structured like: ",db)
		var data = db[weapon_name.to_lower()]
		print("weapon data found: ",data)
		if not data.is_empty():
			return give_weapon(data, hand)
	push_warning("Could not find weapon: %s" % weapon_name)
	return null

func give_weapon_by_type(weapon_type: String) -> WeaponShape:
	"""Quick method to give a weapon by type name (creates default weapon of that type)"""
	return give_weapon({"type": weapon_type})

func cycle_weapon(direction: int = 1) -> void:
	"""Cycle to next/previous weapon"""
	inventory.cycle_weapon(direction)

func holster_weapon() -> void:
	"""Put away current weapon"""
	inventory.holster_weapon()

func draw_weapon() -> void:
	"""Draw first available weapon"""
	inventory.draw_weapon()

func get_current_main_hand_weapon() -> WeaponShape:
	"""Get the currently held weapon"""
	return current_main_hand_weapon

func has_weapon_equipped() -> bool:
	"""Check if character is holding a weapon"""
	return current_main_hand_weapon != null or current_off_hand_weapon != null

# ===== PUBLIC EQUIPMENT API =====

func equip_equipment(equipment_data: Dictionary) -> EquipmentShape:
	"""Equip armor/equipment from data using new shape-based system"""
	var equipment = EquipmentShape.new()
	equipment.load_from_data(equipment_data)
	
	var slot = equipment.get_slot()
	var holder: Node2D = null
	
	match slot:
		EquipmentShape.EquipmentSlot.HEAD:
			if head_equipment:
				head_slot.remove_child(head_equipment)
				head_equipment.queue_free()
			head_equipment = equipment
			holder = head_slot
		EquipmentShape.EquipmentSlot.TORSO:
			if torso_equipment:
				torso_slot.remove_child(torso_equipment)
				torso_equipment.queue_free()
			torso_equipment = equipment
			holder = torso_slot
		EquipmentShape.EquipmentSlot.BACK:
			if back_equipment:
				back_slot.remove_child(back_equipment)
				back_equipment.queue_free()
			back_equipment = equipment
			holder = back_slot
		EquipmentShape.EquipmentSlot.LEGS:
			if legs_equipment:
				legs_slot.remove_child(legs_equipment)
				legs_equipment.queue_free()
			legs_equipment = equipment
			holder = legs_slot
		EquipmentShape.EquipmentSlot.FEET:
			if feet_equipment:
				feet_slot.remove_child(feet_equipment)
				feet_equipment.queue_free()
			feet_equipment = equipment
			holder = feet_slot
	
	if holder:
		holder.add_child(equipment)
	
	return equipment

func unequip_slot(slot: EquipmentShape.EquipmentSlot) -> void:
	"""Remove equipment from a slot"""
	match slot:
		EquipmentShape.EquipmentSlot.HEAD:
			if head_equipment:
				head_slot.remove_child(head_equipment)
				head_equipment.queue_free()
				head_equipment = null
		EquipmentShape.EquipmentSlot.TORSO:
			if torso_equipment:
				torso_slot.remove_child(torso_equipment)
				torso_equipment.queue_free()
				torso_equipment = null
		EquipmentShape.EquipmentSlot.BACK:
			if back_equipment:
				back_slot.remove_child(back_equipment)
				back_equipment.queue_free()
				back_equipment = null
		EquipmentShape.EquipmentSlot.LEGS:
			if legs_equipment:
				legs_slot.remove_child(legs_equipment)
				legs_equipment.queue_free()
				legs_equipment = null
		EquipmentShape.EquipmentSlot.FEET:
			if feet_equipment:
				feet_slot.remove_child(feet_equipment)
				feet_equipment.queue_free()
				feet_equipment = null

func equip_equipment_by_name(equipment_name: String) -> EquipmentShape:
	"""Equip equipment by looking up its name in the database"""
	var db = ProceduralItemDatabase.equipment
	if db:
		#print("The fucking equipment looks like: ",db)
		var data = db[Globals.name_to_id(equipment_name)]
		if not data.is_empty():
			return equip_equipment(data)
	push_warning("Could not find equipment: %s" % equipment_name)
	return null

# ===== PUBLIC FACTION API =====

func get_faction() -> String:
	return faction_id

func set_faction(new_faction_id: String) -> void:
	faction_id = new_faction_id

func get_relationship_with(other_character: ProceduralCharacter) -> Faction.Relationship:
	return game2.factions[faction_id].get_relationship(faction_id, other_character.faction_id)
	
	# Limb identifiers
enum LimbType { HEAD, TORSO, LEFT_ARM, RIGHT_ARM, LEFT_LEG, RIGHT_LEG }

# Limb data structure
class Limb:
	var limb_type: LimbType
	var name: String
	var max_hp: int
	var current_hp: int
	var armor_dr: Dictionary = Globals.DR_0  # Damage Resistance from armor
	var is_disabled: bool = false
	var is_severed: bool = false
	
	# Limb-specific HP multipliers (relative to base)
	const HP_MULTIPLIERS = {
		LimbType.HEAD: 0.4,       # Head is fragile
		LimbType.TORSO: 1.0,      # Torso is the base
		LimbType.LEFT_ARM: 0.5,
		LimbType.RIGHT_ARM: 0.5,
		LimbType.LEFT_LEG: 0.6,
		LimbType.RIGHT_LEG: 0.6
	}
	
	func _init(type: LimbType, base_hp: int) -> void:
		limb_type = type
		name = LimbType.keys()[type].capitalize().replace("_", " ")
		max_hp = int(base_hp * HP_MULTIPLIERS[type])
		current_hp = max_hp
	
	
	func heal(amount: int) -> void:
		if not is_severed:
			current_hp = min(current_hp + amount, max_hp)
			if current_hp > 0:
				is_disabled = false
	
	func set_armor(dr: Dictionary) -> void:
		armor_dr = dr
	
	func get_hp_percent() -> float:
		return float(current_hp) / float(max_hp) if max_hp > 0 else 0.0

# All limbs
var limbs: Dictionary = {}  # LimbType -> Limb

# Reference to owner
var owner_character: Node2D

# Signals
signal limb_damaged(limb_type: LimbType, damage_info: Dictionary)
signal limb_disabled(limb_type: LimbType)
signal limb_severed(limb_type: LimbType)
signal character_died()

func initialize_limbs(base_hp: int) -> void:
	"""Initialize all limbs based on character's max HP"""
	print("initializing limbs")
	limbs.clear()
	for limb_type in LimbType.values():
		limbs[limb_type] = Limb.new(limb_type, base_hp)

func get_limb(limb_type: LimbType) -> Limb:
	return limbs.get(limb_type)

func get_total_hp() -> int:
	"""Get combined HP of all limbs (mainly torso matters for death)"""
	var total = 0
	for limb in limbs.values():
		total += max(0, limb.current_hp)
	return total

func get_torso_hp() -> int:
	"""Torso HP is the main life indicator"""
	var torso = limbs.get(LimbType.TORSO)
	return torso.current_hp if torso else 0

func is_alive() -> bool:
	"""Character dies if torso or head HP <= 0"""
	var torso = limbs.get(LimbType.TORSO)
	var head = limbs.get(LimbType.HEAD)
	#print("limbs and head based is_alive() returns: ", (torso and torso.current_hp > 0) and (head and head.current_hp > 0))
	#print("is alive should return: ", (torso and torso.current_hp > 0) and (head and head.current_hp > 0) and blood_amount > 0)
	return (torso and torso.current_hp > 0) and (head and head.current_hp > 0) and blood_amount > 0

func damage_limb(limb_type: LimbType, damage: Dictionary, location: Vector2):
	"""Apply damage to a specific limb"""
	var limb = limbs.get(limb_type)
	if not limb:
		return {}
	# 1. Get the resistance dictionary for this specific limb
	var armor_dr = get_limb_armor(limb_type) 
	var total_damage = 0
	var raw_val
	var dr_val
# 2. Calculate damage for each type after resistances
	for damage_type in damage:
		raw_val = damage[damage_type]
		dr_val = armor_dr.get(damage_type, 0) # Default to 0 if type not in DR
		if raw_val - dr_val > 0:
			handle_damage_effect_based_on_type(raw_val-dr_val,damage_type, limb_type, location)
		# Ensure damage for a specific type doesn't go below zero
		
		total_damage += max(0, raw_val - dr_val)
		
	# 3. Apply the damage to the limb
	
	limb.current_hp = clamp(limb.current_hp - total_damage, 0, limb.max_hp)
	return total_damage

func set_limb_armor(limb_type: LimbType, dr: Dictionary) -> void:
	"""Set armor DR for a limb"""
	var limb = limbs.get(limb_type)
	if limb:
		limb.set_armor(dr)

func get_limb_armor(limb_type: LimbType) -> Dictionary:
	"""Get current armor DR for a limb"""
	var limb = limbs.get(limb_type)
	return limb.armor_dr if limb else Globals.DR_0 #DR_0 = {"slashing":0, "bludgeoning": 0, "piercing": 0, "sonic": 0, "radiant":0, "necrotic": 0, "fire":0, "cold":0, "acid":0, "poison":0, "force":0 }


# Map equipment slots to limb types for armor
static func get_limb_for_equipment_slot(slot: int) -> Array[LimbType]:
	# EquipmentShape.EquipmentSlot values
	match slot:
		0:  # HEAD
			return [LimbType.HEAD]
		1:  # TORSO
			return [LimbType.TORSO, LimbType.LEFT_ARM, LimbType.RIGHT_ARM]
		3:  # LEGS
			return [LimbType.LEFT_LEG, LimbType.RIGHT_LEG]
		4:  # FEET
			return [LimbType.LEFT_LEG, LimbType.RIGHT_LEG]  # Feet armor protects legs too
		_:
			return []
# Determine which limb was hit based on local hit position
func get_limb_at_position(local_pos: Vector2, body_width: float, body_height: float) -> LimbType:
	"""Determine which limb is at a local position relative to character center"""
	var x = local_pos.x
	var y = local_pos.y
	
	# Head is at front center (negative Y)
	if y < -body_height * 0.3 and abs(x) < body_width * 0.3:
		return LimbType.HEAD
	
	# Arms are to the sides
	if abs(x) > body_width * 0.35:
		if x < 0:
			return LimbType.LEFT_ARM
		else:
			return LimbType.RIGHT_ARM
	
	# Legs are at the back (positive Y in our coordinate system after the fix)
	# Actually legs are forward now (-Y), but let's check lower body area
	if y > body_height * 0.2:
		if x < 0:
			return LimbType.LEFT_LEG
		else:
			return LimbType.RIGHT_LEG
	# Default to torso
	return LimbType.TORSO
func set_stats(str_val: int, con_val: int, dex_val: int) -> void:
	"""Set character stats"""
	strength = str_val
	constitution = con_val
	dexterity = dex_val
	
func get_status_string() -> String:
	"""Get a debug string showing all limb status"""
	var parts = []
	for limb_type in LimbType.values():
		var limb = limbs.get(limb_type)
		if limb:
			var status = "%s: %d/%d" % [limb.name, limb.current_hp, limb.max_hp]
			if limb.is_severed:
				status += " [SEVERED]"
			elif limb.is_disabled:
				status += " [DISABLED]"
			if limb.armor_dr > 0:
				status += " (DR:%d)" % limb.armor_dr
			parts.append(status)
	return "\n".join(parts)
### AI
enum AIState {
	DEAD,           # Does nothing for now, want to implement some spirit world mechanics later
	IDLE,           # No enemies nearby, standing still
	PATROL,         # Moving along patrol path (optional)
	CHASE,          # Moving toward target
	APPROACH,       # Getting into attack range
	ATTACK,         # Performing attack
	RETREAT,        # Backing away (low health, etc)
	STUNNED         # Recovering from hit/stagger
}

# Current state
var current_state: AIState = AIState.IDLE
var state_timer: float = 0.0

# Target tracking
var current_target: ProceduralCharacter = null
var last_known_target_pos: Vector2 = Vector2.ZERO

# Detection settings
@export var detection_range: float = 300.0*Globals.default_body_scale    # How far AI can see enemies
@export var attack_range: float = 70.0 * Globals.default_body_scale         # Range to start attacking
@export var preferred_range: float = 40.0 *Globals.default_body_scale     # Ideal combat distance
@export var too_close_range: float = 20.0 *Globals.default_body_scale     # Back up if closer than this

# Minimum approach distance (prevents walking into other characters)
var min_approach_distance: float:
	get: return collision_radius + minimum_separation + 10.0  # Never get closer than this

# Behavior settings
@export var aggression: float = 0.7           # 0-1, higher = more aggressive
@export var reaction_time: float = 0.15       # Delay before responding
@export var attack_cooldown: float = 0.2      # Minimum time between attacks

# Timing
var attack_cooldown_timer: float = 0.0
var reaction_timer: float = 0.0
var stun_timer: float = 0.0

signal state_changed(old_state: AIState, new_state: AIState)
signal target_acquired(target: ProceduralCharacter)
signal target_lost()
	
func _update_target() -> void:
	"""Find and track enemy targets"""
	#print("attempting to update target")
	# If we have a valid target, check if still valid
	if current_target:
		if not is_instance_valid(current_target):
			print("losing target because instance invalid")
			_lose_target()
			return
		
		if not current_target.is_alive():
			print("losing target because target is dead")
			_lose_target()
			return
		
		# Check if target is now too far
		var dist = self.global_position.distance_to(current_target.global_position)
		if dist > detection_range * 1.5:  # Hysteresis to prevent flickering
			print("losing target because target is too far")
			_lose_target()
			return
		
		# Update last known position
		last_known_target_pos = current_target.global_position
		return
	
	# Search for new target
	var best_target: ProceduralCharacter = null
	var best_distance: float = detection_range
	
	# Get all characters in scene (this could be optimized with groups)
	var characters = game2.characters_in_scene
	#print("Searching for target in: ",characters)
	for node in characters:
		if node == self:
			#print("not targeting self")
			continue
		
		var other = node as ProceduralCharacter
		if not other:
			#print("no other potential targets but self")
			continue
		
		# Check if enemy faction
		if not _is_enemy(other):
			#print("potential target is not an enemy, continuing")
			continue
		#print("enemy target found")
		# Check if alive
		if not other.is_alive():
			continue
		#print("living enemy target found")
		# Check distance
		var dist = self.global_position.distance_to(other.global_position)
		if dist < best_distance:
			print("updating to closer target")
			best_distance = dist
			best_target = other
	
	if best_target:
		print("found best target, attempting to acquire")
		_acquire_target(best_target)

func _is_enemy(other: ProceduralCharacter) -> bool:
	"""Check if other character is an enemy"""
	if self.faction_id == other.faction_id:
		#print("same faction identified")
		return false
	
	# Use faction system if available
	var factions = game2.factions
	if factions:
		#print("My factions enemies are ", factions[self.faction_id].enemies)
		#print("The potential target is in the faction: ", other.faction_id)
		if other.faction_id in factions[self.faction_id].enemies:
			#print("Identified target as enemy")
			return true
	
	# Default: different factions are enemies (except neutral)
	return self.faction_id != "neutral" and other.faction_id != "neutral"

func _acquire_target(target: ProceduralCharacter) -> void:
	current_target = target
	last_known_target_pos = target.global_position
	emit_signal("target_acquired", target)
	print("target acquired")
	# Start reaction delay before responding
	reaction_timer = reaction_time

func _lose_target() -> void:
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

# ===== STATE PROCESSING =====

func _process_idle(delta: float) -> void:
	if current_target and reaction_timer <= 0:
		_change_state(AIState.CHASE)

func _process_chase(delta: float) -> void:
	#print("processing chase")
	if not current_target:
		_change_state(AIState.IDLE)
		return
	
	var dist = self.global_position.distance_to(current_target.global_position)
	
	# Calculate safe approach distance
	var combined_collision_dist = collision_radius + current_target.collision_radius + minimum_separation
	var safe_attack_range = max(attack_range, combined_collision_dist + 5.0)
	
	# Switch to approach when getting close
	if dist <= safe_attack_range * 1.2:
		print("Distance closed, approaching target for attack")
		_change_state(AIState.APPROACH)
		return
	
	# Move toward target, but aim for a position at attack range, not directly on top
	var dir_to_target = (current_target.global_position - self.global_position).normalized()
	var target_pos = current_target.global_position - dir_to_target * safe_attack_range * 0.8
	_move_toward(target_pos)

func _process_approach(delta: float) -> void:
	#print("processing approach")
	if not current_target:
		_change_state(AIState.IDLE)
		return
	
	var dist = self.global_position.distance_to(current_target.global_position)
	var dir_to_target = (current_target.global_position - self.global_position).normalized()
	
	# Calculate combined collision distance (both characters' radii + buffer)
	var combined_collision_dist = collision_radius + current_target.collision_radius + minimum_separation
	var safe_attack_range = max(attack_range, combined_collision_dist + 5.0)
	var safe_preferred_range = max(preferred_range, combined_collision_dist + 10.0)
	var safe_too_close = max(too_close_range, combined_collision_dist)
	
	# Face the target
	self.target_rotation = dir_to_target.angle() + PI / 2
	#print("checking if target is in range")
	# Too far - chase again
	if dist > safe_attack_range * 1.5:
		_change_state(AIState.CHASE)
		return
	
	# In attack range - attack!
	#print("target is in range, attack")
	if dist <= safe_attack_range and dist >= safe_too_close and attack_cooldown_timer <= 0:
		#print("actually attacking target")
		_change_state(AIState.ATTACK)
		return
	
	# Too close - back up to safe distance
	if dist < safe_too_close:
		var retreat_dir = -dir_to_target
		var retreat_pos = self.global_position + retreat_dir * (safe_preferred_range - dist + 10)
		_move_toward(retreat_pos)
		return
	
	# Strafe or approach to preferred range
	if dist > safe_preferred_range:
		# Don't move directly to target - move to a position at preferred range
		var approach_pos = current_target.global_position - dir_to_target * safe_preferred_range
		_move_toward(approach_pos)
	else:
		# At preferred range - strafe or hold position
		if randf() < 0.3 * delta:  # Occasional strafe
			var strafe_dir = dir_to_target.rotated(PI / 2 * (1 if randf() > 0.5 else -1))
			_move_toward(self.global_position + strafe_dir * 30)

func _process_attack(delta: float) -> void:
	# Calculate safe distances
	var combined_collision_dist = collision_radius + (current_target.collision_radius if current_target else 0) + minimum_separation
	var safe_attack_range = max(attack_range, combined_collision_dist + 5.0)
	
	# Start attack if not already attacking
	if not self.attack_animator.is_attacking:
		#print("do we have a weapon?")
		
		if self.current_main_hand_weapon:
		#	print("yes we do have a weapon")
			self.attack()
			attack_cooldown_timer = attack_cooldown / (self.attack_speed_multiplier )
		else:
			print("trying attack without a weapon")
			self.attack()
	# Wait for attack to finish
	if not self.attack_animator.is_attacking:
		_change_state(AIState.APPROACH)
	if current_target and global_position.distance_to(current_target.global_position) > 1.5 * safe_attack_range:
		_change_state(AIState.APPROACH)

func _process_retreat(delta: float) -> void:
	if not current_target:
		_change_state(AIState.IDLE)
		return
	
	var dir_away = (self.global_position - current_target.global_position).normalized()
	var safe_retreat_dist = collision_radius + current_target.collision_radius + minimum_separation + 50.0
	_move_toward(self.global_position + dir_away * safe_retreat_dist)
	
	# Exit retreat after some time
	if state_timer > 1.5:
		_change_state(AIState.IDLE)

# ===== MOVEMENT =====

func _move_toward(target_pos: Vector2) -> void:
	self.target_position = target_pos
	self.is_moving = true
	
	# Face movement direction
	var dir = (target_pos - self.global_position).normalized()
	if dir.length() > 0.1:
		self.target_rotation = dir.angle() + PI / 2

# ===== EVENTS =====

func _on_limb_damaged(limb_type: int, damage_info: Dictionary) -> void:
	# React to being hit
	if damage_info.get("actual_damage", 0) > 0:
		# Stun briefly
		stun_timer = 0.1 + randf() * 0.1
		_change_state(AIState.STUNNED)
		
		# Check if should retreat (low health)
		var torso_hp_percent = self.get_limb(LimbType.TORSO).get_hp_percent()
		
		#TODO: Will Check
		if torso_hp_percent < 0.3 and randf() < 0.5 or blood_amount < 0.5* max_blood_amount:
			stun_timer = 0.0
			_change_state(AIState.RETREAT)

func _on_character_died() -> void:
	if "Male" in self.traits and not "Beast" in self.traits:
		SfxManager.play("man-death-scream",global_position)
	elif "Female" in self.traits and not "Beast" in self.traits:
		SfxManager.play("woman-death-scream",global_position)
	current_state = AIState.DEAD
	current_target = null
	set_process(false)

func _update_blood_drops(delta: float) -> void:
	"""Update all active blood drops"""
	var drops_to_remove: Array[int] = []
	#print("Updating blood drops. Current active blood drops = ",active_blood_drops.size())
	for i in range(active_blood_drops.size()):
		var drop_data = active_blood_drops[i]
		var sprite: Sprite2D = drop_data["sprite"]
		
		if not is_instance_valid(sprite):
			drops_to_remove.append(i)
			continue
		
		# Update time
		drop_data["time"] += delta
		var t = drop_data["time"]
		var fade_time = drop_data["fade_time"]
		
		# Apply velocity with drag
		var velocity: Vector2 = drop_data["velocity"]
		velocity *= 0.98  # Drag
		velocity.y += blood_drop_gravity * delta  # Optional gravity
		drop_data["velocity"] = velocity
		
		# Move sprite (in parent space, not character-local)
		sprite.global_position += velocity * delta
		
		# Rotate
		sprite.rotation += drop_data["rotation_speed"] * delta
		
		# Fade out
		var fade_progress = t / fade_time
		sprite.modulate.a = 1.0 - ease(fade_progress, 0.5)
		
		# Check if done
		if t >= fade_time:
			sprite.visible = false
			drops_to_remove.append(i)
	
	# Remove finished drops (reverse order to preserve indices)
	drops_to_remove.reverse()
	for i in drops_to_remove:
		active_blood_drops.remove_at(i)

# ===== BLOOD DROP SYSTEM =====

func _spawn_blood_drops(origin: Vector2, count: int, is_severing: bool) -> void:
	"""Spawn blood drop particles at the origin"""
	print("Attempting to spawn blood drops")
	if not blood_drop_texture:
		print("The blood drop texture hasn't been set")
		push_warning("No blood drop texture set!")
		return
	
	for i in range(count):
		var drop = _get_blood_drop_sprite()
		drop.texture = blood_drop_texture
		drop.visible = true
		drop.modulate = Color.WHITE
		drop.modulate.a = 1.0
		
		# Random scale
		var scale_val = randf_range(blood_drop_min_scale, blood_drop_max_scale)
		if is_severing:
			scale_val *= randf_range(1.0, 1.5)  # Bigger drops for severing
		drop.scale = Vector2(scale_val, scale_val)
		
		# Random rotation
		drop.rotation = randf() * TAU
		
		# Position at origin with slight offset
		var offset = Vector2(randf_range(-5, 5), randf_range(-5, 5))
		drop.position = origin + offset
		
		# Random velocity - away from character center
		var base_dir = (origin - Vector2.ZERO).normalized()
		if base_dir.length() < 0.1:
			base_dir = Vector2.RIGHT.rotated(randf() * TAU)
		
		# Add randomness to direction
		var spread = randf_range(-PI/3, PI/3)
		var velocity_dir = base_dir.rotated(spread)
		var speed = randf_range(blood_drop_speed_min, blood_drop_speed_max)
		if is_severing:
			speed *= randf_range(1.2, 2.0)  # Faster for severing
		
		# Track this drop
		active_blood_drops.append({
			"sprite": drop,
			"velocity": velocity_dir * speed,
			"time": 0.0,
			"fade_time": blood_drop_fade_time * randf_range(0.8, 1.2),
			"rotation_speed": randf_range(-3.0, 3.0)
		})

func _get_blood_drop_sprite() -> Sprite2D:
	"""Get a sprite from pool or create new one"""
	# Look for inactive sprite in pool
	for sprite in blood_pool:
		if is_instance_valid(sprite) and not sprite.visible:
			return sprite
	
	# Create new sprite
	var sprite = Sprite2D.new()
	sprite.name = "BloodDrop"
	sprite.z_index = 10  # Above everything
	add_child(sprite)
	blood_pool.append(sprite)
	return sprite


# ===== LIMB SEVERING =====

func _handle_limb_severing(limb_type: ProceduralCharacter.LimbType) -> void:
	"""Handle visual and equipment changes when a limb is severed"""
	# Hide the limb visual
	_hide_limb_visual(limb_type)
	
	# Drop equipment from that limb
	_drop_limb_equipment(limb_type)
	
	# Clear wound lines on that limb
	_clear_limb_wounds(limb_type)
	
	# Add stump visual
	_add_stump_visual(limb_type)

func _hide_limb_visual(limb_type: ProceduralCharacter.LimbType) -> void:
	"""Hide the Line2D visual for a severed limb"""
	var limb_node: Line2D = null
	
	match limb_type:
		ProceduralCharacter.LimbType.LEFT_ARM:
			limb_node = self.left_arm
		ProceduralCharacter.LimbType.RIGHT_ARM:
			limb_node = self.right_arm
		ProceduralCharacter.LimbType.LEFT_LEG:
			limb_node = self.left_leg
		ProceduralCharacter.LimbType.RIGHT_LEG:
			limb_node = self.right_leg
		# HEAD and TORSO severing = death, no need to hide
	
	if limb_node:
		limb_node.visible = false

func _drop_limb_equipment(limb_type: ProceduralCharacter.LimbType) -> void:
	"""Drop any equipment held on the severed limb"""
	match limb_type:
		ProceduralCharacter.LimbType.RIGHT_ARM:
			# Drop held weapon
			if self.current_main_hand_weapon:
				_drop_weapon()
		ProceduralCharacter.LimbType.LEFT_ARM:
			# Could handle shield/off-hand here
			pass
		ProceduralCharacter.LimbType.LEFT_LEG, ProceduralCharacter.LimbType.RIGHT_LEG:
			# Check if both legs are severed for feet equipment
			var left_severed = severed_limbs.get(ProceduralCharacter.LimbType.LEFT_LEG, false)
			var right_severed = severed_limbs.get(ProceduralCharacter.LimbType.RIGHT_LEG, false)
			if left_severed and right_severed:
				if self.feet_equipment:
					self.unequip_slot(EquipmentShape.EquipmentSlot.FEET)
		ProceduralCharacter.LimbType.HEAD:
			# Drop head equipment
			if self.head_equipment:
				self.unequip_slot(EquipmentShape.EquipmentSlot.HEAD)

func _drop_weapon(hand:String = "Main") -> void:
	"""Drop the currently held weapon"""
	if not self.current_main_hand_weapon or self.current_off_hand_weapon:
		return
	var weapon
	# Store reference before removing
	if current_hand == "Main":
		weapon = self.current_main_hand_weapon
	else:
		weapon = self.current_off_hand_weapon
	
	# Remove from inventory's active slot
	self.inventory.holster_weapon()
	
	# Optionally: spawn a dropped weapon pickup here
	# For now, just remove it
	print("Weapon dropped due to arm severing: ", weapon.name if weapon else "unknown")

func _clear_limb_wounds(limb_type: ProceduralCharacter.LimbType) -> void:
	"""Remove all wound lines from a limb"""
	if wound_lines.has(limb_type):
		for wound in wound_lines[limb_type]:
			if is_instance_valid(wound):
				wound.queue_free()
		wound_lines[limb_type].clear()

func _add_stump_visual(limb_type: ProceduralCharacter.LimbType) -> void:
	"""Add a bloody stump where the limb was"""
	var stump_pos = _get_limb_attachment_position(limb_type)
	
	# Create a small circle for the stump
	var stump = Line2D.new()
	stump.name = "Stump_" + ProceduralCharacter.LimbType.keys()[limb_type]
	stump.width = 6.0
	stump.default_color = stump_color
	stump.begin_cap_mode = Line2D.LINE_CAP_ROUND
	stump.end_cap_mode = Line2D.LINE_CAP_ROUND
	stump.z_index = 3
	
	# Short line to represent stump
	stump.add_point(stump_pos)
	stump.add_point(stump_pos + Vector2(2, 2))
	
	add_child(stump)

func _update_severed_limb_visuals() -> void:
	"""Keep severed limbs hidden (in case animation tries to show them)"""
	for limb_type in severed_limbs:
		if severed_limbs[limb_type]:
			_hide_limb_visual(limb_type)


func _on_limb_severed(limb_type: ProceduralCharacter.LimbType) -> void:
	severed_limbs[limb_type] = true
	print("on_limb_severed")
	# Create extra blood spray for severing
	var limb_pos = _get_limb_center_position(limb_type)
	var blood_count = int((blood_drops_max * sever_blood_multiplier))
	_spawn_blood_drops(limb_pos, blood_count, true)
	
	# Hide the limb visual and drop equipment
	_handle_limb_severing(limb_type)

# ===== HELPER FUNCTIONS =====

func _get_limb_center_position(limb_type: ProceduralCharacter.LimbType) -> Vector2:
	"""Get the center position of a limb in local coordinates"""
	match limb_type:
		ProceduralCharacter.LimbType.HEAD:
			return Vector2(0, -self.head_length * 0.1)
		ProceduralCharacter.LimbType.TORSO:
			return Vector2(0, self.shoulder_y_offset)
		ProceduralCharacter.LimbType.LEFT_ARM:
			if self.left_arm_joints.size() > 1:
				# Middle of arm
				var start = self.left_arm_joints[0]
				var end = self.left_arm_joints[-1]
				return (start + end) / 2
			return Vector2(-self.body_width / 2, self.shoulder_y_offset)
		ProceduralCharacter.LimbType.RIGHT_ARM:
			if self.right_arm_joints.size() > 1:
				var start = self.right_arm_joints[0]
				var end = self.right_arm_joints[-1]
				return (start + end) / 2
			return Vector2(self.body_width / 2, self.shoulder_y_offset)
		ProceduralCharacter.LimbType.LEFT_LEG:
			return Vector2(-self.leg_spacing, self.shoulder_y_offset + self.leg_length / 2)
		ProceduralCharacter.LimbType.RIGHT_LEG:
			return Vector2(self.leg_spacing, self.shoulder_y_offset + self.leg_length / 2)
	return Vector2.ZERO

func _get_limb_attachment_position(limb_type: ProceduralCharacter.LimbType) -> Vector2:
	"""Get where a limb attaches to the body"""
	match limb_type:
		ProceduralCharacter.LimbType.LEFT_ARM:
			return Vector2(-self.body_width / 2, self.shoulder_y_offset)
		ProceduralCharacter.LimbType.RIGHT_ARM:
			return Vector2(self.body_width / 2, self.shoulder_y_offset)
		ProceduralCharacter.LimbType.LEFT_LEG:
			return Vector2(-self.leg_spacing, self.shoulder_y_offset + 2)
		ProceduralCharacter.LimbType.RIGHT_LEG:
			return Vector2(self.leg_spacing, self.shoulder_y_offset + 2)
	return Vector2.ZERO

func _get_limb_size(limb_type: ProceduralCharacter.LimbType) -> Vector2:
	"""Get approximate size of a limb for wound placement"""
	match limb_type:
		ProceduralCharacter.LimbType.HEAD:
			return Vector2(self.head_width, self.head_length)
		ProceduralCharacter.LimbType.TORSO:
			return Vector2(self.body_width, self.body_height)
		ProceduralCharacter.LimbType.LEFT_ARM, ProceduralCharacter.LimbType.RIGHT_ARM:
			var arm_length = 0.0
			for seg in self.ARM_SEGMENT_LENGTHS:
				arm_length += seg
			return Vector2(arm_length, 7.0)
		ProceduralCharacter.LimbType.LEFT_LEG, ProceduralCharacter.LimbType.RIGHT_LEG:
			return Vector2(self.leg_width, self.leg_length)
	return Vector2(10, 10)

# ===== CLEANUP =====

func clear_all_wounds() -> void:
	"""Remove all wound effects (for healing, respawn, etc.)"""
	for limb_type in wound_lines:
		for wound in wound_lines[limb_type]:
			if is_instance_valid(wound):
				wound.queue_free()
		wound_lines[limb_type].clear()

func reset_severed_limbs() -> void:
	"""Reset all severed limbs (for respawn)"""
	for limb_type in severed_limbs:
		severed_limbs[limb_type] = false
	
	# Show all limb visuals again
	if self.left_arm:
		self.left_arm.visible = true
	if self.right_arm:
		self.right_arm.visible = true
	if self.left_leg:
		self.left_leg.visible = true
	if self.right_leg:
		self.right_leg.visible = true
	
	# Remove stump visuals
	for child in get_children():
		if child.name.begins_with("Stump_"):
			child.queue_free()

func _exit_tree() -> void:
	# Clean up blood pool
	for sprite in blood_pool:
		if is_instance_valid(sprite):
			sprite.queue_free()
	blood_pool.clear()
	active_blood_drops.clear()
	
func handle_damage_effect_based_on_type(damage: int, damage_type: String, limb: LimbType, location: Vector2):
		#match statement for adding conditions, or knockback for force
		match damage_type:
			"slashing":
				# .get(key, default) prevents a crash if the key doesn't exist yet
				var current_tier = conditions.get("bleeding", 0)
				conditions["bleeding"] = current_tier + 1
				print("Gained Bleeding. Current Tier: ", conditions["bleeding"])
				if damage >= 8:
					_handle_limb_severing(limb)
				_spawn_blood_drops(location, 3 * conditions["bleeding"],false)
			"piercing":
				var current_tier = conditions.get("bleeding", 0)
				conditions["bleeding"] = current_tier + 1
				print("Gained Bleeding. Current Tier: ", conditions["bleeding"])
				_spawn_blood_drops(location, 3 * conditions["bleeding"],false)
			"fire":
				conditions["burning"] = conditions.get("burning", 0) + 1
				
			"poison":
				conditions["poisoned"] = conditions.get("poisoned", 0) + 1

			"cold":
				conditions["chilled"] = conditions.get("chilled", 0) + 1

			_: 
				# This is the 'default' case (wildcard) 
				# useful for damage types that don't have conditions yet
				pass
					
# ===== PUBLIC API =====
		# Visual feedback could be added here (screen shake, etc)

func _knock_weapon_away() -> void:
	"""Knock the weapon to the side (still held but out of position)"""
	if self.attack_animator:
		self.attack_animator.interrupt_attack()
		self.attack_animator.apply_knockback(0.4)  # Recovery time
		
func apply_stagger(intensity: float) -> void:
	"""Apply stagger effect to character (interrupts attack, brief pause)"""
	if self.attack_animator:
		# Interrupt current attack if stagger is strong enough
		if intensity >= 0.2 and self.attack_animator.is_attacking:
			self.attack_animator.interrupt_attack()
			#TODO: implement movement and shaking of the character
		
func disarm_character() -> void:
	"""Force character to drop their weapon"""
	if self.attack_animator:
		self.attack_animator.interrupt_attack()
	
	# TODO: Create dropped weapon entity at character position
	# For now, just holster
	self.holster_weapon()
# INTERUPTION AND KNOCKBACK
func apply_knockback(duration: float) -> void:
	"""Apply a knockback recovery period (can't attack)"""
	attack_animator.interrupt_attack()
	attack_animator.knockback_timer = duration
	attack_animator.is_knocked_back = true
	
func set_target(target: ProceduralCharacter) -> void:
	"""Manually set a target"""
	if target and _is_enemy(target):
		_acquire_target(target)

func clear_target() -> void:
	"""Clear current target"""
	_lose_target()

func stun(duration: float) -> void:
	"""Stun the AI for a duration"""
	stun_timer = duration
	_change_state(AIState.STUNNED)

func get_state_name() -> String:
	return AIState.keys()[current_state]
	
func _on_time_updated(_hour: int, _minute: int, second: int):
	# 1. Check if the character is currently bleeding
	if not conditions.has("bleeding"):
		return
	
	# 2. Trigger logic every 6 seconds (at second 0, 6, 12, 18, etc.)
	if second % 6 == 0:
		apply_bleeding_tick()

func apply_bleeding_tick():
	var tier = conditions.get("bleeding", 0)
	
	if tier > 0:
		# Subtract 1 per tier from blood_amount
		blood_amount -= tier
		
		# Subtract 1 from constitution
		constitution -= 1
		
		# Optional: Clamp values so they don't drop into negative infinity
		blood_amount = max(0, blood_amount)
		constitution = max(0, constitution)
		
		#print("Bleed Tick: Blood at ", blood_amount, " | Con at ", constitution)
		
		# Logic check: if constitution or blood hits 0, handle death/unconsciousness
		if blood_amount <= 0 or constitution <= 0 and is_alive():
			_on_character_died()
			conditions["Bleeding"] = 0
#Ability Checks, character.gd code
func ability_check(stat,domain):
	var roll = randi() % 100 + 1
	var success_target = get_stat_by_name(stat)
	var bonus = 0
	for trait_id in domain.advantages:
		if traits.has(trait_id): bonus += 20 * traits[trait_id]
	for trait_id in domain.disadvantages:
		if traits.has(trait_id): bonus -= 20 * traits[trait_id]
		success_target += bonus
		
	var success_level = _calculate_success_level(roll, success_target)
func get_stat_by_name(stat_name: StringName) -> int:
	match stat_name:
		&"str": return strength
		&"dex": return dexterity
		&"con": return constitution
	return 50
func _calculate_success_level(roll: int, target: int) -> int:
	var margin = target - roll
	var level = 0
	
	if margin >= 0: # It's a success
		level = 1 + int(margin / 50) # Every 50 points over is another success level
	
	# Special roll modifiers
	if roll <= CRIT_THRESHOLD: level += 1
	if roll >= CRIT_FAIL_THRESHOLD: level -= 1
	
	return level
