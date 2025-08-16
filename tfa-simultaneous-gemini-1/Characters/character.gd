# res://Characters/Character.gd
extends CharacterBody2D
class_name CombatCharacter

signal planned_action_for_slot(character: CombatCharacter, ap_slot_index: int, action: PlannedAction)
signal no_more_ap_to_plan(character: CombatCharacter) # Ran out of AP or slots this planning turn
signal health_changed(new_health: int, max_health: int, char: CombatCharacter)
signal died(character: CombatCharacter)

enum Allegiance { PLAYER, ENEMY, NEUTRAL }

@export var allegiance: Allegiance = Allegiance.PLAYER
@export var max_health: int = 100
@export var character_id: String = "": 
	set = set_character_id

func set_character_id(value: String):
	character_id = value
	_apply_character_data()

func _apply_character_data():
	if character_id.is_empty():
		print("no character ID")
		return
		
	var char_data = CharacterDatabase.get_character_data(character_id)
	if not char_data:
		print("no character data")
		return

	# Apply character data to THIS character instance
	character_name = char_data.display_name
	allegiance = char_data.allegiance
	max_health = char_data.base_health
	current_health = max_health
	dexterity = char_data.base_dexterity
	max_ap_per_round = char_data.base_ap
	
	# Load and set sprite texture
	set_sprite_texture(char_data.sprite_texture_path)
	
	# Load default abilities
	_load_default_abilities(char_data.Abilities)
	
var current_health: int:
	get: return current_health
	set(value):
		var old_health = current_health
		current_health = clamp(value, 0, max_health)
		if health_bar: 
			health_bar.max_value = max_health
			health_bar.value = current_health
		if current_health != old_health:
			emit_signal("health_changed", current_health, max_health, self)
		if current_health == 0 and old_health > 0:
			emit_signal("died", self)
			_handle_death()

@export var dexterity: int = 10
@export var max_ap_per_round: int = 4 # Default AP
var current_ap_for_planning: int = 0 # AP available for planning this round

@export var abilities: Array[Ability] = [] # Assign abilities in Inspector
@export var move_ability_res: Ability # Assign res://Abilities/Move.tres in Inspector

var planned_actions: Array[PlannedAction] = [] # Index = AP Slot

# Replace or add this property
var is_selected: bool = false:
	set(value):
		print("DEBUG: Character ", character_name, " selection changed from ", is_selected, " to ", value)
		is_selected = value
		_update_selection_visual()
		
func _update_selection_visual():
	if selection_indicator:
		selection_indicator.visible = is_selected
		print("DEBUG: Selection indicator for ", character_name, " set to visible: ", is_selected)
		if is_selected:
			print("DEBUG: Selection indicator position: ", selection_indicator.position, " scale: ", selection_indicator.scale)
	else:
		print("DEBUG: No selection indicator found for ", character_name)
	
@export var character_name: String = "Character": 
	set = _set_character_name
func _set_character_name(new_name: String):
	character_name = new_name
	if label: label.text = character_name
	name = character_name # Set Node name for easier debugging in tree

# Movement
@export var move_speed: float = 150.0
var current_move_target_pos: Vector2 = Vector2.ZERO
var is_moving: bool = false

# Nodes
@onready var sprite: Sprite2D = $sprite
@onready var label: Label = $Label # Optional
@onready var health_bar: ProgressBar = $HealthBar
@onready var action_preview_line: Line2D = $ActionPreviewLine
@onready var aoe_preview_shape: Polygon2D = $AOEPreviewShape
@onready var nav_agent: NavigationAgent2D = $NavAgent
var combat_manager: CombatManager
var selection_indicator: Sprite2D # Added in _ready


func set_sprite_texture(texture_path: String): #new
	if texture_path.is_empty():
		print("texture path is empty")
		return
		
	# Ensure sprite node exists
	if not sprite:
		print("no sprite in character")
		await ready  # Wait for _ready if not called yet
		
	if sprite and is_instance_valid(sprite):
		var texture = load(texture_path) as Texture2D
		if texture:
			sprite.texture = texture
			# Update collision shapes to match new sprite
			call_deferred("sync_collision_shapes")
		else:
			print("Warning: Could not load texture from path: ", texture_path)
	else:
		print("Warning: Sprite node not found for character: ", character_name)
		
