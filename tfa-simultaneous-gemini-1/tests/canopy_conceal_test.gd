# res://tests/canopy_conceal_test.gd
# Headless assertion harness for P3-F (TG roadmap Phase 3, decision 7): tree
# crowns HIDE characters. The rules half of Phase 3's exit criterion 2:
#   - a ground AI beyond 2 tiles detects a crowned target only within
#     0.5 x its sight range (can_see_character, has_in_view, _update_target,
#     CrimeManager.hidden_from's "Canopy");
#   - a viewer on a deck, a roof or a cliff top cannot see a crowned target at
#     any range, and a crown blocks the line for an eye inside its band;
#   - attacking (reveal()) lifts the factor for 3 s;
#   - party members always see each other;
#   - a felled or burnt-down tree stops hiding at once;
#   - near (2 tiles) or under the same crown cluster: seen normally; hedges
#     and dead snags hide nothing; corpses are unaffected.
#   A. synthetic: tree rows through MapLoader._spawn_geo_structure exactly as
#      an export writes them, real ProceduralCharacter.tscn instances on a
#      stub Game surface (as stealth_ai_r4_test), flat then relief terrain.
#   B. the model built from real tree maps' rows (tg_castle_keep's garden,
#      Perrow's tg_hillside_middle): hedges and snags left out, clusters,
#      bounded buckets, and the O(1) lookup's cost.
#   C. the real Game on tg_castle_keep: an NPC under a real crown is hidden
#      from the party through the existing path (npc.visible false), shown
#      by an attack's reveal and by felling the tree.
# Run:  godot --headless --path . res://tests/canopy_conceal_test.tscn
# Judge by the PASS/FAIL lines and "CANOPY CONCEAL DONE failures=0".
extends Node2D

const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const MAP_LOADER := preload("res://Structures/MapLoader.gd")

# --- Game stub surface (ai.gd, ProceduralCharacter, MapLoader, CrimeManager) ---
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
var current_map_id: String = "town_square"   # Liziti law: theft is a crime
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

var failures := 0
var checks := 0
var _ml: Node2D = null
var _trees: Array = []
var _killed: Array = []


func _check(check_name: String, cond: bool, detail: Variant = "") -> void:
	checks += 1
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, str(detail)])


func _ready() -> void:
	# A SCRIPT ERROR aborts the coroutine; don't hang waiting for quit().
	get_tree().create_timer(600.0, true).timeout.connect(func():
		print("FAIL watchdog timeout (coroutine aborted?) failures=%d" % failures)
		get_tree().quit(99))
	fluid_manager = FluidManager.new()
	add_child(fluid_manager)
	TimeManager.pause_time()   # reveal windows are moved by hand
	await get_tree().process_frame
	await _part_a_flat()
	await _part_a_relief()
	await _part_b_real_rows("tg_castle_keep")
	await _part_b_real_rows("tg_hillside_middle")
	await _part_c_real_game()
	print("CANOPY CONCEAL DONE failures=%d checks=%d" % [failures, checks])
	get_tree().quit(1 if failures > 0 else 0)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _settle() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame


func _tree_row(pos: Vector2, r: float, stories: float, extra: Dictionary = {}) -> Dictionary:
	var row := {"kind": "tree", "pos": [pos.x, pos.y], "r": r, "id": "tree", "hp": 80, "stories": stories}
	row.merge(extra, true)
	return row


func _spawn_tree(row: Dictionary) -> Structure:
	var inst: Structure = _ml._spawn_geo_structure(row, null, GridManager.TILE_SIZE)
	_trees.append(inst)
	return inst


func _spawn(faction: String, pos: Vector2, char_name: String, party := false) -> ProceduralCharacter:
	var c: ProceduralCharacter = PC_SCENE.instantiate()
	c.AI_enabled = false
	c.is_player_controlled = party
	add_child(c)
	TopDownCharacterDatabase.build_character(c, "default_human")
	c.game = self
	c.faction_id = faction
	c.Name = char_name
	_place(c, pos, Vector2.UP)
	characters_in_scene.append(c)
	if party:
		party_chars.append(c)
	return c


## Stand `c` at `pos` facing `dir`, its elevation read from the tile now.
func _place(c: ProceduralCharacter, pos: Vector2, dir: Vector2) -> void:
	c.global_position = pos
	var f: Vector2 = dir.normalized()
	c.rotation = atan2(f.x, -f.y)
	c.target_rotation = c.rotation
	c._refresh_elevation()


func _face(c: ProceduralCharacter, at: Vector2) -> void:
	_place(c, c.global_position, at - c.global_position)


func _ai(c: ProceduralCharacter) -> Node:
	return c.get_node("AI")


