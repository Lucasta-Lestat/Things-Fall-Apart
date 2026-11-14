# res://tests/canopy_layer_check.gd
# Headless checks for P3-B (TG roadmap Phase 3, exit criterion 2's visual
# half): crowns draw ABOVE characters, fade near the party and the cursor,
# are not squared off, and the sight cones stop lighting crowns the rules
# hide. All from data (no map art): tree rows exactly as a TG contract-3
# export writes them (canopy_cell / shade_cell, [atlas x, y, w, h, map x, y,
# w, h] px) over a synthetic atlas texture.
#   A. MapLoader._spawn_geo_structure: a row with canopy cells cuts nothing
#      from the structures overlay; its shade multiplies the ground under every
#      slice (z -4, lit by nothing) with the shade cell's 2x map rect; a crown
#      that hides goes to the CanopyLayer (the tree keeps an empty "Art" for
#      the hit flash), one that hides nothing (a snag) is the tree's own
#      premultiplied slice under characters; hedges, contract-2 rows and rows
#      whose map ships no atlas keep the overlay's r + 4 square, byte for byte.
#   B. CanopyLayer: absolute z between characters and the targeting UI, below
#      RoofLayer, roof-walkers and the unexplored fog; lit only by
#      CANOPY_LIGHT; draws the crowns that hide, drops one on crown_changed
#      (kill_crown, and a felled tree through Structure.take_damage); fades
#      round a party member under a crown's art and the cursor over one, and
#      not elsewhere; mirrors the tree's hit flash / damage tint.
#   C. The cone renderer's canopy child (CanopyLayer.fit_canopy_cone): off on
#      a map without a CanopyLayer; else the parent cone's texture, tint,
#      energy and shadows (mask | CANOPY_LIGHT), lighting CANOPY_LIGHT only,
#      at half its range from the ground (the near exemption when farther),
#      all of it under a crown, none a story up (roof, high deck), off with
#      its cone; real ProceduralCharacters through the same path.
# Run:  godot --headless --path . res://tests/canopy_layer_check.tscn
# Judge by the PASS/FAIL lines and "CANOPY LAYER DONE failures=0".
extends Node2D

const MAP_LOADER := preload("res://Structures/MapLoader.gd")
const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

# --- Game stub surface (MapLoader, ProceduralCharacter, CanopyLayer) ---
var characters_in_scene: Array = []
var items_in_scene: Array = []
var structures_in_scene: Array = []
var party_chars: Array = []
var selected_characters: Array = []
var stealth_mode: bool = false
var surface_manager = null
var fluid_manager: FluidManager = null
var fog_manager = null
var context_menu_open := false
var primary_selected = null
var current_map_id: String = "canopy_layer_check"
var current_map_data: Dictionary = {}
var unlocked_locks: Dictionary = {}
const MELEE_ELEV_TOLERANCE: float = 0.5

func can_hit_target(_a: Node2D, _t: Node2D) -> bool: return true
func register_hit(_a: Node2D, _t: Node2D) -> void: pass
func register_attack_start(_a: Node2D) -> void: pass
func register_attack_end(_a: Node2D) -> void: pass
func resolve_melee_swing(_a: Node2D, _hand: String) -> void: pass
func process_weapon_hit(_a, _t, _p, _w, _v) -> void: pass
func process_object_hit(_a, _t, _p, _w, _v) -> void: pass
func trigger_hearing_pulse(_source) -> void: pass
func is_seen_by_party(c) -> bool:
	return c in party_chars


## A viewer with just what the cone fit reads (GridManager.is_high_layer,
## canopy_crown, _canopy_near_px).
class Viewer extends Node2D:
	var on_roof := false
	var hag := 0.0
	var crown := -1
	func height_above_ground() -> float:
		return hag
	func canopy_crown() -> int:
		return crown
	func _canopy_near_px(_o) -> float:
		return 150.0


var failures := 0
var checks := 0
var _atlas: Texture2D = null
var _overlay: Texture2D = null


func _check(check_name: String, cond: bool, detail: Variant = "") -> void:
	checks += 1
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, str(detail)])


