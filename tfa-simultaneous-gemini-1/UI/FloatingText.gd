extends Label
var speed = 50.0  # pixels per second upward movement
var lifetime = 2.0  # how long before it disappears
var elapsed_time = 0.0

func _ready():
	modulate.a = 1.0  # Start fully opaque

func _process(delta):
	elapsed_time += delta
	
	# Move upward
	position.y -= speed * delta
	
	# Fade out (start fading after half the lifetime)
	var fade_start = lifetime * 0.5
	if elapsed_time > fade_start:
		var fade_progress = (elapsed_time - fade_start) / (lifetime - fade_start)
		modulate.a = 1.0 - fade_progress
	
	# Remove when lifetime expires
	if elapsed_time >= lifetime:
		queue_free()
