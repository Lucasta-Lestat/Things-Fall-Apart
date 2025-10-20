# res://Characters/Character.gd
extends CharacterBody2D
class_name CombatCharacter

# --- NEW: Preload the scene for our persistent previews ---
const ActionPreviewVisualScene = preload("res://Characters/ActionPreviewVisual.tscn")

# --- Signals ---
signal health_changed(new_health, max_health, character)
signal planned_action_for_slot(character, slot_index, action)
signal died(character)
signal no_more_ap_to_plan(character)
signal dropped_item(item_id)

# --- Properties ---
enum Allegiance { PLAYER, ENEMY, NEUTRAL }
@export var character_id: String:
	set(value):
		character_id = value
		if is_inside_tree(): _apply_character_data()

# --- Stats & Attributes ---
var character_name: String = "Unnamed"
var icon: String
var allegiance: Allegiance = Allegiance.NEUTRAL
var max_health: int = 100
var current_health: int = 100
var max_ap_per_round: int = 4
var current_ap_for_planning: int = 4
var strength := 50
var dexterity := 50
var constitution := 50 
var will := 50
var intelligence := 10
var charisma := 10
var touch_range: float = 50.0
var base_size: int = 64
var traits: Dictionary = {}
var abilities: Array[Ability] = []
var planned_actions: Array[PlannedAction] = []
var damage_resistances = {"slashing": 0, "bludgeoning": 0, "piercing": 0, "fire": 0, "cold": 0, "electric": 0, "sonic":0, "poison":0, "acid":0, "radiant":0, "necrotic":0 }

# --- UNIFIED EQUIPMENT SLOTS ---

var equipment = {"Main Hand": Item , "Off Hand": Item, "Head": Item, "Chest": Item, 
				"Gloves": Item, "Boots": Item, "Cape": Item, "Neck": Item, "Back": Item, "Ring1":Item, "Ring2": Item }


var is_selected: bool = false:
	set(value):
		is_selected = value
		_update_selection_visual()

# --- Movement State ---
var current_path: Array[Vector2i] = []
var path_index: int = 0
var is_moving: bool = false
@export var move_speed: float = 250.0 # Pixels per second
enum Direction { DOWN, UP, LEFT, RIGHT }
var current_direction: Direction = Direction.DOWN
var body_part_data: Dictionary = {} # Stores the loaded BodyPart resources

# --- Preview State ---
# --- NEW: Array to hold persistent planned action previews ---
var planned_action_previews: Array[Node2D] = []
var cumulative_path_points: PackedVector2Array = PackedVector2Array()
var preview_positions: Array[Vector2] = [] # Track position after each action
var range_preview_squares: Array[ColorRect] = [] # For range/AOE preview
var planned_aoe_squares: Array[ColorRect] = [] # NEW: For persistent planned AoEs


# --- Scene Node References ---
@onready var visuals_container: Node2D = $Body
@onready var body_sprite: Sprite2D = $Body/VBoxContainer/BodySprite
@onready var head_sprite: Sprite2D = $Body/VBoxContainer/HeadSprite
@onready var helmet_sprite: Sprite2D = $Body/Equipment/HelmetSprite
@onready var armor_sprite: Sprite2D = $Body/Equipment/ArmorSprite
@onready var selection_visual: Sprite2D = $SelectionVisual  # Changed from Polygon2D to Sprite2D
@onready var floating_text_label: RichTextLabel = $FloatingTextLabel
@onready var preview_container: Node2D = $PreviewContainer
@onready var path_preview_line: Line2D = $PreviewContainer/PathPreviewLine

# This is now the TEMPORARY preview for targeting
@onready var temp_action_preview: Node2D = $PreviewContainer/TempActionPreview
@onready var temp_preview_body: Sprite2D = $PreviewContainer/TempActionPreview/PreviewBodySprite
@onready var temp_preview_head: Sprite2D = $PreviewContainer/TempActionPreview/PreviewHeadSprite

@onready var temp_path_preview: Line2D = $PreviewContainer/TempPathPreview
# --- Visual Settings ---
@export var selection_ring_texture: Texture2D # Assign ring texture in inspector
@export var selection_ring_scale: Vector2 = Vector2(1.5, 1.5)
@export var selection_ring_offset: Vector2 = Vector2(0, 32) # Offset to place at character's feet


var combat_manager: CombatManager
var vfx_manager: VfxSystem

# --- Godot Lifecycle ---
func _ready():
	if not character_id.is_empty(): _apply_character_data()
	global_position = GridManager.map_to_world(GridManager.world_to_map(global_position))
	
	# Setup selection visual as a ring sprite
	if selection_visual:
		selection_visual.visible = false
		if selection_ring_texture:
			selection_visual.texture = selection_ring_texture
			selection_visual.scale = selection_ring_scale
			selection_visual.position = selection_ring_offset
			selection_visual.z_index = 1 # Place behind character
	
	floating_text_label.visible = false
		
	temp_path_preview.default_color = Color(0.0, 0.0, 0.0, 0.5)
#	preview_container.add_child(temp_path_preview)
	#body_sprite.texture = body_part_data["body"].texture_front
	# Hide the original preview sprite since we'll create dynamic ones
	temp_action_preview.visible = false
	hide_previews()

