# TrainingManager.gd
# Autoload singleton - registered in project.godot as "TrainingManager".
#
# Holds the promises teachers have made. Taking a "training" reward on the quest
# reward screen does NOT grant the ability: it books days with a teacher, and the
# learner has to spend those days on the training downtime activity in the region
# where the teacher lives. This is the game's progression cost — abilities are
# bought with time, not with a level-up.
#
# One open commitment per learner. Keyed by DowntimeDatabase.character_uid, the
# same stable string the downtime cooldown table uses, because a character node
# is freed and respawned on every map transition and cannot be a key.
#
# Speed comes from Intelligence, rolled ONCE at acceptance rather than per day:
# a character who grasps a discipline quickly grasps it quickly on day one, and
# re-rolling nightly would just regress every learner to the mean.
extends Node

signal training_started(learner_uid: String, ability_id: String, days_required: int)
signal training_progressed(learner_uid: String, days_done: int, days_required: int)
signal training_completed(learner_uid: String, ability_id: String)

const TRAINING_ACTIVITY_ID := "training"
# Traits that help or hinder book-work, mirroring the `research` activity's.
const STUDY_ADVANTAGES := ["Scholarly", "Rationalist"]
const STUDY_DISADVANTAGES := ["Restless"]

# learner_uid -> {
#   ability_id, teacher_title, map_id, region_id,
#   days_required, days_done, started_day, learner_name
# }
var commitments: Dictionary = {}

# uid -> [ability_id] earned while the character was not in the scene (a
# companion who finished studying after you left town). Flushed by
# flush_pending_grants when they next spawn.
var pending_grants: Dictionary = {}

# ---------------------------------------------------------------------------
# Query
# ---------------------------------------------------------------------------

func get_commitment(learner_uid: String) -> Dictionary:
	return commitments.get(learner_uid, {})

func commitment_for(character) -> Dictionary:
	if character == null or not is_instance_valid(character):
		return {}
	return get_commitment(DowntimeDatabase.character_uid(character))

func has_open_commitment(character) -> bool:
	return not commitment_for(character).is_empty()

## True when this character can actually study right now: they owe days AND the
## teacher is in this region. Gates the training card onto the downtime board.
func can_train_here(character, region_id: String) -> bool:
	var c: Dictionary = commitment_for(character)
	if c.is_empty():
		return false
	return str(c.get("region_id", "")) == region_id

func days_remaining(character) -> int:
	var c: Dictionary = commitment_for(character)
	if c.is_empty():
		return 0
	return maxi(0, int(c.get("days_required", 0)) - int(c.get("days_done", 0)))

# ---------------------------------------------------------------------------
# Booking
# ---------------------------------------------------------------------------

## Turn a reward-screen "training" offer into a commitment. `map_id` is where the
## teacher is — the learner has to come back here to study.
## Returns the commitment, or {} if the offer was unusable.
func accept_offer(character, offer: Dictionary, map_id: String) -> Dictionary:
	if character == null or not is_instance_valid(character):
		return {}
	var ability_id: String = str(offer.get("ability_id", ""))
	if ability_id.is_empty():
		return {}
	# Nothing to teach someone who already knows it.
	if knows_ability(character, ability_id):
		# Over them too: the game log starts closed.
		if character.has_method("notify"):
			character.notify("Already known", Color(1.0, 0.6, 0.4), "%s already knows that." % _display_name(character))
		elif GameLog:
			GameLog.add_entry("%s already knows that." % _display_name(character))
		return {}

	var uid: String = DowntimeDatabase.character_uid(character)
	if uid.is_empty():
		return {}

	var base_days: int = maxi(1, int(offer.get("base_days", 3)))
	var commitment := {
		"ability_id": ability_id,
		"teacher_title": str(offer.get("teacher_title", "")),
		"map_id": map_id,
		"region_id": RegionDatabase.get_region_for_map(map_id) if RegionDatabase else "",
		"days_required": roll_days_required(character, base_days),
		"days_done": 0,
		"started_day": int(TimeManager.today()) if TimeManager else 0,
		"learner_name": _display_name(character),
	}
	commitments[uid] = commitment
	if GameLog:
		GameLog.add_entry("%s will study %s for %d days." % [
			commitment["learner_name"], _ability_name(ability_id),
			int(commitment["days_required"])])
	emit_signal("training_started", uid, ability_id, int(commitment["days_required"]))
	return commitment

## How long this learner needs. One Intelligence check against the same tier
## ladder downtime uses (DowntimeResolver:113): ability_check rolls d100 against
## intelligence + 20 per relevant trait tier and returns 1 + margin/50, or 0 on a
## failure. So tier 1 is the authored baseline, a sharp character shaves days
## off, and a failed check costs a day more than advertised.
func roll_days_required(character, base_days: int) -> int:
	var tier: int = 1
	if character != null and character.has_method("ability_check"):
		tier = int(character.ability_check("Intelligence", {
			"advantages": STUDY_ADVANTAGES,
			"disadvantages": STUDY_DISADVANTAGES,
		}))
	return clampi(base_days - (tier - 1), 1, base_days + 2)

