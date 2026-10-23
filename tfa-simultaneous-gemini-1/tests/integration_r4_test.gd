extends Node2D
# Round 4 integration review. Each lane was reviewed alone; these checks cover
# where two round-4 lanes meet:
#   1. DoT x Invisible and the AI: a guard that lost a cloaked attacker when
#      Invisible came back is not handed them again by the Burning that
#      attacker lit on it (the ticks carry the attacker as their source): one
#      "loses sight" line, no re-acquiring and no repeat while it burns, and
#      the ticks don't reveal the attacker.
#   2. The DoT summary x the Shrouded reveal: while an attack's reveal window
#      has lifted a Dark Hood's Shrouded, every display of it says so
#      ("Shrouded (revealed 3s)"), and the party panel pip dims and the hover
#      mutes it, as the overhead icon dims; a DoT beside it keeps its own
#      wording; plain again after.
#   3. The stackable refresh x travel and downtime hours: two downtime
#      Exhausted results hours apart keep it a day from the later one
#      ("Gained: Exhausted (24h 00m)"), and Fatigued reaching 3 stacks
#      refreshes an existing Exhausted the same way.
#   4. Warp mid-window: the restored character arrives concealed (the window
#      isn't saved, so neither is its "revealed"), tinted, with an old save's
#      Poisoned x10 held to today's cap.
# Real ProceduralCharacter.tscn instances on a stub Game surface (as in
# stealth_ai_r4_test). Headless-safe.
#   godot --headless --path . res://tests/integration_r4_test.tscn
# Judge by the PASS/FAIL lines and "HARNESS DONE failures=0".

const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const GAME_SCRIPT := preload("res://Game.gd")
const HOVER := preload("res://UI/WorldHoverInfo.gd")
const PANEL := preload("res://UI/PartySidePanel.gd")
const APPLIER := preload("res://scripts/DowntimeEffectApplier.gd")
const TINT := Color(0.5, 0.47, 0.62)

# --- Game stub surface (ai.gd, ProceduralCharacter and CrimeManager touch these) ---
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
var current_map_id: String = "test"
var current_map_data: Dictionary = {}
const MELEE_ELEV_TOLERANCE: float = 0.5

var _seen: Dictionary = {}   # is_seen_by_party stand-in for NPCs

func can_hit_target(_a: Node2D, _t: Node2D) -> bool: return true
func register_hit(_a: Node2D, _t: Node2D) -> void: pass
func register_attack_start(_a: Node2D) -> void: pass
func register_attack_end(_a: Node2D) -> void: pass
func resolve_melee_swing(_a: Node2D, _hand: String) -> void: pass
func process_weapon_hit(_a, _t, _p, _w, _v) -> void: pass
func process_object_hit(_a, _t, _p, _w, _v) -> void: pass
func trigger_hearing_pulse(_source) -> void: pass
func is_seen_by_party(c) -> bool:
	return c in party_chars or bool(_seen.get(c, false))

const ORIGIN := Vector2(1024, 1024)

var failures := 0
var checks := 0


func _check(check_name: String, cond: bool, detail = "") -> void:
	checks += 1
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, str(detail)])


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	fluid_manager = FluidManager.new()
	add_child(fluid_manager)
	TimeManager.pause_time()   # the condition clock is moved by hand
	await get_tree().process_frame

	await _case_burn_doesnt_hand_back_the_cloaked()
	await _case_shrouded_revealed_in_every_display()
	await _case_exhausted_refresh_in_hours()
	await _case_warp_mid_window()

	print("HARNESS DONE failures=%d checks=%d" % [failures, checks])
	get_tree().quit(1 if failures > 0 else 0)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _spawn(faction: String, pos: Vector2, char_name: String, ai_on: bool, party := false) -> ProceduralCharacter:
	var c: ProceduralCharacter = PC_SCENE.instantiate()
	c.AI_enabled = ai_on
	c.is_player_controlled = party and not ai_on
	add_child(c)
	TopDownCharacterDatabase.build_character(c, "default_human")
	c.game = self
	c.faction_id = faction
	c.Name = char_name
	c.global_position = pos
	c.rotation = 0.0   # faces up (-Y)
	c.target_rotation = 0.0
	characters_in_scene.append(c)
	if party:
		party_chars.append(c)
	return c


