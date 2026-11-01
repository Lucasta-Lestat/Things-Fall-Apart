# res://Global/CanopyMap.gd
# Tree crowns as a gameplay layer (P3-F, decision 7: crowns HIDE characters).
# Owned by GridManager (GridManager.canopy: one instance for the session,
# emptied per map by clear() in GridManager.initialize, so a crown_changed
# listener connects once and a cached reference stays live across warps).
# MapLoader._spawn_geo_structure registers every
# concealing "tree" row as it spawns the trunk, from the same row: pos, r, the
# crown top "stories" and the optional contract-3 "crown_base". Hedges (id
# "hedge", occlude_h 0.45: see-over) and crowns whose top is not above their
# trunk clearance (dead snags, 0.72 stories) hide nothing and are never added.
#
# A crown is the disc of radius r MINUS its trunk (MapLoader's trunk-scale
# collider, max(6, 0.45 r): the overhang is walkable, the trunk is not), from
# ground + base (the trunk clearance, 1 story) up to ground + top. Overlapping
# discs form one CLUSTER (a grove, a garden walk under joined crowns).
#
# Queries, all O(1) per character per check (one tile bucket, then exact disc
# tests against the few crowns over that tile; no allocation):
#   crown_at(p, feet)   the live crown hiding a point, or -1 (the target side)
#   cluster_at(p)       its cluster id, or -1
#   canopy_cover(t)     per tile: the cluster over the tile centre, or -1
#   crown(i)            the per-tree record (pos, r, stories, alive, cluster):
#                       P3-B's CanopyLayer and P4-D's cover read it, so the
#                       rules and the visuals agree
#   above_clearance(i, viewer_elev)  an eye above the crown's trunk clearance
#   looks_down_on(i, viewer_elev, target_feet)  a viewer a story or more above
#                       a target under crown i, its eye over the clearance
#   eye_line_in_crown(i, ...)  the eye line goes into crown i's disc through
#                       the leaves, not under them
#   line_blocked(...)   the crown sight band (a sight line through a crown),
#                       a tile walk along the line
#   blocks_view(...)    THE full block: a crown over the target seen from above
#                       (a roof or a deck a story up: looks_down_on; a viewer
#                       on relief terrain: that and eye_line_in_crown), or
#                       line_blocked (visibility_to, the AI's hold rule, the
#                       crime position's witnesses)
# A burnt or felled tree (its Structure's destroyed signal) stops hiding at
# once: alive goes false, the clusters are rebuilt, crown_changed fires.
# The sight cones don't draw any of this (no crown occluder, no band bit: the
# 1-story bands can't hold a 1.0-1.3 story crown band), so a cone still lights
# ground a crown hides; cone shading under crowns is left to P3-B.
extends RefCounted

## A crown died (burnt down, felled): its index. CanopyLayer drops its art.
signal crown_changed(index: int)

## Trunk clearance in stories above the tree's ground, for rows without the
## contract-3 "crown_base" key.
const CROWN_BASE_DEFAULT := 1.0
## Crown top for rows without "stories" (contract 1): the 2 stories MapLoader's
## tree occluder has always assumed.
const CROWN_TOP_DEFAULT := 2.0

# Per crown, by registration order (MapLoader's spawn order).
var _pos: PackedVector2Array = PackedVector2Array()
var _r: PackedFloat32Array = PackedFloat32Array()
var _trunk_r: PackedFloat32Array = PackedFloat32Array()
var _ground: PackedFloat32Array = PackedFloat32Array()   # ABSOLUTE stories under the tree
var _base: PackedFloat32Array = PackedFloat32Array()     # trunk clearance, stories above _ground
var _top: PackedFloat32Array = PackedFloat32Array()      # crown top ("stories"), stories above _ground
var _alive: PackedByteArray = PackedByteArray()
var _cluster: PackedInt32Array = PackedInt32Array()      # -1 once dead
var _by_structure: Dictionary = {}                       # Structure instance id -> crown index

