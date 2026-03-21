# weapon_shape.gd
# Defines the procedural shape/skeleton of a weapon for animation and collision
# A sprite is overlaid on top for visual fidelity
extends CharacterBody2D
class_name WeaponShape

enum WeaponType { SWORD, AXE, DAGGER, SPEAR, MACE, BOW }
enum DamageType { SLASHING, PIERCING, BLUDGEONING }
enum GripStyle { ONE_HANDED, TWO_HANDED }

@export var weapon_scale: float = 1.15

@export var weight: float = 4.0
@export var weapon_type: WeaponType = WeaponType.SWORD
@export var display_name: String = "Weapon"
@export var primary_damage_type: String = "slashing"
@export var base_damage = 1.0
@export var damage: Dictionary = {}
@export var grip_style: GripStyle = GripStyle.ONE_HANDED
@export var traits = {}
@export var use_ability:String =""

# Shape definition (all in local coordinates, weapon points "up" at -Y)
# These represent the final canonical dimensions — already scaled at assignment time.
# weapon_scale is applied when setting defaults, NOT at draw/query time.
@export var total_length: float = 50.0 * Globals.default_body_scale
@export var grip_position: float = 0.7			# 0-1, where along length the grip is (0=tip, 1=pommel)
@export var grip_length: float = 12.0 * Globals.default_body_scale
@export var blade_width: float = 6.0 * Globals.default_body_scale
@export var balance_point: float = 0.4			# 0-1, center of mass (affects swing feel)

# Collision shape points (optional, for complex shapes like axes)
var collision_points: PackedVector2Array = []

# Sprite overlay
var sprite: Sprite2D = null
@export var sprite_path: String = ""			# Path to sprite texture
@export var sprite_scale: Vector2 = Vector2.ONE	# Additional scale multiplier (user-facing)
@export var sprite_offset: Vector2 = Vector2.ZERO	# Fine-tune sprite position
@export var sprite_rotation: float = 0.0		# Rotation offset in radians

# Calculated sprite scale (from auto-scaling to match weapon dimensions)
var _calculated_sprite_scale: Vector2 = Vector2.ONE

# Debug visualization
@export var debug_draw: bool = true
var debug_lines: Array[Line2D] = []

# Calculated values
var grip_world_position: Vector2:
	get:
		var local_grip = get_grip_local_position()
		return to_global(local_grip)

var tip_world_position: Vector2:
	get:
		var local_tip = get_tip_local_position()
		return to_global(local_tip)

signal weapon_equipped
signal weapon_unequipped

# Basic Info
var id: String = ""
var cost: float = 0.0

# Combat Stats
var damage_resitances: Dictionary = {} 
var damage_modifiers: Dictionary = {}
var damage_modifier_changes: Dictionary = {}
var weapon_range: float = 1.5 # Named weapon_range to avoid keyword conflict

# Item Properties
var equip_slot: String = ""
var options: Array = []
var resources: Dictionary = {}

# Status & Durability
var max_health: float = 1.0
var current_health: float = 1.0
var is_cursed: bool = false
var emits_light: bool = false
var satiety: float = 0.0
var healing: float = 0.0
var walkability: float = 1.0

# Abilities & Conditions
var adds_condition_on_equip: Dictionary = {}
var triggers_ability_on_equip: Dictionary = {}
var adds_condition_in_inventory: Dictionary = {}

# Stack & Container Logic
var is_stackable: bool = false
var max_stack_size: int = 1
var num_stacks: int = 1
var adds_item_to_inventory: Dictionary = {}
var num_slots: int = 0
var key: String = ""
var contents: Array = []
var restricted_item_type: String = ""

func _ready() -> void:
	_setup_sprite()
	if debug_draw:
		_create_debug_visualization()

func _setup_sprite() -> void:
	# Create sprite node
	sprite = Sprite2D.new()
	sprite.name = "WeaponSprite"
	add_child(sprite)

	# Load texture if path was set before _ready (from load_from_data)
	if sprite_path and ResourceLoader.exists(sprite_path):
		sprite.texture = load(sprite_path)
		_auto_scale_sprite()

	_update_sprite_transform()

