extends Node2D

@onready var particles: GPUParticles2D = $GPUParticles2D

var _slash_timer: float = 0.0
var _slash_duration: float = 0.3
var _slash_alpha: float = 0.0
var _size_scale: float = 1.0

func play(size_scale: float = 1.0):
	_size_scale = size_scale
	_slash_alpha = 1.0
	_slash_timer = _slash_duration

	var mat = particles.process_material.duplicate() as ParticleProcessMaterial
	particles.process_material = mat
	mat.scale_min *= size_scale
	mat.scale_max *= size_scale
	mat.initial_velocity_min *= size_scale
	mat.initial_velocity_max *= size_scale
	particles.amount = int(particles.amount * size_scale)
	particles.emitting = true

	queue_redraw()

func _process(delta: float) -> void:
	if _slash_timer > 0.0:
		_slash_timer -= delta
		_slash_alpha = clampf(_slash_timer / _slash_duration, 0.0, 1.0)
		queue_redraw()
		if _slash_timer <= 0.0:
			_slash_alpha = 0.0
			queue_redraw()

	if not particles.emitting and _slash_alpha <= 0.0:
		queue_free()

func _draw() -> void:
	if _slash_alpha <= 0.0:
		return

	var base_length = 30.0 * _size_scale
	var base_width = 2.5 * _size_scale
	var color = Color(1.0, 0.95, 0.9, _slash_alpha)

	# Three diagonal claw lines, angled -30, 0, +30 degrees from vertical
	for i in range(3):
		var angle = deg_to_rad(-30 + i * 30)
		var offset_x = (i - 1) * 8.0 * _size_scale
		var start = Vector2(offset_x, -base_length * 0.5).rotated(angle)
		var end = Vector2(offset_x, base_length * 0.5).rotated(angle)
		draw_line(start, end, color, base_width, true)
