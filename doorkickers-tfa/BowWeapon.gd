 #BowWeapon.gd
extends RangedWeapon
class_name BowWeapon

@export var draw_time: float = 1.0
@export var max_draw_force: float = 100.0
@export var arrow_weight: float = 0.05

var is_drawing: bool = false
var draw_start_time: float = 0.0
var draw_power: float = 0.0
var bow_string_anchor: Vector2

signal draw_started()
signal draw_released(power)

func _ready():
	super._ready()
	damage_type = "piercing"
	
	# Create bow visual
	_create_bow_visual()

func _create_bow_visual():
	# Override parent visual
	for child in get_children():
		if child is Polygon2D:
			child.queue_free()
	
	# Bow limbs
	var upper_limb = Line2D.new()
	upper_limb.add_point(Vector2(0, 0))
	upper_limb.add_point(Vector2(weapon_length * 0.7, -weapon_length * 0.4))
	upper_limb.width = 3.0
	upper_limb.default_color = Color(0.6, 0.4, 0.2)
	add_child(upper_limb)
	
	var lower_limb = Line2D.new()
	lower_limb.add_point(Vector2(0, 0))
	lower_limb.add_point(Vector2(weapon_length * 0.7, weapon_length * 0.4))
	lower_limb.width = 3.0
	lower_limb.default_color = Color(0.6, 0.4, 0.2)
	add_child(lower_limb)
	
	# Bow string (will be animated)
	var string = Line2D.new()
	string.name = "String"
	string.add_point(Vector2(weapon_length * 0.7, -weapon_length * 0.4))
	string.add_point(Vector2(weapon_length * 0.1, 0))  # Draw point
	string.add_point(Vector2(weapon_length * 0.7, weapon_length * 0.4))
	string.width = 1.0
	string.default_color = Color(0.9, 0.9, 0.9)
	add_child(string)
	
	bow_string_anchor = Vector2(weapon_length * 0.1, 0)

func start_draw():
	if is_drawing or current_ammo <= 0:
		return
	
	is_drawing = true
	draw_start_time = Time.get_ticks_msec() / 1000.0
	draw_started.emit()

func update_draw(delta: float):
	if not is_drawing:
		return
	
	var draw_duration = (Time.get_ticks_msec() / 1000.0) - draw_start_time
	draw_power = clamp(draw_duration / draw_time, 0.0, 1.0)
	
	# Animate string
	var string = get_node_or_null("String")
	if string:
		var draw_distance = draw_power * weapon_length * 0.3
		string.set_point_position(1, bow_string_anchor - Vector2(draw_distance, 0))
	
	# Visual feedback - slight vibration at full draw
	if draw_power >= 1.0:
		position += Vector2(randf_range(-0.5, 0.5), randf_range(-0.5, 0.5))

func release_draw():
	if not is_drawing:
		return
	
	is_drawing = false
	
	# Fire arrow with power based on draw
	var arrow = _create_arrow()
	var fire_direction = Vector2.RIGHT.rotated(rotation)
	
	# Velocity based on draw power
	var velocity = fire_direction * muzzle_velocity * draw_power
	arrow.linear_velocity = velocity
	
	# Reset string visual
	var string = get_node_or_null("String")
	if string:
		string.set_point_position(1, bow_string_anchor)
	
	current_ammo -= 1
	draw_released.emit(draw_power)
	ammo_changed.emit(current_ammo, magazine_size)
	
	# Apply recoil based on draw power
	apply_central_impulse(-fire_direction * 30.0 * draw_power)
	
	draw_power = 0.0

func _create_arrow() -> RigidBody2D:
	var arrow = RigidBody2D.new()
	arrow.position = global_position + Vector2(weapon_length * 0.5, 0).rotated(rotation)
	arrow.rotation = rotation
	
	# Arrow shape
	var shape = CapsuleShape2D.new()
	shape.radius = 1.0
	shape.height = 20.0
	var collision = CollisionShape2D.new()
	collision.shape = shape
	collision.rotation = PI/2
	arrow.add_child(collision)
	
	# Arrow visual
	var visual = Polygon2D.new()
	visual.polygon = PackedVector2Array([
		Vector2(-10, 0),
		Vector2(8, -1),
		Vector2(10, 0),
		Vector2(8, 1)
	])
	visual.color = Color(0.5, 0.3, 0.1)
	arrow.add_child(visual)
	
	# Fletching
	var fletching = Polygon2D.new()
	fletching.polygon = PackedVector2Array([
		Vector2(-10, -2),
		Vector2(-8, 0),
		Vector2(-10, 2),
		Vector2(-12, 0)
	])
	fletching.color = Color(0.8, 0.8, 0.8)
	arrow.add_child(fletching)
	
	# Physics
	arrow.mass = arrow_weight
	arrow.gravity_scale = 0.3
	arrow.collision_layer = 0b10000
	arrow.collision_mask = 0b0111
	
	# Damage based on kinetic energy
	arrow.set_meta("damage", base_damage_multiplier * draw_power * draw_power)
	arrow.set_meta("damage_type", "piercing")
	
	get_tree().root.add_child(arrow)
	
	return arrow
		
