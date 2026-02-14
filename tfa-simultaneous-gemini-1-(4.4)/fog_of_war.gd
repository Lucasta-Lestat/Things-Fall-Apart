# FogOfWar.gd
extends ColorRect

@onready var visibility_manager = VisibilityManager  # Your autoload

var visibility_texture: ImageTexture
var visibility_image: Image
var grid_size: Vector2i = Vector2i(100, 100)  # Adjust to your map size
var tile_size = GridManager.TILE_SIZE  # Size of each tile in pixels

func _ready():
	# Setup the ColorRect to cover the entire viewport
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # Don't block mouse input
	
	# Create the visibility texture
	visibility_image = Image.create(grid_size.x, grid_size.y, false, Image.FORMAT_RF)
	visibility_image.fill(Color(0, 0, 0, 1))  # Start fully dark
	visibility_texture = ImageTexture.create_from_image(visibility_image)
	
	# Setup shader material
	material = ShaderMaterial.new()
	material.shader = load("res://vfx/shaders/fog_of_war.gdshader")
	material.set_shader_parameter("visibility_texture", visibility_texture)
	material.set_shader_parameter("grid_size", Vector2(grid_size))
	material.set_shader_parameter("tile_size", Vector2(tile_size, tile_size))
	
	# Connect to visibility updates
	visibility_manager.visibility_changed.connect(_on_visibility_changed)

func _process(_delta):
	visibility_manager.update_visibility()

func _on_visibility_changed(visible_tiles: Dictionary):
	# Clear the image (set everything to dark)
	visibility_image.fill(Color(0, 0, 0, 1))
	
	# Update each visible tile
	for tile_pos in visible_tiles:
		print("tile_pos in visibile tiles: ", tile_pos)
		var visibility_level = visible_tiles[tile_pos]
		print("visibility_level: ", visibility_level)
		# Ensure tile is within bounds
		if tile_pos.x >= 0 and tile_pos.x < grid_size.x and \
		   tile_pos.y >= 0 and tile_pos.y < grid_size.y:
			# Set the pixel color based on visibility (0.0 = dark, 1.0 = fully visible)
			visibility_image.set_pixel(tile_pos.x, tile_pos.y, Color(visibility_level, 0, 0, 1))
	
	# Update the texture
	visibility_texture.update(visibility_image)

func set_grid_size(new_size: Vector2i):
	grid_size = new_size
	visibility_image = Image.create(grid_size.x, grid_size.y, false, Image.FORMAT_RF)
	visibility_texture = ImageTexture.create_from_image(visibility_image)
	material.set_shader_parameter("visibility_texture", visibility_texture)
	material.set_shader_parameter("grid_size", Vector2(grid_size))
