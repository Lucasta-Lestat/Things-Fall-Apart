extends Node2D
class_name LightningVFX

# Lightning properties
@export var start_position: Vector2 = Vector2.ZERO
@export var end_position: Vector2 = Vector2.ZERO
@export var color: Color = Color(0.85, 0.95, 1.0, 1.0)          # electric core
@export var glow_color: Color = Color(0.35, 0.6, 1.0, 0.55)     # blue glow
@export var halo_color: Color = Color(0.25, 0.25, 0.8, 0.22)    # outer violet halo
@export var thickness: float = 3.0
@export var segments: int = 20
@export var displacement: float = 30.0
@export var jaggedness: float = 0.8
@export var lifetime: float = 0.35
@export var fade_time: float = 0.15

# Animation properties
@export var flicker_enabled: bool = true
## How often the bolt re-rolls its path. The old behaviour redrew the *same*
## points, so the bolt was a static squiggle; re-generating is what makes it
## crackle.
@export var flicker_interval: float = 0.045
@export var num_branches: int = 3
@export var branch_probability: float = 0.75

# Impact flash
@export var flash_enabled: bool = true
@export var flash_time: float = 0.12
@export var flash_radius: float = 26.0

# Light properties
@export var light_enabled: bool = true
@export var light_energy: float = 1.5
@export var light_range: float = 200.0

var time_alive: float = 0.0
var points: PackedVector2Array = PackedVector2Array()
var branch_segments: Array[PackedVector2Array] = []
var point_light: PointLight2D
var impact_light: PointLight2D

var _flicker_accum: float = 0.0

func _ready() -> void:
	# Lightning is emissive: additive blending stops the glow layers from
	# muddying into a flat blue smear where they overlap.
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat

	if light_enabled:
		setup_light()
	generate_lightning()

func setup_light() -> void:
	var tex := create_radial_gradient()

	# Travelling glow along the bolt
	point_light = PointLight2D.new()
	point_light.enabled = true
	point_light.energy = light_energy
	point_light.texture = tex
	point_light.texture_scale = light_range / 128.0
	point_light.color = glow_color
	point_light.blend_mode = Light2D.BLEND_MODE_ADD
	point_light.range_item_cull_mask = CollisionLayers.LAMP_RANGE_MASK   # P3-B's crowns too
	add_child(point_light)
	point_light.position = (start_position + end_position) / 2.0

	# Hot flash where the bolt lands
	impact_light = PointLight2D.new()
	impact_light.enabled = true
	impact_light.energy = light_energy * 2.0
	impact_light.texture = tex
	impact_light.texture_scale = (light_range * 0.6) / 128.0
	impact_light.color = color
	impact_light.blend_mode = Light2D.BLEND_MODE_ADD
	impact_light.range_item_cull_mask = CollisionLayers.LAMP_RANGE_MASK
	add_child(impact_light)
	impact_light.position = end_position

func create_radial_gradient() -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color.WHITE)
	gradient.set_color(1, Color(1, 1, 1, 0))

	var gradient_texture := GradientTexture2D.new()
	gradient_texture.gradient = gradient
	gradient_texture.fill = GradientTexture2D.FILL_RADIAL
	gradient_texture.fill_from = Vector2(0.5, 0.5)
	gradient_texture.fill_to = Vector2(1.0, 0.5)
	gradient_texture.width = GridManager.TILE_SIZE
	gradient_texture.height = GridManager.TILE_SIZE

	return gradient_texture

func generate_lightning() -> void:
	points = _make_path(start_position, end_position, displacement)

	branch_segments.clear()
	for i in range(num_branches):
		if randf() < branch_probability:
			_generate_branch()

	queue_redraw()

## Recursive midpoint displacement between two endpoints.
func _make_path(from: Vector2, to: Vector2, disp: float) -> PackedVector2Array:
	var current := PackedVector2Array([from, to])
	var iterations := int(log(float(max(segments, 2))) / log(2.0)) + 1

	for iteration in range(iterations):
		var next := PackedVector2Array()
		var falloff: float = pow(0.55, float(iteration))

		for i in range(current.size() - 1):
			var p1: Vector2 = current[i]
			var p2: Vector2 = current[i + 1]
			next.append(p1)

			var midpoint: Vector2 = (p1 + p2) / 2.0
			var perpendicular: Vector2 = (p2 - p1).rotated(PI / 2.0).normalized()

			# A smooth sine sway plus per-point noise: the sway keeps the bolt
			# reading as one arc, the noise gives it the electric jitter.
			var progress: float = float(i) / float(max(1, current.size() - 1))
			var sway: float = sin(progress * PI * 3.0) * disp * 0.35
			var noise: float = (randf() - 0.5) * disp * jaggedness

			midpoint += perpendicular * (sway + noise) * falloff
			next.append(midpoint)

		next.append(current[current.size() - 1])
		current = next

	return current

