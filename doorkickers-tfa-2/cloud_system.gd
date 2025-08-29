 #CloudSystem.gd
extends Node2D
class_name CloudSystem

signal cloud_created(cloud_id, position, intensity)
signal cloud_dissipated(cloud_id)

class Cloud:
	var id: String
	var position: Vector2
	var radius: float
	var intensity: float  # 0.0 to 1.0
	var max_intensity: float
	var dissipation_rate: float = 0.1  # How fast it naturally dissipates
	var wind_resistance: float = 0.5  # How much it resists wind
	var particles: Array[Dictionary] = []
	var lifetime: float = 0.0
	var max_lifetime: float = 30.0
	
	func _init(cloud_id: String, pos: Vector2, size: float, strength: float):
		id = cloud_id
		position = pos
		radius = size
		intensity = strength
		max_intensity = strength
		generate_particles()
	
	func generate_particles():
		var particle_count = int(radius / 8.0)  # Particles based on size
		particles.clear()
		
		for i in range(particle_count):
			var angle = randf() * 2.0 * PI
			var distance = randf() * radius
			var particle_pos = position + Vector2(cos(angle), sin(angle)) * distance
			
			particles.append({
				"position": particle_pos,
				"size": randf_range(8.0, 16.0),
				"alpha": randf_range(0.3, 0.8) * intensity,
				"drift_speed": randf_range(5.0, 15.0)
			})
	
	func update(delta: float, wind_force: Vector2):
		lifetime += delta
		
		# Natural dissipation
		intensity = max(0.0, intensity - dissipation_rate * delta)
		
		# Wind effects
		if wind_force.length() > 0:
			# Move cloud
			var wind_effect = wind_force * (1.0 - wind_resistance) * delta
			position += wind_effect
			
			# Wind dissipates cloud
			var wind_dissipation = wind_force.length() * 0.02 * delta
			intensity = max(0.0, intensity - wind_dissipation)
		
		# Update particles
		for particle in particles:
			# Drift particles
			var drift_angle = randf() * 2.0 * PI
			var drift = Vector2(cos(drift_angle), sin(drift_angle)) * particle.drift_speed * delta
			particle.position += drift + wind_force * delta * 0.5
			
			# Update alpha based on cloud intensity
			particle.alpha = randf_range(0.3, 0.8) * intensity
		
		return intensity > 0.01 and lifetime < max_lifetime
	
	func get_concealment_at(pos: Vector2) -> float:
		var distance = position.distance_to(pos)
		if distance > radius:
			return 0.0
		
		var distance_factor = 1.0 - (distance / radius)
		return intensity * distance_factor * 50.0  # Max 50 concealment points

var clouds: Dictionary = {}  # String -> Cloud
var next_cloud_id: int = 0

func _ready():
	# Connect to weather system
	if WeatherManager:
		WeatherManager.wind_changed.connect(_on_wind_changed)

func _process(delta):
	update_clouds(delta)

func create_cloud(position: Vector2, radius: float, intensity: float = 1.0) -> String:
	var cloud_id = "cloud_" + str(next_cloud_id)
	next_cloud_id += 1
	
	var cloud = Cloud.new(cloud_id, position, radius, intensity)
	clouds[cloud_id] = cloud
	
	# Register concealment with fog of war system
	register_cloud_concealment(cloud)
	
	cloud_created.emit(cloud_id, position, intensity)
	return cloud_id

func update_clouds(delta):
	var clouds_to_remove = []
	var current_wind = WeatherManager.get_wind_at_position(Vector2.ZERO) if WeatherManager else Vector2.ZERO
	
	for cloud_id in clouds:
		var cloud = clouds[cloud_id]
		var still_active = cloud.update(delta, current_wind)
		
		if not still_active:
			clouds_to_remove.append(cloud_id)
		else:
			# Update concealment registration
			update_cloud_concealment(cloud)
	
	# Remove dissipated clouds
	for cloud_id in clouds_to_remove:
		remove_cloud(cloud_id)

func remove_cloud(cloud_id: String):
	if cloud_id in clouds:
		unregister_cloud_concealment(clouds[cloud_id])
		clouds.erase(cloud_id)
		cloud_dissipated.emit(cloud_id)

func register_cloud_concealment(cloud: Cloud):
	# Register concealment with fog of war system
	var affected_tiles = get_tiles_in_radius(cloud.position, cloud.radius)
	
	for tile_pos in affected_tiles:
		var concealment_value = cloud.get_concealment_at(Vector2(tile_pos * FogOfWarManager.tile_size))
		if concealment_value > 0:
			var concealment_data = {
				"id": cloud.id,
				"concealment_value": concealment_value,
				"type": "cloud"
			}
			FogOfWarManager.get_or_create_tile(tile_pos).add_concealment(concealment_data)

func update_cloud_concealment(cloud: Cloud):
	# Remove old concealment
	unregister_cloud_concealment(cloud)
	# Register new concealment
	register_cloud_concealment(cloud)

func unregister_cloud_concealment(cloud: Cloud):
	var affected_tiles = get_tiles_in_radius(cloud.position, cloud.radius + FogOfWarManager.tile_size)
	
	for tile_pos in affected_tiles:
		FogOfWarManager.get_or_create_tile(tile_pos).remove_concealment(cloud.id)

func get_tiles_in_radius(center: Vector2, radius: float) -> Array[Vector2i]:
	var tiles = []
	var tile_size = FogOfWarManager.tile_size
	var center_tile = Vector2i(center / tile_size)
	var tile_radius = int(radius / tile_size) + 1
	
	for x in range(-tile_radius, tile_radius + 1):
		for y in range(-tile_radius, tile_radius + 1):
			var tile_pos = center_tile + Vector2i(x, y)
			var world_pos = Vector2(tile_pos * tile_size)
			if center.distance_to(world_pos) <= radius:
				tiles.append(tile_pos)
	
	return tiles

func _draw():
	draw_all_clouds()

func draw_all_clouds():
	for cloud in clouds.values():
		draw_cloud(cloud)

func draw_cloud(cloud: Cloud):
	# Draw cloud particles
	for particle in cloud.particles:
		var color = Color.WHITE
		color.a = particle.alpha
		var particle_pos = to_local(particle.position)
		draw_circle(particle_pos, particle.size, color)
		
		# Add some variation with smaller wisps
		for i in range(3):
			var wisp_offset = Vector2(randf_range(-8, 8), randf_range(-8, 8))
			var wisp_color = color
			wisp_color.a *= 0.5
			draw_circle(particle_pos + wisp_offset, particle.size * 0.6, wisp_color)

func _on_wind_changed(wind_vector: Vector2):
	# Wind will automatically affect clouds in update_clouds()
	queue_redraw()
