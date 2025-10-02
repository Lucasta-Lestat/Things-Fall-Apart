# res://Data/Characters/BodyPartDatabase.gd
# Autoload Singleton
# Stores all the defined body parts available in the game.
extends Node

@export var body_parts: Dictionary = {}
var body_size = 70
var head_size = 40

func _ready():
	var body_part_names = ["Male Head 1", "Male Body 1", "Female Head 1", "Female Body 1", 
							"Male Orc Head 1", "Male Orc Body 1", "Female Orc Head 1", "Female Orc Body 1"]
	_define_body_parts(body_part_names)

func get_part_data(part_id: StringName) -> BodyPart:
	if body_parts.has(part_id):
		return body_parts[part_id]
	printerr("Body part with ID '", part_id, "' not found in database.")
	return null

func _define_body_parts(body_part_names: Array):
	const path_to_body_parts = "res://Characters/Assets/"
	for name in body_part_names:
		var body_part = BodyPart.new()
		body_part.id = name
		
		var path_to_front = path_to_body_parts + name + " Front.png"
		var path_to_back = path_to_body_parts + name + " Back.png"
		var path_to_left = path_to_body_parts + name + " Left.png"
		var path_to_right = path_to_body_parts + name + " Right.png"
		print("path to this part: ", path_to_front)
		
		body_part.texture_front = load(path_to_front)
		body_part.texture_back = load(path_to_back)
		body_part.texture_left = load(path_to_left)
		body_part.texture_right = load(path_to_right)
		if "Head" in name:
			body_part.type = "head"
			#resize 
			var image = body_part.texture_front.get_image()
			image = image.duplicate()
			image.resize(head_size,head_size, Image.INTERPOLATE_LANCZOS)
			var new_texture = ImageTexture.create_from_image(image)
			body_part.texture_front = new_texture
			
			var original_image = body_part.texture_back.get_image()
			image = original_image.duplicate()
			image.resize(head_size,head_size, Image.INTERPOLATE_LANCZOS)
			new_texture = ImageTexture.create_from_image(image)
			body_part.texture_back = new_texture
			
			image = body_part.texture_left.get_image()
			image.resize(head_size,head_size)
			image.resize(head_size,head_size, Image.INTERPOLATE_LANCZOS)
			new_texture = ImageTexture.create_from_image(image)
			body_part.texture_left = new_texture
			
			image = body_part.texture_right.get_image()
			image.resize(head_size,head_size)
			image.resize(head_size,head_size, Image.INTERPOLATE_LANCZOS)
			new_texture = ImageTexture.create_from_image(image)
			body_part.texture_right = new_texture
			
		elif "Body" in name:
			body_part.type = "body"
			#resize
			var image = body_part.texture_front.get_image()
			image = image.duplicate()
			image.resize(body_size,body_size, Image.INTERPOLATE_LANCZOS)
			var new_texture =  ImageTexture.create_from_image(image)
			body_part.texture_front = new_texture
			
			image = body_part.texture_back.get_image()
			image = image.duplicate()
			image.resize(body_size,body_size, Image.INTERPOLATE_LANCZOS)
			new_texture =  ImageTexture.create_from_image(image)
			body_part.texture_back = new_texture
			
			image = body_part.texture_left.get_image()
			image = image.duplicate()
			image.resize(body_size,body_size, Image.INTERPOLATE_LANCZOS)
			new_texture =  ImageTexture.create_from_image(image)
			body_part.texture_left = new_texture
			
			image = body_part.texture_right.get_image()
			image = image.duplicate()
			image.resize(body_size,body_size, Image.INTERPOLATE_LANCZOS)
			new_texture =  ImageTexture.create_from_image(image)
			body_part.texture_right = new_texture
			
		body_parts[body_part.id] = body_part
		
	
