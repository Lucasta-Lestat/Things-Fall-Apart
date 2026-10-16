# res://tests/vision_test.gd
# Headless checks for the shared sight API and what feeds it:
#   1. Globals.get_sight_cone_texture (authored 150 deg, generated wedges).
#   2. A bare character (no Game): range, Perceptive x1.2, Blinded, the
#      can_see_point FOV / range / close-contact rules.
#   3. Creature senses from TopDownCharacters "sensory" (wolf, skeleton) and
#      the AI's live detection_range.
#   4. FogManager vision density: fog centre, rim, overlays without vision,
#      map-wide ambient fog.
#   5. On the real Game (colosseum, no weather group): cones fitted to range
#      and FOV while paused, Blinded / dead cones off, the party-visibility
#      rule, crime-witness LOS, weather (heavy rain halves sight, the log line,
#      indoors ignores it) and fog concealing a target.
# Run:  godot --headless --path . res://tests/vision_test.tscn
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

func _approx(a: float, b: float, eps: float = 0.5) -> bool:
	return absf(a - b) <= eps

func _ready() -> void:
	TimeManager.pause_time()
	await get_tree().process_frame
	_case_cone_textures()
	await _case_standalone_character()
	await _case_creature_senses()
	await _case_fog_manager()

	var GameScene := load("res://game.tscn")
	game = GameScene.instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _frames(2)
	game.load_map("colosseum")
	await _frames(10)
	await _case_in_game()

	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

# ---------------------------------------------------------------- cones
func _case_cone_textures() -> void:
	_check("cone.150-is-authored", Globals.get_sight_cone_texture(150.0) == Globals.SIGHT_TEXTURE)
	var t270: Texture2D = Globals.get_sight_cone_texture(270.0)
	_check("cone.270-cached", Globals.get_sight_cone_texture(270.4) == t270)
	var img: Image = t270.get_image()
	var c := Vector2(img.get_width() * 0.5, img.get_height() * 0.5)
	var p_in: Vector2 = c + Vector2.from_angle(deg_to_rad(120.0)) * 100.0
	var p_out: Vector2 = c + Vector2.from_angle(deg_to_rad(150.0)) * 100.0
	_check("cone.270-120deg-inside", img.get_pixelv(Vector2i(p_in)).a > 0.9, img.get_pixelv(Vector2i(p_in)))
	_check("cone.270-150deg-outside", img.get_pixelv(Vector2i(p_out)).a < 0.1, img.get_pixelv(Vector2i(p_out)))
	var img360: Image = Globals.get_sight_cone_texture(360.0).get_image()
	var all_in := true
	for a in range(0, 360, 15):
		var p: Vector2 = Vector2(128, 128) + Vector2.from_angle(deg_to_rad(a)) * 120.0
		if img360.get_pixelv(Vector2i(p)).a < 0.9:
			all_in = false
	_check("cone.360-full-disc", all_in)
	_check("cone.generated-256px", t270.get_width() == 256 and img360.get_width() == 256)

# ---------------------------------------------------------------- no Game
func _new_char() -> Node:
	var ch = load("res://Characters/ProceduralCharacter.tscn").instantiate()
	add_child(ch)
	return ch

func _case_standalone_character() -> void:
	var ch = _new_char()
	await _frames(2)
	_check("bare.env-multiplier-1", is_equal_approx(ch._env_sight_mult(Vector2(50, 50)), 1.0))
	_check("bare.range-1440", _approx(ch.get_sight_range_px(), 1440.0), ch.get_sight_range_px())
	ch.condition_manager.apply_condition("perceptive", null, 1)
	_check("bare.perceptive-plus-20pct", _approx(ch.get_sight_range_px(), 1728.0), ch.get_sight_range_px())
	ch.rotation = 0.0  # facing up (-y)
	var here: Vector2 = ch.global_position
	_check("bare.sees-ahead", ch.can_see_point(here + Vector2(0, -400)))
	_check("bare.not-behind", not ch.can_see_point(here + Vector2(0, 400)))
	_check("bare.close-contact-ignores-facing", ch.can_see_point(here + Vector2(0, 60), 0.0, 1.0, 96.0))
	_check("bare.range-limit", not ch.can_see_point(here + Vector2(0, -1800)) and ch.can_see_point(here + Vector2(0, -1700)))
	_check("bare.range-mult", not ch.can_see_point(here + Vector2(0, -1000), 0.0, 0.5))
	var blind = ch.condition_manager.apply_condition("blinded", null, 1, 60.0)
	if blind != null:
		_check("bare.blinded-range-0", _approx(ch.get_sight_range_px(), 0.0), ch.get_sight_range_px())
		_check("bare.blinded-sees-nothing", not ch.can_see_point(here + Vector2(0, -10)))
		ch.condition_manager.remove_condition("blinded")
	else:
		print("SKIP bare.blinded (resisted)")
	ch.condition_manager.remove_condition("perceptive")
	_check("bare.conditions-removed-1440", _approx(ch.get_sight_range_px(), 1440.0), ch.get_sight_range_px())
	ch.current_health = 0
	_check("bare.dead-sees-nothing", not ch.can_see_point(here + Vector2(0, -100)))
	ch.queue_free()
	await _frames(1)

