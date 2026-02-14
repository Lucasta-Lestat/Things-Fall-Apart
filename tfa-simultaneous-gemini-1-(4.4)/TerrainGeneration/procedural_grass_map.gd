extends Node2D
## Advanced procedural grass with ragged edges, terrain blending, and save/load
## This version properly handles edges between grass and other terrain types

class_name ProceduralGrassMap

signal generation_started
signal generation_progress(percent: float)
signal generation_complete

# Terrain types for the mask
enum Terrain { GRASS = 0, PATH = 1, ROCK = 2, WATER = 3 }

@export_group("Map Settings")
@export var map_size: Vector2i = Vector2i(512, 512)
@export var auto_generate: bool = true

@export_group("Grass Palette")
@export var grass_dark: Color = Color("2B5E28")
@export var grass_mid: Color = Color("3D7A35")
@export var grass_light: Color = Color("5A9A4A")
@export var grass_bright: Color = Color("72B85E")

@export_group("Other Terrain")
@export var path_base: Color = Color("B89F70")
@export var path_dark: Color = Color("9A8560")
@export var rock_base: Color = Color("808078")
@export var rock_dark: Color = Color("606058")
@export var water_base: Color = Color("4A90A8")

@export_group("Wildflower Settings")
@export var enable_flowers: bool = true
@export var flower_threshold: float = 0.86
@export var flower_size: int = 1  # 1 = single pixel, 2 = 2x2, etc.
@export var flower_colors: Array[Color] = [
	Color("FFFFFF"),
	Color("FFF5E0"),
	Color("FFE0EC"),
	Color("E8E8FF"),
	Color("FFFFA0"),
]

@export_group("Edge Settings")
@export var edge_noise_scale: float = 0.025
@export var edge_displacement: float = 10.0  # How far edges can wobble
@export var edge_blend_distance: float = 6.0  # Gradient blend zone
@export var enable_grass_tufts: bool = true  # Scattered grass pixels in blend zone

@export_group("Noise Configuration")
@export var world_seed: int = 42
@export var base_scale: float = 0.006  # Large patches
@export var mid_scale: float = 0.02   # Medium variation
@export var fine_scale: float = 0.08  # Fine texture

# Noise generators
var _base_noise: FastNoiseLite
var _mid_noise: FastNoiseLite
var _fine_noise: FastNoiseLite
var _edge_noise: FastNoiseLite
var _flower_noise: FastNoiseLite
var _tuft_noise: FastNoiseLite

# Map data
var _terrain_mask: Image  # R channel stores terrain type (0-255)
var _output_image: Image
var _texture: ImageTexture
var _sprite: Sprite2D

# Distance field cache for edge calculations
var _distance_field: Array[float]
var _nearest_terrain: Array[int]

func _ready():
	_init_noise_generators()
	_init_images()
	_create_sprite()
	
	if auto_generate:
		generate()

func _init_noise_generators():
	# Base layer - large scale light/dark patches
	_base_noise = FastNoiseLite.new()
	_base_noise.seed = world_seed
	_base_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_base_noise.frequency = base_scale
	_base_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_base_noise.fractal_octaves = 3
	_base_noise.fractal_lacunarity = 2.0
	_base_noise.fractal_gain = 0.5
	
	# Mid layer - medium scale variation
	_mid_noise = FastNoiseLite.new()
	_mid_noise.seed = world_seed + 111
	_mid_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_mid_noise.frequency = mid_scale
	_mid_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_mid_noise.fractal_octaves = 2
	
	# Fine layer - small scale texture
	_fine_noise = FastNoiseLite.new()
	_fine_noise.seed = world_seed + 222
	_fine_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_fine_noise.frequency = fine_scale
	
	# Edge noise - for ragged boundaries
	_edge_noise = FastNoiseLite.new()
	_edge_noise.seed = world_seed + 333
	_edge_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_edge_noise.frequency = edge_noise_scale
	_edge_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_edge_noise.fractal_octaves = 4
	_edge_noise.fractal_lacunarity = 2.5
	_edge_noise.fractal_gain = 0.6
	
	# Flower placement noise
	_flower_noise = FastNoiseLite.new()
	_flower_noise.seed = world_seed + 444
	_flower_noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	_flower_noise.frequency = 0.1
	_flower_noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	_flower_noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	
	# Tuft noise for scattered grass in blend zones
	_tuft_noise = FastNoiseLite.new()
	_tuft_noise.seed = world_seed + 555
	_tuft_noise.noise_type = FastNoiseLite.TYPE_VALUE
	_tuft_noise.frequency = 0.5

func _init_images():
	_terrain_mask = Image.create(map_size.x, map_size.y, false, Image.FORMAT_R8)
	_terrain_mask.fill(Color(0, 0, 0))  # All grass by default
	
	_output_image = Image.create(map_size.x, map_size.y, false, Image.FORMAT_RGBA8)
	
	# Initialize distance field
	_distance_field.resize(map_size.x * map_size.y)
	_nearest_terrain.resize(map_size.x * map_size.y)

