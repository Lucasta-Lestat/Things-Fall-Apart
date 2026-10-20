extends Node2D
# RUN furniture regression (Items/RunLayout.gd, RunRenderer.gd, Item.gd run
# branch, Game._world_item_options / ai._is_takeable_item):
#   1. RunLayout math: the opaque strip spans exactly [-L/2, L/2] x [-W/2, W/2]
#      (tiles abut, sum to the length), caps on/off/L-T bitmask, short-run cap
#      squeeze, tile mode fills the span with whole tiles, determinism.
#   2. Parity: tests/run_parity_fixture.json (shared byte-for-byte with Terrain
#      Generation's tests/run_parity_fixture.json, checked there by PrimsCheck
#      test_prim_runs against scripts/RunArt.gd) is reproduced exactly.
#   3. Item: a run spawn hides the sprite, draws through RunRenderer, is FIXED
#      (collision layer 0, no options, not AI-takeable), hp scales with length;
#      a run on an id without a "run" block falls back to a stretched sprite.
# Synthetic map; this node stands in for Game (group "game", current scene).
# Run headless:  godot --headless --path . res://tests/item_run_check.tscn
# Rewrite the fixture (ONLY after an intended RunLayout change, then copy it to
# TG tests/ too):  RUN_FIXTURE_WRITE=1 godot --headless --path . res://tests/item_run_check.tscn
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const ITEM_SCENE := preload("res://Structures/Objects/Item.tscn")
const FIXTURE := "res://tests/run_parity_fixture.json"

# --- Game stand-in state (read by the scripts under test) ---
var characters_in_scene: Array = []
var items_in_scene: Array = []
var structures_in_scene: Array = []
var party_chars: Array = []
var selected_characters: Array = []
var context_menu_open := false
var primary_selected = null
var stealth_mode := false
var current_map_data: Dictionary = {}
var current_map_id := ""
var fog_manager = null
var map_loader = null
var _game_logic = null
var _fails := 0
var _checks := 0


func load_map(_a = null, _b = "", _c = "") -> void:
	pass

func register_attack_start(_a) -> void:
	pass

func register_attack_end(_a) -> void:
	pass

func is_seen_by_party(c) -> bool:
	return c in party_chars

func _world_item_options(item) -> Array:
	return _game_logic._world_item_options(item)


