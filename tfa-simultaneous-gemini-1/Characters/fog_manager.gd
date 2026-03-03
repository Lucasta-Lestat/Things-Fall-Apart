class_name FogManager
extends Node2D

var _active_fogs: Array[FogOverlay] = []


func create_fog(data: FogData, world_position: Vector2 = Vector2.ZERO) -> FogOverlay:
	var overlay := FogOverlay.new()
	add_child(overlay)
	overlay.apply_data(data)
	overlay.position = world_position - data.size * 0.5
	_active_fogs.append(overlay)
	return overlay


func create_fog_from_params(
	color: Color,
	fog_size: Vector2,
	density: float = 0.5,
	scale: float = 4.0,
	speed: Vector2 = Vector2(0.02, 0.01),
	world_position: Vector2 = Vector2.ZERO
) -> FogOverlay:
	var data := FogData.new()
	data.color = color
	data.size = fog_size
	data.density = density
	data.scale = scale
	data.speed = speed
	return create_fog(data, world_position)


func remove_fog(overlay: FogOverlay) -> void:
	_active_fogs.erase(overlay)
	overlay.queue_free()


func clear_all_fog() -> void:
	for fog in _active_fogs:
		fog.queue_free()
	_active_fogs.clear()
