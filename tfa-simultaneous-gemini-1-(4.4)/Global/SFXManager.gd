extends Node

# Configuration
const POOL_SIZE = 32
const DEFAULT_BUS = "SFX"
const SFX_DIRECTORY = "res://sfx/" # Change this to your folder path

# Default pitch variance (+/- 10%)
const DEFAULT_PITCH_VAR = Vector2(0.9, 1.1)

# Library will be populated automatically
var sound_library: Dictionary = {}

# Internal variables
var _pool: Array[AudioStreamPlayer2D] = []
var _next_idx = 0

func _ready() -> void:
	# 1. Load sounds automatically
	_load_sounds_from_folder(SFX_DIRECTORY)
	
	# 2. Initialize the pool
	for i in range(POOL_SIZE):
		var player = AudioStreamPlayer2D.new()
		player.bus = DEFAULT_BUS
		add_child(player)
		_pool.append(player)
	
	print("SFXManager: Loaded %d sounds." % sound_library.size())

## Plays a 2D sound using a filename key (e.g. "jump" for "jump.wav")
func play(sound_key: String, global_pos: Vector2, pitch_range: Vector2 = DEFAULT_PITCH_VAR, volume_db: float = 0.0, bus: String = DEFAULT_BUS) -> void:
	if not sound_library.has(sound_key):
		push_warning("SFXManager: Sound '%s' not found." % sound_key)
		return
		
	var player = _get_next_player()
	player.stream = sound_library[sound_key]
	player.global_position = global_pos
	player.volume_db = volume_db
	player.bus = bus
	player.pitch_scale = randf_range(pitch_range.x, pitch_range.y)
	player.play()

## Plays a UI sound
func play_ui(sound_key: String, pitch_range: Vector2 = DEFAULT_PITCH_VAR, volume_db: float = 0.0) -> void:
	if not sound_library.has(sound_key):
		push_warning("SFXManager: Sound '%s' not found." % sound_key)
		return

	var player = AudioStreamPlayer.new()
	add_child(player)
	player.stream = sound_library[sound_key]
	player.volume_db = volume_db
	player.bus = DEFAULT_BUS
	player.pitch_scale = randf_range(pitch_range.x, pitch_range.y)
	player.finished.connect(player.queue_free)
	player.play()

# --- Auto-Loader ---

func _load_sounds_from_folder(path: String) -> void:
	var dir = DirAccess.open(path)
	if not dir:
		push_error("SFXManager: Could not open directory " + path)
		return
		
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		# Skip directories and navigation (./..)
		if not dir.current_is_dir():
			
			# Handle .remap or .import extensions for exported games
			# Godot sometimes renames files in export: "sound.wav.remap"
			var clean_name = file_name
			if clean_name.ends_with(".import") or clean_name.ends_with(".remap"):
				clean_name = clean_name.get_basename()
				
			# Check for valid audio extensions
			if clean_name.ends_with(".wav") or clean_name.ends_with(".ogg") or clean_name.ends_with(".mp3"):
				var key = clean_name.get_basename() # "jump.wav" -> "jump"
				# Load the actual resource path (original file name required for load)
				# Note: We load the original path, Godot handles the internal remapping
				sound_library[key] = load(path.path_join(clean_name))
				
		file_name = dir.get_next()

# --- Internal Helpers ---

func _get_next_player() -> AudioStreamPlayer2D:
	var player = _pool[_next_idx]
	_next_idx = (_next_idx + 1) % POOL_SIZE
	if player.playing:
		player.stop()
	return player