func _report(check_name: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("%s %s: %s" % ["PASS" if ok else "FAIL", check_name, detail])


func _meta(id: String) -> Dictionary:
	var d: Dictionary = ItemDatabase.items.get(id, {})
	var mv: Variant = d.get("run")
	return mv if mv is Dictionary else {}


# Opaque x/y extents of a tile list (dst rects minus the transparent pad).
func _extent(tiles: Array, meta: Dictionary, width: float) -> Rect2:
	var opaque_h: float = float(meta["h"]) - 2.0 * float(meta["pad"])
	var pk: float = float(meta["pad"]) * width / opaque_h
	var r: Rect2 = tiles[0]["dst"]
	for t in tiles:
		r = r.merge(t["dst"])
	return r.grow_individual(0.0, -pk, 0.0, -pk)


func _ready() -> void:
	add_to_group("game")
	TimeManager.pause_time()
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	_game_logic = load("res://Game.gd").new()
	await get_tree().process_frame
	if OS.get_environment("RUN_FIXTURE_WRITE") != "":
		_write_fixture()
		get_tree().quit(0)
		return
	_case_layout()
	_case_parity()
	await _case_items()
	print("ITEM RUN CHECK DONE: %d checks, %d FAIL" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _case_layout() -> void:
	var lt := _meta("long_table")
	var bn := _meta("bench")
	var rc := _meta("red_carpet")
	_report("data.run-blocks", not lt.is_empty() and not bn.is_empty() and not rc.is_empty(),
		"long_table/bench/red_carpet carry Items.json run blocks")
	if lt.is_empty() or rc.is_empty():
		return
	# guildhall: 14.1 m x 1.95 m
	var L := 601.6
	var W := 83.2
	var t3: Array = RunLayout.tiles(L, W, lt, 3, 7)
	var e3: Rect2 = _extent(t3, lt, W)
	var pk: float = 4.0 * W / (264.0 - 8.0)
	_report("layout.stretch-3-pieces", t3.size() == 3, "%d" % t3.size())
	_report("layout.opaque-length", absf(e3.size.x - (L + 2.0 * pk)) < 1e-3 and absf(e3.position.x + L * 0.5 + pk) < 1e-3,
		"x %.4f..%.4f" % [e3.position.x, e3.end.x])
	_report("layout.opaque-width", absf(e3.size.y - W) < 1e-3 and absf(e3.position.y + W * 0.5) < 1e-3,
		"y %.4f..%.4f" % [e3.position.y, e3.end.y])
	var abut := true
	for i in range(1, t3.size()):
		if absf((t3[i - 1]["dst"] as Rect2).end.x - (t3[i]["dst"] as Rect2).position.x) > 1e-9:
			abut = false
	_report("layout.tiles-abut", abut)
	var span := 0.0
	for t in t3:
		span += (t["dst"] as Rect2).size.x
	_report("layout.tiles-sum-to-length", absf(span - (L + 2.0 * pk)) < 1e-3, "%.4f" % span)
	# caps bitmask: 0 = both butt ends (an L/T join), 1 start only, 2 end only
	var t0: Array = RunLayout.tiles(L, W, lt, 0, 7)
	var e0: Rect2 = t0[0]["dst"]
	_report("layout.caps0-butt", t0.size() == 1 and absf(e0.position.x + L * 0.5) < 1e-3 and absf(e0.end.x - L * 0.5) < 1e-3)
	var t1: Array = RunLayout.tiles(L, W, lt, 1, 7)
	var t2: Array = RunLayout.tiles(L, W, lt, 2, 7)
	_report("layout.caps1-start-only", t1.size() == 2 and (t1[0]["src"] as Rect2).position.x == 0.0
		and absf((t1[1]["dst"] as Rect2).end.x - L * 0.5) < 1e-3)
	_report("layout.caps2-end-only", t2.size() == 2 and absf((t2[0]["dst"] as Rect2).position.x + L * 0.5) < 1e-3
		and (t2[1]["src"] as Rect2).end.x == float(lt["w"]))
	# short run: caps squeezed to 60% of the length, a 40% middle survives
	var ts: Array = RunLayout.tiles(12.0, W, lt, 3, 1)
	var tm: Rect2 = ts[1]["dst"] if ts.size() == 3 else Rect2()
	_report("layout.short-run-cap-shrink", ts.size() == 3 and absf(tm.size.x - 4.8) < 1e-3 and absf(tm.position.x + 2.4) < 1e-3,
		"mid %.4f at %.4f" % [tm.size.x, tm.position.x])
	# tile mode (the runner): whole tiles, equal widths, sum to the span
	var tr: Array = RunLayout.tiles(560.0, 26.0, rc, 3, 99)
	var mids := tr.slice(1, tr.size() - 1)
	var tw: float = (mids[0]["dst"] as Rect2).size.x
	var same := true
	var msum := 0.0
	for t in mids:
		msum += (t["dst"] as Rect2).size.x
		if absf((t["dst"] as Rect2).size.x - tw) > 1e-9:
			same = false
	var cap_k: float = float(rc["cap"]) * 26.0 / (float(rc["h"]) - 2.0 * float(rc["pad"]))
	_report("layout.tile-fit", mids.size() >= 2 and same and absf(msum - (560.0 - 2.0 * cap_k)) < 1e-3,
		"%d tiles of %.3f" % [mids.size(), tw])
	# determinism + hash contract
	_report("layout.deterministic", str(RunLayout.tiles(L, W, lt, 3, 7)) == str(t3))
	_report("layout.hash", RunLayout.hash_i(0, 0) == 0 and RunLayout.hash_i(1, 1) == ((73856093 ^ 19349663) & 0x7fffffff),
		"%d" % RunLayout.hash_i(1, 1))
	# spawn -> run dict (strings/floats from JSON are coerced)
	var rd: Dictionary = RunLayout.run_from_spawn({"length": 601.6, "width": 83.2, "seed": 42.0, "decor": [{"id": "_plate"}]})
	_report("layout.run-from-spawn", float(rd["length"]) == 601.6 and int(rd["caps"]) == 3 and int(rd["seed"]) == 42
		and (rd["decor"] as Array).size() == 1)
	_report("layout.no-length-no-run", RunLayout.run_from_spawn({"id": "long_table"}).is_empty())


# --- parity fixture ---------------------------------------------------------

func _fixture_cases() -> Array:
	var synth := {"atlas": "", "w": 400, "h": 72, "pad": 4, "cap": 20,
		"mid": [[36, 116], [124, 204], [212, 292]], "mid_mode": "tile", "across": 30.0, "shadow": 0.0}
	var out: Array = []
	var metas := {"long_table": _meta("long_table"), "bench": _meta("bench"), "red_carpet": _meta("red_carpet"), "synth3": synth}
	var shapes: Array = [
		["long_table", 601.6, 83.2, 3, 0], ["long_table", 425.3, 42.7, 3, 77], ["long_table", 120.0, 40.1, 1, 5],
		["long_table", 120.0, 40.1, 2, 5], ["long_table", 96.0, 40.1, 0, 5], ["long_table", 10.0, 40.1, 3, 5],
		["bench", 128.0, 20.5, 3, 11], ["bench", 81.1, 19.2, 3, 2147483647], ["bench", 6.0, 20.5, 3, 0],
		["red_carpet", 567.5, 26.5, 3, 1234], ["red_carpet", 33.0, 26.5, 3, 9], ["red_carpet", 280.0, 32.0, 1, 0],
		["synth3", 700.0, 30.0, 3, 1], ["synth3", 700.0, 30.0, 3, 2], ["synth3", 1000.0, 22.0, 2, 1999999999],
	]
	for s in shapes:
		var m: Dictionary = metas[s[0]]
		var rects: Array = []
		for t in RunLayout.tiles(float(s[1]), float(s[2]), m, int(s[3]), int(s[4])):
			var d: Rect2 = t["dst"]
			var r: Rect2 = t["src"]
			rects.append([d.position.x, d.position.y, d.size.x, d.size.y, r.position.x, r.position.y, r.size.x, r.size.y])
		out.append({"meta_id": s[0], "length": s[1], "width": s[2], "caps": s[3], "seed": s[4], "rects": rects})
	return out


func _write_fixture() -> void:
	var metas := {"long_table": _meta("long_table"), "bench": _meta("bench"), "red_carpet": _meta("red_carpet")}
	var hashes: Array = []
	for s in [0, 1, 7, 1234, 2147483647]:
		for i in [0, 1, 2, 17]:
			hashes.append([s, i, RunLayout.hash_i(s, i)])
	var cases := _fixture_cases()
	# the synthetic 3-variant meta is stored inline so TG needs no Items.json
	var synth := {"atlas": "", "w": 400, "h": 72, "pad": 4, "cap": 20,
		"mid": [[36, 116], [124, 204], [212, 292]], "mid_mode": "tile", "across": 30.0, "shadow": 0.0}
	metas["synth3"] = synth
	var doc := {"_contract": "RunLayout.tiles(length, width, metas[meta_id], caps, seed) -> rects [dst x,y,w,h, src x,y,w,h]; written by TFA tests/item_run_check.gd (RUN_FIXTURE_WRITE=1), byte-identical copy in Terrain Generation tests/",
		"metas": metas, "hash": hashes, "cases": cases}
	var f := FileAccess.open(FIXTURE, FileAccess.WRITE)
	f.store_string(JSON.stringify(doc, "  ", true, true) + "\n")
	f.close()
	print("fixture written: %d cases" % cases.size())


func _case_parity() -> void:
	if not FileAccess.file_exists(FIXTURE):
		_report("parity.fixture-present", false, FIXTURE)
		return
	var f := FileAccess.open(FIXTURE, FileAccess.READ)
	var doc: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (doc is Dictionary):
		_report("parity.fixture-parses", false)
		return
	var metas: Dictionary = (doc as Dictionary)["metas"]
	# the fixture's Items metas must still be the live Items.json blocks
	var live_same := true
	for mid in ["long_table", "bench", "red_carpet"]:
		if JSON.stringify(metas[mid], "", true, true) != JSON.stringify(_meta(mid), "", true, true):
			live_same = false
	_report("parity.metas-match-items-json", live_same)
	var hbad := 0
	for h in (doc as Dictionary)["hash"]:
		if RunLayout.hash_i(int(h[0]), int(h[1])) != int(h[2]):
			hbad += 1
	_report("parity.hash", hbad == 0, "%d mismatches" % hbad)
	var bad := 0
	var n := 0
	for c in (doc as Dictionary)["cases"]:
		var m: Dictionary = metas[String(c["meta_id"])]
		var got: Array = RunLayout.tiles(float(c["length"]), float(c["width"]), m, int(c["caps"]), int(c["seed"]))
		var want: Array = c["rects"]
		n += 1
		if got.size() != want.size():
			bad += 1
			continue
		for i in got.size():
			var d: Rect2 = got[i]["dst"]
			var r: Rect2 = got[i]["src"]
			var g := [d.position.x, d.position.y, d.size.x, d.size.y, r.position.x, r.position.y, r.size.x, r.size.y]
			var w: Array = want[i]
			for j in 8:
				# 1e-6 px: Godot's JSON prints the 17th digit loosely, so exact
				# double equality would flake; any formula drift is far larger
				if absf(float(g[j]) - float(w[j])) > 1e-6:
					if bad < 3:
						print("  parity mismatch %s case %d rect %d [%d]: %s vs %s" % [c["meta_id"], n, i, j, String.num(float(g[j]), 17), String.num(float(w[j]), 17)])
					bad += 1
					break
	_report("parity.cases-exact", bad == 0 and n >= 15, "%d cases, %d mismatches" % [n, bad])


# --- items --------------------------------------------------------------------

func _run_item(id: String, run: Dictionary, at: Vector2) -> Item:
	var it: Item = ITEM_SCENE.instantiate()
	it.id = id
	it.run = run
	it.global_position = at
	add_child(it)
	items_in_scene.append(it)
	return it


func _case_items() -> void:
	var lt_run := RunLayout.run_from_spawn({"length": 601.6, "width": 83.2, "seed": 3,
		"decor": [{"id": "_plate", "at": [10.0, 20.0]}, {"id": "_candle", "at": [0.0, 0.0]},
			{"id": "red_carpet", "at": [0.0, 0.0], "length": 560.0, "width": 26.0},
			{"id": "bread_loaf", "at": [40.0, 0.0], "scale": 0.3}, {"id": "no_such_decor_id"}]})
	var table := _run_item("long_table", lt_run, Vector2(700, 700))
	var plain: Item = ITEM_SCENE.instantiate()
	plain.id = "long_table"
	plain.global_position = Vector2(400, 300)
	add_child(plain)
	items_in_scene.append(plain)
	var stool_run := _run_item("stool", RunLayout.run_from_spawn({"length": 120.0}), Vector2(300, 900))
	await get_tree().process_frame
	var rr: Node = table.get_node_or_null("RunRenderer")
	_report("item.run-renderer", rr != null and not table.sprite.visible, "renderer child, sprite hidden")
	if rr != null:
		_report("item.renderer-tiles", (rr.get("_tiles") as Array).size() == 3)
		_report("item.decor-prepared", (rr.get("_builtins") as Array).size() == 2 and (rr.get("_strips") as Array).size() == 1
			and (rr.get("_sprites") as Array).size() == 1, "unknown decor ids skipped with one warning")
		_report("item.renderer-mipmaps", (rr as CanvasItem).texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS)
	_report("item.fixed", table.fixed and table.collision_layer == 0, "layer %d" % table.collision_layer)
	var expect_hp: int = int(round(40.0 * 601.6 / 88.0))
	_report("item.hp-scales-with-length", table.max_health == expect_hp and table.current_health == expect_hp,
		"%d (want %d)" % [table.max_health, expect_hp])
	_report("item.fixed-no-options", _game_logic._world_item_options(table).is_empty())
	_report("item.plain-still-pickable", not plain.fixed and plain.collision_layer != 0
		and str(_game_logic._world_item_options(plain)) == str(["Pick Up"]))
	_report("item.plain-hp-unscaled", plain.max_health == 40)
	_report("item.fallback-no-meta", stool_run.fixed and stool_run.sprite.visible
		and stool_run.get_node_or_null("RunRenderer") == null, "stool has no run block: stretched sprite")
	# NPC AI may not carry a run off
	var looter: ProceduralCharacter = CHAR_SCENE.instantiate()
	looter.is_player_controlled = false
	looter.AI_enabled = false
	add_child(looter)
	looter.game = self
	looter.faction_id = "neutral"
	looter.global_position = Vector2(760, 760)
	characters_in_scene.append(looter)
	await get_tree().physics_frame
	var lai = looter.get_node("AI")
	_report("ai.run-not-takeable", not lai._is_takeable_item(table))
	_report("ai.plain-still-takeable", lai._is_takeable_item(plain))
