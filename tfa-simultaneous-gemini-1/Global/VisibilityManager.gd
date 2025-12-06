# VisibilityManager.gd
extends Node
enum Direction { DOWN, UP, LEFT, RIGHT }
# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	#update_visibility()
	pass

# Configuration
@export var base_vision_range: float = 5.0  # tiles
@export var vision_angle: float = 120.0  # degrees (cone in front of character)
@export var peripheral_range: float = 3.0  # tiles (all around, even behind)
@export var light_levels: Dictionary = {
	"bright": 1.0,      # Full visibility at max range
	"dim": 0.5,         # Half visibility range
	"dark": 0.2,        # Very limited visibility
	"pitch_black": 0.0  # No visibility without light source
}

# Visibility data
var visible_tiles: Dictionary = {}  # grid_position -> visibility_level (0.0 to 1.0)
var lit_tiles: Dictionary = {}  # grid_position -> light_level

var light_probe_viewport: SubViewport
var light_probe_camera: Camera2D
var world_reference: Node2D  # Reference to your game world
@onready var game = get_node("/root/Game")
signal visibility_changed(visible_tiles: Dictionary)

func _ready():
	# Update visibility each frame or on demand
	pass
	#setup_light_probing()

func setup_light_probing():
	# Create a viewport to capture lighting information
	light_probe_viewport = SubViewport.new()
	light_probe_viewport.size = Vector2i(1, 1)  # We only need 1 pixel samples
	light_probe_viewport.transparent_bg = false
	add_child(light_probe_viewport)

	# Create a camera to position our sample point
	light_probe_camera = Camera2D.new()
	light_probe_viewport.add_child(light_probe_camera)


func sample_light_at_position(world_pos: Vector2) -> float:
	# Position the camera at the target location
	light_probe_camera.global_position = world_pos

	# Force a render
	light_probe_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

	# Wait for the next frame to ensure rendering is complete
	await get_tree().process_frame

	# Get the rendered image
	var img = light_probe_viewport.get_texture().get_image()

	# Sample the center pixel
	var pixel_color = img.get_pixel(0, 0)

	# Calculate brightness (luminance)
	var brightness = (pixel_color.r + pixel_color.g + pixel_color.b) / 3.0

	return brightness
func update_visibility():
	visible_tiles.clear() # super inefficient?
	
	# Get all party members
	var party_members = game.party_chars

	for character in party_members:
		var char_pos = character.global_position
		var char_grid_pos = world_to_grid(char_pos)
		var char_facing = get_facing_direction(character.current_direction)  # Assume this returns a Vector2

		# Calculate visible tiles for this character
		var char_visible = await calculate_fov(char_grid_pos, char_facing, character)

		# Merge with overall visibility (taking maximum visibility level)
		for tile_pos in char_visible:
			if tile_pos not in visible_tiles:
				visible_tiles[tile_pos] = char_visible[tile_pos]
			else:
				visible_tiles[tile_pos] = max(visible_tiles[tile_pos], char_visible[tile_pos])
	
	visibility_changed.emit(visible_tiles)
	#print("visible tiles: ", visible_tiles.size())
	return visible_tiles
	
func get_facing_direction(current_direction):
	match current_direction:
		Direction.DOWN:
			return Vector2(0,-1)
		Direction.UP:
			return Vector2(0,1)
		Direction.RIGHT:
			return Vector2(1,0)
		Direction.LEFT:
			return Vector2(-1,0)
func calculate_fov(origin: Vector2i, facing_direction: Vector2, character) -> Dictionary:
	var fov_tiles: Dictionary = {}
	var max_range = base_vision_range

	# Get light level at origin
	var origin_light = await get_light_level(origin)
	max_range *= origin_light

	# Always see the tile you're standing on
	fov_tiles[origin] = 1.0

	# Cast rays in multiple directions
	var ray_count = 360  # Number of rays to cast (more = smoother but slower)

	for i in range(ray_count):
		var angle = (i / float(ray_count)) * TAU
		var ray_dir = Vector2(cos(angle), sin(angle))

		# Determine if this ray is in the character's main vision cone
		var angle_to_facing = rad_to_deg(facing_direction.angle_to(ray_dir))
		var in_main_cone = abs(angle_to_facing) < vision_angle / 2.0
		var effective_range = max_range if in_main_cone else peripheral_range

		# Apply light level reduction
		effective_range *= max(origin_light, 0.2)  # Minimum 20% range even in darkness

		cast_ray(origin, ray_dir, effective_range, fov_tiles, in_main_cone)

	return fov_tiles

