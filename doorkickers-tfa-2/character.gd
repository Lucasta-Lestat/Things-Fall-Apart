# Character.gd, formerly ProceduralCharacterRenderer.gd
extends Node2D
class_name Character

signal animation_finished(animation_name)

@export var character_scale: float = 1.0
@export var walk_speed: float = 2.0

# Character appearance
@export var skin_color: Color = Color(0.9, 0.7, 0.6)
@export var hair_color: Color = Color(0.4, 0.2, 0.1)
@export var clothing_color: Color = Color(0.2, 0.3, 0.8)
@export var eye_color: Color = Color(0.3, 0.5, 0.8)

# Body part nodes
var torso_node: Node2D
var head_node: Node2D
var left_arm_node: Node2D
var right_arm_node: Node2D
var left_leg_node: Node2D
var right_leg_node: Node2D

# Animation state
var current_animation: String = "idle"
var animation_time: float = 0.0
var facing_direction: float = 0.0
var movement_vector: Vector2 = Vector2.ZERO
var is_walking: bool = false

# Body part dimensions (in pixels)
const TORSO_SIZE = Vector2(20, 28)
const HEAD_SIZE = Vector2(16, 16)
const ARM_LENGTH = 20
const ARM_WIDTH = 6
const LEG_LENGTH = 24
const LEG_WIDTH = 7

func _ready():
	create_body_parts()
	
func _process(delta):
	animation_time += delta
	update_animation()

func create_body_parts():
	# Create torso (center/root)
	torso_node = Node2D.new()
	torso_node.name = "Torso"
	add_child(torso_node)
	
	# Create head
	head_node = Node2D.new()
	head_node.name = "Head"
	head_node.position = Vector2(0, -TORSO_SIZE.y/2 - HEAD_SIZE.y/2)
	torso_node.add_child(head_node)
	
	# Create arms
	left_arm_node = Node2D.new()
	left_arm_node.name = "LeftArm"
	left_arm_node.position = Vector2(-TORSO_SIZE.x/2 - ARM_WIDTH/2, -TORSO_SIZE.y/4)
	torso_node.add_child(left_arm_node)
	
	right_arm_node = Node2D.new()
	right_arm_node.name = "RightArm" 
	right_arm_node.position = Vector2(TORSO_SIZE.x/2 + ARM_WIDTH/2, -TORSO_SIZE.y/4)
	torso_node.add_child(right_arm_node)
	
	# Create legs
	left_leg_node = Node2D.new()
	left_leg_node.name = "LeftLeg"
	left_leg_node.position = Vector2(-TORSO_SIZE.x/4, TORSO_SIZE.y/2 + LEG_WIDTH/2)
	torso_node.add_child(left_leg_node)
	
	right_leg_node = Node2D.new()
	right_leg_node.name = "RightLeg"
	right_leg_node.position = Vector2(TORSO_SIZE.x/4, TORSO_SIZE.y/2 + LEG_WIDTH/2)
	torso_node.add_child(right_leg_node)

func _draw():
	draw_character()

func draw_character():
	# Draw torso
	var torso_pos = torso_node.position
	draw_rect(Rect2(torso_pos - TORSO_SIZE/2, TORSO_SIZE), clothing_color)
	draw_rect(Rect2(torso_pos - TORSO_SIZE/2, TORSO_SIZE), Color.BLACK, false, 1.0)
	
	# Draw head
	var head_pos = torso_node.position + head_node.position
	draw_circle(head_pos, HEAD_SIZE.x/2, skin_color)
	draw_circle(head_pos, HEAD_SIZE.x/2, Color.BLACK, false, 1.0)
	
	# Draw hair (simple oval on top)
	draw_ellipse(Rect2(head_pos - Vector2(HEAD_SIZE.x/2, HEAD_SIZE.y/2 + 2), Vector2(HEAD_SIZE.x, HEAD_SIZE.y/2)), hair_color)
	
	# Draw eyes based on facing direction
	draw_eyes(head_pos)
	
	# Draw arms
	draw_limb(torso_node.position + left_arm_node.position, left_arm_node.rotation, ARM_LENGTH, ARM_WIDTH, skin_color)
	draw_limb(torso_node.position + right_arm_node.position, right_arm_node.rotation, ARM_LENGTH, ARM_WIDTH, skin_color)
	
	# Draw legs
	draw_limb(torso_node.position + left_leg_node.position, left_leg_node.rotation, LEG_LENGTH, LEG_WIDTH, clothing_color)
	draw_limb(torso_node.position + right_leg_node.position, right_leg_node.rotation, LEG_LENGTH, LEG_WIDTH, clothing_color)