func _create_sprite():
	_texture = ImageTexture.new()
	_sprite = Sprite2D.new()
	_sprite.centered = false
	add_child(_sprite)

#region Public API

## Set terrain type at a position (for painting)
func set_terrain(x: int, y: int, terrain: Terrain):
	if x < 0 or x >= map_size.x or y < 0 or y >= map_size.y:
		return
	var value = float(terrain) / 255.0
	_terrain_mask.set_pixel(x, y, Color(value, 0, 0))

## Paint a circular brush of terrain
func paint_circle(center: Vector2i, radius: int, terrain: Terrain):
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx * dx + dy * dy <= radius * radius:
				set_terrain(center.x + dx, center.y + dy, terrain)

## Get terrain type at position
func get_terrain(x: int, y: int) -> Terrain:
	if x < 0 or x >= map_size.x or y < 0 or y >= map_size.y:
		return Terrain.GRASS
	var value = _terrain_mask.get_pixel(x, y).r
	return int(value * 255.0) as Terrain

## Clear map to all grass
func clear():
	_terrain_mask.fill(Color(0, 0, 0))

## Main generation function
func generate():
	generation_started.emit()
	
	# First pass: compute distance field for edge handling
	_compute_distance_field()
	
	# Second pass: render all pixels
	for y in range(map_size.y):
		for x in range(map_size.x):
			var color = _compute_pixel(x, y)
			_output_image.set_pixel(x, y, color)
		
		# Emit progress every 32 rows
		if y % 32 == 0:
			generation_progress.emit(float(y) / map_size.y)
	
	_texture.set_image(_output_image)
	_sprite.texture = _texture
	
	generation_complete.emit()

## Async generation (call with await)
func generate_async(rows_per_frame: int = 16):
	generation_started.emit()
	
	_compute_distance_field()
	
	var y = 0
	while y < map_size.y:
		var end_y = mini(y + rows_per_frame, map_size.y)
		for row in range(y, end_y):
			for x in range(map_size.x):
				var color = _compute_pixel(x, row)
				_output_image.set_pixel(x, row, color)
		
		generation_progress.emit(float(end_y) / map_size.y)
		y = end_y
		await get_tree().process_frame
	
	_texture.set_image(_output_image)
	_sprite.texture = _texture
	
	generation_complete.emit()

## Save map data to file
func save_map(path: String) -> bool:
	var data = {
		"version": 2,
		"size": [map_size.x, map_size.y],
		"seed": world_seed,
		"settings": {
			"flower_threshold": flower_threshold,
			"edge_displacement": edge_displacement,
			"edge_blend_distance": edge_blend_distance,
			"base_scale": base_scale,
			"mid_scale": mid_scale,
			"fine_scale": fine_scale,
		},
		"terrain": Marshalls.raw_to_base64(_terrain_mask.get_data()),
	}
	
	var file = FileAccess.open(path, FileAccess.WRITE)
	if not file:
		push_error("Cannot open file for writing: " + path)
		return false
	
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return true

## Load map data from file
func load_map(path: String) -> bool:
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("Cannot open file for reading: " + path)
		return false
	
	var json = JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("Invalid JSON in map file")
		return false
	
	var data = json.get_data()
	
	map_size = Vector2i(data.size[0], data.size[1])
	world_seed = data.get("seed", world_seed)
	
	var settings = data.get("settings", {})
	flower_threshold = settings.get("flower_threshold", flower_threshold)
	edge_displacement = settings.get("edge_displacement", edge_displacement)
	edge_blend_distance = settings.get("edge_blend_distance", edge_blend_distance)
	base_scale = settings.get("base_scale", base_scale)
	mid_scale = settings.get("mid_scale", mid_scale)
	fine_scale = settings.get("fine_scale", fine_scale)
	
	# Reinitialize with new settings
	_init_noise_generators()
	_init_images()
	
	# Load terrain mask
	var terrain_data = Marshalls.base64_to_raw(data.terrain)
	_terrain_mask = Image.create_from_data(map_size.x, map_size.y, false, Image.FORMAT_R8, terrain_data)
	
	return true

## Export rendered image as PNG
func export_png(path: String) -> bool:
	return _output_image.save_png(path) == OK

## Get the output image directly
func get_output_image() -> Image:
	return _output_image

#endregion

#region Private Methods

