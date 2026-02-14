# equipment_shape.gd
# Defines procedural shape/attachment points for equipment with sprite overlay
extends Node2D
class_name EquipmentShape

enum EquipmentType { HELMET, HOOD, BACKPACK, TORSO_ARMOR, CAPE, PANTS, BOOTS }
enum EquipmentSlot { HEAD, TORSO, BACK, LEGS, FEET }

@export var equipment_type: EquipmentType = EquipmentType.HELMET
@export var equipment_name: String = "Equipment"
@export var equipment_slot: EquipmentSlot = EquipmentSlot.HEAD

# Shape definition
@export var base_width: float = 16.0
@export var base_height: float = 16.0
@export var attachment_offset: Vector2 = Vector2.ZERO  # Offset from slot position
@export var DR: int = 1
# Sprite overlay
var sprite: Sprite2D = null
var left_sprite: Sprite2D = null   # For paired equipment (boots, pants legs)
var right_sprite: Sprite2D = null
@export var sprite_path: String = ""
@export var sprite_scale: Vector2 = Vector2.ONE
@export var sprite_offset: Vector2 = Vector2.ZERO
@export var sprite_rotation: float = 0.0

# For leg equipment - updated by character
var is_leg_equipment: bool = false

signal equipment_equipped
signal equipment_unequipped

func _ready() -> void:
	_determine_equipment_properties()
	_setup_sprites()

func _determine_equipment_properties() -> void:
	match equipment_type:
		EquipmentType.HELMET:
			equipment_slot = EquipmentSlot.HEAD
			base_width = Globals.default_head_width
			base_height = Globals.default_head_length
		EquipmentType.HOOD:
			equipment_slot = EquipmentSlot.HEAD
			base_width = Globals.default_head_width+4
			base_height = Globals.default_head_length+2
		EquipmentType.BACKPACK:
			equipment_slot = EquipmentSlot.BACK
			base_width = 16.0
			base_height = 14.0
		EquipmentType.TORSO_ARMOR:
			equipment_slot = EquipmentSlot.TORSO
			base_width = Globals.default_body_width  # Covers full body width
			base_height = Globals.default_body_height # Covers torso depth
		EquipmentType.CAPE:
			equipment_slot = EquipmentSlot.BACK
			base_width = 28.0
			base_height = 24.0
		EquipmentType.PANTS:
			equipment_slot = EquipmentSlot.LEGS
			base_width = Globals.default_leg_width
			base_height = Globals.default_leg_length
			is_leg_equipment = true
		EquipmentType.BOOTS:
			equipment_slot = EquipmentSlot.FEET
			base_width = 8.0
			base_height = 8.0
			is_leg_equipment = true

func _setup_sprites() -> void:
	if is_leg_equipment:
		# Create paired sprites for legs
		left_sprite = Sprite2D.new()
		left_sprite.name = "LeftSprite"
		add_child(left_sprite)
		
		right_sprite = Sprite2D.new()
		right_sprite.name = "RightSprite"
		add_child(right_sprite)
	else:
		# Single sprite
		sprite = Sprite2D.new()
		sprite.name = "EquipmentSprite"
		add_child(sprite)
	
	# Load texture if path was set before _ready (from load_from_data)
	if sprite_path and ResourceLoader.exists(sprite_path):
		_load_sprite_texture(sprite_path)
		_auto_scale_sprite()
	
	_update_sprite_transforms()

func _load_sprite_texture(path: String) -> void:
	var texture = load(path)
	if texture:
		if is_leg_equipment:
			if left_sprite: left_sprite.texture = texture
			if right_sprite: right_sprite.texture = texture
		else:
			if sprite: sprite.texture = texture

func _update_sprite_transforms() -> void:
	if is_leg_equipment:
		if left_sprite:
			left_sprite.scale = sprite_scale
			left_sprite.rotation = sprite_rotation
		if right_sprite:
			right_sprite.scale = sprite_scale
			right_sprite.rotation = sprite_rotation
	else:
		if sprite:
			sprite.scale = sprite_scale
			sprite.position = sprite_offset + attachment_offset
			sprite.rotation = sprite_rotation

func set_sprite_texture(texture: Texture2D) -> void:
	var has_sprite = sprite or (is_leg_equipment and left_sprite)
	if not has_sprite:
		push_warning("set_sprite_texture called before sprites exist")
		return
	
	if is_leg_equipment:
		if left_sprite: left_sprite.texture = texture
		if right_sprite: right_sprite.texture = texture
	else:
		if sprite: sprite.texture = texture
	_auto_scale_sprite()

func set_sprite_from_path(path: String) -> void:
	sprite_path = path
	# Only try to load if sprites already exist (after _ready)
	var has_sprite = sprite or (is_leg_equipment and left_sprite)
	if has_sprite and ResourceLoader.exists(path):
		_load_sprite_texture(path)
		_auto_scale_sprite()

