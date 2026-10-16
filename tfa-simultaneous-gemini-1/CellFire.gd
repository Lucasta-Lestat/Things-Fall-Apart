# res://CellFire.gd
# Fire simulation on the CellGraph (Stalberg cells on structured maps; square
# tiles on legacy maps). This is the editor's FireSim ported BACK into TFA --
# the spread logic originated here, went to the editor for the Stalberg grid,
# and returns improved: probabilistic wind bias, fuel-scaled spread, jittered
# burn durations, organic cell fronts. It supersedes SurfaceManager's tile fire.
#
# STAGE 1 scope: cell-to-cell spread, structure damage, the "burning" condition
# on characters standing in fire, and native fire.tscn vfx per burning cell.
# Fire<->fluid interaction (water douse, oil flood-ignite) stays SurfaceManager's
# tile FluidManager for now and moves to the graph in stage 2 (fluids).
class_name CellFire
extends Node2D

var graph: CellGraph
var sm: Node                          # SurfaceManager (structure fire-tiles + game)
var _fire_def: Dictionary = {}

var burning: Dictionary = {}          # cid -> {t, t0, seed, char, vfx}
var burnt: PackedByteArray = PackedByteArray()
var native_particles := true          # false when CellFireFX draws the flames
                                      # AND the merged cluster lights (per-cell
                                      # fire.tscn is skipped entirely then)
var burn_rev := 0                     # bumped whenever the burning KEY SET
                                      # changes (ignite/douse/burnout) so
                                      # CellFireFX recomputes cluster lights
var scorch_fx: CellScorchFX = null    # persistent ground char (SurfaceManager wires it)

var sim_time := 0.0                   # seconds this fire has ticked. CellFireFX
                                      # animates its GPU flames off this clock, so
                                      # the flames freeze exactly when the sim does

var _spread_timer := 0.0
var _damage_timer := 0.0
var _rng := RandomNumberGenerator.new()
# Structure fuel index: tile -> FUEL_* flags and tile -> claiming structures.
# Rebuilt lazily (one O(fire tiles) sweep) after invalidate_fuel; every fuel
# query and the damage tick are then O(1) per tile. The old per-CELL cache was
# dropped by the fluid projection 4x/s and by every timber death, and each
# miss re-walked every structure's whole footprint -- a big fire spent
# 300-500 ms per damage tick in that scan.
const FUEL_BLOCKED := 1               # a non-flammable claimer (stone): firebreak
const FUEL_FLAMMABLE := 2             # a flammable claimer (timber/tree): heavy fuel
var _tile_index: Dictionary = {}      # Vector2i -> int flags
var _tile_structs: Dictionary = {}    # Vector2i -> Array of structures
var _index_dirty := true
var _game_ref: Node = null
var _cond_timers: Dictionary = {}     # character instance_id -> accumulated time
var _smoke_timer := 0.0
var _smoke_clouds: Array[FogOverlay] = []   # live plumes this fire owns
var _smoke_fog: FogManager = null           # cached so clear_all can reclaim them


func setup(p_graph: CellGraph, p_sm: Node, fire_def: Dictionary) -> void:
	graph = p_graph
	sm = p_sm
	_fire_def = fire_def
	burning.clear()
	_index_dirty = true
	_cond_timers.clear()
	sim_time = 0.0
	burnt = PackedByteArray()
	if graph != null:
		burnt.resize(graph.cell_count)


func active() -> bool:
	return graph != null and graph.cell_count > 0


# Structures changed (a wall/tree burned down, was destroyed, a door opened)
# -> the tile index is rebuilt on the next fuel query. Fluids are NOT indexed
# (read live per cell), so fluid motion never needs to call this.
func invalidate_fuel() -> void:
	_index_dirty = true


# --- ignition API (mirrors SurfaceManager's) --------------------------------

func ignite_area(center_world: Vector2, radius: float) -> int:
	if not active():
		return 0
	var n := 0
	# every cell whose centroid is in range (bucket-bounded, not a walk of the
	# whole 10-25k-cell graph per fireball)
	for cid in graph.cells_within(center_world, radius):
		if _try_ignite(cid):
			n += 1
	return n


func ignite_at(world_pos: Vector2) -> bool:
	if not active():
		return false
	var cid := graph.cell_at(world_pos)
	return _try_ignite(cid) if cid >= 0 else false


