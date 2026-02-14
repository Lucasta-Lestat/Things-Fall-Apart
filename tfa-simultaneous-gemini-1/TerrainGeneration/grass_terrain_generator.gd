class_name GrassTerrainGenerator
extends Node2D
## Main terrain generator that creates procedural grass with tonal variation,
## wildflowers, and ragged edges

signal generation_complete
signal map_saved(path: String)
signal map_loaded(path: String)

# Terrain types
enum TerrainType { GRASS, PATH, ROCK, WATER }

# Export parameters for easy tuning in editor
@export_group("Map Settings")
@export var map_width: int = 512
@export var map_height: int = 512
@export var tile_size: int = 1

@export_group("Grass Colors")
@export var grass_dark: Color = Color(0.216, 0.467, 0.196)
@export var grass_mid: Color = Color(0.318, 0.569, 0.259)
@export var grass_light: Color = Color(0.447, 0.651, 0.318)
@export var grass_highlight: Color = Color(0.529, 0.722, 0.376)

@export_group("Other Terrain Colors")
@export var path_color: Color = Color(0.722, 0.627, 0.471)
@export var rock_color: Color = Color(0.502, 0.486, 0.459)
@export var water_color: Color = Color(0.259, 0.522, 0.604)

@export_group("Wildflower Settings")
@export var flower_threshold: float = 0.88
@export var flower_density: float = 1.0
@export var flower_colors: Array[Color] = [
	Color.WHITE,
	Color(1.0, 0.95, 0.8),  # Cream
	Color(1.0, 0.85, 0.9),  # Light pink
	Color(0.9, 0.9, 1.0),   # Light blue
	Color(1.0, 1.0, 0.7),   # Light yellow
]

@export_group("Edge Settings")
@export var edge_raggedness: float = 12.0
@export var edge_blend_width: float = 8.0

@export_group("Noise Settings")
@export var noise_seed: int = 12345
@export var base_noise_weight: float = 0.55
@export var detail_noise_weight: float = 0.45

# Internal state
var noise_gen: GrassNoiseGenerator
var terrain_mask: Image  # Stores terrain type per pixel
var rendered_image: Image  # Final rendered result
var texture: ImageTexture
var sprite: Sprite2D

# For painting
var is_painting: bool = false
var paint_terrain: TerrainType = TerrainType.GRASS
var brush_size: int = 20

func _ready():
	noise_gen = GrassNoiseGenerator.new(noise_seed)
	_initialize_images()
	_create_sprite()

func _initialize_images():
	# Create terrain mask (R channel = terrain type)
	terrain_mask = Image.create(map_width, map_height, false, Image.FORMAT_R8)
	terrain_mask.fill(Color(0, 0, 0))  # Default to grass (type 0)
	
	# Create rendered image
	rendered_image = Image.create(map_width, map_height, false, Image.FORMAT_RGBA8)

func _create_sprite():
	sprite = Sprite2D.new()
	sprite.centered = false
	add_child(sprite)
	texture = ImageTexture.new()

func set_noise_seed(new_seed: int):
	noise_seed = new_seed
	noise_gen.set_seed(new_seed)

## Generate the full terrain
func generate_terrain():
	var start_time = Time.get_ticks_msec()
	
	for y in range(map_height):
		for x in range(map_width):
			var terrain_type = _get_terrain_type(x, y)
			var pixel_color = _calculate_pixel_color(x, y, terrain_type)
			rendered_image.set_pixel(x, y, pixel_color)
	
	_update_texture()
	
	var elapsed = Time.get_ticks_msec() - start_time
	print("Terrain generated in %d ms" % elapsed)
	generation_complete.emit()

## Generate terrain in chunks (for large maps, call over multiple frames)
func generate_terrain_async(chunk_size: int = 64) -> void:
	var chunks_x = ceili(float(map_width) / chunk_size)
	var chunks_y = ceili(float(map_height) / chunk_size)
	
	for cy in range(chunks_y):
		for cx in range(chunks_x):
			_generate_chunk(cx * chunk_size, cy * chunk_size, chunk_size)
			await get_tree().process_frame
	
	_update_texture()
	generation_complete.emit()

func _generate_chunk(start_x: int, start_y: int, size: int):
	var end_x = mini(start_x + size, map_width)
	var end_y = mini(start_y + size, map_height)
	
	for y in range(start_y, end_y):
		for x in range(start_x, end_x):
			var terrain_type = _get_terrain_type(x, y)
			var pixel_color = _calculate_pixel_color(x, y, terrain_type)
			rendered_image.set_pixel(x, y, pixel_color)

func _get_terrain_type(x: int, y: int) -> TerrainType:
	var mask_value = terrain_mask.get_pixel(x, y).r
	return int(mask_value * 255.0) as TerrainType

