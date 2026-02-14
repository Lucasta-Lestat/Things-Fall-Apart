# res://Structures/Objects/Item.gd
# Attach this to a StaticBody2D scene for any destructible object that is not part of a building
extends AnimatableBody2D
class_name Item

signal destroyed(item, grid_position)

@export var item_id: StringName
var description: String
var weight: float
var cost = 1
var equip_slot = "Main Hand"
var use_ability = null
var healing = 0
var range = 50.0
var damage_modifiers = {} #should probably just fold this in with conditions
var adds_condition_on_equip = null
var triggers_ability_on_equip = null #e.g., explodes when picked up
var adds_condition_in_inventory = null
var is_stackable = false
var max_stack_size = 100
var num_stacks = null
var num_slots = 0
var key = null
var contents = null
var texture: String
var back_texture_path: String
var right_texture_path: String
var left_texture_path: String
var texture_front = null
var texture_back = null
var texture_right = null
var texture_left = null
var walkability = 1.1

var current_health: int
var max_health: int
var size: Vector2
var resources: Dictionary = {} # e.g., {"wood": 20}
var damage_resistances = {"slashing": 0, "bludgeoning": 0, "piercing": 0, "fire": 0, "cold": 0, "electric": 0, "sonic":0, "poison":0, "acid":0, "radiant":0, "necrotic":0 }
var damage: Dictionary = {"bludgeoning": 1}
var primary_damage_type = "bludgeoning"
@export var aoe_shape: StringName = &"slash"
@export var aoe_size: Vector2i = Vector2i.ONE

@onready var floating_text_label: RichTextLabel = $FloatingTextLabel
@onready var sprite: Sprite2D = $Sprite
@onready var collision_shape: CollisionShape2D = $CollisionShape2D

func _ready():
	_apply_item_data()
	# Snap to the grid
	floating_text_label.visible = false
	var grid_pos = GridManager.world_to_map(global_position)
	global_position = GridManager.map_to_world(grid_pos)

func _apply_item_data():
	var data = ItemDatabase.item_definitions[self.item_id]
	if not data:
		printerr("Failed to get data for item_id: ", item_id)
		return
	print("Applying item data for ",data.name)	
	max_health = data.max_health
	current_health = max_health
	resources = data.resources.duplicate()
	texture = "res://Items/" + data.name + ".png"
	print("Attempting texture path: ", texture)
	back_texture_path = "res://Items/" + data.name + " Back.png"
	right_texture_path = "res://Items/" + data.name + " Right.png"
	left_texture_path = "res://Items/" + data.name + " Left.png"
	#res://Equipment/Breastplate.png Breastplate
	if FileAccess.file_exists(texture):
		print("Found Texture Path for equipment")
		texture_front = load(texture)
		texture_back = load(back_texture_path)
		texture_right = load(right_texture_path)
		texture_left = load(left_texture_path)
		
	else:
		texture = "res://Structures/Item.png"
	description = data.description
	weight = data.weight
	cost = data.cost
	equip_slot = data.equip_slot
	if data.use_ability:
		use_ability = data.use_ability
	healing = data.healing
	range = data.range
	#var damage_modifiers = {} #should probably just fold this in with conditions
	if data.adds_condition_on_equip:
		adds_condition_on_equip = data.adds_conditions_on_equip
	if data.triggers_ability_on_equip:
		triggers_ability_on_equip = data.triggers_ability_on_equip
	if data.adds_condition_in_inventory:
		adds_condition_in_inventory = data.adds_condition_in_inventory
	is_stackable = data.is_stackable	
	max_stack_size = data.max_stack_size
	num_stacks = data.num_stacks
	num_slots = data.num_slots
	if data.key:
		key = data.key
	if data.contents:
		contents = data.contents
	walkability = data.walkability
	
	damage = data.damage
	primary_damage_type = data.primary_damage_type
	if primary_damage_type == "piercing":
		aoe_shape = &"thrust"
	sprite.texture = load(texture)
	size = Vector2(64,64)
	self.scale_sprite(size)
	print("texture_path: ", texture, " #items")
	''' On equip, if helmet, find direction of body, change helmet sprite texture to appropriate item direction texture'''


func take_damage(amount: Dictionary, success_level:int = 0):
	var damage_multiplier = pow(1.5,success_level)

	for damage_type in amount.keys():
		current_health = max(0, current_health - (amount[damage_type]*damage_multiplier - self.damage_resistances[damage_type]))
		print_rich(name, " takes ", amount[damage_type], damage_type,  " damage.", "crit tier:", success_level, " Health: ", current_health, "/", max_health)
		if damage_type == "fire": 
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
			
	var tween = create_tween()
	tween.tween_property(sprite, "modulate", Color.RED, 0.1)
	tween.tween_property(sprite, "modulate", Color.WHITE, 0.1)
	
	emit_signal("health_changed", current_health, max_health, self)
	
	if current_health <= 0:
		emit_signal("died", self); sprite.visible = false; $CollisionShape2D.disabled = true

func show_floating_text(text: String, color: Color = Color.WHITE, success_level = 0):
	var formatted_text = "[b]" + text + "[/b]" if success_level else text
	floating_text_label.text = formatted_text; floating_text_label.modulate = color
	# Make critical hit text bigger too
	var scale_multiplier = 1.3 * success_level if success_level else 1.0
	floating_text_label.scale = Vector2(scale_multiplier, scale_multiplier)
	
	floating_text_label.visible = true
	
	var tween = create_tween().set_parallel()
	tween.tween_property(floating_text_label, "position", Vector2(0, -70), 0.9).from(Vector2(0, -40))
	tween.tween_property(floating_text_label, "modulate:a", 0.0, 0.9)
	tween.chain().tween_callback(func(): floating_text_label.visible = false)
func _destroy_item():
	# Notify the game world that this tile is now clear
	emit_signal("destroyed", self, GridManager.world_to_map(global_position))
	
	# TODO: Implement spawning the actual resource items
	#want to spawn resources (which are also items) in stacks when destroyed
	#items that are themselves resources should not spawn anything.
	print_rich(item_id, " destroyed! Dropped: ", resources)
	
	queue_free()

func change_texture(texture_path):
	#print("attempting to update structure texture with: ", texture_path)
	$Sprite.texture = load(texture_path)
	
func scale_sprite(new_size):
	print("is sprite null: ", sprite)
	var initial_texture_size = sprite.texture.get_size()
	var size_ratio = new_size.x/initial_texture_size.x
	sprite.scale = Vector2(size_ratio,size_ratio)
