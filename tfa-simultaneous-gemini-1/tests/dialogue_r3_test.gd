# res://tests/dialogue_r3_test.gd
# Headless harness for the dialogue action API (Global/DialogueActions.gd,
# docs/dialogue_actions.md) and Federica's restored actions.
#
# Drives the REAL game scene on the cemetery map (as law_persist_test does), so
# spawns, party changes, the dialogue panel, hostility and the law all run
# through the real Game. The game is kept paused between steps so spawned
# fighters don't change the state being checked.
#
# The contract under test:
#   (1) Dialogues.json validates clean; a broken dialogue's problems are all
#       reported at load, and bad actions are skipped without ending the talk,
#   (2) every action type does what it says and says so (log line / floating
#       text) when the party is involved,
#   (3) every check type, choice "requires" (greyed out with a reason) and
#       "show_if" (hidden), array branches, on_enter, "once",
#   (4) hostility only through FactionDatabase relations; crimes and pardons
#       through CrimeManager; runtime factions survive a save round trip,
#   (5) Federica: the fight, the guard patrol, the interrogation's guards, the
#       trophies she bags, the Subtle trait for slipping away.
#
# Run:  godot --headless --path . res://tests/dialogue_r3_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

var failures := 0
var checks := 0
var game = null
var api = null
var P = null   # the protagonist
var _faction_snapshot: Dictionary = {}


func _check(check_name: String, cond: bool, detail: String = "") -> void:
	checks += 1
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])


func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame


func _ready() -> void:
	TimeManager.pause_time()
	await get_tree().process_frame
	game = load("res://game.tscn").instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _frames(2)
	game.load_map("cemetery")
	await _frames(6)
	PauseManager.pause()
	api = DialogueManager.actions_api
	P = game.player
	_faction_snapshot = FactionDatabase.standing_to_dict()

	_case_validation()
	await _case_failures_never_crash()
	_case_flags()
	_case_quests()
	_case_items_and_gold()
	await _case_characters()
	await _case_party()
	await _case_combat_pause()
	_case_factions()
	_case_law()
	_case_conversation_actions()
	await _case_choices_and_branches()
	await _case_federica_fight()
	await _case_federica_guard_patrol()
	await _case_federica_interrogation()
	await _case_federica_quiet_exits()

	print("HARNESS DONE failures=%d checks=%d" % [failures, checks])
	get_tree().quit(1 if failures > 0 else 0)


# --- helpers -------------------------------------------------------------------

func _log_n() -> int:
	return GameLog.get_entries().size()


func _logs_since(n: int) -> Array:
	var out: Array = []
	var entries: Array = GameLog.get_entries()
	for i in range(n, entries.size()):
		out.append(str(entries[i].get("text", "")))
	return out


func _logged(n: int, needle: String) -> bool:
	for t in _logs_since(n):
		if t.contains(needle):
			return true
	return false


func _reset_dialogue() -> void:
	DialogueManager._pending_dialogues.clear()
	if DialogueManager.is_active():
		DialogueManager.end_dialogue()
	DialogueManager._pending_dialogues.clear()
	api.pause_requested = false


func _spawn(template: String, offset: Vector2, faction: String = "") -> Node:
	var ov: Dictionary = {}
	if faction != "":
		ov["faction"] = faction
	var c = game._spawn_character(template, P.global_position + offset, ov)
	c.AI_enabled = true
	c.visible = true
	return c


func _despawn_all_npcs_except(keep: Array = []) -> void:
	for c in game.characters_in_scene.duplicate():
		if is_instance_valid(c) and not c in game.party_chars and not c in keep:
			game.despawn_character(c)


func _tagged(tag: String) -> Array:
	var out: Array = []
	for c in game.characters_in_scene:
		if is_instance_valid(c) and tag in c.get_meta("dialogue_tags", []):
			out.append(c)
	return out


func _item_names(c) -> Array:
	var out: Array = []
	for it in c.inventory.items:
		out.append(str(it.get("display_name", it.get("id", ""))))
	return out


func _run(action: Dictionary) -> bool:
	return api.run(action, "test")


## Advance through the current node's lines until choices appear or the
## conversation ends.
func _advance_to_rest() -> void:
	var guard := 0
	while DialogueManager.is_active() and DialogueManager.current_choices.is_empty() and guard < 60:
		DialogueManager.advance_line()
		guard += 1


func _play_node(dialogue_id: String, node_id: String, npc_name: String = "") -> void:
	_reset_dialogue()
	DialogueManager.start_dialogue(dialogue_id, npc_name)
	DialogueManager.show_node(node_id)
	_advance_to_rest()


func _restore_factions() -> void:
	FactionDatabase.standing_from_dict(_faction_snapshot)


# --- 1. validation ---------------------------------------------------------------

func _case_validation() -> void:
	var problems: Array = api.validate_all(DialogueManager.dialogues)
	_check("validate.shipped-dialogues-clean", problems.is_empty(), str(problems))

	var bad := {"t": {"dialogueNodes": {
		"n": {
			"narrator": "x",
			"on_enter": [{"type": "set_flag"}],
			"actions": [{"type": "strat_combat"}, {"type": "give_item"}, {"type": "give_item", "item": "no_such_item"},
				{"type": "spawn", "template": "nobody", "at": [0, 0]}, {"type": "set_relation", "faction": "waldau", "other": "liziti", "relation": "frenemy"},
				{"type": "report_crime", "statute": "jaywalking"}, {"type": "start_dialogue", "dialogue": "no_such_dialogue"}],
			"branch": [{"if": {"type": "flag", "flag": "x"}, "next": "missing"}, {"no_next": true}],
			"choices": [{"text": "a", "requires": [{"type": "has_gold"}], "show_if": {"type": "ability_check", "stat": "charisma"}},
				{"text": "b", "requires": {"type": "quest", "quest": "tutorial_quest", "state": "sideways"}},
				{"text": "c", "show_if": {"type": "flgx", "flag": "x"}}],
		}}}}
	var found: Array = api.validate_all(bad)
	var joined: String = "\n".join(found)
	for needle in ["on_enter #1 set_flag: missing 'flag'", "unknown action type 'strat_combat'", "give_item: missing 'item'",
			"no item 'no_such_item'", "spawn: no template 'nobody'", "relation must be one of", "no statute 'jaywalking'",
			"no dialogue 'no_such_dialogue'", "no node 'missing'", "each entry needs \"next\"", "has_gold: missing 'amount'",
			"ability_check rolls dice", "quest: state must be one of", "unknown check type"]:
		_check("validate.reports " + needle, joined.contains(needle), joined)


# --- 1b. bad actions never end a conversation ----------------------------------

