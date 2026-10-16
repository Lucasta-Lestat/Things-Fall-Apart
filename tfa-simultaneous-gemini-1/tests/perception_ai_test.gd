# res://tests/perception_ai_test.gd
# Headless checks for NPC perception on dev's occluded-chase AI:
#   - a held target behind a wall is dropped after TARGET_OCCLUSION_GIVE_UP,
#     the NPC searches its last-seen point with the yellow '?', and
#     '<NPC> loses sight of <Name>.' is logged when the party can see the NPC;
#   - only the held target's own sounds and hits move last_known_target_pos;
#   - the 1.5x held-target range follows the live sight range, floored at
#     close quarters (a Blinded NPC keeps the foe at its elbow);
#   - the alertness glyph's three stages (pale small '?', yellow '?', red '!'),
#     the outcry fuse's full-size '!', and the glyph staying upright.
# Run:  godot --headless --path . res://tests/perception_ai_test.tscn
# Judge by PASS/FAIL lines and the HARNESS DONE count.
extends Node2D

var failures := 0
var game = null
var ai = null
var bandit = null
var p = null

func _check(check_name: String, cond: bool, detail = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, str(detail)])

func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

# Drive the bandit's AI by hand (the game stays paused, so nothing else moves).
func _step(seconds: float) -> void:
	var t := 0.0
	while t < seconds - 0.0001:
		ai.process_ai(0.1)
		t += 0.1

func _log_count(text: String) -> int:
	var n := 0
	for e in GameLog.get_entries():
		if text in str(e.get("text", "")):
			n += 1
	return n

func _face(who, at: Vector2) -> void:
	who.rotation = (at - who.global_position).angle() + PI / 2

# Refresh the party's LOS cache (it only runs unpaused), AIs stay off.
func _refresh_party_los() -> void:
	PauseManager.is_paused = false
	await _frames(2)
	PauseManager.is_paused = true

