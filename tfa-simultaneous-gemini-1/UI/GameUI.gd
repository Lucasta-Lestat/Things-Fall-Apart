# res://UI/GameUI.gd
extends CanvasLayer
class_name GameUI

#@onready var character_ui_container = $MarginContainer/VBoxContainer/CharacterUI/CharacterUIContainer
@onready var margin_container_vbox = $MarginContainer/VBoxContainer


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
	var game_node = self.get_parent()
	
	# Connect to CombatManager signals
	print("DEBUG: setup in GameUI called #ui")
	combat_manager.combat_started.connect(_on_combat_started)
	combat_manager.round_started.connect(_on_round_started)
	combat_manager.planning_phase_started.connect(_on_planning_phase_started)
	combat_manager.resolution_phase_started.connect(_on_resolution_phase_started)
	combat_manager.ap_slot_resolved.connect(_on_ap_slot_resolved)
	combat_manager.combat_ended.connect(_on_combat_ended)
	
	# Connect to PlayerInputManager signals
	player_input_manager.selection_changed.connect(_on_player_selection_changed)
	
	if game_node.is_active_combat:
		_on_combat_started()

# --- MODIFIED FUNCTION ---
func _create_character_ui(character: CombatCharacter):
	print("DEBUG: attempt to create character UI for ", character.character_name, " #ui")
	if character_ui_map.has(character):
		print("character_ui map already has character #ui")
		return

	var charUI = CharacterUI_Scene.instantiate()
	print(' test instantiate charUI #ui')
	margin_container_vbox.add_child(charUI)
	charUI.combat_manager = self.combat_manager
	
	# 3. Now that the UI has its manager, it's safe to call its setup function.
	charUI.set_character(character)
	
	character_ui_map[character] = charUI
func _on_combat_started():
	print("on_combat_started() called in gameUI #combat #ui")
	var party_chars = combat_manager.player_party
	print("DEBUG: party_chars created #ui")
	for char in party_chars:
		if not character_ui_map.has(char):
			_create_character_ui(char)
	for char in character_ui_map.keys():
		if is_instance_valid(char):
			character_ui_map[char].update_all_ap_slots()
func _on_round_started():
	# On the first round, this will create the UI for all characters.
	# This ensures the node is ready and the combat manager has the character list.
	print("on round started in GameUI #ui.  pass for now")
	pass

func _on_planning_phase_started():
	# Show enemy intents when the player starts planning
	# Show the full visual plan for all enemies.
	for char in combat_manager.enemy_party:
		if is_instance_valid(char) and char.current_health > 0:
			char.update_all_visual_previews()

func _on_resolution_phase_started():
	# Hide all previews and silhouettes when resolution starts
	for char in combat_manager.all_characters_in_combat:
		if is_instance_valid(char):
			char.hide_previews()

func _on_ap_slot_resolved(slot_index: int):
	for char_ui in character_ui_map.values():
		if char_ui != null:
			char_ui.update_ap_slot(slot_index)

func _on_player_selection_changed(selected_chars: Array[CombatCharacter]):
	# Hide all previews first
	for char in combat_manager.player_party:
		char.update_all_visual_previews()
	print('on_player_selection_changed run')
	#print("not currently using _on_player_selection_changed, will display abilities with it later")
	pass

func _on_combat_ended(_winner):
	for char_ui in character_ui_map.values():
		char_ui.queue_free()
	character_ui_map.clear()
