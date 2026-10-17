# DialogueActions.gd
# The dialogue action API: what a conversation can DO (spawn guards, start a
# fight, hand over an item, move standing, advance a quest...) and what it can
# CHECK (has the item, knows the quest, is in the party...). Owned by
# DialogueManager (Global/Dialogue_Manager.gd), which preloads this script;
# no class_name. Reference: docs/dialogue_actions.md.
#
# Where actions live in data/Dialogues.json:
#   node   "on_enter": [...]   when the node is shown, before its first line
#   node   "actions":  [...]   after its last line, before choices / next / branch
#   choice "actions":  [...]   when the player picks it, before it navigates
# Each entry is {"type": "<action>", ...fields}. A plain string is the older
# call syntax ("QuestManager.start_quest('x')") and still works.
#
# Where checks live:
#   choice "requires": [...]   unmet -> the option shows greyed out, with why
#   choice "show_if":  [...]   unmet -> the option is not offered at all
#   "branch": [{"if": [...], "next": "node"}, ..., {"next": "fallback"}]
# Each check is {"type": "<check>", ...fields}, optionally "not": true.
#
# Rules this file keeps:
#   - Every bad action or check (unknown type, missing field, unknown item,
#     nobody matches the name...) is a push_warning naming the dialogue and
#     node, and is skipped. Nothing here may end or crash a conversation.
#   - Hostility only ever changes through FactionDatabase relations (the
#     oracle's data): turning someone hostile moves them into a faction made
#     at runtime. Crimes and pardons go through CrimeManager / LawDatabase.
#   - What the player's side gains, loses or suffers is said: floating text
#     over the character and/or a game-log line. NPC-only changes are logged
#     only when the party can see that NPC.
extends RefCounted

const EquipmentEffects = preload("res://Items/equipment_effects.gd")

# type -> required fields. Checked when Dialogues.json loads and before each
# run. Optional fields are listed in docs/dialogue_actions.md.
const ACTIONS := {
	# world state
	"set_flag": ["flag"],
	"add_to_flag": ["flag", "amount"],
	"clear_flag": ["flag"],
	# quests
	"start_quest": ["quest"],
	"set_quest_stage": ["quest", "stage"],
	"complete_quest": ["quest"],
	"fail_quest": ["quest"],
	"turn_in_quest": ["quest"],
	# items and gold
	"give_item": ["item"],
	"take_item": ["item"],
	"give_gold": ["amount"],
	"take_gold": ["amount"],
	# characters
	"spawn": ["template"],
	"despawn": ["who"],
	"walk_to": ["who", "to"],
	"teleport": ["who", "to"],
	"set_faction": ["who", "faction"],
	"make_hostile": ["who"],
	"make_peaceful": ["who"],
	"start_combat": ["attackers"],
	"join_party": ["who"],
	"leave_party": ["who"],
	"apply_condition": ["who", "condition"],
	"remove_condition": ["who", "condition"],
	"heal": ["who"],
	"damage": ["who", "amount"],
	"add_trait": ["who", "trait"],
	"remove_trait": ["who", "trait"],
	"change_favor": ["who", "amount"],
	"set_dialogue": ["who", "dialogue"],
	"tag": ["who", "tag"],
	# factions and the law
	"change_standing": ["faction", "amount"],
	"set_relation": ["faction", "other", "relation"],
	"change_faction_tier": ["faction", "amount"],
	"report_crime": ["statute"],
	"pardon": ["faction"],
	# conversation
	"log": ["text"],
	"start_dialogue": ["dialogue"],
	"call": ["call"],
}

const CHECKS := {
	"flag": ["flag"],
	"quest": ["quest", "state"],
	"can_turn_in": ["quest"],
	"has_item": ["item"],
	"has_gold": ["amount"],
	"standing": ["faction"],
	"stance": ["faction", "is"],
	"outlaw": ["faction"],
	"hostile": ["a", "b"],
	"in_party": ["who"],
	"present": ["who"],
	"has_condition": ["who", "condition"],
	"has_trait": ["who", "trait"],
	"favor": ["who"],
	"ability_check": ["stat"],
	"any": ["of"],
	"all": ["of"],
}

const QUEST_STATES := ["active", "completed", "failed", "not_started", "started", "done"]
const STANCES := ["hostile", "neutral", "friendly"]
const RELATIONS := ["enemy", "ally", "neutral"]

const GAIN_COLOR := Color(0.55, 1.0, 0.55)
const LOSS_COLOR := Color(1.0, 0.7, 0.35)
const HOSTILE_COLOR := Color(1.0, 0.35, 0.3)

## Characters made by "spawn" get spawn ordinals from here, far above the
## per-map ordinals Game stamps (0, 1, 2...), so if one dies and Game persists
## its corpse the record can never be mistaken for a map NPC on a revisit.
const SPAWN_ORDINAL_BASE := 10000
var _spawn_counter: int = 0

var manager: Node   # DialogueManager
## Where the action being run sits, for warnings ("Federica_greet/end-convo").
var _where: String = ""
## Set by start_combat; DialogueManager pauses the game when the
## conversation closes, so the player can plan the fight.
var pause_requested: bool = false


func _init(dialogue_manager: Node) -> void:
	manager = dialogue_manager


# ===========================================================================
# Running
# ===========================================================================

## Run a list of actions (or one). `where` names the slot for warnings and
## for "once" ("on_enter", "actions", "choice 2").
func run_list(actions, where: String = "") -> void:
	if actions == null:
		return
	if actions is String or actions is Dictionary:
		actions = [actions]
	if not (actions is Array):
		_warn("'actions' must be a list, got %s" % type_string(typeof(actions)), where)
		return
	for i in range(actions.size()):
		var entry = actions[i]
		if entry is String:
			var call_string: String = str(entry).strip_edges()
			if not call_string.is_empty():
				manager.evaluate_function_call(call_string)
			continue
		if not (entry is Dictionary):
			_warn("action #%d is not an object: %s" % [i + 1, str(entry)], where)
			continue
		# "once": true -> after it has worked once (saved in world_state),
		# later visits to this node / choice skip it.
		var once_key: String = ""
		if bool(entry.get("once", false)):
			once_key = "dialogue_once::%s/%s/%s#%d" % [manager.current_dialogue_id, manager.current_node_id, where, i]
			if bool(Globals.world_state.get(once_key, false)):
				continue
		if run(entry, where) and not once_key.is_empty():
			Globals.world_state[once_key] = true


## Run one action. False when it was refused (and warned about).
func run(action: Dictionary, where: String = "") -> bool:
	_where = where
	var type: String = str(action.get("type", ""))
	if not ACTIONS.has(type):
		_warn("unknown action type '%s' (skipped)" % type, where)
		return false
	for field in ACTIONS[type]:
		if not action.has(field):
			_warn("%s: missing field '%s' (skipped)" % [type, field], where)
			return false
	var ok = call("_do_" + type, action)
	return ok == true


# ===========================================================================
# Checks
# ===========================================================================

## True when every check passes. Accepts one check, a list of checks, or a
## condition string in the older syntax (evaluated by DialogueManager).
func check_all(checks) -> bool:
	if checks == null:
		return true
	if checks is String:
		return manager.evaluate_condition(checks)
	if checks is Dictionary:
		return check(checks)
	if checks is Array:
		for c in checks:
			if not check_all(c):
				return false
		return true
	_warn("checks must be an object or a list, got %s" % type_string(typeof(checks)))
	return false


func check(c: Dictionary) -> bool:
	var type: String = str(c.get("type", ""))
	if not CHECKS.has(type):
		_warn("unknown check type '%s' (counts as unmet)" % type)
		return false
	for field in CHECKS[type]:
		if not c.has(field):
			_warn("check %s: missing field '%s' (counts as unmet)" % [type, field])
			return false
	var result: bool = call("_check_" + type, c) == true
	return not result if bool(c.get("not", false)) else result


## Why the first unmet check fails, in words for a greyed-out option
## ("Needs 20 gold"). "" when everything passes.
func unmet_reason(checks) -> String:
	if checks == null:
		return ""
	if checks is Array:
		for c in checks:
			var r: String = unmet_reason(c)
			if not r.is_empty():
				return r
		return ""
	if checks is String:
		return "" if manager.evaluate_condition(checks) else "Not available"
	if checks is Dictionary:
		if check(checks):
			return ""
		return _describe(checks)
	return "Not available"


func _describe(c: Dictionary) -> String:
	var neg: bool = bool(c.get("not", false))
	match str(c.get("type", "")):
		"has_item":
			var n: int = int(c.get("count", 1))
			var item_name: String = _item_name(str(c.get("item", "")))
			if neg:
				return "Not while carrying %s" % item_name
			return "Needs %s" % (item_name if n <= 1 else "%d x %s" % [n, item_name])
		"has_gold":
			return "Needs %d gold" % int(c.get("amount", 0)) if not neg else "Too much gold"
		"quest":
			var qn: String = _quest_name(str(c.get("quest", "")))
			match str(c.get("state", "")):
				"active", "started":
					return ("Not during %s" % qn) if neg else ("Needs the quest %s" % qn)
				"completed", "done":
					return ("Only before finishing %s" % qn) if neg else ("Finish %s first" % qn)
				"not_started":
					return "Only before taking on %s" % qn
			return "Depends on %s" % qn
		"can_turn_in":
			return "Needs what %s asks for" % _quest_name(str(c.get("quest", "")))
		"standing":
			var fname: String = _faction_name(str(c.get("faction", "")))
			if c.has("at_least"):
				return "Needs standing %d with %s" % [int(c["at_least"]), fname]
			return "Standing with %s too high" % fname
		"stance":
			return "%s must be %s" % [_faction_name(str(c.get("faction", ""))), str(c.get("is", ""))]
		"outlaw":
			return ("Wanted by %s" % _faction_name(str(c.get("faction", "")))) if neg \
				else ("Only while wanted by %s" % _faction_name(str(c.get("faction", ""))))
		"in_party":
			return "%s must %s the party" % [str(c.get("who", "")), "not be in" if neg else "be in"]
		"present":
			return "%s isn't here" % str(c.get("who", "")) if not neg else "Not with %s here" % str(c.get("who", ""))
		"has_trait":
			return "Needs %s %d" % [str(c.get("trait", "")), int(c.get("at_least", 1))] if not neg \
				else "Not for the %s" % str(c.get("trait", ""))
		"favor":
			return "%s must like you more" % str(c.get("who", "")) if c.has("at_least") \
				else "%s likes you too much" % str(c.get("who", ""))
		"has_condition":
			return "Needs %s" % _condition_name(str(c.get("condition", ""))) if not neg \
				else "Not while %s" % _condition_name(str(c.get("condition", "")))
		"all":
			if not neg:
				var inner: String = unmet_reason(c.get("of", []))
				if not inner.is_empty():
					return inner
	return "Not available"


