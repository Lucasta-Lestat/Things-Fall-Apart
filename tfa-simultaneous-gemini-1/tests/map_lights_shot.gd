extends Node
# Pixel check for map lights inside their own block (P2-C review): TG exports a
# forge / hearth / glow light at its block's centre, inside that wall seg's
# occluder, and a brazier on its tower. MapLoader._open_light_blocks makes such
# an occluder cull the edges the light faces from inside. This renders a
# synthetic structured map through the real generate_structured_map into an
# offscreen SubViewport (the window stays 64x64 and off-screen) and reads pixels:
#   1. a light inside a wall-seg block lights the ground just outside the block
#      on three sides, and one inside a disc (the other polygon winding) too;
#   2. the other walls still shadow it;
#   3. a light OUTSIDE an opened block is shadowed by it exactly as before
#      (the block's far side and its inside stay dark);
#   4. with the block's occluder put back to CULL_DISABLED the light is trapped
#      again (the check tells the two apart).
# WINDOWED only: the headless renderer is a dummy and reads black pixels.
#   godot --path . --resolution 64x64 --position -20000,-20000 res://tests/map_lights_shot.tscn
# Env TFA_SHOT_DIR: also save the shots there (outside the project; one inside
# it goes to user://shots instead: tests/shot_dir.gd).
# Judge by the PASS/FAIL lines and "MAP LIGHTS SHOT DONE: N checks, M FAIL".

const MAP_LOADER := preload("res://Structures/MapLoader.gd")
const EquipmentEffects = preload("res://Items/equipment_effects.gd")
const ShotDir := preload("res://tests/shot_dir.gd")
const SIZE := Vector2i(800, 600)
const DARK := 0.15            # CanvasModulate grey: an unlit ground pixel reads ~38
const LIT_MIN := 30           # a lit pixel reads at least this much above unlit
const DARK_MAX := 8           # an unlit one at most this much

# --- Game stand-in state (read by MapLoader / Structure) ---
var structures_in_scene: Array = []
var characters_in_scene: Array = []
var items_in_scene: Array = []
var party_chars: Array = []
var unlocked_locks: Dictionary = {}
var current_map_id := "map_lights_shot"

var sv: SubViewport
var ml: Node2D
var _fails := 0
var _checks := 0
var _base := 0
var _shot_dir := ""   # "" = do not save the shots


