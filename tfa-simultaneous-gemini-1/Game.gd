# res://Game.gd
extends Node2D

@onready var characters_container: Node2D = $CharactersContainer
# NEW: A container for our structure objects
@onready var structures_container: Node2D = $StructuresContainer
@onready var floors_container: Node2D = $FloorsContainer
@onready var items_container: Node2D = $ItemsContainer
@onready var player_camera: Camera2D = $PlayerCamera
@onready var game_ui: GameUI = $GameUI
# UPDATED: We now just need the ground layer for coordinate conversion
@onready var ground_layer: TileMapLayer = $GridContainer/GroundLayer
@onready var highlights_layer: TileMapLayer = $GridContainer/HighlightsLayer # Add this line

const CharacterScene = preload("res://Characters/Character.tscn")
const StructureScene = preload("res://Structures/Structure.tscn")
const FloorScene = preload("res://Structures/Floors/floor.tscn")
const ItemScene = preload("res://Structures/Objects/Item.tscn")
var player_input_manager: PlayerInputManager
var combat_manager: CombatManager
var character: CombatCharacter

var is_active_combat = false
var context_menu_open = false
var party_ids = ["Protagonist", "Jacana"]
var party_chars = []
var characters_in_scene = []
var objects_in_scene = []
var structures_in_scene = []
var rotations = generate_random_array(1,4,100, 12345)
var color_offsets = generate_random_float_array(1.0, 1.0, 100, 48273)

func _ready():
	# UPDATED: Initialize the GridManager with the ground layer
	GridManager.initialize(ground_layer, highlights_layer)
	setup_managers()
	setup_input_actions()
	
	# NEW: Spawn structures before characters
	load_map("perrow","Route 1")
		
	# Setup Input Map Actions if not already done (for testing)
	setup_input_actions()
	
	combat_manager.combat_started.connect(_on_combat_started)
	combat_manager.combat_ended.connect(_on_combat_ended)
	TimeManager.set_time_scale(30.0)
	# Collect all characters from container to start combat

func _on_combat_started():
	is_active_combat = true
func _on_combat_ended():
	is_active_combat = false
func _on_item_dropped(item_id, character):
	create_item(item_id, GridManager.map_to_world(character.global_position))
	
