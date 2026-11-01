# res://tests/sfx_manager_test.gd
# Headless assertion harness for SfxManager: library, variant groups, voice
# pools, handles, throttles, loops, ambience, buses, button clicks, pause.
# Run:  godot --headless --path . res://tests/sfx_manager_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (pre-existing parse errors
# print noise; runs can flake exit 255 — rerun once).
extends Node2D

var failures := 0

# Keys the sound pass wires in code; each must resolve (file or variant group).
const WIRED_KEYS := [
	"ui_pause", "ui_unpause", "dialogue_open", "dialogue_close", "paper_rustle",
	"quest_start", "quest_advance", "quest_complete", "quest_fail", "dice_roll",
	"check_success", "check_fail", "favor_down", "stamp", "crime_sting",
	"alarm_bell", "party_join", "party_leave", "ability_learned", "vow_broken",
	"stress_affliction", "stress_virtue", "church_bell", "stealth_on",
	"stealth_off", "alert_spotted", "alert_search", "swing_heavy",
	"swing_thrust", "swing_light", "throw_whoosh", "dry_fire_click",
	"pain_male", "pain_female", "pain_beast", "beast_death", "undead_death",
	"monster_death", "body_fall", "bleed", "bleed_drip", "gasp", "fizzle",
	"gore", "sheathe", "armor_rustle", "item_drop_soft", "glass_break",
	"land_thud", "structure_break_wood", "structure_break_stone", "crate_break",
	"door_open", "door_close", "door_locked", "door_unlock", "fire_ignite",
	"fire_crackle_loop", "fire_douse", "eat", "drink", "rat_squeak",
	"swarm_skitter_loop", "oil_gush_loop", "match_strike", "electric_jolt",
	"ink_splat", "smoke_hiss", "march_drum", "hush", "amb_town_loop",
	"amb_tavern_loop", "amb_cave_loop", "amb_cemetery_loop",
	"amb_countryside_loop", "amb_spring_loop",
]

class MuteZone:
	extends RefCounted
	func sound_gain_for_segment(_from: Vector2, _to: Vector2) -> float:
		return 0.0

func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])

func _ready() -> void:
	await get_tree().process_frame
	_case_library()
	await _case_play_and_stop()
	await _case_voice_preference()
	await _case_footstep_pool()
	_case_throttle()
	_case_silence_zone()
	await _case_loops()
	await _case_ambience()
	_case_buses()
	await _case_buttons()
	await _case_pause()
	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _case_library() -> void:
	_check("library_loaded", SfxManager.sound_library.size() >= 184,
		"only %d sounds" % SfxManager.sound_library.size())
	var missing: Array = []
	for key in WIRED_KEYS:
		if not SfxManager.has_sound(key):
			missing.append(key)
	_check("wired_keys_resolve", missing.is_empty(), str(missing))
	var group: Array = SfxManager._variant_groups.get("pain_male", [])
	_check("variant_group_pain_male", group.size() == 4, str(group))
	_check("bare_key_beats_group", not SfxManager._variant_groups.has("slash"))
	_check("res_path_resolves", SfxManager.has_sound("res://sfx/slash.mp3"))
	_check("res_path_variant_resolves", SfxManager.has_sound("res://sfx/rat_squeak.mp3"))
	_check("unknown_key", not SfxManager.has_sound("no_such_sound"))

