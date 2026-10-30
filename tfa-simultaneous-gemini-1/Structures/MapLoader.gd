# res://MapLoader.gd
extends Node2D

signal map_loaded

# the structured map's ground Sprite2D (null on legacy maps) -- FluidManager binds
# the organic water shader to it
var structured_ground: Sprite2D = null
# relief maps: the parent of the cliff light occluders (null elsewhere). Held
# by reference: a reload's new node can't take the name while the previous
# map's (queue_freed this frame) still holds it.
var cliff_occluders: Node2D = null
# the parent of the map's authored lights (a contract-2 row's "lights":
# forges, hearths, glow blocks); null when the row has none. Held by
# reference for the same reason as cliff_occluders.
var map_lights: Node2D = null

@export var map_image_path: String = "res://Maps/cemetery.png"
@export var mask_image_path: String = "res://Maps/cemetery_mask.png"
@export var structure_map_image_path: String = "res://maps/cemetery_structures.png"
@export var structure_mask_path: String = "res://maps/cemetery_structures_mask.png"
@export var blend_margin: int = 16  # pixels of blending around structure edges

# When true, generate_map() skips the structure pass entirely and uses the
# world-map terrain palette (plains/forest/mountain/water/city/farm). Mountains
# are registered as impassable obstacles directly with GridManager.
@export var world_map_mode: bool = false

# Multiplies tile position + rendered size when world_map_mode is true so the
# world is physically bigger in world coordinates without changing the source
# image. Game.gd reads this off Maps.json and sets it before generate_map().
# 1.0 = source pixels and world units are 1:1 (legacy behaviour).
@export var world_render_scale: float = 1.0

var structure_scene: PackedScene = preload("res://Structures/Structure.tscn")
const DOOR_SCRIPT := preload("res://Structures/Door.gd")
const EquipmentEffects = preload("res://Items/equipment_effects.gd")
## Light rows spawned per map at most (TG caps its export lower; this guards
## hand-edited rows). Beyond it the rest are dropped with one warning.
const MAP_LIGHTS_MAX := 32

# Map id of the structured map being loaded; keys Door.lock_key so session
# unlocks survive the full teardown/reload every warp performs.
var _current_map_id: String = ""

# Door gap endpoints (world px), collected before structures spawn: wall art
# slices normally overgrow +12px past their endpoints (covers bevel caps), but
# at a DOOR GAP that overgrow displays the overlay's baked closed-leaf pixels —
# a phantom "second door" that stays shut under the real swinging one.
var _door_ends: PackedVector2Array = PackedVector2Array()
# The ends of the door gaps no 4-neighbour tile step crosses (no tile column or
# row lands inside the gap), collected with _door_ends: a thin wall's seam
# crossing within half a tile of one stays open (_seam_tiles), so such a door
# never seals for A*.
var _seam_ends: PackedVector2Array = PackedVector2Array()
# _seam_tiles: a wall end this close to a seam end abuts that door gap, and two
# tile centres this close to equally near the wall block the first (up / left)
const DOOR_END_PX := 6.0
const SEAM_TIE_PX := 0.01

# Map mask colors to structure IDs
var color_to_structure: Dictionary = {
	Color8(0, 128, 0): "tree",      # dark green
	Color8(139, 69, 19): "wood_wall",    # brown
	Color8(255, 0, 0): "door_wood",      # red
	Color8(128, 128, 128): "stone_wall"
}

# Map mask colors to floor IDs from your FloorDatabase
var color_to_floor: Dictionary = {
	Color8(0, 255, 0): "grass",       # pure green
	Color8(139, 69, 19): "floor_dirt",       # brown
	Color8(128, 128, 128): "floor_stone",    # gray
	Color8(0, 0, 255): "water",        # blue
	Color8(192, 192, 192): "stone_stairs",   # light gray
}

# World-map terrain palette. The mask PNG should use these exact RGB values
# (anti-aliased pixels within color_tolerance still match):
#   (170, 220,  90) light green -> world_plains
#   ( 20, 100,  30) deep green  -> world_forest
#   (110,  85,  60) brown/gray  -> world_mountain
#   ( 40,  90, 200) blue        -> world_water
#   (220,  60,  40) red         -> world_city
#   (210, 180,  90) golden tan  -> world_farm
var color_to_world_floor: Dictionary = {
	Color8(170, 220, 90): "world_plains",
	Color8(20, 100, 30): "world_forest",
	Color8(110, 85, 60): "world_mountain",
	Color8(40, 90, 200): "world_water",
	Color8(220, 60, 40): "world_city",
	Color8(210, 180, 90): "world_farm",
}

# How close a pixel color must be to a key to match (accounts for anti-aliasing)
@export var color_tolerance: float = 0.15

var floor_scene: PackedScene = preload("res://Structures/floors/floor.tscn")

func _ready():
	# Don't auto-generate; Game.load_map() calls generate_map() after GridManager is initialized
	pass


# ---------------------------------------------------------------------------
# STRUCTURED FORMAT (procedural level-editor exports; "format": "structured"
# in Maps.json). The 4-PNG mask pipeline above exists for hand/LLM-made map
# images; procedural maps ship real data instead:
#   images.map          ONE finished ground PNG -- becomes a single full-map
#                       sprite (no per-tile floor sprites, no blended
#                       underlay: destroying a structure reveals this image)
#   images.structures   alpha overlay holding ONLY the structure art; each
#                       instance displays its own geometry-exact slice of it
#   floors              per-tile type codes (rows of chars, see FLOOR_CODES)
#                       -> logical GridManager floors (fire/pathing/audio)
#   structures          INSTANCE GEOMETRY: wall segments, tree circles, door
#                       leaves -- each becomes a Structure.tscn instance with
#                       an EXACT (rotated) collision shape and per-instance
#                       health, so the gap between two buildings is exactly
#                       as walkable as it looks. Pathing obstacles register
#                       only for tiles whose centre the geometry truly covers
#                       (the flood-fill loader's bounding boxes sealed gaps).
# ---------------------------------------------------------------------------

const FLOOR_CODES := {"g": "grass", "d": "floor_dirt", "s": "floor_stone", "p": "floor_wood", "w": "shallow_water"}

# GridManager.register_floor only reads .floor_id/.walkability; floors on
# structured maps are logical-only (their art is baked into the ground PNG).
class FloorStub:
	extends RefCounted
	var floor_id: String = ""
	var walkability: float = 1.0


