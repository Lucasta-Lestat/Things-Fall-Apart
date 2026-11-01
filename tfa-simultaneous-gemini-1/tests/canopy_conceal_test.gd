# res://tests/canopy_conceal_test.gd
# Headless assertion harness for P3-F (TG roadmap Phase 3, decision 7): tree
# crowns HIDE characters. The rules half of Phase 3's exit criterion 2:
#   - a ground AI beyond 2 tiles detects a crowned target only within
#     0.5 x its sight range (can_see_character, has_in_view, _update_target,
#     CrimeManager.hidden_from's "Canopy");
#   - a viewer on a deck or a roof a story or more above the target cannot
#     see a crowned target at any range, nor hold one that ducks under a
#     crown, nor see a crime happen under one; from relief terrain a story or
#     more up (a cliff edge) the same holds when the eye line goes into the
#     crown through the leaves, while one whose eye line runs in under it (a
#     slope, a far cliff) is a ground observer; a crown blocks the line for an
#     eye inside its band;
#   - a viewer at the target's own level on a slope is a ground observer
#     (the factor, near exemption and all), however far above the trunk's
#     ground both stand;
#   - attacking (reveal()) lifts the factor for 3 s, and the block from
#     above (a crown between still blocks); a cast at the caster's feet is
#     seen happening from above in that window, as she is, an instant cast
#     through use_ability too (its crime is reported inside the call: the
#     window opens when the cast is committed), Shrouded or not;
#   - party members always see each other;
#   - a felled or burnt-down tree stops hiding at once;
#   - near (2 tiles) or under the same crown cluster: seen normally; hedges
#     and dead snags hide nothing; corpses are unaffected.
#   A. synthetic: tree rows through MapLoader._spawn_geo_structure exactly as
#      an export writes them, real ProceduralCharacter.tscn instances on a
#      stub Game surface (as stealth_ai_r4_test), flat then relief terrain
#      (a cliff far from a crown and one right over a crown at its foot, and
#      a crown overhanging a terrace step), then a grove on relief: two
#      overlapping crowns over the target, one whose leaves the cliff's eye
#      line goes in through, registered in both orders.
#   B. the model built from real tree maps' rows on their real terrain
#      (tg_castle_keep's garden, Perrow's tg_hillside_middle with its cells
#      tile_elev): hedges and snags left out, crown grounds, clusters, bounded
#      buckets, the O(1) lookup's cost, and on relief a survey of every crown:
#      no same-level viewer within 2 tiles is blocked, no viewer a story up
#      whose eye line runs in under the crown is blocked by it, and
#      blocks_view's cost where its tile walk runs.
#   C. the real Game on tg_castle_keep: an NPC under a real crown is hidden
#      from the party through the existing path (npc.visible false), shown
#      by an attack's reveal and by felling the tree. Then the real Game on
#      tg_hillside_middle: a same-level pair on a slope sees normally, an
#      uphill viewer under a story up gets the factor, so does one a story or
#      more up whose eye line runs in under the crown (and a guard there
#      keeps holding), and one whose eye line goes in through the leaves is
#      blocked until the tree falls.
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
	await _part_a_grove()
	await _part_b_real_rows("tg_castle_keep", false)
	await _part_b_real_rows("tg_hillside_middle", true)
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


## Cast `ab`, an instant cast, through `x`'s own use_ability with `guard`
## watching: whether the crime hook (filling `at_report`) saw her revealed and
## what hid her from `guard` then, whether `guard` lit a fuse, and how many
## "No one saw it" lines it logged. Then the window shuts and the debounce
## clears.
func _instant_cast(x: ProceduralCharacter, guard: ProceduralCharacter, ab: Ability, at_report: Array) -> Dictionary:
	for c in characters_in_scene:
		var cai = c.get_node_or_null("AI")
		if cai != null:
			cai.pending_outcry = {}
			cai._outcry_timer = -1.0
	at_report.clear()
	var unseen0: int = _log_sum("No one saw it")
	var ok: bool = x.use_ability(ab, {"position": x.global_position + Vector2(100, 0)})
	var one: bool = at_report.size() == 1
	var out := {"ok": ok, "reports": at_report.size(),
		"revealed_at_report": one and bool(at_report[0]["revealed"]),
		"hidden_at_report": String(at_report[0]["hidden"]) if one else "?",
		"outcry": not _ai(guard).pending_outcry.is_empty(),
		"unseen": _log_sum("No one saw it") - unseen0}
	TimeManager.game_time += 3.1
	return out


