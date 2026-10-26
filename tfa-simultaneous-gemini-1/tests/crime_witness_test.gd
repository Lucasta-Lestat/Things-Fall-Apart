# res://tests/crime_witness_test.gd
# Headless assertion harness for Phase 5 — the witness pipeline
# (docs/law_crime_stealth_plan.md). Real ProceduralCharacter.tscn instances,
# real physics blockers, real LawDatabase data. All PCs spawn with
# AI_enabled=false, so outcry fuses tick ONLY via direct _tick_outcry calls —
# fully deterministic, no wall-clock waits.
# Facing: rotation 0 faces UP (-Y). Witnesses face their crime; guards who
# must NOT see the crime face DOWN (rotation PI) — hearing has no facing.
# Run:  godot --headless --path . res://tests/crime_witness_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

var failures := 0

# --- Game stub surface ---
var current_map_id: String = "town_square"   # liziti law; theft/murder live, assault repealed
var characters_in_scene: Array = []
var party_chars: Array = []
var items_in_scene: Array = []
var stealth_mode: bool = false

var reported: Array = []   # captured crime_reported emissions

func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])

func _spawn(faction: String, pos: Vector2, char_name: String, face_up: bool = true) -> ProceduralCharacter:
	var pc: ProceduralCharacter = PC_SCENE.instantiate()
	add_child(pc)
	pc.global_position = pos
	pc.faction_id = faction
	pc.Name = char_name
	if not face_up:
		pc.rotation = PI
	characters_in_scene.append(pc)
	return pc

func _make_blocker(pos: Vector2, occlude_top: float = -1.0) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.collision_layer = CollisionLayers.VISION_BLOCKERS
	body.collision_mask = 0
	var cs := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(40, 200)
	cs.shape = rect
	body.add_child(cs)
	body.position = pos
	if occlude_top >= 0.0:
		body.set_meta("occlude_top", occlude_top)
	add_child(body)
	return body

func _clear_scene(extra_nodes: Array = []) -> void:
	for c in characters_in_scene:
		if is_instance_valid(c):
			c.queue_free()
	characters_in_scene = []
	party_chars = []
	for n in extra_nodes:
		if is_instance_valid(n):
			n.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame

func _pending(pc: ProceduralCharacter) -> Dictionary:
	var ai_node = pc.get_node_or_null("AI")
	return ai_node.pending_outcry if ai_node != null else {}

func _fire_fuse(pc: ProceduralCharacter) -> void:
	var ai_node = pc.get_node_or_null("AI")
	if ai_node != null and ai_node._outcry_timer > 0.0:
		ai_node._tick_outcry(ai_node._outcry_timer + 0.01)

func _alertness(pc: ProceduralCharacter) -> float:
	var ai_node = pc.get_node_or_null("AI")
	return float(ai_node.alertness_value) if ai_node != null else -1.0

func _ready() -> void:
	add_to_group("game")
	TimeManager.pause_time()
	CrimeManager.crime_reported.connect(func(enforcer, payload): reported.append({"enforcer": enforcer, "payload": payload}))
	_check("sfx.witness-clips-registered",
		SfxManager.sound_library.has("witness_huh") and SfxManager.sound_library.has("witness_scream"),
		"generate + import witness_huh/witness_scream")
	await _case_unwitnessed()
	await _case_witnessed_identified()
	await _case_kill_the_witness()
	await _case_silence_the_witness()
	await _case_alarm_propagation()
	await _case_player_footstep_heard()
	await _case_disguise()
	await _case_elevation_los()
	await _case_ranged_behind_cover()
	await _case_lone_guard_is_the_law()
	await _case_victim_is_a_witness()
	await _case_cavern_scream_through_rock()
	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _case_unwitnessed() -> void:
	var actor := _spawn("player", Vector2(0, 0), "Sneak")
	party_chars = [actor]
	# Beyond sight range (1440) — sees nothing.
	var bystander := _spawn("neutral", Vector2(2000, 0), "FarAway")
	CrimeManager.report(actor, "take", {"owner_faction": "liziti", "crime_pos": Vector2(0, 0), "debounce_target": actor})
	_check("unwitnessed.no-fuse-anywhere", _pending(bystander).is_empty(), str(_pending(bystander)))
	await _clear_scene()