func load_map(map_id: StringName, coming_from: String):
	#print("Map definitions: ", MapDatabase.map_definitions)
	GridManager.active_map = map_id
	var Map = MapDatabase.map_definitions[map_id]
	for spawn_point in Map.pc_spawn_points:
		#print("spawn point: ", )
		if coming_from == spawn_point.coming_from:
			#create_character_from_database("Protagonist", Vector2i(spawn_point.party_member_1.x, spawn_point.party_member_1.y))
			var offset = 1
			for character_id in party_ids:
				#claude: add safety check for this square already being occupied
				var c = create_character_from_database(character_id, Vector2i(spawn_point.party_member_1.x+offset, spawn_point.party_member_1.y))
				#print("attempting to spawn: ", character_id, " at: ", Vector2i(spawn_point.party_member_1.x+offset, spawn_point.party_member_1.y))
				characters_container.add_child(c)
				party_chars.append(c)
				if character_id == "Protagonist":
					var protagonist = c
				print("party_chars: ", party_chars)
				c.dropped_item.connect(_on_item_dropped)
				var light = PointLight2D.new()
				# GENERATE A TEXTURE (Crucial Step)
				# Without a texture, the light is invisible. 
				var radius = 1440
				var degree = 150
				var tex = generate_cone_texture(radius,degree)
				#light.offset = Vector2(radius/8, 0) # Half of radius (optional tweaking)
				# Assign the generated texture to the light
				light.texture = tex
				light.name = "LineOfSight"
				light.rotation_degrees = 90
				light.shadow_enabled = true
				# This tells the light: "Cast shadows when you hit an occluder on Layer 1"
				light.shadow_item_cull_mask = 1
				light.z_index = 102
				c.add_child(light)
				
	print("spawned party successfully #map-loading")
	var x = 0
	var y = 0
	var end_x = Map.size_x 
	var end_y = Map.size_y 
	while x < end_x:
		y = 0
		while y < end_y:
			var rotation_index = int(x*y)
			var rotation_amount = rotations[rotation_index%100]
			var color_change = color_offsets[rotation_index%100]
			if not x % 15 and not y % 15:
				#print("x,y locations of floor: ", Vector2i(x,y))
				pass
			create_floor(Map.base_floor_type,Vector2i(x,y), rotation_amount, color_change)
			y += 1
		x += 1
	print("spawned base floor successfully")
	#print("attempting to spawn regions: ", Map.regions)
	for region in Map.regions:
		x = region.x 
		y = region.y
		end_x = x + region.size_x
		end_y = y + region.size_y
		 
		if region.floor_type:
			while x < end_x:
				y = region.y
				while y < end_y:
					var rotation_index = int(x*y)
					var rotation_amount = rotations[rotation_index%100]
					#print("rotation: ",rotation)
					var color_change = color_offsets[rotation_index%100]
					#print("color change: ", color_change)
					print(region.floor_type)
					create_floor(region.floor_type,Vector2i(x,y), rotation_amount,color_change)
					y += 1
				x += 1
		print("spawned first region's floor")
		if "wall_type" in region.keys():
			# Top and bottom walls
			var y_top = region.y
			var y_bottom = end_y - 1
			x = region.x
			end_x = x + region.size_x
			while x < end_x:
				var door = check_for_door(region, Vector2i(x, y_top))
				#print("door: ", door)
				if door:
					var d = create_structure(door.type, Vector2i(x, y_top))      # Top wall
				else: 
					var d = create_structure(region.wall_type, Vector2i(x, y_top))      # Top wall
					structures_in_scene.append(d)
					#print("spawning wall: ",region.wall_type)
					
				door = check_for_door(region, Vector2i(x, y_bottom))
				if door:
					var w = create_structure(door.type, Vector2i(x, y_bottom)) 
					structures_in_scene.append(w) 
				else:
					var w = create_structure(region.wall_type, Vector2i(x, y_bottom))   # Bottom wall
					structures_in_scene.append(w)
					#print("spawning wall: ",region.wall_type)
				x += 1
			# Left and right walls
			var x_left = region.x 
			var x_right = region.x + region.size_x
			y = region.y
			while y < end_y:
				var door = check_for_door(region, Vector2i(x_left, y))
				if door:
					create_structure(door.type, Vector2i(x_left, y))
				else: 
					create_structure(region.wall_type, Vector2i(x_left, y))     # Left wall
					#print("spawning wall: ",region.wall_type)

				door = check_for_door(region, Vector2i(x_right, y))
				if door:
					create_structure(door.type, Vector2i(x_right, y))
				else:
					create_structure(region.wall_type, Vector2i(x_right, y))    # Right wall
					#print("spawning wall: ",region.wall_type)
				y += 1
		print("spawned walls and doors")
		#print("grid_costs: ", GridManager.grid_costs)
		if "structures" in region.keys():	
			for structure in region.structures:
				#print("attempting to spawn")
				if structure.has("id"):
					create_structure(structure.id, Vector2i(structure.x,structure.y))
		#print("#spawning: ",region.keys())
		if "characters" in region.keys():	
			for character in region.characters:
				print("Attempting to spawn: ", character.id, " at ", Vector2i(character.x,character.y))
				var c = create_character_from_database(character.id, Vector2i(character.x,character.y))
				c.light_mask = 2
				c.visibility_layer = 2
				
				# --- Light MAT code---
				# 1. Create a new CanvasItemMaterial
				var light_mat = CanvasItemMaterial.new()
				# 2. Set the Light Mode to "Light Only"
				light_mat.light_mode = CanvasItemMaterial.LIGHT_MODE_LIGHT_ONLY

				# 3. Apply this material to all sprites under the "Body" node
				# We use a helper function to dig through the VBox/HBox/Equipment containers
				if c.has_node("Body"):
					_apply_material_recursive(c.get_node("Body"), light_mat)
				
		if "objects" in region.keys():
			for item in region.objects:
				
				print("Attempting to spawn ", item.id, " at ", Vector2i(item.x, item.y))
				# 1. Create a new CanvasItemMaterial
				var light_mat = CanvasItemMaterial.new()
				# 2. Set the Light Mode to "Light Only"
				light_mat.light_mode = CanvasItemMaterial.LIGHT_MODE_LIGHT_ONLY

				var i = create_item(item.id, Vector2i(item.x, item.y))
				if i.has_node("Sprite"):
					i.get_node("Sprite").material = light_mat
				
		if "fluids" in region.keys():
			for fluid in region.fluids:
				print("Attempting to spawn", fluid.id, " at ", Vector2i(fluid.x, fluid.y))
				GridManager.spawn_fluid_tile(Vector2i(fluid.x,fluid.y), 10)
				
	for structure in structures_container.get_children():
		if structure.structure_id.contains("wall"):
			check_neighbors(GridManager.world_to_map(structure.global_position), structure, structure.structure_id)
	for floor in floors_container.get_children():
			if floor.floor_id != "floor_dirt" and floor.floor_id != "floor_stone" and floor.floor_id != "floor_wood":
				check_floor_neighbors(GridManager.world_to_map(floor.global_position), floor, floor.floor_id)