func _case_failures_never_crash() -> void:
	_reset_dialogue()
	Globals.world_state.erase("r3_after_bad")
	DialogueManager.dialogues["r3_bad"] = {"dialogueNodes": {
		"r3_bad": {
			"narrator": "Bad things follow.",
			"actions": [{"type": "nope"}, {"type": "give_item"}, {"type": "give_item", "item": "zzz_none"},
				{"type": "heal", "who": "Nobody By This Name"}, 42, {"type": "start_combat", "attackers": "protagonist"},
				{"type": "set_flag", "flag": "r3_after_bad"}],
			"next": "r3_bad_after",
		},
		"r3_bad_after": {"narrator": "Still talking."},
	}}
	DialogueManager.start_dialogue("r3_bad")
	DialogueManager.advance_line()
	_check("robust.conversation-continues", DialogueManager.is_active() and DialogueManager.current_node_id == "r3_bad_after",
		"%s %s" % [DialogueManager.is_active(), DialogueManager.current_node_id])
	_check("robust.good-action-after-bad-ones-ran", Globals.world_state.get("r3_after_bad", false) == true)
	_check("robust.unknown-type-refused", not _run({"type": "nope"}))
	_check("robust.missing-field-refused", not _run({"type": "give_item"}))
	_check("robust.unknown-item-refused", not _run({"type": "give_item", "item": "zzz_none"}))
	_check("robust.nobody-refused", not _run({"type": "heal", "who": "Nobody By This Name"}))
	_check("robust.party-not-turned", not _run({"type": "start_combat", "attackers": "protagonist"}))
	_check("robust.unknown-check-unmet", not api.check({"type": "nope"}))
	DialogueManager.dialogues.erase("r3_bad")
	_reset_dialogue()
	await get_tree().process_frame


# --- 2. world state ------------------------------------------------------------------

func _case_flags() -> void:
	for k in ["r3_flag", "r3_count", "flag::%s::met" % str(P.template_id)]:
		Globals.world_state.erase(k)
	_check("flag.unset-is-unmet", not api.check({"type": "flag", "flag": "r3_flag"}))
	_check("flag.set", _run({"type": "set_flag", "flag": "r3_flag"}) and Globals.world_state.get("r3_flag") == true)
	_check("flag.set-is-met", api.check({"type": "flag", "flag": "r3_flag"}))
	_run({"type": "set_flag", "flag": "r3_flag", "value": "spared"})
	_check("flag.equals", api.check({"type": "flag", "flag": "r3_flag", "equals": "spared"})
		and not api.check({"type": "flag", "flag": "r3_flag", "equals": "killed"}))
	_run({"type": "add_to_flag", "flag": "r3_count", "amount": 2})
	_run({"type": "add_to_flag", "flag": "r3_count", "amount": 3})
	_check("flag.add", int(Globals.world_state.get("r3_count", 0)) == 5, str(Globals.world_state.get("r3_count")))
	_check("flag.at-least", api.check({"type": "flag", "flag": "r3_count", "at_least": 5})
		and not api.check({"type": "flag", "flag": "r3_count", "at_most": 4}))
	_check("flag.not", api.check({"type": "flag", "flag": "r3_count", "at_least": 6, "not": true}))
	# world_state mixes numbers, text and bools: checks compare them without a
	# script error ("int != bool"), and "equals" matches 3 and "3" alike.
	Globals.world_state["r3_num"] = 3
	Globals.world_state["r3_text"] = "spared"
	Globals.world_state["r3_zero"] = 0
	_check("flag.bare-number", api.check({"type": "flag", "flag": "r3_num"}) and not api.check({"type": "flag", "flag": "r3_zero"}))
	_check("flag.bare-text", api.check({"type": "flag", "flag": "r3_text"}))
	_check("flag.equals-across-types", api.check({"type": "flag", "flag": "r3_num", "equals": "3"})
		and api.check({"type": "flag", "flag": "r3_num", "equals": 3.0})
		and not api.check({"type": "flag", "flag": "r3_text", "equals": 3})
		and not api.check({"type": "flag", "flag": "r3_num", "equals": true}))
	_check("flag.range-on-text-and-bool", not api.check({"type": "flag", "flag": "r3_text", "at_least": 1})
		and api.check({"type": "flag", "flag": "r3_zero", "at_most": 0}))
	for k in ["r3_num", "r3_text", "r3_zero"]:
		Globals.world_state.erase(k)
	_run({"type": "clear_flag", "flag": "r3_flag"})
	_check("flag.clear", not Globals.world_state.has("r3_flag"))
	_run({"type": "set_flag", "flag": "met", "who": "protagonist"})
	_check("flag.per-character-key", Globals.world_state.get("flag::%s::met" % str(P.template_id)) == true,
		str(Globals.world_state.keys()))
	_check("flag.per-character-check", api.check({"type": "flag", "flag": "met", "who": "protagonist"})
		and not api.check({"type": "flag", "flag": "met"}))

	# any / all, and the reason an "all" gives for a greyed-out option.
	var unset := {"type": "flag", "flag": "r3_never_set"}
	var five := {"type": "flag", "flag": "r3_count", "at_least": 5}
	_check("check.any", api.check({"type": "any", "of": [unset, five]}) and not api.check({"type": "any", "of": [unset]}))
	_check("check.all", api.check({"type": "all", "of": [five]}) and not api.check({"type": "all", "of": [unset, five]}))
	_check("check.all-reason", api.unmet_reason({"type": "all", "of": [{"type": "has_gold", "amount": 100000}]}) == "Needs 100000 gold",
		api.unmet_reason({"type": "all", "of": [{"type": "has_gold", "amount": 100000}]}))
	# A dice check in a branch rolls for real and says so.
	var n0 := _log_n()
	var rolled = api.check({"type": "ability_check", "stat": "charisma", "advantages": ["Subtle"]})
	_check("check.ability-roll", rolled is bool)
	_check("check.ability-roll-logged", _logged(n0, " a Charisma check (rolled "), str(_logs_since(n0)))


# --- 2. quests -----------------------------------------------------------------------

func _fresh_quest(qid: String) -> void:
	QuestManager.active.erase(qid)
	QuestManager.completed.erase(qid)
	QuestManager.failed.erase(qid)


