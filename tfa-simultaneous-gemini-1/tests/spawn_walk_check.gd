extends Node2D
# Spawn-tile walkability audit: loads a map exactly like the game (MapLoader +
# CellGraph elevations) and verifies every ladder/fort warp-arrival spawn is
# usable — *_base tiles walkable at ground level, *_top tiles walkable at
# elevation. Headless-safe (no rendering).
#
# Ground level is RELATIVE to the local terrain (a ladder on a hillside terrace
# stands at ground 8, not 0): *_base = |surface - terrain| < one step,
# *_top = surface - terrain >= GridManager.HIGH_LAYER_STORIES.
# Every map also fails on the absolute-height lints (cells roof below
# terrain + 0.9, deck walk_elev below terrain).
# STRICT is the default (TG P1-C): every other player spawn must stand on a
# walkable tile, the default tile must be walkable, and every non-_top player
# spawn and every npc_spawns base must be in the default spawn's walking
# component (doors count as passable, locked or not: a locked room is a
# puzzle, not a soft-lock). A spawn standing ON an obstacle tile counts as
# reachable when it can step onto a 4-neighbour in the component (NPC: WARN
# line; player: the walkability check reports it).
# Known failures of shipped maps are excused by ALLOWLIST (check key -> the
# reason and the package that removes it) and print ALLOW instead of FAIL; an
# allowlisted check that now passes FAILs as STALE, so the list only shrinks.
# TG's verification engine (tools/grasslab/verify_export.py, ARRIVAL/NPC
# rules) replays the same checks and keeps the same entries in its
# tools/verify_allowlist.json.
# Run:  godot --headless --path . res://tests/spawn_walk_check.tscn
# Env:  TFA_MAPS = comma-separated map ids (default all tg_* structured maps)
#       TFA_STRICT = 0 restores the old lenient pass (flat maps WARN on an
#       unwalkable arrival and skip reachability; relief maps stay strict)
const MAP_LOADER := preload("res://Structures/MapLoader.gd")
# check key ("<map>.<spawn key>" walkability, "<map>.strict.<spawn key>"
# reachability) -> why it is excused, and until when
const ALLOWLIST := {
	"tg_town_square.from_venonan_chapel": "the arrival tile (2,16) sits in a wall halo (WARN since TFA 5ce48a26); hand-authored legacy layout, fixed by the P2-L legacy train",
	"tg_town_square.strict.from_courthouse": "the courthouse arrival and its warp sit in a walled 24-tile NW pocket cut off from the piazza; hand-authored legacy layout, P2-L legacy train",
	"tg_castle_demo.strict.fort_tower_1_base": "the fort bailey holding the ladder bases is a pocket (its gate mouth is walled in); legacy procedural map, P2-L legacy train",
	"tg_castle_demo.strict.fort_tower_2_base": "the fort bailey holding the ladder bases is a pocket (its gate mouth is walled in); legacy procedural map, P2-L legacy train",
	"tg_villa_demo.strict.fort_tower_1_base": "the fort bailey holding the ladder bases is a pocket cut off from the default spawn; legacy procedural map, P2-L legacy train",
	"tg_villa_demo.strict.fort_tower_2_base": "the fort bailey holding the ladder bases is a pocket cut off from the default spawn; legacy procedural map, P2-L legacy train",
}
var structures_in_scene: Array = []
var party_chars: Array = []
var unlocked_locks: Dictionary = {}
var fails := 0
var checks := 0
var allowed := 0
var _allow_seen: Dictionary = {}   # allowlist key -> true once its check FAILED (and was excused)
var _allow_ran: Dictionary = {}    # allowlist key -> true once its check ran at all


