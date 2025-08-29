#  weapon with better sound integration

extends RigidBody2D
class_name Weapon

signal weapon_impact(target, damage, impact_force)
signal weapon_blocked(target, remaining_force)

@export var weapon_name: String = "Weapon"
@export var base_damage: float = 20.0
@export var damage_type: PhysicsManager.DamageType = PhysicsManager.DamageType.SLASHING
@export var weapon_length: float = 48.0
@export var weapon_width: float = 8.0
@export var grip_length: float = 12.0

# Physics properties
@export var penetration_power: float = 50.0  # How well it cuts through resistance
@export var impact_threshold: float = 10.0   # Minimum velocity for damage
@export var bounce_factor: float = 0.3       # How much it bounces off hard targets

# Weapon type specific
@export var projectile_speed: float = 400.0  # For ranged weapons
@export var max_draw_distance: float = 15.0  # For bows

var wielder: Character = null
var is_being_swung: bool = false
var swing_start_time: float = 0.0
var last_collision_time: float = 0.0
var embedded_targets: Array[RigidBody2D] = []

# Visual components
var weapon_sprite: Node2D
var trail_points: Array[Vector2] = []
var max_trail_points: int = 20

func _ready():
	setup_weapon_visual()
	setup_physics_properties()
	connect_signals()

func setup_weapon_visual():
	weapon_sprite = Node2D.new()
	weapon_sprite.name = "WeaponSprite"
	add_child(weapon_sprite)

func setup_physics_properties():
	# Set collision layer for weapons
	collision_layer = 4  # Weapon layer
	collision_mask = 1 + 2  # Characters + Objects
	
	# Enable contact monitoring for detailed collision info
	contact_monitor = true
	max_contacts_reported = 10
	
	# Connect collision signals
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

func connect_signals():
	# Connect to physics manager for enhanced collision handling
	pass

func _draw():
	draw_weapon()
	draw_motion_trail()

func draw_weapon():
	match damage_type:
		PhysicsManager.DamageType.SLASHING:
			draw_sword()
		PhysicsManager.DamageType.PIERCING:
			draw_spear()
		PhysicsManager.DamageType.BLUDGEONING:
			draw_mace()

func draw_sword():
	# Blade
	var blade_length = weapon_length - grip_length
	var blade_rect = Rect2(-weapon_width/2, -blade_length, weapon_width, blade_length)
	draw_rect(blade_rect, Color.SILVER)
	draw_rect(blade_rect, Color.GRAY, false, 1.0)
	
	# Edge highlight
	draw_line(Vector2(0, -blade_length), Vector2(0, 0), Color.WHITE, 1.0)
	
	# Crossguard
	draw_rect(Rect2(-weapon_width, -2, weapon_width * 2, 4), Color.DARK_GRAY)
	
	# Grip
	draw_rect(Rect2(-weapon_width/3, 0, weapon_width * 2/3, grip_length), Color.SADDLE_BROWN)

func draw_spear():
	# Shaft
	draw_rect(Rect2(-weapon_width/4, 0, weapon_width/2, weapon_length - 8), Color.SADDLE_BROWN)
	
	# Spear tip
	var tip_points = PackedVector2Array([
		Vector2(0, -8),
		Vector2(-weapon_width/2, -4),
		Vector2(weapon_width/2, -4),
		Vector2(0, -8)
	])
	draw_colored_polygon(tip_points, Color.SILVER)
	draw_polyline(tip_points, Color.BLACK, 1.0)

func draw_mace():
	# Handle
	draw_rect(Rect2(-weapon_width/3, 0, weapon_width * 2/3, weapon_length * 0.7), Color.SADDLE_BROWN)
	
	# Mace head
	draw_circle(Vector2(0, -weapon_length * 0.8), weapon_width, Color.GRAY)
	draw_circle(Vector2(0, -weapon_length * 0.8), weapon_width, Color.BLACK, false, 1.0)
	
	# Spikes
	for i in range(6):
		var angle = i * PI / 3
		var spike_start = Vector2(cos(angle), sin(angle)) * weapon_width * 0.7
		var spike_end = Vector2(cos(angle), sin(angle)) * weapon_width * 1.2
		spike_start += Vector2(0, -weapon_length * 0.8)
		spike_end += Vector2(0, -weapon_length * 0.8)
		draw_line(spike_start, spike_end, Color.SILVER, 2.0)

func draw_motion_trail():
	if trail_points.size() < 2 or not is_being_swung:
		return
	
	for i in range(trail_points.size() - 1):
		var alpha = float(i) / float(trail_points.size())
		var color = Color.YELLOW
		color.a = alpha * 0.5
		var width = lerp(1.0, 3.0, alpha)
		draw_line(trail_points[i], trail_points[i + 1], color, width)

func _physics_process(delta):
	update_motion_trail()
	
	# Apply resistance from embedded targets
	if not embedded_targets.is_empty():
		apply_embed_resistance(delta)

func update_motion_trail():
	if linear_velocity.length() > 50.0:  # Only trail when moving fast
		trail_points.append(global_position)
		
		if trail_points.size() > max_trail_points:
			trail_points.pop_front()
	else:
		trail_points.clear()
	
	queue_redraw()

