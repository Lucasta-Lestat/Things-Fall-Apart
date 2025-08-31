# res://UI/CharacterUI.gd
extends PanelContainer
class_name CharacterUI

@onready var name_label: Label = $CharacterUIContainer/NameLabel
@onready var icon: TextureRect = $CharacterUIContainer/Icon
@onready var health_bar: ProgressBar = $CharacterUIContainer/HealthBar
@onready var ap_slots_container: HBoxContainer = $CharacterUIContainer/APSlotsContainer

var icon_size: Vector2 = Vector2(100.0,100.0)
var character: CombatCharacter
var combat_manager: CombatManager

# Use a TextureRect for AP slots to show different states
const AP_SLOT_EMPTY = preload("res://UI/Assets/ap_slot.png")
const AP_SLOT_PLANNED = preload("res://UI/Assets/ap_slot_planned.png")
const AP_SLOT_EXECUTED = preload("res://UI/Assets/ap_slot_executed.png")

func _ready():
	print("DEBUG: combat_manager initialized in CharacterUI. Value: ", combat_manager)

	# Hide by default until a character is set
	visible = true

func set_character(char: CombatCharacter):
	print("DEBUG: Set Character #ui")
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
	var texture = load(character.icon)
	
	icon.texture = load(character.icon)
	icon.custom_minimum_size = icon_size
	print("icon min size: ",icon.custom_minimum_size)
	var initial_icon_size = icon.texture.get_size()
	print("icon texture size: ", icon.texture.get_size())
	var size_ratio = icon_size.x/initial_icon_size.x
	print("size_ratio: ",size_ratio)
	icon.scale = Vector2(size_ratio,size_ratio)
	print("icon.scale:", icon.scale)
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
	print("update_all_ap_slots() called #combat #ui")
	for i in range(character.max_ap_per_round):
		update_ap_slot(i)

func update_ap_slot(slot_index: int):
	print("update_ap_slot() called #combat")
	print("DEBUG: update_ap_slot called")
	if slot_index >= ap_slots_container.get_child_count():
		print("DEBUG: slot_index >= ap_slots_container.get_child_count() #combat #ui")
		return # Should not happen if setup is correct

	var ap_slot_texture = ap_slots_container.get_child(slot_index) as TextureRect
	
	if combat_manager.current_combat_state == CombatManager.CombatState.RESOLVING_SLOT and slot_index < combat_manager.current_ap_slot_being_resolved:
		ap_slot_texture.texture = AP_SLOT_EXECUTED
	elif character.planned_actions.size() > slot_index and character.planned_actions[slot_index] != null:
		ap_slot_texture.texture = AP_SLOT_PLANNED
	else:
		ap_slot_texture.texture = AP_SLOT_EMPTY

func _on_health_changed(new_health, max_health, _char):
	print("_on_health_changed in CharacterUI #combat #ui")
	health_bar.max_value = max_health
	health_bar.value = new_health

func _on_action_changed(_char, slot_index, _action):
	print("_on_action_changed in CharacterUI #combat #ui")
	update_ap_slot(slot_index)
