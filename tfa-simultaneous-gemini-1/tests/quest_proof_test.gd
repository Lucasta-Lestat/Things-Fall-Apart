# res://tests/quest_proof_test.gd
# Headless harness for quest proof + turn-in.
#
# The contract under test:
#   (1) a trophy harvested from a corpse is stamped with THAT victim's template,
#   (2) turn-in rejects the same item stamped with someone else's identity,
#   (3) turn-in accepts the right one, CONSUMES it, and completes the quest,
#   (4) proof is read from live inventory, not from world_state — the
#       item_picked:: latch stays true after a drop and must not satisfy a bounty,
#   (5) a dropped-and-retaken head keeps its origin (create_item rebuilds items
#       from canonical database data and would otherwise launder it).
#
# Run:  godot --headless --path . res://tests/quest_proof_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const QUEST_ID := "guild_bounty_bandit_chief"
const TARGET_TEMPLATE := "bandit_chief"

var _fails := 0
var _checks := 0
var game = null


func _ready() -> void:
	TimeManager.pause_time()
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)

	# The harvest case needs the REAL Game: _drop_quest_trophies hangs off the
	# character_died connection made in Game._spawn_character. Same bootstrap as
	# law_persist_test — let the ready cascade finish first, or @onready vars on
	# the game scene stay null.
	await get_tree().process_frame
	var GameScene := load("res://game.tscn")
	game = GameScene.instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _await_frames(2)
	game.load_map("town_square")
	await _await_frames(5)

	_case_data_authored()
	_case_trophy_stamping()
	_case_proof_matching()
	_case_turn_in_consumes()
	_case_latch_is_not_trusted()
	_case_reward_offers_valid()
	await _case_harvest_from_corpse()
	await _case_origin_survives_a_drop()
	await _case_reward_screen_builds()

	print("HARNESS DONE failures=%d checks=%d" % [_fails, _checks])
	get_tree().quit(1 if _fails > 0 else 0)


