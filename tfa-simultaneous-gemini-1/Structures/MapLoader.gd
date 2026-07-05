# res://MapLoader.gd
extends Node2D

signal map_loaded

@export var map_image_path: String = "res://Maps/cemetery.png"
@export var mask_image_path: String = "res://Maps/cemetery_mask.png"
@export var structure_map_image_path: String = "res://maps/cemetery_structures.png"
@export var structure_mask_path: String = "res://maps/cemetery_structures_mask.png"
@export var blend_margin: int = 16  # pixels of blending around structure edges

# When true, generate_map() skips the structure pass entirely and uses the
# world-map terrain palette (plains/forest/mountain/water/city/farm). Mountains
# are registered as impassable obstacles directly with GridManager.
@export var world_map_mode: bool = false

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
	Color8(192, 192, 192): "stone_stairs",   # light gray
}

# World-map terrain palette. The mask PNG should use these exact RGB values
# (anti-aliased pixels within color_tolerance still match):
#   (170, 220,  90) light green -> world_plains
#   ( 20, 100,  30) deep green  -> world_forest
#   (110,  85,  60) brown/gray  -> world_mountain
#   ( 40,  90, 200) blue        -> world_water
#   (220,  60,  40) red         -> world_city
#   (210, 180,  90) golden tan  -> world_farm
var color_to_world_floor: Dictionary = {
	Color8(170, 220, 90): "world_plains",
	Color8(20, 100, 30): "world_forest",
	Color8(110, 85, 60): "world_mountain",
	Color8(40, 90, 200): "world_water",
	Color8(220, 60, 40): "world_city",
	Color8(210, 180, 90): "world_farm",
}

# How close a pixel color must be to a key to match (accounts for anti-aliasing)
@export var color_tolerance: float = 0.15

var floor_scene: PackedScene = preload("res://Structures/floors/floor.tscn")

func _ready():
	# Don't auto-generate; Game.load_map() calls generate_map() after GridManager is initialized
	pass


# ---------------------------------------------------------------------------
# STRUCTURED FORMAT (procedural level-editor exports; "format": "structured"
# in Maps.json). The 4-PNG mask pipeline above exists for hand/LLM-made map
# images; procedural maps ship real data instead:
#   images.map          ONE finished ground PNG -- becomes a single full-map
#                       sprite (no per-tile floor sprites, no blended
#                       underlay: destroying a structure reveals this image)
#   images.structures   alpha overlay holding ONLY the structure art; each
#                       instance displays its own geometry-exact slice of it
#   floors              per-tile type codes (rows of chars, see FLOOR_CODES)
#                       -> logical GridManager floors (fire/pathing/audio)
#   structures          INSTANCE GEOMETRY: wall segments, tree circles, door
#                       leaves -- each becomes a Structure.tscn instance with
#                       an EXACT (rotated) collision shape and per-instance
#                       health, so the gap between two buildings is exactly
#                       as walkable as it looks. Pathing obstacles register
#                       only for tiles whose centre the geometry truly covers
#                       (the flood-fill loader's bounding boxes sealed gaps).
# ---------------------------------------------------------------------------

const FLOOR_CODES := {"g": "grass", "d": "floor_dirt", "s": "floor_stone", "w": "shallow_water"}

# GridManager.register_floor only reads .floor_id/.walkability; floors on
# structured maps are logical-only (their art is baked into the ground PNG).
class FloorStub:
	extends RefCounted
	var floor_id: String = ""
	var walkability: float = 1.0


