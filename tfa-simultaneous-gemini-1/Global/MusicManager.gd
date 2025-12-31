extends Node

const MUSIC_DIR = "res://Music/"
const DEFAULT_CROSSFADE = 2.0 # Duration in seconds
const MUSIC_BUS = "Music"

var tracks: Dictionary = {}

# We use two players to allow crossfading (one fades out while other fades in)
var _player_a: AudioStreamPlayer
var _player_b: AudioStreamPlayer
var _current_player: AudioStreamPlayer = null

func _ready() -> void:
	_load_music_from_folder(MUSIC_DIR)
	
	# Setup the two players
	_player_a = _create_player()
	_player_b = _create_player()

## Plays a music track by key. Handles crossfading automatically.
## [track_key]: The filename without extension (e.g. "boss_theme")
## [crossfade]: Time in seconds to fade. 0.0 for instant cut.
func play(track_key: String, crossfade: float = DEFAULT_CROSSFADE) -> void:
	if not tracks.has(track_key):
		push_warning("MusicManager: Track '%s' not found." % track_key)
		return
		
	var new_stream = tracks[track_key]
	
	# 1. If nothing is playing, just start the track
	if _current_player == null:
		_current_player = _player_a
		_current_player.stream = new_stream
		_current_player.volume_db = 0 # Reset volume
		_current_player.play()
		return

	# 2. If the requested track is ALREADY playing, do nothing
	if _current_player.stream == new_stream and _current_player.playing:
		return

	# 3. Crossfade Logic
	# Identify the "next" player (the one not currently playing)
	var old_player = _current_player
	var new_player = _player_b if _current_player == _player_a else _player_a
	
	new_player.stream = new_stream
	new_player.volume_db = -80 # Start silent
	new_player.play()
	
	var tween = create_tween()
	# Fade OUT old player
	tween.parallel().tween_property(old_player, "volume_db", -80, crossfade)
	# Fade IN new player
	tween.parallel().tween_property(new_player, "volume_db", 0, crossfade)
	
	# Cleanup old player when done
	tween.chain().tween_callback(old_player.stop)
	
	_current_player = new_player

## Stops the music with a fade out
func stop(fade_duration: float = DEFAULT_CROSSFADE) -> void:
	if _current_player and _current_player.playing:
		var tween = create_tween()
		tween.tween_property(_current_player, "volume_db", -80, fade_duration)
		tween.tween_callback(_current_player.stop)

# --- Internal Helpers ---

func _create_player() -> AudioStreamPlayer:
	var p = AudioStreamPlayer.new()
	p.bus = MUSIC_BUS
	add_child(p)
	return p

func _load_music_from_folder(path: String) -> void:
	var dir = DirAccess.open(path)
	if not dir:
		return
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if not dir.current_is_dir():
			var clean_name = file_name
			if clean_name.ends_with(".import") or clean_name.ends_with(".remap"):
				clean_name = clean_name.get_basename()
			
			if clean_name.ends_with(".wav") or clean_name.ends_with(".ogg") or clean_name.ends_with(".mp3"):
				var key = clean_name.get_basename()
				tracks[key] = load(path.path_join(clean_name))
				
		file_name = dir.get_next()
