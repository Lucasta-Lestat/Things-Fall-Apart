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
var is_selected: bool = false

# --- Movement State ---
var current_path: Array[Vector2i] = []
var path_index: int = 0
var is_moving: bool = false
@export var move_speed: float = 250.0 # Pixels per second

# --- Preview State ---
var action_preview_sprites: Array[Sprite2D] = []
var cumulative_path_points: PackedVector2Array = PackedVector2Array()
var preview_positions: Array[Vector2] = [] # Track position after each action

# --- Scene Node References ---
@onready var sprite: Sprite2D = $sprite
@onready var selection_visual: Polygon2D = $SelectionVisual
@onready var floating_text_label: Label = $FloatingTextLabel
@onready var preview_container: Node2D = $PreviewContainer
@onready var path_preview_line: Line2D = $PreviewContainer/PathPreviewLine
@onready var action_preview_sprite: Sprite2D = $PreviewContainer/ActionPreviewSprite

var combat_manager: CombatManager

# --- Godot Lifecycle ---
func _ready():
	if not character_id.is_empty(): _apply_character_data()
	global_position = GridManager.map_to_world(GridManager.world_to_map(global_position))
	selection_visual.visible = false
	floating_text_label.visible = false
	
	# Hide the original preview sprite since we'll create dynamic ones
	action_preview_sprite.visible = false
	hide_previews()

func _process(_delta):
	if not is_moving and not current_path.is_empty():
		_move_along_path()

func _move_along_path():
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
	if not ability: return
	var roll: int
	var success_target = get_stat_by_name(ability.success_stat)
	if ability.success_stat:
		var bonus = 0
		for trait_id in ability.advantages:
			if traits.has(trait_id): bonus += 20 * traits[trait_id]
		for trait_id in ability.disadvantages:
			if traits.has(trait_id): bonus -= 20 * traits[trait_id]
		success_target += bonus
		roll = randi() % 100 + 1
		
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
			var damage = (equipped_weapon.base_damage if equipped_weapon else 1) + (strength / 5) if ability.is_weapon_attack else ability.flat_damage
			if damage > 0 and is_instance_valid(action.target_character):
				action.target_character.take_damage(damage)
		else:
			if is_instance_valid(action.target_character):
				action.target_character.show_floating_text("Miss", Color.WHITE_SMOKE)

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
		return int(ability.range)
	return int(pixel_range / GridManager.TILE_SIZE)

func show_ability_preview(ability: Ability, world_mouse_pos: Vector2, ap_slot_index: int):
	# Don't fully clear - just update the preview for this specific slot
	if not ability: return
	
	# Get the starting position for this action (where character will be after previous actions)
	var start_pos = _get_position_after_actions(ap_slot_index)
	var start_tile = GridManager.world_to_map(start_pos)
	var target_tile = GridManager.world_to_map(world_mouse_pos)
	var range_in_tiles = get_effective_range(ability)
	
	if ability.effect == Ability.ActionEffect.MOVE:
		var path = GridManager.find_path(start_tile, target_tile)
		if not path.is_empty() and path.size() <= range_in_tiles:
			_draw_path_preview(path, Color.AQUAMARINE, ap_slot_index)
		else:
			_draw_area_of_effect_preview(start_tile, range_in_tiles, Color.SALMON, start_pos)
	else:
		_draw_area_of_effect_preview(start_tile, range_in_tiles, Color.AQUAMARINE, start_pos)

func hide_previews():
	GridManager.clear_highlights()
	path_preview_line.clear_points()
	cumulative_path_points.clear()
	preview_positions.clear()
	
	# Clean up all preview sprites
	for sprite in action_preview_sprites:
		if is_instance_valid(sprite):
			sprite.queue_free()
	action_preview_sprites.clear()
	
	preview_container.visible = false

func rebuild_all_previews():
	"""Rebuild all preview visuals based on current planned actions"""
	# Clear existing previews but keep planned actions
	path_preview_line.clear_points()
	cumulative_path_points.clear()
	preview_positions.clear()
	
	for sprite in action_preview_sprites:
		if is_instance_valid(sprite):
			sprite.queue_free()
	action_preview_sprites.clear()
	
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
			preview_positions.append(current_world_pos)
	
	# Update the path line with all cumulative points
	if cumulative_path_points.size() > 1:
		path_preview_line.points = cumulative_path_points
		path_preview_line.default_color = Color.WHITE_SMOKE
		path_preview_line.visible = true
		preview_container.visible = true

func _get_position_after_actions(up_to_slot: int) -> Vector2:
	"""Get the position where the character will be after executing actions up to (but not including) the given slot"""
	var pos = global_position
	
	for i in range(min(up_to_slot, planned_actions.size())):
		if planned_actions[i] == null:
			continue
			
		var action = planned_actions[i]
		var ability = AbilityDatabase.get_ability(action.ability_id)
		
		if ability and ability.effect == Ability.ActionEffect.MOVE:
			pos = action.target_position
	
	return pos

func _create_preview_sprite() -> Sprite2D:
	"""Create a new preview sprite with the same texture as the character"""
	var preview = Sprite2D.new()
	preview.texture = sprite.texture
	preview.scale = sprite.scale
	preview_container.add_child(preview)
	return preview

func _draw_area_of_effect_preview(center_tile: Vector2i, radius_in_tiles: int, _color: Color, from_position: Vector2):
	# The color can be used in the GridManager to select different highlight tiles
	var affected_tiles: Array[Vector2i] = []
	var queue: Array[Vector2i] = [center_tile]
	var visited: Dictionary = { center_tile: 0 } # Tile -> distance
	
	var head = 0
	while head < queue.size():
		var current = queue[head]
		head += 1
		
		var current_dist = visited[current]
		if current_dist >= radius_in_tiles:
			continue
			
		for dir in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			var neighbor = current + dir
			if not visited.has(neighbor):
				visited[neighbor] = current_dist + 1
				queue.append(neighbor)
				affected_tiles.append(neighbor)
	
	GridManager.draw_highlight_tiles(affected_tiles)
	preview_container.visible = true

func _draw_path_preview(path: Array[Vector2i], color: Color, slot_index: int):
	# Get starting position for this action
	var start_pos = _get_position_after_actions(slot_index)
	
	# Clear and rebuild the entire cumulative path
	rebuild_all_previews()

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
	if slot >= max_ap_per_round or not can_start_planning_ability(ability, slot): return
	var action = PlannedAction.new(self)
	action.ability_id = ability.id; action.target_character = target_char
	action.target_position = GridManager.map_to_world(GridManager.world_to_map(target_pos))
	planned_actions[slot] = action; current_ap_for_planning -= ability.ap_cost
	
	# Rebuild all previews when a new action is planned
	rebuild_all_previews()
	
	emit_signal("planned_action_for_slot", self, slot, action)
	if get_next_available_ap_slot_index() == -1 or current_ap_for_planning <= 0:
		emit_signal("no_more_ap_to_plan", self)

func get_next_available_ap_slot_index() -> int:
	for i in range(planned_actions.size()):
		if planned_actions[i] == null: return i
	return -1
	
func can_start_planning_ability(ability: Ability, slot_index: int) -> bool:
	return ability and slot_index != -1 and current_ap_for_planning >= ability.ap_cost

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
	
func get_ability_by_id(id: StringName) -> Ability:
	return AbilityDatabase.abilities[id]

func _update_selection_visual():
	if is_instance_valid(selection_visual): selection_visual.visible = is_selected

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