func _case_quests() -> void:
	var qid := "rats_hostage_sausage"
	_fresh_quest(qid)
	_check("quest.not-started", api.check({"type": "quest", "quest": qid, "state": "not_started"}))
	var n0 := _log_n()
	_check("quest.start", _run({"type": "start_quest", "quest": qid}) and QuestManager.is_quest_active(qid))
	_check("quest.start-logged", _logged(n0, "Quest started: The Rats Are Making Hostage Sausage"), str(_logs_since(n0)))
	n0 = _log_n()
	_check("quest.set-stage", _run({"type": "set_quest_stage", "quest": qid, "stage": "kill_capo"})
		and str(QuestManager.active.get(qid, "")) == "kill_capo")
	_check("quest.stage-logged", _logged(n0, "The Rats Are Making Hostage Sausage: Cut Down the Vermincelli Capo"), str(_logs_since(n0)))
	_check("quest.check-stage", api.check({"type": "quest", "quest": qid, "state": "active", "stage": "kill_capo"}))
	_check("quest.bad-stage-refused", not _run({"type": "set_quest_stage", "quest": qid, "stage": "no_such_stage"}))
	n0 = _log_n()
	_check("quest.complete", _run({"type": "complete_quest", "quest": qid}) and QuestManager.is_quest_completed(qid))
	_check("quest.complete-logged", _logged(n0, "Quest complete: The Rats Are Making Hostage Sausage"))
	_check("quest.check-completed", api.check({"type": "quest", "quest": qid, "state": "completed"}))

	var fq := "cheese_it"
	_fresh_quest(fq)
	_run({"type": "start_quest", "quest": fq})
	n0 = _log_n()
	_check("quest.fail", _run({"type": "fail_quest", "quest": fq, "reason": "The cheesemonger was eaten."})
		and QuestManager.is_quest_failed(fq))
	_check("quest.fail-reason-logged", _logged(n0, "Quest failed: Cheese It! — The cheesemonger was eaten."), str(_logs_since(n0)))
	_check("quest.check-failed", api.check({"type": "quest", "quest": fq, "state": "failed"}))
	_check("quest.unknown-refused", not _run({"type": "start_quest", "quest": "no_such_quest"}))

	# Completing a quest with rewards offers them, as a turn-in does.
	var bq := "guild_bounty_bandit_chief"
	_fresh_quest(bq)
	var offered: Array = []
	var cb := func(q, offers, _c): offered.append([q, offers])
	QuestManager.quest_reward_offered.connect(cb)
	_run({"type": "complete_quest", "quest": bq})
	QuestManager.quest_reward_offered.disconnect(cb)
	_check("quest.complete-offers-rewards", offered.size() == 1 and (offered[0][1] as Array).size() == 3, str(offered))
	var screen = game.get_node_or_null("QuestRewardScreen")
	if screen != null:
		screen.queue_free()

	# Turn-in without the proof is refused and said.
	_fresh_quest(bq)
	_run({"type": "start_quest", "quest": bq})
	_run({"type": "set_quest_stage", "quest": bq, "stage": "claim_bounty"})
	_check("quest.cannot-turn-in-check", not api.check({"type": "can_turn_in", "quest": bq}))
	n0 = _log_n()
	_check("quest.turn-in-refused", not _run({"type": "turn_in_quest", "quest": bq}) and QuestManager.is_quest_active(bq))
	_check("quest.turn-in-refusal-said", _logged(n0, "doesn't have what A Guild Bounty: The Bandit Chief asks for"), str(_logs_since(n0)))
	_fresh_quest(bq)


# --- 2. items and gold ------------------------------------------------------------------

func _case_items_and_gold() -> void:
	var item := "potion_of_healing"
	var before: int = api._count_items([P], item)
	var n0 := _log_n()
	_check("item.give", _run({"type": "give_item", "item": item, "count": 2}) and api._count_items([P], item) == before + 2,
		"%d -> %d" % [before, api._count_items([P], item)])
	_check("item.give-said", _logged(n0, "%s receives Potion of Healing (x2)." % P.Name), str(_logs_since(n0)))
	_check("item.has-check", api.check({"type": "has_item", "who": "protagonist", "item": item, "count": before + 2}))
	_check("item.has-check-party-pool", api.check({"type": "has_item", "item": item, "count": before + 2}))
	n0 = _log_n()
	_check("item.take", _run({"type": "take_item", "item": item, "from": "protagonist"}) and api._count_items([P], item) == before + 1)
	_check("item.take-said", _logged(n0, "%s loses Potion of Healing." % P.Name), str(_logs_since(n0)))
	n0 = _log_n()
	_check("item.take-too-many-refused", not _run({"type": "take_item", "item": item, "count": 999, "from": "protagonist"})
		and api._count_items([P], item) == before + 1)
	_check("item.take-too-many-said", _logged(n0, "doesn't have 999 x Potion of Healing"), str(_logs_since(n0)))

	var npc = _spawn("town_guard", Vector2(70, 0))
	var npc_name: String = str(npc.Name)
	_check("item.give-named-to-npc", _run({"type": "give_item", "item": "bones", "to": npc_name, "name": "Arms of Test"})
		and "Arms of Test" in _item_names(npc), str(_item_names(npc)))
	n0 = _log_n()
	_check("item.hand-over", _run({"type": "take_item", "item": item, "from": "protagonist", "to": npc_name})
		and api._count_items([npc], item) >= 1 and api._count_items([P], item) == before)
	_check("item.hand-over-said", _logged(n0, "%s gives Potion of Healing to %s." % [P.Name, npc_name]), str(_logs_since(n0)))

	# Weapons are nodes (held or stowed), not pack items: has_item and
	# take_item still see them, and a hand-over stows it on the receiver.
	var weapon := "handaxe"
	var w0: int = api._count_items([P], weapon)
	var nw0: int = api._count_items([npc], weapon)
	_check("weapon.give-stowed", _run({"type": "give_item", "item": weapon}) and api._count_items([P], weapon) == w0 + 1,
		"%d -> %d" % [w0, api._count_items([P], weapon)])
	_check("weapon.has-check", api.check({"type": "has_item", "who": "protagonist", "item": weapon, "count": w0 + 1}))
	n0 = _log_n()
	_check("weapon.hand-over", _run({"type": "take_item", "item": weapon, "from": "protagonist", "to": npc_name})
		and api._count_items([P], weapon) == w0 and api._count_items([npc], weapon) == nw0 + 1)
	_check("weapon.hand-over-said", _logged(n0, "%s gives Handaxe to %s." % [P.Name, npc_name]), str(_logs_since(n0)))
	var held = npc.inventory.main_hand_item
	if held is WeaponShape and api._item_known(str(held.id)):
		var hid: String = str(held.id)
		var have_n: int = api._count_items([npc], hid)
		_check("weapon.take-from-hand", _run({"type": "take_item", "item": hid, "from": npc_name, "count": have_n})
			and api._count_items([npc], hid) == 0 and npc.inventory.main_hand_item == null
			and npc.inventory.items.all(func(it): return str(it.get("id", "")) != hid),
			"%s left %d" % [hid, api._count_items([npc], hid)])

	var gold_before: int = api._count_items([P], "gold")
	n0 = _log_n()
	_check("gold.give", _run({"type": "give_gold", "amount": 25}) and api._count_items([P], "gold") == gold_before + 25)
	_check("gold.give-said", _logged(n0, "%s receives 25 gold." % P.Name), str(_logs_since(n0)))
	_check("gold.has-check", api.check({"type": "has_gold", "who": "protagonist", "amount": gold_before + 25})
		and not api.check({"type": "has_gold", "who": "protagonist", "amount": gold_before + 26}))
	n0 = _log_n()
	_check("gold.pay", _run({"type": "take_gold", "amount": 10, "from": "protagonist", "to": npc_name})
		and api._count_items([P], "gold") == gold_before + 15 and api._count_items([npc], "gold") >= 10)
	_check("gold.pay-said", _logged(n0, "%s pays 10 gold to %s." % [P.Name, npc_name]), str(_logs_since(n0)))
	n0 = _log_n()
	_check("gold.cannot-pay-refused", not _run({"type": "take_gold", "amount": 1000000}))
	_check("gold.cannot-pay-said", _logged(n0, "can't pay 1000000 gold"), str(_logs_since(n0)))
	_run({"type": "take_gold", "amount": 15, "from": "protagonist"})
	game.despawn_character(npc)


