extends Node

# Configuration
const POOL_SIZE = 32
# Footsteps fire every FOOTSTEP_DISTANCE px for every walker on the map,
# off-screen NPCs included. On a shared pool a busy town recycled each voice
# about once a second, cutting death screams and explosions mid-tail, so
# footsteps get a small pool of their own and can only steal from each other.
const FOOTSTEP_POOL_SIZE = 12
const FOOTSTEP_PREFIX = "footstep"
const DEFAULT_BUS = "SFX"
const UI_BUS = "UI"
const AMBIENCE_BUS = "Ambience"
const SFX_DIRECTORY = "res://sfx/" # Change this to your folder path

# Default pitch variance (+/- 10%)
const DEFAULT_PITCH_VAR = Vector2(0.9, 1.1)

## Matches AudioStreamPlayer2D's default max_distance. A one-shot farther than
## this from the listener is inaudible anyway, so it isn't given a voice.
const MAX_AUDIBLE_DISTANCE = 2000.0

## How often looping emitters re-read the Silence-zone gain at their position.
## A zone can be cast on (or expire over) a fire that is already crackling.
const LOOP_ZONE_REFRESH = 0.25

## Loops of one sound left playing at once, nearest the listener first; the
## rest pause until they are among the nearest again. Every brazier and torch
## on a map crackles, and past a handful that is just louder mush (CellFireFX
## caps its own at the same 6 for the same reason).
const LOOP_BUDGET := {"fire_crackle_loop": 6}

## Button feedback. A button that plays its own sound sets this meta (to any
## value) so the global click doesn't stack on top of it. Hover still ticks.
const SILENT_BUTTON_META = "sfx_silent"
const BUTTON_CLICK_KEY = "ui-click"
const BUTTON_CLICK_DB = -6.0
const BUTTON_HOVER_KEY = "ui-navigation"
const BUTTON_HOVER_DB = -16.0
const BUTTON_HOVER_COOLDOWN = 0.05

const AMBIENCE_DB = -4.0
const AMBIENCE_FADE = 2.0

const AUDIO_SETTINGS_PATH = "user://audio_settings.cfg"

# Library will be populated automatically
var sound_library: Dictionary = {}
## "pain_male" -> ["pain_male_1", "pain_male_2", ...]: files named <key>_<n>
## form a variant group, and playing the bare key picks one at random.
var _variant_groups: Dictionary = {}
## Streams loaded by path from outside SFX_DIRECTORY (ability data may name
## any res:// path).
var _path_cache: Dictionary = {}

# Internal variables
var _pool: Array[AudioStreamPlayer2D] = []
var _next_idx: int = 0
var _footstep_pool: Array[AudioStreamPlayer2D] = []
var _next_footstep_idx: int = 0

# One-shot handles: every play() returns an int that stop() accepts. A voice
# remembers the handle it is currently playing, so stopping a stale handle
# after its voice was reused is a no-op rather than cutting someone else off.
const HANDLE_META = "sfx_handle"
var _handle_voice: Dictionary = {} # int -> AudioStreamPlayer2D
var _next_handle: int = 1

# handle -> {player, base_db, follow: WeakRef|null, owner: WeakRef|null}
var _loops: Dictionary = {}
var _loop_refresh_left: float = 0.0

var _throttle_until: Dictionary = {} # throttle id -> msec
## Expired throttle ids are swept once the table reaches this size.
const THROTTLE_PRUNE_SIZE = 512

## Bumped by every one-shot that starts (world or UI). A caller compares it
## around an action to learn whether the action made a sound of its own (the
## context menu clicks only when its option didn't).
var sounds_started: int = 0

var _ambience_a: AudioStreamPlayer
var _ambience_b: AudioStreamPlayer
var _ambience_current: AudioStreamPlayer = null
var _ambience_key: String = ""
var _ambience_tween: Tween = null

