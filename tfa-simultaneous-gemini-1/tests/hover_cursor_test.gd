# res://tests/hover_cursor_test.gd
# Headless assertion harness for the character hover cursor.
# Run:  godot --headless --path . res://tests/hover_cursor_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (pre-existing parse errors
# print noise; runs can flake exit 255 — rerun once).
#
# Covers ProceduralCharacter._hover_cursor_for_character and its talk gate:
#   hostile              -> attack cursor (dagger)
#   talkable non-hostile -> talk cursor
#   everyone else        -> the plain reticle
# and the three ways "talkable" can fail: no Talk verb, no dialogue at the
# current index, and the player sneaking. A peaceful NPC whose dialogue id is
# missing from Dialogues.json is a talk click with nothing to say: the arrow.
#
# The scene root is deliberately named "Game": ProceduralCharacter resolves its
# `game` reference as get_node_or_null("/root/Game"), so the stealth_mode gate
# is only reachable when this harness occupies that path.
extends Node2D

const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

# Game.gd contract stubs — ai.gd resolves `game = get_tree().current_scene`.
var characters_in_scene: Array = []
var party_chars: Array = []
var items_in_scene: Array = []
var structures_in_scene: Array = []
var selected_characters: Array = []
var stealth_mode: bool = false
var context_menu_open: bool = false

var failures := 0
var _viewer: ProceduralCharacter = null

const _STUB_DIALOGUES := ["test_dialogue", "first", "second"]


func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])


func _spawn(faction: String, char_name: String) -> ProceduralCharacter:
	var pc: ProceduralCharacter = PC_SCENE.instantiate()
	add_child(pc)
	pc.faction_id = faction
	pc.Name = char_name
	characters_in_scene.append(pc)
	return pc


## An NPC who would actually answer: carries the Talk verb and a dialogue at the
## index context_menu.gd reads.
func _spawn_talker(faction: String, char_name: String) -> ProceduralCharacter:
	var pc := _spawn(faction, char_name)
	pc.interact_options = ["Attack", "Talk"]
	pc.dialogues = ["test_dialogue"]
	pc.current_dialogue_index = 0
	return pc


func _ready() -> void:
	_viewer = _spawn("player", "Viewer")
	# The oracle must agree with the fixtures, or every assertion below is
	# vacuous — a "hostile" who isn't hostile would silently pass the reticle.
	_check("fixture.oracle-hostile",
		FactionDatabase.are_hostile("player", "bandits"),
		"expected player/bandits hostile; pick another faction for this test")

	# active_dialogue_id() only answers for dialogues DialogueManager has loaded
	# with nodes, so the fixtures' ids get stub entries for the run.
	for stub_id in _STUB_DIALOGUES:
		DialogueManager.dialogues[stub_id] = {"dialogueNodes": {stub_id: {"narrator": "..."}}}

	_case_verb_cursors()
	_case_talk_gates()
	_case_click_agrees_with_cursor()
	_case_nothing_to_say()

	for stub_id in _STUB_DIALOGUES:
		DialogueManager.dialogues.erase(stub_id)

	if failures == 0:
		print("ALL PASS")
	else:
		print("%d FAILURE(S)" % failures)
	get_tree().quit(1 if failures > 0 else 0)


func _case_verb_cursors() -> void:
	var reticle := _viewer._get_targeting_cursor()
	var attack_cursor := _viewer._get_hover_cursor(
		ProceduralCharacter.ATTACK_CURSOR_PATH)
	var talk_cursor := _viewer._get_hover_cursor(
		ProceduralCharacter.TALK_CURSOR_PATH)

	# Art presence is part of the contract: if a file goes missing the cursor
	# silently degrades to the reticle, which is exactly the bug this catches.
	_check("art.attack-cursor-loads", attack_cursor != null,
		ProceduralCharacter.ATTACK_CURSOR_PATH)
	_check("art.talk-cursor-loads", talk_cursor != null,
		ProceduralCharacter.TALK_CURSOR_PATH)
	_check("art.reticle-loads", reticle != null,
		ProceduralCharacter.TARGETING_CURSOR_PATH)

	var hostile := _spawn_talker("bandits", "Brigand")
	_check("hostile.shows-dagger",
		_viewer._hover_cursor_for_character(hostile) == attack_cursor,
		"a hostile must show the attack cursor even when they carry dialogue")

	var friendly := _spawn_talker("player", "Companion")
	_check("friendly-talker.shows-talk",
		_viewer._hover_cursor_for_character(friendly) == talk_cursor)

	var mute := _spawn("player", "Mute")
	_check("friendly-silent.shows-reticle",
		_viewer._hover_cursor_for_character(mute) == reticle,
		"a non-hostile with nothing to say still has to be designatable")


