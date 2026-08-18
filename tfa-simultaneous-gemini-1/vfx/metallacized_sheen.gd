extends Node2D
# Chrome shell overlay for the "metallacized" condition: a cool silver
# additive glow over the body with a slow shimmer. Rides the character via the
# condition custom_vfx pipeline; texture built in code.


func _ready() -> void:
	var grad := Gradient.new()
	grad.set_color(0, Color(0.85, 0.9, 1.0, 0.75))
	grad.set_color(1, Color(0.85, 0.9, 1.0, 0.0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 256
	tex.height = 256

	var sheen := Sprite2D.new()
	sheen.texture = tex
	sheen.scale = Vector2(0.42, 0.42)
	sheen.modulate = Color(0.8, 0.86, 0.98, 0.55)
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	sheen.material = mat
	add_child(sheen)

	var tween := create_tween().set_loops()
	tween.tween_property(sheen, "modulate:a", 0.3, 1.1)
	tween.tween_property(sheen, "modulate:a", 0.55, 1.1)
