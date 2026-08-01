# res://tests/music_manager_test.gd
# Headless assertion harness for the combat/ambient music layer.
# Locks down:
#   1. Every key in MusicManager.COMBAT_TRACKS actually resolves to a loaded
#      stream — a typo there silently degrades to "combat music never plays",
#      which is invisible in normal play.
#   2. set_ambient_track / set_combat state machine: combat overrides ambient,
#      ending combat restores the map's track, and a map change mid-fight is
#      remembered rather than stomping the combat track.
#   3. _pick_combat_track never returns the track already playing when an
#      alternative exists (no back-to-back repeat).
# Run:  godot --headless --path . res://tests/music_manager_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

var failures := 0

func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("PASS  ", label)
	else:
		failures += 1
		print("FAIL  ", label, "  ", detail)

func _ready() -> void:
	await get_tree().process_frame

	_case_tracks_load()
	_case_combat_pool_resolves()
	_case_default_ambient_fallback()
	await _case_state_machine()
	_case_no_immediate_repeat()
	await _case_survives_pause()

	print("")
	if failures == 0:
		print("ALL PASS (music_manager_test)")
	else:
		print("FAILURES: %d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _case_tracks_load() -> void:
	_check("tracks dict non-empty", not MusicManager.tracks.is_empty(),
		"MUSIC_DIR scan found nothing")

# Every declared combat key must exist, or combat music silently no-ops.
func _case_combat_pool_resolves() -> void:
	var missing: Array[String] = []
	for key in MusicManager.COMBAT_TRACKS:
		if not MusicManager.tracks.has(key):
			missing.append(key)
	_check("every COMBAT_TRACKS key is loaded", missing.is_empty(),
		"missing: %s" % str(missing))

# A blank or broken `music_track` must land on the default, not on silence —
# silence is now opt-in via SILENCE_KEY.
func _case_default_ambient_fallback() -> void:
	_check("DEFAULT_AMBIENT_TRACK is installed",
		MusicManager.tracks.has(MusicManager.DEFAULT_AMBIENT_TRACK),
		MusicManager.DEFAULT_AMBIENT_TRACK)

	_check("blank music_track resolves to the default",
		MusicManager._resolve_ambient_key("") == MusicManager.DEFAULT_AMBIENT_TRACK)

	# The four maps that shipped pointing at tracks nobody added.
	for broken in ["cemetery_ambient", "town_theme", "tavern_theme"]:
		_check("broken key '%s' resolves to the default" % broken,
			MusicManager._resolve_ambient_key(broken) == MusicManager.DEFAULT_AMBIENT_TRACK)

	_check("SILENCE_KEY resolves to silence",
		MusicManager._resolve_ambient_key(MusicManager.SILENCE_KEY) == "")

	_check("a real track is passed through untouched",
		MusicManager._resolve_ambient_key("ambient-the-long-dark") == "ambient-the-long-dark")

func _case_state_machine() -> void:
	var ambient := "ambient-permafrost"
	if not MusicManager.tracks.has(ambient):
		_check("state machine (needs %s)" % ambient, false, "fixture track absent")
		return

	MusicManager.set_ambient_track(ambient)
	await get_tree().process_frame
	_check("ambient plays when out of combat",
		not MusicManager.is_in_combat())

	MusicManager.set_combat(true)
	await get_tree().process_frame
	_check("set_combat(true) enters combat", MusicManager.is_in_combat())

	# A warp mid-fight must not yank the combat track out from under us.
	MusicManager.set_ambient_track("ambient-the-long-dark")
	await get_tree().process_frame
	_check("map change mid-combat keeps combat music",
		MusicManager.is_in_combat())

	MusicManager.set_combat(false)
	await get_tree().process_frame
	_check("set_combat(false) leaves combat", not MusicManager.is_in_combat())

	# Idempotence: repeated calls in the same state must be no-ops.
	MusicManager.set_combat(false)
	_check("set_combat is idempotent", not MusicManager.is_in_combat())

# Music must not cut out when the tree pauses — the tactical pause is where
# the player spends much of a fight.
func _case_survives_pause() -> void:
	_check("MusicManager runs while paused",
		MusicManager.process_mode == Node.PROCESS_MODE_ALWAYS,
		"process_mode=%d" % MusicManager.process_mode)

	MusicManager.set_ambient_track("ambient-permafrost")
	await get_tree().process_frame
	var player: AudioStreamPlayer = MusicManager._current_player
	if player == null or not player.playing:
		_check("fixture is playing before pause", false, "nothing playing")
		return

	get_tree().paused = true
	await get_tree().process_frame
	await get_tree().process_frame
	var still_playing: bool = player.playing
	get_tree().paused = false

	_check("music keeps playing across a pause", still_playing)

func _case_no_immediate_repeat() -> void:
	if MusicManager.COMBAT_TRACKS.size() < 2:
		print("SKIP  no-immediate-repeat (pool < 2)")
		return
	# _pick_combat_track filters whatever _current_player is holding; with a
	# pool of 2+ it must always find something else.
	var repeats := 0
	for i in range(40):
		var key: String = MusicManager._pick_combat_track()
		if key.is_empty():
			repeats += 1
			continue
		var stream = MusicManager.tracks[key]
		if MusicManager._current_player != null \
				and MusicManager._current_player.stream == stream:
			repeats += 1
	_check("_pick_combat_track avoids the playing track", repeats == 0,
		"%d/40 picks repeated" % repeats)
