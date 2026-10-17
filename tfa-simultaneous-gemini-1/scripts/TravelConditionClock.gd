## TravelConditionClock
## On the world map the party folds into one banner: only the protagonist has a
## body there, and everyone else's conditions sit in their party_state snapshot
## (live_state.condition_state, ConditionManager.to_dict's format) where
## nothing ticks them. Game calls expire_snapshots while on the world map, so a
## companion's Hungover or Exhausted runs out during the journey, with its log
## line then, instead of all at once on arrival. Static helpers only; no
## class_name (preload it).
extends RefCounted

## Removes every timed condition whose expires_at (absolute time, the clock
## ConditionManager expires on) has passed from the snapshots of the party_state
## rows not in `skip_rows` (rows with a body, which tick themselves). Away and
## dead members are left alone: an away member isn't on the road with you, and
## a corpse's conditions don't tick. Returns one log line per condition, in the
## wording the living use (ProceduralCharacter._announce_condition_ran_out).
static func expire_snapshots(party_state: Array, skip_rows: Dictionary, now: float) -> PackedStringArray:
	var lines := PackedStringArray()
	for row in range(party_state.size()):
		if skip_rows.has(row):
			continue
		var entry = party_state[row]
		if not (entry is Dictionary):
			continue
		var away = entry.get("away", null)
		if away is Dictionary and not (away as Dictionary).is_empty():
			continue
		var live = entry.get("live_state")
		if not (live is Dictionary):
			continue
		if live.has("current_health") and int(live["current_health"]) <= 0:
			continue
		var cs = live.get("condition_state")
		if not (cs is Dictionary):
			continue
		var conds = cs.get("conditions")
		if not (conds is Dictionary):
			continue
		var who := str(live.get("Name", ""))
		if who.is_empty():
			who = str(live.get("display_name", "A companion"))
		for cid in conds.keys():
			var inst = conds[cid]
			if not (inst is Dictionary):
				continue
			var expires_at := float(inst.get("expires_at", -1.0))
			if expires_at < 0.0 or expires_at > now:
				continue
			conds.erase(cid)
			lines.append("%s is no longer %s." % [who, condition_name(str(cid))])
	return lines

static func condition_name(cid: String) -> String:
	var tmpl = ConditionManager.condition_registry.get(cid)
	if tmpl != null and str(tmpl.display_name) != "":
		return str(tmpl.display_name)
	return cid.replace("_", " ").capitalize()