func _case_talk_gates() -> void:
	var npc := _spawn_talker("player", "Chatty")
	_check("talk.baseline", _viewer._can_be_talked_to(npc))

	# Gate 1: Game.show_context_menu only lists verbs from interact_options.
	npc.interact_options = ["Attack"]
	_check("talk.needs-verb", not _viewer._can_be_talked_to(npc))
	npc.interact_options = ["Attack", "Talk"]

	# Gate 2: context_menu.gd's Talk branch no-ops on an out-of-range index.
	npc.current_dialogue_index = 3
	_check("talk.index-out-of-range", not _viewer._can_be_talked_to(npc))
	npc.current_dialogue_index = -1
	_check("talk.index-negative", not _viewer._can_be_talked_to(npc))
	npc.current_dialogue_index = 0

	npc.dialogues = []
	_check("talk.no-dialogues", not _viewer._can_be_talked_to(npc))
	# Gate 2b: the id must name a loaded dialogue that has nodes to show.
	npc.dialogues = ["no_such_dialogue_harness"]
	_check("talk.unknown-dialogue", not _viewer._can_be_talked_to(npc))
	DialogueManager.dialogues["empty_dialogue_harness"] = {"dialogueNodes": {}}
	npc.dialogues = ["empty_dialogue_harness"]
	_check("talk.dialogue-without-nodes", not _viewer._can_be_talked_to(npc))
	DialogueManager.dialogues.erase("empty_dialogue_harness")
	npc.dialogues = ["test_dialogue"]
	_check("talk.restored", _viewer._can_be_talked_to(npc))

	# Gate 3: sneaking suppresses the invitation to chat.
	stealth_mode = true
	_check("talk.suppressed-while-sneaking", not _viewer._can_be_talked_to(npc))
	_check("talk.sneaking-falls-back-to-reticle",
		_viewer._hover_cursor_for_character(npc) == _viewer._get_targeting_cursor())
	stealth_mode = false
	_check("talk.resumes-after-sneaking", _viewer._can_be_talked_to(npc))


# The left-click fast path and the hover cursor must agree about who answers,
# and must open the dialogue the right-click menu would have opened. Both read
# _would_talk_to / active_dialogue_id, so this pins that contract rather than
# the individual call sites.
func _case_click_agrees_with_cursor() -> void:
	var talk_cursor := _viewer._get_hover_cursor(ProceduralCharacter.TALK_CURSOR_PATH)
	var subjects := [
		_spawn_talker("player", "Friendly"),
		_spawn_talker("bandits", "Hostile"),
		_spawn("player", "Silent"),
	]
	for subject in subjects:
		var shows_talk: bool = _viewer._hover_cursor_for_character(subject) == talk_cursor
		var would_talk: bool = _viewer._would_talk_to(subject)
		_check("agree.%s" % subject.Name, shows_talk == would_talk,
			"cursor says %s, click says %s" % [shows_talk, would_talk])

	# Hostility is the fast path's own gate, not just the cursor's: a hostile
	# carrying dialogue must take the swing.
	_check("click.hostile-not-talkable", not _viewer._would_talk_to(subjects[1]))

	# active_dialogue_id is what both call sites hand to DialogueManager.
	var friendly: ProceduralCharacter = subjects[0]
	_check("dialogue-id.resolves", friendly.active_dialogue_id() == "test_dialogue")
	friendly.dialogues = ["first", "second"]
	friendly.current_dialogue_index = 1
	_check("dialogue-id.follows-index", friendly.active_dialogue_id() == "second")
	friendly.current_dialogue_index = 7
	_check("dialogue-id.empty-when-out-of-range", friendly.active_dialogue_id() == "")
	_check("dialogue-id.gates-the-click", not _viewer._would_talk_to(friendly))


# A peaceful NPC whose dialogue id Dialogues.json lacks (a town guard, a
# merchant): not a conversation (no talk cursor), but still a talk click that
# says "nothing to say" rather than swinging, so the cursor is the plain arrow,
# not the reticle. Sneaking, hostility and an empty dialogues list keep dev's
# behaviour: the click designates (reticle).
func _case_nothing_to_say() -> void:
	var reticle := _viewer._get_targeting_cursor()
	var guard := _spawn("player", "Guard")
	guard.interact_options = ["Talk"]
	guard.dialogues = ["no_such_dialogue_harness"]
	guard.current_dialogue_index = 0
	_check("mute.not-a-conversation", not _viewer._would_talk_to(guard))
	_check("mute.click-is-talk", _viewer._click_is_talk(guard))
	_check("mute.cursor-is-arrow", _viewer._hover_cursor_for_character(guard) == null)

	stealth_mode = true
	_check("mute.sneaking-click-not-talk", not _viewer._click_is_talk(guard))
	_check("mute.sneaking-cursor-is-reticle", _viewer._hover_cursor_for_character(guard) == reticle)
	stealth_mode = false

	var brigand := _spawn("bandits", "Brigand")
	brigand.interact_options = ["Talk"]
	brigand.dialogues = ["no_such_dialogue_harness"]
	brigand.current_dialogue_index = 0
	_check("mute.hostile-click-not-talk", not _viewer._click_is_talk(brigand))

	var blank := _spawn("player", "Blank")
	blank.interact_options = ["Talk"]
	blank.dialogues = []
	_check("mute.no-dialogues-click-not-talk", not _viewer._click_is_talk(blank))
	_check("mute.no-dialogues-designatable", _viewer._hover_cursor_for_character(blank) == reticle)