## A fresh acquisition pass: does `guard` pick `foe` as its target?
func _acquires(guard: ProceduralCharacter, foe: ProceduralCharacter) -> bool:
	var ai = _ai(guard)
	ai.current_target = null
	ai._update_target(0.0)
	var got: bool = ai.current_target == foe
	ai.current_target = null
	return got


func _clear_chars() -> void:
	for c in characters_in_scene:
		if is_instance_valid(c):
			c.queue_free()
	characters_in_scene = []
	party_chars = []
	await _settle()


func _clear_trees() -> void:
	for t in _trees:
		if is_instance_valid(t):
			t.queue_free()
	_trees = []
	if _ml != null and is_instance_valid(_ml):
		_ml.queue_free()
	_ml = null
	await _settle()


func _log_sum(fragment: String) -> int:
	var n := 0
	for e in GameLog.get_entries():
		if String(e.get("text", "")).contains(fragment):
			n += int(e.get("count", 1))
	return n


func _on_crown_changed(i: int) -> void:
	_killed.append(i)


# ---------------------------------------------------------------------------
# A. Synthetic, flat map
# ---------------------------------------------------------------------------

const T1 := Vector2(1000, 1000)      # r 60, 1.3 stories: the main crown
const UNDER := Vector2(0, 45)        # inside r 60, outside the 27 px trunk
const OPEN := Vector2(1600, 1045)    # a control spot under no crown
const B1 := Vector2(3000, 1000)      # B1 + B2: one cluster (140 < 75 + 75)
const B2 := Vector2(3000, 1140)
const HEDGE := Vector2(4000, 1000)
const SNAG := Vector2(4400, 1000)
const C1_TREE := Vector2(4800, 1000) # contract-1 row: no "stories"
const FELL := Vector2(5200, 1000)
const BURN := Vector2(5800, 1000)
const BAND := Vector2(2200, 2000)    # the crown-band tree
const CHAIN := Vector2(1000, 3000)   # three crowns in a row, 120 px apart

