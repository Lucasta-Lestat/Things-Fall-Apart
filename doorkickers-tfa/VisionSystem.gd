# VisionSystem.gd
extends Node2D
class_name VisionSystem

@export var tile_size: int = 32
@export var map_width: int = 100
@export var map_height: int = 100

var fog_texture: ImageTexture
var fog_image: Image
var visibility_map: Array = []
var light_map: Array = []

# Vision rendering
var vision_polygons: Array = []
var combined_vision: PackedVector2Array

# Fog of war colors
var fog_color = Color(0, 0, 0, 0.8)
var explored_fog_color = Color(0, 0, 0, 0.5)
var visible_color = Color(1, 1, 1, 0)

# Cloud/smoke system
var smoke_clouds: Array = []

signal visibility_updated

func _ready():
	_initialize_maps()
	set_process(true)

func _initialize_maps():
	visibility_map.resize(map_width)
	light_map.resize(map_width)
	
	for x in range(map_width):
		visibility_map[x] = []
		light_map[x] = []
		visibility_map[x].resize(map_height)
		light_map[x].resize(map_height)
		
		for y in range(map_height):
			visibility_map[x][y] = false
			light_map[x][y] = 0.0
	
	# Create fog texture
	fog_image = Image.create(map_width, map_height, false, Image.FORMAT_RGBA8)
	fog_texture = ImageTexture.create_from_image(fog_image)

func _process(_delta):
	_update_visibility()
	_render_fog_of_war()
	queue_redraw()

func _update_visibility():
	# Reset visibility
	for x in range(map_width):
		for y in range(map_height):
			visibility_map[x][y] = false
	
	vision_polygons.clear()
	
	# Get all player characters
	var player_characters = get_tree().get_nodes_in_group("player_characters")
	
	for character in player_characters:
		if character.has_method("get_vision_polygon"):
			var poly = character.vision_polygon
			if poly.size() > 0:
				vision_polygons.append(poly)
				_mark_visible_tiles(poly)
	
	# Combine all vision polygons
	_combine_vision_polygons()
	visibility_updated.emit()

func _mark_visible_tiles(polygon: PackedVector2Array):
	if polygon.size() < 3:
		return
	
	# Get bounding box
	var min_x = INF
	var min_y = INF
	var max_x = -INF
	var max_y = -INF
	
	for point in polygon:
		min_x = min(min_x, point.x)
		min_y = min(min_y, point.y)
		max_x = max(max_x, point.x)
		max_y = max(max_y, point.y)
	
	# Convert to tile coordinates
	var tile_min_x = int(min_x / tile_size)
	var tile_min_y = int(min_y / tile_size)
	var tile_max_x = int(max_x / tile_size) + 1
	var tile_max_y = int(max_y / tile_size) + 1
	
	# Clamp to map bounds
	tile_min_x = clamp(tile_min_x, 0, map_width - 1)
	tile_min_y = clamp(tile_min_y, 0, map_height - 1)
	tile_max_x = clamp(tile_max_x, 0, map_width)
	tile_max_y = clamp(tile_max_y, 0, map_height)
	
	# Check each tile in bounding box
	for x in range(tile_min_x, tile_max_x):
		for y in range(tile_min_y, tile_max_y):
			var tile_center = Vector2(x * tile_size + tile_size/2, y * tile_size + tile_size/2)
			if Geometry2D.is_point_in_polygon(tile_center, polygon):
				visibility_map[x][y] = true

func _combine_vision_polygons():
	if vision_polygons.size() == 0:
		combined_vision = PackedVector2Array()
		return
	
	# For simplicity, just use the first polygon
	# In a full implementation, you'd merge overlapping polygons
	combined_vision = vision_polygons[0]
	
	for i in range(1, vision_polygons.size()):
		# Merge polygons (simplified - just add points)
		for point in vision_polygons[i]:
			combined_vision.append(point)

func _render_fog_of_war():
	fog_image.fill(fog_color)
	
	for x in range(map_width):
		for y in range(map_height):
			if visibility_map[x][y]:
				fog_image.set_pixel(x, y, visible_color)
			else:
				# Check if in smoke cloud
				var world_pos = Vector2(x * tile_size, y * tile_size)
				if _is_in_smoke(world_pos):
					fog_image.set_pixel(x, y, fog_color)
	
	fog_texture.update(fog_image)

func _draw():
	# Draw fog of war overlay
	if fog_texture:
		draw_texture_rect(fog_texture, Rect2(Vector2.ZERO, Vector2(map_width * tile_size, map_height * tile_size)), false)
	
	# Debug: Draw vision polygons
	if OS.is_debug_build():
		for poly in vision_polygons:
			if poly.size() > 2:
				draw_colored_polygon(poly, Color(1, 1, 0, 0.1))
				draw_polyline(poly, Color(1, 1, 0, 0.5), 2.0)

func is_position_visible(pos: Vector2) -> bool:
	var tile_x = int(pos.x / tile_size)
	var tile_y = int(pos.y / tile_size)
	
	if tile_x < 0 or tile_x >= map_width or tile_y < 0 or tile_y >= map_height:
		return false
	
	return visibility_map[tile_x][tile_y]

func add_smoke_cloud(position: Vector2, radius: float, duration: float):
	smoke_clouds.append({
		"position": position,
		"radius": radius,
		"duration": duration,
		"time_left": duration
	})

func _is_in_smoke(pos: Vector2) -> bool:
	for cloud in smoke_clouds:
		if pos.distance_to(cloud.position) <= cloud.radius:
			return true
	return false

func update_smoke_clouds(delta: float):
	for i in range(smoke_clouds.size() - 1, -1, -1):
		smoke_clouds[i].time_left -= delta
		if smoke_clouds[i].time_left <= 0:
			smoke_clouds.remove_at(i)

func get_light_level_at(pos: Vector2) -> float:
	var tile_x = int(pos.x / tile_size)
	var tile_y = int(pos.y / tile_size)
	
	if tile_x < 0 or tile_x >= map_width or tile_y < 0 or tile_y >= map_height:
		return 0.0
	
	return light_map[tile_x][tile_y]

func set_light_level_at(pos: Vector2, level: float):
	var tile_x = int(pos.x / tile_size)
	var tile_y = int(pos.y / tile_size)
	
	if tile_x >= 0 and tile_x < map_width and tile_y >= 0 and tile_y < map_height:
		light_map[tile_x][tile_y] = level

# Called when a light source is added
func add_light_source(position: Vector2, intensity: float, radius: float):
	var tile_radius = int(radius / tile_size)
	var center_x = int(position.x / tile_size)
	var center_y = int(position.y / tile_size)
	
	for x in range(max(0, center_x - tile_radius), min(map_width, center_x + tile_radius + 1)):
		for y in range(max(0, center_y - tile_radius), min(map_height, center_y + tile_radius + 1)):
			var dist = Vector2(x - center_x, y - center_y).length()
			if dist <= tile_radius:
				var falloff = 1.0 - (dist / tile_radius)
				var light_contribution = intensity * falloff
				light_map[x][y] = min(100.0, light_map[x][y] + light_contribution)
