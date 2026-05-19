# MapTriggerState.gd
# Autoload. Tiny in-memory record of which one-shot dialogue triggers have
# already fired, keyed by map_id then trigger_id. Used by:
#   - MapLoader on-load triggers (dialogue_triggers_on_load[].id)
#   - DialogueZoneController proximity triggers (dialogue_zones[].id)
#   - EventScheduler time triggers (under synthetic map key GLOBAL_KEY)
#
# Lives across map unloads so a one-shot stays fired if the player re-enters.
# Save/load integration is a follow-up; persisting `fired` is enough to
# restore all one-shot state.
extends Node

const GLOBAL_KEY := "__global__"

var fired: Dictionary = {}   # map_id -> { trigger_id: true }

func has_fired(map_id: String, trigger_id: String) -> bool:
	if not fired.has(map_id):
		return false
	return fired[map_id].has(trigger_id)

func mark_fired(map_id: String, trigger_id: String) -> void:
	if not fired.has(map_id):
		fired[map_id] = {}
	fired[map_id][trigger_id] = true

# Drop all fired state for a single map. Useful for debug / new-game flow.
func clear_map(map_id: String) -> void:
	if fired.has(map_id):
		fired.erase(map_id)

func clear_all() -> void:
	fired.clear()