func _ready() -> void:
	# Loops (fires, ambience beds) and UI sounds must keep going through the
	# tactical pause, which the player spends much of a fight inside, and the
	# follow/zone refresh in _process has to keep running with them. One-shot
	# world voices opt back into PAUSABLE below so the existing freeze-frame
	# behaviour of in-flight hits is unchanged.
	process_mode = Node.PROCESS_MODE_ALWAYS

	# 1. Load sounds automatically
	_load_sounds_from_folder(SFX_DIRECTORY)
	_build_variant_groups()

	# 2. Initialize the pool
	for i in range(POOL_SIZE):
		_pool.append(_make_voice())
	for i in range(FOOTSTEP_POOL_SIZE):
		_footstep_pool.append(_make_voice())

	_ambience_a = _make_ambience_player()
	_ambience_b = _make_ambience_player()

	_load_audio_settings()

	# 3. Every button in the game clicks. Nodes added later arrive through
	# node_added; anything already in the tree (earlier autoloads) is walked
	# once, deferred so the whole root is populated.
	get_tree().node_added.connect(_on_node_added)
	_wire_existing_buttons.call_deferred(get_tree().root)

	print("SFXManager: Loaded %d sounds (%d variant groups)." % [sound_library.size(), _variant_groups.size()])

func _process(delta: float) -> void:
	if _loops.is_empty():
		return
	_loop_refresh_left -= delta
	var refresh_zone := _loop_refresh_left <= 0.0
	if refresh_zone:
		_loop_refresh_left = LOOP_ZONE_REFRESH
		_refresh_loop_culling()
	for handle in _loops.keys():
		var entry: Dictionary = _loops[handle]
		var player: AudioStreamPlayer2D = entry["player"]
		if not is_instance_valid(player):
			_loops.erase(handle)
			continue
		var owner_ref = entry["owner"]
		if owner_ref != null and owner_ref.get_ref() == null:
			stop_loop(handle, 0.0)
			continue
		var follow_ref = entry["follow"]
		if follow_ref != null:
			var follow = follow_ref.get_ref()
			if follow == null:
				stop_loop(handle, 0.0)
				continue
			player.global_position = (follow as Node2D).global_position
		if refresh_zone and not entry["fading"]:
			player.volume_db = _zoned_db(float(entry["base_db"]), player.global_position)
		# Re-applied every frame rather than once: the engine drops a pause
		# asked for before a new loop's playback starts (the next physics
		# frame), so a loop paused as it is restored would play anyway.
		var want_paused: bool = entry["paused"] or entry["culled"]
		if player.stream_paused != want_paused:
			player.stream_paused = want_paused

# --- Playback -----------------------------------------------------------------

## True when `sound_key` names a sound (or a variant group) in the library.
func has_sound(sound_key: String) -> bool:
	return _resolve_key(sound_key) != ""

## Plays a 2D sound using a filename key (e.g. "jump" for "jump.wav"), a
## variant group ("pain_male" for pain_male_1..N) or a res:// path. Returns a
## handle for stop(), or 0 when nothing was played (unknown key, inaudible,
## inside a Silence zone).
func play(sound_key: String, global_pos: Vector2, pitch_range: Vector2 = DEFAULT_PITCH_VAR, volume_db: float = 0.0, bus: String = DEFAULT_BUS) -> int:
	var stream := _stream_for(sound_key)
	if stream == null:
		push_warning("SFXManager: Sound '%s' not found." % sound_key)
		return 0

	# Sound-suppression zones damp what the player hears, not just what the AI
	# notices. This system and HearingManager are otherwise unaware of each
	# other — every call site pokes them independently — so without this a
	# silenced brawl would still clang, which reads as a bug rather than magic.
	var zone_gain: float = HearingManager.sound_gain_at(global_pos)
	if zone_gain <= 0.0:
		return 0
	if zone_gain < 1.0:
		volume_db += linear_to_db(zone_gain)

	if not _audible_from_listener(global_pos):
		return 0

	var player: AudioStreamPlayer2D
	if sound_key.begins_with(FOOTSTEP_PREFIX):
		player = _take_footstep_voice()
	else:
		player = _take_voice()
	player.stream = stream
	player.global_position = global_pos
	player.volume_db = volume_db
	player.bus = bus
	player.pitch_scale = randf_range(pitch_range.x, pitch_range.y)
	# A pausable voice only starts on its next physics frame, which never
	# comes during the tactical pause: a drop or an equip from the paused
	# inventory would stay silent and then fire with everything else on
	# unpause. A sound asked for while paused is the player's own feedback, so
	# it plays at once; reused unpaused, the voice freezes with the world again.
	player.process_mode = Node.PROCESS_MODE_ALWAYS if get_tree().paused else Node.PROCESS_MODE_PAUSABLE
	player.play()
	sounds_started += 1

	var handle := _next_handle
	_next_handle += 1
	var previous: int = int(player.get_meta(HANDLE_META, 0))
	if previous != 0:
		_handle_voice.erase(previous)
	player.set_meta(HANDLE_META, handle)
	_handle_voice[handle] = player
	return handle