func _await_frames(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame


# --- 1. the data exists and is shaped as the code expects -------------------

func _case_data_authored() -> void:
	var q: Dictionary = QuestDatabase.get_quest(QUEST_ID)
	_report("data.quest-exists", not q.is_empty(), QUEST_ID)

	var proof: Array = QuestDatabase.get_proof(QUEST_ID, "claim_bounty")
	_report("data.proof-on-stage", proof.size() == 1, str(proof))
	if proof.size() == 1:
		_report("data.proof-names-template",
			str(proof[0].get("from_template", "")) == TARGET_TEMPLATE, str(proof[0]))

	# get_all_proof must see the spec from ANY stage: you kill the target while
	# still on the "hunt" stage, and the head has to drop then.
	var all_proof: Array = QuestDatabase.get_all_proof(QUEST_ID)
	_report("data.all-proof-scans-every-stage", all_proof.size() >= 1, str(all_proof.size()))

	var item: Dictionary = ItemDatabase.get_item_data("severed_head")
	_report("data.severed-head-in-db", not item.is_empty(), "severed_head")

	# The pre-existing king quest's head had no way into the world; it now
	# declares its source so the trophy actually drops.
	var king_proof: Array = QuestDatabase.get_all_proof("king_in_the_north")
	_report("data.king-head-now-sourced",
		king_proof.size() == 1 and str(king_proof[0].get("from_template", "")) == "king_skarsgaard",
		str(king_proof))


# --- 2. build_trophy_item stamps the victim --------------------------------

func _case_trophy_stamping() -> void:
	var victim := _spawn(Vector2(400, 400))
	victim.template_id = TARGET_TEMPLATE
	victim.Name = "Ser Brannoc"
	victim.race_id = "human"

	var trophy: Dictionary = victim.build_trophy_item("severed_head")
	_report("trophy.uses-real-db-id", str(trophy.get("id", "")) == "severed_head", str(trophy.get("id")))
	var origin = trophy.get("origin", {})
	_report("trophy.origin-present", origin is Dictionary and not origin.is_empty(), str(origin))
	_report("trophy.origin-template",
		str(origin.get("template_id", "")) == TARGET_TEMPLATE, str(origin))
	_report("trophy.names-the-victim",
		str(trophy.get("display_name", "")).contains("Ser Brannoc"),
		str(trophy.get("display_name")))
	# Database fields must still be present or the item is unrenderable.
	_report("trophy.keeps-db-sprite",
		not str(trophy.get("sprite_path", "")).is_empty(), str(trophy.get("sprite_path")))
	victim.queue_free()


# --- 3. matching is identity-aware -----------------------------------------

func _case_proof_matching() -> void:
	var spec := {"item": "severed_head", "from_template": TARGET_TEMPLATE, "count": 1}

	var right := {"id": "severed_head", "origin": {"template_id": TARGET_TEMPLATE}}
	var wrong := {"id": "severed_head", "origin": {"template_id": "bandit"}}
	var unstamped := {"id": "severed_head"}
	var other_item := {"id": "longsword", "origin": {"template_id": TARGET_TEMPLATE}}

	_report("match.right-victim", QuestManager._item_matches_proof(right, spec), "")
	_report("match.rejects-wrong-victim", not QuestManager._item_matches_proof(wrong, spec), "")
	_report("match.rejects-unstamped", not QuestManager._item_matches_proof(unstamped, spec), "")
	_report("match.rejects-other-item", not QuestManager._item_matches_proof(other_item, spec), "")

	# With from_template omitted, any copy counts.
	var loose := {"item": "severed_head", "count": 1}
	_report("match.loose-spec-accepts-unstamped",
		QuestManager._item_matches_proof(unstamped, loose), "")


# --- 4. turn-in completes the quest and eats the head -----------------------

func _case_turn_in_consumes() -> void:
	_reset_quest()
	var hero := _spawn(Vector2(800, 400))
	QuestManager.start_quest(QUEST_ID)
	QuestManager.active[QUEST_ID] = "claim_bounty"

	# Wrong head first: nothing should happen.
	hero.inventory.add_item({"id": "severed_head", "display_name": "Head of a nobody",
		"origin": {"template_id": "bandit"}})
	_report("turnin.blocked-without-right-proof",
		not QuestManager.can_turn_in(QUEST_ID, hero), "")
	_report("turnin.refuses-and-changes-nothing",
		QuestManager.turn_in(QUEST_ID, hero) == false and QuestManager.active.has(QUEST_ID), "")
	_report("turnin.wrong-head-not-eaten", hero.inventory.items.size() == 1,
		str(hero.inventory.items.size()))

	# Now the real one.
	hero.inventory.add_item({"id": "severed_head", "display_name": "Head of Ser Brannoc",
		"origin": {"template_id": TARGET_TEMPLATE}})
	_report("turnin.allowed-with-proof", QuestManager.can_turn_in(QUEST_ID, hero), "")

	var offered := {"fired": false}
	var cb := func(qid: String, offers: Array, _c) -> void:
		if qid == QUEST_ID:
			offered["fired"] = true
			offered["count"] = offers.size()
	QuestManager.quest_reward_offered.connect(cb)

	var ok: bool = QuestManager.turn_in(QUEST_ID, hero)
	QuestManager.quest_reward_offered.disconnect(cb)

	_report("turnin.succeeds", ok, "")
	_report("turnin.quest-completed", QuestManager.is_quest_completed(QUEST_ID), "")
	_report("turnin.no-longer-active", not QuestManager.active.has(QUEST_ID), "")
	_report("turnin.rewards-offered", bool(offered.get("fired", false)),
		str(offered.get("count", 0)))
	# The right head is gone; the wrong one is still in the bag.
	_report("turnin.consumed-exactly-one", hero.inventory.items.size() == 1,
		str(hero.inventory.items.size()))
	if hero.inventory.items.size() == 1:
		var left: Dictionary = hero.inventory.items[0]
		_report("turnin.consumed-the-right-one",
			str(left.get("origin", {}).get("template_id", "")) == "bandit", str(left.get("origin")))
	hero.queue_free()


# --- 5. the world_state latch must not be the source of truth ---------------

func _case_latch_is_not_trusted() -> void:
	_reset_quest()
	var hero := _spawn(Vector2(1200, 400))
	QuestManager.start_quest(QUEST_ID)
	QuestManager.active[QUEST_ID] = "claim_bounty"

	# Simulate having picked the head up at some point and then lost it. This is
	# exactly the state the old item_picked:: condition would have accepted.
	Globals.world_state["item_picked::severed_head"] = true
	Globals.world_state["item_count::severed_head"] = 1

	_report("latch.empty-bag-cannot-turn-in",
		not QuestManager.can_turn_in(QUEST_ID, hero), "world_state says picked, bag is empty")
	_report("latch.turn-in-refuses", QuestManager.turn_in(QUEST_ID, hero) == false, "")

	Globals.world_state.erase("item_picked::severed_head")
	Globals.world_state.erase("item_count::severed_head")
	hero.queue_free()


# --- 6. the reward block is renderable -------------------------------------

func _case_reward_offers_valid() -> void:
	var rewards: Dictionary = QuestDatabase.get_rewards(QUEST_ID)
	var offers: Array = rewards.get("offers", [])
	_report("rewards.three-offers", offers.size() == 3, str(offers.size()))

	var kinds: Array = []
	for o in offers:
		kinds.append(str(o.get("type", "")))
	_report("rewards.covers-all-three-types",
		"money" in kinds and "item" in kinds and "training" in kinds, str(kinds))

	# Every referenced id must resolve, or the card renders blank.
	for o in offers:
		match str(o.get("type", "")):
			"item":
				var d: Dictionary = ItemDatabase.get_item_data(str(o.get("item_id", "")))
				_report("rewards.item-resolves", not d.is_empty(), str(o.get("item_id")))
			"training":
				var a: Dictionary = AbilityDatabase.get_ability_data(str(o.get("ability_id", "")))
				_report("rewards.ability-resolves", not a.is_empty(), str(o.get("ability_id")))

	# A4 regression: this method did not exist, so the Research activity's
	# random-spell outcome silently did nothing.
	_report("rewards.ability-db-has-get-all-abilities",
		AbilityDatabase.has_method("get_all_abilities"), "")
	if AbilityDatabase.has_method("get_all_abilities"):
		_report("rewards.get-all-abilities-non-empty",
			AbilityDatabase.get_all_abilities().size() > 0, "")


# --- 7. end to end: kill the target, find the head on the body --------------

func _case_harvest_from_corpse() -> void:
	_reset_quest()
	QuestManager.start_quest(QUEST_ID)

	# A bystander whose template nothing has a bounty on: the control.
	var bystander = game._spawn_character("bandit", Vector2(1400, 1400), {})
	var target = game._spawn_character(TARGET_TEMPLATE, Vector2(1500, 1500), {})
	await _await_frames(2)
	_report("harvest.target-spawned", target != null and is_instance_valid(target), "")
	if target == null:
		return

	target.take_damage({"slashing": 9999}, target.global_position)
	bystander.take_damage({"slashing": 9999}, bystander.global_position)
	await _await_frames(3)

	_report("harvest.target-dead", not target.is_alive(), "")
	_report("harvest.head-on-the-body", _has_head(target.inventory.items, TARGET_TEMPLATE),
		str(_ids(target.inventory.items)))
	# The corpse's loot view must show it — contents aliases inventory.items.
	_report("harvest.head-in-loot-view", _has_head(target.contents, TARGET_TEMPLATE),
		str(_ids(target.contents)))
	# No bounty on this one, so no trophy.
	_report("harvest.no-bounty-no-trophy",
		not _has_head(bystander.inventory.items, "bandit"), str(_ids(bystander.inventory.items)))

	# Idempotent: re-entering the corpse state on map re-entry must not re-mint.
	target.restore_dead_state()
	await _await_frames(1)
	var heads := 0
	for it in target.inventory.items:
		if it is Dictionary and str(it.get("id", "")) == "severed_head":
			heads += 1
	_report("harvest.exactly-one-head", heads == 1, str(heads))

	_reset_quest()


# --- 8. the origin survives a round trip through the world ------------------

func _case_origin_survives_a_drop() -> void:
	var origin := {"template_id": TARGET_TEMPLATE, "name": "Ser Brannoc", "race": "human"}
	var world_item = game.create_item("severed_head", Vector2(1600, 1600), 1, {
		"origin": origin.duplicate(true),
		"origin_display_name": "Severed Head of Ser Brannoc",
	})
	await _await_frames(1)

	_report("drop.world-item-created", world_item != null, "")
	if world_item == null:
		return
	_report("drop.origin-set-on-node",
		str(world_item.origin.get("template_id", "")) == TARGET_TEMPLATE, str(world_item.origin))
	# _apply_item_data must not have overwritten the per-instance name with the
	# generic database one.
	_report("drop.per-instance-name-wins",
		str(world_item.display_name) == "Severed Head of Ser Brannoc", str(world_item.display_name))

	# Picking it back up must still satisfy the bounty.
	var back: Dictionary = world_item.to_inventory_data()
	_report("drop.origin-returns-to-inventory",
		str(back.get("origin", {}).get("template_id", "")) == TARGET_TEMPLATE, str(back.get("origin")))
	_report("drop.retaken-head-still-counts",
		QuestManager._item_matches_proof(back,
			{"item": "severed_head", "from_template": TARGET_TEMPLATE, "count": 1}), "")


# --- 9. the reward screen actually builds ----------------------------------
#
# Headless is a dummy renderer so this proves nothing about how it LOOKS, but it
# does prove the tree builds, every offer resolves to a card, a bad offer is
# dropped rather than exploding, and selection emits the right dict.

func _case_reward_screen_builds() -> void:
	var offers: Array = QuestDatabase.get_rewards(QUEST_ID).get("offers", [])
	var screen = load("res://UI/QuestRewardScreen.gd").new()
	screen.setup(QUEST_ID, offers, game.player)
	_report("screen.try-open-true-with-offers", screen.try_open(), "")
	game.add_child(screen)
	await _await_frames(2)

	var row = screen._row
	_report("screen.one-card-per-offer",
		row != null and row.get_child_count() == offers.size(),
		"%d cards / %d offers" % [row.get_child_count() if row != null else -1, offers.size()])

	# Selection hands back the offer dict, once.
	var got := {"n": 0, "type": ""}
	screen.chosen.connect(func(o: Dictionary) -> void:
		got["n"] = int(got["n"]) + 1
		got["type"] = str(o.get("type", "")))
	screen._on_take(offers[0])
	screen._on_take(offers[1])   # a second click must be ignored
	_report("screen.emits-chosen-once", int(got["n"]) == 1, str(got["n"]))
	_report("screen.emits-the-right-offer",
		str(got["type"]) == str(offers[0].get("type", "")), str(got["type"]))
	screen.queue_free()

	# A junk offer is dropped, not fatal.
	var junk = load("res://UI/QuestRewardScreen.gd").new()
	junk.setup(QUEST_ID, [{"type": "nonsense"}, {"type": "money", "amount": 5}], game.player)
	_report("screen.sanitises-unknown-types", junk.offers.size() == 1, str(junk.offers))
	junk.queue_free()

	# Nothing to offer => try_open false, so the caller frees instead of showing
	# an empty document.
	var empty = load("res://UI/QuestRewardScreen.gd").new()
	empty.setup(QUEST_ID, [], game.player)
	_report("screen.try-open-false-when-empty", not empty.try_open(), "")
	empty.queue_free()

	# And the applier honours each type.
	# A hand item (Winter's Grip is a Main Hand weapon) is stowed as a weapon,
	# as a pick-up is, so it lands in stowed_items rather than items.
	var inv = game.player.inventory
	var before: int = inv.items.size() + inv.stowed_items.size()
	game._apply_quest_reward({"type": "item", "item_id": "winters_grip"}, game.player)
	var after: int = inv.items.size() + inv.stowed_items.size()
	_report("screen.item-reward-lands", after > before, "%d -> %d" % [before, after])

	TrainingManager.commitments.clear()
	game._apply_quest_reward(
		{"type": "training", "ability_id": "shield_bash", "base_days": 3}, game.player)
	_report("screen.training-reward-books-days",
		TrainingManager.has_open_commitment(game.player), "")
	_report("screen.training-reward-grants-nothing-yet",
		not TrainingManager.knows_ability(game.player, "shield_bash"), "")
	TrainingManager.commitments.clear()


# --- helpers ----------------------------------------------------------------

func _has_head(pool, template_id: String) -> bool:
	if not (pool is Array):
		return false
	for it in pool:
		if not (it is Dictionary):
			continue
		if str(it.get("id", "")) != "severed_head":
			continue
		if str(it.get("origin", {}).get("template_id", "")) == template_id:
			return true
	return false


func _ids(pool) -> Array:
	var out: Array = []
	if pool is Array:
		for it in pool:
			if it is Dictionary:
				out.append(str(it.get("id", "?")))
	return out


func _reset_quest() -> void:
	QuestManager.active.erase(QUEST_ID)
	QuestManager.completed.erase(QUEST_ID)
	QuestManager.failed.erase(QUEST_ID)


func _spawn(pos: Vector2) -> ProceduralCharacter:
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	c.is_player_controlled = true   # keep the AI FSM out of the way
	add_child(c)
	c.global_position = pos
	c.hold_position = true
	return c


func _report(check_name: String, ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("%s %s: %s" % ["PASS" if ok else "FAIL", check_name, detail])