func _ready() -> void:
	get_tree().create_timer(300.0, true).timeout.connect(func():
		print("FAIL watchdog timeout (coroutine aborted?) failures=%d" % failures)
		get_tree().quit(99))
	fluid_manager = FluidManager.new()
	add_child(fluid_manager)
	GridManager.TILE_SIZE = 64
	GridManager.initialize(32 * 64, 32 * 64)
	var img := Image.create(512, 256, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.6, 0.2, 1.0))
	_atlas = ImageTexture.create_from_image(img)
	var oimg := Image.create(2048, 2048, false, Image.FORMAT_RGBA8)
	_overlay = ImageTexture.create_from_image(oimg)
	await get_tree().process_frame
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	ml._current_map_id = "canopy_layer_check"
	ml._canopy_tex = _atlas
	ml._canopy_crowns = []
	var spawned: Dictionary = _part_a(ml)
	GridManager.canopy.finish()
	ml._spawn_canopy_layer()
	await get_tree().process_frame
	await _part_b(ml, spawned)
	await _part_c(ml)
	await _part_c_real(ml)
	print("CANOPY LAYER DONE failures=%d checks=%d" % [failures, checks])
	get_tree().quit(1 if failures > 0 else 0)


func _row(pos: Vector2, r: float, stories: float, extra: Dictionary = {}) -> Dictionary:
	var row := {"kind": "tree", "pos": [pos.x, pos.y], "r": r, "id": "tree", "hp": 80, "stories": stories}
	row.merge(extra, true)
	return row


# The cells a TG export gives a tree: the crown 1.35 r round it, the shade
# the understory disk plus the shadow down-sun, at half resolution.
func _cells(pos: Vector2, r: float, ax: int, ay: int, sx: int, sy: int) -> Dictionary:
	var ch: int = ceili(r * 1.35 + 4.0)
	var sh: int = ceili(r * 1.9 + 4.0)
	var s_aw: int = sh   # map side 2 * sh, stored at half resolution
	return {"canopy_cell": [ax, ay, 2 * ch, 2 * ch, int(pos.x) - ch, int(pos.y) - ch, 2 * ch, 2 * ch],
		"shade_cell": [sx, sy, s_aw, s_aw, int(pos.x) - sh, int(pos.y) - sh, 2 * s_aw, 2 * s_aw]}


