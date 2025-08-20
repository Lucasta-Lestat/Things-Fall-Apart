# res://UI/CharacterUI.gd
extends PanelContainer
class_name CharacterUI

@onready var name_label: Label = %NameLabel
@onready var health_bar: ProgressBar = %HealthBar
@onready var ap_slots_container: HBoxContainer = %APSlotsContainer

var character: CombatCharacter
var combat_manager: CombatManager

# Use a TextureRect for AP slots to show different states
const AP_SLOT_EMPTY = preload("res://UI/Assets/ap_slot.png")
const AP_SLOT_PLANNED = preload("res://UI/Assets/ap_slot_planned.png")
const AP_SLOT_EXECUTED = preload("res://UI/Assets/ap_slot_executed.png")

func _ready():
	print("DEBUG: combat_manager initialized in CharacterUI. Value: ", combat_manager)

	# Hide by default until a character is set
	visible = false

func set_character(char: CombatCharacter):
	print("DEBUG: Set Character")
	self.character = char
	if not is_instance_valid(character):
		push_error("Assigned an invalid character to CharacterUI")
		return
	
	visible = true
	name = "UI_" + character.character_name # For easier debugging in the scene tree
	
	# Initial UI setup
	name_label.text = character.character_name
	health_bar.max_value = character.max_health
	print("DEBUG:",character.character_name, "max health:", character.max_health)
	
	health_bar.value = character.current_health
	
	# Connect to character signals
	character.health_changed.connect(_on_health_changed)
	character.planned_action_for_slot.connect(_on_action_changed)
	character.died.connect(func(_char): queue_free()) # Remove UI on death

	setup_ap_slots()
	update_all_ap_slots()

func setup_ap_slots():
	# Clear any existing slots
	for child in ap_slots_container.get_children():
		child.queue_free()
		
	# Create slots based on character's max AP
	for i in range(character.max_ap_per_round):
		var ap_slot_texture = TextureRect.new()
		ap_slot_texture.texture = AP_SLOT_EMPTY
		ap_slot_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ap_slot_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ap_slots_container.add_child(ap_slot_texture)

func update_all_ap_slots():
	for i in range(character.max_ap_per_round):
		update_ap_slot(i)

func update_ap_slot(slot_index: int):
	print("DEBUG: update_ap_slot called")
	if slot_index >= ap_slots_container.get_child_count():
		print("DEBUG: slot_index >= ap_slots_container.get_child_count()")
		return # Should not happen if setup is correct

	var ap_slot_texture = ap_slots_container.get_child(slot_index) as TextureRect
	
	if combat_manager.current_combat_state == CombatManager.CombatState.RESOLVING_SLOT and slot_index < combat_manager.current_ap_slot_being_resolved:
		ap_slot_texture.texture = AP_SLOT_EXECUTED
	elif character.planned_actions.size() > slot_index and character.planned_actions[slot_index] != null:
		ap_slot_texture.texture = AP_SLOT_PLANNED
	else:
		ap_slot_texture.texture = AP_SLOT_EMPTY

func _on_health_changed(new_health, max_health, _char):
	health_bar.max_value = max_health
	health_bar.value = new_health

func _on_action_changed(_char, slot_index, _action):
	update_ap_slot(slot_index)