func _part_a_flat() -> void:
	GridManager.TILE_SIZE = 64
	GridManager.initialize(6400, 6400)
	GridManager.refresh_terrain_stats()
	_check("a.flat-no-relief", not GridManager.relief_los)
	_ml = MAP_LOADER.new()
	add_child(_ml)
	GridManager.canopy.crown_changed.connect(_on_crown_changed)
	var t1: Structure = _spawn_tree(_tree_row(T1, 60.0, 1.3))
	_spawn_tree(_tree_row(B1, 75.0, 1.8))
	_spawn_tree(_tree_row(B2, 75.0, 1.8))
	var hedge: Structure = _spawn_tree({"kind": "tree", "pos": [HEDGE.x, HEDGE.y], "r": 24.0, "id": "hedge",
		"hp": 40, "occlude_h": 0.45, "stories": 0.5})
	var snag: Structure = _spawn_tree(_tree_row(SNAG, 40.0, 0.72))
	var c1: Structure = _spawn_tree({"kind": "tree", "pos": [C1_TREE.x, C1_TREE.y], "r": 50.0, "id": "tree", "hp": 80})
	var fell: Structure = _spawn_tree(_tree_row(FELL, 60.0, 1.3))
	var burn: Structure = _spawn_tree(_tree_row(BURN, 60.0, 1.3))
	_spawn_tree(_tree_row(BAND, 60.0, 1.3))
	var chain: Array = []
	for k in 3:
		chain.append(_spawn_tree(_tree_row(CHAIN + Vector2(120.0 * k, 0.0), 70.0, 1.3)))
	GridManager.canopy.finish()
	await _settle()
	var cm = GridManager.canopy

	# --- the model
	_check("a.model-count", cm.crown_count() == 10, cm.crown_count())
	_check("a.model-hedge-not-a-crown", cm.crown_of(hedge) == -1 and cm.crown_at(HEDGE + Vector2(0, 18)) == -1)
	_check("a.model-snag-not-a-crown", cm.crown_of(snag) == -1 and cm.crown_at(SNAG + Vector2(0, 30)) == -1)
	var c1_rec: Dictionary = cm.crown(cm.crown_of(c1))
	_check("a.model-contract1-tree-2-stories", not c1_rec.is_empty() and is_equal_approx(float(c1_rec["stories"]), 2.0)
		and is_equal_approx(float(c1_rec["base"]), 1.0), c1_rec)
	var t1_i: int = cm.crown_of(t1)
	var rec: Dictionary = cm.crown(t1_i)
	_check("a.model-crown-record", not rec.is_empty() and (rec["pos"] as Vector2).is_equal_approx(T1)
		and is_equal_approx(float(rec["r"]), 60.0) and is_equal_approx(float(rec["trunk_r"]), 27.0)
		and is_equal_approx(float(rec["stories"]), 1.3) and bool(rec["alive"]) and int(rec["cluster"]) == t1_i, rec)
	_check("a.model-trunk-not-cover", cm.crown_at(T1 + Vector2(0, 20)) == -1)
	_check("a.model-overhang-cover", cm.crown_at(T1 + UNDER) == t1_i)
	_check("a.model-outside-disc", cm.crown_at(T1 + Vector2(0, 61)) == -1)
	_check("a.model-tile-cover", cm.canopy_cover(GridManager.world_to_map(T1 + Vector2(0, 50))) == cm.cluster_of(t1_i)
		and cm.canopy_cover(GridManager.world_to_map(OPEN)) == -1)
	_check("a.model-cluster-joins-overlap", cm.cluster_at(B1 + Vector2(60, -30)) == cm.cluster_at(B2 + Vector2(60, 30))
		and cm.cluster_at(B1 + Vector2(60, -30)) >= 0 and cm.cluster_at(B1 + Vector2(60, -30)) != cm.cluster_of(t1_i))
	_check("a.model-chain-one-cluster", cm.cluster_of(cm.crown_of(chain[0])) == cm.cluster_of(cm.crown_of(chain[2])))

	# --- ground AI: concealed within half its sight range only
	var guard := _spawn("bandits", T1 + UNDER + Vector2(0, 600), "Guard")
	var x := _spawn("player", T1 + UNDER, "Ximena")
	var y := _spawn("player", OPEN, "Yusuf")
	var ai = _ai(guard)
	var sight_px: float = ai.get_sight_range_pixels()
	_check("a.hostile-pair", FactionDatabase.are_hostile("bandits", "player"))
	_check("a.sight-range-sane", sight_px > 800.0 and sight_px < 3000.0, sight_px)
	_check("a.target-side-half", is_equal_approx(x.effective_visibility(), 0.5), x.effective_visibility())
	_check("a.target-side-open-full", is_equal_approx(y.effective_visibility(), 1.0))
	_check("a.no-smoky-tint-under-crown", is_equal_approx(x.modulate.r, 1.0) and is_equal_approx(x.concealment_visibility(), 1.0))
	_place(guard, T1 + UNDER + Vector2(0, sight_px * 0.6), Vector2.UP)
	_check("a.ground-0.6x-hidden", not ai.can_see_character(x) and not ai.has_in_view(x))
	_check("a.ground-0.6x-not-acquired", not _acquires(guard, x))
	_check("a.ground-0.6x-observer-half", is_equal_approx(x.visibility_to(guard), 0.5), x.visibility_to(guard))
	_check("a.ground-0.6x-witness-canopy", CrimeManager.hidden_from(guard, x) == "Canopy", CrimeManager.hidden_from(guard, x))
	_place(guard, OPEN + Vector2(0, sight_px * 0.6), Vector2.UP)
	_check("a.control-open-0.6x-seen", ai.can_see_character(y) and _acquires(guard, y))
	_place(guard, T1 + UNDER + Vector2(0, sight_px * 0.4), Vector2.UP)
	_check("a.ground-0.4x-seen", ai.can_see_character(x) and ai.has_in_view(x))
	_check("a.ground-0.4x-acquired", _acquires(guard, x))
	_check("a.ground-0.4x-witness-none", CrimeManager.hidden_from(guard, x) == "")

	# --- a theft under the crown, beyond half sight: nobody saw it, and why
	_place(guard, T1 + UNDER + Vector2(0, sight_px * 0.6), Vector2.UP)
	var mark := _spawn("neutral", Vector2(6000, 6000), "Purse")
	mark.rotation = PI
	var lines := _log_sum("No one saw it: Ximena was under the trees.")
	CrimeManager.report(x, "take", {"owner_faction": "liziti", "crime_pos": x.global_position, "debounce_target": mark})
	_check("a.theft-unseen-canopy", ai.pending_outcry.is_empty() and _log_sum("No one saw it: Ximena was under the trees.") == lines + 1,
		"outcry %s log %s" % [str(ai.pending_outcry), str(GameLog.get_entries().slice(-2))])

	# --- within 2 tiles: the canopy factor is lifted (a short-sighted guard)
	var base_sight: float = guard.sight
	guard.sight = 0.15
	var short_px: float = ai.get_sight_range_pixels()
	_check("a.short-sight", short_px * 0.5 < 128.0 and short_px > 150.0, short_px)
	_place(guard, T1 + UNDER + Vector2(0, 120), Vector2.UP)
	_check("a.near-2-tiles-seen", ai.can_see_character(x) and is_equal_approx(x.visibility_to(guard), 1.0),
		x.visibility_to(guard))
	_place(guard, T1 + UNDER + Vector2(0, 150), Vector2.UP)
	_check("a.beyond-2-tiles-hidden", not ai.can_see_character(x) and is_equal_approx(x.visibility_to(guard), 0.5))
	guard.sight = base_sight

	# --- the same crown cluster: seen normally; just outside it, hidden
	guard.sight = 0.2
	var cl_px: float = ai.get_sight_range_pixels()
	var under_b1 := B1 + Vector2(60, -30)
	var under_b2 := B2 + Vector2(60, 30)
	_place(x, under_b1, Vector2.UP)
	_place(guard, under_b2, Vector2.UP)
	_check("a.cluster-setup", cl_px * 0.5 < under_b1.distance_to(under_b2) and under_b1.distance_to(under_b2) < cl_px
		and under_b1.distance_to(under_b2) > 128.0, cl_px)
	_check("a.same-cluster-seen", ai.can_see_character(x) and is_equal_approx(x.visibility_to(guard), 1.0))
	_place(guard, B2 + Vector2(60, 90), Vector2.UP)   # out from under B2, 260 px off
	_check("a.outside-cluster-hidden", cm.cluster_at(guard.global_position) == -1 and not ai.can_see_character(x))
	guard.sight = base_sight

	# --- hedges hide nothing
	_place(x, HEDGE + Vector2(0, 18), Vector2.UP)
	_place(guard, x.global_position + Vector2(0, sight_px * 0.6), Vector2.UP)
	_check("a.hedge-no-conceal", is_equal_approx(x.effective_visibility(), 1.0) and ai.can_see_character(x))

	# --- corpses are unaffected (a deck viewer too)
	_place(x, T1 + UNDER, Vector2.UP)
	var hp: int = x.current_health
	x.current_health = 0
	_place(guard, T1 + UNDER + Vector2(0, sight_px * 0.6), Vector2.UP)
	var corpse_ground: float = x.visibility_to(guard)
	var corpse_side: float = x.effective_visibility()
	x.current_health = hp
	_check("a.corpse-unaffected", is_equal_approx(corpse_side, 1.0) and is_equal_approx(corpse_ground, 1.0),
		"%s %s" % [corpse_side, corpse_ground])

	# --- attacking reveals for 3 s
	_check("a.reveal-before", not ai.can_see_character(x))
	x.reveal()
	_check("a.reveal-lifts-factor", is_equal_approx(x.effective_visibility(), 1.0)
		and is_equal_approx(x.visibility_to(guard), 1.0) and ai.can_see_character(x) and _acquires(guard, x))
	_check("a.reveal-witness-sees", CrimeManager.hidden_from(guard, x) == "")
	TimeManager.game_time += 2.5
	_check("a.reveal-holds-2.5s", ai.can_see_character(x))
	TimeManager.game_time += 0.6
	_check("a.reveal-ends-3s", not ai.can_see_character(x) and is_equal_approx(x.effective_visibility(), 0.5))
	x.reveal(ProceduralCharacter.REVEAL_SECONDS, "casting", false)
	_check("a.cast-reveals", ai.can_see_character(x))
	TimeManager.game_time += 3.1

	# --- elevated viewers: a deck, a roof
	var deck_t := GridManager.world_to_map(T1 + UNDER + Vector2(0, sight_px * 0.4))
	GridManager.register_deck(deck_t, 1.5)
	_place(guard, T1 + UNDER + Vector2(0, sight_px * 0.4), Vector2.UP)
	_check("a.deck-viewer-up", is_equal_approx(guard.get_elevation(), 1.5), guard.get_elevation())
	_check("a.deck-viewer-hidden", not ai.can_see_character(x) and not _acquires(guard, x)
		and is_equal_approx(x.visibility_to(guard), 0.0), x.visibility_to(guard))
	_check("a.deck-viewer-witness-canopy", CrimeManager.hidden_from(guard, x) == "Canopy")
	x.reveal()
	_check("a.deck-viewer-reveal-still-hidden", not ai.can_see_character(x))
	TimeManager.game_time += 3.1
	GridManager.unregister_deck(deck_t, 1.5)
	var near_t := GridManager.world_to_map(T1 + UNDER + Vector2(0, 100))
	GridManager.register_deck(near_t, 1.5)
	_place(guard, T1 + UNDER + Vector2(0, 100), Vector2.UP)
	_check("a.deck-viewer-near-still-hidden", guard.get_elevation() > 1.0 and not ai.can_see_character(x))
	GridManager.unregister_deck(near_t, 1.5)
	var open_deck := GridManager.world_to_map(OPEN + Vector2(0, sight_px * 0.4))
	GridManager.register_deck(open_deck, 1.5)
	_place(guard, OPEN + Vector2(0, sight_px * 0.4), Vector2.UP)
	_check("a.deck-viewer-sees-open", guard.get_elevation() > 1.0 and ai.can_see_character(y))
	GridManager.unregister_deck(open_deck, 1.5)
	var roof_t := GridManager.world_to_map(T1 + UNDER + Vector2(0, sight_px * 0.4))
	GridManager.roof_elevations[roof_t] = 2.0
	guard.on_roof = true
	_place(guard, T1 + UNDER + Vector2(0, sight_px * 0.4), Vector2.UP)
	_check("a.roof-viewer-up", is_equal_approx(guard.get_elevation(), 2.0), guard.get_elevation())
	_check("a.roof-viewer-hidden", not ai.can_see_character(x) and not ai.has_in_view(x) and not _acquires(guard, x))
	guard.on_roof = false
	GridManager.roof_elevations.erase(roof_t)
	_place(guard, guard.global_position, Vector2.UP)

	# --- the crown band: a crown between two eyes at crown height blocks
	# the line (a target under no crown, the line 45 px off the trunk)
	var beyond := BAND + Vector2(45, -200)
	var band_view := BAND + Vector2(45, 400)
	_place(y, beyond, Vector2.UP)
	_place(guard, band_view, Vector2.UP)
	_check("a.band-ground-passes-under", ai.can_see_character(y) and is_equal_approx(y.visibility_to(guard), 1.0))
	var band_t := GridManager.world_to_map(band_view)
	GridManager.register_deck(band_t, 0.7)   # eye 1.2: inside the 1.0..1.3 band
	_place(guard, band_view, Vector2.UP)
	_check("a.band-eye-in-crown-blocked", not ai.can_see_character(y) and is_equal_approx(y.visibility_to(guard), 0.0)
		and CrimeManager.hidden_from(guard, y) == "Canopy", guard.get_elevation())
	GridManager.unregister_deck(band_t, 0.7)
	GridManager.register_deck(band_t, 2.5)   # eye 3.0: over the 1.3 top
	_place(guard, band_view, Vector2.UP)
	_check("a.band-eye-over-crown-sees", ai.can_see_character(y))
	GridManager.unregister_deck(band_t, 2.5)
	_place(guard, band_view, Vector2.UP)

	# --- party members always see each other
	var p1 := _spawn("player", T1 + UNDER + Vector2(-40, sight_px * 0.6), "Pia", true)
	var p2 := _spawn("player", T1 + UNDER + Vector2(-20, 0), "Paz", true)
	_place(x, OPEN + Vector2(300, 0), Vector2.UP)
	_check("a.party-pair-setup", p2.canopy_crown() >= 0 and is_equal_approx(p2.effective_visibility(), 0.5))
	_check("a.party-sees-party", _ai(p1).can_see_character(p2) and is_equal_approx(p2.visibility_to(p1), 1.0))
	_place(guard, p1.global_position + Vector2(40, 0), Vector2.UP)
	_check("a.npc-same-spot-doesnt", not ai.can_see_character(p2))
	var pdeck := GridManager.world_to_map(p1.global_position)
	GridManager.register_deck(pdeck, 1.5)
	_place(p1, p1.global_position, Vector2.UP)
	_check("a.party-elevated-sees-party", p1.get_elevation() > 1.0 and _ai(p1).can_see_character(p2))
	GridManager.unregister_deck(pdeck, 1.5)
	_place(p1, p1.global_position, Vector2.UP)

	# --- a felled tree, a burnt one: no cover at once
	_place(x, FELL + UNDER, Vector2.UP)
	_place(guard, FELL + UNDER + Vector2(0, sight_px * 0.6), Vector2.UP)
	_check("a.fell-before-hidden", not ai.can_see_character(x))
	var fell_i: int = cm.crown_of(fell)
	fell.take_damage({"slashing": 9999})
	_check("a.felled-no-cover-at-once", not bool(cm.crown(fell_i)["alive"]) and int(cm.crown(fell_i)["cluster"]) == -1
		and _killed.has(fell_i) and is_equal_approx(x.effective_visibility(), 1.0) and ai.can_see_character(x))
	_place(x, BURN + UNDER, Vector2.UP)
	_place(guard, BURN + UNDER + Vector2(0, sight_px * 0.6), Vector2.UP)
	_check("a.burn-before-hidden", not ai.can_see_character(x))
	var burn_i: int = cm.crown_of(burn)
	burn.take_damage({"fire": 9999})
	_check("a.burnt-no-cover-at-once", not bool(cm.crown(burn_i)["alive"]) and ai.can_see_character(x)
		and is_equal_approx(x.visibility_to(guard), 1.0))
	# a death in the middle of a chain splits its cluster
	var c0: int = cm.crown_of(chain[0])
	var c2: int = cm.crown_of(chain[2])
	(chain[1] as Structure).take_damage({"slashing": 9999})
	_check("a.chain-split", cm.cluster_of(c0) >= 0 and cm.cluster_of(c2) >= 0 and cm.cluster_of(c0) != cm.cluster_of(c2))

	# --- cost: O(1) lookup, no objects made per check
	_place(x, T1 + UNDER, Vector2.UP)
	_place(guard, T1 + UNDER + Vector2(0, sight_px * 0.6), Vector2.UP)
	var objs: float = Performance.get_monitor(Performance.OBJECT_COUNT)
	var t0: int = Time.get_ticks_usec()
	var acc := 0.0
	for k in 10000:
		acc += x.visibility_to(guard)
	var us: float = float(Time.get_ticks_usec() - t0) / 10000.0
	_check("a.visibility-to-no-objects", is_equal_approx(Performance.get_monitor(Performance.OBJECT_COUNT), objs),
		Performance.get_monitor(Performance.OBJECT_COUNT) - objs)
	print("INFO visibility_to %.2f us/call (sum %.0f)" % [us, acc])
	_check("a.visibility-to-cheap", us < 200.0, us)
	await _clear_chars()
	await _clear_trees()