func _load_default_abilities(ability_ids: Array[String]):
	abilities.clear()
	for ability_id in ability_ids:
		var ability_path = "res://Abilities/" + ability_id.capitalize().replace(" ", "") + ".tres"
		var ability = load(ability_path) as Ability
		if ability:
			abilities.append(ability)
		else:
			print("Warning: Could not load ability: ", ability_path)
func _ready():
	# Apply character data if ID is set
	if not character_id.is_empty():
		_apply_character_data()
	current_health = max_health # Initialize health fully
	# Ensure planned_actions is initialized to the correct size with nulls
	planned_actions.resize(max_ap_per_round) # Max_ap_per_round determines slots
	for i in range(max_ap_per_round): planned_actions[i] = null
	if label: label.text = character_name
	if health_bar: health_bar.value = current_health; health_bar.max_value = max_health

	selection_indicator = Sprite2D.new()
	selection_indicator.texture = preload("res://selection ring.png") # Placeholder selection sprite
	selection_indicator.modulate = Color.GREEN if allegiance == Allegiance.PLAYER else Color.ORANGE
	await get_tree().process_frame
	
	# Position the selection indicator properly
	_position_selection_indicator()
	selection_indicator.scale = Vector2(0.6, 0.1) 
	selection_indicator.position.y = sprite.texture.get_height() * sprite.scale.y / 2 + 5
	selection_indicator.visible = false
	add_child(selection_indicator)

	# Connect nav_agent signals if needed, e.g., target_reached
	nav_agent.path_desired_distance = 5.0
	nav_agent.target_desired_distance = 5.0
	# nav_agent.velocity_computed.connect(Callable(self, "_on_nav_agent_velocity_computed")) # If using agent velocity

	# Populate abilities with move if not already there and move_ability_res is set
	if move_ability_res and not abilities.has(move_ability_res):
		var found_move = false
		for ab in abilities:
			if ab and ab.id == &"move": found_move = true; break
		if not found_move:
			abilities.insert(0, move_ability_res) # Add move to the front for convention (e.g. hotkey 1)
	sync_collision_shapes()
func _position_selection_indicator():
	if not sprite or not sprite.texture or not selection_indicator:
		print("DEBUG: Cannot position selection indicator - missing sprite or texture")
		return
	
	# Get the actual sprite bounds
	var sprite_size = sprite.texture.get_size() * sprite.scale
	var sprite_rect = sprite.get_rect()  # This gets the local rect of the sprite
	
	print("DEBUG: Sprite size: ", sprite_size)
	print("DEBUG: Sprite rect: ", sprite_rect)
	print("DEBUG: Sprite position: ", sprite.position)
	
	# Position indicator at the bottom of the sprite
	var bottom_y = sprite.position.y + sprite_rect.position.y + sprite_rect.size.y + 5
	selection_indicator.position = Vector2(sprite.position.x, bottom_y)
	
	# Scale the indicator to be proportional to the sprite width
	var indicator_width = sprite_size.x * 0.8  # 80% of sprite width
	var indicator_height = 8  # Fixed height
	
	if selection_indicator.texture:
		print("DEBUG: Selection has Texture for indicator")
		var indicator_texture_size = selection_indicator.texture.get_size()
		selection_indicator.scale = Vector2(
			indicator_width / indicator_texture_size.x,
			indicator_height / indicator_texture_size.y
		)
	
	print("DEBUG: Final selection indicator position: ", selection_indicator.position)
	print("DEBUG: Final selection indicator scale: ", selection_indicator.scale)