func _check_flag(c: Dictionary) -> bool:
	var key: String = _flag_key(c, true)
	if key.is_empty():
		return false
	var v = Globals.world_state.get(key, null)
	# world_state holds bools, numbers and strings side by side, and GDScript
	# raises a script error on == / != between different types (an int flag
	# compared with false), so every comparison below is type-safe.
	if c.has("equals"):
		return v != null and _same_value(v, c["equals"])
	if c.has("at_least"):
		return _flag_number(v) >= float(c["at_least"])
	if c.has("at_most"):
		return _flag_number(v) <= float(c["at_most"])
	# Bare "is it set": anything but missing, false, 0 or "".
	if v == null:
		return false
	if v is bool:
		return v
	if v is int or v is float:
		return float(v) != 0.0
	return str(v) != "" and str(v) != "0"


## A flag's value as a number: true = 1, false / missing / text = 0.
func _flag_number(v) -> float:
	if v is bool:
		return 1.0 if v else 0.0
	if v is int or v is float:
		return float(v)
	if v is String and v.is_valid_float():
		return float(v)
	return 0.0


## Equality across the types JSON and world_state mix (3 == 3.0, "3" == 3).
func _same_value(a, b) -> bool:
	var a_num: bool = a is int or a is float
	var b_num: bool = b is int or b is float
	if a_num and b_num:
		return is_equal_approx(float(a), float(b))
	if typeof(a) == typeof(b):
		return a == b
	if a_num and b is String and b.is_valid_float():
		return is_equal_approx(float(a), float(b))
	if b_num and a is String and a.is_valid_float():
		return is_equal_approx(float(a), float(b))
	return str(a) == str(b)


func _check_quest(c: Dictionary) -> bool:
	var qid: String = str(c["quest"])
	if not _quest_known(qid):
		return false
	var active: bool = QuestManager.is_quest_active(qid)
	var done: bool = QuestManager.is_quest_completed(qid)
	var failed: bool = QuestManager.is_quest_failed(qid)
	var ok: bool = false
	match str(c["state"]):
		"active":
			ok = active
		"completed", "done":
			ok = done
		"failed":
			ok = failed
		"not_started":
			ok = not active and not done and not failed
		"started":
			ok = active or done or failed
		_:
			_warn("check quest: state must be one of %s, got '%s'" % [str(QUEST_STATES), str(c["state"])])
			return false
	if ok and c.has("stage"):
		ok = active and str(QuestManager.active.get(qid, "")) == str(c["stage"])
	return ok


func _check_can_turn_in(c: Dictionary) -> bool:
	var who = _first(c.get("who", "protagonist"), true)
	return who != null and _quest_known(str(c["quest"])) and QuestManager.can_turn_in(str(c["quest"]), who)


func _check_has_item(c: Dictionary) -> bool:
	var item_id: String = str(c["item"])
	if not _item_known(item_id):
		return false
	return _count_items(_chars(c.get("who", "party"), false, true), item_id) >= maxi(1, int(c.get("count", 1)))


func _check_has_gold(c: Dictionary) -> bool:
	return _count_items(_chars(c.get("who", "party"), false, true), "gold") >= int(c["amount"])


func _check_standing(c: Dictionary) -> bool:
	var f: String = str(c["faction"])
	if not _faction_known(f):
		return false
	var v: int = FactionDatabase.get_player_standing(f)
	if c.has("at_least") and v < int(c["at_least"]):
		return false
	if c.has("at_most") and v > int(c["at_most"]):
		return false
	return c.has("at_least") or c.has("at_most") or v != 0


func _check_stance(c: Dictionary) -> bool:
	var f: String = str(c["faction"])
	if not _faction_known(f):
		return false
	if not str(c["is"]) in STANCES:
		_warn("check stance: 'is' must be one of %s" % str(STANCES))
		return false
	return FactionDatabase.player_stance_toward(f) == str(c["is"])


func _check_outlaw(c: Dictionary) -> bool:
	var f: String = str(c["faction"])
	if f == "any":
		return FactionDatabase.is_outlaw_anywhere()
	return _faction_known(f) and FactionDatabase.is_outlaw_with(f)


## "a" and "b": faction ids, or character references (their faction).
func _check_hostile(c: Dictionary) -> bool:
	var fa: String = _faction_of_ref(c["a"], true)
	var fb: String = _faction_of_ref(c["b"], true)
	if fa.is_empty() or fb.is_empty():
		return false
	return FactionDatabase.are_hostile(fa, fb)


func _check_in_party(c: Dictionary) -> bool:
	var found: Array = _chars(c["who"], false, true)
	if found.is_empty():
		return false
	for ch in found:
		if not _is_party(ch):
			return false
	return true


func _check_present(c: Dictionary) -> bool:
	return not _chars(c["who"], false, true).is_empty()


func _check_has_condition(c: Dictionary) -> bool:
	var cid: String = str(c["condition"])
	for ch in _chars(c["who"], false, true):
		var cm = ch.get_node_or_null("ConditionManager")
		if cm != null and cm.has_condition(cid):
			return true
	return false


func _check_has_trait(c: Dictionary) -> bool:
	var need: int = int(c.get("at_least", 1))
	for ch in _chars(c["who"], false, true):
		if "traits" in ch and int(ch.traits.get(str(c["trait"]), 0)) >= need:
			return true
	return false


func _check_favor(c: Dictionary) -> bool:
	var ch = _first(c["who"], true)
	if ch == null or not ("favorability" in ch):
		return false
	var v: int = int(ch.favorability)
	if c.has("at_least") and v < int(c["at_least"]):
		return false
	if c.has("at_most") and v > int(c["at_most"]):
		return false
	return true


## A real roll, logged like every dialogue check ("<Name> passes a Charisma
## check (rolled 34 vs 60)."). For branches, not for "requires".
func _check_ability_check(c: Dictionary) -> bool:
	var ch = _first(c.get("who", "protagonist"), true)
	if ch == null or not ch.has_method("ability_check"):
		return false
	var domain = null
	if c.has("target"):
		domain = int(c["target"])
	else:
		domain = {"advantages": c.get("advantages", []), "disadvantages": c.get("disadvantages", [])}
	var result = ch.ability_check(str(c["stat"]), domain)
	manager._log_ability_check(ch, [str(c["stat"])], result)
	return (typeof(result) in [TYPE_INT, TYPE_FLOAT] and result > 0) or (result is bool and result)


func _check_any(c: Dictionary) -> bool:
	if not (c["of"] is Array):
		_warn("check any: 'of' must be a list of checks")
		return false
	for sub in c["of"]:
		if check_all(sub):
			return true
	return false


func _check_all(c: Dictionary) -> bool:
	if not (c["of"] is Array):
		_warn("check all: 'of' must be a list of checks")
		return false
	return check_all(c["of"])


# ===========================================================================
# Actions: world state
# ===========================================================================

func _do_set_flag(a: Dictionary) -> bool:
	var key: String = _flag_key(a)
	if key.is_empty():
		return false
	Globals.world_state[key] = a.get("value", true)
	QuestManager.world_state_changed()
	return true


func _do_add_to_flag(a: Dictionary) -> bool:
	var key: String = _flag_key(a)
	if key.is_empty():
		return false
	var old = Globals.world_state.get(key, 0)
	var base: float = float(old) if (old is int or old is float) else 0.0
	var total: float = base + float(a["amount"])
	Globals.world_state[key] = int(total) if is_equal_approx(total, roundf(total)) else total
	QuestManager.world_state_changed()
	return true


func _do_clear_flag(a: Dictionary) -> bool:
	var key: String = _flag_key(a)
	if key.is_empty():
		return false
	Globals.world_state.erase(key)
	QuestManager.world_state_changed()
	return true


# ===========================================================================
# Actions: quests (QuestManager writes the log lines)
# ===========================================================================

func _do_start_quest(a: Dictionary) -> bool:
	var qid: String = str(a["quest"])
	if not _quest_known(qid, true):
		return false
	QuestManager.start_quest(qid)
	return true


func _do_set_quest_stage(a: Dictionary) -> bool:
	var qid: String = str(a["quest"])
	if not _quest_known(qid, true):
		return false
	if not QuestManager.is_quest_active(qid):
		if QuestManager.is_quest_completed(qid) or QuestManager.is_quest_failed(qid):
			_warn("set_quest_stage: quest '%s' is already over (skipped)" % qid)
			return false
		QuestManager.start_quest(qid)
	if not QuestManager.set_stage(qid, str(a["stage"])):
		_warn("set_quest_stage: quest '%s' has no stage '%s' (skipped)" % [qid, str(a["stage"])])
		return false
	return true


func _do_complete_quest(a: Dictionary) -> bool:
	var qid: String = str(a["quest"])
	if not _quest_known(qid, true):
		return false
	if QuestManager.is_quest_completed(qid):
		return true
	if QuestManager.is_quest_failed(qid):
		_warn("complete_quest: quest '%s' already failed (skipped)" % qid)
		return false
	if not QuestManager.is_quest_active(qid):
		QuestManager.start_quest(qid)
	return QuestManager.complete_quest(qid, _first(a.get("who", "protagonist"), true))


func _do_fail_quest(a: Dictionary) -> bool:
	var qid: String = str(a["quest"])
	if not _quest_known(qid, true):
		return false
	if not QuestManager.is_quest_active(qid):
		_warn("fail_quest: quest '%s' isn't active (skipped)" % qid)
		return false
	return QuestManager.fail_quest(qid, str(a.get("reason", "")))


