class_name FogOverlay
extends ColorRect

var _shader_material: ShaderMaterial


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shader_material = ShaderMaterial.new()
	_shader_material.shader = preload("res://vfx/shaders/fog.gdshader")
	material = _shader_material


func apply_data(data: FogData) -> void:
	custom_minimum_size = data.size
	size = data.size
	# Center the fog on the node's position
	pivot_offset = data.size * 0.5

	_shader_material.set_shader_parameter("fog_color", data.color)
	_shader_material.set_shader_parameter("density", data.density)
	_shader_material.set_shader_parameter("scale", data.scale)
	_shader_material.set_shader_parameter("speed", data.speed)
