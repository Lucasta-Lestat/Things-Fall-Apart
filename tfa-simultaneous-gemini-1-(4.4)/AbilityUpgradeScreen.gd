# AbilityUpgradeScreen.gd
extends Control

signal ability_selected(ability)
signal upgrade_cancelled()

@export var abilities_database: Resource  # Your abilities database resource
@export var keyword_definitions: Dictionary = {
	"Daze": "Target is stunned and cannot act for 1 turn",
	"Burn": "Target takes damage over time",
	"Freeze": "Target's movement is reduced",
	# Add more keywords as needed
}

var current_character = null
var available_abilities: Array = []
var ability_cards: Array = []

@onready var splash_image: TextureRect = $HBoxContainer/SplashImage
@onready var abilities_container: VBoxContainer = $HBoxContainer/AbilitiesPanel/VBoxContainer
@onready var character_name_label: Label = $HBoxContainer/AbilitiesPanel/CharacterName
@onready var title_label: Label = $HBoxContainer/AbilitiesPanel/TitleLabel

func _ready():
	setup_ui()

func setup_ui():
	# Create the base UI structure if not already in scene
	if not has_node("HBoxContainer"):
		create_ui_structure()
	
	# Connect any necessary signals
	if has_node("HBoxContainer/AbilitiesPanel/ButtonContainer/CancelButton"):
		$HBoxContainer/AbilitiesPanel/ButtonContainer/CancelButton.pressed.connect(_on_cancel_pressed)

func create_ui_structure():
	var hbox = HBoxContainer.new()
	hbox.name = "HBoxContainer"
	add_child(hbox)
	
	# Splash image on the left
	var splash = TextureRect.new()
	splash.name = "SplashImage"
	splash.custom_minimum_size = Vector2(400, 600)
	splash.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	hbox.add_child(splash)
	splash_image = splash
	
	# Abilities panel on the right
	var panel = Panel.new()
	panel.name = "AbilitiesPanel"
	panel.custom_minimum_size = Vector2(600, 600)
	hbox.add_child(panel)
	
	var vbox_main = VBoxContainer.new()
	vbox_main.add_theme_constant_override("separation", 20)
	panel.add_child(vbox_main)
	vbox_main.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox_main.set_offsets_preset(Control.PRESET_FULL_RECT)
	
	# Title
	var title = Label.new()
	title.name = "TitleLabel"
	title.text = "Choose Your Ability"
	title.add_theme_font_size_override("font_size", 24)
	vbox_main.add_child(title)
	title_label = title
	
	# Character name
	var char_name = Label.new()
	char_name.name = "CharacterName"
	char_name.text = "Character Name"
	char_name.add_theme_font_size_override("font_size", 18)
	vbox_main.add_child(char_name)
	character_name_label = char_name
	
	# Abilities container
	var abilities_vbox = VBoxContainer.new()
	abilities_vbox.name = "VBoxContainer"
	abilities_vbox.add_theme_constant_override("separation", 15)
	vbox_main.add_child(abilities_vbox)
	abilities_container = abilities_vbox
	
	# Button container
	var button_container = HBoxContainer.new()
	button_container.name = "ButtonContainer"
	button_container.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox_main.add_child(button_container)
	
	var cancel_button = Button.new()
	cancel_button.name = "CancelButton"
	cancel_button.text = "Cancel"
	button_container.add_child(cancel_button)

func show_upgrade_options(character, required_traits: Array):
	current_character = character
	
	# Set character splash image
	if character.has("splash_image") and splash_image:
		var texture = load(character.splash_image)
		if texture:
			splash_image.texture = texture
	
	# Set character name
	if character.has("name") and character_name_label:
		character_name_label.text = "Learning from: " + character.name
	
	# Filter abilities by traits
	var filtered_abilities = filter_abilities_by_traits(required_traits)
	
	# Select 3 random abilities
	available_abilities = select_random_abilities(filtered_abilities, 3)
	
	# Display the abilities
	display_abilities()
	
	# Show the screen
	show()

func filter_abilities_by_traits(required_traits: Array) -> Array:
	var filtered = []
	
	# Assuming abilities_database has a method to get all abilities
	# Adjust based on your actual database structure
	var all_abilities = abilities_database.get_all_abilities() if abilities_database.has_method("get_all_abilities") else []
	
	for ability in all_abilities:
		if ability.has("traits") and has_required_traits(ability.traits, required_traits):
			filtered.append(ability)
	
	return filtered

func has_required_traits(ability_traits: Array, required_traits: Array) -> bool:
	for Trait in required_traits:
		if not Trait in ability_traits:
			return false
	return true

func select_random_abilities(abilities: Array, count: int) -> Array:
	if abilities.size() <= count:
		return abilities
	
	var selected = []
	var temp_abilities = abilities.duplicate()
	temp_abilities.shuffle()
	
	for i in min(count, temp_abilities.size()):
		selected.append(temp_abilities[i])
	
	return selected

func display_abilities():
	# Clear existing ability cards
	for card in ability_cards:
		card.queue_free()
	ability_cards.clear()
	
	# Create new ability cards
	for ability in available_abilities:
		var card = create_ability_card(ability)
		abilities_container.add_child(card)
		ability_cards.append(card)

