# res://Characters/Character.gd
extends CharacterBody2D
class_name CombatCharacter

# --- Signals (No Changes) ---
signal planned_action_for_slot(character: CombatCharacter, ap_slot_index: int, action: PlannedAction)
signal no_more_ap_to_plan(character: CombatCharacter) # Ran out of AP or slots this planning turn
signal health_changed(new_health: int, max_health: int, char: CombatCharacter)
signal died(character: CombatCharacter)

# --- Core Properties ---
enum Allegiance { PLAYER, ENEMY, NEUTRAL }

# The character_id is the primary way to configure a character.
# Setting it will trigger _apply_character_data to load from the database.
@export var character_id: String = "": 
	set = set_character_id

# These properties are populated by _apply_character_data. 
# They are exported to allow for quick prototyping or debugging directly in the scene,
# but the database is the primary source of truth.
@export var character_name: String = "Character": set = _set_character_name
@export var allegiance: Allegiance = Allegiance.PLAYER
@export var max_health: int = 100
@export var dexterity: int = 10
@export var max_ap_per_round: int = 4

var current_health: int:
	get: return current_health
	set(value):
		var old_health = current_health
		current_health = clamp(value, 0, max_health)
		# The character's only job is to emit a signal that its health changed.
		# It is the UI's job to listen for this and update itself.
		if current_health != old_health:
			emit_signal("health_changed", current_health, max_health, self)
		if current_health == 0 and old_health > 0:
			emit_signal("died", self)
			_handle_death()

var current_ap_for_planning: int = 0

# --- Abilities & Planning ---
@export var abilities: Array[Ability] = []
@export var move_ability_res: Ability # Assign res://Abilities/Move.tres in Inspector
var planned_actions: Array[PlannedAction] = []

# --- State ---
var is_selected: bool = false:
	set(value):
		is_selected = value
		_update_selection_visual()

# --- Movement ---
@export var move_speed: float = 150.0
var is_moving: bool = false

# --- Node References ---
@onready var sprite: Sprite2D = $sprite
@onready var nav_agent: NavigationAgent2D = $NavAgent
# In-world previews are part of the character's scene, not the UI layer. This is correct.
@onready var action_preview_line: Line2D = $ActionPreviewLine
@onready var aoe_preview_shape: Polygon2D = $AOEPreviewShape

var combat_manager: CombatManager
var selection_indicator: Sprite2D
var planned_move_silhouette: Sprite2D

# --- Initialization ---

func _ready():
	# If the character_id was set in the editor before runtime, apply data now.
	if not character_id.is_empty():
		_apply_character_data()

	# Initialize health. The setter will emit health_changed for the UI to catch.
	self.current_health = max_health

	# Ensure planned_actions is initialized to the correct size with nulls
	planned_actions.resize(max_ap_per_round)
	for i in range(max_ap_per_round): planned_actions[i] = null
	
	name = character_name # Set Node name for easier debugging in tree

	# Create in-world visuals that are part of this character's scene
	_create_selection_indicator()
	_create_planned_move_silhouette()

	# Connect nav_agent signals
	nav_agent.path_desired_distance = 5.0
	nav_agent.target_desired_distance = 5.0

	sync_collision_shapes()

func set_character_id(value: String):
	character_id = value
	if not is_node_ready():
		await ready
	_apply_character_data()

func _apply_character_data():
	if character_id.is_empty(): return
		
	var char_data = CharacterDatabase.get_character_data(character_id)
	if not char_data:
		printerr("Could not find character data for ID: ", character_id)
		return

	# Apply character data to this character instance
	self.character_name = char_data.display_name
	allegiance = char_data.allegiance
	max_health = char_data.base_health
	dexterity = char_data.base_dexterity
	max_ap_per_round = char_data.base_ap
	
	# This will trigger the setter and emit the signal for the UI
	self.current_health = max_health 
	
	set_sprite_texture(char_data.sprite_texture_path)
	_load_default_abilities(char_data.Abilities)
	
	# Add move ability if not present
	if move_ability_res and not abilities.has(move_ability_res):
		abilities.insert(0, move_ability_res)
func _load_default_abilities(ability_ids: Array[String]):
	abilities.clear()
	for ability_id in ability_ids:
		var ability_path = "res://Abilities/" + ability_id.capitalize().replace(" ", "") + ".tres"
		var ability = load(ability_path) as Ability
		if ability:
			abilities.append(ability)
		else:
			print("Warning: Could not load ability: ", ability_path)
func _set_character_name(new_name: String):
	character_name = new_name
	# Set the node's name for easier debugging in the scene tree.
	# No longer responsible for updating a UI label.
	name = character_name

func _create_selection_indicator():
	selection_indicator = Sprite2D.new()
	selection_indicator.texture = preload("res://selection ring.png")
	selection_indicator.modulate = Color.GREEN if allegiance == Allegiance.PLAYER else Color.ORANGE
	selection_indicator.visible = false
	add_child(selection_indicator)
	await get_tree().process_frame # Wait a frame for sprite texture to be loaded
	_position_selection_indicator()

func _create_planned_move_silhouette():
	planned_move_silhouette = Sprite2D.new()
	planned_move_silhouette.texture = sprite.texture
	planned_move_silhouette.scale = sprite.scale
	planned_move_silhouette.modulate = Color(1, 1, 1, 0.4)
	planned_move_silhouette.visible = false
	planned_move_silhouette.z_index = -1
	add_child(planned_move_silhouette)