func generate_structured_map(map_data: Dictionary) -> void:
	# MapLoader is Game's direct child (same resolution the legacy path uses);
	# the "game" group has no members, so a group lookup would silently return
	# null and kill fire/targeting/loot for every structure on the map
	var game = get_parent()
	if game == null or not ("structures_in_scene" in game):
		game = get_tree().current_scene
	_current_map_id = String(map_data.get("id", ""))
	var images: Dictionary = map_data.get("images", {})
	var tile_size: int = GridManager.TILE_SIZE

	# 1. ground: the finished editor render as one sprite (kept as structured_ground
	# so FluidManager/CellFluidFX can bind the organic water shader to it)
	structured_ground = null
	cliff_occluders = null
	map_lights = null
	var ground_path := String(images.get("map", ""))
	if ground_path != "" and ResourceLoader.exists(ground_path):
		var ground := Sprite2D.new()
		ground.texture = load(ground_path)
		ground.centered = false
		ground.z_index = -6
		add_child(ground)
		structured_ground = ground
	else:
		push_error("structured map: missing ground image " + ground_path)

	# 1b. roofs: the painted DF-style view-slice cover (exporter pass 3),
	# premult alpha exactly like the structures slice art. Spawned HIDDEN —
	# Game owns visibility through the view layer (roof_view), and a map load
	# must never flash roofs over the default ground view. Sits above
	# characters (z 5) and their overhead widgets (~115); light_mask 0 keeps
	# the additive sight-cone lights from painting the cover.
	var roofs_path := String(images.get("roofs", ""))
	if roofs_path != "" and ResourceLoader.exists(roofs_path):
		var roofs := Sprite2D.new()
		roofs.name = "RoofLayer"
		roofs.texture = load(roofs_path)
		roofs.centered = false
		roofs.z_as_relative = false
		roofs.z_index = 120
		roofs.light_mask = 0
		roofs.visible = false
		var rmat := CanvasItemMaterial.new()
		rmat.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
		roofs.material = rmat
		add_child(roofs)

	# 2. floors: logical registration from per-tile codes
	var rows: Array = map_data.get("floors", [])
	for ty in rows.size():
		var row := String(rows[ty])
		for tx in row.length():
			var fid := String(FLOOR_CODES.get(row[tx], ""))
			if fid == "":
				continue
			var stub := FloorStub.new()
			stub.floor_id = fid
			var fdata = FloorDatabase.floor_definitions.get(fid)
			if fdata != null and "walkability" in fdata:
				stub.walkability = maxf(0.05, float(fdata.walkability))
			GridManager.register_floor(Vector2i(tx, ty), stub)

	# 2b. solid rock: an interior whose rock is terrain (TG writes the entry key
	# for tg_hillside_cavern / _ossuary) — terrain at or above it rejects
	# walking, jump landings, spawns and teleports (GridManager.is_solid_rock).
	# No key: GridManager.initialize() left it INF, today's behaviour.
	var rock_elev = map_data.get("solid_rock_elev", null)
	if rock_elev is float or rock_elev is int:
		GridManager.solid_rock_elev = float(rock_elev)
	elif rock_elev != null:
		push_warning("map %s: solid_rock_elev must be a number (stories), got %s" % [_current_map_id, str(rock_elev)])

	# 3. structures: geometry instances with exact collision
	var overlay_tex: Texture2D = null
	var op := String(images.get("structures", ""))
	if op != "" and ResourceLoader.exists(op):
		overlay_tex = load(op)
	if game != null and "structures_in_scene" in game:
		game.structures_in_scene.clear()
	# TWO passes, decks (walk_elev) first: a solid structure's occlude_top is
	# terrain + height read at spawn time, so every deck must have registered
	# its elevation before any parapet standing on it spawns — regardless of
	# JSON array order.
	var all_structs: Array = map_data.get("structures", [])
	_door_ends = PackedVector2Array()
	_seam_ends = PackedVector2Array()
	for s in all_structs:
		if typeof(s) == TYPE_DICTIONARY and String(s.get("kind", "")) == "door":
			var dh := _arr_v2(s.get("hinge", [0, 0]))
			var dl := Vector2.RIGHT.rotated(deg_to_rad(float(s.get("deg", 0.0)))) * float(s.get("width", 30.0))
			_door_ends.append(dh)
			_door_ends.append(dh + dl)
			if not _has_lane(dh, dh + dl, tile_size):
				_seam_ends.append(dh)
				_seam_ends.append(dh + dl)
	for pass_decks in [true, false]:
		for s in all_structs:
			if typeof(s) != TYPE_DICTIONARY:
				continue
			var deck: bool = s.get("walk_elev") != null and String(s.get("kind", "")) in ["disc", "wall"]
			if deck != pass_decks:
				continue
			var inst := _spawn_geo_structure(s, overlay_tex, tile_size)
			if inst != null and game != null and "structures_in_scene" in game:
				game.structures_in_scene.append(inst)
				if inst.has_signal("destroyed") and game.has_method("_on_structure_destroyed"):
					inst.destroyed.connect(game._on_structure_destroyed)
	if GridManager.deck_lint_bad > 0:
		push_warning("structured map %s: %d deck tiles below terrain-0.05: structure walk_elev must be ABSOLUTE stories"
			% [_current_map_id, GridManager.deck_lint_bad])

	# 4. cliff shadows for the sight cones (relief maps only)
	if GridManager.relief_los:
		cliff_occluders = _build_cliff_occluders()

	# 5. authored light sources (export contract 2: forges, hearths, glow
	# blocks). No key: no map lights, today's behaviour. The ground PNG stays
	# unlit; these light it at runtime.
	var lv: Variant = map_data.get("lights")
	if lv is Array and not (lv as Array).is_empty():
		map_lights = _spawn_map_lights(lv)

	emit_signal("map_loaded")


## One PointLight2D per Maps.json "lights" row (docs/export_contract.md,
## P2-C): position [x, y] px, level 0..1 (the emits_light scale of
## EquipmentEffects.make_light), optional color [r, g, b] (absent = the fire
## colour), optional shadow (absent = true: the LIGHT_SHADOW_MASK shadows every
## item light casts). "source" is informational and never changes the look.
func _spawn_map_lights(rows: Array) -> Node2D:
	var root := Node2D.new()
	root.name = "MapLights"
	add_child(root)
	var n := 0
	for rv in rows:
		if not (rv is Dictionary):
			continue
		var row: Dictionary = rv
		var pv: Variant = row.get("position")
		var lev: Variant = row.get("level")
		if not (pv is Array) or (pv as Array).size() < 2 or not (lev is float or lev is int):
			push_warning("map %s: light row without position/level skipped: %s" % [_current_map_id, str(row)])
			continue
		if n >= MAP_LIGHTS_MAX:
			push_warning("map %s: %d light rows > %d; the rest are dropped" % [_current_map_id, rows.size(), MAP_LIGHTS_MAX])
			break
		var col: Variant = row.get("color")
		if EquipmentEffects.explicit_light_color(col) == null:
			col = EquipmentEffects.LIGHT_TRAIT_COLORS["fire"]
		var light: PointLight2D = EquipmentEffects.make_light(float(lev), {}, col)
		light.name = "MapLight%d" % n
		light.position = _arr_v2(pv)
		var sh: Variant = row.get("shadow", true)
		light.shadow_enabled = not (sh is bool) or bool(sh)
		var src: Variant = row.get("source")
		if src != null:
			light.set_meta("source", str(src))
		root.add_child(light)
		n += 1
	return root