## The witnesses CrimeManager.witnesses_of finds for a crime at `crime_pos`
## (its surface's elevation) by `actor`, a victim's crime (not by hand).
func _witnesses(crime_pos: Vector2, actor) -> Array:
	var out: Array = []
	var elev: float = GridManager.effective_elev(GridManager.world_to_map(crime_pos))
	for e in CrimeManager.witnesses_of(crime_pos, elev, actor, false):
		out.append((e as Dictionary)["witness"])
	return out


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

	# --- within 2 tiles (plus the observer's body: the AI's close quarters)
	# the canopy factor is lifted (a short-sighted guard)
	var base_sight: float = guard.sight
	guard.sight = 0.15
	var short_px: float = ai.get_sight_range_pixels()
	var near_px: float = ai._close_quarters_radius()
	_check("a.short-sight", short_px * 0.5 < 128.0 and short_px > near_px + 12.0, "%.0f near %.0f" % [short_px, near_px])
	_place(guard, T1 + UNDER + Vector2(0, 120), Vector2.UP)
	_check("a.near-2-tiles-seen", ai.can_see_character(x) and is_equal_approx(x.visibility_to(guard), 1.0),
		x.visibility_to(guard))
	_place(guard, T1 + UNDER + Vector2(0, near_px - 3.0), Vector2.UP)
	_check("a.near-close-quarters-edge-seen", ai.can_see_character(x) and is_equal_approx(x.visibility_to(guard), 1.0),
		"%.2f at %.0f px" % [x.visibility_to(guard), near_px - 3.0])
	_place(guard, T1 + UNDER + Vector2(0, near_px + 6.0), Vector2.UP)
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
	# attacking shows it for 3 s from above too (only a crown between still
	# cuts the line then)
	x.reveal()
	_check("a.deck-viewer-reveal-seen", ai.can_see_character(x) and is_equal_approx(x.visibility_to(guard), 1.0)
		and not x.canopy_hides_from(guard) and CrimeManager.hidden_from(guard, x) == "", x.visibility_to(guard))
	TimeManager.game_time += 3.1
	_check("a.deck-viewer-reveal-ends", not ai.can_see_character(x) and x.canopy_hides_from(guard))
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
	# a low deck (0.6 stories: the eye clears the trunk, but it stands under a
	# story above the target) doesn't look down on the crown: a ground viewer
	var low_t := GridManager.world_to_map(T1 + UNDER + Vector2(0, sight_px * 0.4))
	GridManager.register_deck(low_t, 0.6)
	_place(guard, T1 + UNDER + Vector2(0, sight_px * 0.4), Vector2.UP)
	_check("a.low-deck-not-looking-down", cm.above_clearance(t1_i, guard.get_elevation())
		and not cm.looks_down_on(t1_i, guard.get_elevation(), x.get_elevation()), guard.get_elevation())
	_check("a.low-deck-viewer-half", is_equal_approx(x.visibility_to(guard), 0.5) and not x.canopy_hides_from(guard)
		and ai.can_see_character(x), x.visibility_to(guard))
	GridManager.unregister_deck(low_t, 0.6)
	_place(guard, guard.global_position, Vector2.UP)

	# --- the hold: a held target under a crown its holder looks down on (a
	# deck) is occluded like one behind a wall, and demoted after
	# TARGET_OCCLUSION_GIVE_UP; a ground holder at 0.6x keeps it (the factor
	# is acquisition's, as Shrouded's is)
	var hold_t := GridManager.world_to_map(T1 + UNDER + Vector2(0, sight_px * 0.4))
	GridManager.register_deck(hold_t, 1.5)
	_place(guard, T1 + UNDER + Vector2(0, sight_px * 0.4), Vector2.UP)
	ai._acquire_target(x)
	ai._update_target(1.0)
	_check("a.hold-deck-occluded", ai.current_target == x and not ai.is_target_in_sight() and x.canopy_hides_from(guard),
		"target %s occluded %.1f" % [str(ai.current_target), ai._target_occluded_time])
	for k in 5:
		ai._update_target(1.0)
	_check("a.hold-deck-demoted", ai.current_target == null, str(ai.current_target))
	# the crime position: from the deck nobody saw it happen under the crown
	_check("a.crime-pos-deck-unseen", not (guard in _witnesses(T1 + UNDER, y)))
	GridManager.unregister_deck(hold_t, 1.5)
	_place(guard, T1 + UNDER + Vector2(0, sight_px * 0.4), Vector2.UP)
	_check("a.crime-pos-ground-seen", guard in _witnesses(T1 + UNDER, y))
	_place(guard, T1 + UNDER + Vector2(0, sight_px * 0.6), Vector2.UP)
	ai._acquire_target(x)
	for k in 7:
		ai._update_target(1.0)
	_check("a.hold-ground-keeps", ai.current_target == x and ai.is_target_in_sight(), str(ai.current_target))
	ai._lose_target()
	var open_wdeck := GridManager.world_to_map(OPEN + Vector2(0, sight_px * 0.4))
	GridManager.register_deck(open_wdeck, 1.5)
	_place(guard, OPEN + Vector2(0, sight_px * 0.4), Vector2.UP)
	_check("a.crime-pos-deck-open-seen", guard in _witnesses(OPEN, y))
	GridManager.unregister_deck(open_wdeck, 1.5)
	# a theft under the crown seen from a deck: nobody saw it, under the trees
	GridManager.register_deck(hold_t, 1.5)
	_place(guard, T1 + UNDER + Vector2(0, sight_px * 0.4), Vector2.UP)
	var mark2 := _spawn("neutral", Vector2(6000, 5600), "Purse2")
	mark2.rotation = PI
	var deck_lines := _log_sum("No one saw it: Ximena was under the trees.")
	CrimeManager.report(x, "take", {"owner_faction": "liziti", "crime_pos": x.global_position, "debounce_target": mark2})
	_check("a.theft-deck-unseen-canopy", ai.pending_outcry.is_empty()
		and _log_sum("No one saw it: Ximena was under the trees.") == deck_lines + 1, str(GameLog.get_entries().slice(-2)))
	# a cast there (no crime_pos: the crime is at her feet). Casting shows her
	# from above for 3 s, and the act with her: the deck sees it happen.
	x.reveal(ProceduralCharacter.REVEAL_SECONDS, "casting", false)
	var cast_evaded: Array = []
	var cast_seen := false
	for e in CrimeManager.witnesses_of(x.global_position, x.get_elevation(), x, true, cast_evaded):
		cast_seen = cast_seen or ((e as Dictionary)["witness"] == guard and bool((e as Dictionary)["sees_actor"]))
	var unseen_lines := _log_sum("No one saw it")
	var alert0: float = ai.alertness_value
	var at_ease0: bool = ai.is_at_ease
	CrimeManager.report(x, "cast", {"law_faction": "patriciate", "traits": {"necrotic": 1}})
	_check("a.cast-deck-reveal-witnessed", not x.canopy_hides_from(guard) and cast_seen and cast_evaded.is_empty()
		and not ai.pending_outcry.is_empty() and _log_sum("No one saw it") == unseen_lines,
		"evaded %s outcry %s log %s" % [str(cast_evaded), str(ai.pending_outcry), str(GameLog.get_entries().slice(-2))])
	for c in characters_in_scene:   # drop the lit fuses (Yusuf on the ground may have one too)
		var cai = c.get_node_or_null("AI")
		if cai != null:
			cai.pending_outcry = {}
			cai._outcry_timer = -1.0
	ai.is_at_ease = at_ease0
	ai._set_alertness_value(alert0)
	TimeManager.game_time += 3.1
	# out of the window the crown hides the act from the deck again, as it hides her
	cast_evaded = []
	var deck_sees_after := false
	for e in CrimeManager.witnesses_of(x.global_position, x.get_elevation(), x, true, cast_evaded):
		deck_sees_after = deck_sees_after or (e as Dictionary)["witness"] == guard
	_check("a.cast-deck-after-reveal-unseen", not deck_sees_after and x.canopy_hides_from(guard) and "Canopy" in cast_evaded,
		str(cast_evaded))
	# The same for real: an instant cast (no windup) through her own
	# use_ability, a crime under Waldau's law. Its crime is reported inside
	# that call, so the window opens when the cast is committed
	# (AbilityManager.cast_committed), before it resolves: the deck sees it
	# happen. So does a ground guard at 0.6x, and a guard at 0.6x sees a
	# Shrouded caster's in the open. ("No one saw it" in each while the reveal
	# came after the call.) An item's cast, straight to the AbilityManager,
	# still shows nothing.
	var law_map := "__canopy_waldau"
	MapDatabase._maps[law_map] = {"id": law_map, "controlling_faction": "waldau"}
	var map0: String = current_map_id
	current_map_id = law_map
	x.npc_unlimited_resources = true
	var charm := Ability.from_dict({"id": "canopy_instant_charm", "display_name": "Test Instant Charm", "cast_time": 0.0,
		"traits": {"charm": 1}, "targeting": {"type": "point", "range": 300.0, "shape": "circle", "radius": 10.0}, "effects": []})
	var at_report: Array = []
	var hook := func(_eff, _verdict, _payload): at_report.append({"revealed": x._canopy_revealed(),
		"hidden": CrimeManager.hidden_from(guard, x)})
	CrimeManager.crime_committed.connect(hook)
	alert0 = ai.alertness_value
	at_ease0 = ai.is_at_ease
	var verdict_ok: bool = str(CrimeManager.preview(x, "cast", CrimeManager.cast_payload(charm)).get("statute", "")) == "mind_magic"
	_check("a.instant-cast-setup", verdict_ok and x.canopy_hides_from(guard) and not x._canopy_revealed(), "")
	var ic: Dictionary = _instant_cast(x, guard, charm, at_report)
	_check("a.instant-cast-deck-witnessed", bool(ic["ok"]) and bool(ic["revealed_at_report"]) and ic["hidden_at_report"] == ""
		and bool(ic["outcry"]) and int(ic["unseen"]) == 0, ic)
	GridManager.unregister_deck(hold_t, 1.5)
	_place(guard, T1 + UNDER + Vector2(0, sight_px * 0.6), Vector2.UP)
	ic = _instant_cast(x, guard, charm, at_report)
	_check("a.instant-cast-ground-witnessed", bool(ic["ok"]) and bool(ic["revealed_at_report"]) and ic["hidden_at_report"] == ""
		and bool(ic["outcry"]) and int(ic["unseen"]) == 0, ic)
	var shroud_spot := Vector2(3000, 3000)
	_place(x, shroud_spot, Vector2.UP)
	_place(guard, shroud_spot + Vector2(0, sight_px * 0.6), Vector2.UP)
	x.visibility_mult = 0.5
	_check("a.instant-cast-shrouded-setup", x.canopy_crown() == -1 and CrimeManager.hidden_from(guard, x) == "Shrouded",
		CrimeManager.hidden_from(guard, x))
	ic = _instant_cast(x, guard, charm, at_report)
	_check("a.instant-cast-shrouded-witnessed", bool(ic["ok"]) and ic["hidden_at_report"] == ""
		and bool(ic["outcry"]) and int(ic["unseen"]) == 0, ic)
	x.visibility_mult = 1.0
	_place(x, T1 + UNDER, Vector2.UP)
	_place(guard, T1 + UNDER + Vector2(0, sight_px * 0.6), Vector2.UP)
	at_report.clear()
	var item_ok: bool = x.ability_manager.use_ability(charm, {"position": x.global_position + Vector2(100, 0), "free": true})
	_check("a.instant-cast-item-unrevealed", item_ok and at_report.size() == 1 and not bool(at_report[0]["revealed"])
		and not x._canopy_revealed(), at_report)
	TimeManager.game_time += 3.1
	CrimeManager.crime_committed.disconnect(hook)
	for c in characters_in_scene:
		var cai = c.get_node_or_null("AI")
		if cai != null:
			cai.pending_outcry = {}
			cai._outcry_timer = -1.0
	ai.is_at_ease = at_ease0
	ai._set_alertness_value(alert0)
	x.npc_unlimited_resources = false
	current_map_id = map0
	MapDatabase._maps.erase(law_map)
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
	y.reveal()
	_check("a.band-reveal-still-blocked", is_equal_approx(y.visibility_to(guard), 0.0) and y.canopy_hides_from(guard))
	TimeManager.game_time += 3.1
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
	var mem0: float = Performance.get_monitor(Performance.MEMORY_STATIC)
	var t0: int = Time.get_ticks_usec()
	var acc := 0.0
	for k in 10000:
		acc += x.visibility_to(guard)
	var us: float = float(Time.get_ticks_usec() - t0) / 10000.0
	# Objects and the static heap only show what is LEFT after the loop (no
	# leak, no growth); that nothing is allocated per call is the code's own
	# (packed arrays and values only, read from the model).
	var mem_grew: float = Performance.get_monitor(Performance.MEMORY_STATIC) - mem0
	_check("a.visibility-to-no-objects-or-growth", is_equal_approx(Performance.get_monitor(Performance.OBJECT_COUNT), objs)
		and mem_grew < 16384.0, "objects %+.0f, static heap %+.0f B" % [Performance.get_monitor(Performance.OBJECT_COUNT) - objs, mem_grew])
	print("INFO visibility_to %.2f us/call (sum %.0f)" % [us, acc])
	_check("a.visibility-to-cheap", us < 200.0, us)
	await _clear_chars()
	await _clear_trees()