func draw_eyes(head_pos: Vector2):
	var eye_offset = 4.0
	var eye_size = 2.0
	
	# Calculate eye positions based on facing direction
	var forward = Vector2(cos(facing_direction), sin(facing_direction))
	var right = Vector2(-forward.y, forward.x)
	
	var left_eye_pos = head_pos + right * eye_offset/2 + forward * 2
	var right_eye_pos = head_pos - right * eye_offset/2 + forward * 2
	
	# Draw eye whites
	draw_circle(left_eye_pos, eye_size, Color.WHITE)
	draw_circle(right_eye_pos, eye_size, Color.WHITE)
	
	# Draw pupils
	draw_circle(left_eye_pos + forward * 0.5, eye_size * 0.6, eye_color)
	draw_circle(right_eye_pos + forward * 0.5, eye_size * 0.6, eye_color)

func draw_limb(start_pos: Vector2, rotation: float, length: float, width: float, color: Color):
	var end_pos = start_pos + Vector2(cos(rotation), sin(rotation)) * length
	
	# Draw limb as a line with thickness
	draw_line(start_pos, end_pos, color, width)
	draw_line(start_pos, end_pos, Color.BLACK, 1.0)
	
	# Draw joint circles
	draw_circle(start_pos, width/2, color)
	draw_circle(end_pos, width/2, color)
	draw_circle(start_pos, width/2, Color.BLACK, false, 1.0)
	draw_circle(end_pos, width/2, Color.BLACK, false, 1.0)

func draw_ellipse(rect: Rect2, color: Color):
	var points = PackedVector2Array()
	var segments = 16
	var center = rect.position + rect.size * 0.5
	
	for i in segments:
		var angle = i * 2.0 * PI / segments
		var x = center.x + cos(angle) * rect.size.x * 0.5
		var y = center.y + sin(angle) * rect.size.y * 0.5
		points.append(Vector2(x, y))
	
	draw_colored_polygon(points, color)

func update_animation():
	match current_animation:
		"idle":
			update_idle_animation()
		"walk":
			update_walk_animation()
		"attack_melee":
			update_attack_animation()
	
	queue_redraw()

func update_idle_animation():
	# Subtle breathing animation
	var breath_offset = sin(animation_time * 2.0) * 0.5
	torso_node.position.y = breath_offset

func update_walk_animation():
	if not is_walking:
		return
		
	var cycle_time = 1.0 / walk_speed
	var walk_phase = fmod(animation_time, cycle_time) / cycle_time * 2.0 * PI
	
	# Leg animation - alternate stepping
	var leg_swing = sin(walk_phase) * 0.5  # +/- 0.5 radians
	left_leg_node.rotation = leg_swing
	right_leg_node.rotation = -leg_swing
	
	# Arm swing - opposite to legs for natural walking
	var arm_swing = sin(walk_phase + PI) * 0.3
	left_arm_node.rotation = arm_swing
	right_arm_node.rotation = -arm_swing
	
	# Slight torso bob
	torso_node.position.y = abs(sin(walk_phase * 2)) * 1.0

func update_attack_animation():
	# This will be overridden by IK system when attacking
	pass

func set_facing_direction(direction: float):
	facing_direction = direction
	torso_node.rotation = direction

func set_movement(velocity: Vector2):
	movement_vector = velocity
	is_walking = velocity.length() > 0.1
	
	if is_walking:
		current_animation = "walk"
		set_facing_direction(velocity.angle())
	else:
		current_animation = "idle"

func play_animation(anim_name: String):
	current_animation = anim_name
	animation_time = 0.0
