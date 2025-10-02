# VFXEffectNode.gd
extends Node2D

var color_rect: ColorRect
var light: PointLight2D
var size: Vector2
var shape: String
var effect_material: ShaderMaterial

func _ready():
	# Create ColorRect for shader display
	color_rect = ColorRect.new()
	color_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(color_rect)
	
	# Set default size
	size = Vector2(100, 100)
	_update_rect_size()

func setup_effect(material: ShaderMaterial, effect_size: Vector2, effect_shape: String):
	size = effect_size
	shape = effect_shape
	effect_material = material
	
	if color_rect:
		# Make sure the ColorRect is visible and properly sized first
		_update_rect_size()
		color_rect.material = material
		color_rect.visible = true
		
		# Debug info
		print("Setting up effect - Size: ", effect_size, " Shape: ", effect_shape)
		if material and material.shader:
			print("Shader applied successfully for shape: ", effect_shape)
			print("Shader code length: ", material.shader.code.length())
		else:
			push_error("Failed to apply shader material!")

func add_light(color: Color, energy: float, radius: float, texture: Texture2D):
	if not light:
		light = PointLight2D.new()
		add_child(light)
	
	light.color = color
	light.energy = energy
	light.texture = texture
	light.texture_scale = radius / 256.0  # Texture is 256x256
	light.position = Vector2.ZERO  # Light should be centered at node position
	light.visible = true

func _update_rect_size():
	if color_rect:
		color_rect.size = size
		color_rect.position = -size / 2.0  # Center the rect
		print("ColorRect updated - Size: ", size, " Position: ", color_rect.position)

func cleanup():
	if color_rect and color_rect.material:
		color_rect.material = null
	if light:
		light.queue_free()
		light = null

func set_param(param_name: String, value):
	if effect_material:
		effect_material.set_shader_parameter(param_name, value)
		print("Set shader parameter: ", param_name, " = ", value)
