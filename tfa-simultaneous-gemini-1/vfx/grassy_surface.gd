extends Node2D

@onready var sprite: Sprite2D = $Sprite

func play(size_scale: float = 1.0):
	if not sprite:
		return

	var tile_size = GridManager.TILE_SIZE
	var img = Image.create(tile_size, tile_size, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	sprite.texture = ImageTexture.create_from_image(img)

	if size_scale != 1.0:
		sprite.scale = Vector2(size_scale, size_scale)

	if sprite.material is ShaderMaterial:
		sprite.material = sprite.material.duplicate()