func _case_witnessed_identified() -> void:
	var actor := _spawn("player", Vector2(0, -300), "Thief")
	party_chars = [actor]
	var witness := _spawn("neutral", Vector2(0, 0), "Onlooker")   # faces up, sees actor
	var w_target := _spawn("neutral", Vector2(600, 600), "t1", false)
	CrimeManager.report(actor, "take", {"owner_faction": "liziti", "crime_pos": actor.global_position, "debounce_target": w_target})
	var pending: Dictionary = _pending(witness)
	_check("witnessed.fuse-lit", not pending.is_empty())
	_check("witnessed.identified", bool(pending.get("identified", false)))
	_check("witnessed.perp-carried", pending.get("perp") == actor)
	_check("witnessed.witness-startled", _alertness(witness) >= 69.9, "%f" % _alertness(witness))
	await _clear_scene()

func _case_kill_the_witness() -> void:
	for kill_at_frac in [0.5, 0.999]:
		var actor := _spawn("player", Vector2(0, -300), "Cutthroat")
		party_chars = [actor]
		var witness := _spawn("neutral", Vector2(0, 0), "DoomedWitness")
		var w_target := _spawn("neutral", Vector2(600, 600), "t2", false)
		var before: int = reported.size()
		CrimeManager.report(actor, "take", {"owner_faction": "liziti", "crime_pos": actor.global_position, "debounce_target": w_target})
		var ai_node = witness.get_node_or_null("AI")
		_check("kill.fuse-lit-%s" % kill_at_frac, ai_node._outcry_timer > 0.0)
		# Advance to the kill moment, murder the witness, run out the fuse.
		ai_node._tick_outcry(ai_node._outcry_timer * float(kill_at_frac))
		witness.current_health = 0
		_fire_fuse(witness)
		_check("kill.no-alarm-%s" % kill_at_frac, reported.size() == before and ai_node.pending_outcry.is_empty(),
			"reported=%d" % (reported.size() - before))
		await _clear_scene()

func _case_silence_the_witness() -> void:
	var actor := _spawn("player", Vector2(0, -300), "Hushman")
	party_chars = [actor]
	var witness := _spawn("neutral", Vector2(0, 0), "MuffledWitness")
	var w_target := _spawn("neutral", Vector2(600, 600), "t3", false)
	var before: int = reported.size()
	CrimeManager.report(actor, "take", {"owner_faction": "liziti", "crime_pos": actor.global_position, "debounce_target": w_target})
	var cm = witness.get_node_or_null("ConditionManager")
	cm.apply_condition("silenced")
	_fire_fuse(witness)
	_check("silence.no-alarm", reported.size() == before and _pending(witness).is_empty())
	await _clear_scene()