# ---------------------------------------------------------------------------
# A2. Synthetic, relief: a viewer on a cliff top
# ---------------------------------------------------------------------------

func _part_a_relief() -> void:
	GridManager.TILE_SIZE = 64
	GridManager.initialize(4096, 4096)
	# the cliff: every tile from row 30 down stands 3 stories up
	for ty in range(30, 64):
		for tx in range(64):
			GridManager.elevations[Vector2i(tx, ty)] = 3.0
	GridManager.refresh_terrain_stats()
	_check("a2.relief-on", GridManager.relief_los)
	_ml = MAP_LOADER.new()
	add_child(_ml)
	var tree_pos := Vector2(1000, 1300)
	_spawn_tree(_tree_row(tree_pos, 60.0, 1.3))
	GridManager.canopy.finish()
	await _settle()
	var x := _spawn("player", tree_pos + UNDER, "Ximena")
	var y := _spawn("player", Vector2(1600, 1345), "Yusuf")
	var guard := _spawn("bandits", Vector2(1000, 30 * 64 + 32), "Lookout")
	var ai = _ai(guard)
	var rec: Dictionary = GridManager.canopy.crown(0)
	_check("a2.tree-on-low-ground", not rec.is_empty() and is_equal_approx(float(rec["ground"]), 0.0), rec)
	_check("a2.viewer-on-cliff", is_equal_approx(guard.get_elevation(), 3.0) and guard.height_above_ground() < 0.01,
		guard.get_elevation())
	_place(guard, Vector2(1000 + 45, 30 * 64 + 32), x.global_position - Vector2(1045, 30 * 64 + 32))
	_check("a2.cliff-viewer-hidden", not ai.can_see_character(x) and is_equal_approx(x.visibility_to(guard), 0.0),
		x.visibility_to(guard))
	_place(guard, Vector2(1600, 30 * 64 + 32), y.global_position - Vector2(1600, 30 * 64 + 32))
	_check("a2.cliff-viewer-sees-open", ai.can_see_character(y))
	# a ground viewer level with the tree (beyond 2 tiles, within half sight;
	# beside it, so the line misses the trunk)
	var low := _spawn("bandits", x.global_position + Vector2(300, 0), "Walker")
	_face(low, x.global_position)
	_check("a2.ground-viewer-half-range", _ai(low).can_see_character(x) and is_equal_approx(x.visibility_to(low), 0.5))
	await _clear_chars()
	await _clear_trees()


