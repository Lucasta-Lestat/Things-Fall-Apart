# res://Global/ExplorationManager.gd
# Autoload. Door Kickers-style "never seen" fog-of-war memory.
#
# Tracks, PER MAP, which tiles a party member has ever had in line of sight.
# The record survives map warps in memory (same autoload pattern as
# MapTriggerState): warp away and back and the rooms you cleared stay clear.
# Save/load integration is a follow-up; persisting `_maps` is enough to
# restore all explored state.
#
# Rendering is UnexploredFogLayer (vfx/unexplored_fog_layer.gd): it samples
# get_texture() (one L8 pixel per tile) and paints never-seen areas with a
# blue-grey filter. Game.load_map calls begin_map, Game._process drives sweep
# on the same unpaused gate as the party LOS sweeps — LOS cannot change during
# tactical pause, so neither can exploration.
#
# The reveal sweep mirrors Game._is_position_visible_to_party (sight range,
# FOV cone, GridManager.sight_line_clear with elevation) so the fog never
# disagrees with what NPC/item visibility says the party can see.
extends Node

const SWEEP_INTERVAL := 0.15        # seconds between sweeps (Game's accumulator)
const RAY_BUDGET_PER_SWEEP := 500   # cap on sight_line_clear casts per sweep
const REVEAL_FADE_TIME := 0.35      # seconds for a newly seen tile to fade in
# Ray endpoints pull back toward the viewer by this many tiles so a WALL tile
# is revealed by seeing its near face — a ray to the wall's own center always
# hits the wall and would leave every facade fog-tinted forever. A floor tile
# hiding BEHIND a wall still reads blocked: its pulled-back endpoint lands
# inside the wall tile, so the ray hits the occluder on the way in.
const WALL_REVEAL_PULLBACK_TILES := 0.55
# Party sight range in px per point of `sight` — same constant the LOS lights
# and _is_position_visible_to_party use.
const SIGHT_RANGE_PX := 1440.0
# Fade bytes are written onto the shader's ACTIVE smoothstep window
# (edge_lo 0.25 .. edge_hi 0.75 of unexplored_fog.gdshader): a linear 1..254
# ramp would spend the first quarter of REVEAL_FADE_TIME invisibly below
# edge_lo and the last quarter above edge_hi. 64 ~= 0.25 * 255.
const FADE_START_BYTE := 64
# Standing-still sweep memo granularity: facing changes smaller than one
# bucket (360/36 = 10 deg) don't force a re-test of blocked frontier tiles.
const FACING_BUCKETS := 36
# Fallback re-test cadence for occlusion changes nothing calls
# notify_occlusion_changed() for (walls burning down, future spell walls):
# a stationary party's fog frontier is stale for at most this long.
const OCCLUSION_RETEST_INTERVAL := 5.0

# map_id -> { "dims": Vector2i, "image": Image }. The Image (L8, one byte per
# tile: 0 = never seen, 255 = explored, 1..254 = fade-in) is stored BY
# REFERENCE, so _write_tile's set_pixelv mutations persist without any store-
# back. _bytes is a private working mirror for fast is-explored checks — a
# PackedByteArray is a copy-on-write VALUE in GDScript, so it must never be
# what the store holds (every write would re-copy the whole mask).
var _maps: Dictionary = {}

var current_map_id: String = ""
var active: bool = false
var _dims: Vector2i = Vector2i.ZERO
var _bytes: PackedByteArray = PackedByteArray()
var _image: Image = null
var _texture: ImageTexture = null
var _dirty: bool = false
var _fading: Dictionary = {}        # Vector2i -> float progress 0..1
var _sweep_start: int = 0           # round-robin so the ray budget rotates allies
# ally instance_id -> [origin_tile, facing_bucket, occlusion_epoch] of that
# ally's last COMPLETED (un-starved) sweep. Blocked tiles stay byte 0, so
# without this an unmoving ally re-raycasts every wall-shadowed tile in the
# cone at every sweep, forever — the budget saturates indoors.
var _sweep_memo: Dictionary = {}
var _occlusion_epoch: int = 0
var _retest_accum: float = 0.0
# int radius (tiles) -> Array[Vector2i] offsets sorted near-to-far, so a
# budget-starved sweep still reveals outward from the viewer's feet.
var _offsets_cache: Dictionary = {}


func _ready() -> void:
	# Tactical pause halts the whole tree, and Game (PROCESS_MODE_ALWAYS)
	# freezes the SWEEP itself while paused — correct, LOS cannot change. But
	# the fade-in and the dirty-texture upload for tiles revealed just before
	# the pause are cosmetic and must still land, or the player plans inside
	# fog covering an area a party member plainly sees. _process is inert
	# with no active fades and no dirty bytes, so ALWAYS is safe.
	process_mode = Node.PROCESS_MODE_ALWAYS