func _do_turn_in_quest(a: Dictionary) -> bool:
	var qid: String = str(a["quest"])
	if not _quest_known(qid, true):
		return false
	var who = _first(a.get("who", "protagonist"))
	if who == null:
		return false
	if not QuestManager.turn_in(qid, who):
		# Gate the choice with a can_turn_in check to avoid this.
		_warn("turn_in_quest: '%s' can't be turned in by %s right now" % [qid, _name(who)])
		_say_party(who, "Can't hand that in", "%s doesn't have what %s asks for." % [_name(who), _quest_name(qid)], LOSS_COLOR)
		return false
	return true


# ===========================================================================
# Actions: items and gold
# ===========================================================================

func _do_give_item(a: Dictionary) -> bool:
	var item_id: String = str(a["item"])
	if not _item_known(item_id, true):
		return false
	var count: int = clampi(int(a.get("count", 1)), 1, 999)
	var targets: Array = _chars(a.get("to", "protagonist"), false, false, "give_item")
	if targets.is_empty():
		return false
	var any_ok: bool = false
	for ch in targets:
		var inv = ch.get_node_or_null("Inventory")
		if inv == null:
			_warn("give_item: %s has no inventory" % _name(ch))
			continue
		var given: int = 0
		var shown_name: String = ""
		for i in range(count):
			var data: Dictionary = ItemDatabase.get_item_data(item_id)
			if a.has("name"):
				data["display_name"] = str(a["name"])
			if a.has("description"):
				data["description"] = str(a["description"])
			shown_name = str(data.get("display_name", item_id.replace("_", " ")))
			var stackable: bool = bool(data.get("is_stackable", false))
			if stackable:
				data["num_stacks"] = count - given
			var equip_slot: String = str(data.get("equip_slot", ""))
			var placed: int = 0
			if (equip_slot == "Main Hand" or equip_slot == "Off Hand") and inv.has_method("stow_weapon_from_data"):
				# A hand item is stowed as a weapon, as a pick-up is.
				inv.stow_weapon_from_data(data)
				placed = 1
			elif inv.add_stack(data):
				placed = (count - given) if stackable else 1
			elif stackable:
				# add_stack writes back what it couldn't place; a full pack is
				# announced by the inventory itself (add_failed).
				placed = (count - given) - int(data.get("num_stacks", count - given))
			given += placed
			if stackable or placed == 0:
				break
		if given <= 0:
			continue
		any_ok = true
		var label: String = shown_name if given == 1 else "%s (x%d)" % [shown_name, given]
		if _is_party(ch):
			ch.notify("+" + label, GAIN_COLOR, "%s receives %s." % [_name(ch), label])
		elif _seen(ch):
			GameLog.add_entry("%s takes %s." % [_name(ch), label])
	return any_ok


func _do_take_item(a: Dictionary) -> bool:
	var item_id: String = str(a["item"])
	if not _item_known(item_id, true):
		return false
	var count: int = clampi(int(a.get("count", 1)), 1, 999)
	var pool: Array = _chars(a.get("from", "party"), false, false, "take_item")
	if pool.is_empty():
		return false
	var have: int = _count_items(pool, item_id)
	var item_name: String = _item_name(item_id)
	if have < count:
		# All or nothing. Gate the choice with a has_item check to avoid this.
		_warn("take_item: only %d of %d '%s' to take (nothing taken)" % [have, count, item_id])
		_say_party(pool[0], "Missing " + item_name, "%s doesn't have %s." % [_name(pool[0]), item_name if count == 1 else "%d x %s" % [count, item_name]], LOSS_COLOR)
		return false
	var receiver = null
	if a.has("to"):
		receiver = _first(a["to"])
		if receiver == null:
			return false
	var removed: Array = _remove_items(pool, item_id, count)
	var taken_from: Dictionary = {}
	for r in removed:
		var who = r["from"]
		taken_from[who] = int(taken_from.get(who, 0)) + int(r["count"])
		if receiver != null:
			var rinv = receiver.get_node_or_null("Inventory")
			var data: Dictionary = r["data"]
			if rinv != null and bool(r.get("weapon", false)):
				rinv.stow_weapon_from_data(data)
			elif rinv == null or not rinv.add_stack(data):
				_warn("take_item: %s couldn't hold %s; it was dropped from the conversation" % [_name(receiver), item_name])
	for who in taken_from:
		var n: int = int(taken_from[who])
		var label: String = item_name if n == 1 else "%s (x%d)" % [item_name, n]
		var line: String = "%s gives %s to %s." % [_name(who), label, _name(receiver)] if receiver != null \
			else "%s loses %s." % [_name(who), label]
		if _is_party(who):
			who.notify("-" + label, LOSS_COLOR, line)
		elif _seen(who):
			GameLog.add_entry(line)
	if receiver != null and _is_party(receiver):
		receiver.notify("+" + item_name, GAIN_COLOR)
	return true


func _do_give_gold(a: Dictionary) -> bool:
	var amount: int = int(a["amount"])
	if amount <= 0:
		_warn("give_gold: amount must be above 0")
		return false
	var ch = _first(a.get("to", "protagonist"), false, "give_gold")
	if ch == null:
		return false
	var inv = ch.get_node_or_null("Inventory")
	var data: Dictionary = ItemDatabase.get_item_data("gold")
	if inv == null or data.is_empty():
		_warn("give_gold: %s can't hold gold" % _name(ch))
		return false
	data["num_stacks"] = amount
	data["is_stackable"] = true
	var placed: int = amount
	if not inv.add_stack(data):
		placed = amount - int(data.get("num_stacks", amount))
	if placed <= 0:
		return false
	if _is_party(ch):
		ch.notify("+%d gold" % placed, GAIN_COLOR, "%s receives %d gold." % [_name(ch), placed])
	elif _seen(ch):
		GameLog.add_entry("%s takes %d gold." % [_name(ch), placed])
	return true


func _do_take_gold(a: Dictionary) -> bool:
	var amount: int = int(a["amount"])
	if amount <= 0:
		_warn("take_gold: amount must be above 0")
		return false
	var pool: Array = _chars(a.get("from", "party"), false, false, "take_gold")
	if pool.is_empty():
		return false
	var have: int = _count_items(pool, "gold")
	if have < amount:
		_warn("take_gold: only %d of %d gold to take (nothing taken)" % [have, amount])
		_say_party(pool[0], "Not enough gold", "%s can't pay %d gold (has %d)." % [_name(pool[0]), amount, have], LOSS_COLOR)
		return false
	var receiver = _first(a["to"]) if a.has("to") else null
	var removed: Array = _remove_items(pool, "gold", amount)
	var paid: Dictionary = {}
	for r in removed:
		paid[r["from"]] = int(paid.get(r["from"], 0)) + int(r["count"])
	if receiver != null:
		var rinv = receiver.get_node_or_null("Inventory")
		var gdata: Dictionary = ItemDatabase.get_item_data("gold")
		gdata["num_stacks"] = amount
		gdata["is_stackable"] = true
		if rinv == null or not rinv.add_stack(gdata):
			_warn("take_gold: %s couldn't hold the gold; it was dropped from the conversation" % _name(receiver))
	for who in paid:
		var n: int = int(paid[who])
		var line: String = "%s pays %d gold to %s." % [_name(who), n, _name(receiver)] if receiver != null \
			else "%s pays %d gold." % [_name(who), n]
		if _is_party(who):
			who.notify("-%d gold" % n, LOSS_COLOR, line)
		elif _seen(who):
			GameLog.add_entry(line)
	return true


# ===========================================================================
# Actions: characters
# ===========================================================================

func _do_spawn(a: Dictionary) -> bool:
	var template: String = str(a["template"])
	if not TopDownCharacterDatabase.get_all_template_ids().has(template):
		_warn("spawn: no character template '%s' (skipped)" % template)
		return false
	var g = _game()
	if g == null or not g.has_method("_spawn_character"):
		_warn("spawn: no Game scene to spawn into (skipped)")
		return false
	var count: int = clampi(int(a.get("count", 1)), 1, 20)
	# "at" a place; "near" a character. With both, "near" is the fallback
	# for a map that lacks the place.
	var anchor = null
	var by_near: bool = false
	if a.has("at"):
		anchor = _resolve_position(a["at"], not a.has("near"))
	if anchor == null and a.has("near"):
		var near = _first(a["near"], false, "spawn")
		if near != null:
			anchor = near.global_position
			by_near = true
	if anchor == null:
		if not a.has("at") and not a.has("near"):
			_warn("spawn: needs 'at' (a place) or 'near' (a character) (skipped)")
		return false
	# Default spacing: a ring round someone ("near"), a huddle at a place.
	var spread: float = float(a.get("distance", 64.0 if by_near else (40.0 if count > 1 else 0.0)))
	var overrides: Dictionary = {}
	if a.has("faction"):
		if not _faction_known(str(a["faction"]), true):
			return false
		overrides["faction"] = str(a["faction"])
	if a.has("titles") and a["titles"] is Array:
		overrides["titles"] = a["titles"]
	# "name": one name for all, or a list naming them in order (the rest
	# keep the template's name).
	var names = a.get("name", null)
	var spawned: Array = []
	# Nobody lands on a tile someone already stands on (the party included).
	var used: Dictionary = _occupied_tiles([])
	for i in range(count):
		var pos: Vector2 = _placement(anchor, i, count, spread, used)
		var ov: Dictionary = overrides.duplicate()
		if names is Array:
			if i < names.size() and str(names[i]) != "":
				ov["unique_name"] = str(names[i])
		elif names != null and str(names) != "":
			ov["unique_name"] = str(names)
		var c = g._spawn_character(template, pos, ov)
		if c == null:
			_warn("spawn: '%s' refused to spawn here (its spawn_conditions)" % template)
			continue
		c.AI_enabled = true
		_spawn_counter += 1
		c.set_meta("spawn_ordinal", SPAWN_ORDINAL_BASE + _spawn_counter)
		c.set_meta("dialogue_spawned", true)
		if a.has("dialogue") and "dialogues" in c:
			c.dialogues = [str(a["dialogue"])] if str(a["dialogue"]) != "" else []
			c.current_dialogue_index = 0
		else:
			apply_persistent_dialogue(c)
		if a.has("tag"):
			_add_tag(c, str(a["tag"]))
		# As Game._spawn_npcs: hidden until the party's sight finds them, with
		# their own (stealth-mode) sight cone.
		if g.has_method("_add_npc_line_of_sight_light"):
			g._add_npc_line_of_sight_light(c)
		c.visible = false
		spawned.append(c)
	if spawned.is_empty():
		return false
	# "Centurion and Town Guard (x3) arrive." when the party can see them.
	var seen_names: Array = []
	var seen_counts: Dictionary = {}
	for c in spawned:
		if _seen(c):
			var nm: String = _name(c)
			if not seen_counts.has(nm):
				seen_names.append(nm)
			seen_counts[nm] = int(seen_counts.get(nm, 0)) + 1
	if not seen_names.is_empty():
		var parts: Array = []
		var total: int = 0
		for nm in seen_names:
			parts.append(nm if int(seen_counts[nm]) == 1 else "%s (x%d)" % [nm, int(seen_counts[nm])])
			total += int(seen_counts[nm])
		GameLog.add_entry("%s %s." % [_join_names(parts), "arrives" if total == 1 else "arrive"])
	return true