# ---------------------------------------------------------------------------
# B. The model from real maps' tree rows
# ---------------------------------------------------------------------------

func _part_b_real_rows(map_id: String) -> void:
	var data: Dictionary = MapDatabase.get_map_data(map_id)
	_check("b.%s-has-data" % map_id, not data.is_empty())
	if data.is_empty():
		return
	var ws: Array = data.get("world_size", [2048, 2048])
	GridManager.TILE_SIZE = int(data.get("tile_size", 64))
	GridManager.initialize(int(ws[0]), int(ws[1]))
	GridManager.refresh_terrain_stats()
	_ml = MAP_LOADER.new()
	add_child(_ml)
	var want := 0
	var hedges := 0
	var snags := 0
	for s in data.get("structures", []):
		if not (s is Dictionary) or String(s.get("kind", "")) != "tree":
			continue
		if String(s.get("id", "")) == "hedge":
			hedges += 1
		elif float(s.get("stories", 2.0)) <= 1.0:
			snags += 1
		else:
			want += 1
		_spawn_tree(s)
	var t0: int = Time.get_ticks_usec()
	GridManager.canopy.finish()
	var build_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	var cm = GridManager.canopy
	_check("b.%s-crowns-are-the-trees" % map_id, cm.crown_count() == want and want > 0,
		"crowns %d, tree rows %d (hedges %d, snags %d)" % [cm.crown_count(), want, hedges, snags])
	var hedge_crowns := 0
	for t in _trees:
		if is_instance_valid(t) and (t as Structure).structure_id == &"hedge" and cm.crown_of(t) >= 0:
			hedge_crowns += 1
	_check("b.%s-no-hedge-crowns" % map_id, hedge_crowns == 0, hedge_crowns)
	var clusters: Dictionary = {}
	var bad := []
	var max_bucket := 0
	for k in range(cm._cols * cm._rows):
		max_bucket = maxi(max_bucket, cm._tile_start[k + 1] - cm._tile_start[k])
	for i in cm.crown_count():
		var rec: Dictionary = cm.crown(i)
		var p: Vector2 = rec["pos"]
		var r: float = rec["r"]
		var tr: float = rec["trunk_r"]
		clusters[int(rec["cluster"])] = true
		if cm.crown_at(p) == i:
			bad.append("%d trunk" % i)
		var mid: float = (r + tr) * 0.5
		for dir in [Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT, Vector2.UP]:
			var probe: Vector2 = p + (dir as Vector2) * mid
			if not GridManager.map_rect.has_point(GridManager.world_to_map(probe)):
				continue   # a crown overhanging the map edge
			var hit: int = cm.crown_at(probe)
			if hit < 0 or cm.cluster_of(hit) != cm.cluster_of(i):
				bad.append("%d overhang %s" % [i, str(dir)])
	_check("b.%s-discs-minus-trunks" % map_id, bad.is_empty(), str(bad.slice(0, 6)))
	_check("b.%s-clusters" % map_id, clusters.size() >= 1 and clusters.size() <= cm.crown_count(), clusters.size())
	_check("b.%s-buckets-bounded" % map_id, max_bucket <= 12, max_bucket)
	# the O(1) lookup over the whole map, a point every 16 px
	var n := 0
	var covered := 0
	t0 = Time.get_ticks_usec()
	var step := 16.0
	var y := 8.0
	while y < float(ws[1]):
		var x := 8.0
		while x < float(ws[0]):
			if cm.crown_at(Vector2(x, y)) >= 0:
				covered += 1
			n += 1
			x += step
		y += step
	var per_us: float = float(Time.get_ticks_usec() - t0) / float(maxi(1, n))
	print("INFO %s: %d crowns, %d clusters, %d hedges, %d snags, max bucket %d, build %.1f ms, crown_at %.3f us x %d (%.1f%% covered)"
		% [map_id, cm.crown_count(), clusters.size(), hedges, snags, max_bucket, build_ms, per_us, n, 100.0 * covered / maxf(1.0, n)])
	_check("b.%s-lookup-cheap" % map_id, per_us < 20.0, per_us)
	await _clear_trees()