func _update_sprite_transform() -> void:
	if sprite:
		# Apply calculated scale * user scale multiplier
		sprite.scale = _calculated_sprite_scale * sprite_scale
		sprite.position = sprite_offset
		sprite.rotation = sprite_rotation

func set_sprite_texture(texture: Texture2D) -> void:
	if sprite:
		sprite.texture = texture
		_auto_scale_sprite()
		_update_sprite_transform()
	else:
		# Sprite not created yet, will be applied in _ready
		push_warning("set_sprite_texture called before sprite exists - texture will be applied on _ready")

func set_sprite_from_path(path: String) -> void:
	sprite_path = path
	# Only try to load if sprite already exists (after _ready)
	if sprite and ResourceLoader.exists(path):
		sprite.texture = load(path)
		_auto_scale_sprite()
		_update_sprite_transform()

func _auto_scale_sprite() -> void:
	"""Automatically scale sprite to match procedural dimensions.
	Writes to _calculated_sprite_scale so that the user-facing sprite_scale
	is preserved as a separate multiplier."""
	if sprite and sprite.texture:
		var tex_size = sprite.texture.get_size()
		# Scale to match total_length (sprite is assumed vertical)
		var target_height = total_length
		var scale_factor = target_height / tex_size.y

		# Store calculated scale separately from user sprite_scale
		_calculated_sprite_scale = Vector2(scale_factor, scale_factor)

		# Calculate offset so grip position aligns with origin
		var GRIP_OFFSET_TWEAK = 5
		var grip_offset_y = 0
		sprite_offset = Vector2(0, grip_offset_y)

# ===== SHAPE QUERIES =====

func get_grip_local_position() -> Vector2:
	"""Get the grip position in local coordinates (this is where hand attaches)"""
	# Grip is at origin by convention - the weapon is positioned relative to grip
	return Vector2.ZERO

func get_grip_offset_for_hand() -> Vector2:
	"""Get the offset needed to position the weapon so the grip is at the hand position.
	This accounts for grip_position (0=tip, 1=pommel) to offset the sprite correctly."""
	var offset_y = (0.5 - grip_position) * total_length
	return Vector2(0, offset_y)

func get_tip_local_position() -> Vector2:
	"""Get the weapon tip in local coordinates"""
	return Vector2(0, -total_length * grip_position)

func get_pommel_local_position() -> Vector2:
	"""Get the pommel/bottom end in local coordinates"""
	return Vector2(0, total_length * (1.0 - grip_position))

func get_blade_start_local() -> Vector2:
	"""Get where the blade/head starts (end of grip)"""
	return Vector2(0, -grip_length * 0.5)

func get_reach() -> float:
	"""Get the weapon's reach from grip to tip"""
	return total_length * grip_position

func get_swing_radius() -> float:
	"""Get effective swing radius (for sweep attacks)"""
	return total_length * grip_position + blade_width * 0.5

# ===== COLLISION =====

func get_collision_rect() -> Rect2:
	"""Get a simple rectangular collision bounds"""
	var tip = get_tip_local_position()
	var pommel = get_pommel_local_position()
	var half_width = blade_width * 0.5
	return Rect2(
		Vector2(-half_width, tip.y),
		Vector2(blade_width, pommel.y - tip.y)
	)

func get_blade_collision_rect() -> Rect2:
	"""Get collision rect for just the blade/damaging part"""
	var tip = get_tip_local_position()
	var blade_start = get_blade_start_local()
	var half_width = blade_width * 0.5
	return Rect2(
		Vector2(-half_width, tip.y),
		Vector2(blade_width, blade_start.y - tip.y)
	)

func is_point_on_blade(local_point: Vector2) -> bool:
	"""Check if a point is within the blade area"""
	return get_blade_collision_rect().has_point(local_point)

# ===== DEBUG VISUALIZATION =====