func _do_despawn(a: Dictionary) -> bool:
	var found: Array = _chars(a["who"], true, false, "despawn")
	if found.is_empty():
		return false
	var g = _game()
	var removed: int = 0
	for c in found:
		if _is_party(c):
			_warn("despawn: %s is in the party; use leave_party first (skipped)" % _name(c))
			continue
		removed += 1
		var seen: bool = _seen(c)
		var who: String = _name(c)
		if g != null and g.has_method("despawn_character"):
			g.despawn_character(c)
		else:
			if g != null and "characters_in_scene" in g:
				g.characters_in_scene.erase(c)
			c.queue_free()
		if seen and not bool(a.get("quiet", false)):
			GameLog.add_entry("%s leaves." % who)
	return removed > 0


func _do_walk_to(a: Dictionary) -> bool:
	var pos = _resolve_position(a["to"])
	if pos == null:
		return false
	var any_ok: bool = false
	for c in _chars(a["who"], false, false, "walk_to"):
		if bool(c.get("is_player_controlled")):
			_warn("walk_to: %s is under the player's control; use teleport (skipped)" % _name(c))
			continue
		var ai = c.get_node_or_null("AI")
		if ai == null or not ai.has_method("navigate_to"):
			_warn("walk_to: %s has no AI to walk with (skipped)" % _name(c))
			continue
		c.AI_enabled = true
		ai.navigate_to(pos)
		if ai.nav_path.is_empty() and c.global_position.distance_to(pos) > 48.0:
			_warn("walk_to: no path for %s to %s" % [_name(c), str(pos)])
			continue
		# Stay there instead of wandering off once they arrive.
		if bool(a.get("stay", true)) and "wander_cooldown" in ai:
			ai.wander_cooldown = 600.0
		any_ok = true
	return any_ok


func _do_teleport(a: Dictionary) -> bool:
	var pos = _resolve_position(a["to"])
	if pos == null:
		return false
	var found: Array = _chars(a["who"], false, false, "teleport")
	var used: Dictionary = _occupied_tiles(found)
	for i in range(found.size()):
		var c = found[i]
		c.global_position = _placement(pos, i, found.size(), 40.0 if found.size() > 1 else 0.0, used)
		c.is_moving = false
		c.target_position = c.global_position
		var ai = c.get_node_or_null("AI")
		if ai != null and "nav_path" in ai:
			ai.nav_path.clear()
		if c.has_method("_refresh_elevation"):
			c._refresh_elevation()
	return not found.is_empty()


func _do_set_faction(a: Dictionary) -> bool:
	var f: String = str(a["faction"])
	if not _faction_known(f, true):
		return false
	var changed: Array = []
	for c in _chars(a["who"], false, false, "set_faction"):
		if _is_party(c):
			_warn("set_faction: %s is in the party; use leave_party first (skipped)" % _name(c))
			continue
		if c.faction_id == f:
			continue
		_remember_faction(c)
		c.set_faction(f)
		changed.append(c)
		if _seen(c):
			var stance: String = FactionDatabase.player_stance_toward(f) if f != "player" else "friendly"
			c.notify(_faction_name(f), HOSTILE_COLOR if stance == "hostile" else Color.WHITE,
				"%s now sides with %s%s." % [_name(c), _faction_name(f), " (hostile to you)" if stance == "hostile" else ""])
	_drop_stale_targets()
	return not changed.is_empty()


## Turn characters against someone (the party by default) WITHOUT touching
## their whole faction: they move into a faction made at runtime, copied
## from their own (so their old comrades stay friends), that is at war with
## the targets. are_hostile reads it like any faction.
func _do_make_hostile(a: Dictionary) -> bool:
	var who: Array = _chars(a["who"], false, false, "make_hostile")
	if who.is_empty():
		return false
	var toward: Array = _target_factions(a.get("toward", "party"))
	if toward.is_empty():
		_warn("make_hostile: nobody to be hostile toward (skipped)")
		return false
	var turned: Array = _turn_hostile(who, toward, str(a.get("group", "")))
	_alert(turned, _chars_of_factions(toward))
	_drop_stale_targets()
	return not turned.is_empty()


func _do_make_peaceful(a: Dictionary) -> bool:
	var calmed: Array = []
	for c in _chars(a["who"], false, false, "make_peaceful"):
		if _is_party(c):
			continue
		var before: String = str(c.get_meta("faction_before_dialogue", ""))
		var to: String = str(a.get("faction", before))
		if to.is_empty():
			to = c.faction_id
		if not _faction_known(to, true):
			continue
		c.set_faction(to)
		var ai = c.get_node_or_null("AI")
		if ai != null and "manhunt_target" in ai:
			ai.manhunt_target = null
		calmed.append(c)
		if _seen(c):
			c.notify("Stands down", Color.WHITE, "%s stands down." % _name(c))
	_drop_stale_targets()
	return not calmed.is_empty()


func _do_start_combat(a: Dictionary) -> bool:
	var attackers: Array = _chars(a["attackers"], false, false, "start_combat")
	if attackers.is_empty():
		return false
	var target_ref = a.get("targets", "party")
	var toward: Array = _target_factions(target_ref)
	if toward.is_empty():
		_warn("start_combat: no targets (skipped)")
		return false
	var fighters: Array = []
	for c in attackers:
		if _is_party(c):
			_warn("start_combat: %s is in the party and won't be turned (use leave_party first)" % _name(c))
		else:
			fighters.append(c)
	if fighters.is_empty():
		return false
	# One "Combat!" line below says who turned; no per-character line too.
	_turn_hostile(fighters, toward, str(a.get("group", "")), false)
	var defenders: Array = _chars_of_factions(toward)
	_alert(fighters, defenders)
	_alert(defenders, fighters)
	_drop_stale_targets()
	var names: Array = []
	for c in fighters:
		names.append(_name(c))
	var at_party: bool = "player" in toward
	var others: Array = []
	for f in toward:
		if f != "player":
			others.append(_faction_name(f))
	var line: String
	if at_party and others.is_empty():
		line = "Combat! %s %s you." % [_join_names(names), "attacks" if names.size() == 1 else "attack"]
	elif at_party:
		line = "Combat! %s %s you and the %s." % [_join_names(names), "attacks" if names.size() == 1 else "attack", _join_names(others)]
	else:
		line = "Combat! %s %s the %s." % [_join_names(names), "turns on" if names.size() == 1 else "turn on", _join_names(others)]
	GameLog.add_entry(line)
	if bool(a.get("pause", true)):
		pause_requested = true
	return true


func _do_join_party(a: Dictionary) -> bool:
	var g = _game()
	if g == null or not ("party_chars" in g) or not ("party_state" in g):
		_warn("join_party: no party to join (skipped)")
		return false
	var joined: Array = []
	for c in _chars(a["who"], false, false, "join_party"):
		if _is_party(c):
			continue
		_remember_faction(c)
		var overrides: Dictionary = {}
		var tmpl_name: String = str(TopDownCharacterDatabase.get_template(str(c.template_id)).get("name", "")) \
			if str(c.template_id) != "" else ""
		if str(c.display_name) != tmpl_name:
			overrides["unique_name"] = str(c.display_name)
		g.party_state.append({"template_id": str(c.template_id), "overrides": overrides, "live_state": null})
		g.party_chars.append(c)
		c.set_meta("party_index", g.party_state.size() - 1)
		if "npc_unlimited_resources" in c:
			c.npc_unlimited_resources = false
		c.faction_id = "player"
		c.AI_enabled = true
		c.is_player_controlled = false
		c.visible = true
		var ai = c.get_node_or_null("AI")
		if ai != null and "manhunt_target" in ai:
			ai.manhunt_target = null
		if g.has_method("_clear_companion_ai"):
			g._clear_companion_ai(c)
		# Swap the NPC's stealth-mode cone for a party sight cone.
		for n in ["NPCLineOfSight", "NPCLineOfSightHigh"]:
			var light = c.get_node_or_null(n)
			if light != null:
				light.queue_free()
		if g.has_method("_add_line_of_sight_light") and c.get_node_or_null("LineOfSight") == null:
			g._add_line_of_sight_light(c)
		if g.has_method("_wire_ally_witness"):
			g._wire_ally_witness(c)
		if str(c.template_id) != "":
			Globals.world_state["in_party::" + str(c.template_id)] = true
		joined.append(c)
		c.notify("Joined the party", GAIN_COLOR, "%s joins the party." % _name(c))
	if not joined.is_empty():
		_refresh_party_panel()
		_drop_stale_targets()
	return not joined.is_empty()


