extends Node2D
## Standalone procedural grass generator - attach to a Node2D to use
## This is a simpler version you can easily integrate into existing projects

# Configuration
@export_group("Map Size")
@export var map_width: int = 256
@export var map_height: int = 256

@export_group("Grass Colors")
@export var grass_colors: Array[Color] = [
	Color("376F32"),  # Dark
	Color("519F42"),  # Mid
	Color("72A651"),  # Light  
	Color("87B860"),  # Highlight
]

@export_group("Noise Settings")
@export var noise_seed: int = 12345
@export var base_frequency: float = 0.008
@export var detail_frequency: float = 0.05

@export_group("Wildflowers")
@export var flower_threshold: float = 0.87
@export var flower_colors: Array[Color] = [
	Color.WHITE,
	Color("FFF8CC"),  # Cream
	Color("FFD6E5"),  # Pink
	Color("E5E5FF"),  # Blue tint
]

# Internal
var base_noise: FastNoiseLite
var detail_noise: FastNoiseLite
var flower_noise: FastNoiseLite
var image: Image
var texture: ImageTexture
var sprite: Sprite2D

func _ready():
	_setup_noise()
	_create_display()
	generate()

func _setup_noise():
	# Large-scale tonal variation
	base_noise = FastNoiseLite.new()
	base_noise.seed = noise_seed
	base_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	base_noise.frequency = base_frequency
	base_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	base_noise.fractal_octaves = 3
	
	# Fine detail texture
	detail_noise = FastNoiseLite.new()
	detail_noise.seed = noise_seed + 1000
	detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	detail_noise.frequency = detail_frequency
	detail_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	detail_noise.fractal_octaves = 2
	
	# Cellular noise for flower clustering
	flower_noise = FastNoiseLite.new()
	flower_noise.seed = noise_seed + 2000
	flower_noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	flower_noise.frequency = 0.08
	flower_noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE

func _create_display():
	image = Image.create(map_width, map_height, false, Image.FORMAT_RGBA8)
	texture = ImageTexture.new()
	sprite = Sprite2D.new()
	sprite.centered = false
	add_child(sprite)

## Main generation function
func generate():
	for y in range(map_height):
		for x in range(map_width):
			var color = _get_pixel_color(x, y)
			image.set_pixel(x, y, color)
	
	texture.set_image(image)
	sprite.texture = texture

func _get_pixel_color(x: int, y: int) -> Color:
	# Layer 1: Base tonal variation (large patches of light/dark)
	var base_val = _normalize_noise(base_noise.get_noise_2d(x, y))
	
	# Layer 2: Detail variation (fine texture)
	var detail_val = _normalize_noise(detail_noise.get_noise_2d(x, y))
	
	# Combine with weighted blend
	var tone = base_val * 0.6 + detail_val * 0.4
	
	# Map tone to color gradient
	var grass_color = _sample_gradient(tone, grass_colors)
	
	# Check for wildflower placement
	if _should_place_flower(x, y, tone):
		return _get_flower_color(x, y)
	
	return grass_color

func _normalize_noise(value: float) -> float:
	# Convert -1..1 to 0..1
	return (value + 1.0) * 0.5

func _sample_gradient(t: float, colors: Array[Color]) -> Color:
	if colors.is_empty():
		return Color.MAGENTA
	if colors.size() == 1:
		return colors[0]
	
	# Map t (0-1) to color array
	var scaled = t * (colors.size() - 1)
	var idx = int(scaled)
	var frac = scaled - idx
	
	idx = clampi(idx, 0, colors.size() - 2)
	return colors[idx].lerp(colors[idx + 1], frac)

func _should_place_flower(x: int, y: int, grass_tone: float) -> bool:
	# Only place flowers on lighter grass for visibility
	if grass_tone < 0.4:
		return false
	
	# Use cellular noise for natural clustering
	var flower_val = _normalize_noise(flower_noise.get_noise_2d(x, y))
	
	# Add position-based randomness
	var hash = fposmod(sin(x * 12.9898 + y * 78.233) * 43758.5453, 1.0)
	
	return (flower_val * 0.7 + hash * 0.3) > flower_threshold

func _get_flower_color(x: int, y: int) -> Color:
	if flower_colors.is_empty():
		return Color.WHITE
	
	# Deterministic random based on position
	var hash = fposmod(sin(x * 127.1 + y * 311.7) * 43758.5453, 1.0)
	var idx = int(hash * flower_colors.size()) % flower_colors.size()
	return flower_colors[idx]

## Regenerate with new seed
func set_seed(new_seed: int):
	noise_seed = new_seed
	base_noise.seed = new_seed
	detail_noise.seed = new_seed + 1000
	flower_noise.seed = new_seed + 2000
	generate()

## Get the generated image for use elsewhere
func get_image() -> Image:
	return image

## Save to PNG
func save_png(path: String) -> bool:
	return image.save_png(path) == OK
