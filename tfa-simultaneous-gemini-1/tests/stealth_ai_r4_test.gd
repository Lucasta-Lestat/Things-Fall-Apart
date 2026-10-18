extends Node2D
# Round 4, stealth-ai lane (the developer's answers on Invisible, Shrouded and
# the AI):
#   A. An enemy holding a target loses it when the target's Invisible is
#      active again (a Shadow Cloak's returning after the reveal window, a
#      potion mid-fight): the '?', "<NPC> loses sight of <Name> (invisible).",
#      a search of the last known position, no re-acquiring until revealed.
#      true_sight still holds. A companion losing an enemy that way says so.
#   B. Sneaking while Invisible no longer wakes a resting NPC; it uses the same
#      rule as the stealth eye (ai.has_in_view, StealthOverlay agreeing).
#      true_sight still wakes; a loud sound still wakes; Shrouded only within
#      sight x its visibility.
#   C. Crime witnesses respect Invisible and Shrouded: a victimless crime by a
#      hidden actor goes unseen ("Unseen (Invisible)." / "No one saw it: X was
#      Invisible."), a hidden attacker is not identified ("Unrecognised"), the
#      reveal window counts as visible, true_sight sees through it.
#   D. Shrouded feedback: "Revealed" float and "X is revealed for 3 s
#      (attacking)." on the hidden-to-revealed transition, silent stretches,
#      "Shrouded returns" / "X's Shrouded returns (Dark Hood)." when it ends,
#      the smoky tint (off while revealed, back after, restored on warp,
#      stacked with Invisible's alpha), NPC quietness, Djargo's start.
# Real ProceduralCharacter.tscn instances on a stub Game surface (as in
# conditions_r3_test). Headless-safe.
#   godot --headless --path . res://tests/stealth_ai_r4_test.tscn
# Judge by the PASS/FAIL lines and "HARNESS DONE failures=0".

const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const GAME_SCRIPT := preload("res://Game.gd")
const OVERLAY_SCRIPT := preload("res://vfx/StealthOverlay.gd")

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
var overlay = null


func _check(check_name: String, cond: bool, detail: String = "") -> void:
	checks += 1
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	fluid_manager = FluidManager.new()
	add_child(fluid_manager)
	overlay = OVERLAY_SCRIPT.new()
	add_child(overlay)
	TimeManager.pause_time()   # the tests move the condition clock by hand
	await get_tree().process_frame

	# A. Invisible and a held target
	await _case_a_cloak_returns()
	await _case_a_potion_mid_fight()
	await _case_a_true_sight_holds()
	await _case_a_companion_loses_enemy()
	# B. The stealth wake
	await _case_b_visible_sneaker_wakes()
	await _case_b_invisible_sneaker_doesnt()
	await _case_b_true_sight_wakes()
	await _case_b_loud_sound_still_wakes()
	await _case_b_shrouded_range()
	# C. Crime witnesses
	await _case_c_crimes()
	# D. Shrouded feedback
	await _case_d_reveal_notice()
	await _case_d_same_frame_rereveal()
	await _case_d_npc_quiet()
	await _case_d_with_cloak()
	await _case_d_condition_effect_readable()
	await _case_d_warp_and_world_map()
	await _case_d_djargo_start()

	print("HARNESS DONE failures=%d checks=%d" % [failures, checks])
	get_tree().quit(1 if failures > 0 else 0)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _spawn(faction: String, pos: Vector2, char_name: String, ai_on: bool, party := false, template := "default_human") -> ProceduralCharacter:
	var c: ProceduralCharacter = PC_SCENE.instantiate()
	c.AI_enabled = ai_on
	c.is_player_controlled = party and not ai_on
	add_child(c)
	TopDownCharacterDatabase.build_character(c, template)
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
	stealth_mode = false
	current_map_id = "test"
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


func _floats_with(text: String) -> int:
	var n := 0
	for ch in get_children():
		if ch is Label and (ch as Label).text == text:
			n += 1
	for c in characters_in_scene:
		if is_instance_valid(c):
			for ch in c.get_children():
				if ch is Label and (ch as Label).text == text:
					n += 1
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