# --- 2. characters -------------------------------------------------------------------------

func _case_characters() -> void:
	var gate: Vector2 = Vector2(20, 300)
	var before: int = game.characters_in_scene.size()
	_check("spawn.at-marker", _run({"type": "spawn", "template": "town_guard", "count": 2, "at": "to_town_square",
		"tag": "squad", "name": ["Sergeant"]}))
	var squad: Array = _tagged("squad")
	_check("spawn.count-and-tag", squad.size() == 2 and game.characters_in_scene.size() == before + 2, "%d" % squad.size())
	var names: Array = []
	for c in squad:
		names.append(str(c.Name))
	_check("spawn.named-in-order", "Sergeant" in names and "Town Guard" in names, str(names))
	# The cemetery's town gate sits in a wall block: they stand on the nearest
	# open ground, each on a tile of their own.
	var near_gate := true
	for c in squad:
		near_gate = near_gate and c.global_position.distance_to(gate) < 260.0
		near_gate = near_gate and GridManager.grid_costs.get(GridManager.world_to_map(c.global_position), INF) != INF
	_check("spawn.at-the-gate", near_gate, str(squad.map(func(c): return c.global_position)))
	_check("spawn.not-stacked", squad.size() == 2 and squad[0].global_position.distance_to(squad[1].global_position) > 16.0,
		str(squad.map(func(c): return c.global_position)))
	_check("spawn.ai-and-cone", squad.all(func(c): return c.AI_enabled and c.get_node_or_null("NPCLineOfSight") != null))
	_check("spawn.ordinal-out-of-map-range", squad.all(func(c): return int(c.get_meta("spawn_ordinal", 0)) >= 10000))

	_run({"type": "spawn", "template": "town_guard", "near": "protagonist", "tag": "near_squad"})
	var near: Array = _tagged("near_squad")
	_check("spawn.near-someone", near.size() == 1 and near[0].global_position.distance_to(P.global_position) < 140.0,
		str(near.map(func(c): return c.global_position.distance_to(P.global_position))))
	# Aimed at the leader's own tile, a spawn lands beside the party, not on it.
	_run({"type": "spawn", "template": "town_guard", "at": [P.global_position.x, P.global_position.y], "tag": "on_top"})
	var on_top: Array = _tagged("on_top")
	var party_tiles: Array = game.party_chars.map(func(c): return GridManager.world_to_map(c.global_position))
	_check("spawn.not-on-anyone", on_top.size() == 1 and not GridManager.world_to_map(on_top[0].global_position) in party_tiles
		and on_top[0].global_position.distance_to(P.global_position) < 200.0,
		str(on_top.map(func(c): return c.global_position)) + " vs " + str(P.global_position))
	_check("spawn.unknown-template-refused", not _run({"type": "spawn", "template": "nobody_at_all", "at": [0, 0]}))
	_check("spawn.unknown-marker-refused", not _run({"type": "spawn", "template": "town_guard", "at": "nowhere_marker"}))

	_check("ref.whole-word-name", api._chars("sergeant").size() == 1)
	_check("ref.tag", api._chars("tag:squad").size() == 2)
	_check("present.check", api.check({"type": "present", "who": "Sergeant"}) and not api.check({"type": "present", "who": "Nobody Else"}))

	var dest: Vector2 = P.global_position + Vector2(200, 120)
	_check("teleport", _run({"type": "teleport", "who": "tag:squad", "to": [dest.x, dest.y]})
		and squad.all(func(c): return c.global_position.distance_to(dest) < 80.0))
	var sergeant = api._first("Sergeant")
	_check("walk-to.path", _run({"type": "walk_to", "who": "Sergeant", "to": "protagonist"})
		and not sergeant.get_node("AI").nav_path.is_empty())

	_check("set-faction", _run({"type": "set_faction", "who": "Sergeant", "faction": "waldau"}) and sergeant.faction_id == "waldau")
	var n0 := _log_n()
	_check("make-hostile", _run({"type": "make_hostile", "who": "Sergeant"}))
	_check("make-hostile.runtime-faction", FactionDatabase.is_runtime_faction(sergeant.faction_id), sergeant.faction_id)
	_check("make-hostile.oracle", FactionDatabase.are_hostile("player", sergeant.faction_id) and sergeant.is_hostile_to_party())
	_check("make-hostile.ai-agrees", sergeant.get_node("AI")._is_enemy(P))
	_check("make-hostile.old-comrades-friendly", not FactionDatabase.are_hostile(sergeant.faction_id, "waldau"))
	_check("make-hostile.check", api.check({"type": "hostile", "a": "Sergeant", "b": "party"}))
	if game.is_seen_by_party(sergeant):
		_check("make-hostile.said", _logged(n0, "Sergeant turns hostile."), str(_logs_since(n0)))
	n0 = _log_n()
	_check("make-peaceful", _run({"type": "make_peaceful", "who": "Sergeant"}) and sergeant.faction_id == "golden_guard"
		and not sergeant.is_hostile_to_party(), sergeant.faction_id)
	if game.is_seen_by_party(sergeant):
		_check("make-peaceful.said", _logged(n0, "Sergeant stands down."), str(_logs_since(n0)))

	# Conditions, health, traits, favour: the party hears about all of it.
	var cid := "blessed"
	n0 = _log_n()
	_check("condition.apply", _run({"type": "apply_condition", "who": "protagonist", "condition": cid})
		and P.get_node("ConditionManager").has_condition(cid))
	_check("condition.apply-said", _logged(n0, "%s is now Blessed." % P.Name), str(_logs_since(n0)))
	_check("condition.check", api.check({"type": "has_condition", "who": "protagonist", "condition": cid}))
	n0 = _log_n()
	_check("condition.remove", _run({"type": "remove_condition", "who": "protagonist", "condition": cid})
		and not P.get_node("ConditionManager").has_condition(cid))
	_check("condition.remove-said", _logged(n0, "%s is no longer Blessed." % P.Name), str(_logs_since(n0)))
	_check("condition.unknown-refused", not _run({"type": "apply_condition", "who": "protagonist", "condition": "no_such_condition"}))

	var hp0: int = P.current_health
	n0 = _log_n()
	_check("damage", _run({"type": "damage", "who": "protagonist", "amount": 3}) and P.current_health < hp0,
		"%d -> %d" % [hp0, P.current_health])
	_check("damage-said", _logged(n0, "%s takes " % P.Name) and _logged(n0, "bludgeoning damage."), str(_logs_since(n0)))
	n0 = _log_n()
	_check("heal-full", _run({"type": "heal", "who": "protagonist"}) and P.current_health == P.max_health)
	_check("heal-said", _logged(n0, "%s recovers " % P.Name), str(_logs_since(n0)))

	var t0: int = int(P.traits.get("Stubborn", 0))
	n0 = _log_n()
	_check("trait.add", _run({"type": "add_trait", "who": "protagonist", "trait": "Stubborn"}) and int(P.traits.get("Stubborn", 0)) == t0 + 1)
	_check("trait.add-said", _logged(n0, "%s gains the Stubborn trait (now %d)." % [P.Name, t0 + 1]), str(_logs_since(n0)))
	_check("trait.check", api.check({"type": "has_trait", "who": "protagonist", "trait": "Stubborn", "at_least": t0 + 1}))
	n0 = _log_n()
	_check("trait.remove", _run({"type": "remove_trait", "who": "protagonist", "trait": "Stubborn"}) and not P.traits.has("Stubborn"))
	_check("trait.remove-said", _logged(n0, "%s loses the Stubborn trait." % P.Name), str(_logs_since(n0)))
	if t0 > 0:
		P.traits["Stubborn"] = t0

	var companion = null
	for c in game.party_chars:
		if c != P:
			companion = c
			break
	if companion != null:
		var f0: int = companion.favorability
		n0 = _log_n()
		_check("favor.change", _run({"type": "change_favor", "who": str(companion.Name), "amount": 3}) and companion.favorability == f0 + 3)
		_check("favor.said", _logged(n0, "%s approves (+3 favour" % companion.Name), str(_logs_since(n0)))
		_check("favor.check", api.check({"type": "favor", "who": str(companion.Name), "at_least": f0 + 3}))
		companion.favorability = f0

	_check("set-dialogue", _run({"type": "set_dialogue", "who": "Sergeant", "dialogue": "guard_greet"})
		and sergeant.dialogues == ["guard_greet"] and Globals.world_state.get("dialogue_for::town_guard") == "guard_greet")
	sergeant.dialogues = []
	DialogueManager._on_map_loaded("cemetery")
	_check("set-dialogue.survives-map-load", sergeant.dialogues == ["guard_greet"], str(sergeant.dialogues))
	_check("set-dialogue.unknown-refused", not _run({"type": "set_dialogue", "who": "Sergeant", "dialogue": "no_such_dialogue"}))
	Globals.world_state.erase("dialogue_for::town_guard")

	_check("tag", _run({"type": "tag", "who": "Sergeant", "tag": "chief"}) and api._chars("tag:chief") == [sergeant])

	n0 = _log_n()
	_check("despawn", _run({"type": "despawn", "who": "tag:near_squad"}) and _tagged("near_squad").is_empty())
	_check("despawn.party-refused", not _run({"type": "despawn", "who": "protagonist"}) and P in game.characters_in_scene)
	_despawn_all_npcs_except()
	await get_tree().process_frame