# ---------------------------------------------------------------------------
# A2. Synthetic, relief: a viewer on a cliff top
# ---------------------------------------------------------------------------

const SLOPE_TREE := Vector2(2010, 1000)   # its trunk tile (31, 15) at ground 0
const SLOPE_Q := Vector2(2055, 1000)      # its overhang, on the 0.6 terrace (tile 32)
const SLOPE_LOW := Vector2(1980, 1035)    # its overhang on the low side (tile (30, 16), ground 0)
const CLIFF_TREE := Vector2(2600, 1860)   # at the cliff's foot (tile (40, 29)): its crown reaches the edge
const CLIFF_Q := Vector2(2645, 1860)      # its overhang (tile (41, 29), ground 0)
const CLIFF_EDGE := Vector2(2645, 1924)   # the cliff top right above it (tile (41, 30), 3 stories)

func _part_a_relief() -> void:
	GridManager.TILE_SIZE = 64
	GridManager.initialize(4096, 4096)
	# the cliff: every tile from row 30 down stands 3 stories up
	for ty in range(30, 64):
		for tx in range(64):
			GridManager.elevations[Vector2i(tx, ty)] = 3.0
	# a hillside step under a crown: from tile column 32 the ground is 0.6 up
	# (rows 10-20), from column 36 a story higher again (1.7)
	for ty in range(10, 21):
		for tx in range(32, 64):
			GridManager.elevations[Vector2i(tx, ty)] = 0.6 if tx < 36 else 1.7
	GridManager.refresh_terrain_stats()
	_check("a2.relief-on", GridManager.relief_los)
	_ml = MAP_LOADER.new()
	add_child(_ml)
	var tree_pos := Vector2(1000, 1300)
	_spawn_tree(_tree_row(tree_pos, 60.0, 1.3))
	_spawn_tree(_tree_row(SLOPE_TREE, 60.0, 1.3))
	_spawn_tree(_tree_row(CLIFF_TREE, 60.0, 1.3))
	GridManager.canopy.finish()
	await _settle()
	var cm = GridManager.canopy
	var x := _spawn("player", tree_pos + UNDER, "Ximena")
	var y := _spawn("player", Vector2(1600, 1345), "Yusuf")
	var guard := _spawn("bandits", Vector2(1000, 30 * 64 + 32), "Lookout")
	var ai = _ai(guard)
	var rec: Dictionary = GridManager.canopy.crown(0)
	_check("a2.tree-on-low-ground", not rec.is_empty() and is_equal_approx(float(rec["ground"]), 0.0), rec)
	_check("a2.viewer-on-cliff", is_equal_approx(guard.get_elevation(), 3.0) and guard.height_above_ground() < 0.01,
		guard.get_elevation())
	# On the cliff's edge, 9 tiles from the tree: 3 stories up, but the eye
	# line runs in under the crown (it enters the disc at ~0.6 stories, below
	# the 1-story clearance), so a ground observer: the factor, not the block.
	_place(guard, Vector2(1000 + 45, 30 * 64 + 32), x.global_position - Vector2(1045, 30 * 64 + 32))
	_check("a2.cliff-far-line-under-crown-half", cm.looks_down_on(0, guard.get_elevation(), x.get_elevation())
		and not cm.eye_line_in_crown(0, guard.global_position, guard.get_elevation(), x.global_position, x.get_elevation())
		and is_equal_approx(x.visibility_to(guard), 0.5) and not x.canopy_hides_from(guard), x.visibility_to(guard))
	_place(guard, Vector2(1600, 30 * 64 + 32), y.global_position - Vector2(1600, 30 * 64 + 32))
	_check("a2.cliff-viewer-sees-open", ai.can_see_character(y))
	# a ground viewer level with the tree (beyond 2 tiles, within half sight;
	# beside it, so the line misses the trunk)
	var low := _spawn("bandits", x.global_position + Vector2(300, 0), "Walker")
	_face(low, x.global_position)
	_check("a2.ground-viewer-half-range", _ai(low).can_see_character(x) and is_equal_approx(x.visibility_to(low), 0.5))
	# A cliff edge right over a crown at its foot: the eye line drops through
	# the leaves (it enters the disc at ~2.4 stories), so the crown blocks.
	var ci: int = cm.crown_at(CLIFF_Q, 0.0)
	_place(x, CLIFF_Q, Vector2.UP)
	_place(guard, CLIFF_EDGE, CLIFF_Q - CLIFF_EDGE)
	_check("a2.cliff-edge-setup", ci >= 0 and x.canopy_crown() == ci and is_equal_approx(guard.get_elevation(), 3.0)
		and guard.height_above_ground() < 0.01, "%d %.2f" % [ci, guard.get_elevation()])
	_check("a2.cliff-edge-hidden", cm.eye_line_in_crown(ci, guard.global_position, guard.get_elevation(), x.global_position, x.get_elevation())
		and is_equal_approx(x.visibility_to(guard), 0.0) and x.canopy_hides_from(guard) and not ai.can_see_character(x)
		and CrimeManager.hidden_from(guard, x) == "Canopy", x.visibility_to(guard))
	_place(x, tree_pos + UNDER, Vector2.UP)

	# --- a crown overhanging a terrace step: the target on the overhang and a
	# viewer level with it both stand 0.6 above the trunk's ground (their eyes
	# over its flat 1-story clearance), yet neither looks down on the other
	var si: int = cm.crown_at(SLOPE_Q, 0.6)
	_place(x, SLOPE_Q, Vector2.UP)
	_check("a2.slope-target-under", si >= 0 and x.canopy_crown() == si and is_equal_approx(x.get_elevation(), 0.6)
		and is_equal_approx(float(cm.crown(si)["ground"]), 0.0), "%d %.2f" % [si, x.get_elevation()])
	_place(low, SLOPE_Q + Vector2(100, 0), Vector2.LEFT)
	_check("a2.slope-near-same-level-seen", cm.above_clearance(si, low.get_elevation())
		and is_equal_approx(x.visibility_to(low), 1.0) and not x.canopy_hides_from(low) and _ai(low).can_see_character(x)
		and CrimeManager.hidden_from(low, x) == "", "vis %.2f elev %.2f" % [x.visibility_to(low), low.get_elevation()])
	_place(low, SLOPE_Q + Vector2(200, 0), Vector2.LEFT)
	_check("a2.slope-far-same-level-half", is_equal_approx(x.visibility_to(low), 0.5) and not x.canopy_hides_from(low),
		x.visibility_to(low))
	# a story up (the 1.7 terrace): the eye line drops into the crown through
	# the leaves (it enters at ~1.15, over the 1.0 clearance) to the target's
	# eye in them
	_place(low, SLOPE_Q + Vector2(300, 0), Vector2.LEFT)
	_check("a2.slope-story-up-blocked", is_equal_approx(low.get_elevation(), 1.7) and is_equal_approx(x.visibility_to(low), 0.0)
		and cm.eye_line_in_crown(si, low.global_position, low.get_elevation(), x.global_position, x.get_elevation())
		and x.canopy_hides_from(low) and not _ai(low).can_see_character(x) and CrimeManager.hidden_from(low, x) == "Canopy",
		"vis %.2f elev %.2f" % [x.visibility_to(low), low.get_elevation()])
	# the same viewer, the target on the crown's low side (ground 0): a story
	# and more up, but the eye line runs in under the crown (it enters at
	# ~0.8): a ground observer, the factor
	_place(x, SLOPE_LOW, Vector2.UP)
	_place(low, Vector2(2400, SLOPE_LOW.y), Vector2.LEFT)
	_check("a2.story-up-line-under-crown-half", x.canopy_crown() == si and is_equal_approx(low.get_elevation(), 1.7)
		and cm.looks_down_on(si, low.get_elevation(), x.get_elevation())
		and not cm.eye_line_in_crown(si, low.global_position, low.get_elevation(), x.global_position, x.get_elevation())
		and is_equal_approx(x.visibility_to(low), 0.5) and not x.canopy_hides_from(low),
		"crown %d vis %.2f elev %.2f/%.2f" % [x.canopy_crown(), x.visibility_to(low), x.get_elevation(), low.get_elevation()])
	await _clear_chars()
	await _clear_trees()