func _do_leave_party(a: Dictionary) -> bool:
	var g = _game()
	if g == null or not ("party_chars" in g):
		return false
	var left: Array = []
	for c in _chars(a["who"], false, false, "leave_party"):
		if not _is_party(c):
			continue
		if bool(c.get("is_protagonist")) or c == g.get("player"):
			_warn("leave_party: the protagonist can't leave the party (skipped)")
			continue
		var row: int = int(c.get_meta("party_index", g.party_chars.find(c)))
		g.party_chars.erase(c)
		if "party_state" in g and row > 0 and row < g.party_state.size():
			g.party_state.remove_at(row)
			# Rows after it moved up one.
			for other in g.party_chars:
				if is_instance_valid(other) and int(other.get_meta("party_index", -1)) > row:
					other.set_meta("party_index", int(other.get_meta("party_index")) - 1)
		c.remove_meta("party_index")
		if "selected_characters" in g and c in g.selected_characters:
			if g.has_method("_remove_selection_circle"):
				g._remove_selection_circle(c)
			g.selected_characters.erase(c)
			if g.get("primary_selected") == c:
				g.primary_selected = null
				if g.has_method("select_character") and is_instance_valid(g.get("player")):
					g.select_character(g.player, 0)
		var to: String = str(a.get("faction", c.get_meta("faction_before_dialogue", "")))
		if to.is_empty() or not FactionDatabase.has_faction(to):
			to = str(TopDownCharacterDatabase.get_template(str(c.template_id)).get("faction", "neutral"))
		c.faction_id = to
		c.is_player_controlled = false
		c.AI_enabled = true
		var light = c.get_node_or_null("LineOfSight")
		if light != null:
			light.queue_free()
		if g.has_method("_add_npc_line_of_sight_light"):
			g._add_npc_line_of_sight_light(c)
		Globals.world_state.erase("in_party::" + str(c.template_id))
		left.append(c)
		c.notify("Left the party", LOSS_COLOR, "%s leaves the party." % _name(c))
	if not left.is_empty():
		_refresh_party_panel()
		_drop_stale_targets()
	return not left.is_empty()


func _do_apply_condition(a: Dictionary) -> bool:
	var cid: String = str(a["condition"])
	if not ConditionManager.condition_registry.has(cid):
		_warn("apply_condition: unknown condition '%s' (skipped)" % cid)
		return false
	var any_ok: bool = false
	var duration: float = float(a.get("duration", -2.0))
	var cname: String = _condition_name(cid)
	for c in _chars(a["who"], false, false, "apply_condition"):
		var cm = c.get_node_or_null("ConditionManager")
		if cm == null:
			continue
		var inst = cm.apply_condition(cid, null, maxi(1, int(a.get("stacks", 1))), duration)
		if inst != null:
			any_ok = true
			_say_seen(c, cname, "%s is now %s." % [_name(c), cname], Color.WHITE)
		else:
			_say_seen(c, "Resisted", "%s resists %s." % [_name(c), cname], Color(0.7, 0.85, 1.0))
	return any_ok


func _do_remove_condition(a: Dictionary) -> bool:
	var cid: String = str(a["condition"])
	var any_ok: bool = false
	var cname: String = _condition_name(cid)
	for c in _chars(a["who"], false, false, "remove_condition"):
		var cm = c.get_node_or_null("ConditionManager")
		if cm != null and cm.remove_condition(cid):
			any_ok = true
			_say_seen(c, "No longer " + cname, "%s is no longer %s." % [_name(c), cname], GAIN_COLOR)
	return any_ok


func _do_heal(a: Dictionary) -> bool:
	var any_ok: bool = false
	for c in _chars(a["who"], false, false, "heal"):
		var amount: int = int(c.max_health) if str(a.get("amount", "full")) == "full" else int(a.get("amount", 0))
		var healed: int = int(c.heal(amount)) if c.has_method("heal") else 0
		if healed > 0:
			any_ok = true
			# heal() floats "+N" itself; the log line says who and why.
			if _is_party(c):
				GameLog.add_entry("%s recovers %d HP." % [_name(c), healed])
	return any_ok


func _do_damage(a: Dictionary) -> bool:
	var amount: int = int(a["amount"])
	if amount <= 0:
		_warn("damage: amount must be above 0")
		return false
	var dtype: String = str(a.get("damage_type", "bludgeoning"))
	var any_ok: bool = false
	for c in _chars(a["who"], false, false, "damage"):
		if not c.has_method("take_damage"):
			continue
		# No attacker: a scripted hurt is nobody's crime and wakes no witness.
		var dealt: int = int(c.take_damage({dtype: amount}, c.global_position, null))
		any_ok = true
		if _is_party(c) or _seen(c):
			GameLog.add_entry("%s takes %d %s damage." % [_name(c), dealt, dtype])
	return any_ok


func _do_add_trait(a: Dictionary) -> bool:
	var trait_name: String = str(a["trait"])
	var tiers: int = int(a.get("tiers", 1))
	var any_ok: bool = false
	for c in _chars(a["who"], false, false, "add_trait"):
		if not ("traits" in c):
			continue
		var now: int = int(c.traits.get(trait_name, 0)) + tiers
		c.traits[trait_name] = now
		any_ok = true
		if _is_party(c):
			c.notify("%s %+d" % [trait_name, tiers], GAIN_COLOR,
				"%s gains the %s trait (now %d)." % [_name(c), trait_name, now])
	return any_ok


func _do_remove_trait(a: Dictionary) -> bool:
	var trait_name: String = str(a["trait"])
	var any_ok: bool = false
	for c in _chars(a["who"], false, false, "remove_trait"):
		if "traits" in c and c.traits.erase(trait_name):
			any_ok = true
			if _is_party(c):
				c.notify("Lost " + trait_name, LOSS_COLOR, "%s loses the %s trait." % [_name(c), trait_name])
	return any_ok


func _do_change_favor(a: Dictionary) -> bool:
	var any_ok: bool = false
	for c in _chars(a["who"], false, false, "change_favor"):
		if c.has_method("apply_favorability_delta"):
			# Announces itself ("Jacana approves (+3 favour, now 13).").
			c.apply_favorability_delta(int(a["amount"]), "dialogue:" + str(manager.current_dialogue_id))
			any_ok = true
	return any_ok


## Who says what when the player next talks to them. Remembered by template
## id (Globals.world_state "dialogue_for::<template>"), so it survives map
## changes and saves; "persist": false for this visit only. "" = nothing to say.
func _do_set_dialogue(a: Dictionary) -> bool:
	var did: String = str(a["dialogue"])
	if did != "" and not manager.dialogues.has(did):
		_warn("set_dialogue: no dialogue '%s' in Dialogues.json (skipped)" % did)
		return false
	var found: Array = _chars(a["who"], false, false, "set_dialogue")
	for c in found:
		if "dialogues" in c:
			c.dialogues = [did] if did != "" else []
			c.current_dialogue_index = 0
		if bool(a.get("persist", true)) and str(c.template_id) != "":
			Globals.world_state["dialogue_for::" + str(c.template_id)] = did
	return not found.is_empty()


func _do_tag(a: Dictionary) -> bool:
	var found: Array = _chars(a["who"], true, false, "tag")
	for c in found:
		_add_tag(c, str(a["tag"]))
	return not found.is_empty()


# ===========================================================================
# Actions: factions and the law
# ===========================================================================

func _do_change_standing(a: Dictionary) -> bool:
	var f: String = str(a["faction"])
	if not _faction_known(f, true):
		return false
	var amount: int = int(a["amount"])
	var before: int = FactionDatabase.get_player_standing(f)
	var stance_before: String = FactionDatabase.player_stance_toward(f)
	FactionDatabase.adjust_player_standing(f, amount)
	var after: int = FactionDatabase.get_player_standing(f)
	if after == before:
		return true
	var stance_after: String = FactionDatabase.player_stance_toward(f)
	var line: String = "Standing with %s: %+d (now %d)." % [_faction_name(f), after - before, after]
	if stance_after != stance_before:
		line += " They are now %s." % ("hostile to you" if stance_after == "hostile" else stance_after)
	var p = _first("protagonist", true)
	if p != null:
		p.notify("%s %+d" % [_faction_name(f), after - before], GAIN_COLOR if after > before else LOSS_COLOR, line)
	else:
		GameLog.add_entry(line)
	_drop_stale_targets()
	return true


func _do_set_relation(a: Dictionary) -> bool:
	var fa: String = _faction_of_ref(a["faction"])
	var fb: String = _faction_of_ref(a["other"])
	var rel: String = str(a["relation"])
	if fa.is_empty() or fb.is_empty():
		return false
	if not rel in RELATIONS:
		_warn("set_relation: relation must be one of %s, got '%s'" % [str(RELATIONS), rel])
		return false
	var was_hostile: bool = FactionDatabase.are_hostile(fa, fb)
	if not FactionDatabase.set_relation(fa, fb, rel):
		_warn("set_relation: can't relate '%s' and '%s'" % [fa, fb])
		return false
	var now_hostile: bool = FactionDatabase.are_hostile(fa, fb)
	if fa == "player" or fb == "player":
		var other: String = fb if fa == "player" else fa
		GameLog.add_entry("%s now counts you as %s." % [_faction_name(other), {"enemy": "an enemy", "ally": "an ally", "neutral": "neither friend nor foe"}[rel]])
	elif was_hostile != now_hostile or rel != "neutral":
		GameLog.add_entry("%s and %s are now %s." % [_faction_name(fa), _faction_name(fb), {"enemy": "enemies", "ally": "allies", "neutral": "at peace"}[rel]])
	_drop_stale_targets()
	return true


func _do_change_faction_tier(a: Dictionary) -> bool:
	var f: String = str(a["faction"])
	if not _faction_known(f, true):
		return false
	var before: int = FactionDatabase.get_faction_tier(f)
	FactionDatabase.adjust_faction_tier(f, int(a["amount"]))
	var after: int = FactionDatabase.get_faction_tier(f)
	if after != before:
		GameLog.add_entry("%s %s (tier %d)." % [_faction_name(f), "grows stronger" if after > before else "grows weaker", after])
	return true