func _case_alarm_propagation() -> void:
	var actor := _spawn("player", Vector2(0, -500), "PlazaThief")
	party_chars = [actor]
	var witness := _spawn("neutral", Vector2(0, -300), "Screamer")   # sees crime at (0,-500)
	# Guards positioned so none of them SEE the crime — they only hear.
	# ClearGuard sits NORTH on the x=0 line (past the crime, facing away,
	# clear of the walls that belong to the walled guards' rays).
	var guard_clear := _spawn("neutral", Vector2(0, -1000), "ClearGuard", true)
	var guard_one_wall := _spawn("neutral", Vector2(300, -300), "WalledGuard", false)
	var guard_two_walls := _spawn("neutral", Vector2(-140, -300), "FarRoomGuard", false)
	var enforcer := _spawn("liziti", Vector2(0, 0), "Constable", false)
	var wall_a := _make_blocker(Vector2(150, -300))    # between witness and WalledGuard
	var wall_b := _make_blocker(Vector2(-50, -300))    # two between witness and FarRoomGuard
	var wall_c := _make_blocker(Vector2(-100, -300))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var before: int = reported.size()
	CrimeManager.report(actor, "take", {"owner_faction": "liziti", "crime_pos": actor.global_position, "debounce_target": actor})
	_check("alarm.only-witness-has-fuse",
		not _pending(witness).is_empty() and _pending(guard_clear).is_empty(),
		"guards face away; only the witness saw it")
	_fire_fuse(witness)
	var a_clear: float = _alertness(guard_clear)
	var a_one: float = _alertness(guard_one_wall)
	var a_two: float = _alertness(guard_two_walls)
	_check("alarm.clear-guard-searching", a_clear >= 70.0 and a_clear <= 78.0, "%f" % a_clear)
	_check("alarm.one-wall-suspicious", a_one >= 30.0 and a_one <= 37.0, "%f" % a_one)
	_check("alarm.two-walls-nothing", a_two < 25.0, "%f" % a_two)
	# Neutral witness screaming to neutral guards, everyone enemies:[] — the
	# alarm is DELIVERED (the old :72 faction gate discarded exactly this).
	_check("alarm.neutral-to-neutral-delivered", a_clear > 0.0)
	_check("alarm.enforcer-recorded", reported.size() == before + 1
		and reported.back()["enforcer"] == enforcer, "reported=%d" % (reported.size() - before))
	await _clear_scene([wall_a, wall_b, wall_c])

func _case_player_footstep_heard() -> void:
	# R3: player-made ambient sound reaches lawful NPCs — sneaking is
	# detectable BEFORE the player is hostile.
	var player := _spawn("player", Vector2(0, -150), "Sneaker")
	party_chars = [player]
	var guard := _spawn("golden_guard", Vector2(0, 0), "TownGuard", false)
	HearingManager.emit(player.global_position, 0.9, player)
	var a: float = _alertness(guard)
	_check("footstep.lawful-npc-hears-player", a >= 45.0 and a <= 55.0, "%f" % a)
	await _clear_scene()

func _case_disguise() -> void:
	var actor := _spawn("player", Vector2(0, -300), "MaskedFigure")
	party_chars = [actor]
	var hood := EquipmentShape.new()
	hood.set_meta("item_data", {"disguise": {"strength": 3, "conceals": ["face"]}})
	actor.head_equipment = hood
	_check("disguise.recognised", CrimeManager.is_disguised(actor))
	var witness := _spawn("neutral", Vector2(0, 0), "Bystander")
	# An enforcer in earshot but facing away: anonymous alarms only become
	# REPORTS when someone whose job it is to care actually hears them.
	var constable := _spawn("liziti", Vector2(300, 0), "HoodConstable", false)
	var w_target := _spawn("neutral", Vector2(600, 600), "t4", false)
	var before: int = reported.size()
	CrimeManager.report(actor, "take", {"owner_faction": "liziti", "crime_pos": actor.global_position, "debounce_target": w_target})
	var pending: Dictionary = _pending(witness)
	_check("disguise.fuse-still-lit", not pending.is_empty(), "an unidentified crime still screams")
	_check("disguise.unidentified", not bool(pending.get("identified", true)))
	_check("disguise.no-perp-carried", pending.get("perp") == null)
	_fire_fuse(witness)
	_check("disguise.alarm-fires-anonymous", reported.size() == before + 1
		and not bool(reported.back()["payload"].get("identified", true))
		and reported.back()["enforcer"] == constable)
	hood.free()
	await _clear_scene()