func generate_structured_map(map_data: Dictionary) -> void:
	# MapLoader is Game's direct child (same resolution the legacy path uses);
	# the "game" group has no members, so a group lookup would silently return
	# null and kill fire/targeting/loot for every structure on the map
	var game = get_parent()
	if game == null or not ("structures_in_scene" in game):
		game = get_tree().current_scene
	var images: Dictionary = map_data.get("images", {})
	var tile_size: int = GridManager.TILE_SIZE

	# 1. ground: the finished editor render as one sprite
	var ground_path := String(images.get("map", ""))
	if ground_path != "" and ResourceLoader.exists(ground_path):
		var ground := Sprite2D.new()
		ground.texture = load(ground_path)
		ground.centered = false
		ground.z_index = -6
		add_child(ground)
	else:
		push_error("structured map: missing ground image " + ground_path)

	# 2. floors: logical registration from per-tile codes
	var rows: Array = map_data.get("floors", [])
	for ty in rows.size():
		var row := String(rows[ty])
		for tx in row.length():
			var fid := String(FLOOR_CODES.get(row[tx], ""))
			if fid == "":
				continue
			var stub := FloorStub.new()
			stub.floor_id = fid
			var fdata = FloorDatabase.floor_definitions.get(fid)
			if fdata != null and "walkability" in fdata:
				stub.walkability = maxf(0.05, float(fdata.walkability))
			GridManager.register_floor(Vector2i(tx, ty), stub)

	# 3. structures: geometry instances with exact collision
	var overlay_tex: Texture2D = null
	var op := String(images.get("structures", ""))
	if op != "" and ResourceLoader.exists(op):
		overlay_tex = load(op)
	if game != null and "structures_in_scene" in game:
		game.structures_in_scene.clear()
	for s in map_data.get("structures", []):
		if typeof(s) != TYPE_DICTIONARY:
			continue
		var inst := _spawn_geo_structure(s, overlay_tex, tile_size)
		if inst != null and game != null and "structures_in_scene" in game:
			game.structures_in_scene.append(inst)
			if inst.has_signal("destroyed") and game.has_method("_on_structure_destroyed"):
				inst.destroyed.connect(game._on_structure_destroyed)

	emit_signal("map_loaded")