func _apply_material_recursive(node: Node, material: Material):
	# Check if the node is a visual sprite (covers Sprite2D and TextureRect)
	if node is Sprite2D or node is TextureRect:
		node.material = material
		# Optional: Ensure the sprite itself is on the correct light mask if needed
		# node.light_mask = 2 
	# Continue digging deeper into children (Equipment, Containers, etc.)
	for child in node.get_children():
		_apply_material_recursive(child, material)	
func check_for_door(region, pos: Vector2i):
	if region.has("doors"):
					for door in region.doors:
						var door_pos = Vector2i(door.x , door.y)
						if door_pos == pos:
							return door
	return false
func add_characters_to_combat():
	for character in characters_in_scene:
		if character:
			character.combat_manager = combat_manager
			characters_container.add_child(character)

func generate_random_array(min_val: int, max_val: int, size: int, seed_value: int) -> Array:
	var rng = RandomNumberGenerator.new()
	rng.seed = seed_value  # Set the seed for deterministic results

	var result = []
	for i in range(size):
		result.append(90*rng.randi_range(min_val, max_val))
	return result

func generate_random_float_array(min_val: float, max_val: float, size: int, seed_value: int):
	var rng = RandomNumberGenerator.new()
	rng.seed = seed_value  # Set the seed for deterministic results
	var result = []
	for i in range(size):
		result.append(rng.randf_range(min_val, max_val))
	return result
func setup_managers():
	print("DEBUG: Setting up managers")
	
	# Create and setup CombatManager
	combat_manager = CombatManager.new()
	add_child(combat_manager)
	print("DEBUG: CombatManager created and added")
	
	# Create and setup PlayerInputManager
	player_input_manager = PlayerInputManager.new()
	add_child(player_input_manager)
	print("DEBUG: PlayerInputManager created and added")
	
	# Wait a frame to ensure both managers are fully ready
	await get_tree().process_frame
	
	# Connect managers to each other
	player_input_manager.combat_manager = combat_manager
	player_input_manager.setup_combat_manager_connections()
	print("DEBUG: Managers connected to each other")
	
	# Connect camera to PlayerInputManager signals
	player_input_manager.selection_changed.connect(_on_player_selection_changed_for_camera)
	player_input_manager.camera_recenter_request.connect(_on_camera_recenter_request)
	print("DEBUG: Camera signals connected")
	
	# NEW: Setup GameUI
	game_ui.setup(combat_manager, player_input_manager)
	print("DEBUG: GameUI setup")
	# Set combat_manager reference in characters (will be done when characters are spawned)
func trigger_time_based_event(time):
	pass
func setup_input_actions():
	if not InputMap.has_action("ui_accept"): 
		InputMap.add_action("ui_accept")
		var accept_event = InputEventKey.new()
		accept_event.keycode = KEY_SPACE
		InputMap.action_add_event("ui_accept", accept_event)
	if not InputMap.has_action("ui_cancel"): 
		InputMap.add_action("ui_cancel")
		var cancel_event = InputEventKey.new()
		cancel_event.keycode = KEY_ESCAPE
		InputMap.action_add_event("ui_cancel", cancel_event)

func create_character_from_database(character_id: String, position: Vector2) -> CombatCharacter:
	var character = CharacterScene.instantiate() as CombatCharacter
	if not character:
		print("Error: Failed to instantiate character scene")
		return null
	# Set character ID - this will automatically apply all character data
	character.character_id = character_id
	character.global_position =  GridManager.map_to_world(position)
	characters_in_scene.append(character)
	characters_container.add_child(character)
	#add as a child of characters container
	return character
# --- NEW: Spawning and Managing Structures ---
	