func _case_creature_senses() -> void:
	var wolf = _new_char()
	await _frames(1)
	TopDownCharacterDatabase.build_character(wolf, "wild_wolf")
	_check("senses.wolf-sight-1.5", is_equal_approx(wolf.sight, 1.5), wolf.sight)
	_check("senses.wolf-hearing-2.0", is_equal_approx(wolf.hearing, 2.0), wolf.hearing)
	_check("senses.wolf-fov-270", is_equal_approx(wolf.fov_angle_degrees, 270.0), wolf.fov_angle_degrees)
	_check("senses.wolf-range-2160", _approx(wolf.get_sight_range_px(), 2160.0), wolf.get_sight_range_px())
	var ai = wolf.get_node_or_null("AI")
	_check("senses.ai-detection-range-live", ai != null and _approx(ai.detection_range, 2160.0), ai.detection_range if ai else null)
	wolf.condition_manager.apply_condition("perceptive", null, 1)
	_check("senses.perceptive-wolf-2592", _approx(wolf.get_sight_range_px(), 2592.0), wolf.get_sight_range_px())
	_check("senses.ai-follows-perceptive", ai != null and _approx(ai.detection_range, 2592.0), ai.detection_range if ai else null)
	wolf.rotation = 0.0
	# 270 deg FOV: 120 deg off facing is seen, straight behind is not.
	var side: Vector2 = wolf.global_position + Vector2.UP.rotated(deg_to_rad(120.0)) * 300.0
	_check("senses.wolf-sees-120deg-side", wolf.can_see_point(side))
	_check("senses.wolf-blind-spot-behind", not wolf.can_see_point(wolf.global_position + Vector2(0, 300)))
	var skel = _new_char()
	await _frames(1)
	TopDownCharacterDatabase.build_character(skel, "skeleton_warrior")
	skel.rotation = 0.0
	_check("senses.skeleton-360-sees-behind", skel.can_see_point(skel.global_position + Vector2(0, 300)))
	_check("senses.skeleton-range-1152", _approx(skel.get_sight_range_px(), 1152.0), skel.get_sight_range_px())
	_check("senses.skeleton-hearing-0.3", is_equal_approx(skel.hearing, 0.3), skel.hearing)
	wolf.queue_free()
	skel.queue_free()
	await _frames(1)