func _clear() -> void:
	for c in characters_in_scene:
		if is_instance_valid(c):
			c.queue_free()
	characters_in_scene = []
	party_chars = []
	_seen = {}
	await get_tree().physics_frame
	await get_tree().physics_frame


func _cm(c: ProceduralCharacter) -> ConditionManager:
	return c.get_node("ConditionManager")


func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame


## Log entries containing `fragment`, counting folded repeats ("(xN)").
func _log_sum(fragment: String) -> int:
	var n := 0
	for e in GameLog.get_entries():
		if String(e.get("text", "")).contains(fragment):
			n += int(e.get("count", 1))
	return n


func _engaged_within(guard: ProceduralCharacter, foe: ProceduralCharacter, seconds: float) -> bool:
	var ai = guard.get_node_or_null("AI")
	var elapsed := 0.0
	while elapsed < seconds:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		if ai != null and ai.current_target == foe:
			return true
	return false


func _rgb_is(c: Color, want: Color) -> bool:
	return is_equal_approx(c.r, want.r) and is_equal_approx(c.g, want.g) and is_equal_approx(c.b, want.b)


# ---------------------------------------------------------------------------
# 1. DoT x Invisible and the AI
# ---------------------------------------------------------------------------

func _case_burn_doesnt_hand_back_the_cloaked() -> void:
	var guard := _spawn("bandits", ORIGIN + Vector2(0, 300), "Warden", true)
	var foe := _spawn("player", ORIGIN, "Djargo", false, true)
	_seen[guard] = true
	foe.equip_equipment(ItemDatabase.get_item_data("shadow_cloak"))
	await get_tree().process_frame
	guard.constitution = 1000   # survives the burn
	guard.current_health = guard.max_health
	var ai = guard.get_node("AI")
	foe.reveal()
	_check("1.acquired-in-window", await _engaged_within(guard, foe, 3.0))
	# His fire swing lit the guard: Burning at the cap, its ticks his.
	var burn: ConditionInstance = _cm(guard).apply_condition("burning", foe, 4)
	_check("1.burn-is-his", burn != null and burn.source == foe)
	var line := "Warden loses sight of Djargo (invisible)."
	var lines := _log_sum(line)
	TimeManager.game_time += foe.REVEAL_SECONDS + 0.25
	await _frames(3)
	_check("1.dropped-when-invisible", ai.current_target == null, str(ai.current_target))
	_check("1.lost-sight-once", _log_sum(line) == lines + 1,
		"log tail: %s" % str(GameLog.get_entries().slice(-3)))
	var hp0: float = guard.current_health
	var reacquired := false
	var shown := false
	for i in range(8):   # past the burn's 5 s
		TimeManager.game_time += 1.0
		await _frames(2)
		if ai.current_target == foe:
			reacquired = true
		if not _cm(foe).has_active_condition("invisible"):
			shown = true
	_check("1.burn-ticked", guard.current_health < hp0, "%s -> %s" % [hp0, guard.current_health])
	_check("1.burn-out", not _cm(guard).has_condition("burning"))
	_check("1.ticks-dont-hand-him-back", not reacquired)
	_check("1.no-repeat-lost-sight", _log_sum(line) == lines + 1,
		"log tail: %s" % str(GameLog.get_entries().slice(-3)))
	_check("1.ticks-dont-reveal-him", not shown)
	await _clear()


# ---------------------------------------------------------------------------
# 2. The DoT summary x the Shrouded reveal
# ---------------------------------------------------------------------------