# ---------------------------------------------------------------------------
# C. The real Game on a real tree map
# ---------------------------------------------------------------------------

func _part_c_real_game() -> void:
	var game = load("res://game.tscn").instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await get_tree().process_frame
	await get_tree().process_frame
	game.load_map("tg_castle_keep")
	for i in 10:
		await get_tree().process_frame
	if PauseManager.is_paused:
		PauseManager.unpause()
	TimeManager.pause_time()
	_check("c.loaded", game.party_chars.size() > 0 and String(game.current_map_id) == "tg_castle_keep")
	if game.party_chars.is_empty():
		return
	var cm = GridManager.canopy
	var want := 0
	for s in MapDatabase.get_map_data("tg_castle_keep").get("structures", []):
		if s is Dictionary and String(s.get("kind", "")) == "tree" and String(s.get("id", "")) != "hedge" \
				and float(s.get("stories", 2.0)) > 1.0:
			want += 1
	_check("c.loader-built-the-canopy", cm.crown_count() == want and not cm._dirty, "%d vs %d" % [cm.crown_count(), want])
	for c in game.characters_in_scene:
		if is_instance_valid(c):
			c.AI_enabled = false
	var leader: ProceduralCharacter = game.party_chars[0]
	var saved_sight: Dictionary = {}
	for pc in game.party_chars:
		saved_sight[pc] = pc.sight
		if pc != leader:
			pc.sight = 0.0   # only the leader looks
	leader.sight = 0.4
	# A real crown with a clear sight line from open ground, between half and
	# the whole of the leader's sight range.
	var found: Dictionary = _find_real_setup(game, leader)
	_check("c.found-a-real-crown", not found.is_empty())
	if found.is_empty():
		for pc in saved_sight:
			pc.sight = saved_sight[pc]
		return
	var q: Vector2 = found["q"]
	var stand: Vector2 = found["stand"]
	var ci: int = found["crown"]
	print("INFO real crown %d at %s, target %s, leader %s (%.0f px, range %.0f)" % [ci, str(cm.crown(ci)["pos"]),
		str(q), str(stand), q.distance_to(stand), leader.get_sight_range_px_to(q)])
	var npc = game._spawn_character("default_human", q, {"faction": "bandits"})
	_check("c.npc-spawned", npc != null)
	if npc == null:
		return
	npc.AI_enabled = false
	npc.Name = "Lurker"
	npc.global_position = q
	_place(leader, stand, q - stand)
	for i in 4:
		await get_tree().process_frame
	_check("c.npc-under-crown", npc.canopy_crown() == ci and is_equal_approx(npc.visibility_to(leader), 0.5))
	_check("c.npc-hidden-from-party", not npc.visible and not game.is_seen_by_party(npc), "visible %s" % npc.visible)
	# attacking shows it for 3 s (the real Game.register_attack_start)
	game.register_attack_start(npc)
	for i in 3:
		await get_tree().process_frame
	_check("c.attack-reveals", npc.visible and game.is_seen_by_party(npc))
	TimeManager.game_time += 3.2
	for i in 3:
		await get_tree().process_frame
	_check("c.reveal-ends", not npc.visible and not game.is_seen_by_party(npc))
	# near: within 2 tiles the crown doesn't hide it
	var near_pos: Vector2 = q + (stand - q).normalized() * 100.0
	if GridManager.would_walk(GridManager.world_to_map(near_pos)):
		_place(leader, near_pos, q - near_pos)
		for i in 3:
			await get_tree().process_frame
		_check("c.near-seen", npc.visible and game.is_seen_by_party(npc))
		_place(leader, stand, q - stand)
		for i in 3:
			await get_tree().process_frame
	# felled: the real tree Structure, through its destroyed signal
	var tree_s: Structure = null
	for s in game.structures_in_scene:
		if is_instance_valid(s) and cm.crown_of(s) == ci:
			tree_s = s
	_check("c.tree-structure-found", tree_s != null)
	if tree_s != null:
		_check("c.still-hidden-before-fell", not npc.visible)
		tree_s.take_damage({"slashing": 9999})
		for i in 3:
			await get_tree().process_frame
		_check("c.felled-npc-seen", not bool(cm.crown(ci)["alive"]) and npc.visible and game.is_seen_by_party(npc))
	for pc in saved_sight:
		pc.sight = saved_sight[pc]


