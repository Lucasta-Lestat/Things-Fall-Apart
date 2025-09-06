# res://Characters/Character.gd
extends CharacterBody2D
class_name CombatCharacter

# --- Signals ---
signal health_changed(new_health, max_health, character)
signal planned_action_for_slot(character, slot_index, action)
signal died(character)
signal no_more_ap_to_plan(character)

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
var equipped_weapon: Weapon
var abilities: Array[Ability] = []
var planned_actions: Array[PlannedAction] = []
var is_selected: bool = false:
	set(value):
		is_selected = value
		_update_selection_visual()

# --- Movement State ---
var current_path: Array[Vector2i] = []
var path_index: int = 0
var is_moving: bool = false
@export var move_speed: float = 250.0 # Pixels per second

# --- Preview State ---
var action_preview_sprites: Array[Sprite2D] = []
var cumulative_path_points: PackedVector2Array = PackedVector2Array()
var preview_positions: Array[Vector2] = [] # Track position after each action
var range_preview_squares: Array[ColorRect] = [] # For range/AOE preview
var planned_aoe_squares: Array[ColorRect] = [] # NEW: For persistent planned AoEs


# --- Scene Node References ---
@onready var sprite: Sprite2D = $sprite
@onready var selection_visual: Sprite2D = $SelectionVisual  # Changed from Polygon2D to Sprite2D
@onready var floating_text_label: Label = $FloatingTextLabel
@onready var preview_container: Node2D = $PreviewContainer
@onready var path_preview_line: Line2D = $PreviewContainer/PathPreviewLine
@onready var action_preview_sprite: Sprite2D = $PreviewContainer/ActionPreviewSprite
@onready var temp_path_preview: Line2D = $PreviewContainer/TempPathPreview
# --- Visual Settings ---
@export var selection_ring_texture: Texture2D # Assign ring texture in inspector
@export var selection_ring_scale: Vector2 = Vector2(1.5, 1.5)
@export var selection_ring_offset: Vector2 = Vector2(0, 32) # Offset to place at character's feet

var combat_manager: CombatManager

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
			selection_visual.z_index = -1 # Place behind character
	
	floating_text_label.visible = false
		
	temp_path_preview.default_color = Color(0.0, 0.0, 0.0, 0.5)
#	preview_container.add_child(temp_path_preview)
	
	# Hide the original preview sprite since we'll create dynamic ones
	action_preview_sprite.visible = false
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
	var target_tile = current_path[path_index]
	var target_world_pos = GridManager.map_to_world(target_tile)
	
	var duration = global_position.distance_to(target_world_pos) / move_speed
	var tween = create_tween()
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(self, "global_position", target_world_pos, duration)
	tween.tween_callback(func(): path_index += 1; is_moving = false)

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
		
		
	if ability.effect == Ability.ActionEffect.MOVE:
		var start_tile = GridManager.world_to_map(global_position)
		var end_tile = GridManager.world_to_map(action.target_position)
		current_path = GridManager.find_path(start_tile, end_tile)
		var move_range_tiles = get_effective_range(ability)
		if current_path.size() > move_range_tiles:
			current_path.resize(move_range_tiles)
		path_index = 0
	
	elif ability.effect == Ability.ActionEffect.DAMAGE:
		if roll <= success_target:
			var affected_tiles = get_affected_tiles(ability, global_position, action.target_position)
			var targets = combat_manager.get_entities_in_tiles(affected_tiles)
			
			if targets.is_empty():
				print_rich("  [color=gray]Attack hits nothing.[/color]")
				return
				
			print_rich("[color=orange]Executing Damage Action: ", ability.display_name, "[/color]")
			for entity in targets:
				# Don't hit self unless it's an explosive type of attack (future feature)
				#if entity == self: continue

				var damage = (equipped_weapon.base_damage if equipped_weapon else 1) + (strength / 5) if ability.is_weapon_attack else ability.flat_damage
				if is_instance_valid(entity) and entity.has_method("take_damage"):
					print_rich("  [color=green]HIT:[/color] ", entity.name, " for ", damage, " damage.")
					entity.take_damage(damage)
				else:
					print_rich("  [color=yellow]MISS![/color] (Rolled ", roll, " vs target of ", success_target, ")")
					entity.show_floating_text("Miss", Color.WHITE_SMOKE)