func _auto_scale_sprite(body_scale:float = 1.0) -> void:
	"""Scale sprite to match equipment dimensions"""
	var tex: Texture2D = null
	if is_leg_equipment and left_sprite:
		tex = left_sprite.texture
	elif sprite:
		tex = sprite.texture
	
	if tex:
		var tex_size = tex.get_size()
		var scale_x = base_width / tex_size.x
		var scale_y = base_height / tex_size.y
		var uniform_scale = min(scale_x, scale_y)
		sprite_scale = 2*Vector2(scale_x,scale_y)
		if is_leg_equipment:
			if left_sprite: left_sprite.scale = Vector2(uniform_scale, uniform_scale) * sprite_scale
			if right_sprite: right_sprite.scale = Vector2(uniform_scale, uniform_scale) * sprite_scale
		else:
			if sprite: sprite.scale = Vector2(uniform_scale, uniform_scale) * sprite_scale

# ===== LEG EQUIPMENT UPDATES =====

func update_leg_positions(left_hip: Vector2, left_foot: Vector2, right_hip: Vector2, right_foot: Vector2) -> void:
	"""Called by character to update leg equipment positions during animation"""
	if not is_leg_equipment:
		return
	
	match equipment_slot:
		EquipmentSlot.LEGS:  # Pants
			_update_pants_position(left_hip, left_foot, right_hip, right_foot)
		EquipmentSlot.FEET:  # Boots
			_update_boots_position(left_foot, right_foot)

func _update_pants_position(left_hip: Vector2, left_foot: Vector2, right_hip: Vector2, right_foot: Vector2) -> void:
	if left_sprite:
		# Position at midpoint of leg, rotate to align
		var left_mid = (left_hip + left_foot) * 0.5
		var left_dir = (left_foot - left_hip).normalized()
		var left_angle = left_dir.angle() + PI/2  # Rotate to align with leg
		left_sprite.position = left_mid
		left_sprite.rotation = left_angle
	
	if right_sprite:
		var right_mid = (right_hip + right_foot) * 0.5
		var right_dir = (right_foot - right_hip).normalized()
		var right_angle = right_dir.angle() + PI/2
		right_sprite.position = right_mid
		right_sprite.rotation = right_angle

func _update_boots_position(left_foot: Vector2, right_foot: Vector2) -> void:
	if left_sprite:
		left_sprite.position = left_foot + Vector2(0, base_height * 0.5)
	if right_sprite:
		right_sprite.position = right_foot + Vector2(0, base_height * 0.5)

# ===== QUERIES =====

func get_slot() -> EquipmentSlot:
	return equipment_slot

func get_bounds() -> Rect2:
	return Rect2(
		attachment_offset - Vector2(base_width, base_height) * 0.5,
		Vector2(base_width, base_height)
	)

# ===== SERIALIZATION =====

func load_from_data(data: Dictionary) -> void:
	if data.has("type"):
		match data["type"].to_lower():
			"helmet": equipment_type = EquipmentType.HELMET
			"hood": equipment_type = EquipmentType.HOOD
			"backpack": equipment_type = EquipmentType.BACKPACK
			"torso", "torso_armor", "breastplate", "chestplate", "armor": 
				equipment_type = EquipmentType.TORSO_ARMOR
			"cape", "cloak": equipment_type = EquipmentType.CAPE
			"pants", "leggings": equipment_type = EquipmentType.PANTS
			"boots", "greaves": equipment_type = EquipmentType.BOOTS
	
	_determine_equipment_properties()
	
	if data.has("name"): equipment_name = data["name"]
	if data.has("base_width"): base_width = data["base_width"]
	if data.has("base_height"): base_height = data["base_height"]
	if data.has("sprite_path"):
		sprite_path = data["sprite_path"]
	if data.has("sprite_scale"):
		if data["sprite_scale"] is Vector2:
			sprite_scale = data["sprite_scale"]
		elif data["sprite_scale"] is float:
			sprite_scale = Vector2(data["sprite_scale"], data["sprite_scale"])
	if data.has("sprite_offset"):
		sprite_offset = data["sprite_offset"]
	
	_setup_sprites()
	if sprite_path:
		set_sprite_from_path(sprite_path)

func to_data() -> Dictionary:
	return {
		"type": EquipmentType.keys()[equipment_type].to_lower(),
		"name": equipment_name,
		"base_width": base_width,
		"base_height": base_height,
		"sprite_path": sprite_path
	}

# ===== FACTORY METHODS =====

static func create_helmet() -> EquipmentShape:
	var eq = EquipmentShape.new()
	eq.equipment_type = EquipmentType.HELMET
	eq.equipment_name = "Helmet"
	return eq

static func create_hood() -> EquipmentShape:
	var eq = EquipmentShape.new()
	eq.equipment_type = EquipmentType.HOOD
	eq.equipment_name = "Hood"
	return eq

static func create_pants() -> EquipmentShape:
	var eq = EquipmentShape.new()
	eq.equipment_type = EquipmentType.PANTS
	eq.equipment_name = "Pants"
	return eq

static func create_boots() -> EquipmentShape:
	var eq = EquipmentShape.new()
	eq.equipment_type = EquipmentType.BOOTS
	eq.equipment_name = "Boots"
	return eq
