extends Node2D
# Spawn-tile walkability audit: loads a map exactly like the game (MapLoader +
# CellGraph elevations) and verifies every ladder/fort warp-arrival spawn is
# usable — *_base tiles walkable at ground level, *_top tiles walkable at
# elevation. Headless-safe (no rendering).
# Run:  godot --headless --path . res://tests/spawn_walk_check.tscn
# Env:  TFA_MAPS = comma-separated map ids (default all tg_* structured maps)
const MAP_LOADER := preload("res://Structures/MapLoader.gd")
var structures_in_scene: Array = []
var party_chars: Array = []
var unlocked_locks: Dictionary = {}
var fails := 0
var checks := 0


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
	print("spawn_walk_check: %d checks, %d FAIL" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)


func _audit_map(m: Dictionary) -> void:
	var mid := String(m.get("id", ""))
	GridManager.TILE_SIZE = int(m.get("tile_size", 64))
	var ws: Array = m.get("world_size", [2048, 2048])
	GridManager.initialize(int(ws[0]), int(ws[1]))
	var graph: CellGraph = CellGraph.from_structured(String(m.get("cell_graph", "")))
	GridManager.set_elevation_data(graph)
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	ml.generate_structured_map(m)
	for k in m.get("player_spawns", {}):
		var sk := String(k)
		var is_base := sk.ends_with("_base")
		var is_top := sk.ends_with("_top")
		if not (is_base or is_top):
			continue
		var pos_a: Array = m["player_spawns"][k]["position"]
		var t := GridManager.world_to_map(Vector2(float(pos_a[0]), float(pos_a[1])))
		var e := GridManager.effective_elev(t)
		var ok: bool = GridManager.would_walk(t) and \
			((absf(e) < 0.55) if is_base else (e >= 1.0))
		checks += 1
		if not ok:
			fails += 1
			print("FAIL %s.%s tile=%s elev=%.2f walkable=%s"
				% [mid, sk, str(t), e, str(GridManager.would_walk(t))])
	ml.queue_free()
	# structures from this map must not bleed into the next audit
	for s in structures_in_scene:
		if is_instance_valid(s):
			s.queue_free()
	structures_in_scene = []
