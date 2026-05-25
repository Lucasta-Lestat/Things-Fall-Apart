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

func get_auto_start_ids() -> Array:
	var out: Array = []
	for id in _quests:
		if bool(_quests[id].get("auto_start", false)):
			out.append(id)
	return out