func _case_party() -> void:
	var recruit = _spawn("town_guard", Vector2(60, 40))
	recruit.Name = "Recruit"
	recruit.display_name = "Recruit"
	var rows0: int = game.party_state.size()
	var size0: int = game.party_chars.size()
	_check("party.in-party-check-before", not api.check({"type": "in_party", "who": "Recruit"}))
	var n0 := _log_n()
	_check("party.join", _run({"type": "join_party", "who": "Recruit"}) and recruit in game.party_chars
		and game.party_state.size() == rows0 + 1 and recruit.faction_id == "player")
	_check("party.join-row", int(recruit.get_meta("party_index", -1)) == rows0
		and str(game.party_state[rows0].get("template_id")) == "town_guard"
		and str(game.party_state[rows0].get("overrides", {}).get("unique_name", "")) == "Recruit", str(game.party_state[rows0]))
	_check("party.join-said", _logged(n0, "Recruit joins the party."), str(_logs_since(n0)))
	_check("party.join-sight-cone", recruit.get_node_or_null("LineOfSight") != null)
	_check("party.is-party-member", recruit.is_party_member() and api.check({"type": "in_party", "who": "Recruit"}))
	await _frames(2)
	n0 = _log_n()
	_check("party.leave", _run({"type": "leave_party", "who": "Recruit"}) and not recruit in game.party_chars
		and game.party_state.size() == rows0 and game.party_chars.size() == size0)
	_check("party.leave-faction-restored", recruit.faction_id == "golden_guard", recruit.faction_id)
	_check("party.leave-said", _logged(n0, "Recruit leaves the party."), str(_logs_since(n0)))
	_check("party.leader-cannot-leave", not _run({"type": "leave_party", "who": "protagonist"}) and P in game.party_chars)
	var ok_rows := true
	for i in range(game.party_chars.size()):
		var c = game.party_chars[i]
		ok_rows = ok_rows and int(c.get_meta("party_index", i)) < game.party_state.size()
	_check("party.rows-consistent", ok_rows)
	game.despawn_character(recruit)
	Globals.world_state.erase("in_party::town_guard")
	await _frames(2)

	# A character the maps place once (Deputy Gleg) who joins the party isn't
	# also standing where the map put him after the next map load; a recruited
	# town guard doesn't empty every guardhouse.
	var gleg = _spawn("deputy_gleg", Vector2(60, -40))
	_run({"type": "join_party", "who": str(gleg.Name)})
	var placed_copy = _spawn("deputy_gleg", Vector2(300, 0))
	var guard = _spawn("town_guard", Vector2(300, 60))
	Globals.world_state["in_party::town_guard"] = true
	DialogueManager._on_map_loaded("cemetery")
	_check("party.recruit-not-duplicated", not placed_copy in game.characters_in_scene and gleg in game.party_chars)
	_check("party.generic-recruit-hides-nobody", guard in game.characters_in_scene)
	Globals.world_state.erase("in_party::town_guard")
	_run({"type": "leave_party", "who": str(gleg.Name)})
	_check("party.leave-clears-recruit-mark", not Globals.world_state.has("in_party::deputy_gleg"))
	game.despawn_character(gleg)
	game.despawn_character(guard)
	await _frames(2)


