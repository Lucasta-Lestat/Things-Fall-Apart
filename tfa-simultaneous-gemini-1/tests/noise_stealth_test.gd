# res://tests/noise_stealth_test.gd - stealth mode (I6) and noise readouts (I5).
#   - set_stealth_mode: sneaking pace and footstep loudness, the STEALTH badge,
#     NPC cones and their elevated-surface twins, in-view eyes (ai.has_in_view),
#     no sneaking on the world map, ai._is_sneaking agreeing;
#   - deck art carrying the elevated-surface light bit;
#   - HearingManager.audible_radius / loudness_tier, worn-item noise
#     (EquipmentShape.noise_for_item_data, ItemTooltip.noise_lines), the party
#     panel's footsteps readout, and the noise rings.
# Run:  godot --headless --path . res://tests/noise_stealth_test.tscn
# Judge by PASS/FAIL lines and the HARNESS DONE count.
extends Node2D

var failures := 0
var game = null

func _check(check_name: String, cond: bool, detail = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, str(detail)])

func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

func _ready() -> void:
	TimeManager.pause_time()
	await get_tree().process_frame
	var GameScene := load("res://game.tscn")
	game = GameScene.instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _frames(2)
	game.load_map("tg_castle_demo")
	await _frames(20)
	# Freeze characters (their movement stops) so the test drives it; Game and
	# the overlay run while paused, as they do in play.
	PauseManager.pause()
	await _frames(2)
	await _stealth_mode_cases()
	_deck_art_cases()
	await _extra_cases()
	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

# I5: noise visibility.
func _extra_cases() -> void:
	_hearing_helper_cases()
	await _hearing_matches_emit_cases()
	_item_noise_cases()
	await _readout_cases()
	await _ring_cases()

# ---------------------------------------------------------------------------
# I6: sneaking, badge, cones, in-view eyes
# ---------------------------------------------------------------------------

func _npcs() -> Array:
	var out: Array = []
	for c in game.characters_in_scene:
		if is_instance_valid(c) and not (c in game.party_chars):
			out.append(c)
	return out