func start_swing(swing_force: Vector2):
	is_being_swung = true
	swing_start_time = Time.get_time_dict_from_system()["second"] + Time.get_time_dict_from_system()["minute"] * 60
	
	# Apply swing impulse
	apply_central_impulse(swing_force)
	
	# Add angular velocity for spinning weapons
	angular_velocity += swing_force.length() * 0.01
	HearingManager.create_weapon_sound(self, HearingManager.SoundType.WEAPON_SWING)
	

func stop_swing():
	is_being_swung = false
	trail_points.clear()
	queue_redraw()

func _on_body_entered(body: Node):
	if body == wielder or body in embedded_targets:
		return
	
	var collision_velocity = linear_velocity.length()
	if collision_velocity < impact_threshold:
		return
	
	handle_weapon_collision(body, collision_velocity)

func _on_body_exited(body: Node):
	if body in embedded_targets:
		embedded_targets.erase(body)

func handle_weapon_collision(target: RigidBody2D, impact_velocity: float):
	# Prevent multiple rapid collisions with the same target
	var current_time = Time.get_time_dict_from_system()["second"] + Time.get_time_dict_from_system()["minute"] * 60
	if current_time - last_collision_time < 0.1:
		return
	last_collision_time = current_time
	
	# Get target's damage resistance
	var damage_resistance = get_target_damage_resistance(target)
	
	# Calculate penetration vs resistance
	var effective_penetration = penetration_power * impact_velocity / 100.0
	var resistance_factor = damage_resistance / effective_penetration
	
	# Determine collision outcome
	if resistance_factor < 0.5:
		# Weapon penetrates deeply
		handle_penetration(target, impact_velocity, resistance_factor)
	elif resistance_factor < 1.0:
		# Weapon cuts/damages but slows significantly
		handle_partial_penetration(target, impact_velocity, resistance_factor)
	else:
		# Weapon bounces off or embeds shallowly
		handle_bounce(target, impact_velocity, resistance_factor)

func handle_penetration(target: RigidBody2D, velocity: float, resistance: float):
	# Deal full damage
	var damage = calculate_impact_damage(velocity)
	apply_damage_to_target(target, damage)
	
	# Slight slowdown but weapon continues through
	var velocity_retention = 1.0 - resistance * 0.3
	linear_velocity *= velocity_retention
	
	weapon_impact.emit(target, damage, velocity)

func handle_partial_penetration(target: RigidBody2D, velocity: float, resistance: float):
	# Moderate damage
	var damage = calculate_impact_damage(velocity) * 0.7
	apply_damage_to_target(target, damage)
	
	# Significant slowdown and potential embedding
	var damping_factor = resistance * 2.0
	apply_embed_damping(target, damping_factor)
	
	# Add to embedded targets for continued resistance
	if target not in embedded_targets:
		embedded_targets.append(target)
	
	weapon_impact.emit(target, damage, velocity * 0.5)

func handle_bounce(target: RigidBody2D, velocity: float, resistance: float):
	# Minimal damage
	var damage = calculate_impact_damage(velocity) * 0.3
	apply_damage_to_target(target, damage)
	
	# Bounce off with reduced velocity
	var bounce_direction = (global_position - target.global_position).normalized()
	var bounce_velocity = velocity * bounce_factor
	
	# Clear existing velocity and apply bounce
	linear_velocity = bounce_direction * bounce_velocity
	
	# Add some angular velocity for realistic spinning
	angular_velocity += randf_range(-5.0, 5.0)
	
	weapon_blocked.emit(target, velocity * bounce_factor)

func apply_embed_damping(target: RigidBody2D, damping_factor: float):
	# Apply damping force proportional to velocity and resistance
	var damping_force = -linear_velocity * damping_factor * mass
	apply_central_force(damping_force)
	
	# Also reduce angular velocity
	angular_velocity *= 0.7

func apply_embed_resistance(delta: float):
	var total_resistance = 0.0
	
	for target in embedded_targets:
		if is_instance_valid(target):
			var resistance = get_target_damage_resistance(target)
			total_resistance += resistance
	
	# Apply continuous damping while embedded
	if total_resistance > 0:
		var damping = total_resistance * 0.1
		linear_velocity = linear_velocity.move_toward(Vector2.ZERO, damping * delta)
		angular_velocity = move_toward(angular_velocity, 0.0, damping * delta)

func get_target_damage_resistance(target: RigidBody2D) -> float:
	# Get damage resistance from target
	if target.has_method("get_damage_resistance"):
		return target.get_damage_resistance(damage_type)
	elif target is BodyPart:
		return target.armor_value + 5.0  # Base body resistance
	else:
		return 10.0  # Default resistance for objects

func calculate_impact_damage(velocity: float) -> float:
	# Damage based on kinetic energy and weapon properties
	var kinetic_energy = 0.5 * mass * velocity * velocity
	return (kinetic_energy / 100.0) * base_damage

func apply_damage_to_target(target: RigidBody2D, damage: float):
	if target.has_method("take_damage"):
		target.take_damage(damage, damage_type)

func get_damage_value() -> float:
	var swing_modifier = 1.5 if is_being_swung else 1.0
	return base_damage * swing_modifier

func get_damage_type() -> PhysicsManager.DamageType:
	return damage_type