func _ready() -> void:
	add_to_group("game")
	var f := FileAccess.open("res://data/Maps.json", FileAccess.READ)
	var raw: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	var want := OS.get_environment("TFA_MAPS")
	for e in raw.get("maps", []):
		var mid := String(e.get("id", ""))
		if want != "" and not mid in want.split(","):
			continue
		if want == "" and not (mid.begins_with("tg_") and e.has("cell_graph")):
			continue
		_audit_map(e)
	# an excused check that passed: the excuse is stale (remove it from ALLOWLIST)
	for k in _allow_ran:
		if not _allow_seen.has(k):
			_fail("%s STALE allowlist entry: the check passes now -- remove it (%s)" % [String(k), String(ALLOWLIST[k])])
	print("spawn_walk_check: %d checks, %d FAIL, %d allowed" % [checks, fails, allowed])
	get_tree().quit(1 if fails > 0 else 0)


func _fail(msg: String) -> void:
	fails += 1
	print("FAIL " + msg)


# A failed check `key` (see ALLOWLIST): excused -> ALLOW line, else FAIL.
func _check_fail(key: String, msg: String) -> void:
	if ALLOWLIST.has(key):
		_allow_seen[key] = true
		allowed += 1
		print("ALLOW %s (%s)" % [msg, String(ALLOWLIST[key])])
		return
	_fail(msg)


# Every check that has an allowlist key goes through here first, pass or fail.
func _ran(key: String) -> void:
	if ALLOWLIST.has(key):
		_allow_ran[key] = true


func _spawn_tile(entry) -> Vector2i:
	var pos_a: Array = entry.get("position", [0, 0]) if typeof(entry) == TYPE_DICTIONARY else [0, 0]
	return GridManager.world_to_map(Vector2(float(pos_a[0]), float(pos_a[1])))


func _audit_map(m: Dictionary) -> void:
	var mid := String(m.get("id", ""))
	GridManager.TILE_SIZE = int(m.get("tile_size", 64))
	var ws: Array = m.get("world_size", [2048, 2048])
	GridManager.initialize(int(ws[0]), int(ws[1]))
	# initialize() drops the door tiles like a warp does, although the previous
	# audit's Doors are only queue_free'd: a leak would open an earlier map's
	# doorways here (combat_test's opened tg_town_square's walled NW pocket, P2-L)
	checks += 1
	if not GridManager.door_pass.is_empty() or not GridManager.door_gaps.is_empty():
		_fail("%s.door-tiles-reset %d door_pass / %d door_gaps tiles survived initialize()"
			% [mid, GridManager.door_pass.size(), GridManager.door_gaps.size()])
	var graph: CellGraph = CellGraph.from_structured(String(m.get("cell_graph", "")))
	GridManager.set_elevation_data(graph)
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	ml.generate_structured_map(m)
	# absolute-height lints (a RELATIVE roof / deck leaked out of the exporter)
	checks += 1
	if GridManager.roof_lint_bad > 0 or GridManager.deck_lint_bad > 0:
		_fail("%s.lints roof_bad=%d deck_bad=%d (cells roof / walk_elev must be ABSOLUTE stories)"
			% [mid, GridManager.roof_lint_bad, GridManager.deck_lint_bad])
	var spawns: Dictionary = m.get("player_spawns", {})
	var strict: bool = GridManager.relief_los or OS.get_environment("TFA_STRICT") != "0"
	for k in spawns:
		var sk := String(k)
		var is_base := sk.ends_with("_base")
		var is_top := sk.ends_with("_top")
		var t := _spawn_tile(spawns[k])
		var ckey := "%s.%s" % [mid, sk]
		if not (is_base or is_top):
			# any other arrival point must at least stand on walkable ground
			checks += 1
			if strict:
				_ran(ckey)
			if not GridManager.would_walk(t):
				if strict:
					_check_fail(ckey, "%s.%s tile=%s not walkable" % [mid, sk, str(t)])
				else:
					print("WARN %s.%s tile=%s not walkable (FAIL in strict mode, the default)" % [mid, sk, str(t)])
			continue
		var e := GridManager.effective_elev(t)
		var ground: float = GridManager.terrain_elev(t)
		var hag: float = e - ground
		var ok: bool = GridManager.would_walk(t) and \
			((absf(hag) < GridManager.MAX_STEP_STORIES) if is_base else (hag >= GridManager.HIGH_LAYER_STORIES))
		checks += 1
		_ran(ckey)
		if not ok:
			_check_fail(ckey, "%s.%s tile=%s elev=%.2f ground=%.2f hag=%.2f walkable=%s"
				% [mid, sk, str(t), e, ground, hag, str(GridManager.would_walk(t))])
	if strict:
		_audit_reachability(mid, m, spawns)
	ml.queue_free()
	# structures from this map must not bleed into the next audit
	for s in structures_in_scene:
		if is_instance_valid(s):
			s.queue_free()
	structures_in_scene = []