# ---------------------------------------------------------------------------
# A. MapLoader: what each row's slice is
# ---------------------------------------------------------------------------
func _part_a(ml: Node2D) -> Dictionary:
	var out := {}
	# 1. a crown that hides, with cells
	var p1 := Vector2(600, 600)
	var row1 := _row(p1, 60.0, 1.7, _cells(p1, 60.0, 2, 2, 200, 2))
	var t1: Structure = ml._spawn_geo_structure(row1, _overlay, 64)
	out["hide"] = t1
	_check("a.hide.spawned", t1 != null)
	var shade := t1.get_node_or_null("Shade") as Polygon2D
	_check("a.hide.shade-polygon", shade != null)
	if shade != null:
		var mm := shade.material as CanvasItemMaterial
		_check("a.hide.shade-mul", mm != null and mm.blend_mode == CanvasItemMaterial.BLEND_MODE_MUL)
		_check("a.hide.shade-unlit", shade.light_mask == 0, shade.light_mask)
		_check("a.hide.shade-under-slices", shade.z_as_relative and t1.z_index + shade.z_index == -4,
			"%d + %d" % [t1.z_index, shade.z_index])
		_check("a.hide.shade-texture", shade.texture == _atlas)
		var sc: Array = row1["shade_cell"]
		var want0 := Vector2(float(sc[4]), float(sc[5])) - t1.position
		var want2 := Vector2(float(sc[4] + sc[6]), float(sc[5] + sc[7])) - t1.position
		_check("a.hide.shade-map-rect", shade.polygon.size() == 4 and shade.polygon[0].is_equal_approx(want0)
			and shade.polygon[2].is_equal_approx(want2), str(shade.polygon))
		_check("a.hide.shade-atlas-rect", shade.uv.size() == 4 and shade.uv[0].is_equal_approx(Vector2(sc[0], sc[1]))
			and shade.uv[2].is_equal_approx(Vector2(sc[0] + sc[2], sc[1] + sc[3])), str(shade.uv))
		# half-resolution shade: the map rect is twice the atlas rect
		_check("a.hide.shade-2x", is_equal_approx((shade.polygon[2] - shade.polygon[0]).x, 2.0 * (shade.uv[2] - shade.uv[0]).x))
	var art1 := t1.get_node_or_null("Art")
	_check("a.hide.art-is-empty-proxy", art1 != null and not (art1 is Polygon2D) and art1 is Node2D,
		art1.get_class() if art1 != null else "none")
	_check("a.hide.visual-is-proxy", t1._visual() == art1)
	_check("a.hide.registered", GridManager.canopy.crown_of(t1) >= 0)
	_check("a.hide.queued-for-layer", ml._canopy_crowns.size() == 1, ml._canopy_crowns.size())
	# the trunk collider and the occluder are the contract-2 ones
	var cs: CollisionShape2D = t1.get_node("CollisionShape2D")
	_check("a.hide.trunk-collider", is_equal_approx((cs.shape as CircleShape2D).radius, 27.0))
	_check("a.hide.occluder", t1.get_node_or_null("Occluder") != null)
	# 2. a second crown that hides, overlapping the first (a grove)
	var p2 := Vector2(700, 640)
	var t2: Structure = ml._spawn_geo_structure(_row(p2, 50.0, 1.7, _cells(p2, 50.0, 2, 180, 330, 2)), _overlay, 64)
	out["hide2"] = t2
	_check("a.grove.queued", ml._canopy_crowns.size() == 2)
	# 3. a dead snag (stories 0.72: hides nothing): its crown is its own slice, under characters
	var p3 := Vector2(1200, 600)
	var row3 := _row(p3, 40.0, 0.72, _cells(p3, 40.0, 120, 180, 420, 120))
	var t3: Structure = ml._spawn_geo_structure(row3, _overlay, 64)
	out["snag"] = t3
	var art3 := t3.get_node_or_null("Art") as Polygon2D
	_check("a.snag.art-polygon", art3 != null)
	if art3 != null:
		var pm := art3.material as CanvasItemMaterial
		_check("a.snag.premult", pm != null and pm.blend_mode == CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA)
		_check("a.snag.lit-like-slices", art3.light_mask == 1, art3.light_mask)
		_check("a.snag.under-characters", t3.z_index + art3.z_index == -3)
		_check("a.snag.atlas-texture", art3.texture == _atlas)
		var cc: Array = row3["canopy_cell"]
		_check("a.snag.not-squared-r+4", (art3.polygon[2] - art3.polygon[0]).x > 2.0 * (40.0 + 4.0),
			"crown cell %.0f px wide" % (art3.polygon[2] - art3.polygon[0]).x)
		_check("a.snag.uv-atlas", art3.uv[0].is_equal_approx(Vector2(cc[0], cc[1])))
	_check("a.snag.shade", t3.get_node_or_null("Shade") is Polygon2D)
	_check("a.snag.not-registered", GridManager.canopy.crown_of(t3) < 0)
	_check("a.snag.not-queued", ml._canopy_crowns.size() == 2)
	# 4. a hedge (no cells: a TG hedge stays in the overlay)
	var hedge := {"kind": "tree", "pos": [300, 1200], "r": 18.0, "id": "hedge", "hp": 30, "stories": 0.5, "occlude_h": 0.45}
	var t4: Structure = ml._spawn_geo_structure(hedge, _overlay, 64)
	_check_square(t4, 18.0, "a.hedge")
	_check("a.hedge.no-shade", t4.get_node_or_null("Shade") == null)
	# 5. a contract-2 tree (no cells): the overlay square, still a crown that hides
	var t5: Structure = ml._spawn_geo_structure(_row(Vector2(1500, 1300), 56.0, 1.7), _overlay, 64)
	_check_square(t5, 56.0, "a.c2-tree")
	_check("a.c2-tree.registered", GridManager.canopy.crown_of(t5) >= 0)
	_check("a.c2-tree.not-queued", ml._canopy_crowns.size() == 2)
	out["c2"] = t5
	# 6. cells but the map ships no atlas: the overlay square (nothing to draw otherwise)
	ml._canopy_tex = null
	var p6 := Vector2(1700, 300)
	var t6: Structure = ml._spawn_geo_structure(_row(p6, 44.0, 1.7, _cells(p6, 44.0, 2, 2, 2, 2)), _overlay, 64)
	_check_square(t6, 44.0, "a.no-atlas")
	_check("a.no-atlas.not-queued", ml._canopy_crowns.size() == 2)
	ml._canopy_tex = _atlas
	return out


