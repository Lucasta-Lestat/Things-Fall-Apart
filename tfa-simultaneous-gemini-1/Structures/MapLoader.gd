# res://MapLoader.gd
extends Node2D

@export var map_image_path: String = "res://maps/church.png"
@export var mask_image_path: String = "res://maps/church_mask.png"
@export var tile_size: int = GridManager.TILE_SIZE/2

# Map mask colors to floor IDs from your FloorDatabase
var color_to_floor: Dictionary = {
	Color8(0, 255, 0): "grass",
	Color8(139, 69, 19): "dirt",
	Color8(128, 128, 128): "stone",
	Color8(0, 0, 255): "water",
}
var inherit_color: Color = Color8(255, 0, 255)  # Magenta = use neighbor texture

@export var color_tolerance: float = 0.15

var floor_scene: PackedScene = preload("res://Structures/floors/floor.tscn")

# Track tile data across both passes
var tile_grid: Dictionary = {}       # Vector2i -> floor_id string
var tile_textures: Dictionary = {}   # Vector2i -> ImageTexture

func _ready():
	generate_map()
# Add to MapLoader.gd

# Store placed tiles for the infill pass

func generate_map():
	var map_img: Image = load(map_image_path).get_image()
	var mask_img: Image = load(mask_image_path).get_image()

	var cols = map_img.get_width() / tile_size
	var rows = map_img.get_height() / tile_size

	# --- First pass: place all color-matched tiles ---
	for row in rows:
		for col in cols:
			var grid_pos = Vector2i(col, row)
			var px = col * tile_size
			var py = row * tile_size

			var sample_x = px + tile_size / 2
			var sample_y = py + tile_size / 2
			var mask_color = mask_img.get_pixel(sample_x, sample_y)

			var floor_id = match_color_to_floor(mask_color)
			if floor_id == "":
				continue

			var tile_rect = Rect2i(px, py, tile_size, tile_size)
			var tile_img = map_img.get_region(tile_rect)
			var tile_tex = ImageTexture.create_from_image(tile_img)

			tile_grid[grid_pos] = {
				"floor_id": floor_id,
				"texture": tile_tex
			}

			_spawn_floor(floor_id, tile_tex, px, py)

	# --- Second pass: infill gaps from neighbors ---
	infill_gaps(cols, rows)

func infill_gaps(cols: int, rows: int):
	var directions = [
		Vector2i(-1, 0), Vector2i(1, 0),
		Vector2i(0, -1), Vector2i(0, 1),
		Vector2i(-1, -1), Vector2i(1, -1),
		Vector2i(-1, 1), Vector2i(1, 1),
	]

	# Collect all gaps first, then fill (so we don't use freshly-filled
	# tiles as sources, which could propagate weirdness)
	var gaps_to_fill: Array[Vector2i] = []
	for row in rows:
		for col in cols:
			var pos = Vector2i(col, row)
			if pos not in tile_grid:
				gaps_to_fill.append(pos)

	# Multiple iterations handle gaps that are far from any placed tile.
	# Each pass can fill gaps adjacent to previously-filled ones.
	var max_iterations = 10
	for iteration in max_iterations:
		if gaps_to_fill.is_empty():
			break

		var still_unfilled: Array[Vector2i] = []
		var newly_filled: Dictionary = {}

		for gap_pos in gaps_to_fill:
			var neighbor_tiles: Array[Dictionary] = []

			for dir in directions:
				var neighbor = gap_pos + dir
				if neighbor in tile_grid:
					neighbor_tiles.append(tile_grid[neighbor])

			if neighbor_tiles.is_empty():
				still_unfilled.append(gap_pos)
				continue

			# Pick the most common floor type among neighbors
			var type_counts: Dictionary = {}
			for t in neighbor_tiles:
				var fid = t["floor_id"]
				type_counts[fid] = type_counts.get(fid, 0) + 1

			var best_id = ""
			var best_count = 0
			for fid in type_counts:
				if type_counts[fid] > best_count:
					best_count = type_counts[fid]
					best_id = fid

			# Grab a random texture from matching neighbors
			var matching: Array[ImageTexture] = []
			for t in neighbor_tiles:
				if t["floor_id"] == best_id:
					matching.append(t["texture"])

			var chosen_tex = matching.pick_random()

			var px = gap_pos.x * tile_size
			var py = gap_pos.y * tile_size

			newly_filled[gap_pos] = {
				"floor_id": best_id,
				"texture": chosen_tex
			}

			_spawn_floor(best_id, chosen_tex, px, py)

		# Merge newly filled into the grid for next iteration
		tile_grid.merge(newly_filled)
		gaps_to_fill = still_unfilled