func _at_ease_for(npc: ProceduralCharacter, seconds: float) -> bool:
	var ai = npc.get_node("AI")
	var elapsed := 0.0
	while elapsed < seconds:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		if not ai.is_at_ease:
			return false
	return true


func _rgb_is(c: Color, want: Color) -> bool:
	return is_equal_approx(c.r, want.r) and is_equal_approx(c.g, want.g) and is_equal_approx(c.b, want.b)


func _icon_alpha(c: ProceduralCharacter, cond_id: String) -> float:
	for ch in c._condition_display.get_children():
		if ch.has_meta("cond_id") and ch.get_meta("cond_id") == cond_id and not ch.is_queued_for_deletion():
			return ch.modulate.a
	return -1.0


# ---------------------------------------------------------------------------
# A. An enemy loses a held target whose Invisible is active again
# ---------------------------------------------------------------------------

func _case_a_cloak_returns() -> void:
	var guard := _spawn("bandits", ORIGIN + Vector2(0, 300), "Guard", true)
	var foe := _spawn("player", ORIGIN, "Djargo", false, true)
	_seen[guard] = true
	foe.equip_equipment(ItemDatabase.get_item_data("shadow_cloak"))
	var ai = guard.get_node("AI")
	_check("a.cloaked-not-acquired", not await _engaged_within(guard, foe, 1.0))
	foe.reveal()
	_check("a.acquired-in-reveal-window", await _engaged_within(guard, foe, 3.0))
	var spot: Vector2 = foe.global_position
	var line := "Guard loses sight of Djargo (invisible)."
	var lines := _log_sum(line)
	TimeManager.game_time += foe.REVEAL_SECONDS + 0.5
	await _frames(3)
	_check("a.invisible-returned", _cm(foe).has_active_condition("invisible"))
	_check("a.target-dropped", ai.current_target == null, str(ai.current_target))
	_check("a.lost-sight-logged", _log_sum(line) == lines + 1,
		"log tail: %s" % str(GameLog.get_entries().slice(-3)))
	_check("a.searching-question-mark", ai.current_alertness == ai.Alertness.SEARCHING
		and guard._alertness_indicator.visible and guard._alertness_indicator.text == "?",
		"alertness %s value %.1f" % [ai.current_alertness, ai.alertness_value])
	_check("a.search-goes-to-last-known", ai.last_heard_position.distance_to(spot) < 4.0,
		"%s vs %s" % [ai.last_heard_position, spot])
	await _frames(2)
	_check("a.searching-state", ai.current_state == ai.AIState.SEARCHING, str(ai.current_state))
	_check("a.not-in-view", not ai.has_in_view(foe))
	_check("a.not-reacquired-while-invisible", not await _engaged_within(guard, foe, 1.5))
	# Shown again (another attack): acquired again.
	foe.reveal()
	_check("a.reacquired-when-revealed", await _engaged_within(guard, foe, 3.0))
	await _clear()


func _case_a_potion_mid_fight() -> void:
	var guard := _spawn("bandits", ORIGIN + Vector2(0, 300), "Sentry", true)
	var foe := _spawn("player", ORIGIN, "Aldric", false, true)
	_seen[guard] = true
	var ai = guard.get_node("AI")
	_check("a2.acquired-visible", await _engaged_within(guard, foe, 3.0))
	var lines := _log_sum("Sentry loses sight of Aldric (invisible).")
	_cm(foe).apply_condition("invisible", null, 1)   # a potion: timed Invisible
	await _frames(2)
	_check("a2.lost-on-potion", ai.current_target == null)
	_check("a2.logged", _log_sum("Sentry loses sight of Aldric (invisible).") == lines + 1)
	# An NPC the party can't see loses them quietly.
	await _clear()
	guard = _spawn("bandits", ORIGIN + Vector2(0, 300), "Lurker", true)
	foe = _spawn("player", ORIGIN, "Aldric", false, true)
	ai = guard.get_node("AI")
	_check("a2.hidden-npc-acquired", await _engaged_within(guard, foe, 3.0))
	_cm(foe).apply_condition("invisible", null, 1)
	await _frames(2)
	_check("a2.hidden-npc-lost-too", ai.current_target == null)
	_check("a2.hidden-npc-silent", _log_sum("Lurker loses sight") == 0)
	await _clear()


