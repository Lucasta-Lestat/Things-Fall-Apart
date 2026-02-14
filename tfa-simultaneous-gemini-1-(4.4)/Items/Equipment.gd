# equipment.gd
# Procedurally drawn armor and equipment pieces
extends Node2D
class_name Equipment

enum EquipmentType { HELMET, HOOD, BACKPACK, SHOULDER_PADS, CAPE, PANTS, BOOTS }
enum EquipmentSlot { HEAD, BACK, SHOULDERS, LEGS, FEET, OFF_HAND }

@export var equipment_type: EquipmentType = EquipmentType.HELMET
@export var equipment_name: String = "Equipment"
@export var equipment_slot: EquipmentSlot = EquipmentSlot.HEAD

# Colors
var primary_color: Color = Color("#808080")    # Main material color
var secondary_color: Color = Color("#606060")  # Accent/trim color
var detail_color: Color = Color("#a0a0a0")     # Highlights/details

# Equipment parts (Line2D nodes)
var parts: Array[Line2D] = []

# Dimensions (set by equipment type)
var base_width: float = 16.0
var base_height: float = 16.0

# For leg equipment - these get updated by character
var left_leg_points: Array[Vector2] = []
var right_leg_points: Array[Vector2] = []

signal equipment_equipped
signal equipment_unequipped

func _ready() -> void:
	_create_equipment()

func _create_equipment() -> void:
	# Clear existing parts
	for child in get_children():
		child.queue_free()
	parts.clear()
	
	match equipment_type:
		EquipmentType.HELMET:
			_create_helmet()
		EquipmentType.HOOD:
			_create_hood()
		EquipmentType.BACKPACK:
			_create_backpack()
		EquipmentType.SHOULDER_PADS:
			_create_shoulder_pads()
		EquipmentType.CAPE:
			_create_cape()
		EquipmentType.PANTS:
			_create_pants()
		EquipmentType.BOOTS:
			_create_boots()

func _create_helmet() -> void:
	equipment_name = "Steel Helmet"
	equipment_slot = EquipmentSlot.HEAD
	base_width = 18.0
	base_height = 20.0
	
	# Helmet dome (top-down view: oval covering top of head)
	var dome = Line2D.new()
	dome.name = "HelmetDome"
	dome.width = base_width
	dome.default_color = primary_color
	dome.begin_cap_mode = Line2D.LINE_CAP_ROUND
	dome.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(dome)
	parts.append(dome)
	
	# Dome covers the head from front to back
	dome.add_point(Vector2(0, -base_height * 0.4))
	dome.add_point(Vector2(0, base_height * 0.3))
	
	# Helmet rim/brim (darker edge around the helmet)
	var rim = Line2D.new()
	rim.name = "HelmetRim"
	rim.width = base_width + 4
	rim.default_color = secondary_color
	rim.begin_cap_mode = Line2D.LINE_CAP_ROUND
	rim.end_cap_mode = Line2D.LINE_CAP_ROUND
	rim.z_index = -1  # Behind dome
	add_child(rim)
	parts.append(rim)
	
	rim.add_point(Vector2(0, base_height * 0.15))
	rim.add_point(Vector2(0, base_height * 0.35))
	
	# Center ridge/crest (decorative line on top)
	var crest = Line2D.new()
	crest.name = "HelmetCrest"
	crest.width = 3.0
	crest.default_color = detail_color
	crest.begin_cap_mode = Line2D.LINE_CAP_ROUND
	crest.end_cap_mode = Line2D.LINE_CAP_ROUND
	crest.z_index = 1
	add_child(crest)
	parts.append(crest)
	
	crest.add_point(Vector2(0, -base_height * 0.35))
	crest.add_point(Vector2(0, base_height * 0.1))