func _spawn_floor(floor_id: String, tex: ImageTexture, px: int, py: int):
	var floor_instance = floor_scene.instantiate()
	floor_instance.floor_id = floor_id
	floor_instance.position = Vector2(px + tile_size / 2, py + tile_size / 2)
	add_child(floor_instance)
	floor_instance.call_deferred("_set_custom_texture", tex)

func fill_inherit_tiles(inherit_tiles: Array[Vector2i]):
	var offsets = [
		Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1),
		Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)
	]

	for pos in inherit_tiles:
		var neighbor_type = get_majority_neighbor_type(pos, offsets)
		if neighbor_type == "":
			continue

		# Gather neighbor textures matching the dominant type
		var matching_textures: Array[ImageTexture] = []
		for offset in offsets:
			var neighbor = pos + offset
			if tile_grid.has(neighbor) and tile_grid[neighbor] == neighbor_type:
				if tile_textures.has(neighbor):
					matching_textures.append(tile_textures[neighbor])

		if matching_textures.is_empty():
			continue

		# Blend two random neighbors, or use the one available
		var blended_tex: ImageTexture
		if matching_textures.size() >= 2:
			matching_textures.shuffle()
			blended_tex = blend_two_textures(
				matching_textures[0], matching_textures[1], randf_range(0.3, 0.7)
			)
		else:
			blended_tex = matching_textures[0]

		# Store so later inherit tiles can reference this one as a neighbor
		tile_grid[pos] = neighbor_type
		tile_textures[pos] = blended_tex

		var floor_instance = floor_scene.instantiate()
		floor_instance.floor_id = neighbor_type
		floor_instance.position = Vector2(
			pos.x * tile_size + tile_size / 2,
			pos.y * tile_size + tile_size / 2
		)
		add_child(floor_instance)
		floor_instance.call_deferred("_set_custom_texture", blended_tex)

func get_majority_neighbor_type(pos: Vector2i, offsets: Array) -> String:
	var counts: Dictionary = {}
	for offset in offsets:
		var neighbor = pos + offset
		if tile_grid.has(neighbor):
			var ftype = tile_grid[neighbor]
			counts[ftype] = counts.get(ftype, 0) + 1

	var best = ""
	var best_count = 0
	for ftype in counts:
		if counts[ftype] > best_count:
			best_count = counts[ftype]
			best = ftype
	return best

func match_color_to_floor(color: Color) -> String:
	var best_match := ""
	var best_dist := color_tolerance

	for key_color in color_to_floor:
		var dist = color_distance(color, key_color)
		if dist < best_dist:
			best_dist = dist
			best_match = color_to_floor[key_color]

	return best_match

func color_distance(a: Color, b: Color) -> float:
	return sqrt(
		pow(a.r - b.r, 2) +
		pow(a.g - b.g, 2) +
		pow(a.b - b.b, 2)
	)

func blend_two_textures(tex_a: ImageTexture, tex_b: ImageTexture, weight: float) -> ImageTexture:
	var img_a: Image = tex_a.get_image()
	var img_b: Image = tex_b.get_image()
	var width = img_a.get_width()
	var height = img_a.get_height()

	# Random flip/rotation to break up repetition
	if randi() % 2 == 0:
		img_b.flip_x()
	if randi() % 2 == 0:
		img_b.flip_y()

	var result = Image.create(width, height, false, img_a.get_format())

	for y in height:
		for x in width:
			var color_a = img_a.get_pixel(x, y)
			var color_b = img_b.get_pixel(x, y)
			result.set_pixel(x, y, color_a.lerp(color_b, weight))

	return ImageTexture.create_from_image(result)