func sync_collision_shapes():
	if not sprite or not sprite.texture:
		return
	
	var sprite_size = sprite.texture.get_size() * sprite.scale
	
	# Sync ClickArea collision shape
	var click_area = get_node_or_null("ClickArea/CollisionShape2D")
	if click_area and click_area.shape is RectangleShape2D:
		click_area.shape.size = sprite_size
	
	# Sync body collision shape (usually smaller than sprite)
	var body_collision = get_node_or_null("CollisionShape2D")
	if body_collision and body_collision.shape is RectangleShape2D:
		# Make body collision slightly smaller than sprite
		body_collision.shape.size = sprite_size * 0.8

func _physics_process(delta):
	if is_moving and nav_agent and not nav_agent.is_navigation_finished():
		var next_path_pos = nav_agent.get_next_path_position()
		var direction = global_position.direction_to(next_path_pos)
		velocity = direction * move_speed
		move_and_slide()
		if global_position.distance_to(nav_agent.target_position) < nav_agent.target_desired_distance:
			_stop_movement()
	elif is_moving: # Fallback if no nav_agent or finished
		_stop_movement()


func _stop_movement():
	is_moving = false
	velocity = Vector2.ZERO
	# print_debug(character_name, " reached destination or stopped.")

func start_round_reset():
	current_ap_for_planning = max_ap_per_round
	for i in range(planned_actions.size()):
		planned_actions[i] = null # Clear actions for new round
	# Clear any lingering multi-AP charge states if not handled by action consumption
	for action_slot_idx in range(planned_actions.size()):
		var action = planned_actions[action_slot_idx]
		if action and (action.is_multi_ap_charge_segment or action.is_final_segment_of_multi_ap):
			action.ap_spent_on_charge = 0 # Reset charge progress
	hide_previews()


func get_next_available_ap_slot_index() -> int:
	for i in range(planned_actions.size()):
		if planned_actions[i] == null:
			return i
	return -1

func can_start_planning_ability(ability: Ability, at_slot_index: int) -> bool:
	if not ability: return false
	if at_slot_index == -1: return false # No available slot
	if current_ap_for_planning < 1 : return false # Minimum 1 AP to plan first segment
	if current_ap_for_planning < ability.ap_cost and ability.ap_cost > 1 : # Not enough total AP for a multi-AP ability
		# Allow planning if some AP left, even if not enough for full multi-AP,
		# but Character.plan_ability_use will only plan what's possible.
		# For a stricter check before even entering targeting:
		# return current_ap_for_planning >= ability.ap_cost
		pass # Allow initiating, plan_ability_use will cap it.
	# Check if enough *slots* are available from at_slot_index for the ability's full cost
	return (at_slot_index + ability.ap_cost -1) < max_ap_per_round