func _process(_delta):
	if not is_moving and not current_path.is_empty():
		_move_along_path()

func _move_along_path():
	print("Move Along Path Called #movement")
	if path_index >= current_path.size():
		current_path.clear(); path_index = 0
		return

	is_moving = true
	var current_tile = GridManager.world_to_map(global_position)
	var target_tile = current_path[path_index]
	var target_world_pos = GridManager.map_to_world(target_tile)
	
	# --- Direction Handling ---
	var direction_vector = target_tile - current_tile
	_update_direction(direction_vector)
	
	var duration = global_position.distance_to(target_world_pos) / move_speed
	var tween = create_tween()
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(self, "global_position", target_world_pos, duration)
	tween.tween_callback(func(): path_index += 1; is_moving = false)
# --- VISUALS LOGIC ---
# NEW Helper function to determine direction from a vector
func _get_direction_from_vector(vector: Vector2i) -> Direction:
	if abs(vector.x) > abs(vector.y):
		if vector.x > 0: return Direction.RIGHT
		else: return Direction.LEFT
	else:
		if vector.y > 0: return Direction.DOWN
		else: return Direction.UP
	return Direction.DOWN # Default fallback

func _update_direction(direction_vector: Vector2i):
	# This function now uses the helper
	var new_direction = _get_direction_from_vector(direction_vector)
	if new_direction != current_direction:
		current_direction = new_direction
		print_debug(character_name, " facing ", Direction.keys()[current_direction])
		_update_visual_sprites()

func _update_visual_sprites():
	if body_part_data.is_empty(): return
	
	var body_data: BodyPart = body_part_data.get("body")
	var head_data: BodyPart = body_part_data.get("head")

	if body_data:
		match current_direction:
			Direction.DOWN: body_sprite.texture = body_data.texture_front
			Direction.UP: body_sprite.texture = body_data.texture_back
			Direction.LEFT: body_sprite.texture = body_data.texture_left
			Direction.RIGHT: body_sprite.texture = body_data.texture_right
	
	if head_data:
		match current_direction:
			Direction.DOWN: head_sprite.texture = head_data.texture_front
			Direction.UP: head_sprite.texture = head_data.texture_back
			Direction.LEFT: head_sprite.texture = head_data.texture_left
			Direction.RIGHT: head_sprite.texture = head_data.texture_right
			
	if equipment.Head:
		match current_direction:
			Direction.DOWN: helmet_sprite.texture = equipment.Head.texture
			Direction.UP: helmet_sprite.texture = equipment.Head.texture_back
			Direction.LEFT: helmet_sprite.texture = equipment.Head.texture_left
			Direction.RIGHT: helmet_sprite.texture = equipment.Head.texture_right
			
	if equipment.chest:
		print("Chest is real")
		match current_direction:
			Direction.DOWN: armor_sprite.texture = equipment.Chest.texture
			Direction.UP: armor_sprite.texture = equipment.Chest.texture_back
			Direction.LEFT: armor_sprite.texture = equipment.Chest.texture_left
			Direction.RIGHT: armor_sprite.texture = equipment.Chest.texture_right
#check in database how characters are actually equipped			
# --- Core Logic ---
func execute_planned_action(action: PlannedAction):
	if is_moving:
		current_path.clear(); path_index = 0; is_moving = false
		
	var ability = AbilityDatabase.get_ability(action.ability_id)
	if not ability: print_rich("[color=red]ERROR: Ability not found: ", action.ability_id, "[/color]"); return
	var roll = randi() % 100 + 1
	var success_target = get_stat_by_name(ability.success_stat)
	
	if ability.success_stat:
		var bonus = 0
		for trait_id in ability.advantages:
			if traits.has(trait_id): bonus += 20 * traits[trait_id]
		for trait_id in ability.disadvantages:
			if traits.has(trait_id): bonus -= 20 * traits[trait_id]
		success_target += bonus
		
	var success_level = _calculate_success_level(roll, success_target)

	if ability.effect == Ability.ActionEffect.MOVE:
		var start_tile = GridManager.world_to_map(global_position)
		var end_tile = GridManager.world_to_map(action.target_position)
		current_path = GridManager.find_path(start_tile, end_tile)
		var move_range_tiles = get_effective_range(ability)
		if current_path.size() > move_range_tiles:
			current_path.resize(move_range_tiles)
		path_index = 0
		
	
	elif ability.effect == Ability.ActionEffect.DAMAGE:
		if success_level > 0 :
			var affected_tiles = get_affected_tiles(ability, global_position, action.target_position)
			var targets = combat_manager.get_entities_in_tiles(affected_tiles)
			show_shader(ability, action)

			if targets.is_empty():
				print_rich("  [color=gray]Attack hits nothing.[/color]")
				return
				
			print_rich("[color=orange]Executing Damage Action: ", ability.display_name, "[/color]")
			var base_damage = {}
			for entity in targets:
				if ability.is_weapon_attack:
					if is_instance_valid(entity) and entity.has_method("take_damage"):
						if equipment["Main Hand"]:
							base_damage = equipment["Main Hand"].damage 
							base_damage[equipment["Main Hand"].primary_damage_type] +=  strength/5
							#for damage_type in damage:
								#damage[damage_type] *= damage_multiplier
						else: 
							base_damage = {"bludgeoning": (1 + strength/5) }
				else:
					base_damage = ability.damage
					#for damage_type in base_damage:
					#		pass
							#damage[damage_type] *= damage_multiplier
				if is_instance_valid(entity) and entity.has_method("take_damage"):
					#print_rich("  [color=green]HIT:[/color] ", entity.name, " for ", damage, " damage.")
					entity.take_damage(base_damage, success_level, ability.primary_damage_type)
		else:
			print_rich(" [color=yellow]MISS![/color] (Rolled ", roll, " vs target of ", success_target, ")")
			show_floating_text("Miss", Color.WHITE_SMOKE)
					