# Everything a party or NPC group arrives at must be walkable to and from the
# default spawn: on a hillside a spawn on the wrong side of a cliff is a soft-lock.
func _audit_reachability(mid: String, m: Dictionary, spawns: Dictionary) -> void:
	if not spawns.has("default"):
		checks += 1
		_fail("%s.strict no default player spawn" % mid)
		return
	var dt := _spawn_tile(spawns["default"])
	checks += 1
	if not GridManager.would_walk(dt):
		_fail("%s.strict default tile=%s not walkable" % [mid, str(dt)])
		return
	var comp: Dictionary = _flood(dt)
	for k in spawns:
		var sk := String(k)
		if sk == "default" or sk.ends_with("_top"):
			continue
		var t := _spawn_tile(spawns[k])
		var ckey := "%s.strict.%s" % [mid, sk]
		checks += 1
		_ran(ckey)
		# (a player spawn ON an obstacle tile is already reported by the
		# walkability check above; here it only has to be able to step off)
		if t != dt and not comp.has(t) and not _steps_off_into(t, comp):
			_check_fail(ckey, "%s.strict %s tile=%s unreachable from default %s" % [mid, sk, str(t), str(dt)])
	var npcs: Array = m.get("npc_spawns", [])
	for i in npcs.size():
		var n = npcs[i]
		if typeof(n) != TYPE_DICTIONARY:
			continue
		var t := _spawn_tile(n)
		var ckey := "%s.strict.npc_spawns[%d]" % [mid, i]
		checks += 1
		_ran(ckey)
		if t == dt or comp.has(t):
			continue
		if _steps_off_into(t, comp):
			# stall keepers, smiths, counter clerks stand inside their
			# fixture's pathing halo: the walker starts on the INF tile and
			# steps off (A* filters neighbours, never the start tile)
			print("WARN %s.strict npc_spawns[%d] %s tile=%s on an obstacle tile (steps off into the default component)"
				% [mid, i, String(n.get("template_id", "")), str(t)])
			continue
		_check_fail(ckey, "%s.strict npc_spawns[%d] %s tile=%s unreachable from default %s"
			% [mid, i, String(n.get("template_id", "")), str(t), str(dt)])


# A spawn on a NON-passable tile (obstacle halo) that has a 4-neighbour in the
# default component it can step onto: the body is not stuck there. A walkable
# tile outside the component is a real pocket and never qualifies.
func _steps_off_into(t: Vector2i, comp: Dictionary) -> bool:
	if GridManager.grid_costs.get(t, INF) != INF or GridManager.door_pass.has(t) or GridManager.door_gaps.has(t):
		return false
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nb: Vector2i = t + d
		if comp.has(nb) and GridManager.can_step(t, nb):
			return true
	return false


# The walking component of from_t (GridManager.can_step + pathable), with every
# door tile passable — closed, unlocked (door_pass) or LOCKED (door_gaps).
func _flood(from_t: Vector2i) -> Dictionary:
	var seen: Dictionary = {from_t: true}
	var frontier: Array[Vector2i] = [from_t]
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	while not frontier.is_empty():
		var next: Array[Vector2i] = []
		for t in frontier:
			for d in dirs:
				var n: Vector2i = t + d
				if seen.has(n) or not GridManager.map_rect.has_point(n):
					continue
				var passable: bool = GridManager.grid_costs.get(n, INF) != INF \
					or GridManager.door_pass.has(n) or GridManager.door_gaps.has(n)
				if passable and GridManager.can_step(t, n):
					seen[n] = true
					next.append(n)
		frontier = next
	return seen
