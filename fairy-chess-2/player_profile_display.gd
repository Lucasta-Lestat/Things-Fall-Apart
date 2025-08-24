# PlayerProfileDisplay.gd
# A simple script for the reusable player profile UI component.

extends VBoxContainer

@onready var portrait = $Portrait
@onready var name_label = $NameLabel

# This function will be called by the main UI script to populate the display.
func set_profile(profile_data):
	print("DEBUG: set_profile called.  data: ", profile_data)
	if not profile_data:
		self.visible = false
		return
	
	self.visible = true
	name_label.text = profile_data.get("name", "Player")
	print("DEBUG: name_label.text = ", name_label.text)
	
	var portrait_path = profile_data.get("portrait", "")
	print("DEBUG: portrait_path = ", portrait_path, " File exists: ", FileAccess.file_exists(portrait_path))
	if FileAccess.file_exists(portrait_path):
		portrait.texture = load(portrait_path)
	else:
		# You can set a default texture here if you want
		portrait.texture = load("icon.svg")