func _case_elevation_los() -> void:
	# Direct unit of the target_elev fix: a low wall hides ground level but
	# not a rooftop-height target behind it.
	var viewer := _spawn("neutral", Vector2(0, 0), "StreetViewer")
	var low_wall := _make_blocker(Vector2(0, -150), 1.0)
	var target_pos := Vector2(0, -300)
	# (async-free: uses physics directly after two frames)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("elev.ground-hidden", not CrimeManager.has_visual_los(viewer, target_pos, 0.0))
	_check("elev.rooftop-crime-seen", CrimeManager.has_visual_los(viewer, target_pos, 2.0))
	await _clear_scene([low_wall])

func _case_ranged_behind_cover() -> void:
	# Witness sees the CRIME position but the ACTOR is behind cover: the
	# outcry starts unidentified — ranged/AoE crime is not free.
	var actor := _spawn("player", Vector2(400, -300), "CovertCaster")
	party_chars = [actor]
	var witness := _spawn("neutral", Vector2(0, 0), "PlazaWitness")
	var wall := _make_blocker(Vector2(200, -150))   # between witness and actor
	await get_tree().physics_frame
	await get_tree().physics_frame
	var crime_pos := Vector2(0, -300)               # open line from witness
	var w_target := _spawn("neutral", Vector2(600, 600), "t5", false)
	CrimeManager.report(actor, "take", {"owner_faction": "liziti", "crime_pos": crime_pos, "debounce_target": w_target})
	var pending: Dictionary = _pending(witness)
	_check("cover.fuse-lit", not pending.is_empty())
	_check("cover.unidentified", not bool(pending.get("identified", true)))
	await _clear_scene([wall])

func _case_lone_guard_is_the_law() -> void:
	# The sole witness is the enforcer: HearingManager skips the emitter, so
	# the consequence must arrive via the direct path at fire time.
	var actor := _spawn("player", Vector2(0, -300), "BoldThief")
	party_chars = [actor]
	var guard := _spawn("liziti", Vector2(0, 0), "LoneConstable")
	var w_target := _spawn("neutral", Vector2(600, 600), "t6", false)
	var before: int = reported.size()
	CrimeManager.report(actor, "take", {"owner_faction": "liziti", "crime_pos": actor.global_position, "debounce_target": w_target})
	_check("lone.fuse-lit", not _pending(guard).is_empty())
	_fire_fuse(guard)
	_check("lone.self-delivered", reported.size() == before + 1
		and reported.back()["enforcer"] == guard, "no HearingManager round trip needed")
	await _clear_scene()

func _case_victim_is_a_witness() -> void:
	# Assault with zero third parties: the victim is the witness, identified,
	# even facing away (no LOS at fan-out — the explicit victim fallback).
	# Runs under common law: Perrow repealed assault.
	MapDatabase._maps["__witness_commonlaw"] = {"id": "__witness_commonlaw", "controlling_faction": "alamoneans"}
	current_map_id = "__witness_commonlaw"
	var actor := _spawn("player", Vector2(0, 100), "Mugger")
	party_chars = [actor]
	var victim := _spawn("neutral", Vector2(0, 0), "Mark", false)   # faces away
	var before: int = reported.size()
	CrimeManager.report(actor, "attack", CrimeManager.attack_payload(actor, victim))
	var pending: Dictionary = _pending(victim)
	_check("victim.fuse-lit", not pending.is_empty(), "the victim can always report")
	_check("victim.identified", bool(pending.get("identified", false)), "contact beats costume")
	_check("victim.statute-assault", str(pending.get("statute", "")) == "assault", str(pending))
	_fire_fuse(victim)
	_check("victim.alarm-raised", reported.size() >= before, "scream fired (no enforcer nearby to record)")
	MapDatabase._maps.erase("__witness_commonlaw")
	current_map_id = "town_square"
	await _clear_scene()

func _tile(x: int, y: int) -> Vector2:
	return GridManager.map_to_world(Vector2i(x, y))