func create_ability_card(ability) -> Panel:
	var card = Panel.new()
	card.custom_minimum_size = Vector2(550, 120)
	
	# Create a stylebox for the card
	var stylebox = StyleBoxFlat.new()
	stylebox.bg_color = Color(0.1, 0.1, 0.2, 0.9)
	stylebox.border_color = get_tier_color(ability.get("tier", "Common"))
	stylebox.set_border_width_all(2)
	stylebox.set_corner_radius_all(8)
	card.add_theme_stylebox_override("panel", stylebox)
	
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 15)
	card.add_child(hbox)
	hbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hbox.set_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_KEEP_SIZE, 10)
	
	# Icon
	var icon_container = Panel.new()
	icon_container.custom_minimum_size = Vector2(80, 80)
	hbox.add_child(icon_container)
	
	if ability.has("icon"):
		var icon = TextureRect.new()
		icon.texture = load(ability.icon)
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_container.add_child(icon)
		icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	
	# Info container
	var info_vbox = VBoxContainer.new()
	info_vbox.add_theme_constant_override("separation", 5)
	hbox.add_child(info_vbox)
	
	# Name and tier row
	var name_row = HBoxContainer.new()
	info_vbox.add_child(name_row)
	
	var name_label = Label.new()
	name_label.text = ability.get("name", "Unknown Ability")
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.add_theme_color_override("font_color", get_tier_color(ability.get("tier", "Common")))
	name_row.add_child(name_label)
	
	name_row.add_spacer(false)
	
	var tier_label = Label.new()
	tier_label.text = ability.get("tier", "Common").to_upper()
	tier_label.add_theme_font_size_override("font_size", 14)
	tier_label.add_theme_color_override("font_color", get_tier_color(ability.get("tier", "Common")))
	name_row.add_child(tier_label)
	
	# Description with keyword highlighting
	var desc_label = RichTextLabel.new()
	desc_label.bbcode_enabled = true
	desc_label.fit_content = true
	desc_label.custom_minimum_size = Vector2(0, 60)
	desc_label.text = process_description_keywords(ability.get("description", ""))
	info_vbox.add_child(desc_label)
	
	# Connect mouse events for tooltips
	desc_label.meta_hover_started.connect(_on_keyword_hover_started)
	desc_label.meta_hover_ended.connect(_on_keyword_hover_ended)
	
	# Stats row
	if ability.has("stats"):
		var stats_label = Label.new()
		stats_label.text = format_ability_stats(ability.stats)
		stats_label.add_theme_font_size_override("font_size", 12)
		stats_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		info_vbox.add_child(stats_label)
	
	# Select button
	var select_button = Button.new()
	select_button.text = "Select"
	select_button.custom_minimum_size = Vector2(80, 40)
	hbox.add_child(select_button)
	select_button.pressed.connect(_on_ability_selected.bind(ability))
	
	return card

func process_description_keywords(description: String) -> String:
	var processed = description
	
	for keyword in keyword_definitions.keys():
		# Use BBCode to make keywords bold and clickable
		var pattern = "\\b" + keyword + "\\b"
		var regex = RegEx.new()
		regex.compile(pattern)
		
		for result in regex.search_all(processed):
			var found_text = result.get_string()
			var replacement = "[b][url={\"keyword\":\"" + keyword + "\"}]" + found_text + "[/url][/b]"
			processed = processed.replace(found_text, replacement)
	
	return processed

func format_ability_stats(stats: Dictionary) -> String:
	var formatted = []
	
	for stat_name in stats:
		var value = stats[stat_name]
		if value > 0:
			formatted.append("+" + str(value) + "% " + stat_name)
		else:
			formatted.append(str(value) + "% " + stat_name)
	
	return " • ".join(formatted)

func get_tier_color(tier: String) -> Color:
	match tier.to_lower():
		"legendary":
			return Color(1.0, 0.5, 0.0)  # Orange
		"epic":
			return Color(0.7, 0.3, 0.9)  # Purple
		"rare":
			return Color(0.3, 0.6, 1.0)  # Blue
		"uncommon":
			return Color(0.3, 0.9, 0.3)  # Green
		_:
			return Color(0.7, 0.7, 0.7)  # Gray for common

var tooltip = null

func _on_keyword_hover_started(meta):
	if typeof(meta) == TYPE_DICTIONARY and meta.has("keyword"):
		show_keyword_tooltip(meta.keyword)

func _on_keyword_hover_ended(meta):
	hide_keyword_tooltip()

func show_keyword_tooltip(keyword: String):
	if not keyword_definitions.has(keyword):
		return
	
	# Create tooltip if it doesn't exist
	if not tooltip:
		tooltip = Panel.new()
		var tooltip_style = StyleBoxFlat.new()
		tooltip_style.bg_color = Color(0.0, 0.0, 0.0, 0.9)
		tooltip_style.border_color = Color(0.5, 0.5, 0.5)
		tooltip_style.set_border_width_all(1)
		tooltip_style.set_corner_radius_all(4)
		tooltip.add_theme_stylebox_override("panel", tooltip_style)
		
		var tooltip_label = Label.new()
		tooltip_label.name = "TooltipLabel"
		tooltip.add_child(tooltip_label)
		tooltip_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		tooltip_label.set_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_KEEP_SIZE, 8)
		
		get_tree().root.add_child(tooltip)
	
	# Set tooltip text and position
	var tooltip_label = tooltip.get_node("TooltipLabel")
	tooltip_label.text = keyword + ": " + keyword_definitions[keyword]
	
	var mouse_pos = get_viewport().get_mouse_position()
	tooltip.position = mouse_pos + Vector2(10, 10)
	tooltip.size = tooltip_label.get_minimum_size() + Vector2(16, 16)
	tooltip.show()

func hide_keyword_tooltip():
	if tooltip:
		tooltip.hide()

func _on_ability_selected(ability):
	ability_selected.emit(ability)
	hide()

func _on_cancel_pressed():
	upgrade_cancelled.emit()
	hide()

func _exit_tree():
	if tooltip:
		tooltip.queue_free()