# ---------------------------------------------------------------- fog
func _case_fog_manager() -> void:
	var fm = load("res://Characters/fog_manager.gd").new()
	add_child(fm)
	await _frames(1)
	var ovs: Array = fm.create_fog_from_id("thick_fog", Vector2(1000, 1000))
	await _frames(1)
	_check("fog.thick-centre-x0.40", _approx(fm.get_sight_multiplier_at(Vector2(1000, 1000)), 0.40, 0.01), fm.get_sight_multiplier_at(Vector2(1000, 1000)))
	_check("fog.outside-x1", is_equal_approx(fm.get_sight_multiplier_at(Vector2(5000, 5000)), 1.0))
	var corner: Vector2 = ovs[0].global_position + Vector2(2, 2)
	_check("fog.rect-corner-clear", is_equal_approx(fm.get_sight_multiplier_at(corner), 1.0), fm.get_sight_multiplier_at(corner))
	var edge: Vector2 = ovs[0].global_position + Vector2(ovs[0].size.x * 0.5, 4.0)
	_check("fog.faded-at-the-edge", fm.get_sight_multiplier_at(edge) > 0.95, fm.get_sight_multiplier_at(edge))
	_check("fog.lets-the-mouse-through", ovs[0].mouse_filter == Control.MOUSE_FILTER_IGNORE)
	var multi: Array = fm.create_fog_from_id("zip_smoke", Vector2(4000, 4000))
	_check("fog.extra-overlays-no-vision", multi.size() == 2 and multi[1].vision_density == 0.0)
	_check("fog.smoke-centre", _approx(fm.get_sight_multiplier_at(Vector2(4000, 4000)), 1.0 - 0.75 * 0.65, 0.01), fm.get_sight_multiplier_at(Vector2(4000, 4000)))
	fm.clear_all_fog()
	var mf: Array = fm.create_map_fog("fog", Vector2(2048, 2048))
	_check("fog.map-fog-one-overlay", mf.size() == 1)
	if mf.size() == 1:
		var r := Rect2(mf[0].global_position, mf[0].size)
		_check("fog.map-fog-covers-the-map", r.encloses(Rect2(Vector2.ZERO, Vector2(2048, 2048))), r)
	var dense := 1.0 - 0.75 * 0.45
	_check("fog.map-fog-centre", _approx(fm.get_sight_multiplier_at(Vector2(1024, 1024)), dense, 0.01), fm.get_sight_multiplier_at(Vector2(1024, 1024)))
	_check("fog.map-fog-corner", _approx(fm.get_sight_multiplier_at(Vector2(4, 4)), dense, 0.02), fm.get_sight_multiplier_at(Vector2(4, 4)))
	fm.queue_free()
	await _frames(1)

# ---------------------------------------------------------------- in game
func _cone_radius(l: PointLight2D) -> float:
	return l.texture_scale * l.texture.get_width() * 0.5

func _case_in_game() -> void:
	_check("game.loaded", game != null and game.party_chars.size() > 0)
	if game == null or game.party_chars.is_empty():
		return
	PauseManager.is_paused = true  # cones must refit while paused (planning)
	var p = game.party_chars[0]
	var los: PointLight2D = p.get_node_or_null("LineOfSight")
	_check("game.party-cone", los != null)
	if los == null:
		return
	var r0: float = p.get_sight_range_px()
	_check("game.cone-radius-is-range", _approx(_cone_radius(los), r0, 1.0), [_cone_radius(los), r0])
	p.condition_manager.apply_condition("perceptive", null, 1)
	await _frames(2)
	var r1: float = p.get_sight_range_px()
	_check("game.perceptive-lengthens-cone-paused", r1 > r0 * 1.19 and _approx(_cone_radius(los), r1, 1.0), [r0, r1, _cone_radius(los)])
	var blind = p.condition_manager.apply_condition("blinded", null, 1, 60.0)
	if blind != null:
		await _frames(2)
		_check("game.blinded-cone-off", not los.enabled)
		p.condition_manager.remove_condition("blinded")
	p.condition_manager.remove_condition("perceptive")
	await _frames(2)
	_check("game.cone-back-on", los.enabled)

	# A wolf spawned by Game, 300 px off in a direction with a clear sight
	# line: its cone wedge matches its 270 deg FOV.
	var face: float = 0.0
	for deg in range(0, 360, 30):
		var a: float = deg_to_rad(deg)
		if GridManager.sight_line_clear(p.get_world_2d().direct_space_state, p.global_position,
				p.global_position + Vector2.UP.rotated(a) * 300.0, p.get_elevation(), 0.0):
			face = a
			break
	var wolf = game._spawn_character("wild_wolf", p.global_position + Vector2.UP.rotated(face) * 300.0)
	_check("game.wolf-spawned", wolf != null)
	if wolf == null:
		PauseManager.is_paused = false
		return
	wolf.AI_enabled = false
	game._add_npc_line_of_sight_light(wolf)
	await _frames(2)
	var wl: PointLight2D = wolf.get_node_or_null("NPCLineOfSight")
	_check("game.wolf-cone-generated-wedge", wl != null and wl.texture != Globals.SIGHT_TEXTURE and wl.texture.get_width() == 256)
	_check("game.wolf-cone-radius", wl != null and _approx(_cone_radius(wl), wolf.get_sight_range_px(), 1.0),
		[_cone_radius(wl) if wl else null, wolf.get_sight_range_px()])
	var ai = wolf.get_node("AI")
	_check("game.ai-los-is-can-see-point", ai.is_in_line_of_sight(p.global_position, p.get_elevation()) == wolf.can_see_point(p.global_position, p.get_elevation()))
	_check("game.witness-los-is-can-see-point", CrimeManager.has_visual_los(wolf, p.global_position, p.get_elevation()) == wolf.can_see_point(p.global_position, p.get_elevation()))
	# Party visibility: is_seen_by_party answers with the visibility rule.
	p.rotation = face
	PauseManager.is_paused = false   # the LOS pass runs unpaused
	await _frames(2)
	_check("game.seen-equals-rule", game.is_seen_by_party(wolf) == game._is_character_visible_to_party(wolf))
	_check("game.wolf-ahead-seen", game.is_seen_by_party(wolf), [p.rotation, face, p.global_position, wolf.global_position])
	p.rotation = face + PI
	await _frames(2)
	var others_see := false
	for ally in game.party_chars:
		if ally != p and ally.can_see_point(wolf.global_position, wolf.get_elevation()):
			others_see = true
	_check("game.facing-away-seen-only-by-companions", game.is_seen_by_party(wolf) == others_see)
	PauseManager.is_paused = true
	# A corpse sees nothing, so its cone goes out (and comes back if revived).
	var hp: int = wolf.current_health
	wolf.current_health = 0
	await _frames(2)
	_check("game.dead-cone-off", wl != null and not wl.enabled and not wolf.can_see_point(wolf.global_position + Vector2(0, -100)))
	wolf.current_health = hp
	await _frames(2)
	_check("game.alive-again-cone-on", wl != null and wl.enabled)
	await _case_weather_in_game(p, wolf)
	PauseManager.is_paused = false