# --- Physics & Movement ---

func _physics_process(delta):
	if is_moving and nav_agent and not nav_agent.is_navigation_finished():
		var next_path_pos = nav_agent.get_next_path_position()
		var direction = global_position.direction_to(next_path_pos)
		velocity = direction * move_speed
		move_and_slide()
		if global_position.distance_to(nav_agent.target_position) < nav_agent.target_desired_distance:
			_stop_movement()
	elif is_moving:
		_stop_movement()

func _stop_movement():
	is_moving = false
	velocity = Vector2.ZERO
	print_debug(character_name, " reached destination or stopped.")

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
		# NEW: After planning, update the silhouette if a move was planned
	if ability.id == &"move":
		print("DEBUG: Attempting to show silhoutte")
		show_planned_move_silhouette(p_target_pos)
	
	# NEW: Update all previews for this character
	show_all_planned_action_previews()
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

	#var caster_pos = global_position
	# MODIFIED: Caster position is now based on the plan
	var caster_pos = get_planned_position_for_slot(for_ap_slot)
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
			
			break
func _update_selection_visual():
	if selection_indicator:
		selection_indicator.visible = is_selected

func _position_selection_indicator():
	if not sprite or not sprite.texture or not is_instance_valid(selection_indicator):
		return
	var sprite_rect = sprite.get_rect()
	var bottom_y = sprite.position.y + sprite_rect.position.y + sprite_rect.size.y + 5
	selection_indicator.position = Vector2(sprite.position.x, bottom_y)
	var indicator_width = sprite.texture.get_size().x * sprite.scale.x * 0.8
	var indicator_height = 8.0
	var indicator_texture_size = selection_indicator.texture.get_size()
	selection_indicator.scale = Vector2(
		indicator_width / indicator_texture_size.x,
		indicator_height / indicator_texture_size.y
	)

func set_sprite_texture(texture_path: String):
	if texture_path.is_empty(): return
	if not sprite: await ready
	if sprite and is_instance_valid(sprite):
		var texture = load(texture_path) as Texture2D
		if texture:
			sprite.texture = texture
			call_deferred("sync_collision_shapes")
		else:
			printerr("Could not load texture from path: ", texture_path)

func sync_collision_shapes():
	if not sprite or not sprite.texture: return
	var sprite_size = sprite.texture.get_size() * sprite.scale
	var click_area_shape = get_node_or_null("ClickArea/CollisionShape2D")
	if click_area_shape and click_area_shape.shape is RectangleShape2D:
		click_area_shape.shape.size = sprite_size
	var body_collision_shape = get_node_or_null("CollisionShape2D")
	if body_collision_shape and body_collision_shape.shape is RectangleShape2D:
		body_collision_shape.shape.size = sprite_size * 0.8
			
# --- (NEW FUNCTIONS for Silhouette and Previews) ---

func get_planned_position_for_slot(slot_index: int) -> Vector2:
	"""Calculates the character's effective position for a given action slot,
	   considering any moves planned in previous slots."""
	var effective_pos = global_position
	for i in range(slot_index):
		var action = planned_actions[i]
		if action and action.action_type == PlannedAction.ActionType.MOVE:
			effective_pos = action.target_position
	return effective_pos

func get_last_planned_move_position() -> Vector2:
	"""Finds the position of the very last move action planned in any slot."""
	var last_pos = Vector2.INF # Use as a sentinel value for "no move planned"
	for action in planned_actions:
		if action and action.action_type == PlannedAction.ActionType.MOVE:
			last_pos = action.target_position
	return last_pos

func show_planned_move_silhouette(position: Vector2):
	if planned_move_silhouette:
		planned_move_silhouette.global_position = position
		planned_move_silhouette.visible = true

func hide_planned_move_silhouette():
	if planned_move_silhouette:
		planned_move_silhouette.visible = false

func show_all_planned_action_previews():
	"""Draws previews for all actions this character has planned."""
	hide_previews() # Clear existing single-action previews first
	
	for i in range(planned_actions.size()):
		var action = planned_actions[i]
		if action:
			var caster_effective_pos = get_planned_position_for_slot(i)
			var ability = get_ability_by_id(action.ability_id)
			if ability:
				var target_pos = action.target_position
				if is_instance_valid(action.target_character):
					target_pos = action.target_character.global_position
				
				# We need a way to draw multiple lines/previews.
				# For simplicity, let's reuse the existing Line2D and just show the last one.
				# A better implementation would instance new Line2D nodes for each preview.
				_draw_persistent_preview(ability, caster_effective_pos, target_pos)

func _draw_persistent_preview(ability: Ability, caster_pos: Vector2, target_pos: Vector2):
	"""Helper to draw a preview line. In a full implementation, you'd
	   create separate Line2D nodes for each planned action."""
	action_preview_line.points = [to_local(caster_pos), to_local(target_pos)]
	action_preview_line.default_color = Color.CYAN
	action_preview_line.visible = true
	
	if ability.area_of_effect_radius > 0:
		_draw_aoe_circle(to_local(target_pos), ability.area_of_effect_radius)
		aoe_preview_shape.color = Color(Color.CYAN, 0.3)
		aoe_preview_shape.visible = true
