class_name FogManager
extends Node2D

var _active_fogs: Array[FogOverlay] = []
var _fog_db: Dictionary = {}

func _ready() -> void:
	_load_fog_database()

func _load_fog_database() -> void:
	var file_path = "res://data/fogs.json"
	if not FileAccess.file_exists(file_path):
		push_error("FogManager: fogs.json not found at " + file_path)
		return
	var file = FileAccess.open(file_path, FileAccess.READ)
	var json = JSON.new()
	if json.parse(file.get_as_text()) == OK:
		_fog_db = json.get_data().get("fogs", {})
	else:
		push_error("FogManager: Failed to parse fogs.json")

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
	
## Creates one or more fog overlays from a named fog_id defined in fogs.json.
## For fogs with multiple conditions (e.g. zip_smoke), each condition gets its
## own overlay; only the first overlay carries the visual — extras are transparent.
## Returns all created overlays.
func create_fog_from_id(fog_id: String, world_position: Vector2 = Vector2.ZERO, duration: float = -1.0, source: Node = null) -> Array:
	if not _fog_db.has(fog_id):
		push_error("FogManager: Unknown fog_id '%s'" % fog_id)
		return []

	var entry: Dictionary = _fog_db[fog_id]
	var data := _fog_data_from_entry(entry)
	var conditions: Array = entry.get("conditions", [])
	var overlays: Array = []

	if conditions.is_empty():
		var overlay = create_fog(data, world_position)
		overlay.duration = duration
		overlay.source = source
		overlays.append(overlay)
	else:
		var first := true
		for condition_id in conditions:
			var overlay_data := data if first else _make_invisible_data(data.size)
			var overlay = create_fog(overlay_data, world_position)
			overlay.duration = duration
			overlay.condition_id = condition_id
			overlay.source = source
			overlays.append(overlay)
			first = false

	return overlays

func _fog_data_from_entry(entry: Dictionary) -> FogData:
	var data := FogData.new()
	var c: Array = entry.get("color", [0.7, 0.75, 0.8, 0.4])
	data.color = Color(c[0], c[1], c[2], c[3])
	var s: Array = entry.get("size", [1920, 1080])
	data.size = Vector2(s[0], s[1])
	data.density = entry.get("density", 0.5)
	data.scale = entry.get("noise_scale", 5.0)
	var sp: Array = entry.get("speed", [0.02, 0.01])
	data.speed = Vector2(sp[0], sp[1])
	data.falloff_radius = minf(float(entry.get("falloff_radius", 1.0)), 1.0)
	data.falloff_softness = float(entry.get("falloff_softness", 0.5))
	data.edge_wobble = float(entry.get("edge_wobble", 0.35))
	return data

func _make_invisible_data(fog_size: Vector2) -> FogData:
	var data := FogData.new()
	data.size = fog_size
	data.color = Color(0.0, 0.0, 0.0, 0.0)
	data.density = 0.0
	return data

# Vision through fog: sight multiplier = 1 - FOG_SIGHT_FACTOR * density, never
# below FOG_MIN_SIGHT_MULT (thick fog 0.8 -> x0.4; smoke 0.7 -> x0.475).
const FOG_SIGHT_FACTOR := 0.75
const FOG_MIN_SIGHT_MULT := 0.25

## Sight multiplier at a world point from the densest fog or cloud covering it
## (FogOverlay.get_vision_density_at). 1.0 where there is none.
func get_sight_multiplier_at(world_pos: Vector2) -> float:
	var d: float = 0.0
	for fog in _active_fogs:
		if is_instance_valid(fog):
			d = maxf(d, fog.get_vision_density_at(world_pos))
	if d <= 0.0:
		return 1.0
	return clampf(1.0 - FOG_SIGHT_FACTOR * d, FOG_MIN_SIGHT_MULT, 1.0)

# A map-wide fog's rect overshoots the map by this factor so its faded rim
# (and the rect edge) falls outside the map: the map corners sit at 0.88 of
# the silhouette radius, inside its dense body.
const MAP_FOG_OVERSIZE := 1.6

## Creates a Maps.json ambient fog covering the whole map (map_px in pixels,
## top-left at origin_px): an even, unwobbled body centred on the map, its
## noise stretched so the blobs keep the authored pixel size. Returns the
## overlays, as create_fog_from_id.
func create_map_fog(fog_id: String, map_px: Vector2, origin_px: Vector2 = Vector2.ZERO) -> Array:
	if map_px.x <= 0.0 or map_px.y <= 0.0:
		return create_fog_from_id(fog_id, origin_px)
	if not _fog_db.has(fog_id):
		push_error("FogManager: Unknown fog_id '%s'" % fog_id)
		return []
	var entry: Dictionary = _fog_db[fog_id]
	var data := _fog_data_from_entry(entry)
	var authored_w: float = float(entry.get("size", [1920, 1080])[0])
	data.size = map_px * MAP_FOG_OVERSIZE
	data.falloff_radius = 1.0
	data.falloff_softness = 0.1
	data.edge_wobble = 0.0
	if authored_w > 0.0:
		data.scale = data.scale * data.size.x / authored_w
	var centre: Vector2 = origin_px + map_px * 0.5
	var overlays: Array = []
	var conditions: Array = entry.get("conditions", [])
	if conditions.is_empty():
		overlays.append(create_fog(data, centre))
	else:
		var first := true
		for condition_id in conditions:
			var overlay = create_fog(data if first else _make_invisible_data(data.size), centre)
			overlay.condition_id = condition_id
			overlays.append(overlay)
			first = false
	return overlays

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