func _report(check_name: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("%s %s: %s" % ["PASS" if ok else "FAIL", check_name, detail])


func _ready() -> void:
	var w := get_window()
	w.borderless = true
	w.unfocusable = true
	w.size = Vector2i(64, 64)
	w.position = Vector2i(-20000, -20000)
	TimeManager.pause_time()
	_shot_dir = ShotDir.dir("TFA_SHOT_DIR", true)
	GridManager.TILE_SIZE = 64
	GridManager.initialize(1024, 1024)
	sv = SubViewport.new()
	sv.size = SIZE
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	var ground := Polygon2D.new()
	ground.polygon = PackedVector2Array([Vector2.ZERO, Vector2(SIZE.x, 0), Vector2(SIZE), Vector2(0, SIZE.y)])
	ground.color = Color.WHITE
	ground.z_index = -10
	sv.add_child(ground)
	var cm := CanvasModulate.new()
	cm.color = Color(DARK, DARK, DARK)
	sv.add_child(cm)
	ml = MAP_LOADER.new()
	sv.add_child(ml)
	ml.generate_structured_map({"id": "map_lights_shot", "format": "structured", "images": {"map": "res://icon.svg"},
		"tile_size": 64, "world_size": [1024, 1024], "floors": [], "export_contract": 2,
		"structures": [
			# a hearth block (77 x 64, a wall seg) with its light at the centre
			{"kind": "wall", "a": [361, 300], "b": [438, 300], "half": 32},
			# a wall 100 px south of it: still shadows that light
			{"kind": "wall", "a": [300, 400], "b": [500, 400], "half": 8},
			# a tower drum with a brazier on it (the other polygon winding)
			{"kind": "disc", "pos": [700, 120], "r": 30}],
		"lights": [{"position": [399.5, 300], "level": 0.84, "source": "hearth"},
			{"position": [700, 120], "level": 0.84, "source": "brazier"}]})
	var gs: Variant = ml.get("structured_ground")
	if gs is CanvasItem:
		(gs as CanvasItem).visible = false   # the 128 px icon would sit under the probes
	await _run()
	print("MAP LIGHTS SHOT DONE: %d checks, %d FAIL" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _occluders() -> Array:
	var out: Array = []
	for s in ml.get_children():
		var occ := (s as Node).get_node_or_null("Occluder") as LightOccluder2D
		if occ != null:
			out.append(occ)
	return out


func _shot(tag: String) -> Image:
	for _i in 12:
		await RenderingServer.frame_post_draw
	var img := sv.get_texture().get_image()
	if _shot_dir != "":
		img.save_png("%s/map_lights_shot_%s.png" % [_shot_dir, tag])
	return img


func _v(img: Image, p: Vector2i) -> int:
	return int(round(img.get_pixelv(p).r * 255.0))


func _run() -> void:
	print("map_lights_shot: renderer %s" % RenderingServer.get_video_adapter_api_version())
	var occs := _occluders()
	if occs.size() != 3:
		_report("setup.three-occluders", false, "%d occluders" % occs.size())
		return
	var block: LightOccluder2D = occs[0]
	var wall: LightOccluder2D = occs[1]
	var disc: LightOccluder2D = occs[2]
	_report("cull.block-opened", block.occluder.cull_mode == OccluderPolygon2D.CULL_COUNTER_CLOCKWISE,
		"cull_mode %d" % block.occluder.cull_mode)
	_report("cull.disc-opened", disc.occluder.cull_mode == OccluderPolygon2D.CULL_CLOCKWISE,
		"cull_mode %d" % disc.occluder.cull_mode)
	_report("cull.other-wall-untouched", wall.occluder.cull_mode == OccluderPolygon2D.CULL_DISABLED,
		"cull_mode %d" % wall.occluder.cull_mode)
	var img := await _shot("lit")
	if img.get_size() != SIZE or _v(img, Vector2i(5, 590)) == 0:
		_report("setup.rendered", false, "size %s, corner %d (headless? run it windowed)"
			% [str(img.get_size()), _v(img, Vector2i(5, 590))])
		return
	_base = _v(img, Vector2i(5, 590))   # far from both lights
	_report("setup.unlit-ground", absi(_base - int(round(DARK * 255.0))) <= 3, "unlit %d" % _base)
	var probes := {"south": Vector2i(399, 360), "north": Vector2i(399, 240), "east": Vector2i(470, 300)}
	var got := ""
	var ok := true
	for k in probes:
		var v := _v(img, probes[k])
		got += " %s=%d" % [k, v]
		ok = ok and v >= _base + LIT_MIN
	_report("lit.block-light-escapes", ok, "unlit %d,%s" % [_base, got])
	var behind := _v(img, Vector2i(399, 430))
	_report("lit.other-walls-still-shadow", behind <= _base + DARK_MAX, "behind the south wall %d (unlit %d)" % [behind, _base])
	var dsouth := _v(img, Vector2i(700, 190))
	_report("lit.disc-light-escapes", dsouth >= _base + LIT_MIN, "70 px south of the drum %d (unlit %d)" % [dsouth, _base])
	# 4. the same block CULL_DISABLED: the light is trapped (the bug this guards)
	block.occluder.cull_mode = OccluderPolygon2D.CULL_DISABLED
	img = await _shot("trapped")
	var trapped := _v(img, probes["south"])
	_report("trapped.disabled-cull-traps-the-light", trapped <= _base + DARK_MAX and _v(img, Vector2i(399, 300)) >= _base + LIT_MIN,
		"south %d, inside %d (unlit %d)" % [trapped, _v(img, Vector2i(399, 300)), _base])
	block.occluder.cull_mode = MAP_LOADER._inside_open_cull(block.occluder.polygon)
	# 3. an outside light: the opened block shadows it as a closed one would
	var map_lights: Node2D = ml.get("map_lights")
	map_lights.visible = false
	var outside: PointLight2D = EquipmentEffects.make_light(0.84, {}, Color(1.0, 0.6, 0.25))
	outside.position = Vector2(399.5, 160)
	sv.add_child(outside)
	img = await _shot("outside")
	var o_near := _v(img, Vector2i(399, 240))
	var o_far := _v(img, Vector2i(399, 360))
	var o_in := _v(img, Vector2i(399, 300))
	_report("outside.block-still-shadows", o_near >= _base + LIT_MIN and o_far <= _base + DARK_MAX and o_in <= _base + DARK_MAX,
		"near side %d, far side %d, inside %d (unlit %d)" % [o_near, o_far, o_in, _base])