func _create_debug_visualization() -> void:
	# Clear existing
	for line in debug_lines:
		line.queue_free()
	debug_lines.clear()

	# Weapon outline
	var outline = Line2D.new()
	outline.name = "DebugOutline"
	outline.width = 1.0
	outline.default_color = Color(1, 1, 0, 0.5)	# Yellow, semi-transparent
	add_child(outline)
	debug_lines.append(outline)

	var tip = get_tip_local_position()
	var pommel = get_pommel_local_position()
	var half_w = blade_width * 0.5

	outline.add_point(Vector2(-half_w, tip.y))
	outline.add_point(Vector2(0, tip.y - 3))	# Pointed tip
	outline.add_point(Vector2(half_w, tip.y))
	outline.add_point(Vector2(half_w, pommel.y))
	outline.add_point(Vector2(-half_w, pommel.y))
	outline.add_point(Vector2(-half_w, tip.y))

	# Grip indicator
	var grip_marker = Line2D.new()
	grip_marker.name = "GripMarker"
	grip_marker.width = 3.0
	grip_marker.default_color = Color(0, 1, 0, 0.7)	# Green
	add_child(grip_marker)
	debug_lines.append(grip_marker)

	grip_marker.add_point(Vector2(-4, -grip_length * 0.5))
	grip_marker.add_point(Vector2(-4, grip_length * 0.5))

	# Balance point
	var balance_y = lerp(tip.y, pommel.y, balance_point)
	var balance_marker = Line2D.new()
	balance_marker.name = "BalanceMarker"
	balance_marker.width = 2.0
	balance_marker.default_color = Color(0, 0.5, 1, 0.7)	# Blue
	add_child(balance_marker)
	debug_lines.append(balance_marker)

	balance_marker.add_point(Vector2(-half_w - 2, balance_y))
	balance_marker.add_point(Vector2(half_w + 2, balance_y))

func set_debug_draw(enabled: bool) -> void:
	debug_draw = enabled
	if enabled:
		_create_debug_visualization()
	else:
		for line in debug_lines:
			line.queue_free()
		debug_lines.clear()

# ===== FACTORY METHODS =====
# All factory methods bake weapon_scale and Globals.default_body_scale into the
# dimensional properties so the returned weapon is immediately consistent.

static func create_sword(length: float = 50.0, damage: int = 12) -> WeaponShape:
	var weapon = WeaponShape.new()
	weapon.weapon_type = WeaponType.SWORD
	weapon.weapon_name = "Sword"
	weapon.primary_damage_type = "slashing"
	weapon.damage = {"slashing": damage}
	var s = weapon.weapon_scale * Globals.default_body_scale
	weapon.total_length = length * s
	weapon.grip_position = 0.75
	weapon.grip_length = length * 0.25 * s
	weapon.blade_width = 5.0 * s
	weapon.balance_point = 0.35
	return weapon

static func create_axe(length: float = 45.0, damage: int = 15) -> WeaponShape:
	var weapon = WeaponShape.new()
	weapon.weapon_type = WeaponType.AXE
	weapon.weapon_name = "Axe"
	weapon.primary_damage_type = "slashing"
	weapon.damage = {"slashing": damage}
	var s = weapon.weapon_scale * Globals.default_body_scale
	weapon.total_length = length * s
	weapon.grip_position = 0.85
	weapon.grip_length = length * 0.6 * s
	weapon.blade_width = 14.0 * s
	weapon.balance_point = 0.2
	return weapon

static func create_spear(length: float = 70.0, damage: int = 11) -> WeaponShape:
	var weapon = WeaponShape.new()
	weapon.weapon_type = WeaponType.SPEAR
	weapon.weapon_name = "Spear"
	weapon.primary_damage_type = "piercing"
	weapon.damage = {"piercing": damage}
	var s = weapon.weapon_scale * Globals.default_body_scale
	weapon.total_length = length * s
	weapon.grip_position = 0.6
	weapon.grip_length = length * 0.4 * s
	weapon.blade_width = 4.0 * s
	weapon.balance_point = 0.45
	return weapon

static func create_dagger(length: float = 25.0, damage: int = 8) -> WeaponShape:
	var weapon = WeaponShape.new()
	weapon.weapon_type = WeaponType.DAGGER
	weapon.weapon_name = "Dagger"
	weapon.primary_damage_type = "piercing"
	weapon.damage = {"piercing": damage}
	var s = weapon.weapon_scale * Globals.default_body_scale
	weapon.total_length = length * s
	weapon.grip_position = 0.65
	weapon.grip_length = length * 0.35 * s
	weapon.blade_width = 3.0 * s
	weapon.balance_point = 0.4
	return weapon