# --- NEW: Core AoE Calculation Functions ---
# --- UPDATED: Core AoE Calculation Functions ---
func get_affected_tiles(ability: Ability, start_world_pos: Vector2, target_world_pos: Vector2) -> Array[Vector2i]:
	print("global position vs. start_world position: ", global_position, " ", start_world_pos)
	var start_tile = GridManager.world_to_map(start_world_pos)
	print("start_tile 1: ", start_tile)
	
	#print("start_tile 2 ", start_tile)
	# UPDATED: Prioritize the ability's own AoE definition. Fall back to weapon's.
	var aoe_shape = ability.aoe_shape if not ability.is_weapon_attack else \
					(equipped_weapon.aoe_shape if ability.is_weapon_attack and equipped_weapon else Ability.AttackShape.RECTANGLE)
	var aoe_size = ability.aoe_size if not ability.is_weapon_attack else \
				   (equipped_weapon.aoe_size if ability.is_weapon_attack and equipped_weapon else Vector2i.ONE)

	if ability.effect == Ability.ActionEffect.MOVE: # Movement uses a different "flood fill" logic
		return _get_reachable_tiles(start_tile, get_effective_range(ability))
		
	var direction = _get_attack_direction(start_world_pos, target_world_pos)
	# Bonus reach from character stats, converted to whole tiles
	var reach = 0
	
	print_debug("[get_affected_tiles] Shape: ", Ability.AttackShape.keys()[aoe_shape], ", Size: ", aoe_size, ", Dir: ", direction)
	
	match aoe_shape:
		Ability.AttackShape.SLASH:
			return _get_slash_tiles(start_tile, direction, aoe_size.x, reach)
		Ability.AttackShape.THRUST:
			return _get_thrust_tiles(start_tile, direction, aoe_size.x, reach)
		Ability.AttackShape.RECTANGLE:
			var target_tile = GridManager.world_to_map(target_world_pos)
			return _get_rectangle_tiles(target_tile, aoe_size)
		# NEW: Handle circular AoE for spells like Fireball
		Ability.AttackShape.CIRCLE:
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
		Ability.RangeType.WEAPON_MELEE: pixel_range = touch_range + (equipped_weapon.range if equipped_weapon else 0.0)
		Ability.RangeType.WEAPON_RANGED: pixel_range = equipped_weapon.range if equipped_weapon else touch_range
	if ability.effect == Ability.ActionEffect.MOVE:
		print(" Movement range: ", int(ability.range))
		return int(ability.range / GridManager.TILE_SIZE)
	return int(pixel_range / GridManager.TILE_SIZE)

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
	for sprite in action_preview_sprites:
		if is_instance_valid(sprite):
			sprite.queue_free()
	action_preview_sprites.clear()
	
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
	
	for sprite in action_preview_sprites:
		if is_instance_valid(sprite):
			sprite.queue_free()
	action_preview_sprites.clear()
	for square in planned_aoe_squares:
		if is_instance_valid(square): square.queue_free()
	planned_aoe_squares.clear()
	# Start from character's current position
	cumulative_path_points.append(Vector2.ZERO)
	var current_world_pos = global_position
	
	# Rebuild preview for each planned action
	for i in range(planned_actions.size()):
		if planned_actions[i] == null:
			continue
			
		var action = planned_actions[i]
		var ability = AbilityDatabase.get_ability(action.ability_id)
		if not ability:
			continue
		
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
				
				# Create a preview sprite at this position
				var preview_sprite = _create_preview_sprite()
				preview_sprite.global_position = current_world_pos
				preview_sprite.modulate.a = 0.6 - (i * 0.1) # Fade older previews
				action_preview_sprites.append(preview_sprite)
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

func _create_preview_sprite() -> Sprite2D:
	"""Create a new preview sprite with the same texture as the character"""
	var preview = Sprite2D.new()
	preview.texture = sprite.texture
	preview.scale = sprite.scale
	preview_container.add_child(preview)
	return preview

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
	sprite.texture = load(data.sprite_texture_path)
	var initial_sprite_size = sprite.texture.get_size()
	var size_ratio = self.base_size/initial_sprite_size.x
	sprite.scale = Vector2(size_ratio,size_ratio)
	
	icon = "res://Icons/"+ character_name + "_icon.png"
	if not FileAccess.file_exists(icon):
		icon = "res://Icons/dummy_icon.png"
	
	action_preview_sprite.texture = sprite.texture
	action_preview_sprite.scale = Vector2(size_ratio,size_ratio) #need the preview to be the same scale as the actual sprite
	
	allegiance = data.allegiance
	strength = data.strength; dexterity = data.dexterity; constitution = data.constitution
	will = data.will; intelligence = data.intelligence; charisma = data.charisma
	touch_range = data.base_touch_range; max_health = data.max_health
	current_health = max_health; max_ap_per_round = data.base_ap
	traits = data.traits.duplicate(true)
	equipped_weapon = WeaponDatabase.get_weapon(data.equipped_weapon)
	abilities.clear()
	for ability_id in data.abilities: abilities.append(AbilityDatabase.get_ability(ability_id))
	start_round_reset()

func take_damage(amount: int):
	current_health = max(0, current_health - amount)
	emit_signal("health_changed", current_health, max_health, self)
	show_floating_text(str(amount), Color.CRIMSON)
	if current_health <= 0:
		emit_signal("died", self); sprite.visible = false; $CollisionShape2D.disabled = true

func show_floating_text(text: String, color: Color = Color.WHITE):
	floating_text_label.text = text; floating_text_label.modulate = color
	floating_text_label.visible = true
	var tween = create_tween().set_parallel()
	tween.tween_property(floating_text_label, "position", Vector2(0, -70), 0.9).from(Vector2(0, -40))
	tween.tween_property(floating_text_label, "modulate:a", 0.0, 0.9)
	tween.chain().tween_callback(func(): floating_text_label.visible = false)

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
	var targets = all_chars.filter(func(c): return c.allegiance!=self.allegiance and c.current_health>0)
	
	if targets.is_empty():
		while get_next_available_ap_slot_index() != -1: plan_ability_use(AbilityDatabase.get_ability(&"wait"), get_next_available_ap_slot_index())
		return
		
	targets.sort_custom(func(a,b): return global_position.distance_to(a.global_position) < global_position.distance_to(b.global_position))
	var target = targets[0]
	var attacks = []
	for ability in self.abilities:
		if ability.ActionEffect.DAMAGE:
			attacks.append(ability)
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
	return sprite.get_global_transform() * sprite.get_rect() if sprite else Rect2()

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