func _case_shrouded_revealed_in_every_display() -> void:
	var p := _spawn("player", ORIGIN, "Djargo", false, true)
	p.equip_equipment(ItemDatabase.get_item_data("dark_hood"))
	var cm := _cm(p)
	cm.apply_condition("burning", null, 2)
	var sh: ConditionInstance = cm.get_condition("shrouded")
	var burn: ConditionInstance = cm.get_condition("burning")
	var now := TimeManager.absolute_time()
	_check("2.plain-before", sh != null and sh.get_summary(now) == "Shrouded", sh.get_summary(now) if sh else "no Shrouded")
	_check("2.not-revealed-before", not sh.is_revealed(now))
	p.reveal()
	now = TimeManager.absolute_time()
	_check("2.summary-says-revealed", sh.get_summary(now) == "Shrouded (revealed 3s)", sh.get_summary(now))
	_check("2.tooltip-says-revealed", sh.get_tooltip_text(now).begins_with("Shrouded (revealed 3s)\n"), sh.get_tooltip_text(now))
	_check("2.no-clock-no-time", sh.get_summary() == "Shrouded", sh.get_summary())
	_check("2.dot-wording-untouched", burn.get_summary(now) == "Burning x2: 2 fire every 1 s (5s left)", burn.get_summary(now))
	var hover = HOVER.new()
	var muted := "[color=#%s]" % HOVER.COLOR_MUTED.to_html(false)
	var lines: PackedStringArray = hover.condition_lines(p)
	var sh_line := ""
	var burn_line := ""
	for l in lines:
		if l.contains("Shrouded"):
			sh_line = l
		elif l.contains("Burning"):
			burn_line = l
	_check("2.hover-mutes-revealed", sh_line.begins_with(muted) and sh_line.contains("Shrouded (revealed 3s)"), lines)
	_check("2.hover-dot-not-muted", burn_line != "" and not burn_line.begins_with(muted), lines)
	_check("2.overhead-dims-too", _icon_alpha(p, "shrouded") < 1.0 and _icon_alpha(p, "shrouded") >= 0.0, _icon_alpha(p, "shrouded"))
	# The party panel's pip dims as the overhead icon does, and its tooltip
	# says why; the Burning pip beside it stays lit.
	var panel = PANEL.new()
	add_child(panel)
	var row := HBoxContainer.new()
	add_child(row)
	var data := {"condition_container": row}
	panel._update_conditions(data, p)
	_check("2.pip-dims", is_equal_approx(_pip_alpha(row, "shrouded"), 0.4), _pip_alpha(row, "shrouded"))
	_check("2.pip-tooltip-says-revealed", _pip_tip(row, "shrouded").begins_with("Shrouded (revealed 3s)\n"), _pip_tip(row, "shrouded"))
	_check("2.burning-pip-lit", is_equal_approx(_pip_alpha(row, "burning"), 1.0), _pip_alpha(row, "burning"))
	# A second swing stretches the window and the count with it.
	TimeManager.game_time += 1.0
	p.reveal()
	now = TimeManager.absolute_time()
	_check("2.stretched", sh.get_summary(now) == "Shrouded (revealed 3s)", sh.get_summary(now))
	TimeManager.game_time += 2.0
	now = TimeManager.absolute_time()
	_check("2.counts-down", sh.get_summary(now) == "Shrouded (revealed 1s)", sh.get_summary(now))
	# The window shuts: plain, unmuted, the mark cleared.
	TimeManager.game_time += 1.5
	await _frames(2)
	now = TimeManager.absolute_time()
	_check("2.plain-after", sh.get_summary(now) == "Shrouded" and not sh.is_revealed(now), sh.get_summary(now))
	_check("2.mark-cleared", sh.revealed_until < 0.0, sh.revealed_until)
	lines = hover.condition_lines(p)
	var muted_after := false
	for l in lines:
		if l.contains("Shrouded") and l.begins_with(muted):
			muted_after = true
	_check("2.hover-unmuted-after", not muted_after, lines)
	panel._update_conditions(data, p)
	_check("2.pip-lit-after", is_equal_approx(_pip_alpha(row, "shrouded"), 1.0), _pip_alpha(row, "shrouded"))
	_check("2.pip-tooltip-plain-after", _pip_tip(row, "shrouded").begins_with("Shrouded\n"), _pip_tip(row, "shrouded"))
	panel.queue_free()
	row.queue_free()
	# The world map opens no window: nothing marked there either.
	p.on_world_map = true
	p.reveal(p.REVEAL_SECONDS, "casting")
	now = TimeManager.absolute_time()
	_check("2.world-map-unmarked", sh.get_summary(now) == "Shrouded", sh.get_summary(now))
	p.on_world_map = false
	hover.free()
	await _clear()


func _pip(row: Node, cond_id: String) -> Control:
	for ch in row.get_children():
		if ch is Control and ch.get_meta("cond_id", "") == cond_id and not ch.is_queued_for_deletion():
			return ch
	return null