# ---------------------------------------------------------------------------
# A2b. Synthetic, relief: a grove under a cliff
# ---------------------------------------------------------------------------

const GROVE_A := Vector2(1000, 1500)     # r 60, trunk 27, ground 0, base 1, top 2
const GROVE_B := Vector2(1000, 1580)     # overlaps A: one cluster
const GROVE_Q := Vector2(1000, 1540)     # in the overlap, outside both trunks
const GROVE_VIEW := Vector2(1000, 1952)  # the cliff top (row 30 on, 3 stories)

## Two overlapping crowns over the target; the cliff viewer's eye line runs in
## under A (about 0.65 stories where it enters A's disc) and through B's
## leaves (about 1.23). Whichever crown was registered first, B hides it.
func _part_a_grove() -> void:
	for b_first in [false, true]:
		GridManager.TILE_SIZE = 64
		GridManager.initialize(4096, 4096)
		for ty in range(30, 64):
			for tx in range(64):
				GridManager.elevations[Vector2i(tx, ty)] = 3.0
		GridManager.refresh_terrain_stats()
		var cm = GridManager.canopy
		var order: Array = [GROVE_B, GROVE_A] if b_first else [GROVE_A, GROVE_B]
		for p in order:
			cm.add_crown(p, 60.0, 27.0, 0.0, 1.0, 2.0)
		cm.finish()
		var ia: int = order.find(GROVE_A)
		var ib: int = order.find(GROVE_B)
		var tag: String = "b-first" if b_first else "a-first"
		_check("a2g.%s-setup" % tag, GridManager.relief_los and cm.cluster_of(ia) == cm.cluster_of(ib)
			and cm.crown_at(GROVE_Q, 0.0) == mini(ia, ib)
			and not cm.eye_line_in_crown(ia, GROVE_VIEW, 3.0, GROVE_Q, 0.0) and cm.eye_line_in_crown(ib, GROVE_VIEW, 3.0, GROVE_Q, 0.0)
			and not cm.line_blocked(GROVE_VIEW, GROVE_Q, 3.0, 0.0))
		_check("a2g.%s-blocks-view" % tag, cm.blocks_view(GROVE_VIEW, 3.0, GROVE_Q, 0.0, 0))
		var x := _spawn("player", GROVE_Q, "Ximena")
		var guard := _spawn("bandits", GROVE_VIEW, "Lookout")
		_face(guard, GROVE_Q)
		await _settle()
		_check("a2g.%s-hidden" % tag, is_equal_approx(guard.get_elevation(), 3.0) and not GridManager.is_high_layer(guard)
			and x.canopy_hides_from(guard) and is_equal_approx(x.visibility_to(guard), 0.0) and not _ai(guard).can_see_character(x),
			"elev %.2f vis %.2f" % [guard.get_elevation(), x.visibility_to(guard)])
		await _clear_chars()