func _case_a_true_sight_holds() -> void:
	var guard := _spawn("bandits", ORIGIN + Vector2(0, 300), "Seer", true)
	guard.traits["true_sight"] = 1
	var foe := _spawn("player", ORIGIN, "Djargo", false, true)
	foe.equip_equipment(ItemDatabase.get_item_data("shadow_cloak"))
	var ai = guard.get_node("AI")
	_check("a3.true-sight-acquires-cloaked", await _engaged_within(guard, foe, 3.0))
	await _frames(5)
	_check("a3.true-sight-holds", ai.current_target == foe)
	_check("a3.true-sight-in-view", ai.has_in_view(foe))
	await _clear()


func _case_a_companion_loses_enemy() -> void:
	var ally := _spawn("player", ORIGIN, "Aldric", true, true)
	var brigand := _spawn("bandits", ORIGIN + Vector2(0, -300), "Brigand", false)
	var ai = ally.get_node("AI")
	_check("a4.companion-acquires", await _engaged_within(ally, brigand, 3.0))
	var line := "Aldric loses sight of Brigand (invisible)."
	var lines := _log_sum(line)
	_cm(brigand).apply_condition("invisible", null, 1)
	await _frames(2)
	_check("a4.companion-drops-invisible-enemy", ai.current_target == null)
	_check("a4.companion-logged", _log_sum(line) == lines + 1,
		"log tail: %s" % str(GameLog.get_entries().slice(-3)))
	await _clear()


# ---------------------------------------------------------------------------
# B. Sneaking while Invisible doesn't wake a resting NPC
# ---------------------------------------------------------------------------

func _resting_npc(char_name: String) -> ProceduralCharacter:
	var npc := _spawn("neutral", ORIGIN + Vector2(0, 300), char_name, true)
	npc.get_node("AI").apply_default_alertness("at_ease")
	_seen[npc] = true
	return npc


func _case_b_visible_sneaker_wakes() -> void:
	stealth_mode = true
	var npc := _resting_npc("Dozer")
	var p := _spawn("player", ORIGIN, "Djargo", false, true)
	_check("b.sneaking", p.is_sneaking())
	_check("b.control-eye", overlay.is_in_view_of_onlooker(p))
	_check("b.control-wakes", not await _at_ease_for(npc, 1.0))
	await _clear()


func _case_b_invisible_sneaker_doesnt() -> void:
	stealth_mode = true
	var npc := _resting_npc("Napper")
	var p := _spawn("player", ORIGIN, "Djargo", false, true)
	p.equip_equipment(ItemDatabase.get_item_data("shadow_cloak"))
	var ai = npc.get_node("AI")
	_check("b.invisible-not-in-view", not ai.has_in_view(p))
	_check("b.invisible-no-eye", not overlay.is_in_view_of_onlooker(p))
	_check("b.invisible-stays-at-ease", await _at_ease_for(npc, 1.5))
	# The cloak's reveal window shows them: the eye and the wake agree again.
	p.reveal()
	_check("b.window-eye", overlay.is_in_view_of_onlooker(p))
	_check("b.window-wakes", not await _at_ease_for(npc, 1.0))
	await _clear()


func _case_b_true_sight_wakes() -> void:
	stealth_mode = true
	var npc := _resting_npc("Oracle")
	npc.traits["true_sight"] = 1
	var p := _spawn("player", ORIGIN, "Djargo", false, true)
	_cm(p).apply_condition("invisible", null, 1)
	_check("b.true-sight-eye", overlay.is_in_view_of_onlooker(p))
	_check("b.true-sight-wakes", not await _at_ease_for(npc, 1.0))
	await _clear()


func _case_b_loud_sound_still_wakes() -> void:
	stealth_mode = true
	var npc := _resting_npc("LightSleeper")
	var p := _spawn("player", ORIGIN, "Djargo", false, true)
	_cm(p).apply_condition("invisible", null, 1)
	_check("b.loud-precondition", await _at_ease_for(npc, 0.3))
	HearingManager.emit(p.global_position, 2.0, p)
	_check("b.loud-sound-wakes", not npc.get_node("AI").is_at_ease)
	await _clear()


