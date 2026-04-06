# procedrual character.gd
# Attach to a Node2D that will be the character root
extends CharacterBody2D
class_name ProceduralCharacter
@onready var game = get_node_or_null("/root/Game")
# Character data
var character_data: Dictionary = {}
var Name = ""
var skin_color: Color = Color.BEIGE
var hair_color: Color = Color("#4a3728")  # Default brown hair
var body_color: Color  # Derived from skin_color, slightly darker
var traits = {"Male":1}
# Faction
var faction_id: String = "neutral"
var is_protagonist = false
var AI_enabled = false
var is_player_controlled: bool = false
# Dialogue / interaction
var dialogues: Array = []
var current_dialogue_index: int = 0
var interact_options: Array = ["Inspect"]

var action_queue: ActionQueue = null
var _was_paused: bool = false
# Body parts
var body: Line2D
var head: Line2D
var hair: Line2D
var left_arm: Line2D
var right_arm: Line2D
var left_leg: Line2D
var right_leg: Line2D

var current_hand = "Main"
var display_name = "John Doe"

# Ability Resolution:
## AbilityManager handles casting, cooldowns, and multi-step sequences
var ability_manager: AbilityManager

## Currently casting ability — delegates to ability_manager.current_cast
var current_cast: Dictionary:
	get: return ability_manager.current_cast if ability_manager else {}
	set(value):
		if ability_manager:
			ability_manager.current_cast = value

## Cooldowns for abilities — delegates to ability_manager.cooldowns
var cooldowns: Dictionary:
	get: return ability_manager.cooldowns if ability_manager else {}
	set(value):
		if ability_manager:
			ability_manager.cooldowns = value

var MODIFY_DURATION_BY_TRAIT: Dictionary = {
	"fire": 1.2,
	"ice": 1.5,
	"spell": 1.0,
	"aoe": 1.3,
	"attack": 1.0,
	"magical": 1.1,
} #

## Preloaded visual effect scenes
var _effect_cache: Dictionary = {}
var _audio_cache: Dictionary = {}   # path -> AudioStream
var _active_condition_vfx: Dictionary = {}  # condition_id -> Node (VFX instance attached to character)
var _active_condition_sfx: Dictionary = {}  # condition_id -> AudioStreamPlayer2D

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
	MOHAWK,         # Strip down the middle
	LONG,           # Long hair extending past back of head
	BRAIDS,         # Two braids running along left and right sides
	BUN,            # Hair gathered in a bun at the back
	PIGTAILS,       # Two small bunches on left and right sides
	MANE            # Mane running along spine (for horses/quadrupeds)
}
var hair_style: HairStyle = HairStyle.FULL

enum HeadShape {
	HUMANOID,    # Default oval
	ORCISH,      # Wider, squarer jaw + tusks
	DRACONIC,    # Elongated snout, tapering forward
	CANINE,      # Animal head with short snout
	EQUINE       # Long narrow head (horse)
}
var head_shape: HeadShape = HeadShape.HUMANOID
var head_features: Array = []  # e.g. ["elf_ears", "animal_ears"]

# Head feature nodes (created by _create_racial_features)
var head_features_node: Node2D = null

enum BodyType {
	BIPEDAL,     # Default (2 legs, 2 arms)
	QUADRUPED    # 4 legs, no arms (unless has_arms), elongated body, tail
}
var body_type: BodyType = BodyType.BIPEDAL
var body_length: float = 0.0       # Front-to-back length for quadrupeds
var has_tail: bool = false
var tail_length: float = 0.0
var has_arms: bool = true          # Quadrupeds can have arms (centaur)

# Quadruped-specific body parts
var front_left_leg: Line2D = null
var front_right_leg: Line2D = null
var tail: Line2D = null
var tail_swing_time: float = 0.0
var tail_swing_speed: float = 4.0  # Faster when moving
var tail_idle_speed: float = 1.5
# Inventory and weapons (using new shape-based system)
var inventory: Inventory
var current_main_hand_item: Node2D = null
var current_off_hand_item: Node2D = null
var main_hand_holder: Node2D
var off_hand_holder: Node2D
var unarmed_strike_damage_type = "bludgeoning"
var unarmed_strike_damage = 1
# Attack system
@onready var attack_animator: AttackAnimator = $AttackAnimator

# Movement
var target_position: Vector2
var target_rotation: float = 0.0
var is_moving: bool = false
# Waypoint-based pathfinding for real-time movement
var _nav_waypoints: Array[Vector2] = []
var _nav_index: int = 0
var _last_nav_target_tile: Vector2i = Vector2i(-999, -999)

@export var sight: float = 1.0  # Base sight stat
var fov_angle_degrees: float = 150.0  # Field of view in degrees
@export var hearing: float = 1.0 #base hearing stat

@export var targeting_confusion = 0.0
@export var restricted_actions_by_trait= {
		"manipulate": false,
		"attack": false,
		"magic": false,
		"arcane": false,
		"holy": false,
		"occult": false,
		"primal": false,
		"concentration": false
	}
@export var bonus_damage = 0.0
@export var bonus_damage_against_trait = {
	"giant": 0.0,
	"draconic": 0.0,
	"fungal": 0.0,
	"fae": 0.0,
	"oneiric":0.0,
	"mechanical": 0.0,
	"organic": 0.0,
	"metal": 0.0,
	"undead": 0.0,
	"angelic": 0.0,
	"devil": 0.0,
	"demon": 0.0
}

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

# Base attributes (1-100 scale, 50 is average human)
@export var strength: int = 50      # Damage multiplier, weapon clash power
@export var constitution: int = 50  # HP multiplier, stagger resistance
@export var dexterity: int = 50     # Speed multiplier (move + attack)
@export var will: int = 50
@export var intelligence: int = 50
@export var charisma: int = 50
# --- Add these modifier variables near your other vars ---
var strength_modifier: float = 0.0
var constitution_modifier: float = 0.0
var dexterity_modifier: float = 0.0
var will_modifier: float = 0.0
var intelligence_modifier: float = 0.0
var charisma_modifier: float = 0.0
var sight_modifier: float = 0.0
var hearing_modifier: float = 0.0
var fov_modifier: float = 0.0
var mp_regen_modifier: float = 0.0
var crit_threshold_modifier: float = 0.0
var crit_fail_modifier: float = 0.0

# --- Helper to get effective attribute values ---
func effective_strength() -> float:
	return strength + strength_modifier

func effective_constitution() -> float:
	return constitution + constitution_modifier

func effective_dexterity() -> float:
	return dexterity + dexterity_modifier

func effective_will() -> float:
	return will + will_modifier

func effective_intelligence() -> float:
	return intelligence + intelligence_modifier

func effective_charisma() -> float:
	return charisma + charisma_modifier

func effective_sight() -> float:
	return sight + sight_modifier

func effective_hearing() -> float:
	return hearing + hearing_modifier

func effective_fov() -> float:
	return fov_angle_degrees + fov_modifier

func effective_mp_regen() -> int:
	return int(mp_regen_amount + mp_regen_modifier)

func effective_crit_threshold() -> float:
	return CRIT_THRESHOLD + crit_threshold_modifier

func effective_crit_fail_threshold() -> float:
	return CRIT_FAIL_THRESHOLD + crit_fail_modifier
	
	
var speed_modifier: float = 0.0
var arm_length: float = 0.0
var race_id: String = ""
var creature_size: String = "Medium"
var racial_features: Array = []

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
@onready var condition_manager: ConditionManager = $ConditionManager
# Derived stats (calculated from attributes)

var max_blood_amount = max_hp
var blood_amount = max_hp

# --- Update your existing getters to use effective values ---

var max_hp: int:
	get: return 6 + int(effective_constitution()) / 10

var max_MP: int:
	get: return int(effective_will()) * consciousness

var rotation_speed: float:
	get: return 8.0 * (effective_dexterity() / 50.0)

var consciousness: int:
	get: return blood_amount + int(effective_will())

var damage_multiplier: float:
	get: return 0.5 + (effective_strength() / 100.0) + bonus_damage

var move_speed: float:
	get: return GridManager.TILE_SIZE * (0.5 + (effective_dexterity() / 100.0)) * (1.0 + speed_modifier)
@export var dash_speed_multiplier: float = 5.0
@export var dash_duration: float = 0.2
@export var dash_cooldown: float = 0.8
@export var avoidance_radius: float = 50.0
@export var avoidance_strength: float = 200.0
var is_dashing: bool = false
var dash_timer: float = 0.0
var dash_cooldown_timer: float = 0.0


var attack_speed_multiplier: float:
	get: return 0.5 + (effective_dexterity() / 100.0)

var clash_power: float:
	get: return effective_strength() + (effective_constitution() * 0.3)
#MP
@export var MP = max_MP	
@export var mp_regen_amount: int = 5
@export var mp_regen_interval: float = 0.5
var mp_regen_timer: float = 0.0

# Load from dictionary

