# res://MapLoader.gd
extends Node2D

@export var map_image_path: String = "res://Maps/cemetery.png"
@export var mask_image_path: String = "res://Maps/cemetery_mask.png"
@export var structure_map_image_path: String = "res://maps/cemetery_structures.png"
@export var structure_mask_path: String = "res://maps/cemetery_structures_mask.png"
@export var blend_margin: int = 16  # pixels of blending around structure edges

var structure_scene: PackedScene = preload("res://Structures/Structure.tscn")

# Map mask colors to structure IDs
var color_to_structure: Dictionary = {
	Color8(0, 128, 0): "tree",      # dark green
	Color8(139, 69, 19): "wood_wall",    # brown
	Color8(255, 0, 0): "door_wood",      # red
	Color8(128, 128, 128): "stone_wall"
}

# Map mask colors to floor IDs from your FloorDatabase
var color_to_floor: Dictionary = {
	Color8(0, 255, 0): "grass",       # pure green
	Color8(139, 69, 19): "floor_dirt",       # brown
	Color8(128, 128, 128): "floor_stone",    # gray
	Color8(0, 0, 255): "water",        # blue
}

# How close a pixel color must be to a key to match (accounts for anti-aliasing)
@export var color_tolerance: float = 0.15

var floor_scene: PackedScene = preload("res://Structures/floors/floor.tscn")

func _ready():
	# Don't auto-generate; Game.load_map() calls generate_map() after GridManager is initialized
	pass

func generate_map():
	var tile_size = GridManager.TILE_SIZE

	var struct_map_img: Image = load(structure_map_image_path).get_image()
	var clean_map_img: Image = load(map_image_path).get_image()
	var floor_mask_img: Image = load(mask_image_path).get_image()
	var struct_mask_img: Image = load(structure_mask_path).get_image()

	var map_width = struct_map_img.get_width()
	var map_height = struct_map_img.get_height()

	# Build a structure occupancy mask so we know which pixels have structures
	var structure_mask: PackedByteArray = _build_structure_occupancy(struct_mask_img, map_width, map_height)

	# Create blended ground image: structures map everywhere, but blend in
	# the clean map underneath structure regions so that when structures
	# are destroyed the clean ground is revealed seamlessly
	var blended_ground: Image = _create_blended_ground(struct_map_img, clean_map_img, structure_mask, map_width, map_height)

	# --- Generate top ground layer (from structures map) ---
	var cols = map_width / tile_size
	var rows = map_height / tile_size

	for row in rows:
		for col in cols:
			var px = col * tile_size
			var py = row * tile_size
			var sample_x = px + tile_size / 2
			var sample_y = py + tile_size / 2
			var mask_color = floor_mask_img.get_pixel(sample_x, sample_y)
			var floor_id = match_color_to_floor(mask_color)
			if floor_id == "":
				continue

			# Top layer: sampled from the structures map
			var tile_rect = Rect2i(px, py, tile_size, tile_size)
			var tile_img = struct_map_img.get_region(tile_rect)
			var tile_tex = ImageTexture.create_from_image(tile_img)

			var floor_instance = floor_scene.instantiate()
			floor_instance.floor_id = floor_id
			floor_instance.use_custom_texture = true
			floor_instance.custom_texture = tile_tex
			floor_instance.skip_grid_snap = true
			floor_instance.position = Vector2(px + tile_size / 2, py + tile_size / 2)
			floor_instance.z_index = -4
			add_child(floor_instance)

			# Register floor with GridManager
			GridManager.register_floor(Vector2i(col, row), floor_instance)

			# Underneath layer: blended clean map (revealed when structures break)
			var under_img = blended_ground.get_region(tile_rect)
			var under_tex = ImageTexture.create_from_image(under_img)

			var under_floor = floor_scene.instantiate()
			under_floor.floor_id = floor_id
			under_floor.use_custom_texture = true
			under_floor.custom_texture = under_tex
			under_floor.skip_grid_snap = true
			under_floor.position = Vector2(px + tile_size / 2, py + tile_size / 2)
			under_floor.z_index = -6
			add_child(under_floor)

	# --- Generate structures ---
	_generate_structures(struct_map_img, struct_mask_img, map_width, map_height)

	emit_signal("map_loaded")