func _stealth_mode_cases() -> void:
	var party: Array = game.party_chars
	_check("setup.party-present", party.size() > 0, party.size())
	if party.is_empty():
		return
	var p = party[0]
	var npcs: Array = _npcs()
	_check("setup.map-has-npcs", npcs.size() > 0, npcs.size())

	# Stealth off: nobody sneaks, full pace, badge hidden.
	_check("off.starts-off", not game.stealth_mode)
	_check("off.party-member-not-sneaking", not p.is_sneaking())
	_check("off.walk-speed-is-move-speed", is_equal_approx(p.walk_speed(), p.move_speed), [p.walk_speed(), p.move_speed])
	var badge = game.hud_status.get_node_or_null("StealthBadge")
	_check("badge.on-hud-status", badge != null)
	_check("badge.off-hidden", badge != null and not badge.visible)
	_check("badge.keeps-its-tooltip-pass", badge != null and badge.mouse_filter == Control.MOUSE_FILTER_PASS and badge.tooltip_text != "")
	_check("overlay.exists", game.stealth_overlay != null and game.stealth_overlay.get_parent() == game)

	var walk_off := _measure_walk_velocity(p)
	var loud_off := _measure_footstep(p)
	_check("off.walks-at-move-speed", walk_off > 0.0 and is_equal_approx(walk_off, p.move_speed), [walk_off, p.move_speed])

	# Turn it on through the one toggle path.
	var emitted := []
	game.stealth_mode_changed.connect(func(a): emitted.append(a))
	game.set_stealth_mode(true)
	await _frames(2)
	_check("on.stealth-mode-set", game.stealth_mode)
	_check("on.signal-once", emitted == [true], emitted)
	_check("on.log-says-what-it-does", _log_has("the party sneaks (footsteps 50% as loud, 70% walking pace)"))
	_check("on.party-member-sneaks", p.is_sneaking())
	_check("on.walk-speed-slowed", is_equal_approx(p.walk_speed(), p.move_speed * p.SNEAK_SPEED_MULT), [p.walk_speed(), p.move_speed])
	_check("on.badge-visible", badge != null and badge.visible)
	var any_npc = npcs[0] if not npcs.is_empty() else null
	if any_npc != null:
		_check("on.npc-does-not-sneak", not any_npc.is_sneaking())
		_check("on.ai-agrees", any_npc.get_node("AI")._is_sneaking(p) == p.is_sneaking())

	var walk_on := _measure_walk_velocity(p)
	_check("on.walks-at-sneak-pace", walk_off > 0.0 and is_equal_approx(walk_on / walk_off, p.SNEAK_SPEED_MULT), [walk_on, walk_off])
	var loud_on := _measure_footstep(p)
	_check("on.footstep-at-sneak-loudness", loud_off > 0.0 and is_equal_approx(loud_on / loud_off, p.SNEAK_NOISE_MULT), [loud_on, loud_off])
	var dash_on: float = p.get_dash_range()

	# Every NPC cone gets an elevated-surface twin, matching the red one.
	var cones := 0
	var bad := []
	for n in npcs:
		if not is_instance_valid(n) or not n.has_node("NPCLineOfSight"):
			continue
		cones += 1
		var red: PointLight2D = n.get_node("NPCLineOfSight")
		var high = n.get_node_or_null("NPCLineOfSightHigh")
		if high == null:
			bad.append("%s: no elevated cone" % n.Name)
			continue
		if high.visible != red.visible or (n.is_alive() and not red.visible):
			bad.append("%s: cones shown %s/%s" % [n.Name, red.visible, high.visible])
		if not n.is_alive() and (high.enabled or red.enabled):
			bad.append("%s: a corpse's cones lit" % n.Name)
		if high.range_item_cull_mask != CollisionLayers.ELEVATED_SURFACE_LIGHT or high.shadow_item_cull_mask != CollisionLayers.SIGHT_MASK_HIGH:
			bad.append("%s: elevated masks %d/%d" % [n.Name, high.range_item_cull_mask, high.shadow_item_cull_mask])
		if not is_equal_approx(high.texture_scale, red.texture_scale) or high.texture != red.texture:
			bad.append("%s: elevated size %.3f vs %.3f" % [n.Name, high.texture_scale, red.texture_scale])
		if high.enabled != (n.get_elevation() < 1.0 and red.enabled):
			bad.append("%s: elevated enabled=%s at elevation %.1f" % [n.Name, high.enabled, n.get_elevation()])
		if high.color.is_equal_approx(Color(1.0, 0.75, 0.25)) or high.color.is_equal_approx(Color(1.0, 0.72, 0.2)):
			bad.append("%s: elevated cone uses the Suspicious/outcry amber" % n.Name)
	_check("cones.every-npc-cone-has-a-matching-elevated-cone (%d)" % cones, cones > 0 and bad.is_empty(), bad)

	# The elevated cone goes dark while its NPC is up on a walkway.
	if not npcs.is_empty():
		var n0 = npcs[0]
		var high0 = n0.get_node_or_null("NPCLineOfSightHigh")
		if high0:
			var e0: float = n0.current_elevation
			n0.current_elevation = 1.5
			game.sync_npc_elevated_cone(n0)
			_check("cones.elevated-off-for-an-elevated-npc", not high0.enabled)
			n0.current_elevation = 0.0
			game.sync_npc_elevated_cone(n0)
			_check("cones.elevated-back-on-at-ground", high0.enabled == n0.get_node("NPCLineOfSight").enabled)
			n0.current_elevation = e0
			game.sync_npc_elevated_cone(n0)

	# In-view eye: stand a party member in front of a visible onlooker.
	await _eye_cases(p, npcs)

	# A corpse sees nothing: an NPC that dies while stealth is on goes dark.
	var victim = null
	for n in npcs:
		if is_instance_valid(n) and n.is_alive() and n.has_node("NPCLineOfSightHigh"):
			victim = n
	if victim:
		_check("corpse.living-npc-cones-lit", victim.get_node("NPCLineOfSight").enabled)
		victim.current_health = 0
		victim._check_death()
		await _frames(3)
		_check("corpse.cones-dark", not victim.is_alive() and not victim.get_node("NPCLineOfSight").enabled and not victim.get_node("NPCLineOfSightHigh").enabled)

	# Off again: everything clears.
	game.set_stealth_mode(false)
	await _frames(2)
	_check("off-again.not-sneaking", not p.is_sneaking())
	_check("off-again.badge-hidden", badge != null and not badge.visible)
	_check("off-again.walk-speed-full", is_equal_approx(p.walk_speed(), p.move_speed))
	if dash_on >= 0.0:
		_check("dash.unaffected-by-sneaking", is_equal_approx(dash_on, p.get_dash_range()), [dash_on, p.get_dash_range()])
	var any_cone_shown := false
	for n in npcs:
		if is_instance_valid(n):
			for cn in ["NPCLineOfSight", "NPCLineOfSightHigh"]:
				var l = n.get_node_or_null(cn)
				if l and l.visible:
					any_cone_shown = true
	_check("off-again.cones-hidden", not any_cone_shown)
	_check("off-again.no-eyes", not game.stealth_overlay.is_marked_in_view(p))

	# World map: nobody sneaks there.
	game.set_stealth_mode(true)
	p.on_world_map = true
	_check("world-map.no-sneaking", not p.is_sneaking())
	_check("world-map.full-pace", is_equal_approx(p.walk_speed(), p.move_speed))
	p.on_world_map = false
	# The badge hides on the world map and in downtime, where nobody sneaks.
	if badge != null:
		var was_wm: bool = game.current_map_data.get("is_world_map", false)
		game.current_map_data["is_world_map"] = true
		badge._refresh()
		_check("world-map.badge-hidden", not badge.visible)
		game.current_map_data["is_world_map"] = was_wm
		badge._refresh()
		_check("world-map.badge-back-after", badge.visible)
		var was_dt: bool = game.downtime_mode_active
		game.downtime_mode_active = true
		badge._refresh()
		_check("downtime.badge-hidden", not badge.visible)
		game.downtime_mode_active = was_dt
		badge._refresh()
	game.set_stealth_mode(false)
	game.current_map_data["is_world_map"] = true
	game.set_stealth_mode(true)
	_check("world-map.log-nobody-sneaks-here", _log_has("Nobody sneaks on the world map"))
	game.set_stealth_mode(false)
	game.current_map_data.erase("is_world_map")

