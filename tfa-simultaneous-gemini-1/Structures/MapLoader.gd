# res://MapLoader.gd
extends Node2D

@export var map_image_path: String = "res://Maps/cemetery.png"
@export var mask_image_path: String = "res://Maps/cemetery_mask.png"
@export var tile_size: int = 64

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
	generate_map()

func generate_map():
	var map_img: Image = load(map_image_path).get_image()
	var mask_img: Image = load(mask_image_path).get_image()

	var map_width = map_img.get_width()
	var map_height = map_img.get_height()

	# How many tiles fit in the image
	var cols = map_width / tile_size
	var rows = map_height / tile_size
	print("MapLoader: rows, cols: ", rows, " ", cols)
	for row in rows:
		for col in cols:
			var px = col * tile_size
			var py = row * tile_size

			# Sample the mask at the center of this tile
			var sample_x = px + tile_size / 2
			var sample_y = py + tile_size / 2
			var mask_color = mask_img.get_pixel(sample_x, sample_y)
			print("mask_color: ", mask_color, "vs green in dict: (0,255,0)",  )
			var floor_id = match_color_to_floor(mask_color)
			print("floor_id: ", floor_id)
			if floor_id == "":
				continue  # No mapping — skip (or use a default)

			# Crop this tile's texture from the source image
			var tile_rect = Rect2i(px, py, tile_size, tile_size)
			print("tile_rect: ", tile_rect)
			var tile_img = map_img.get_region(tile_rect)
			print("tile_img ", tile_img)
			var tile_tex = ImageTexture.create_from_image(tile_img)
			print(tile_tex)
			# Instantiate the floor
			var floor_instance = floor_scene.instantiate()
			floor_instance.floor_id = floor_id
			floor_instance.use_custom_texture = true
			floor_instance.custom_texture = tile_tex
			floor_instance.skip_grid_snap = true
			floor_instance.position = Vector2(px + tile_size / 2, py + tile_size / 2)
			# Replace the instantiation block temporarily:
			#var test_sprite = Sprite2D.new()
			#test_sprite.texture = tile_tex
			#test_sprite.position = Vector2(px + tile_size / 2, py + tile_size / 2)
			#add_child(test_sprite)
			add_child(floor_instance)
			


			# Override the texture after the floor's _ready sets it from the database
			# We use call_deferred so it runs after _ready
			floor_instance.call_deferred("_set_custom_texture", tile_tex)
	print("MapLoader position: ", global_position)
	print("Children count: ", get_child_count())
	print("First child pos: ", get_child(0).global_position if get_child_count() > 0 else "none")

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
	# Euclidean distance in RGB space, ignoring alpha
	return sqrt(
		pow(a.r - b.r, 2) +
		pow(a.g - b.g, 2) +
		pow(a.b - b.b, 2)
	)
