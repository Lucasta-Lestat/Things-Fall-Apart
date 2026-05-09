extends Panel

# References to UI elements
@onready var character_portrait: TextureRect = $MarginContainer/HBoxContainer/Portrait
@onready var speaker_name_label: Label = $MarginContainer/HBoxContainer/DialogueVBox/SpeakerName
@onready var dialogue_text: RichTextLabel = $MarginContainer/HBoxContainer/DialogueVBox/DialogueText
@onready var choices_container: VBoxContainer = $MarginContainer/HBoxContainer/DialogueVBox/ChoicesContainer
@onready var continue_indicator: Label = $MarginContainer/HBoxContainer/DialogueVBox/ContinueIndicator

# Choice button scene (we'll create this)
const CHOICE_BUTTON = preload("res://choice_button.tscn")

# When true, a per-character looping .ogv video at Icons/anim/{id}/speak.ogv
# (if present) will be used instead of sprite frames. Used for the Veo
# prototype on Jacana; flip on to A/B test. Default off so the cheap
# sprite-frame path is the default rendered behavior.
const USE_VIDEO_PORTRAITS := false

# Reference to dialogue manager
var dialogue_manager: Node

# Speaking-portrait controller (sprite-frame mode).
var _portrait_anim: AnimatedPortrait = null
# Video stream player (Veo mode); created lazily, kept hidden until used.
var _portrait_video: VideoStreamPlayer = null

func _ready():
	# Hide panel by default
	hide()

	# Hide continue indicator initially
	continue_indicator.hide()

	# Set up the speaking-portrait animation controller, bound to the existing
	# Portrait TextureRect. Falls back to a static texture when a speaker has
	# no speak_frames defined.
	_portrait_anim = AnimatedPortrait.new()
	add_child(_portrait_anim)
	_portrait_anim.bind(character_portrait)

	# Find and connect to dialogue manager
	# Adjust the path based on your node structure
	dialogue_manager = get_node("/root/DialogueManager")

	if dialogue_manager:
		dialogue_manager.dialogue_updated.connect(_on_dialogue_updated)
		dialogue_manager.choices_available.connect(_on_choices_available)
		dialogue_manager.dialogue_ended.connect(_on_dialogue_ended)

func _input(event):
	# Only process input when panel is visible and no choices are shown
	if visible and choices_container.get_child_count() == 0:
		if event.is_action_pressed("ui_accept") or (event is InputEventKey and event.pressed and event.keycode == KEY_SPACE):
			# Advance dialogue
			if dialogue_manager:
				dialogue_manager.advance_line()

func _on_dialogue_updated(speaker_name: String, portrait: Texture2D, text: String, has_next: bool):
	# Show the panel
	show()

	# Update speaker name
	speaker_name_label.text = speaker_name

	# Update portrait + speaking animation
	if portrait:
		character_portrait.texture = portrait
		character_portrait.show()
		_setup_speaking_portrait(speaker_name, portrait)
	else:
		character_portrait.hide()
		if _portrait_anim:
			_portrait_anim.stop_speaking()
		_hide_video_portrait()

	# Update dialogue text
	dialogue_text.text = text

	# Clear any existing choices
	_clear_choices()

	# Show/hide continue indicator
	if has_next:
		continue_indicator.show()
		continue_indicator.text = "Press SPACE to continue..."
	else:
		continue_indicator.hide()

func _setup_speaking_portrait(speaker_name: String, rest_texture: Texture2D) -> void:
	# Veo prototype path: if enabled and an .ogv exists for this speaker, use
	# the video stream player instead of the sprite-frame TextureRect.
	if USE_VIDEO_PORTRAITS:
		var ogv_path := "res://Icons/anim/%s/speak.ogv" % speaker_name
		if ResourceLoader.exists(ogv_path):
			_play_video_portrait(ogv_path)
			if _portrait_anim:
				_portrait_anim.stop_speaking()
			return
	_hide_video_portrait()
	if _portrait_anim == null or dialogue_manager == null:
		return
	var frames: Array[Texture2D] = []
	if dialogue_manager.has_method("get_character_speak_frames"):
		frames = dialogue_manager.get_character_speak_frames(speaker_name)
	_portrait_anim.set_frames(frames, rest_texture)
	if _portrait_anim.has_animation():
		_portrait_anim.start_speaking()

func _play_video_portrait(stream_path: String) -> void:
	if _portrait_video == null:
		_portrait_video = VideoStreamPlayer.new()
		_portrait_video.expand = true
		_portrait_video.custom_minimum_size = character_portrait.custom_minimum_size
		_portrait_video.size_flags_horizontal = character_portrait.size_flags_horizontal
		_portrait_video.size_flags_vertical = character_portrait.size_flags_vertical
		_portrait_video.loop = true
		character_portrait.get_parent().add_child(_portrait_video)
		character_portrait.get_parent().move_child(_portrait_video, character_portrait.get_index())
	character_portrait.hide()
	_portrait_video.stream = load(stream_path)
	_portrait_video.show()
	_portrait_video.play()

func _hide_video_portrait() -> void:
	if _portrait_video == null:
		return
	if _portrait_video.is_playing():
		_portrait_video.stop()
	_portrait_video.hide()
	character_portrait.show()

func _on_choices_available(choices: Array):
	# Clear existing choices
	_clear_choices()

	# Speaker is done; stop speaking animation while the player picks a choice.
	if _portrait_anim:
		_portrait_anim.stop_speaking()
	_hide_video_portrait()

	# Hide continue indicator when choices are shown
	continue_indicator.hide()
	
	# Create button for each choice
	for i in range(choices.size()):
		var choice = choices[i]
		var button = CHOICE_BUTTON.instantiate()
		button.text = choice["text"]
		
		# Connect button press to choice selection
		button.pressed.connect(_on_choice_selected.bind(i))
		
		choices_container.add_child(button)

func _on_choice_selected(choice_index: int):
	SfxManager.play_ui("ui-click")
	# Tell dialogue manager which choice was selected
	if dialogue_manager:
		dialogue_manager.select_choice(choice_index)

func _on_dialogue_ended():
	# Hide the panel
	hide()

	# Stop speaking animation / video.
	if _portrait_anim:
		_portrait_anim.stop_speaking()
	_hide_video_portrait()

	# Clear choices
	_clear_choices()

func _clear_choices():
	# Remove all choice buttons
	for child in choices_container.get_children():
		child.queue_free()