## Stops a one-shot started by play(). A stale handle (its voice has since
## been reused for another sound) does nothing.
func stop(handle: int) -> void:
	if handle == 0 or not _handle_voice.has(handle):
		return
	var player: AudioStreamPlayer2D = _handle_voice[handle]
	_handle_voice.erase(handle)
	if is_instance_valid(player) and int(player.get_meta(HANDLE_META, 0)) == handle:
		player.stop()
		player.set_meta(HANDLE_META, 0)

## play(), but at most once per `cooldown` seconds for a given `throttle_id`.
## For sounds that can fire in bursts — fire spreading to a dozen cells in one
## tick, a Regenerating heal every second, quest stages chaining in one call.
func play_throttled(throttle_id: String, cooldown: float, sound_key: String, global_pos: Vector2, pitch_range: Vector2 = DEFAULT_PITCH_VAR, volume_db: float = 0.0, bus: String = DEFAULT_BUS) -> int:
	if not throttle_ok(throttle_id, cooldown):
		return 0
	return play(sound_key, global_pos, pitch_range, volume_db, bus)

## True (and arms the cooldown) when `throttle_id` hasn't fired within the
## last `cooldown` seconds. Real time, so it works while paused.
func throttle_ok(throttle_id: String, cooldown: float) -> bool:
	var now := Time.get_ticks_msec()
	if now < int(_throttle_until.get(throttle_id, 0)):
		return false
	# Ids are often per character instance, and NPCs get new instances on
	# every map load, so drop the expired ones before the table grows for the
	# whole session.
	if _throttle_until.size() >= THROTTLE_PRUNE_SIZE:
		for id in _throttle_until.keys():
			if int(_throttle_until[id]) <= now:
				_throttle_until.erase(id)
	_throttle_until[throttle_id] = now + int(cooldown * 1000.0)
	return true

## True while `throttle_id` is still cooling down. Doesn't arm anything.
func is_throttled(throttle_id: String) -> bool:
	return Time.get_ticks_msec() < int(_throttle_until.get(throttle_id, 0))

## Plays a UI sound
func play_ui(sound_key: String, pitch_range: Vector2 = DEFAULT_PITCH_VAR, volume_db: float = 0.0) -> void:
	var stream := _stream_for(sound_key)
	if stream == null:
		push_warning("SFXManager: Sound '%s' not found." % sound_key)
		return

	var player = AudioStreamPlayer.new()
	player.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(player)
	player.stream = stream
	player.volume_db = volume_db
	player.bus = UI_BUS
	player.pitch_scale = randf_range(pitch_range.x, pitch_range.y)
	player.finished.connect(player.queue_free)
	player.play()
	sounds_started += 1

## play_ui(), at most once per `cooldown` seconds for a given `throttle_id`.
func play_ui_throttled(throttle_id: String, cooldown: float, sound_key: String, pitch_range: Vector2 = DEFAULT_PITCH_VAR, volume_db: float = 0.0) -> void:
	if throttle_ok(throttle_id, cooldown):
		play_ui(sound_key, pitch_range, volume_db)

# --- Looping emitters ---------------------------------------------------------