# Water arriving puts the cell's fire out (SurfaceManager.try_extinguish bridges
# the tile FluidManager to here until fluids move to the graph in stage 2).
# burnt is NOT set -- the cell can reignite once it dries, matching the source.
func douse_at(world_pos: Vector2) -> void:
	douse(graph.cell_at(world_pos) if active() else -1)


# Exact-cell douse (CellFluid calls this for the cell water actually sits in, so
# the water->fire bridge can't miss via a tile-center round-trip).
func douse(cid: int) -> void:
	if cid >= 0 and burning.has(cid):
		var vfx = burning[cid].get("vfx")
		if vfx and is_instance_valid(vfx):
			vfx.queue_free()
		burning.erase(cid)
		burn_rev += 1


# --- tick --------------------------------------------------------------------

func tick(delta: float, characters: Array, game: Node) -> void:
	if not active():
		return
	sim_time += delta
	if burning.is_empty():
		return
	_spread_timer += delta
	if _spread_timer >= float(_fire_def.get("spread_interval", 2.0)):
		_spread_timer = 0.0
		_spread(game)
	_damage_timer += delta
	if _damage_timer >= float(_fire_def.get("damage_interval", 1.0)):
		_damage_timer = 0.0
		_damage(game)
		_melt_ice()
	_lifetime(delta)
	_apply_burning(delta, characters)
	_smoke(delta, game)


func clear_all() -> void:
	for cid in burning:
		var vfx = burning[cid].get("vfx")
		if vfx and is_instance_valid(vfx):
			vfx.queue_free()
	burning.clear()
	burn_rev += 1
	_index_dirty = true
	_cond_timers.clear()
	_clear_smoke()
	burnt = PackedByteArray()
	if graph != null:
		burnt.resize(graph.cell_count)
	_spread_timer = 0.0
	_damage_timer = 0.0


# --- internals ---------------------------------------------------------------

func _try_ignite(cid: int) -> bool:
	if cid < 0 or burning.has(cid) or burnt[cid] == 1:
		return false
	if _fuel(cid) <= 0.0:
		return false
	_light(cid)
	return true


func _light(cid: int) -> void:
	var dur := float(_fire_def.get("base_duration", 10.0)) * _rng.randf_range(0.7, 1.3)
	var seed := _rng.randf()
	burning[cid] = {"t": dur, "t0": dur, "seed": seed, "char": 0.0, "vfx": _spawn_vfx(cid)}
	burn_rev += 1


func _spawn_vfx(cid: int) -> Node:
	# When CellFireFX draws the flames it also owns a few MERGED cluster lights;
	# a per-cell fire.tscn instance (one ~34px light per ~31px-spaced cell) read
	# as a lattice of little yellow circles, so cell maps skip the scene entirely.
	if not native_particles:
		return null
	var path := String(_fire_def.get("vfx_scene", ""))
	if path == "" or not ResourceLoader.exists(path):
		return null
	var scene = load(path)
	if scene == null:
		return null
	var vfx = scene.instantiate()
	vfx.global_position = graph.centroid(cid)
	# fire.tscn is authored for a 64px tile; scale it to the cell so a fine
	# Stalberg cell shows a proportionate flame and the field reads continuous
	var s := clampf(graph.radius(cid) / 32.0, 0.55, 1.5)
	vfx.scale = Vector2(s, s)
	add_child(vfx)
	if vfx.has_method("play"):
		vfx.play(1.0)
	return vfx


# TFA _process_spread with the probabilistic wind bias (see the port note).
func _spread(game: Node) -> void:
	var wind := _wind()
	var windy := wind.length() > 0.01
	var chance := float(_fire_def.get("spread_chance", 0.4))
	var to_ignite: Array = []
	for cid in burning:
		var cc := graph.centroid(cid)
		for nb in graph.neighbors(cid):
			if burning.has(nb) or burnt[nb] == 1:
				continue
			var fuel := _fuel(nb)
			if fuel <= 0.0:
				continue
			var wk := 1.0
			if windy:
				var d := (graph.centroid(nb) - cc).normalized()
				wk = clampf(1.0 + d.dot(wind), 0.15, 2.2)
			if _rng.randf() < chance * fuel * wk:
				to_ignite.append(nb)
	for cid in to_ignite:
		_try_ignite(cid)