func _log_has(fragment: String) -> bool:
	for e in GameLog.get_entries():
		if fragment in str(e.get("text", "")):
			return true
	return false

# Deck (walkway) art carries the elevated-surface light bit that only the
# elevated cone lights; other structure art doesn't. Spawned through
# MapLoader's own geometry path with a stand-in overlay texture, far off in a
# map corner (the map's own overlay PNG may not be on disk in a text-only
# checkout).
func _deck_art_cases() -> void:
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	var tex := ImageTexture.create_from_image(img)
	var ml = game.map_loader
	var deck = ml._spawn_geo_structure({"kind": "wall", "a": [40, 40], "b": [240, 40], "half": 20.0, "id": "stone_wall", "walk_elev": 1.44}, tex, 64)
	var wall = ml._spawn_geo_structure({"kind": "wall", "a": [40, 200], "b": [240, 200], "half": 10.0, "id": "stone_wall"}, tex, 64)
	var deck_art = deck.get_node_or_null("Art") if deck else null
	var wall_art = wall.get_node_or_null("Art") if wall else null
	_check("deck.art-spawned", deck_art != null and deck.is_deck)
	_check("deck.art-lit-by-elevated-cone-and-ordinary-lights", deck_art != null and (deck_art.light_mask & CollisionLayers.ELEVATED_SURFACE_LIGHT) != 0 and (deck_art.light_mask & 1) != 0, deck_art.light_mask if deck_art else -1)
	_check("deck.wall-art-not-lit-by-elevated-cone", wall_art != null and (wall_art.light_mask & CollisionLayers.ELEVATED_SURFACE_LIGHT) == 0, wall_art.light_mask if wall_art else -1)
	var occ = deck.get_node_or_null("Occluder") if deck else null
	_check("deck.occluder-doesnt-shadow-the-elevated-cone", occ != null and (occ.occluder_light_mask & CollisionLayers.SIGHT_MASK_HIGH) == 0)

