# WeatherSystem.gd
extends Node2D
class_name WeatherSystem

# Global weather that affects all characters

enum WeatherType {
	CLEAR,
	WIND,
	STORM,
	BLIZZARD,
	SANDSTORM
}

@export var current_weather: WeatherType = WeatherType.CLEAR
@export var wind_direction: Vector2 = Vector2(100, 0)
@export var wind_strength: float = 0.0
@export var visibility_reduction: float = 0.0

var weather_particles: CPUParticles2D

signal weather_changed(weather_type)

func _ready():
	set_physics_process(true)
	_setup_weather_visuals()

func _physics_process(delta):
	# Apply weather to all characters
	match current_weather:
		WeatherType.WIND:
			_apply_wind_to_all(delta)
		WeatherType.STORM:
			_apply_storm_effects(delta)
		WeatherType.BLIZZARD:
			_apply_blizzard_effects(delta)
		WeatherType.SANDSTORM:
			_apply_sandstorm_effects(delta)

func change_weather(new_weather: WeatherType, transition_time: float = 2.0):
	var tween = get_tree().create_tween()
	
	# Fade out current weather
	if weather_particles:
		tween.tween_property(weather_particles, "amount", 0, transition_time * 0.5)
	
	# Change weather
	tween.tween_callback(func():
		current_weather = new_weather
		_update_weather_properties()
		weather_changed.emit(new_weather)
	)
	
	# Fade in new weather
	if weather_particles:
		tween.tween_property(weather_particles, "amount", _get_particle_amount(), transition_time * 0.5)

func _update_weather_properties():
	match current_weather:
		WeatherType.CLEAR:
			wind_strength = 0.0
			visibility_reduction = 0.0
		
		WeatherType.WIND:
			wind_strength = 150.0
			visibility_reduction = 0.0
			wind_direction = Vector2(1, 0.2).normalized() * wind_strength
		
		WeatherType.STORM:
			wind_strength = 300.0
			visibility_reduction = 0.3
			wind_direction = Vector2(randf_range(-1, 1), randf_range(-1, 1)).normalized() * wind_strength
		
		WeatherType.BLIZZARD:
			wind_strength = 200.0
			visibility_reduction = 0.6
			wind_direction = Vector2(0.7, 0.3).normalized() * wind_strength
		
		WeatherType.SANDSTORM:
			wind_strength = 250.0
			visibility_reduction = 0.7
			wind_direction = Vector2(1, 0).normalized() * wind_strength

func _apply_wind_to_all(delta):
	for character in get_tree().get_nodes_in_group("characters"):
		if character.has_method("add_external_force"):
			# Wind affects lighter characters more
			var mass_factor = 1.0
			if character.physics_body:
				mass_factor = 70.0 / character.physics_body.mass  # Assume 70kg as baseline
			
			var wind_force = wind_direction * mass_factor
			character.physics_body.apply_external_force(wind_force * delta, "weather_wind")

func _apply_storm_effects(delta):
	_apply_wind_to_all(delta)
	
	# Random strong gusts
	if randf() < 0.01:  # 1% chance per frame
		var gust_direction = wind_direction.rotated(randf_range(-PI/4, PI/4))
		var gust_strength = wind_strength * randf_range(2.0, 4.0)
		
		for character in get_tree().get_nodes_in_group("characters"):
			if character.has_method("add_external_force"):
				character.add_external_force(gust_direction * gust_strength, 0.5, "storm_gust")
	
	# Lightning strikes (visual only for now)
	if randf() < 0.005:
		_create_lightning_effect()

func _apply_blizzard_effects(delta):
	_apply_wind_to_all(delta)
	
	# Gradually freeze ground
	if randf() < 0.01:
		var ice_pos = Vector2(randf_range(0, 1000), randf_range(0, 1000))
		var ice = TerrainModifier.new()
		ice.modifier_type = TerrainModifier.ModifierType.ICE
		ice.area_size = Vector2(50, 50)
		ice.duration = 30.0
		ice.position = ice_pos
		add_child(ice)

func _apply_sandstorm_effects(delta):
	_apply_wind_to_all(delta)
	
	# Reduce movement speed due to sand
	for character in get_tree().get_nodes_in_group("characters"):
		if character.physics_body:
			character.physics_body.max_velocity = 200.0  # Reduced from normal

func _setup_weather_visuals():
	if weather_particles:
		weather_particles.queue_free()
	
	weather_particles = CPUParticles2D.new()
	add_child(weather_particles)
	
	weather_particles.amount = _get_particle_amount()
	weather_particles.lifetime = 3.0
	weather_particles.preprocess = 1.0
	weather_particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_BOX
	weather_particles.emission_box_extents = Vector2(1200, 1200)
	
	match current_weather:
		WeatherType.WIND:
			weather_particles.texture = preload("res://leaf_particle.png") if ResourceLoader.exists("res://leaf_particle.png") else null
			weather_particles.direction = wind_direction.normalized()
			weather_particles.initial_velocity_min = 100
			weather_particles.initial_velocity_max = 200
			weather_particles.color = Color(0.6, 0.8, 0.3, 0.5)
		
		WeatherType.STORM:
			weather_particles.direction = Vector2(0, 1)
			weather_particles.initial_velocity_min = 300
			weather_particles.initial_velocity_max = 400
			weather_particles.spread = 10.0
			weather_particles.color = Color(0.5, 0.5, 0.6, 0.7)
		
		WeatherType.BLIZZARD:
			weather_particles.direction = wind_direction.normalized()
			weather_particles.initial_velocity_min = 150
			weather_particles.initial_velocity_max = 250
			weather_particles.scale_amount_min = 0.5
			weather_particles.scale_amount_max = 1.5
			weather_particles.color = Color(1, 1, 1, 0.8)
		
		WeatherType.SANDSTORM:
			weather_particles.direction = wind_direction.normalized()
			weather_particles.initial_velocity_min = 200
			weather_particles.initial_velocity_max = 300
			weather_particles.color = Color(0.8, 0.7, 0.5, 0.4)
	
	weather_particles.emitting = true

func _get_particle_amount() -> int:
	match current_weather:
		WeatherType.CLEAR:
			return 0
		WeatherType.WIND:
			return 20
		WeatherType.STORM:
			return 100
		WeatherType.BLIZZARD:
			return 150
		WeatherType.SANDSTORM:
			return 80
	return 0

func _create_lightning_effect():
	var lightning = Line2D.new()
	lightning.width = 3.0
	lightning.default_color = Color(1, 1, 0.8, 1)
	
	# Generate jagged line
	var start = Vector2(randf_range(0, 1000), 0)
	var end = Vector2(start.x + randf_range(-100, 100), 600)
	
	lightning.add_point(start)
	for i in range(5):
		var t = (i + 1) / 6.0
		var point = start.lerp(end, t)
		point.x += randf_range(-20, 20)
		lightning.add_point(point)
	lightning.add_point(end)
	
	add_child(lightning)
	
	# Flash effect
	var flash = ColorRect.new()
	flash.color = Color(1, 1, 1, 0.3)
	flash.size = Vector2(1200, 800)
	add_child(flash)
	
	# Fade out
	var tween = get_tree().create_tween()
	tween.tween_property(lightning, "modulate:a", 0.0, 0.3)
	tween.parallel().tween_property(flash, "modulate:a", 0.0, 0.1)
	tween.tween_callback(func():
		lightning.queue_free()
		flash.queue_free()
	)
		
