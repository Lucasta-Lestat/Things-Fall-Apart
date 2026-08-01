extends Node2D
# Persisted-NPC race regression probe: "from_faction" templates re-roll their
# race every spawn, so a persisted NPC used to come back as a NEW race and then
# have the OLD race's identity/dims/colors stamped over the new rig by
# _deserialize_character. The fix peeks the snapshot pre-spawn and forces the
# saved race/gender through build_character (Game._peek_npc_snapshot +
# _spawn_npcs / _spawn_player_and_party override injection).
# This battery drives the real save/peek/serialize/deserialize methods on a
# bare Game.gd instance (never added to the tree, so _ready/UI never run).
# Headless-safe.  Run:  godot --headless --path . res://tests/npc_race_persistence_check.tscn
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const GAME_SCRIPT := preload("res://Game.gd")

var fails := 0
var checks := 0


func _check(name: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if not ok:
		fails += 1
	print("%s %s %s" % ["PASS" if ok else "FAIL", name, detail])


func _visual_mode(c) -> String:
	if c.character_rig != null and is_instance_valid(c.character_rig):
		return "rig"
	if c.skeletal_rig != null:
		return "skeletal"
	if c.body_part_sprites != null:
		return "sprites"
	return "PROCEDURAL"


func _spawn(template_id: String, pos: Vector2, overrides: Dictionary = {}) -> ProceduralCharacter:
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	c.position = pos
	add_child(c)                       # _ready first, like Game._spawn_character
	TopDownCharacterDatabase.build_character(c, template_id, overrides)
	return c


## The override injection Game._spawn_npcs performs when a snapshot exists —
## kept in one place so every round-trip below respawns exactly the way the
## game does.
func _respawn_overrides(snap: Dictionary) -> Dictionary:
	var ov: Dictionary = {}
	if not str(snap.get("race_id", "")).is_empty():
		ov["race"] = str(snap["race_id"])
		if not str(snap.get("gender", "")).is_empty():
			ov["gender"] = str(snap["gender"])
	return ov


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	await get_tree().process_frame

	# --- 1. snapshot must capture race identity (race_id + gender) ---
	var game = GAME_SCRIPT.new()
	var c1 := _spawn("bandit", Vector2(200, 200))
	await get_tree().process_frame
	var snap1: Dictionary = game._serialize_character(c1)
	_check("snapshot.race_id", str(snap1.get("race_id", "")) == c1.race_id and not c1.race_id.is_empty(),
		"snap=%s live=%s" % [snap1.get("race_id"), c1.race_id])
	_check("snapshot.gender", str(snap1.get("gender", "")) == c1.gender,
		"snap=%s live=%s" % [snap1.get("gender"), c1.gender])

	# --- 2. real save path -> pre-spawn peek (service uid form) ---
	c1.titles = ["Bartender"]          # makes _should_persist_npc true
	c1.set_meta("template_id", "bandit")  # in-game this is stamped by _maybe_restore_npc_state
	game.characters_in_scene.append(c1)
	game._save_service_npc_states()
	var peeked: Dictionary = game._peek_npc_snapshot("bandit", "")
	_check("peek.service-uid", str(peeked.get("race_id", "")) == c1.race_id,
		"peeked=%s live=%s" % [peeked.get("race_id"), c1.race_id])

	# --- 2b. peek: ordinal uid form (dead non-service NPC) ---
	var game2 = GAME_SCRIPT.new()
	game2.npc_state_per_region[game2._npc_bucket_key()] = {"bandit#0": snap1}
	var peeked_ord: Dictionary = game2._peek_npc_snapshot("bandit", "")
	_check("peek.ordinal-uid", str(peeked_ord.get("race_id", "")) == c1.race_id,
		"peeked=%s" % [peeked_ord.get("race_id")])
	game2.free()

	# --- 3. THE regression: respawn+restore must keep the snapshot's race and
	# render its rig. 8 rounds so the faction table rolls several races. ---
	for i in 8:
		var ga = GAME_SCRIPT.new()
		var a := _spawn("bandit", Vector2(400 + i * 90, 200))
		await get_tree().process_frame
		var snap: Dictionary = ga._serialize_character(a)

		# respawn the way the fixed _spawn_npcs does: snapshot race wins the roll
		var b := _spawn("bandit", Vector2(400 + i * 90, 400), _respawn_overrides(snap))
		var pre_restore_ok := b.race_id == a.race_id
		ga._deserialize_character(b, snap)
		await get_tree().process_frame

		var tag := "roundtrip[%d](%s)" % [i, a.race_id]
		_check(tag + ".race-rebuilt-before-restore", pre_restore_ok, b.race_id)
		_check(tag + ".race-matches-snapshot", b.race_id == str(snap["race_id"]), b.race_id)
		_check(tag + ".gender-matches", b.gender == str(snap["gender"]), b.gender)
		_check(tag + ".same-rig-path", b.rig_scene_path == a.rig_scene_path,
			"a=%s b=%s" % [a.rig_scene_path, b.rig_scene_path])
		if b.rig_scene_path != "":
			_check(tag + ".declared-rig-renders", _visual_mode(b) == "rig", _visual_mode(b))
		_check(tag + ".dims-match-snapshot",
			is_equal_approx(b.body_width, float(snap["body_width"]))
			and is_equal_approx(b.body_height, float(snap["body_height"])),
			"b=%sx%s snap=%sx%s" % [b.body_width, b.body_height, snap["body_width"], snap["body_height"]])
		a.queue_free()
		b.queue_free()
		ga.free()

	# --- 4. gender survives the round trip on a template-gendered NPC ---
	var gf = GAME_SCRIPT.new()
	var fed := _spawn("surgeon_captain_federica", Vector2(1500, 200))
	await get_tree().process_frame
	var fed_snap: Dictionary = gf._serialize_character(fed)
	var fed2 := _spawn("surgeon_captain_federica", Vector2(1500, 400), _respawn_overrides(fed_snap))
	gf._deserialize_character(fed2, fed_snap)
	await get_tree().process_frame
	_check("gendered.female-round-trip", fed2.gender == "female"
		and fed2.rig_scene_path == fed.rig_scene_path,
		"gender=%s rig=%s" % [fed2.gender, fed2.rig_scene_path])
	gf.free()

	game.free()
	print("npc_race_persistence_check: %d checks, %d FAIL" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)