# ---------------------------------------------------------------------------
# B. The model from real maps' tree rows
# ---------------------------------------------------------------------------

func _part_b_real_rows(map_id: String, expect_relief: bool) -> void:
	var data: Dictionary = MapDatabase.get_map_data(map_id)
	_check("b.%s-has-data" % map_id, not data.is_empty())
	if data.is_empty():
		return
	var ws: Array = data.get("world_size", [2048, 2048])
	GridManager.TILE_SIZE = int(data.get("tile_size", 64))
	GridManager.initialize(int(ws[0]), int(ws[1]))
	# the map's real terrain, as Game.load_map sets it before the structures
	var cg_path: String = String(data.get("cell_graph", ""))
	var graph: CellGraph = CellGraph.from_structured(cg_path) if cg_path != "" else null
	GridManager.set_elevation_data(graph)
	_check("b.%s-terrain" % map_id, graph != null and GridManager.relief_los == expect_relief
		and (GridManager.tile_elev_used or not expect_relief),
		"relief %s tile_elev %s" % [GridManager.relief_los, GridManager.tile_elev_used])
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
	# each crown stands on the terrain under its trunk (no decks here)
	var ground_bad := []
	var ground_max := -INF
	for i in cm.crown_count():
		var grec: Dictionary = cm.crown(i)
		var want_g: float = GridManager.terrain_elev(GridManager.world_to_map(grec["pos"]))
		ground_max = maxf(ground_max, float(grec["ground"]))
		if not is_equal_approx(float(grec["ground"]), want_g):
			ground_bad.append("%d: %.3f vs %.3f" % [i, float(grec["ground"]), want_g])
	_check("b.%s-crown-ground-is-terrain" % map_id, ground_bad.is_empty() and (ground_max > 1.0 or not expect_relief),
		"max %.2f %s" % [ground_max, str(ground_bad.slice(0, 4))])
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
	if expect_relief:
		_relief_survey(map_id, cm)
	await _clear_trees()