func _spawn_geo_structure(s: Dictionary, overlay_tex: Texture2D, tile_size: int) -> Structure:
	var kind := String(s.get("kind", ""))
	var center: Vector2
	var shape: Shape2D
	var shape_rot := 0.0
	var door_leaf := Vector2.ZERO   # doors only: hinge -> free end (swing pivot)
	var poly_local := PackedVector2Array()
	var occ_poly := PackedVector2Array()   # exact silhouette for the vision-cone occluder
	var occupied: Array[Vector2i] = []
	var tight: Array[Vector2i] = []        # tiles the REAL geometry covers (fire gates)
	# pathing margin: a tile registers as an obstacle only if its CENTRE is
	# within this reach of the actual geometry (about a body-width)
	var path_margin := float(tile_size) * 0.35
	var wall_a := Vector2.ZERO             # walls only: for the terrain-following test
	var wall_b := Vector2.ZERO
	var wall_half := 0.0

	if kind == "wall":
		var a := _arr_v2(s.get("a", [0, 0]))
		var b := _arr_v2(s.get("b", [0, 0]))
		var half := float(s.get("half", 5.0))
		var seg := b - a
		if seg.length() < 2.0:
			return null
		wall_a = a
		wall_b = b
		wall_half = half
		center = (a + b) * 0.5
		var rect := RectangleShape2D.new()
		rect.size = Vector2(seg.length(), half * 2.0)
		shape = rect
		shape_rot = seg.angle()
		var dirn := seg.normalized()
		var perp := dirn.orthogonal()
		# generous art overgrow: wall ART extends past the collision geometry
		# (bevelled caps, castle BATTLEMENT merlons on tower rims) -- clipping
		# the slice at the quad leaves see-through notches where the ground
		# shows. Overlapping neighbour slices draw identical overlay pixels, so
		# the overlap is invisible.
		var g := half + 12.0
		# per-end overgrow: an end that abuts a DOOR GAP keeps a tight 1px lip —
		# the full +12 lip reached into the gap and displayed the overlay's
		# baked closed door leaf (phantom door under the real swung one)
		var g_a := g
		var g_b := g
		for de in _door_ends:
			if de.distance_to(a) < 6.0:
				g_a = 1.0
			if de.distance_to(b) < 6.0:
				g_b = 1.0
		poly_local = PackedVector2Array([
			-seg * 0.5 - dirn * g_a - perp * (half + g), seg * 0.5 + dirn * g_b - perp * (half + g),
			seg * 0.5 + dirn * g_b + perp * (half + g), -seg * 0.5 - dirn * g_a + perp * (half + g)])
		occ_poly = PackedVector2Array([
			-seg * 0.5 - perp * half, seg * 0.5 - perp * half,
			seg * 0.5 + perp * half, -seg * 0.5 + perp * half])
		occupied = _tiles_near_segment(a, b, half + path_margin, tile_size)
		# a thin wall on a tile boundary clears both centres: its seam tiles
		occupied.append_array(_seam_tiles(a, b, half + path_margin, occupied, tile_size))
		tight = _tiles_near_segment(a, b, half, tile_size)
	elif kind == "tree":
		center = _arr_v2(s.get("pos", [0, 0]))
		var r := float(s.get("r", 30.0))
		var circ := CircleShape2D.new()
		circ.radius = maxf(6.0, r * 0.45)   # trunk-scale: canopy overhang stays walkable
		shape = circ
		var rr := r + 4.0
		poly_local = PackedVector2Array([
			Vector2(-rr, -rr), Vector2(rr, -rr), Vector2(rr, rr), Vector2(-rr, rr)])
		# occluder = the TRUNK silhouette (matches what LOS rays hit), not the crown
		for i in 10:
			var ang := TAU * float(i) / 10.0
			occ_poly.append(Vector2(cos(ang), sin(ang)) * circ.radius)
		occupied = _tiles_near_segment(center, center, circ.radius + path_margin, tile_size)
		tight = _tiles_near_segment(center, center, circ.radius, tile_size)
	elif kind == "door":
		var hinge := _arr_v2(s.get("hinge", [0, 0]))
		var deg := float(s.get("deg", 0.0))
		var width := float(s.get("width", 30.0))
		var dhalf := float(s.get("half", 5.0))
		var leaf := Vector2.RIGHT.rotated(deg_to_rad(deg)) * width
		door_leaf = leaf
		center = hinge + leaf * 0.5
		var drect := RectangleShape2D.new()
		drect.size = Vector2(width, dhalf * 2.0)
		shape = drect
		shape_rot = leaf.angle()
		var ddir := leaf.normalized()
		var dperp := ddir.orthogonal()
		poly_local = PackedVector2Array([
			-leaf * 0.5 - dperp * (dhalf + 2.0), leaf * 0.5 - dperp * (dhalf + 2.0),
			leaf * 0.5 + dperp * (dhalf + 2.0), -leaf * 0.5 + dperp * (dhalf + 2.0)])
		occ_poly = PackedVector2Array([
			-leaf * 0.5 - dperp * dhalf, leaf * 0.5 - dperp * dhalf,
			leaf * 0.5 + dperp * dhalf, -leaf * 0.5 + dperp * dhalf])
		occupied = _tiles_near_segment(hinge, hinge + leaf, dhalf + path_margin, tile_size)
		tight = _tiles_near_segment(hinge, hinge + leaf, dhalf, tile_size)
	elif kind == "disc":
		# a solid fort-tower drum (exported wall_platform): full-radius stone, no
		# walkable interior. Covers the overlay drum art so no ground shows through.
		center = _arr_v2(s.get("pos", [0, 0]))
		var dr := float(s.get("r", 30.0))
		var dcirc := CircleShape2D.new()
		dcirc.radius = dr
		shape = dcirc
		var drr := dr + 6.0
		poly_local = PackedVector2Array([
			Vector2(-drr, -drr), Vector2(drr, -drr), Vector2(drr, drr), Vector2(-drr, drr)])
		for i in 16:
			var da := TAU * float(i) / 16.0
			occ_poly.append(Vector2(cos(da), sin(da)) * dr)
		occupied = _tiles_near_segment(center, center, dr + path_margin, tile_size)
		tight = _tiles_near_segment(center, center, dr, tile_size)
	else:
		return null

	# Walkable elevated deck (battlement walkway / tower top): "walk_elev" in
	# signed stories. occlude_top (ABSOLUTE stories) feeds elevation-aware LOS:
	# decks occlude up to their walking surface; solids occlude terrain + height.
	var walk_elev = s.get("walk_elev")
	var is_deck := walk_elev != null and (kind == "disc" or kind == "wall")
	var occlude_top: float
	# Occluding height in stories ABOVE LOCAL GROUND: optional "occlude_h"
	# (exporter: walls[].occlude_h), else wall/door 1 story, tree/solid disc 2.
	# Ignored on decks. Below eye height (0.5) the structure never blocks sight.
	# TG export contract 2 (P2-A) writes it on building walls (the building's
	# stories), curtain pieces (walk_h + merlon_h) and "hedge" tree rows (0.45:
	# see-over, still an obstacle). A tree row's "stories" (the crown top) is NOT
	# read here: the trunk keeps its 2 stories until P3-F's crown band.
	var occ_h: float = 2.0 if (kind == "tree" or kind == "disc") else 1.0
	var has_occ_h: bool = s.get("occlude_h") != null
	if has_occ_h:
		occ_h = float(s.get("occlude_h"))
	# Terrain-following wall (relief maps only): a long wall over a slope or a
	# pad edge gets its top re-based on the ground at each sight-ray crossing
	# (GridManager._sight_line_clear_relief) instead of one centre-based top.
	var follow := false
	if is_deck:
		occlude_top = float(walk_elev)   # a viewer AT deck height sees past the deck floor itself
	else:
		var base_elev := GridManager.effective_elev(GridManager.world_to_map(center))
		occlude_top = base_elev + occ_h
		if kind == "wall" and GridManager.relief_los:
			follow = _wall_spans_relief(wall_a, wall_b, wall_half)

	var inst: Structure = structure_scene.instantiate()
	if kind == "door":
		# safe: Structure.tscn root sets no exported values, and no properties
		# have been assigned yet — the swap loses nothing
		inst.set_script(DOOR_SCRIPT)
		inst.set("leaf", door_leaf)   # hinge->free-end vector: the visual swing pivot
	inst.structure_id = StringName(String(s.get("id", "stone_wall")))
	inst.skip_grid_snap = true
	inst.use_custom_texture = true
	inst.custom_texture = _blank_tex()   # the Sprite stays hidden; Art draws instead
	inst.custom_size = Vector2(8, 8)
	inst.position = center
	inst.z_index = -3
	inst.occupied_tiles = occupied
	inst.fire_blocking_tiles = tight   # fire gates use the REAL footprint, not the halo
	add_child(inst)
	# EXACT collision: rotated to the real geometry (the legacy loader's
	# axis-aligned region bounding boxes are what sealed walkable gaps)
	var cs: CollisionShape2D = inst.get_node("CollisionShape2D")
	cs.shape = shape
	cs.rotation = shape_rot
	inst.get_node("Sprite").visible = false
	# vision-cone occluder: the sight cones are PointLight2Ds with shadows, and
	# 2D light shadows come ONLY from LightOccluder2D -- physics bodies don't
	# cast them, so without this the cones render straight through walls even
	# though gameplay LOS rays are blocked correctly. Freed with the structure.
	if not occ_poly.is_empty():
		var occ := LightOccluder2D.new()
		occ.name = "Occluder"
		var opoly := OccluderPolygon2D.new()
		opoly.polygon = occ_poly
		opoly.cull_mode = OccluderPolygon2D.CULL_DISABLED
		occ.occluder = opoly
		occ.occluder_light_mask = CollisionLayers.SIGHT_MASK_GROUND
		if not is_deck and occlude_top >= 2.0:
			# tall solids + parapets-on-decks occlude elevated sight cones too;
			# deck occluders stay ground-mask only: they must never shadow the
			# cone of a light standing on them
			occ.occluder_light_mask |= CollisionLayers.SIGHT_MASK_HIGH
		if has_occ_h and not is_deck and occ_h < GridManager.EYE_HEIGHT_STORIES:
			occ.occluder_light_mask = 0   # waist-high parapet: no cone shadow at all
		elif GridManager.relief_los:
			# relief maps: cones there are GROUND | their elevation band, so the
			# structure must NOT carry bit 1 (it would shadow every cone). It
			# carries bit 2 for torches and other lights (LIGHT_SHADOW_MASK)
			# plus the bands it hides things from.
			var bands: int
			if is_deck:
				# half a story under the walkway: the deck mass still shadows
				# viewers below it, but never the pink (band + 1) cone of a
				# ground viewer, which has to light the walkway art, nor the
				# cone of a light standing on it
				bands = GridManager.band_mask_below(float(walk_elev) - GridManager.EYE_HEIGHT_STORIES)
			elif follow:
				bands = _add_follow_wall_band_chunks(inst, wall_a, wall_b, wall_half, occ_h)
			else:
				bands = GridManager.band_mask_below(occlude_top)
			occ.occluder_light_mask = CollisionLayers.SIGHT_MASK_HIGH | bands
		inst.add_child(occ)
	# "art_polys" (exporter, curtain walls + their towers): the instance's art is
	# an EXACT partition of the overlay -- body, plinth, cast shadow, foot AO --
	# instead of the +-(half+12) rectangle that clipped the shadow / towers and
	# streaked past the map edge. One Polygon2D named "Art" (damage tint /
	# hide / Door casts keep working) carrying every piece via `polygons`; an
	# empty list (a piece wholly off-map) builds no Art.
	var art_polys: Variant = s.get("art_polys")
	var has_art_polys: bool = art_polys is Array
	if has_art_polys and (art_polys as Array).is_empty():
		overlay_tex = null
	if overlay_tex != null:
		var art := Polygon2D.new()
		art.name = "Art"
		art.texture = overlay_tex
		var uvs := PackedVector2Array()
		if has_art_polys:
			var all_pts := PackedVector2Array()
			var groups: Array = []
			for ap in art_polys:
				var idx := PackedInt32Array()
				for v in ap:
					var pv := Vector2(float(v[0]), float(v[1]))
					idx.append(all_pts.size())
					all_pts.append(pv - center)
					uvs.append(pv)   # overlay covers the whole map 1:1 in pixels
				if idx.size() >= 3:
					groups.append(idx)
			art.polygon = all_pts
			art.polygons = groups
		else:
			art.polygon = poly_local
			for p in poly_local:
				uvs.append(p + center)   # overlay covers the whole map 1:1 in pixels
		art.uv = uvs
		# the overlay was rendered onto a transparent viewport, so its edge
		# pixels carry PREMULTIPLIED alpha -- straight-alpha blending would draw
		# dark fringes around every wall/crown edge
		var pm := CanvasItemMaterial.new()
		pm.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
		art.material = pm
		if is_deck:
			# walkway art: stealth mode's elevated-surface cone (a ground NPC
			# seeing someone standing up here) lights it as well as the
			# ordinary bit-1 lights
			art.light_mask = 1 | CollisionLayers.ELEVATED_SURFACE_LIGHT
		inst.add_child(art)
		# "art_under" (curtain pieces next to a tower): the piece's wall as it
		# runs on UNDER the tower, from the exporter's small atlas
		# ({image, parts: [{off, polys}]}, atlas px = map px + off). A child of
		# Art (hidden / freed with the piece); the tower spawns later, so its
		# art covers this while it stands, and a destroyed tower reveals wall
		# ends that match the piece's collision instead of bare ground.
		var under: Variant = s.get("art_under")
		if has_art_polys and under is Dictionary:
			var upath := String((under as Dictionary).get("image", ""))
			if upath != "" and ResourceLoader.exists(upath):
				var ua := Polygon2D.new()
				ua.name = "ArtUnder"
				ua.texture = load(upath)
				var upts := PackedVector2Array()
				var uuv := PackedVector2Array()
				var ugroups: Array = []
				for part in (under as Dictionary).get("parts", []):
					var off_a: Array = (part as Dictionary).get("off", [0, 0])
					var off := Vector2(float(off_a[0]), float(off_a[1]))
					for up in (part as Dictionary).get("polys", []):
						var uidx := PackedInt32Array()
						for uv_v in up:
							var upv := Vector2(float(uv_v[0]), float(uv_v[1]))
							uidx.append(upts.size())
							upts.append(upv - center)
							uuv.append(upv + off)
						if uidx.size() >= 3:
							ugroups.append(uidx)
				if not ugroups.is_empty():
					ua.polygon = upts
					ua.uv = uuv
					ua.polygons = ugroups
					ua.material = pm
					ua.show_behind_parent = true
					art.add_child(ua)
	# per-instance health: the editor scales wall hp by run length
	if s.has("hp"):
		inst.max_health = int(s["hp"])
		inst.current_health = inst.max_health
	if inst is Door:
		var door := inst as Door
		door.locked = bool(s.get("locked", false))
		door.key_id = String(s.get("key_id", ""))
		door.consume_key = bool(s.get("consume_key", false))
		var hpx := _arr_v2(s.get("hinge", [0, 0]))
		door.lock_key = "%s|door|%d,%d" % [_current_map_id, int(hpx.x), int(hpx.y)]
		# Session-unlock re-application: warps do a FULL load_map teardown; a
		# consumed key must not re-lock its door (softlock guard).
		var g: Node = get_parent()
		if g == null or not ("unlocked_locks" in g):
			g = get_tree().current_scene
		if g != null and ("unlocked_locks" in g) and g.unlocked_locks.has(door.lock_key):
			door.locked = false
		# pathability sync AFTER the lock fields land (add_child ran _ready
		# before `locked` was assigned — a locked door must not read pushable)
		door._sync_door_pass()
	inst.set_meta("occlude_top", occlude_top)
	if follow:
		inst.set_meta("occlude_rel_h", occ_h)
		inst.set_meta("occlude_half_px", wall_half)
	if is_deck:
		# No hard collision, no pathing obstacle: blocking ground characters is
		# purely logical via GridManager.can_step. Body stays on VISION_BLOCKERS
		# so ground LOS rays hit it (occlude_top = deck height hides its top).
		inst.collision_layer = CollisionLayers.VISION_BLOCKERS   # post-add_child, wins over _ready's STRUCTURE_LAYERS
		inst.is_deck = true
		inst.deck_elevation = float(walk_elev)
		inst.deck_tiles = tight   # TIGHT footprint — the walkable top is the real geometry, not the pathing halo
		for t in tight:
			GridManager.register_deck(t, float(walk_elev))
			# walk_elev is ABSOLUTE: a deck below its own terrain is an export
			# bug (a relative game_elev leaked through)
			if float(walk_elev) < GridManager.terrain_elev(t) - 0.05:
				GridManager.deck_lint_bad += 1
	else:
		for t in occupied:
			GridManager.register_obstacle(t)
	return inst


