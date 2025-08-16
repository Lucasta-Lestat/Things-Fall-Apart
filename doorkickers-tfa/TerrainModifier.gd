# TerrainModifier.gd
extends Node2D
class_name TerrainModifier

# Modifies terrain properties to affect character physics

enum ModifierType {
	ICE,
	MUD,
	OIL,
	QUICKSAND,
	CONVEYOR,
	BOUNCY
}

@export var modifier_type: ModifierType = ModifierType.ICE
@export var area_size: Vector2 = Vector2(100, 100)
@export var duration: float = -1.0  # -1 = permanent

var affected_characters: Dictionary = {}  # Character -> original_friction

func _ready():
	_create_area()
	
	if duration > 0:
		await get_tree().create_timer(duration).timeout
		queue_free()

func _create_area():
	var area = Area2D.new()
	add_child(area)
	
	var shape = RectangleShape2D.new()
	shape.size = area_size
	var collision = CollisionShape2D.new()
	collision.shape = shape
	area.add_child(collision)
	
	# Visual
	var visual = ColorRect.new()
	visual.size = area_size
	visual.position = -area_size / 2
	
	match modifier_type:
		ModifierType.ICE:
			visual.color = Color(0.7, 0.9, 1.0, 0.4)
		ModifierType.MUD:
			visual.color = Color(0.4, 0.3, 0.2, 0.6)
		ModifierType.OIL:
			visual.color = Color(0.1, 0.1, 0.1, 0.7)
		ModifierType.QUICKSAND:
			visual.color = Color(0.8, 0.7, 0.5, 0.5)
		ModifierType.CONVEYOR:
			visual.color = Color(0.5, 0.5, 0.5, 0.3)
		ModifierType.BOUNCY:
			visual.color = Color(1.0, 0.5, 0.8, 0.3)
	
	add_child(visual)
	
	# Connect area signals
	area.body_entered.connect(_on_body_entered)
	area.body_exited.connect(_on_body_exited)
	
	area.collision_layer = 0
	area.collision_mask = 0b0100  # Characters

func _on_body_entered(body):
	if not body.has_method("get_parent"):
		return
	
	var character = body.get_parent()
	if not character is TopDownCharacterController:
		return
	
	var physics_body = character.physics_body
	if not physics_body:
		return
	
	# Store original friction
	affected_characters[character] = physics_body.friction_coefficient
	
	# Apply terrain effect
	match modifier_type:
		ModifierType.ICE:
			physics_body.friction_coefficient = 0.2
			physics_body.angular_damp = 0.5
		
		ModifierType.MUD:
			physics_body.friction_coefficient = 50.0
			physics_body.max_velocity = 100.0
		
		ModifierType.OIL:
			physics_body.friction_coefficient = 0.1
			physics_body.angular_damp = 0.1
			# Add random slip
			physics_body.apply_central_impulse(Vector2(randf_range(-50, 50), randf_range(-50, 50)))
		
		ModifierType.QUICKSAND:
			physics_body.friction_coefficient = 100.0
			physics_body.linear_damp = 20.0
			# Slowly sink (pull down in top-down means toward center)
			character.add_external_force(Vector2(0, 50), 999.0, "quicksand")
		
		ModifierType.CONVEYOR:
			# Add constant directional force
			character.add_external_force(Vector2(200, 0), 999.0, "conveyor")
		
		ModifierType.BOUNCY:
			physics_body.friction_coefficient = 5.0
			# Make character bounce on impact
			physics_body.physics_material_override = PhysicsMaterial.new()
			physics_body.physics_material_override.bounce = 0.8

func _on_body_exited(body):
	if not body.has_method("get_parent"):
		return
	
	var character = body.get_parent()
	if not character is TopDownCharacterController:
		return
	
	var physics_body = character.physics_body
	if not physics_body:
		return
	
	# Restore original friction
	if character in affected_characters:
		physics_body.friction_coefficient = affected_characters[character]
		affected_characters.erase(character)
	
	# Remove special effects
	match modifier_type:
		ModifierType.MUD:
			physics_body.max_velocity = 300.0
		
		ModifierType.OIL, ModifierType.ICE:
			physics_body.angular_damp = 5.0
		
		ModifierType.QUICKSAND:
			physics_body.linear_damp = physics_body.friction_coefficient
			# Remove sinking force
			for force in character.external_forces:
				if force.source == "quicksand":
					character.external_forces.erase(force)
		
		ModifierType.CONVEYOR:
			# Remove conveyor force
			for force in character.external_forces:
				if force.source == "conveyor":
					character.external_forces.erase(force)
		
		ModifierType.BOUNCY:
			physics_body.physics_material_override = null