func _calculate_pixel_color(x: int, y: int, terrain_type: TerrainType) -> Color:
	match terrain_type:
		TerrainType.GRASS:
			return _calculate_grass_color(x, y)
		TerrainType.PATH:
			return _calculate_path_color(x, y)
		TerrainType.ROCK:
			return _calculate_rock_color(x, y)
		TerrainType.WATER:
			return _calculate_water_color(x, y)
	return grass_mid

func _calculate_grass_color(x: int, y: int) -> Color:
	# Check for edge blending with other terrain
	var edge_factor = _calculate_edge_factor(x, y)
	
	if edge_factor < 0.0:
		# This pixel should be the neighboring terrain type
		return _get_neighbor_terrain_color(x, y)
	
	# Get tonal variation from noise
	var tone = noise_gen.get_grass_tone(x, y, base_noise_weight, detail_noise_weight)
	
	# Map tone to color gradient
	var base_color: Color
	if tone < 0.33:
		base_color = grass_dark.lerp(grass_mid, tone / 0.33)
	elif tone < 0.66:
		base_color = grass_mid.lerp(grass_light, (tone - 0.33) / 0.33)
	else:
		base_color = grass_light.lerp(grass_highlight, (tone - 0.66) / 0.34)
	
	# Check for wildflower placement
	if noise_gen.should_place_flower(x, y, flower_threshold, flower_density):
		# Only place flowers in lighter grass areas for visibility
		if tone > 0.35:
			var flower_color = _get_random_flower_color(x, y)
			return flower_color
	
	# Apply edge blending if near boundary
	if edge_factor < 1.0:
		var neighbor_color = _get_neighbor_terrain_color(x, y)
		base_color = base_color.lerp(neighbor_color, 1.0 - edge_factor)
	
	return base_color

func _calculate_edge_factor(x: int, y: int) -> float:
	# Check distance to nearest non-grass terrain
	var min_dist = edge_blend_width + edge_raggedness
	var nearest_terrain = TerrainType.GRASS
	
	var check_radius = int(edge_blend_width + edge_raggedness)
	for dy in range(-check_radius, check_radius + 1):
		for dx in range(-check_radius, check_radius + 1):
			var nx = x + dx
			var ny = y + dy
			if nx < 0 or nx >= map_width or ny < 0 or ny >= map_height:
				continue
			
			var neighbor_type = _get_terrain_type(nx, ny)
			if neighbor_type != TerrainType.GRASS:
				var dist = sqrt(dx * dx + dy * dy)
				if dist < min_dist:
					min_dist = dist
					nearest_terrain = neighbor_type
	
	if min_dist >= edge_blend_width + edge_raggedness:
		return 1.0  # Fully grass
	
	# Apply noise-based raggedness to the edge
	var noise_offset = noise_gen.get_edge_displacement(x, y, edge_raggedness)
	var adjusted_dist = min_dist + noise_offset
	
	if adjusted_dist <= 0:
		return -1.0  # Should be other terrain
	elif adjusted_dist >= edge_blend_width:
		return 1.0  # Fully grass
	else:
		return adjusted_dist / edge_blend_width  # Blend zone

func _get_neighbor_terrain_color(x: int, y: int) -> Color:
	# Find the nearest non-grass terrain and return its color
	var check_radius = int(edge_blend_width + edge_raggedness) + 2
	for dy in range(-check_radius, check_radius + 1):
		for dx in range(-check_radius, check_radius + 1):
			var nx = x + dx
			var ny = y + dy
			if nx < 0 or nx >= map_width or ny < 0 or ny >= map_height:
				continue
			
			var neighbor_type = _get_terrain_type(nx, ny)
			if neighbor_type != TerrainType.GRASS:
				match neighbor_type:
					TerrainType.PATH:
						return _calculate_path_color(x, y)
					TerrainType.ROCK:
						return _calculate_rock_color(x, y)
					TerrainType.WATER:
						return _calculate_water_color(x, y)
	
	return path_color

func _calculate_path_color(x: int, y: int) -> Color:
	# Add subtle variation to path
	var variation = noise_gen.get_grass_tone(x, y, 0.7, 0.3)
	return path_color.darkened(0.1 - variation * 0.2)

func _calculate_rock_color(x: int, y: int) -> Color:
	var variation = noise_gen.get_grass_tone(x * 2, y * 2, 0.6, 0.4)
	return rock_color.darkened(0.15 - variation * 0.3)

func _calculate_water_color(x: int, y: int) -> Color:
	var variation = noise_gen.get_grass_tone(x, y, 0.5, 0.5)
	return water_color.lightened(variation * 0.15)

