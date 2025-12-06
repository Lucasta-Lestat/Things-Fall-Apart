extends Node2D
class_name LightningVFX

# Lightning properties
@export var start_position: Vector2 = Vector2.ZERO
@export var end_position: Vector2 = Vector2.ZERO
@export var color: Color = Color(0.7, 0.9, 1.0, 1.0)
@export var glow_color: Color = Color(0.4, 0.7, 1.0, 0.5)
@export var thickness: float = 3.0
@export var segments: int = 20
@export var displacement: float = 30.0
@export var jaggedness: float = 0.8
@export var lifetime: float = 0.3
@export var fade_time: float = 0.15

# Animation properties
@export var flicker_enabled: bool = true
@export var num_branches: int = 2
@export var branch_probability: float = 0.3

# Light properties
@export var light_enabled: bool = true
@export var light_energy: float = 1.5
@export var light_range: float = 200.0

var time_alive: float = 0.0
var points: Array[Vector2] = []
var branch_segments: Array[Array] = []
var point_light: PointLight2D

func _ready():
	if light_enabled:
		setup_light()
	print("lightning ready")
	generate_lightning()

func setup_light():
	point_light = PointLight2D.new()
	point_light.enabled = true
	point_light.energy = light_energy
	point_light.texture = create_radial_gradient()
	point_light.texture_scale = light_range / 128.0
	point_light.color = color
	point_light.blend_mode = Light2D.BLEND_MODE_ADD
	add_child(point_light)
	
	# Position light at midpoint
	var midpoint = (start_position + end_position) / 2.0
	point_light.position = midpoint

func create_radial_gradient() -> GradientTexture2D:
	print("creating gradient for lightning")
	var gradient = Gradient.new()
	gradient.set_color(0, Color.WHITE)
	gradient.set_color(1, Color(1, 1, 1, 0))
	
	var gradient_texture = GradientTexture2D.new()
	gradient_texture.gradient = gradient
	gradient_texture.fill = GradientTexture2D.FILL_RADIAL
	gradient_texture.fill_from = Vector2(0.5, 0.5)
	gradient_texture.fill_to = Vector2(1.0, 0.5)
	gradient_texture.width = GridManager.TILE_SIZE
	gradient_texture.height = GridManager.TILE_SIZE
	
	return gradient_texture

func generate_lightning():
	print("generate_lightning called")
	points.clear()
	branch_segments.clear()
	
	var direction = end_position - start_position
	var length = direction.length()
	var segment_length = length / segments
	
	points.append(start_position)
	
	# Generate main lightning path using midpoint displacement
	var current_points = [start_position, end_position]
	print("current_points for lightning: ", current_points)
	for iteration in range(int(log(segments) / log(2)) + 1):
		var new_points: Array[Vector2] = []
		
		for i in range(len(current_points) - 1):
			var p1 = current_points[i]
			var p2 = current_points[i + 1]
			print("tyring to construct newpoints for lightning")
			new_points.append(p1)
			
			# Midpoint with displacement
			var midpoint = (p1 + p2) / 2.0
			var perpendicular = (p2 - p1).rotated(PI / 2.0).normalized()
			
			# Add multiple sine waves for complex motion
			var progress = float(i) / max(1, len(current_points) - 1)
			var sine_offset = sin(progress * PI * 4.0 + randf() * PI) * displacement * 0.5
			sine_offset += sin(progress * PI * 7.0 + randf() * PI) * displacement * 0.3
			
			# Random jaggedness
			var random_offset = (randf() - 0.5) * displacement * jaggedness
			var total_offset = sine_offset + random_offset
			
			# Scale displacement down with each iteration
			total_offset *= pow(0.5, iteration)
			
			midpoint += perpendicular * total_offset
			new_points.append(midpoint)
			print("final newpoint for lightning")
		new_points.append(current_points[-1])
		current_points = new_points
	
	points = current_points
	
	# Generate branches
	if num_branches > 0:
		for i in range(num_branches):
			if randf() < branch_probability:
				generate_branch()
	
	queue_redraw()

func generate_branch():
	if points.size() < 3:
		print("lightning points size was less than 3: ", points.size())
		return
	
	# Pick a random point along the main bolt (not start or end)
	var branch_start_idx = randi_range(1, points.size() - 2)
	var branch_start = points[branch_start_idx]
	
	# Create a short branch
	var main_direction = end_position - start_position
	var branch_angle = randf_range(-PI/3, PI/3)
	var branch_direction = main_direction.rotated(branch_angle).normalized()
	var branch_length = main_direction.length() * randf_range(0.2, 0.4)
	
	var branch_points: Array[Vector2] = []
	branch_points.append(branch_start)
	
	var num_branch_segments = randi_range(3, 6)
	print("num_branch_segments for lightning")
	for i in range(1, num_branch_segments + 1):
		var t = float(i) / num_branch_segments
		var point = branch_start + branch_direction * branch_length * t
		
		# Add some wiggle to the branch
		var perpendicular = branch_direction.rotated(PI / 2.0)
		var offset = (randf() - 0.5) * displacement * 0.5
		point += perpendicular * offset
		
		branch_points.append(point)
	
	branch_segments.append(branch_points)

func _process(delta):
	time_alive += delta
	
	# Flicker effect
	if flicker_enabled and randf() > 0.7:
		print("queuing lightning redraw")
		queue_redraw()
	
	# Update light intensity
	if point_light:
		var fade_factor = 1.0
		if time_alive > lifetime - fade_time:
			fade_factor = (lifetime - time_alive) / fade_time
		
		point_light.energy = light_energy * fade_factor * randf_range(0.8, 1.0)
	
	# Auto-destroy after lifetime
	if time_alive >= lifetime:
		print("destroying lightning passed it's lifetime")
		queue_free()

func _draw():
	if points.size() < 2:
		return
	
	var fade_factor = 1.0
	if time_alive > lifetime - fade_time:
		fade_factor = (lifetime - time_alive) / fade_time
	
	var current_color = color
	current_color.a *= fade_factor
	
	var current_glow = glow_color
	current_glow.a *= fade_factor
	
	# Draw glow layers
	draw_polyline(points, current_glow, thickness * 3.0, true)
	draw_polyline(points, current_glow, thickness * 2.0, true)
	
	# Draw main lightning
	draw_polyline(points, current_color, thickness, true)
	
	# Draw branches
	for branch in branch_segments:
		if branch.size() >= 2:
			var branch_color = current_color
			branch_color.a *= 0.7
			var branch_glow = current_glow
			branch_glow.a *= 0.7
			
			draw_polyline(branch, branch_glow, thickness * 2.0, true)
			draw_polyline(branch, branch_color, thickness * 0.7, true)

# Helper function to create lightning between two positions
static func create_bolt(from: Vector2, to: Vector2, parent: Node) -> LightningVFX:
	var lightning = LightningVFX.new()
	lightning.start_position = from
	lightning.end_position = to
	parent.add_child(lightning)
	return lightning

# Helper function to create lightning strike at a grid position
static func create_strike_at_tile(grid_pos: Vector2i, parent: Node, height: float = 3.0) -> LightningVFX:
	var tile_center = Vector2(grid_pos) * GridManager.TILE_SIZE + Vector2.ONE * GridManager.TILE_SIZE / 2.0
	var start = tile_center - Vector2(0, GridManager.TILE_SIZE * height)
	var end = tile_center
	
	return create_bolt(start, end, parent)
