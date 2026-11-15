extends Node2D
# Visual QA for P3-B (crowns above characters, the fade, the cone shading):
# loads a structured map through MapLoader like the game, picks a crown (the
# record's crown with the most overlapping neighbours, or TFA_AT="x,y"),
# stands two stand-in characters (a yellow party member under the crown's
# leaves, a red NPC beside it) and saves, under TFA_SHOT_DIR (default
# user://shots; never the project: tests/shot_dir.gd):
#   canopy_<map>_crowns.png     the grove: crowns over the party member, faded
#                               round it; the NPC under its crown covered
#   canopy_<map>_cursor.png     the same with the cursor over another crown
#   canopy_<map>_cone.png       a ground NPC's red sight cone into the grove
#                               (+ its canopy child when the map has one)
#   canopy_<map>_cone_far.png   the same from 0.75 of its range: the crown past
#                               half range
#   canopy_<map>_cone_fadehole.png  the same, the party member back under the
#                               crown: its fade hole's ground and the party
#                               member stay unlit by that cone (the rules hide
#                               them from it)
#   canopy_<map>_cone_high.png  the same viewer a story up (on a roof)
#   canopy_<map>_route.png      a planned route (PathDrawer) through the crown:
#                               the crown fades along it
# The world wears game.tscn's CanvasModulate (0.716), as in the game.
# On a map without the contract-3 canopy cells (every shipped map today) the
# crowns are the structures overlay's, under the stand-ins, and the cone has
# no canopy child: the "before" shots. WINDOWED only (the headless renderer
# is a dummy and saves black PNGs). Run it through its SubViewport mode (the
# window stays 64x64 and off-screen):
#   godot --path . --resolution 64x64 --position -20000,-20000 res://tests/canopy_shot_sv.tscn
# Env: TFA_MAP (default tg_hillside_middle), TFA_AT, TFA_SHOT_DIR.
const MAP_LOADER := preload("res://Structures/MapLoader.gd")
const ShotDir := preload("res://tests/shot_dir.gd")
const VIEW := Vector2(1200.0, 860.0)

var structures_in_scene: Array = []
var characters_in_scene: Array = []
var party_chars: Array = []
var unlocked_locks: Dictionary = {}
var map_loader: Node2D = null


class Marker extends Node2D:
	var col := Color.WHITE
	var on_roof := false
	func _ready() -> void:
		z_index = 5
		queue_redraw()
	func _draw() -> void:
		draw_circle(Vector2.ZERO, 17.0, Color(0.1, 0.1, 0.1))
		draw_circle(Vector2.ZERO, 14.0, col)
		draw_line(Vector2.ZERO, Vector2(0, -22), Color(0.1, 0.1, 0.1), 4.0)
	func height_above_ground() -> float:
		return 0.0
	func canopy_crown() -> int:
		return GridManager.canopy.crown_at(global_position)
	func _canopy_near_px(_o) -> float:
		return GridManager.TILE_SIZE * ProceduralCharacter.CANOPY_NEAR_TILES + 16.0


