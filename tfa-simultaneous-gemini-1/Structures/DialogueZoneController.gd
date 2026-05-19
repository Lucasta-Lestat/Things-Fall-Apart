# DialogueZoneController.gd
# Per-map node spawned by MapLoader to drive proximity-based dialogue
# triggers declared under Maps.json[map].dialogue_zones.
#
# Each zone:
#   { id, dialogue, position:[x,y], radius, trigger_on, prerequisites, one_shot }
# `trigger_on`: "protagonist" (default) or "any_party"
#
# On every frame we sample the relevant character positions and detect
# outside→inside transitions per zone. On entry (and after prerequisites
# pass) we ask DialogueManager to start the dialogue. One-shots are then
# marked in MapTriggerState and skipped forever.
extends Node2D
class_name DialogueZoneController

const TriggerStateNS = "/root/MapTriggerState"

var map_id: String = ""
var zones: Array = []          # raw zone dicts from Maps.json
# Per-zone state: id -> { "inside": bool }
var _state: Dictionary = {}

@onready var _game = get_node_or_null("/root/Game")
@onready var _dialogue = get_node_or_null("/root/DialogueManager")
@onready var _trigger_state = get_node_or_null(TriggerStateNS)

func configure(p_map_id: String, p_zones: Array) -> void:
	map_id = p_map_id
	zones = p_zones
	_state.clear()
	for z in zones:
		_state[str(z.get("id", ""))] = {"inside": false}

func _process(_dt: float) -> void:
	if zones.is_empty() or _dialogue == null:
		return
	# Targets are sampled fresh each frame so that party composition / death
	# during a session is handled.
	var targets_by_zone: Dictionary = {}  # zone_id -> Array of Vector2 positions
	for z in zones:
		var zid := str(z.get("id", ""))
		if zid.is_empty():
			continue
		if _trigger_state and bool(z.get("one_shot", true)) and _trigger_state.has_fired(map_id, zid):
			continue
		targets_by_zone[zid] = _collect_targets(z)

	for z in zones:
		var zid := str(z.get("id", ""))
		if not targets_by_zone.has(zid):
			continue
		var pos_arr = z.get("position", [0, 0])
		var center := Vector2(float(pos_arr[0]), float(pos_arr[1]))
		var radius := float(z.get("radius", 0))
		var radius_sq := radius * radius
		var any_inside := false
		for p in targets_by_zone[zid]:
			if (p - center).length_squared() <= radius_sq:
				any_inside = true
				break

		var was_inside: bool = _state[zid]["inside"]
		_state[zid]["inside"] = any_inside

		# Fire only on transition outside→inside so the player can re-enter
		# repeatable zones, and one-shots don't spam while standing still.
		if any_inside and not was_inside:
			_try_fire(z)

func _collect_targets(zone: Dictionary) -> Array:
	var out: Array = []
	if _game == null:
		return out
	var mode := str(zone.get("trigger_on", "protagonist"))
	if mode == "any_party":
		if _game.has_method("get_party"):
			for c in _game.get_party():
				if is_instance_valid(c):
					out.append(c.global_position)
	else:
		var p = _game.get("player") if "player" in _game else null
		if p and is_instance_valid(p):
			out.append(p.global_position)
	return out

func _try_fire(zone: Dictionary) -> void:
	var zid := str(zone.get("id", ""))
	var dialogue_id := str(zone.get("dialogue", ""))
	if dialogue_id.is_empty():
		return
	var prereqs = zone.get("prerequisites", [])
	if _dialogue and _dialogue.has_method("evaluate_prerequisites"):
		if not _dialogue.evaluate_prerequisites(prereqs):
			return
	_dialogue.start_dialogue(dialogue_id)
	if bool(zone.get("one_shot", true)) and _trigger_state:
		_trigger_state.mark_fired(map_id, zid)
