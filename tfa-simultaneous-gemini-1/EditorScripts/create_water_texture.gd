@tool
extends EditorScript

# This script creates a simple blue water texture
# Run it once in the Godot editor with File -> Run

func _run():
	var img = Image.create(GridManager.TILE_SIZE, GridManager.TILE_SIZE, false, Image.FORMAT_RGBA8)
	
	# Fill with blue color
	for x in range(GridManager.TILE_SIZE):
		for y in range(GridManager.TILE_SIZE):
			# Create a simple blue texture with slight variation
			var red_value = 0.6 + (randf() * 0.1)
			var color = Color(0.3, red_value,0.3 , 1.0)
			img.set_pixel(x, y, color)
	
	# Save the image
	img.save_png("res://acid_texture.png")
	print("Blood texture created at res://acid_texture.png")