func _create_hood() -> void:
	equipment_name = "Dark Hood"
	equipment_slot = EquipmentSlot.HEAD
	base_width = 20.0
	base_height = 22.0
	
	# Hood main body (drapes over head and down the back)
	var hood_main = Line2D.new()
	hood_main.name = "HoodMain"
	hood_main.default_color = primary_color
	hood_main.begin_cap_mode = Line2D.LINE_CAP_ROUND
	hood_main.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(hood_main)
	parts.append(hood_main)
	
	# Width curve: pointed at front, wide at back
	var hood_curve = Curve.new()
	hood_curve.add_point(Vector2(0.0, 0.5))   # Front point (shadowed face)
	hood_curve.add_point(Vector2(0.3, 0.9))   # Opens up
	hood_curve.add_point(Vector2(0.6, 1.0))   # Widest at crown
	hood_curve.add_point(Vector2(1.0, 0.85))  # Drapes down back
	hood_main.width_curve = hood_curve
	hood_main.width = base_width
	
	hood_main.add_point(Vector2(0, -base_height * 0.45))  # Front point
	hood_main.add_point(Vector2(0, base_height * 0.4))    # Back drape
	
	# Hood shadow/opening (dark area where face would be)
	var shadow = Line2D.new()
	shadow.name = "HoodShadow"
	shadow.width = base_width * 0.5
	shadow.default_color = secondary_color.darkened(0.3)
	shadow.begin_cap_mode = Line2D.LINE_CAP_ROUND
	shadow.end_cap_mode = Line2D.LINE_CAP_ROUND
	shadow.z_index = 1
	add_child(shadow)
	parts.append(shadow)
	
	shadow.add_point(Vector2(0, -base_height * 0.3))
	shadow.add_point(Vector2(0, -base_height * 0.1))

func _create_backpack() -> void:
	equipment_name = "Leather Backpack"
	equipment_slot = EquipmentSlot.BACK
	base_width = 16.0
	base_height = 14.0
	
	# Main pack body
	var pack = Line2D.new()
	pack.name = "PackBody"
	pack.width = base_width
	pack.default_color = primary_color
	pack.begin_cap_mode = Line2D.LINE_CAP_ROUND
	pack.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(pack)
	parts.append(pack)
	
	# Pack sits on the back (positive Y direction from character center)
	pack.add_point(Vector2(0, 0))
	pack.add_point(Vector2(0, base_height))
	
	# Pack flap/top
	var flap = Line2D.new()
	flap.name = "PackFlap"
	flap.width = base_width + 2
	flap.default_color = secondary_color
	flap.begin_cap_mode = Line2D.LINE_CAP_ROUND
	flap.end_cap_mode = Line2D.LINE_CAP_ROUND
	flap.z_index = 1
	add_child(flap)
	parts.append(flap)
	
	flap.add_point(Vector2(0, -2))
	flap.add_point(Vector2(0, 3))
	
	# Buckle/clasp
	var buckle = Line2D.new()
	buckle.name = "PackBuckle"
	buckle.width = 4.0
	buckle.default_color = detail_color
	buckle.begin_cap_mode = Line2D.LINE_CAP_ROUND
	buckle.end_cap_mode = Line2D.LINE_CAP_ROUND
	buckle.z_index = 2
	add_child(buckle)
	parts.append(buckle)
	
	buckle.add_point(Vector2(-2, 1))
	buckle.add_point(Vector2(2, 1))
	
	# Side pouches
	var left_pouch = Line2D.new()
	left_pouch.name = "LeftPouch"
	left_pouch.width = 5.0
	left_pouch.default_color = primary_color.darkened(0.1)
	left_pouch.begin_cap_mode = Line2D.LINE_CAP_ROUND
	left_pouch.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(left_pouch)
	parts.append(left_pouch)
	
	left_pouch.add_point(Vector2(-base_width * 0.4, 2))
	left_pouch.add_point(Vector2(-base_width * 0.4, base_height * 0.6))
	
	var right_pouch = Line2D.new()
	right_pouch.name = "RightPouch"
	right_pouch.width = 5.0
	right_pouch.default_color = primary_color.darkened(0.1)
	right_pouch.begin_cap_mode = Line2D.LINE_CAP_ROUND
	right_pouch.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(right_pouch)
	parts.append(right_pouch)
	
	right_pouch.add_point(Vector2(base_width * 0.4, 2))
	right_pouch.add_point(Vector2(base_width * 0.4, base_height * 0.6))