func to_data() -> Dictionary:
	return {
		"strength": strength,
		"constitution": constitution,
		"dexterity": dexterity,
		"will": will,  
		"intelligence": intelligence, 
		"charisma": charisma
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

const AbilityTargetingScript = preload("res://Abilities/AbilityTargeting.gd")
var targeting_system: Node2D
var _awaiting_target_release: bool = false

# Add reference to the child ConditionManager
signal character_reached_target
signal character_died
signal weapon_changed(weapon: WeaponShape)
signal attack_hit(damage: int, damage_type: int)

func _ready() -> void:
	target_position = global_position
	targeting_system = AbilityTargetingScript.new()
	 # Connect condition signals
	condition_manager.condition_applied.connect(_on_condition_applied)
	condition_manager.condition_removed.connect(_on_condition_removed)
	condition_manager.condition_expired.connect(_on_condition_expired)
	condition_manager.stats_recalculated.connect(_on_stats_recalculated)
	condition_manager.triggered_effect_fired.connect(_on_triggered_effect_fired)
	condition_manager.condition_suppressed.connect(_on_condition_suppressed)
	condition_manager.condition_unsuppressed.connect(_on_condition_unsuppressed)
	# 2. Name it (optional, but helps with debugging)
	targeting_system.name = "AbilityTargeting"
	add_child(targeting_system)
	# Set up AbilityManager
	ability_manager = AbilityManager.new()
	ability_manager.name = "AbilityManager"
	add_child(ability_manager)
	ability_manager.cast_started.connect(_on_ability_cast_started)
	ability_manager.cast_completed.connect(_on_ability_cast_completed)
	ability_manager.cast_interrupted.connect(_on_ability_cast_interrupted)
	ability_manager.cast_failed.connect(_on_ability_cast_failed)
	ability_manager.step_started.connect(_on_ability_step_started)
	ability_manager.step_completed.connect(_on_ability_step_completed)
	blood_drop_texture = load("res://vfx/blood drop.png")

	_setup_condition_display()
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_inventory()
	_setup_action_queue()
	_setup_equipment_slots()
	_setup_attack_system()
	_setup_collision()
	_create_body_parts()
	_initialize_arms()
	initialize_limbs(constitution)
	TimeManager.time_updated.connect(_on_time_updated)
	targeting_system.connect("targeting_confirmed", _on_targeting_confirmed)
	_on_stats_recalculated() # Initialize the effective stats
	# LOS light is added by Game.gd after spawn (not here) to control
	# per-character settings like cull masks and NPC visibility
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

func _setup_los_visual() -> void:
	var light = PointLight2D.new()
	light.texture = Globals.SIGHT_TEXTURE
	light.energy = 0.3
	var master_radius = 512.0
	var desired_radius = 1440.0 * sight
	light.texture_scale = desired_radius / master_radius
	light.name = "LineOfSight"
	light.rotation_degrees = 90
	light.shadow_enabled = true
	light.shadow_item_cull_mask = 1
	light.z_index = 102
	add_child(light)

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
	_update_holder_scale()

func _update_holder_scale() -> void:
	# Scale weapon holders so weapons match character size (race body_size_mod)
	var s = Vector2(body_size_mod, body_size_mod)
	if main_hand_holder:
		main_hand_holder.scale = s
	if off_hand_holder:
		off_hand_holder.scale = s

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
	# AttackAnimator is now a scene child node (see ProceduralCharacter.tscn)
	# Just connect signals here
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
		print("updating collision shape")
		collision_shape.shape.points = _get_body_collision_points()

func _get_body_collision_points() -> PackedVector2Array:
	var half_width = body_width / 2

	if body_type == BodyType.QUADRUPED:
		# Elongated body collision for quadrupeds
		var front = -body_length * 0.5
		var rear = body_length * 0.5
		return PackedVector2Array([
			Vector2(-half_width, front),
			Vector2(half_width, front),
			Vector2(half_width, rear),
			Vector2(-half_width, rear)
		])
	else:
		var top = -head_length * 0.35
		var bottom = shoulder_y_offset + leg_length
		return PackedVector2Array([
			Vector2(-half_width, top),
			Vector2(half_width, top),
			Vector2(half_width, bottom),
			Vector2(-half_width, bottom)
		])



var _condition_display: HBoxContainer = null
const COND_DISPLAY_ICON_SIZE := Vector2(16, 16)
const COND_DISPLAY_OFFSET_Y := -30.0

func _setup_condition_display() -> void:
	_condition_display = HBoxContainer.new()
	_condition_display.name = "ConditionDisplay"
	_condition_display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_condition_display.z_index = 100
	_condition_display.add_theme_constant_override("separation", 2)
	add_child(_condition_display)

func _refresh_condition_display() -> void:
	if not _condition_display:
		return
	for child in _condition_display.get_children():
		child.queue_free()
	for cond_id in condition_manager.conditions:
		var instance = condition_manager.conditions[cond_id]
		var cond_res = instance.condition
		var icon_tex = cond_res.icon if cond_res else null
		var tex_rect = TextureRect.new()
		tex_rect.custom_minimum_size = COND_DISPLAY_ICON_SIZE
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if icon_tex and icon_tex is Texture2D:
			tex_rect.texture = icon_tex
		_condition_display.add_child(tex_rect)
	# Center the icons above the character
	var total_width = condition_manager.conditions.size() * (COND_DISPLAY_ICON_SIZE.x + 2)
	_condition_display.position = Vector2(-total_width * 0.5, COND_DISPLAY_OFFSET_Y)

func _on_condition_applied(instance: ConditionInstance) -> void:
	_spawn_condition_vfx(instance)
	_start_condition_sfx(instance)
	_refresh_condition_display()

func _on_condition_removed(instance: ConditionInstance) -> void:
	_remove_condition_vfx(instance)
	_stop_condition_sfx(instance)
	_refresh_condition_display()

func _on_condition_expired(instance: ConditionInstance) -> void:
	_remove_condition_vfx(instance)
	_stop_condition_sfx(instance)
	_refresh_condition_display()


func _on_stats_recalculated() -> void:
	# --- Core attributes (conditions can buff/debuff these) ---
	# We store the base values and let conditions modify them.
	# Using "add" operations on these means a condition with
	# {"stat": "strength", "operation": "add", "value": -10} reduces STR by 10.
	
	# For base attributes, calculate_effective_stat takes the export value as base.
	# But we don't want to overwrite the export — we need separate "effective" values
	# that the getters can use. So we use modifier floats.
	
	# --- Simple modifier stats (base is 0.0, conditions add/multiply onto them) ---
	speed_modifier = condition_manager.calculate_effective_stat(0.0, "speed_modifier")
	bonus_damage = condition_manager.calculate_effective_stat(0.0, "bonus_damage")
	
	# --- Attribute modifiers (applied on top of base attributes) ---
	# These are separate floats that getters can incorporate
	strength_modifier = condition_manager.calculate_effective_stat(0.0, "strength")
	constitution_modifier = condition_manager.calculate_effective_stat(0.0, "constitution")
	dexterity_modifier = condition_manager.calculate_effective_stat(0.0, "dexterity")
	will_modifier = condition_manager.calculate_effective_stat(0.0, "will")
	intelligence_modifier = condition_manager.calculate_effective_stat(0.0, "intelligence")
	charisma_modifier = condition_manager.calculate_effective_stat(0.0, "charisma")
	
	# --- Sensory stats ---
	sight_modifier = condition_manager.calculate_effective_stat(0.0, "sight")
	hearing_modifier = condition_manager.calculate_effective_stat(0.0, "hearing")
	fov_modifier = condition_manager.calculate_effective_stat(0.0, "fov_angle_degrees")
	targeting_confusion = condition_manager.calculate_effective_stat(0.0, "targeting_confusion")
	
	# --- MP regen ---
	mp_regen_modifier = condition_manager.calculate_effective_stat(0.0, "mp_regen_amount")
	
	# --- Crit thresholds ---
	crit_threshold_modifier = condition_manager.calculate_effective_stat(0.0, "crit_threshold")
	crit_fail_modifier = condition_manager.calculate_effective_stat(0.0, "crit_fail_threshold")
	
	# --- Bonus damage against trait (each trait is its own stat key) ---
	for trait_key in bonus_damage_against_trait:
		bonus_damage_against_trait[trait_key] = condition_manager.calculate_effective_stat(
			0.0, "bonus_damage_against_%s" % trait_key
		)
	
	# --- Action restrictions (conditions can set these to true) ---
	# A "set" operation with value 1.0 means restricted
	for action_trait in restricted_actions_by_trait:
		var val = condition_manager.calculate_effective_stat(0.0, "restrict_%s" % action_trait)
		restricted_actions_by_trait[action_trait] = val >= 1.0


func _on_triggered_effect_fired(instance: ConditionInstance, effect: Dictionary, result: Dictionary) -> void:
	if result.has("damage"):
		var damage_amount = result["damage"]
		var damage_type = result.get("damage_type", "true")
		var limb_type = instance.target_limb if instance.target_limb != null else LimbType.TORSO
		
		# Build damage dict matching your damage_limb format
		var damage_dict = {damage_type: damage_amount}
		
		# Use global position as fallback for visual location
		var hit_location = global_position
		damage_limb(limb_type, damage_dict, hit_location)
		is_alive()  # Check death
	
	if result.has("heal"):
		var heal_amount = result["heal"]
		if instance.target_limb != null:
			var limb = get_limb(instance.target_limb)
			if limb:
				limb.heal(heal_amount)
		else:
			# Whole body heal — distribute across all limbs
			for limb in limbs.values():
				limb.heal(heal_amount)
	
	if result.has("condition_id") and effect.get("type") == "apply_condition":
		if randf() <= result.get("chance", 1.0):
			# Chain-applied conditions inherit the same limb
			condition_manager.apply_condition(result["condition_id"], instance.source, 1, -2.0, instance.target_limb)
	
	if result.has("condition_id") and effect.get("type") == "remove_condition":
		condition_manager.remove_condition(result["condition_id"])

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
	
	if data.has("skin_color"):
		skin_color = Color.html(data["skin_color"])
	if data.has("hair_color"):
		hair_color = Color.html(data["hair_color"])
	if data.has("hair_style"):
		hair_style = _parse_hair_style(data["hair_style"])
	if data.has("head_shape"):
		head_shape = _parse_head_shape(data["head_shape"])
	if data.has("head_features"):
		head_features = data["head_features"]
	if data.has("faction"):
		faction_id = data["faction"]
	
	body_color = skin_color.darkened(0.15)
	
	# --- Body dimensions (respect size override) ---
	var use_custom_size = data.has("size") and data["size"] != "default"
	if data.has("body_width") and use_custom_size:
		body_width = data["body_width"]
	if data.has("body_height") and use_custom_size:
		body_height = data["body_height"]
	if data.has("head_width") and use_custom_size:
		head_width = data["head_width"]
	if data.has("head_length") and use_custom_size:
		head_length = data["head_length"]
	if data.has("shoulder_y_offset") and use_custom_size:
		shoulder_y_offset = data["shoulder_y_offset"]
	
	# --- Core attributes ---
	if data.has("strength"): strength = data["strength"]
	if data.has("constitution"): constitution = data["constitution"]
	if data.has("dexterity"): dexterity = data["dexterity"]
	if data.has("intelligence"): intelligence = data["intelligence"]
	if data.has("will"): will = data["will"]
	if data.has("charisma"): charisma = data["charisma"]
	# Short forms
	if data.has("str"): strength = data["str"]
	if data.has("con"): constitution = data["con"]
	if data.has("dex"): dexterity = data["dex"]
	if data.has("int"): intelligence = data["int"]
	if data.has("wil"): will = data["wil"]
	if data.has("cha"): charisma = data["cha"]
	
	# --- Identity / race ---
	if data.has("race_id"): race_id = data["race_id"]
	if data.has("creature_size"): creature_size = data["creature_size"]
	if data.has("racial_features"): racial_features = data["racial_features"]
	
	# --- Combat stats ---
	if data.has("unarmed_strike_damage_type"):
		unarmed_strike_damage_type = data["unarmed_strike_damage_type"]
	if data.has("unarmed_strike_damage"):
		unarmed_strike_damage = data["unarmed_strike_damage"]
	if data.has("crit_threshold"): CRIT_THRESHOLD = data["crit_threshold"]
	if data.has("crit_fail_threshold"): CRIT_FAIL_THRESHOLD = data["crit_fail_threshold"]
	
	# --- Sensory ---
	if data.has("sight"): sight = data["sight"]
	if data.has("hearing"): hearing = data["hearing"]
	if data.has("fov_angle_degrees"): fov_angle_degrees = data["fov_angle_degrees"]
	
	# --- MP ---
	if data.has("mp_regen_amount"): mp_regen_amount = data["mp_regen_amount"]
	if data.has("mp_regen_interval"): mp_regen_interval = data["mp_regen_interval"]
	
	# --- Bonus damage / trait bonuses ---
	if data.has("bonus_damage"): bonus_damage = data["bonus_damage"]
	if data.has("bonus_damage_against_trait"):
		var trait_data = data["bonus_damage_against_trait"]
		for trait_key in trait_data:
			if trait_key in bonus_damage_against_trait:
				bonus_damage_against_trait[trait_key] = trait_data[trait_key]
	
	# --- Action restrictions ---
	if data.has("restricted_actions_by_trait"):
		var restrict_data = data["restricted_actions_by_trait"]
		for action_key in restrict_data:
			if action_key in restricted_actions_by_trait:
				restricted_actions_by_trait[action_key] = restrict_data[action_key]
	
	# --- Duration modifiers ---
	if data.has("modify_duration_by_trait"):
		var dur_data = data["modify_duration_by_trait"]
		for trait_key in dur_data:
			MODIFY_DURATION_BY_TRAIT[trait_key] = dur_data[trait_key]
	
	# --- Targeting ---
	if data.has("targeting_confusion"):
		targeting_confusion = data["targeting_confusion"]
	
	_update_colors()

func _parse_head_shape(shape_name: String) -> HeadShape:
	match shape_name.to_lower():
		"humanoid", "default":
			return HeadShape.HUMANOID
		"orcish", "orc":
			return HeadShape.ORCISH
		"draconic", "dragon":
			return HeadShape.DRACONIC
		"canine", "wolf", "dog":
			return HeadShape.CANINE
		"equine", "horse":
			return HeadShape.EQUINE
		_:
			return HeadShape.HUMANOID

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
		"long":
			return HairStyle.LONG
		"braids":
			return HairStyle.BRAIDS
		"bun":
			return HairStyle.BUN
		"pigtails":
			return HairStyle.PIGTAILS
		"mane":
			return HairStyle.MANE
		_:
			return HairStyle.FULL

func _create_body_parts() -> void:
	if body_type == BodyType.QUADRUPED:
		_create_quadruped_body()
	else:
		_create_bipedal_body()

	# Create hair based on style
	_create_hair()

	# Create head based on race head shape
	_create_head_by_shape()

	# Create racial features (ears, tusks, etc.)
	_create_racial_features()

	# Create tail if applicable
	if has_tail and tail_length > 0:
		_create_tail()

func _create_bipedal_body() -> void:
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
	body.width = body_height
	body.default_color = skin_color
	body.begin_cap_mode = Line2D.LINE_CAP_ROUND
	body.end_cap_mode = Line2D.LINE_CAP_ROUND
	body.z_index = -1
	add_child(body)

	body.add_point(Vector2(-body_width / 2, shoulder_y_offset))
	body.add_point(Vector2(body_width / 2, shoulder_y_offset))

func _create_quadruped_body() -> void:
	# Quadruped: elongated body running front-to-back (-Y to +Y)
	# Rear legs (reuse left_leg/right_leg for compatibility)
	var rear_y = body_length * 0.4  # Rear hips position
	left_leg = _create_quad_leg("RearLeftLeg", -leg_spacing, rear_y)
	left_leg.z_index = -3
	add_child(left_leg)

	right_leg = _create_quad_leg("RearRightLeg", leg_spacing, rear_y)
	right_leg.z_index = -3
	add_child(right_leg)

	# Front legs
	var front_y = -body_length * 0.35  # Front shoulder position
	front_left_leg = _create_quad_leg("FrontLeftLeg", -leg_spacing, front_y)
	front_left_leg.z_index = -3
	add_child(front_left_leg)

	front_right_leg = _create_quad_leg("FrontRightLeg", leg_spacing, front_y)
	front_right_leg.z_index = -3
	add_child(front_right_leg)

	# Create arms only if this quadruped has arms (e.g. centaur)
	if has_arms:
		left_arm = _create_arm("LeftArm")
		left_arm.z_index = -2
		add_child(left_arm)

		right_arm = _create_arm("RightArm")
		right_arm.z_index = -2
		add_child(right_arm)

	# Quadruped body: vertical line from front to back
	body = Line2D.new()
	body.name = "Body"
	body.width = body_width  # Left-right width of the body
	body.default_color = skin_color
	body.begin_cap_mode = Line2D.LINE_CAP_ROUND
	body.end_cap_mode = Line2D.LINE_CAP_ROUND
	body.z_index = -1
	add_child(body)

	# Body runs front-to-back (vertical in top-down view)
	body.add_point(Vector2(0, -body_length * 0.4))  # Front (head end)
	body.add_point(Vector2(0, body_length * 0.45))   # Rear (tail end)

func _create_quad_leg(leg_name: String, x_offset: float, hip_y: float) -> Line2D:
	var leg = Line2D.new()
	leg.name = leg_name
	leg.default_color = skin_color
	leg.begin_cap_mode = Line2D.LINE_CAP_ROUND
	leg.end_cap_mode = Line2D.LINE_CAP_ROUND
	leg.width = leg_width
	# Legs extend outward from the body
	leg.add_point(Vector2(x_offset, hip_y))  # Hip
	leg.add_point(Vector2(x_offset * 1.5, hip_y))  # Foot (extends outward)
	return leg

func _create_tail() -> void:
	tail = Line2D.new()
	tail.name = "Tail"
	tail.default_color = skin_color
	tail.begin_cap_mode = Line2D.LINE_CAP_ROUND
	tail.end_cap_mode = Line2D.LINE_CAP_ROUND
	tail.z_index = -1  # Same level as body

	# Width curve: tapers from base to tip
	var curve = Curve.new()
	curve.add_point(Vector2(0.0, 1.0))    # Base: full width
	curve.add_point(Vector2(0.3, 0.7))
	curve.add_point(Vector2(0.6, 0.4))
	curve.add_point(Vector2(1.0, 0.15))   # Tip: thin
	tail.width_curve = curve
	tail.width = leg_width * 1.2

	add_child(tail)

	# 5 points from base to tip, extending backward (+Y)
	var tail_base_y = body_length * 0.45 if body_type == BodyType.QUADRUPED else shoulder_y_offset + leg_length
	for i in range(5):
		var t = float(i) / 4.0
		tail.add_point(Vector2(0, tail_base_y + t * tail_length))

func _create_head_by_shape() -> void:
	match head_shape:
		HeadShape.HUMANOID:
			_create_humanoid_head()
		HeadShape.ORCISH:
			_create_orcish_head()
		HeadShape.DRACONIC:
			_create_draconic_head()
		HeadShape.CANINE:
			_create_canine_head()
		HeadShape.EQUINE:
			_create_equine_head()
		_:
			_create_humanoid_head()

func _create_humanoid_head() -> void:
	# Default oval head (existing code)
	head = Line2D.new()
	head.name = "Head"
	head.width = head_width
	head.default_color = skin_color
	head.begin_cap_mode = Line2D.LINE_CAP_ROUND
	head.end_cap_mode = Line2D.LINE_CAP_ROUND
	head.z_index = 1
	add_child(head)
	head.add_point(Vector2(0, -head_length * 0.35))  # Front of head (face)
	head.add_point(Vector2(0, head_length * 0.25))   # Back of head

func _create_orcish_head() -> void:
	# Wider, squarer jaw with box cap at the front
	head = Line2D.new()
	head.name = "Head"
	head.width = head_width + 4  # Wider than humanoid
	head.default_color = skin_color
	head.begin_cap_mode = Line2D.LINE_CAP_BOX  # Square jaw
	head.end_cap_mode = Line2D.LINE_CAP_ROUND   # Round back
	head.z_index = 1
	add_child(head)
	head.add_point(Vector2(0, -head_length * 0.35))
	head.add_point(Vector2(0, head_length * 0.25))

	# Tusks - two small prongs extending forward from the jaw
	var tusk_l = Line2D.new()
	tusk_l.name = "TuskL"
	tusk_l.width = 2.5
	tusk_l.default_color = Color("#FFFFF0")  # Ivory/bone color
	tusk_l.begin_cap_mode = Line2D.LINE_CAP_ROUND
	tusk_l.end_cap_mode = Line2D.LINE_CAP_ROUND
	tusk_l.z_index = 2  # Above head
	add_child(tusk_l)
	tusk_l.add_point(Vector2(-head_width * 0.25, -head_length * 0.25))
	tusk_l.add_point(Vector2(-head_width * 0.2, -head_length * 0.55))

	var tusk_r = Line2D.new()
	tusk_r.name = "TuskR"
	tusk_r.width = 2.5
	tusk_r.default_color = Color("#FFFFF0")
	tusk_r.begin_cap_mode = Line2D.LINE_CAP_ROUND
	tusk_r.end_cap_mode = Line2D.LINE_CAP_ROUND
	tusk_r.z_index = 2
	add_child(tusk_r)
	tusk_r.add_point(Vector2(head_width * 0.25, -head_length * 0.25))
	tusk_r.add_point(Vector2(head_width * 0.2, -head_length * 0.55))

func _create_draconic_head() -> void:
	# Elongated snout head with width_curve tapering from back to front
	head = Line2D.new()
	head.name = "Head"
	head.width = head_width
	head.default_color = skin_color
	head.begin_cap_mode = Line2D.LINE_CAP_ROUND
	head.end_cap_mode = Line2D.LINE_CAP_ROUND
	head.z_index = 1
	add_child(head)

	# Width curve tapers from full at back to narrow at snout
	var curve = Curve.new()
	curve.add_point(Vector2(0.0, 0.4))    # Snout tip: narrow
	curve.add_point(Vector2(0.3, 0.65))   # Mid-snout
	curve.add_point(Vector2(0.6, 0.9))    # Jaw area: widening
	curve.add_point(Vector2(1.0, 1.0))    # Back of head: full width
	head.width_curve = curve

	# Longer head for draconic snout
	head.add_point(Vector2(0, -head_length * 0.55))  # Snout tip (further forward)
	head.add_point(Vector2(0, head_length * 0.25))   # Back of head

func _create_canine_head() -> void:
	# Animal head with a separate snout extending forward
	head = Line2D.new()
	head.name = "Head"
	head.width = head_width
	head.default_color = skin_color
	head.begin_cap_mode = Line2D.LINE_CAP_ROUND
	head.end_cap_mode = Line2D.LINE_CAP_ROUND
	head.z_index = 1
	add_child(head)
	head.add_point(Vector2(0, -head_length * 0.2))
	head.add_point(Vector2(0, head_length * 0.25))

	# Snout extending forward from the front of the head
	var snout = Line2D.new()
	snout.name = "Snout"
	snout.width = head_width * 0.5  # Narrower than head
	snout.default_color = skin_color.darkened(0.05)
	snout.begin_cap_mode = Line2D.LINE_CAP_ROUND
	snout.end_cap_mode = Line2D.LINE_CAP_ROUND
	snout.z_index = 2  # Above head
	add_child(snout)
	snout.add_point(Vector2(0, -head_length * 0.15))
	snout.add_point(Vector2(0, -head_length * 0.55))  # Forward extending snout

func _create_equine_head() -> void:
	# Very elongated narrow horse head
	head = Line2D.new()
	head.name = "Head"
	head.width = head_width
	head.default_color = skin_color
	head.begin_cap_mode = Line2D.LINE_CAP_ROUND
	head.end_cap_mode = Line2D.LINE_CAP_ROUND
	head.z_index = 1
	add_child(head)

	# Width curve: narrower at front, wider at back (skull)
	var curve = Curve.new()
	curve.add_point(Vector2(0.0, 0.45))   # Nose: narrow
	curve.add_point(Vector2(0.4, 0.6))    # Mid-face
	curve.add_point(Vector2(0.7, 0.85))   # Cheekbones
	curve.add_point(Vector2(1.0, 1.0))    # Back of skull: full
	head.width_curve = curve

	# Very elongated from snout to back
	head.add_point(Vector2(0, -head_length * 0.6))  # Long snout
	head.add_point(Vector2(0, head_length * 0.25))   # Back of skull

func _create_racial_features() -> void:
	# Create a container for head features that will rotate with the head
	if head_features_node:
		head_features_node.queue_free()
	head_features_node = Node2D.new()
	head_features_node.name = "HeadFeatures"
	head_features_node.z_index = 2  # Above head
	add_child(head_features_node)

	for feature in head_features:
		match feature:
			"elf_ears":
				_create_elf_ears()
			"animal_ears":
				_create_animal_ears()
			"round_ears":
				_create_round_ears()
			"horse_ears":
				_create_horse_ears()

func _create_elf_ears() -> void:
	# Pointed ears extending outward and slightly backward from sides of head
	var ear_l = Line2D.new()
	ear_l.name = "ElfEarL"
	ear_l.width = 3.0
	ear_l.default_color = skin_color
	ear_l.begin_cap_mode = Line2D.LINE_CAP_ROUND
	ear_l.end_cap_mode = Line2D.LINE_CAP_ROUND
	head_features_node.add_child(ear_l)
	# Left ear: base at side of head, extends outward and backward
	ear_l.add_point(Vector2(-head_width * 0.45, 0))
	ear_l.add_point(Vector2(-head_width * 0.8, head_length * 0.15))

	var ear_r = Line2D.new()
	ear_r.name = "ElfEarR"
	ear_r.width = 3.0
	ear_r.default_color = skin_color
	ear_r.begin_cap_mode = Line2D.LINE_CAP_ROUND
	ear_r.end_cap_mode = Line2D.LINE_CAP_ROUND
	head_features_node.add_child(ear_r)
	ear_r.add_point(Vector2(head_width * 0.45, 0))
	ear_r.add_point(Vector2(head_width * 0.8, head_length * 0.15))

func _create_animal_ears() -> void:
	# Triangular ears pointing upward from top of head (wolf, etc.)
	var ear_l = Line2D.new()
	ear_l.name = "AnimalEarL"
	ear_l.width = 4.0
	ear_l.default_color = skin_color
	ear_l.begin_cap_mode = Line2D.LINE_CAP_ROUND
	ear_l.end_cap_mode = Line2D.LINE_CAP_ROUND
	head_features_node.add_child(ear_l)
	ear_l.add_point(Vector2(-head_width * 0.35, -head_length * 0.1))
	ear_l.add_point(Vector2(-head_width * 0.55, -head_length * 0.45))

	var ear_r = Line2D.new()
	ear_r.name = "AnimalEarR"
	ear_r.width = 4.0
	ear_r.default_color = skin_color
	ear_r.begin_cap_mode = Line2D.LINE_CAP_ROUND
	ear_r.end_cap_mode = Line2D.LINE_CAP_ROUND
	head_features_node.add_child(ear_r)
	ear_r.add_point(Vector2(head_width * 0.35, -head_length * 0.1))
	ear_r.add_point(Vector2(head_width * 0.55, -head_length * 0.45))

func _create_round_ears() -> void:
	# Small round ears on left/right of head (bear, rat)
	var ear_l = Line2D.new()
	ear_l.name = "RoundEarL"
	ear_l.width = 5.0
	ear_l.default_color = skin_color
	ear_l.begin_cap_mode = Line2D.LINE_CAP_ROUND
	ear_l.end_cap_mode = Line2D.LINE_CAP_ROUND
	head_features_node.add_child(ear_l)
	# Short line creates a round bump on each side
	ear_l.add_point(Vector2(-head_width * 0.4, -head_length * 0.15))
	ear_l.add_point(Vector2(-head_width * 0.5, -head_length * 0.25))

	var ear_r = Line2D.new()
	ear_r.name = "RoundEarR"
	ear_r.width = 5.0
	ear_r.default_color = skin_color
	ear_r.begin_cap_mode = Line2D.LINE_CAP_ROUND
	ear_r.end_cap_mode = Line2D.LINE_CAP_ROUND
	head_features_node.add_child(ear_r)
	ear_r.add_point(Vector2(head_width * 0.4, -head_length * 0.15))
	ear_r.add_point(Vector2(head_width * 0.5, -head_length * 0.25))

func _create_horse_ears() -> void:
	# Small forward-pointing ears (horse)
	var ear_l = Line2D.new()
	ear_l.name = "HorseEarL"
	ear_l.width = 2.5
	ear_l.default_color = skin_color
	ear_l.begin_cap_mode = Line2D.LINE_CAP_ROUND
	ear_l.end_cap_mode = Line2D.LINE_CAP_ROUND
	head_features_node.add_child(ear_l)
	ear_l.add_point(Vector2(-head_width * 0.3, -head_length * 0.05))
	ear_l.add_point(Vector2(-head_width * 0.35, -head_length * 0.35))

	var ear_r = Line2D.new()
	ear_r.name = "HorseEarR"
	ear_r.width = 2.5
	ear_r.default_color = skin_color
	ear_r.begin_cap_mode = Line2D.LINE_CAP_ROUND
	ear_r.end_cap_mode = Line2D.LINE_CAP_ROUND
	head_features_node.add_child(ear_r)
	ear_r.add_point(Vector2(head_width * 0.3, -head_length * 0.05))
	ear_r.add_point(Vector2(head_width * 0.35, -head_length * 0.35))

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
		HairStyle.LONG:
			_create_long_hair()
		HairStyle.BRAIDS:
			_create_braids_hair()
		HairStyle.BUN:
			_create_bun_hair()
		HairStyle.PIGTAILS:
			_create_pigtails_hair()
		HairStyle.MANE:
			_create_mane_hair()

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

func _create_long_hair() -> void:
	# Long hair - extends well past the back of the head into shoulder area
	hair = Line2D.new()
	hair.name = "Hair"
	hair.width = head_width + 4
	hair.default_color = hair_color
	hair.begin_cap_mode = Line2D.LINE_CAP_ROUND
	hair.end_cap_mode = Line2D.LINE_CAP_ROUND
	hair.z_index = 0  # Behind head
	add_child(hair)

	# Extends from near front of head well past the back into shoulder area
	hair.add_point(Vector2(0, -head_length * 0.2))
	hair.add_point(Vector2(0, head_length * 0.5))
	hair.add_point(Vector2(0, shoulder_y_offset + 6))  # Past shoulders

func _create_braids_hair() -> void:
	# Two braids running along the left and right sides of the head
	hair = Line2D.new()
	hair.name = "Hair"
	hair.width = head_width * 0.3  # Narrow braid
	hair.default_color = hair_color
	hair.begin_cap_mode = Line2D.LINE_CAP_ROUND
	hair.end_cap_mode = Line2D.LINE_CAP_ROUND
	hair.z_index = 0
	add_child(hair)

	# Left braid
	hair.add_point(Vector2(-head_width * 0.35, -head_length * 0.1))
	hair.add_point(Vector2(-head_width * 0.4, head_length * 0.3))
	hair.add_point(Vector2(-head_width * 0.35, shoulder_y_offset + 4))

	# Right braid
	var hair_right = Line2D.new()
	hair_right.name = "HairBraidR"
	hair_right.width = head_width * 0.3
	hair_right.default_color = hair_color
	hair_right.begin_cap_mode = Line2D.LINE_CAP_ROUND
	hair_right.end_cap_mode = Line2D.LINE_CAP_ROUND
	hair_right.z_index = 0
	add_child(hair_right)

	hair_right.add_point(Vector2(head_width * 0.35, -head_length * 0.1))
	hair_right.add_point(Vector2(head_width * 0.4, head_length * 0.3))
	hair_right.add_point(Vector2(head_width * 0.35, shoulder_y_offset + 4))

func _create_bun_hair() -> void:
	# Hair bun - short extra-wide blob at the back of the head
	# Back coverage first
	hair = Line2D.new()
	hair.name = "Hair"
	hair.width = head_width + 2
	hair.default_color = hair_color
	hair.begin_cap_mode = Line2D.LINE_CAP_ROUND
	hair.end_cap_mode = Line2D.LINE_CAP_ROUND
	hair.z_index = 0
	add_child(hair)

	# Covers the back portion of the head
	hair.add_point(Vector2(0, -head_length * 0.1))
	hair.add_point(Vector2(0, head_length * 0.25))

	# The bun itself - a thick round blob at the back
	var bun = Line2D.new()
	bun.name = "HairBun"
	bun.width = head_width * 0.6
	bun.default_color = hair_color.darkened(0.05)
	bun.begin_cap_mode = Line2D.LINE_CAP_ROUND
	bun.end_cap_mode = Line2D.LINE_CAP_ROUND
	bun.z_index = 0
	add_child(bun)

	# Small thick line creates a round bump at the back
	bun.add_point(Vector2(0, head_length * 0.3))
	bun.add_point(Vector2(0, head_length * 0.45))

func _create_pigtails_hair() -> void:
	# Two small bunches on left and right sides of the head
	# Main hair coverage on top
	hair = Line2D.new()
	hair.name = "Hair"
	hair.width = head_width + 2
	hair.default_color = hair_color
	hair.begin_cap_mode = Line2D.LINE_CAP_ROUND
	hair.end_cap_mode = Line2D.LINE_CAP_ROUND
	hair.z_index = 0
	add_child(hair)

	hair.add_point(Vector2(0, -head_length * 0.25))
	hair.add_point(Vector2(0, head_length * 0.15))

	# Left pigtail - small round protrusion
	var pigtail_l = Line2D.new()
	pigtail_l.name = "HairPigtailL"
	pigtail_l.width = head_width * 0.35
	pigtail_l.default_color = hair_color
	pigtail_l.begin_cap_mode = Line2D.LINE_CAP_ROUND
	pigtail_l.end_cap_mode = Line2D.LINE_CAP_ROUND
	pigtail_l.z_index = 0
	add_child(pigtail_l)

	pigtail_l.add_point(Vector2(-head_width * 0.4, -head_length * 0.05))
	pigtail_l.add_point(Vector2(-head_width * 0.6, head_length * 0.15))

	# Right pigtail
	var pigtail_r = Line2D.new()
	pigtail_r.name = "HairPigtailR"
	pigtail_r.width = head_width * 0.35
	pigtail_r.default_color = hair_color
	pigtail_r.begin_cap_mode = Line2D.LINE_CAP_ROUND
	pigtail_r.end_cap_mode = Line2D.LINE_CAP_ROUND
	pigtail_r.z_index = 0
	add_child(pigtail_r)

	pigtail_r.add_point(Vector2(head_width * 0.4, -head_length * 0.05))
	pigtail_r.add_point(Vector2(head_width * 0.6, head_length * 0.15))

func _create_mane_hair() -> void:
	# Mane running along the spine/neck for quadrupeds (horses)
	hair = Line2D.new()
	hair.name = "Hair"
	hair.width = head_width * 0.3  # Narrow strip along spine
	hair.default_color = hair_color
	hair.begin_cap_mode = Line2D.LINE_CAP_ROUND
	hair.end_cap_mode = Line2D.LINE_CAP_ROUND
	hair.z_index = 1  # On top of body
	add_child(hair)

	# Runs from back of head down along spine
	hair.add_point(Vector2(0, head_length * 0.2))
	hair.add_point(Vector2(0, shoulder_y_offset))
	hair.add_point(Vector2(0, shoulder_y_offset + 12))  # Extends down the body

# Add this to your _update_colors function if you have one, or create it
func _update_hair_colors() -> void:
	if hair:
		if hair_style == HairStyle.BUZZCUT:
			hair.default_color = hair_color.darkened(0.2)
		else:
			hair.default_color = hair_color

	# Update any secondary hair components
	for child in get_children():
		if child is Line2D and child.name.begins_with("Hair") and child != hair:
			if child.name == "HairBack" and hair_style == HairStyle.POMPADOUR:
				child.default_color = hair_color.darkened(0.1)
			elif child.name == "HairBun":
				child.default_color = hair_color.darkened(0.05)
			else:
				child.default_color = hair_color
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
	# Skip arm initialization for armless quadrupeds
	if body_type == BodyType.QUADRUPED and not has_arms:
		return

	# Initialize joint arrays
	left_arm_joints.clear()
	right_arm_joints.clear()

	# For centaur-type quadrupeds, shoulders are at the front of the body
	var shoulder_base_y = -body_length * 0.35 if (body_type == BodyType.QUADRUPED and has_arms) else shoulder_y_offset

	# Shoulders are at the BACK of the body (positive Y = behind)
	# Left arm extends to the LEFT (negative X)
	var left_shoulder = Vector2(-body_width / 2, shoulder_base_y)
	left_arm_joints.append(left_shoulder)
	var pos = left_shoulder
	for length in ARM_SEGMENT_LENGTHS:
		pos += Vector2(-length, 0)  # Extend left
		left_arm_joints.append(pos)
	left_arm_target = left_arm_joints[-1]
	
	# Right arm extends to the RIGHT (positive X)
	var right_shoulder = Vector2(body_width / 2, shoulder_base_y)
	right_arm_joints.append(right_shoulder)
	pos = right_shoulder
	for length in ARM_SEGMENT_LENGTHS:
		pos += Vector2(length, 0)  # Extend right
		right_arm_joints.append(pos)
	right_arm_target = right_arm_joints[-1]
	
	_update_arm_visuals()

func _update_colors() -> void:
	if body:
		body.default_color = skin_color
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
	if front_left_leg:
		front_left_leg.default_color = skin_color
	if front_right_leg:
		front_right_leg.default_color = skin_color
	if tail:
		tail.default_color = skin_color
	# Update snout color if present
	var snout = get_node_or_null("Snout")
	if snout:
		snout.default_color = skin_color.darkened(0.05)
	# Update head features (ears) color
	if head_features_node:
		for child in head_features_node.get_children():
			if child is Line2D and not child.name.begins_with("Tusk"):
				child.default_color = skin_color

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
		# MP regeneration (only when not stunned)
		if true: # make stun alter mp_regen_timer
			mp_regen_timer += delta
			if mp_regen_timer >= mp_regen_interval:
				mp_regen_timer -= mp_regen_interval
				MP = min(MP + mp_regen_amount, max_MP)
		# Delegate to AI child node
		if AI_enabled:
			$AI.process_ai(delta)
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

	if body_type == BodyType.QUADRUPED:
		# Quadruped body doesn't rotate much during attacks
		# Body line runs front-to-back, so rotation is applied differently
		if body:
			var front = Vector2(0, -body_length * 0.4).rotated(body_rotation * 0.3)
			var rear = Vector2(0, body_length * 0.45).rotated(body_rotation * 0.1)
			body.clear_points()
			body.add_point(front)
			body.add_point(rear)
	else:
		# Bipedal: update body line (shoulders)
		if body:
			var left_shoulder = Vector2(-body_width / 2, shoulder_y_offset).rotated(body_rotation)
			var right_shoulder = Vector2(body_width / 2, shoulder_y_offset).rotated(body_rotation)
			body.clear_points()
			body.add_point(left_shoulder)
			body.add_point(right_shoulder)

	# Update head position/rotation (head follows body slightly)
	if head:
		var head_rotation = body_rotation * 0.5
		head.rotation = head_rotation

	# Update hair to follow head
	if hair:
		hair.rotation = head.rotation if head else 0.0

	# Update head features (ears, tusks) to follow head rotation
	if head_features_node:
		head_features_node.rotation = head.rotation if head else 0.0

	# Update snout rotation for canine/equine heads
	var snout = get_node_or_null("Snout")
	if snout:
		snout.rotation = head.rotation if head else 0.0

	# Update tusk rotation for orcish heads
	var tusk_l = get_node_or_null("TuskL")
	var tusk_r = get_node_or_null("TuskR")
	if tusk_l:
		tusk_l.rotation = head.rotation if head else 0.0
	if tusk_r:
		tusk_r.rotation = head.rotation if head else 0.0

func _update_leg_animation(delta: float) -> void:
	if body_type == BodyType.QUADRUPED:
		_update_quadruped_legs(delta)
		_update_tail_animation(delta)
	else:
		_update_bipedal_legs(delta)

func _update_bipedal_legs(delta: float) -> void:
	if is_moving:
		leg_swing_time += delta * leg_swing_speed
	else:
		var target_time = round(leg_swing_time / TAU) * TAU
		leg_swing_time = lerpf(leg_swing_time, target_time, delta * 5.0)
		if abs(leg_swing_time - target_time) < 0.01:
			leg_swing_time = target_time

	var swing = sin(leg_swing_time) * leg_swing_amount
	var hip_y = shoulder_y_offset + 2

	var left_hip = Vector2(-leg_spacing, hip_y)
	var left_foot = Vector2(-leg_spacing + swing * 0.3, hip_y - leg_length + swing)
	var right_hip = Vector2(leg_spacing, hip_y)
	var right_foot = Vector2(leg_spacing - swing * 0.3, hip_y - leg_length - swing)

	if left_leg:
		left_leg.clear_points()
		left_leg.add_point(left_hip)
		left_leg.add_point(left_foot)

	if right_leg:
		right_leg.clear_points()
		right_leg.add_point(right_hip)
		right_leg.add_point(right_foot)

	if legs_equipment:
		legs_equipment.update_leg_positions(left_hip, left_foot, right_hip, right_foot)
	if feet_equipment:
		feet_equipment.update_leg_positions(left_hip, left_foot, right_hip, right_foot)

func _update_quadruped_legs(delta: float) -> void:
	if is_moving:
		leg_swing_time += delta * leg_swing_speed
	else:
		var target_time = round(leg_swing_time / TAU) * TAU
		leg_swing_time = lerpf(leg_swing_time, target_time, delta * 5.0)
		if abs(leg_swing_time - target_time) < 0.01:
			leg_swing_time = target_time

	# Trot gait: diagonal pairs move together
	var swing_a = sin(leg_swing_time) * leg_swing_amount
	var swing_b = sin(leg_swing_time + PI) * leg_swing_amount

	var front_y = -body_length * 0.35
	var rear_y = body_length * 0.4

	# Front-left + Rear-right move together (swing_a)
	if front_left_leg:
		front_left_leg.clear_points()
		front_left_leg.add_point(Vector2(-leg_spacing, front_y))
		front_left_leg.add_point(Vector2(-leg_spacing - leg_length * 0.5, front_y + swing_a))

	if right_leg:  # Rear-right
		right_leg.clear_points()
		right_leg.add_point(Vector2(leg_spacing, rear_y))
		right_leg.add_point(Vector2(leg_spacing + leg_length * 0.5, rear_y + swing_a))

	# Front-right + Rear-left move together (swing_b)
	if front_right_leg:
		front_right_leg.clear_points()
		front_right_leg.add_point(Vector2(leg_spacing, front_y))
		front_right_leg.add_point(Vector2(leg_spacing + leg_length * 0.5, front_y + swing_b))

	if left_leg:  # Rear-left
		left_leg.clear_points()
		left_leg.add_point(Vector2(-leg_spacing, rear_y))
		left_leg.add_point(Vector2(-leg_spacing - leg_length * 0.5, rear_y + swing_b))

func _update_tail_animation(delta: float) -> void:
	if not tail or not has_tail:
		return

	# Tail wags faster when moving
	var current_tail_speed = tail_swing_speed if is_moving else tail_idle_speed
	tail_swing_time += delta * current_tail_speed

	var tail_base_y = body_length * 0.45 if body_type == BodyType.QUADRUPED else shoulder_y_offset + leg_length
	tail.clear_points()

	for i in range(5):
		var t = float(i) / 4.0
		# Progressive lateral displacement creating a wave
		var lateral = sin(tail_swing_time + t * 1.5) * (t * t * 6.0)
		tail.add_point(Vector2(lateral, tail_base_y + t * tail_length))
# Helper to distinguish Weapon vs Ability logic
func _process_hand_action(item: Node2D, hand_str: String, mouse_pos: Vector2, paused: bool) -> void:
	if item is WeaponShape:
		# Standard Weapon Logic
		if paused:
			target_rotation = (mouse_pos - global_position).angle() + PI / 2
			action_queue.queue_attack(mouse_pos)
		else:
			target_rotation = (mouse_pos - global_position).angle() + PI / 2
			attack(hand_str)
			
	elif item is AbilityShape:
		# Ability Logic — always face the target
		target_rotation = (mouse_pos - global_position).angle() + PI / 2
		var ability_data = item.get_ability_data()
		if ability_data.get("requires_targeting", false):
			targeting_system.start_targeting(hand_str, ability_data, mouse_pos)
		else:
			# Instant cast (self buffs, etc)
			if paused:
				action_queue.queue_ability(item.ability_id, mouse_pos)
			else:
				var ability_obj = Ability.from_dict(ability_data)
				use_ability(ability_obj, {"position": mouse_pos})

func cast_ability(ability: AbilityShape):
	if attack_animator.is_attacking: return
	
	print("Casting ability: ", ability.ability_name)

	# 1. Trigger Visuals
	ability.activate_visuals(true)

	# 2. Trigger Animation (Straight arm push)
	attack_animator.start_cast()

	# 3. Wait for hit frame (via signal) to spawn actual projectile
	await attack_animator.attack_hit_frame

	# 4. Execute Logic (Spawn fireball, etc)
	
	# 5. Cleanup Visuals
	await attack_animator.attack_finished
	ability.activate_visuals(false)
	print("is cast ability being called") #it isn't
	targeting_system._end_targeting()

func _handle_input() -> void:
	if not is_player_controlled:
		return
	var mouse_pos = get_global_mouse_position()
	var paused = PauseManager.is_paused

	if paused != _was_paused:
		_was_paused = paused
		return

	# --- Right mouse button - Off hand ---
	if paused:
		if Input.is_action_just_pressed("right_click"):
			current_hand = "Off"
			_handle_hand_input("Off", current_off_hand_item, mouse_pos, paused)
	else:
		if Input.is_action_just_pressed("right_click"):
			current_hand = "Off"
			_handle_hand_input("Off", current_off_hand_item, mouse_pos, paused)

	# --- Left mouse button - Main hand ---
	if paused:
		if Input.is_action_just_pressed("left_click") or Input.is_action_just_pressed("ui_select"):
			current_hand = "Main"
			_handle_hand_input("Main", current_main_hand_item, mouse_pos, paused)
	else:
		if Input.is_action_just_pressed("left_click") or Input.is_action_just_pressed("ui_select"):
			current_hand = "Main"
			_handle_hand_input("Main", current_main_hand_item, mouse_pos, paused)

	# --- Middle mouse button - Move ---
	if paused:
		if Input.is_action_just_pressed("middle_mouse"):
			action_queue.queue_move(mouse_pos)
	else:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
			var target_tile = GridManager.world_to_map(mouse_pos)
			if target_tile != _last_nav_target_tile:
				_last_nav_target_tile = target_tile
				var start_tile = GridManager.world_to_map(global_position)
				var tile_path = GridManager.find_path(start_tile, target_tile)
				_nav_waypoints.clear()
				for tile in tile_path:
					_nav_waypoints.append(GridManager.map_to_world(tile))
				_nav_index = 0
				if _nav_waypoints.is_empty():
					# No path or same tile — move directly
					target_position = mouse_pos
				else:
					target_position = _nav_waypoints[0]
				target_rotation = (target_position - global_position).angle() + PI / 2
				is_moving = true

	# Per-hand weapon cycling: E/Shift+E for main hand, Q/Shift+Q for off hand
	if Input.is_action_just_pressed("cycle_main_hand_next"):
		if paused:
			action_queue.queue_cycle_weapon(1, "Main")
		else:
			inventory.cycle_weapon_for_hand("Main", 1)
	elif Input.is_action_just_pressed("cycle_main_hand_prev"):
		if paused:
			action_queue.queue_cycle_weapon(-1, "Main")
		else:
			inventory.cycle_weapon_for_hand("Main", -1)

	if Input.is_action_just_pressed("cycle_off_hand_next"):
		if paused:
			action_queue.queue_cycle_weapon(1, "Off")
		else:
			inventory.cycle_weapon_for_hand("Off", 1)
	elif Input.is_action_just_pressed("cycle_off_hand_prev"):
		if paused:
			action_queue.queue_cycle_weapon(-1, "Off")
		else:
			inventory.cycle_weapon_for_hand("Off", -1)

	if paused:
		if Input.is_action_just_pressed("ui_cancel"):
			action_queue.cancel_all()
			
	if Input.is_action_just_pressed("dash"):
		if paused:
			action_queue.queue_dash(mouse_pos)
		else:
			dash(mouse_pos)
	if Input.is_action_just_pressed("ui_cancel") and targeting_system.is_targeting:
		targeting_system.cancel_targeting()
func _handle_hand_input(hand: String, item, mouse_pos: Vector2, paused: bool) -> void:
	if targeting_system.is_targeting:
		if targeting_system.current_hand == hand:
			# 2nd click: confirm the target and cast
			_confirm_ability_target(paused)
		else:
			# Clicked the other hand while targeting — cancel current targeting
			# and start a new action with this hand instead
			targeting_system.cancel_targeting()
			_process_hand_action(item, hand, mouse_pos, paused)
	else:
		# 1st click: this will enter targeting if the ability requires it,
		# or execute immediately for non-targeted actions (melee, items, etc.)
		_process_hand_action(item, hand, mouse_pos, paused)
func _confirm_ability_target(paused: bool) -> void:
	# Retrieve the data from the targeting system
	var result = targeting_system.confirm_targeting()

	if result.is_empty(): return

	# End targeting state so subsequent clicks go back to normal input
	targeting_system.end_targeting()

	var ability_data = result.get("ability", {})
	var target_pos = result.get("position", Vector2.ZERO)
	var ability_id = ability_data.get("id", "")

	# Face the target when confirming an ability
	target_rotation = (target_pos - global_position).angle() + PI / 2

	if paused:
		# QUEUE: Add visual indicator to world and add to action queue
		# Matches your queue_ability signature
		action_queue.queue_ability(ability_id, target_pos)
		
		# Optional: Create the persistent ghost indicator since we are paused
		targeting_system.create_queued_indicator(
			target_pos, 
			result.get("shape"), 
			result.get("radius", 0), 
			result.get("size", Vector2.ZERO), 
			result.get("rotation", 0.0)
		)
	else:
		# IMMEDIATE: Cast
		var ability_obj = Ability.from_dict(ability_data)
		use_ability(ability_obj, {"position": target_pos})


func _update_movement(delta: float) -> void:
	# Smoothly rotate toward target
	var angle_diff = wrapf(target_rotation - rotation, -PI, PI)
	rotation += sign(angle_diff) * min(abs(angle_diff), rotation_speed * delta)
	# Update dash timers
	if is_dashing:
		dash_timer -= delta
		if dash_timer <= 0.0:
			is_dashing = false
	if dash_cooldown_timer > 0.0:
		dash_cooldown_timer -= delta
		
	# Move toward target if moving
	if is_moving:
		var to_target = target_position - global_position
		var distance = to_target.length()

		if distance > 5.0:
			var move_dir = to_target.normalized()
			global_position += move_dir * min(move_speed * delta, distance)
		else:
			# Check if there are more waypoints to follow
			if not _nav_waypoints.is_empty() and _nav_index < _nav_waypoints.size() - 1:
				_nav_index += 1
				target_position = _nav_waypoints[_nav_index]
				target_rotation = (target_position - global_position).angle() + PI / 2
			else:
				_nav_waypoints.clear()
				_nav_index = 0
				is_moving = false
				emit_signal("character_reached_target")
	
	# Apply collision separation
	if collision_enabled:
		var separation = get_separation_vector()
		if separation.length() > 0.1:
			# Apply separation force (scaled by delta for smooth movement)
			global_position += separation * min(1.0, delta * 10.0)

func _update_arm_ik() -> void:
	# Skip for armless quadrupeds
	if body_type == BodyType.QUADRUPED and not has_arms:
		return

	# Shoulder positions - at the sides and toward the back
	var shoulder_base_y = -body_length * 0.35 if (body_type == BodyType.QUADRUPED and has_arms) else shoulder_y_offset
	var left_shoulder = Vector2(-body_width / 2, shoulder_base_y)
	var right_shoulder = Vector2(body_width / 2, shoulder_base_y)
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
	var in_combat_stance = (current_main_hand_item != null) or (current_off_hand_item != null) or (attack_animator and attack_animator.is_attacking)

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
	# Determine the holder for this hand
	var holder = main_hand_holder if hand == "Main" else off_hand_holder

	# Remove ALL children from the holder (the old item). Don't free — still in inventory.
	for child in holder.get_children():
		holder.remove_child(child)

	# Update the character reference
	if hand == "Main":
		current_main_hand_item = weapon
	else:
		current_off_hand_item = weapon

	# Add new weapon/ability to holder
	if weapon != null:
		holder.add_child(weapon)
		var grip_offset = weapon.get_grip_offset_for_hand()
		weapon.position = grip_offset
		weapon.z_index = 2  # Above character
	emit_signal("weapon_changed", weapon)

func _on_attack_hit(hand) -> void:
	if hand== "Main":
	# Called when attack hits (at the impact frame)
		if current_main_hand_item:
			emit_signal("attack_hit", current_main_hand_item.base_damage, current_main_hand_item.primary_damage_type)
		else:
			emit_signal("attack_hit", unarmed_strike_damage, unarmed_strike_damage_type)
	if hand == "Off":
		if current_main_hand_item:
			emit_signal("attack_hit", current_off_hand_item.base_damage, current_off_hand_item.primary_damage_type)
		else:
			emit_signal("attack_hit", unarmed_strike_damage, unarmed_strike_damage_type)

func _on_attack_finished() -> void:
	attack_animator.is_attacking = false

func get_weapon_tip_world_position() -> Vector2:
	var weapon = current_main_hand_item if current_hand == "Main" else current_off_hand_item
	if weapon and weapon.has_method("get_tip_local_position"):
		return weapon.to_global(weapon.get_tip_local_position())
	# Fallback: use hand position
	var joints = right_arm_joints if current_hand == "Main" else left_arm_joints
	if joints.size() > 0:
		return to_global(joints[-1])
	return global_position

# ===== PUBLIC ATTACK API =====

func attack(Ability:String= "Main") -> void:
	"""Perform an attack with current weapon"""
	if Ability == "Main":
		if attack_animator.is_attacking:
			return  # Already attacking

		# Get damage type from weapon and start appropriate animation
		var damage_type
		if current_main_hand_item != null:
			damage_type = current_main_hand_item.primary_damage_type
		else:
			damage_type = unarmed_strike_damage_type
		if damage_type == "slashing":
			SfxManager.play("slash", position)
		elif damage_type in ["ranged_arrow", "ranged_bullet"]:
			_fire_ranged_async(current_main_hand_item)
		attack_animator.start_attack(damage_type)
	if Ability == "Off":
		if attack_animator.is_attacking:
			return  # Already attacking
		# Get damage type from weapon and start appropriate animation
		var damage_type
		if current_off_hand_item != null:
			damage_type = current_off_hand_item.primary_damage_type
		else:
			damage_type = unarmed_strike_damage_type
		if damage_type == "slashing":
			SfxManager.play("slash", position)
		elif damage_type in ["ranged_arrow", "ranged_bullet"]:
			_fire_ranged_async(current_off_hand_item)
		attack_animator.start_attack(damage_type)

func _fire_ranged_async(weapon: WeaponShape) -> void:
	"""Wait for the release frame, then play SFX and ask Game.gd to spawn a projectile."""
	await attack_animator.attack_hit_frame
	if not is_instance_valid(weapon):
		return
	# Consume ammo if the weapon requires it
	if weapon.ammo_type != "":
		var ammo_index = _find_ammo_in_inventory(weapon.ammo_type)
		if ammo_index == -1:
			return  # No ammo available, skip firing
		inventory.remove_item(ammo_index)
	# Play the appropriate firing sound at the moment of release
	if weapon.primary_damage_type == "ranged_bullet":
		SfxManager.play("gun", global_position)
	else:
		SfxManager.play("bow_release", global_position)
	# Ask Game.gd to spawn and manage the projectile
	var game = get_tree().current_scene
	if game and game.has_method("spawn_projectile"):
		var fire_direction = Vector2.UP.rotated(rotation)
		game.spawn_projectile(self, fire_direction, weapon)

func _find_ammo_in_inventory(ammo_id: String) -> int:
	"""Find the first inventory item matching the given ammo id. Returns index or -1."""
	for i in range(inventory.items.size()):
		if inventory.items[i].get("id", "") == ammo_id:
			return i
	return -1

func is_attacking() -> bool:
	"""Check if currently performing an attack"""
	#print("Does character think they're attacking? ", attack_animator.is_attacking)
	return attack_animator.is_attacking

# ===== PUBLIC WEAPON API =====

func give_weapon(weapon_data: Dictionary, hand = "Main") -> WeaponShape:
	"""Give the character a weapon from data and equip it"""
	print("give weapon being run with: ", weapon_data.get("display_name", weapon_data.get("id", "")), " in hand ", hand)
	return inventory.equip_weapon_from_data(weapon_data, hand)

func give_weapon_by_name(weapon_name: String, hand:String = "Main") -> WeaponShape:
	"""Give the character a weapon by looking up its name in the database"""
	var db = ItemDatabase.weapons
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
func give_ability_by_name(ability_name: String, hand:String= "Main"):
	print("giving ability by name: ", ability_name)
	inventory.equip_ability_from_id(ability_name, hand)
	
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

func get_current_main_hand_item() -> WeaponShape:
	"""Get the currently held weapon"""
	return current_main_hand_item

func has_weapon_equipped() -> bool:
	"""Check if character is holding a weapon"""
	return current_main_hand_item != null or current_off_hand_item != null

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
	var db = ItemDatabase.equipment
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
	return game.factions[faction_id].get_relationship(faction_id, other_character.faction_id)
	
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

func initialize_limbs(base_hp: int) -> void:
	"""Initialize all limbs based on character's max HP"""
	print("initializing limbs")
	limbs.clear()
	for limb_type in LimbType.values():
		limbs[limb_type] = Limb.new(limb_type, base_hp)

func get_limb(limb_type: LimbType) -> Limb:
	return limbs.get(limb_type)

func get_total_hp() -> int:
	"""Get combined HP of all limbs"""
	var total = 0
	for limb in limbs.values():
		total += max(0, limb.current_hp)
	return total

func is_alive() -> bool:
	"""Character dies if torso or head HP <= 0 or blood is 0"""
	var torso = limbs.get(LimbType.TORSO)
	var head = limbs.get(LimbType.HEAD)
	#print("limbs and head based is_alive() returns: ", (torso and torso.current_hp > 0) and (head and head.current_hp > 0))
	#print("is alive should return: ", (torso and torso.current_hp > 0) and (head and head.current_hp > 0) and blood_amount > 0)
	var is_alive = (torso and torso.current_hp > 0) and (head and head.current_hp > 0) and blood_amount > 0
	if not is_alive:
		_on_character_died()
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
func dash(target_pos: Vector2) -> void:
	if is_dashing or dash_cooldown_timer > 0.0:
		print("tried to dash too soon after cooldown")
		return

	var dir = (target_pos - global_position).normalized()
	if dir.length() < 0.1:
		return
	is_dashing = true
	dash_timer = dash_duration
	dash_cooldown_timer = dash_cooldown

# ===== EVENTS =====

func _on_limb_damaged(limb_type: int, damage_info: Dictionary) -> void:
	# React to being hit
	if damage_info.get("actual_damage", 0) > 0:
		# Stun briefly
		if not "stunned" in conditions:
			condition_manager.apply_condition("stunned")
		
		# Check if should retreat (low health)
		var torso_hp_percent = self.get_limb(LimbType.TORSO).get_hp_percent()
		
		#TODO: Will Check for retreat using ability check function
		
func _on_character_died() -> void:
	if $AI.current_state == $AI.AIState.DEAD:
		return  # Already dead, don't re-trigger
	if "Male" in self.traits and not "Beast" in self.traits:
		SfxManager.play("man-death-scream",global_position)
	elif "Female" in self.traits and not "Beast" in self.traits:
		SfxManager.play("woman-death-scream",global_position)
	$AI.die()
	character_died.emit()
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
	#print("Attempting to spawn blood drops")
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
			if self.current_main_hand_item:
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
	if not self.current_main_hand_item or self.current_off_hand_item:
		return
	var weapon
	# Store reference before removing
	if current_hand == "Main":
		weapon = self.current_main_hand_item
	else:
		weapon = self.current_off_hand_item
	
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
				#print("Gained Bleeding. Current Tier: ", conditions["bleeding"])
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
	if target and $AI._is_enemy(target):
		$AI._acquire_target(target)

func clear_target() -> void:
	$AI._lose_target()

func get_state_name() -> String:
	return $AI.AIState.keys()[$AI.current_state]
	
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
				
		# Optional: Clamp values so they don't drop into negative infinity
		blood_amount = max(0, blood_amount)
		#print("attempting to lower torso hp: ", limbs.get(LimbType.TORSO).current_hp)
		limbs.get(LimbType.TORSO).current_hp -= tier
		#print("after attempt to lower torso hp: ", limbs.get(LimbType.TORSO).current_hp)
		#constitution = max(0, constitution)
		
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


## Ability Use
## Start using an ability
signal cast_started(ability: Ability, target_position: Vector2)
signal cast_completed(ability: Ability, results: Array)
signal cast_interrupted(ability: Ability, reason: String)
signal cast_failed(ability: Ability, reason: String)
signal targeting_started(ability: Ability)
signal targeting_cancelled(ability: Ability)

func use_ability(ability: Ability, target_data: Dictionary = {}) -> bool:
	return ability_manager.use_ability(ability, target_data)


## Start targeting mode for an ability
'''
func _start_targeting(ability: Ability) -> void:
	
	if not targeting_system:
		# No targeting system - just cast at mouse position
		print("Couldn't find targeting system, just cast at mouse position")
		var target_pos = get_viewport().get_mouse_position()
		use_ability(ability, {"position": target_pos})
		return
	
	# Configure targeting system
	var targeting_data = {
		"target_shape": ability.get_target_shape(),
		"radius": ability.get_aoe_radius(),
		"size": ability.get_aoe_size(),
		"range": ability.targeting.get("range", 0.0),
	}
	
	# Store ability for when targeting confirms
	current_cast = {
		"ability": ability,
		"state": "targeting"
	}
	
	# Start targeting (assuming hand slot, adjust as needed)
	targeting_system.start_targeting(0, targeting_data)
	targeting_started.emit(ability)
'''
## Called when targeting is confirmed
func on_targeting_confirmed(target_position: Vector2) -> void:
	if current_cast.is_empty() or current_cast.get("state") != "targeting":
		return
	
	var ability = current_cast.get("ability") as Ability
	if not ability:
		return
	
	# Check range
	var range_limit = ability.targeting.get("range", 0.0)
	if range_limit > 0:
		var distance = global_position.distance_to(target_position)
		if distance > range_limit:
			cast_failed.emit(ability, "Out of range")
			_cancel_current()
			return
	
	# Clear targeting state and use ability
	current_cast.clear()
	use_ability(ability, {"position": target_position})


## Called when targeting is cancelled
func on_targeting_cancelled() -> void:
	if current_cast.is_empty():
		return
	
	var ability = current_cast.get("ability") as Ability
	current_cast.clear()
	
	if ability:
		targeting_cancelled.emit(ability)


## AbilityManager signal handlers
func _on_ability_cast_started(ability: Ability, target_position: Vector2) -> void:
	cast_started.emit(ability, target_position)

func _on_ability_cast_completed(ability: Ability, results: Array) -> void:
	cast_completed.emit(ability, results)

func _on_ability_cast_interrupted(ability: Ability, reason: String) -> void:
	cast_interrupted.emit(ability, reason)

func _on_ability_cast_failed(ability: Ability, reason: String) -> void:
	cast_failed.emit(ability, reason)

func _on_ability_step_started(_ability: Ability, _step_index: int, _step_data: Dictionary) -> void:
	pass

func _on_ability_step_completed(_ability: Ability, _step_index: int, _results: Array) -> void:
	pass

## Spawn a projectile that travels to the target
func _spawn_projectile(ability: Ability, target_position: Vector2) -> void:
	print("spawning projectile with target_position ", target_position)
	var projectile_path = ability.visuals.get("projectile", "")
	var scene = _load_effect_scene(projectile_path)
	if not scene:
		print("Did not find projectile scene at path: ", projectile_path)
		var results = ability_manager._resolve_effects(ability, ability.effects, target_position)
		_spawn_ability_visuals(ability, target_position)
		ability_manager.cast_completed.emit(ability, results)
		return
	
	var projectile = scene.instantiate()
	
	# Position at caster
	var spawn_offset = ability.visuals.get("projectile_spawn_offset", Vector2(0, -20))
	projectile.global_position = global_position + spawn_offset
	projectile.z_index = 3
	
	# Add to scene
	var scene_root = get_tree().current_scene
	scene_root.add_child(projectile)
	
	# Configure projectile movement
	var speed = ability.visuals.get("projectile_speed", 400.0)
	var max_lifetime = ability.visuals.get("projectile_max_lifetime", 5.0)
	
	# Rotate to face target
	var direction = (target_position - projectile.global_position).normalized()
	projectile.rotation = direction.angle()
	
	# Start projectile movement
	_move_projectile(projectile, target_position, speed, max_lifetime, ability)


## Move projectile toward target (using a tween or manual process)
func _move_projectile(projectile: Node2D, target_position: Vector2, speed: float, max_lifetime: float, ability: Ability) -> void:
	var distance = projectile.global_position.distance_to(target_position)
	var duration = distance / speed
	
	# Clamp duration to max lifetime
	duration = min(duration, max_lifetime)
	
	var tween = create_tween()
	tween.tween_property(projectile, "global_position", target_position, duration)
	
	# When projectile arrives (or times out), resolve effects
	tween.finished.connect(func():
		var final_position = projectile.global_position
		projectile.queue_free()
		var results = ability_manager._resolve_effects(ability, ability.effects, final_position)
		_spawn_ability_visuals(ability, final_position)
		ability_manager.cast_completed.emit(ability, results)
	)

	# Safety timeout in case tween fails
	get_tree().create_timer(max_lifetime + 0.1).timeout.connect(func():
		if is_instance_valid(projectile):
			var final_position = projectile.global_position
			projectile.queue_free()
			var results = ability_manager._resolve_effects(ability, ability.effects, final_position)
			_spawn_ability_visuals(ability, final_position)
			ability_manager.cast_completed.emit(ability, results)
	, CONNECT_ONE_SHOT)
func _get_modified_visual_duration(ability: Ability) -> float:
	var base_duration = ability.visual_duration
	var traits = ability.traits  # assuming this is an Array of strings like ["spell", "fire", "aoe"]
	
	var final_multiplier = 1.0
	for TRAIT in traits:
		if MODIFY_DURATION_BY_TRAIT.has(TRAIT):
			final_multiplier *= MODIFY_DURATION_BY_TRAIT[TRAIT]
	
	return base_duration * final_multiplier
## Find targets in the ability's area of effect
func _find_targets_in_area(ability: Ability, center: Vector2) -> Array:
	var targets: Array = []
	var shape = ability.targeting.get("shape", "none")
	var radius = ability.targeting.get("radius", 0.0)
	var size = ability.targeting.get("size", Vector2.ZERO)
	print("shape: ", shape, " size: ", size, " and radius: ", radius, "of ability ", ability.display_name)
	# Get all potential targets
	var potential_targets: Array = []
	if game:
		if "characters_in_scene" in game:
			potential_targets.append_array(game.characters_in_scene)
		if "items_in_scene" in game:
			potential_targets.append_array(game.items_in_scene)
		if "structures_in_scene" in game:
			potential_targets.append_array(game.structures_in_scene)
	
	# Filter by area
	for target in potential_targets:
		if not is_instance_valid(target):
			continue
		
		var in_area = false
		
		match shape:
			"circle":
				var distance = center.distance_to(target.global_position)
				in_area = distance <= radius
			"rectangle":
				# Axis-aligned rectangle check
				var half_size = size / 2
				var diff = target.global_position - center
				in_area = abs(diff.x) <= half_size.x and abs(diff.y) <= half_size.y
			"cone":
				# Cone check (direction from caster to target_position)
				var cone_direction = (center - global_position).normalized()
				var to_target = (target.global_position - global_position)
				var distance = to_target.length()
				if distance <= radius:
					var angle_to_target = cone_direction.angle_to(to_target.normalized())
					var half_angle = deg_to_rad(ability.targeting.get("angle", 45.0)) / 2
					in_area = abs(angle_to_target) <= half_angle
			"line":
				# Line from caster to target_position — hit anything within half-width
				if target == self:
					continue  # Don't hit the caster
				var half_width = size.y / 2.0 if size.y > 0 else 15.0
				var line_start = global_position
				var line_end = center
				var seg = line_end - line_start
				var seg_len_sq = seg.length_squared()
				if seg_len_sq < 1.0:
					continue
				var to_pt = target.global_position - line_start
				var t = clamp(to_pt.dot(seg) / seg_len_sq, 0.0, 1.0)
				var closest = line_start + seg * t
				var dist_to_line = target.global_position.distance_to(closest)
				in_area = dist_to_line <= half_width
			"none", "single":
				# No AoE - would need different targeting logic
				in_area = target.global_position.distance_to(center) < 50.0
		
		if in_area:
			targets.append(target)
	
	return targets


## Spawn visual effects for ability
func _spawn_ability_visuals(ability: Ability, target_position: Vector2) -> void:
	var impact_path = ability.visuals.get("impact_effect", "")
	if impact_path == "":
		return

	var shape = ability.targeting.get("shape", "none")
	if shape == "line":
		_spawn_line_effect(ability, target_position)
	elif shape == "cone":
		# Cone VFX spawns at caster, facing toward target
		var size_scale = 1.0
		var radius = ability.get_aoe_radius()
		if radius > 0:
			size_scale = radius / 25.0
		var duration = _get_modified_visual_duration(ability)
		var instance = _spawn_effect(impact_path, global_position, size_scale, duration)
		if instance:
			var dir = (target_position - global_position).angle()
			instance.rotation = dir
			# Pass cone angle to shader if present
			var cone_angle_deg = ability.targeting.get("angle", 60.0)
			var wave_layer = instance.get_node_or_null("WaveLayer")
			if wave_layer and wave_layer.material is ShaderMaterial:
				wave_layer.material.set_shader_parameter("cone_half_angle", deg_to_rad(cone_angle_deg) / 2.0)
	else:
		var size_scale = 1.0
		var radius = ability.get_aoe_radius()
		if radius > 0:
			size_scale = radius / 25.0
		var duration = _get_modified_visual_duration(ability)
		_spawn_effect(impact_path, target_position, size_scale, duration)

	# Play ability SFX
	var sfx_path = ability.visuals.get("sound_impact", "")
	if sfx_path != "":
		_play_sfx_at(sfx_path, target_position)


## Spawn a line effect (e.g., lightning bolt) from caster to target
func _spawn_line_effect(ability: Ability, target_position: Vector2) -> void:
	var impact_path = ability.visuals.get("impact_effect", "")
	var scene = _load_effect_scene(impact_path)
	if not scene:
		return

	var instance = scene.instantiate()
	instance.z_index = 3

	if "start_position" in instance:
		# LightningVFX-style: has start/end position properties
		instance.start_position = Vector2.ZERO
		instance.end_position = target_position - global_position
		instance.global_position = global_position
	else:
		# Generic particle VFX: position at midpoint, rotate toward target, stretch
		var midpoint = (global_position + target_position) / 2.0
		instance.global_position = midpoint
		var direction = target_position - global_position
		instance.rotation = direction.angle()
		# Stretch along the line direction
		var line_length = direction.length()
		var base_size = 100.0  # Default VFX diameter
		instance.scale.x = line_length / base_size

	var scene_root = get_tree().current_scene
	scene_root.add_child(instance)

	var duration = _get_modified_visual_duration(ability)
	_schedule_effect_cleanup(instance, duration)

# --- Add these variables near your other vars in character.gd ---




# ============================================================
# ABILITY SFX
# ============================================================

## Play a one-shot sound effect at a world position
func _play_sfx_at(path: String, position: Vector2, volume_db: float = 0.0, pitch_scale: float = 1.0) -> AudioStreamPlayer2D:
	var stream = _load_audio(path)
	if not stream:
		return null
	
	var player = AudioStreamPlayer2D.new()
	player.stream = stream
	player.global_position = position
	player.volume_db = volume_db
	player.pitch_scale = pitch_scale
	player.max_distance = 2000.0
	
	var scene_root = get_tree().current_scene
	scene_root.add_child(player)
	player.play()
	
	# Auto-cleanup when done
	player.finished.connect(func():
		if is_instance_valid(player):
			player.queue_free()
	, CONNECT_ONE_SHOT)
	
	return player


## Play a one-shot sound attached to this character
func _play_sfx_on_self(path: String, volume_db: float = 0.0, pitch_scale: float = 1.0) -> AudioStreamPlayer2D:
	var stream = _load_audio(path)
	if not stream:
		return null
	
	var player = AudioStreamPlayer2D.new()
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = pitch_scale
	player.max_distance = 2000.0
	add_child(player)
	player.play()
	
	player.finished.connect(func():
		if is_instance_valid(player):
			player.queue_free()
	, CONNECT_ONE_SHOT)
	
	return player


func _load_audio(path: String) -> AudioStream:
	if path in _audio_cache:
		return _audio_cache[path]
	
	if not ResourceLoader.exists(path):
		push_warning("Audio not found: %s" % path)
		return null
	
	var stream = load(path) as AudioStream
	_audio_cache[path] = stream
	return stream


# ============================================================
# CONDITION VFX — attached to character, persistent while active
# ============================================================

func _spawn_condition_vfx(instance: ConditionInstance) -> void:
	var vfx_path = instance.condition.custom_vfx
	if vfx_path == "" or vfx_path == "no vfx scene":
		return
	
	# Don't double-spawn
	if instance.condition.id in _active_condition_vfx:
		return
	
	var scene = _load_effect_scene(vfx_path)
	if not scene:
		return
	
	var vfx = scene.instantiate()
	vfx.z_index = 2
	
	# Attach as child of character so it follows movement
	add_child(vfx)
	
	# Offset to the target limb if applicable
	if instance.target_limb != null:
		vfx.position = _get_limb_vfx_offset(instance.target_limb)
	else:
		vfx.position = Vector2.ZERO
	
	# Start playing if the effect supports it
	if vfx.has_method("play"):
		vfx.play(1.0)
	elif vfx.has_method("start"):
		vfx.start(1.0)
	elif vfx is GPUParticles2D or vfx is CPUParticles2D:
		vfx.emitting = true
	
	_active_condition_vfx[instance.condition.id] = vfx


func _remove_condition_vfx(instance: ConditionInstance) -> void:
	var cond_id = instance.condition.id
	if cond_id not in _active_condition_vfx:
		return
	
	var vfx = _active_condition_vfx[cond_id]
	_active_condition_vfx.erase(cond_id)
	
	if not is_instance_valid(vfx):
		return
	
	# Graceful shutdown: stop emitting, then clean up after particles finish
	if vfx.has_method("stop"):
		vfx.stop()
	
	if vfx is GPUParticles2D or vfx is CPUParticles2D:
		vfx.emitting = false
		var lifetime = vfx.lifetime if "lifetime" in vfx else 1.0
		get_tree().create_timer(lifetime).timeout.connect(func():
			if is_instance_valid(vfx):
				vfx.queue_free()
		, CONNECT_ONE_SHOT)
	else:
		vfx.queue_free()


## Approximate visual offset for a limb — 
## Position VFX relative to the procedural body layout
func _get_limb_vfx_offset(limb_type) -> Vector2:
	match limb_type:
		LimbType.HEAD:
			# Head center is at origin, face points -Y
			return Vector2(0, -head_length * 0.1)
		LimbType.TORSO:
			# Body line runs at shoulder_y_offset
			return Vector2(0, shoulder_y_offset)
		LimbType.LEFT_ARM:
			# Left shoulder is at (-body_width/2, shoulder_y_offset)
			# Mid-arm is a bit further left
			return Vector2(-body_width / 2 - 5, shoulder_y_offset)
		LimbType.RIGHT_ARM:
			return Vector2(body_width / 2 + 5, shoulder_y_offset)
		LimbType.LEFT_LEG:
			# Legs start at shoulder_y_offset+2, extend by leg_length
			# Place VFX at mid-leg
			return Vector2(-leg_spacing, shoulder_y_offset + 2 + leg_length * 0.5)
		LimbType.RIGHT_LEG:
			return Vector2(leg_spacing, shoulder_y_offset + 2 + leg_length * 0.5)
		_:
			return Vector2.ZERO


# ============================================================
# CONDITION SFX — looping ambient sound while condition is active
# ============================================================

func _start_condition_sfx(instance: ConditionInstance) -> void:
	var sfx_path = instance.condition.custom_sfx
	if sfx_path == "" or sfx_path == "no sfx scene":
		return
	
	if instance.condition.id in _active_condition_sfx:
		return
	
	var stream = _load_audio(sfx_path)
	if not stream:
		return
	
	var player = AudioStreamPlayer2D.new()
	player.stream = stream
	player.volume_db = -5.0
	player.max_distance = 1500.0
	
	# Loop if the stream supports it — otherwise it plays once as an apply sound
	# AudioStreamWAV and AudioStreamOggVorbis have loop properties;
	# we just let it play and check if it finishes
	add_child(player)
	player.play()
	
	_active_condition_sfx[instance.condition.id] = player
	
	# If it's a non-looping sound, clean up when done but keep the dict entry
	# so we don't re-trigger. The entry gets erased in _stop_condition_sfx.
	player.finished.connect(func():
		# Sound ended naturally — don't free yet, _stop_condition_sfx handles that
		pass
	, CONNECT_ONE_SHOT)


func _stop_condition_sfx(instance: ConditionInstance) -> void:
	var cond_id = instance.condition.id
	if cond_id not in _active_condition_sfx:
		return
	
	var player = _active_condition_sfx[cond_id]
	_active_condition_sfx.erase(cond_id)
	
	if is_instance_valid(player):
		player.stop()
		player.queue_free()


# ============================================================
# UPDATED CONDITION SIGNAL HANDLERS
# ============================================================



func _on_condition_suppressed(instance: ConditionInstance) -> void:
	# Hide VFX/mute SFX while suppressed but don't destroy them
	var vfx = _active_condition_vfx.get(instance.condition.id)
	if vfx and is_instance_valid(vfx):
		vfx.visible = false
		if vfx is GPUParticles2D or vfx is CPUParticles2D:
			vfx.emitting = false
	
	var sfx = _active_condition_sfx.get(instance.condition.id)
	if sfx and is_instance_valid(sfx):
		sfx.stream_paused = true

func _on_condition_unsuppressed(instance: ConditionInstance) -> void:
	var vfx = _active_condition_vfx.get(instance.condition.id)
	if vfx and is_instance_valid(vfx):
		vfx.visible = true
		if vfx is GPUParticles2D or vfx is CPUParticles2D:
			vfx.emitting = true
	
	var sfx = _active_condition_sfx.get(instance.condition.id)
	if sfx and is_instance_valid(sfx):
		sfx.stream_paused = false
## Spawn a visual effect
func _spawn_effect(scene_path: String, position: Vector2, size_scale: float = 1.0, duration: float = 1.0) -> Node:
	var scene = _load_effect_scene(scene_path)
	if not scene:
		print("did not find ability vfx scene at scene path: ", scene_path)
		return null
	print("DID FIND ABILITY VFX SCENE at scene path: ", scene_path)

	var instance = scene.instantiate()
	instance.global_position = position
	instance.z_index = 3

	var scene_root = get_tree().current_scene
	scene_root.add_child(instance)

	if instance.has_method("explode"):
		instance.explode(size_scale)
	elif instance.has_method("play"):
		instance.play(size_scale)
	elif instance.has_method("start"):
		instance.start(size_scale)
	elif "scale" in instance:
		instance.scale = Vector2(size_scale, size_scale)

	# Schedule cleanup after modified duration
	_schedule_effect_cleanup(instance, duration)

	return instance


func _schedule_effect_cleanup(effect: Node, duration: float) -> void:
	get_tree().create_timer(duration).timeout.connect(func():
		if is_instance_valid(effect):
			# Fade out if possible, otherwise just remove
			if effect.has_method("stop"):
				effect.stop()
			if effect is GPUParticles2D or effect is CPUParticles2D:
				effect.emitting = false
				# Give particles time to finish their current emission
				get_tree().create_timer(effect.lifetime if "lifetime" in effect else 1.0).timeout.connect(func():
					if is_instance_valid(effect):
						effect.queue_free()
				, CONNECT_ONE_SHOT)
			else:
				effect.queue_free()
	, CONNECT_ONE_SHOT)


## Load and cache effect scene
func _load_effect_scene(path: String) -> PackedScene:
	if path in _effect_cache:
		return _effect_cache[path]
	
	if not ResourceLoader.exists(path):
		push_warning("Effect scene not found: %s" % path)
		return null
	
	var scene = load(path) as PackedScene
	_effect_cache[path] = scene
	return scene


## Delegates to AbilityManager
func is_on_cooldown(ability_id: String) -> bool:
	return ability_manager.is_on_cooldown(ability_id)

func get_cooldown_remaining(ability_id: String) -> float:
	return ability_manager.get_cooldown_remaining(ability_id)

func interrupt_cast(reason: String = "Interrupted") -> bool:
	return ability_manager.interrupt_cast(reason)

func _cancel_current() -> void:
	if current_cast.get("state") == "targeting":
		if targeting_system:
			targeting_system.cancel_targeting()
	ability_manager.current_cast.clear()


## Get character resource value
func _get_character_resource(resource_name: String) -> float:
	# Try common patterns
	var stat_name = resource_name 
	
	if stat_name in self:
		return self.get(stat_name)
	
	if resource_name in self:
		return self.get(resource_name)
	print("Did not find resource ", resource_name, "in get_character_resource")
	return 0.0


## Spend character resource
func _spend_character_resource(resource_name: String, amount: float) -> bool:
	var stat_name = resource_name 
	
	if stat_name in self:
		self.set(stat_name, self.get(stat_name) - amount)
		return true
	
	if resource_name in self:
		self.set(resource_name, self.get(resource_name) - amount)
		return true
		print("Did not find resource ", resource_name, "in spend_character_resource")

	return false

func _on_targeting_confirmed(_hand, _ability, _pos):
	# Signal listener if you need audio/UI feedback outside the input flow
	pass

func _get_item_for_ability(id: String) -> Node2D:
	print("Attempting to get item for ability")
	# Helper to find the AbilityShape node in hands that matches the ID
	if current_main_hand_item is AbilityShape and current_main_hand_item.ability_id == id:
		return current_main_hand_item
	if current_off_hand_item is AbilityShape and current_off_hand_item.ability_id == id:
		return current_off_hand_item
	return null
## Get condition manager
func _get_condition_manager():
	if self.has_node("ConditionManager"):
		return self.get_node("ConditionManager")
	return null


## Serialize cooldowns for saving
func save_cooldowns() -> Dictionary:
	return ability_manager.save_cooldowns()


## Load cooldowns from save
func load_cooldowns(data: Dictionary) -> void:
	ability_manager.load_cooldowns(data)
