# HearingManager.gd - Autoload Singleton
extends Node

signal sound_detected(listener, sound_source, sound_data)
signal sound_created(sound_id, position, intensity)

class SoundEvent:
	var id: String
	var source_position: Vector2
	var source_character: Node  # Can be null for environmental sounds
	var sound_type: String
	var base_intensity: float
	var current_intensity: float
	var creation_time: float
	var duration: float
	var falloff_rate: float = 2.0  # How quickly sound fades with distance
	var wall_penetration: float = 0.5  # How well sound goes through walls
	
	func _init(sound_id: String, pos: Vector2, type: String, intensity: float, dur: float = 1.0):
		id = sound_id
		source_position = pos
		sound_type = type
		base_intensity = intensity
		current_intensity = intensity
		duration = dur
		creation_time = GameManager.game_time
	
	func get_intensity_at_position(listener_pos: Vector2) -> float:
		var distance = source_position.distance_to(listener_pos)
		var age = GameManager.game_time - creation_time
		
		# Sound fades over time
		var time_factor = max(0.0, 1.0 - (age / duration))
		
		# Sound fades with distance
		var distance_factor = 1.0 / (1.0 + distance / 50.0)  # 50 pixels = 1 falloff unit
		
		return current_intensity * time_factor * distance_factor
	
	func is_expired() -> bool:
		return (GameManager.game_time - creation_time) > duration

# Sound type definitions
enum SoundType {
	FOOTSTEPS,
	WEAPON_SWING,
	WEAPON_IMPACT,
	DOOR_OPEN,
	DOOR_CLOSE,
	OBJECT_BREAK,
	SPELL_CAST,
	PROJECTILE_FIRE,
	CONVERSATION,
	ENVIRONMENTAL
}

var sound_type_properties = {
	SoundType.FOOTSTEPS: {"base_intensity": 15.0, "duration": 0.5, "wall_penetration": 0.8},
	SoundType.WEAPON_SWING: {"base_intensity": 25.0, "duration": 0.3, "wall_penetration": 0.6},
	SoundType.WEAPON_IMPACT: {"base_intensity": 40.0, "duration": 0.8, "wall_penetration": 0.4},
	SoundType.DOOR_OPEN: {"base_intensity": 30.0, "duration": 1.0, "wall_penetration": 0.7},
	SoundType.DOOR_CLOSE: {"base_intensity": 35.0, "duration": 0.6, "wall_penetration": 0.7},
	SoundType.OBJECT_BREAK: {"base_intensity": 50.0, "duration": 1.2, "wall_penetration": 0.5},
	SoundType.SPELL_CAST: {"base_intensity": 20.0, "duration": 0.4, "wall_penetration": 0.9},
	SoundType.PROJECTILE_FIRE: {"base_intensity": 45.0, "duration": 0.2, "wall_penetration": 0.3},
	SoundType.CONVERSATION: {"base_intensity": 10.0, "duration": 2.0, "wall_penetration": 0.9},
	SoundType.ENVIRONMENTAL: {"base_intensity": 20.0, "duration": 3.0, "wall_penetration": 0.8}
}

var active_sounds: Dictionary = {}  # String -> SoundEvent
var next_sound_id: int = 0
var hearing_update_timer: float = 0.0
const HEARING_UPDATE_INTERVAL = 0.1  # Update hearing every 100ms

func _ready():
	# Connect to character actions that make sound
	PhysicsManager.collision_damage_dealt.connect(_on_collision_damage)

func _process(delta):
	hearing_update_timer += delta
	if hearing_update_timer >= HEARING_UPDATE_INTERVAL:
		hearing_update_timer = 0.0
		update_hearing_system()
	
	cleanup_expired_sounds()

func create_sound(position: Vector2, sound_type: SoundType, intensity_modifier: float = 1.0, source_character: Node = null) -> String:
	var sound_id = "sound_" + str(next_sound_id)
	next_sound_id += 1
	
	var properties = sound_type_properties[sound_type]
	var intensity = properties.base_intensity * intensity_modifier
	var duration = properties.duration
	
	# Modify intensity based on terrain
	var terrain_pos = Vector2i(position / TerrainManager.terrain_grid.values()[0] if not TerrainManager.terrain_grid.is_empty() else Vector2i(position / 32))
	if TerrainManager.terrain_grid.has(terrain_pos):
		var terrain = TerrainManager.get_terrain_at(terrain_pos)
		intensity *= (1.0 + terrain.noisiness)  # Noisy terrain amplifies sound
	
	var sound = SoundEvent.new(sound_id, position, SoundType.keys()[sound_type], intensity, duration)
	sound.source_character = source_character
	sound.wall_penetration = properties.wall_penetration
	
	active_sounds[sound_id] = sound
	sound_created.emit(sound_id, position, intensity)
	
	return sound_id

func update_hearing_system():
	var listeners = get_tree().get_nodes_in_group("characters")
	
	for listener in listeners:
		if not listener is EnhancedCharacter or not listener.is_conscious:
			continue
			
		check_character_hearing(listener)