func show_shader(ability:Ability, action:PlannedAction):
	print("showing shader for ", ability.primary_damage_type)
	
	VfxSystem.create_effect(action.target_position, GridManager.TILE_SIZE*ability.aoe_size, ability.aoe_shape, ability.primary_damage_type)
		
# --- NEW: Core AoE Calculation Functions ---
# --- UPDATED: Core AoE Calculation Functions ---
func get_affected_tiles(ability: Ability, start_world_pos: Vector2, target_world_pos: Vector2) -> Array[Vector2i]:
	print("global position vs. start_world position: ", global_position, " ", start_world_pos)
	var start_tile = GridManager.world_to_map(start_world_pos)
	print("start_tile 1: ", start_tile)
	
	#print("start_tile 2 ", start_tile)
	# UPDATED: Prioritize the ability's own AoE definition. Fall back to weapon's.
	var aoe_shape = ability.aoe_shape if not ability.is_weapon_attack else \
					(equipment["Main Hand"].aoe_shape if ability.is_weapon_attack and equipment["Main Hand"] else &"rectangle")
	var aoe_size = ability.aoe_size if not ability.is_weapon_attack else \
				   (equipment["Main Hand"].aoe_size if ability.is_weapon_attack and equipment["Main Hand"] else Vector2i.ONE)

	if ability.effect == Ability.ActionEffect.MOVE: # Movement uses a different "flood fill" logic
		return _get_reachable_tiles(start_tile, get_effective_range(ability))
		
	var direction = _get_attack_direction(start_world_pos, target_world_pos)
	# Bonus reach from character stats, converted to whole tiles
	var reach = 0
	
	print_debug("[get_affected_tiles] Shape: ", ability.aoe_shape, ", Size: ", ability.aoe_size, ", Dir: ", direction)
	
	match aoe_shape:
		&"slash":
			return _get_slash_tiles(start_tile, direction, aoe_size.x, reach)
		"thrust":
			return _get_thrust_tiles(start_tile, direction, aoe_size.x, reach)
		"rectangle":
			var target_tile = GridManager.world_to_map(target_world_pos)
			return _get_rectangle_tiles(target_tile, aoe_size)
		# NEW: Handle circular AoE for spells like Fireball
		"circle":
			var target_tile = GridManager.world_to_map(target_world_pos)
			return _get_circular_tiles(target_tile, aoe_size.x) # aoe_size.x is the radius
	return []
	
func _get_attack_direction(from_pos: Vector2, to_pos: Vector2) -> Vector2i:
	var angle = rad_to_deg((to_pos - from_pos).angle()) + 22.5
	if angle < 0: angle += 360
	var octant = int(angle / 45)
	match octant:
		0: return Vector2i.RIGHT; 
		1: return Vector2i(1, 1);  # Down-Right
		2: return Vector2i.DOWN;
		3: return Vector2i(-1, 1); # Down-Left
		4: return Vector2i.LEFT;  
		5: return Vector2i(-1, -1);# Up-Left
		6: return Vector2i.UP;    
		7: return Vector2i(1, -1); # Up-Right
	return Vector2i.ZERO

# --- NEW: Shape-Specific Tile Calculation ---
func _get_slash_tiles(start: Vector2i, dir: Vector2i, size: int, reach: int) -> Array[Vector2i]:
	var tiles: Array[Vector2i] = []
	var total_size = size + reach
	print_debug("[_get_slash_tiles] Calculating slash from ", start, " in dir ", dir, " with total size ", total_size)

	# Check if the direction is diagonal (e.g., (1, -1)) or orthogonal (e.g., (1, 0))
	if dir.x != 0 and dir.y != 0:
		# DIAGONAL: Create a square area in the target quadrant, excluding the caster's own tile.
		# This forms an "L-shape" or a "rectangle with the caster's corner cut out".
		print_debug("... Slash is DIAGONAL. Creating square pattern.")
		for y in range(total_size + 1):
			for x in range(total_size + 1):
				if x == 0 and y == 0: continue # Skip the caster's own tile
				var tile_offset = Vector2i(x * dir.x, y * dir.y)
				tiles.append(start + tile_offset)
	else:
		# ORTHOGONAL: Create a line perpendicular to the attack direction.
		print_debug("... Slash is ORTHOGONAL. Creating perpendicular line.")
		var center_tile = start + dir # The tile directly in front
		var perp_dir: Vector2i
	
	# Manually calculate perpendicular direction for Vector2i
		if dir.x != 0:  # Horizontal direction (left/right)
			perp_dir = Vector2i(0, 1)  # Perpendicular is vertical
		else:  # Vertical direction (up/down)
			perp_dir = Vector2i(1, 0)  # Perpendicular is horizontal
		
		# Create the line centered on the 'center_tile'
		tiles.append(center_tile) # Add the center tile itself
		for i in range(1, total_size + 1):
			tiles.append(center_tile + perp_dir * i)
			tiles.append(center_tile - perp_dir * i)
	return tiles