func _eye_cases(p, npcs: Array) -> void:
	var overlay = game.stealth_overlay
	var onlooker = null
	var spot := Vector2.ZERO
	for n in npcs:
		if not is_instance_valid(n) or not n.is_alive() or not n.AI_enabled or not n.has_node("AI"):
			continue
		var ai = n.get_node("AI")
		if ai.current_target != null:
			continue
		var facing: Vector2 = ai.get_facing_vector()
		for d in [200.0, 160.0, 240.0, 140.0]:
			var pt: Vector2 = n.global_position + facing * d
			if ai.is_in_line_of_sight(pt, 0.0) and game._sight_line_clear(pt, n.global_position):
				onlooker = n
				spot = pt
				break
		if onlooker:
			break
	_check("eye.found-an-onlooker-with-a-clear-spot", onlooker != null)
	if onlooker == null:
		return
	var old_pos: Vector2 = p.global_position
	var old_rot: float = p.rotation
	p.global_position = spot
	p.rotation = (onlooker.global_position - spot).angle() + PI / 2.0   # face the onlooker
	game._update_npc_los_visibility()   # the LOS pass is frozen while paused
	_check("eye.party-sees-the-onlooker", game.is_seen_by_party(onlooker))
	_check("eye.onlooker-has-the-member-in-view", overlay.is_in_view_of_onlooker(p))
	await get_tree().create_timer(0.3, true).timeout   # > EYE_REFRESH_SEC
	_check("eye.drawn-over-the-member", overlay.is_marked_in_view(p))
	# An onlooker the party can't see must not reveal itself.
	game._npc_was_truly_seen[onlooker] = false
	var revealed: bool = false
	for n in npcs:
		if n != onlooker and is_instance_valid(n) and game.is_seen_by_party(n):
			revealed = true   # another visible onlooker could legitimately see p
	if not revealed:
		_check("eye.hidden-onlooker-doesnt-count", not overlay.is_in_view_of_onlooker(p))
	game._update_npc_los_visibility()
	# Right behind the onlooker while sneaking: close quarters doesn't apply,
	# so out of its view cone means out of view.
	var ai = onlooker.get_node("AI")
	var behind: Vector2 = onlooker.global_position - ai.get_facing_vector() * 60.0
	p.global_position = behind
	if not ai.is_in_line_of_sight(behind, 0.0):
		var others_see := false
		for n in npcs:
			if n != onlooker and is_instance_valid(n) and n.has_node("AI") and n.AI_enabled and n.get_node("AI").has_in_view(p):
				others_see = true
		if not others_see:
			_check("eye.none-behind-the-onlooker-while-sneaking", not overlay.is_in_view_of_onlooker(p))
		_check("eye.close-quarters-sees-a-non-sneaker", (func():
			game.stealth_mode = false
			var seen: bool = ai.has_in_view(p) == ai._has_clear_sight_line(behind, 0.0)
			game.stealth_mode = true
			return seen).call())
	p.global_position = old_pos
	p.rotation = old_rot
	game._update_npc_los_visibility()

# Velocity one movement step gives the character, walking toward a point 300
# px away (tries four directions; returns 0 if every one is blocked).
func _measure_walk_velocity(p) -> float:
	var start: Vector2 = p.global_position
	for dir in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
		p.global_position = start
		p.velocity = Vector2.ZERO
		p.target_position = start + dir * 300.0
		p.is_moving = true
		p._update_movement(1.0 / 60.0)
		var v: float = p.velocity.length()
		p.is_moving = false
		p.global_position = start
		p.velocity = Vector2.ZERO
		if v > 0.0:
			return v
	return 0.0

