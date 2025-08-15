
# RangedWeapon.gd
extends PhysicsWeapon
class_name RangedWeapon

@export var projectile_scene: PackedScene
@export var muzzle_velocity: float = 500.0
@export var fire_rate: float = 2.0  # Shots per second
@export var magazine_size: int = 30
@export var reload_time: float = 2.0
@export var spread_angle: float = 5.0  # Degrees

var current_ammo: int = 30
var last_shot_time: float = 0.0
var is_reloading: bool = false

signal shot_fired(projectile)
signal reload_started()
signal reload_completed()
signal ammo_changed(current, max)

func _ready():
	super._ready()
	current_ammo = magazine_size

func fire(shooter_strength: float = 100.0) -> bool:
	var current_time = Time.get_ticks_msec() / 1000.0
	
	if is_reloading:
		return false
	
	if current_ammo <= 0:
		start_reload()
		return false
	
	if current_time - last_shot_time < (1.0 / fire_rate):
		return false
	
	last_shot_time = current_time
	current_ammo -= 1
	
	# Create projectile
	var projectile = _create_projectile()
	
	# Apply muzzle velocity with spread
	var spread = randf_range(-spread_angle, spread_angle)
	var fire_direction = Vector2.RIGHT.rotated(rotation + deg_to_rad(spread))
	projectile.linear_velocity = fire_direction * muzzle_velocity
	
	# Add shooter's velocity
	if get_parent() is RigidBody2D:
		projectile.linear_velocity += get_parent().linear_velocity
	
	shot_fired.emit(projectile)
	ammo_changed.emit(current_ammo, magazine_size)
	
	# Recoil
	apply_central_impulse(-fire_direction * 50.0)
	
	return true

func _create_projectile() -> RigidBody2D:
	var projectile = RigidBody2D.new()
	projectile.position = global_position + Vector2(weapon_length, 0).rotated(rotation)
	projectile.rotation = rotation
	
	# Add collision shape
	var shape = CircleShape2D.new()
	shape.radius = 2.0
	var collision = CollisionShape2D.new()
	collision.shape = shape
	projectile.add_child(collision)
	
	# Visual
	var visual = Polygon2D.new()
	visual.polygon = PackedVector2Array([
		Vector2(-3, -1),
		Vector2(3, 0),
		Vector2(-3, 1)
	])
	visual.color = Color(0.8, 0.7, 0.3)
	projectile.add_child(visual)
	
	# Physics settings
	projectile.mass = 0.01
	projectile.gravity_scale = 0.1
	projectile.collision_layer = 0b10000  # Projectile layer
	projectile.collision_mask = 0b0111  # Hit walls, cover, characters
	
	get_tree().root.add_child(projectile)
	
	return projectile

func start_reload():
	if is_reloading or current_ammo == magazine_size:
		return
	
	is_reloading = true
	reload_started.emit()
	
	# Create reload timer
	var timer = Timer.new()
	timer.wait_time = reload_time
	timer.one_shot = true
	timer.timeout.connect(_on_reload_complete)
	add_child(timer)
	timer.start()

func _on_reload_complete():
	current_ammo = magazine_size
	is_reloading = false
	reload_completed.emit()
	ammo_changed.emit(current_ammo, magazine_size)