## Every crown of a relief map: targets on its overhang (8 bearings at mid
## radius, on the terrain), viewers around each on open ground (16 bearings,
## 1 to 10 tiles out). Within 2 tiles at the target's level (+-0.25 stories)
## none is blocked: the slope case the flat trunk clearance alone got wrong
## (the old rule, above_clearance by itself, is counted for the INFO line).
## Further out (the 2-10 tile ring, viewers on the terrain): how many stand a
## story up over the crown (looks_down_on, enough from a roof or a deck), and
## how many of those the target's crown blocks (the eye line in through the
## leaves); none whose eye line runs in under the crown is blocked by it.
## Then blocks_view's cost on the ring pairs past its quick reject (eyes
## inside the crowns' height span: the tile walk runs).
func _relief_survey(map_id: String, cm) -> void:
	var near_px: float = float(GridManager.TILE_SIZE) * ProceduralCharacter.CANOPY_NEAR_TILES
	var near_pairs := 0
	var near_blocked := 0
	var near_old := 0
	var old_crowns: Dictionary = {}
	var ring := 0
	var ring_new := 0
	var ring_old := 0
	var ring_story := 0
	var under_blocked := 0
	var walk_v := PackedVector2Array()
	var walk_q := PackedVector2Array()
	var walk_e := PackedFloat32Array()
	var walk_f := PackedFloat32Array()
	var eye: float = GridManager.EYE_HEIGHT_STORIES
	var bad := []
	for i in cm.crown_count():
		var rec: Dictionary = cm.crown(i)
		var p: Vector2 = rec["pos"]
		var mid: float = (float(rec["r"]) + float(rec["trunk_r"])) * 0.5
		for a in 8:
			var q: Vector2 = p + Vector2.RIGHT.rotated(TAU * a / 8.0) * mid
			var qt := GridManager.world_to_map(q)
			if not GridManager.map_rect.has_point(qt):
				continue
			var f: float = GridManager.effective_elev(qt)
			if cm.crown_at(q, f) != i:
				continue
			for b in 16:
				var u: Vector2 = Vector2.RIGHT.rotated(TAU * b / 16.0)
				for d in [64.0, 96.0, 128.0, 192.0, 256.0, 384.0, 512.0, 640.0]:
					var v: Vector2 = q + u * float(d)
					var vt := GridManager.world_to_map(v)
					if not GridManager.map_rect.has_point(vt):
						continue
					var e: float = GridManager.effective_elev(vt)
					if cm.crown_at(v, e) >= 0:
						continue
					var old: bool = cm.above_clearance(i, e)
					if float(d) <= near_px:
						if absf(e - f) > 0.25:
							continue
						near_pairs += 1
						if old:
							near_old += 1
							old_crowns[i] = true
						if cm.blocks_view(v, e, q, f):
							near_blocked += 1
							if bad.size() < 6:
								bad.append("crown %d q %s v %s (%.2f/%.2f)" % [i, str(q), str(v), f, e])
					else:
						ring += 1
						if old:
							ring_old += 1
						if cm.looks_down_on(i, e, f):
							ring_story += 1
							if cm.eye_line_in_crown(i, v, e, q, f):
								ring_new += 1
							elif cm.blocks_view(v, e, q, f, 0) and not cm.line_blocked(v, q, e, f):
								under_blocked += 1
						if walk_v.size() < 2000 and maxf(e, f) + eye >= cm._min_base_abs and minf(e, f) + eye <= cm._max_top_abs:
							walk_v.append(v)
							walk_q.append(q)
							walk_e.append(e)
							walk_f.append(f)
	_check("b.%s-relief-near-same-level-seen" % map_id, near_pairs > 0 and near_blocked == 0,
		"pairs %d blocked %d %s" % [near_pairs, near_blocked, str(bad)])
	_check("b.%s-relief-line-under-crown-not-blocked" % map_id, ring_story > ring_new and under_blocked == 0,
		"story up %d, through the leaves %d, blocked under the crown %d" % [ring_story, ring_new, under_blocked])
	print("INFO %s relief survey: %d same-level pairs within 2 tiles, 0 allowed blocked, %d blocked by the old rule (%d crowns); 2-10 tile ring %d spots: %.1f%% a story up (the roof/deck rule), %.1f%% blocked from the terrain (eye line through the leaves; old rule %.1f%%)"
		% [map_id, near_pairs, near_old, old_crowns.size(), ring, 100.0 * ring_story / maxf(1.0, ring),
			100.0 * ring_new / maxf(1.0, ring), 100.0 * ring_old / maxf(1.0, ring)])
	# the cost where it is paid: relief pairs that get past the quick reject
	var calls := 0
	var hits := 0
	var t0: int = Time.get_ticks_usec()
	while calls < 10000 and not walk_v.is_empty():
		for k in walk_v.size():
			if cm.blocks_view(walk_v[k], walk_e[k], walk_q[k], walk_f[k], 0):
				hits += 1
			calls += 1
	var us: float = float(Time.get_ticks_usec() - t0) / float(maxi(1, calls))
	print("INFO %s blocks_view on relief: %.2f us/call over %d calls (%d ring pairs past the quick reject, %.1f%% blocked)"
		% [map_id, us, calls, walk_v.size(), 100.0 * hits / maxf(1.0, calls)])
	_check("b.%s-relief-blocks-view-cheap" % map_id, walk_v.size() > 0 and us < 200.0, "%.2f us over %d pairs" % [us, walk_v.size()])


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
		var killed_before: int = _killed.size()
		tree_s.take_damage({"slashing": 9999})
		for i in 3:
			await get_tree().process_frame
		# part A's crown_changed listener is still connected: one CanopyMap,
		# cleared per map, across every GridManager.initialize since
		_check("c.felled-npc-seen", not bool(cm.crown(ci)["alive"]) and npc.visible and game.is_seen_by_party(npc)
			and _killed.size() == killed_before + 1 and int(_killed[-1]) == ci, "killed %s" % str(_killed.slice(killed_before)))
	for pc in saved_sight:
		pc.sight = saved_sight[pc]
	await _part_c_relief(game)