# Loudness of one footstep as HearingManager hears it.
func _measure_footstep(p) -> float:
	var got := []
	var cb := func(_pos, loudness, source):
		if source == p:
			got.append(loudness)
	HearingManager.sound_emitted.connect(cb)
	p._emit_footstep()
	HearingManager.sound_emitted.disconnect(cb)
	return float(got[0]) if not got.is_empty() else 0.0

# ---------------------------------------------------------------------------
# I5: noise visibility
# ---------------------------------------------------------------------------

const AUTHORED_NOISE := {
	"kettle_helm": 0.05, "fancy_metal_helmet": 0.05, "full_face_helmet": 0.05, "golden_crown_helm": 0.05,
	"dark_hood": 0.0, "purple_hood": 0.0, "leather_backpack": 0.05, "adventurer's_pack": 0.08,
	"red_travel_cape": 0.0, "shadow_cloak": 0.0, "venonan_vestments": 0.0, "steel_pauldrons": 0.1,
	"leather_pants": 0.02, "armored_leggings": 0.2, "leather_boots": 0.1, "steel_greaves": 0.3,
	"breastplate_2": 0.4, "leather_armor": 0.06, "legionnaires_armor": 0.35, "dark_robes": 0.0,
	"padded_vest": 0.03, "peasant's_stained_shirt": 0.0, "noble's_blouse": 0.0,
}

func _hearing_helper_cases() -> void:
	var HM = HearingManager
	_check("hearing.radius-1.0-is-240px", is_equal_approx(HM.audible_radius(1.0), 240.0), HM.audible_radius(1.0))
	_check("hearing.radius-scales-with-hearing", is_equal_approx(HM.audible_radius(0.5, 2.0), 240.0))
	_check("hearing.radius-negative-is-0", is_equal_approx(HM.audible_radius(-1.0), 0.0))
	_check("hearing.loud-sounds-carry-2.5x", is_equal_approx(HM.audible_radius(1.5), 240.0 * 1.5 * HM.LOUD_RANGE_MULT), HM.audible_radius(1.5))
	_check("hearing.one-wall", is_equal_approx(HM.audible_radius(1.0, 1.0, 1), 240.0 * HM.WALL_OCCLUSION_FACTOR))
	_check("hearing.walls-capped", is_equal_approx(HM.audible_radius(1.0, 1.0, 9), HM.audible_radius(1.0, 1.0, HM.MAX_OCCLUDERS)))
	var tiers := {0.0: "Quiet", 0.39: "Quiet", 0.4: "Normal", 0.99: "Normal", 1.0: "Loud", 1.5: "Loud"}
	for l in tiers:
		_check("hearing.tier-%.2f-%s" % [l, tiers[l]], HM.loudness_tier(l) == tiers[l], HM.loudness_tier(l))

# The readout radius is the reach NPCs actually hear at: a listener just
# inside it hears the step, one just outside doesn't.
func _hearing_matches_emit_cases() -> void:
	var p = game.party_chars[0]
	var listener = null
	for n in _npcs():
		if is_instance_valid(n) and n.is_alive() and n.has_node("AI"):
			listener = n
			break
	if listener == null:
		print("SKIP hearing.matches-emit (no NPC)")
		return
	var ai = listener.get_node("AI")
	var old_pos: Vector2 = listener.global_position
	var old_ease: bool = ai.is_at_ease
	ai.is_at_ease = false
	var loud := 0.6
	var r: float = HearingManager.audible_radius(loud, listener.effective_hearing())
	var dir := Vector2.ZERO
	for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
		if game._sight_line_clear(p.global_position, p.global_position + d * (r + 20.0)):
			dir = d
			break
	if dir == Vector2.ZERO:
		print("SKIP hearing.matches-emit (no open line)")
	else:
		var marker := Vector2(-9999, -9999)
		listener.global_position = p.global_position + dir * (r - 4.0)
		ai.last_heard_position = marker
		HearingManager.emit(p.global_position, loud, p)
		_check("hearing.inside-the-radius-heard", ai.last_heard_position != marker, ai.last_heard_position)
		listener.global_position = p.global_position + dir * (r + 4.0)
		ai.last_heard_position = marker
		HearingManager.emit(p.global_position, loud, p)
		_check("hearing.outside-the-radius-not-heard", ai.last_heard_position == marker, ai.last_heard_position)
	listener.global_position = old_pos
	ai.is_at_ease = old_ease
	await _frames(1)

