# PauseManager.gd
# Add this as an Autoload in Project Settings -> Autoload
# Name it "PauseManager"
# IMPORTANT: Make sure this loads AFTER TimeManager in the Autoload list
extends Node

signal game_paused
signal game_unpaused

var is_paused: bool = false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		toggle_pause()

func toggle_pause() -> void:
	if is_paused:
		unpause()
	else:
		pause()

func pause() -> void:
	if is_paused:
		return
	print("game paused")
	is_paused = true
	get_tree().paused = true
	
	# Also pause TimeManager's game time
	if TimeManager:
		TimeManager.pause_time()
	
	emit_signal("game_paused")

func unpause() -> void:
	if not is_paused:
		return
	is_paused = false
	get_tree().paused = false
	
	# Also resume TimeManager's game time
	if TimeManager:
		TimeManager.resume_time()
	
	emit_signal("game_unpaused")
