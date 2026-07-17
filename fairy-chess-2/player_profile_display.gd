# PlayerProfileDisplay.gd
# A simple script for the reusable player profile UI component.

extends VBoxContainer

@onready var portrait = $Portrait
@onready var name_label = $NameLabel

# This function will be called by the main UI script to populate the display.
func set_profile(profile_data):
	if not profile_data:
		self.visible = false
		return

	self.visible = true
	name_label.text = profile_data.get("name", "Player")

	var portrait_path = profile_data.get("portrait", "")
	# ResourceLoader.exists (not FileAccess) so imported textures are found
	# in exported builds too.
	if portrait_path != "" and ResourceLoader.exists(portrait_path):
		portrait.texture = load(portrait_path)
	else:
		portrait.texture = load("res://icon.svg")
