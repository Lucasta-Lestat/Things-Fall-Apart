class_name GrassNoiseGenerator
extends RefCounted
## Utility class for generating layered noise for grass terrain

# Noise generators for different aspects
var base_noise: FastNoiseLite
var detail_noise: FastNoiseLite
var flower_noise: FastNoiseLite
var edge_noise: FastNoiseLite

# Configuration
var seed_value: int = 0

func _init(p_seed: int = 0):
	seed_value = p_seed
	_setup_noise_generators()

func _setup_noise_generators():
	# Base noise - large scale tonal variation
	base_noise = FastNoiseLite.new()
	base_noise.seed = seed_value
	base_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	base_noise.frequency = 0.008
	base_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	base_noise.fractal_octaves = 3
	base_noise.fractal_lacunarity = 2.0
	base_noise.fractal_gain = 0.5
	
	# Detail noise - fine texture variation
	detail_noise = FastNoiseLite.new()
	detail_noise.seed = seed_value + 1000
	detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	detail_noise.frequency = 0.05
	detail_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	detail_noise.fractal_octaves = 2
	detail_noise.fractal_lacunarity = 2.0
	detail_noise.fractal_gain = 0.5
	
	# Flower noise - for wildflower placement
	flower_noise = FastNoiseLite.new()
	flower_noise.seed = seed_value + 2000
	flower_noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	flower_noise.frequency = 0.1
	flower_noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	flower_noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	
	# Edge noise - for ragged boundaries
	edge_noise = FastNoiseLite.new()
	edge_noise.seed = seed_value + 3000
	edge_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	edge_noise.frequency = 0.03
	edge_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	edge_noise.fractal_octaves = 4
	edge_noise.fractal_lacunarity = 2.0
	edge_noise.fractal_gain = 0.6

func set_seed(new_seed: int):
	seed_value = new_seed
	_setup_noise_generators()

## Get combined grass tone value (0-1) for position
func get_grass_tone(x: float, y: float, base_weight: float = 0.6, detail_weight: float = 0.4) -> float:
	var base_val = (base_noise.get_noise_2d(x, y) + 1.0) * 0.5
	var detail_val = (detail_noise.get_noise_2d(x, y) + 1.0) * 0.5
	return clamp(base_val * base_weight + detail_val * detail_weight, 0.0, 1.0)

## Check if a flower should be placed at position
func should_place_flower(x: float, y: float, threshold: float = 0.85, density_scale: float = 1.0) -> bool:
	var flower_val = (flower_noise.get_noise_2d(x * density_scale, y * density_scale) + 1.0) * 0.5
	# Add some randomness based on position for more natural distribution
	var hash_val = fposmod(sin(x * 12.9898 + y * 78.233) * 43758.5453, 1.0)
	return flower_val * 0.7 + hash_val * 0.3 > threshold

## Get edge displacement for ragged boundaries
func get_edge_displacement(x: float, y: float, amplitude: float = 15.0) -> float:
	return edge_noise.get_noise_2d(x, y) * amplitude

## Get normalized edge noise for blending
func get_edge_blend(x: float, y: float) -> float:
	return (edge_noise.get_noise_2d(x, y) + 1.0) * 0.5