func _get_thrust_tiles(start: Vector2i, dir: Vector2i, size: int, reach: int) -> Array[Vector2i]:
	var tiles: Array[Vector2i] = []
	for i in range(1, size + reach + 1):
		tiles.append(start + dir * i)
	return tiles

func _get_rectangle_tiles(center: Vector2i, size: Vector2i) -> Array[Vector2i]:
	var tiles: Array[Vector2i] = []
	var half_size = (size - Vector2i.ONE) / 2
	for y in range(center.y - half_size.y, center.y + half_size.y + 1):
		for x in range(center.x - half_size.x, center.x + half_size.x + 1):
			tiles.append(Vector2i(x,y))
	return tiles
# NEW: The "old" way of getting AoE tiles, now used for circular spells.
func _get_circular_tiles(center: Vector2i, radius: int) -> Array[Vector2i]:
	print_debug("[_get_circular_tiles] Calculating circle at ", center, " with radius ", radius)
	var tiles: Array[Vector2i] = []
	var queue = [center]; var visited = {center: 0}
	var head = 0
	while head < queue.size():
		var current = queue[head]; head += 1
		var dist = visited[current]
		tiles.append(current) # Add to the list of affected tiles
		
		if dist >= radius: continue
		
		# Use a breadth-first search to find all tiles within the radius
		for dir in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			var neighbor = current + dir
			if not visited.has(neighbor):
				visited[neighbor] = dist + 1
				queue.append(neighbor)
	print_debug("... Generated ", tiles.size(), " circular tiles.")
	return tiles
	
func _get_reachable_tiles(start_tile: Vector2i, radius: int) -> Array[Vector2i]:
	var queue = [start_tile]; var visited = {start_tile: 0}
	var head = 0
	while head < queue.size():
		var current = queue[head]; head += 1
		var dist = visited[current]
		if dist >= radius: continue
		for dir in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			var neighbor = current + dir
			if not visited.has(neighbor) and GridManager.grid_costs.get(neighbor, INF) < INF:
				visited[neighbor] = dist + 1
				queue.append(neighbor)
	return visited.keys()
# --- Range & Previews ---
func get_effective_range(ability: Ability) -> int:
	if not ability: return 0
	var pixel_range: float = 0.0
	match ability.range_type:
		Ability.RangeType.ABILITY: pixel_range = ability.range
		Ability.RangeType.TOUCH: pixel_range = touch_range
		Ability.RangeType.WEAPON_MELEE: pixel_range = touch_range + (equipment["Main Hand"].range if equipment["Main Hand"] else 0.0)
		Ability.RangeType.WEAPON_RANGED: pixel_range = equipment["Main Hand"].range if equipment["Main Hand"] else touch_range
	if ability.effect == Ability.ActionEffect.MOVE:
		print(" Movement range: ", int(ability.range))
		return int(ability.range / GridManager.TILE_SIZE)
	return int(pixel_range / GridManager.TILE_SIZE)

#Item Management
func equip_item(item_id: String): #Need to check where it is so it can swap places with the existing item if equipping from inventory
	var item = ItemDatabase.item_definitions[item_id]
	var current_item = equipment[item.equip_slot]
	if current_item != null:
		add_to_inventory(current_item)
	equipment[item.equip_slot] = item
#Next, get direction and use it to apply the right texture to helmet sprite and armorsprite.  
#Put main hand and off hand in the hbox container around the body and do the same for them
func add_to_inventory(item: Item):
	print("Attempting to add to inventory")
	if equipment.Belt != null:
		if equipment.Belt.contents.size() < equipment.Belt.num_slots:
			equipment.Belt.contents[item.id] = item
	elif equipment.Back != null:
		if equipment.Back.contents.size() < equipment.Back.num_slots:
			equipment.Back.contents[item.id] = item
	else:
		Globals.show_floating_text("Inventory Full", global_position, get_tree().root)
		drop(item)
		
func drop(item: Item):
	emit_signal("dropped_item", item.id, self)
		
func show_ability_preview(ability: Ability, world_mouse_pos: Vector2, ap_slot_index: int):
	_clear_temp_previews()
	if not ability: return
	
	var start_pos = _get_position_after_actions(ap_slot_index)
	var start_tile = GridManager.world_to_map(start_pos)
	var target_tile = GridManager.world_to_map(world_mouse_pos)
	var range_in_tiles = get_effective_range(ability)

	# FIXED: This logic is now clear and correct.
	if ability.effect == Ability.ActionEffect.MOVE:
		var path = GridManager.find_path(start_tile, target_tile)
		# Condition 1: Is there a valid path and is it within our movement range?
		if not path.is_empty() and path.size() <= range_in_tiles:
			# If yes, draw the specific path the character will take.
			_draw_temp_path_preview(path, start_pos, Color.WHITE_SMOKE)
		else:
			# If no (unreachable or too far), show the general movement radius.
			# This now uses the correct, small 'range_in_tiles' value, preventing the crash.
			#_draw_area_of_effect_preview(start_tile, range_in_tiles, Color(0.5, 0.7, 1.0, 0.3), start_pos)
			pass
	else: # For attacks, spells, etc.
		var affected_tiles = get_affected_tiles(ability, start_tile, world_mouse_pos)
		_draw_area_of_effect_preview(affected_tiles, Color(1.0, 0.3, 0.3, 0.3))