# Tile buckets over GridManager.map_rect (CSR): the crowns whose disc touches
# each tile, so a point query reads one tile's short list.
var _cols: int = 0
var _rows: int = 0
var _tile_start: PackedInt32Array = PackedInt32Array()
var _tile_items: PackedInt32Array = PackedInt32Array()
# Overlapping crown pairs (i, j flattened), for re-clustering after a death.
var _pairs: PackedInt32Array = PackedInt32Array()
# Eye-line quick reject for line_blocked: the lowest live crown base and the
# highest live crown top (ABSOLUTE stories).
var _min_base_abs: float = INF
var _max_top_abs: float = -INF
var _dirty: bool = false


## Empties the model for the next map (GridManager.initialize). The same
## instance carries on, so crown_changed's listeners stay connected; a
## crown index from the previous map means nothing after this.
func clear() -> void:
	_pos = PackedVector2Array()
	_r = PackedFloat32Array()
	_trunk_r = PackedFloat32Array()
	_ground = PackedFloat32Array()
	_base = PackedFloat32Array()
	_top = PackedFloat32Array()
	_alive = PackedByteArray()
	_cluster = PackedInt32Array()
	_by_structure.clear()
	_cols = 0
	_rows = 0
	_tile_start = PackedInt32Array()
	_tile_items = PackedInt32Array()
	_pairs = PackedInt32Array()
	_min_base_abs = INF
	_max_top_abs = -INF
	_dirty = false


## Registers one concealing crown. `ground` is the ABSOLUTE terrain height at
## the tree (stories); `base` and `top` are stories above it. Returns its index.
func add_crown(pos: Vector2, r: float, trunk_r: float, ground: float, base: float, top: float, structure: Object = null) -> int:
	var i: int = _pos.size()
	_pos.append(pos)
	_r.append(r)
	_trunk_r.append(trunk_r)
	_ground.append(ground)
	_base.append(base)
	_top.append(top)
	_alive.append(1)
	_cluster.append(i)
	if structure != null:
		_by_structure[structure.get_instance_id()] = i
	_dirty = true
	return i


## Builds the tile buckets and the clusters. MapLoader calls it once the map's
## structures have spawned; any query does it first if a crown was added since.
func finish() -> void:
	_dirty = false
	_cols = GridManager.map_rect.size.x
	_rows = GridManager.map_rect.size.y
	var n: int = _pos.size()
	var ntiles: int = _cols * _rows
	# Pass 1 counts each tile's crowns, pass 2 fills them in (CSR).
	var per_crown: Array = []
	var counts := PackedInt32Array()
	counts.resize(ntiles)
	counts.fill(0)
	for i in range(n):
		var tiles: PackedInt32Array = _crown_tiles(i)
		per_crown.append(tiles)
		for k in tiles:
			counts[k] += 1
	_tile_start = PackedInt32Array()
	_tile_start.resize(ntiles + 1)
	var acc: int = 0
	for k in range(ntiles):
		_tile_start[k] = acc
		acc += counts[k]
	_tile_start[ntiles] = acc
	_tile_items = PackedInt32Array()
	_tile_items.resize(acc)
	var cursor: PackedInt32Array = _tile_start.duplicate()
	for i in range(n):
		for k in (per_crown[i] as PackedInt32Array):
			_tile_items[cursor[k]] = i
			cursor[k] += 1
	# Overlapping pairs, found through the buckets (a crown only meets the
	# crowns that share a tile with it).
	_pairs = PackedInt32Array()
	var seen: Dictionary = {}
	for k in range(ntiles):
		var a1: int = _tile_start[k + 1]
		for ia in range(_tile_start[k], a1):
			for ib in range(ia + 1, a1):
				var i: int = mini(_tile_items[ia], _tile_items[ib])
				var j: int = maxi(_tile_items[ia], _tile_items[ib])
				var key: int = i * n + j
				if seen.has(key):
					continue
				seen[key] = true
				if _pos[i].distance_squared_to(_pos[j]) < (_r[i] + _r[j]) * (_r[i] + _r[j]):
					_pairs.append(i)
					_pairs.append(j)
	_rebuild_clusters()