# Main function to plan an ability (move is also an ability)
# ap_slot_to_start_planning_at: the first empty slot this ability will fill.
func plan_ability_use(ability: Ability, ap_slot_to_start_planning_at: int, p_target_char: CombatCharacter = null, p_target_pos: Vector2 = Vector2.ZERO):
	if not ability: printerr("Attempted to plan null ability"); return
	if ap_slot_to_start_planning_at < 0 or ap_slot_to_start_planning_at >= max_ap_per_round:
		printerr("Invalid start slot for planning: ", ap_slot_to_start_planning_at); return

	var total_ap_cost = ability.ap_cost
	var ap_actually_can_spend = min(current_ap_for_planning, total_ap_cost) # Max AP we can use up
	var slots_actually_can_fill = 0

	# Create the root action first (this holds final execution logic for multi-AP)
	var root_action = PlannedAction.new(self)
	root_action.ability_id = ability.id
	root_action.target_character = p_target_char
	root_action.target_position = p_target_pos
	root_action.action_type = PlannedAction.ActionType.USE_ABILITY if ability.id != &"move" else PlannedAction.ActionType.MOVE
	root_action.total_ap_cost_for_ability = total_ap_cost
	root_action.ap_spent_on_charge = 0 # Will be incremented by charge segments

	var current_slot_for_planning = ap_slot_to_start_planning_at
	for i in range(total_ap_cost): # Iterate for each AP cost of the ability
		if current_ap_for_planning <= 0: break # No more AP to spend on planning
		if current_slot_for_planning >= max_ap_per_round: break # No more slots available
		
		if planned_actions[current_slot_for_planning] != null: # Slot already taken (shouldn't happen if ap_slot_to_start_planning_at is from get_next_available)
			printerr("Slot ", current_slot_for_planning, " for ", character_name, " was unexpectedly filled.")
			break 

		var action_segment: PlannedAction
		if total_ap_cost > 1: # Multi-AP ability
			action_segment = PlannedAction.new(self) # Create a new segment
			action_segment.multi_ap_ability_id = ability.id
			action_segment.total_ap_cost_for_ability = total_ap_cost 
			# The root_action itself is only placed in the *last* slot if multi-AP.
			# Charging segments point to the ability.
			if i < total_ap_cost - 1: # This is a charging segment
				action_segment.is_multi_ap_charge_segment = true
				action_segment.action_type = PlannedAction.ActionType.USE_ABILITY # Or a specific CHARGE type
				action_segment.ability_id = ability.id # For display/intent
			else: # This is the final segment that executes the ability
				root_action.is_final_segment_of_multi_ap = true # Mark the root action
				action_segment = root_action # Place the root action in the last slot
		else: # Single AP ability
			action_segment = root_action # The root action is the only segment

		planned_actions[current_slot_for_planning] = action_segment
		current_ap_for_planning -= 1
		slots_actually_can_fill += 1
		
		emit_signal("planned_action_for_slot", self, current_slot_for_planning, action_segment)
		current_slot_for_planning += 1

	if slots_actually_can_fill > 0:
		print_debug(character_name, " planned '", ability.display_name, "' consuming ", slots_actually_can_fill, " AP slots. Remaining planning AP: ", current_ap_for_planning)
	
	if get_next_available_ap_slot_index() == -1 or current_ap_for_planning == 0:
		emit_signal("no_more_ap_to_plan", self)

# Helper to find the main "root" action for a multi-AP ability, given one of its segments
func get_multi_ap_action_root(p_multi_ap_ability_id: StringName, segment_slot_index: int) -> PlannedAction:
	# Search backwards from the segment to find the start, then forwards to find the end (root)
	var start_slot = -1
	for i in range(segment_slot_index, -1, -1):
		var action = planned_actions[i]
		if action and action.multi_ap_ability_id == p_multi_ap_ability_id:
			start_slot = i
			if not action.is_multi_ap_charge_segment and not action.is_final_segment_of_multi_ap : # Found the old single-slot way
				return action # This is a fallback if new system not fully used
			if action.is_final_segment_of_multi_ap: # Found root searching backwards
				return action
		else: # Different ability or empty slot
			break 
	
	if start_slot != -1: # Found a start, now search forward for the final segment
		var root_action = planned_actions[start_slot] # Could be the root if 1 AP cost.
		if root_action and root_action.multi_ap_ability_id == p_multi_ap_ability_id and root_action.is_final_segment_of_multi_ap:
			return root_action

		for i in range(start_slot, min(start_slot + root_action.total_ap_cost_for_ability, max_ap_per_round)):
			var action = planned_actions[i]
			if action and action.multi_ap_ability_id == p_multi_ap_ability_id and action.is_final_segment_of_multi_ap:
				return action
	printerr("Root action for multi_ap_id '",p_multi_ap_ability_id,"' not found from slot ",segment_slot_index," for ", character_name)
	return null