func _case_b_shrouded_range() -> void:
	stealth_mode = true
	var npc := _resting_npc("Watcher")
	var ai = npc.get_node("AI")
	var sight_px: float = ai.get_sight_range_pixels()
	var p := _spawn("player", ORIGIN + Vector2(0, 300 - sight_px * 0.7), "Djargo", false, true)
	_cm(p).apply_condition("shrouded", null, 1, -1.0)
	_check("b.shrouded-0.7x-not-in-view", not ai.has_in_view(p), "sight %.0f" % sight_px)
	_check("b.shrouded-0.7x-no-eye", not overlay.is_in_view_of_onlooker(p))
	_check("b.shrouded-0.7x-stays-at-ease", await _at_ease_for(npc, 1.0))
	p.global_position = ORIGIN + Vector2(0, 300 - sight_px * 0.4)
	await get_tree().physics_frame
	_check("b.shrouded-0.4x-eye", overlay.is_in_view_of_onlooker(p))
	_check("b.shrouded-0.4x-wakes", not await _at_ease_for(npc, 1.0))
	await _clear()


# ---------------------------------------------------------------------------
# C. Crime witnesses
# ---------------------------------------------------------------------------

func _pending(c: ProceduralCharacter) -> Dictionary:
	return c.get_node("AI").pending_outcry


func _theft(actor: ProceduralCharacter, mark: Node) -> void:
	CrimeManager.report(actor, "take", {"owner_faction": "liziti", "crime_pos": actor.global_position, "debounce_target": mark})