func _spawn_geo_structure(s: Dictionary, overlay_tex: Texture2D, tile_size: int) -> Structure:
	var kind := String(s.get("kind", ""))
	var center: Vector2
	var shape: Shape2D
	var shape_rot := 0.0
	var poly_local := PackedVector2Array()
	var occupied: Array[Vector2i] = []
	# pathing margin: a tile registers as an obstacle only if its CENTRE is
	# within this reach of the actual geometry (about a body-width)
	var path_margin := float(tile_size) * 0.35

	if kind == "wall":
		var a := _arr_v2(s.get("a", [0, 0]))
		var b := _arr_v2(s.get("b", [0, 0]))
		var half := float(s.get("half", 5.0))
		var seg := b - a
		if seg.length() < 2.0:
			return null
		center = (a + b) * 0.5
		var rect := RectangleShape2D.new()
		rect.size = Vector2(seg.length(), half * 2.0)
		shape = rect
		shape_rot = seg.angle()
		var dirn := seg.normalized()
		var perp := dirn.orthogonal()
		# generous art overgrow: wall ART extends past the collision geometry
		# (bevelled caps, castle BATTLEMENT merlons on tower rims) -- clipping
		# the slice at the quad leaves see-through notches where the ground
		# shows. Overlapping neighbour slices draw identical overlay pixels, so
		# the overlap is invisible.
		var g := half + 12.0
		poly_local = PackedVector2Array([
			-seg * 0.5 - dirn * g - perp * (half + g), seg * 0.5 + dirn * g - perp * (half + g),
			seg * 0.5 + dirn * g + perp * (half + g), -seg * 0.5 - dirn * g + perp * (half + g)])
		occupied = _tiles_near_segment(a, b, half + path_margin, tile_size)
	elif kind == "tree":
		center = _arr_v2(s.get("pos", [0, 0]))
		var r := float(s.get("r", 30.0))
		var circ := CircleShape2D.new()
		circ.radius = maxf(6.0, r * 0.45)   # trunk-scale: canopy overhang stays walkable
		shape = circ
		var rr := r + 4.0
		poly_local = PackedVector2Array([
			Vector2(-rr, -rr), Vector2(rr, -rr), Vector2(rr, rr), Vector2(-rr, rr)])
		occupied = _tiles_near_segment(center, center, circ.radius + path_margin, tile_size)
	elif kind == "door":
		var hinge := _arr_v2(s.get("hinge", [0, 0]))
		var deg := float(s.get("deg", 0.0))
		var width := float(s.get("width", 30.0))
		var dhalf := float(s.get("half", 5.0))
		var leaf := Vector2.RIGHT.rotated(deg_to_rad(deg)) * width
		center = hinge + leaf * 0.5
		var drect := RectangleShape2D.new()
		drect.size = Vector2(width, dhalf * 2.0)
		shape = drect
		shape_rot = leaf.angle()
		var ddir := leaf.normalized()
		var dperp := ddir.orthogonal()
		poly_local = PackedVector2Array([
			-leaf * 0.5 - dperp * (dhalf + 2.0), leaf * 0.5 - dperp * (dhalf + 2.0),
			leaf * 0.5 + dperp * (dhalf + 2.0), -leaf * 0.5 + dperp * (dhalf + 2.0)])
		occupied = _tiles_near_segment(hinge, hinge + leaf, dhalf + path_margin, tile_size)
	else:
		return null

	var inst: Structure = structure_scene.instantiate()
	inst.structure_id = StringName(String(s.get("id", "stone_wall")))
	inst.skip_grid_snap = true
	inst.use_custom_texture = true
	inst.custom_texture = _blank_tex()   # the Sprite stays hidden; Art draws instead
	inst.custom_size = Vector2(8, 8)
	inst.position = center
	inst.z_index = -3
	inst.occupied_tiles = occupied
	add_child(inst)
	# EXACT collision: rotated to the real geometry (the legacy loader's
	# axis-aligned region bounding boxes are what sealed walkable gaps)
	var cs: CollisionShape2D = inst.get_node("CollisionShape2D")
	cs.shape = shape
	cs.rotation = shape_rot
	inst.get_node("Sprite").visible = false
	if overlay_tex != null:
		var art := Polygon2D.new()
		art.name = "Art"
		art.texture = overlay_tex
		art.polygon = poly_local
		var uvs := PackedVector2Array()
		for p in poly_local:
			uvs.append(p + center)   # overlay covers the whole map 1:1 in pixels
		art.uv = uvs
		# the overlay was rendered onto a transparent viewport, so its edge
		# pixels carry PREMULTIPLIED alpha -- straight-alpha blending would draw
		# dark fringes around every wall/crown edge
		var pm := CanvasItemMaterial.new()
		pm.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
		art.material = pm
		inst.add_child(art)
	# per-instance health: the editor scales wall hp by run length
	if s.has("hp"):
		inst.max_health = int(s["hp"])
		inst.current_health = inst.max_health
	for t in occupied:
		GridManager.register_obstacle(t)
	return inst