func _build_structure_occupancy(mask: Image, width: int, height: int) -> PackedByteArray:
	# Returns a byte array where 1 = this pixel is part of a structure
	var occupancy: PackedByteArray
	occupancy.resize(width * height)
	occupancy.fill(0)

	for y in height:
		for x in width:
			var color = mask.get_pixel(x, y)
			if color.a < 0.5:
				continue
			if match_color_to_structure(color) != "":
				occupancy[y * width + x] = 1

	return occupancy

func _create_blended_ground(struct_img: Image, clean_img: Image, structure_mask: PackedByteArray, width: int, height: int) -> Image:
	# Start with the clean (structureless) map as base
	var result: Image = clean_img.duplicate()

	# Build a distance field from structure edges into non-structure areas
	# so we can smoothly blend the two images at boundaries
	var distance_to_structure: PackedFloat32Array
	distance_to_structure.resize(width * height)
	distance_to_structure.fill(float(blend_margin + 1))

	# First pass: mark structure pixels as distance 0, and seed the BFS
	var queue: Array[Vector2i] = []
	for y in height:
		for x in width:
			if structure_mask[y * width + x] == 1:
				distance_to_structure[y * width + x] = 0.0
				# Only seed edge pixels (pixels adjacent to non-structure)
				if _has_non_structure_neighbor(x, y, width, height, structure_mask):
					queue.append(Vector2i(x, y))

	# BFS outward from structure edges
	var visited: PackedByteArray
	visited.resize(width * height)
	visited.fill(0)
	for pos in queue:
		visited[pos.y * width + pos.x] = 1

	var directions = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

	while queue.size() > 0:
		var pos = queue.pop_front()
		var current_dist = distance_to_structure[pos.y * width + pos.x]

		if current_dist >= blend_margin:
			continue

		for dir in directions:
			var nx = pos.x + dir.x
			var ny = pos.y + dir.y
			if nx < 0 or nx >= width or ny < 0 or ny >= height:
				continue
			var nidx = ny * width + nx
			if visited[nidx]:
				continue
			if structure_mask[nidx] == 1:
				continue

			var new_dist = current_dist + 1.0
			if new_dist < distance_to_structure[nidx]:
				distance_to_structure[nidx] = new_dist
				visited[nidx] = 1
				queue.append(Vector2i(nx, ny))

	# Now blend: in the margin zone around structures, lerp between
	# the structures map and the clean map
	for y in height:
		for x in width:
			var idx = y * width + x
			var dist = distance_to_structure[idx]

			if structure_mask[idx] == 1:
				# Under a structure: use clean map (this is the underneath layer)
				continue  # result is already clean_img
			elif dist < blend_margin:
				# In the blend zone: mix the two images
				var t = dist / float(blend_margin)  # 0 at edge, 1 at full distance
				var struct_color = struct_img.get_pixel(x, y)
				var clean_color = clean_img.get_pixel(x, y)
				var blended = clean_color.lerp(struct_color, 1.0 - t)
				result.set_pixel(x, y, blended)
			# else: far from structures, keep clean_img as-is

	return result

func _has_non_structure_neighbor(x: int, y: int, width: int, height: int, mask: PackedByteArray) -> bool:
	var directions = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for dir in directions:
		var nx = x + dir.x
		var ny = y + dir.y
		if nx < 0 or nx >= width or ny < 0 or ny >= height:
			continue
		if mask[ny * width + nx] == 0:
			return true
	return false

