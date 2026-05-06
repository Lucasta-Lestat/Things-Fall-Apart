# res://Fluid.gd
# Visual representation of a fluid tile using the water flow shader
extends Node2D

# Visual components
@onready var water_sprite: Sprite2D = $Sprite

# Grid position
var grid_position: Vector2i = Vector2i.ZERO

# Flow data — current is what the shader sees this frame; target is what the
# fluid sim last reported. Sim updates every SIM_INTERVAL; we lerp the
# shader-facing values toward the target each frame so flow direction, speed,
# fill ratio, and inflow direction all transition continuously instead of
# snapping every sim tick.
var current_flow_direction: Vector2 = Vector2.ZERO
var current_flow_speed: float = 0.0
var target_flow_direction: Vector2 = Vector2.ZERO
var target_flow_speed: float = 0.0

# Fill mask state (1.0 = full, < 1.0 = partially filled).
var current_fill_ratio: float = 1.0
var target_fill_ratio: float = 1.0

# Inflow direction = velocity of fluid as it enters this tile. Drives the
# directional fill front in the shader.
var current_inflow_direction: Vector2 = Vector2.ZERO
var target_inflow_direction: Vector2 = Vector2.ZERO

# Exponential lerp rates. Higher = snappier convergence.
const FLOW_LERP_RATE: float = 3.0    # was 1.5 (when sim ran every 2s); sim is now 0.5s
const FILL_LERP_RATE: float = 4.0    # snappier so fill-in animation tracks the sim
const INFLOW_LERP_RATE: float = 3.0

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

	# Pass grid position so shaders can compute world-continuous effects
	if water_sprite and water_sprite.material is ShaderMaterial:
		water_sprite.material.set_shader_parameter("tile_position", Vector2(grid_pos.x, grid_pos.y))

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

func set_corner_mask(mask: Vector4) -> void:
	"""Set which inside corners need rounding. vec4(top-right, top-left, bottom-left, bottom-right)."""
	if water_sprite and water_sprite.material is ShaderMaterial:
		water_sprite.material.set_shader_parameter("corner_mask", mask)

func set_custom_shader(shader_path: String) -> void:
	"""Replace the shader with a custom one (e.g. oil sheen)."""
	if not water_sprite:
		return
	if ResourceLoader.exists(shader_path):
		var shader_material = ShaderMaterial.new()
		shader_material.shader = load(shader_path)
		water_sprite.material = shader_material
		# Re-apply tile position for world-space continuity
		shader_material.set_shader_parameter("tile_position", Vector2(grid_position.x, grid_position.y))

func update_visuals():
	# Alpha lives in the shader (water_color.a * edge_alpha) so all tiles of the
	# same fluid type render consistently. Per-tile depth-based modulate.a was
	# stamping visible rectangles around tiles whose amount diverged from neighbors'.
	if not water_sprite:
		return
	modulate.a = 1.0

func _process(delta: float) -> void:
	var flow_changed = not current_flow_direction.is_equal_approx(target_flow_direction) \
			or not is_equal_approx(current_flow_speed, target_flow_speed)
	var fill_changed = not is_equal_approx(current_fill_ratio, target_fill_ratio)
	var inflow_changed = not current_inflow_direction.is_equal_approx(target_inflow_direction)
	# Skip the per-frame work entirely when this tile is fully settled.
	if not (flow_changed or fill_changed or inflow_changed):
		return
	if flow_changed:
		var t_flow = 1.0 - exp(-FLOW_LERP_RATE * delta)
		current_flow_direction = current_flow_direction.lerp(target_flow_direction, t_flow)
		current_flow_speed = lerp(current_flow_speed, target_flow_speed, t_flow)
	if fill_changed:
		var t_fill = 1.0 - exp(-FILL_LERP_RATE * delta)
		current_fill_ratio = lerp(current_fill_ratio, target_fill_ratio, t_fill)
	if inflow_changed:
		var t_in = 1.0 - exp(-INFLOW_LERP_RATE * delta)
		current_inflow_direction = current_inflow_direction.lerp(target_inflow_direction, t_in)
	if water_sprite and water_sprite.material is ShaderMaterial:
		var mat = water_sprite.material
		if flow_changed:
			mat.set_shader_parameter("flow_direction", current_flow_direction)
			mat.set_shader_parameter("flow_speed", current_flow_speed)
		if fill_changed:
			mat.set_shader_parameter("fill_ratio", current_fill_ratio)
		if inflow_changed:
			mat.set_shader_parameter("inflow_direction", current_inflow_direction)

func set_flow_direction(flow_dir: Vector2, flow_speed: float):
	"""Called by FluidManager to update flow visualization. Lerped toward via _process."""
	target_flow_direction = flow_dir
	target_flow_speed = flow_speed

func set_fill_ratio(ratio: float) -> void:
	"""Called by FluidManager. 1.0 = visually full; < 1.0 = partial fill mask in shader."""
	target_fill_ratio = clamp(ratio, 0.0, 1.0)

func set_inflow_direction(direction: Vector2) -> void:
	"""Called by FluidManager. Direction fluid moves AS IT ENTERS this tile."""
	target_inflow_direction = direction

func snap_fill_state(ratio: float, inflow: Vector2) -> void:
	"""Used at tile creation to set the initial fill state without a fade-in
	animation from the default values (which would otherwise show a brief
	full-tile flash before the lerp catches up)."""
	var clamped = clamp(ratio, 0.0, 1.0)
	target_fill_ratio = clamped
	current_fill_ratio = clamped
	target_inflow_direction = inflow
	current_inflow_direction = inflow
	if water_sprite and water_sprite.material is ShaderMaterial:
		water_sprite.material.set_shader_parameter("fill_ratio", clamped)
		water_sprite.material.set_shader_parameter("inflow_direction", inflow)

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