# True when the ground along a wall (sampled every 32px, just outside BOTH
# faces) varies by more than one walkable step: a wall climbing a slope, or a
# pad-edge wall with the street a story below. Not the `tight` tiles — a
# retaining-line wall sitting exactly on a tile boundary has an empty set.
# Any deck tile next to the wall vetoes (battlement parapets keep the deck rule).
#
# Each face is read twice: at the wall surface and half a tile further out.
# tile_elev is sampled at tile CENTRES, so a pad edge is only known to lie
# somewhere between two centres — a house wall can stand up to half a tile
# inside a street-valued tile and still bound the raised pad. The narrow
# sample alone (half + 2) only caught walls within ~9 px of the tile step.
# Off-map samples are skipped (absent tiles there would read as ground 0).
func _wall_spans_relief(a: Vector2, b: Vector2, half: float) -> bool:
	var seg := b - a
	var seg_len := seg.length()
	if seg_len < 0.001:
		return false
	var perp := (seg / seg_len).orthogonal()
	var off := perp * (half + 2.0)
	var off_wide := perp * (half + float(GridManager.TILE_SIZE) * 0.5 + 2.0)
	var n := maxi(1, int(ceil(seg_len / 32.0)))
	var lo := INF
	var hi := -INF
	for i in range(n + 1):
		var p := a + seg * (float(i) / float(n))
		var qs := PackedVector2Array([p - off, p + off, p - off_wide, p + off_wide])
		for k in qs.size():
			var t := GridManager.world_to_map(qs[k])
			if not GridManager.map_rect.has_point(t):
				continue
			if k < 2 and GridManager.deck_elevations.has(t):
				return false
			var g := GridManager.terrain_elev(t)
			lo = minf(lo, g)
			hi = maxf(hi, g)
	return hi - lo > GridManager.MAX_STEP_STORIES