## Starts a looping 2D sound and returns a handle for stop_loop() (0 if the key
## is unknown). The stream is duplicated before looping is switched on, so the
## same file can still be played as a one-shot elsewhere.
##   follow — the loop tracks this node's position and stops when it is freed.
##   lifetime_owner — the loop stops when this object is freed (position
##                    stays fixed).
## Silence zones are re-read every LOOP_ZONE_REFRESH seconds. Loops keep
## playing through the tactical pause; out of earshot (or past LOOP_BUDGET)
## they pause until heard again.
func start_loop(sound_key: String, global_pos: Vector2, volume_db: float = 0.0, bus: String = DEFAULT_BUS, follow: Node2D = null, lifetime_owner: Object = null, max_distance: float = MAX_AUDIBLE_DISTANCE) -> int:
	var stream := _looped_copy(_stream_for(sound_key))
	if stream == null:
		push_warning("SFXManager: Loop '%s' not found." % sound_key)
		return 0
	var player := AudioStreamPlayer2D.new()
	player.process_mode = Node.PROCESS_MODE_ALWAYS
	player.stream = stream
	player.bus = bus
	player.max_distance = max_distance
	add_child(player)
	player.global_position = follow.global_position if follow != null else global_pos
	player.volume_db = _zoned_db(volume_db, player.global_position)
	# Start at a random point so several fires or swarms started together
	# don't phase into one loud, obviously-repeating loop.
	var length: float = stream.get_length()
	player.play(randf() * length if length > 0.0 else 0.0)

	var handle := _next_handle
	_next_handle += 1
	_loops[handle] = {
		"player": player,
		"base_db": volume_db,
		"follow": weakref(follow) if follow != null else null,
		"owner": weakref(lifetime_owner) if lifetime_owner != null else null,
		"fading": false,
		"key": sound_key.get_file().get_basename() if sound_key.begins_with("res://") else sound_key,
		"paused": false, # set_loop_paused
		"culled": false, # _refresh_loop_culling
	}
	# Cull on the next frame, not up to LOOP_ZONE_REFRESH later: a map load
	# starts every brazier's crackle at once.
	_loop_refresh_left = 0.0
	return handle

## Stops a loop started by start_loop(), fading out over `fade` seconds.
func stop_loop(handle: int, fade: float = 0.15) -> void:
	if not _loops.has(handle):
		return
	var entry: Dictionary = _loops[handle]
	_loops.erase(handle)
	var player: AudioStreamPlayer2D = entry["player"]
	if not is_instance_valid(player):
		return
	if fade <= 0.0 or not player.is_inside_tree():
		player.queue_free()
		return
	var tween := create_tween()
	tween.tween_property(player, "volume_db", -60.0, fade)
	tween.tween_callback(player.queue_free)

## Pauses or resumes a loop in place (a suppressed condition, say).
func set_loop_paused(handle: int, paused: bool) -> void:
	if not _loops.has(handle):
		return
	var entry: Dictionary = _loops[handle]
	entry["paused"] = paused
	var player: AudioStreamPlayer2D = entry["player"]
	if is_instance_valid(player):
		player.stream_paused = paused or bool(entry["culled"])

## Moves a fixed-position loop (one started without `follow`).
func set_loop_position(handle: int, global_pos: Vector2) -> void:
	if not _loops.has(handle):
		return
	var player: AudioStreamPlayer2D = _loops[handle]["player"]
	if is_instance_valid(player):
		player.global_position = global_pos

## Changes a loop's base volume; the Silence-zone gain is applied on top.
func set_loop_volume(handle: int, volume_db: float) -> void:
	if not _loops.has(handle):
		return
	var entry: Dictionary = _loops[handle]
	entry["base_db"] = volume_db
	var player: AudioStreamPlayer2D = entry["player"]
	if is_instance_valid(player):
		player.volume_db = _zoned_db(volume_db, player.global_position)

func is_loop_active(handle: int) -> bool:
	return _loops.has(handle)

## Stops every looping emitter. Called when a map is torn down so a fire or
## well on the old map can't keep playing at stale coordinates on the new one.
func stop_all_loops() -> void:
	for handle in _loops.keys():
		stop_loop(handle, 0.0)