func _do_report_crime(a: Dictionary) -> bool:
	var statute: String = str(a["statute"])
	if LawDatabase.statute_def(statute).is_empty():
		_warn("report_crime: laws.json has no statute '%s' (skipped)" % statute)
		return false
	var actor = _first(a.get("who", "protagonist"), true, "report_crime")
	if actor == null:
		return false
	var law: String = str(a.get("law", ""))
	if not law.is_empty() and not _faction_known(law, true):
		return false
	var witnesses: Array = _chars(a["witnesses"]) if a.has("witnesses") else []
	var verdict: Dictionary = CrimeManager.accuse(actor, statute, witnesses, law)
	if verdict.is_empty():
		var where_law: String = law if not law.is_empty() else CrimeManager.current_law_faction()
		_warn("report_crime: '%s' is not a crime for %s under the law here (%s)" % [statute, _name(actor), where_law if where_law != "" else "no jurisdiction"])
		return false
	return true


func _do_pardon(a: Dictionary) -> bool:
	var f: String = str(a["faction"])
	if not _faction_known(f, true):
		return false
	var was_outlaw: bool = FactionDatabase.is_outlaw_with(f)
	var standing_before: int = FactionDatabase.get_player_standing(f)
	CrimeManager.pardon(f)
	if was_outlaw or standing_before < 0:
		var p = _first("protagonist", true)
		var line: String = "%s pardons you. You are no longer wanted there." % _faction_name(f) if was_outlaw \
			else "%s pardons you; your standing is restored to %d." % [_faction_name(f), FactionDatabase.get_player_standing(f)]
		if p != null:
			p.notify("Pardoned", GAIN_COLOR, line)
		else:
			GameLog.add_entry(line)
	_drop_stale_targets()
	return true


# ===========================================================================
# Actions: conversation
# ===========================================================================

func _do_log(a: Dictionary) -> bool:
	GameLog.add_entry(manager.process_text(str(a["text"])))
	return true


func _do_start_dialogue(a: Dictionary) -> bool:
	var did: String = str(a["dialogue"])
	if not manager.dialogues.has(did):
		_warn("start_dialogue: no dialogue '%s' (skipped)" % did)
		return false
	# Queued: it starts when this conversation ends.
	manager.start_dialogue(did)
	return true


func _do_call(a: Dictionary) -> bool:
	manager.evaluate_function_call(str(a["call"]))
	return true


# ===========================================================================
# Hostility helpers
# ===========================================================================

## Faction ids a "toward"/"targets" reference means: "party"/"player" ->
## "player"; a faction id; a character reference -> that character's faction
## (party members -> "player"). A list mixes these.
func _target_factions(ref) -> Array:
	var out: Array = []
	var refs: Array = ref if ref is Array else [ref]
	for r in refs:
		var f: String = _faction_of_ref(r)
		if not f.is_empty() and not f in out:
			out.append(f)
	return out


func _faction_of_ref(ref, quiet: bool = false) -> String:
	var s: String = str(ref)
	if s in ["party", "player", "protagonist", "companions"]:
		return "player"
	if FactionDatabase.has_faction(s):
		return s
	var found: Array = _chars(ref, false, true)
	if found.is_empty():
		if not quiet:
			_warn("'%s' is neither a faction nor anyone here" % s)
		return ""
	return "player" if _is_party(found[0]) else str(found[0].faction_id)


func _turn_hostile(chars: Array, toward: Array, group: String, log_each: bool = true) -> Array:
	var turned: Array = []
	for c in chars:
		if _is_party(c):
			_warn("make_hostile: %s is in the party; use leave_party first (skipped)" % _name(c))
			continue
		var needed: Array = []
		for f in toward:
			if f != c.faction_id and not FactionDatabase.are_hostile(c.faction_id, f):
				needed.append(f)
		if needed.is_empty():
			turned.append(c)   # already hostile: nothing to change, still alerted
			continue
		var band: String = c.faction_id
		if not FactionDatabase.is_runtime_faction(band):
			band = group if not group.is_empty() else "band_" + _ident(c)
			if not FactionDatabase.create_runtime_faction(band, str(c.faction_id), "%s's band" % _name(c)):
				_warn("make_hostile: couldn't make a faction for %s" % _name(c))
				continue
		for f in needed:
			if f != band:
				FactionDatabase.set_relation(band, f, "enemy")
		_remember_faction(c)
		c.set_faction(band)
		turned.append(c)
		if _seen(c):
			var vs_party: bool = "player" in needed
			c.notify("Hostile!", HOSTILE_COLOR, "%s turns hostile." % _name(c) if vs_party and log_each else "")
	return turned


## Wake `who` and point them at the nearest of `at`: alertness into
## SEARCHING with the target's position as the last thing heard, so the AI
## walks over and acquires them by sight (its own rules decide the rest).
func _alert(who: Array, at: Array) -> void:
	for c in who:
		if not is_instance_valid(c) or _is_party(c):
			continue
		var ai = c.get_node_or_null("AI")
		if ai == null or not ai.has_method("wake_from_at_ease"):
			continue
		var best = null
		var best_d: float = INF
		for t in at:
			if not is_instance_valid(t) or t == c or not t.has_method("is_alive") or not t.is_alive():
				continue
			var d: float = c.global_position.distance_to(t.global_position)
			if d < best_d:
				best_d = d
				best = t
		if best == null:
			continue
		c.AI_enabled = true
		# 70: inside ai.gd's SEARCHING band (60..90). Sight, not this, makes
		# them HOSTILE, so a target behind a wall is searched for, not known.
		ai.wake_from_at_ease(70.0, best.global_position)


## Living characters in the scene whose faction is one of `factions` (the
## whole party for "player").
func _chars_of_factions(factions: Array) -> Array:
	var out: Array = []
	var g = _game()
	if g == null or not ("characters_in_scene" in g):
		return out
	for c in g.characters_in_scene:
		if not is_instance_valid(c) or not c.has_method("is_alive") or not c.is_alive():
			continue
		var f: String = "player" if _is_party(c) else str(c.faction_id)
		if f in factions:
			out.append(c)
	return out


## An AI holding a target it no longer counts as an enemy (peace was made, a
## faction changed sides) lets go; otherwise it would fight on regardless.
func _drop_stale_targets() -> void:
	var g = _game()
	if g == null or not ("characters_in_scene" in g):
		return
	for c in g.characters_in_scene:
		if not is_instance_valid(c):
			continue
		var ai = c.get_node_or_null("AI")
		if ai == null or not ("current_target" in ai):
			continue
		var t = ai.current_target
		if t != null and is_instance_valid(t) and ai.has_method("_is_enemy") and not ai._is_enemy(t):
			if ai.has_method("_lose_target"):
				ai._lose_target()


func _remember_faction(c) -> void:
	if not c.has_meta("faction_before_dialogue"):
		c.set_meta("faction_before_dialogue", str(c.faction_id))


# ===========================================================================
# After a map loads: set_dialogue choices, recruited characters
# ===========================================================================

## Called by DialogueManager when a map has loaded. Re-applies set_dialogue,
## and hides the map's own copy of anyone who joined the party (they travel
## with you now). Only for characters a single map places once — recruiting
## one town guard must not empty every guardhouse.
func on_map_loaded() -> void:
	var g = _game()
	if g == null or not ("characters_in_scene" in g):
		return
	for c in g.characters_in_scene.duplicate():
		if not is_instance_valid(c):
			continue
		apply_persistent_dialogue(c)
		if _is_party(c):
			continue
		var tid: String = str(c.get("template_id"))
		if tid != "" and bool(Globals.world_state.get("in_party::" + tid, false)) and _placed_once(tid):
			if g.has_method("despawn_character"):
				g.despawn_character(c)


var _placement_counts: Dictionary = {}

## True when Maps.json places this template at most once in the whole game.
func _placed_once(template_id: String) -> bool:
	if not _placement_counts.has(template_id):
		var n: int = 0
		for map_id in MapDatabase.get_all_map_ids():
			var spawns = MapDatabase.get_map_data(map_id).get("npc_spawns", [])
			if not (spawns is Array):
				continue
			for sp in spawns:
				if sp is Dictionary and str(sp.get("template_id", "")) == template_id:
					n += maxi(1, int(sp.get("count", 1)))
		_placement_counts[template_id] = n
	return int(_placement_counts[template_id]) <= 1


## Re-apply set_dialogue choices to a freshly spawned character. Called for
## every character after a map loads (DialogueManager) and by "spawn".
func apply_persistent_dialogue(c) -> void:
	if c == null or not is_instance_valid(c) or not ("template_id" in c) or str(c.template_id) == "":
		return
	var key: String = "dialogue_for::" + str(c.template_id)
	if not Globals.world_state.has(key) or not ("dialogues" in c):
		return
	var did: String = str(Globals.world_state[key])
	c.dialogues = [did] if did != "" else []
	c.current_dialogue_index = 0


# ===========================================================================
# References: who, where
# ===========================================================================

