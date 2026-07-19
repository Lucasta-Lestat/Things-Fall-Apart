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

var burning: Dictionary = {}          # cid -> {t, t0, seed, vfx}
var burnt: PackedByteArray = PackedByteArray()

var _spread_timer := 0.0
var _damage_timer := 0.0
var _rng := RandomNumberGenerator.new()
var _fuel_cache: Dictionary = {}
var _cond_timers: Dictionary = {}     # character instance_id -> accumulated time


func setup(p_graph: CellGraph, p_sm: Node, fire_def: Dictionary) -> void:
	graph = p_graph
	sm = p_sm
	_fire_def = fire_def
	burning.clear()
	_fuel_cache.clear()
	_cond_timers.clear()
	burnt = PackedByteArray()
	if graph != null:
		burnt.resize(graph.cell_count)


func active() -> bool:
	return graph != null and graph.cell_count > 0


# Structures changed (a wall/tree burned down or was destroyed) -> refresh fuel.
func invalidate_fuel() -> void:
	_fuel_cache.clear()


# --- ignition API (mirrors SurfaceManager's) --------------------------------

func ignite_area(center_world: Vector2, radius: float) -> int:
	if not active():
		return 0
	var n := 0
	# ignite the cell under the point plus every cell whose centroid is in range
	for cid in graph.cell_count:
		if graph.centroid(cid).distance_to(center_world) <= radius and _try_ignite(cid):
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


# --- tick --------------------------------------------------------------------

func tick(delta: float, characters: Array, game: Node) -> void:
	if not active() or burning.is_empty():
		return
	_spread_timer += delta
	if _spread_timer >= float(_fire_def.get("spread_interval", 2.0)):
		_spread_timer = 0.0
		_spread(game)
	_damage_timer += delta
	if _damage_timer >= float(_fire_def.get("damage_interval", 1.0)):
		_damage_timer = 0.0
		_damage(game)
	_lifetime(delta)
	_apply_burning(delta, characters)


func clear_all() -> void:
	for cid in burning:
		var vfx = burning[cid].get("vfx")
		if vfx and is_instance_valid(vfx):
			vfx.queue_free()
	burning.clear()
	_fuel_cache.clear()
	_cond_timers.clear()
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
	burning[cid] = {"t": dur, "t0": dur, "seed": seed, "vfx": _spawn_vfx(cid)}


func _spawn_vfx(cid: int) -> Node:
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
	var hit := {}   # structure -> true, deduped this tick
	for structure in game.structures_in_scene:
		if not is_instance_valid(structure) or hit.has(structure):
			continue
		for ft in sm._fire_tiles_of(structure):
			if burning_tiles.has(ft):
				hit[structure] = true
				break
	var any_dead := false
	for structure in hit:
		if not is_instance_valid(structure):
			continue
		structure.take_damage(dmg.duplicate(), 0)
		if not is_instance_valid(structure) or structure.current_health <= 0:
			any_dead = true
	if any_dead:
		_fuel_cache.clear()
	# fire consumes the flammable fluid (oil) it burns on, so slicks deplete and
	# eventually go out instead of the fuel reading 2.5 forever
	var cf = game.fluid_manager.cell_fluid if ("fluid_manager" in game and game.fluid_manager) else null
	if cf != null and cf.active_sim():
		var consumed := false
		for cid in burning:
			if cf.is_flammable_at(cid):
				cf.burn_off(cid, 0.06)
				consumed = true
		if consumed:
			_fuel_cache.clear()


func _lifetime(delta: float) -> void:
	var out: Array = []
	for cid in burning:
		var bd: Dictionary = burning[cid]
		bd["t"] = float(bd["t"]) - delta
		if float(bd["t"]) <= 0.0:
			out.append(cid)
	for cid in out:
		burnt[cid] = 1
		var vfx = burning[cid].get("vfx")
		if vfx and is_instance_valid(vfx):
			vfx.queue_free()
		burning.erase(cid)


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


# Cell fuel: non-flammable structure -> firebreak; flammable structure -> heavy
# fuel; else the graph's static ground fuel. Cached; structure sweeps are the
# cost and only change on structure death (invalidate_fuel).
func _fuel(cid: int) -> float:
	if _fuel_cache.has(cid):
		return _fuel_cache[cid]
	var f := _compute_fuel(cid)
	_fuel_cache[cid] = f
	return f


func _compute_fuel(cid: int) -> float:
	var game = sm._get_game() if sm.has_method("_get_game") else null
	if game != null and "structures_in_scene" in game:
		var tile := _tile_of(cid)
		var blocked := false
		var flammable_fuel := 0.0
		for structure in game.structures_in_scene:
			if not is_instance_valid(structure):
				continue
			if tile in sm._fire_tiles_of(structure):
				if structure.flammable:
					flammable_fuel = maxf(flammable_fuel, 1.25)   # timber/tree: heavy fuel
				else:
					blocked = true                                 # stone: firebreak
		# ANY flammable claimer wins over a co-located stone one (iteration order
		# must not decide) -- must scan ALL claimers before returning the break,
		# matching SurfaceManager._is_tile_flammable's contract.
		if flammable_fuel > 0.0:
			return flammable_fuel
		if blocked:
			return 0.0
		# cell fluids: standing OIL is heavy fuel (a spark takes the slick), any
		# other fluid (water) is a firebreak. Structures already decided above.
		var cf = game.fluid_manager.cell_fluid if ("fluid_manager" in game and game.fluid_manager) else null
		if cf != null and cf.active_sim():
			if cf.is_flammable_at(cid):
				return 2.5
			if cf.amount_at(cid) > 0.01:
				return 0.0
	return graph.ground_fuel(cid)


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