func get_entities_in_tiles(tiles: Array[Vector2i]) -> Array:
	var entities_found: Array = []
	var tile_set = {} # Use a dictionary for faster lookups
	for tile in tiles:
		tile_set[tile] = true
		
	for char in self.characters_in_scene:
		if is_instance_valid(char) and char.current_health > 0:
			var char_tile = GridManager.world_to_map(char.global_position)
			if tile_set.has(char_tile):
				entities_found.append(char)
	for struct in self.structures_in_scene:
		if is_instance_valid(struct) and struct.current_health > 0:
			var struct_tile = GridManager.world_to_map(struct.global_position)
			if tile_set.has(struct_tile):
				entities_found.append(struct)
	for obj in self.objects_in_scene:
		if is_instance_valid(obj):
			var struct_tile = GridManager.world_to_map(obj.global_position)
			if tile_set.has(struct_tile):
				entities_found.append(obj)
	#claude: add floors check
	print_debug("[CombatManager] Found ", entities_found.size(), " entities in ", tiles.size(), " tiles.")
	return entities_found

func create_floor(floor_id: StringName, grid_pos: Vector2i, rotation_amount, color_change):
	var floor = FloorScene.instantiate() as Floor
	
	if floor_id == "floor_stone" or floor_id == "floor_dirt":
		floor.get_node("Sprite").rotation_degrees = rotation_amount
	floor.get_node("Sprite").modulate = Color(color_change,color_change,color_change)
	
	floor.global_position = GridManager.map_to_world(grid_pos) 
	# The floor tells the GridManager how walkable it is
	floor.floor_id = floor_id
	GridManager.register_floor(grid_pos, floor)
	#var base_pos = GridManager.map_to_world(grid_pos)
	
	# Connect to its destroyed signal to update pathfinding
	floor.destroyed.connect(_on_floor_destroyed)
	
	floors_container.add_child(floor)
	

func create_structure(structure_id: StringName, grid_pos: Vector2i):
	var structure = StructureScene.instantiate() as Structure
	structure.structure_id = structure_id
	structure.global_position = GridManager.map_to_world(grid_pos)
	
	GridManager.register_obstacle(grid_pos)
	structure.destroyed.connect(_on_structure_destroyed)
	
	# 1. Add the child FIRST. 
	# This triggers structure._ready(), allowing it to load its texture.
	structures_container.add_child(structure)

	# 2. NOW generate the shadow. 
	# The texture is guaranteed to exist now (assuming structure._ready() loads it).
	if structure.has_node("Sprite"):
		var sprite = structure.get_node("Sprite")
		
		# Allow a tiny frame delay if textures load asynchronously (optional safety)
		if not sprite.texture:
			await get_tree().process_frame 
			
		if sprite.texture:
			var occluder = LightOccluder2D.new()
			var poly = OccluderPolygon2D.new()
			poly.cull_mode = OccluderPolygon2D.CULL_DISABLED
			
			# IMPORTANT: Match this to your Light's "Shadow Item Cull Mask"
			# If your light is set to Mask 1 (default), this must include 1.
			occluder.occluder_light_mask = 1 
			
			var size = sprite.texture.get_size()
			var w = size.x / 4.0
			var h = size.y / 4.0
			
			poly.polygon = PackedVector2Array([
				Vector2(-w, -h),
				Vector2(w, -h),
				Vector2(w, h),
				Vector2(-w, h)
			])
			
			occluder.occluder = poly
			structure.add_child(occluder)
			print("Success: Shadow added for ", structure_id)
		else:
			push_error("FAIL: Still no texture for " + str(structure_id) + ". Check Structure.gd _ready()")
	
func create_item(item_id: StringName, grid_pos: Vector2i):
	var item = ItemScene.instantiate() as Item
	item.item_id = item_id
	item.global_position = GridManager.map_to_world(grid_pos)
	if ItemDatabase.item_definitions[item_id].has("light"):
		spawn_light(item.global_position, ItemDatabase.item_definitions[item_id].light)
	# The structure tells the GridManager it's an obstacle
	GridManager.register_object(grid_pos, item)
	
	# Connect to its destroyed signal to update pathfinding
	item.destroyed.connect(_on_item_destroyed)
	items_container.add_child(item)
	objects_in_scene.append(item)
	return item
	