# Cone band bits for a terrain-following wall (relief maps). Its sight-line
# top changes along its length (the higher face's ground + occ_h at each
# crossing, GridManager._wall_face_ground_max), so a single mask either lets
# street cones through a pad-edge house wall or shadows uphill viewers over
# its low end. Sampled every 32 px like _wall_spans_relief: the bits every
# sample shares are returned for the main Occluder; each run of samples that
# blocks MORE bands gets its own band-only occluder over that stretch.
func _add_follow_wall_band_chunks(inst: Node2D, a: Vector2, b: Vector2, half: float, occ_h: float) -> int:
	var seg := b - a
	var seg_len := seg.length()
	var dirn := seg / seg_len
	var perp := dirn.orthogonal()
	var n := maxi(1, int(ceil(seg_len / 32.0)))
	var masks: Array[int] = []
	var common := -1
	for i in range(n + 1):
		var p := a + seg * (float(i) / float(n))
		# a perpendicular ray hitting the -perp face at p
		var top: float = GridManager._wall_face_ground_max(p - perp * half, perp, half) + occ_h
		var m: int = GridManager.band_mask_below(top)
		masks.append(m)
		common &= m
	var step := seg_len / float(n)
	var local_a := a - inst.position
	var i0 := 0
	for i in range(1, n + 2):
		if i <= n and masks[i] == masks[i0]:
			continue
		var extra: int = masks[i0] & ~common
		if extra != 0:
			# samples i0..i-1 cover [s_i0 - step/2, s_(i-1) + step/2] along the wall
			var s0: float = maxf(0.0, (float(i0) - 0.5) * step)
			var s1: float = minf(seg_len, (float(i - 1) + 0.5) * step)
			var occ := LightOccluder2D.new()
			occ.name = "OccluderBand%d" % i0
			var opoly := OccluderPolygon2D.new()
			opoly.polygon = PackedVector2Array([
				local_a + dirn * s0 - perp * half, local_a + dirn * s1 - perp * half,
				local_a + dirn * s1 + perp * half, local_a + dirn * s0 + perp * half])
			opoly.cull_mode = OccluderPolygon2D.CULL_DISABLED
			occ.occluder = opoly
			occ.occluder_light_mask = extra
			inst.add_child(occ)
		i0 = i
	return common


# Relief maps: cliffs shadow sight cones. Open polyline occluders along every
# tile edge where the terrain jumps more than a walkable step, masked with the
# bands below the HIGH side (a viewer on the brow looks down unshadowed; one
# at the foot cannot see onto the terrace). No bit 1, so torches and other
# lights ignore them; sdf_collision off so particles don't collide with them.
# Collinear neighbouring edges with the same mask merge into one run. Built
# once per load: terrain never changes at runtime.
func _build_cliff_occluders() -> Node2D:
	var root := Node2D.new()
	root.name = "CliffOccluders"
	add_child(root)
	var ts := float(GridManager.TILE_SIZE)
	var cols: int = GridManager.map_rect.size.x
	var rows: int = GridManager.map_rect.size.y
	# vertical edges: tile (x-1, y) | (x, y), on the line x * ts
	for x in range(1, cols):
		var run_mask := 0
		var run0 := 0
		for y in range(rows + 1):
			var m: int = _cliff_mask(Vector2i(x - 1, y), Vector2i(x, y)) if y < rows else 0
			if m == run_mask:
				continue
			if run_mask != 0:
				_add_cliff_run(root, Vector2(x * ts, run0 * ts), Vector2(x * ts, y * ts), run_mask)
			run_mask = m
			run0 = y
	# horizontal edges: tile (x, y-1) over (x, y), on the line y * ts
	for y in range(1, rows):
		var run_mask := 0
		var run0 := 0
		for x in range(cols + 1):
			var m: int = _cliff_mask(Vector2i(x, y - 1), Vector2i(x, y)) if x < cols else 0
			if m == run_mask:
				continue
			if run_mask != 0:
				_add_cliff_run(root, Vector2(run0 * ts, y * ts), Vector2(x * ts, y * ts), run_mask)
			run_mask = m
			run0 = x
	return root