# Fire damages every structure whose fire-footprint covers a burning cell's
# centroid tile (stone just outlasts the flames). A death refreshes the fuel map.
func _damage(game: Node) -> void:
	if game == null or not ("structures_in_scene" in game):
		return
	var dmg: Dictionary = _fire_def.get("damage_per_tick", {"fire": 10})
	# tiles that fire touches: each burning cell's tile PLUS its 4-neighbourhood,
	# so fire ADJACENT to a structure (a stone wall never ignites, so no burning
	# cell ever sits on its own tile) still damages it -- TFA damages every
	# structure fire reaches, stone just outlasts it.
	var burning_tiles := {}
	for cid in burning:
		var t := _tile_of(cid)
		burning_tiles[t] = true
		burning_tiles[t + Vector2i(1, 0)] = true
		burning_tiles[t + Vector2i(-1, 0)] = true
		burning_tiles[t + Vector2i(0, 1)] = true
		burning_tiles[t + Vector2i(0, -1)] = true
	# tile -> claimers index: O(burning tiles), not O(structures x footprint)
	_ensure_index()
	var hit := {}   # structure -> true, deduped this tick
	for t in burning_tiles:
		var claimers = _tile_structs.get(t)
		if claimers == null:
			continue
		for structure in claimers:
			if is_instance_valid(structure):
				hit[structure] = true
	var any_dead := false
	for structure in hit:
		if not is_instance_valid(structure):
			continue
		structure.take_damage(dmg.duplicate(), 0)
		if not is_instance_valid(structure) or structure.current_health <= 0:
			any_dead = true
	if any_dead:
		_index_dirty = true
	# fire consumes the flammable fluid (oil) it burns on, so slicks deplete and
	# eventually go out instead of the fuel reading 2.5 forever (fuel reads the
	# fluid live, so nothing to invalidate)
	var cf = _cell_fluid()
	if cf != null and cf.active_sim():
		for cid in burning:
			if cf.is_flammable_at(cid):
				cf.burn_off(cid, 0.06)
	else:
		# legacy maps keep the flat tile fluid sim (no cell_fluid): burn the oil
		# off the tile under each burning cell, at the tile fire's rate
		var fm = _tile_fluids()
		if fm != null:
			var rate := float(_fire_def.get("fluid_consume_rate", 0.05))
			for cid in burning:
				var t := _tile_of(cid)
				if fm.is_fluid_flammable(t):
					fm.remove_fluid(t, rate)
	# progressive ground char, ported from the editor's FireSim._damage: each
	# damage tick deepens the cell's char and restamps -- fully black after ~5
	# ticks, so ground blackens WHILE it burns, not just at burnout
	if scorch_fx != null and is_instance_valid(scorch_fx):
		for cid in burning:
			var bd: Dictionary = burning[cid]
			bd["char"] = minf(float(bd.get("char", 0.0)) + 0.22, 1.0)
			scorch_fx.stamp(cid, bd["char"], float(bd["seed"]))


# Fire melts ice. Ice is a TILE surface (SurfaceManager.surface_grid) even on
# cell-fire maps -- freezing DRAINS the cells under the tile, so no burning cell
# ever sits "in" ice and neither _fuel nor CellFluid._fire_interactions
# can see it. Melting is therefore driven by ADJACENCY: every tile the flames
# reach (a burning cell's tile plus its 4-neighbourhood -- the same footprint
# _damage uses for structures, since cells are ~half a tile) takes one melt
# tick, and SurfaceManager thaws the ice back into its frozen fluid once enough
# heat has accumulated.
func _melt_ice() -> void:
	if sm == null or not sm.has_method("apply_heat_to_ice"):
		return
	var melt: float = float(_fire_def.get("ice_melt_per_tick", 0.34))
	if melt <= 0.0:
		return
	var touched: Dictionary = {}
	for cid in burning:
		var t := _tile_of(cid)
		touched[t] = true
		touched[t + Vector2i(1, 0)] = true
		touched[t + Vector2i(-1, 0)] = true
		touched[t + Vector2i(0, 1)] = true
		touched[t + Vector2i(0, -1)] = true
	for tile in touched:
		sm.apply_heat_to_ice(tile, melt)


