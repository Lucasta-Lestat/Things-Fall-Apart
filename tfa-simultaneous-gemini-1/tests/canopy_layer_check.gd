# res://tests/canopy_layer_check.gd
# Headless checks for P3-B (TG roadmap Phase 3, exit criterion 2's visual
# half): crowns draw ABOVE characters, fade near the party and the cursor and
# over what must stay readable, are not squared off, and the sight cones stop
# lighting what the crown rules hide. All from data (no map art): tree rows
# exactly as a TG contract-3 export writes them (canopy_cell / shade_cell,
# [atlas x, y, w, h, map x, y, w, h] px) over a synthetic atlas texture.
#   A. MapLoader._spawn_geo_structure: a row with canopy cells cuts nothing
#      from the structures overlay; its shade multiplies the ground under every
#      slice (z -4, UNSHADED so the world CanvasModulate cannot darken its white
#      into a square) with the shade cell's 2x map rect; a crown that hides
#      goes to the CanopyLayer (the tree keeps an empty "Art" for the hit
#      flash), one that hides nothing (a snag) is the tree's own premultiplied
#      slice under characters; hedges, contract-2 rows and rows whose map ships
#      no atlas keep the overlay's r + 4 square, byte for byte.
#   B. CanopyLayer: absolute z between characters and the targeting UI, below
#      RoofLayer, roof-walkers and the unexplored fog; lit only by
#      CANOPY_LIGHT | LAMP_LIGHT; draws the crowns that hide, each with its
#      rule disc of ground (r minus the trunk, the ground's texture and
#      material, lit like the crowns); fades round a party member under a
#      crown's art (or its body's edge: BODY_PAD) with the party rings, the
#      cursor over one with the cursor rings, and over the REVEAL_GROUP's
#      shapes near a crown and in view (a stub; a real AimLine with its
#      landing reticle; a real PathDrawer's route, dash leash and AoE end, a
#      node left on a plan with no route, a facing arrow being drawn; a
#      real CellFireFX driven through setup() by a stub sim, whose cluster
#      light lights the crowns), a straight polyline as one capsule; the
#      view is the viewport's (its canvas transform), a shape whose feather
#      reaches into it from just outside kept; the shader's arrays and loop
#      hold exactly MAX_FADES shapes; the ordinary lights
#      (make_light, glow marks, VFXEffectNode, lightning) light the crowns;
#      mirrors the tree's hit flash / damage tint; drops a crown and its disc
#      on crown_changed (kill_crown, and a felled tree through
#      Structure.take_damage).
#   C. The cone renderer's canopy child (CanopyLayer.fit_canopy_cone): off on
#      a map without a CanopyLayer and with no crown in its reach; else the
#      parent cone's texture, tint, energy and shadows (mask | CANOPY_LIGHT),
#      lighting CANOPY_LIGHT only, at half its range from the ground (the near
#      exemption when farther), all of it under a crown, none a story up
#      (roof, high deck), off with its cone or while the cone is hidden; real
#      ProceduralCharacters through the same path. A real character under a
#      crown trades light mask 1 for SHADED_MASK on its body (the full cones
#      stop lighting it; its top_level route layer and aim line keep mask 1),
#      gear put on while it stays hidden is shaded at the next re-walk
#      (REGATE_SECONDS), and it has mask 1 back out from under it, when
#      revealed and when the layer goes; its queued reticle is a REVEAL disc.
#   D. The real loader: MapLoader.generate_structured_map on a contract-3 map
#      dict builds the CanopyLayer (and its discs from the ground sprite),
#      drops the atlas reference after, and a contract-2 one builds none.
#      Game.shade_selection_ring: a hidden party member's selection ring
#      (Game's own node) wears SHADED_MASK like its body; mask 1 in the
#      open, out from under the crown, and on a map without a CanopyLayer.
#   E. Game._update_sight_cones (Game.gd, instanced bare): fits the canopy
#      child on a map with a CanopyLayer, switches it off on one without;
#      Game.weapon_shot_z: CanopyLayer.SHOT_Z there, 3 here.
#   F. A missing atlas push_errors: images.canopy naming no file, and tree
#      rows with canopy cells but no images.canopy at all.
#   G. The fade budget (a 12-crown grove): three planned routes through four
#      crowns each, with dash leashes, keep every crown crossing faded, in
#      few capsules; with the budget overrun the primary selection's route
#      (then the rest of the selection's, then a party member's before an
#      NPC's) is served first; reveal_runs (a straight line one run, its last
#      point kept, every kept point within REVEAL_TOL of its run's axis on
#      part G's routes, an arc, a hairpin and random hand-drawn weaves), its
#      runs reused by polyline content (an edit PathDrawer's smooth key would
#      miss is seen; only this frame's polylines held); the coarse grid
#      answers any_crown_within and long near_art queries as a scan of every
#      crown would.
# Run:  godot --headless --path . res://tests/canopy_layer_check.tscn
# Judge by the PASS/FAIL lines and "CANOPY LAYER DONE failures=0".
extends Node2D

const MAP_LOADER := preload("res://Structures/MapLoader.gd")
const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const GAME_SCRIPT := "res://Game.gd"
const EQUIPMENT_EFFECTS := preload("res://Items/equipment_effects.gd")
# Two small project textures for the real loader's map dict.
const GROUND_RES := "res://UI/UI Icons/warp_arrow.png"
const ATLAS_RES := "res://UI/UI Icons/Dash.png"

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


## A REVEAL_GROUP member handing over fixed shapes.
class RevealStub extends Node:
	var shapes: Array = []
	func _enter_tree() -> void:
		add_to_group(CanopyLayer.REVEAL_GROUP)
	func canopy_reveal(out: Array) -> void:
		out.append_array(shapes)


## What CellFireFX reads of a CellFire.
class FireSimStub extends Node:
	var burning: Dictionary = {}
	var burn_rev: int = 0
	var sim_time: float = 0.0


