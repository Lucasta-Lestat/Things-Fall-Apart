extends Node2D
class_name CreepyBeamVFX

# Beam endpoints in local space (the line dispatcher sets these relative to the caster)
@export var start_position: Vector2 = Vector2.ZERO
@export var end_position: Vector2 = Vector2.ZERO

# Beam colors
@export var color: Color = Color(0.95, 0.75, 1.0, 1.0)        # bright core
@export var glow_color: Color = Color(0.55, 0.18, 0.7, 0.8)   # mid violet glow
@export var halo_color: Color = Color(0.25, 0.05, 0.4, 0.4)   # outer void halo

# Beam shape
@export var thickness: float = 4.0
@export var beam_width: float = 32.0
@export var segments: int = 24
@export var wave_amplitude: float = 12.0
@export var wave_frequency: float = 1.4
@export var wave_speed: float = 1.6

# Lifetime
@export var lifetime: float = 0.6
@export var fade_time: float = 0.25

# Light
@export var light_enabled: bool = true
@export var light_energy: float = 1.4
@export var light_range: float = 220.0

var time_alive: float = 0.0
var phase: float = 0.0
var points: PackedVector2Array = PackedVector2Array()

@onready var beam_strip: Polygon2D = $BeamStrip
@onready var wisps: GPUParticles2D = $Wisps
@onready var endpoint_flare: GPUParticles2D = $EndpointFlare
@onready var beam_light: PointLight2D = $BeamLight

var _strip_material: ShaderMaterial


func _ready() -> void:
	phase = randf() * TAU
	_setup_beam_strip()
	_setup_light()
	_setup_wisps()
	_setup_endpoint_flare()
	_generate_path()
	queue_redraw()


func _setup_beam_strip() -> void:
	if beam_strip == null:
		return
	var direction := end_position - start_position
	var length := direction.length()
	if length < 0.01:
		beam_strip.visible = false
		return

	var half_w := beam_width * 0.5
	beam_strip.polygon = PackedVector2Array([
		Vector2(0.0, -half_w),
		Vector2(length, -half_w),
		Vector2(length, half_w),
		Vector2(0.0, half_w),
	])
	beam_strip.uv = PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(1.0, 0.0),
		Vector2(1.0, 1.0),
		Vector2(0.0, 1.0),
	])
	beam_strip.position = start_position
	beam_strip.rotation = direction.angle()

	if beam_strip.material is ShaderMaterial:
		_strip_material = beam_strip.material.duplicate() as ShaderMaterial
		beam_strip.material = _strip_material
		_strip_material.set_shader_parameter("time", 0.0)
		_strip_material.set_shader_parameter("intensity", 1.0)
		_strip_material.set_shader_parameter("core_color", color)
		_strip_material.set_shader_parameter("glow_color", glow_color)
		_strip_material.set_shader_parameter("halo_color", halo_color)


func _setup_light() -> void:
	if beam_light == null:
		return
	if not light_enabled:
		beam_light.visible = false
		return
	var midpoint := (start_position + end_position) * 0.5
	beam_light.position = midpoint
	beam_light.color = glow_color
	beam_light.energy = light_energy
	beam_light.texture_scale = light_range / 128.0


func _setup_wisps() -> void:
	if wisps == null:
		return
	var direction := end_position - start_position
	var length := direction.length()
	if length < 0.01:
		wisps.emitting = false
		return
	var midpoint := (start_position + end_position) * 0.5
	wisps.position = midpoint
	wisps.rotation = direction.angle()

	if wisps.process_material:
		var mat := wisps.process_material.duplicate() as ParticleProcessMaterial
		wisps.process_material = mat
		# Box emission spans the full beam length × narrow band perpendicular to it
		mat.emission_box_extents = Vector3(length * 0.5, beam_width * 0.4, 0.0)
		# Wisps drift back toward the caster (local -X since we rotated to beam direction)
		mat.direction = Vector3(-1.0, 0.0, 0.0)

	wisps.emitting = true


func _setup_endpoint_flare() -> void:
	if endpoint_flare == null:
		return
	endpoint_flare.position = end_position
	endpoint_flare.emitting = true


func _generate_path() -> void:
	points.clear()
	var direction := end_position - start_position
	var length := direction.length()
	if length < 0.01:
		return
	var perp := direction.rotated(PI / 2.0).normalized()

	for i in range(segments + 1):
		var t := float(i) / float(segments)
		var base := start_position.lerp(end_position, t)
		# Sine envelope so the path snaps to both endpoints cleanly
		var envelope := sin(t * PI)
		var primary := sin(t * TAU * wave_frequency + phase)
		var secondary := sin(t * TAU * wave_frequency * 2.6 + phase * 1.7) * 0.45
		var offset := perp * (primary + secondary) * wave_amplitude * envelope
		points.append(base + offset)


func _process(delta: float) -> void:
	time_alive += delta
	phase += delta * wave_speed
	_generate_path()
	queue_redraw()

	var fade := _fade_factor()

	if _strip_material:
		_strip_material.set_shader_parameter("time", time_alive)
		_strip_material.set_shader_parameter("intensity", fade)

	if beam_light and light_enabled:
		beam_light.energy = light_energy * fade * randf_range(0.85, 1.0)

	if time_alive >= lifetime + fade_time:
		queue_free()


func _fade_factor() -> float:
	if time_alive <= lifetime:
		return 1.0
	return clamp(1.0 - (time_alive - lifetime) / fade_time, 0.0, 1.0)


func _draw() -> void:
	if points.size() < 2:
		return

	var fade := _fade_factor()

	var c_halo := halo_color
	c_halo.a *= fade
	var c_glow := glow_color
	c_glow.a *= fade
	var c_core := color
	c_core.a *= fade

	# Three-layer glow polyline: outer halo → mid glow → bright core
	draw_polyline(points, c_halo, thickness * 6.0, true)
	draw_polyline(points, c_glow, thickness * 2.5, true)
	draw_polyline(points, c_core, thickness * 1.0, true)


static func create_beam(from: Vector2, to: Vector2, parent: Node) -> CreepyBeamVFX:
	var beam := CreepyBeamVFX.new()
	beam.start_position = from
	beam.end_position = to
	parent.add_child(beam)
	return beam