func hide_previews():
	print("Hiding Previews #ui")
	_clear_temp_previews()
	path_preview_line.clear_points()
	cumulative_path_points.clear()
	preview_positions.clear()
	
	
	# Clean up all preview sprites
	for sprite in planned_action_previews:
		if is_instance_valid(sprite):
			sprite.queue_free()
	planned_action_previews.clear()
	
	# Clean up range preview squares
	for square in range_preview_squares:
		if is_instance_valid(square):
			square.queue_free()
	range_preview_squares.clear()
	# Clean up PLANNED aoe preview squares
	for square in planned_aoe_squares:
		if is_instance_valid(square):
			square.queue_free()
	planned_aoe_squares.clear()
	
	preview_container.visible = false
	print("Succesfully hid previews #ui")

func _clear_temp_previews():
	print("Attempting _clear_temp_previews #ui")
	"""Clear only temporary previews (not planned action previews)"""
	temp_path_preview.clear_points()
	
	# Clear range preview squares
	for square in range_preview_squares:
		if is_instance_valid(square):
			square.queue_free()
	range_preview_squares.clear()
	print("Completed  _clear_temp_previews ui")

func rebuild_all_previews():
	"""Rebuild all preview visuals based on current planned actions"""
	# Clear existing previews but keep planned actions
	print("Attempting to rebuild_all_previews # ui")
	path_preview_line.clear_points()
	cumulative_path_points.clear()
	preview_positions.clear()
	# Step 1: Clear out all old persistent previews
	print_debug("Rebuilding all persistent previews for ", character_name)
	for preview in planned_action_previews:
		if is_instance_valid(preview):
			preview.queue_free()
	planned_action_previews.clear()

	for square in planned_aoe_squares:
		if is_instance_valid(square): square.queue_free()
	planned_aoe_squares.clear()
	# Start from character's current position
	cumulative_path_points.append(Vector2.ZERO) # why is this here?  
	var current_world_pos = self.global_position
	var current_tile = GridManager.world_to_map(current_world_pos)
	# Rebuild preview for each planned action
	for i in range(planned_actions.size()):
		if planned_actions[i] == null:
			continue
			
		var action = planned_actions[i]
		var ability = AbilityDatabase.get_ability(action.ability_id)
		if not ability:
			continue
		var preview_instance = ActionPreviewVisualScene.instantiate()
		
		if ability.effect == Ability.ActionEffect.MOVE:
			# Add path points for this move
			var start_tile = GridManager.world_to_map(current_world_pos)
			var end_tile = GridManager.world_to_map(action.target_position)
			var path = GridManager.find_path(start_tile, end_tile)
			
			var move_range_tiles = get_effective_range(ability)
			if path.size() > move_range_tiles:
				path.resize(move_range_tiles)
			
			# Add path points (in local space)
			for tile in path:
				var world_pos = GridManager.map_to_world(tile)
				cumulative_path_points.append(to_local(world_pos))
			
			# Update current position for next action
			if not path.is_empty():
				
				current_world_pos = GridManager.map_to_world(path.back())
				preview_positions.append(current_world_pos)
				preview_instance.global_position = current_world_pos
				
				# Create a preview sprite at this position
				#var preview_sprite = _create_preview_sprite()
				#preview_sprite.global_position = current_world_pos
				#preview_sprite.modulate.a = 0.6 - (i * 0.1) # Fade older previews
				var final_direction = _get_direction_from_vector(current_tile - path[path.size()-2] if path.size() > 1 else current_tile - GridManager.world_to_map(global_position))
				_update_preview_visuals(preview_instance, final_direction)
				planned_action_previews.append(preview_instance)
		else:
			# Non-move actions don't change position
			var aoe_center_tile = GridManager.world_to_map(action.target_position)
			var aoe_radius = ability.aoe_size.x
			var affected_tiles = get_affected_tiles(ability, current_world_pos, action.target_position)
			_draw_planned_aoe_preview(affected_tiles, Color(0.8, 0.2, 0.2, 0.5))
			preview_positions.append(current_world_pos)
	
	# Update the path line with all cumulative points
	if cumulative_path_points.size() > 1:
		path_preview_line.points = cumulative_path_points
		path_preview_line.default_color = Color.WHITE
		path_preview_line.visible = true
		preview_container.visible = true
	
	print("sucessfully rebuilt all previews #ui")

func _get_position_after_actions(up_to_slot: int) -> Vector2:
	print("Attempting _get_position_after_actions #ui")
	"""Get the position where the character will be after executing actions up to (but not including) the given slot"""
	var pos = global_position
	
	for i in range(min(up_to_slot, planned_actions.size())):
		if planned_actions[i] == null:
			continue
			
		var action = planned_actions[i]
		var ability = AbilityDatabase.get_ability(action.ability_id)
		
		if ability and ability.effect == Ability.ActionEffect.MOVE:
			pos = action.target_position
	print("Got position after previews #ui")
	return pos