# Marks the loops nobody can hear as culled (paused by _process): farther from
# the listener than their max_distance (the AudioServer still decodes a
# playback attenuated to nothing, every one of a map's braziers), or past
# their sound's LOOP_BUDGET nearest. They resume when that changes.
func _refresh_loop_culling() -> void:
	var listener: Variant = _listener_position()
	var ranked_by_key: Dictionary = {} # budgeted key -> [[distance, entry], ...]
	for handle in _loops:
		var entry: Dictionary = _loops[handle]
		var player: AudioStreamPlayer2D = entry["player"]
		if not is_instance_valid(player):
			continue
		if listener == null:
			entry["culled"] = false
			continue
		var dist: float = (listener as Vector2).distance_to(player.global_position)
		entry["culled"] = dist > player.max_distance
		var key: String = entry["key"]
		if not entry["culled"] and not entry["paused"] and LOOP_BUDGET.has(key):
			if not ranked_by_key.has(key):
				ranked_by_key[key] = []
			ranked_by_key[key].append([dist, entry])
	for key in ranked_by_key:
		var ranked: Array = ranked_by_key[key]
		var budget: int = int(LOOP_BUDGET[key])
		if ranked.size() <= budget:
			continue
		ranked.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
		for i in range(budget, ranked.size()):
			var culled_entry: Dictionary = ranked[i][1]
			culled_entry["culled"] = true

# --- Ambience bed ----------------------------------------------------------------

## Per-map ambience beds. A separate file rather than a Maps.json key: the
## Terrain Generation exporter rebuilds the tg_* rows from scratch, and its
## splice refuses any key the export doesn't produce.
const MAP_AMBIENCE_PATH = "res://data/map_ambience.json"
var _map_ambience: Dictionary = {}
var _map_ambience_loaded: bool = false

## The ambience bed `map_id` plays ("" for none), from MAP_AMBIENCE_PATH.
func ambience_for_map(map_id: String) -> String:
	if not _map_ambience_loaded:
		_map_ambience_loaded = true
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(MAP_AMBIENCE_PATH))
		if typeof(parsed) == TYPE_DICTIONARY:
			_map_ambience = parsed.get("maps", {})
		else:
			push_error("SFXManager: failed to parse %s" % MAP_AMBIENCE_PATH)
	return str(_map_ambience.get(map_id, ""))

## Crossfades the non-positional ambience bed to `sound_key` ("" for silence).
## One bed at a time; maps choose theirs in MAP_AMBIENCE_PATH.
func set_ambience(sound_key: String, fade: float = AMBIENCE_FADE) -> void:
	if sound_key == _ambience_key:
		return
	_ambience_key = sound_key
	var stream: AudioStream = null
	if sound_key != "":
		stream = _looped_copy(_stream_for(sound_key))
		if stream == null:
			push_warning("SFXManager: Ambience '%s' not found." % sound_key)
	var old_player := _ambience_current
	var new_player: AudioStreamPlayer = null
	if stream != null:
		new_player = _ambience_b if old_player == _ambience_a else _ambience_a
		new_player.stream = stream
		new_player.volume_db = -60.0
		var length: float = stream.get_length()
		new_player.play(randf() * length if length > 0.0 else 0.0)
	_ambience_current = new_player

	if _ambience_tween != null and _ambience_tween.is_valid():
		_ambience_tween.kill()
	_ambience_tween = null
	# Every other bed still sounding fades out, not just the last current one:
	# killing the previous tween dropped its fade, so a bed from two quick
	# warps ago would loop on, half faded, with nothing tracking it.
	var fading: Array[AudioStreamPlayer] = []
	for player: AudioStreamPlayer in [_ambience_a, _ambience_b]:
		if player != new_player and player.playing:
			fading.append(player)
	# Nothing to fade (no bed to no bed): a tween with no tweeners is an error.
	if new_player == null and fading.is_empty():
		return
	_ambience_tween = create_tween().set_parallel(true)
	if new_player != null:
		_ambience_tween.tween_property(new_player, "volume_db", AMBIENCE_DB, fade)
	for player in fading:
		_ambience_tween.tween_property(player, "volume_db", -60.0, fade)
	if not fading.is_empty():
		_ambience_tween.chain().tween_callback(_stop_ambience_players.bind(fading))

