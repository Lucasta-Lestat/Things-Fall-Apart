extends Node2D
# P3-D proof that the relative deep-water rule REPRODUCES today's verdicts: a
# per-tile diff of GridManager.is_deep_water on every shipped structured map,
#   OLD = the map WITHOUT a water layer, so the absolute -0.5 rule (also
#         checked against a literal copy of that rule as it stood before
#         P3-D, on the same load). A map whose shipped cells.json carries no
#         tile_water / tile_body (contract 1/2) loads as it ships. One that
#         carries them (it ships at contract 3: the Perrow tg_hillside_* water
#         maps since P3-T) loads from a copy with both keys removed: the
#         shipped file parsed, the keys erased, written to STRIP_PATH and
#         checked to re-read as exactly that. Either way the OLD load must
#         report no layer (GridManager.has_water_layer() false) or the map
#         FAILS: with the layer, OLD would already be the relative rule and
#         the diff would compare it with itself.
#   NEW = the same map with the contract-3 open-water layer (cells.json
#         tile_water / tile_body), so is_deep_water measures depth below each
#         water's own surface. A map SHIPPING its layer: the shipped file as is
#         (it must load as a layer); it needs no fixture record, and a record
#         left for it is not used (its line says "shipped layer"). Every other
#         map's layer is COMMITTED: LAYERS_PATH holds its pair (run-length
#         text, packed from TG p3-rivers contract-3 dumps whose other keys
#         equal the shipped files), grafted onto the shipped cells.json text
#         here. TFA_DEEP_CELLS=<dir of contract-3 <id>_cells.json> uses those
#         files instead, for every map (each only when every key but
#         tile_water / tile_body equals the shipped file's: the layer is the
#         only difference; and a map SHIPPING its layer FAILS unless the c3
#         file carries that same layer, so a c3 file without it, or with
#         another one, can never pass vacuously). A map
#         with no recorded layer (no open water) is reported, and its NEW
#         verdicts are the fallback's; a map with no record at all is a SKIP (a
#         map shipped after the fixture: re-pack it). Each record carries
#         cells_md5, the md5 of the shipped cells.json text (CR dropped) it was
#         checked against: a shipped map re-exported since FAILS until the
#         fixture is re-packed. More than SKIP_ALLOWANCE skips, or every map
#         skipped, fails the run (a fixture whose ids no longer match would
#         otherwise pass with nothing compared). The packer is
#         tools/pack_c3_water_layers.py (PACK_CMD; --merge re-packs only the
#         maps with a file in the dir, --check lists the stale records; both
#         skip a map shipping its own layer).
# Floors, decks and the relief switch come from the shipped row through
# MapLoader (images swapped for the icon: no art is loaded).
#   godot --headless --path . res://tests/deep_water_verdict_diff.tscn
# Env: TFA_DEEP_MAPS (comma list; default every format:"structured" row of
# data/Maps.json whose cell_graph exists), TFA_DEEP_CELLS (above).
# Prints one line per map and "DEEP WATER DIFF DONE: N maps, M tiles differ,
# K FAIL, S SKIP"; exit 0 when no tile differs, no map failed and at most
# SKIP_ALLOWANCE maps (never all of them) skipped.
const MAP_LOADER := preload("res://Structures/MapLoader.gd")
const LAYERS_PATH := "res://tests/fixtures/p3d_deep_water/c3_water_layers.json"
# temp files (user:// is shared by every worktree of the project, so each run
# names its own by process id): the grafted NEW, and the stripped OLD of a map
# shipping its layer
var GRAFT_PATH := "user://deep_water_verdict_graft_cells_%d.json" % OS.get_process_id()
var STRIP_PATH := "user://deep_water_verdict_strip_cells_%d.json" % OS.get_process_id()
const SKIP_ALLOWANCE := 2   # maps shipped after the fixture was packed, before it is re-packed
# how to re-pack LAYERS_PATH (run from the project folder; TG contract-3 files)
const PACKER_PATH := "res://tools/pack_c3_water_layers.py"
const PACK_CMD := "python tools/pack_c3_water_layers.py <dir of contract-3 <id>_cells.json> --merge"

var structures_in_scene: Array = []
var party_chars: Array = []
var unlocked_locks: Dictionary = {}

var _fails := 0
var _maps := 0
var _skips := 0
var _diff_total := 0
var _layers: Dictionary = {}   # LAYERS_PATH "maps": id -> {layer, cols, rows, tile_water, tile_body}


