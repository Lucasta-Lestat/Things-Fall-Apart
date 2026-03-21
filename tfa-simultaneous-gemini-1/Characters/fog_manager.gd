class_name FogManager
extends Node2D

var _active_fogs: Array[FogOverlay] = []

func create_fog(data: FogData, world_position: Vector2 = Vector2.ZERO) -> FogOverlay:
	var overlay := FogOverlay.new()
	add_child(overlay)
	overlay.apply_data(data)
	overlay.position = world_position - data.size * 0.5
	overlay.fog_expired.connect(_on_fog_expired)
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

func create_cloud(
	color: Color,
	fog_size: Vector2,
	duration: float,
	condition_id: String = "",
	condition_stacks: int = 1,
	condition_duration_override: float = -2.0,
	apply_interval: float = 1.0,
	density: float = 0.6,
	fog_scale: float = 4.0,
	speed: Vector2 = Vector2(0.02, 0.01),
	world_position: Vector2 = Vector2.ZERO,
	source: Node = null
) -> FogOverlay:
	var data := FogData.new()
	data.color = color
	data.size = fog_size
	data.density = density
	data.scale = fog_scale
	data.speed = speed

	var overlay = create_fog(data, world_position)
	overlay.duration = duration
	overlay.condition_id = condition_id
	overlay.condition_stacks = condition_stacks
	overlay.condition_duration_override = condition_duration_override
	overlay.apply_interval = apply_interval
	overlay.source = source
	return overlay
	
func update_fogs(delta: float, characters: Array) -> void:
	"""Called from main scene _process to tick all active fogs"""
	# Iterate a copy since fogs may expire and remove themselves
	for fog in _active_fogs.duplicate():
		if is_instance_valid(fog):
			fog.update(delta, characters)

func _on_fog_expired(fog: FogOverlay) -> void:
	remove_fog(fog)

func remove_fog(overlay: FogOverlay) -> void:
	_active_fogs.erase(overlay)
	if is_instance_valid(overlay):
		overlay.queue_free()

func clear_all_fog() -> void:
	for fog in _active_fogs:
		if is_instance_valid(fog):
			fog.queue_free()
	_active_fogs.clear()