# ---------------------------------------------------------------------------
# C2. The real Game on Perrow's relief (tg_hillside_middle)
# ---------------------------------------------------------------------------

func _part_c_relief(game) -> void:
	game.load_map("tg_hillside_middle")
	for i in 10:
		await get_tree().process_frame
	if PauseManager.is_paused:
		PauseManager.unpause()
	TimeManager.pause_time()
	_check("c2.loaded-relief", game.party_chars.size() > 0 and String(game.current_map_id) == "tg_hillside_middle"
		and GridManager.relief_los)
	if game.party_chars.is_empty():
		return
	for c in game.characters_in_scene:
		if is_instance_valid(c):
			c.AI_enabled = false
	var cm = GridManager.canopy
	var leader: ProceduralCharacter = game.party_chars[0]
	for pc in game.party_chars:
		if pc != leader:
			pc.sight = 0.0   # only the leader looks
	leader.sight = 0.4
	var found: Dictionary = _find_relief_setups(leader)
	print("INFO relief setups: %s" % str(found))
	_check("c2.found-near-same-level", found.has("near"))
	_check("c2.found-uphill-under-a-story", found.has("uphill"))
	_check("c2.found-story-up", found.has("up"))
	_check("c2.found-story-up-line-under", found.has("up_under"))
	var lurker = game._spawn_character("default_human", leader.global_position + Vector2(40, 0), {"faction": "bandits"})
	var watcher = game._spawn_character("default_human", leader.global_position + Vector2(-40, 0), {"faction": "bandits"})
	_check("c2.npcs-spawned", lurker != null and watcher != null)
	if lurker == null or watcher == null:
		return
	lurker.AI_enabled = false
	lurker.Name = "Lurker"
	watcher.AI_enabled = false
	watcher.Name = "Watcher"
	var wai = _ai(watcher)
	if found.has("near"):
		# A same-level pair a tile or two apart on the slope under a crown
		# that stands lower: both eyes are over its flat trunk clearance (the
		# old rule's 'elevated'), yet they see each other normally.
		var s: Dictionary = found["near"]
		var q: Vector2 = s["q"]
		var v: Vector2 = s["v"]
		_place(lurker, q, Vector2.UP)
		_place(watcher, v + Vector2(2000, 2000), Vector2.UP)   # out of the way
		_place(leader, v, q - v)
		for i in 4:
			await get_tree().process_frame
		_check("c2.near-same-level-seen", lurker.canopy_crown() == int(s["crown"]) and cm.above_clearance(int(s["crown"]), leader.get_elevation())
			and is_equal_approx(lurker.visibility_to(leader), 1.0) and lurker.visible and game.is_seen_by_party(lurker),
			"vis %.2f visible %s elev %.2f/%.2f" % [lurker.visibility_to(leader), lurker.visible, lurker.get_elevation(), leader.get_elevation()])
		# the other way round: a guard level with the party member under the crown
		_place(lurker, v + Vector2(2000, -2000), Vector2.UP)
		_place(leader, q, Vector2.UP)
		_place(watcher, v, q - v)
		_check("c2.near-same-level-guard-sees", wai.can_see_character(leader) and CrimeManager.hidden_from(watcher, leader) == "",
			"vis %.2f" % leader.visibility_to(watcher))
	if found.has("uphill"):
		# uphill but under a story above the target, beyond 2 tiles: the
		# factor, not the block
		var s: Dictionary = found["uphill"]
		var q: Vector2 = s["q"]
		var v: Vector2 = s["v"]
		_place(lurker, q, Vector2.UP)
		_place(watcher, v + Vector2(2000, 2000), Vector2.UP)
		_place(leader, v, q - v)
		_check("c2.uphill-under-a-story-half", is_equal_approx(lurker.visibility_to(leader), 0.5) and not lurker.canopy_hides_from(leader),
			"vis %.2f elev %.2f/%.2f" % [lurker.visibility_to(leader), lurker.get_elevation(), leader.get_elevation()])
	if found.has("up_under"):
		# a story or more up the slope, beyond 2 tiles, but the eye line runs
		# in under the crown: a ground observer (the factor), both ways, and
		# a guard there keeps holding a party member who steps under it
		var s: Dictionary = found["up_under"]
		var q: Vector2 = s["q"]
		var v: Vector2 = s["v"]
		_place(lurker, q, Vector2.UP)
		_place(watcher, v + Vector2(2000, 2000), Vector2.UP)
		_place(leader, v, q - v)
		_check("c2.story-up-line-under-half", is_equal_approx(lurker.visibility_to(leader), 0.5) and not lurker.canopy_hides_from(leader),
			"vis %.2f elev %.2f/%.2f" % [lurker.visibility_to(leader), lurker.get_elevation(), leader.get_elevation()])
		_place(lurker, v + Vector2(2000, -2000), Vector2.UP)
		_place(leader, q, Vector2.UP)
		_place(watcher, v, q - v)
		wai._acquire_target(leader)
		for i in 6:
			wai._update_target(1.0)
		_check("c2.story-up-line-under-guard-holds", is_equal_approx(leader.visibility_to(watcher), 0.5)
			and not leader.canopy_hides_from(watcher) and wai.current_target == leader and wai.is_target_in_sight(),
			"vis %.2f target %s" % [leader.visibility_to(watcher), str(wai.current_target)])
		wai._lose_target()
	if found.has("up"):
		# a story or more up, the eye line in through the leaves: blocked,
		# from the party's eyes and a guard's, until the tree falls
		var s: Dictionary = found["up"]
		var q: Vector2 = s["q"]
		var v: Vector2 = s["v"]
		var ci: int = int(s["crown"])
		_place(lurker, q, Vector2.UP)
		_place(watcher, v + Vector2(2000, 2000), Vector2.UP)
		_place(leader, v, q - v)
		for i in 4:
			await get_tree().process_frame
		_check("c2.story-up-npc-hidden", lurker.canopy_crown() == ci and is_equal_approx(lurker.visibility_to(leader), 0.0)
			and not lurker.visible and not game.is_seen_by_party(lurker),
			"vis %.2f visible %s elev %.2f/%.2f" % [lurker.visibility_to(leader), lurker.visible, lurker.get_elevation(), leader.get_elevation()])
		_place(lurker, v + Vector2(2000, -2000), Vector2.UP)
		_place(leader, q, Vector2.UP)
		_place(watcher, v, q - v)
		_check("c2.story-up-guard-blind", leader.canopy_crown() == ci and not wai.can_see_character(leader)
			and CrimeManager.hidden_from(watcher, leader) == "Canopy", "vis %.2f" % leader.visibility_to(watcher))
		var killed_before: int = _killed.size()
		cm.kill_crown(ci)
		_check("c2.kill-notifies-listener", _killed.size() == killed_before + 1 and int(_killed[-1]) == ci)
		_check("c2.story-up-guard-sees-once-felled", wai.can_see_character(leader) and CrimeManager.hidden_from(watcher, leader) == "")
		_place(watcher, v + Vector2(2000, 2000), Vector2.UP)
		_place(lurker, q, Vector2.UP)
		_place(leader, v, q - v)
		for i in 4:
			await get_tree().process_frame
		_check("c2.story-up-npc-seen-once-felled", lurker.visible and game.is_seen_by_party(lurker))


