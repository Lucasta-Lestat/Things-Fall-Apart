class_name UnexploredFogLayer
extends ColorRect
# Door Kickers-style "never seen" filter quad. Covers the whole map and lets
# unexplored_fog.gdshader repaint everything beneath it (ground, structures,
# roofs) as a desaturated blue-grey wherever ExplorationManager's mask says no
# party member has ever had line of sight. Explored areas are fully
# transparent, so the live scene — sight cones included — shows through
# untouched.
#
# Parent under MapLoader: its children are freed on map unload, so teardown
# across warps is automatic (same contract as RoofLayer). The explored MASK is
# not ours — it lives in ExplorationManager and persists across warps.

# Above RoofLayer (120) AND roof-walkers (ProceduralCharacter.ROOF_WALKER_Z,
# 135) so every world-rendered thing in a never-seen area is filtered — a
# hearing-pulsed rooftop NPC must tint like its street-level twin. Intent UI
# that must stay readable over fog (path markers, targeting previews) sits at
# 150+; floating text at 200 pierces by design but is exploration-gated at its
# call sites instead.
const FOG_Z := 140
const FOG_SHADER := preload("res://vfx/shaders/unexplored_fog.gdshader")


func _ready() -> void:
	z_as_relative = false
	z_index = FOG_Z
	light_mask = 0  # sight-cone PointLight2Ds must not paint the fog quad
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # clicks fall through to the world
	position = Vector2.ZERO
	size = Vector2(GridManager.map_rect.size * GridManager.TILE_SIZE)
	color = Color.WHITE  # shader owns all color output
	var mat := ShaderMaterial.new()
	mat.shader = FOG_SHADER
	mat.set_shader_parameter("explored_mask", ExplorationManager.get_texture())
	material = mat