func _log_has(fragment: String) -> bool:
	for e in GameLog.get_entries():
		if fragment in str(e.get("text", "")):
			return true
	return false

func _case_weather_in_game(p, npc) -> void:
	_check("weather.clear-multiplier-1", is_equal_approx(game.get_weather_visibility_mult(), 1.0), game.get_weather_visibility_mult())
	var base: float = p.get_sight_range_px()
	game.force_weather("heavy_rain")
	await _frames(2)
	_check("weather.current-precipitation-groupless", game.current_precipitation() == "heavy_rain", game.current_precipitation())
	_check("weather.heavy-rain-halves-sight", _approx(p.get_sight_range_px(), base * 0.5, 1.0), [base, p.get_sight_range_px()])
	var los: PointLight2D = p.get_node("LineOfSight")
	_check("weather.cone-follows", _approx(_cone_radius(los), p.get_sight_range_px(), 1.0))
	var ai = npc.get_node("AI")
	_check("weather.npc-detection-follows", _approx(ai.detection_range, npc.get_sight_range_px(), 0.5) and npc.get_sight_range_px() < 2160.0 * 0.51, ai.detection_range)
	_check("weather.log-sight-drops", _log_has("Sight drops to 50%"))
	# Indoors maps ignore the weather for sight.
	game.current_map_data["indoors"] = true
	game._refresh_weather_state()
	_check("weather.indoors-full-sight", is_equal_approx(game.get_weather_visibility_mult(), 1.0))
	game.current_map_data.erase("indoors")
	game._refresh_weather_state()
	game.force_weather("clear")
	await _frames(1)
	_check("weather.clear-again-full-sight", _approx(p.get_sight_range_px(), base, 1.0))
	_check("weather.log-full-sight-returns", _log_has("Full sight returns"))
	# Fog conceals a target standing in it: a point 600 px ahead is seen in
	# the clear and hidden once thick fog sits on it (1440 x 0.4 = 576 < 600).
	var spot := Vector2.INF
	for deg in range(0, 360, 15):
		p.rotation = deg_to_rad(deg)
		var cand: Vector2 = p.global_position + Vector2.UP.rotated(p.rotation) * 600.0
		if p.can_see_point(cand):
			spot = cand
			break
	_check("fog.found-a-clear-spot", spot != Vector2.INF)
	if spot == Vector2.INF:
		return
	var fog_ovs: Array = game.fog_manager.create_fog_from_id("thick_fog", spot)
	await _frames(1)
	_check("fog.thick-fog-on-target-hides-it", not p.can_see_point(spot), p.get_sight_range_px_to(spot))
	_check("fog.range-to-fogged-target-shorter", p.get_sight_range_px_to(spot) < p.get_sight_range_px(), [p.get_sight_range_px_to(spot), p.get_sight_range_px()])
	for o in fog_ovs:
		game.fog_manager.remove_fog(o)
	await _frames(1)
