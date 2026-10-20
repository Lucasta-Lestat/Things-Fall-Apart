# res://tests/art_polys_check.gd
# Headless checks for the structured-map "art_polys" key (TG curtain walls +
# their towers): MapLoader cuts an instance's art from the structures overlay
# by the exporter's exact partition instead of the +-(half+12) rectangle.
# Run:  godot --headless --path . res://tests/art_polys_check.tscn
# Judge by the PASS/FAIL lines and the final "ART_POLYS DONE failures=N".
extends Node2D

const MAP_LOADER := preload("res://Structures/MapLoader.gd")

var failures := 0


func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])


func _ready() -> void:
	GridManager.TILE_SIZE = 64
	GridManager.initialize(16 * 64, 16 * 64)
	var img := Image.create(1024, 1024, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.5, 0.5, 0.5, 1.0))
	var tex := ImageTexture.create_from_image(img)
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	ml._current_map_id = "art_polys_test"
	_case_curtain_piece(ml, tex)
	_case_legacy_wall(ml, tex)
	_case_empty(ml, tex)
	_case_tower(ml, tex)
	print("ART_POLYS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)


# A curtain piece: two slices (body + shadow halo), map px coordinates.
func _case_curtain_piece(ml: Node2D, tex: Texture2D) -> void:
	var body := [[100, 180], [228, 180], [228, 250], [100, 250]]
	var halo := [[100, 250], [228, 250], [240, 300], [110, 300]]
	var s := {"kind": "wall", "a": [100, 215], "b": [228, 215], "half": 35.2, "id": "stone_wall",
		"hp": 160, "occlude_h": 1.6, "art_polys": [body, halo]}
	var inst = ml._spawn_geo_structure(s, tex, 64)
	_check("curtain.spawned", inst != null)
	if inst == null:
		return
	var art := inst.get_node_or_null("Art") as Polygon2D
	_check("curtain.art-is-polygon2d", art != null)
	if art == null:
		return
	_check("curtain.visual-is-art", inst._visual() == art)
	_check("curtain.two-polygons", art.polygons.size() == 2, str(art.polygons.size()))
	_check("curtain.point-count", art.polygon.size() == 8 and art.uv.size() == 8, "%d/%d" % [art.polygon.size(), art.uv.size()])
	var center: Vector2 = inst.position
	var uv_ok := true
	var all_src: Array = body + halo
	for i in all_src.size():
		var src := Vector2(float(all_src[i][0]), float(all_src[i][1]))
		if art.uv[i].distance_to(src) > 1e-4 or (art.polygon[i] + center).distance_to(src) > 1e-4:
			uv_ok = false
	_check("curtain.uv-are-map-px", uv_ok)
	_check("curtain.texture", art.texture == tex)
	var pm := art.material as CanvasItemMaterial
	_check("curtain.premult", pm != null and pm.blend_mode == CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA)
	# collision / pathing are unchanged by the art key
	var cs: CollisionShape2D = inst.get_node("CollisionShape2D")
	var rect := cs.shape as RectangleShape2D
	_check("curtain.collision-unchanged", rect != null and rect.size.is_equal_approx(Vector2(128, 70.4)),
		str(rect.size if rect else Vector2.ZERO))
	_check("curtain.occluder", inst.get_node_or_null("Occluder") != null)
	# damage tint lands on the Art node (self_modulate), destruction hides it
	inst.current_health = 1
	inst._refresh_tint()
	_check("curtain.damage-tint", art.self_modulate.r < 0.99, str(art.self_modulate))


# A wall WITHOUT art_polys keeps the legacy +-(half+12) slice exactly.
func _case_legacy_wall(ml: Node2D, tex: Texture2D) -> void:
	var s := {"kind": "wall", "a": [100, 500], "b": [300, 500], "half": 10.0, "id": "stone_wall", "hp": 80}
	var inst = ml._spawn_geo_structure(s, tex, 64)
	var art := inst.get_node_or_null("Art") as Polygon2D if inst else null
	_check("legacy.art", art != null)
	if art == null:
		return
	_check("legacy.no-polygons", art.polygons.is_empty())
	var g := 10.0 + 12.0
	var dirn := Vector2.RIGHT
	var perp := dirn.orthogonal()   # MapLoader's frame
	var hs := Vector2(100.0, 0.0)
	var want := PackedVector2Array([-hs - dirn * g - perp * (10.0 + g), hs + dirn * g - perp * (10.0 + g),
		hs + dirn * g + perp * (10.0 + g), -hs - dirn * g + perp * (10.0 + g)])
	var ok := art.polygon.size() == 4
	if ok:
		for i in 4:
			if art.polygon[i].distance_to(want[i]) > 1e-3 or art.uv[i].distance_to(want[i] + Vector2(200, 500)) > 1e-3:
				ok = false
	_check("legacy.rect-slice", ok, str(art.polygon))


# art_polys: [] (a piece wholly off the map) builds no Art at all.
func _case_empty(ml: Node2D, tex: Texture2D) -> void:
	var s := {"kind": "wall", "a": [600, 100], "b": [700, 100], "half": 35.2, "id": "stone_wall",
		"hp": 160, "art_polys": []}
	var inst = ml._spawn_geo_structure(s, tex, 64)
	_check("empty.spawned", inst != null)
	if inst == null:
		return
	_check("empty.no-art", inst.get_node_or_null("Art") == null)
	_check("empty.visual-falls-back", inst._visual() == inst.sprite)


# A curtain tower: solid disc (no walk_elev) with its own slices.
func _case_tower(ml: Node2D, tex: Texture2D) -> void:
	var disc := []
	for i in 24:
		var a := TAU * float(i) / 24.0
		disc.append([600.0 + cos(a) * 78.0, 600.0 + sin(a) * 78.0])
	var halo := [[680, 560], [760, 600], [700, 700], [660, 640]]
	var s := {"kind": "disc", "pos": [600, 600], "r": 66.8, "id": "stone_wall", "hp": 160,
		"occlude_h": 2.2, "art_polys": [disc, halo]}
	var inst = ml._spawn_geo_structure(s, tex, 64)
	_check("tower.spawned", inst != null)
	if inst == null:
		return
	_check("tower.solid", not inst.is_deck)
	var circ := (inst.get_node("CollisionShape2D") as CollisionShape2D).shape as CircleShape2D
	_check("tower.collision-r", circ != null and absf(circ.radius - 66.8) < 1e-3)
	var blocked := false
	for t in inst.occupied_tiles:
		if not GridManager.would_walk(t):
			blocked = true
	_check("tower.tiles-blocked", blocked)
	var art := inst.get_node_or_null("Art") as Polygon2D
	_check("tower.art", art != null and art.polygons.size() == 2 and art.polygon.size() == 28)
	var occ := inst.get_node_or_null("Occluder") as LightOccluder2D
	_check("tower.occluder-high", occ != null and (occ.occluder_light_mask & CollisionLayers.SIGHT_MASK_HIGH) != 0)