## On the loaded relief map, for the leader's sight: a live crown with a spot
## q under it an NPC can stand on, and open ground v for a viewer with a clear
## sight line to q (walls, terrain and every other crown):
##   near      64-120 px off, within 0.25 stories of q, its eye over the
##             crown's trunk clearance (what the old rule called elevated);
##   uphill    beyond 2 tiles, 0.3-0.9 stories above q, eye over the clearance;
##   up        beyond 2 tiles, at least a story above q, the eye line into the
##             crown through the leaves (eye_line_in_crown);
##   up_under  beyond 2 tiles, at least a story above q, the eye line in
##             under the crown (a slope viewer, not one looking down through it).
## Each within 0.8 of the leader's sight range from there. Missing keys: none.
func _find_relief_setups(leader: ProceduralCharacter) -> Dictionary:
	var cm = GridManager.canopy
	var space := leader.get_world_2d().direct_space_state
	var near_px: float = float(GridManager.TILE_SIZE) * ProceduralCharacter.CANOPY_NEAR_TILES
	var out: Dictionary = {}
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
			if not GridManager.map_rect.has_point(qt) or not GridManager.would_walk(qt) or GridManager.is_solid_rock(qt) \
					or GridManager.has_roof(qt):
				continue
			var q_elev: float = GridManager.effective_elev(qt)
			if cm.crown_at(q, q_elev) != i:
				continue
			for b in 16:
				var u: Vector2 = Vector2.RIGHT.rotated(TAU * b / 16.0)
				for d in [64.0, 96.0, 120.0, 192.0, 256.0, 320.0, 384.0, 448.0]:
					var v: Vector2 = q + u * float(d)
					var vt := GridManager.world_to_map(v)
					if not GridManager.map_rect.has_point(vt) or not GridManager.would_walk(vt) \
							or GridManager.is_solid_rock(vt) or GridManager.has_roof(vt):
						continue
					var v_elev: float = GridManager.effective_elev(vt)
					if cm.crown_at(v, v_elev) >= 0:
						continue
					var rise: float = v_elev - q_elev
					var key: String = ""
					if float(d) <= near_px:
						if absf(rise) <= 0.25 and cm.above_clearance(i, v_elev):
							key = "near"
					elif rise >= GridManager.HIGH_LAYER_STORIES:
						key = "up" if cm.eye_line_in_crown(i, v, v_elev, q, q_elev) else "up_under"
					elif rise >= 0.3 and rise <= 0.9 and cm.above_clearance(i, v_elev):
						key = "uphill"
					if key == "" or out.has(key):
						continue
					var save_pos: Vector2 = leader.global_position
					leader.global_position = v
					var rng: float = leader.get_sight_range_px_to(q)
					leader.global_position = save_pos
					if float(d) > rng * 0.8:
						continue
					if not GridManager.sight_line_clear(space, v, q, v_elev, q_elev) or cm.line_blocked(v, q, v_elev, q_elev):
						continue
					out[key] = {"crown": i, "q": q, "v": v, "rise": snappedf(rise, 0.01)}
			if out.size() == 4:
				return out
	return out


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