static func create_mace(length: float = 40.0, damage: int = 14) -> WeaponShape:
	var weapon = WeaponShape.new()
	weapon.weapon_type = WeaponType.MACE
	weapon.weapon_name = "Mace"
	weapon.primary_damage_type = "bludgeoning"
	weapon.damage = {"bludgeoning": damage}
	var s = weapon.weapon_scale * Globals.default_body_scale
	weapon.total_length = length * s
	weapon.grip_position = 0.8
	weapon.grip_length = length * 0.5 * s
	weapon.blade_width = 10.0 * s
	weapon.balance_point = 0.15
	return weapon

# ===== SERIALIZATION =====

func load_from_data(data: Dictionary) -> void:
	# Type Mapping
	if data.has("type"):
		match data["type"].to_lower():
			"sword", "longsword": weapon_type = WeaponType.SWORD
			"axe": weapon_type = WeaponType.AXE
			"dagger": weapon_type = WeaponType.DAGGER
			"spear": weapon_type = WeaponType.SPEAR
			"mace": weapon_type = WeaponType.MACE
			"bow": weapon_type = WeaponType.BOW

	# Basic Properties
	if data.has("id"): id = data["id"]
	if data.has("name"): display_name = data["name"]
	if data.has("cost"): cost = data["cost"]
	if data.has("weight"): weight = data["weight"]
	if data.has("equip_slot"): equip_slot = data["equip_slot"]
	if data.has("use_ability"): use_ability = str(data["use_ability"]) if data["use_ability"] != null else ""
	
	# Combat & Stats
	if data.has("base_damage"): base_damage = data["base_damage"]
	if data.has("damage"): damage = data["damage"]
	if data.has("primary_damage_type"): primary_damage_type = data["primary_damage_type"]
	if data.has("damage_resitances"): damage_resitances = data["damage_resitances"]
	if data.has("range"): weapon_range = data["range"]
	if data.has("damage_modifiers"): damage_modifiers = data["damage_modifiers"] if data["damage_modifiers"] != null else {}
	if data.has("damage_modifier_changes"): damage_modifier_changes = data["damage_modifier_changes"] if data["damage_modifier_changes"] != null else {}
	
	# Item State
	if data.has("max_health"): max_health = data["max_health"]
	if data.has("current_health"): current_health = data["current_health"]
	if data.has("is_cursed"): is_cursed = bool(data["is_cursed"])
	if data.has("emits_light"): emits_light = bool(data["emits_light"])
	if data.has("satiety"): satiety = data["satiety"]
	if data.has("healing"): healing = data["healing"]
	if data.has("walkability"): walkability = data["walkability"]
	
	# Logic & Arrays
	if data.has("options"): options = data["options"]
	if data.has("traits"): traits = data["traits"]
	if data.has("resources"): resources = data["resources"]
	
	# Requirements/Conditions
	if data.has("adds_condition_on_equip"): adds_condition_on_equip = data["adds_condition_on_equip"] if data["adds_condition_on_equip"] != null else {}
	if data.has("triggers_ability_on_equip"): triggers_ability_on_equip = data["triggers_ability_on_equip"] if data["triggers_ability_on_equip"] != null else {}
	if data.has("adds_condition_in_inventory"): adds_condition_in_inventory = data["adds_condition_in_inventory"] if data["adds_condition_in_inventory"] != null else {}
	
	# Stacking & Containers
	if data.has("is_stackable"): is_stackable = bool(data["is_stackable"])
	if data.has("max_stack_size"): max_stack_size = int(data["max_stack_size"]) if data["max_stack_size"] != null else 1
	if data.has("num_stacks"): num_stacks = int(data["num_stacks"]) if data["num_stacks"] != null else 1
	if data.has("adds_item_to_inventory"): adds_item_to_inventory = data["adds_item_to_inventory"] if data["adds_item_to_inventory"] != null else {}
	if data.has("num_slots"): num_slots = int(data["num_slots"]) if data["num_slots"] != null else 0
	if data.has("key"): key = str(data["key"]) if data["key"] != null else ""
	if data.has("contents"): contents = data["contents"] if data["contents"] != null else []
	if data.has("restricted_item_type"): restricted_item_type = str(data["restricted_item_type"]) if data["restricted_item_type"] != null else ""

	# Visuals & Geometry
	if data.get("size") == "default":
		_apply_default_size_for_type()
	else:
		if data.has("total_length"): total_length = data["total_length"]
		if data.has("grip_position"): grip_position = data["grip_position"]
		if data.has("grip_length"): grip_length = data["grip_length"]
		if data.has("blade_width"): blade_width = data["blade_width"]
		if data.has("balance_point"): balance_point = data["balance_point"]
		
	if data.has("sprite_path"):
		sprite_path = data["sprite_path"]
		set_sprite_from_path(sprite_path)
		
	if data.has("sprite_scale"):
		if data["sprite_scale"] is Vector2:
			sprite_scale = data["sprite_scale"]
		elif data["sprite_scale"] is float:
			sprite_scale = Vector2(data["sprite_scale"], data["sprite_scale"])

	_update_sprite_transform()
	if debug_draw:
		_create_debug_visualization()

