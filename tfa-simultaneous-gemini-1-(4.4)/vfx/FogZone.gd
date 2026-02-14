class_name FogZone
extends ForceField

# Configuration
@export var fog_color: Color = Color(0.6, 0.7, 0.8, 0.6):
	set(value):
		fog_color = value
		_update_shader_uniforms()

@export var base_density: float = 1.0:
	set(value):
		base_density = value
		_update_shader_uniforms()

# Internal nodes
var _visual_rect: ColorRect
var _noise_texture: NoiseTexture2D

# Wind simulation
var _current_wind_vector: Vector2 = Vector2(0.05, 0.05) # Base drift
var _accumulated_wind_force: Vector2 = Vector2.ZERO

func _ready() -> void:
	super._ready() # Call ForceField _ready
	
	# Ensure we monitor areas to detect Wind Zones
	monitoring = true
	monitorable = false # Fog doesn't usually trigger other fog
	
	# Setup Visuals if created programmatically
	if not has_node("VisualRect"):
		_setup_visuals()
	else:
		_visual_rect = $VisualRect
		_update_shader_uniforms()

func _physics_process(delta: float) -> void:
	super._physics_process(delta) # Run ForceField logic
	_handle_wind_interaction(delta)

# Detect overlapping Wind Zones (ForceFields)
func _handle_wind_interaction(delta: float) -> void:
	var total_wind_push = Vector2.ZERO
	var max_wind_strength = 0.0
	
	# Check for other ForceFields (Wind Zones) interacting with this Fog
	var overlapping_areas = get_overlapping_areas()
	for area in overlapping_areas:
		if area is ForceField and area != self:
			# Check if it is a wind-type field
			if area.direction_type == ForceField.DirectionType.FIXED_DIRECTION:
				total_wind_push += area.fixed_direction * area.force_magnitude
				max_wind_strength = max(max_wind_strength, area.force_magnitude)

	# Smoothly interpolate current wind
	# If external wind exists, use it. Otherwise, return to base drift.
	var target_wind = total_wind_push * 0.001 # Scale down force for UV scrolling
	if target_wind == Vector2.ZERO:
		target_wind = Vector2(0.05, 0.0) # Default slow drift

	_current_wind_vector = _current_wind_vector.lerp(target_wind, delta * 2.0)
	
	# Calculate density loss based on wind strength
	# Stronger wind = thinner fog
	var density_reduction = clamp(max_wind_strength / 1000.0, 0.0, 0.8)
	var current_density = base_density * (1.0 - density_reduction)
	
	# Update Shader
	if _visual_rect and _visual_rect.material:
		_visual_rect.material.set_shader_parameter("wind_velocity", _current_wind_vector)
		_visual_rect.material.set_shader_parameter("density", current_density)

func _setup_visuals() -> void:
	# Create ColorRect
	_visual_rect = ColorRect.new()
	_visual_rect.name = "VisualRect"
	_visual_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	# Center the rect on the collision shape
	# Assuming a RectangleShape2D for simplicity in programmatic creation
	var col_shape = get_node_or_null("CollisionShape2D")
	if col_shape and col_shape.shape is RectangleShape2D:
		var size = col_shape.shape.size
		_visual_rect.size = size
		_visual_rect.position = -size / 2
	
	add_child(_visual_rect)
	
	# Create Material
	var shader = load("res://fog.gdshader") # Make sure path matches Step 1
	var mat = ShaderMaterial.new()
	mat.shader = shader
	
	# Create Noise Texture
	_noise_texture = NoiseTexture2D.new()
	_noise_texture.width = 256
	_noise_texture.height = 256
	_noise_texture.seamless = true
	_noise_texture.noise = FastNoiseLite.new()
	_noise_texture.noise.frequency = 0.02
	
	mat.set_shader_parameter("noise_texture", _noise_texture)
	_visual_rect.material = mat
	
	_update_shader_uniforms()

func _update_shader_uniforms() -> void:
	if _visual_rect and _visual_rect.material:
		_visual_rect.material.set_shader_parameter("fog_color", fog_color)
		_visual_rect.material.set_shader_parameter("density", base_density)

# Static factory method for programmatic creation
static func create_fog_zone(
	parent: Node,
	position: Vector2,
	size: Vector2,
	color: Color = Color(0.5, 0.5, 0.5, 0.8),
	density: float = 1.0,
	condition_name: String = ""
) -> FogZone:
	var fog = FogZone.new()
	fog.global_position = position
	fog.fog_color = color
	fog.base_density = density
	
	# Setup Physics/ForceField properties
	var collision = CollisionShape2D.new()
	var shape = RectangleShape2D.new()
	shape.size = size
	collision.shape = shape
	collision.name = "CollisionShape2D"
	fog.add_child(collision)
	
	# Setup Condition (using your ForceField logic)
	if condition_name != "":
		fog.conditions_to_apply.append(condition_name)
		fog.condition_apply_interval = 1.0
	
	parent.add_child(fog)
	
	# Force visual setup after adding to tree (so it can read shape size)
	fog._setup_visuals()
	
	return fog
