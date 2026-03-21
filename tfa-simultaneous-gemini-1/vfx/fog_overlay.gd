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

	material.set_shader_parameter("fog_color", data.color)
	material.set_shader_parameter("density", data.density)
	material.set_shader_parameter("scale", data.scale)
	material.set_shader_parameter("speed", data.speed)

func update(delta: float, characters: Array) -> void:
	if duration > 0:
		elapsed += delta
		if elapsed >= duration:
			fog_expired.emit(self)
			return
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

func _get_condition_manager(character: Node) -> ConditionManager:
	var cm = character.get_node_or_null("ConditionManager")
	if not cm and character.has_method("get_condition_manager"):
		cm = character.get_condition_manager()
	return cm