func _create_preview_sprite():
	"""Create a new preview sprite with the same texture as the character"""
	#var preview = ActionPreviewVisualScene.instantiate()
	#preview.texture = sprite.texture
	#preview.scale = sprite.scale
	#preview_container.add_child(preview)
	print("create preview sprite deprecated ")
# Renamed and modified to update a specific preview instance passed to it
func _update_preview_visuals(preview_node: Node2D, direction: Direction):
	if body_part_data.is_empty(): return
	var body_data: BodyPart = body_part_data.get("body")
	var head_data: BodyPart = body_part_data.get("head")
	
	var body_sprite_node = preview_node.get_node("PreviewBodySprite")
	var head_sprite_node = preview_node.get_node("PreviewHeadSprite")
		
	# Update Body
	if body_data and is_instance_valid(body_sprite_node):
		print("attempting to assign body texture for planning preview")
		body_sprite_node.texture = body_data.get_texture_for_direction(direction)
		body_sprite_node.modulate.a = 0.6
	
	# Update Head
	if head_data and is_instance_valid(head_sprite_node):
		head_sprite_node.texture = head_data.get_texture_for_direction(direction)
		head_sprite_node.modulate.a = 0.6
		
		
func _draw_area_of_effect_preview(affected_tiles: Array[Vector2i], color: Color):
	print_debug("Drawing AoE preview for ", affected_tiles.size(), " tiles. #ui")
	"""Draw colored squares to show area of effect"""
	# --- UPDATED: Simplified Preview Drawing ---
	for tile in affected_tiles:
		var square = ColorRect.new()
		square.size = Vector2(GridManager.TILE_SIZE, GridManager.TILE_SIZE)
		square.mouse_filter = Control.MOUSE_FILTER_IGNORE
		square.color = color
		square.global_position = GridManager.map_to_world(tile) - square.size / 2
		square.z_index = 0
		preview_container.add_child(square)
		range_preview_squares.append(square)
	preview_container.visible = true
	
func _draw_planned_aoe_preview(affected_tiles: Array[Vector2i],  color: Color):
	"""Draws persistent AoE for planned actions, adding squares to planned_aoe_squares."""
	#var affected_tiles = _get_tiles_in_radius(center_tile, radius_in_tiles) WRONG
	for tile in affected_tiles:
		var square = ColorRect.new()
		square.size = Vector2(GridManager.TILE_SIZE, GridManager.TILE_SIZE)
		square.mouse_filter = Control.MOUSE_FILTER_IGNORE
		square.color = color
		square.global_position = GridManager.map_to_world(tile) - square.size / 2
		square.z_index = 0
		preview_container.add_child(square)
		planned_aoe_squares.append(square) # Add to persistent array
	preview_container.visible = true

func _draw_temp_path_preview(path: Array[Vector2i], from_position: Vector2, color: Color):
	print("Attempting to draw temp path preview #ui")
	"""Draw a temporary path preview for real-time targeting feedback"""
	var points = PackedVector2Array()
	
	# Start from the position where character will be when this action executes
	points.append(to_local(from_position))
	
	# Add each point in the path
	for tile_pos in path:
		var world_pos = GridManager.map_to_world(tile_pos)
		points.append(to_local(world_pos))
	
	temp_path_preview.points = points
	temp_path_preview.default_color = color
	temp_path_preview.visible = true
	preview_container.visible = true
	print("Successfully drew temp path preview #ui")

func _draw_path_preview(path: Array[Vector2i], color: Color, slot_index: int):
	# Get starting position for this action
	var start_pos = _get_position_after_actions(slot_index)
	print("Attempting to draw planned path preview #ui")
	# Clear and rebuild the entire cumulative path
	rebuild_all_previews()
	print("Successfully drew planned path preview #ui")
	

	
func _get_tiles_in_radius(center_tile: Vector2i, radius: int) -> Array[Vector2i]:
	"""Helper function to get all tiles within a certain radius of a center tile."""
	print("get_tiles_in_radius called #ui")
	var tiles: Array[Vector2i] = []
	var queue: Array[Vector2i] = [center_tile]
	var visited: Dictionary = { center_tile: 0 }
	var head = 0
	while head < queue.size():
		var current = queue[head]; head += 1
		var dist = visited[current]
		tiles.append(current)
		if dist >= radius: continue
		for dir in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			var neighbor = current + dir
			if not visited.has(neighbor):
				visited[neighbor] = dist + 1
				queue.append(neighbor)
	print("tiles: ", tiles)
	return tiles