func _lifetime(delta: float) -> void:
	var out: Array = []
	for cid in burning:
		var bd: Dictionary = burning[cid]
		bd["t"] = float(bd["t"]) - delta
		if float(bd["t"]) <= 0.0:
			out.append(cid)
	for cid in out:
		burnt[cid] = 1
		# final full-depth char stamp on burnout (editor _lifetime emits k=1.0)
		if scorch_fx != null and is_instance_valid(scorch_fx):
			scorch_fx.stamp(cid, 1.0, float(burning[cid]["seed"]))
		# Legacy square-graph maps draw real Floor nodes at z -4, over the char
		# layer (-5), so a burnt-out tile would look untouched while it can
		# never burn again. Scorch the floor itself there, as tile fire did.
		if graph._square:
			_scorch_tile_floor(cid)
		var vfx = burning[cid].get("vfx")
		if vfx and is_instance_valid(vfx):
			vfx.queue_free()
		burning.erase(cid)
	if not out.is_empty():
		burn_rev += 1


# SurfaceManager's ash shader on every Floor node of the cell's tile (none on
# tiles without floors, where the char layer already shows).
func _scorch_tile_floor(cid: int) -> void:
	if sm == null or not sm.has_method("_scorch_floor"):
		return
	var sc: Array = _fire_def.get("scorch_color", [0.15, 0.12, 0.1, 1.0])
	sm._scorch_floor(_tile_of(cid), Color(sc[0], sc[1], sc[2], sc[3]), _game())


# Apply the "burning" condition to characters whose cell is on fire.
func _apply_burning(delta: float, characters: Array) -> void:
	var cond := String(_fire_def.get("condition_id", "burning"))
	if cond == "":
		return
	var interval := float(_fire_def.get("apply_interval", 1.0))
	var stacks := int(_fire_def.get("condition_stacks", 1))
	for character in characters:
		if not is_instance_valid(character):
			continue
		if character.has_method("is_alive") and not character.is_alive():
			continue
		# Fire burns at ground level. A roof-walker's world position sits inside
		# the burning footprint cell, but they are two stories up and out of
		# reach of the flames below — don't set them alight through the roof.
		if "on_roof" in character and character.on_roof:
			continue
		var cid: int = graph.cell_at(character.global_position)
		if cid < 0 or not burning.has(cid):
			continue
		var key: int = character.get_instance_id()
		_cond_timers[key] = float(_cond_timers.get(key, 0.0)) + delta
		if _cond_timers[key] < interval:
			continue
		_cond_timers[key] = 0.0
		var mgr = character.get_node_or_null("ConditionManager")
		if mgr == null and character.has_method("get_condition_manager"):
			mgr = character.get_condition_manager()
		if mgr:
			mgr.apply_condition(cond, null, stacks)


# --- smoke ---------------------------------------------------------------------

# REAL smoke: burning cells feed the game's cloud system (FogManager ->
# FogOverlay, the same persistent volume cloud_kill and the map's ambient fogs
# use) instead of only the cosmetic wisps CellFireFX draws. One
# cloud per burning cell per tick would be hundreds of overlapping full-rect fbm
# shaders, so emission is throttled four ways: a fixed interval, coarse spatial
# bucketing (one plume per SMOKE_BUCKET-sized patch of fire), a per-tick plume
# budget, and a hard cap on how many of this fire's clouds may live at once.
# Plume SIZE/opacity carry the intensity instead -- a hotter, oilier, denser
# patch of fire makes ONE bigger, thicker plume, not more of them.
const SMOKE_BUCKET := 160.0      # world px: one plume per bucket of burning cells
const SMOKE_MAX_LIVE := 8        # concurrent FogOverlays this fire may own
const SMOKE_MAX_PER_EMIT := 2    # new plumes per emission tick
const SMOKE_SIZE_K := 1.2        # rect upsize: the cloud shader no longer fills it
const SMOKE_RISE := 9.0          # px/s the plume body climbs (screen -Y)
const SMOKE_WIND := 26.0         # px/s of downwind travel at full wind


func _smoke(delta: float, game: Node) -> void:
	var interval := float(_fire_def.get("smoke_interval", 1.5))
	if interval <= 0.0:
		return                      # smoke_interval 0 in surfaces.json disables it
	_smoke_timer += delta
	if _smoke_timer < interval:
		return
	_smoke_timer = 0.0
	_emit_smoke(game)