func _case_combat_pause() -> void:
	_reset_dialogue()
	var foe = _spawn("town_guard", Vector2(90, 0), "waldau")
	foe.Name = "Rationalist"
	foe.display_name = "Rationalist"
	DialogueManager.dialogues["r3_fight"] = {"dialogueNodes": {"r3_fight": {
		"Rationalist": "You have seen too much.",
		"actions": [{"type": "start_combat", "attackers": "partner"}],
	}}}
	PauseManager.unpause()
	var n0 := _log_n()
	DialogueManager.start_dialogue("r3_fight", "Rationalist")
	_check("combat.partner-resolved", DialogueManager.get_partner() == foe)
	_advance_to_rest()
	_check("combat.ended", not DialogueManager.is_active())
	_check("combat.hostile", foe.is_hostile_to_party() and foe.get_node("AI")._is_enemy(P))
	_check("combat.alerted", float(foe.get_node("AI").alertness_value) >= 60.0, str(foe.get_node("AI").alertness_value))
	_check("combat.said", _logged(n0, "Combat! Rationalist attacks you."), str(_logs_since(n0)))
	_check("combat.paused-when-talk-ends", PauseManager.is_paused)
	PauseManager.pause()
	DialogueManager.dialogues.erase("r3_fight")
	game.despawn_character(foe)
	_restore_factions()
	await _frames(2)


# --- 2. factions and the law -------------------------------------------------------------

func _case_factions() -> void:
	var n0 := _log_n()
	_check("standing.change", _run({"type": "change_standing", "faction": "waldau", "amount": -60})
		and FactionDatabase.get_player_standing("waldau") == -60)
	_check("standing.said", _logged(n0, "Standing with Waldau: -60 (now -60). They are now hostile to you."), str(_logs_since(n0)))
	_check("standing.checks", api.check({"type": "stance", "faction": "waldau", "is": "hostile"})
		and api.check({"type": "standing", "faction": "waldau", "at_most": -50})
		and not api.check({"type": "standing", "faction": "waldau", "at_least": 0}))
	n0 = _log_n()
	_run({"type": "change_standing", "faction": "waldau", "amount": 60})
	_check("standing.recovered-said", _logged(n0, "They are now neutral."), str(_logs_since(n0)))

	_check("relation.before", not FactionDatabase.are_hostile("golden_guard", "waldau"))
	n0 = _log_n()
	_check("relation.enemy", _run({"type": "set_relation", "faction": "golden_guard", "other": "waldau", "relation": "enemy"})
		and FactionDatabase.are_hostile("golden_guard", "waldau") and FactionDatabase.are_hostile("waldau", "golden_guard"))
	_check("relation.said", _logged(n0, "Golden Guard and Waldau are now enemies."), str(_logs_since(n0)))
	_check("relation.check", api.check({"type": "hostile", "a": "golden_guard", "b": "waldau"}))
	var saved: Dictionary = FactionDatabase.standing_to_dict()
	_run({"type": "set_relation", "faction": "golden_guard", "other": "waldau", "relation": "neutral"})
	_check("relation.neutral", not FactionDatabase.are_hostile("golden_guard", "waldau"))
	FactionDatabase.create_runtime_faction("r3_band", "waldau", "Test Band")
	var with_band: Dictionary = FactionDatabase.standing_to_dict()
	FactionDatabase.standing_from_dict(saved)
	_check("relation.saved-and-restored", FactionDatabase.are_hostile("golden_guard", "waldau") and not FactionDatabase.has_faction("r3_band"))
	FactionDatabase.standing_from_dict(with_band)
	_check("runtime-faction.saved", FactionDatabase.has_faction("r3_band") and FactionDatabase.are_friendly("r3_band", "waldau"))
	n0 = _log_n()
	_run({"type": "set_relation", "faction": "waldau", "other": "party", "relation": "enemy"})
	_check("relation.with-party", FactionDatabase.are_hostile("player", "waldau"))
	_check("relation.with-party-said", _logged(n0, "Waldau now counts you as an enemy."), str(_logs_since(n0)))
	_check("relation.unknown-refused", not _run({"type": "set_relation", "faction": "waldau", "other": "nobodies", "relation": "enemy"}))
	_restore_factions()
	_check("relation.restored", not FactionDatabase.are_hostile("golden_guard", "waldau") and not FactionDatabase.are_hostile("player", "waldau"))

	var tier0: int = FactionDatabase.get_faction_tier("waldau")
	n0 = _log_n()
	_check("tier.change", _run({"type": "change_faction_tier", "faction": "waldau", "amount": 1})
		and FactionDatabase.get_faction_tier("waldau") == tier0 + 1)
	_check("tier.said", _logged(n0, "Waldau grows stronger (tier %d)." % (tier0 + 1)), str(_logs_since(n0)))
	FactionDatabase.set_faction_tier("waldau", tier0)


func _case_law() -> void:
	# The cemetery is Perrow: Liziti law, enforced by Liziti and the Golden Guard.
	_check("law.jurisdiction", CrimeManager.current_law_faction() == "liziti", CrimeManager.current_law_faction())
	var witness = _spawn("town_guard", Vector2(80, 0))
	var n0 := _log_n()
	_check("crime.statute-not-law-here-refused", not _run({"type": "report_crime", "statute": "necromancy"}))
	_check("crime.refusal-silent-in-game", not _logged(n0, "commits"))
	n0 = _log_n()
	_check("crime.report", _run({"type": "report_crime", "statute": "theft", "witnesses": str(witness.Name)}))
	_check("crime.report-said", _logged(n0, "%s commits Theft (severity 25)" % P.Name), str(_logs_since(n0)))
	var ai = witness.get_node("AI")
	var pending: Dictionary = ai.pending_outcry.duplicate()
	_check("crime.witness-fuse-lit", not pending.is_empty() and bool(pending.get("identified", false)), str(pending))
	# Let the fuse run out now rather than waiting on the paused clock.
	ai.pending_outcry = {}
	ai._outcry_timer = -1.0
	n0 = _log_n()
	CrimeManager.fire_outcry(witness, pending)
	_check("crime.alarm-raised", _logged(n0, "The alarm is raised: Theft — %s stands accused." % P.Name), str(_logs_since(n0)))
	_check("crime.outlaw", api.check({"type": "outlaw", "faction": "liziti"}) and FactionDatabase.is_outlaw_with("liziti"))
	_check("crime.wanted-shown", P.get_node("ConditionManager").has_condition("wanted"))
	n0 = _log_n()
	_check("pardon", _run({"type": "pardon", "faction": "liziti"}) and not FactionDatabase.is_outlaw_with("liziti"))
	_check("pardon.said", _logged(n0, "Liziti pardons you. You are no longer wanted there."), str(_logs_since(n0)))
	_check("pardon.wanted-cleared", not P.get_node("ConditionManager").has_condition("wanted"))
	_check("pardon.manhunt-cleared", ai.manhunt_target == null)
	game.despawn_character(witness)
	_restore_factions()


