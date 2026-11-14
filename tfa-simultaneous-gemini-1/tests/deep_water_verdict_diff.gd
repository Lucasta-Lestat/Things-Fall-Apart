extends Node2D
# P3-D proof that the relative deep-water rule REPRODUCES today's verdicts: a
# per-tile diff of GridManager.is_deep_water on every shipped structured map,
#   OLD = the map as it ships (contract 2: no water layer, so the absolute
#         -0.5 rule; also checked against a literal copy of that rule as it
#         stood before P3-D),
#   NEW = the same map with the contract-3 open-water layer (cells.json
#         tile_water / tile_body) from a TG export or headless dump of it, so
#         is_deep_water measures depth below each water's own surface.
# A map's contract-3 cells.json is used only when every other key equals the
# shipped file's (the layer is the only difference); a map whose contract-3
# file has no layer (no open water) is reported, and its NEW verdicts are the
# fallback's. Floors, decks and the relief switch come from the shipped row
# through MapLoader (images swapped for the icon: no art is loaded).
#   TFA_DEEP_CELLS=<dir of <id>_cells.json> godot --headless --path . res://tests/deep_water_verdict_diff.tscn
# Env: TFA_DEEP_MAPS (comma list; default every format:"structured" row of
# data/Maps.json whose cell_graph exists). Without TFA_DEEP_CELLS only the
# OLD-vs-literal check runs (a map is then "no c3 file").
# Prints one line per map and "DEEP WATER DIFF DONE: N maps, M tiles differ,
# K FAIL"; exit 0 when no tile differs and every map had a usable file.
const MAP_LOADER := preload("res://Structures/MapLoader.gd")

var structures_in_scene: Array = []
var party_chars: Array = []
var unlocked_locks: Dictionary = {}

var _fails := 0
var _maps := 0
var _diff_total := 0


func _ready() -> void:
	await get_tree().process_frame
	var cdir := OS.get_environment("TFA_DEEP_CELLS").replace("\\", "/").trim_suffix("/")
	var only: PackedStringArray = []
	var envm := OS.get_environment("TFA_DEEP_MAPS")
	if envm != "":
		only = envm.split(",", false)
	var f := FileAccess.open("res://data/Maps.json", FileAccess.READ)
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	for m_v in data["maps"]:
		var m: Dictionary = m_v
		var mid := String(m.get("id", ""))
		if String(m.get("format", "")) != "structured" or not ResourceLoader.exists(String(m.get("cell_graph", ""))) \
				and not FileAccess.file_exists(String(m.get("cell_graph", ""))):
			continue
		if not only.is_empty() and not only.has(mid):
			continue
		await _diff_map(m, cdir)
	print("DEEP WATER DIFF DONE: %d maps, %d tiles differ, %d FAIL" % [_maps, _diff_total, _fails])
	get_tree().quit(1 if _fails > 0 or _maps == 0 else 0)


# The deep-water rule as it stood before P3-D (GridManager at TFA 07a3cb2e).
func _literal_old(t: Vector2i) -> bool:
	return GridManager.relief_los and GridManager.floors.get(t, "") == "shallow_water" \
		and GridManager.effective_elev(t) <= GridManager.DEEP_WATER_ELEV + 0.0001


func _load(m: Dictionary, cells_path: String) -> Node2D:
	var ws: Array = m["world_size"]
	GridManager.TILE_SIZE = 64
	GridManager.initialize(int(ws[0]), int(ws[1]))
	GridManager.set_elevation_data(CellGraph.from_structured(cells_path))
	var row: Dictionary = m.duplicate(true)
	row["images"] = {"map": "res://icon.svg"}
	row.erase("lights")
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	ml.generate_structured_map(row)
	return ml


func _verdicts(literal: bool) -> PackedByteArray:
	var out := PackedByteArray()
	var r: Rect2i = GridManager.map_rect
	out.resize(r.size.x * r.size.y)
	for y in r.size.y:
		for x in r.size.x:
			var t := Vector2i(x, y)
			var v: bool = _literal_old(t) if literal else GridManager.is_deep_water(t)
			out[y * r.size.x + x] = 1 if v else 0
	return out


func _parse(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var v: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return v if v is Dictionary else {}


func _free(ml: Node2D) -> void:
	ml.queue_free()
	structures_in_scene.clear()
	await get_tree().process_frame


func _diff_map(m: Dictionary, cdir: String) -> void:
	var mid := String(m["id"])
	var shipped := String(m["cell_graph"])
	_maps += 1
	var t0 := Time.get_ticks_msec()
	var ml := _load(m, shipped)
	var old := _verdicts(false)
	var lit := _verdicts(true)
	var relief: bool = GridManager.relief_los
	var cols: int = GridManager.map_rect.size.x
	await _free(ml)
	var old_n := old.count(1)
	var lit_ok: bool = old == lit
	if not lit_ok:
		_fails += 1
	var note := ""
	var c3 := cdir + "/%s_cells.json" % mid
	if cdir == "" or not FileAccess.file_exists(c3):
		_fails += 1 if cdir != "" else 0
		print("%s %s: tiles %d relief %s deep(old) %d, literal-old %s | no c3 file" % [
			"FAIL" if cdir != "" or not lit_ok else "PASS", mid, old.size(), str(relief), old_n,
			"same" if lit_ok else "DIFFERS"])
		return
	# the graft is valid only when the layer is the only difference
	var a := _parse(ProjectSettings.globalize_path(shipped))
	var b := _parse(c3)
	var has_layer: bool = b.has("tile_water") and b.has("tile_body")
	b.erase("tile_water")
	b.erase("tile_body")
	if a.is_empty() or a != b:
		_fails += 1
		print("FAIL %s: the contract-3 cells.json differs from the shipped one outside tile_water/tile_body (keys %s vs %s)"
			% [mid, str(a.keys()), str(b.keys())])
		return
	ml = _load(m, c3)
	var layer_used: bool = GridManager.has_water_layer()
	var water_tiles := 0
	if layer_used:
		for y in GridManager.map_rect.size.y:
			for x in cols:
				if GridManager.water_body_at(Vector2i(x, y)) > 0:
					water_tiles += 1
	var nw := _verdicts(false)
	await _free(ml)
	var diffs: Array = []
	var n_diff := 0
	for i in nw.size():
		if nw[i] != old[i]:
			n_diff += 1
			if diffs.size() < 6:
				diffs.append("(%d,%d) old %d new %d" % [i % cols, i / cols, old[i], nw[i]])
	_diff_total += n_diff
	if n_diff > 0 or not lit_ok or has_layer != layer_used:
		_fails += 1
	if not has_layer:
		note = " (the contract-3 file has no layer: no open water)"
	print("%s %s: tiles %d relief %s | deep old %d new %d, %d differ%s | layer %s, %d open-water tiles%s | literal-old %s | %d ms" % [
		"PASS" if n_diff == 0 and lit_ok and has_layer == layer_used else "FAIL", mid, nw.size(), str(relief),
		old_n, nw.count(1), n_diff, (": " + ", ".join(diffs)) if n_diff > 0 else "",
		str(layer_used), water_tiles, note, "same" if lit_ok else "DIFFERS", Time.get_ticks_msec() - t0])