func _emit_smoke(game: Node) -> void:
	if game == null or not ("fog_manager" in game):
		return
	var fog: FogManager = game.fog_manager
	if fog == null or not is_instance_valid(fog):
		return
	_smoke_fog = fog
	# prune: FogManager frees expired overlays (and clear_all_fog frees them all
	# on map load) behind our back, so validate before counting against the cap
	var live: Array[FogOverlay] = []
	for c in _smoke_clouds:
		if is_instance_valid(c):
			live.append(c)
	_smoke_clouds = live
	var budget: int = mini(SMOKE_MAX_PER_EMIT, SMOKE_MAX_LIVE - _smoke_clouds.size())
	if budget <= 0:
		return
	# bucket the burning cells so one plume stands for a whole patch of fire
	var buckets: Dictionary = {}
	for cid in burning:
		var p: Vector2 = graph.centroid(cid)
		var key := Vector2i(floori(p.x / SMOKE_BUCKET), floori(p.y / SMOKE_BUCKET))
		var bk: Dictionary = buckets.get(key, {"n": 0, "sum": Vector2.ZERO, "k": 0.0})
		var bd: Dictionary = burning[cid]
		var t0: float = maxf(float(bd["t0"]), 0.01)
		var frac: float = clampf((t0 - float(bd["t"])) / t0, 0.0, 1.0)
		var acc: Vector2 = bk["sum"]
		bk["n"] = int(bk["n"]) + 1
		bk["sum"] = acc + p
		# intensity: a cell smokes hardest mid-burn (sin arch: flare-up, sustain,
		# die down) and heavy fuel -- oil 2.5, timber 1.25 -- smokes more than grass
		bk["k"] = float(bk["k"]) + minf(_fuel(cid), 2.5) * (0.35 + 0.65 * sin(frac * PI))
		buckets[key] = bk
	if buckets.is_empty():
		return
	var patches: Array = []
	for key in buckets:
		patches.append(buckets[key])
	# jittered intensity sort: the fiercest patches usually smoke first, but a
	# small outlying patch still gets its turn instead of being starved forever
	for i in patches.size():
		var pw: Dictionary = patches[i]
		pw["w"] = float(pw["k"]) * _rng.randf_range(0.55, 1.45)
	patches.sort_custom(func(x, y): return float(x["w"]) > float(y["w"]))
	var wind := _wind()
	var drift := Vector2(0.0, -SMOKE_RISE) + wind * SMOKE_WIND
	var base_dur := float(_fire_def.get("smoke_duration", 9.0))
	var cond_min := int(_fire_def.get("smoke_condition_min_cells", 4))
	var emitted := 0
	for patch in patches:
		if emitted >= budget:
			break
		var pd: Dictionary = patch
		var n: int = int(pd["n"])
		var k: float = float(pd["k"])
		var sum_pos: Vector2 = pd["sum"]
		var center: Vector2 = sum_pos / float(n)
		# fog.gdshader fades a cloud out by its rect's INSCRIBED circle and then
		# noise-erodes that boundary inward (~0.84 of it on average), so the plume
		# no longer fills its rect corner to corner the way the old hard-clipped
		# square did. SMOKE_SIZE_K restores the apparent width that cost us.
		var side: float = clampf(96.0 + 46.0 * sqrt(k), 96.0, 288.0) * SMOKE_SIZE_K
		var dur: float = base_dur * _rng.randf_range(0.8, 1.25)
		# only a real body of fire makes air unbreathable; a lone smouldering cell
		# is scenery, not a hazard
		var cond := ""
		if n >= cond_min:
			cond = String(_fire_def.get("smoke_condition", "suffocating"))
		# NOTE: the Vector2 below is the shader's UV scroll (internal churn), NOT
		# travel -- travel is FogOverlay.drift, set just after.
		var cloud: FogOverlay = _smoke_fog.create_cloud(
			Color(0.17, 0.16, 0.15, clampf(0.30 + 0.05 * k, 0.30, 0.62)),
			Vector2(side, side),
			dur,
			cond,
			1,
			-2.0,
			2.0,
			clampf(0.45 + 0.06 * k, 0.45, 0.8),
			3.0,
			Vector2(0.05, 0.03),
			center + Vector2(0.0, -side * 0.15),
			null)
		if cloud == null:
			continue
		cloud.drift = drift
		cloud.set_fade_envelope(1.0, minf(3.5, dur * 0.5))
		_smoke_clouds.append(cloud)
		emitted += 1


