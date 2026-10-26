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
# (civilians ignore ambient noise but react to gunshots/explosions), and
# above which the sound carries at extended range (see range_mult in emit).
# Muzzle blast is 1.9, bullet impact 1.5; melee swings/bows are <= 0.9.
const LOUD_SOUND_THRESHOLD: float = 1.2
# How much farther a sound at or above LOUD_SOUND_THRESHOLD carries (range,
# not arousal; see emit).
const LOUD_RANGE_MULT: float = 2.5

# Loudness words for the party's noise readouts (footsteps panel, noise rings):
# below QUIET_MAX is "Quiet" (heard within ~1.5 tiles), from LOUD_MIN up is
# "Loud" (carries past the base hearing radius), in between "Normal".
const QUIET_MAX_LOUDNESS: float = 0.4
const LOUD_MIN_LOUDNESS: float = 1.0

signal sound_emitted(world_pos: Vector2, loudness: float, source)

## How far (px) an ambient sound of this loudness carries to a listener with
## this hearing, through `walls` walls (each takes WALL_OCCLUSION_FACTOR off,
## up to MAX_OCCLUDERS): exactly emit()'s reach, loud sounds' extended range
## included. The party's noise readouts (footsteps panel, noise rings) use it.
func audible_radius(loudness: float, hearing: float = 1.0, walls: int = 0) -> float:
	if loudness <= 0.0:
		return 0.0
	var eff: float = loudness * pow(WALL_OCCLUSION_FACTOR, clampi(walls, 0, MAX_OCCLUDERS))
	var range_mult: float = LOUD_RANGE_MULT if loudness >= LOUD_SOUND_THRESHOLD else 1.0
	return BASE_HEARING_RADIUS * hearing * eff * range_mult

## "Quiet", "Normal" or "Loud", for readouts.
func loudness_tier(loudness: float) -> String:
	if loudness < QUIET_MAX_LOUDNESS:
		return "Quiet"
	if loudness >= LOUD_MIN_LOUDNESS:
		return "Loud"
	return "Normal"

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


## channel: "ambient" (default — footsteps, combat, casts; behaviourally
## unchanged for all pre-existing call sites) or "alarm" (a witness's scream,
## carrying a crime payload to enforcers). Alarms route through the exact
## same wall/zone attenuation — a SilenceZone smothers a scream like any
## other sound, which is the silence-the-witness counterplay. Do NOT give
## alarms a bypass around _loudness_at.
func emit(world_pos: Vector2, loudness: float, source = null,
		channel: String = "ambient", payload: Dictionary = {}) -> void:
	if loudness <= 0.0:
		return
	sound_emitted.emit(world_pos, loudness, source)

	var game = _get_game()
	if not game or not ("characters_in_scene" in game):
		return

	var is_alarm: bool = channel == "alarm"
	# Alarms carry farther, not louder: vision outranges hearing ~6:1
	# (1440×sight vs 240×hearing×loudness), so an unmultiplied scream dies
	# ~5 tiles out and never reaches a guard across a plaza. Range only —
	# arousal (loudness) is tuned independently. Value lives in laws.json.
	var range_mult: float = 1.0
	if is_alarm:
		range_mult = float(LawDatabase.witness_cfg().get("alarm_range_mult", 2.5))
	elif loudness >= LOUD_SOUND_THRESHOLD:
		# Gunshots/explosions CARRY (range, not arousal): the base radius is
		# tuned for footstep stealth (~3 tiles), which left whole firefights
		# inaudible one house over. 1.9-loud muzzle × 2.5 ≈ 18 tiles open air,
		# ~8 tiles through one wall.
		range_mult = LOUD_RANGE_MULT

	var party: Array = game.party_chars if "party_chars" in game else []
	var any_party_heard := false

	for listener in game.characters_in_scene:
		if not is_instance_valid(listener):
			continue
		if not listener.has_method("is_alive") or not listener.is_alive():
			continue
		if listener == source:
			continue

		# Cheap conservative early-out BEFORE the occlusion raycast:
		# attenuation only ever reduces loudness, so the unattenuated reach
		# is a true upper bound. Saves the per-footstep ray fan for every
		# listener that could never have heard it.
		var dist: float = listener.global_position.distance_to(world_pos)
		var reach_bound: float = BASE_HEARING_RADIUS * listener.effective_hearing() * loudness * range_mult
		if dist > reach_bound:
			continue

		var eff_loudness := _loudness_at(world_pos, listener.global_position, loudness)
		if eff_loudness <= 0.0:
			continue

		var max_dist: float = BASE_HEARING_RADIUS * listener.effective_hearing() * eff_loudness * range_mult
		if dist > max_dist:
			continue

		# Party listener: only the visibility-pulse path cares. Enemy footsteps
		# (source is non-party char) should pulse the source so the player sees
		# a brief flash.
		if listener in party:
			if source is ProceduralCharacter and not (source in party):
				any_party_heard = true
			continue

		# Non-party listener: route to AI alertness.
		var ai_node = listener.get_node_or_null("AI")
		if ai_node and ai_node.has_method("on_sound_heard"):
			var src_faction := ""
			if source is ProceduralCharacter:
				src_faction = source.faction_id
			# Ambient gate: NPCs shouldn't constantly alert each other with
			# their own footsteps — which is all this was ever for. Alarms
			# are the inverse (meant to be heard) and bypass it. Player-made
			# sound is always audible, so sneaking is detectable BEFORE the
			# player is hostile — the only ordering under which pre-crime
			# stealth exists. A very loud sound (gunshot, explosion) still
			# reaches an AT_EASE listener whoever made it, a guard's shot
			# included: on_sound_heard only wakes them to UNAWARE.
			if not is_alarm and src_faction != "" and src_faction != "player" \
					and not FactionDatabase.are_hostile(listener.faction_id, src_faction) \
					and not (eff_loudness >= LOUD_SOUND_THRESHOLD and "is_at_ease" in ai_node and ai_node.is_at_ease):
				continue
			ai_node.on_sound_heard(world_pos, eff_loudness, source, channel, payload)

	if any_party_heard and game.has_method("trigger_hearing_pulse"):
		game.trigger_hearing_pulse(source)