func _ready() -> void:
	await get_tree().process_frame
	var cdir := OS.get_environment("TFA_DEEP_CELLS").replace("\\", "/").trim_suffix("/")
	var only: PackedStringArray = []
	var envm := OS.get_environment("TFA_DEEP_MAPS")
	if envm != "":
		only = envm.split(",", false)
	if cdir == "":
		var lf := _parse(LAYERS_PATH)
		if lf.is_empty() or not (lf.get("maps") is Dictionary):
			_fails += 1
			print("FAIL the committed water layers %s did not load" % LAYERS_PATH)
		else:
			_layers = lf["maps"]
		# the fixture's re-pack path: its packer is committed and the fixture names it
		if not FileAccess.file_exists(PACKER_PATH) or not String(lf.get("_comment", "")).contains(PACK_CMD.get_slice(" <", 0)):
			_fails += 1
			print("FAIL the fixture packer %s is missing, or %s's _comment does not name it" % [PACKER_PATH, LAYERS_PATH])
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
	for tmp_v in [GRAFT_PATH, STRIP_PATH]:
		var tmp: String = tmp_v
		if FileAccess.file_exists(tmp):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	var skip_bad: bool = _skips > SKIP_ALLOWANCE or (_maps > 0 and _skips == _maps)
	if skip_bad:
		print("FAIL %d of %d maps skipped (allowance %d): re-pack %s: %s" % [_skips, _maps, SKIP_ALLOWANCE, LAYERS_PATH, PACK_CMD])
	print("DEEP WATER DIFF DONE: %d maps, %d tiles differ, %d FAIL, %d SKIP" % [_maps, _diff_total, _fails, _skips])
	get_tree().quit(1 if _fails > 0 or _maps == 0 or skip_bad else 0)


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


func _unrle(runs: Array) -> Array:
	var out: Array = []
	for r_v in runs:
		var r: Array = r_v
		for i in int(r[1]):
			out.append(r[0])
	return out