func _clear_smoke() -> void:
	if _smoke_fog != null and is_instance_valid(_smoke_fog):
		for c in _smoke_clouds:
			if is_instance_valid(c):
				_smoke_fog.remove_fog(c)
	_smoke_clouds.clear()
	_smoke_timer = 0.0


# Cell fuel: non-flammable structure -> firebreak; flammable structure -> heavy
# fuel; else standing fluid (oil = fuel, water = break); else the graph's
# static ground fuel. Every layer is an O(1) lookup, so nothing is cached per
# cell -- the structure index is the only derived state (see invalidate_fuel).
func _fuel(cid: int) -> float:
	_ensure_index()
	var flags := int(_tile_index.get(_tile_of(cid), 0))
	# ANY flammable claimer wins over a co-located stone one, matching
	# SurfaceManager._is_tile_flammable's contract (the index ORs all claimers)
	if flags & FUEL_FLAMMABLE:
		return 1.25                                            # timber/tree: heavy fuel
	if flags & FUEL_BLOCKED:
		return 0.0                                             # stone: firebreak
	# cell fluids: standing OIL is heavy fuel (a spark takes the slick), any
	# other fluid (water) is a firebreak. Structures already decided above.
	var cf = _cell_fluid()
	if cf != null and cf.active_sim():
		if cf.is_flammable_at(cid):
			return 2.5
		if cf.amount_at(cid) > 0.01:
			return 0.0
	else:
		# legacy maps (square graph, no cell_fluid): the same rule, read live
		# from the flat tile fluid sim -- an oil slick there is fuel too
		var fm = _tile_fluids()
		if fm != null:
			var t := _tile_of(cid)
			if fm.is_fluid_flammable(t):
				return 2.5
			if fm.get_fluid_type_at(t) != "":
				return 0.0
	return graph.ground_fuel(cid)


# One sweep over every structure's fire footprint -> per-tile flags + claimer
# lists. Runs only after invalidate_fuel (structure death / destruction / a
# door opening), never per query.
func _ensure_index() -> void:
	if not _index_dirty:
		return
	_index_dirty = false
	_tile_index.clear()
	_tile_structs.clear()
	var game := _game()
	if game == null or not ("structures_in_scene" in game):
		return
	for structure in game.structures_in_scene:
		if not is_instance_valid(structure):
			continue
		var flag := FUEL_FLAMMABLE if structure.flammable else FUEL_BLOCKED
		for ft in sm._fire_tiles_of(structure):
			_tile_index[ft] = int(_tile_index.get(ft, 0)) | flag
			var claimers = _tile_structs.get(ft)
			if claimers == null:
				claimers = []
				_tile_structs[ft] = claimers
			claimers.append(structure)


func _game() -> Node:
	if _game_ref != null and is_instance_valid(_game_ref):
		return _game_ref
	_game_ref = sm._get_game() if sm != null and sm.has_method("_get_game") else null
	return _game_ref


func _cell_fluid():
	var game := _game()
	if game == null or not ("fluid_manager" in game) or game.fluid_manager == null:
		return null
	return game.fluid_manager.cell_fluid


# The flat tile FluidManager, for legacy maps where cell_fluid is null.
func _tile_fluids():
	var game := _game()
	if game == null or not ("fluid_manager" in game):
		return null
	return game.fluid_manager


func _wind() -> Vector2:
	# soft wind from the map's weather (no weather -> no bias, uniform spread)
	if not sm.has_method("_get_map_weather_group"):
		return Vector2.ZERO
	var grp = sm._get_map_weather_group(sm._get_game() if sm.has_method("_get_game") else null)
	if typeof(grp) != TYPE_STRING or grp == "":
		return Vector2.ZERO
	var dir: Vector2 = WeatherManager.get_wind_direction(grp)
	var spd: float = WeatherManager.get_wind_speed(grp)
	if dir.length() < 0.01 or spd <= 0.0:
		return Vector2.ZERO
	return dir.normalized() * clampf(spd / 15.0, 0.0, 1.0)


func _tile_of(cid: int) -> Vector2i:
	return GridManager.world_to_map(graph.centroid(cid))