## Characters a reference names. A reference is a string, or a list of them:
##   "protagonist" / "player" / "leader"   the party leader
##   "partner"                             who the player opened the talk with
##   "party" / "companions"                the party / the party minus its leader
##   "tag:<name>"                          characters a spawn or tag action marked
##   anything else                         template id, name or display name,
##                                         case/hyphen/underscore-insensitive;
##                                         failing that, a whole word of a name
##                                         ("Federica" finds "Surgeon Captain Federica")
## Living characters only unless include_dead. Warns (naming `who_for`) when
## nobody matches, unless quiet.
func _chars(ref, include_dead: bool = false, quiet: bool = false, who_for: String = "") -> Array:
	var out: Array = []
	if ref is Array:
		for r in ref:
			for c in _chars(r, include_dead, true):
				if not c in out:
					out.append(c)
		if out.is_empty() and not quiet:
			_warn("%snobody matches %s" % [(who_for + ": ") if who_for != "" else "", str(ref)])
		return out
	var s: String = str(ref).strip_edges()
	var g = _game()
	var everyone: Array = g.characters_in_scene if (g != null and "characters_in_scene" in g) else []
	var party: Array = g.party_chars if (g != null and "party_chars" in g) else []
	var key: String = s.to_lower()
	match key:
		"protagonist", "player", "leader":
			var p = g.get("player") if g != null else null
			if p != null and is_instance_valid(p):
				out.append(p)
		"partner", "speaker":
			var partner = manager.get_partner() if manager.has_method("get_partner") else null
			if partner != null:
				out.append(partner)
		"party":
			out = party.duplicate()
		"companions":
			for c in party:
				if is_instance_valid(c) and c != g.get("player"):
					out.append(c)
		_:
			if key.begins_with("tag:"):
				var tag: String = s.substr(4)
				for c in everyone:
					if is_instance_valid(c) and tag in c.get_meta("dialogue_tags", []):
						out.append(c)
			else:
				var want: String = _norm(s)
				for c in everyone:
					if not is_instance_valid(c):
						continue
					if _norm(str(c.get("template_id"))) == want or _norm(str(c.get("display_name"))) == want \
							or _norm(str(c.get("Name"))) == want:
						out.append(c)
				if out.is_empty() and not want.is_empty():
					for c in everyone:
						if is_instance_valid(c) and (" " + _norm(str(c.get("display_name"))) + " ").contains(" " + want + " "):
							out.append(c)
	var living: Array = []
	for c in out:
		if not is_instance_valid(c):
			continue
		if not include_dead and c.has_method("is_alive") and not c.is_alive():
			continue
		living.append(c)
	if living.is_empty() and not quiet:
		_warn("%snobody here matches '%s'" % [(who_for + ": ") if who_for != "" else "", s])
	# Nearest to the leader first, so single-target actions pick sensibly.
	var p2 = g.get("player") if g != null else null
	if living.size() > 1 and p2 != null and is_instance_valid(p2) and s.to_lower() not in ["party", "companions"]:
		living.sort_custom(func(x, y): return x.global_position.distance_squared_to(p2.global_position) \
			< y.global_position.distance_squared_to(p2.global_position))
	return living


func _first(ref, quiet: bool = false, who_for: String = ""):
	var found: Array = _chars(ref, false, quiet, who_for)
	return found[0] if not found.is_empty() else null


## A place: [x, y]; a marker of the current map (its optional "markers"
## {name: [x, y]}, then a player_spawns key, then a warp_points id); or a
## character reference (where they stand).
func _resolve_position(spec, warn_if_missing: bool = true):
	if spec is Array and spec.size() == 2:
		return Vector2(float(spec[0]), float(spec[1]))
	if spec is Dictionary and spec.has("x") and spec.has("y"):
		return Vector2(float(spec["x"]), float(spec["y"]))
	var s: String = str(spec)
	if s.begins_with("marker:"):
		s = s.substr(7)
	var g = _game()
	var map_data: Dictionary = g.get("current_map_data") if (g != null and g.get("current_map_data") is Dictionary) else {}
	var markers = map_data.get("markers", {})
	if markers is Dictionary and markers.has(s) and markers[s] is Array and markers[s].size() >= 2:
		return Vector2(float(markers[s][0]), float(markers[s][1]))
	var spawns = map_data.get("player_spawns", {})
	if spawns is Dictionary and spawns.has(s):
		var p = spawns[s].get("position", null)
		if p is Array and p.size() >= 2:
			return Vector2(float(p[0]), float(p[1]))
	for w in map_data.get("warp_points", []):
		if w is Dictionary and str(w.get("id", "")) == s:
			var wp = w.get("position", null)
			if wp is Array and wp.size() >= 2:
				return Vector2(float(wp[0]), float(wp[1]))
	var c = _first(spec, true)
	if c != null:
		return c.global_position
	if warn_if_missing:
		_warn("no place or character called '%s' on this map" % s)
	return null


## The i-th of n positions around `anchor` at `distance`, on walkable ground
## when the map grid is loaded: an anchor inside a wall moves to the nearest
## open tile first, and `used` (shared across one action's calls) keeps two
## characters off the same tile.
func _placement(anchor: Vector2, i: int, n: int, distance: float, used: Dictionary) -> Vector2:
	var grid: bool = not GridManager.grid_costs.is_empty()
	if grid and not _walkable(GridManager.world_to_map(anchor)):
		anchor = _nearest_open(anchor, {}, anchor)
	var pos: Vector2 = anchor
	if distance > 0.0:
		var angle: float = TAU * float(i) / float(maxi(n, 1)) + 0.4
		pos = anchor + Vector2.RIGHT.rotated(angle) * distance
	if not grid:
		return pos
	var t: Vector2i = GridManager.world_to_map(pos)
	if _walkable(t) and not used.has(t):
		used[t] = true
		return pos
	var out: Vector2 = _nearest_open(pos, used, anchor)
	used[GridManager.world_to_map(out)] = true
	return out


## Tiles living characters stand on (but not `moving`), to seed _placement's
## `used` so a spawn or teleport never lands on someone.
func _occupied_tiles(moving: Array) -> Dictionary:
	var out: Dictionary = {}
	var g = _game()
	if g == null or not ("characters_in_scene" in g) or GridManager.grid_costs.is_empty():
		return out
	for c in g.characters_in_scene:
		if not is_instance_valid(c) or not (c is Node2D) or c in moving:
			continue
		if c.has_method("is_alive") and not c.is_alive():
			continue
		out[GridManager.world_to_map(c.global_position)] = true
	return out


func _walkable(t: Vector2i) -> bool:
	return GridManager.grid_costs.get(t, INF) != INF


## Centre of the walkable tile nearest `pos` (within 4 tiles) not in `used`;
## `fallback` when there is none.
func _nearest_open(pos: Vector2, used: Dictionary, fallback: Vector2) -> Vector2:
	var t: Vector2i = GridManager.world_to_map(pos)
	var best: Vector2i = t
	var best_d: float = INF
	for dy in range(-4, 5):
		for dx in range(-4, 5):
			var c: Vector2i = t + Vector2i(dx, dy)
			if not _walkable(c) or used.has(c):
				continue
			var d: float = GridManager.map_to_world(c).distance_squared_to(pos)
			if d < best_d:
				best_d = d
				best = c
	return GridManager.map_to_world(best) if best_d < INF else fallback


# ===========================================================================
# Small helpers
# ===========================================================================

func _game() -> Node:
	return manager._get_game() if manager != null else null


func _is_party(c) -> bool:
	return c != null and is_instance_valid(c) and c.has_method("is_party_member") and c.is_party_member()


## Whether the party may be told about this character (ConditionManager's
## rule: a party member, or an NPC the party can see), or it is who the
## player is talking to.
func _seen(c) -> bool:
	if c == null or not is_instance_valid(c):
		return false
	if manager != null and manager.has_method("get_partner") and c == manager.get_partner():
		return true
	if c.has_method("_announces_to_party"):
		return c._announces_to_party()
	return _is_party(c)


func _say_seen(c, text: String, log_text: String, color: Color) -> void:
	if _seen(c):
		c.notify(text, color, log_text)


func _say_party(c, text: String, log_text: String, color: Color) -> void:
	if c != null and is_instance_valid(c) and c.has_method("notify"):
		c.notify(text, color, log_text)
	else:
		GameLog.add_entry(log_text)


func _name(c) -> String:
	if c == null or not is_instance_valid(c):
		return "Someone"
	var n = c.get("Name")
	if n != null and str(n) != "":
		return str(n)
	var d = c.get("display_name")
	return str(d) if d != null else str(c.name)


func _norm(s: String) -> String:
	return s.to_lower().replace("-", " ").replace("_", " ").strip_edges()


func _ident(c) -> String:
	var t: String = str(c.get("template_id"))
	return t if t != "" and t != "<null>" else _norm(_name(c)).replace(" ", "_")


func _join_names(names: Array) -> String:
	if names.size() <= 1:
		return "".join(names)
	return ", ".join(names.slice(0, names.size() - 1)) + " and " + str(names[-1])


func _add_tag(c, tag: String) -> void:
	var tags: Array = c.get_meta("dialogue_tags", []).duplicate()
	if not tag in tags:
		tags.append(tag)
	c.set_meta("dialogue_tags", tags)


func _flag_key(d: Dictionary, quiet: bool = false) -> String:
	var flag: String = str(d.get("flag", "")).strip_edges()
	if flag.is_empty():
		_warn("flag name is empty")
		return ""
	if not d.has("who"):
		return flag
	var c = _first(d["who"], quiet, "flag")
	if c == null:
		return ""
	return "flag::%s::%s" % [_ident(c), flag]


func _count_items(pool: Array, item_id: String) -> int:
	var total: int = 0
	var want: String = Globals.name_to_id(item_id)
	for c in pool:
		var inv = c.get_node_or_null("Inventory") if is_instance_valid(c) else null
		if inv == null:
			continue
		for it in inv.items:
			if str(it.get("id", "")) == want and not _is_hand_ghost(it):
				var n = it.get("num_stacks", 1)
				total += int(n) if (n is int or n is float) and int(n) > 0 else 1
		# Weapons live as nodes in the hands or stowed, not in `items`.
		total += _weapons_of(inv, want).size()
	return total


## The weapon nodes (held or stowed) of an inventory with this item id,
## stowed first, then off hand, then main hand: the order take_item uses.
func _weapons_of(inv, want: String) -> Array:
	var out: Array = []
	for w in inv.stowed_items:
		if w is WeaponShape and is_instance_valid(w) and str(w.id) == want:
			out.append(w)
	for w in [inv.off_hand_item, inv.main_hand_item]:
		if w is WeaponShape and is_instance_valid(w) and str(w.id) == want:
			out.append(w)
	return out


