# QuestManager.gd
# Autoload singleton - registered in project.godot as "QuestManager".
#
# Runs the quest state machine. Each active quest is at a current stage; on any
# world event (time tick, character death, item pickup, map load, faction tier
# change, date change) we reflect the event into Globals.world_state with a
# canonical key, then re-evaluate every active quest's stage transitions.
#
# Transitions are dicts {<world_state_key>: <expected_value_or_op_string>}.
# Matching uses the same operator-string convention as Game._check_condition
# (">3", "<=5", "!=0", literals). Reserved next_stage sentinels:
#   "__complete__" -> quest moves to completed
#   "__fail__"     -> quest moves to failed
#
# World-state key conventions written here:
#   char_at::<template_id>         -> map_id String
#   char_dead::<template_id>       -> true
#   item_picked::<item_id>         -> true   (also item_count::<item_id> -> int)
#   faction_tier::<faction_id>     -> int (mirrors live tier)
#   quest_days::<quest_id>         -> int days since quest started
#   date_passed::<Y-M-D>           -> true on date_changed
extends Node

signal quest_updated(quest_id: String)
signal quest_stage_changed(quest_id: String, old_stage: String, new_stage: String)
signal quest_completed(quest_id: String)
signal quest_failed(quest_id: String)

const COMPLETE_STAGE := "__complete__"
const FAIL_STAGE := "__fail__"

# quest_id -> current_stage_id
var active: Dictionary = {}
var completed: Array = []
var failed: Array = []
# quest_id -> packed int Y*10000 + M*100 + D when started
var _quest_start_day: Dictionary = {}
# Inventories already wired so we don't double-connect on re-registration.
var _wired_inventories: Array = []

func _ready() -> void:
	# Connect global signals. Game is in the scene tree, so defer until it's ready.
	if TimeManager:
		if TimeManager.has_signal("date_changed"):
			TimeManager.date_changed.connect(_on_date_changed)
	if FactionDatabase and FactionDatabase.has_signal("faction_tier_changed"):
		FactionDatabase.faction_tier_changed.connect(_on_faction_tier_changed)
	call_deferred("_connect_game_signals")
	call_deferred("_start_auto_start_quests")

func _connect_game_signals() -> void:
	var game := get_node_or_null("/root/Game")
	if game and game.has_signal("map_loaded") and not game.map_loaded.is_connected(_on_map_loaded):
		game.map_loaded.connect(_on_map_loaded)

func _start_auto_start_quests() -> void:
	if QuestDatabase == null:
		return
	for id in QuestDatabase.get_auto_start_ids():
		if not active.has(id) and not (id in completed) and not (id in failed):
			start_quest(id)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func start_quest(quest_id: String) -> void:
	var q: Dictionary = QuestDatabase.get_quest(quest_id) if QuestDatabase else {}
	if q.is_empty():
		push_warning("QuestManager.start_quest: unknown quest_id " + quest_id)
		return
	if active.has(quest_id) or quest_id in completed or quest_id in failed:
		return
	var start_stage := str(q.get("start_stage", ""))
	if start_stage.is_empty():
		var stages: Array = q.get("stages", [])
		if stages.size() > 0 and stages[0] is Dictionary:
			start_stage = str(stages[0].get("id", ""))
	active[quest_id] = start_stage
	_quest_start_day[quest_id] = _today_stamp()
	if GameLog:
		GameLog.add_entry("Quest started: " + str(q.get("display_name", quest_id)))
	emit_signal("quest_updated", quest_id)
	_reevaluate(quest_id)

func get_active_quests() -> Array:
	return active.keys()

func get_completed_quests() -> Array:
	return completed.duplicate()

func get_failed_quests() -> Array:
	return failed.duplicate()

func get_current_stage(quest_id: String) -> Dictionary:
	if not active.has(quest_id):
		return {}
	return QuestDatabase.get_stage(quest_id, active[quest_id])

# Returns [{stage_id, name, description, status}] for the quest log UI.
# status ∈ "done" | "current" | "failed" | "completed".
# Per design, FUTURE stages are not included (hide-until-reached).
func get_quest_checklist(quest_id: String) -> Array:
	var out: Array = []
	if QuestDatabase == null:
		return out
	var stages: Array = QuestDatabase.get_stages(quest_id)
	var current_stage_id: String = active.get(quest_id, "")
	var current_idx: int = -1
	if not current_stage_id.is_empty():
		current_idx = QuestDatabase.get_stage_index(quest_id, current_stage_id)

	var is_complete: bool = quest_id in completed
	var is_failed: bool = quest_id in failed

	for i in range(stages.size()):
		var s: Dictionary = stages[i]
		var entry := {
			"stage_id": str(s.get("id", "")),
			"name": str(s.get("name", "")),
			"description": str(s.get("description", "")),
			"status": "future",
		}
		if is_complete:
			entry["status"] = "done"
		elif is_failed:
			# Mark stages before the last-known active as done, the active one as failed.
			if current_idx >= 0 and i < current_idx:
				entry["status"] = "done"
			elif current_idx >= 0 and i == current_idx:
				entry["status"] = "failed"
			else:
				continue
		else:
			if current_idx < 0:
				continue
			if i < current_idx:
				entry["status"] = "done"
			elif i == current_idx:
				entry["status"] = "current"
			else:
				continue  # hide future stages per spec
		out.append(entry)
	return out