## Collects push_error text (Godot's Logger).
class ErrLog extends Logger:
	var msgs: PackedStringArray = PackedStringArray()
	var mu := Mutex.new()
	func _log_error(_function: String, _file: String, _line: int, code: String, rationale: String,
			_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		mu.lock()
		msgs.append(code + " " + rationale)
		mu.unlock()
	func has(sub: String) -> bool:
		mu.lock()
		var found := false
		for m in msgs:
			if sub in m:
				found = true
		mu.unlock()
		return found


var failures := 0
var checks := 0
var _atlas: Texture2D = null
var _overlay: Texture2D = null
var _ground_tex: Texture2D = null


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
	var gimg := Image.create(2048, 2048, false, Image.FORMAT_RGBA8)
	gimg.fill(Color(0.4, 0.5, 0.3, 1.0))
	_ground_tex = ImageTexture.create_from_image(gimg)
	await get_tree().process_frame
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	ml._current_map_id = "canopy_layer_check"
	ml._canopy_tex = _atlas
	ml._canopy_crowns = []
	var spawned: Dictionary = _part_a(ml)
	GridManager.canopy.finish()
	var gs := Sprite2D.new()
	gs.texture = _ground_tex
	gs.centered = false
	gs.z_index = -6
	# a contract-3 ground: MapLoader samples it through its mipmaps (P3-C)
	gs.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	ml.add_child(gs)
	ml.structured_ground = gs
	ml._spawn_canopy_layer()
	_check("a.atlas-not-held-after-load", ml._canopy_tex == null)
	await get_tree().process_frame
	await _part_b(ml, spawned)
	await _part_c(ml)
	await _part_c_real(ml, spawned)
	await _part_b_drop(ml, spawned)
	await _part_g()
	ml.queue_free()
	await get_tree().process_frame
	await _part_d()
	await _part_f()
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


# The body's own canvas items (CanopyLayer._gate's walk): [mask 1 count,
# SHADED_MASK count].
func _body_masks(c: Node) -> Vector2i:
	var out := Vector2i.ZERO
	var stack: Array = [c]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Light2D:
			continue
		if n != c and n is CanvasItem and (n as CanvasItem).top_level:
			continue
		if n is CanvasItem:
			if (n as CanvasItem).light_mask == 1:
				out.x += 1
			elif (n as CanvasItem).light_mask == CanopyLayer.SHADED_MASK:
				out.y += 1
		for ch in n.get_children():
			stack.append(ch)
	return out


func _shapes_of(layer: CanopyLayer, kind: int) -> Array:
	var out: Array = []
	for s in layer.fade_shapes():
		if int(s["kind"]) == kind:
			out.append(s)
	return out


# A disc shape at p with inner radius `inner` among `shapes`.
func _has_disc(shapes: Array, p: Vector2, inner: float) -> bool:
	for s in shapes:
		if (s["a"] as Vector2).is_equal_approx(p) and (s["b"] as Vector2).is_equal_approx(p) \
				and is_equal_approx(float(s["inner"]), inner):
			return true
	return false


# A capsule a..b (either way round) with inner radius `inner` among `shapes`.
func _has_capsule(shapes: Array, a: Vector2, b: Vector2, inner: float) -> bool:
	for s in shapes:
		var sa: Vector2 = s["a"]
		var sb: Vector2 = s["b"]
		if ((sa.is_equal_approx(a) and sb.is_equal_approx(b)) or (sa.is_equal_approx(b) and sb.is_equal_approx(a))) \
				and is_equal_approx(float(s["inner"]), inner):
			return true
	return false


# The points of `route` within a live crown's art reach that no REVEAL shape
# fades fully (within its inner radius).
func _uncovered(layer: CanopyLayer, route: PackedVector2Array) -> Array:
	var shapes: Array = _shapes_of(layer, CanopyLayer.Fade.REVEAL)
	var out: Array = []
	for p in route:
		if not layer.under_art(p, 0.0):
			continue
		var ok := false
		for s in shapes:
			var q: Vector2 = Geometry2D.get_closest_point_to_segment(p, s["a"], s["b"])
			if q.distance_to(p) <= float(s["inner"]) + 0.01:
				ok = true
				break
		if not ok:
			out.append(p)
	return out


# The farthest any kept point (CanopyLayer.reveal_kept) of `pts` lies from
# its run's axis (CanopyLayer.reveal_runs); -1 when the runs are not the kept
# points' own, in order, first and last included.
func _runs_worst(pts: PackedVector2Array) -> float:
	var kept := CanopyLayer.reveal_kept(pts)
	var runs := CanopyLayer.reveal_runs(pts)
	if kept.is_empty() or runs.is_empty() or runs[0] != kept[0] or runs[runs.size() - 1] != kept[kept.size() - 1]:
		return -1.0
	var j := 0
	var worst := 0.0
	for r in range(1, runs.size()):
		var k := j + 1
		while k < kept.size() and kept[k] != runs[r]:
			var q: Vector2 = Geometry2D.get_closest_point_to_segment(kept[k], runs[r - 1], runs[r])
			worst = maxf(worst, q.distance_to(kept[k]))
			k += 1
		if k >= kept.size():
			return -1.0
		j = k
	return worst


# A hand-drawn route as PathDrawer hands it over: mouse samples along a
# wobbly line, waypoints TacticalPath.MIN_WAYPOINT_DISTANCE apart, Chaikin x2.
func _weave_route(rng: RandomNumberGenerator) -> PackedVector2Array:
	var amp: float = rng.randf_range(0.0, 70.0)
	var lam: float = rng.randf_range(150.0, 600.0)
	var ph: float = rng.randf() * TAU
	var length: float = rng.randf_range(300.0, 2500.0)
	var turn: float = rng.randf() * TAU
	var raw := PackedVector2Array()
	var x := 0.0
	while x <= length:
		var p := Vector2(1000, 1000) + Vector2(x, amp * sin(TAU * x / lam + ph) + rng.randf_range(-3.0, 3.0)).rotated(turn)
		if raw.is_empty() or p.distance_to(raw[raw.size() - 1]) >= TacticalPath.MIN_WAYPOINT_DISTANCE:
			raw.append(p)
		x += 3.0
	return PathDrawer._chaikin(raw, PathDrawer.SMOOTH_ITERATIONS)


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
		# lit, the world CanvasModulate (game.tscn 0.716) multiplies the MUL quad
		# first: every white "no shade" texel darkens the ground into a square
		_check("a.hide.shade-unshaded", mm != null and mm.light_mode == CanvasItemMaterial.LIGHT_MODE_UNSHADED,
			mm.light_mode if mm != null else -1)
		_check("a.hide.shade-no-light-mask", shade.light_mask == 0, shade.light_mask)
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
	# headless, the window (the view the fade serves) is 64 px: serve the map
	layer.view_override = Rect2(0, 0, 2048, 2048)
	_check("b.z-absolute", not layer.z_as_relative and layer.z_index == CanopyLayer.CANOPY_Z)
	_check("b.z-above-characters", CanopyLayer.CANOPY_Z > 5 and CanopyLayer.CANOPY_Z > 1)
	_check("b.z-below-targeting-ui", CanopyLayer.CANOPY_Z < 49)
	_check("b.z-below-roofs", CanopyLayer.CANOPY_Z < RoofLayer.ROOF_Z)
	_check("b.z-below-roof-walkers", CanopyLayer.CANOPY_Z < ProceduralCharacter.ROOF_WALKER_Z)
	_check("b.z-below-fog", CanopyLayer.CANOPY_Z < UnexploredFogLayer.FOG_Z)
	_check("b.lit-by-canopy-cones-and-lamps", layer.light_mask == (CollisionLayers.CANOPY_LIGHT | CollisionLayers.LAMP_LIGHT),
		layer.light_mask)
	_check("b.not-lit-by-full-cones", (layer.light_mask & 1) == 0)
	_check("b.canopy-bits-unused-by-cones", (CollisionLayers.CANOPY_LIGHT & (1 | CollisionLayers.ELEVATED_SURFACE_LIGHT)) == 0
		and (CollisionLayers.LAMP_LIGHT & (1 | CollisionLayers.ELEVATED_SURFACE_LIGHT)) == 0)
	var lamp: PointLight2D = EQUIPMENT_EFFECTS.make_light(0.5, {})
	_check("b.lamps-light-the-crowns", (lamp.range_item_cull_mask & CollisionLayers.LAMP_LIGHT) != 0
		and (lamp.range_item_cull_mask & 1) != 0, lamp.range_item_cull_mask)
	lamp.free()
	# the other ordinary lights: glow marks, VFXEffectNode, lightning
	var gmk: Node2D = load("res://vfx/glow_mark.gd").new()
	add_child(gmk)
	var glow_l: PointLight2D = null
	for ch in gmk.get_children():
		if ch is PointLight2D:
			glow_l = ch
	_check("b.lamps.glow-mark", glow_l != null and glow_l.range_item_cull_mask == CollisionLayers.LAMP_RANGE_MASK,
		glow_l.range_item_cull_mask if glow_l != null else -1)
	gmk.queue_free()
	var vn: Node2D = load("res://VFXEffectNode.gd").new()
	add_child(vn)
	vn.call("add_light", Color.WHITE, 1.0, 100.0, null)
	var vl: PointLight2D = vn.get("light")
	_check("b.lamps.vfx-node", vl != null and vl.range_item_cull_mask == CollisionLayers.LAMP_RANGE_MASK,
		vl.range_item_cull_mask if vl != null else -1)
	vn.queue_free()
	var lt := LightningVFX.new()
	lt.end_position = Vector2(100, 0)
	add_child(lt)
	_check("b.lamps.lightning", lt.point_light != null and lt.impact_light != null
		and lt.point_light.range_item_cull_mask == CollisionLayers.LAMP_RANGE_MASK
		and lt.impact_light.range_item_cull_mask == CollisionLayers.LAMP_RANGE_MASK)
	lt.queue_free()
	var sm := layer.material as ShaderMaterial
	_check("b.fade-shader", sm != null and sm.shader != null)
	# its arrays and its loop hold exactly MAX_FADES shapes (headless nothing
	# renders, so a shape past the shader's size would go unfaded unseen)
	var code: String = (sm.shader as Shader).code if sm != null and sm.shader != null else ""
	var sizes: Array = []
	for m in RegEx.create_from_string("fade_(?:seg|rad)\\s*\\[\\s*(\\d+)\\s*\\]").search_all(code):
		sizes.append(int((m as RegExMatch).get_string(1)))
	var loop_m := RegEx.create_from_string("for\\s*\\(\\s*int\\s+i\\s*=\\s*0\\s*;\\s*i\\s*<\\s*(\\d+)").search(code)
	var loop_n: int = int(loop_m.get_string(1)) if loop_m != null else -1
	_check("b.fade-shader.holds-max-fades", sizes.size() == 2 and sizes.count(CanopyLayer.MAX_FADES) == 2
		and loop_n == CanopyLayer.MAX_FADES, "arrays %s, loop %d, MAX_FADES %d" % [str(sizes), loop_n, CanopyLayer.MAX_FADES])
	var i1: int = GridManager.canopy.crown_of(spawned["hide"])
	var i2: int = GridManager.canopy.crown_of(spawned["hide2"])
	var drawn: Array = layer.drawn_crowns()
	_check("b.draws-the-hiding-crowns", drawn.size() == 2 and i1 in drawn and i2 in drawn, str(drawn))
	_check("b.c2-crown-not-drawn", not (GridManager.canopy.crown_of(spawned["c2"]) in drawn))
	# the rule disc: the ground (its texture and material) over r minus the trunk, lit like the crowns
	var d1 := layer.rule_disc(i1)
	_check("b.disc.built", d1 != null and layer.rule_disc(i2) != null)
	if d1 != null:
		_check("b.disc.ground-texture", d1.texture == _ground_tex)
		_check("b.disc.ground-filter", d1.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS,
			"%d (the ground samples its mipmaps)" % d1.texture_filter)
		_check("b.disc.uv-is-map-px", d1.uv == d1.polygon)
		_check("b.disc.z-ground", not d1.z_as_relative and d1.z_index == -6)
		_check("b.disc.lit-like-crowns", d1.light_mask == CanopyLayer.SHADED_MASK, d1.light_mask)
		var c1: Dictionary = GridManager.canopy.crown(i1)
		var outer: float = (d1.polygon[0] - (c1["pos"] as Vector2)).length()
		var inner: float = (d1.polygon[CanopyLayer.DISC_SEGMENTS] - (c1["pos"] as Vector2)).length()
		_check("b.disc.rule-radii", is_equal_approx(outer, float(c1["r"])) and is_equal_approx(inner, float(c1["trunk_r"])),
			"%.2f / %.2f vs r %.2f trunk %.2f" % [outer, inner, float(c1["r"]), float(c1["trunk_r"])])
		var gm := ShaderMaterial.new()
		ml.structured_ground.material = gm
		await get_tree().process_frame
		_check("b.disc.follows-ground-material", d1.material == gm)
		ml.structured_ground.material = null
		await get_tree().process_frame
	# fade: nobody under a crown, cursor off every crown
	layer.cursor_override = Vector2(100, 100)
	party_chars = []
	await get_tree().process_frame
	_check("b.fade.none", layer.fade_shapes().size() == 0, layer.fade_shapes())
	# a party member under the first crown's art (inside 1.35 r, outside the disc r)
	var pm := Node2D.new()
	add_child(pm)
	pm.global_position = Vector2(600 + 75, 600)
	party_chars = [pm]
	await get_tree().process_frame
	var fp: Array = _shapes_of(layer, CanopyLayer.Fade.PARTY)
	_check("b.fade.party-under-art", fp.size() == 1 and (fp[0]["a"] as Vector2).is_equal_approx(pm.global_position), fp)
	_check("b.fade.party-rings", fp.size() == 1 and is_equal_approx(float(fp[0]["inner"]), CanopyLayer.PARTY_FADE.x)
		and is_equal_approx(float(fp[0]["outer"]), CanopyLayer.PARTY_FADE.y), fp)
	_check("b.fade.uniform", int(sm.get_shader_parameter("fade_count")) == layer.fade_shapes().size())
	# the body's edge: past the art's reach by less than BODY_PAD fades, more does not
	var reach1: float = 60.0 * CanopyLayer.ART_REACH
	pm.global_position = Vector2(600 - reach1 - CanopyLayer.BODY_PAD * 0.5, 600)
	await get_tree().process_frame
	_check("b.fade.body-edge-under-art", _shapes_of(layer, CanopyLayer.Fade.PARTY).size() == 1)
	pm.global_position = Vector2(600 - reach1 - CanopyLayer.BODY_PAD * 1.5, 600)
	await get_tree().process_frame
	_check("b.fade.body-past-art", _shapes_of(layer, CanopyLayer.Fade.PARTY).size() == 0)
	# off the view: no fade (the budget is for what can be seen)
	pm.global_position = Vector2(600 + 75, 600)
	layer.view_override = Rect2(1500, 1500, 100, 100)
	await get_tree().process_frame
	_check("b.fade.party-off-view", _shapes_of(layer, CanopyLayer.Fade.PARTY).is_empty())
	# ... but just off it, its rings reaching in (55 px past its edge, rings 120), it does
	layer.view_override = Rect2(560, 520, 60, 60)
	await get_tree().process_frame
	_check("b.fade.party-just-off-view", _shapes_of(layer, CanopyLayer.Fade.PARTY).size() == 1)
	layer.view_override = Rect2(0, 0, 2048, 2048)
	# an NPC under it fades nothing (only the party)
	party_chars = []
	var npc := Node2D.new()
	add_child(npc)
	npc.global_position = Vector2(600, 600)
	await get_tree().process_frame
	_check("b.fade.not-for-npcs", layer.fade_shapes().size() == 0)
	# a party member in the open: no fade
	pm.global_position = Vector2(1000, 1000)
	party_chars = [pm]
	await get_tree().process_frame
	_check("b.fade.party-in-open", layer.fade_shapes().size() == 0)
	# the cursor over a crown
	layer.cursor_override = Vector2(700, 640)
	await get_tree().process_frame
	fp = _shapes_of(layer, CanopyLayer.Fade.CURSOR)
	_check("b.fade.cursor", fp.size() == 1 and is_equal_approx(float(fp[0]["inner"]), CanopyLayer.CURSOR_FADE.x)
		and is_equal_approx(float(fp[0]["outer"]), CanopyLayer.CURSOR_FADE.y), fp)
	# ... but not off the view (the mouse is always in it; an override need not be)
	layer.view_override = Rect2(1500, 1500, 100, 100)
	await get_tree().process_frame
	_check("b.fade.cursor-off-view", _shapes_of(layer, CanopyLayer.Fade.CURSOR).is_empty())
	layer.view_override = Rect2(0, 0, 2048, 2048)
	layer.cursor_override = Vector2(100, 100)
	# REVEAL_GROUP: a polyline fades along each straight run that comes near
	# a crown (one capsule, its radii grown by REVEAL_TOL), not along a run
	# far from every crown; a disc far from every crown fades nothing
	var stub := RevealStub.new()
	stub.shapes = [[PackedVector2Array([Vector2(200, 1700), Vector2(200, 600), Vector2(1000, 600)]), 14.0],
		[PackedVector2Array([Vector2(1800, 1800)]), 20.0]]
	add_child(stub)
	await get_tree().process_frame
	var rv: Array = _shapes_of(layer, CanopyLayer.Fade.REVEAL)
	var inner_l: float = 14.0 + CanopyLayer.REVEAL_TOL
	var all_near := not rv.is_empty()
	for s in rv:
		all_near = all_near and layer.near_art(s["a"], s["b"], float(s["outer"])) \
			and is_equal_approx(float(s["outer"]), inner_l + CanopyLayer.REVEAL_FEATHER)
	_check("b.reveal.polyline-near-crowns", all_near and _has_capsule(rv, Vector2(200, 600), Vector2(1000, 600), inner_l), rv)
	_check("b.reveal.straight-run-one-capsule", rv.size() == 1, rv)
	_check("b.reveal.culls-far-shapes", not _has_capsule(rv, Vector2(200, 1700), Vector2(200, 600), inner_l)
		and not _has_disc(rv, Vector2(1800, 1800), 20.0), rv)
	stub.shapes = [[PackedVector2Array([Vector2(610, 560)]), 10.0]]
	await get_tree().process_frame
	rv = _shapes_of(layer, CanopyLayer.Fade.REVEAL)
	_check("b.reveal.disc", rv.size() == 1 and _has_disc(rv, Vector2(610, 560), 10.0), rv)
	# the view: a shape wholly outside it (grown by its feather) is dropped
	stub.shapes = [[PackedVector2Array([Vector2(610, 560)]), 10.0], [PackedVector2Array([Vector2(700, 700)]), 10.0]]
	layer.view_override = Rect2(560, 520, 60, 60)
	await get_tree().process_frame
	rv = _shapes_of(layer, CanopyLayer.Fade.REVEAL)
	_check("b.reveal.view-culls", rv.size() == 1 and _has_disc(rv, Vector2(610, 560), 10.0), rv)
	# ... and one whose feather reaches into it from just outside is kept: a
	# disc 30 px past its edge (outer 38), a polyline 30 px past it (outer 48)
	stub.shapes = [[PackedVector2Array([Vector2(650, 560)]), 10.0]]
	await get_tree().process_frame
	rv = _shapes_of(layer, CanopyLayer.Fade.REVEAL)
	_check("b.reveal.view-keeps-feather-disc", rv.size() == 1 and _has_disc(rv, Vector2(650, 560), 10.0), rv)
	stub.shapes = [[PackedVector2Array([Vector2(650, 500), Vector2(650, 660)]), 14.0]]
	await get_tree().process_frame
	rv = _shapes_of(layer, CanopyLayer.Fade.REVEAL)
	_check("b.reveal.view-keeps-feather-capsule", rv.size() == 1
		and _has_capsule(rv, Vector2(650, 500), Vector2(650, 660), 14.0 + CanopyLayer.REVEAL_TOL), rv)
	# ... and the view is what the viewport shows: zoomed in x8 on (610, 560)
	var vp := get_viewport()
	var keep_xf: Transform2D = vp.canvas_transform
	var vs: Vector2 = vp.get_visible_rect().size
	vp.canvas_transform = Transform2D(0.0, Vector2(8, 8), 0.0, vs * 0.5 - Vector2(610, 560) * 8.0)
	layer.view_override = null
	stub.shapes = [[PackedVector2Array([Vector2(610, 560)]), 10.0], [PackedVector2Array([Vector2(790, 660)]), 10.0]]
	await get_tree().process_frame
	rv = _shapes_of(layer, CanopyLayer.Fade.REVEAL)
	var vr: Rect2 = layer.view_rect()
	_check("b.reveal.view-is-the-viewport", vr.get_center().is_equal_approx(Vector2(610, 560))
		and is_equal_approx(vr.size.x, vs.x / 8.0) and rv.size() == 1 and _has_disc(rv, Vector2(610, 560), 10.0), [vr, rv])
	vp.canvas_transform = keep_xf
	layer.view_override = Rect2(0, 0, 2048, 2048)
	stub.queue_free()
	await get_tree().process_frame   # freed at the end of this frame
	await get_tree().process_frame
	_check("b.reveal.gone-with-provider", _shapes_of(layer, CanopyLayer.Fade.REVEAL).is_empty())
	# a real aim line into the crown: the ribbon and its landing reticle
	var aim := AimLine.new()
	add_child(aim)
	aim.show_aim(Vector2(450, 600), Vector2(650, 600))
	await get_tree().process_frame
	rv = _shapes_of(layer, CanopyLayer.Fade.REVEAL)
	_check("b.reveal.aim-line", _has_capsule(rv, aim._from, aim._to, 14.0 + CanopyLayer.REVEAL_TOL), rv)
	_check("b.reveal.aim-reticle", _has_disc(rv, aim._to, AimLine.RETICLE_RADIUS + 10.0), rv)
	aim.hide_aim()
	await get_tree().process_frame
	_check("b.reveal.aim-line-hidden", _shapes_of(layer, CanopyLayer.Fade.REVEAL).is_empty())
	aim.queue_free()
	# a real planned route through the grove: every point of it under a
	# crown's art fades fully
	var pd := PathDrawer.new()
	pd.tactical_path = TacticalPath.new()
	pd.tactical_path.set_waypoints(PackedVector2Array([Vector2(420, 700), Vector2(600, 660), Vector2(820, 640)]))
	add_child(pd)
	await get_tree().process_frame
	var route: PackedVector2Array = pd._visible_route()
	var bare: Array = _uncovered(layer, route)
	_check("b.reveal.path-route", route.size() > 3 and bare.is_empty() and not _shapes_of(layer, CanopyLayer.Fade.REVEAL).is_empty(),
		"%d route points, uncovered %s" % [route.size(), str(bare)])
	# its nodes' ends: a queued dash's leash and landing, a detached AoE's
	var dash_to := Vector2(690, 600)
	var nd = pd.tactical_path.insert_action_node(Vector2(600, 660), ActionQueue.ActionType.ATTACK, {"dash_target": dash_to})
	var na = pd.tactical_path.insert_action_node(Vector2(540, 672))
	na.aoe_center = Vector2(560, 590)
	na.aoe_extent = 30.0
	await get_tree().process_frame
	rv = _shapes_of(layer, CanopyLayer.Fade.REVEAL)
	var leash_r: float = PathDrawer.CANOPY_REVEAL_R + CanopyLayer.REVEAL_TOL
	_check("b.reveal.path-node-marks", _has_disc(rv, nd.world_position, PathDrawer.ARROW_LENGTH)
		and _has_disc(rv, na.world_position, PathDrawer.ARROW_LENGTH), rv)
	_check("b.reveal.path-dash", _has_capsule(rv, nd.world_position, dash_to, leash_r)
		and _has_disc(rv, dash_to, PathDrawer.NODE_RADIUS + 4.0), rv)
	_check("b.reveal.path-aoe", _has_capsule(rv, na.world_position, na.aoe_center, leash_r)
		and _has_disc(rv, na.aoe_center, PathDrawer.NODE_RADIUS + 4.0), rv)
	# a plan with no route left (TacticalPath.truncate_before at its last point
	# keeps one waypoint and the nodes there), a node there with a detached
	# AoE: its mark and its leash still fade
	var spot := Vector2(560, 640)
	pd.tactical_path.set_waypoints(PackedVector2Array([spot]))
	var ns = pd.tactical_path.insert_action_node(spot)
	ns.aoe_center = Vector2(620, 570)
	ns.aoe_extent = 30.0
	await get_tree().process_frame
	rv = _shapes_of(layer, CanopyLayer.Fade.REVEAL)
	_check("b.reveal.path-node-without-route", _has_disc(rv, spot, PathDrawer.ARROW_LENGTH)
		and _has_capsule(rv, spot, ns.aoe_center, leash_r) and _has_disc(rv, ns.aoe_center, PathDrawer.NODE_RADIUS + 4.0), rv)
	# no plan at all, a facing arrow being drawn: its start fades
	pd.tactical_path.set_waypoints(PackedVector2Array())
	pd.is_drawing_rotation = true
	pd.rotation_start = Vector2(640, 560)
	pd.rotation_current = Vector2(700, 560)
	await get_tree().process_frame
	rv = _shapes_of(layer, CanopyLayer.Fade.REVEAL)
	_check("b.reveal.path-rotation-without-plan", rv.size() == 1
		and _has_disc(rv, Vector2(640, 560), PathDrawer.ARROW_LENGTH + 4.0), rv)
	pd.is_drawing_rotation = false
	pd.queue_free()
	await get_tree().process_frame
	# fire under a crown: a real CellFireFX, set up with a sim whose two
	# neighbouring cells burn, clusters them with its lights; the cluster is a
	# REVEAL disc and its light lights the crowns
	var fx := CellFireFX.new()
	add_child(fx)
	var sim := FireSimStub.new()
	add_child(sim)
	var graph := CellGraph.from_square_tiles()
	var c0: int = graph.cell_at(Vector2(610, 610))
	var c1: int = c0 + 1
	sim.burning = {c0: {"seed": 0.3, "t0": 6.0, "t": 5.0}, c1: {"seed": 0.6, "t0": 6.0, "t": 5.0}}
	sim.burn_rev = 1
	fx.setup(sim, graph)
	await get_tree().process_frame
	await get_tree().process_frame
	var fc: Vector2 = (graph.centroid(c0) + graph.centroid(c1)) * 0.5
	var fext: float = fc.distance_to(graph.centroid(c0)) + graph.radius(c0)
	_check("b.fire.clusters", fx._reveal.size() == 1 and (fx._reveal[0][0] as Vector2).is_equal_approx(fc)
		and is_equal_approx(float(fx._reveal[0][1]), fext), fx._reveal)
	rv = _shapes_of(layer, CanopyLayer.Fade.REVEAL)
	_check("b.reveal.fire", rv.size() == 1 and _has_disc(rv, fx.to_global(fc), fext + 12.0), rv)
	var fl: PointLight2D = fx._lights[0] if fx._lights.size() > 0 else null
	_check("b.fire.light-lights-crowns", fl != null and fl.visible and fl.range_item_cull_mask == CollisionLayers.LAMP_RANGE_MASK,
		fl.range_item_cull_mask if fl != null else -1)
	sim.burning = {}
	sim.burn_rev = 2
	await get_tree().process_frame   # the fire re-clusters (the layer may ask first)
	await get_tree().process_frame
	_check("b.reveal.fire-out", fx._reveal.is_empty() and _shapes_of(layer, CanopyLayer.Fade.REVEAL).is_empty())
	fx.queue_free()
	sim.queue_free()
	await get_tree().process_frame
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
	pm.queue_free()
	npc.queue_free()
	party_chars = []


# A crown the record kills goes at once, its disc too; a felled tree's crown,
# disc and shade go.
func _part_b_drop(ml: Node2D, spawned: Dictionary) -> void:
	var layer: CanopyLayer = ml.canopy_layer
	if layer == null:
		return
	var i1: int = GridManager.canopy.crown_of(spawned["hide"])
	var i2: int = GridManager.canopy.crown_of(spawned["hide2"])
	var d2 := layer.rule_disc(i2)
	GridManager.canopy.kill_crown(i2)
	_check("b.drop.kill_crown", not (i2 in layer.drawn_crowns()), layer.drawn_crowns())
	await get_tree().process_frame
	_check("b.drop.disc-freed", not is_instance_valid(d2) and layer.rule_disc(i2) == null)
	var tree: Structure = spawned["hide"]
	var shade := tree.get_node("Shade")
	var d1 := layer.rule_disc(i1)
	tree.take_damage({"slashing": 100000})
	_check("b.drop.felled", layer.drawn_crowns().is_empty(), layer.drawn_crowns())
	await get_tree().process_frame
	_check("b.drop.shade-freed", not is_instance_valid(shade))
	_check("b.drop.felled-disc-freed", not is_instance_valid(d1))
	_check("b.drop.no-fade-over-dead-crowns", not layer.under_art(Vector2(600, 600), 0.0))


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


func _part_c(ml: Node2D) -> void:
	var layer: CanopyLayer = ml.canopy_layer
	_check("c.of-map-loader", CanopyLayer.of(ml) == layer and layer != null)
	var v := Viewer.new()
	add_child(v)
	v.global_position = Vector2(900, 700)   # 209 px from the second crown
	var light := _cone(800.0)
	v.add_child(light)
	# a map without a CanopyLayer: no child
	_check("c.off.none", CanopyLayer.fit_canopy_cone(light, v, null) == null)
	var cc: PointLight2D = CanopyLayer.fit_canopy_cone(light, v, layer)
	_check("c.child", cc != null and cc.get_parent() == light and cc.name == CanopyLayer.CANOPY_CONE_NAME)
	if cc == null:
		v.queue_free()
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
	CanopyLayer.fit_canopy_cone(light, v, layer)
	_check("c.ground.near-wins", cc.enabled and is_equal_approx(cc.texture_scale, light.texture_scale * 150.0 / 200.0), cc.texture_scale)
	light.texture_scale = 800.0 / (light.texture.get_width() * 0.5)
	# no live crown within the canopy cone's reach: off (no second shadowed light for nothing)
	v.global_position = Vector2(1900, 1900)
	CanopyLayer.fit_canopy_cone(light, v, layer)
	_check("c.no-crown-in-reach.off", not cc.enabled)
	v.global_position = Vector2(900, 700)
	# under a crown: its whole range
	v.crown = 3
	CanopyLayer.fit_canopy_cone(light, v, layer)
	_check("c.under-crown.full-range", cc.enabled and is_equal_approx(cc.texture_scale, light.texture_scale))
	v.crown = -1
	# a story up: nothing
	v.hag = 1.2
	CanopyLayer.fit_canopy_cone(light, v, layer)
	_check("c.high-deck.off", not cc.enabled)
	v.hag = 0.0
	v.on_roof = true
	CanopyLayer.fit_canopy_cone(light, v, layer)
	_check("c.roof.off", not cc.enabled)
	v.on_roof = false
	# a deck under a story: a ground viewer
	v.hag = 0.7
	CanopyLayer.fit_canopy_cone(light, v, layer)
	_check("c.low-deck.half", cc.enabled and is_equal_approx(cc.texture_scale, light.texture_scale * 0.5))
	v.hag = 0.0
	# the cone off (Blinded, dead): its child too
	light.enabled = false
	CanopyLayer.fit_canopy_cone(light, v, layer)
	_check("c.cone-off", not cc.enabled)
	light.enabled = true
	# the cone hidden (stealth mode off hides NPC cones): its child off, no work
	light.visible = false
	CanopyLayer.fit_canopy_cone(light, v, layer)
	_check("c.cone-hidden", not cc.enabled)
	light.visible = true
	CanopyLayer.fit_canopy_cone(light, v, layer)
	_check("c.cone-shown-again", cc.enabled)
	# the cone retiers (a band mask): the child follows
	light.shadow_item_cull_mask = CollisionLayers.SIGHT_MASK_GROUND | (1 << 5)
	light.color = Color(0.55, 0.62, 0.72)
	light.energy = 0.08
	CanopyLayer.fit_canopy_cone(light, v, layer)
	_check("c.follows-retier", cc.shadow_item_cull_mask == (CollisionLayers.SIGHT_MASK_GROUND | (1 << 5) | CollisionLayers.CANOPY_LIGHT))
	_check("c.follows-tint", cc.color == light.color and is_equal_approx(cc.energy, 0.08))
	# the map loses its CanopyLayer: the child switches off
	CanopyLayer.fit_canopy_cone(light, v, null)
	_check("c.off-again", not cc.enabled)
	v.queue_free()
	await get_tree().process_frame


func _spawn_pc(pos: Vector2) -> ProceduralCharacter:
	var c: ProceduralCharacter = PC_SCENE.instantiate()
	c.AI_enabled = false
	add_child(c)
	TopDownCharacterDatabase.build_character(c, "default_human")
	c.game = self
	c.faction_id = "player"
	c.global_position = pos
	c._refresh_elevation()
	return c


# Real characters: the methods the fit reads exist and agree with the rules;
# a character under a crown is lit only by the canopy cones; its reticle.
func _part_c_real(ml: Node2D, spawned: Dictionary) -> void:
	var layer: CanopyLayer = ml.canopy_layer
	var c := _spawn_pc(Vector2(880, 640))   # 180 px from the second crown, under none
	characters_in_scene.append(c)
	var light := _cone(c.get_sight_range_px())
	c.add_child(light)
	var cc: PointLight2D = CanopyLayer.fit_canopy_cone(light, c, layer)
	var near: float = c._canopy_near_px(c)
	var want: float = maxf(ProceduralCharacter.CANOPY_VISIBILITY, near / c.get_sight_range_px())
	_check("c.real.ground", cc != null and cc.enabled and is_equal_approx(cc.texture_scale, light.texture_scale * want),
		"%s %f want x%f" % [str(cc != null and cc.enabled), cc.texture_scale if cc else -1.0, want])
	# a fresh crown over them through the record (they stand under its leaves, off its trunk)
	var ci: int = GridManager.canopy.add_crown(Vector2(920, 640), 60.0, 27.0, 0.0, 1.0, 1.7, null)
	GridManager.canopy.finish()
	_check("c.real.under-crown-is-read", c.canopy_crown() == ci, c.canopy_crown())
	CanopyLayer.fit_canopy_cone(light, c, layer)
	_check("c.real.under-crown.full", cc.enabled and is_equal_approx(cc.texture_scale, light.texture_scale))
	GridManager.canopy.kill_crown(ci)
	c.on_roof = true
	CanopyLayer.fit_canopy_cone(light, c, layer)
	_check("c.real.roof.off", not cc.enabled)
	c.on_roof = false
	# out in the open: the full cones light the body (mask 1)
	await get_tree().process_frame
	var m0 := _body_masks(c)
	_check("c.gate.open-body-lit", m0.x > 0 and m0.y == 0 and not (c in layer.gated_characters()), m0)
	# under the first crown (the rules hide it): its body trades mask 1 for SHADED_MASK
	var i1: int = GridManager.canopy.crown_of(spawned["hide"])
	c.global_position = Vector2(600 + 45, 600)
	await get_tree().process_frame
	_check("c.gate.hidden-is-read", c.canopy_crown() == i1 and CanopyLayer.hides_under_crown(c), c.canopy_crown())
	var m1 := _body_masks(c)
	_check("c.gate.hidden-body-shaded", m1.x == 0 and m1.y >= m0.x and c in layer.gated_characters(), m1)
	_check("c.gate.own-cone-untouched", light.light_mask == 1)
	# its world-space UI (top_level: the route layer, the aim line) is no body
	# part and keeps mask 1; gear put on while it stays hidden is shaded at
	# the next re-walk
	c._ensure_aim_line()
	var gear := Sprite2D.new()
	c.add_child(gear)
	await get_tree().create_timer(CanopyLayer.REGATE_SECONDS + 0.25, true).timeout
	await get_tree().process_frame
	_check("c.gate.regate-new-gear", gear.light_mask == CanopyLayer.SHADED_MASK, gear.light_mask)
	_check("c.gate.top-level-ui-untouched", c.path_drawer != null and c.path_drawer.light_mask == 1
		and c._aim_line != null and c._aim_line.light_mask == 1,
		"%d %d" % [c.path_drawer.light_mask if c.path_drawer else -1, c._aim_line.light_mask if c._aim_line else -1])
	gear.queue_free()
	# its queued reticle is a REVEAL disc as wide as the sprite (ActionQueue)
	var ret: Sprite2D = c.action_queue._create_reticle(Vector2(600, 560), ActionQueue.ActionType.ATTACK)
	await get_tree().process_frame
	var found := false
	for s in _shapes_of(layer, CanopyLayer.Fade.REVEAL):
		if (s["a"] as Vector2).is_equal_approx(Vector2(600, 560)) and float(s["inner"]) >= 4.0:
			found = true
	_check("c.reveal.reticle", ret != null and found, _shapes_of(layer, CanopyLayer.Fade.REVEAL))
	if ret != null:
		ret.queue_free()
	# an attack gives it away (reveal()): lit by the full cones again
	c.reveal()
	await get_tree().process_frame
	var m2 := _body_masks(c)
	_check("c.gate.revealed-body-lit", m2.y == 0 and m2.x >= m0.x and not (c in layer.gated_characters()), m2)
	c._canopy_revealed_until = -1.0
	await get_tree().process_frame
	_check("c.gate.hidden-again", _body_masks(c).x == 0)
	# out from under it: mask 1 back
	c.global_position = Vector2(880, 640)
	await get_tree().process_frame
	var m3 := _body_masks(c)
	_check("c.gate.out-body-lit", m3.y == 0 and m3.x >= m0.x, m3)
	characters_in_scene.erase(c)
	c.queue_free()
	await get_tree().process_frame


# ---------------------------------------------------------------------------
# D/E. the real loader, and Game's cone wiring
# ---------------------------------------------------------------------------
func _map_dict(id: String, images: Dictionary, with_cells: bool) -> Dictionary:
	var p1 := Vector2(600, 600)
	var p2 := Vector2(1200, 600)
	var p3 := Vector2(1500, 1300)
	var rows: Array = [
		_row(p1, 60.0, 1.7, _cells(p1, 60.0, 2, 2, 200, 2) if with_cells else {}),
		_row(p2, 50.0, 1.7, _cells(p2, 50.0, 2, 180, 330, 2) if with_cells else {}),
		_row(p3, 40.0, 0.72, _cells(p3, 40.0, 120, 180, 420, 120) if with_cells else {}),
		{"kind": "tree", "pos": [300, 1200], "r": 18.0, "id": "hedge", "hp": 30, "stories": 0.5, "occlude_h": 0.45}]
	return {"id": id, "format": "structured", "images": images, "floors": [], "structures": rows}


func _load_map(m: Dictionary) -> Node2D:
	GridManager.initialize(32 * 64, 32 * 64)
	structures_in_scene.clear()
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	ml.generate_structured_map(m)
	return ml


func _part_d() -> void:
	var ml: Node2D = _load_map(_map_dict("canopy_check_c3", {"map": GROUND_RES, "canopy": ATLAS_RES}, true))
	var layer: CanopyLayer = ml.canopy_layer
	_check("d.loader.layer-built", layer != null and is_instance_valid(layer) and layer.get_parent() == ml)
	_check("d.loader.of", CanopyLayer.of(ml) == layer)
	if layer == null:
		ml.queue_free()
		return
	layer.view_override = Rect2(0, 0, 2048, 2048)
	_check("d.loader.draws-hiding-crowns", layer.drawn_crowns().size() == 2, layer.drawn_crowns())
	_check("d.loader.atlas-not-held", ml._canopy_tex == null)
	var shades := 0
	var unshaded := 0
	for ch in ml.get_children():
		if ch is Structure:
			var sh := (ch as Node).get_node_or_null("Shade") as Polygon2D
			if sh != null:
				shades += 1
				var mm := sh.material as CanvasItemMaterial
				if mm != null and mm.light_mode == CanvasItemMaterial.LIGHT_MODE_UNSHADED:
					unshaded += 1
	_check("d.loader.shades-unshaded", shades == 3 and unshaded == 3, "%d shades, %d unshaded" % [shades, unshaded])
	var discs := 0
	for ci in layer.drawn_crowns():
		var d := layer.rule_disc(int(ci))
		if d != null and ml.structured_ground != null and d.texture == ml.structured_ground.texture \
				and d.light_mask == CanopyLayer.SHADED_MASK and not d.z_as_relative and d.z_index == -6:
			discs += 1
	_check("d.loader.rule-discs-from-ground", discs == 2, discs)
	# the layer's game is the loader's parent: the party fade works on a real load
	var pm := Node2D.new()
	add_child(pm)
	pm.global_position = Vector2(600 + 50, 600)
	party_chars = [pm]
	await get_tree().process_frame
	_check("d.loader.party-fade", _shapes_of(layer, CanopyLayer.Fade.PARTY).size() == 1)
	party_chars = []
	pm.queue_free()
	# E. Game._update_sight_cones, Game.gd instanced bare (not in the tree)
	var c := _spawn_pc(Vector2(700, 600))   # 100 px from the first crown: off its rule disc, near it
	var los := _cone(c.get_sight_range_px())
	los.name = "LineOfSight"
	c.add_child(los)
	var g: Object = load(GAME_SCRIPT).new()
	g.set("map_loader", ml)
	g.set("characters_in_scene", [c])
	g.call("_update_sight_cones")
	var cc := los.get_node_or_null(CanopyLayer.CANOPY_CONE_NAME) as PointLight2D
	_check("e.game.fits-canopy-cone", cc != null and cc.enabled and cc.range_item_cull_mask == CollisionLayers.CANOPY_LIGHT)
	_check("e.game.weapon-shot-over-crowns", int(g.call("weapon_shot_z")) == CanopyLayer.SHOT_Z and CanopyLayer.SHOT_Z > CanopyLayer.CANOPY_Z)
	var c2: Node2D = _load_map(_map_dict("canopy_check_c2", {"map": GROUND_RES}, false))
	_check("d.loader.c2-no-layer", c2.canopy_layer == null and CanopyLayer.of(c2) == null)
	g.set("map_loader", c2)
	g.call("_update_sight_cones")
	_check("e.game.c2-canopy-cone-off", cc != null and not cc.enabled)
	_check("e.game.c2-weapon-shot-under-characters", int(g.call("weapon_shot_z")) == 3)
	(g as Node).free()
	c2.queue_free()
	await get_tree().process_frame
	# the layer gives a hidden character's lights back when the map goes
	GridManager.initialize(32 * 64, 32 * 64)
	ml.queue_free()
	await get_tree().process_frame
	c.queue_free()
	await get_tree().process_frame
	await _part_d_exit()


# A hidden character keeps its lights when the map (and its layer) goes.
func _part_d_exit() -> void:
	var ml: Node2D = _load_map(_map_dict("canopy_check_exit", {"map": GROUND_RES, "canopy": ATLAS_RES}, true))
	var c := _spawn_pc(Vector2(600 + 45, 600))
	characters_in_scene.append(c)
	await get_tree().process_frame
	var layer: CanopyLayer = ml.canopy_layer
	_check("d.exit.gated", layer != null and c in layer.gated_characters() and _body_masks(c).x == 0)
	# its selection ring (Game's, not the character's) takes the same gate
	_part_d_ring(ml, c)
	ml.queue_free()
	await get_tree().process_frame
	var m := _body_masks(c)
	_check("d.exit.lights-back", m.y == 0 and m.x > 0, m)
	characters_in_scene.erase(c)
	c.queue_free()
	await get_tree().process_frame


# Game.shade_selection_ring (Game.gd instanced bare, as in part E): the
# selection ring of a party member the crown rules hide under a crown wears
# SHADED_MASK like its body, so no cone whose viewer is blind to the member
# tints it; a member in the open, and any member on a map without a
# CanopyLayer (contract 2), keeps mask 1; the ring follows the member out.
func _part_d_ring(ml: Node2D, hidden: ProceduralCharacter) -> void:
	var g: Node = load(GAME_SCRIPT).new()
	g.set("map_loader", ml)
	var open_c := _spawn_pc(Vector2(1000, 1100))   # under no crown
	g.call("_add_selection_circle", hidden, Color.WHITE)
	g.call("_add_selection_circle", open_c, Color.WHITE)
	var inds: Dictionary = g.get("selection_indicators")
	var ring: Node2D = inds.get(hidden) as Node2D
	var open_ring: Node2D = inds.get(open_c) as Node2D
	var layer: CanopyLayer = CanopyLayer.of(ml)
	_check("d.ring.made", ring != null and open_ring != null and _ring_mask(ring) == 1 and layer != null
		and CanopyLayer.hides_under_crown(hidden) and not CanopyLayer.hides_under_crown(open_c))
	if ring == null or open_ring == null:
		g.free()
		open_c.queue_free()
		return
	g.call("shade_selection_ring", ring, hidden, layer)
	g.call("shade_selection_ring", open_ring, open_c, layer)
	_check("d.ring.hidden-shaded", _ring_mask(ring) == CanopyLayer.SHADED_MASK, _ring_mask(ring))
	_check("d.ring.open-lit", _ring_mask(open_ring) == 1, _ring_mask(open_ring))
	g.call("shade_selection_ring", ring, hidden, null)
	_check("d.ring.no-layer-lit", _ring_mask(ring) == 1, _ring_mask(ring))
	g.call("shade_selection_ring", ring, hidden, layer)
	hidden.global_position = Vector2(1000, 1000)   # out from under the crown
	hidden._refresh_elevation()
	g.call("shade_selection_ring", ring, hidden, layer)
	_check("d.ring.out-lit", not CanopyLayer.hides_under_crown(hidden) and _ring_mask(ring) == 1, _ring_mask(ring))
	hidden.global_position = Vector2(600 + 45, 600)
	hidden._refresh_elevation()
	g.free()
	open_c.queue_free()


# The ring's light mask: the indicator's and its circle's when they agree, else -1.
func _ring_mask(ring: Node2D) -> int:
	var m: int = ring.light_mask
	for ch in ring.get_children():
		if ch is CanvasItem and (ch as CanvasItem).light_mask != m:
			return -1
	return m if ring.get_child_count() > 0 else -1


# ---------------------------------------------------------------------------
# G. the fade budget
# ---------------------------------------------------------------------------
const G_R := 60.0

# Route k of three through four crowns each, zig-zagging (the crowns' centre
# offset as a party would walk through them).
func _g_route(k: int) -> PackedVector2Array:
	var y0: float = 360.0 + 420.0 * float(k)
	var pts := PackedVector2Array([Vector2(120, y0)])
	for j in 4:
		var c := Vector2(320.0 + 230.0 * float(j), y0 + (70.0 if j % 2 == 1 else -40.0))
		pts.append(c + Vector2(G_R * 0.3, G_R * 0.35))
	pts.append(Vector2(1280, y0 + 60.0))
	return pts


func _part_g() -> void:
	# a grove of its own: twelve hiding crowns, four on each route
	var crowns: Array = []
	var arts: Array = []
	for k in 3:
		var y0: float = 360.0 + 420.0 * float(k)
		for j in 4:
			var p := Vector2(320.0 + 230.0 * float(j), y0 + (70.0 if j % 2 == 1 else -40.0))
			var art := Node2D.new()
			add_child(art)
			arts.append(art)
			var ci: int = GridManager.canopy.add_crown(p, G_R, 27.0, 0.0, 1.0, 1.7, null)
			var ch: int = ceili(G_R * 1.35 + 4.0)
			crowns.append({"index": ci, "art": art,
				"cell": [2, 2, 2 * ch, 2 * ch, int(p.x) - ch, int(p.y) - ch, 2 * ch, 2 * ch]})
	GridManager.canopy.finish()
	var layer := CanopyLayer.new()
	layer.setup(_atlas, crowns, self, null)
	add_child(layer)
	layer.view_override = Rect2(0, 0, 2048, 2048)
	layer.cursor_override = Vector2(-9999, -9999)
	party_chars = []
	# reveal_runs: a straight line of many points is one capsule, an L two
	var line := PackedVector2Array()
	for i in 41:
		line.append(Vector2(100.0 + 20.0 * float(i), 300.0))
	_check("g.runs.straight", CanopyLayer.reveal_runs(line).size() == 2, CanopyLayer.reveal_runs(line))
	line.append(Vector2(900, 700))
	_check("g.runs.corner", CanopyLayer.reveal_runs(line).size() == 3, CanopyLayer.reveal_runs(line))
	# the last point is always kept: 20 px past the last REVEAL_STEP one, and
	# a 20 px last leg that turns is a run of its own, out to its tip
	line.remove_at(line.size() - 1)
	line.append(Vector2(920, 300))
	var lr := CanopyLayer.reveal_runs(line)
	_check("g.runs.keeps-last", lr.size() == 2 and lr[lr.size() - 1] == Vector2(920, 300), lr)
	line.append(Vector2(920, 320))
	lr = CanopyLayer.reveal_runs(line)
	_check("g.runs.keeps-last-turn", lr.size() == 3 and lr[lr.size() - 1] == Vector2(920, 320), lr)
	# every kept point within REVEAL_TOL of its run's axis (the fade radii
	# grow by just that much, so the line's own radius fades fully): part G's
	# routes as PathDrawer smooths them, an arc, a hairpin back along itself,
	# forty hand-drawn weaves
	var curves: Array = []
	for k in 3:
		curves.append(PathDrawer._chaikin(_g_route(k), PathDrawer.SMOOTH_ITERATIONS))
	var arc := PackedVector2Array()
	for i in 181:
		arc.append(Vector2(1000, 1000) + Vector2.from_angle(deg_to_rad(float(i))) * 300.0)
	curves.append(arc)
	curves.append(PathDrawer._chaikin(PackedVector2Array([Vector2(100, 100), Vector2(500, 100), Vector2(300, 102),
		Vector2(300, 400)]), PathDrawer.SMOOTH_ITERATIONS))
	var wrng := RandomNumberGenerator.new()
	wrng.seed = 5
	for _i in 40:
		curves.append(_weave_route(wrng))
	var broken: Array = []
	var n_runs := 0
	var n_kept := 0
	for i in curves.size():
		var worst: float = _runs_worst(curves[i])
		if worst < 0.0 or worst > CanopyLayer.REVEAL_TOL + 0.001:
			broken.append("curve %d: %.3f" % [i, worst])
		n_runs += CanopyLayer.reveal_runs(curves[i]).size() - 1
		n_kept += CanopyLayer.reveal_kept(curves[i]).size() - 1
	_check("g.runs.within-tol-of-axis", broken.is_empty() and n_runs * 2 < n_kept,
		"%s; %d runs for %d kept segments" % [str(broken), n_runs, n_kept])
	# three planned routes, each through four crowns, each with a dash leash
	var pds: Array = []
	for k in 3:
		var pd := PathDrawer.new()
		pd.tactical_path = TacticalPath.new()
		pd.tactical_path.set_waypoints(_g_route(k))
		add_child(pd)
		pd.tactical_path.insert_action_node(_g_route(k)[2], ActionQueue.ActionType.ATTACK,
			{"dash_target": _g_route(k)[3] + Vector2(0, 40)})
		pds.append(pd)
	await get_tree().process_frame
	var n_rev: int = _shapes_of(layer, CanopyLayer.Fade.REVEAL).size()
	var bare: Array = []
	for pd in pds:
		bare.append(_uncovered(layer, (pd as PathDrawer)._visible_route()).size())
	_check("g.three-routes.every-crossing-faded", bare == [0, 0, 0], "uncovered points per route %s" % str(bare))
	# round 1 cut each route into a capsule per ~48 px near a crown: 34 a
	# route here (111 shapes in all, past its 64); a straight run is one
	# capsule now (13 a route, 48 in all)
	_check("g.three-routes.few-capsules", n_rev <= 60 and layer.fade_shapes().size() < CanopyLayer.MAX_FADES,
		"%d REVEAL shapes for three routes (+ node marks and leashes)" % n_rev)
	for pd in pds:
		(pd as Node).queue_free()
	await get_tree().process_frame
	# the budget overrun: 300 discs from a provider earlier in the tree, then a
	# character's own route; served first while it is the primary selection,
	# or in the selection, else the budget is spent before it
	var flood := RevealStub.new()
	for i in 300:
		var ci: Dictionary = crowns[i % crowns.size()]
		var rec: Dictionary = GridManager.canopy.crown(int(ci["index"]))
		flood.shapes.append([PackedVector2Array([(rec["pos"] as Vector2) + Vector2(float(i % 7) - 3.0, float(i % 5) - 2.0)]), 8.0])
	add_child(flood)
	var pc := _spawn_pc(Vector2(1800, 1900))
	var tp := TacticalPath.new()
	tp.set_waypoints(_g_route(1))
	pc.path_drawer.tactical_path = tp
	primary_selected = pc
	selected_characters = [pc]
	await get_tree().process_frame
	var mine: Array = _uncovered(layer, pc.path_drawer._visible_route())
	_check("g.overrun.full", layer.fade_shapes().size() == CanopyLayer.MAX_FADES, layer.fade_shapes().size())
	_check("g.overrun.primary-served-first", mine.is_empty(), "uncovered %s" % str(mine))
	primary_selected = null
	await get_tree().process_frame
	mine = _uncovered(layer, pc.path_drawer._visible_route())
	_check("g.overrun.selection-served-next", mine.is_empty(), "uncovered %s" % str(mine))
	selected_characters = []
	await get_tree().process_frame
	mine = _uncovered(layer, pc.path_drawer._visible_route())
	_check("g.overrun.others-after", not mine.is_empty(), "the flood should have spent the budget first")
	pc.path_drawer.tactical_path = pc.tactical_path
	var flood_shapes: Array = flood.shapes.duplicate()
	flood.queue_free()
	pc.queue_free()
	await get_tree().process_frame
	# a party member's plan before an NPC's: the same flood handed over by an
	# NPC's child, earlier in the tree, does not crowd out an unselected party
	# member's route
	var npc := _spawn_pc(Vector2(1900, 100))
	var nflood := RevealStub.new()
	nflood.shapes = flood_shapes
	npc.add_child(nflood)
	var mate := _spawn_pc(Vector2(1800, 1950))
	var tp2 := TacticalPath.new()
	tp2.set_waypoints(_g_route(2))
	mate.path_drawer.tactical_path = tp2
	party_chars = [mate]
	await get_tree().process_frame
	mine = _uncovered(layer, mate.path_drawer._visible_route())
	_check("g.overrun.party-before-npcs", layer.fade_shapes().size() == CanopyLayer.MAX_FADES and mine.is_empty(),
		"%d shapes, uncovered %s" % [layer.fade_shapes().size(), str(mine)])
	mate.path_drawer.tactical_path = mate.tactical_path
	party_chars = []
	npc.queue_free()
	mate.queue_free()
	await get_tree().process_frame
	# a polyline's runs are reused while it is unchanged, by its content: an
	# edit keeping its count and first, middle and last points (PathDrawer's
	# smooth key would miss it) is seen at once; only this frame's are held
	var c0: Vector2 = GridManager.canopy.crown(int(crowns[0]["index"]))["pos"]
	var cl := PackedVector2Array([c0 + Vector2(-150, 0), c0 + Vector2(-75, 0), c0, c0 + Vector2(75, 0), c0 + Vector2(150, 0)])
	var cst := RevealStub.new()
	cst.shapes = [[cl, 14.0]]
	add_child(cst)
	await get_tree().process_frame
	var inner_c: float = 14.0 + CanopyLayer.REVEAL_TOL
	var rv: Array = _shapes_of(layer, CanopyLayer.Fade.REVEAL)
	var straight_one: bool = rv.size() == 1 and _has_capsule(rv, cl[0], cl[4], inner_c)
	var reused: int = layer._runs_reused
	await get_tree().process_frame
	rv = _shapes_of(layer, CanopyLayer.Fade.REVEAL)
	var still_one: bool = rv.size() == 1 and _has_capsule(rv, cl[0], cl[4], inner_c)
	_check("g.cache.reused-while-unchanged", layer._runs_reused > reused, "%d reuses, %d before" % [layer._runs_reused, reused])
	var cl2 := PackedVector2Array(cl)
	cl2[3] = c0 + Vector2(75, 40)
	cst.shapes = [[cl2, 14.0]]
	await get_tree().process_frame
	rv = _shapes_of(layer, CanopyLayer.Fade.REVEAL)
	_check("g.cache.sees-an-edit", straight_one and still_one and _has_capsule(rv, c0, cl2[3], inner_c)
		and not _has_capsule(rv, cl[0], cl[4], inner_c), rv)
	for i in 6:
		var walk := PackedVector2Array(cl2)
		walk.append(c0 + Vector2(200.0 + 40.0 * float(i), 0))
		cst.shapes = [[walk, 14.0]]
		await get_tree().process_frame
	_check("g.cache.this-frame-only", layer._runs_now.size() == 1 and layer._runs_prev.size() <= 1,
		"%d now, %d kept from the frame before" % [layer._runs_now.size(), layer._runs_prev.size()])
	cst.queue_free()
	# the coarse grid answers as a scan of every crown would (two crowns dead)
	GridManager.canopy.kill_crown(int(crowns[5]["index"]))
	GridManager.canopy.kill_crown(int(crowns[6]["index"]))
	var every: Array = range(layer._crowns.size())
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var bad_any := 0
	var bad_near := 0
	var hits := 0
	for i in 600:
		var p := Vector2(rng.randf_range(-300.0, 2300.0), rng.randf_range(-300.0, 2300.0))
		var rad: float = rng.randf_range(0.0, 900.0)
		var want := false
		for c in layer._crowns:
			if bool(c["alive"]) and p.distance_to(c["pos"]) <= float(c["reach"]) + rad:
				want = true
		if want:
			hits += 1
		if layer.any_crown_within(p, rad) != want:
			bad_any += 1
		var q := p + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(0.0, 1500.0)
		var rr: float = rng.randf_range(0.0, 80.0)
		if layer.near_art(p, q, rr) != layer._capsule_hits(p, q, rr, every):
			bad_near += 1
	_check("g.grid.any-crown-within", bad_any == 0 and hits > 50 and hits < 550, "%d wrong (%d hits of 600)" % [bad_any, hits])
	_check("g.grid.near-art-long", bad_near == 0, "%d wrong of 600" % bad_near)
	layer.queue_free()
	for a in arts:
		(a as Node).queue_free()
	primary_selected = null
	selected_characters = []
	await get_tree().process_frame


# ---------------------------------------------------------------------------
# F. a missing atlas is loud
# ---------------------------------------------------------------------------
func _part_f() -> void:
	var lg := ErrLog.new()
	OS.add_logger(lg)
	var ml: Node2D = _load_map(_map_dict("canopy_check_nokey", {"map": GROUND_RES}, true))
	_check("f.cells-without-images-canopy.error", lg.has("images.canopy is missing"), lg.msgs)
	_check("f.cells-without-images-canopy.no-layer", ml.canopy_layer == null)
	ml.queue_free()
	await get_tree().process_frame
	ml = _load_map(_map_dict("canopy_check_nofile", {"map": GROUND_RES, "canopy": "res://Maps/no_such_canopy.png"}, true))
	_check("f.missing-canopy-file.error", lg.has("missing canopy image"), lg.msgs)
	ml.queue_free()
	await get_tree().process_frame
	var before := lg.msgs.size()
	ml = _load_map(_map_dict("canopy_check_c2quiet", {"map": GROUND_RES}, false))
	var quiet := true
	for i in range(before, lg.msgs.size()):
		if "canopy" in lg.msgs[i]:
			quiet = false
	_check("f.contract-2.quiet", quiet, lg.msgs)
	ml.queue_free()
	OS.remove_logger(lg)
	await get_tree().process_frame