func clear_planned_actions_from_slot(start_slot_index: int, refund_ap: bool):
	var ap_refunded = 0
	var cleared_multi_ap_roots = {} # To avoid double-refunding from segments of same ability

	for i in range(start_slot_index, planned_actions.size()):
		var action_to_clear = planned_actions[i]
		if action_to_clear:
			if refund_ap:
				# If it's a multi-AP root, its cost is total_ap_cost_for_ability
				# If it's a segment, it effectively cost 1 AP from current_ap_for_planning
				# The refund should restore 1 AP for each slot cleared.
				current_ap_for_planning += 1 # Each cleared slot gives 1 planning AP back
				ap_refunded += 1

				# If clearing part of a multi-AP ability, reset charge on its root
				if action_to_clear.is_multi_ap_charge_segment or action_to_clear.is_final_segment_of_multi_ap:
					if not cleared_multi_ap_roots.has(action_to_clear.multi_ap_ability_id):
						var root_action = get_multi_ap_action_root(action_to_clear.multi_ap_ability_id, i)
						if root_action:
							root_action.ap_spent_on_charge = 0
							cleared_multi_ap_roots[action_to_clear.multi_ap_ability_id] = true

			planned_actions[i] = null
			# emit_signal("cleared_action_for_slot", self, i) # Potentially for UI update
	
	current_ap_for_planning = min(current_ap_for_planning, max_ap_per_round) # Cap refund
	if ap_refunded > 0:
		print_debug(character_name, " cleared ", ap_refunded, " AP slots from index ", start_slot_index, ". Planning AP now: ", current_ap_for_planning)
	hide_previews()


func execute_planned_action(action: PlannedAction):
	if not action or action.caster != self: return
	if current_health <= 0:
		print_debug(character_name, " is defeated, cannot execute ", action.to_string())
		return

	print_rich("[b]", character_name, "[/b] (DEX:",action.dex_snapshot,") executes: ", action.to_string())
	var ability_resource: Ability = null
	if action.action_type == PlannedAction.ActionType.USE_ABILITY or \
	   (action.action_type == PlannedAction.ActionType.MOVE and action.ability_id == &"move"): # Move is an ability
		ability_resource = get_ability_by_id(action.ability_id)

	match action.action_type:
		PlannedAction.ActionType.MOVE:
			if nav_agent:
				is_moving = true
				nav_agent.target_position = action.target_position
				# print_debug("  ", character_name, " moving to ", action.target_position)
			else: # Fallback direct move
				global_position = action.target_position
			# Play move animation
			# sprite.play("walk")
		
		PlannedAction.ActionType.USE_ABILITY:
			if ability_resource:
				# print_debug("  ", character_name, " using ability '", ability_resource.display_name, "'")
				# Actual effect application here
				if action.target_character and is_instance_valid(action.target_character):
					print_rich("    [color=cyan]Targeting character:", action.target_character.character_name, "[/color]")
					if ability_resource.id == &"basic_attack": action.target_character.take_damage(10, self)
					elif ability_resource.id == &"heavy_strike": action.target_character.take_damage(30, self)
					# Add more ability effects
				elif action.target_position != Vector2.ZERO:
					print_rich("    [color=cyan]Targeting position:", action.target_position, "[/color]")
					# AOE damage/effects at position
				else: # Self target
					print_rich("    [color=cyan]Targeting self.[/color]")
				# Play ability animation
				# sprite.play(ability_resource.animation_name if ability_resource.animation_name else "attack")
			else:
				printerr("Could not find ability resource for ID: ", action.ability_id)

		PlannedAction.ActionType.WAIT:
			print_debug("  ", character_name, " waits.")
			# Play idle/wait animation
			# sprite.play("idle")
	
	# If this was the final segment of a multi-AP action, mark its earlier charge segments as "resolved"
	# so they don't get processed again by CombatManager if logic changes.
	if action.is_final_segment_of_multi_ap:
		for i in range(planned_actions.size()):
			var prev_action = planned_actions[i]
			if prev_action and prev_action.multi_ap_ability_id == action.multi_ap_ability_id and prev_action.is_multi_ap_charge_segment:
				prev_action.is_part_of_resolved_multi_ap = true


func take_damage(amount: int, _source: CombatCharacter):
	if current_health <= 0: return # Already defeated
	current_health -= amount
	print_rich("[color=red]", character_name, " takes ", amount, " damage. HP: ", current_health, "/", max_health, "[/color]")