func _pip_alpha(row: Node, cond_id: String) -> float:
	var pip := _pip(row, cond_id)
	return pip.modulate.a if pip != null else -1.0


func _pip_tip(row: Node, cond_id: String) -> String:
	var pip := _pip(row, cond_id)
	return pip.tooltip_text if pip != null else "(no pip)"


func _icon_alpha(c: ProceduralCharacter, cond_id: String) -> float:
	for ch in c._condition_display.get_children():
		if ch.has_meta("cond_id") and ch.get_meta("cond_id") == cond_id and not ch.is_queued_for_deletion():
			return ch.modulate.a
	return -1.0


# ---------------------------------------------------------------------------
# 3. The stackable refresh x travel and downtime hours
# ---------------------------------------------------------------------------

func _case_exhausted_refresh_in_hours() -> void:
	var p := _spawn("player", ORIGIN, "Walker", false, true)
	var cm := _cm(p)
	var day := 24.0 * 3600.0
	var first: Array = APPLIER._apply_add_condition(p, {"id": "exhausted", "duration_hours": 24})
	var ex: ConditionInstance = cm.get_condition("exhausted")
	var t0 := TimeManager.absolute_time()
	_check("3.first-a-day", ex != null and is_equal_approx(ex.expires_at, t0 + day) and first == ["Gained: Exhausted (24h 00m)"],
		"%s %s" % [first, ex.expires_at - t0 if ex else -1.0])
	TimeManager.game_time += 6.0 * 3600.0
	var second: Array = APPLIER._apply_add_condition(p, {"id": "exhausted", "duration_hours": 24})
	var t1 := TimeManager.absolute_time()
	_check("3.second-a-day-from-it", ex.stacks == 2 and is_equal_approx(ex.expires_at, t1 + day),
		"x%d, %.0f s left" % [ex.stacks, ex.expires_at - t1])
	_check("3.gained-line-says-a-day", second == ["Gained: Exhausted (24h 00m)"], second)
	# A third night's Fatigued becomes another Exhausted stack, a day from now.
	TimeManager.game_time += 3600.0
	cm.apply_condition("fatigued", null, 3)
	var t2 := TimeManager.absolute_time()
	_check("3.fatigued-feeds-exhausted", not cm.has_condition("fatigued") and ex.stacks == 3 and is_equal_approx(ex.expires_at, t2 + day),
		"fatigued %s, x%d, %.0f s left" % [cm.has_condition("fatigued"), ex.stacks, ex.expires_at - t2])
	await _clear()


# ---------------------------------------------------------------------------
# 4. Warp mid-window
# ---------------------------------------------------------------------------

func _case_warp_mid_window() -> void:
	var game = GAME_SCRIPT.new()
	var a := _spawn("player", ORIGIN, "Warper", false, true)
	var hood: Dictionary = ItemDatabase.get_item_data("dark_hood").duplicate(true)
	a.inventory.add_item(hood)
	hood["_equipped"] = true
	a.equip_equipment(hood)
	_cm(a).apply_condition("poisoned", null, 3)
	await get_tree().process_frame
	a.reveal()
	var snap: Dictionary = game._serialize_character(a)
	# As a save from before the caps came down would hold it.
	snap["condition_state"]["conditions"]["poisoned"]["stacks"] = 10
	var b := _spawn("player", ORIGIN + Vector2(200, 0), "Warper", false, true)
	game._deserialize_character(b, snap)
	await get_tree().process_frame
	var now := TimeManager.absolute_time()
	var sh: ConditionInstance = b.condition_manager.get_condition("shrouded")
	var poi: ConditionInstance = b.condition_manager.get_condition("poisoned")
	_check("4.arrives-shrouded", sh != null and b.condition_manager.has_active_condition("shrouded"))
	_check("4.arrives-concealed", sh != null and sh.get_summary(now) == "Shrouded" and is_equal_approx(b.effective_visibility(), 0.5),
		sh.get_summary(now) if sh else "no Shrouded")
	_check("4.arrives-tinted", _rgb_is(b.modulate, TINT), b.modulate)
	_check("4.poison-held-to-cap", poi != null and poi.stacks == 4 and poi.get_summary(now).begins_with("Poisoned x4: 4 poison every 2 s"),
		poi.get_summary(now) if poi else "no Poisoned")
	game.free()
	await _clear()
