extends Node2D
# Glowing brand for the "illuminated" condition: a warm PointLight2D plus a
# small additive spark, pulsing gently. Textures are built in code —
# PointLight2D renders nothing without one, and no shared glow asset exists.


func _make_radial(inner: Color, outer: Color) -> GradientTexture2D:
	var grad := Gradient.new()
	grad.set_color(0, inner)
	grad.set_color(1, outer)
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 256
	tex.height = 256
	return tex


func _ready() -> void:
	var tex := _make_radial(Color(1.0, 0.9, 0.6, 1.0), Color(1.0, 0.9, 0.6, 0.0))
	var light := PointLight2D.new()
	light.texture = tex
	light.energy = 0.9
	light.texture_scale = 0.55
	light.range_item_cull_mask = 1
	add_child(light)

	var spark := Sprite2D.new()
	spark.texture = tex
	spark.scale = Vector2(0.16, 0.16)
	spark.modulate = Color(1.0, 0.85, 0.45, 0.9)
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	spark.material = mat
	add_child(spark)

	var tween := create_tween().set_loops()
	tween.tween_property(light, "energy", 0.6, 0.8)
	tween.tween_property(light, "energy", 0.9, 0.8)
