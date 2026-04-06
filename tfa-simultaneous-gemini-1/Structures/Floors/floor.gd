# res://Structures/floors/floor.gd
extends Node2D
class_name Floor

signal destroyed(floor, grid_position)

@export var floor_id: StringName 
@export var use_blend_shader: bool = false  # Toggle shader on/off
@export var blend_amount: float = 0.2  # Adjust per floor type if needed
var display_name: String
@export var current_health: int
var max_health: int
var texture: String
var size: Vector2 = Vector2(64,64)
var walkability: float = 1.0
var flammable: bool = false
var conductive: bool = false
var resources: Dictionary = {} #e.g. Wood:10 for a wooden floor
var damage_resistances = {"slashing": 0, "bludgeoning": 0, "piercing": 0, "fire": 0, "cold": 0, "electric": 0, "sonic":0, "poison":0, "acid":0, "radiant":0, "necrotic":0 }
var damage: Dictionary = {"Bludgeoning": 1}

@onready var floating_text_label: RichTextLabel = $FloatingTextLabel
@onready var sprite: Sprite2D = $Sprite
@onready var collision_shape: Area2D = $Area2D

var use_custom_texture: bool = false
var custom_texture: ImageTexture
var skip_grid_snap: bool = false

# Preload the shader material
const BLEND_SHADER = preload("res://Structures/floors/floor_blend_material.tres")

func _ready():
	apply_floor_data()
	floating_text_label.visible = false
	floating_text_label.z_index = 200
	floating_text_label.z_as_relative = false
	if not skip_grid_snap:
		var grid_pos = GridManager.world_to_map(global_position)
		global_position = GridManager.map_to_world(grid_pos)
	# Apply shader after texture is loaded
	if use_blend_shader:
		apply_blend_shader()

func apply_floor_data():
	var data = FloorDatabase.floor_definitions[self.floor_id]
	if not data:
		printerr("Failed to get data for floor_id: ", floor_id)
		return
	floor_id = data.id
	max_health = data.max_health
	current_health = max_health
	resources = data.resources.duplicate()
	walkability = data.walkability
	flammable = data.flammable
	conductive = data.conductive

	if use_custom_texture and custom_texture:
		sprite.texture = custom_texture
	elif "alternate_textures" in data.keys():
		sprite.texture = load(data.alternate_textures.pick_random())
	else:
		sprite.texture = load(data.texture)

		var initial_texture_size = sprite.texture.get_size()
		var size_ratio = size.x / initial_texture_size.x
		#sprite.scale = Vector2(size_ratio, size_ratio)

func apply_blend_shader():
	# Create a unique material instance for this floor
	var material = BLEND_SHADER.duplicate()
	
	# Optionally load a noise texture (create one in Godot or use procedural noise)
	# var noise = load("res://textures/noise.png")
	# material.set_shader_parameter("noise_texture", noise)
	
	# Set blend amount (can vary per floor type)
	material.set_shader_parameter("blend_amount", blend_amount)
	material.set_shader_parameter("noise_scale", randf_range(1.5, 2.5))
	
	sprite.material = material
	
func take_damage(amount: Dictionary, success_level:int = 0):
	var damage_multiplier = pow(1.5,success_level)
	var took_fire_damage = false

	for damage_type in amount.keys():
		current_health = max(0, current_health - (amount[damage_type]*damage_multiplier - self.damage_resistances[damage_type]))
		print_rich(name, " takes ", amount[damage_type], damage_type,  " damage.", "crit tier:", success_level, " Health: ", current_health, "/", max_health)
		if damage_type == "fire":
			took_fire_damage = true
			show_floating_text(str(amount[damage_type]), Color.CRIMSON, success_level)
		elif damage_type == "electric":
			show_floating_text(str(amount[damage_type]), Color.YELLOW, success_level)
		elif damage_type == "cold":
			show_floating_text(str(amount[damage_type]), Color.ALICE_BLUE, success_level)
		elif damage_type == "acid":
			show_floating_text(str(amount[damage_type]), Color.DARK_GREEN, success_level)
		elif damage_type == "radiant":
			show_floating_text(str(amount[damage_type]), Color.LIGHT_GOLDENROD, success_level)
		elif damage_type == "necrotic":
			show_floating_text(str(amount[damage_type]), Color.BLACK, success_level)
		elif damage_type == "poison":
			show_floating_text(str(amount[damage_type]), Color.BLUE_VIOLET, success_level)
		else:
			show_floating_text(str(amount[damage_type]), Color.WHITE_SMOKE, success_level)

	# Fire damage on flammable floors triggers ignition
	if took_fire_damage and flammable:
		var grid_pos = GridManager.world_to_map(global_position)
		var game = get_tree().get_first_node_in_group("game")
		if not game:
			game = get_tree().current_scene
		if game and "surface_manager" in game and game.surface_manager:
			game.surface_manager.try_ignite(grid_pos)

	var tween = create_tween()
	tween.tween_property(sprite, "modulate", Color.RED, 0.1)
	tween.tween_property(sprite, "modulate", Color.WHITE, 0.1)

	emit_signal("health_changed", current_health, max_health, self)

	if current_health <= 0:
		emit_signal("died", self)
		sprite.visible = false
		var col_shape = get_node_or_null("CollisionShape2D")
		if col_shape:
			col_shape.disabled = true
		var area = get_node_or_null("Area2D")
		if area:
			area.monitoring = false

func show_floating_text(text: String, color: Color = Color.WHITE, success_level = 0):
	var formatted_text = "[b]" + text + "[/b]" if success_level else text
	floating_text_label.text = formatted_text; floating_text_label.modulate = color
	# Make critical hit text bigger too
	var scale_multiplier = 0.91 * success_level if success_level else 0.7
	floating_text_label.scale = Vector2(scale_multiplier, scale_multiplier)
	
	floating_text_label.visible = true
	
	var tween = create_tween().set_parallel()
	tween.tween_property(floating_text_label, "position", Vector2(0, -70), 0.9).from(Vector2(0, -40))
	tween.tween_property(floating_text_label, "modulate:a", 0.0, 0.9)
	tween.chain().tween_callback(func(): floating_text_label.visible = false)
	
func _destroy_floor():
	# Unregister from grid before removal
	var grid_pos = GridManager.world_to_map(global_position)
	GridManager.unregister_floor(grid_pos)
	# Notify the game world that this tile is now clear
	emit_signal("destroyed", self, grid_pos)
	print_rich(floor_id, " destroyed! Dropped: ", resources, " (implement this with game.create_item()")

	queue_free()
func change_texture(texture_path):
	#print("attempting to update structure texture with: ", texture_path)
	$Sprite.texture = load(texture_path)
	
# Add to floor.gd
func _set_custom_texture(tex: ImageTexture):
	sprite.texture = tex
	# Recalculate scale to fit tile size
	var tex_size = tex.get_size()
	var ratio = size.x / tex_size.x
	sprite.scale = Vector2(ratio, ratio)