func cast_ray(origin: Vector2i, direction: Vector2, max_distance: float, 
			  visible_tiles: Dictionary, is_main_vision: bool):
	var current_pos = Vector2(origin)
	var step_size = 0.25  # Sub-tile precision for smoother walls
	var distance = 0.0

	while distance < max_distance:
		current_pos += direction * step_size
		distance += step_size

		var grid_pos = Vector2i(floor(current_pos.x), floor(current_pos.y))

		# Check if we hit a wall
		if GridManager.walls[grid_pos]:
			# Mark the wall as visible but stop the ray
			var visibility = 1.0 - (distance / max_distance)
			visibility *= 0.5 if not is_main_vision else 1.0

			if grid_pos not in visible_tiles:
				visible_tiles[grid_pos] = visibility
			else:
				visible_tiles[grid_pos] = max(visible_tiles[grid_pos], visibility)
			break
		
		# Mark this tile as visible
		var light_level = await get_light_level(grid_pos)
		if light_level > 0.1:  # Only visible if some light
			var visibility = (1.0 - (distance / max_distance)) * light_level
			visibility *= 0.5 if not is_main_vision else 1.0
			
			if grid_pos not in visible_tiles:
				visible_tiles[grid_pos] = visibility
			else:
				visible_tiles[grid_pos] = max(visible_tiles[grid_pos], visibility)

func get_light_level(grid_pos: Vector2i) -> float:
	if not world_reference:
		return 0.3  # Default fallback
	
	var world_pos = grid_to_world(grid_pos)

	# Sample the light at this position
	var light_value = await sample_light_at_position(world_pos)

	# Convert to 0.0-1.0 range (adjust based on your lighting setup)
	return clamp(light_value, 0.0, 1.0)

func add_light_source(grid_pos: Vector2i, intensity: float, radius: float):
	# Add a light source that affects surrounding tiles
	for x in range(-int(radius), int(radius) + 1):
		for y in range(-int(radius), int(radius) + 1):
			var check_pos = grid_pos + Vector2i(x, y)
			var distance = Vector2(x, y).length()
			
			if distance <= radius:
				# Calculate light falloff
				var light_value = intensity * (1.0 - (distance / radius))

				# Check if light is blocked by walls (simple version)
				if not is_light_blocked(grid_pos, check_pos):
					if check_pos not in lit_tiles:
						lit_tiles[check_pos] = light_value
					else:
						lit_tiles[check_pos] = max(lit_tiles[check_pos], light_value)

func is_light_blocked(from: Vector2i, to: Vector2i) -> bool:
	# Simple line-of-sight check for light
	var direction = (Vector2(to) - Vector2(from)).normalized()
	var distance = Vector2(from).distance_to(Vector2(to))
	var current = Vector2(from)
	var step = 0.5
	
	while current.distance_to(Vector2(from)) < distance:
		current += direction * step
		var grid_pos = Vector2i(floor(current.x), floor(current.y))
		if GridManager.wall.get(grid_pos, false):
			return true
	return false

func world_to_grid(world_pos: Vector2) -> Vector2i:
	# Adjust based on your tile size
	var tile_size = GridManager.TILE_SIZE 
	return Vector2i(floor(world_pos.x / tile_size), floor(world_pos.y / tile_size))

func is_tile_visible(grid_pos: Vector2i) -> bool:
	return grid_pos in visible_tiles and visible_tiles[grid_pos] > 0.1

func get_tile_visibility(grid_pos: Vector2i) -> float:
	return visible_tiles.get(grid_pos, 0.0)
	
func grid_to_world(grid_pos: Vector2i) -> Vector2:
	var tile_size = GridManager.TILE_SIZE  # Adjust to your tile size
	return Vector2(grid_pos.x * tile_size + tile_size / 2, 
				   grid_pos.y * tile_size + tile_size / 2)