func _compute_distance_field():
	## Compute approximate distance to nearest non-grass terrain for each pixel
	## This enables efficient edge calculations
	
	var check_radius = int(edge_displacement + edge_blend_distance) + 2
	
	for y in range(map_size.y):
		for x in range(map_size.x):
			var idx = y * map_size.x + x
			var my_terrain = get_terrain(x, y)
			
			if my_terrain != Terrain.GRASS:
				_distance_field[idx] = 0.0
				_nearest_terrain[idx] = my_terrain
				continue
			
			# Find nearest non-grass pixel
			var min_dist = INF
			var nearest = Terrain.GRASS
			
			for dy in range(-check_radius, check_radius + 1):
				for dx in range(-check_radius, check_radius + 1):
					var nx = x + dx
					var ny = y + dy
					if nx < 0 or nx >= map_size.x or ny < 0 or ny >= map_size.y:
						continue
					
					var neighbor_terrain = get_terrain(nx, ny)
					if neighbor_terrain != Terrain.GRASS:
						var dist = sqrt(dx * dx + dy * dy)
						if dist < min_dist:
							min_dist = dist
							nearest = neighbor_terrain
			
			_distance_field[idx] = min_dist if min_dist != INF else 999.0
			_nearest_terrain[idx] = nearest

func _compute_pixel(x: int, y: int) -> Color:
	var idx = y * map_size.x + x
	var base_terrain = get_terrain(x, y)
	var dist_to_edge = _distance_field[idx]
	var nearest = _nearest_terrain[idx] as Terrain
	
	# Get edge noise for this position
	var edge_noise_val = _edge_noise.get_noise_2d(x, y) * edge_displacement
	
	# Effective distance considering noise displacement
	var effective_dist = dist_to_edge + edge_noise_val
	
	# Determine what to render based on effective distance
	if base_terrain == Terrain.GRASS:
		if effective_dist <= 0:
			# Noise pushed us into other terrain
			return _get_terrain_color(nearest, x, y)
		elif effective_dist < edge_blend_distance:
			# In the blend zone
			var blend = effective_dist / edge_blend_distance
			var grass_color = _get_grass_color(x, y)
			var other_color = _get_terrain_color(nearest, x, y)
			
			# Add grass tufts in blend zone
			if enable_grass_tufts:
				var tuft = (_tuft_noise.get_noise_2d(x, y) + 1.0) * 0.5
				if tuft > 0.7 - blend * 0.3:
					return grass_color
			
			return other_color.lerp(grass_color, blend)
		else:
			# Pure grass
			return _get_grass_color(x, y)
	else:
		# Non-grass terrain - check if noise pushes grass into us
		if effective_dist < -edge_blend_distance:
			# Definitely this terrain
			return _get_terrain_color(base_terrain, x, y)
		elif effective_dist < 0:
			# Blend zone on the terrain side
			var blend = -effective_dist / edge_blend_distance
			var terrain_color = _get_terrain_color(base_terrain, x, y)
			var grass_color = _get_grass_color(x, y)
			return grass_color.lerp(terrain_color, blend)
		else:
			return _get_terrain_color(base_terrain, x, y)

func _get_grass_color(x: int, y: int) -> Color:
	# Multi-octave noise for tonal variation
	var base = (_base_noise.get_noise_2d(x, y) + 1.0) * 0.5
	var mid = (_mid_noise.get_noise_2d(x, y) + 1.0) * 0.5
	var fine = (_fine_noise.get_noise_2d(x, y) + 1.0) * 0.5
	
	# Weighted combination
	var tone = base * 0.5 + mid * 0.35 + fine * 0.15
	
	# Check for wildflower
	if enable_flowers and _should_place_flower(x, y, tone):
		return _get_flower_color(x, y)
	
	# Map tone to gradient
	return _sample_grass_gradient(tone)

func _sample_grass_gradient(t: float) -> Color:
	t = clampf(t, 0.0, 1.0)
	if t < 0.33:
		return grass_dark.lerp(grass_mid, t / 0.33)
	elif t < 0.66:
		return grass_mid.lerp(grass_light, (t - 0.33) / 0.33)
	else:
		return grass_light.lerp(grass_bright, (t - 0.66) / 0.34)

func _should_place_flower(x: int, y: int, tone: float) -> bool:
	# Only on lighter grass
	if tone < 0.35:
		return false
	
	var flower_val = (_flower_noise.get_noise_2d(x, y) + 1.0) * 0.5
	var hash = fposmod(sin(x * 12.9898 + y * 78.233) * 43758.5453, 1.0)
	
	return (flower_val * 0.6 + hash * 0.4) > flower_threshold

func _get_flower_color(x: int, y: int) -> Color:
	if flower_colors.is_empty():
		return Color.WHITE
	
	var hash = fposmod(sin(x * 127.1 + y * 311.7) * 43758.5453, 1.0)
	var idx = int(hash * flower_colors.size()) % flower_colors.size()
	return flower_colors[idx]

func _get_terrain_color(terrain: Terrain, x: int, y: int) -> Color:
	var variation = (_mid_noise.get_noise_2d(x * 1.5, y * 1.5) + 1.0) * 0.5
	
	match terrain:
		Terrain.PATH:
			return path_dark.lerp(path_base, variation)
		Terrain.ROCK:
			return rock_dark.lerp(rock_base, variation)
		Terrain.WATER:
			return water_base.lightened(variation * 0.15)
		_:
			return _get_grass_color(x, y)

#endregion