func _cliff_mask(t0: Vector2i, t1: Vector2i) -> int:
	var g0: float = GridManager.terrain_elev(t0)
	var g1: float = GridManager.terrain_elev(t1)
	if absf(g1 - g0) <= GridManager.MAX_STEP_STORIES:
		return 0
	return GridManager.band_mask_below(maxf(g0, g1))


func _add_cliff_run(root: Node2D, p0: Vector2, p1: Vector2, mask: int) -> void:
	var occ := LightOccluder2D.new()
	var opoly := OccluderPolygon2D.new()
	opoly.closed = false
	opoly.cull_mode = OccluderPolygon2D.CULL_DISABLED
	opoly.polygon = PackedVector2Array([p0, p1])
	occ.occluder = opoly
	occ.occluder_light_mask = mask
	occ.sdf_collision = false
	root.add_child(occ)


# Tiles whose CENTRE lies within `reach` of segment ab (a == b -> a disc).
func _tiles_near_segment(a: Vector2, b: Vector2, reach: float, tile_size: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var lo := Vector2(minf(a.x, b.x) - reach, minf(a.y, b.y) - reach)
	var hi := Vector2(maxf(a.x, b.x) + reach, maxf(a.y, b.y) + reach)
	var t0 := Vector2i(int(floor(lo.x / tile_size)), int(floor(lo.y / tile_size)))
	var t1 := Vector2i(int(floor(hi.x / tile_size)), int(floor(hi.y / tile_size)))
	var ab := b - a
	var l2 := ab.length_squared()
	for ty in range(t0.y, t1.y + 1):
		for tx in range(t0.x, t1.x + 1):
			var c := Vector2((tx + 0.5) * tile_size, (ty + 0.5) * tile_size)
			var q := a
			if l2 > 0.0001:
				q = a + ab * clampf((c - a).dot(ab) / l2, 0.0, 1.0)
			if c.distance_to(q) <= reach and GridManager.map_rect.has_point(Vector2i(tx, ty)):
				out.append(Vector2i(tx, ty))
	return out


# A wall whose obstacle reach is under half a tile can lie between two tile
# centres (on a tile boundary) and block neither, so A* would step straight
# through what physics blocks: the Perrow bank's hall/treasury partition (half
# 7 px, reach 29.4 < 32) let a path walk around the locked treasury door. For
# each 4-neighbour step across the seg with neither tile in `occ` (its reach
# tiles), block the tile whose centre is nearer the seg (the first, up / left,
# within SEAM_TIE_PX). A crossing within half a tile of a seg end at a lane-less
# door gap (_seam_ends) stays open: the body slides into the gap, and that door
# would otherwise seal. Mirrored by TG tools/grasslab/tg_model.py
# TileModel.seam_tiles in the same order (rows, columns, the right step first).
func _seam_tiles(a: Vector2, b: Vector2, reach: float, occ: Array[Vector2i], tile_size: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var ts := float(tile_size)
	if reach >= 0.5 * ts:
		return out   # one tile of every crossing step is already within reach
	var open_ends := PackedVector2Array()
	for p in PackedVector2Array([a, b]):
		for e in _seam_ends:
			if p.distance_to(e) < DOOR_END_PX:
				open_ends.append(p)
				break
	var taken := {}
	for t in occ:
		taken[t] = true
	for ty in range(int(floor(minf(a.y, b.y) / ts)) - 1, int(floor(maxf(a.y, b.y) / ts)) + 1):
		for tx in range(int(floor(minf(a.x, b.x) / ts)) - 1, int(floor(maxf(a.x, b.x) / ts)) + 1):
			var t := Vector2i(tx, ty)
			if not GridManager.map_rect.has_point(t):
				continue
			var ct := Vector2((tx + 0.5) * ts, (ty + 0.5) * ts)
			for k in 2:
				var n: Vector2i = t + (Vector2i(1, 0) if k == 0 else Vector2i(0, 1))
				if taken.has(t) or taken.has(n) or not GridManager.map_rect.has_point(n):
					continue
				var cn := Vector2((n.x + 0.5) * ts, (n.y + 0.5) * ts)
				var x := _seg_cross(ct, cn, a, b)
				if not x.is_finite():
					continue
				var beside_gap := false
				for p in open_ends:
					if x.distance_to(p) <= 0.5 * ts:
						beside_gap = true
				if beside_gap:
					continue
				var pick: Vector2i = n if _dist_point_seg(cn, a, b) < _dist_point_seg(ct, a, b) - SEAM_TIE_PX else t
				taken[pick] = true
				out.append(pick)
	return out


# True when some 4-neighbour step of on-map tiles properly crosses a-b.
func _has_lane(a: Vector2, b: Vector2, tile_size: int) -> bool:
	var ts := float(tile_size)
	for ty in range(int(floor(minf(a.y, b.y) / ts)) - 1, int(floor(maxf(a.y, b.y) / ts)) + 1):
		for tx in range(int(floor(minf(a.x, b.x) / ts)) - 1, int(floor(maxf(a.x, b.x) / ts)) + 1):
			if not GridManager.map_rect.has_point(Vector2i(tx, ty)):
				continue
			var ct := Vector2((tx + 0.5) * ts, (ty + 0.5) * ts)
			for k in 2:
				var d: Vector2i = Vector2i(1, 0) if k == 0 else Vector2i(0, 1)
				if GridManager.map_rect.has_point(Vector2i(tx, ty) + d) \
						and _seg_cross(ct, ct + Vector2(d) * ts, a, b).is_finite():
					return true
	return false


# Where segment p-q properly crosses segment a-b (touching at an end is no
# crossing), else Vector2.INF. TG tg_model.seg_cross, term for term.
static func _seg_cross(p: Vector2, q: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var rx: float = q.x - p.x
	var ry: float = q.y - p.y
	var sx: float = b.x - a.x
	var sy: float = b.y - a.y
	var den: float = rx * sy - ry * sx
	if absf(den) < 1e-6:
		return Vector2.INF
	var wx: float = a.x - p.x
	var wy: float = a.y - p.y
	var t: float = (wx * sy - wy * sx) / den
	var u: float = (wx * ry - wy * rx) / den
	if t <= 0.0 or t >= 1.0 or u <= 0.0 or u >= 1.0:
		return Vector2.INF
	return Vector2(p.x + rx * t, p.y + ry * t)


static func _dist_point_seg(c: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	var q := a
	if l2 > 0.0001:
		q = a + ab * clampf((c - a).dot(ab) / l2, 0.0, 1.0)
	return c.distance_to(q)


func _arr_v2(v) -> Vector2:
	if typeof(v) == TYPE_ARRAY and v.size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.ZERO


var _blank: ImageTexture

func _blank_tex() -> ImageTexture:
	if _blank == null:
		var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		_blank = ImageTexture.create_from_image(img)
	return _blank

func generate_map():
	if world_map_mode:
		_generate_world_map()
		return

	var tile_size = GridManager.TILE_SIZE

	var struct_map_img: Image = load(structure_map_image_path).get_image()
	var clean_map_img: Image = load(map_image_path).get_image()
	var floor_mask_img: Image = load(mask_image_path).get_image()
	var struct_mask_img: Image = load(structure_mask_path).get_image()

	var map_width = struct_map_img.get_width()
	var map_height = struct_map_img.get_height()

	# Build a structure occupancy mask so we know which pixels have structures
	var structure_mask: PackedByteArray = _build_structure_occupancy(struct_mask_img, map_width, map_height)

	# Create blended ground image: structures map everywhere, but blend in
	# the clean map underneath structure regions so that when structures
	# are destroyed the clean ground is revealed seamlessly
	var blended_ground: Image = _create_blended_ground(struct_map_img, clean_map_img, structure_mask, map_width, map_height)

	# --- Generate top ground layer (from structures map) ---
	var cols = map_width / tile_size
	var rows = map_height / tile_size

	for row in rows:
		for col in cols:
			var px = col * tile_size
			var py = row * tile_size
			var sample_x = px + tile_size / 2
			var sample_y = py + tile_size / 2
			var mask_color = floor_mask_img.get_pixel(sample_x, sample_y)
			var floor_id = match_color_to_floor(mask_color)
			if floor_id == "":
				continue

			# Top layer: sampled from the structures map
			var tile_rect = Rect2i(px, py, tile_size, tile_size)
			var tile_img = struct_map_img.get_region(tile_rect)
			var tile_tex = ImageTexture.create_from_image(tile_img)

			var floor_instance = floor_scene.instantiate()
			floor_instance.floor_id = floor_id
			floor_instance.use_custom_texture = true
			floor_instance.custom_texture = tile_tex
			floor_instance.skip_grid_snap = true
			floor_instance.position = Vector2(px + tile_size / 2, py + tile_size / 2)
			floor_instance.z_index = -4
			add_child(floor_instance)

			# Register floor with GridManager
			GridManager.register_floor(Vector2i(col, row), floor_instance)

			# Underneath layer: blended clean map (revealed when structures break)
			var under_img = blended_ground.get_region(tile_rect)
			var under_tex = ImageTexture.create_from_image(under_img)

			var under_floor = floor_scene.instantiate()
			under_floor.floor_id = floor_id
			under_floor.use_custom_texture = true
			under_floor.custom_texture = under_tex
			under_floor.skip_grid_snap = true
			under_floor.position = Vector2(px + tile_size / 2, py + tile_size / 2)
			under_floor.z_index = -6
			add_child(under_floor)

	# --- Generate structures ---
	_generate_structures(struct_map_img, struct_mask_img, map_width, map_height)

	emit_signal("map_loaded")

func _build_structure_occupancy(mask: Image, width: int, height: int) -> PackedByteArray:
	# Returns a byte array where 1 = this pixel is part of a structure
	var occupancy: PackedByteArray
	occupancy.resize(width * height)
	occupancy.fill(0)

	for y in height:
		for x in width:
			var color = mask.get_pixel(x, y)
			if color.a < 0.5:
				continue
			if match_color_to_structure(color) != "":
				occupancy[y * width + x] = 1

	return occupancy

func _create_blended_ground(struct_img: Image, clean_img: Image, structure_mask: PackedByteArray, width: int, height: int) -> Image:
	# Start with the clean (structureless) map as base
	var result: Image = clean_img.duplicate()

	# Build a distance field from structure edges into non-structure areas
	# so we can smoothly blend the two images at boundaries
	var distance_to_structure: PackedFloat32Array
	distance_to_structure.resize(width * height)
	distance_to_structure.fill(float(blend_margin + 1))

	# First pass: mark structure pixels as distance 0, and seed the BFS
	var queue: Array[Vector2i] = []
	for y in height:
		for x in width:
			if structure_mask[y * width + x] == 1:
				distance_to_structure[y * width + x] = 0.0
				# Only seed edge pixels (pixels adjacent to non-structure)
				if _has_non_structure_neighbor(x, y, width, height, structure_mask):
					queue.append(Vector2i(x, y))

	# BFS outward from structure edges
	var visited: PackedByteArray
	visited.resize(width * height)
	visited.fill(0)
	for pos in queue:
		visited[pos.y * width + pos.x] = 1

	var directions = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

	while queue.size() > 0:
		var pos = queue.pop_front()
		var current_dist = distance_to_structure[pos.y * width + pos.x]

		if current_dist >= blend_margin:
			continue

		for dir in directions:
			var nx = pos.x + dir.x
			var ny = pos.y + dir.y
			if nx < 0 or nx >= width or ny < 0 or ny >= height:
				continue
			var nidx = ny * width + nx
			if visited[nidx]:
				continue
			if structure_mask[nidx] == 1:
				continue

			var new_dist = current_dist + 1.0
			if new_dist < distance_to_structure[nidx]:
				distance_to_structure[nidx] = new_dist
				visited[nidx] = 1
				queue.append(Vector2i(nx, ny))

	# Now blend: in the margin zone around structures, lerp between
	# the structures map and the clean map
	for y in height:
		for x in width:
			var idx = y * width + x
			var dist = distance_to_structure[idx]

			if structure_mask[idx] == 1:
				# Under a structure: use clean map (this is the underneath layer)
				continue  # result is already clean_img
			elif dist < blend_margin:
				# In the blend zone: mix the two images
				var t = dist / float(blend_margin)  # 0 at edge, 1 at full distance
				var struct_color = struct_img.get_pixel(x, y)
				var clean_color = clean_img.get_pixel(x, y)
				var blended = clean_color.lerp(struct_color, 1.0 - t)
				result.set_pixel(x, y, blended)
			# else: far from structures, keep clean_img as-is

	return result

func _has_non_structure_neighbor(x: int, y: int, width: int, height: int, mask: PackedByteArray) -> bool:
	var directions = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for dir in directions:
		var nx = x + dir.x
		var ny = y + dir.y
		if nx < 0 or nx >= width or ny < 0 or ny >= height:
			continue
		if mask[ny * width + nx] == 0:
			return true
	return false

func _generate_structures(struct_img: Image, mask_img: Image, width: int, height: int):
	var tile_size = GridManager.TILE_SIZE
	var visited: PackedByteArray
	visited.resize(width * height)
	visited.fill(0)

	for y in height:
		for x in width:
			if visited[y * width + x]:
				continue
			var color = mask_img.get_pixel(x, y)
			if color.a < 0.5:
				continue
			var structure_id = match_color_to_structure(color)
			if structure_id == "":
				continue

			var region_pixels = flood_fill(mask_img, visited, x, y, color, width, height)
			if region_pixels.size() < 16:
				continue

			var min_x = width
			var min_y = height
			var max_x = 0
			var max_y = 0
			for pixel in region_pixels:
				min_x = min(min_x, pixel.x)
				min_y = min(min_y, pixel.y)
				max_x = max(max_x, pixel.x)
				max_y = max(max_y, pixel.y)

			var region_width = max_x - min_x + 1
			var region_height = max_y - min_y + 1
			var region_rect = Rect2i(min_x, min_y, region_width, region_height)
			var region_img = struct_img.get_region(region_rect)
			var region_tex = ImageTexture.create_from_image(region_img)

			var center_x = min_x + region_width / 2.0
			var center_y = min_y + region_height / 2.0

			var struct_instance = structure_scene.instantiate()
			struct_instance.structure_id = structure_id
			struct_instance.use_custom_texture = true
			struct_instance.custom_texture = region_tex
			struct_instance.custom_size = Vector2(region_width, region_height)
			struct_instance.skip_grid_snap = true
			struct_instance.position = Vector2(center_x, center_y)
			struct_instance.z_index = -3
			add_child(struct_instance)

			# Register with Game's structures_in_scene for fire/combat awareness
			var game = get_parent()
			if game and "structures_in_scene" in game:
				game.structures_in_scene.append(struct_instance)
				if struct_instance.has_signal("destroyed") and game.has_method("_on_structure_destroyed"):
					struct_instance.destroyed.connect(game._on_structure_destroyed)

			# Register all grid tiles this structure occupies as obstacles
			var tile_min_x = int(floor(float(min_x) / tile_size))
			var tile_min_y = int(floor(float(min_y) / tile_size))
			var tile_max_x = int(floor(float(max_x) / tile_size))
			var tile_max_y = int(floor(float(max_y) / tile_size))
			var occupied: Array[Vector2i] = []
			for ty in range(tile_min_y, tile_max_y + 1):
				for tx in range(tile_min_x, tile_max_x + 1):
					var tile_pos = Vector2i(tx, ty)
					GridManager.register_obstacle(tile_pos)
					occupied.append(tile_pos)
			struct_instance.occupied_tiles = occupied

func flood_fill(mask: Image, visited: PackedByteArray, start_x: int, start_y: int, target_color: Color, width: int, height: int) -> Array[Vector2i]:
	var pixels: Array[Vector2i] = []
	var stack: Array[Vector2i] = [Vector2i(start_x, start_y)]

	while stack.size() > 0:
		var pos = stack.pop_back()
		var idx = pos.y * width + pos.x

		if pos.x < 0 or pos.x >= width or pos.y < 0 or pos.y >= height:
			continue
		if visited[idx]:
			continue

		var pixel_color = mask.get_pixel(pos.x, pos.y)
		if color_distance(pixel_color, target_color) > color_tolerance:
			continue

		visited[idx] = 1
		pixels.append(pos)

		stack.append(Vector2i(pos.x + 1, pos.y))
		stack.append(Vector2i(pos.x - 1, pos.y))
		stack.append(Vector2i(pos.x, pos.y + 1))
		stack.append(Vector2i(pos.x, pos.y - 1))

	return pixels

func match_color_to_floor(color: Color) -> String:
	var best_match := ""
	var best_dist := color_tolerance
	for key_color in color_to_floor:
		var dist = color_distance(color, key_color)
		if dist < best_dist:
			best_dist = dist
			best_match = color_to_floor[key_color]
	return best_match

func match_color_to_structure(color: Color) -> String:
	var best_match := ""
	var best_dist := color_tolerance
	for key_color in color_to_structure:
		var dist = color_distance(color, key_color)
		if dist < best_dist:
			best_dist = dist
			best_match = color_to_structure[key_color]
	return best_match

func color_distance(a: Color, b: Color) -> float:
	return sqrt(
		pow(a.r - b.r, 2) +
		pow(a.g - b.g, 2) +
		pow(a.b - b.b, 2)
	)

# ---------------------------------------------------------------------------
# World-map generation
# ---------------------------------------------------------------------------
# The world-map pipeline skips structures entirely. Tile texture is sampled
# from the source map image. The mask defines terrain type per tile;
# world_mountain tiles register as impassable with GridManager. Unmapped
# terrain (alpha 0) falls back to world_plains so a fresh authoring pass
# doesn't leave gaps. If the mask file is missing the loader still renders
# the source image as a flat plain.
func _generate_world_map():
	# Sample source in `source_tile_size`-px blocks but render / position each
	# tile at `world_tile_size` world units. With world_render_scale = 1.5 the
	# rendered world is 1.5× as wide and tall as the source image.
	var source_tile_size: int = 64
	var world_tile_size: int = int(round(float(source_tile_size) * world_render_scale))
	if not ResourceLoader.exists(map_image_path):
		push_error("[MapLoader] World map source image not found: %s" % map_image_path)
		return
	var clean_map_img: Image = load(map_image_path).get_image()
	var map_width: int = clean_map_img.get_width()
	var map_height: int = clean_map_img.get_height()

	var has_mask: bool = ResourceLoader.exists(mask_image_path)
	var mask_img: Image
	if has_mask:
		mask_img = load(mask_image_path).get_image()
	else:
		push_warning("[MapLoader] World-map mask missing (%s) — defaulting all tiles to world_plains." % mask_image_path)

	var cols: int = map_width / source_tile_size
	var rows: int = map_height / source_tile_size

	for row in rows:
		for col in cols:
			var sample_px = col * source_tile_size
			var sample_py = row * source_tile_size
			var sample_x = sample_px + source_tile_size / 2
			var sample_y = sample_py + source_tile_size / 2

			var floor_id: String = "world_plains"
			if has_mask and sample_x < mask_img.get_width() and sample_y < mask_img.get_height():
				var mask_color: Color = mask_img.get_pixel(sample_x, sample_y)
				if mask_color.a >= 0.5:
					var matched := _match_world_floor(mask_color)
					if matched != "":
						floor_id = matched

			var tile_rect = Rect2i(sample_px, sample_py, source_tile_size, source_tile_size)
			var tile_img = clean_map_img.get_region(tile_rect)
			var tile_tex = ImageTexture.create_from_image(tile_img)

			var floor_instance = floor_scene.instantiate()
			floor_instance.floor_id = floor_id
			floor_instance.use_custom_texture = true
			floor_instance.custom_texture = tile_tex
			floor_instance.skip_grid_snap = true
			# Position and visually scale each tile so the world becomes
			# world_render_scale times bigger in world coordinates.
			var world_px = col * world_tile_size
			var world_py = row * world_tile_size
			floor_instance.position = Vector2(world_px + world_tile_size / 2, world_py + world_tile_size / 2)
			if world_render_scale != 1.0:
				floor_instance.scale = Vector2(world_render_scale, world_render_scale)
			floor_instance.z_index = -4
			add_child(floor_instance)

			var tile_pos = Vector2i(col, row)
			GridManager.register_floor(tile_pos, floor_instance)

			# Mountains are impassable: register as obstacle so pathfinding
			# avoids them and characters can't move through them.
			if floor_id == "world_mountain":
				GridManager.register_obstacle(tile_pos)

	emit_signal("map_loaded")

func _match_world_floor(color: Color) -> String:
	var best_match := ""
	var best_dist := color_tolerance
	for key_color in color_to_world_floor:
		var dist = color_distance(color, key_color)
		if dist < best_dist:
			best_dist = dist
			best_match = color_to_world_floor[key_color]
	return best_match