func _item_noise_cases() -> void:
	var f := FileAccess.open("res://data/Items.json", FileAccess.READ)
	var items = JSON.parse_string(f.get_as_text())
	_check("items.json-parses", items is Array)
	if not (items is Array):
		return
	var found := 0
	var wrong := []
	var item_vs_shape := []
	for d in items:
		if not (d is Dictionary) or not AUTHORED_NOISE.has(d.get("id")):
			continue
		found += 1
		var want: float = AUTHORED_NOISE[d["id"]]
		var got: float = EquipmentShape.noise_for_item_data(d)
		if not is_equal_approx(got, want):
			wrong.append("%s %.2f != %.2f" % [d["id"], got, want])
		# The equipped shape must carry the same number (it read nothing before).
		var shape = EquipmentShape.new()
		shape.load_from_data(d)
		if not is_equal_approx(shape.noise_per_step, want):
			wrong.append("%s shape %.2f" % [d["id"], shape.noise_per_step])
		shape.free()
		# A world Item made from the same entry agrees too.
		var it = game.create_item(d["id"], Vector2(-5000, -5000))
		if it != null:
			if not is_equal_approx(it.noise_per_step, want):
				item_vs_shape.append("%s item %.2f" % [d["id"], it.noise_per_step])
			game.items_in_scene.erase(it)
			it.queue_free()
	var wearables := 0
	for d in items:
		if d is Dictionary and str(d.get("equip_slot", "")) in ["Head", "Torso", "Back", "Cape", "Legs", "Feet", "Shoulders"]:
			wearables += 1
			if d.get("noise_per_step") == null:
				wrong.append("%s has no authored noise" % d.get("id"))
	_check("items.all-%d-wearables-authored" % wearables, found == 23 and found == wearables, [found, wearables])
	_check("items.shapes-and-data-match-the-authored-value", wrong.is_empty(), wrong)
	_check("items.world-items-match-the-worn-value", item_vs_shape.is_empty(), item_vs_shape)
	# Heuristic fallback (no authored value): keyed on type + display_name.
	_check("fallback.steel-greaves-0.30", is_equal_approx(EquipmentShape.noise_for_item_data({"type": "boots", "display_name": "Steel Greaves"}), 0.30))
	_check("fallback.leather-armor-0.06", is_equal_approx(EquipmentShape.noise_for_item_data({"type": "armor", "display_name": "Leather Armor"}), 0.06))
	_check("fallback.chain-mail-0.30", is_equal_approx(EquipmentShape.noise_for_item_data({"type": "armor", "id": "chain_mail"}), 0.30))
	_check("fallback.plain-boots-0.15", is_equal_approx(EquipmentShape.noise_for_item_data({"type": "boots"}), 0.15))
	_check("fallback.a-chest-is-not-armour", is_equal_approx(EquipmentShape.noise_for_item_data({"type": "chest", "display_name": "Treasure Chest"}), 0.0))
	_check("fallback.authored-wins", is_equal_approx(EquipmentShape.noise_for_item_data({"type": "boots", "display_name": "Steel Greaves", "noise_per_step": 0.05}), 0.05))

	# Tooltips: the same number, in every item window.
	var IT = load("res://UI/ItemTooltip.gd")
	var greaves: Dictionary = ItemDatabase.get_item_data("steel_greaves")
	var lines: PackedStringArray = IT.noise_lines({"kind": "item", "raw": greaves})
	_check("tooltip.greaves-noise-line", lines.size() >= 1 and lines[0] == "Noise when worn: loud (+0.30 per step)", lines)
	_check("tooltip.greaves-boots-line", lines.size() == 2 and lines[1].begins_with("Boots:"), lines)
	var hood_lines: PackedStringArray = IT.noise_lines({"kind": "item", "raw": ItemDatabase.get_item_data("dark_hood")})
	_check("tooltip.hood-silent", hood_lines.size() == 1 and hood_lines[0] == "Noise when worn: silent", hood_lines)
	var leather_lines: PackedStringArray = IT.noise_lines({"kind": "item", "raw": ItemDatabase.get_item_data("leather_armor")})
	_check("tooltip.leather-armour-light", leather_lines.size() == 1 and leather_lines[0] == "Noise when worn: light (+0.06 per step)", leather_lines)
	_check("tooltip.pauldrons-no-slot-no-line", IT.noise_lines({"kind": "item", "raw": ItemDatabase.get_item_data("steel_pauldrons")}).is_empty())
	_check("tooltip.non-wearables-no-line", IT.noise_lines({"kind": "item", "raw": {"id": "bread", "equip_slot": null}}).is_empty() and IT.noise_lines({"kind": "weapon", "raw": null}).is_empty())
	for ctx in ["", "trade", "chest", "service"]:
		var txt: String = IT.detail_text({"kind": "item", "display_name": "Steel Greaves", "raw": greaves, "num_stacks": 1}, ctx)
		_check("tooltip.detail-text-'%s'-shows-the-noise" % ctx, txt.contains("Noise when worn: loud (+0.30 per step)"), txt)