func _stop_ambience_players(players: Array[AudioStreamPlayer]) -> void:
	for player in players:
		if player != _ambience_current:
			player.stop()

## The ambience bed key currently playing ("" for none).
func current_ambience() -> String:
	return _ambience_key

# --- Bus volumes -------------------------------------------------------------------

## Linear 0..1 volume for a bus ("Master", "Music", "SFX", "UI", "Ambience"),
## saved to AUDIO_SETTINGS_PATH.
func set_bus_volume(bus_name: String, linear: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	linear = clampf(linear, 0.0, 1.0)
	AudioServer.set_bus_volume_db(idx, linear_to_db(linear))
	AudioServer.set_bus_mute(idx, linear <= 0.0)
	var cfg := ConfigFile.new()
	cfg.load(AUDIO_SETTINGS_PATH)
	cfg.set_value("volume", bus_name, linear)
	cfg.save(AUDIO_SETTINGS_PATH)

func get_bus_volume(bus_name: String) -> float:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return 1.0
	if AudioServer.is_bus_mute(idx):
		return 0.0
	return db_to_linear(AudioServer.get_bus_volume_db(idx))

func _load_audio_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(AUDIO_SETTINGS_PATH) != OK:
		return
	if not cfg.has_section("volume"):
		return
	for bus_name in cfg.get_section_keys("volume"):
		var idx := AudioServer.get_bus_index(bus_name)
		if idx < 0:
			continue
		var linear: float = clampf(float(cfg.get_value("volume", bus_name, 1.0)), 0.0, 1.0)
		AudioServer.set_bus_volume_db(idx, linear_to_db(linear))
		AudioServer.set_bus_mute(idx, linear <= 0.0)

# --- Buttons -------------------------------------------------------------------------

func _on_node_added(node: Node) -> void:
	if node is BaseButton:
		_wire_button(node as BaseButton)

func _wire_existing_buttons(node: Node) -> void:
	if node is BaseButton:
		_wire_button(node as BaseButton)
	for child in node.get_children():
		_wire_existing_buttons(child)

const WIRED_BUTTON_META = "_sfx_wired"

func _wire_button(button: BaseButton) -> void:
	# node_added fires again whenever a button is re-parented, so mark it once.
	if button.has_meta(WIRED_BUTTON_META):
		return
	button.set_meta(WIRED_BUTTON_META, true)
	button.pressed.connect(_on_button_pressed.bind(button))
	button.mouse_entered.connect(_on_button_hovered.bind(button))

func _on_button_pressed(button: BaseButton) -> void:
	if not is_instance_valid(button) or button.has_meta(SILENT_BUTTON_META):
		return
	play_ui(BUTTON_CLICK_KEY, Vector2(0.95, 1.05), BUTTON_CLICK_DB)

## sfx_silent only stops the click (the button plays its own on press); no
## button has a hover sound of its own, so every one still ticks on hover.
func _on_button_hovered(button: BaseButton) -> void:
	if not is_instance_valid(button) or button.disabled:
		return
	play_ui_throttled("button_hover", BUTTON_HOVER_COOLDOWN, BUTTON_HOVER_KEY, Vector2(0.97, 1.03), BUTTON_HOVER_DB)

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
				if not sound_library.has(key):
					sound_library[key] = load(path.path_join(clean_name))

		file_name = dir.get_next()

func _build_variant_groups() -> void:
	var numbered := RegEx.new()
	numbered.compile("^(.+)_(\\d+)$")
	for key in sound_library.keys():
		var m := numbered.search(key)
		if m == null:
			continue
		var base := m.get_string(1)
		# A real file named after the base wins; the group is only a fallback.
		if sound_library.has(base):
			continue
		if not _variant_groups.has(base):
			_variant_groups[base] = []
		_variant_groups[base].append(key)

# --- Internal Helpers ---

# Library key for `sound_key`: the key itself, a random member of its variant
# group, or the basename of a res://sfx/ path. "" when none of those exist.
func _resolve_key(sound_key: String) -> String:
	if sound_library.has(sound_key):
		return sound_key
	if _variant_groups.has(sound_key):
		var group: Array = _variant_groups[sound_key]
		return String(group[randi() % group.size()])
	if sound_key.begins_with("res://") and sound_key.get_base_dir() + "/" == SFX_DIRECTORY:
		# Data written before sounds were keyed (ability visuals, condition
		# custom_sfx) names res://sfx/ paths; resolve them like a bare key.
		return _resolve_key(sound_key.get_file().get_basename())
	return ""

func _stream_for(sound_key: String) -> AudioStream:
	var key := _resolve_key(sound_key)
	if key != "":
		return sound_library[key]
	if sound_key.begins_with("res://"):
		if not _path_cache.has(sound_key):
			_path_cache[sound_key] = load(sound_key) if ResourceLoader.exists(sound_key) else null
		return _path_cache[sound_key]
	return null

func _looped_copy(stream: AudioStream) -> AudioStream:
	if stream == null:
		return null
	var copy := stream.duplicate() as AudioStream
	if copy is AudioStreamMP3:
		(copy as AudioStreamMP3).loop = true
	elif copy is AudioStreamOggVorbis:
		(copy as AudioStreamOggVorbis).loop = true
	elif copy is AudioStreamWAV:
		(copy as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
	return copy

func _zoned_db(base_db: float, global_pos: Vector2) -> float:
	var zone_gain: float = HearingManager.sound_gain_at(global_pos)
	if zone_gain <= 0.0:
		return -80.0
	if zone_gain < 1.0:
		return base_db + linear_to_db(zone_gain)
	return base_db

func _audible_from_listener(global_pos: Vector2) -> bool:
	var listener: Variant = _listener_position()
	return listener == null or (listener as Vector2).distance_to(global_pos) <= MAX_AUDIBLE_DISTANCE

# Where 2D sound is heard from (the camera's view centre), or null when there
# is no camera to judge by.
func _listener_position() -> Variant:
	var viewport := get_viewport()
	if viewport == null:
		return null
	var cam := viewport.get_camera_2d()
	if cam == null:
		return null
	return cam.get_screen_center_position()

func _make_voice() -> AudioStreamPlayer2D:
	var player = AudioStreamPlayer2D.new()
	player.bus = DEFAULT_BUS
	player.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(player)
	return player

func _make_ambience_player() -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.bus = AMBIENCE_BUS
	player.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(player)
	return player

# An idle voice if there is one; otherwise steal whichever voice has the least
# left to play, so a death scream outlives the clink that started after it.
func _take_voice() -> AudioStreamPlayer2D:
	for i in range(POOL_SIZE):
		var idx := (_next_idx + i) % POOL_SIZE
		var candidate := _pool[idx]
		# A voice frozen by the tactical pause reports playing == false, but
		# it still holds a sound that resumes on unpause: not idle.
		if not candidate.playing and not candidate.stream_paused:
			_next_idx = (idx + 1) % POOL_SIZE
			return candidate
	var victim := _pool[0]
	var least_left := INF
	for candidate in _pool:
		var left := _time_left(candidate)
		if left < least_left:
			least_left = left
			victim = candidate
	victim.stop()
	return victim

func _take_footstep_voice() -> AudioStreamPlayer2D:
	var player := _footstep_pool[_next_footstep_idx]
	_next_footstep_idx = (_next_footstep_idx + 1) % FOOTSTEP_POOL_SIZE
	if player.playing:
		player.stop()
	return player

func _time_left(player: AudioStreamPlayer2D) -> float:
	if player.stream == null:
		return 0.0
	var length: float = player.stream.get_length()
	return maxf(0.0, length - player.get_playback_position()) / maxf(player.pitch_scale, 0.01)