func _case_conversation_actions() -> void:
	var n0 := _log_n()
	_check("log", _run({"type": "log", "text": "The **bell** tolls."}) and _logged(n0, "The [b]bell[/b] tolls."), str(_logs_since(n0)))
	_reset_dialogue()
	DialogueManager.start_dialogue("Jacana_greet")
	_check("start-dialogue.queued", _run({"type": "start_dialogue", "dialogue": "guard_greet"})
		and "guard_greet" in DialogueManager._pending_dialogues)
	_check("start-dialogue.unknown-refused", not _run({"type": "start_dialogue", "dialogue": "no_such"}))
	_reset_dialogue()
	var qid := "sacred_grove"
	_fresh_quest(qid)
	_check("call.legacy-string", _run({"type": "call", "call": "QuestManager.start_quest('sacred_grove')"}) and QuestManager.is_quest_active(qid))
	_fresh_quest(qid)
	api.run_list(["QuestManager.start_quest('sacred_grove')"])
	_check("call.plain-string-entry", QuestManager.is_quest_active(qid))
	_fresh_quest(qid)


# --- 3. choices, branches, on_enter, once -------------------------------------------------

func _panel_buttons() -> Array:
	var box = game.get_node_or_null("GameUI/DialoguePanel/MarginContainer/HBoxContainer/DialogueVBox/ChoicesContainer")
	var out: Array = []
	if box == null:
		return out
	for b in box.get_children():
		if not b.is_queued_for_deletion():
			out.append(b)
	return out


func _case_choices_and_branches() -> void:
	_reset_dialogue()
	for k in ["r3_entered", "r3_secret", "r3_went", "r3_never"]:
		Globals.world_state.erase(k)
	DialogueManager.dialogues["r3_choices"] = {"dialogueNodes": {
		"r3_choices": {
			"on_enter": [{"type": "set_flag", "flag": "r3_entered"}],
			"narrator": "Choose.",
			"choices": [
				{"text": "Pay", "requires": [{"type": "has_gold", "amount": 100000}], "nextNode": "paid"},
				{"text": "Secret", "show_if": {"type": "flag", "flag": "r3_secret"}, "nextNode": "paid"},
				{"text": "Friends only", "requires": {"type": "flag", "flag": "r3_never"}, "locked_text": "Only for friends", "nextNode": "paid"},
				{"text": "Go", "actions": [{"type": "set_flag", "flag": "r3_went"}],
					"branch": [{"if": {"type": "flag", "flag": "r3_went"}, "next": "went"}, {"next": "paid"}]},
			],
		},
		"paid": {"narrator": "Paid."},
		"went": {"narrator": "Went."},
		"r3_stuck": {"narrator": "Stuck?", "choices": [{"text": "Pay", "requires": {"type": "has_gold", "amount": 100000}, "nextNode": "paid"}]},
		"r3_hidden": {"narrator": "Hidden.", "choices": [{"text": "x", "show_if": {"type": "flag", "flag": "r3_never"}, "nextNode": "paid"}], "next": "went"},
		"r3_once": {"narrator": "Once.", "actions": [{"type": "add_to_flag", "flag": "r3_once_count", "amount": 1, "once": true}]},
	}}
	DialogueManager.start_dialogue("r3_choices")
	_check("on-enter.ran-before-first-line", Globals.world_state.get("r3_entered") == true and DialogueManager.current_line_index == 0)
	_advance_to_rest()
	var ch: Array = DialogueManager.current_choices
	_check("show-if.hidden", ch.size() == 3, str(ch.map(func(c): return c["text"])))
	_check("requires.disabled-with-reason", ch.size() == 3 and ch[0]["disabled"] and str(ch[0]["locked_reason"]) == "Needs 100000 gold",
		str(ch[0]) if ch.size() > 0 else "")
	_check("requires.locked-text", ch.size() == 3 and ch[1]["disabled"] and str(ch[1]["locked_reason"]) == "Only for friends")
	_check("requires.open-choice-enabled", ch.size() == 3 and not ch[2]["disabled"])
	await _frames(1)
	var buttons: Array = _panel_buttons()
	_check("panel.disabled-button", buttons.size() == 3 and buttons[0].disabled and str(buttons[0].text).contains("[Needs 100000 gold]")
		and str(buttons[0].tooltip_text) == "Needs 100000 gold", str(buttons.map(func(b): return [b.text, b.disabled])))
	_check("panel.open-button", buttons.size() == 3 and not buttons[2].disabled)
	var n0 := _log_n()
	DialogueManager.select_choice(0)
	_check("requires.pick-refused", DialogueManager.current_node_id == "r3_choices" and DialogueManager.current_choices.size() == 3)
	_check("requires.pick-refusal-said", _logged(n0, "Can't choose that: Needs 100000 gold."), str(_logs_since(n0)))
	DialogueManager.select_choice(2)
	_check("choice.actions-then-array-branch", Globals.world_state.get("r3_went") == true and DialogueManager.current_node_id == "went",
		DialogueManager.current_node_id)
	_reset_dialogue()

	Globals.world_state["r3_secret"] = true
	DialogueManager.start_dialogue("r3_choices")
	_advance_to_rest()
	_check("show-if.shown-when-met", DialogueManager.current_choices.size() == 4)
	_reset_dialogue()

	DialogueManager.start_dialogue("r3_choices")
	DialogueManager.show_node("r3_stuck")
	_advance_to_rest()
	var stuck: Array = DialogueManager.current_choices
	_check("all-locked.leave-offered", stuck.size() == 2 and str(stuck[1]["text"]) == "Leave." and not stuck[1]["disabled"],
		str(stuck.map(func(c): return c["text"])))
	DialogueManager.select_choice(1)
	_check("all-locked.leave-ends", not DialogueManager.is_active())

	DialogueManager.start_dialogue("r3_choices")
	DialogueManager.show_node("r3_hidden")
	_advance_to_rest()
	_check("all-hidden.falls-through-to-next", DialogueManager.current_node_id == "went" or not DialogueManager.is_active(),
		DialogueManager.current_node_id)
	_reset_dialogue()

	Globals.world_state.erase("r3_once_count")
	for i in range(2):
		DialogueManager.start_dialogue("r3_choices")
		DialogueManager.show_node("r3_once")
		_advance_to_rest()
		_reset_dialogue()
	_check("once.runs-once", int(Globals.world_state.get("r3_once_count", 0)) == 1, str(Globals.world_state.get("r3_once_count")))
	DialogueManager.dialogues.erase("r3_choices")
	await _frames(1)


