# QuestDatabase.gd
# Autoload singleton - registered in project.godot as "QuestDatabase".
# Loads static quest definitions from data/Quests.json.
extends Node

const QUESTS_PATH := "res://data/Quests.json"

var _quests: Dictionary = {}

func _ready() -> void:
	_load_database()

func _load_database() -> void:
	if not FileAccess.file_exists(QUESTS_PATH):
		push_error("Quest Database not found at: " + QUESTS_PATH)
		return
	var f := FileAccess.open(QUESTS_PATH, FileAccess.READ)
	if f == null:
		push_error("Failed to open " + QUESTS_PATH)
		return
	var text := f.get_as_text()
	f.close()
	var json := JSON.new()
	var err := json.parse(text)
	print("====== Quest Database =======")
	if err != OK:
		push_error("Failed to parse Quests.json: " + json.get_error_message())
		print("====== End Quest Database ======")
		return
	var data = json.data
	var entries: Array = []
	if data is Dictionary and data.has("quests"):
		entries = data.get("quests", [])
	elif data is Array:
		entries = data
	for entry in entries:
		if entry is Dictionary and entry.has("id"):
			_quests[str(entry["id"])] = entry
	print("Loaded %d quests" % _quests.size())
	print("====== End Quest Database ======")

func get_quest(id: String) -> Dictionary:
	if _quests.has(id):
		return _quests[id]
	return {}

func get_all_quest_ids() -> Array:
	return _quests.keys()

func get_stage(quest_id: String, stage_id: String) -> Dictionary:
	var q := get_quest(quest_id)
	for s in q.get("stages", []):
		if s is Dictionary and str(s.get("id", "")) == stage_id:
			return s
	return {}

func get_stages(quest_id: String) -> Array:
	return get_quest(quest_id).get("stages", [])

func get_stage_index(quest_id: String, stage_id: String) -> int:
	var stages: Array = get_stages(quest_id)
	for i in range(stages.size()):
		var s = stages[i]
		if s is Dictionary and str(s.get("id", "")) == stage_id:
			return i
	return -1

# Proof requirements declared on a stage. Each entry is
#   {"item": <item_id>, "from_template": <template_id or absent>, "count": int}
# `from_template` absent means any copy of the item satisfies the requirement;
# present means the item must carry origin.template_id == that value.
func get_proof(quest_id: String, stage_id: String) -> Array:
	var stage := get_stage(quest_id, stage_id)
	var raw = stage.get("proof", [])
	return raw if raw is Array else []

# The turn-in descriptor on a stage: {"npc_template": ..., "faction": ...}.
# Empty when the stage completes passively (the pre-existing behaviour).
func get_turn_in(quest_id: String, stage_id: String) -> Dictionary:
	var stage := get_stage(quest_id, stage_id)
	var raw = stage.get("turn_in", {})
	return raw if raw is Dictionary else {}

# The quest-level reward block: {"pick": int, "offers": [...]}.
func get_rewards(quest_id: String) -> Dictionary:
	var raw = get_quest(quest_id).get("rewards", {})
	return raw if raw is Dictionary else {}

# Every proof entry across EVERY stage of a quest. Trophy harvesting needs this
# rather than the current stage's proof alone: you routinely kill the bounty
# target while the quest is still on the "find them" stage, and the head has to
# drop then, not retroactively when you reach "claim the bounty".
func get_all_proof(quest_id: String) -> Array:
	var out: Array = []
	for s in get_stages(quest_id):
		if not (s is Dictionary):
			continue
		var raw = s.get("proof", [])
		if raw is Array:
			for entry in raw:
				if entry is Dictionary:
					out.append(entry)
	return out

func get_auto_start_ids() -> Array:
	var out: Array = []
	for id in _quests:
		if bool(_quests[id].get("auto_start", false)):
			out.append(id)
	return out
