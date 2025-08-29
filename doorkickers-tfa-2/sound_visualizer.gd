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
var listening_character: Character

func _ready():
	HearingManager.sound_detected.connect(_on_sound_detected)

func set_listening_character(character: Character):
	listening_character = character

func _on_sound_detected(listener: Character, detected_sounds: Array):
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
func _on_character_moved(character: Character):
	# This would be called from character movement system
	if character.is_walking and character.is_conscious:
		# Create footstep sounds based on movement
		var time_since_last_step = GameManager.game_time - character.get("last_footstep_time", 0.0)
		var step_interval = 0.5 / character.walk_speed  # Faster walking = more frequent steps
		
		if time_since_last_step >= step_interval:
			HearingManager.create_footstep_sound(character)
			character.set("last_footstep_time", GameManager.game_time)

# Integration with weapon system
func _on_weapon_attack_started(weapon: Weapon):
	HearingManager.create_weapon_sound(weapon, HearingManager.SoundType.WEAPON_SWING)

func _on_weapon_impact(weapon: Weapon, target: Node, damage: float):
	# Impact sound is handled by collision system
	pass