func _create_shoulder_pads() -> void:
	equipment_name = "Shoulder Pads"
	equipment_slot = EquipmentSlot.SHOULDERS
	base_width = 10.0
	base_height = 8.0
	
	# Left shoulder pad
	var left_pad = Line2D.new()
	left_pad.name = "LeftPad"
	left_pad.width = base_height
	left_pad.default_color = primary_color
	left_pad.begin_cap_mode = Line2D.LINE_CAP_ROUND
	left_pad.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(left_pad)
	parts.append(left_pad)
	
	# Positioned at left shoulder
	left_pad.add_point(Vector2(-12, 0))
	left_pad.add_point(Vector2(-12 - base_width, 0))
	
	# Right shoulder pad
	var right_pad = Line2D.new()
	right_pad.name = "RightPad"
	right_pad.width = base_height
	right_pad.default_color = primary_color
	right_pad.begin_cap_mode = Line2D.LINE_CAP_ROUND
	right_pad.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(right_pad)
	parts.append(right_pad)
	
	right_pad.add_point(Vector2(12, 0))
	right_pad.add_point(Vector2(12 + base_width, 0))
	
	# Decorative rivets/studs
	var left_stud = Line2D.new()
	left_stud.name = "LeftStud"
	left_stud.width = 3.0
	left_stud.default_color = detail_color
	left_stud.begin_cap_mode = Line2D.LINE_CAP_ROUND
	left_stud.end_cap_mode = Line2D.LINE_CAP_ROUND
	left_stud.z_index = 1
	add_child(left_stud)
	parts.append(left_stud)
	
	left_stud.add_point(Vector2(-14, 0))
	left_stud.add_point(Vector2(-14.5, 0))
	
	var right_stud = Line2D.new()
	right_stud.name = "RightStud"
	right_stud.width = 3.0
	right_stud.default_color = detail_color
	right_stud.begin_cap_mode = Line2D.LINE_CAP_ROUND
	right_stud.end_cap_mode = Line2D.LINE_CAP_ROUND
	right_stud.z_index = 1
	add_child(right_stud)
	parts.append(right_stud)
	
	right_stud.add_point(Vector2(14, 0))
	right_stud.add_point(Vector2(14.5, 0))

func _create_cape() -> void:
	equipment_name = "Cape"
	equipment_slot = EquipmentSlot.BACK
	base_width = 28.0
	base_height = 20.0
	
	# Cape body (flows from shoulders down the back)
	var cape_body = Line2D.new()
	cape_body.name = "CapeBody"
	cape_body.default_color = primary_color
	cape_body.begin_cap_mode = Line2D.LINE_CAP_ROUND
	cape_body.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(cape_body)
	parts.append(cape_body)
	
	# Width curve: narrow at neck, wide at bottom
	var cape_curve = Curve.new()
	cape_curve.add_point(Vector2(0.0, 0.4))   # Neck attachment
	cape_curve.add_point(Vector2(0.3, 0.7))   # Shoulders
	cape_curve.add_point(Vector2(0.7, 0.95))  # Flowing out
	cape_curve.add_point(Vector2(1.0, 1.0))   # Full width at bottom
	cape_body.width_curve = cape_curve
	cape_body.width = base_width
	
	cape_body.add_point(Vector2(0, 2))           # Neck
	cape_body.add_point(Vector2(0, base_height)) # Bottom hem
	
	# Cape clasp at neck
	var clasp = Line2D.new()
	clasp.name = "CapeClasp"
	clasp.width = 4.0
	clasp.default_color = detail_color
	clasp.begin_cap_mode = Line2D.LINE_CAP_ROUND
	clasp.end_cap_mode = Line2D.LINE_CAP_ROUND
	clasp.z_index = 1
	add_child(clasp)
	parts.append(clasp)
	
	clasp.add_point(Vector2(-4, 2))
	clasp.add_point(Vector2(4, 2))
	
	# Inner lining visible at edges (slightly different color)
	var lining = Line2D.new()
	lining.name = "CapeLining"
	lining.default_color = secondary_color
	lining.begin_cap_mode = Line2D.LINE_CAP_ROUND
	lining.end_cap_mode = Line2D.LINE_CAP_ROUND
	lining.z_index = -1
	add_child(lining)
	parts.append(lining)
	
	var lining_curve = Curve.new()
	lining_curve.add_point(Vector2(0.0, 0.5))
	lining_curve.add_point(Vector2(0.5, 0.9))
	lining_curve.add_point(Vector2(1.0, 1.0))
	lining.width_curve = lining_curve
	lining.width = base_width + 4
	
	lining.add_point(Vector2(0, 4))
	lining.add_point(Vector2(0, base_height + 2))

