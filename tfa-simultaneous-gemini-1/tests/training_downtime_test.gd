# res://tests/training_downtime_test.gd
# Headless harness for training commitments, multi-day downtime, and the
# companion departure/return rules.
#
# The contract under test:
#   (1) Intelligence shortens training — a sharp learner never needs MORE days
#       than a dull one, across enough samples that the d100 can't fake it,
#   (2) N days of study grants the ability and N-1 does not,
#   (3) granting twice does not double-append (add_ability_by_id does not dedupe),
#   (4) training only appears where the teacher actually is,
#   (5) favorability decides whether a companion follows you or takes other work,
#   (6) an away member does not break save_party_state's row pairing — the trap
#       that would otherwise write one companion's snapshot over another's,
#   (7) favorability and stress survive a serialize/deserialize round trip.
#
# Run:  godot --headless --path . res://tests/training_downtime_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const ABILITY := "shield_bash"

var _fails := 0
var _checks := 0
var game = null


func _ready() -> void:
	TimeManager.pause_time()
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)

	# Drive the REAL game scene, the way law_persist_test does: the departure,
	# row-pairing and persistence cases are all Game methods, and stubbing Game
	# would test the stub. Let the initial ready cascade finish first — a node
	# added to root DURING it never receives NOTIFICATION_READY, so @onready
	# vars stay null and Game._ready never runs.
	await get_tree().process_frame
	var GameScene := load("res://game.tscn")
	game = GameScene.instantiate()
	game.current_map_id = ""   # _ready's load_map("") early-returns; we load below
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _await_frames(2)
	game.load_map("town_square")
	await _await_frames(5)

	_case_activity_authored()
	_case_intelligence_sets_the_pace()
	_case_days_grant_the_ability()
	_case_grant_dedupes()
	_case_region_gating()
	_case_departure_branches()
	_case_away_row_pairing()
	_case_social_state_round_trips()
	await _case_day_advance()

	print("HARNESS DONE failures=%d checks=%d" % [_fails, _checks])
	get_tree().quit(1 if _fails > 0 else 0)


