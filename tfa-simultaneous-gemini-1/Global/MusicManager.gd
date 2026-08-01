extends Node

const MUSIC_DIR = "res://Music/"
const DEFAULT_CROSSFADE = 2.0 # Duration in seconds
const COMBAT_CROSSFADE = 1.0 # Snappier stab when a fight starts
const MUSIC_BUS = "Music"

## Tracks eligible to play when the party is in combat. One is picked at
## random per encounter so repeated fights on the same map don't all sound
## identical. Keys are filenames-without-extension in MUSIC_DIR.
## Every entry here must be cleared for use in MUSIC_CREDITS.md.
const COMBAT_TRACKS: PackedStringArray = [
	"combat-chase",
	"combat-dragonslayer",
	"combat-juggernaut",
	"combat-celtic-impulse",
	"combat-march-of-midnight",
]

## Played on any map whose `music_track` is blank or unresolvable. Chosen for
## being mood-neutral — "a meditative, ebbing ambient work" — so it sits under
## a town, a road or a crypt without editorialising. Set to "" to restore the
## old behaviour of silence-by-default.
const DEFAULT_AMBIENT_TRACK := "ambient-permafrost"

## Opt-in silence: a map that genuinely wants no music sets its `music_track`
## to this rather than leaving it blank, which now means "use the default".
const SILENCE_KEY := "none"

var tracks: Dictionary = {}

# The map's own track — what we return to when combat ends.
var _ambient_key: String = ""
var _in_combat: bool = false

# We use two players to allow crossfading (one fades out while other fades in)
var _player_a: AudioStreamPlayer
var _player_b: AudioStreamPlayer
var _current_player: AudioStreamPlayer = null
# True while stop()'s fade-out tween is still running on _current_player.
var _fading_out: bool = false
var _tween: Tween = null

func _ready() -> void:
	# Music is diegetically outside the simulation: it must survive
	# `get_tree().paused`, which covers both the pause menu and the tactical
	# pause the player spends much of a fight inside. Without this the
	# AudioStreamPlayers inherit PROCESS_MODE_PAUSABLE and cut out mid-bar.
	# Same pattern as PauseManager/TimeManager/BoidServer.
	process_mode = Node.PROCESS_MODE_ALWAYS

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

	# 2. If the requested track is ALREADY playing, do nothing.
	#    `_fading_out` guards the case where stop() left this player audible
	#    but tweening to silence — re-requesting the same track must restart
	#    the fade-in, not ride the fade-out down to nothing.
	if _current_player.stream == new_stream and _current_player.playing \
			and not _fading_out:
		return
	_fading_out = false

	# 3. Crossfade Logic
	# Identify the "next" player (the one not currently playing)
	var old_player = _current_player
	var new_player = _player_b if _current_player == _player_a else _player_a

	new_player.stream = new_stream
	new_player.volume_db = -80 # Start silent
	new_player.play()

	# Kill any in-flight fade first: two live tweens driving the same
	# volume_db fight each other and can strand a player at -80 while
	# `playing` stays true, which reads as "already playing" forever after.
	var tween = _restart_tween()
	# Fade OUT old player
	tween.parallel().tween_property(old_player, "volume_db", -80, crossfade)
	# Fade IN new player
	tween.parallel().tween_property(new_player, "volume_db", 0, crossfade)

	# Cleanup old player when done
	tween.chain().tween_callback(old_player.stop)

	_current_player = new_player

## Stops the music with a fade out
func stop(fade_duration: float = DEFAULT_CROSSFADE) -> void:
	_ambient_key = ""
	_in_combat = false
	if _current_player and _current_player.playing:
		_fading_out = true
		var tween = _restart_tween()
		tween.tween_property(_current_player, "volume_db", -80, fade_duration)
		tween.tween_callback(_current_player.stop)
		tween.tween_callback(func() -> void: _fading_out = false)

# --- Ambient / combat layer -------------------------------------------------

## Sets the map's baseline track. Plays it immediately unless a fight is
## already underway, in which case it becomes what we fall back to when the
## fight ends.
##
## A map with no `music_track` — or one naming a track that isn't installed —
## falls back to DEFAULT_AMBIENT_TRACK rather than playing nothing. Silence
## used to be the accidental result of a typo; now it has to be asked for, by
## setting `music_track` to SILENCE_KEY.
func set_ambient_track(track_key: String) -> void:
	_ambient_key = _resolve_ambient_key(track_key)
	if _in_combat:
		return
	if _ambient_key.is_empty():
		stop()
	else:
		play(_ambient_key)

func _resolve_ambient_key(track_key: String) -> String:
	if track_key == SILENCE_KEY:
		return ""
	if not track_key.is_empty() and tracks.has(track_key):
		return track_key
	if not track_key.is_empty():
		# A map pointed at a track that isn't in MUSIC_DIR. Worth surfacing —
		# it's almost always a typo or a file that never got committed.
		push_warning("MusicManager: map track '%s' not found; falling back to '%s'."
			% [track_key, DEFAULT_AMBIENT_TRACK])
	if tracks.has(DEFAULT_AMBIENT_TRACK):
		return DEFAULT_AMBIENT_TRACK
	return ""

## Drives the combat layer. Safe to call every tick — it only acts on a
## change. Callers are responsible for debouncing what counts as "in combat";
## see Game._update_combat_music.
func set_combat(active: bool) -> void:
	if active == _in_combat:
		return
	_in_combat = active
	if active:
		var key := _pick_combat_track()
		if key.is_empty():
			return # No combat music installed — leave ambient running.
		play(key, COMBAT_CROSSFADE)
	elif _ambient_key.is_empty():
		stop()
	else:
		play(_ambient_key)

func is_in_combat() -> bool:
	return _in_combat

# Random combat track, skipping any that failed to load and avoiding an
# immediate repeat of what's already playing when there's a choice.
func _pick_combat_track() -> String:
	var playing_stream: AudioStream = null
	if _current_player != null:
		playing_stream = _current_player.stream
	var pool: Array[String] = []
	var fallback: Array[String] = []
	for key in COMBAT_TRACKS:
		if not tracks.has(key):
			continue
		fallback.append(key)
		if tracks[key] != playing_stream:
			pool.append(key)
	if pool.is_empty():
		pool = fallback
	if pool.is_empty():
		return ""
	return pool[randi() % pool.size()]

# --- Internal Helpers ---

# Only one fade may be in flight at a time; a second concurrent tween on the
# same volume_db properties produces audible stutter and can strand a player
# at -80.
func _restart_tween() -> Tween:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	# Crossfades must keep running while the tree is paused too, or a fade
	# started just before a pause freezes half-done and leaves both players
	# audible at partial volume. TWEEN_PAUSE_BOUND would already follow this
	# node's PROCESS_MODE_ALWAYS; stating it outright keeps the two from
	# drifting apart if the node's mode is ever reconsidered.
	_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	return _tween

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