func _create_pants() -> void:
	equipment_name = "Pants"
	equipment_slot = EquipmentSlot.LEGS
	base_width = 7.0  # Slightly wider than leg
	base_height = 16.0
	
	# Left pant leg
	var left_pant = Line2D.new()
	left_pant.name = "LeftPant"
	left_pant.width = base_width
	left_pant.default_color = primary_color
	left_pant.begin_cap_mode = Line2D.LINE_CAP_ROUND
	left_pant.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(left_pant)
	parts.append(left_pant)
	
	# Default position - will be updated by character
	left_pant.add_point(Vector2(-6, 6))
	left_pant.add_point(Vector2(-6, 6 + base_height))
	
	# Right pant leg
	var right_pant = Line2D.new()
	right_pant.name = "RightPant"
	right_pant.width = base_width
	right_pant.default_color = primary_color
	right_pant.begin_cap_mode = Line2D.LINE_CAP_ROUND
	right_pant.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(right_pant)
	parts.append(right_pant)
	
	right_pant.add_point(Vector2(6, 6))
	right_pant.add_point(Vector2(6, 6 + base_height))
	
	# Belt/waistband
	var belt = Line2D.new()
	belt.name = "Belt"
	belt.width = 3.0
	belt.default_color = secondary_color
	belt.begin_cap_mode = Line2D.LINE_CAP_ROUND
	belt.end_cap_mode = Line2D.LINE_CAP_ROUND
	belt.z_index = 1
	add_child(belt)
	parts.append(belt)
	
	belt.add_point(Vector2(-8, 5))
	belt.add_point(Vector2(8, 5))
	
	# Belt buckle
	var buckle = Line2D.new()
	buckle.name = "Buckle"
	buckle.width = 4.0
	buckle.default_color = detail_color
	buckle.begin_cap_mode = Line2D.LINE_CAP_ROUND
	buckle.end_cap_mode = Line2D.LINE_CAP_ROUND
	buckle.z_index = 2
	add_child(buckle)
	parts.append(buckle)
	
	buckle.add_point(Vector2(-1.5, 5))
	buckle.add_point(Vector2(1.5, 5))