# ---------------------------------------------------------------------------
# Progress
# ---------------------------------------------------------------------------

## Credit one day of study. Returns true if that finished the training (in which
## case the ability has already been granted and the commitment cleared).
func credit_day(character) -> bool:
	if character == null or not is_instance_valid(character):
		return false
	var uid: String = DowntimeDatabase.character_uid(character)
	var c: Dictionary = get_commitment(uid)
	if c.is_empty():
		return false

	c["days_done"] = int(c.get("days_done", 0)) + 1
	commitments[uid] = c
	emit_signal("training_progressed", uid, int(c["days_done"]), int(c["days_required"]))

	if int(c["days_done"]) < int(c["days_required"]):
		return false
	_finish(character, uid, c)
	return true

## Grant the ability and clear the booking. Split out so the companion-return
## path (a party member who finished while you were away) can complete a
## commitment without a live character node having studied on screen.
func _finish(character, uid: String, c: Dictionary) -> void:
	var ability_id: String = str(c.get("ability_id", ""))
	commitments.erase(uid)
	if character != null and is_instance_valid(character):
		grant_ability(character, ability_id)
	if GameLog:
		GameLog.add_entry("%s has learned %s." % [
			str(c.get("learner_name", "Someone")), _ability_name(ability_id)])
	# Over the learner too: the game log starts closed.
	if character is Node2D and is_instance_valid(character) and character.is_inside_tree():
		Globals.show_floating_text("Learned: " + _ability_name(ability_id), character.global_position,
			character, Color(0.55, 1.0, 0.55), 0, Globals.NOTICE_FONT_SIZE)
	emit_signal("training_completed", uid, ability_id)

## Force a commitment to completion without the learner being present — used
## when a companion finishes their studies off-screen after you left town. The
## ability is granted the next time they are spawned, via pending_grants.
func complete_absent(uid: String) -> String:
	var c: Dictionary = get_commitment(uid)
	if c.is_empty():
		return ""
	var ability_id: String = str(c.get("ability_id", ""))
	commitments.erase(uid)
	if not pending_grants.has(uid):
		pending_grants[uid] = []
	if not (ability_id in pending_grants[uid]):
		pending_grants[uid].append(ability_id)
	emit_signal("training_completed", uid, ability_id)
	return ability_id

func flush_pending_grants(character) -> void:
	if character == null or not is_instance_valid(character):
		return
	var uid: String = DowntimeDatabase.character_uid(character)
	if not pending_grants.has(uid):
		return
	for ability_id in pending_grants[uid]:
		grant_ability(character, str(ability_id))
	pending_grants.erase(uid)

# ---------------------------------------------------------------------------
# Ability granting
# ---------------------------------------------------------------------------

## Known-abilities test. There is no known_abilities list in this game: an
## ability a character knows is an AbilityShape sitting in inventory.stowed_items
## (or in a hand), so that is what we walk.
func knows_ability(character, ability_id: String) -> bool:
	if character == null or ability_id.is_empty():
		return false
	var inv = character.get_node_or_null("Inventory")
	if inv == null:
		return false
	for pool in [inv.stowed_items, [inv.main_hand_item], [inv.off_hand_item]]:
		for entry in pool:
			if entry == null or not is_instance_valid(entry):
				continue
			if "ability_id" in entry and String(entry.ability_id) == ability_id:
				return true
			if "raw_data" in entry and entry.raw_data is Dictionary \
					and String(entry.raw_data.get("id", "")) == ability_id:
				return true
	return false

## Teach it. Inventory.add_ability_by_id does NOT dedupe — calling it twice
## appends a second canonical AbilityShape and the character ends up with the
## same spell listed twice — so the check above is mandatory, not defensive.
func grant_ability(character, ability_id: String) -> bool:
	if character == null or ability_id.is_empty():
		return false
	if knows_ability(character, ability_id):
		return false
	var inv = character.get_node_or_null("Inventory")
	if inv == null or not inv.has_method("add_ability_by_id"):
		return false
	return bool(inv.add_ability_by_id(ability_id))

# ---------------------------------------------------------------------------
# Save/load (mirrors QuestManager.get_save_data / load_save_data)
# ---------------------------------------------------------------------------

func get_save_data() -> Dictionary:
	return {
		"commitments": commitments.duplicate(true),
		"pending_grants": pending_grants.duplicate(true),
	}

func load_save_data(data: Dictionary) -> void:
	commitments = data.get("commitments", {}).duplicate(true) if data.has("commitments") else {}
	pending_grants = data.get("pending_grants", {}).duplicate(true) if data.has("pending_grants") else {}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _display_name(character) -> String:
	if character == null:
		return "Someone"
	if "display_name" in character and String(character.display_name) != "":
		return String(character.display_name)
	return String(character.name)

func _ability_name(ability_id: String) -> String:
	if AbilityDatabase == null:
		return ability_id
	var data: Dictionary = AbilityDatabase.get_ability_data(ability_id)
	return str(data.get("display_name", ability_id))
