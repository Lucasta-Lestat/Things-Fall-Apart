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


# Compute loudness at the listener, applying wall occlusion damping. Sounds
# carry through walls but are noticeably quieter.
func _loudness_at(from_pos: Vector2, to_pos: Vector2, loudness: float) -> float:
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