func _ready() -> void:
	var f := FileAccess.open("res://data/Maps.json", FileAccess.READ)
	var raw: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	var want := OS.get_environment("TFA_MAP")
	if want == "":
		want = "tg_hillside_middle"
	var m: Dictionary = {}
	for e in raw.get("maps", []):
		if String(e.get("id", "")) == want:
			m = e
			break
	GridManager.TILE_SIZE = int(m.get("tile_size", 64))
	var ws: Array = m.get("world_size", [2048, 2048])
	GridManager.initialize(int(ws[0]), int(ws[1]))
	GridManager.set_elevation_data(CellGraph.from_structured(String(m.get("cell_graph", ""))))
	# game.tscn's world tint: lit things (and a lit MUL quad) are multiplied by it
	var cm := CanvasModulate.new()
	cm.color = Color(0.716296, 0.716296, 0.716296)
	add_child(cm)
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	map_loader = ml
	ml.generate_structured_map(m)
	var layer: CanopyLayer = ml.canopy_layer
	print("canopy_shot: %s crowns=%d canopy_layer=%s" % [want, GridManager.canopy.crown_count(), str(layer != null)])
	# the grove: the live crown with the most neighbours within 3.5 r (the
	# bigger crown on a tie)
	var best := -1
	var best_n := -1.0
	var at_env := OS.get_environment("TFA_AT")
	for i in GridManager.canopy.crown_count():
		var ci: Dictionary = GridManager.canopy.crown(i)
		var n: float = float(ci["r"]) * 0.001
		for j in GridManager.canopy.crown_count():
			var cj: Dictionary = GridManager.canopy.crown(j)
			if (ci["pos"] as Vector2).distance_to(cj["pos"]) < 3.5 * float(ci["r"]):
				n += 1.0
		if at_env != "":
			var xy := at_env.split(",")
			n = -(ci["pos"] as Vector2).distance_to(Vector2(float(xy[0]), float(xy[1])))
		if n > best_n:
			best_n = n
			best = i
	if best < 0:
		push_error("canopy_shot: no crown on " + want)
		get_tree().quit(1)
		return
	var c0: Dictionary = GridManager.canopy.crown(best)
	var cpos: Vector2 = c0["pos"]
	var r: float = c0["r"]
	print("canopy_shot: crown %d at %s r %.1f (score %.3f)" % [best, str(cpos), r, best_n])
	var party := Marker.new()
	party.col = Color(1.0, 0.85, 0.15)
	party.position = cpos + Vector2(r * 0.7, 0.0)
	add_child(party)
	party_chars = [party]
	var npc := Marker.new()
	npc.col = Color(0.9, 0.2, 0.2)
	npc.position = cpos + Vector2(-r * 0.7, r * 0.2)
	add_child(npc)
	characters_in_scene = [party, npc]
	var cam := Camera2D.new()
	cam.position = cpos
	var vp := get_viewport().get_visible_rect().size
	var z := minf(vp.x / VIEW.x, vp.y / VIEW.y)
	cam.zoom = Vector2(z, z)
	add_child(cam)
	cam.make_current()
	var out_dir := ShotDir.dir()
	if layer != null:
		layer.cursor_override = Vector2(-99999, -99999)
	await _shot(out_dir + "/canopy_%s_crowns.png" % want)
	# the cursor over a neighbour crown (or past this one)
	if layer != null:
		layer.cursor_override = cpos + Vector2(-r * 0.2, -r * 1.6)
	await _shot(out_dir + "/canopy_%s_cursor.png" % want)
	if layer != null:
		layer.cursor_override = Vector2(-99999, -99999)
	# a ground NPC's cone from 3.2 r west of the crown, looking east into it
	var viewer := Marker.new()
	viewer.col = Color(0.95, 0.35, 0.95)
	viewer.position = cpos + Vector2(-r * 3.2, -r * 0.4)
	add_child(viewer)
	var light := PointLight2D.new()
	light.texture = Globals.get_sight_cone_texture(120.0)
	light.texture_scale = 900.0 / (light.texture.get_width() * 0.5)
	light.color = Color(1.0, 0.3, 0.2)
	light.energy = 0.5
	light.shadow_enabled = true
	light.range_item_cull_mask = 1
	light.shadow_item_cull_mask = CollisionLayers.SIGHT_MASK_GROUND
	if GridManager.relief_los:
		light.shadow_item_cull_mask = CollisionLayers.SIGHT_MASK_GROUND \
			| GridManager.cone_band_bit(GridManager.cone_band(GridManager.effective_elev(GridManager.world_to_map(viewer.position))))
	light.z_index = 102
	viewer.add_child(light)
	viewer.rotation = (cpos - viewer.position).angle()
	party.position = cpos + Vector2(r * 2.6, 0.0)   # out of the grove: no fade in the cone shots
	CanopyLayer.fit_canopy_cone(light, viewer, layer)
	await _shot(out_dir + "/canopy_%s_cone.png" % want)
	# the same viewer 0.75 of its range away: the crown past half range (unlit
	# with canopy cells), the ground round it lit as before
	var near_pos: Vector2 = viewer.position
	viewer.position = cpos + (near_pos - cpos).normalized() * 675.0
	CanopyLayer.fit_canopy_cone(light, viewer, layer)
	cam.position = (viewer.position + cpos) * 0.5
	await _shot(out_dir + "/canopy_%s_cone_far.png" % want)
	# the party member hidden under the crown again, the far cone on it
	party.position = cpos + Vector2(r * 0.7, 0.0)
	cam.position = cpos
	await _shot(out_dir + "/canopy_%s_cone_fadehole.png" % want)
	party.position = cpos + Vector2(r * 2.6, 0.0)
	viewer.position = near_pos
	viewer.on_roof = true
	CanopyLayer.fit_canopy_cone(light, viewer, layer)
	await _shot(out_dir + "/canopy_%s_cone_high.png" % want)
	# a planned route through the crown, the cone off
	light.enabled = false
	CanopyLayer.fit_canopy_cone(light, viewer, layer)
	var pd := PathDrawer.new()
	pd.tactical_path = TacticalPath.new()
	pd.tactical_path.set_waypoints(PackedVector2Array([cpos + Vector2(-r * 2.4, r * 0.9),
		cpos + Vector2(-r * 0.3, r * 0.35), cpos + Vector2(r * 2.4, -r * 0.6)]))
	add_child(pd)
	await _shot(out_dir + "/canopy_%s_route.png" % want)
	get_tree().quit(0)


func _shot(path: String) -> void:
	for _i in 4:
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("saved " + path)