# Tiles whose CENTRE lies within `reach` of segment ab (a == b -> a disc).
func _tiles_near_segment(a: Vector2, b: Vector2, reach: float, tile_size: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var lo := Vector2(minf(a.x, b.x) - reach, minf(a.y, b.y) - reach)
	var hi := Vector2(maxf(a.x, b.x) + reach, maxf(a.y, b.y) + reach)
	var t0 := Vector2i(int(floor(lo.x / tile_size)), int(floor(lo.y / tile_size)))
	var t1 := Vector2i(int(floor(hi.x / tile_size)), int(floor(hi.y / tile_size)))
	var ab := b - a
	var l2 := ab.length_squared()
	for ty in range(t0.y, t1.y + 1):
		for tx in range(t0.x, t1.x + 1):
			var c := Vector2((tx + 0.5) * tile_size, (ty + 0.5) * tile_size)
			var q := a
			if l2 > 0.0001:
				q = a + ab * clampf((c - a).dot(ab) / l2, 0.0, 1.0)
			if c.distance_to(q) <= reach and GridManager.map_rect.has_point(Vector2i(tx, ty)):
				out.append(Vector2i(tx, ty))
	return out


func _arr_v2(v) -> Vector2:
	if typeof(v) == TYPE_ARRAY and v.size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.ZERO


var _blank: ImageTexture

func _blank_tex() -> ImageTexture:
	if _blank == null:
		var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		_blank = ImageTexture.create_from_image(img)
	return _blank

func generate_map():
	if world_map_mode:
		_generate_world_map()
		return

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
			struct_instance.custom_size = Vector2(region_width, region_height)
			struct_instance.skip_grid_snap = true
			struct_instance.position = Vector2(center_x, center_y)
			struct_instance.z_index = -3
			add_child(struct_instance)

			# Register with Game's structures_in_scene for fire/combat awareness
			var game = get_parent()
			if game and "structures_in_scene" in game:
				game.structures_in_scene.append(struct_instance)
				if struct_instance.has_signal("destroyed") and game.has_method("_on_structure_destroyed"):
					struct_instance.destroyed.connect(game._on_structure_destroyed)

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

# ---------------------------------------------------------------------------
# World-map generation
# ---------------------------------------------------------------------------
# The world-map pipeline skips structures entirely. Tile texture is sampled
# from the source map image. The mask defines terrain type per tile;
# world_mountain tiles register as impassable with GridManager. Unmapped
# terrain (alpha 0) falls back to world_plains so a fresh authoring pass
# doesn't leave gaps. If the mask file is missing the loader still renders
# the source image as a flat plain.
func _generate_world_map():
	var tile_size = GridManager.TILE_SIZE
	if not ResourceLoader.exists(map_image_path):
		push_error("[MapLoader] World map source image not found: %s" % map_image_path)
		return
	var clean_map_img: Image = load(map_image_path).get_image()
	var map_width: int = clean_map_img.get_width()
	var map_height: int = clean_map_img.get_height()

	var has_mask: bool = ResourceLoader.exists(mask_image_path)
	var mask_img: Image
	if has_mask:
		mask_img = load(mask_image_path).get_image()
	else:
		push_warning("[MapLoader] World-map mask missing (%s) — defaulting all tiles to world_plains." % mask_image_path)

	var cols: int = map_width / tile_size
	var rows: int = map_height / tile_size

	for row in rows:
		for col in cols:
			var px = col * tile_size
			var py = row * tile_size
			var sample_x = px + tile_size / 2
			var sample_y = py + tile_size / 2

			var floor_id: String = "world_plains"
			if has_mask and sample_x < mask_img.get_width() and sample_y < mask_img.get_height():
				var mask_color: Color = mask_img.get_pixel(sample_x, sample_y)
				if mask_color.a >= 0.5:
					var matched := _match_world_floor(mask_color)
					if matched != "":
						floor_id = matched

			var tile_rect = Rect2i(px, py, tile_size, tile_size)
			var tile_img = clean_map_img.get_region(tile_rect)
			var tile_tex = ImageTexture.create_from_image(tile_img)

			var floor_instance = floor_scene.instantiate()
			floor_instance.floor_id = floor_id
			floor_instance.use_custom_texture = true
			floor_instance.custom_texture = tile_tex
			floor_instance.skip_grid_snap = true
			floor_instance.position = Vector2(px + tile_size / 2, py + tile_size / 2)
			floor_instance.z_index = -4
			add_child(floor_instance)

			var tile_pos = Vector2i(col, row)
			GridManager.register_floor(tile_pos, floor_instance)

			# Mountains are impassable: register as obstacle so pathfinding
			# avoids them and characters can't move through them.
			if floor_id == "world_mountain":
				GridManager.register_obstacle(tile_pos)

	emit_signal("map_loaded")

func _match_world_floor(color: Color) -> String:
	var best_match := ""
	var best_dist := color_tolerance
	for key_color in color_to_world_floor:
		var dist = color_distance(color, key_color)
		if dist < best_dist:
			best_dist = dist
			best_match = color_to_world_floor[key_color]
	return best_match