func begin_map(map_id: String, enable_fog: bool) -> void:
	"""Swap the active explored mask to `map_id`'s, restoring a stored mask
	when one exists with matching dimensions. Call AFTER GridManager.initialize
	(dims come from GridManager.map_rect). enable_fog=false (world maps,
	opted-out maps) deactivates tracking entirely for this map."""
	finalize_fades()
	current_map_id = map_id
	active = enable_fog
	_fading.clear()
	# Memos key on tiles: stale entries from another map would wrongly skip
	# allies standing on coincidentally-matching coordinates.
	_sweep_memo.clear()
	_sweep_start = 0
	if not active:
		_dims = Vector2i.ZERO
		_bytes = PackedByteArray()
		_image = null
		_texture = null
		return
	_dims = GridManager.map_rect.size
	if _dims.x <= 0 or _dims.y <= 0:
		active = false
		_image = null
		_texture = null
		_bytes = PackedByteArray()
		return
	var entry: Dictionary = _maps.get(map_id, {})
	var stored_dims: Vector2i = entry.get("dims", Vector2i.ZERO)
	if stored_dims == _dims and not entry.is_empty():
		_image = entry["image"]
		_bytes = _image.get_data()
	else:
		# New map, or dimensions changed since last visit (map re-authored):
		# start from nothing seen.
		_bytes = PackedByteArray()
		_bytes.resize(_dims.x * _dims.y)
		_image = Image.create_from_data(_dims.x, _dims.y, false, Image.FORMAT_L8, _bytes)
		_maps[map_id] = {"dims": _dims, "image": _image}
	_texture = ImageTexture.create_from_image(_image)
	_dirty = false


func get_texture() -> ImageTexture:
	return _texture


func is_explored(tile: Vector2i) -> bool:
	if not active or not _in_bounds(tile):
		return false
	return _bytes[tile.y * _dims.x + tile.x] > 0


func reveal_tile(tile: Vector2i) -> void:
	"""Mark a never-seen tile as seen and start its fade-in."""
	if not active or not _in_bounds(tile):
		return
	if _bytes[tile.y * _dims.x + tile.x] > 0:
		return
	_write_tile(tile, FADE_START_BYTE)
	_fading[tile] = 0.0


func seed_explored(tile: Vector2i, radius: int = 0) -> void:
	"""Instantly mark a tile (plus a tile radius around it) fully explored —
	no fade, no raycasts. Used for party spawn points: the party must never
	render inside its own fog while the first budgeted sweep waits for the
	new map's colliders to reach the physics space."""
	if not active:
		return
	for off in _offsets_for_radius(radius):
		var t: Vector2i = tile + off
		if _in_bounds(t):
			_fading.erase(t)
			_write_tile(t, 255)


func finalize_fades() -> void:
	"""Snap every in-progress fade to fully explored. Called on map change so a
	stored mask never holds a half-faded tile."""
	for tile in _fading:
		_write_tile(tile, 255)
	_fading.clear()


func clear_map(map_id: String) -> void:
	"""Drop explored state for one map (debug / new-game flow)."""
	_maps.erase(map_id)
	if map_id == current_map_id and active:
		_fading.clear()
		_bytes = PackedByteArray()
		_bytes.resize(_dims.x * _dims.y)
		_image = Image.create_from_data(_dims.x, _dims.y, false, Image.FORMAT_L8, _bytes)
		_maps[map_id] = {"dims": _dims, "image": _image}
		if _texture != null:
			_texture.update(_image)


func clear_all() -> void:
	_maps.clear()
	if active and _dims != Vector2i.ZERO:
		clear_map(current_map_id)


func notify_occlusion_changed() -> void:
	"""Vision-blocking geometry changed (a door opened or closed, a wall came
	down): invalidate every ally's standing-still sweep memo so the blocked
	frontier re-tests on the next sweep instead of waiting for the periodic
	OCCLUSION_RETEST_INTERVAL bump."""
	_occlusion_epoch += 1


