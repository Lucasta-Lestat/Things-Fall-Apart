# WeatherManager.gd - Autoload Singleton
extends Node

signal wind_changed(wind_vector)
signal weather_changed(weather_type)

enum WeatherType {
	CLEAR,
	WINDY,
	STORMY,
	FOGGY
}

class WindZone:
	var position: Vector2
	var radius: float
	var wind_vector: Vector2
	var strength: float
	var duration: float = -1  # -1 for permanent
	var lifetime: float = 0.0
	
	func _init(pos: Vector2, size: float, wind: Vector2, dur: float = -1):
		position = pos
		radius = size
		wind_vector = wind
		strength = wind.length()
		duration = dur
	
	func update(delta: float) -> bool:
		if duration > 0:
			lifetime += delta
			return lifetime < duration
		return true
	
	func get_wind_at(pos: Vector2) -> Vector2:
		var distance = position.distance_to(pos)
		if distance > radius:
			return Vector2.ZERO
		
		var falloff = 1.0 - (distance / radius)
		return wind_vector * falloff

var current_weather: WeatherType = WeatherType.CLEAR
var global_wind: Vector2 = Vector2.ZERO
var wind_zones: Array[WindZone] = []
var weather_timer: float = 0.0
var weather_change_interval: float = 120.0  # Change weather every 2 minutes

func _ready():
	# Start with light wind
	set_global_wind(Vector2(randf_range(-20, 20), randf_range(-20, 20)))

func _process(delta):
	update_weather_system(delta)
	update_wind_zones(delta)

func update_weather_system(delta):
	weather_timer += delta
	
	if weather_timer >= weather_change_interval:
		weather_timer = 0.0
		change_weather_randomly()

func change_weather_randomly():
	var new_weather = randi() % WeatherType.size()
	set_weather(new_weather)

func set_weather(weather: WeatherType):
	if current_weather == weather:
		return
	
	current_weather = weather
	apply_weather_effects()
	weather_changed.emit(weather)

func apply_weather_effects():
	match current_weather:
		WeatherType.CLEAR:
			set_global_wind(Vector2.ZERO)
		WeatherType.WINDY:
			var wind_strength = randf_range(30, 60)
			var wind_direction = randf() * 2.0 * PI
			set_global_wind(Vector2(cos(wind_direction), sin(wind_direction)) * wind_strength)
		WeatherType.STORMY:
			var wind_strength = randf_range(60, 100)
			var wind_direction = randf() * 2.0 * PI
			set_global_wind(Vector2(cos(wind_direction), sin(wind_direction)) * wind_strength)
			create_random_wind_zones()
		WeatherType.FOGGY:
			set_global_wind(Vector2(randf_range(-10, 10), randf_range(-10, 10)))
			create_fog_clouds()

func set_global_wind(wind: Vector2):
	global_wind = wind
	wind_changed.emit(wind)
	
	# Apply wind force to all physics objects
	apply_wind_to_physics_objects()

func apply_wind_to_physics_objects():
	# Find all RigidBody2D nodes and apply wind force
	var physics_objects = get_tree().get_nodes_in_group("physics_objects")
	for obj in physics_objects:
		if obj is RigidBody2D:
			apply_wind_to_object(obj)

func apply_wind_to_object(obj: RigidBody2D):
	var wind_at_position = get_wind_at_position(obj.global_position)
	if wind_at_position.length() > 5.0:  # Only apply if wind is strong enough
		var wind_force = wind_at_position * obj.mass * 0.1
		obj.apply_central_force(wind_force)

func create_wind_zone(position: Vector2, radius: float, wind_vector: Vector2, duration: float = -1):
	var zone = WindZone.new(position, radius, wind_vector, duration)
	wind_zones.append(zone)

func create_random_wind_zones():
	# Create 3-5 random wind zones for stormy weather
	var zone_count = randi_range(3, 5)
	
	for i in range(zone_count):
		var pos = Vector2(randf_range(-1000, 1000), randf_range(-1000, 1000))
		var radius = randf_range(200, 400)
		var wind_strength = randf_range(40, 80)
		var wind_direction = randf() * 2.0 * PI
		var wind = Vector2(cos(wind_direction), sin(wind_direction)) * wind_strength
		var duration = randf_range(30, 60)  # 30-60 seconds
		
		create_wind_zone(pos, radius, wind, duration)

func create_fog_clouds():
	# Create several fog clouds across the map
	if not get_tree().current_scene.has_node("CloudSystem"):
		return
	
	var cloud_system = get_tree().current_scene.get_node("CloudSystem")
	var cloud_count = randi_range(5, 10)
	
	for i in range(cloud_count):
		var pos = Vector2(randf_range(-800, 800), randf_range(-600, 600))
		var radius = randf_range(100, 200)
		var intensity = randf_range(0.6, 1.0)
		cloud_system.create_cloud(pos, radius, intensity)

func update_wind_zones(delta):
	var zones_to_remove = []
	
	for i in range(wind_zones.size()):
		var zone = wind_zones[i]
		if not zone.update(delta):
			zones_to_remove.append(i)
	
	# Remove expired zones (in reverse order to maintain indices)
	for i in range(zones_to_remove.size() - 1, -1, -1):
		wind_zones.remove_at(zones_to_remove[i])

func get_wind_at_position(pos: Vector2) -> Vector2:
	var total_wind = global_wind
	
	# Add wind from all zones
	for zone in wind_zones:
		total_wind += zone.get_wind_at(pos)
	
	return total_wind

# Spell integration methods
func cast_wind_spell(caster_pos: Vector2, target_pos: Vector2, power: float, duration: float):
	var direction = caster_pos.direction_to(target_pos)
	var wind_vector = direction * power
	var radius = power * 2.0  # Larger area for stronger spells
	
	create_wind_zone(target_pos, radius, wind_vector, duration)

func cast_fog_spell(position: Vector2, radius: float, intensity: float = 1.0):
	if not get_tree().current_scene.has_node("CloudSystem"):
		return
	
	var cloud_system = get_tree().current_scene.get_node("CloudSystem")
	cloud_system.create_cloud(position, radius, intensity)
