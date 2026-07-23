# res://tests/crime_consequence_test.gd
# Headless assertion harness for Phase 6 — consequence, hostility, legibility
# (docs/law_crime_stealth_plan.md). Real ProceduralCharacter instances where
# hostility/manhunt behaviour is asserted; direct FactionDatabase/CrimeManager
# calls where the pipeline stages were already proven by crime_witness_test.
# NOTE: mutates FactionDatabase standing state — each case cleans up after
# itself (settle/adjust back) so cases stay independent.
# Run:  godot --headless --path . res://tests/crime_consequence_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

var failures := 0

# --- Game stub surface ---
var current_map_id: String = "town_square"
var characters_in_scene: Array = []
var party_chars: Array = []
var items_in_scene: Array = []
var stealth_mode: bool = false

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
		pc.rotation = PI   # face DOWN — cannot witness anything north of it
	characters_in_scene.append(pc)
	return pc

func _clear_scene() -> void:
	for c in characters_in_scene:
		if is_instance_valid(c):
			c.queue_free()
	characters_in_scene = []
	party_chars = []
	await get_tree().physics_frame

func _alarm_payload(crime_id: int, identified: bool, perp, severity: int = 90, statute: String = "murder") -> Dictionary:
	return {
		"crime_id": crime_id,
		"identified": identified,
		"perp": perp,
		"crime_pos": Vector2.ZERO,
		"law_faction": "liziti",
		"statute": statute,
		"display_name": statute.capitalize(),
		"severity": severity,
	}

func _ready() -> void:
	add_to_group("game")
	TimeManager.pause_time()
	await _case_threshold_hostility()
	await _case_identified_crime_consequence()
	_case_alarm_dedup()
	_case_ledger_inertness()
	await _case_manhunt_outlives_decay()
	await _case_settle()
	await _case_thrill_of_sin()
	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _case_threshold_hostility() -> void:
	_check("stance.baseline-neutral", FactionDatabase.player_stance_toward("waldau") == "neutral")
	FactionDatabase.adjust_player_standing("waldau", -50)
	_check("stance.scalar-crosses-threshold", FactionDatabase.player_stance_toward("waldau") == "hostile")
	_check("stance.oracle-follows", FactionDatabase.are_hostile("player", "waldau"))
	# A real AI agrees with the oracle.
	var npc := _spawn("waldau", Vector2.ZERO, "Rationalist")
	var target := _spawn("player", Vector2(100, 0), "Visitor")
	party_chars = [target]
	_check("stance.ai-agrees", npc.get_node("AI")._is_enemy(target))
	FactionDatabase.adjust_player_standing("waldau", 50)
	_check("stance.recovers", not FactionDatabase.are_hostile("player", "waldau"))
	await _clear_scene()

func _case_identified_crime_consequence() -> void:
	var protagonist := _spawn("player", Vector2.ZERO, "Ana")
	party_chars = [protagonist]
	var enforcer := _spawn("liziti", Vector2(50, 0), "Constable")
	var standing_before: int = FactionDatabase.get_player_standing("liziti")
	CrimeManager.on_alarm_heard(enforcer, _alarm_payload(9001, true, protagonist))
	_check("consequence.standing-drops-by-severity",
		FactionDatabase.get_player_standing("liziti") == standing_before - 90,
		"%d" % FactionDatabase.get_player_standing("liziti"))
	_check("consequence.override-set", FactionDatabase.is_outlaw_with("liziti"))
	_check("consequence.binary-hostile", FactionDatabase.are_hostile("player", "liziti"))
	_check("consequence.ledger-written", FactionDatabase.crime_records("liziti").size() == 1)
	_check("consequence.wanted-derived",
		protagonist.get_node("ConditionManager").has_condition("wanted"))
	# Anonymous alarm: rouses, but moves nothing.
	var standing_mid: int = FactionDatabase.get_player_standing("liziti")
	CrimeManager.on_alarm_heard(enforcer, _alarm_payload(9002, false, null, 25, "theft"))
	_check("consequence.anonymous-moves-nothing",
		FactionDatabase.get_player_standing("liziti") == standing_mid
		and FactionDatabase.crime_records("liziti").size() == 1)
	await _clear_scene()
	# Leave liziti outlaw state for the settle case? No — settle case builds
	# its own. Clean up here.
	CrimeManager.settle_with("liziti", "")

func _case_alarm_dedup() -> void:
	var standing_before: int = FactionDatabase.get_player_standing("waldau")
	var e1 := Node2D.new()
	var e2 := Node2D.new()
	var e3 := Node2D.new()
	add_child(e1); add_child(e2); add_child(e3)
	var payload: Dictionary = _alarm_payload(9010, true, null, 40, "assault")
	payload["law_faction"] = "waldau"
	CrimeManager.on_alarm_heard(e1, payload)
	CrimeManager.on_alarm_heard(e2, payload)
	CrimeManager.on_alarm_heard(e3, payload)
	_check("dedup.three-hearers-one-penalty",
		FactionDatabase.get_player_standing("waldau") == standing_before - 40,
		"%d" % FactionDatabase.get_player_standing("waldau"))
	e1.queue_free(); e2.queue_free(); e3.queue_free()
	CrimeManager.settle_with("waldau", "")

func _case_ledger_inertness() -> void:
	# Ten records at standing 0: the ledger prices fines and feeds dialogue,
	# and touches NO behaviour path. The D2-mitigation invariant.
	for i in range(10):
		FactionDatabase.record_crime("alamoneans", {"statute": "theft", "severity": 25})
	_check("ledger.inert-stance", FactionDatabase.player_stance_toward("alamoneans") == "neutral")
	_check("ledger.inert-oracle", not FactionDatabase.are_hostile("player", "alamoneans"))
	_check("ledger.prices-fines", FactionDatabase.fine_owed("alamoneans") == 10 * 25 * 12)
	FactionDatabase.settle("alamoneans", "")