# --- Unchanged Helper Functions ---
func _apply_character_data():
	var data = CharacterDatabase.get_character_data(character_id); if not data: return
	
	character_name = data.character_name; name = character_name
	# Load visual part data
	body_part_data.clear()
	var visual_parts = data.visual_parts
	print("visual_parts: ", visual_parts)
	if visual_parts.has("body"):
		body_part_data["body"] = BodyPartDatabase.get_part_data(visual_parts["body"])
		print("output from body database: ", BodyPartDatabase.get_part_data(visual_parts["body"]))
	if visual_parts.has("head"):
		body_part_data["head"] = BodyPartDatabase.get_part_data(visual_parts["head"])
		print("body_part_data head: ", body_part_data["head"].texture_front)
	body_sprite.texture = body_part_data["body"].texture_front
	print("body sprite texture: ", body_sprite.texture)
	head_sprite.texture = body_part_data["head"].texture_front
	body_sprite.visible = true
	head_sprite.visible = true
	#print("armor_sprite: ", armor_sprite)
	print("armor_sprite.texture: ", armor_sprite.texture)
	equipment["Main Hand"] = data.equipment["Main Hand"]
	equipment["Chest"] = data.equipment["Chest"]
	equipment ["Head"] = data.equipment["Head"]
	#print("data: ", data.equipment)
	print("#armor, data.equipment.Chest.texture: ", data.equipment.Chest.texture)
	armor_sprite.texture = load(data.equipment.Chest.texture)
	helmet_sprite.texture = load(data.equipment.Chest.texture)
	scale_equipment_sprites(Vector2(70,70))
	icon = "res://Icons/"+ character_name + "_icon.png"
	if not FileAccess.file_exists(icon):
		icon = "res://Icons/dummy_icon.png"
	
	#action_preview_sprite.texture = sprite.texture
	#action_preview_sprite.scale = Vector2(size_ratio,size_ratio) #need the preview to be the same scale as the actual sprite
	
	allegiance = data.allegiance
	strength = data.strength; dexterity = data.dexterity; constitution = data.constitution
	will = data.will; intelligence = data.intelligence; charisma = data.charisma
	touch_range = data.base_touch_range; max_health = data.max_health
	current_health = max_health; max_ap_per_round = data.base_ap
	traits = data.traits.duplicate(true)
	
	abilities.clear()
	for ability_id in data.abilities: abilities.append(AbilityDatabase.get_ability(ability_id))
	start_round_reset()

func take_damage(amount: Dictionary, success_level:int = 0, primary_damage_type:String = "slashing"):
	var damage_multiplier = pow(1.5,success_level)
	for damage_type in amount.keys():
		current_health = max(0, current_health - (amount[damage_type]*damage_multiplier)) #- self._get_total_damage_resistance()[damage_type]))
		print_rich(name, " takes ", amount[damage_type], damage_type,  " damage.", "crit tier:", success_level, " Health: ", current_health, "/", max_health)
		if damage_type == "Fire": 
			show_floating_text(str(amount[damage_type]), Color.CRIMSON, success_level)
		elif damage_type == "Electric":
			show_floating_text(str(amount[damage_type]), Color.YELLOW, success_level)
		elif damage_type == "Cold":
			show_floating_text(str(amount[damage_type]), Color.ALICE_BLUE, success_level)
		elif damage_type == "Acid":
			show_floating_text(str(amount[damage_type]), Color.DARK_GREEN, success_level)
		elif damage_type == "Radiant":
			show_floating_text(str(amount[damage_type]), Color.LIGHT_GOLDENROD, success_level)
		elif damage_type == "Necrotic":
			show_floating_text(str(amount[damage_type]), Color.BLACK, success_level)
		elif damage_type == "Poison":
			show_floating_text(str(amount[damage_type]), Color.BLUE_VIOLET)
		else:
			show_floating_text(str(amount[damage_type]), Color.WHITE_SMOKE)
			
	var tween = create_tween()
	tween.tween_property(body_sprite, "modulate", Color.RED, 0.1)
	tween.tween_property(head_sprite, "modulate", Color.WHITE, 0.1)
	
	emit_signal("health_changed", current_health, max_health, self)
	
	if current_health <= 0:
		emit_signal("died", self); body_sprite.visible = false; head_sprite.visible = false; $CollisionShape2D.disabled = true

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
	
func _get_total_damage_resistance() -> Dictionary:
	var total_dr = damage_resistances
	
	for item in equipment:
		if not item: continue
		for damage_type in equipment.item.damage_resistances:
			total_dr[damage_type] = total_dr.get(damage_type, 0) + item.damage_resistances[damage_type]
			
	return total_dr
	
func _calculate_success_level(roll: int, target: int) -> int:
	var margin = target - roll
	var level = 0
	
	if margin >= 0: # It's a success
		level = 1 + int(margin / 50) # Every 50 points over is another success level
	
	# Special roll modifiers
	if roll <= 5: level += 1
	if roll >= 96: level -= 1
	
	print_debug("Roll: ", roll, " vs Target: ", target, " | Margin: ", margin, " -> Success Level: ", level)
	return level
	
func get_stat_by_name(stat_name: StringName) -> int:
	match stat_name:
		&"str": return strength
		&"dex": return dexterity
		&"con": return constitution
		&"wil": return will
		&"int": return intelligence
		&"cha": return charisma
	return 50

func start_round_reset():
	current_ap_for_planning = max_ap_per_round
	planned_actions.clear(); planned_actions.resize(max_ap_per_round)
	hide_previews()