# ---------------------------------------------------------------------------
# Save/load (in-memory; matches Game.save_party_state pattern)
# ---------------------------------------------------------------------------

func get_save_data() -> Dictionary:
	return {
		"active": active.duplicate(),
		"completed": completed.duplicate(),
		"failed": failed.duplicate(),
		"quest_start_day": _quest_start_day.duplicate(),
	}

func load_save_data(data: Dictionary) -> void:
	active = data.get("active", {}).duplicate() if data.has("active") else {}
	completed = data.get("completed", []).duplicate() if data.has("completed") else []
	failed = data.get("failed", []).duplicate() if data.has("failed") else []
	_quest_start_day = data.get("quest_start_day", {}).duplicate() if data.has("quest_start_day") else {}
	_reevaluate_all()

# ---------------------------------------------------------------------------
# Per-character registration (called from Game._spawn_character).
# Wires death + inventory.item_added signals and seeds char_at::<template_id>.
# ---------------------------------------------------------------------------

func register_character(character) -> void:
	if character == null or not is_instance_valid(character):
		return
	var template_id: String = str(character.get("template_id")) if "template_id" in character else ""
	if not template_id.is_empty():
		var game := get_node_or_null("/root/Game")
		if game and "current_map_id" in game:
			_write_world_state("char_at::" + template_id, str(game.current_map_id))
	if character.has_signal("character_died") and not character.character_died.is_connected(_on_character_died):
		character.character_died.connect(_on_character_died.bind(character))
	var inv = character.get("inventory") if "inventory" in character else null
	if inv != null and is_instance_valid(inv) and inv.has_signal("item_added"):
		# Drop freed entries before checking membership so the list stays bounded.
		_wired_inventories = _wired_inventories.filter(func(x): return is_instance_valid(x))
		if not (inv in _wired_inventories):
			inv.item_added.connect(_on_item_added.bind(template_id))
			_wired_inventories.append(inv)

# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------

func _on_character_died(character) -> void:
	if character == null or not is_instance_valid(character):
		return
	var template_id: String = str(character.get("template_id")) if "template_id" in character else ""
	if template_id.is_empty():
		# Fall back to display_name slug so quests can still target by name.
		template_id = Globals.name_to_id(str(character.get("display_name")) if "display_name" in character else "")
	if template_id.is_empty():
		return
	_write_world_state("char_dead::" + template_id, true)
	_reevaluate_all()

func _on_item_added(item_data: Dictionary, owner_template_id: String) -> void:
	var item_id: String = str(item_data.get("id", ""))
	if item_id.is_empty():
		return
	_write_world_state("item_picked::" + item_id, true)
	var prev: int = int(Globals.world_state.get("item_count::" + item_id, 0))
	_write_world_state("item_count::" + item_id, prev + 1)
	if not owner_template_id.is_empty():
		_write_world_state("item_picked_by::" + owner_template_id + "::" + item_id, true)
	_reevaluate_all()

func _on_map_loaded(map_id: String) -> void:
	# Reflect the new location for every party member (their template_ids are
	# tracked in Game.party_state).
	var game := get_node_or_null("/root/Game")
	if game and "party_state" in game:
		for slot in game.party_state:
			if slot is Dictionary:
				var tid: String = str(slot.get("template_id", ""))
				if not tid.is_empty():
					_write_world_state("char_at::" + tid, str(map_id))
	_reevaluate_all()

func _on_faction_tier_changed(faction_id: String, _old_tier: int, new_tier: int) -> void:
	_write_world_state("faction_tier::" + faction_id, int(new_tier))
	_reevaluate_all()

func _on_date_changed(day: int, month: int, year: int) -> void:
	# Update per-quest day counters.
	var today := _today_stamp_from(year, month, day)
	for quest_id in active.keys():
		var start: int = int(_quest_start_day.get(quest_id, today))
		_write_world_state("quest_days::" + quest_id, _days_between(start, today))
	# Specific-date passing marker. Format: Y-M-D.
	_write_world_state("date_passed::%d-%d-%d" % [year, month, day], true)
	_reevaluate_all()

# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------

func _reevaluate_all() -> void:
	for quest_id in active.keys():
		_reevaluate(quest_id, {})

func _reevaluate(quest_id: String, _visited: Dictionary = {}) -> void:
	if not active.has(quest_id):
		return
	var stage: Dictionary = QuestDatabase.get_stage(quest_id, active[quest_id])
	if stage.is_empty():
		return
	var transitions: Array = stage.get("transitions", [])
	for t in transitions:
		if not (t is Dictionary):
			continue
		var conditions = t.get("conditions", {})
		if _conditions_pass(conditions):
			var next_stage: String = str(t.get("next_stage", ""))
			if next_stage.is_empty():
				continue
			_advance(quest_id, next_stage, _visited)
			return