func _handle_death():
	print_rich("[b][color=maroon]", character_name, " has been defeated![/color][/b]")
	sprite.modulate = Color(0.5, 0.5, 0.5, 0.7) # Dim sprite
	set_process(false) # Stop _process and _physics_process
	set_physics_process(false)
	var click_col = $ClickArea/CollisionShape2D as CollisionShape2D
	if click_col : click_col.disabled = true # Disable click detection
	hide_previews()
	# Could play death animation and then queue_free() or set visible = false


func get_ability_by_id(id: StringName) -> Ability:
	for ability in abilities:
		if ability and ability.id == id:
			return ability
	return null # Or return move_ability_res if id == &"move" as a fallback

# --- AI Planning ---
func plan_entire_round_ai(all_chars_in_combat: Array[CombatCharacter]):
	if allegiance != Allegiance.ENEMY: return

	while current_ap_for_planning > 0 and get_next_available_ap_slot_index() != -1:
		var current_planning_slot = get_next_available_ap_slot_index()
		if current_planning_slot == -1: break # No more slots

		# Simplistic AI: find a player target, try heavy_strike, then basic_attack, then move, then wait.
		var player_targets: Array[CombatCharacter] = []
		for char_node in all_chars_in_combat:
			var char = char_node as CombatCharacter
			if is_instance_valid(char) and char.current_health > 0 and char.allegiance == Allegiance.PLAYER:
				player_targets.append(char)
		
		if player_targets.is_empty(): # No targets, just wait
			_ai_plan_wait(current_planning_slot); continue

		var target = player_targets.pick_random() # Pick a random live player
		
		var heavy_strike = get_ability_by_id(&"heavy_strike")
		var basic_attack = get_ability_by_id(&"basic_attack")
		var move_ab = get_ability_by_id(&"move") # Assumes "move" is in its abilities list

		var planned_something = false
		# Try Heavy Strike
		if heavy_strike and can_start_planning_ability(heavy_strike, current_planning_slot) and current_ap_for_planning >= heavy_strike.ap_cost:
			if global_position.distance_to(target.global_position) <= heavy_strike.range:
				plan_ability_use(heavy_strike, current_planning_slot, target)
				planned_something = true
		
		# Try Basic Attack if Heavy Strike not viable or not planned
		if not planned_something and basic_attack and can_start_planning_ability(basic_attack, current_planning_slot) and current_ap_for_planning >= basic_attack.ap_cost:
			if global_position.distance_to(target.global_position) <= basic_attack.range:
				plan_ability_use(basic_attack, current_planning_slot, target)
				planned_something = true

		# Try Move if no attack planned and move ability exists
		if not planned_something and move_ab and can_start_planning_ability(move_ab, current_planning_slot) and current_ap_for_planning >= move_ab.ap_cost:
			if global_position.distance_to(target.global_position) > (basic_attack.range if basic_attack else 50): # Move if not in range of basic attack
				var move_target_pos = target.global_position - global_position.direction_to(target.global_position) * (basic_attack.range * 0.8 if basic_attack else 40)
				plan_ability_use(move_ab, current_planning_slot, null, move_target_pos)
				planned_something = true
		
		if not planned_something: # Fallback to wait
			_ai_plan_wait(current_planning_slot)

	# print_debug(character_name, " (AI) finished planning its turn. Remaining AP: ", current_ap_for_planning)

func _ai_plan_wait(slot_idx: int):
	if current_ap_for_planning > 0 and slot_idx < max_ap_per_round and planned_actions[slot_idx] == null:
		var wait_action = PlannedAction.new(self, PlannedAction.ActionType.WAIT)
		planned_actions[slot_idx] = wait_action
		current_ap_for_planning -=1
		emit_signal("planned_action_for_slot", self, slot_idx, wait_action)
		# print_debug(character_name, " (AI) planned WAIT in slot ", slot_idx)