func _generate_branch() -> void:
	if points.size() < 4:
		return

	# Fork from somewhere in the first two thirds so the branch has room to run
	var branch_start_idx := randi_range(1, int(points.size() * 0.66))
	var branch_start: Vector2 = points[branch_start_idx]

	var main_direction: Vector2 = end_position - start_position
	if main_direction.length() < 1.0:
		return
	var branch_angle: float = randf_range(-PI / 3.0, PI / 3.0)
	var branch_length: float = main_direction.length() * randf_range(0.18, 0.38)
	var branch_end: Vector2 = branch_start + main_direction.rotated(branch_angle).normalized() * branch_length

	branch_segments.append(_make_path(branch_start, branch_end, displacement * 0.6))

func _process(delta: float) -> void:
	time_alive += delta

	if flicker_enabled:
		_flicker_accum += delta
		if _flicker_accum >= flicker_interval:
			_flicker_accum = 0.0
			generate_lightning()

	var fade := _fade_factor()

	if point_light:
		point_light.energy = light_energy * fade * randf_range(0.75, 1.0)
	if impact_light:
		# Impact light is a hard flash that decays fast, then rides the fade
		var flash := _flash_factor()
		impact_light.energy = light_energy * (0.4 + 2.2 * flash) * fade

	# The flash animates every frame, so redraw even between flickers
	queue_redraw()

	if time_alive >= lifetime:
		queue_free()

func _fade_factor() -> float:
	if time_alive <= lifetime - fade_time:
		return 1.0
	return clamp((lifetime - time_alive) / fade_time, 0.0, 1.0)

func _flash_factor() -> float:
	if flash_time <= 0.0:
		return 0.0
	return clamp(1.0 - time_alive / flash_time, 0.0, 1.0)

func _draw() -> void:
	# Some callers (conditions, surfaces) instantiate the scene without setting
	# endpoints. Draw nothing rather than parking a flash blob at the origin.
	if points.size() < 2 or start_position.distance_to(end_position) < 1.0:
		return

	var fade := _fade_factor()

	var c_halo := halo_color
	c_halo.a *= fade
	var c_glow := glow_color
	c_glow.a *= fade
	var c_core := color
	c_core.a *= fade
	var c_hot := Color(1, 1, 1, fade)

	# Four layers: wide soft halo -> glow -> coloured core -> white filament.
	# The old version drew the same glow colour twice and had no hot centre, so
	# the bolt read as a fat blue line rather than lightning.
	draw_polyline(points, c_halo, thickness * 5.0, true)
	draw_polyline(points, c_glow, thickness * 2.6, true)
	draw_polyline(points, c_core, thickness * 1.2, true)
	draw_polyline(points, c_hot, thickness * 0.45, true)

	for branch in branch_segments:
		if branch.size() >= 2:
			var b_glow := c_glow
			b_glow.a *= 0.7
			var b_core := c_core
			b_core.a *= 0.75
			draw_polyline(branch, b_glow, thickness * 1.6, true)
			draw_polyline(branch, b_core, thickness * 0.6, true)

	if flash_enabled:
		var flash := _flash_factor()
		if flash > 0.0:
			# Impact bloom: a bright core that collapses, plus an expanding ring
			var bloom := Color(1, 1, 1, flash * 0.85 * fade)
			draw_circle(end_position, flash_radius * (0.35 + 0.65 * flash), bloom)
			var ring := color
			ring.a = flash * 0.6 * fade
			draw_arc(end_position, flash_radius * (1.6 - flash), 0.0, TAU, 24, ring, thickness * 0.8, true)
			# Muzzle spark at the caster's hand
			var muzzle := Color(1, 1, 1, flash * 0.5 * fade)
			draw_circle(start_position, flash_radius * 0.3 * flash, muzzle)

# Helper function to create lightning between two positions
static func create_bolt(from: Vector2, to: Vector2, parent: Node) -> LightningVFX:
	var lightning := LightningVFX.new()
	lightning.start_position = from
	lightning.end_position = to
	parent.add_child(lightning)
	return lightning

# Helper function to create lightning strike at a grid position
static func create_strike_at_tile(grid_pos: Vector2i, parent: Node, height: float = 3.0) -> LightningVFX:
	var tile_center := Vector2(grid_pos) * GridManager.TILE_SIZE + Vector2.ONE * GridManager.TILE_SIZE / 2.0
	var start := tile_center - Vector2(0, GridManager.TILE_SIZE * height)
	var end := tile_center

	return create_bolt(start, end, parent)
