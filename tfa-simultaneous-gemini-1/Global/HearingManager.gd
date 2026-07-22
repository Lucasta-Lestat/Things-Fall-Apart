extends Node

# HearingManager — central broadcaster for in-world sounds that should feed
# the hearing/alertness systems. Footsteps, attacks, ability casts, etc.
# call HearingManager.emit(world_pos, loudness, source). Listeners (NPC AIs
# and the player party for the visibility-pulse effect) are notified if the
# sound carries to their position given their effective_hearing().

# Maximum hearing radius in pixels at loudness=1.0 and hearing=1.0. Tuned to
# be "relatively poor" per design — most enemies can sneak ~3 tiles before
# being noticed. Hearing stat (effective_hearing()) is a multiplier on top.
const BASE_HEARING_RADIUS: float = 240.0

# When a sound's straight line to the listener is blocked by a vision
# blocker (wall), reduce effective loudness by this factor. Sounds still
# carry through walls — just quieter.
const WALL_OCCLUSION_FACTOR: float = 0.45

# Loudness threshold above which a sound cuts through the AT_EASE filter
# (civilians ignore ambient noise but react to gunshots/explosions).
# Gunshot loudness is 1.5; melee swings and clashes are <= 0.9.
const LOUD_SOUND_THRESHOLD: float = 1.2

signal sound_emitted(world_pos: Vector2, loudness: float, source)

# --- Sound-suppression zones ---------------------------------------------
#
# A sound zone is any node that damps sound crossing a region of the map.
# Zones live here rather than on the emitters so that every sound path —
# footsteps, weapon clashes, gunshots, ability casts, environmental noise —
# is damped by the same rule without touching a single call site.
#
# A zone only has to answer one question:
#     sound_gain_for_segment(from_pos, to_pos) -> float
# a multiplier in [0, 1] for a sound travelling that path (1.0 = untouched,
# 0.0 = perfect silence). Anything able to answer that can be a zone;
# SilenceZone is simply the one whose gain is 0.
#
# Testing the whole segment rather than just its endpoints is what makes a
# zone behave like dead air, and gets all three cases from one test: a sound
# made inside never gets out, a listener inside hears nothing from outside,
# and a sound whose path merely crosses the region is damped in passing.
var _sound_zones: Array = []


func register_sound_zone(zone) -> void:
	if zone != null and not (zone in _sound_zones):
		_sound_zones.append(zone)


func unregister_sound_zone(zone) -> void:
	_sound_zones.erase(zone)


## Free every registered zone. Called on map unload so zones cannot leak
## across maps the way ability-spawned force fields currently do.
func clear_sound_zones() -> void:
	for zone in _sound_zones.duplicate():
		if is_instance_valid(zone):
			zone.queue_free()
	_sound_zones.clear()


## Combined gain for a sound travelling between two points. The strongest
## suppressor wins outright rather than stacking, so overlapping zones can
## never damp a sound further than the quietest one would alone.
func sound_gain_between(from_pos: Vector2, to_pos: Vector2) -> float:
	var gain: float = 1.0
	for i in range(_sound_zones.size() - 1, -1, -1):
		var zone = _sound_zones[i]
		if not is_instance_valid(zone):
			_sound_zones.remove_at(i)
			continue
		if not zone.has_method("sound_gain_for_segment"):
			continue
		var zone_gain: float = float(zone.sound_gain_for_segment(from_pos, to_pos))
		if zone_gain < gain:
			gain = zone_gain
		if gain <= 0.0:
			return 0.0
	return gain


## Gain for a sound heard at a single point. Used by audio playback, which
## has an emitter position but no separate listener position.
func sound_gain_at(world_pos: Vector2) -> float:
	return sound_gain_between(world_pos, world_pos)


func emit(world_pos: Vector2, loudness: float, source = null) -> void:
	if loudness <= 0.0:
		return
	sound_emitted.emit(world_pos, loudness, source)

	var game = _get_game()
	if not game or not ("characters_in_scene" in game):
		return

	var party: Array = game.party_chars if "party_chars" in game else []
	var any_party_heard := false

	for listener in game.characters_in_scene:
		if not is_instance_valid(listener):
			continue
		if not listener.has_method("is_alive") or not listener.is_alive():
			continue
		if listener == source:
			continue

		var eff_loudness := _loudness_at(world_pos, listener.global_position, loudness)
		if eff_loudness <= 0.0:
			continue

		var max_dist: float = BASE_HEARING_RADIUS * listener.effective_hearing() * eff_loudness
		if listener.global_position.distance_to(world_pos) > max_dist:
			continue

		# Party listener: only the visibility-pulse path cares. Enemy footsteps
		# (source is non-party char) should pulse the source so the player sees
		# a brief flash.
		if listener in party:
			if source is ProceduralCharacter and not (source in party):
				any_party_heard = true
			continue

		# Non-party listener: route to AI alertness. Filter by faction so enemies
		# don't constantly alert each other from their own footsteps.
		var ai_node = listener.get_node_or_null("AI")
		if ai_node and ai_node.has_method("on_sound_heard"):
			var src_faction := ""
			if source is ProceduralCharacter:
				src_faction = source.faction_id
			# If no source faction (env sound), treat as foreign. If the source
			# IS a character of the same/allied faction, skip alertness.
			if src_faction != "" and not FactionDatabase.are_enemies(listener.faction_id, src_faction):
				continue
			ai_node.on_sound_heard(world_pos, eff_loudness, source)

	if any_party_heard and game.has_method("trigger_hearing_pulse"):
		game.trigger_hearing_pulse(source)


# Compute loudness at the listener, applying sound-zone suppression and wall
# occlusion damping. Sounds carry through walls but are noticeably quieter.
func _loudness_at(from_pos: Vector2, to_pos: Vector2, loudness: float) -> float:
	# Suppression zones are applied before the wall check: a sound already
	# smothered at its source has nothing left for a wall to occlude.
	var zone_gain: float = sound_gain_between(from_pos, to_pos)
	if zone_gain <= 0.0:
		return 0.0
	loudness *= zone_gain

	var tree := get_tree()
	if not tree:
		return loudness
	var root := tree.root
	if not root:
		return loudness
	var world := root.world_2d
	if not world:
		return loudness
	var space := world.direct_space_state
	var params := PhysicsRayQueryParameters2D.create(from_pos, to_pos, CollisionLayers.VISION_RAY_MASK)
	params.collide_with_areas = false
	params.collide_with_bodies = true
	if not space.intersect_ray(params).is_empty():
		return loudness * WALL_OCCLUSION_FACTOR
	return loudness


func _get_game():
	var tree := get_tree()
	if not tree:
		return null
	return tree.current_scene