func _case_play_and_stop() -> void:
	var h: int = SfxManager.play("church_bell", Vector2.ZERO)
	_check("play_returns_handle", h != 0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var voice: AudioStreamPlayer2D = SfxManager._handle_voice.get(h)
	_check("play_is_playing", voice != null and voice.playing)
	SfxManager.stop(h)
	_check("stop_stops", voice != null and not voice.playing)
	SfxManager.stop(h) # stale handle: no-op, no error
	var v: int = SfxManager.play("pain_male", Vector2.ZERO)
	var vv: AudioStreamPlayer2D = SfxManager._handle_voice.get(v)
	var path: String = vv.stream.resource_path if vv and vv.stream else ""
	_check("variant_plays_member", path.contains("pain_male_"), path)
	SfxManager.stop(v)

# An idle voice is always taken before a busy one is stolen.
func _case_voice_preference() -> void:
	var long_h: int = SfxManager.play("church_bell", Vector2.ZERO)
	await get_tree().physics_frame
	for i in range(SfxManager.POOL_SIZE - 2):
		SfxManager.play("ui-click", Vector2.ZERO)
	await get_tree().physics_frame
	var voice: AudioStreamPlayer2D = SfxManager._handle_voice.get(long_h)
	_check("idle_voice_preferred", voice != null and voice.playing
		and int(voice.get_meta(SfxManager.HANDLE_META, 0)) == long_h)
	SfxManager.stop(long_h)

# Footsteps can't steal from the main pool.
func _case_footstep_pool() -> void:
	var long_h: int = SfxManager.play("church_bell", Vector2.ZERO)
	for i in range(60):
		SfxManager.play("footstep_stone_boots", Vector2.ZERO)
	await get_tree().physics_frame
	var voice: AudioStreamPlayer2D = SfxManager._handle_voice.get(long_h)
	_check("footsteps_dont_steal", voice != null and voice.playing)
	SfxManager.stop(long_h)

func _case_throttle() -> void:
	var a: int = SfxManager.play_throttled("test_throttle", 5.0, "ui-click", Vector2.ZERO)
	var b: int = SfxManager.play_throttled("test_throttle", 5.0, "ui-click", Vector2.ZERO)
	_check("throttle_first_plays", a != 0)
	_check("throttle_second_blocked", b == 0)
	_check("is_throttled", SfxManager.is_throttled("test_throttle"))

func _case_silence_zone() -> void:
	var zone := MuteZone.new()
	HearingManager.register_sound_zone(zone)
	var h: int = SfxManager.play("ui-click", Vector2.ZERO)
	HearingManager.unregister_sound_zone(zone)
	_check("silence_zone_mutes", h == 0)

func _case_loops() -> void:
	var original: AudioStream = SfxManager.sound_library["fire_crackle_loop"]
	var h: int = SfxManager.start_loop("fire_crackle_loop", Vector2.ZERO, -6.0, "Ambience")
	_check("loop_handle", h != 0 and SfxManager.is_loop_active(h))
	var player: AudioStreamPlayer2D = SfxManager._loops[h]["player"]
	var looped: bool = bool(player.stream.get("loop"))
	_check("loop_stream_loops", looped)
	_check("library_stream_untouched", not bool(original.get("loop")))
	_check("loop_bus", player.bus == "Ambience")
	SfxManager.stop_loop(h, 0.0)
	_check("loop_stopped", not SfxManager.is_loop_active(h))

	var holder := Node2D.new()
	add_child(holder)
	var h2: int = SfxManager.start_loop("swarm_skitter_loop", Vector2.ZERO, 0.0, "SFX", holder)
	holder.position = Vector2(50, 25)
	await get_tree().process_frame
	await get_tree().process_frame
	var p2: AudioStreamPlayer2D = SfxManager._loops[h2]["player"] if SfxManager.is_loop_active(h2) else null
	_check("loop_follows", p2 != null and p2.global_position.is_equal_approx(Vector2(50, 25)))
	holder.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	_check("loop_stops_with_follow", not SfxManager.is_loop_active(h2))

	var h3: int = SfxManager.start_loop("oil_gush_loop", Vector2.ZERO)
	SfxManager.set_loop_paused(h3, true)
	# The engine starts a new loop's playback on its next physics frame and
	# drops a pause asked for before that; SfxManager re-applies it in the
	# _process after. Wait for a physics frame, then a full process frame.
	await get_tree().physics_frame
	await get_tree().process_frame
	await get_tree().process_frame
	var p3: AudioStreamPlayer2D = SfxManager._loops[h3]["player"]
	_check("loop_pause_sticks", p3.stream_paused)
	SfxManager.stop_all_loops()
	_check("stop_all_loops", not SfxManager.is_loop_active(h3))

func _case_ambience() -> void:
	_check("map_ambience_lookup", SfxManager.ambience_for_map("tg_hillside_lower") == "amb_town_loop")
	_check("map_ambience_unlisted", SfxManager.ambience_for_map("no_such_map") == "")
	var missing: Array = []
	for map_id in SfxManager._map_ambience:
		if not MapDatabase.get_all_map_ids().has(map_id):
			missing.append(map_id)
	_check("map_ambience_ids_exist", missing.is_empty(), str(missing))
	SfxManager.set_ambience("amb_town_loop", 0.05)
	_check("ambience_set", SfxManager.current_ambience() == "amb_town_loop")
	SfxManager.set_ambience("amb_cave_loop", 0.05)
	await get_tree().create_timer(0.2).timeout
	var playing := 0
	for p in [SfxManager._ambience_a, SfxManager._ambience_b]:
		if (p as AudioStreamPlayer).playing:
			playing += 1
	_check("ambience_one_bed_after_fade", playing == 1, "%d beds playing" % playing)
	SfxManager.set_ambience("", 0.05)
	await get_tree().create_timer(0.2).timeout
	_check("ambience_cleared", SfxManager.current_ambience() == "")

func _case_buses() -> void:
	for bus in ["Music", "SFX", "UI", "Ambience"]:
		_check("bus_%s" % bus, AudioServer.get_bus_index(bus) >= 0)

func _case_buttons() -> void:
	var b := Button.new()
	add_child(b)
	await get_tree().process_frame
	var before: int = SfxManager.sounds_started
	b.pressed.emit()
	_check("button_clicks", SfxManager.sounds_started == before + 1)
	var quiet := Button.new()
	quiet.set_meta(SfxManager.SILENT_BUTTON_META, true)
	add_child(quiet)
	await get_tree().process_frame
	before = SfxManager.sounds_started
	quiet.pressed.emit()
	_check("silent_button_quiet", SfxManager.sounds_started == before)
	# Re-parenting fires node_added again; it must not double-wire.
	remove_child(b)
	add_child(b)
	await get_tree().process_frame
	before = SfxManager.sounds_started
	b.pressed.emit()
	_check("reparented_button_clicks_once", SfxManager.sounds_started == before + 1)
	b.queue_free()
	quiet.queue_free()

# A sound asked for during the tactical pause plays then, not on unpause.
func _case_pause() -> void:
	get_tree().paused = true
	var h: int = SfxManager.play("church_bell", Vector2.ZERO)
	await get_tree().create_timer(0.3, true).timeout
	var voice: AudioStreamPlayer2D = SfxManager._handle_voice.get(h)
	var pos: float = voice.get_playback_position() if voice else 0.0
	_check("plays_while_paused", voice != null and voice.playing and pos > 0.05, "pos=%f" % pos)
	get_tree().paused = false
	SfxManager.stop(h)
