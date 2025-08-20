# res://UI/GameUI.gd
extends CanvasLayer
class_name GameUI

@onready var character_ui_container = $MarginContainer/CharacterUI/CharacterUIContainer

const CharacterUI_Scene = preload("res://UI/CharacterUI.tscn")

var combat_manager: CombatManager
var player_input_manager: PlayerInputManager
var character_ui_map: Dictionary = {} # Maps CombatCharacter to its CharacterUI instance

func _ready():
	# The Game node will set these references
	print("DEBUG: ready in GameUI")
	pass

func setup(cm: CombatManager, pim: PlayerInputManager):
	self.combat_manager = cm
	self.player_input_manager = pim
	
	# Connect to CombatManager signals
	print("DEBUG: setup in GameUI called")
	print("DEBUG: setup characters directly in setup in GameUI")
	var all_chars = combat_manager.all_characters_in_combat
	print("DEBUG: all_chars created")
	for char in all_chars:
		if not character_ui_map.has(char):
			_create_character_ui(char)
	for char in character_ui_map.keys():
		if is_instance_valid(char):
			character_ui_map[char].update_all_ap_slots()
	combat_manager.round_started.connect(_on_round_started)
	combat_manager.planning_phase_started.connect(_on_planning_phase_started)
	combat_manager.resolution_phase_started.connect(_on_resolution_phase_started)
	combat_manager.ap_slot_resolved.connect(_on_ap_slot_resolved)
	combat_manager.combat_ended.connect(_on_combat_ended)

	# Connect to PlayerInputManager signals
	player_input_manager.selection_changed.connect(_on_player_selection_changed)

# --- MODIFIED FUNCTION ---
# Made the function async to allow for 'await'
func _create_character_ui(character: CombatCharacter):
	print("DEBUG: attempt to create character UI for", character.name)
	if character_ui_map.has(character):
		return

	var char_ui = CharacterUI_Scene.instantiate()
	character_ui_container.add_child(char_ui)
	
	# 1. Wait for the new node to be fully ready in the scene tree.
	# This ensures its own @onready vars are set before we proceed.
	await char_ui.ready
	
	# 2. Inject the dependency. Pass the "real" combat manager to the UI instance.
	char_ui.combat_manager = self.combat_manager
	
	# 3. Now that the UI has its manager, it's safe to call its setup function.
	char_ui.set_character(character)
	
	character_ui_map[character] = char_ui

func _on_round_started():
	# On the first round, this will create the UI for all characters.
	# This ensures the node is ready and the combat manager has the character list.
	var all_chars = combat_manager.all_characters_in_combat
	print("DEBUG: all_chars created")
	for char in all_chars:
		if not character_ui_map.has(char):
			_create_character_ui(char)
	for char in character_ui_map.keys():
		if is_instance_valid(char):
			character_ui_map[char].update_all_ap_slots()

func _on_planning_phase_started():
	# Show enemy intents when the player starts planning
	for char in combat_manager.enemy_party:
		if is_instance_valid(char) and char.current_health > 0:
			char.show_enemy_intent()

func _on_resolution_phase_started():
	# Hide all previews and silhouettes when resolution starts
	for char in combat_manager.all_characters_in_combat:
		if is_instance_valid(char):
			char.hide_previews()
			char.hide_planned_move_silhouette()

func _on_ap_slot_resolved(slot_index: int):
	for char_ui in character_ui_map.values():
		char_ui.update_ap_slot(slot_index)

func _on_player_selection_changed(selected_chars: Array[CombatCharacter]):
	# Hide all previews first
	for char in combat_manager.all_characters_in_combat:
		if is_instance_valid(char):
			char.hide_previews()
			# Keep enemy intents visible during planning
			if char.allegiance == CombatCharacter.Allegiance.ENEMY and combat_manager.current_combat_state == CombatManager.CombatState.PLANNING:
				char.show_enemy_intent()

	# Show previews for the newly selected characters
	for char in selected_chars:
		if is_instance_valid(char):
			char.show_all_planned_action_previews()

func _on_combat_ended(_winner):
	for char_ui in character_ui_map.values():
		char_ui.queue_free()
	character_ui_map.clear()
