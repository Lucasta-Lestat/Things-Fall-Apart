# res://Fluid.gd
# Visual representation of a fluid tile using the water flow shader
extends Node2D

# Visual components
@onready var water_sprite: Sprite2D = $Sprite

# Grid position
var grid_position: Vector2i = Vector2i.ZERO

# Flow data
var current_flow_direction: Vector2 = Vector2.ZERO
var current_flow_speed: float = 0.0

# Depth
var water_depth: float = 1.0

func _ready():
	setup_shader_material()

func initialize(grid_pos: Vector2i, initial_depth: float):
	"""Initialize the fluid tile at a grid position"""
	grid_position = grid_pos
	water_depth = initial_depth
	position = GridManager.map_to_world(grid_pos)

	if water_sprite and not water_sprite.material:
		setup_shader_material()

	update_visuals()

func setup_shader_material():
	"""Ensure the water sprite has the flow shader and a white texture to color"""
	if not water_sprite:
		push_error("Fluid: Sprite node not found")
		return

	# Create a plain white texture for the shader to colorize
	if not water_sprite.texture:
		var img = Image.create(GridManager.TILE_SIZE, GridManager.TILE_SIZE, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		water_sprite.texture = ImageTexture.create_from_image(img)

	# Scale sprite to exactly one tile
	var tex_size = water_sprite.texture.get_size()
	if tex_size.x > 0 and tex_size.y > 0:
		water_sprite.scale = Vector2(
			float(GridManager.TILE_SIZE) / tex_size.x,
			float(GridManager.TILE_SIZE) / tex_size.y
		)

	# Load and apply the flow shader
	if not water_sprite.material or not water_sprite.material is ShaderMaterial:
		var shader_path = "res://vfx/shaders/water_flow.gdshader"
		if ResourceLoader.exists(shader_path):
			var shader_material = ShaderMaterial.new()
			shader_material.shader = load(shader_path)
			water_sprite.material = shader_material

	# Set default parameters
	if water_sprite.material is ShaderMaterial:
		water_sprite.material.set_shader_parameter("water_color", Color(0.0, 0.4, 0.8, 0.7))
		water_sprite.material.set_shader_parameter("wave_color", Color(0.0, 0.9, 1.0, 0.4))
		water_sprite.material.set_shader_parameter("flow_direction", Vector2.ZERO)
		water_sprite.material.set_shader_parameter("flow_speed", 0.1)

func set_fluid_colors(water_color: Color, wave_color: Color) -> void:
	"""Set fluid-type-specific colors (called by FluidManager after instantiation)."""
	if water_sprite and water_sprite.material is ShaderMaterial:
		water_sprite.material.set_shader_parameter("water_color", water_color)
		water_sprite.material.set_shader_parameter("wave_color", wave_color)

func set_edge_mask(mask: Vector4) -> void:
	"""Set which edges are exposed boundaries. vec4(right, left, bottom, top), 1.0 = exposed."""
	if water_sprite and water_sprite.material is ShaderMaterial:
		water_sprite.material.set_shader_parameter("edge_mask", mask)

func set_custom_shader(shader_path: String) -> void:
	"""Replace the shader with a custom one (e.g. oil sheen)."""
	if not water_sprite:
		return
	if ResourceLoader.exists(shader_path):
		var shader_material = ShaderMaterial.new()
		shader_material.shader = load(shader_path)
		water_sprite.material = shader_material

func update_visuals():
	"""Update the visual representation based on depth"""
	if not water_sprite:
		return
	var alpha = clamp(water_depth / 4.0, 0.3, 0.9)
	modulate.a = alpha

func set_flow_direction(flow_dir: Vector2, flow_speed: float):
	"""Called by FluidManager to update flow visualization"""
	current_flow_direction = flow_dir
	current_flow_speed = flow_speed

	if water_sprite and water_sprite.material is ShaderMaterial:
		water_sprite.material.set_shader_parameter("flow_direction", flow_dir)
		water_sprite.material.set_shader_parameter("flow_speed", flow_speed)

func set_water_depth(new_depth: float):
	"""Update water depth and visuals"""
	water_depth = new_depth
	update_visuals()

func get_flow_info() -> Dictionary:
	return {
		"direction": current_flow_direction,
		"speed": current_flow_speed,
		"depth": water_depth
	}