# --- UI Previews ---
func show_ability_preview(ability: Ability, world_mouse_pos: Vector2, for_ap_slot: int):
	#hide_previews()
	print("DEBUG: show_ability_preview triggered")
	#if not ability or not CombatManager or CombatManager.current_combat_state != CombatManager.CombatState.PLANNING: return
	if not ability or not combat_manager or combat_manager.current_combat_state != CombatManager.CombatState.PLANNING: return
	if for_ap_slot == -1 : return # Not a valid slot for planning

	var caster_pos = global_position
	var color = Color.YELLOW
	var dist_to_target = caster_pos.distance_to(world_mouse_pos)
	if dist_to_target > ability.range:
		color = Color.ORANGE_RED # Out of range indication

	action_preview_line.default_color = color
	aoe_preview_shape.color = Color(color, 0.3) # Base color with alpha

	if ability.target_type == Ability.TargetType.GROUND or ability.id == &"move":
		print("DEBUG: Ability targeting ground or move being used")
		action_preview_line.points = [to_local(caster_pos), to_local(world_mouse_pos)]
		action_preview_line.visible = true
		if ability.area_of_effect_radius > 0:
			_draw_aoe_circle(to_local(world_mouse_pos), ability.area_of_effect_radius)
			aoe_preview_shape.visible = true
	elif ability.target_type != Ability.TargetType.SELF: # Character target
		var target_char = combat_manager.get_character_at_world_pos(world_mouse_pos)
		var line_end_pos = world_mouse_pos
		if target_char: line_end_pos = target_char.global_position # Snap line to char center
		
		action_preview_line.points = [to_local(caster_pos), to_local(line_end_pos)]
		action_preview_line.visible = true
		if ability.area_of_effect_radius > 0:
			_draw_aoe_circle(to_local(line_end_pos), ability.area_of_effect_radius)
			aoe_preview_shape.visible = true

func _draw_aoe_circle(center_local_pos: Vector2, radius: float):
	print("DEBUG: Drawing AoE Circle")
	var points = PackedVector2Array()
	var segments = 32
	for i in range(segments + 1):
		var angle = TAU * i / segments
		points.append(center_local_pos + Vector2(cos(angle), sin(angle)) * radius)
	aoe_preview_shape.polygon = points

func hide_previews():
	action_preview_line.visible = false
	aoe_preview_shape.visible = false

func get_sprite_rect_global() -> Rect2: # For drag selection
	if not is_instance_valid(sprite): return Rect2(global_position, Vector2.ONE) # fallback
	var sprite_size = sprite.texture.get_size() * sprite.scale
	return Rect2(global_position - sprite_size / 2.0, sprite_size)

# Enemy intent display (called by a potential GameUI or CombatManager during enemy planning phase)
func show_enemy_intent():
	print("DEBUG: show_enemy_intent called")
	if allegiance != Allegiance.ENEMY or not combat_manager or combat_manager.current_combat_state != CombatManager.CombatState.PLANNING:
		return

	hide_previews() # Clear old previews
	
	# For each planned action by this enemy, show a simplified preview
	# This example just shows the first non-wait action's target
	for i in range(planned_actions.size()):
		var action = planned_actions[i]
		if action and action.action_type != PlannedAction.ActionType.WAIT:
			var intent_color = Color.RED
			intent_color.a = 0.5 # Semi-transparent
			action_preview_line.default_color = intent_color
			aoe_preview_shape.color = intent_color

			var target_pos_for_line = global_position # Default to self if no clear target
			if action.target_character and is_instance_valid(action.target_character):
				target_pos_for_line = action.target_character.global_position
			elif action.target_position != Vector2.ZERO:
				target_pos_for_line = action.target_position
			
			action_preview_line.points = [to_local(global_position), to_local(target_pos_for_line)]
			action_preview_line.visible = true
			
			var ability = get_ability_by_id(action.ability_id)
			if ability and ability.area_of_effect_radius > 0:
				_draw_aoe_circle(to_local(target_pos_for_line), ability.area_of_effect_radius)
				aoe_preview_shape.visible = true
			
			# Only show first intent for simplicity; a full UI would show all slots
			break