func _check_square(t: Structure, r: float, nm: String) -> void:
	var art := t.get_node_or_null("Art") as Polygon2D
	_check(nm + ".overlay-slice", art != null and art.texture == _overlay)
	if art == null:
		return
	var rr := r + 4.0
	var want := PackedVector2Array([Vector2(-rr, -rr), Vector2(rr, -rr), Vector2(rr, rr), Vector2(-rr, rr)])
	var same := art.polygon.size() == 4
	for i in mini(4, art.polygon.size()):
		same = same and art.polygon[i].is_equal_approx(want[i]) and art.uv[i].is_equal_approx(want[i] + t.position)
	_check(nm + ".r+4-square", same, str(art.polygon))


# ---------------------------------------------------------------------------
# B. CanopyLayer
# ---------------------------------------------------------------------------
func _part_b(ml: Node2D, spawned: Dictionary) -> void:
	var layer: CanopyLayer = ml.canopy_layer
	_check("b.layer-built", layer != null and is_instance_valid(layer))
	if layer == null:
		return
	_check("b.z-absolute", not layer.z_as_relative and layer.z_index == CanopyLayer.CANOPY_Z)
	_check("b.z-above-characters", CanopyLayer.CANOPY_Z > 5 and CanopyLayer.CANOPY_Z > 1)
	_check("b.z-below-targeting-ui", CanopyLayer.CANOPY_Z < 49)
	_check("b.z-below-roofs", CanopyLayer.CANOPY_Z < RoofLayer.ROOF_Z)
	_check("b.z-below-roof-walkers", CanopyLayer.CANOPY_Z < ProceduralCharacter.ROOF_WALKER_Z)
	_check("b.z-below-fog", CanopyLayer.CANOPY_Z < UnexploredFogLayer.FOG_Z)
	_check("b.lit-by-canopy-cones-only", layer.light_mask == CollisionLayers.CANOPY_LIGHT)
	_check("b.canopy-bit-unused-by-lights", (CollisionLayers.CANOPY_LIGHT & (1 | CollisionLayers.ELEVATED_SURFACE_LIGHT)) == 0)
	var sm := layer.material as ShaderMaterial
	_check("b.fade-shader", sm != null and sm.shader != null)
	var i1: int = GridManager.canopy.crown_of(spawned["hide"])
	var i2: int = GridManager.canopy.crown_of(spawned["hide2"])
	var drawn: Array = layer.drawn_crowns()
	_check("b.draws-the-hiding-crowns", drawn.size() == 2 and i1 in drawn and i2 in drawn, str(drawn))
	_check("b.c2-crown-not-drawn", not (GridManager.canopy.crown_of(spawned["c2"]) in drawn))
	# fade: nobody under a crown, cursor off every crown
	layer.cursor_override = Vector2(100, 100)
	party_chars = []
	await get_tree().process_frame
	_check("b.fade.none", layer.fade_points().size() == 0, layer.fade_points())
	# a party member under the first crown's art (inside 1.35 r, outside the disc r)
	var pm := Node2D.new()
	add_child(pm)
	pm.global_position = Vector2(600 + 75, 600)
	party_chars = [pm]
	await get_tree().process_frame
	var fp: PackedVector4Array = layer.fade_points()
	_check("b.fade.party-under-art", fp.size() == 1 and Vector2(fp[0].x, fp[0].y).is_equal_approx(pm.global_position), fp)
	# an NPC under it fades nothing (only the party)
	party_chars = []
	var npc := Node2D.new()
	add_child(npc)
	npc.global_position = Vector2(600, 600)
	await get_tree().process_frame
	_check("b.fade.not-for-npcs", layer.fade_points().size() == 0)
	# a party member in the open: no fade
	pm.global_position = Vector2(1000, 1000)
	party_chars = [pm]
	await get_tree().process_frame
	_check("b.fade.party-in-open", layer.fade_points().size() == 0)
	# the cursor over a crown
	layer.cursor_override = Vector2(700, 640)
	await get_tree().process_frame
	fp = layer.fade_points()
	_check("b.fade.cursor", fp.size() == 1 and is_equal_approx(fp[0].z, CanopyLayer.CURSOR_FADE.x), fp)
	_check("b.fade.uniform", int(sm.get_shader_parameter("fade_count")) == 1)
	layer.cursor_override = Vector2(100, 100)
	# the hit flash / damage tint of the tree, onto its crown
	var art := (spawned["hide"] as Structure).get_node("Art") as CanvasItem
	art.modulate = Color(1, 0, 0)
	await get_tree().process_frame
	_check("b.mirror.flash", layer.crown_color(i1).is_equal_approx(Color(1, 0, 0)), layer.crown_color(i1))
	art.modulate = Color.WHITE
	(spawned["hide"] as Structure).current_health = 10
	(spawned["hide"] as Structure)._refresh_tint()
	await get_tree().process_frame
	_check("b.mirror.damage-tint", layer.crown_color(i1).r < 0.99, layer.crown_color(i1))
	# a crown the record kills goes at once
	GridManager.canopy.kill_crown(i2)
	_check("b.drop.kill_crown", not (i2 in layer.drawn_crowns()), layer.drawn_crowns())
	# a felled tree: its Structure dies, its crown and its shade go
	var tree: Structure = spawned["hide"]
	var shade := tree.get_node("Shade")
	tree.take_damage({"slashing": 100000})
	_check("b.drop.felled", layer.drawn_crowns().is_empty(), layer.drawn_crowns())
	await get_tree().process_frame
	_check("b.drop.shade-freed", not is_instance_valid(shade))
	_check("b.drop.no-fade-over-dead-crowns", not layer.under_art(Vector2(600, 600), 0.0))
	pm.queue_free()
	npc.queue_free()
	party_chars = []