func to_data() -> Dictionary:
	return {
		"id": id,
		"name": display_name,
		"type": WeaponType.keys()[weapon_type].to_lower(),
		"cost": cost,
		"weight": weight,
		"equip_slot": equip_slot,
		"use_ability": use_ability,
		"base_damage": base_damage,
		"damage": damage,
		"primary_damage_type": primary_damage_type,
		"damage_resitances": damage_resitances,
		"range": weapon_range,
		"damage_modifiers": damage_modifiers,
		"damage_modifier_changes": damage_modifier_changes,
		"max_health": max_health,
		"current_health": current_health,
		"is_cursed": float(is_cursed),
		"emits_light": float(emits_light),
		"satiety": satiety,
		"healing": healing,
		"walkability": walkability,
		"options": options,
		"traits": traits,
		"resources": resources,
		"adds_condition_on_equip": adds_condition_on_equip,
		"triggers_ability_on_equip": triggers_ability_on_equip,
		"adds_condition_in_inventory": adds_condition_in_inventory,
		"is_stackable": float(is_stackable),
		"max_stack_size": max_stack_size,
		"num_stacks": num_stacks,
		"adds_item_to_inventory": adds_item_to_inventory,
		"num_slots": num_slots,
		"key": key,
		"contents": contents,
		"restricted_item_type": restricted_item_type,
		"total_length": total_length,
		"grip_position": grip_position,
		"grip_length": grip_length,
		"blade_width": blade_width,
		"balance_point": balance_point,
		"sprite_path": sprite_path
	}

func get_damage_type_name() -> String:
	return primary_damage_type

func _apply_default_size_for_type() -> void:
	"""Resets geometric parameters to hardcoded defaults based on weapon_type.
	weapon_scale and Globals.default_body_scale are baked into dimensional
	properties (length, width) but NOT into 0-1 ratio properties
	(grip_position, balance_point)."""
	var s = weapon_scale * Globals.default_body_scale
	match weapon_type:
		WeaponType.SWORD:
			total_length = 50.0 * s
			grip_position = 0.75
			grip_length = 12.5 * s
			blade_width = 5.0 * s
			balance_point = 0.35
		WeaponType.AXE:
			total_length = 45.0 * s
			grip_position = 0.85
			grip_length = 27.0 * s
			blade_width = 14.0 * s
			balance_point = 0.2
		WeaponType.SPEAR:
			total_length = 70.0 * s
			grip_position = 0.6
			grip_length = 28.0 * s
			blade_width = 4.0 * s
			balance_point = 0.45
		WeaponType.DAGGER:
			total_length = 25.0 * s
			grip_position = 0.65
			grip_length = 8.75 * s
			blade_width = 3.0 * s
			balance_point = 0.4
		WeaponType.MACE:
			total_length = 40.0 * s
			grip_position = 0.8
			grip_length = 20.0 * s
			blade_width = 10.0 * s
			balance_point = 0.15