# md5 of a file's text with every CR dropped (a checkout's line endings never
# matter); "" when it does not open. The fixture packer
# (tools/pack_c3_water_layers.py text_md5) hashes the same bytes.
func _text_md5(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text.replace("\r", "").md5_text()


# The shipped cells.json TEXT with the recorded layer appended (every shipped
# byte kept), written to GRAFT_PATH. "" when the record does not fit the map.
func _graft(shipped: String, rec: Dictionary) -> String:
	var n: int = int(rec["cols"]) * int(rec["rows"])
	var tw := _unrle(rec["tile_water"])
	var tb := _unrle(rec["tile_body"])
	if tw.size() != n or tb.size() != n:
		return ""
	var f := FileAccess.open(shipped, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text().strip_edges()
	f.close()
	if not text.ends_with("}") or text.contains("\"tile_water\""):
		return ""
	var dims := {"cols": int(rec["cols"]), "rows": int(rec["rows"])}
	var wd := dims.duplicate()
	wd["data"] = tw
	var bd := dims.duplicate()
	bd["data"] = tb
	text = text.substr(0, text.length() - 1) + ",\"tile_water\":" + JSON.stringify(wd, "", false, true) \
		+ ",\"tile_body\":" + JSON.stringify(bd, "", false, true) + "}"
	var w := FileAccess.open(GRAFT_PATH, FileAccess.WRITE)
	w.store_string(text)
	w.close()
	return GRAFT_PATH


# True when a parsed cells.json carries the contract-3 open-water layer. Either
# key counts: a lone one is malformed, and its NEW load then fails the layer
# check (has_layer true, no layer loaded).
func _carries_layer(cells: Dictionary) -> bool:
	return cells.has("tile_water") or cells.has("tile_body")


# A parsed cells.json without tile_water / tile_body (only top-level keys go,
# so a shallow copy suffices).
func _without_layer(cells: Dictionary) -> Dictionary:
	var out: Dictionary = cells.duplicate()
	out.erase("tile_water")
	out.erase("tile_body")
	return out


# The shipped cells.json (parsed) minus its water layer, written to STRIP_PATH
# at full float precision and checked to re-read as exactly that: every other
# key and value is the shipped one. "" when it does not.
func _strip(cells: Dictionary) -> String:
	var want := _without_layer(cells)
	var w := FileAccess.open(STRIP_PATH, FileAccess.WRITE)
	if w == null:
		return ""
	w.store_string(JSON.stringify(want, "", false, true))
	w.close()
	if _parse(STRIP_PATH) != want:
		return ""
	return STRIP_PATH


func _free(ml: Node2D) -> void:
	ml.queue_free()
	structures_in_scene.clear()
	await get_tree().process_frame


func _diff_map(m: Dictionary, cdir: String) -> void:
	var mid := String(m["id"])
	var shipped := String(m["cell_graph"])
	_maps += 1
	var t0 := Time.get_ticks_msec()
	# OLD has no water layer: a shipped one (contract 3) is stripped from a copy
	var shipped_cells := _parse(ProjectSettings.globalize_path(shipped))
	var shipped_layer := _carries_layer(shipped_cells)
	var old_path := shipped
	if shipped_layer:
		old_path = _strip(shipped_cells)
		if old_path == "":
			_fails += 1
			print("FAIL %s: the shipped cells.json without tile_water/tile_body did not write to %s intact" % [mid, STRIP_PATH])
			return
	var ml := _load(m, old_path)
	var old_layer: bool = GridManager.has_water_layer()
	var old := _verdicts(false)
	var lit := _verdicts(true)
	var relief: bool = GridManager.relief_los
	var cols: int = GridManager.map_rect.size.x
	await _free(ml)
	if old_layer:
		_fails += 1
		print("FAIL %s: the OLD load (%s) has a water layer, so OLD is not the absolute rule" % [mid, old_path])
		return
	var old_n := old.count(1)
	var lit_ok: bool = old == lit
	if not lit_ok:
		_fails += 1
	var note := ""
	var c3 := ""
	var has_layer := false
	if cdir == "" and shipped_layer:
		# NEW = the shipped file and its own layer: no fixture record needed
		c3 = shipped
		has_layer = true
		note = " (shipped layer used: OLD = the shipped cells.json without it%s)" % [
			"; its fixture record was not used" if _layers.has(mid) else ""]
	elif cdir == "":
		# the committed layer, grafted onto the shipped text
		if not _layers.has(mid):
			_skips += 1
			print("SKIP %s: tiles %d relief %s deep(old) %d, literal-old %s | no recorded contract-3 layer (re-pack %s: %s)" % [
				mid, old.size(), str(relief), old_n, "same" if lit_ok else "DIFFERS", LAYERS_PATH, PACK_CMD])
			return
		var rec: Dictionary = _layers[mid]
		var md5 := _text_md5(ProjectSettings.globalize_path(shipped))
		if String(rec.get("cells_md5", "")) != md5:
			_fails += 1
			print("FAIL %s: the shipped cells.json (md5 %s) is not the one the layer was packed against (%s): re-pack %s: %s" % [
				mid, md5, String(rec.get("cells_md5", "none")), LAYERS_PATH, PACK_CMD])
			return
		has_layer = bool(rec.get("layer", false))
		c3 = shipped
		if has_layer:
			c3 = _graft(ProjectSettings.globalize_path(shipped), rec)
			if c3 == "":
				_fails += 1
				print("FAIL %s: the recorded layer does not fit the shipped cells.json" % mid)
				return
	else:
		c3 = cdir + "/%s_cells.json" % mid
		if not FileAccess.file_exists(c3):
			_fails += 1
			print("FAIL %s: tiles %d relief %s deep(old) %d, literal-old %s | no c3 file in TFA_DEEP_CELLS" % [
				mid, old.size(), str(relief), old_n, "same" if lit_ok else "DIFFERS"])
			return
		# the c3 file is valid only when the layer is the only difference (the
		# shipped file's own layer, when it carries one, set aside too)
		var a := _without_layer(shipped_cells)
		var b_full := _parse(c3)
		has_layer = b_full.has("tile_water") and b_full.has("tile_body")
		if shipped_layer:
			# the map ships its layer: the c3 file must carry exactly that one
			if not has_layer or b_full.get("tile_water") != shipped_cells.get("tile_water") 					or b_full.get("tile_body") != shipped_cells.get("tile_body"):
				_fails += 1
				print("FAIL %s: the map ships its own water layer, and the contract-3 file %s (has a layer: %s) does not carry that same one"
					% [mid, c3, str(has_layer)])
				return
			note = " (shipped layer: OLD = the shipped cells.json without it; the c3 file carries the same layer)"
		var b := _without_layer(b_full)
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
		note += " (the contract-3 file has no layer: no open water)"
	print("%s %s: tiles %d relief %s | deep old %d new %d, %d differ%s | layer %s, %d open-water tiles%s | literal-old %s | %d ms" % [
		"PASS" if n_diff == 0 and lit_ok and has_layer == layer_used else "FAIL", mid, nw.size(), str(relief),
		old_n, nw.count(1), n_diff, (": " + ", ".join(diffs)) if n_diff > 0 else "",
		str(layer_used), water_tiles, note, "same" if lit_ok else "DIFFERS", Time.get_ticks_msec() - t0])