func _case_c_crimes() -> void:
	current_map_id = "town_square"   # Liziti law: theft and murder
	var witness := _spawn("neutral", ORIGIN, "Shopkeep", false)
	var mark := _spawn("neutral", ORIGIN + Vector2(900, 900), "Purse", false)
	mark.rotation = PI   # looks away: never a witness here
	var sight_px: float = witness.get_sight_range_px()

	# Control: a visible thief in plain view is identified.
	var thief := _spawn("player", ORIGIN + Vector2(0, -300), "Plain", false, true)
	_theft(thief, mark)
	_check("c.control-identified", bool(_pending(witness).get("identified", false)), str(_pending(witness)))
	await _reset_witness(witness)

	# Invisible: nobody saw it, and the notice says why.
	var ghost := _spawn("player", ORIGIN + Vector2(0, -300), "Ghost", false, true)
	_cm(ghost).apply_condition("invisible", null, 1)
	_check("c.hidden-from-names-invisible", CrimeManager.hidden_from(witness, ghost) == "Invisible")
	var lines := _log_sum("No one saw it: Ghost was Invisible.")
	_theft(ghost, mark)
	_check("c.invisible-no-fuse", _pending(witness).is_empty(), str(_pending(witness)))
	_check("c.invisible-unseen-float", _floats_with("Unseen (Invisible).") >= 1)
	_check("c.invisible-unseen-logged", _log_sum("No one saw it: Ghost was Invisible.") == lines + 1,
		"log tail: %s" % str(GameLog.get_entries().slice(-3)))
	await _reset_witness(witness)

	# The reveal window counts as visible (a timed Invisible simply ends).
	var bold := _spawn("player", ORIGIN + Vector2(0, -300), "Bold", false, true)
	_cm(bold).apply_condition("invisible", null, 1)
	bold.reveal()
	_theft(bold, mark)
	_check("c.revealed-identified", bool(_pending(witness).get("identified", false)))
	await _reset_witness(witness)

	# true_sight sees through Invisible.
	witness.traits["true_sight"] = 1
	var seen_ghost := _spawn("player", ORIGIN + Vector2(0, -300), "Wisp", false, true)
	_cm(seen_ghost).apply_condition("invisible", null, 1)
	_theft(seen_ghost, mark)
	_check("c.true-sight-identifies", bool(_pending(witness).get("identified", false)))
	witness.traits.erase("true_sight")
	await _reset_witness(witness)

	# Shrouded: unseen beyond sight x 0.5 ...
	var hood := _spawn("player", ORIGIN + Vector2(0, -sight_px * 0.7), "Hood", false, true)
	_cm(hood).apply_condition("shrouded", null, 1, -1.0)
	_check("c.hidden-from-names-shrouded", CrimeManager.hidden_from(witness, hood) == "Shrouded")
	lines = _log_sum("No one saw it: Hood was Shrouded.")
	_theft(hood, mark)
	_check("c.shrouded-far-no-fuse", _pending(witness).is_empty(), "sight %.0f" % sight_px)
	_check("c.shrouded-far-logged", _log_sum("No one saw it: Hood was Shrouded.") == lines + 1)
	_check("c.shrouded-far-float", _floats_with("Unseen (Shrouded).") >= 1)
	await _reset_witness(witness)
	# ... seen within it ...
	var near_hood := _spawn("player", ORIGIN + Vector2(0, -sight_px * 0.4), "NearHood", false, true)
	_cm(near_hood).apply_condition("shrouded", null, 1, -1.0)
	_theft(near_hood, mark)
	_check("c.shrouded-near-identified", bool(_pending(witness).get("identified", false)))
	await _reset_witness(witness)
	# ... and in full while revealed.
	var bold_hood := _spawn("player", ORIGIN + Vector2(0, -sight_px * 0.7), "BoldHood", false, true)
	_cm(bold_hood).apply_condition("shrouded", null, 1, -1.0)
	bold_hood.reveal()
	_theft(bold_hood, mark)
	_check("c.shrouded-revealed-identified", bool(_pending(witness).get("identified", false)))
	await _reset_witness(witness)

	# A plain "No one saw it." when nobody was there at all.
	var alone := _spawn("player", ORIGIN + Vector2(0, -300), "Alone", false, true)
	alone.rotation = 0.0
	witness.rotation = PI   # facing away: sees nothing
	lines = _log_sum("No one saw it.")
	_theft(alone, mark)
	_check("c.unwatched-plain-line", _log_sum("No one saw it.") == lines + 1
		and _log_sum("No one saw it: Alone") == 0)
	witness.rotation = 0.0
	await _reset_witness(witness)

	# A crime with a victim (a murder seen from across the square): the deed
	# is seen, the Invisible killer is not made out, and the notice says so.
	var victim := _spawn("neutral", ORIGIN + Vector2(300, -300), "Victim", false)
	var killer := _spawn("player", ORIGIN + Vector2(330, -300), "Shade", false, true)
	_cm(killer).apply_condition("invisible", null, 1)
	victim.current_health = 0
	var payload: Dictionary = CrimeManager.attack_payload(killer, victim)
	var verdict: Dictionary = CrimeManager.preview(killer, "attack", payload)
	_check("c.murder-is-a-crime-here", not verdict.is_empty(), str(verdict))
	lines = _log_sum("Witnesses saw it, but not who did it: Shade was Invisible.")
	CrimeManager.report(killer, "attack", payload)
	var pend: Dictionary = _pending(witness)
	_check("c.victim-crime-seen", not pend.is_empty(), "the deed itself is in plain view")
	_check("c.victim-crime-unidentified", not bool(pend.get("identified", true)) and pend.get("perp") == null)
	_check("c.unrecognised-logged", _log_sum("Witnesses saw it, but not who did it: Shade was Invisible.") == lines + 1,
		"log tail: %s" % str(GameLog.get_entries().slice(-3)))
	_check("c.unrecognised-float", _floats_with("Unrecognised (Invisible)") >= 1)
	await _reset_witness(witness)
	await _clear()


## Drop the witness's lit fuse so the next case starts clean.
func _reset_witness(w: ProceduralCharacter) -> void:
	var ai = w.get_node("AI")
	ai.pending_outcry = {}
	ai._outcry_timer = -1.0
	await get_tree().physics_frame


# ---------------------------------------------------------------------------
# D. Shrouded feedback
# ---------------------------------------------------------------------------

const TINT := Color(0.5, 0.47, 0.62)   # ProceduralCharacter.CONCEALED_TINT