func _advance(quest_id: String, next_stage: String, visited: Dictionary) -> void:
	var old_stage: String = active.get(quest_id, "")
	var q: Dictionary = QuestDatabase.get_quest(quest_id)
	var display_name: String = str(q.get("display_name", quest_id))

	if next_stage == COMPLETE_STAGE:
		active.erase(quest_id)
		if not (quest_id in completed):
			completed.append(quest_id)
		if GameLog:
			GameLog.add_entry("Quest complete: " + display_name)
		emit_signal("quest_stage_changed", quest_id, old_stage, COMPLETE_STAGE)
		emit_signal("quest_completed", quest_id)
		emit_signal("quest_updated", quest_id)
		return
	if next_stage == FAIL_STAGE:
		active.erase(quest_id)
		if not (quest_id in failed):
			failed.append(quest_id)
		if GameLog:
			GameLog.add_entry("Quest failed: " + display_name)
		emit_signal("quest_stage_changed", quest_id, old_stage, FAIL_STAGE)
		emit_signal("quest_failed", quest_id)
		emit_signal("quest_updated", quest_id)
		return

	# Normal stage transition.
	active[quest_id] = next_stage
	if GameLog:
		var st := QuestDatabase.get_stage(quest_id, next_stage)
		var stage_name := str(st.get("name", next_stage)) if not st.is_empty() else next_stage
		GameLog.add_entry("%s: %s" % [display_name, stage_name])
	emit_signal("quest_stage_changed", quest_id, old_stage, next_stage)
	emit_signal("quest_updated", quest_id)

	# Chain-evaluate, but guard against cycles (a transition whose conditions
	# always pass shouldn't loop forever).
	var visit_key: String = quest_id + "::" + next_stage
	if visited.has(visit_key):
		return
	visited[visit_key] = true
	_reevaluate(quest_id, visited)

# AND semantics across a conditions dict, mirroring Game._check_condition.
func _conditions_pass(conditions) -> bool:
	if conditions == null:
		return true
	if conditions is Dictionary:
		for key in conditions:
			if not _check_condition(str(key), conditions[key]):
				return false
		return true
	if conditions is Array:
		for c in conditions:
			if c is Dictionary:
				if not _conditions_pass(c):
					return false
		return true
	return true

# Duplicated from Game.gd::_check_condition (line ~2000) so this autoload stays
# self-contained and doesn't depend on the game scene being loaded.
func _check_condition(condition_key: String, condition_value = true) -> bool:
	if condition_key == "time_hour_min":
		return TimeManager.current_hour >= int(condition_value)
	if condition_key == "time_hour_max":
		return TimeManager.current_hour <= int(condition_value)
	if not Globals.world_state.has(condition_key):
		# Missing key counts as false for boolean checks, and as 0 for numeric
		# operator checks. Avoid spammy warnings - quests legitimately probe
		# for keys that haven't been written yet.
		if condition_value is String:
			var actual_default = 0
			return _compare_with_op(actual_default, condition_value)
		return condition_value == false  # only true if quest explicitly checks for false
	var actual = Globals.world_state[condition_key]
	if condition_value is String:
		return _compare_with_op(actual, condition_value)
	return actual == condition_value

func _compare_with_op(actual, value_str: String) -> bool:
	var op := ""
	var rhs_str: String = value_str
	for prefix in [">=", "<=", "!=", ">", "<"]:
		if value_str.begins_with(prefix):
			op = prefix
			rhs_str = value_str.substr(prefix.length()).strip_edges()
			break
	if op.is_empty():
		return str(actual) == value_str
	var rhs := float(rhs_str)
	var lhs := float(actual)
	match op:
		">":  return lhs > rhs
		"<":  return lhs < rhs
		">=": return lhs >= rhs
		"<=": return lhs <= rhs
		"!=": return lhs != rhs
	return false

# ---------------------------------------------------------------------------
# World-state writer
# ---------------------------------------------------------------------------

func _write_world_state(key: String, value) -> void:
	Globals.world_state[key] = value

# ---------------------------------------------------------------------------
# Date helpers (match EventScheduler._today_stamp packing)
# ---------------------------------------------------------------------------

func _today_stamp() -> int:
	if TimeManager == null:
		return 0
	return _today_stamp_from(TimeManager.current_year, TimeManager.current_month, TimeManager.current_day)

func _today_stamp_from(year: int, month: int, day: int) -> int:
	return year * 10000 + month * 100 + day

# Approximate day delta from packed stamps. Same month/year -> exact; across
# months we approximate with 36 days per month (TimeManager.DAYS_PER_MONTH).
# Quests that need true precision can use date_passed::<Y-M-D> instead.
func _days_between(start_stamp: int, end_stamp: int) -> int:
	var sy := int(start_stamp / 10000)
	var sm := int((start_stamp / 100) % 100)
	var sd := int(start_stamp % 100)
	var ey := int(end_stamp / 10000)
	var em := int((end_stamp / 100) % 100)
	var ed := int(end_stamp % 100)
	var days_per_month := 36
	return (ey - sy) * (days_per_month * 10) + (em - sm) * days_per_month + (ed - sd)