func _readout_cases() -> void:
	var p = game.party_chars[0]
	# Wear Steel Greaves: the worn shape reads 0.30 and the step includes it.
	var greaves: Dictionary = ItemDatabase.get_item_data("steel_greaves").duplicate(true)
	var old_feet = p.feet_equipment.get_meta("item_data") if p.feet_equipment and p.feet_equipment.has_meta("item_data") else null
	p.equip_equipment(greaves)
	_check("readout.worn-greaves-add-0.30", p.feet_equipment != null and is_equal_approx(p.feet_equipment.noise_per_step, 0.30), p.feet_equipment.noise_per_step if p.feet_equipment else -1)
	var n: Dictionary = p.footstep_noise()
	var expect: float = (float(n["floor_base"]) * float(n["footwear_mult"]) + float(n["gear"])) * float(n["race_mult"]) * float(n["sneak_mult"])
	_check("readout.loudness-formula", is_equal_approx(float(n["loudness"]), expect), [n["loudness"], expect])
	_check("readout.boots-worn-footwear-1", n["boots"] and is_equal_approx(float(n["footwear_mult"]), 1.0))
	_check("readout.race-mult-is-walking-noise", is_equal_approx(float(n["race_mult"]), p.walking_noise))
	var names := []
	for g in n["gear_items"]:
		names.append(g[0])
	_check("readout.names-the-greaves", "Steel Greaves" in names, names)
	var heard := _measure_footstep(p)
	_check("readout.equals-what-npcs-hear", is_equal_approx(heard, float(n["loudness"])), [heard, n["loudness"]])
	game.set_stealth_mode(true)
	var ns: Dictionary = p.footstep_noise()
	_check("readout.sneaking-in-the-breakdown", is_equal_approx(float(ns["sneak_mult"]), p.SNEAK_NOISE_MULT) and is_equal_approx(float(ns["loudness"]), float(n["loudness"]) * p.SNEAK_NOISE_MULT), [ns["sneak_mult"], ns["loudness"]])

	# Party panel: "<tier> steps" + breakdown tooltip, on the HP row.
	var panel = game.get_node_or_null("GameUI/PartySidePanel")
	_check("panel.present", panel != null)
	if panel:
		var data = null
		for d in panel._character_panels:
			if d.get("character") == p:
				data = d
		_check("panel.has-a-footsteps-label", data != null and data.get("noise_label") != null)
		if data != null and data.get("noise_label") != null:
			var lbl: Label = data["noise_label"]
			var row = lbl.get_parent()
			_check("panel.label-on-the-hp-row-not-the-header", row is HBoxContainer and row.get_parent() == data["container"] \
				and row.get_child(0) is Label and (row.get_child(0) as Label).text == "HP")
			panel._update_footsteps(data, p, 1.0)
			var tier: String = HearingManager.loudness_tier(float(p.footstep_noise()["loudness"]))
			_check("panel.label-reads-tier-steps", lbl.text == "%s steps" % tier, [lbl.text, tier])
			_check("panel.tooltip-breaks-it-down", lbl.tooltip_text.begins_with("Footsteps: " + tier) and lbl.tooltip_text.contains("Sneaking: x0.5") and lbl.tooltip_text.contains("Steel Greaves 0.30") and lbl.tooltip_text.contains("Per step: ("), lbl.tooltip_text)
			print("  tooltip: ", lbl.tooltip_text.replace("\n", " | "))
			_check("panel.label-passes-clicks-on (MOUSE_FILTER_PASS)", lbl.mouse_filter == Control.MOUSE_FILTER_PASS)
			game.set_stealth_mode(false)
			panel._update_footsteps(data, p, 1.0)
			_check("panel.tooltip-drops-sneaking-when-off", not lbl.tooltip_text.contains("Sneaking"), lbl.tooltip_text)
			var was_wm: bool = game.current_map_data.get("is_world_map", false)
			game.current_map_data["is_world_map"] = true
			panel._update_footsteps(data, p, 1.0)
			_check("panel.label-hidden-on-the-world-map", lbl.text == "")
			game.current_map_data["is_world_map"] = was_wm
			panel._update_footsteps(data, p, 1.0)
	game.set_stealth_mode(false)
	# Put the old boots back (or go barefoot as before).
	if old_feet is Dictionary:
		p.equip_equipment(old_feet)
	else:
		p.unequip_slot(EquipmentShape.EquipmentSlot.FEET)
	await _frames(1)