# --- 5. Federica --------------------------------------------------------------------------

func _federica() -> Node:
	var fed = _spawn("surgeon_captain_federica", Vector2(110, 0))
	return fed


func _case_federica_fight() -> void:
	_check("federica.no-inline-tokens-left", not JSON.stringify(DialogueManager.dialogues["Federica_greet"]).contains("[["))
	var fed = _federica()
	_check("federica.found-by-one-word", api._chars("Federica") == [fed])
	PauseManager.unpause()
	var n0 := _log_n()
	_play_node("Federica_greet", "Federica-intro-fight", str(fed.Name))
	_check("federica.fight.ended", not DialogueManager.is_active())
	_check("federica.fight.hostile-to-party", fed.is_hostile_to_party() and FactionDatabase.are_hostile("player", fed.faction_id))
	_check("federica.fight.own-band", FactionDatabase.is_runtime_faction(fed.faction_id) and not FactionDatabase.are_hostile(fed.faction_id, "waldau"),
		fed.faction_id)
	_check("federica.fight.said", _logged(n0, "Combat! Surgeon Captain Federica attacks you."), str(_logs_since(n0)))
	_check("federica.fight.said-once", not _logged(n0, "turns hostile"), str(_logs_since(n0)))
	_check("federica.fight.paused", PauseManager.is_paused)
	PauseManager.pause()
	_despawn_all_npcs_except()
	_restore_factions()
	await _frames(2)


func _case_federica_guard_patrol() -> void:
	var fed = _federica()
	var n_help := _log_n()
	_play_node("Federica_greet", "Federica-intro-agree-to-help", str(fed.Name))
	_check("federica.help.choices-up", DialogueManager.current_choices.size() == 3)
	_check("federica.help.arms-bagged", "Arms of Octavian" in _item_names(fed), str(_item_names(fed)))
	_check("federica.help.arms-said", _logged(n_help, "Surgeon Captain Federica takes Arms of Octavian."), str(_logs_since(n_help)))
	var n0 := _log_n()
	DialogueManager.select_choice(0)   # shout for the guard
	_advance_to_rest()
	_check("federica.patrol.ended", not DialogueManager.is_active())
	var patrol: Array = _tagged("night_patrol")
	_check("federica.patrol.four-guards", patrol.size() == 4 and patrol.all(func(c): return str(c.template_id) == "town_guard"), str(patrol.size()))
	# They come from the town: the map's arrival point from the town square.
	var arrival: Array = game.current_map_data.get("player_spawns", {}).get("from_town_square", {}).get("position", [0, 0])
	var arrive_at := Vector2(float(arrival[0]), float(arrival[1]))
	# (Here the party itself stands on that arrival point, so the guards fan out
	# round it onto free tiles rather than on top of the party.)
	_check("federica.patrol.from-the-town", patrol.all(func(c): return c.global_position.distance_to(arrive_at) < 240.0),
		str(patrol.map(func(c): return c.global_position)))
	_check("federica.patrol.federica-fights-guards", FactionDatabase.are_hostile(fed.faction_id, "golden_guard")
		and patrol.all(func(c): return c.get_node("AI")._is_enemy(fed)))
	_check("federica.patrol.federica-fights-you", fed.is_hostile_to_party())
	_check("federica.patrol.guards-not-hostile-to-you", patrol.all(func(c): return not c.is_hostile_to_party()))
	_check("federica.patrol.guards-alerted", patrol.all(func(c): return float(c.get_node("AI").alertness_value) >= 60.0))
	_check("federica.patrol.said", _logged(n0, "Combat! Surgeon Captain Federica attacks you and the Golden Guard."), str(_logs_since(n0)))

	# Replaying the scene doesn't bag a second pair of arms.
	_play_node("Federica_greet", "Federica-intro-agree-to-help", str(fed.Name))
	_check("federica.help.arms-once", _item_names(fed).count("Arms of Octavian") == 1, str(_item_names(fed)))
	_reset_dialogue()
	_despawn_all_npcs_except()
	_restore_factions()
	await _frames(2)


func _case_federica_interrogation() -> void:
	var fed = _federica()
	var n0 := _log_n()
	_play_node("Federica_greet", "Federica-intro-interrogation-continued", str(fed.Name))
	_check("federica.interrogation.ended", not DialogueManager.is_active())
	_check("federica.interrogation.skull-bagged", "Skull of a Scholar" in _item_names(fed), str(_item_names(fed)))
	_check("federica.interrogation.skull-said", _logged(n0, "Surgeon Captain Federica takes Skull of a Scholar."), str(_logs_since(n0)))
	var patrol: Array = _tagged("night_patrol")
	_check("federica.interrogation.four-guards", patrol.size() == 4, str(patrol.size()))
	_check("federica.interrogation.surround-the-grave", patrol.all(func(c): return c.global_position.distance_to(fed.global_position) < 160.0),
		str(patrol.map(func(c): return c.global_position.distance_to(fed.global_position))))
	_check("federica.interrogation.centurion", patrol.any(func(c): return str(c.Name) == "Centurion"))
	_check("federica.interrogation.she-will-not-kneel", FactionDatabase.are_hostile(fed.faction_id, "golden_guard"))
	_check("federica.interrogation.your-affair", not fed.is_hostile_to_party() and patrol.all(func(c): return not c.is_hostile_to_party()))
	_check("federica.interrogation.said", _logged(n0, "Combat! Surgeon Captain Federica turns on the Golden Guard."), str(_logs_since(n0)))
	_despawn_all_npcs_except()
	_restore_factions()
	await _frames(2)


func _case_federica_quiet_exits() -> void:
	var fed = _federica()
	var t0: int = int(P.traits.get("Subtle", 0))
	var n0 := _log_n()
	_play_node("Federica_greet", "end-convo", str(fed.Name))
	_check("federica.slip-away.subtle", int(P.traits.get("Subtle", 0)) == t0 + 1, "%d -> %d" % [t0, int(P.traits.get("Subtle", 0))])
	_check("federica.slip-away.said", _logged(n0, "%s gains the Subtle trait (now %d)." % [P.Name, t0 + 1]), str(_logs_since(n0)))
	_play_node("Federica_greet", "end-convo", str(fed.Name))
	_check("federica.slip-away.once", int(P.traits.get("Subtle", 0)) == t0 + 1)
	_play_node("Federica_greet", "Federica-intro-let-go", str(fed.Name))
	_check("federica.let-go.peaceful", fed.faction_id == "waldau" and not fed.is_hostile_to_party())
	_reset_dialogue()
	_despawn_all_npcs_except()
	await _frames(1)
