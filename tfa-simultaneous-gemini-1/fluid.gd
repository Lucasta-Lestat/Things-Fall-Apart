# res://Fluid.gd
# script for a water tile that uses the flow shader
extends Node2D

# Configuration
@export var tile_size: int = 128
@export var water_depth: float = 10000.0
var debug_fluid = true

# Visual components - adjust these references to match your scene structure
@onready var water_sprite: Sprite2D = $Sprite 

# Grid position
var grid_position: Vector2i = Vector2i.ZERO

# Flow data
var current_flow_direction: Vector2 = Vector2.ZERO
var current_flow_speed: float = 0.0

func _ready():
	# Ensure we have a shader material
	setup_shader_material()

func initialize(grid_pos: Vector2i, initial_depth: float):
	"""Initialize the water tile at a grid position"""
	grid_position = grid_pos
	water_depth = initial_depth
	
	# Position in world
	position = GridManager.map_to_world(grid_pos)
	
	# Setup shader if not already done
	if water_sprite and not water_sprite.material:
		setup_shader_material()
	
	# Update visuals
	update_visuals()
	
	print("Initialized water tile at ", grid_pos, " (world: ", position, ") with depth ", initial_depth)

func setup_shader_material():
	"""Ensure the water sprite has the flow shader applied"""
	if not water_sprite:
		push_error("WaterSprite not found! Check your node references.")
		return
	
	# If no material exists, create one
	if not water_sprite.material:
		var shader_material = ShaderMaterial.new()
		var shader_path = "res://vfx/shaders/water_flow.gdshader"
		if ResourceLoader.exists(shader_path):
			var shader = load(shader_path)
			shader_material.shader = shader
			water_sprite.material = shader_material
			print("Loaded shader from ", shader_path)
		else:
			push_error("Shader not found at ", shader_path)
			return
	
	# Set initial shader parameters
	if water_sprite.material is ShaderMaterial:
		print("Setting up shader parameters for water tile")
		# You can set default colors and parameters here
		water_sprite.material.set_shader_parameter("water_color", Color(0.0, 0.4, 0.8, 0.7))
		water_sprite.material.set_shader_parameter("wave_color", Color(0.0, 0.9, 1.0, 0.4))
		water_sprite.material.set_shader_parameter("flow_direction", Vector2.ONE)
		water_sprite.material.set_shader_parameter("flow_speed", 0.1)
		print("Shader parameters initialized")

func update_visuals():
	"""Update the visual representation based on water depth"""
	if not water_sprite:
		print("no water sprite")
		return
	
	# Adjust opacity based on depth
	var alpha = clamp(water_depth / 4.0, 0.3, 0.9)
	modulate.a = alpha
	
	# Scale sprite to fill tile
	water_sprite.scale = Vector2.ONE * (tile_size / GridManager.TILE_SIZE)  # Assuming 128px base size
	
	queue_redraw()  # Trigger _draw() for debug visualization

func set_flow_direction(flow_dir: Vector2, flow_speed: float):
	"""Called by GridManager to update flow visualization"""
	current_flow_direction = flow_dir
	current_flow_speed = flow_speed
	
	#print("Setting flow for tile at ", grid_position, ": direction=", flow_dir, " speed=", flow_speed)
	
	# Update shader parameters
	if water_sprite and water_sprite.material is ShaderMaterial:
		water_sprite.material.set_shader_parameter("flow_direction", flow_dir)
		water_sprite.material.set_shader_parameter("flow_speed", flow_speed)
		#print("Shader parameters updated successfully")
	else:
		push_error("Cannot update shader - material is not ShaderMaterial")
	
	queue_redraw()  # Trigger _draw() for debug visualization

func set_water_depth(new_depth: float):
	"""Update water depth and visuals"""
	water_depth = new_depth
	update_visuals()

func get_flow_info() -> Dictionary:
	"""Get current flow information"""
	return {
		"direction": current_flow_direction,
		"speed": current_flow_speed,
		"depth": water_depth
	}

# Optional: Debug visualization
func _draw():
	if not debug_fluid:
		return
		
	# Draw flow direction arrow for debugging
	if current_flow_speed > 0.01:
		#print("current_flow_speed sufficient for debug arrow")
		var arrow_length = 40.0 * current_flow_speed
		var arrow_end = current_flow_direction * arrow_length
		draw_line(Vector2.ZERO, arrow_end, Color.RED, 3.0)
		
		# Arrow head
		var arrow_size = 10.0
		var perp = Vector2(-current_flow_direction.y, current_flow_direction.x)
		draw_line(arrow_end, arrow_end - current_flow_direction * arrow_size + perp * arrow_size * 0.5, Color.RED, 3.0)
		draw_line(arrow_end, arrow_end - current_flow_direction * arrow_size - perp * arrow_size * 0.5, Color.RED, 3.0)
		
		# Draw a circle at the center
		draw_circle(Vector2.ZERO, 5.0, Color.YELLOW)
