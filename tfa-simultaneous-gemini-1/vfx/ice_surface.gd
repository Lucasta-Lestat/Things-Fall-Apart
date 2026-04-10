extends Node2D

@onready var sprite: Sprite2D = $Sprite

func play(size_scale: float = 1.0):
	if not sprite:
		return

	# Create a white texture for the shader to colorize, sized to one tile
	var tile_size = GridManager.TILE_SIZE
	var img = Image.create(tile_size, tile_size, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	sprite.texture = ImageTexture.create_from_image(img)

	# Scale if needed
	if size_scale != 1.0:
		sprite.scale = Vector2(size_scale, size_scale)

	# Duplicate material to avoid shared resource mutation
	if sprite.material is ShaderMaterial:
		sprite.material = sprite.material.duplicate()