func sweep(party_chars: Array, space: PhysicsDirectSpaceState2D) -> void:
	"""Reveal every never-seen tile currently inside a party member's sight:
	within range, inside the FOV cone, and on a clear sight line. Budgeted —
	at most RAY_BUDGET_PER_SWEEP raycasts per call, spent near-to-far, so the
	first sweep after spawning grows outward over a few calls instead of
	hitching one frame. Already-explored tiles cost no rays, so steady-state
	sweeps only pay for the frontier."""
	if not active or _image == null or space == null:
		return
	var budget: int = RAY_BUDGET_PER_SWEEP
	var ts: float = float(GridManager.TILE_SIZE)
	var count: int = party_chars.size()
	if count == 0:
		return
	# Hoisted + inlined bounds/byte checks below: this loop visits ~1,660
	# offsets per ally per sweep and a method call per offset dominates it.
	var dx: int = _dims.x
	var dy: int = _dims.y
	_sweep_start = (_sweep_start + 1) % count
	for i in range(count):
		if budget <= 0:
			return
		var ally = party_chars[(_sweep_start + i) % count]
		if not is_instance_valid(ally) or not ally.is_alive():
			continue
		var cm = ally.get_node_or_null("ConditionManager")
		if cm and (cm.has_condition("blinded") or cm.has_condition("unconscious")):
			continue
		var origin: Vector2 = ally.global_position
		var origin_tile: Vector2i = GridManager.world_to_map(origin)
		# Where you stand is always seen.
		reveal_tile(origin_tile)
		# Standing-still memo: blocked tiles stay byte 0, so an unchanged
		# viewpoint would re-raycast its whole wall-shadowed frontier every
		# sweep. Skip an ally whose tile, facing bucket, and occlusion epoch
		# match their last completed sweep; moving, turning past a bucket,
		# a door change, or the periodic epoch bump re-tests naturally.
		var facing_bucket: int = int(floor(float(ally.rotation) / (TAU / float(FACING_BUCKETS))))
		var iid: int = ally.get_instance_id()
		var memo: Array = _sweep_memo.get(iid, [])
		if memo.size() == 3 and memo[0] == origin_tile and memo[1] == facing_bucket \
				and int(memo[2]) == _occlusion_epoch:
			continue
		var sight_px: float = SIGHT_RANGE_PX * float(ally.sight)
		var radius_tiles: int = int(ceil(sight_px / ts))
		var facing: Vector2 = Vector2.UP.rotated(ally.rotation)
		var half_fov: float = deg_to_rad(float(ally.fov_angle_degrees) * 0.5)
		var viewer_elev: float = ally.get_elevation()
		var starved: bool = false
		for off in _offsets_for_radius(radius_tiles):
			var tile: Vector2i = origin_tile + off
			if tile.x < 0 or tile.y < 0 or tile.x >= dx or tile.y >= dy:
				continue
			if _bytes[tile.y * dx + tile.x] > 0:
				continue
			var center: Vector2 = GridManager.map_to_world(tile)
			var to_tile: Vector2 = center - origin
			var dist: float = to_tile.length()
			if dist > sight_px:
				continue
			if dist > 0.001:
				var dir: Vector2 = to_tile / dist
				if absf(facing.angle_to(dir)) > half_fov:
					continue
				if budget <= 0:
					starved = true
					break
				budget -= 1
				var target: Vector2 = center - dir * (ts * WALL_REVEAL_PULLBACK_TILES)
				# Deck-aware target height (a raised platform's SURFACE, not
				# the terrain under it), mirroring get_elevation() on the NPC
				# visibility path — fog and NPC LOS must agree on deck tiles.
				var target_elev: float = GridManager.effective_elev(tile)
				if GridManager.sight_line_clear(space, origin, target, viewer_elev, target_elev):
					reveal_tile(tile)
			else:
				reveal_tile(tile)
		if not starved:
			_sweep_memo[iid] = [origin_tile, facing_bucket, _occlusion_epoch]


func _process(delta: float) -> void:
	if not active:
		return
	# Fallback sweep-memo invalidation for occlusion changes with no explicit
	# notify_occlusion_changed() caller (walls burning down, spell effects).
	_retest_accum += delta
	if _retest_accum >= OCCLUSION_RETEST_INTERVAL:
		_retest_accum = 0.0
		_occlusion_epoch += 1
	if not _fading.is_empty():
		var done: Array = []
		for tile in _fading:
			var progress: float = float(_fading[tile]) + delta / REVEAL_FADE_TIME
			if progress >= 1.0:
				_write_tile(tile, 255)
				done.append(tile)
			else:
				_fading[tile] = progress
				# Remap onto the shader's visible [0.25, 0.75] smoothstep band
				# so the whole REVEAL_FADE_TIME is on-screen motion.
				_write_tile(tile, clampi(int((0.25 + 0.5 * progress) * 255.0), FADE_START_BYTE, 254))
		for tile in done:
			_fading.erase(tile)
	if _dirty and _texture != null:
		_texture.update(_image)
		_dirty = false


func _write_tile(tile: Vector2i, value: int) -> void:
	# Dual write: the Image is the persistent + rendered truth (shared by
	# reference with _maps and the ImageTexture), _bytes is the fast-read
	# mirror the sweep's hot loop checks.
	_bytes[tile.y * _dims.x + tile.x] = value
	if _image != null:
		_image.set_pixelv(tile, Color8(value, value, value))
	_dirty = true


func _in_bounds(tile: Vector2i) -> bool:
	return tile.x >= 0 and tile.y >= 0 and tile.x < _dims.x and tile.y < _dims.y


func _offsets_for_radius(radius: int) -> Array:
	if _offsets_cache.has(radius):
		return _offsets_cache[radius]
	var offs: Array = []
	for y in range(-radius, radius + 1):
		for x in range(-radius, radius + 1):
			if x * x + y * y <= radius * radius:
				offs.append(Vector2i(x, y))
	offs.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a.x * a.x + a.y * a.y) < (b.x * b.x + b.y * b.y))
	_offsets_cache[radius] = offs
	return offs