# ---------------------------------------------------------------------------
# C. the cone renderer's canopy child
# ---------------------------------------------------------------------------
func _cone(range_px: float) -> PointLight2D:
	var light := PointLight2D.new()
	light.texture = Globals.get_sight_cone_texture(120.0)
	light.texture_scale = range_px / (light.texture.get_width() * 0.5)
	light.energy = 0.5
	light.color = Color(1.0, 0.3, 0.2)
	light.shadow_enabled = true
	light.shadow_item_cull_mask = CollisionLayers.SIGHT_MASK_GROUND
	light.range_item_cull_mask = 1
	return light


func _part_c(_ml: Node2D) -> void:
	var v := Viewer.new()
	add_child(v)
	v.global_position = Vector2(1000, 1000)
	var light := _cone(800.0)
	v.add_child(light)
	# a map without a CanopyLayer: no child
	_check("c.off.none", CanopyLayer.fit_canopy_cone(light, v, false) == null)
	var cc: PointLight2D = CanopyLayer.fit_canopy_cone(light, v, true)
	_check("c.child", cc != null and cc.get_parent() == light and cc.name == CanopyLayer.CANOPY_CONE_NAME)
	if cc == null:
		return
	_check("c.same-texture", cc.texture == light.texture)
	_check("c.same-tint-energy", cc.color == light.color and is_equal_approx(cc.energy, light.energy))
	_check("c.lights-canopy-only", cc.range_item_cull_mask == CollisionLayers.CANOPY_LIGHT)
	_check("c.shadows", cc.shadow_enabled and cc.shadow_item_cull_mask == (CollisionLayers.SIGHT_MASK_GROUND | CollisionLayers.CANOPY_LIGHT),
		cc.shadow_item_cull_mask)
	_check("c.ground.half-range", cc.enabled and is_equal_approx(cc.texture_scale, light.texture_scale * 0.5),
		"%f vs %f" % [cc.texture_scale, light.texture_scale])
	_check("c.inherits-rotation", is_zero_approx(cc.rotation) and cc.position == Vector2.ZERO)
	# a short-sighted viewer: the near exemption's reach wins
	light.texture_scale = 200.0 / (light.texture.get_width() * 0.5)
	CanopyLayer.fit_canopy_cone(light, v, true)
	_check("c.ground.near-wins", is_equal_approx(cc.texture_scale, light.texture_scale * 150.0 / 200.0), cc.texture_scale)
	light.texture_scale = 800.0 / (light.texture.get_width() * 0.5)
	# under a crown: its whole range
	v.crown = 3
	CanopyLayer.fit_canopy_cone(light, v, true)
	_check("c.under-crown.full-range", cc.enabled and is_equal_approx(cc.texture_scale, light.texture_scale))
	v.crown = -1
	# a story up: nothing
	v.hag = 1.2
	CanopyLayer.fit_canopy_cone(light, v, true)
	_check("c.high-deck.off", not cc.enabled)
	v.hag = 0.0
	v.on_roof = true
	CanopyLayer.fit_canopy_cone(light, v, true)
	_check("c.roof.off", not cc.enabled)
	v.on_roof = false
	# a deck under a story: a ground viewer
	v.hag = 0.7
	CanopyLayer.fit_canopy_cone(light, v, true)
	_check("c.low-deck.half", cc.enabled and is_equal_approx(cc.texture_scale, light.texture_scale * 0.5))
	v.hag = 0.0
	# the cone off (Blinded, dead): its child too
	light.enabled = false
	CanopyLayer.fit_canopy_cone(light, v, true)
	_check("c.cone-off", not cc.enabled)
	light.enabled = true
	# the cone retiers (a band mask): the child follows
	light.shadow_item_cull_mask = CollisionLayers.SIGHT_MASK_GROUND | (1 << 5)
	light.color = Color(0.55, 0.62, 0.72)
	light.energy = 0.08
	CanopyLayer.fit_canopy_cone(light, v, true)
	_check("c.follows-retier", cc.shadow_item_cull_mask == (CollisionLayers.SIGHT_MASK_GROUND | (1 << 5) | CollisionLayers.CANOPY_LIGHT))
	_check("c.follows-tint", cc.color == light.color and is_equal_approx(cc.energy, 0.08))
	# the map loses its CanopyLayer: the child switches off
	CanopyLayer.fit_canopy_cone(light, v, false)
	_check("c.off-again", not cc.enabled)
	v.queue_free()