# Sounds attenuate per wall crossed, capped — two rooms away is genuinely
# quieter than one (a single binary test made them identical, which erased
# the "indoor crime is quiet crime" contrast the alarm system depends on).
const MAX_OCCLUDERS: int = 3

# Terrain (relief maps only): when the bare heightfield rises above the eye
# line between the two points — a cliff face, a terrace brow, a cave's rock
# mass (the interiors export no walls at all) — the sound counts as this many
# more walls, inside the same MAX_OCCLUDERS cap. One term however much rock
# lies between: a scream through cavern rock is two walls quieter, never
# silenced outright. Before this, sound and physics-ray aim passed straight
# through terrain that sight and fog already treated as solid.
const TERRAIN_OCCLUDERS: int = 2

# Compute loudness at the listener, applying sound-zone suppression and wall
# occlusion damping. Sounds carry through walls but are noticeably quieter.
# Budget: at most MAX_OCCLUDERS physics rays, then ONE terrain walk per
# sound/listener pair, which stops at the first blocking tile and is skipped
# on flat maps or once the walls alone reach the cap. emit() only calls this
# for listeners inside the unattenuated reach.
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
	# Per-occluder damping, mirroring GridManager.sight_line_clear's
	# exclude-list walk (GridManager.gd:199-208), capped at MAX_OCCLUDERS.
	var occluders: int = 0
	for i in range(MAX_OCCLUDERS):
		var hit: Dictionary = space.intersect_ray(params)
		if hit.is_empty():
			break
		loudness *= WALL_OCCLUSION_FACTOR
		occluders += 1
		var exclude: Array = params.exclude.duplicate()
		exclude.append(hit["rid"])
		params.exclude = exclude
	if occluders < MAX_OCCLUDERS and _terrain_blocks(from_pos, to_pos):
		for _k in range(mini(TERRAIN_OCCLUDERS, MAX_OCCLUDERS - occluders)):
			loudness *= WALL_OCCLUSION_FACTOR
	return loudness


# True when the terrain between two points rises above the eye line joining
# them (relief maps only; flat maps never walk). Eye heights stand on the
# ground or deck under each point, the same model as GridManager's relief LOS
# minus its roof slabs (a roof's walls already damp the sound above).
func _terrain_blocks(from_pos: Vector2, to_pos: Vector2) -> bool:
	if not GridManager.relief_los:
		return false
	var h0: float = GridManager.effective_elev(GridManager.world_to_map(from_pos)) + GridManager.EYE_HEIGHT_STORIES
	var h1: float = GridManager.effective_elev(GridManager.world_to_map(to_pos)) + GridManager.EYE_HEIGHT_STORIES
	return GridManager.terrain_line_hit(from_pos, to_pos, h0, h1, false) >= 0.0


func _get_game():
	var tree := get_tree()
	if not tree:
		return null
	return tree.current_scene
