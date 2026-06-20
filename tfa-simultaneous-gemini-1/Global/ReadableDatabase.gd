# ReadableDatabase.gd
# Autoload singleton - registered in project.godot as "ReadableDatabase".
# Loads static readable (note/letter/scroll/book/tome) definitions from
# data/Readables.json. Mirrors QuestDatabase's load + accessor pattern.
extends Node

const READABLES_PATH := "res://data/Readables.json"

var _readables: Dictionary = {}

func _ready() -> void:
	_load_database()

func _load_database() -> void:
	if not FileAccess.file_exists(READABLES_PATH):
		push_error("Readable Database not found at: " + READABLES_PATH)
		return
	var f := FileAccess.open(READABLES_PATH, FileAccess.READ)
	if f == null:
		push_error("Failed to open " + READABLES_PATH)
		return
	var text := f.get_as_text()
	f.close()
	var json := JSON.new()
	var err := json.parse(text)
	print("====== Readable Database =======")
	if err != OK:
		push_error("Failed to parse Readables.json: " + json.get_error_message())
		print("====== End Readable Database ======")
		return
	var data = json.data
	var entries: Array = []
	if data is Dictionary and data.has("readables"):
		entries = data.get("readables", [])
	elif data is Array:
		entries = data
	for entry in entries:
		if entry is Dictionary and entry.has("id"):
			_readables[str(entry["id"])] = entry
	print("Loaded %d readables" % _readables.size())
	print("====== End Readable Database ======")

func get_readable(id: String) -> Dictionary:
	if _readables.has(id):
		return _readables[id]
	return {}

func has_readable(id: String) -> bool:
	return _readables.has(id)

func get_all_readable_ids() -> Array:
	return _readables.keys()

func get_title(id: String) -> String:
	return str(get_readable(id).get("title", id))

func get_kind(id: String) -> String:
	return str(get_readable(id).get("kind", "note"))

# Always returns a non-empty Array of BBCode page strings. Accepts either a
# "pages" array or a single "body" string; falls back to [""].
func get_pages(id: String) -> Array:
	var data := get_readable(id)
	var pages_val = data.get("pages", null)
	if pages_val is Array and not (pages_val as Array).is_empty():
		var out: Array = []
		for p in pages_val:
			out.append(str(p))
		return out
	var body_val = data.get("body", null)
	if body_val != null and str(body_val) != "":
		return [str(body_val)]
	return [""]