func _case_d_reveal_notice() -> void:
	var p := _spawn("player", ORIGIN, "Djargo", false, true)
	var quiet_before := _log_sum("Djargo is revealed") + _log_sum("Djargo's Shrouded returns")
	p.equip_equipment(ItemDatabase.get_item_data("dark_hood"))
	var cm := _cm(p)
	_check("d.hood-shrouded", cm.has_active_condition("shrouded"))
	_check("d.const-matches", _rgb_is(p.CONCEALED_TINT, TINT), str(p.CONCEALED_TINT))
	_check("d.smoky-tint", _rgb_is(p.modulate, TINT) and is_equal_approx(p.modulate.a, 1.0), str(p.modulate))
	_check("d.icons-tinted-back", _rgb_is(p.modulate * p._condition_display.modulate, Color.WHITE),
		str(p._condition_display.modulate))
	_check("d.equip-no-notice", _log_sum("Djargo is revealed") + _log_sum("Djargo's Shrouded returns") == quiet_before)

	var line := "Djargo is revealed for 3 s (attacking)."
	var lines := _log_sum(line)
	var floats := _floats_with("Revealed")
	p.reveal()
	_check("d.revealed-float", _floats_with("Revealed") == floats + 1)
	_check("d.revealed-logged", _log_sum(line) == lines + 1, "log tail: %s" % str(GameLog.get_entries().slice(-2)))
	_check("d.revealed-drawn-normally", _rgb_is(p.modulate, Color.WHITE), str(p.modulate))
	_check("d.revealed-visibility-full", is_equal_approx(p.effective_visibility(), 1.0))
	_check("d.revealed-icon-dims", _icon_alpha(p, "shrouded") < 1.0 and _icon_alpha(p, "shrouded") >= 0.0,
		str(_icon_alpha(p, "shrouded")))

	# Another swing inside the window stretches it, quietly.
	TimeManager.game_time += 1.0
	var any_reveal := _log_sum("is revealed for")
	p.reveal()
	_check("d.second-swing-quiet", _log_sum("is revealed for") == any_reveal)
	_check("d.second-swing-stretches", is_equal_approx(p._revealed_until, TimeManager.absolute_time() + p.REVEAL_SECONDS))
	TimeManager.game_time += 2.0
	await _frames(2)
	_check("d.still-revealed-after-stretch", _rgb_is(p.modulate, Color.WHITE) and _log_sum("Djargo's Shrouded returns") == 0)

	# The window ends: back in shadow, said once.
	var back_line := "Djargo's Shrouded returns (Dark Hood)."
	var backs := _log_sum(back_line)
	var back_floats := _floats_with("Shrouded returns")
	TimeManager.game_time += 1.5
	await _frames(2)
	_check("d.returns-float", _floats_with("Shrouded returns") > back_floats)
	_check("d.returns-logged", _log_sum(back_line) == backs + 1, "log tail: %s" % str(GameLog.get_entries().slice(-2)))
	_check("d.tint-back", _rgb_is(p.modulate, TINT), str(p.modulate))
	_check("d.icon-undimmed", is_equal_approx(_icon_alpha(p, "shrouded"), 1.0), str(_icon_alpha(p, "shrouded")))
	_check("d.visibility-half-again", is_equal_approx(p.effective_visibility(), 0.5))
	await _frames(3)
	_check("d.returns-said-once", _log_sum(back_line) == backs + 1)

	# Casting reveals too, and says so.
	await _wait_real_ms(1100)   # past notify's same-text repeat window
	var casts := _log_sum("Djargo is revealed for 3 s (casting).")
	p.reveal(p.REVEAL_SECONDS, "casting")
	_check("d.cast-logged", _log_sum("Djargo is revealed for 3 s (casting).") == casts + 1)

	# Taking the hood off during a window: normal colours, no "returns".
	var head := EquipmentShape.EquipmentSlot.HEAD
	p.unequip_slot(head)
	_check("d.hood-off-normal", _rgb_is(p.modulate, Color.WHITE) and not cm.has_condition("shrouded"))
	backs = _log_sum("Shrouded returns")
	TimeManager.game_time += p.REVEAL_SECONDS + 0.5
	await _frames(2)
	_check("d.hood-off-no-returns", _log_sum("Shrouded returns") == backs)
	await _clear()