## On the loaded map: a live crown, a spot q under it the NPC can stand on,
## and open ground `stand` for the leader between 0.6 and 0.9 of its sight
## range from q, with a clear sight line when facing q. {} if none.
func _find_real_setup(game, leader: ProceduralCharacter) -> Dictionary:
	var cm = GridManager.canopy
	var space := leader.get_world_2d().direct_space_state
	for i in cm.crown_count():
		var rec: Dictionary = cm.crown(i)
		if not bool(rec["alive"]):
			continue
		var p: Vector2 = rec["pos"]
		var r: float = rec["r"]
		var tr: float = rec["trunk_r"]
		for a in 8:
			var q: Vector2 = p + Vector2.RIGHT.rotated(TAU * a / 8.0) * (tr + (r - tr) * 0.6)
			var qt := GridManager.world_to_map(q)
			if cm.crown_at(q) != i or not GridManager.would_walk(qt) or GridManager.is_solid_rock(qt) or GridManager.has_roof(qt):
				continue
			var q_elev: float = GridManager.effective_elev(qt)
			for b in 16:
				var u: Vector2 = Vector2.RIGHT.rotated(TAU * b / 16.0)
				var save_pos: Vector2 = leader.global_position
				leader.global_position = q + u * 400.0
				var rng: float = leader.get_sight_range_px_to(q)
				leader.global_position = save_pos
				for frac in [0.75, 0.65, 0.85]:
					var stand: Vector2 = q + u * rng * float(frac)
					var st := GridManager.world_to_map(stand)
					if not GridManager.map_rect.has_point(st) or not GridManager.would_walk(st) \
							or GridManager.is_solid_rock(st) or GridManager.has_roof(st) or cm.crown_at(stand) >= 0:
						continue
					if absf(GridManager.effective_elev(st) - q_elev) > 0.3:
						continue
					if not GridManager.sight_line_clear(space, stand, q, GridManager.effective_elev(st), q_elev):
						continue
					if cm.line_blocked(stand, q, GridManager.effective_elev(st), q_elev):
						continue
					return {"crown": i, "q": q, "stand": stand}
	return {}
