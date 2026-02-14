# weapon.gd
# Base class for procedurally drawn weapons
extends Node2D
class_name Weapon

enum WeaponType { LONGSWORD, AXE, DAGGER, SPEAR, MACE }

@export var weapon_type: WeaponType = WeaponType.LONGSWORD
@export var weapon_name: String = "Weapon"
var damage_type: String = "slashing"
var base_damage: int = 5
# Colors
var blade_color: Color = Color("#a8a8a8")  # Steel gray
var handle_color: Color = Color("#4a3728")  # Wood brown
var accent_color: Color = Color("#ffd700")  # Gold for guards/decorations

# Weapon parts (Line2D nodes)
var handle: Line2D
var blade: Line2D
var guard: Line2D  # Crossguard for swords, axe head connection
var axe_head: Line2D  # Only for axes

# Dimensions (will vary by weapon type)
var handle_length: float = 12.0
var handle_width: float = 4.0
var blade_length: float = 25.0
var blade_width: float = 5.0

signal weapon_equipped
signal weapon_unequipped

func _ready() -> void:
	_create_weapon()

func _create_weapon() -> void:
	# Clear existing parts
	for child in get_children():
		child.queue_free()
	
	match weapon_type:
		WeaponType.LONGSWORD:
			_create_longsword()
		WeaponType.AXE:
			_create_axe()
		WeaponType.DAGGER:
			_create_dagger()
		WeaponType.SPEAR:
			_create_spear()
		WeaponType.MACE:
			_create_mace()

func _create_longsword() -> void:
	weapon_name = "Longsword"
	damage_type = "slashing"
	base_damage = 12
	handle_length = 16.0
	handle_width = 3.5
	blade_length = 38.0
	blade_width = 4.5
	
	# Handle (pommel to guard)
	handle = Line2D.new()
	handle.name = "Handle"
	handle.width = handle_width
	handle.default_color = handle_color
	handle.begin_cap_mode = Line2D.LINE_CAP_ROUND
	handle.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(handle)
	
	# Handle goes from grip end toward blade
	handle.add_point(Vector2(0, handle_length))  # Pommel end (held here)
	handle.add_point(Vector2(0, 0))  # Guard end
	
	# Crossguard
	guard = Line2D.new()
	guard.name = "Guard"
	guard.width = 3.0
	guard.default_color = accent_color
	guard.begin_cap_mode = Line2D.LINE_CAP_ROUND
	guard.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(guard)
	
	guard.add_point(Vector2(-6, 0))
	guard.add_point(Vector2(6, 0))
	
	# Blade
	blade = Line2D.new()
	blade.name = "Blade"
	blade.default_color = blade_color
	blade.begin_cap_mode = Line2D.LINE_CAP_NONE
	blade.end_cap_mode = Line2D.LINE_CAP_NONE
	add_child(blade)
	
	# Blade tapers to a point
	var blade_curve = Curve.new()
	blade_curve.add_point(Vector2(0.0, 1.0))   # Base: full width
	blade_curve.add_point(Vector2(0.7, 0.9))   # Most of blade
	blade_curve.add_point(Vector2(0.9, 0.5))   # Taper starts
	blade_curve.add_point(Vector2(1.0, 0.1))   # Tip: pointed
	blade.width_curve = blade_curve
	blade.width = blade_width
	
	blade.add_point(Vector2(0, 0))  # At guard
	blade.add_point(Vector2(0, -blade_length))  # Tip (forward)

func _create_axe() -> void:
	weapon_name = "Battle Axe"
	damage_type = "slashing"
	base_damage = 15
	handle_length = 28.0
	handle_width = 3.5
	var head_width = 18.0
	var head_height = 14.0
	
	# Handle
	handle = Line2D.new()
	handle.name = "Handle"
	handle.width = handle_width
	handle.default_color = handle_color
	handle.begin_cap_mode = Line2D.LINE_CAP_ROUND
	handle.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(handle)
	
	handle.add_point(Vector2(0, handle_length))  # Grip end
	handle.add_point(Vector2(0, 0))  # Head end
	
	# Axe head - drawn as a curved blade shape
	axe_head = Line2D.new()
	axe_head.name = "AxeHead"
	axe_head.default_color = blade_color
	axe_head.begin_cap_mode = Line2D.LINE_CAP_ROUND
	axe_head.end_cap_mode = Line2D.LINE_CAP_ROUND
	axe_head.z_index = 1
	add_child(axe_head)
	
	# Width curve for axe head - thick at spine, thin at edge
	var head_curve = Curve.new()
	head_curve.add_point(Vector2(0.0, 0.3))   # Top edge (thin)
	head_curve.add_point(Vector2(0.2, 0.8))   # Curves out
	head_curve.add_point(Vector2(0.5, 1.0))   # Thickest at middle (spine)
	head_curve.add_point(Vector2(0.8, 0.8))   # Curves back
	head_curve.add_point(Vector2(1.0, 0.3))   # Bottom edge (thin)
	axe_head.width_curve = head_curve
	axe_head.width = head_height
	
	# Axe head extends to one side
	axe_head.add_point(Vector2(0, -2))  # Near handle
	axe_head.add_point(Vector2(-head_width, -2))  # Blade edge
	
	# Socket/collar where head meets handle
	guard = Line2D.new()
	guard.name = "Socket"
	guard.width = 5.0
	guard.default_color = accent_color
	guard.begin_cap_mode = Line2D.LINE_CAP_ROUND
	guard.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(guard)
	
	guard.add_point(Vector2(-2, 1))
	guard.add_point(Vector2(2, 1))