func spawn_light(target_position: Vector2, brightness: float):
	# 1. Create the node
	var light = PointLight2D.new()

	# 2. Set essential properties
	light.position = target_position
	light.energy = brightness

	# 3. GENERATE A TEXTURE (Crucial Step)
	# Without a texture, the light is invisible. 
	# We will create a procedural "soft ball" of light here.
	var tex = GradientTexture2D.new()
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.width = 256
	tex.height = 256

	# Set the gradient center to the middle (0.5, 0.5) and radius edge to top (0.5, 0.0)
	tex.fill_from = Vector2(0.5, 0.5) 
	tex.fill_to = Vector2(0.5, 0.0)

	# Create the color ramp: White (center) to Black (edge)
	# Note: Use Transparent instead of Black if using "Add" blend mode
	var grad = Gradient.new()
	grad.colors = PackedColorArray([Color.WHITE, Color.GOLD]) 
	tex.gradient = grad

	# Assign the generated texture to the light
	light.texture = tex
	light.z_index = 102
	# 4. Add to the scene tree
	add_child(light)
func check_neighbors(grid_pos, structure, structure_id):
	var top = Vector2i(grid_pos.x, grid_pos.y -1)
	var right = Vector2i(grid_pos.x+1, grid_pos.y)
	var bottom = Vector2i(grid_pos.x, grid_pos.y+1)
	var left = Vector2i(grid_pos.x-1, grid_pos.y)
	var top_neighbor = ""
	var right_neighbor = ""
	var bottom_neighbor = ""
	var left_neighbor = ""
	#print("grid manager has top? #structure " , GridManager.grid_costs.has(top))
	if GridManager.grid_costs.has(top):
		if GridManager.walls[top]: 
			top_neighbor = "Top" 
	if GridManager.grid_costs.has(right):
		if GridManager.walls[right]:
			right_neighbor = "Right" 
	if GridManager.grid_costs.has(bottom):
		if GridManager.walls[bottom]:
			bottom_neighbor = "Bottom" 
	if GridManager.grid_costs.has(left):
		if GridManager.walls[left]:
			left_neighbor = "Left" 
	#print("structure data: ", StructureDatabase.structure_data[structure_id])
	if top_neighbor or right_neighbor or left_neighbor or bottom_neighbor:
		var texture_path = "res://Structures/"+ StructureDatabase.structure_data[structure_id].display_name + " " + top_neighbor + right_neighbor + bottom_neighbor + left_neighbor + ".png" 
		StructureDatabase.structure_data[structure_id].texture = texture_path
		#print("structure texture path: ", texture_path)
		structure.change_texture(texture_path)
		
func check_floor_neighbors(grid_pos, floor, floor_id):
	var top = Vector2i(grid_pos.x, grid_pos.y -1)
	var right = Vector2i(grid_pos.x+1, grid_pos.y)
	var bottom = Vector2i(grid_pos.x, grid_pos.y+1)
	var left = Vector2i(grid_pos.x-1, grid_pos.y)
	var top_neighbor = ""
	var right_neighbor = ""
	var bottom_neighbor = ""
	var left_neighbor = ""
	#print("grid manager has top? #structure " , GridManager.grid_costs.has(top))
	if GridManager.grid_costs.has(top):
		if GridManager.floors[top] == floor_id: 
			top_neighbor = "Top" 
	if GridManager.grid_costs.has(right):
		if GridManager.floors[right] == floor_id:
			right_neighbor = "Right" 
	if GridManager.grid_costs.has(bottom):
		if GridManager.floors[bottom] == floor_id:
			bottom_neighbor = "Bottom" 
	if GridManager.grid_costs.has(left):
		if GridManager.floors[left] == floor_id:
			left_neighbor = "Left" 
	#print("structure data: ", StructureDatabase.structure_data[structure_id])
	if top_neighbor or right_neighbor or left_neighbor or bottom_neighbor:
		var texture_path = "res://Structures/Floors/"+ FloorDatabase.floor_definitions[floor_id].name + " " + top_neighbor + right_neighbor + bottom_neighbor + left_neighbor + ".png" 
		#print("floor texture path: ", texture_path)

		FloorDatabase.floor_definitions[floor_id].texture = texture_path
		#print("structure texture path: ", texture_path)
		floor.change_texture(texture_path)
		
func _on_structure_destroyed(structure: Structure, grid_position: Vector2i):
	# When a structure is destroyed, it tells the GridManager its tile is now open
	GridManager.unregister_obstacle(grid_position)
	for pos in GridManager.get_neighboring_coords(grid_position):
		check_neighbors(pos,structure, structure.structure_id)
	
func _on_floor_destroyed(floor: Floor, grid_position: Vector2i):
	# When a structure is destroyed, it tells the GridManager its tile is now open
	GridManager.unregister_floor(grid_position)
	for pos in GridManager.get_neighboring_coords(grid_position):
		check_neighbors(pos,floor, floor.floor_id)
	#claude: find floor at that grid_position now that this one is gone and reregister it.
