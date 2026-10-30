class_name SpawnRowSchema
extends RefCounted
# ONE ROW SCHEMA (TG export contract P2-E, Terrain Generation docs/
# export_contract.md): the optional npc_spawns[] / item_spawns[] keys a
# Maps.json row may carry, read by Game._spawn_npcs / _spawn_items from these
# lists. Mirrors TG scripts/RowSchema.gd (TG tools/tests/test_row_schema.py
# compares the two when its TFA_ROOT has this file). Every key is optional: a
# row without one behaves exactly as before the schema.
#
# Numbers come back from a Godot-merged Maps.json as floats ("count": 1.0):
# read them through int() / float().

## npc_spawns[] keys copied verbatim into the spawn overrides
## (TopDownCharacterDatabase reads unique_name / titles / faction; Game wires
## dialogue). extra_items (carried Items.json ids -> persist_unique) and
## condition (the spawn gate) are read on their own.
const NPC_OVERRIDE_KEYS := ["unique_name", "titles", "faction", "dialogue"]
## Reserved for schedules / residents / patrols (P6): exported rows may carry
## them already; nothing reads them yet.
const NPC_RESERVED_KEYS := ["home", "work", "schedule", "resident_id", "patrol"]

## item_spawns[] keys beyond the geometry and run fields.
const ITEM_KEYS := ["condition", "count", "value", "owner_faction", "owner_uid", "controlling_faction"]


## The spawn overrides of one npc row (only the keys it has).
static func npc_overrides(npc_def: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in NPC_OVERRIDE_KEYS:
		if npc_def.has(k):
			out[k] = npc_def[k]
	return out


## Who owns a placed item. First hit wins:
##   1. the row's owner_faction;
##   2. the row's owner_uid -> that character's faction, when the character is
##      on the map (alive or a corpse): a per-item owner beats the map defaults;
##   3. the map's default_item_owner;
##   4. the map's jurisdiction when the map declares "settlement": true;
##   5. "" = unowned.
## Deliberately NO "everything on a lawful map is owned" global: that
## criminalises picking up a stray apple with no authoring signal.
static func item_owner_faction(item_def: Dictionary, map_data: Dictionary, map_id: String,
		characters: Array) -> String:
	var owner_f: String = str(item_def.get("owner_faction", ""))
	if owner_f.is_empty() and item_def.has("owner_uid"):
		owner_f = faction_of_uid(str(item_def["owner_uid"]), characters)
	if owner_f.is_empty():
		owner_f = str(map_data.get("default_item_owner", ""))
	if owner_f.is_empty() and bool(map_data.get("settlement", false)):
		owner_f = LawDatabase.jurisdiction_for_map(map_id)
	return owner_f


## The faction of the spawned character whose persistence uid is uid: the
## named form "template_id/unique_name" (or a bare template_id) or the
## ordinal form "template_id#N" (Game._build_npc_uid / _save_service_npc_states).
## "" when no such character is on the map.
static func faction_of_uid(uid: String, characters: Array) -> String:
	if uid.is_empty():
		return ""
	for c in characters:
		if not is_instance_valid(c) or not ("faction_id" in c):
			continue
		var tid: String = str(c.get_meta("template_id", ""))
		if tid.is_empty():
			continue
		var uname: String = str(c.get_meta("unique_name", ""))
		var named: String = tid if uname.is_empty() else tid + "/" + uname
		var ordinal: String = "%s#%d" % [tid, int(c.get_meta("spawn_ordinal", 0))]
		if uid == named or uid == ordinal:
			return str(c.faction_id)
	return ""