func check_character_hearing(listener: EnhancedCharacter):
	var detected_sounds = []
	
	for sound_id in active_sounds:
		var sound = active_sounds[sound_id]
		
		# Don't hear your own sounds (usually)
		if sound.source_character == listener:
			continue
		
		var can_hear = can_character_hear_sound(listener, sound)
		if can_hear:
			detected_sounds.append({
				"sound": sound,
				"intensity": can_hear,
				"direction": listener.global_position.direction_to(sound.source_position)
			})
	
	if not detected_sounds.is_empty():
		sound_detected.emit(listener, detected_sounds)

func can_character_hear_sound(listener: EnhancedCharacter, sound: SoundEvent) -> float:
	var distance = listener.global_position.distance_to(sound.source_position)
	var sound_intensity = sound.get_intensity_at_position(listener.global_position)
	
	# Calculate sound attenuation due to walls/obstacles
	var attenuation = calculate_sound_attenuation(listener.global_position, sound.source_position, sound.wall_penetration)
	var attenuated_intensity = sound_intensity * attenuation
	
	# Check if character's hearing can detect the sound
	var hearing_threshold = 100.0 - listener.hearing  # Higher hearing = lower threshold
	
	if attenuated_intensity > hearing_threshold:
		# Return how clearly they can hear it (0.0 to 1.0)
		return min(1.0, (attenuated_intensity - hearing_threshold) / 25.0)
	
	return 0.0

func calculate_sound_attenuation(listener_pos: Vector2, sound_pos: Vector2, wall_penetration: float) -> float:
	# Cast a ray to check for walls between listener and sound source
	var space_state = get_tree().current_scene.get_world_2d().direct_space_state
	var query = PhysicsRayQueryParameters2D.create(listener_pos, sound_pos)
	query.collision_mask = 8  # Wall collision layer
	
	var attenuation = 1.0
	var current_pos = listener_pos
	var step_size = 16.0  # Check every 16 pixels
	var direction = listener_pos.direction_to(sound_pos)
	var total_distance = listener_pos.distance_to(sound_pos)
	
	# Check for walls along the path
	var steps = int(total_distance / step_size)
	for i in range(steps):
		var check_pos = current_pos + direction * step_size
		query.from = current_pos
		query.to = check_pos
		
		var result = space_state.intersect_ray(query)
		if result:
			# Hit a wall - reduce sound based on wall penetration
			attenuation *= wall_penetration
		
		current_pos = check_pos
	
	return attenuation

func cleanup_expired_sounds():
	var expired_sounds = []
	
	for sound_id in active_sounds:
		var sound = active_sounds[sound_id]
		if sound.is_expired():
			expired_sounds.append(sound_id)
	
	for sound_id in expired_sounds:
		active_sounds.erase(sound_id)

# Sound creation helpers for common game events
func create_footstep_sound(character: EnhancedCharacter):
	var intensity_mod = 1.0
	
	# Modify based on movement speed
	if character.main_body:
		var speed = character.main_body.linear_velocity.length()
		intensity_mod = 0.5 + (speed / 100.0)  # Faster = louder
	
	# Modify based on terrain
	var terrain_pos = Vector2i(character.global_position / 32)
	if TerrainManager.terrain_grid.has(terrain_pos):
		var terrain = TerrainManager.get_terrain_at(terrain_pos)
		intensity_mod *= (1.0 + terrain.noisiness)
	
	create_sound(character.global_position, SoundType.FOOTSTEPS, intensity_mod, character)

func create_weapon_sound(weapon: EnhancedWeapon, sound_type: SoundType):
	var intensity_mod = 1.0
	
	if weapon.wielder:
		# Stronger characters make more noise
		intensity_mod = 0.8 + (weapon.wielder.strength / 200.0)
	
	if sound_type == SoundType.WEAPON_SWING:
		# Swinging sound based on weapon velocity
		intensity_mod *= (weapon.linear_velocity.length() / 100.0)
	
	create_sound(weapon.global_position, sound_type, intensity_mod, weapon.wielder)

# Connect to physics events
func _on_collision_damage(body1: RigidBody2D, body2: RigidBody2D, damage: float, damage_type: PhysicsManager.DamageType):
	# Create impact sound
	var impact_pos = (body1.global_position + body2.global_position) / 2.0
	var intensity_mod = damage / 20.0  # Louder impacts for more damage
	create_sound(impact_pos, SoundType.WEAPON_IMPACT, intensity_mod)

# ===================================================================



# SoundVisualizer.gd - Visual feedback for hearing system
extends Node2D
class_name SoundVisualizer