func _get_random_flower_color(x: int, y: int) -> Color:
	if flower_colors.is_empty():
		return Color.WHITE
	
	# Use position-based hash for consistent random color
	var hash_val = fposmod(sin(x * 12.9898 + y * 78.233) * 43758.5453, 1.0)
	var index = int(hash_val * flower_colors.size()) % flower_colors.size()
	return flower_colors[index]

func _update_texture():
	texture.set_image(rendered_image)
	sprite.texture = texture

## Paint terrain at position
func paint_at(world_pos: Vector2, terrain: TerrainType, radius: int = -1):
	if radius < 0:
		radius = brush_size
	
	var center_x = int(world_pos.x)
	var center_y = int(world_pos.y)
	
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var dist = sqrt(dx * dx + dy * dy)
			if dist <= radius:
				var px = center_x + dx
				var py = center_y + dy
				if px >= 0 and px < map_width and py >= 0 and py < map_height:
					var terrain_value = float(terrain) / 255.0
					terrain_mask.set_pixel(px, py, Color(terrain_value, 0, 0))

## Clear all terrain to grass
func clear_terrain():
	terrain_mask.fill(Color(0, 0, 0))

## Save map to file
func save_map(file_path: String) -> bool:
	var save_data = {
		"version": 1,
		"width": map_width,
		"height": map_height,
		"seed": noise_seed,
		"settings": {
			"flower_threshold": flower_threshold,
			"flower_density": flower_density,
			"edge_raggedness": edge_raggedness,
			"edge_blend_width": edge_blend_width,
			"base_noise_weight": base_noise_weight,
			"detail_noise_weight": detail_noise_weight,
		},
		"colors": {
			"grass_dark": grass_dark.to_html(),
			"grass_mid": grass_mid.to_html(),
			"grass_light": grass_light.to_html(),
			"grass_highlight": grass_highlight.to_html(),
			"path": path_color.to_html(),
			"rock": rock_color.to_html(),
			"water": water_color.to_html(),
		},
		"terrain_mask": Marshalls.raw_to_base64(terrain_mask.get_data()),
	}
	
	var json_string = JSON.stringify(save_data, "\t")
	var file = FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		push_error("Failed to open file for saving: " + file_path)
		return false
	
	file.store_string(json_string)
	file.close()
	
	# Also save the rendered image as PNG
	var png_path = file_path.get_basename() + "_rendered.png"
	rendered_image.save_png(png_path)
	
	map_saved.emit(file_path)
	print("Map saved to: ", file_path)
	return true

## Load map from file
func load_map(file_path: String) -> bool:
	var file = FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		push_error("Failed to open file for loading: " + file_path)
		return false
	
	var json_string = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var error = json.parse(json_string)
	if error != OK:
		push_error("Failed to parse JSON: " + json.get_error_message())
		return false
	
	var data = json.get_data()
	
	# Load settings
	map_width = data.get("width", map_width)
	map_height = data.get("height", map_height)
	noise_seed = data.get("seed", noise_seed)
	noise_gen.set_seed(noise_seed)
	
	var settings = data.get("settings", {})
	flower_threshold = settings.get("flower_threshold", flower_threshold)
	flower_density = settings.get("flower_density", flower_density)
	edge_raggedness = settings.get("edge_raggedness", edge_raggedness)
	edge_blend_width = settings.get("edge_blend_width", edge_blend_width)
	base_noise_weight = settings.get("base_noise_weight", base_noise_weight)
	detail_noise_weight = settings.get("detail_noise_weight", detail_noise_weight)
	
	var colors = data.get("colors", {})
	if colors.has("grass_dark"):
		grass_dark = Color.html(colors.grass_dark)
	if colors.has("grass_mid"):
		grass_mid = Color.html(colors.grass_mid)
	if colors.has("grass_light"):
		grass_light = Color.html(colors.grass_light)
	if colors.has("grass_highlight"):
		grass_highlight = Color.html(colors.grass_highlight)
	if colors.has("path"):
		path_color = Color.html(colors.path)
	if colors.has("rock"):
		rock_color = Color.html(colors.rock)
	if colors.has("water"):
		water_color = Color.html(colors.water)
	
	# Load terrain mask
	if data.has("terrain_mask"):
		var mask_data = Marshalls.base64_to_raw(data.terrain_mask)
		terrain_mask = Image.create_from_data(map_width, map_height, false, Image.FORMAT_R8, mask_data)
	else:
		_initialize_images()
	
	# Recreate rendered image with new size
	rendered_image = Image.create(map_width, map_height, false, Image.FORMAT_RGBA8)
	
	map_loaded.emit(file_path)
	print("Map loaded from: ", file_path)
	return true

## Export just the rendered image
func export_image(file_path: String) -> bool:
	var error = rendered_image.save_png(file_path)
	if error != OK:
		push_error("Failed to export image: " + file_path)
		return false
	print("Image exported to: ", file_path)
	return true