# Real characters: the methods the fit reads exist and agree with the rules.
func _part_c_real(_ml: Node2D) -> void:
	var c: ProceduralCharacter = PC_SCENE.instantiate()
	c.AI_enabled = false
	add_child(c)
	TopDownCharacterDatabase.build_character(c, "default_human")
	c.game = self
	c.faction_id = "player"
	c.global_position = Vector2(1000, 1500)
	c._refresh_elevation()
	characters_in_scene.append(c)
	var light := _cone(c.get_sight_range_px())
	c.add_child(light)
	var cc: PointLight2D = CanopyLayer.fit_canopy_cone(light, c, true)
	var near: float = c._canopy_near_px(c)
	var want: float = maxf(ProceduralCharacter.CANOPY_VISIBILITY, near / c.get_sight_range_px())
	_check("c.real.ground", cc != null and cc.enabled and is_equal_approx(cc.texture_scale, light.texture_scale * want),
		"%s %f want x%f" % [str(cc != null and cc.enabled), cc.texture_scale if cc else -1.0, want])
	# a fresh crown over them through the record (they stand under its leaves, off its trunk)
	var ci: int = GridManager.canopy.add_crown(Vector2(1040, 1500), 60.0, 27.0, 0.0, 1.0, 1.7, null)
	GridManager.canopy.finish()
	_check("c.real.under-crown-is-read", c.canopy_crown() == ci, c.canopy_crown())
	CanopyLayer.fit_canopy_cone(light, c, true)
	_check("c.real.under-crown.full", cc.enabled and is_equal_approx(cc.texture_scale, light.texture_scale))
	GridManager.canopy.kill_crown(ci)
	c.on_roof = true
	CanopyLayer.fit_canopy_cone(light, c, true)
	_check("c.real.roof.off", not cc.enabled)
	c.on_roof = false
	c.queue_free()
	await get_tree().process_frame
