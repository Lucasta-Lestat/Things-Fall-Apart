# AudioManager.gd

extends Node

# Get references to all the audio player nodes
@onready var music_player = $MusicPlayer
@onready var move_sfx = $MoveSFX
@onready var spawn_sfx = $SpawnSFX 
@onready var capture_sfx = $CaptureSFX
@onready var promote_sfx = $PromoteSFX
@onready var shoot_sfx = $RifleSFX
@onready var cannon_sfx = $CannonSFX
@onready var game_over_sfx = $WinSound

# --- Music Control ---
func play_music():
	if not music_player.playing:
		music_player.play()

func stop_music():
	music_player.stop()

# --- Sound Effect Control ---
# A central function to play sound effects by name.
func play_sfx(sfx_name):
	match sfx_name:
		"move":
			move_sfx.play()
		"spawn":
			spawn_sfx.play()
		"capture":
			capture_sfx.play()
		"promote":
			promote_sfx.play()
		"shoot":
			shoot_sfx.play()
		"cannon":
			cannon_sfx.play()
		"win":
			game_over_sfx.play()
		