## Take `count` of an item from the pool, in pool order. Returns
## [{from, count, data}] (data: a copy carrying just that many).
func _remove_items(pool: Array, item_id: String, count: int) -> Array:
	var out: Array = []
	var left: int = count
	var want: String = Globals.name_to_id(item_id)
	for c in pool:
		if left <= 0:
			break
		var inv = c.get_node_or_null("Inventory")
		if inv == null:
			continue
		var i: int = inv.items.size() - 1
		while i >= 0 and left > 0:
			var it: Dictionary = inv.items[i]
			if str(it.get("id", "")) == want and not _is_hand_ghost(it):
				var n_v = it.get("num_stacks", 1)
				var have: int = int(n_v) if (n_v is int or n_v is float) and int(n_v) > 0 else 1
				var take: int = mini(have, left)
				var copy: Dictionary = it.duplicate(true)
				if bool(it.get("is_stackable", false)):
					copy["num_stacks"] = take
				inv.remove_amount(i, take)
				out.append({"from": c, "count": take, "data": copy})
				left -= take
			i -= 1
		# Then weapons, as the trade window hands one over: out of the hand
		# or the stowed list. A weapon is its WeaponShape alone (starting
		# weapons leave no hidden hand dict; old saves drop theirs on load).
		for w in _weapons_of(inv, want):
			if left <= 0:
				break
			var wdata: Dictionary = w.to_data()
			if w == inv.main_hand_item:
				inv.unequip_hand("Main")
			elif w == inv.off_hand_item:
				inv.unequip_hand("Off")
			else:
				inv.stowed_items.erase(w)
				inv.emit_signal("weapon_unequipped", w)
			w.queue_free()
			out.append({"from": c, "count": 1, "data": wdata, "weapon": true})
			left -= 1
	return out


## Hand-slot dicts are weapon data (a corpse's loot, or an old save's hidden
## copy before Inventory.migrate_hand_dicts drops it); a carried weapon is
## its WeaponShape, so take_item and has_item count the node (_weapons_of),
## never a dict as well.
func _is_hand_ghost(it: Dictionary) -> bool:
	return EquipmentEffects.is_hand_ghost(it)


func _refresh_party_panel() -> void:
	var g = _game()
	if g == null:
		return
	var panel = g.get_node_or_null("GameUI/PartySidePanel")
	if panel != null and panel.has_method("_populate_party"):
		panel.call_deferred("_populate_party")


func _item_known(item_id: String, warn: bool = false) -> bool:
	var key: String = Globals.name_to_id(item_id)
	var ok: bool = ItemDatabase.items.has(key) or ItemDatabase.weapons.has(key) or ItemDatabase.equipment.has(key)
	if not ok and warn:
		_warn("no item '%s' in Items.json (skipped)" % item_id)
	return ok


func _item_name(item_id: String) -> String:
	var key: String = Globals.name_to_id(item_id)
	for db in [ItemDatabase.items, ItemDatabase.weapons, ItemDatabase.equipment]:
		if db.has(key):
			return str(db[key].get("display_name", item_id.replace("_", " ").capitalize()))
	return item_id.replace("_", " ").capitalize()


func _quest_known(quest_id: String, warn: bool = false) -> bool:
	var ok: bool = not QuestDatabase.get_quest(quest_id).is_empty()
	if not ok and warn:
		_warn("no quest '%s' in Quests.json (skipped)" % quest_id)
	return ok


func _quest_name(quest_id: String) -> String:
	return str(QuestDatabase.get_quest(quest_id).get("display_name", quest_id.replace("_", " ").capitalize()))


func _faction_known(faction_id: String, warn: bool = false) -> bool:
	var ok: bool = FactionDatabase.has_faction(faction_id)
	if not ok and warn:
		_warn("no faction '%s' (skipped)" % faction_id)
	return ok


func _faction_name(faction_id: String) -> String:
	if faction_id == "player":
		return "your party"
	if FactionDatabase.has_faction(faction_id):
		return str(FactionDatabase.get_faction_data(faction_id).get("name", faction_id.capitalize()))
	return faction_id.capitalize()


func _condition_name(cid: String) -> String:
	var cond = ConditionManager.condition_registry.get(cid)
	if cond != null and str(cond.display_name) != "":
		return str(cond.display_name)
	return cid.replace("_", " ").capitalize()


func _warn(msg: String, where: String = "") -> void:
	var w: String = where if where != "" else _where
	var at: String = ""
	if manager != null and str(manager.current_dialogue_id) != "":
		at = "%s/%s" % [manager.current_dialogue_id, manager.current_node_id]
	var label: String = " ".join([at, w]).strip_edges()
	push_warning("Dialogue action [%s]: %s" % [label if label != "" else "no dialogue", msg])


# ===========================================================================
# Load-time validation
# ===========================================================================

## Every problem in Dialogues.json's actions and checks that can be seen
## without playing: unknown types, missing fields, unknown items, templates,
## factions, quests, conditions and dialogues. One line each; DialogueManager
## push_warnings them at startup.
func validate_all(dialogues: Dictionary) -> Array:
	var problems: Array = []
	for did in dialogues:
		var nodes = dialogues[did].get("dialogueNodes", {}) if dialogues[did] is Dictionary else {}
		if not (nodes is Dictionary):
			continue
		for nid in nodes:
			var node = nodes[nid]
			if not (node is Dictionary):
				continue
			var at: String = "%s/%s" % [did, nid]
			_validate_actions(node.get("on_enter", null), at + " on_enter", nodes, dialogues, problems)
			_validate_actions(node.get("actions", null), at + " actions", nodes, dialogues, problems)
			_validate_branch(node.get("branch", null), at + " branch", nodes, problems)
			var choices = node.get("choices", [])
			if choices is Array:
				for i in range(choices.size()):
					var ch = choices[i]
					if not (ch is Dictionary):
						continue
					var cat: String = "%s choice %d" % [at, i + 1]
					_validate_actions(ch.get("actions", null), cat + " actions", nodes, dialogues, problems)
					_validate_checks(ch.get("requires", null), cat + " requires", problems, true)
					_validate_checks(ch.get("show_if", null), cat + " show_if", problems, true)
					_validate_branch(ch.get("branch", null), cat + " branch", nodes, problems)
	return problems


func _validate_actions(list, at: String, nodes: Dictionary, dialogues: Dictionary, problems: Array) -> void:
	if list == null:
		return
	if list is String or list is Dictionary:
		list = [list]
	if not (list is Array):
		problems.append("%s: must be a list" % at)
		return
	for i in range(list.size()):
		var a = list[i]
		if a is String:
			continue
		if not (a is Dictionary):
			problems.append("%s #%d: not an object" % [at, i + 1])
			continue
		var type: String = str(a.get("type", ""))
		if not ACTIONS.has(type):
			problems.append("%s #%d: unknown action type '%s'" % [at, i + 1, type])
			continue
		for field in ACTIONS[type]:
			if not a.has(field):
				problems.append("%s #%d %s: missing '%s'" % [at, i + 1, type, field])
		if a.has("item") and not _item_known(str(a["item"])):
			problems.append("%s #%d %s: no item '%s'" % [at, i + 1, type, str(a["item"])])
		if type == "spawn" and a.has("template") and not TopDownCharacterDatabase.get_all_template_ids().has(str(a["template"])):
			problems.append("%s #%d spawn: no template '%s'" % [at, i + 1, str(a["template"])])
		if a.has("quest") and not _quest_known(str(a["quest"])):
			problems.append("%s #%d %s: no quest '%s'" % [at, i + 1, type, str(a["quest"])])
		if type in ["change_standing", "change_faction_tier", "pardon", "set_faction"] and not FactionDatabase.has_faction(str(a.get("faction", ""))):
			problems.append("%s #%d %s: no faction '%s'" % [at, i + 1, type, str(a.get("faction", ""))])
		if type in ["apply_condition"] and not ConditionManager.condition_registry.has(str(a.get("condition", ""))):
			problems.append("%s #%d %s: no condition '%s'" % [at, i + 1, type, str(a.get("condition", ""))])
		if type in ["set_dialogue", "start_dialogue"] and str(a.get("dialogue", "")) != "" and not dialogues.has(str(a.get("dialogue", ""))):
			problems.append("%s #%d %s: no dialogue '%s'" % [at, i + 1, type, str(a.get("dialogue", ""))])
		if type == "report_crime" and LawDatabase.statute_def(str(a.get("statute", ""))).is_empty():
			problems.append("%s #%d report_crime: no statute '%s'" % [at, i + 1, str(a.get("statute", ""))])
		if type == "set_relation" and not str(a.get("relation", "")) in RELATIONS:
			problems.append("%s #%d set_relation: relation must be one of %s" % [at, i + 1, str(RELATIONS)])


func _validate_checks(checks, at: String, problems: Array, for_option: bool) -> void:
	if checks == null or checks is String:
		return
	if checks is Dictionary:
		checks = [checks]
	if not (checks is Array):
		problems.append("%s: must be an object or a list" % at)
		return
	for i in range(checks.size()):
		var c = checks[i]
		if c is String:
			continue
		if not (c is Dictionary):
			problems.append("%s #%d: not an object" % [at, i + 1])
			continue
		var type: String = str(c.get("type", ""))
		if not CHECKS.has(type):
			problems.append("%s #%d: unknown check type '%s'" % [at, i + 1, type])
			continue
		for field in CHECKS[type]:
			if not c.has(field):
				problems.append("%s #%d %s: missing '%s'" % [at, i + 1, type, field])
		if type == "ability_check" and for_option:
			problems.append("%s #%d: ability_check rolls dice; use it in a branch, not in requires/show_if" % [at, i + 1])
		if c.has("item") and not _item_known(str(c["item"])):
			problems.append("%s #%d %s: no item '%s'" % [at, i + 1, type, str(c["item"])])
		if c.has("quest") and not _quest_known(str(c["quest"])):
			problems.append("%s #%d %s: no quest '%s'" % [at, i + 1, type, str(c["quest"])])
		if type == "quest" and not str(c.get("state", "")) in QUEST_STATES:
			problems.append("%s #%d quest: state must be one of %s" % [at, i + 1, str(QUEST_STATES)])
		if type in ["any", "all"]:
			_validate_checks(c.get("of", null), "%s #%d %s" % [at, i + 1, type], problems, for_option)


func _validate_branch(branch, at: String, nodes: Dictionary, problems: Array) -> void:
	if not (branch is Array):
		return
	for i in range(branch.size()):
		var b = branch[i]
		if not (b is Dictionary) or not b.has("next"):
			problems.append("%s #%d: each entry needs \"next\"" % [at, i + 1])
			continue
		if not nodes.has(str(b["next"])):
			problems.append("%s #%d: no node '%s'" % [at, i + 1, str(b["next"])])
		if b.has("if"):
			_validate_checks(b["if"], "%s #%d if" % [at, i + 1], problems, false)
