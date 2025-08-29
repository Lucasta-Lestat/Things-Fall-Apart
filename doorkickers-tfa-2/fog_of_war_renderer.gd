# FogOfWarRenderer.gd - Visual fog of war rendering
extends CanvasLayer
class_name FogOfWarRenderer

var fog_material: ShaderMaterial
var fog_quad: ColorRect
var visibility_texture: ImageTexture
var visibility_image: Image

# Fog colors
var fog_color: Color = Color(0, 0, 0, 0.9)  # Almost black
var partially_visible_color: Color = Color(0, 0, 0, 0.6)  # Semi-transparent
var visible_color: Color = Color(0, 0, 0, 0)  # Fully transparent

var map_size: Vector2i = Vector2i(100, 100)
var tile_size: int = 32

func _ready():
	setup_fog_rendering()
	FogOfWarManager.visibility_updated.connect(_on_visibility_updated)

func setup_fog_rendering():
	# Create fog shader material
	var fog_shader = preload("res://shaders/fog_of_war.gdshader")
	fog_material = ShaderMaterial.new()
	fog_material.shader = fog_shader
	
	# Create visibility texture
	visibility_image = Image.create(map_size.x, map_size.y, false, Image.FORMAT_RGBA8)
	visibility_image.fill(fog_color)  # Start with full fog
	visibility_texture = ImageTexture.new()
	visibility_texture.set_image(visibility_image)
	
	# Create full-screen quad
	fog_quad = ColorRect.new()
	fog_quad.material = fog_material
	fog_quad.color = Color.WHITE  # Shader will handle coloring
	fog_quad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(fog_quad)
	
	# Set shader parameters
	fog_material.set_shader_parameter("visibility_texture", visibility_texture)
	fog_material.set_shader_parameter("tile_size", tile_size)

func _on_visibility_updated(visible_tiles: Dictionary, partially_visible_tiles: Dictionary):
	update_visibility_texture(visible_tiles, partially_visible_tiles)

func update_visibility_texture(visible_tiles: Dictionary, partially_visible_tiles: Dictionary):
	# Clear to fog
	visibility_image.fill(fog_color)
	
	# Set visible tiles
	for tile_pos in visible_tiles:
		if tile_pos.x >= 0 and tile_pos.x < map_size.x and tile_pos.y >= 0 and tile_pos.y < map_size.y:
			visibility_image.set_pixelv(tile_pos, visible_color)
	
	# Set partially visible tiles
	for tile_pos in partially_visible_tiles:
		if tile_pos.x >= 0 and tile_pos.x < map_size.x and tile_pos.y >= 0 and tile_pos.y < map_size.y:
			var visibility = partially_visible_tiles[tile_pos]
			var alpha = lerp(fog_color.a, visible_color.a, visibility)
			var color = Color(0, 0, 0, alpha)
			visibility_image.set_pixelv(tile_pos, color)
	
	# Update texture
	visibility_texture.update(visibility_image)

func _process(delta):
	# Update fog quad size and position to match viewport
	var viewport = get_viewport()
	fog_quad.size = viewport.get_visible_rect().size
	fog_quad.position = Vector2.ZERO

# ===================================================================