func _await_frames(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame


# --- 1. data ---------------------------------------------------------------

func _case_activity_authored() -> void:
	var a: Dictionary = DowntimeDatabase.get_activity("training")
	_report("data.training-activity-exists", not a.is_empty(), "")
	_report("data.training-flagged", bool(a.get("requires_training", false)), "")
	_report("data.training-checks-intelligence",
		str(a.get("ability_check", "")) == "Intelligence", str(a.get("ability_check")))
	# It must NOT be a camp activity — the teacher is in town, not at a campfire.
	_report("data.training-not-camp",
		not ("training" in DowntimeDatabase.get_camp_activities()), "")


# --- 2. Intelligence sets the pace -----------------------------------------

func _case_intelligence_sets_the_pace() -> void:
	var dull := _spawn(Vector2(200, 200))
	var sharp := _spawn(Vector2(260, 200))
	dull.intelligence = 5
	sharp.intelligence = 95

	# ability_check rolls d100, so compare distributions rather than one roll.
	var base := 5
	var dull_total := 0
	var sharp_total := 0
	var samples := 200
	for i in range(samples):
		dull_total += TrainingManager.roll_days_required(dull, base)
		sharp_total += TrainingManager.roll_days_required(sharp, base)

	_report("speed.sharp-learns-no-slower", sharp_total <= dull_total,
		"sharp=%d dull=%d over %d samples" % [sharp_total, dull_total, samples])
	_report("speed.sharp-is-actually-faster", sharp_total < dull_total,
		"sharp=%d dull=%d" % [sharp_total, dull_total])

	# Bounds hold whatever the roll does.
	var lo := TrainingManager.roll_days_required(sharp, base)
	_report("speed.never-below-one", lo >= 1, str(lo))
	var hi := TrainingManager.roll_days_required(dull, base)
	_report("speed.never-runs-away", hi <= base + 2, str(hi))

	dull.queue_free()
	sharp.queue_free()


# --- 3. days buy the ability ------------------------------------------------

func _case_days_grant_the_ability() -> void:
	TrainingManager.commitments.clear()
	var learner := _spawn(Vector2(400, 200))
	learner.template_id = "test_learner"
	learner.set_meta("template_id", "test_learner")

	var c: Dictionary = TrainingManager.accept_offer(
		learner, {"ability_id": ABILITY, "base_days": 3, "teacher_title": "Master"}, "town_square")
	_report("days.commitment-created", not c.is_empty(), str(c))
	if c.is_empty():
		learner.queue_free()
		return

	var required: int = int(c["days_required"])
	_report("days.not-granted-on-acceptance",
		not TrainingManager.knows_ability(learner, ABILITY), "")

	# One short of the requirement must not be enough.
	for i in range(required - 1):
		TrainingManager.credit_day(learner)
	_report("days.n-minus-one-is-not-enough",
		not TrainingManager.knows_ability(learner, ABILITY),
		"after %d of %d" % [required - 1, required])
	_report("days.remaining-counts-down",
		TrainingManager.days_remaining(learner) == 1,
		str(TrainingManager.days_remaining(learner)))

	var finished: bool = TrainingManager.credit_day(learner)
	_report("days.final-day-completes", finished, "")
	_report("days.ability-granted", TrainingManager.knows_ability(learner, ABILITY), "")
	_report("days.commitment-cleared", not TrainingManager.has_open_commitment(learner), "")
	learner.queue_free()


# --- 4. granting is idempotent ---------------------------------------------

func _case_grant_dedupes() -> void:
	var c := _spawn(Vector2(600, 200))
	var before: int = c.inventory.stowed_items.size()
	TrainingManager.grant_ability(c, ABILITY)
	var after_one: int = c.inventory.stowed_items.size()
	TrainingManager.grant_ability(c, ABILITY)
	var after_two: int = c.inventory.stowed_items.size()

	_report("dedupe.first-grant-adds", after_one > before, "%d -> %d" % [before, after_one])
	_report("dedupe.second-grant-is-a-noop", after_two == after_one,
		"%d -> %d" % [after_one, after_two])
	_report("dedupe.knows-ability-true", TrainingManager.knows_ability(c, ABILITY), "")
	c.queue_free()


# --- 5. the teacher has to be here -----------------------------------------

func _case_region_gating() -> void:
	TrainingManager.commitments.clear()
	var learner := _spawn(Vector2(800, 200))
	learner.template_id = "test_region_learner"
	learner.set_meta("template_id", "test_region_learner")

	# town_square's region, whatever regions.json says it is.
	var home: String = RegionDatabase.get_region_for_map("town_square")
	TrainingManager.accept_offer(
		learner, {"ability_id": ABILITY, "base_days": 3}, "town_square")

	_report("region.can-train-where-booked",
		TrainingManager.can_train_here(learner, home), "region=" + home)
	_report("region.cannot-train-elsewhere",
		not TrainingManager.can_train_here(learner, "__nowhere__"), "")
	_report("region.no-commitment-no-training",
		not TrainingManager.can_train_here(_spawn(Vector2(860, 200)), home), "")

	TrainingManager.commitments.clear()
	learner.queue_free()


# --- 6. loyalty decides -----------------------------------------------------

func _case_departure_branches() -> void:
	_report("departure.threshold-is-just-above-neutral",
		game.FOLLOW_FAVOR_THRESHOLD > 0 and game.FOLLOW_FAVOR_THRESHOLD < 50,
		str(game.FOLLOW_FAVOR_THRESHOLD))

	# Two companions, same unfinished commitment on the map we're about to
	# leave, opposite feelings about the player.
	TrainingManager.commitments.clear()
	var saved_state: Array = game.party_state.duplicate(true)
	var saved_chars: Array = game.party_chars.duplicate()

	game.party_state = [
		{"template_id": "row_hero", "overrides": {}, "live_state": null},
		{"template_id": "row_loyal", "overrides": {}, "live_state": null},
		{"template_id": "row_sour", "overrides": {}, "live_state": null},
	]
	var hero := _spawn(Vector2(1500, 500))
	var loyal := _spawn(Vector2(1560, 500))
	var sour := _spawn(Vector2(1620, 500))
	for pair in [[hero, 0, "row_hero"], [loyal, 1, "row_loyal"], [sour, 2, "row_sour"]]:
		pair[0].set_meta("party_index", pair[1])
		pair[0].template_id = pair[2]
		pair[0].set_meta("template_id", pair[2])
		pair[0].display_name = pair[2]
	game.party_chars = [hero, loyal, sour]

	loyal.favorability = game.FOLLOW_FAVOR_THRESHOLD + 5
	sour.favorability = game.FOLLOW_FAVOR_THRESHOLD - 5
	TrainingManager.accept_offer(loyal, {"ability_id": ABILITY, "base_days": 4}, "town_square")
	TrainingManager.accept_offer(sour, {"ability_id": ABILITY, "base_days": 4}, "town_square")

	game._resolve_departures("town_square", "cemetery")

	var loyal_away = game.party_state[1].get("away", {})
	var sour_away = game.party_state[2].get("away", {})
	_report("departure.loyal-goes-away", loyal_away is Dictionary and not loyal_away.is_empty(),
		str(loyal_away))
	_report("departure.loyal-will-follow",
		str(loyal_away.get("reason", "")) == "training", str(loyal_away.get("reason")))
	_report("departure.loyal-has-a-return-date",
		int(loyal_away.get("return_day", -1)) > TimeManager.today(), str(loyal_away.get("return_day")))
	_report("departure.sour-takes-other-work",
		str(sour_away.get("reason", "")) == "other_work", str(sour_away.get("reason")))
	_report("departure.sour-waits-where-left",
		str(sour_away.get("return_map", "")) == "town_square", str(sour_away.get("return_map")))
	# The protagonist is never left behind, whatever they owe.
	_report("departure.protagonist-never-leaves",
		not game.is_party_member_away(game.party_state[0]), "")

	# A loyal companion finishes off-screen: the ability is queued, not lost.
	_report("departure.loyal-ability-queued",
		str(loyal_away.get("ability_id", "")) == ABILITY, str(loyal_away.get("ability_id")))

	# ...and lands when they walk back in.
	game._resolve_returns("nowhere")   # not due yet
	_report("departure.not-back-early", game.is_party_member_away(game.party_state[1]), "")

	TimeManager.days_elapsed = int(loyal_away.get("return_day", 0))
	game._resolve_returns("cemetery")
	_report("departure.returns-when-due", not game.is_party_member_away(game.party_state[1]), "")
	# The sour one is still gone — you have to go back for them.
	_report("departure.sour-still-gone", game.is_party_member_away(game.party_state[2]), "")
	game._resolve_returns("town_square")
	_report("departure.sour-back-when-you-return",
		not game.is_party_member_away(game.party_state[2]), "")

	for c in [hero, loyal, sour]:
		if is_instance_valid(c):
			c.queue_free()
	TrainingManager.commitments.clear()
	TrainingManager.pending_grants.clear()
	game.party_state = saved_state
	game.party_chars = saved_chars


# --- 7. an away member must not shift everyone else's snapshot --------------

func _case_away_row_pairing() -> void:
	var saved_state: Array = game.party_state.duplicate(true)
	var saved_chars: Array = game.party_chars.duplicate()

	# Three rows; the MIDDLE one is away, so positional zipping would write
	# row 1's snapshot from the character that actually belongs to row 2.
	game.party_state = [
		{"template_id": "row0", "overrides": {}, "live_state": null},
		{"template_id": "row1", "overrides": {}, "live_state": null,
			"away": {"reason": "training", "return_day": 999, "return_map": "", "ability_id": ABILITY}},
		{"template_id": "row2", "overrides": {}, "live_state": null},
	]
	var a := _spawn(Vector2(1000, 200))
	var b := _spawn(Vector2(1060, 200))
	a.display_name = "RowZero"
	b.display_name = "RowTwo"
	a.set_meta("party_index", 0)
	b.set_meta("party_index", 2)
	game.party_chars = [a, b]

	_report("pairing.away-detected", game.is_party_member_away(game.party_state[1]), "")
	_report("pairing.present-not-away", not game.is_party_member_away(game.party_state[0]), "")
	_report("pairing.away-list-size", game.get_away_members().size() == 1,
		str(game.get_away_members().size()))

	game.save_party_state()
	var row0 = game.party_state[0].get("live_state")
	var row1 = game.party_state[1].get("live_state")
	var row2 = game.party_state[2].get("live_state")

	_report("pairing.row0-got-its-own",
		row0 is Dictionary and str(row0.get("display_name", "")) == "RowZero",
		str(row0.get("display_name") if row0 is Dictionary else row0))
	_report("pairing.away-row-untouched", row1 == null, str(row1))
	_report("pairing.row2-got-its-own",
		row2 is Dictionary and str(row2.get("display_name", "")) == "RowTwo",
		str(row2.get("display_name") if row2 is Dictionary else row2))

	a.queue_free()
	b.queue_free()
	game.party_state = saved_state
	game.party_chars = saved_chars


# --- 8. Phase 0: the state the whole feature leans on -----------------------

func _case_social_state_round_trips() -> void:
	var src := _spawn(Vector2(1300, 200))
	src.favorability = 42
	src.stress = 7
	src.patron_id = "lilith"
	src.vow_poverty_points = 3

	var snap: Dictionary = game._serialize_character(src)
	_report("persist.favorability-serialized", snap.has("favorability"), "")
	_report("persist.stress-serialized", snap.has("stress"), "")

	var dst := _spawn(Vector2(1360, 200))
	game._deserialize_character(dst, snap)
	_report("persist.favorability-restored", dst.favorability == 42, str(dst.favorability))
	_report("persist.stress-restored", dst.stress == 7, str(dst.stress))
	_report("persist.patron-restored", dst.patron_id == "lilith", dst.patron_id)
	_report("persist.vow-points-restored", dst.vow_poverty_points == 3, str(dst.vow_poverty_points))

	src.queue_free()
	dst.queue_free()


# --- 9. the day rolls over and idle companions do something -----------------

func _case_day_advance() -> void:
	var saved_state: Array = game.party_state.duplicate(true)
	var saved_chars: Array = game.party_chars.duplicate()

	game.party_state = [
		{"template_id": "row_a", "overrides": {}, "live_state": null},
		{"template_id": "row_b", "overrides": {}, "live_state": null},
	]
	var a := _spawn(Vector2(1700, 500))
	var b := _spawn(Vector2(1760, 500))
	a.set_meta("party_index", 0)
	b.set_meta("party_index", 1)
	a.set_meta("template_id", "row_a")
	b.set_meta("template_id", "row_b")
	a.display_name = "RowA"
	b.display_name = "RowB"
	game.party_chars = [a, b]
	game.downtime_day_assignments.clear()

	# One of them already spent the day; the other should get one picked for them.
	game.record_downtime_assignment(a, "carousing")
	_report("day.assignment-recorded", game.has_downtime_assignment(a), "")
	_report("day.other-still-idle", not game.has_downtime_assignment(b), "")

	var day_before: int = TimeManager.today()
	game.advance_downtime_day()
	await _await_frames(1)

	_report("day.clock-advanced-one-day", TimeManager.today() == day_before + 1,
		"%d -> %d" % [day_before, TimeManager.today()])
	_report("day.wakes-at-dawn", TimeManager.current_hour == 6, str(TimeManager.current_hour))
	_report("day.assignments-cleared", game.downtime_day_assignments.is_empty(),
		str(game.downtime_day_assignments))

	# trained_today must distinguish training from any other activity.
	game.record_downtime_assignment(a, "carousing")
	_report("day.carousing-is-not-training", not game.trained_today(a), "")
	game.record_downtime_assignment(a, TrainingManager.TRAINING_ACTIVITY_ID)
	_report("day.training-is-training", game.trained_today(a), "")

	game.downtime_day_assignments.clear()
	for c in [a, b]:
		if is_instance_valid(c):
			c.queue_free()
	game.party_state = saved_state
	game.party_chars = saved_chars


# --- helpers ----------------------------------------------------------------

func _spawn(pos: Vector2) -> ProceduralCharacter:
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	c.is_player_controlled = true
	add_child(c)
	c.global_position = pos
	c.hold_position = true
	return c


func _report(check_name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("%s %s: %s" % ["PASS" if ok else "FAIL", check_name, detail])