func _create_boots() -> void:
	equipment_name = "Boots"
	equipment_slot = EquipmentSlot.FEET
	base_width = 8.0
	base_height = 6.0
	
	# Left boot
	var left_boot = Line2D.new()
	left_boot.name = "LeftBoot"
	left_boot.width = base_width
	left_boot.default_color = primary_color
	left_boot.begin_cap_mode = Line2D.LINE_CAP_ROUND
	left_boot.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(left_boot)
	parts.append(left_boot)
	
	# Default position at foot - will be updated
	left_boot.add_point(Vector2(-6, 20))
	left_boot.add_point(Vector2(-6, 20 + base_height))
	
	# Right boot
	var right_boot = Line2D.new()
	right_boot.name = "RightBoot"
	right_boot.width = base_width
	right_boot.default_color = primary_color
	right_boot.begin_cap_mode = Line2D.LINE_CAP_ROUND
	right_boot.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(right_boot)
	parts.append(right_boot)
	
	right_boot.add_point(Vector2(6, 20))
	right_boot.add_point(Vector2(6, 20 + base_height))
	
	# Boot cuffs/tops (decorative)
	var left_cuff = Line2D.new()
	left_cuff.name = "LeftCuff"
	left_cuff.width = base_width + 2
	left_cuff.default_color = secondary_color
	left_cuff.begin_cap_mode = Line2D.LINE_CAP_ROUND
	left_cuff.end_cap_mode = Line2D.LINE_CAP_ROUND
	left_cuff.z_index = 1
	add_child(left_cuff)
	parts.append(left_cuff)
	
	left_cuff.add_point(Vector2(-6, 19))
	left_cuff.add_point(Vector2(-6, 21))
	
	var right_cuff = Line2D.new()
	right_cuff.name = "RightCuff"
	right_cuff.width = base_width + 2
	right_cuff.default_color = secondary_color
	right_cuff.begin_cap_mode = Line2D.LINE_CAP_ROUND
	right_cuff.end_cap_mode = Line2D.LINE_CAP_ROUND
	right_cuff.z_index = 1
	add_child(right_cuff)
	parts.append(right_cuff)
	
	right_cuff.add_point(Vector2(6, 19))
	right_cuff.add_point(Vector2(6, 21))

# Update leg equipment positions (called by character during animation)
func update_leg_positions(left_hip: Vector2, left_foot: Vector2, right_hip: Vector2, right_foot: Vector2) -> void:
	if equipment_slot == EquipmentSlot.LEGS:
		# Update pants to follow legs
		for part in parts:
			if part.name == "LeftPant":
				part.clear_points()
				part.add_point(left_hip)
				part.add_point(left_foot)
			elif part.name == "RightPant":
				part.clear_points()
				part.add_point(right_hip)
				part.add_point(right_foot)
	elif equipment_slot == EquipmentSlot.FEET:
		# Update boots to be at foot positions
		var boot_length = base_height
		for part in parts:
			if part.name == "LeftBoot":
				part.clear_points()
				part.add_point(left_foot)
				part.add_point(left_foot + Vector2(0, boot_length))
			elif part.name == "RightBoot":
				part.clear_points()
				part.add_point(right_foot)
				part.add_point(right_foot + Vector2(0, boot_length))
			elif part.name == "LeftCuff":
				part.clear_points()
				part.add_point(left_foot + Vector2(0, -1))
				part.add_point(left_foot + Vector2(0, 2))
			elif part.name == "RightCuff":
				part.clear_points()
				part.add_point(right_foot + Vector2(0, -1))
				part.add_point(right_foot + Vector2(0, 2))

# Get the slot this equipment occupies
func get_slot() -> EquipmentSlot:
	return equipment_slot

# Set custom colors
func set_colors(primary: Color, secondary: Color, detail: Color) -> void:
	primary_color = primary
	secondary_color = secondary
	detail_color = detail
	_create_equipment()

# Load from dictionary
func load_from_data(data: Dictionary) -> void:
	if data.has("type"):
		match data["type"].to_lower():
			"helmet": equipment_type = EquipmentType.HELMET
			"hood": equipment_type = EquipmentType.HOOD
			"backpack": equipment_type = EquipmentType.BACKPACK
			"shoulder_pads", "shoulders": equipment_type = EquipmentType.SHOULDER_PADS
			"cape": equipment_type = EquipmentType.CAPE
			"pants": equipment_type = EquipmentType.PANTS
			"boots": equipment_type = EquipmentType.BOOTS
	
	if data.has("primary_color"):
		primary_color = Color.html(data["primary_color"])
	if data.has("secondary_color"):
		secondary_color = Color.html(data["secondary_color"])
	if data.has("detail_color"):
		detail_color = Color.html(data["detail_color"])
	if data.has("name"):
		equipment_name = data["name"]
	
	_create_equipment()