## A swing landing in the very frame its window ran out (before "returns"
## was said) carries the window on: no second "Revealed" without a "returns".
func _case_d_same_frame_rereveal() -> void:
	var p := _spawn("player", ORIGIN, "Nyx", false, true)
	_cm(p).apply_condition("shrouded", null, 1, -1.0)
	p.reveal()
	_check("d.rr-first-notice", _log_sum("Nyx is revealed for 3 s (attacking).") == 1)
	TimeManager.game_time += p.REVEAL_SECONDS + 0.1
	p.reveal()   # same frame: the window's end hasn't been processed yet
	await _frames(2)
	_check("d.rr-no-second-notice", _log_sum("Nyx is revealed") == 1)
	_check("d.rr-no-returns-yet", _log_sum("Nyx's Shrouded returns") == 0)
	_check("d.rr-still-revealed", _rgb_is(p.modulate, Color.WHITE))
	TimeManager.game_time += p.REVEAL_SECONDS + 0.1
	await _frames(2)
	_check("d.rr-returns-once", _log_sum("Nyx's Shrouded returns") == 1 and _rgb_is(p.modulate, TINT))
	await _clear()


func _wait_real_ms(ms: int) -> void:
	var until := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame


func _case_d_npc_quiet() -> void:
	var watcher := _spawn("player", ORIGIN + Vector2(0, 300), "Aldric", false, true)
	var npc := _spawn("bandits", ORIGIN, "Cutpurse", false)
	_cm(npc).apply_condition("shrouded", null, 1, -1.0)
	_check("d.npc-tinted-too", _rgb_is(npc.modulate, TINT), str(npc.modulate))
	# The party sees it: the floats, no log lines.
	_seen[npc] = true
	var floats := _floats_with("Revealed")
	npc.reveal()
	_check("d.npc-seen-float", _floats_with("Revealed") == floats + 1)
	var back_floats := _floats_with("Shrouded returns")
	TimeManager.game_time += npc.REVEAL_SECONDS + 0.5
	await _frames(2)
	_check("d.npc-seen-returns-float", _floats_with("Shrouded returns") > back_floats)
	_check("d.npc-seen-no-log", _log_sum("Cutpurse is revealed") == 0 and _log_sum("Cutpurse's Shrouded") == 0,
		"log tail: %s" % str(GameLog.get_entries().slice(-3)))
	# An NPC the party can't see: nothing at all.
	var lurker := _spawn("bandits", ORIGIN + Vector2(600, 0), "Skulker", false)
	_cm(lurker).apply_condition("shrouded", null, 1, -1.0)
	floats = _floats_with("Revealed")
	lurker.reveal()
	_check("d.npc-unseen-silent", _log_sum("Skulker") == 0 and _floats_with("Revealed") == floats)
	_check("d.npc-unseen-still-drawn-normally-while-revealed", _rgb_is(lurker.modulate, Color.WHITE))
	TimeManager.game_time += lurker.REVEAL_SECONDS + 0.5
	await _frames(2)
	_check("d.npc-unseen-tint-back", _rgb_is(lurker.modulate, TINT))
	_check("d.npc-alertness-glyph-tinted-back", lurker._alertness_indicator == null
		or _rgb_is(lurker.modulate * lurker._alertness_indicator.modulate, Color.WHITE))
	await _clear()


func _case_d_with_cloak() -> void:
	var p := _spawn("player", ORIGIN, "Vex", false, true)
	p.equip_equipment(ItemDatabase.get_item_data("dark_hood"))
	p.equip_equipment(ItemDatabase.get_item_data("shadow_cloak"))
	var cm := _cm(p)
	_check("d.both-on", cm.has_active_condition("shrouded") and cm.has_active_condition("invisible"))
	_check("d.both-see-through-and-smoky", _rgb_is(p.modulate, TINT) and is_equal_approx(p.modulate.a, 0.35), str(p.modulate))
	var broke := _log_sum("Vex's invisibility breaks")
	p.reveal()
	_check("d.both-cloak-notice", _log_sum("Vex's invisibility breaks") == broke + 1)
	_check("d.both-no-second-notice", _log_sum("Vex is revealed") == 0)
	_check("d.both-solid-normal", _rgb_is(p.modulate, Color.WHITE) and is_equal_approx(p.modulate.a, 1.0), str(p.modulate))
	TimeManager.game_time += p.REVEAL_SECONDS + 0.5
	await _frames(3)
	_check("d.both-cloak-returns", _log_sum("Vex's Invisible returns (Shadow Cloak).") == 1)
	_check("d.both-no-shrouded-returns", _log_sum("Vex's Shrouded returns") == 0)
	_check("d.both-back", _rgb_is(p.modulate, TINT) and is_equal_approx(p.modulate.a, 0.35), str(p.modulate))
	# The cloak's Invisible already down (doused) when he swings: the cloak
	# breaks nothing and says nothing, so Shrouded's own pair speaks.
	cm.suppress_for("invisible", 30.0, "water")
	await _wait_real_ms(1100)   # past notify's same-text repeat window
	broke = _log_sum("Vex's invisibility breaks")
	p.reveal()
	_check("d.doused-cloak-silent", _log_sum("Vex's invisibility breaks") == broke)
	_check("d.doused-cloak-shrouded-speaks", _log_sum("Vex is revealed for 3 s (attacking).") == 1,
		"log tail: %s" % str(GameLog.get_entries().slice(-3)))
	TimeManager.game_time += p.REVEAL_SECONDS + 0.5
	await _frames(3)
	_check("d.doused-cloak-shrouded-returns", _log_sum("Vex's Shrouded returns (Dark Hood).") == 1)
	await _clear()