func _create_dagger() -> void:
	weapon_name = "Dagger"
	damage_type = "piercing"
	base_damage = 6
	handle_length = 10.0
	handle_width = 3.0
	blade_length = 16.0
	blade_width = 3.5
	
	# Handle
	handle = Line2D.new()
	handle.name = "Handle"
	handle.width = handle_width
	handle.default_color = handle_color
	handle.begin_cap_mode = Line2D.LINE_CAP_ROUND
	handle.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(handle)
	
	handle.add_point(Vector2(0, handle_length))
	handle.add_point(Vector2(0, 0))
	
	# Small crossguard
	guard = Line2D.new()
	guard.name = "Guard"
	guard.width = 2.5
	guard.default_color = accent_color
	guard.begin_cap_mode = Line2D.LINE_CAP_ROUND
	guard.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(guard)
	
	guard.add_point(Vector2(-4, 0))
	guard.add_point(Vector2(4, 0))
	
	# Blade - short and pointed
	blade = Line2D.new()
	blade.name = "Blade"
	blade.default_color = blade_color
	blade.begin_cap_mode = Line2D.LINE_CAP_NONE
	blade.end_cap_mode = Line2D.LINE_CAP_NONE
	add_child(blade)
	
	var blade_curve = Curve.new()
	blade_curve.add_point(Vector2(0.0, 1.0))
	blade_curve.add_point(Vector2(0.5, 0.8))
	blade_curve.add_point(Vector2(1.0, 0.1))
	blade.width_curve = blade_curve
	blade.width = blade_width
	
	blade.add_point(Vector2(0, 0))
	blade.add_point(Vector2(0, -blade_length))

func _create_spear() -> void:
	weapon_name = "Spear"
	damage_type = "piercing"
	base_damage = 10
	handle_length = 45.0
	handle_width = 3.0
	blade_length = 14.0
	blade_width = 4.5
	
	# Long shaft
	handle = Line2D.new()
	handle.name = "Shaft"
	handle.width = handle_width
	handle.default_color = handle_color
	handle.begin_cap_mode = Line2D.LINE_CAP_ROUND
	handle.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(handle)
	
	handle.add_point(Vector2(0, handle_length))
	handle.add_point(Vector2(0, 0))
	
	# Spearhead
	blade = Line2D.new()
	blade.name = "Spearhead"
	blade.default_color = blade_color
	blade.begin_cap_mode = Line2D.LINE_CAP_NONE
	blade.end_cap_mode = Line2D.LINE_CAP_NONE
	add_child(blade)
	
	var blade_curve = Curve.new()
	blade_curve.add_point(Vector2(0.0, 0.6))  # Base
	blade_curve.add_point(Vector2(0.3, 1.0))  # Widens
	blade_curve.add_point(Vector2(0.7, 0.7))  # Narrows
	blade_curve.add_point(Vector2(1.0, 0.1))  # Point
	blade.width_curve = blade_curve
	blade.width = blade_width
	
	blade.add_point(Vector2(0, 0))
	blade.add_point(Vector2(0, -blade_length))

func _create_mace() -> void:
	weapon_name = "Mace"
	damage_type = "bludgeoning"
	base_damage = 14
	handle_length = 22.0
	handle_width = 3.5
	var head_size = 10.0
	
	# Handle
	handle = Line2D.new()
	handle.name = "Handle"
	handle.width = handle_width
	handle.default_color = handle_color
	handle.begin_cap_mode = Line2D.LINE_CAP_ROUND
	handle.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(handle)
	
	handle.add_point(Vector2(0, handle_length))
	handle.add_point(Vector2(0, 0))
	
	# Mace head - circular
	blade = Line2D.new()
	blade.name = "Head"
	blade.width = head_size
	blade.default_color = blade_color
	blade.begin_cap_mode = Line2D.LINE_CAP_ROUND
	blade.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(blade)
	
	blade.add_point(Vector2(0, -head_size * 0.4))
	blade.add_point(Vector2(0, -head_size * 0.5))
	
	# Flanges/spikes (decorative lines)
	guard = Line2D.new()
	guard.name = "Flanges"
	guard.width = 2.0
	guard.default_color = accent_color
	guard.begin_cap_mode = Line2D.LINE_CAP_ROUND
	guard.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(guard)
	
	guard.add_point(Vector2(-head_size * 0.5, -head_size * 0.4))
	guard.add_point(Vector2(head_size * 0.5, -head_size * 0.4))

# Get the grip position (where hand holds the weapon)
func get_grip_position() -> Vector2:
	return Vector2(0, handle_length * 0.7)

# Get total weapon length for reach calculations
func get_weapon_length() -> float:
	return handle_length + blade_length

# Set custom colors
func set_colors(new_blade: Color, new_handle: Color, new_accent: Color) -> void:
	blade_color = new_blade
	handle_color = new_handle
	accent_color = new_accent
	_create_weapon()

# Load from dictionary (for JSON-based weapon definitions)
func load_from_data(data: Dictionary) -> void:
	if data.has("type"):
		match data["type"].to_lower():
			"longsword": weapon_type = WeaponType.LONGSWORD
			"axe": weapon_type = WeaponType.AXE
			"dagger": weapon_type = WeaponType.DAGGER
			"spear": weapon_type = WeaponType.SPEAR
			"mace": weapon_type = WeaponType.MACE
	
	if data.has("blade_color"):
		blade_color = Color.html(data["blade_color"])
	if data.has("handle_color"):
		handle_color = Color.html(data["handle_color"])
	if data.has("accent_color"):
		accent_color = Color.html(data["accent_color"])
	if data.has("name"):
		weapon_name = data["name"]
	if data.has("damage_type"):
		damage_type = data["damage_type"]
	
	_create_weapon()
