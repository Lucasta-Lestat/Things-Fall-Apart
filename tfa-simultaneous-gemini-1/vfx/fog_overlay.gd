class_name FogOverlay
extends ColorRect

var duration: float = -1.0
var elapsed: float = 0.0
var condition_id: String = ""
var condition_stacks: int = 1
var condition_duration_override: float = -2.0
var apply_interval: float = 1.0
var _apply_timer: float = 0.0
var source: Node = null

# Drifting / dissipating clouds (fire smoke, steam). The shader's `speed` is only
# a UV scroll — the rect itself never moved, so a cloud read as a static square.
# Static map fog leaves these at their defaults and behaves exactly as before.
var drift: Vector2 = Vector2.ZERO   # world px/s the whole cloud body travels
var fade_in: float = 0.0            # seconds of alpha ramp-up after spawning
var fade_out: float = 0.0           # seconds of alpha ramp-down before expiry
var _base_color: Color = Color.WHITE
var _has_base_color: bool = false

const FOG_SHADER = preload("res://vfx/Shaders/fog.gdshader")

signal fog_expired(fog: FogOverlay)

func _ready() -> void:
	# Ensure we have a shader material when created via code
	if not material or not material is ShaderMaterial:
		var mat = ShaderMaterial.new()
		mat.shader = FOG_SHADER
		material = mat

func apply_data(data: FogData) -> void:
	size = data.size
	# Don't set ColorRect.color — the shader handles all color output
	color = Color.WHITE

	# Make sure material exists (in case apply_data is called before _ready)
	if not material or not material is ShaderMaterial:
		var mat = ShaderMaterial.new()
		mat.shader = FOG_SHADER
		material = mat

	_base_color = data.color
	_has_base_color = true
	material.set_shader_parameter("fog_color", data.color)
	material.set_shader_parameter("density", data.density)
	material.set_shader_parameter("scale", data.scale)
	material.set_shader_parameter("speed", data.speed)
	material.set_shader_parameter("falloff_radius", data.falloff_radius)
	material.set_shader_parameter("falloff_softness", data.falloff_softness)
	material.set_shader_parameter("edge_wobble", data.edge_wobble)
	# Unique seed per overlay: the noise is otherwise identical for every cloud,
	# so a cluster of smoke puffs would all share one silhouette.
	material.set_shader_parameter("noise_seed", Vector2(randf() * 128.0, randf() * 128.0))

func update(delta: float, characters: Array) -> void:
	if drift != Vector2.ZERO:
		position += drift * delta
	if duration > 0:
		elapsed += delta
		if elapsed >= duration:
			fog_expired.emit(self)
			return
		_update_opacity()
	if condition_id.is_empty():
		return
	_apply_timer += delta
	if _apply_timer < apply_interval:
		return
	_apply_timer = 0.0
	var fog_rect = Rect2(global_position, size)
	for character in characters:
		if not is_instance_valid(character):
			continue
		if not character.has_method("is_alive") or not character.is_alive():
			continue
		if not fog_rect.has_point(character.global_position):
			continue
		var cm = _get_condition_manager(character)
		if cm:
			cm.apply_condition(condition_id, source, condition_stacks, condition_duration_override)

func set_fade_envelope(p_fade_in: float, p_fade_out: float) -> void:
	"""Configure the alpha ramp and apply it IMMEDIATELY, so a cloud that is
	supposed to fade in doesn't render one frame at full opacity before update()
	first runs. Note the ramp is only advanced while `duration > 0`; an infinite
	fog keeps whatever alpha this call sets."""
	fade_in = p_fade_in
	fade_out = p_fade_out
	_update_opacity()

# Alpha envelope for drifting clouds: ramp in so a plume doesn't pop into
# existence, ramp out so it thins away instead of vanishing on one frame. Drives
# the shader's fog_color alpha because fog.gdshader assigns COLOR outright and
# therefore ignores CanvasItem.modulate.
func _update_opacity() -> void:
	if not _has_base_color or (fade_in <= 0.0 and fade_out <= 0.0):
		return
	if not material or not material is ShaderMaterial:
		return
	var k: float = 1.0
	if fade_in > 0.0:
		k = minf(k, clampf(elapsed / fade_in, 0.0, 1.0))
	if fade_out > 0.0 and duration > 0.0:
		var remaining: float = duration - elapsed
		k = minf(k, clampf(remaining / fade_out, 0.0, 1.0))
	var c: Color = _base_color
	c.a = _base_color.a * k
	material.set_shader_parameter("fog_color", c)


func _get_condition_manager(character: Node) -> ConditionManager:
	var cm = character.get_node_or_null("ConditionManager")
	if not cm and character.has_method("get_condition_manager"):
		cm = character.get_condition_manager()
	return cm