func _case_cavern_scream_through_rock() -> void:
	# G3: an interior whose rock is terrain (tg_hillside_cavern / _ossuary export
	# no walls at all). The scream carries down its own gallery, but across the
	# rock mass it counts as two walls more (HearingManager.TERRAIN_OCCLUDERS),
	# so the next gallery's guard and constable hear nothing. Same alarm path as
	# _case_alarm_propagation: _loudness_at is the law system's hook.
	# 16x8 tiles: gallery A floor 9.0 (x <= 6), rock 12.5 (x 7..8), gallery B
	# floor 9.0 (x >= 9). A relief map (span 3.5), so terrain LOS is on too.
	GridManager.TILE_SIZE = 64
	GridManager.initialize(16 * 64, 8 * 64)
	for y in 8:
		for x in 16:
			GridManager.elevations[Vector2i(x, y)] = 12.5 if x == 7 or x == 8 else 9.0
	GridManager.refresh_terrain_stats()
	var actor := _spawn("player", _tile(5, 1), "CaveThief")
	party_chars = [actor]
	var witness := _spawn("neutral", _tile(5, 4), "CaveWitness")                    # faces up, sees the theft
	var guard_open := _spawn("neutral", _tile(1, 4), "GalleryGuard", false)          # 256 px, open floor
	var guard_rock := _spawn("neutral", _tile(9, 4), "FarGalleryGuard", false)       # 256 px, across the rock
	var enforcer_open := _spawn("liziti", _tile(3, 6), "GalleryConstable", false)
	var enforcer_rock := _spawn("liziti", _tile(9, 6), "FarGalleryConstable", false)
	var w_target := _spawn("neutral", _tile(14, 7), "t7", false)
	for pc in [actor, witness, guard_open, guard_rock, enforcer_open, enforcer_rock, w_target]:
		pc._refresh_elevation()   # stand ON the 9.0 floor (eye 9.5), not at sea level
	await get_tree().physics_frame
	await get_tree().physics_frame
	var scream: float = float(LawDatabase.witness_cfg().get("scream_loudness", 1.35))
	var wf: float = HearingManager.WALL_OCCLUSION_FACTOR
	_check("cavern.relief-on", GridManager.relief_los)
	_check("cavern.scream-path-attenuated",
		is_equal_approx(HearingManager._loudness_at(witness.global_position, guard_rock.global_position, scream), scream * wf * wf)
		and is_equal_approx(HearingManager._loudness_at(witness.global_position, guard_open.global_position, scream), scream))
	var before: int = reported.size()
	CrimeManager.report(actor, "take", {"owner_faction": "liziti", "crime_pos": actor.global_position, "debounce_target": w_target})
	_check("cavern.witness-fuse-lit", not _pending(witness).is_empty() and _pending(guard_open).is_empty()
		and _pending(guard_rock).is_empty(), "only the witness saw it")
	_fire_fuse(witness)
	var a_open: float = _alertness(guard_open)
	var a_rock: float = _alertness(guard_rock)
	_check("cavern.open-gallery-guard-searching", a_open >= 70.0 and a_open <= 78.0, "%f" % a_open)
	_check("cavern.guard-across-rock-hears-nothing", a_rock < 25.0 and a_rock < a_open, "%f" % a_rock)
	_check("cavern.only-open-constable-reports", reported.size() == before + 1
		and reported.back()["enforcer"] == enforcer_open, "reported=%d" % (reported.size() - before))
	# control: the same two points with the rock levelled carry the scream whole
	for y in 8:
		for x in [7, 8]:
			GridManager.elevations[Vector2i(x, y)] = 9.0
	GridManager.refresh_terrain_stats()
	_check("cavern.flat-control-unattenuated", not GridManager.relief_los
		and is_equal_approx(HearingManager._loudness_at(witness.global_position, guard_rock.global_position, scream), scream))
	await _clear_scene()
	GridManager.initialize(0, 0)   # back to this harness's unloaded grid
	GridManager.refresh_terrain_stats()
