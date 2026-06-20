# ReadableManager.gd
# Autoload singleton - registered in project.godot as "ReadableManager".
#
# Tracks which readables (notes/books) the player has collected into the journal
# and which have been read. Mirrors QuestManager's in-memory save/load pattern
# and reflects state into Globals.world_state so map item_spawns can suppress
# already-collected readables via a `condition`.
#
# World-state keys written here:
#   readable_collected::<id>  -> bool  (true once in the journal; suppresses world respawn)
#   readable_read::<id>       -> true  (has been opened/read)
extends Node

signal journal_updated(readable_id: String)

# Collection order preserved for journal display.
var collected: Array = []
# id -> true for readables that have been read.
var read: Dictionary = {}

func _ready() -> void:
	# Seed every known readable's "collected" flag to false. Game._check_condition
	# treats a MISSING world_state key as a failed condition (and warns), so map
	# item_spawns gated on `readable_collected::<id> == false` need the key to
	# exist before the first map spawns. ReadableDatabase is an earlier autoload,
	# so its definitions are already loaded here. Collected flags are restored
	# afterwards by load_save_data()/_rehydrate_world_state().
	_seed_world_state()

func _seed_world_state() -> void:
	if ReadableDatabase == null:
		return
	for id in ReadableDatabase.get_all_readable_ids():
		var key: String = "readable_collected::" + str(id)
		if not Globals.world_state.has(key):
			Globals.world_state[key] = false

# ---------------------------------------------------------------------------
# Mutators
# ---------------------------------------------------------------------------

func collect(id: String) -> void:
	if id.is_empty() or id in collected:
		return
	collected.append(id)
	_write_world_state("readable_collected::" + id, true)
	var title: String = id
	if ReadableDatabase != null:
		title = ReadableDatabase.get_title(id)
	if GameLog != null and GameLog.has_method("add_entry"):
		GameLog.add_entry("Added to your journal: %s" % title)
	emit_signal("journal_updated", id)

func mark_read(id: String) -> void:
	if id.is_empty():
		return
	# Reading always files it in the journal first.
	if not (id in collected):
		collect(id)
	if not read.get(id, false):
		read[id] = true
		_write_world_state("readable_read::" + id, true)
		emit_signal("journal_updated", id)

# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

func is_read(id: String) -> bool:
	return bool(read.get(id, false))

func is_collected(id: String) -> bool:
	return id in collected

func get_collected() -> Array:
	return collected.duplicate()

# ---------------------------------------------------------------------------
# Save/load (in-memory; mirrors QuestManager.get_save_data/load_save_data).
# TODO: include get_save_data() in Game's central save aggregator when one is
# built (next to QuestManager.get_save_data()).
# ---------------------------------------------------------------------------

func get_save_data() -> Dictionary:
	return {
		"collected": collected.duplicate(),
		"read": read.duplicate(),
	}

func load_save_data(data: Dictionary) -> void:
	collected = data.get("collected", []).duplicate() if data.has("collected") else []
	read = data.get("read", {}).duplicate() if data.has("read") else {}
	_rehydrate_world_state()
	emit_signal("journal_updated", "")

func _rehydrate_world_state() -> void:
	for id in collected:
		Globals.world_state["readable_collected::" + str(id)] = true
	for id in read.keys():
		Globals.world_state["readable_read::" + str(id)] = true

func _write_world_state(key: String, value) -> void:
	Globals.world_state[key] = value