## A condition shown by its effect instead of an icon (Burning's flames) keeps
## its colours on a Shrouded body, as the icons do.
func _case_d_condition_effect_readable() -> void:
	var p := _spawn("player", ORIGIN, "Ember", false, true)
	_cm(p).apply_condition("shrouded", null, 1, -1.0)
	_cm(p).apply_condition("burning", null, 1)
	var vfx = p._active_condition_vfx.get("burning")
	_check("d.fx-spawned", vfx != null and is_instance_valid(vfx), "fire.tscn did not spawn")
	if vfx != null and is_instance_valid(vfx):
		_check("d.fx-tinted-back", _rgb_is(p.modulate, TINT) and _rgb_is(p.modulate * vfx.modulate, Color.WHITE),
			"%s x %s" % [p.modulate, vfx.modulate])
		p.reveal()
		_check("d.fx-normal-while-revealed", _rgb_is(vfx.modulate, Color.WHITE) and _rgb_is(p.modulate, Color.WHITE),
			str(vfx.modulate))
	await _clear()


func _case_d_warp_and_world_map() -> void:
	var game = GAME_SCRIPT.new()
	var a := _spawn("player", ORIGIN, "Warper", false, true)
	var hood: Dictionary = ItemDatabase.get_item_data("dark_hood").duplicate(true)
	a.inventory.add_item(hood)
	hood["_equipped"] = true
	a.equip_equipment(hood)
	await get_tree().process_frame
	var snap: Dictionary = game._serialize_character(a)
	var b := _spawn("player", ORIGIN + Vector2(200, 0), "Warper", false, true)
	game._deserialize_character(b, snap)
	await get_tree().process_frame
	_check("d.warp-shrouded", b.condition_manager.has_active_condition("shrouded"))
	_check("d.warp-tint-restored", _rgb_is(b.modulate, TINT), str(b.modulate))
	# _restore_condition_presentation on its own re-applies it too.
	b.modulate = Color.WHITE
	game._restore_condition_presentation(b)
	_check("d.restore-presentation-tints", _rgb_is(b.modulate, TINT), str(b.modulate))
	game.free()
	# No notice on the world map (as the cloak's).
	b.on_world_map = true
	b.reveal(b.REVEAL_SECONDS, "casting")
	_check("d.world-map-silent", _log_sum("Warper is revealed") == 0)
	b.on_world_map = false
	await _clear()


func _case_d_djargo_start() -> void:
	var before := _log_sum("is revealed for") + _log_sum("Shrouded returns")
	var floats := _floats_with("Revealed") + _floats_with("Shrouded returns")
	var d := _spawn("player", ORIGIN, "Djargo", false, true, "djargo")
	await _frames(3)
	_check("d.djargo-shrouded", _cm(d).has_active_condition("shrouded"))
	_check("d.djargo-tinted", _rgb_is(d.modulate, TINT), str(d.modulate))
	_check("d.djargo-no-spurious-notice", _log_sum("is revealed for") + _log_sum("Shrouded returns") == before
		and _floats_with("Revealed") + _floats_with("Shrouded returns") <= floats)
	await _clear()
