extends Node2D

# World-space range the artwork is authored at. The spawner divides the
# ability's actual range by this to get the scale, so the cone lands exactly
# on the targeting preview instead of overshooting it.
const BASE_RANGE := 300.0

@onready var waves: ColorRect = $WaveLayer
@onready var particles: GPUParticles2D = $GPUParticles2D
@onready var light: PointLight2D = $PointLight2D

var vfx_base_radius: float = BASE_RANGE

var _size_scale: float = 1.0
var _cone_half_angle: float = deg_to_rad(30.0)

func play(size_scale: float = 1.0):
	_size_scale = size_scale
	_layout_cone()

	var mat = particles.process_material.duplicate() as ParticleProcessMaterial
	particles.process_material = mat

	# Particles are a light dusting on top of the wave, not the effect itself:
	# count and size grow linearly with range (not squared) so big cones don't
	# turn into a wall of sprites.
	mat.emission_sphere_radius *= size_scale
	mat.scale_min *= size_scale
	mat.scale_max *= size_scale
	mat.initial_velocity_min *= size_scale
	mat.initial_velocity_max *= size_scale
	mat.spread = rad_to_deg(_cone_half_angle) * 0.8

	particles.amount = max(4, int(particles.amount * size_scale))
	particles.lifetime *= sqrt(size_scale)

	light.position = Vector2(BASE_RANGE * 0.25 * size_scale, 0)
	light.texture_scale *= size_scale
	light.energy *= clamp(size_scale, 0.5, 1.5)

	particles.emitting = true

## Match the cone geometry to the ability's targeting cone. Called by the
## spawner after play(); safe to call before it too.
func set_cone_angle(half_angle_rad: float) -> void:
	_cone_half_angle = clamp(half_angle_rad, 0.05, 1.4)
	_layout_cone()
	if particles and particles.process_material is ParticleProcessMaterial:
		var mat := particles.process_material as ParticleProcessMaterial
		mat.spread = rad_to_deg(_cone_half_angle) * 0.8

func _layout_cone() -> void:
	if waves == null:
		return
	# Rect spans the full range along +X and just enough height to hold the cone
	# mouth; the shader corrects for the non-square aspect.
	var range_px: float = BASE_RANGE * _size_scale
	waves.size = Vector2(range_px, 2.0 * range_px * tan(_cone_half_angle))
	waves.position = Vector2(0, -waves.size.y * 0.5)
	if waves.material is ShaderMaterial:
		if not waves.material.resource_local_to_scene:
			waves.material = waves.material.duplicate()
			waves.material.resource_local_to_scene = true
		waves.material.set_shader_parameter("resolution", waves.size)
		waves.material.set_shader_parameter("cone_half_angle", _cone_half_angle)

func _process(delta: float) -> void:
	if waves.material is ShaderMaterial:
		var current_time = waves.material.get_shader_parameter("time")
		if current_time == null:
			current_time = 0.0
		waves.material.set_shader_parameter("time", current_time + delta)