class SoundIndicator:
	var position: Vector2
	var intensity: float
	var lifetime: float = 0.0
	var max_lifetime: float = 2.0
	var sound_type: String
	var direction: Vector2
	
	func _init(pos: Vector2, dir: Vector2, intensity_val: float, type: String):
		position = pos
		direction = dir
		intensity = intensity_val
		sound_type = type
	
	func update(delta: float) -> bool:
		lifetime += delta
		return lifetime < max_lifetime
	
	func get_alpha() -> float:
		return 1.0 - (lifetime / max_lifetime)

var sound_indicators: Array[SoundIndicator] = []
var listening_character: EnhancedCharacter

func _ready():
	HearingManager.sound_detected.connect(_on_sound_detected)

func set_listening_character(character: EnhancedCharacter):
	listening_character = character

func _on_sound_detected(listener: EnhancedCharacter, detected_sounds: Array):
	if listener != listening_character:
		return
	
	# Add sound indicators
	for sound_data in detected_sounds:
		var sound = sound_data.sound
		var direction = sound_data.direction
		var intensity = sound_data.intensity
		
		var indicator = SoundIndicator.new(
			listener.global_position + direction * 50.0,  # Show indicator 50 pixels in sound direction
			direction,
			intensity,
			sound.sound_type
		)
		sound_indicators.append(indicator)

func _process(delta):
	# Update sound indicators
	var indicators_to_remove = []
	
	for i in range(sound_indicators.size()):
		var indicator = sound_indicators[i]
		if not indicator.update(delta):
			indicators_to_remove.append(i)
	
	# Remove expired indicators (in reverse order)
	for i in range(indicators_to_remove.size() - 1, -1, -1):
		sound_indicators.remove_at(indicators_to_remove[i])
	
	queue_redraw()

func _draw():
	for indicator in sound_indicators:
		draw_sound_indicator(indicator)

func draw_sound_indicator(indicator: SoundIndicator):
	var alpha = indicator.get_alpha()
	var color = get_sound_color(indicator.sound_type)
	color.a = alpha * indicator.intensity
	
	var pos = to_local(indicator.position)
	
	# Draw directional arrow
	var arrow_length = 20.0 * indicator.intensity
	var arrow_end = pos + indicator.direction * arrow_length
	
	# Arrow shaft
	draw_line(pos, arrow_end, color, 3.0)
	
	# Arrow head
	var head_size = 8.0
	var perpendicular = Vector2(-indicator.direction.y, indicator.direction.x)
	var head_point1 = arrow_end - indicator.direction * head_size + perpendicular * head_size * 0.5
	var head_point2 = arrow_end - indicator.direction * head_size - perpendicular * head_size * 0.5
	
	var head_points = PackedVector2Array([arrow_end, head_point1, head_point2])
	draw_colored_polygon(head_points, color)
	
	# Draw sound type icon
	draw_sound_type_icon(pos, indicator.sound_type, color)

func get_sound_color(sound_type: String) -> Color:
	match sound_type:
		"FOOTSTEPS":
			return Color.YELLOW
		"WEAPON_SWING", "WEAPON_IMPACT":
			return Color.RED
		"DOOR_OPEN", "DOOR_CLOSE":
			return Color.BLUE
		"CONVERSATION":
			return Color.GREEN
		"OBJECT_BREAK":
			return Color.ORANGE
		_:
			return Color.WHITE

func draw_sound_type_icon(pos: Vector2, sound_type: String, color: Color):
	match sound_type:
		"FOOTSTEPS":
			# Draw footprint
			draw_circle(pos + Vector2(-3, -3), 2.0, color)
			draw_circle(pos + Vector2(3, 3), 2.0, color)
		"WEAPON_SWING", "WEAPON_IMPACT":
			# Draw crossed swords
			draw_line(pos + Vector2(-5, -5), pos + Vector2(5, 5), color, 2.0)
			draw_line(pos + Vector2(-5, 5), pos + Vector2(5, -5), color, 2.0)
		"CONVERSATION":
			# Draw speech bubble
			draw_circle(pos, 4.0, Color.TRANSPARENT)
			draw_arc(pos, 4.0, 0, 2 * PI, 16, color, 1.0)
		_:
			# Default: draw question mark
			draw_circle(pos, 3.0, color)

# ===================================================================

# Enhanced character integration for movement sounds
func _on_character_moved(character: EnhancedCharacter):
	# This would be called from character movement system
	if character.is_walking and character.is_conscious:
		# Create footstep sounds based on movement
		var time_since_last_step = GameManager.game_time - character.get("last_footstep_time", 0.0)
		var step_interval = 0.5 / character.walk_speed  # Faster walking = more frequent steps
		
		if time_since_last_step >= step_interval:
			HearingManager.create_footstep_sound(character)
			character.set("last_footstep_time", GameManager.game_time)

# Integration with weapon system
func _on_weapon_attack_started(weapon: EnhancedWeapon):
	HearingManager.create_weapon_sound(weapon, HearingManager.SoundType.WEAPON_SWING)

func _on_weapon_impact(weapon: EnhancedWeapon, target: Node, damage: float):
	# Impact sound is handled by collision system
	pass