func _generate_structures(struct_img: Image, mask_img: Image, width: int, height: int):
	var tile_size = GridManager.TILE_SIZE
	var visited: PackedByteArray
	visited.resize(width * height)
	visited.fill(0)

	for y in height:
		for x in width:
			if visited[y * width + x]:
				continue
			var color = mask_img.get_pixel(x, y)
			if color.a < 0.5:
				continue
			var structure_id = match_color_to_structure(color)
			if structure_id == "":
				continue

			var region_pixels = flood_fill(mask_img, visited, x, y, color, width, height)
			if region_pixels.size() < 16:
				continue

			var min_x = width
			var min_y = height
			var max_x = 0
			var max_y = 0
			for pixel in region_pixels:
				min_x = min(min_x, pixel.x)
				min_y = min(min_y, pixel.y)
				max_x = max(max_x, pixel.x)
				max_y = max(max_y, pixel.y)

			var region_width = max_x - min_x + 1
			var region_height = max_y - min_y + 1
			var region_rect = Rect2i(min_x, min_y, region_width, region_height)
			var region_img = struct_img.get_region(region_rect)
			var region_tex = ImageTexture.create_from_image(region_img)

			var center_x = min_x + region_width / 2.0
			var center_y = min_y + region_height / 2.0

			var struct_instance = structure_scene.instantiate()
			struct_instance.structure_id = structure_id
			struct_instance.use_custom_texture = true
			struct_instance.custom_texture = region_tex
			struct_instance.skip_grid_snap = true
			struct_instance.position = Vector2(center_x, center_y)
			struct_instance.z_index = -3
			add_child(struct_instance)

			# Register all grid tiles this structure occupies as obstacles
			var tile_min_x = int(floor(float(min_x) / tile_size))
			var tile_min_y = int(floor(float(min_y) / tile_size))
			var tile_max_x = int(floor(float(max_x) / tile_size))
			var tile_max_y = int(floor(float(max_y) / tile_size))
			var occupied: Array[Vector2i] = []
			for ty in range(tile_min_y, tile_max_y + 1):
				for tx in range(tile_min_x, tile_max_x + 1):
					var tile_pos = Vector2i(tx, ty)
					GridManager.register_obstacle(tile_pos)
					occupied.append(tile_pos)
			struct_instance.occupied_tiles = occupied

func flood_fill(mask: Image, visited: PackedByteArray, start_x: int, start_y: int, target_color: Color, width: int, height: int) -> Array[Vector2i]:
	var pixels: Array[Vector2i] = []
	var stack: Array[Vector2i] = [Vector2i(start_x, start_y)]

	while stack.size() > 0:
		var pos = stack.pop_back()
		var idx = pos.y * width + pos.x

		if pos.x < 0 or pos.x >= width or pos.y < 0 or pos.y >= height:
			continue
		if visited[idx]:
			continue

		var pixel_color = mask.get_pixel(pos.x, pos.y)
		if color_distance(pixel_color, target_color) > color_tolerance:
			continue

		visited[idx] = 1
		pixels.append(pos)

		stack.append(Vector2i(pos.x + 1, pos.y))
		stack.append(Vector2i(pos.x - 1, pos.y))
		stack.append(Vector2i(pos.x, pos.y + 1))
		stack.append(Vector2i(pos.x, pos.y - 1))

	return pixels

func match_color_to_floor(color: Color) -> String:
	var best_match := ""
	var best_dist := color_tolerance
	for key_color in color_to_floor:
		var dist = color_distance(color, key_color)
		if dist < best_dist:
			best_dist = dist
			best_match = color_to_floor[key_color]
	return best_match

func match_color_to_structure(color: Color) -> String:
	var best_match := ""
	var best_dist := color_tolerance
	for key_color in color_to_structure:
		var dist = color_distance(color, key_color)
		if dist < best_dist:
			best_dist = dist
			best_match = color_to_structure[key_color]
	return best_match

func color_distance(a: Color, b: Color) -> float:
	return sqrt(
		pow(a.r - b.r, 2) +
		pow(a.g - b.g, 2) +
		pow(a.b - b.b, 2)
	)