# The tiles (row-major indices) whose square crown i's disc touches.
func _crown_tiles(i: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var ts: float = float(GridManager.TILE_SIZE)
	var p: Vector2 = _pos[i]
	var r: float = _r[i]
	var x0: int = maxi(0, floori((p.x - r) / ts))
	var x1: int = mini(_cols - 1, floori((p.x + r) / ts))
	var y0: int = maxi(0, floori((p.y - r) / ts))
	var y1: int = mini(_rows - 1, floori((p.y + r) / ts))
	for ty in range(y0, y1 + 1):
		for tx in range(x0, x1 + 1):
			var qx: float = clampf(p.x, float(tx) * ts, float(tx + 1) * ts)
			var qy: float = clampf(p.y, float(ty) * ts, float(ty + 1) * ts)
			if (qx - p.x) * (qx - p.x) + (qy - p.y) * (qy - p.y) <= r * r:
				out.append(ty * _cols + tx)
	return out


func _ensure() -> void:
	if _dirty:
		finish()


# Union-find over the live crowns; a cluster's id is its lowest crown index.
func _rebuild_clusters() -> void:
	var n: int = _pos.size()
	var parent := PackedInt32Array()
	parent.resize(n)
	for i in range(n):
		parent[i] = i
	for e in range(0, _pairs.size(), 2):
		var a: int = _pairs[e]
		var b: int = _pairs[e + 1]
		if _alive[a] == 0 or _alive[b] == 0:
			continue
		var ra: int = _find(parent, a)
		var rb: int = _find(parent, b)
		if ra != rb:
			parent[maxi(ra, rb)] = mini(ra, rb)
	_min_base_abs = INF
	_max_top_abs = -INF
	for i in range(n):
		if _alive[i] == 0:
			_cluster[i] = -1
			continue
		_cluster[i] = _find(parent, i)
		_min_base_abs = minf(_min_base_abs, _ground[i] + _base[i])
		_max_top_abs = maxf(_max_top_abs, _ground[i] + _top[i])


static func _find(parent: PackedInt32Array, i: int) -> int:
	var x: int = i
	while parent[x] != x:
		x = parent[x]
	return x


## The tree's Structure was destroyed (felled, burnt down): its crown stops
## hiding at once. MapLoader connects it to Structure.destroyed.
func on_tree_destroyed(structure: Object, _grid_position: Variant = null) -> void:
	if structure == null:
		return
	kill_crown(int(_by_structure.get(structure.get_instance_id(), -1)))


func kill_crown(i: int) -> void:
	if i < 0 or i >= _pos.size() or _alive[i] == 0:
		return
	_ensure()
	_alive[i] = 0
	_rebuild_clusters()
	crown_changed.emit(i)


# --- queries ---------------------------------------------------------------

func crown_count() -> int:
	return _pos.size()

## The per-tree record: pos (px), r (crown radius px), trunk_r (px), ground
## (ABSOLUTE stories), base (trunk clearance) and stories (crown top), both
## stories above ground, alive, and cluster (-1 once dead). {} out of range.
func crown(i: int) -> Dictionary:
	if i < 0 or i >= _pos.size():
		return {}
	_ensure()
	return {"pos": _pos[i], "r": _r[i], "trunk_r": _trunk_r[i], "ground": _ground[i],
		"base": _base[i], "stories": _top[i], "alive": _alive[i] == 1, "cluster": _cluster[i]}

## The crown index of a tree Structure, or -1 (not a concealing tree).
func crown_of(structure: Object) -> int:
	if structure == null:
		return -1
	return int(_by_structure.get(structure.get_instance_id(), -1))

func cluster_of(i: int) -> int:
	if i < 0 or i >= _pos.size():
		return -1
	_ensure()
	return _cluster[i]

## The live crown hiding point `p`: inside its disc, outside its trunk, and
## (when `feet` is given, ABSOLUTE stories) not standing above its top. -1
## when none. The lowest index wins where crowns overlap (same cluster).
func crown_at(p: Vector2, feet: float = NAN) -> int:
	if _pos.is_empty():
		return -1
	_ensure()
	var ts: float = float(GridManager.TILE_SIZE)
	var tx: int = floori(p.x / ts)
	var ty: int = floori(p.y / ts)
	if tx < 0 or ty < 0 or tx >= _cols or ty >= _rows:
		return -1
	var k: int = ty * _cols + tx
	for a in range(_tile_start[k], _tile_start[k + 1]):
		var i: int = _tile_items[a]
		if _covers(i, p, feet):
			return i
	return -1

# Crown i hides point `p`: alive, inside its disc, outside its trunk, and
# (`feet` given) not standing above its top.
func _covers(i: int, p: Vector2, feet: float) -> bool:
	if _alive[i] == 0:
		return false
	var d2: float = p.distance_squared_to(_pos[i])
	if d2 > _r[i] * _r[i] or d2 <= _trunk_r[i] * _trunk_r[i]:
		return false
	return is_nan(feet) or feet < _ground[i] + _top[i]

## The cluster over point `p` (crown_at's), or -1.
func cluster_at(p: Vector2, feet: float = NAN) -> int:
	var i: int = crown_at(p, feet)
	return _cluster[i] if i >= 0 else -1

## Per tile: the cluster of a live crown over the tile CENTRE, or -1.
func canopy_cover(t: Vector2i) -> int:
	return cluster_at(GridManager.map_to_world(t))

## True when an eye standing at `viewer_elev` (ABSOLUTE stories) is above
## crown i's trunk clearance (its ground + base). Alone this is NOT "looking
## down on" the crown: on a slope the flat clearance sits below the eyes of
## anyone on the crown's uphill overhang, the target's own included
## (looks_down_on adds the height over the target).
func above_clearance(i: int, viewer_elev: float) -> bool:
	return viewer_elev + GridManager.EYE_HEIGHT_STORIES > _ground[i] + _base[i]

## True when an eye at `viewer_elev` looks DOWN on crown i over a target
## whose feet are at `target_feet` (both ABSOLUTE stories): the eye is above
## the crown's trunk clearance AND the viewer stands at least
## GridManager.HIGH_LAYER_STORIES above the target. A viewer at the target's
## own level, uphill overhang or not, sees along beneath the crown and is a
## ground observer (the 0.5 factor). From a roof or a deck this alone is
## decision 7's "crowns fully block sight from roofs and decks"; a viewer on
## relief terrain (a slope, a cliff top) is blocked only when its eye line
## also goes in through the leaves (eye_line_in_crown, blocks_view).
func looks_down_on(i: int, viewer_elev: float, target_feet: float) -> bool:
	return above_clearance(i, viewer_elev) and viewer_elev - target_feet >= GridManager.HIGH_LAYER_STORIES

## True when the eye line from an eye at (from_pos, viewer_elev) to the eye
## of a target at (to_pos, target_elev) -- sight_line_clear's relief model,
## the eye height interpolated along the chord -- goes into crown i's disc at
## or above its trunk clearance and meets its band on the way to the target:
## it enters through the leaves, not under them. A viewer inside the disc
## (over the crown's top, on a cliff above it) looks straight down: entry is
## its own eye. Elevations are ABSOLUTE stories.
func eye_line_in_crown(i: int, from_pos: Vector2, viewer_elev: float, to_pos: Vector2, target_elev: float) -> bool:
	if i < 0 or i >= _pos.size():
		return false
	var h0: float = viewer_elev + GridManager.EYE_HEIGHT_STORIES
	var h1: float = target_elev + GridManager.EYE_HEIGHT_STORIES
	var c: Vector2 = _pos[i]
	var r2: float = _r[i] * _r[i]
	var t_in: float = 0.0
	if from_pos.distance_squared_to(c) > r2:
		var d: Vector2 = to_pos - from_pos
		var len2: float = d.length_squared()
		if len2 < 1e-6:
			return false
		var f: Vector2 = from_pos - c
		var b: float = f.dot(d)
		var disc: float = b * b - len2 * (f.length_squared() - r2)
		if disc <= 0.0:
			return false   # the line misses the disc (the target is not under it)
		t_in = clampf((-b - sqrt(disc)) / len2, 0.0, 1.0)
	var entry: float = lerpf(h0, h1, t_in)
	return entry >= _ground[i] + _base[i] and minf(entry, h1) <= _ground[i] + _top[i]

## THE full block, positional: true when a live crown cuts the view from an
## eye at (viewer_pos, viewer_elev) to a point at (target_pos, target_elev).
## Either the point is under a crown the viewer looks down on (looks_down_on;
## a viewer under the same crown cluster is beneath it too and is spared), or
## the line runs through a crown between them at crown height (line_blocked).
## Looking down: from a raised surface (`viewer_raised`, below) that is
## enough, as on a flat map; a viewer on relief terrain is a ground observer
## unless its eye line also goes in through the leaves (eye_line_in_crown): a
## steep look over a cliff edge is blocked, a gentle slope a story up whose
## line runs in under the crown is not. Every live crown over the point is
## asked, not crown_at's lowest index alone: where a grove's discs overlap,
## the line can run in under one crown and through another's leaves, and
## line_blocked skips every crown over an end.
## viewer_raised: 1 = on a raised surface (on a roof, or a deck
## HIGH_LAYER_STORIES or more above its terrain: GridManager.is_high_layer),
## 0 = on terrain or a low deck, -1 = judge it from viewer_elev against the
## terrain under viewer_pos.
## The rest of the canopy (the 0.5 factor, its exemptions within 2 tiles plus
## the observer's body radius and under the same cluster, reveal(), party and
## corpse exemptions) is the character's:
## ProceduralCharacter.visibility_to / canopy_hides_from. CrimeManager's
## crime-position test asks this directly. Elevations are ABSOLUTE stories;
## NAN = the ground or deck under that point.
func blocks_view(viewer_pos: Vector2, viewer_elev: float, target_pos: Vector2, target_elev: float, viewer_raised: int = -1) -> bool:
	if _pos.is_empty():
		return false
	_ensure()
	if is_nan(viewer_elev):
		viewer_elev = GridManager.effective_elev(GridManager.world_to_map(viewer_pos))
	if is_nan(target_elev):
		target_elev = GridManager.effective_elev(GridManager.world_to_map(target_pos))
	var ts: float = float(GridManager.TILE_SIZE)
	var tx: int = floori(target_pos.x / ts)
	var ty: int = floori(target_pos.y / ts)
	if tx >= 0 and ty >= 0 and tx < _cols and ty < _rows:
		var k: int = ty * _cols + tx
		var judged: bool = false   # the viewer's cluster and surface, read once
		for a in range(_tile_start[k], _tile_start[k + 1]):
			var i: int = _tile_items[a]
			if not _covers(i, target_pos, target_elev) or not looks_down_on(i, viewer_elev, target_elev):
				continue
			if not judged:
				judged = true
				# The crowns over one point overlap there: one cluster. A viewer
				# under it is beneath them all.
				if cluster_at(viewer_pos, viewer_elev) == _cluster[i]:
					break
				var raised: bool = viewer_raised == 1
				if viewer_raised < 0:
					raised = GridManager.height_above_ground(GridManager.world_to_map(viewer_pos), viewer_elev) >= GridManager.HIGH_LAYER_STORIES
				if raised or not GridManager.relief_los:
					return true
			if eye_line_in_crown(i, viewer_pos, viewer_elev, target_pos, target_elev):
				return true
	return line_blocked(viewer_pos, target_pos, viewer_elev, target_elev)

## The crown sight band: true when the sight line from_pos -> to_pos runs
## through a live crown between them at a height inside the crown (trunk
## clearance up to the top). The eye model is sight_line_clear's: flat maps
## take max(viewer, target) + eye for the whole line, relief maps interpolate
## it along the chord. Ground-to-ground lines pass under every crown. Crowns
## over either end are not "between" (blocks_view's looks_down_on judges the
## target's; a viewer under a crown sees out from under it). Elevations are
## ABSOLUTE stories; NAN = the ground or deck under that point.
func line_blocked(from_pos: Vector2, to_pos: Vector2, viewer_elev: float = NAN, target_elev: float = NAN) -> bool:
	if _pos.is_empty():
		return false
	_ensure()
	if is_nan(viewer_elev):
		viewer_elev = GridManager.effective_elev(GridManager.world_to_map(from_pos))
	if is_nan(target_elev):
		target_elev = GridManager.effective_elev(GridManager.world_to_map(to_pos))
	var h0: float = viewer_elev + GridManager.EYE_HEIGHT_STORIES
	var h1: float = target_elev + GridManager.EYE_HEIGHT_STORIES
	if not GridManager.relief_los:
		h0 = maxf(h0, h1)
		h1 = h0
	if maxf(h0, h1) < _min_base_abs or minf(h0, h1) > _max_top_abs:
		return false   # the whole line runs under every crown, or over every one
	var d: Vector2 = to_pos - from_pos
	var len2: float = d.length_squared()
	if len2 < 1e-6:
		return false
	# Tile walk (Amanatides-Woo, as GridManager.terrain_line_hit) over every
	# tile the segment crosses; each tile's crowns are tested exactly.
	var ts: float = float(GridManager.TILE_SIZE)
	var cx: int = floori(from_pos.x / ts)
	var cy: int = floori(from_pos.y / ts)
	var ex: int = floori(to_pos.x / ts)
	var ey: int = floori(to_pos.y / ts)
	var sx: int = 1 if d.x > 0.0 else -1
	var sy: int = 1 if d.y > 0.0 else -1
	var tmx: float = INF
	var tdx: float = INF
	var tmy: float = INF
	var tdy: float = INF
	if absf(d.x) > 1e-6:
		tmx = ((float(cx) + (1.0 if sx > 0 else 0.0)) * ts - from_pos.x) / d.x
		tdx = ts / absf(d.x)
	if absf(d.y) > 1e-6:
		tmy = ((float(cy) + (1.0 if sy > 0 else 0.0)) * ts - from_pos.y) / d.y
		tdy = ts / absf(d.y)
	for _g in range(2 * (absi(ex - cx) + absi(ey - cy)) + 4):
		if cx >= 0 and cy >= 0 and cx < _cols and cy < _rows:
			var k: int = cy * _cols + cx
			for a in range(_tile_start[k], _tile_start[k + 1]):
				if _crown_blocks(_tile_items[a], from_pos, d, len2, h0, h1):
					return true
		if (cx == ex and cy == ey) or minf(tmx, tmy) >= 1.0:
			return false
		if tmx < tmy:
			cx += sx
			tmx += tdx
		else:
			cy += sy
			tmy += tdy
	return false


# Crown i against the segment from_pos + d * t (t in 0..1): the eye heights
# over the chord inside its disc overlap its band.
func _crown_blocks(i: int, from_pos: Vector2, d: Vector2, len2: float, h0: float, h1: float) -> bool:
	if _alive[i] == 0:
		return false
	var c: Vector2 = _pos[i]
	var r2: float = _r[i] * _r[i]
	if from_pos.distance_squared_to(c) <= r2 or (from_pos + d).distance_squared_to(c) <= r2:
		return false   # an end under this crown: not between them
	var f: Vector2 = from_pos - c
	var b: float = f.dot(d)
	var disc: float = b * b - len2 * (f.length_squared() - r2)
	if disc <= 0.0:
		return false
	var sq: float = sqrt(disc)
	var t_in: float = (-b - sq) / len2
	var t_out: float = (-b + sq) / len2
	if t_out <= 0.0 or t_in >= 1.0:
		return false
	var ea: float = lerpf(h0, h1, clampf(t_in, 0.0, 1.0))
	var eb: float = lerpf(h0, h1, clampf(t_out, 0.0, 1.0))
	return maxf(ea, eb) >= _ground[i] + _base[i] and minf(ea, eb) <= _ground[i] + _top[i]
