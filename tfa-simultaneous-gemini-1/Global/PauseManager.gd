# PauseManager.gd
# Add this as an Autoload in Project Settings -> Autoload
# Name it "PauseManager"
# IMPORTANT: Make sure this loads AFTER TimeManager in the Autoload list
extends Node

signal game_paused
signal game_unpaused

var is_paused: bool = false

# On-screen "PAUSED" banner. Clicks queue orders while paused and act at
# once while running, so the player always needs to know which mode they're in.
var _indicator_layer: CanvasLayer
var _indicator: Label

const BANNER_PLANNING := "PAUSED  ·  Space to resume"
# While a conversation is up, Space advances its lines (dialogue_panel.gd
# consumes the pause action), so the banner mustn't promise that it resumes.
const BANNER_TALKING := "PAUSED — in conversation"

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_indicator()
	# DialogueManager is an earlier autoload, so it is already in the tree.
	var dm = get_node_or_null("/root/DialogueManager")
	if dm:
		dm.dialogue_updated.connect(_update_indicator.unbind(4))
		dm.dialogue_ended.connect(_update_indicator)

func _build_indicator() -> void:
	_indicator_layer = CanvasLayer.new()
	_indicator_layer.layer = 50
	add_child(_indicator_layer)
	_indicator = Label.new()
	_indicator.text = BANNER_PLANNING
	_indicator.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_indicator.add_theme_font_size_override("font_size", 20)
	_indicator.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	_indicator.add_theme_color_override("font_outline_color", Color.BLACK)
	_indicator.add_theme_constant_override("outline_size", 6)
	_indicator.anchor_left = 0.5
	_indicator.anchor_right = 0.5
	_indicator.offset_left = -250
	_indicator.offset_right = 250
	_indicator.offset_top = 12
	_indicator.visible = false
	_indicator_layer.add_child(_indicator)

func _update_indicator() -> void:
	if _indicator:
		_indicator.visible = is_paused
		var dm = get_node_or_null("/root/DialogueManager")
		var talking: bool = dm != null and dm.has_method("is_active") and dm.is_active()
		_indicator.text = BANNER_TALKING if talking else BANNER_PLANNING

func _input(event: InputEvent) -> void:
	# A space typed in a text field (the carta's name, the combat-test filter)
	# must not toggle the pause: Node._input runs BEFORE Control gui_input, so
	# the focused LineEdit can't consume it first (same guard as Game._input).
	if event is InputEventKey:
		var focus := get_viewport().gui_get_focus_owner()
		if focus is LineEdit or focus is TextEdit:
			return
	if event.is_action_pressed("pause"):
		toggle_pause()

func toggle_pause() -> void:
	if is_paused:
		unpause()
	else:
		pause()

## `play_sound` is false when the pause rides on something with its own sound
## (a conversation closing into the fight it started).
func pause(play_sound: bool = true) -> void:
	if is_paused:
		return
	print("game paused")
	is_paused = true
	get_tree().paused = true
	
	# Also pause TimeManager's game time
	if TimeManager:
		TimeManager.pause_time()
	_update_indicator()
	if play_sound:
		SfxManager.play_ui("ui_pause", Vector2.ONE, -6.0)
	
	emit_signal("game_paused")

func unpause() -> void:
	if not is_paused:
		return
	is_paused = false
	get_tree().paused = false
	
	# Also resume TimeManager's game time
	if TimeManager:
		TimeManager.resume_time()
	_update_indicator()
	SfxManager.play_ui("ui_unpause", Vector2.ONE, -6.0)
	
	emit_signal("game_unpaused")