func _ring_cases() -> void:
	var overlay = game.stealth_overlay
	var p = game.party_chars[0]
	await get_tree().create_timer(0.5, true).timeout   # clear the per-source throttle
	var before: int = overlay.get_rings().size()
	p._emit_footstep()
	_check("rings.none-while-stealth-off", overlay.get_rings().size() == before)
	game.set_stealth_mode(true)
	await get_tree().create_timer(0.4, true).timeout
	var loud: float = float(p.footstep_noise()["loudness"])
	p._emit_footstep()
	var rings: Array = overlay.get_rings()
	_check("rings.a-footstep-draws-one", rings.size() == 1, rings.size())
	if rings.size() >= 1:
		_check("rings.sized-to-the-audible-radius", is_equal_approx(float(rings[-1]["r"]), HearingManager.audible_radius(loud)), [rings[-1]["r"], HearingManager.audible_radius(loud)])
		_check("rings.inner-ring-one-wall", is_equal_approx(float(rings[-1]["r_wall"]), HearingManager.audible_radius(loud, 1.0, 1)))
		_check("rings.at-the-character", (rings[-1]["pos"] as Vector2).distance_to(p.global_position) < 0.01)
	p._emit_footstep()
	_check("rings.throttled", overlay.get_rings().size() == 1, overlay.get_rings().size())
	HearingManager.emit(p.global_position, 1.5, p)
	_check("rings.a-loud-sound-always-draws", overlay.get_rings().size() == 2, overlay.get_rings().size())
	var npc = null
	for c in _npcs():
		npc = c
		break
	if npc:
		HearingManager.emit(npc.global_position, 1.5, npc)
		_check("rings.none-for-an-npc", overlay.get_rings().size() == 2, overlay.get_rings().size())
	p.on_world_map = true
	HearingManager.emit(p.global_position, 1.5, p)
	_check("rings.none-on-the-world-map", overlay.get_rings().size() == 2, overlay.get_rings().size())
	p.on_world_map = false
	await get_tree().create_timer(1.0, true).timeout
	_check("rings.fade-out", overlay.get_rings().is_empty(), overlay.get_rings().size())
	HearingManager.emit(p.global_position, 1.5, p)
	game.set_stealth_mode(false)
	_check("rings.stealth-off-clears", overlay.get_rings().is_empty())