func _ready() -> void:
	TimeManager.pause_time()
	await get_tree().process_frame
	var GameScene := load("res://game.tscn")
	game = GameScene.instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _frames(2)
	game.load_map("colosseum")
	await _frames(10)
	await _run()
	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _run() -> void:
	PauseManager.is_paused = true
	for c in game.characters_in_scene:
		c.AI_enabled = false
	p = game.party_chars[0]
	var centre := Vector2(768, 768)
	p.global_position = centre
	# Companions out of the picture: far away and nobody's enemy.
	for i in range(1, game.party_chars.size()):
		game.party_chars[i].global_position = centre + Vector2(-600 - i * 40, -600)
		game.party_chars[i].faction_id = "neutral"
	bandit = game._spawn_character("bandit", centre + Vector2(0, 200))
	_check("setup.bandit-spawned", bandit != null)
	if bandit == null:
		return
	bandit.AI_enabled = false
	ai = bandit.get_node("AI")
	for c in game.characters_in_scene:
		if c != bandit and not (c in game.party_chars):
			c.global_position = centre + Vector2(5000, 5000)
	await _frames(3)

	# ---------------- acquisition
	_face(bandit, p.global_position)
	_face(p, bandit.global_position)
	_step(0.3)
	_check("acquire.bandit-targets-the-protagonist", ai.current_target == p, ai.current_target)

	# ---------------- live held-target range (1.5x the current sight range)
	var base_sight: float = bandit.sight
	bandit.sight = 0.1   # 144 px sight, 216 px held
	p.global_position = bandit.global_position + Vector2(0, -180)
	_face(bandit, p.global_position)
	_step(0.3)
	_check("range.held-at-1.25x-live-sight", ai.current_target == p, ai.current_target)
	p.global_position = bandit.global_position + Vector2(0, -260)
	_step(0.3)
	_check("range.lost-beyond-1.5x-live-sight", ai.current_target == null, ai.current_target)
	bandit.sight = base_sight
	p.global_position = centre
	_face(bandit, p.global_position)
	_step(0.3)
	_check("range.re-acquired", ai.current_target == p, ai.current_target)

	# ---------------- Blinded (live range 0): a foe at its elbow stays held,
	# one out of close quarters is dropped; cured, it re-acquires by sight.
	var cq: float = ai._close_quarters_radius()
	var bcm = bandit.get_node("ConditionManager")
	p.global_position = bandit.global_position + Vector2(0, -cq * 0.6)
	_face(bandit, p.global_position)
	_step(0.3)
	bcm.apply_condition("blinded", null, 1, 60.0)
	_step(0.3)
	_check("blinded.range-zero", is_zero_approx(ai.detection_range), ai.detection_range)
	_check("blinded.keeps-the-foe-at-its-elbow", ai.current_target == p, ai.current_target)
	_check("blinded.eye-says-not-in-view", not ai.has_in_view(p))
	p.global_position = bandit.global_position + Vector2(0, -(cq + 60.0))
	_step(0.3)
	_check("blinded.drops-a-target-out-of-reach", ai.current_target == null, ai.current_target)
	bcm.remove_condition("blinded")
	p.global_position = centre
	_face(bandit, p.global_position)
	_step(0.3)
	_check("blinded.cured-re-acquires", ai.current_target == p, ai.current_target)

	# ---------------- a wall between them: dropped after the give-up time
	var wall := StaticBody2D.new()
	wall.collision_layer = CollisionLayers.VISION_RAY_MASK
	wall.collision_mask = 0
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(300, 20)
	shape.shape = rect
	wall.add_child(shape)
	wall.global_position = (bandit.global_position + p.global_position) * 0.5
	game.add_child(wall)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var seen_at: Vector2 = p.global_position
	_check("wall.blocks-the-sight-line", not ai._has_clear_sight_line(p.global_position, p.get_elevation()))

	# Sounds and hits while occluded: only the target's own move the search point.
	ai._set_alertness_value(ai.ALERTNESS_MAX)
	var other = bandit
	for c in game.characters_in_scene:
		if c != bandit and c != p and is_instance_valid(c) and c.is_alive():
			other = c
			break
	ai.on_sound_heard(centre + Vector2(300, 300), 0.5, other)
	_check("sound.someone-elses-noise-doesnt-steer", ai.last_known_target_pos.distance_to(seen_at) < 1.0, ai.last_known_target_pos)
	var third = game._spawn_character("bandit", centre + Vector2(400, 0))
	if third != null:
		third.AI_enabled = false
		third.faction_id = "player"   # an enemy of the bandit, not its target
		ai._on_self_damaged(third, bandit.global_position, 1.0)
		_check("hit.third-partys-hit-doesnt-steer", ai.current_target == p and ai.last_known_target_pos.distance_to(seen_at) < 1.0,
			[ai.current_target, ai.last_known_target_pos])
		# Out of the picture again: the bandit's own kind, far away.
		third.faction_id = bandit.faction_id
		third.global_position = centre + Vector2(5000, -5000)
	ai.on_sound_heard(p.global_position + Vector2(10, 0), 0.5, p)
	_check("sound.the-targets-own-noise-does", ai.last_known_target_pos.distance_to(p.global_position + Vector2(10, 0)) < 1.0)
	ai.last_known_target_pos = seen_at

	# A companion on the bandit's side of the wall watches it, so the party
	# sees the NPC give up.
	var observer = game.party_chars[1] if game.party_chars.size() > 1 else null
	if observer != null:
		observer.global_position = bandit.global_position + Vector2(160, 0)
		_face(observer, bandit.global_position)
	await _refresh_party_los()
	_check("log.party-sees-the-bandit", game.is_seen_by_party(bandit))
	var before_logs: int = _log_count("loses sight of")
	_step(ai.TARGET_OCCLUSION_GIVE_UP - 1.0)
	_check("occluded.still-held-within-give-up", ai.current_target == p)
	_step(1.5)
	_check("occluded.dropped-after-give-up", ai.current_target == null, ai.current_target)
	_check("occluded.searching", ai.current_state == ai.AIState.SEARCHING, ai.current_state)
	_check("occluded.search-question-mark", ai.current_alertness == ai.Alertness.SEARCHING, ai.current_alertness)
	_check("occluded.searches-last-seen-point", ai.last_heard_position.distance_to(seen_at) < 1.0, [ai.last_heard_position, seen_at])
	_check("log.loses-sight-of", _log_count("loses sight of") == before_logs + 1, _log_count("loses sight of"))
	wall.queue_free()
	await get_tree().physics_frame

	# Unseen NPC: no log line.
	_face(bandit, p.global_position)
	_step(0.3)
	_check("log.re-acquired", ai.current_target == p)
	for ally in game.party_chars:   # every back turned on the bandit
		ally.rotation = (bandit.global_position - ally.global_position).angle() + PI / 2 + PI
	await _refresh_party_los()
	if not game.is_seen_by_party(bandit):
		before_logs = _log_count("loses sight of")
		ai._announce_lost_sight(p)
		_check("log.unseen-npc-stays-quiet", _log_count("loses sight of") == before_logs)
	else:
		print("SKIP log.unseen-npc-stays-quiet (a companion sees the bandit)")

	await _case_indicator()