func plan_ability_use(ability: Ability, slot: int, target_char: CombatCharacter=null, target_pos: Vector2=Vector2.ZERO):
	print("planned ability: ", ability.display_name, " for slot ", slot)
	if slot >= max_ap_per_round or not can_start_planning_ability(ability, slot): return
	var action = PlannedAction.new(self)
	action.ability_id = ability.id; action.target_character = target_char
	action.target_position = GridManager.map_to_world(GridManager.world_to_map(target_pos))
	planned_actions[slot] = action; current_ap_for_planning -= ability.ap_cost
	
	# Clear temporary previews and rebuild all previews
	_clear_temp_previews()
	rebuild_all_previews()
	
	emit_signal("planned_action_for_slot", self, slot, action)
	if get_next_available_ap_slot_index() == -1 or current_ap_for_planning <= 0:
		emit_signal("no_more_ap_to_plan", self)

func get_next_available_ap_slot_index() -> int:
	for i in range(planned_actions.size()):
		if planned_actions[i] == null: return i
	return -1
	
func can_start_planning_ability(ability: Ability, slot_index: int) -> bool:
	var can_start_planning = ability and slot_index != -1 and current_ap_for_planning >= ability.ap_cost 
	if can_start_planning:
		print(" Able to start planning ability: ", ability.display_name)
	else:
		print(" Unable to start planning ability: ", ability.display_name)
	return can_start_planning

func plan_entire_round_ai(all_chars: Array[CombatCharacter]):
	print("Planning round for AI")
	var targets = all_chars.filter(func(c): return c.allegiance!=self.allegiance and c.current_health>0)
	print("Planning round for AI.  Possible targets: ",targets)

	if targets.is_empty():
		while get_next_available_ap_slot_index() != -1: plan_ability_use(AbilityDatabase.get_ability(&"wait"), get_next_available_ap_slot_index())
		return
		
	targets.sort_custom(func(a,b): return global_position.distance_to(a.global_position) < global_position.distance_to(b.global_position))
	var target = targets[0]
	var attacks = []
	for ability in self.abilities:
		if ability.ActionEffect.DAMAGE:
			attacks.append(ability)
	print("Planning round for AI, possible attacks: ", attacks)

	while current_ap_for_planning > 0:
		var slot = get_next_available_ap_slot_index(); if slot == -1: break
		var my_tile = GridManager.world_to_map(global_position)
		var target_tile = GridManager.world_to_map(target.global_position)
		var distance = abs(my_tile.x - target_tile.x) + abs(my_tile.y - target_tile.y)
		var attack = get_best_attack_ai(attacks, distance, all_chars)
		if attack:
			plan_ability_use(attack, slot, target, target.global_position)
		else:
			var move = AbilityDatabase.get_ability(&"move")
			if move and current_ap_for_planning >= move.ap_cost:
				var path = GridManager.find_path(my_tile, target_tile)
				if not path.is_empty():
					var move_end_tile = path[min(path.size() - 1, get_effective_range(move) - 1)]
					plan_ability_use(move, slot, null, GridManager.map_to_world(move_end_tile))
				else: plan_ability_use(AbilityDatabase.get_ability(&"wait"), slot)
			else: plan_ability_use(AbilityDatabase.get_ability(&"wait"), slot)
			
func get_best_attack_ai(attacks, distance, all_chars: Array[CombatCharacter]):
	print("get_best_attack called.  Update later when damage resistances and types have been added. #combat")
	var most_damage = 0
	var winning_attack = null
	for attack in attacks: 
		if attack.flat_damage > most_damage and current_ap_for_planning >= attack.ap_cost and distance <= get_effective_range(attack):
			winning_attack = attack
	print("best attack = ",winning_attack)
	return winning_attack
	
func get_ability_by_id(id: StringName) -> Ability:
	return AbilityDatabase.abilities[id]

func _update_selection_visual():
	if is_instance_valid(selection_visual): 
		selection_visual.visible = is_selected

func get_sprite_rect_global() -> Rect2:
	# This function now correctly combines the areas of the body and head sprites.
	if not is_instance_valid(body_sprite):
		return Rect2() # Return empty rect if no body

	# Start with the body's rectangle
	var combined_rect = body_sprite.get_global_transform() * body_sprite.get_rect()

	# If there's a head, merge its rectangle with the body's
	if is_instance_valid(head_sprite):
		var head_rect = head_sprite.get_global_transform() * head_sprite.get_rect()
		combined_rect = combined_rect.merge(head_rect)
		
	return combined_rect
func scale_equipment_sprites(new_size):
	if helmet_sprite:	
		var initial_texture_size = helmet_sprite.texture.get_size()
		var size_ratio_x = new_size.x/initial_texture_size.x
		var size_ratio_y = new_size.y/initial_texture_size.y
		helmet_sprite.scale = Vector2(size_ratio_x,size_ratio_y)
	if armor_sprite:
		var initial_texture_size = armor_sprite.texture.get_size()
		var size_ratio_x = new_size.x/initial_texture_size.x
		var size_ratio_y = new_size.y/initial_texture_size.y
		armor_sprite.scale = Vector2(size_ratio_x,size_ratio_y)
	
func clear_planned_actions_from_slot(slot: int, refund_ap: bool):
	for i in range(slot, max_ap_per_round):
		if planned_actions.size() > i and planned_actions[i]:
			if refund_ap:
				var ability = AbilityDatabase.get_ability(planned_actions[i].ability_id)
				if ability: current_ap_for_planning += ability.ap_cost
			planned_actions[i] = null
	
	# Rebuild previews after clearing actions
	rebuild_all_previews()

func update_all_visual_previews(): 
	rebuild_all_previews()