func _case_manhunt_outlives_decay() -> void:
	var perp := _spawn("player", Vector2(200, 0), "Fugitive")
	party_chars = [perp]
	var guard := _spawn("liziti", Vector2.ZERO, "Bloodhound")
	var guard_ai = guard.get_node("AI")
	guard_ai.on_sound_heard(Vector2.ZERO, 1.35, null, "alarm", _alarm_payload(9020, true, perp))
	_check("manhunt.set-from-alarm", guard_ai.manhunt_target == perp)
	# Full alertness decay: he stops searching, he does not forget.
	guard_ai._set_alertness_value(0.0)
	_check("manhunt.survives-decay", guard_ai._is_enemy(perp), "knowledge outlives arousal")
	CrimeManager.settle_with("liziti", "")
	_check("manhunt.cleared-by-settle", guard_ai.manhunt_target == null)
	_check("manhunt.no-longer-enemy", not guard_ai._is_enemy(perp))
	await _clear_scene()

func _case_settle() -> void:
	var protagonist := _spawn("player", Vector2.ZERO, "Debtor")
	party_chars = [protagonist]
	# A stolen item in inventory, a crime on the books, an override in force.
	protagonist.inventory.items.append({"id": "candlestick", "stolen_from": "liziti", "num_stacks": 1})
	var enforcer := _spawn("liziti", Vector2(50, 0), "Bailiff")
	CrimeManager.on_alarm_heard(enforcer, _alarm_payload(9030, true, protagonist, 25, "theft"))
	_check("settle.pre-wanted", protagonist.get_node("ConditionManager").has_condition("wanted"))
	var day_before: int = TimeManager.today()
	CrimeManager.settle_with("liziti", "serve_time")
	_check("settle.override-cleared", not FactionDatabase.is_outlaw_with("liziti"))
	_check("settle.standing-floored-at-zero", FactionDatabase.get_player_standing("liziti") == 0,
		"%d" % FactionDatabase.get_player_standing("liziti"))
	# Records accumulate across this harness's earlier liziti cases — the
	# ledger deliberately never deletes. All must read settled, none erased.
	var records: Array = FactionDatabase.crime_records("liziti")
	var all_settled: bool = not records.is_empty()
	for record in records:
		if not bool(record.get("settled", false)):
			all_settled = false
	_check("settle.records-kept-and-settled", all_settled,
		"square with the law; nobody has forgotten (%d records)" % records.size())
	_check("settle.goods-returned", protagonist.inventory.items.is_empty())
	_check("settle.time-actually-served", TimeManager.today() > day_before,
		"today=%d before=%d" % [TimeManager.today(), day_before])
	_check("settle.no-longer-hostile", not FactionDatabase.are_hostile("player", "liziti"))
	_check("settle.wanted-removed",
		not protagonist.get_node("ConditionManager").has_condition("wanted"))
	await _clear_scene()

func _case_thrill_of_sin() -> void:
	var actor := _spawn("player", Vector2(0, -300), "Sinner")
	party_chars = [actor]
	var actor_cm = actor.get_node("ConditionManager")
	actor_cm.apply_condition("thrill_of_sin", null, 1, -1.0)
	_check("thrill.seeded", actor_cm.has_condition("thrill_of_sin"))
	var stacks_at: int = actor_cm.conditions["thrill_of_sin"].stacks
	# Unwitnessed crime: no fuse, no reward — the reward is for BEATING a
	# fuse, not for the absence of one.
	CrimeManager.report(actor, "take", {"owner_faction": "liziti", "crime_pos": actor.global_position, "debounce_target": actor})
	_check("thrill.no-stack-unwitnessed", actor_cm.conditions["thrill_of_sin"].stacks == stacks_at)
	# Witnessed crime, witness killed in the window: stack granted. The loot
	# stand-in faces AWAY — a face-up PC at any distance is a real witness
	# whose unresolved fuse would block the grant forever.
	var witness := _spawn("neutral", Vector2(0, 0), "Silenced")
	var target := _spawn("neutral", Vector2(600, 600), "loot", false)
	CrimeManager.report(actor, "take", {"owner_faction": "liziti", "crime_pos": actor.global_position, "debounce_target": target})
	var w_ai = witness.get_node("AI")
	_check("thrill.fuse-lit", w_ai._outcry_timer > 0.0)
	witness.current_health = 0
	w_ai._tick_outcry(w_ai._outcry_timer + 0.01)
	_check("thrill.stacked-on-beaten-fuse",
		actor_cm.conditions["thrill_of_sin"].stacks == stacks_at + 1,
		"stacks=%d" % actor_cm.conditions["thrill_of_sin"].stacks)
	# Same target again (past the report debounce): the (statute, target)
	# thrill dedup blocks farming even though the crime itself re-reports.
	TimeManager.game_time += 3.0
	var witness2 := _spawn("neutral", Vector2(0, 0), "Silenced2")
	CrimeManager.report(actor, "take", {"owner_faction": "liziti", "crime_pos": actor.global_position, "debounce_target": target})
	var w2_ai = witness2.get_node("AI")
	_check("thrill.refuse-lit", w2_ai._outcry_timer > 0.0, "crime re-reports after debounce")
	witness2.current_health = 0
	w2_ai._tick_outcry(w2_ai._outcry_timer + 0.01)
	_check("thrill.deduped-per-target",
		actor_cm.conditions["thrill_of_sin"].stacks == stacks_at + 1)
	CrimeManager.settle_with("liziti", "")
	await _clear_scene()