func _on_item_destroyed(item: Item, grid_position: Vector2i):
	GridManager.unregister_item(grid_position)
	for item_name in item.resources.keys():
		create_item(ItemDatabase.item_name,grid_position) # need to update to check if this square is occupied
# Alternative method if you want to override specific properties
# I think this is deprecated
func create_custom_character(character_id: String, position: Vector2, overrides: Dictionary = {}) -> CombatCharacter:
	var character = create_character_from_database(character_id, position)
	if not character:
		return null
	# Apply any custom overrides
	for property in overrides.keys():
		if character.get(property) != null:
			character.set(property, overrides[property])
		else:
			print("Warning: Property '", property, "' not found on character")
	
	return character

func generate_cone_texture(radius: int, angle_deg: float) -> ImageTexture:
	# 1. Create a new empty image with RGBA channels
	var size = radius * 2
	var img = Image.create(size, size, false, Image.FORMAT_RGBA8)

	var center = Vector2(radius, radius)
	var angle_rad = deg_to_rad(angle_deg)

	# 2. Loop through every pixel to decide if it's inside the "Cone"
	for y in range(size):
		for x in range(size):
			var pixel_pos = Vector2(x, y)
			var dir = pixel_pos - center
			var dist = dir.length()

			# Skip pixels outside the circle radius (optimization)
			if dist > radius:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			
			# Calculate angle of this pixel relative to the Right (0 degrees)
			# We use `angle_to` to check the deviation from Vector2.RIGHT
			var angle_diff = abs(Vector2.RIGHT.angle_to(dir))

			# 3. Check if the pixel is within our cone angle
			if angle_diff < angle_rad / 2.0:
				# Calculate simple falloff (dimmer further away)
				var alpha = 1.0 - (dist / radius)
				# Apply squared falloff for softer light
				alpha = ease(alpha, 0.5) 

				# Set the pixel color (White with calculated transparency)
				img.set_pixel(x, y, Color(1, 1, 1, alpha))
			else:
				# Pixel is outside the cone angle -> Transparent
				img.set_pixel(x, y, Color(0, 0, 0, 0))
	
	# 4. Convert Image to Texture
	return ImageTexture.create_from_image(img)

func _on_player_selection_changed_for_camera(selected_chars: Array[CombatCharacter]):
	print("DEBUG: Camera selection changed. Selected chars count: ", selected_chars.size())
	for character in characters_container.get_children():
		character._update_selection_visual()
	if not selected_chars.is_empty() and player_input_manager and is_instance_valid(player_input_manager.primary_selected_character):
		print("DEBUG: Following primary selected character: ", player_input_manager.primary_selected_character.character_name)
		_set_camera_target(player_input_manager.primary_selected_character)
	elif not selected_chars.is_empty() and is_instance_valid(selected_chars[0]):
		print("DEBUG: Following first selected character: ", selected_chars[0].character_name)
		_set_camera_target(selected_chars[0])
	else:
		print("DEBUG: Clearing camera target")
		_clear_camera_target()

func _on_camera_recenter_request(target_pos: Vector2):
	print("DEBUG: Camera recenter requested to position: ", target_pos)
	
	if player_input_manager and is_instance_valid(player_input_manager.primary_selected_character):
		print("DEBUG: Recentering on primary character: ", player_input_manager.primary_selected_character.character_name)
		_set_camera_target(player_input_manager.primary_selected_character)
	else:
		print("DEBUG: Moving camera to specific position: ", target_pos)
		if not _is_following_node:
			var tween = create_tween()
			tween.tween_property(player_camera, "global_position", target_pos, 0.3)

var _camera_follow_target: Node2D = null
var _is_following_node: bool = false

func _set_camera_target(node: Node2D):
	print("DEBUG: Setting camera target to: ", node.name if node else "null")
	_camera_follow_target = node
	_is_following_node = true

func _clear_camera_target():
	print("DEBUG: Clearing camera target")
	_camera_follow_target = null
	_is_following_node = false

func _process(delta): # For camera following
	if _is_following_node and is_instance_valid(_camera_follow_target):
		# Smooth camera following
		var target_pos = _camera_follow_target.global_position
		player_camera.global_position = player_camera.global_position.lerp(target_pos, 5.0 * delta)
	elif _is_following_node: # Target became invalid
		_clear_camera_target()