# ---------------- alertness indicator: pale ? / yellow ? / red !
func _case_indicator() -> void:
	bandit.AI_enabled = true  # the indicator is for AI-driven NPCs (still paused)
	var ind: Label = bandit.get_node_or_null("AlertnessIndicator")
	_check("glyph.exists", ind != null)
	if ind == null:
		return
	ai._lose_target()
	ai._set_alertness_value(10.0)
	_check("glyph.calm-hidden", not ind.visible)
	ai._set_alertness_value(30.0)
	_check("glyph.suspicious-shown", ind.visible and ind.text == "?")
	_check("glyph.suspicious-small", ind.get_theme_font_size("font_size") == 20, ind.get_theme_font_size("font_size"))
	var c: Color = ind.get_theme_color("font_color")
	_check("glyph.suspicious-pale", c.r > 0.85 and c.g > 0.85 and c.b > 0.85, c)
	ai._set_alertness_value(70.0)
	c = ind.get_theme_color("font_color")
	_check("glyph.searching-28px-yellow", ind.visible and ind.text == "?" and ind.get_theme_font_size("font_size") == 28 and c.b < 0.5 and c.r > 0.9,
		[ind.get_theme_font_size("font_size"), c])
	ai._set_alertness_value(100.0)
	c = ind.get_theme_color("font_color")
	_check("glyph.hostile-28px-red", ind.visible and ind.text == "!" and ind.get_theme_font_size("font_size") == 28 and c.r > 0.9 and c.g < 0.3, [ind.text, c])
	ai._set_alertness_value(10.0)
	_check("glyph.calm-again-hidden", not ind.visible)
	# The outcry fuse's amber '!' is full size even right after a small '?'.
	ai._set_alertness_value(30.0)
	bandit._on_outcry_state_changed(true, 0.0)
	_check("glyph.fuse-full-size", ind.visible and ind.text == "!" and ind.get_theme_font_size("font_size") == 28, ind.get_theme_font_size("font_size"))
	bandit._on_outcry_state_changed(false, 0.0)
	_check("glyph.fuse-over-back-to-suspicious", ind.visible and ind.text == "?" and ind.get_theme_font_size("font_size") == 20)
	# Upright whatever the facing (paused: _process still runs).
	bandit.rotation = PI
	await _frames(2)
	_check("glyph.counter-rotated", absf(wrapf(ind.rotation + PI, -PI, PI)) < 0.01, ind.rotation)
	var above: Vector2 = bandit.get_global_transform() * (ind.position + ind.pivot_offset) - bandit.global_position
	_check("glyph.stays-above-the-head", above.y < -30.0 and absf(above.x) < 1.0, above)
	bandit.AI_enabled = false
