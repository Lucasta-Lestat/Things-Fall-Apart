# Game.gd
# Attach to your main scene or a manager node
extends Node

const ProceduralCharacterScript = preload("res://Characters/ProceduralCharacter.gd")
const WORLD_MAP_OVERLAY_SCRIPT = preload("res://WorldMap/WorldMapOverlay.gd")
const UNEXPLORED_FOG_SCRIPT = preload("res://vfx/unexplored_fog_layer.gd")
const WARP_ARROW_TEXTURE: Texture2D = preload("res://UI/UI Icons/warp_arrow.png")
const WARP_ARROW_DISPLAY_HEIGHT: float = 64.0

@onready var fog_manager: FogManager = $FogManager
@onready var fluid_manager: FluidManager = $FluidManager
@onready var surface_manager: SurfaceManager = $SurfaceManager
@onready var map_loader: Node2D = $MapLoader
@onready var player_camera: Camera2D = $PlayerCamera
@onready var collision_visualizer: Node2D = $CollisionVisualizer

var weather_vfx_controller: Node = null
var weather_debug_window: CanvasLayer = null
var combat_test_window: CanvasLayer = null
# Shared HUD hosts under GameUI, built in _ready. Features plug into them:
# world_tooltip (UI/WorldHoverTooltip.gd) is the one hover tooltip for the map
# (add_provider), hud_status (UI/HudStatusBar.gd) the always-on status strip
# under the clock (add_widget).
var world_tooltip: Control = null
var hud_status: Control = null
var _pending_rival_spawns: Array = []
var _pending_rival_override_faction: bool = false
# Set by start_combat_test around its load_map: party_state already holds the
# fresh test loadouts, which the outgoing party must not be saved over.
var _skip_party_save: bool = false
# Set by load_save around its load_map: the service-NPC and world-item state
# just loaded must not be overwritten from the outgoing map's live scene.
var _skip_unload_capture: bool = false


var CharacterScene = preload("res://Characters/ProceduralCharacter.tscn")
@export var spawn_container: Node2D  # Where to spawn characters

var characters_database: Array = []
var characters_in_scene: Array = []
var party_chars: Array = [] 
var enemies: Array
var player = null
var item_scene: PackedScene = preload("res://Structures/Objects/Item.tscn")
var items_in_scene: Array = []
var structure_scene: PackedScene = preload("res://Structures/Structure.tscn")
var structures_in_scene: Array = []
var current_map_id: String = "tg_town_square"  # TEMP: piazza review ("combat_test" = arena, "tg_castle_keep" = castle level, "tg_castle_demo"/"tg_export" = towns, "cemetery" = built-in)
var current_map_data: Dictionary = {}
var warp_zones: Array = []
var context_menu_open: bool = false
var stealth_mode: bool = false
# Change stealth_mode through set_stealth_mode (the C key), which emits this.
signal stealth_mode_changed(active: bool)
# vfx/StealthOverlay.gd: in-view eyes and noise rings while stealth_mode.
var stealth_overlay: Node2D = null
# Session-scoped unlock memory, keyed "<map_id>|door|<hinge_x>,<hinge_y>" (export-px
# ints from the geometry JSON hinge). Written by Door.interact on successful unlock,
# re-applied by MapLoader on door spawn. Intentionally NOT cleared in
# _unload_current_map: every map change is a full reload (same-map stairs only move
# the party, see _relocate_party), and a consumed key must never soft-lock the
# player. Include in the save system when one lands.
var unlocked_locks: Dictionary = {}

const WORLD_MAP_ID: String = "scarlatti_world"
# Active WorldMapOverlay (only present while we're on a world map). Used by
# set_city_controller() to flip ownership at runtime, civ-style.
var _world_map_overlay: Node2D = null

signal character_selected(character: ProceduralCharacter, index: int)
signal character_deselected(character: ProceduralCharacter)
signal selection_changed()
signal map_loaded(map_id: String)

# Multi-select: all currently selected characters
var selected_characters: Array = []
# Primary selected character (most recently clicked, camera follows this one)
var primary_selected: ProceduralCharacter = null
var primary_index: int = 0
# Backward compat alias
var selected_character: ProceduralCharacter:
	get: return primary_selected
var selected_index: int:
	get: return primary_index

# Selection indicators (one per selected character)
var selection_indicators: Dictionary = {}  # ProceduralCharacter -> Node2D

# ===== VIEW LAYER (DF-style ground/roof slice) =====
# roof_view=false: the ground slice — interiors visible (the ground PNG is
# exported roofless), roof cover hidden, roof-walkers hidden ("characters on
# roofs are seen only on the higher layer"). roof_view=true: RoofLayer quads
# cover interiors (and everyone in them, by z), roof-walkers draw above the
# cover via their on_roof z boost. Auto-follows the primary selection's layer
# every frame (_process); structured maps only (legacy maps have no roof data).
var roof_view: bool = false
var roof_layer: Node2D = null   # RoofLayer under map_loader; freed on unload
# Manual layer browse (Ctrl+scroll, DF-style): -1 = follow the selection
# (auto), 0 = pin ground, 1 = pin roof. Cleared whenever the auto answer
# CHANGES (the selected character climbs/drops — their layer wins again) and
# on a fresh selection (mirrors the camera's manual-pan re-engage).
var roof_view_override: int = -1
var _roof_view_auto: bool = false
const SELECTION_CIRCLE_COLOR = Color(1, 1, 1, 0.8)  # White (primary)
const SELECTION_CIRCLE_COLOR_MULTI = Color(0.5, 0.7, 1.0, 0.5)  # Blue (multi-select)
const SELECTION_CIRCLE_WIDTH = 1.0

# ---------------------------------------------------------------------------
# Party state — persists across map transitions and save/load
# ---------------------------------------------------------------------------
# party_state holds the player + allies as an array of dicts.
# Index 0 is always the protagonist. Each entry has:
#   "template_id" : the CharacterDatabase template
#   "overrides"   : any build_character overrides (race, gender, etc.)
#   "live_state"  : runtime snapshot (hp, mp, blood, inventory, conditions)
#                   null on first spawn, populated by save_party_state()
 # ---------------------------------------------------------------------------
# Party state management
# ---------------------------------------------------------------------------
 
var party_state: Array = [
	{"template_id": "protagonist", "overrides": {}, "live_state": null},
	{"template_id": "jacana", "overrides": {}, "live_state": null},
	# grimalkin (cat-folk, jump-capable): can pounce onto roofs
	{"template_id": "djargo", "overrides": {}, "live_state": null},
]

# Service-NPC state per region. Lets trades and inventory changes survive
# map transitions and saves. Keyed by region_id -> npc_uid -> live_state dict
# (same shape as party_state[i].live_state).
var npc_state_per_region: Dictionary = {}
# World-item state per map (law/crime Phase 7): captured wholesale on unload,
# restored in place of the authored spawns on revisit. A taken item is simply
# absent from the records; an emptied chest stays emptied. Same neighbourhood
# as npc_state_per_region so a reader who understands one understands both.
var item_state_per_map: Dictionary = {}   # map_id -> Array[record]

# Set of npc_uids the party has discovered, per region. Drives whether a
# service that's illegal under the controlling faction's laws shows up in
# the TownServicesPanel.
var known_services_per_region: Dictionary = {}

# Downtime mode: toggled by the crescent-moon button next to TimeLabel.
# When true, the town services panel swaps to a downtime activity board,
# the party panel hides, the camp panel appears on the right, and party
# portraits show in the centre to be dragged onto activities.
var downtime_mode_active: bool = false
signal downtime_mode_changed(active: bool)

# Per-character downtime cooldown bookkeeping. Keyed by a stable character
# uid (template_id, or display_name for protagonist) -> Array of dicts
# {"result_id": String, "day_abs": int}. DowntimeDatabase reads/writes this.
var downtime_recent_events: Dictionary = {}

# Who has already spent today, character_uid -> activity_id. Cleared by
# advance_downtime_day. Its only job is to tell the day-advance which party
# members still need an activity picked FOR them; it deliberately does not cap
# how many activities a character may do, because downtime is hours-based and
# a four-hour activity leaves room for another. Training is the exception and
# guards itself (a day of study is a day, not four hours).
var downtime_day_assignments: Dictionary = {}
signal downtime_day_advanced(day: int)

func set_downtime_mode(active: bool) -> void:
	if downtime_mode_active == active:
		return
	downtime_mode_active = active
	downtime_mode_changed.emit(active)

func record_downtime_assignment(character, activity_id: String) -> void:
	var uid: String = DowntimeDatabase.character_uid(character)
	if uid.is_empty():
		return
	downtime_day_assignments[uid] = activity_id

func has_downtime_assignment(character) -> bool:
	return downtime_day_assignments.has(DowntimeDatabase.character_uid(character))

func trained_today(character) -> bool:
	var uid: String = DowntimeDatabase.character_uid(character)
	return str(downtime_day_assignments.get(uid, "")) == TrainingManager.TRAINING_ACTIVITY_ID

## Roll the day over. Everyone the player left idle picks something for
## themselves, then the clock moves to the next morning.
##
## The auto-pick is what makes a multi-day stay in town bearable: a character
## booked on four days of sword drill would otherwise leave two companions
## standing still for four days while the player clicks through their evenings.
func advance_downtime_day() -> void:
	var region_id: String = RegionDatabase.get_region_for_map(current_map_id)
	for c in party_chars:
		if c == null or not is_instance_valid(c):
			continue
		if not c.is_alive():
			continue
		if has_downtime_assignment(c):
			continue
		_auto_pick_downtime(c, region_id)

	downtime_day_assignments.clear()
	TimeManager.advance_days(1)
	# Wake everyone at dawn rather than carrying the previous evening's clock
	# forward; advance_days moves the date, not the time of day.
	TimeManager.set_time(6, 0, 0)
	emit_signal("downtime_day_advanced", TimeManager.today())
	if GameLog:
		GameLog.add_entry("A new day: %s" % TimeManager.get_date_string())

## Choose and resolve one activity for an unassigned companion, silently.
## Weighted by how much they'd actually like it — rate_choice is the same
## preferred/disliked scoring DowntimeResolver uses to decide whether a
## companion would refuse a player-assigned activity, so a Reclusive character
## drifts to meditation and a Sociable one to the tavern.
func _auto_pick_downtime(character, region_id: String) -> void:
	var candidates: Array = DowntimeDatabase.get_activities_for_region(region_id)
	# Never volunteer someone for a crime, a self-harm ritual, or a teacher they
	# haven't been booked with.
	var weighted: Array = []
	var total: float = 0.0
	for activity_id in candidates:
		var a: Dictionary = DowntimeDatabase.get_activity(activity_id)
		if a.is_empty():
			continue
		if bool(a.get("requires_training", false)):
			continue
		if not String(a.get("legal_title", "")).is_empty():
			continue
		# Nor for one that can't happen for them (no patron to offer souls to).
		if not DowntimeResolver.unavailable_reason(character, a).is_empty():
			continue
		var score: int = 0
		if character.has_method("rate_choice"):
			score = int(character.rate_choice(a.get("preferred_traits", []), a.get("disliked_traits", [])))
		# A companion never picks something they'd have refused if ordered to.
		if score < 0:
			continue
		var weight: float = 1.0 + float(score) * 2.0
		weighted.append({"id": activity_id, "weight": weight})
		total += weight
	if weighted.is_empty():
		return

	var roll: float = randf() * total
	var picked: String = str(weighted[weighted.size() - 1]["id"])
	for entry in weighted:
		roll -= float(entry["weight"])
		if roll <= 0.0:
			picked = str(entry["id"])
			break
	DowntimeResolver.resolve_silently(character, picked, region_id)

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	fog_manager.create_fog_from_params(
		Color(0.2, 0.6, 0.2, 0.4),   # green poison fog
		Vector2(512, 512),             # size in pixels
		0.95,                           # density
		6.0,                           # noise scale
		Vector2(0.63, 0.215),          # drift speed
		Vector2(600, 800)             # world position
	)
	_create_selection_indicator(Globals.default_body_width+5)

	# Weather VFX controller
	var WeatherVFXScript = preload("res://vfx/WeatherVFXController.gd")
	weather_vfx_controller = Node.new()
	weather_vfx_controller.set_script(WeatherVFXScript)
	weather_vfx_controller.name = "WeatherVFXController"
	add_child(weather_vfx_controller)

	# Weather debug window (F9)
	var WeatherDebugScript = preload("res://UI/WeatherDebugWindow.gd")
	weather_debug_window = CanvasLayer.new()
	weather_debug_window.set_script(WeatherDebugScript)
	weather_debug_window.name = "WeatherDebugWindow"
	add_child(weather_debug_window)

	# Combat test window (F10)
	var CombatTestScript = preload("res://UI/CombatTestWindow.gd")
	combat_test_window = CanvasLayer.new()
	combat_test_window.set_script(CombatTestScript)
	combat_test_window.name = "CombatTestWindow"
	add_child(combat_test_window)

	# React to weather changes (snow → freeze, rain → puddles)
	WeatherManager.weather_changed.connect(_on_weather_changed)

	# Quest turn-in opens the reward screen.
	if not QuestManager.quest_reward_offered.is_connected(show_quest_rewards):
		QuestManager.quest_reward_offered.connect(show_quest_rewards)

	# A companion catching up with you arrives on a date, and the player can burn
	# those days standing still in downtime — so returns can't wait for the next
	# map load.
	if not TimeManager.date_changed.is_connected(_on_date_changed_for_returns):
		TimeManager.date_changed.connect(_on_date_changed_for_returns)

	# Law/crime Phase 7: the Surrender button (visible whenever a hostile is
	# near — a missing button is confusion, a visible one is information).
	_setup_surrender_button()
	_setup_threat_indicators()

	# On-screen game log (GameLog.add_entry is the standard channel for
	# refusals and announcements; this is what makes it visible).
	var log_panel := PanelContainer.new()
	log_panel.set_script(preload("res://game_log_panel.gd"))
	$GameUI.add_child(log_panel)

	# World hover tooltip and HUD status strip. Both ship empty; features
	# register providers / widgets on them.
	world_tooltip = preload("res://UI/WorldHoverTooltip.gd").new()
	$GameUI.add_child(world_tooltip)
	hud_status = preload("res://UI/HudStatusBar.gd").new()
	$GameUI.add_child(hud_status)
	# While paused: a faint line from each visible NPC to whoever it is after.
	# World-space child of Game (not GameUI), so it survives map changes.
	add_child(preload("res://UI/TargetIntentOverlay.gd").new())
	# Character, structure and hazard readouts on the hover tooltip; wind in
	# the clock cluster, beside the date and the downtime (moon) button.
	add_child(preload("res://UI/WorldHoverInfo.gd").new())
	$GameUI.add_child(preload("res://UI/WindIndicator.gd").new())

	# Stealth mode readouts: the STEALTH badge on the status strip, and the
	# world-space overlay (in-view eyes, noise rings).
	hud_status.add_widget(preload("res://UI/StealthBadge.gd").new())
	stealth_overlay = preload("res://vfx/StealthOverlay.gd").new()
	add_child(stealth_overlay)

	# Character creation gates the first map load: Scarlatti issues the carta
	# d'identità before it lets anyone in. _ready becomes a coroutine here, so
	# nothing may be added below the load_map call.
	if _should_run_character_creation():
		await _run_character_creation()

	load_map(current_map_id)
 
# ---------------------------------------------------------------------------
# Character creation — the Scarlatti carta d'identità
# ---------------------------------------------------------------------------

## Whether the new-game gate should run. Off for headless test scenes, off when
## a run was launched with --skip-creation, and off once a card has been issued
## (a scene reload with R must not re-open the office).
func _should_run_character_creation() -> bool:
	if Globals.skip_character_creation:
		return false
	if DisplayServer.get_name() == "headless":
		return false
	if "--skip-creation" in OS.get_cmdline_args() \
			or "--skip-creation" in OS.get_cmdline_user_args():
		return false
	return true

func _run_character_creation() -> void:
	var screen = load("res://UI/CharacterCreationScreen.gd").new()
	screen.name = "CharacterCreationScreen"
	screen.mode = CartaIdentita.Mode.CREATE
	add_child(screen)
	var draft: Dictionary = await screen.completed
	screen.queue_free()
	apply_character_draft(draft)
	Globals.skip_character_creation = true

## Fold a convalidated card into the protagonist's party_state entry. Everything
## the document says is expressed as build_character overrides, so it survives
## map transitions and rides into the save file for free (build_save_dict
## snapshots party_state wholesale).
func apply_character_draft(draft: Dictionary) -> void:
	if draft.is_empty() or party_state.is_empty():
		return
	var overrides: Dictionary = party_state[0].get("overrides", {}).duplicate(true)
	var gender: String = String(draft.get("gender", "male"))

	overrides["unique_name"] = String(draft.get("name", ""))
	overrides["gender"] = gender
	overrides["race"] = CharacterCreationDatabase.PLAYER_RACE
	overrides["background"] = String(draft.get("background_id", ""))
	overrides["stats"] = draft.get("stats", {}).duplicate()
	overrides["icon"] = CharacterCreationDatabase.portrait_path(
			String(draft.get("portrait_id", "")))

	# body_metrics travels inside "options" because that is the dict
	# RaceDatabase.apply_race_to_character reads — without it the protagonist
	# would be re-measured on every map load.
	var options: Dictionary = overrides.get("options", {}).duplicate()
	options["gender"] = gender
	options["body_metrics"] = draft.get("body_metrics", {}).duplicate()
	overrides["options"] = options

	# The document itself, kept verbatim so the character sheet reprints the
	# card that was issued rather than reconstructing an approximation.
	overrides["carta"] = draft.duplicate(true)

	party_state[0]["overrides"] = overrides
	# A card issued mid-session invalidates any snapshot taken before it.
	party_state[0]["live_state"] = null

## Open (or close) the carta d'identità as a read-only character sheet. Shows
## the primary-selected party member, falling back to the protagonist.
func show_character_sheet(character = null) -> void:
	var existing = get_node_or_null("CharacterSheetScreen")
	if existing:
		existing.queue_free()
		return

	var subject = character
	if subject == null:
		subject = primary_selected
	if subject == null or not is_instance_valid(subject):
		subject = player
	if subject == null or not is_instance_valid(subject):
		return

	var screen = load("res://UI/CharacterCreationScreen.gd").new()
	screen.name = "CharacterSheetScreen"
	screen.mode = CartaIdentita.Mode.VIEW
	screen.subject = subject
	screen.dismissed.connect(func() -> void:
		if is_instance_valid(screen):
			screen.queue_free())
	add_child(screen)

## Quest rewards. QuestManager.turn_in completes the quest and consumes the
## proof, then emits quest_reward_offered; granting lives here because the
## autoload has no business owning a screen.
func show_quest_rewards(quest_id: String, offers: Array, character) -> void:
	if get_node_or_null("QuestRewardScreen") != null:
		return
	if character == null or not is_instance_valid(character):
		character = player
	if character == null or not is_instance_valid(character):
		return

	var screen = load("res://UI/QuestRewardScreen.gd").new()
	screen.name = "QuestRewardScreen"
	screen.setup(quest_id, offers, character)
	if not screen.try_open():
		screen.queue_free()
		return
	screen.chosen.connect(func(offer: Dictionary) -> void:
		_apply_quest_reward(offer, character)
		if is_instance_valid(screen):
			screen.queue_free())
	screen.dismissed.connect(func() -> void:
		if is_instance_valid(screen):
			screen.queue_free())
	add_child(screen)

## Hand over one chosen reward. Items and coin go through DowntimeEffectApplier,
## which already knows how to pay out in currency items and how to put a thing in
## a bag. A training offer grants NOTHING now — it books days with a teacher that
## the learner has to actually spend.
func _apply_quest_reward(offer: Dictionary, character) -> void:
	match str(offer.get("type", "")):
		"money":
			DowntimeEffectApplier.apply(character, {"money": int(offer.get("amount", 0))}, 1)
		"item":
			var item_id: String = str(offer.get("item_id", ""))
			var data: Dictionary = ItemDatabase.get_item_data(item_id)
			if data.is_empty():
				push_warning("Quest reward: unknown item '%s'" % item_id)
				return
			var inv = character.get_node_or_null("Inventory")
			if inv != null and inv.has_method("add_stack"):
				# A hand item is stowed as a weapon, as a pick-up is: a bare hand
				# dict is hidden in every grid and can't be drawn. A full pack is
				# announced by the inventory itself (add_failed), so no
				# "Received" line then.
				var equip_slot: String = str(data.get("equip_slot", ""))
				var ok: bool = false
				if (equip_slot == "Main Hand" or equip_slot == "Off Hand") and inv.has_method("stow_weapon_from_data"):
					inv.stow_weapon_from_data(data)
					ok = true
				else:
					ok = inv.add_stack(data)
				if ok and GameLog:
					GameLog.add_entry("Received %s." % str(data.get("display_name", item_id)))
		"training":
			TrainingManager.accept_offer(character, offer, current_map_id)

func save_party_state() -> void:
	## Snapshots every living party member's runtime state so it survives
	## map transitions and can be written to a save file.
	##
	## Pairs by the party_index stamped at spawn rather than by array position:
	## an away member has no entry in party_chars, so positional zipping would
	## shift every later member's snapshot onto the wrong row and, e.g., write
	## Djargo's inventory over Jacana's. Members without the meta (spawned by
	## older code paths) fall back to their position.
	for idx in range(party_chars.size()):
		var character = party_chars[idx]
		if not is_instance_valid(character):
			continue
		var row: int = int(character.get_meta("party_index", idx))
		if row < 0 or row >= party_state.size():
			continue
		party_state[row]["live_state"] = _serialize_character(character)
 
 
func load_party_state_from_save(saved: Array) -> void:
	## Called when loading a save file. Replaces party_state entirely.
	party_state = saved

# ---------------------------------------------------------------------------
# Away party members (training that outlasts your stay)
#
# A companion who still owes their teacher days when you leave town has to
# decide between you and the work. Absence is a data flag on their party_state
# row, so it saves and loads with everything else and needs no new registry:
#   entry["away"] = {reason, return_day, return_map, ability_id}
#
# reason "training"   — they stayed to finish, then come and find you.
# reason "other_work" — they took a different job. They are where you left them
#                       and will not chase you; go back for them.
# ---------------------------------------------------------------------------

## At or above this favour a companion finishes the course and then follows you.
## Below it they take other work. Deliberately just above neutral: an ally you
## have never done anything for is not obliged to cross a country for you.
const FOLLOW_FAVOR_THRESHOLD: int = 10
## Days a companion spends on the road catching up after finishing their studies.
const REJOIN_TRAVEL_DAYS: int = 2

func _on_date_changed_for_returns(_day: int, _month: int, _year: int) -> void:
	if current_map_id.is_empty():
		return
	_resolve_returns(current_map_id)

func is_party_member_away(entry) -> bool:
	if not (entry is Dictionary):
		return false
	var away = entry.get("away", null)
	return away is Dictionary and not (away as Dictionary).is_empty()

func get_away_members() -> Array:
	var out: Array = []
	for entry in party_state:
		if is_party_member_away(entry):
			out.append(entry)
	return out

## Called just before a map change, while the party is still assembled. Any
## member with an unfinished commitment anchored to the map we are leaving picks
## one of the two branches above.
func _resolve_departures(leaving_map: String, target_map: String) -> void:
	if leaving_map.is_empty() or leaving_map == target_map:
		return
	for idx in range(party_chars.size()):
		var character = party_chars[idx]
		if not is_instance_valid(character):
			continue
		var row: int = int(character.get_meta("party_index", idx))
		if row <= 0 or row >= party_state.size():
			continue  # the protagonist never stays behind
		var commitment: Dictionary = TrainingManager.commitment_for(character)
		if commitment.is_empty():
			continue
		if str(commitment.get("map_id", "")) != leaving_map:
			continue

		var uid: String = DowntimeDatabase.character_uid(character)
		var who: String = String(character.display_name)
		var days_left: int = TrainingManager.days_remaining(character)
		var loyal: bool = int(character.favorability) >= FOLLOW_FAVOR_THRESHOLD

		if loyal:
			# Finishes the course on their own time, then travels to you.
			var ability_id: String = TrainingManager.complete_absent(uid)
			party_state[row]["away"] = {
				"reason": "training",
				"return_day": TimeManager.today() + days_left + REJOIN_TRAVEL_DAYS,
				"return_map": "",
				"ability_id": ability_id,
			}
			if GameLog:
				GameLog.add_entry("%s stays to finish their training, and will follow." % who)
		else:
			# Not owed enough to be left waiting. The booking stands — come back
			# and they will still be studying — but they will not chase you.
			party_state[row]["away"] = {
				"reason": "other_work",
				"return_day": -1,
				"return_map": leaving_map,
				"ability_id": str(commitment.get("ability_id", "")),
			}
			if GameLog:
				GameLog.add_entry("%s takes other work rather than follow you." % who)

## Called after a map loads. Brings back anyone whose absence has run out.
## A "training" absence expires on a date; an "other_work" absence expires when
## you return to the town you abandoned them in.
func _resolve_returns(arrived_map: String) -> void:
	var today: int = TimeManager.today()
	var changed := false
	for entry in party_state:
		if not is_party_member_away(entry):
			continue
		var away: Dictionary = entry["away"]
		var due: bool = false
		match str(away.get("reason", "")):
			"training":
				due = int(away.get("return_day", -1)) >= 0 and today >= int(away.get("return_day", 0))
			"other_work":
				due = str(away.get("return_map", "")) == arrived_map
		if not due:
			continue
		entry.erase("away")
		changed = true
		if GameLog:
			GameLog.add_entry("%s rejoins the party." % str(entry.get("template_id", "Someone")))
	if changed:
		# Respawn so the returned member actually has a body on this map.
		_spawn_returned_members(arrived_map)

## Spawn party rows that are present but have no body, without disturbing the
## ones already standing. Reuses the normal spawn path by re-running it for the
## missing rows only.
func _spawn_returned_members(_arrived_map: String) -> void:
	var occupied: Dictionary = {}
	for idx in range(party_chars.size()):
		var c = party_chars[idx]
		if is_instance_valid(c):
			occupied[int(c.get_meta("party_index", idx))] = true
	var anchor: Vector2 = player.global_position if is_instance_valid(player) else Vector2.ZERO
	for row in range(party_state.size()):
		if occupied.has(row) or is_party_member_away(party_state[row]):
			continue
		var entry = party_state[row]
		var character = _spawn_character(entry["template_id"], anchor + Vector2(40 * (row + 1), 0),
			entry.get("overrides", {}))
		if not character:
			continue
		party_chars.append(character)
		character.set_meta("party_index", row)
		character.npc_unlimited_resources = false
		character.AI_enabled = true
		character.is_player_controlled = false
		if entry.get("live_state"):
			_deserialize_character(character, entry["live_state"])
		character.faction_id = "player"
		_wire_ally_witness(character)
		_add_line_of_sight_light(character)
		# Anything they finished studying while away lands now.
		TrainingManager.flush_pending_grants(character)


# ---------------------------------------------------------------------------
# Service NPC state persistence (per-region, survives map transitions)
# ---------------------------------------------------------------------------

func _build_npc_uid(template_id: String, unique_name: String) -> String:
	## Mirror of RegionDatabase._build_npc_uid — duplicated to avoid coupling.
	if unique_name.is_empty():
		return template_id
	return template_id + "/" + unique_name

func _is_service_npc(character) -> bool:
	return is_instance_valid(character) and "titles" in character and character.titles.size() > 0

## Phase 7: death must persist or the witness pipeline is theatre — a
## murdered guard used to be queue_free'd with state unrecorded and respawn
## pristine on revisit. Service NPCs persist as before; anyone DEAD persists
## too (corpses stay corpses, and their corpse_crime meta stays with them).
func _should_persist_npc(c) -> bool:
	if _is_service_npc(c):
		return true
	return is_instance_valid(c) and "current_health" in c and c.current_health <= 0

## Region bucket, with a per-map fallback so wilderness maps (no region)
## persist NPC state too instead of silently dropping it.
func _npc_bucket_key() -> String:
	var region_id: String = RegionDatabase.get_region_for_map(current_map_id)
	if region_id.is_empty():
		return "map:" + current_map_id
	return region_id

func _save_service_npc_states() -> void:
	## Walk the live scene; snapshot every NPC that should persist into
	## npc_state_per_region[bucket][uid].
	var bucket_key: String = _npc_bucket_key()
	if not npc_state_per_region.has(bucket_key):
		npc_state_per_region[bucket_key] = {}
	for c in characters_in_scene:
		if c in party_chars:
			continue
		if not _should_persist_npc(c):
			continue
		var template_id: String = str(c.get_meta("template_id", ""))
		if template_id.is_empty():
			# Fallback: derive from display_name (won't survive renames but is rare)
			template_id = str(c.display_name).to_lower().replace(" ", "_")
		var unique_name: String = str(c.get_meta("unique_name", ""))
		var uid: String
		if _is_service_npc(c):
			# Service NPCs keep the legacy uid form — known_services_per_region
			# and RegionDatabase._build_npc_uid must keep matching, or the
			# town services panel loses every discovered service.
			uid = _build_npc_uid(template_id, unique_name)
		else:
			# Non-service persistence (dead guards, dead bystanders): ordinal
			# uid so two town_guard spawns don't collide on one key. The
			# ordinal is per-template spawn order — deterministic unless
			# same-template conditional spawns flip between visits.
			uid = "%s#%d" % [template_id, int(c.get_meta("spawn_ordinal", 0))]
		npc_state_per_region[bucket_key][uid] = _serialize_character(c)

func _peek_npc_snapshot(template_id: String, unique_name: String) -> Dictionary:
	## Pre-spawn lookup of the persisted snapshot the upcoming spawn would be
	## restored from. Mirrors _maybe_restore_npc_state's two uid forms; the
	## ordinal probe reads the counter value the spawn is about to be stamped
	## with (_spawn_ordinals only advances on successful spawns).
	var bucket: Dictionary = npc_state_per_region.get(_npc_bucket_key(), {})
	if bucket.is_empty():
		return {}
	var service_uid: String = _build_npc_uid(template_id, unique_name)
	if bucket.has(service_uid):
		return bucket[service_uid]
	var ordinal_uid: String = "%s#%d" % [template_id, int(_spawn_ordinals.get(template_id, 0))]
	return bucket.get(ordinal_uid, {})

func _maybe_restore_npc_state(npc, template_id: String, unique_name: String) -> void:
	## On NPC spawn, if we have a cached snapshot from a previous visit, replay it.
	## Also tags the live node with template_id + unique_name for save-on-unload.
	## (spawn_ordinal meta is stamped by _spawn_npcs BEFORE this runs.)
	if not is_instance_valid(npc):
		return
	npc.set_meta("template_id", template_id)
	npc.set_meta("unique_name", unique_name)
	var bucket: Dictionary = npc_state_per_region.get(_npc_bucket_key(), {})
	if bucket.is_empty():
		return
	if _is_service_npc(npc):
		var uid: String = _build_npc_uid(template_id, unique_name)
		if bucket.has(uid):
			_deserialize_character(npc, bucket[uid])
		return
	var ordinal_uid: String = "%s#%d" % [template_id, int(npc.get_meta("spawn_ordinal", 0))]
	if bucket.has(ordinal_uid):
		_deserialize_character(npc, bucket[ordinal_uid])

func mark_service_seen(npc) -> void:
	## Records discovery. The panel lists a service only when it is legal AND
	## seen, and the record keeps it listed after the party leaves the map.
	if not _is_service_npc(npc):
		return
	var region_id: String = RegionDatabase.get_region_for_map(current_map_id)
	if region_id.is_empty():
		return
	var template_id: String = str(npc.get_meta("template_id", ""))
	var unique_name: String = str(npc.get_meta("unique_name", ""))
	var uid: String = _build_npc_uid(template_id, unique_name)
	if not known_services_per_region.has(region_id):
		known_services_per_region[region_id] = []
	if uid not in known_services_per_region[region_id]:
		known_services_per_region[region_id].append(uid)
		# List them in the open panel now, so a merchant met on this visit
		# appears without leaving and coming back.
		var services_panel = get_node_or_null("GameUI/TownServicesPanel")
		if services_panel != null and services_panel.has_method("list_newly_seen_service"):
			services_panel.call_deferred("list_newly_seen_service", uid)
 
 
func add_party_member(template_id: String, overrides: Dictionary = {}) -> void:
	party_state.append({
		"template_id": template_id,
		"overrides": overrides,
		"live_state": null,
	})
 
 
func remove_party_member(index: int) -> void:
	if index > 0 and index < party_state.size():  # Can't remove the protagonist
		party_state.remove_at(index)

# ---------------------------------------------------------------------------
# NPC spawning
# ---------------------------------------------------------------------------
 
# Per-template spawn counters for the current map load; reset in load_map.
var _spawn_ordinals: Dictionary = {}

func _spawn_npcs(npc_list: Array) -> void:
	_spawn_ordinals.clear()
	for npc_def in npc_list:
		# Check spawn conditions
		if npc_def.has("condition") and not check_spawn_conditions(npc_def["condition"]):
			continue

		var template_id: String = npc_def.get("template_id", "")
		var pos_arr = npc_def.get("position", [0, 0])
		var base_pos = Vector2(pos_arr[0], pos_arr[1])
		var count: int = npc_def.get("count", 1)
		var spread: float = npc_def.get("spread_radius", 0)
		# Per-spawn overrides for unique NPCs, faction, titles, and dialogue.
		var spawn_overrides: Dictionary = {}
		if npc_def.has("unique_name"):
			spawn_overrides["unique_name"] = npc_def["unique_name"]
		if npc_def.has("titles"):
			spawn_overrides["titles"] = npc_def["titles"]
		if npc_def.has("faction"):
			spawn_overrides["faction"] = npc_def["faction"]
		if npc_def.has("dialogue"):
			spawn_overrides["dialogue"] = npc_def["dialogue"]

		for i in range(count):
			var pos = base_pos
			if spread > 0 and i > 0:
				pos += Vector2(randf_range(-spread, spread), randf_range(-spread, spread))

			# "from_faction" races re-roll every spawn, but a persisted NPC's
			# snapshot restore stamps the OLD race's identity/dims/colors over
			# whatever rig the fresh roll built. Peek the snapshot BEFORE spawn
			# and force its race/gender so build_character rebuilds the same
			# body the snapshot was taken from.
			var per_spawn_overrides: Dictionary = spawn_overrides
			var snap: Dictionary = _peek_npc_snapshot(template_id, str(spawn_overrides.get("unique_name", "")))
			if not str(snap.get("race_id", "")).is_empty():
				per_spawn_overrides = spawn_overrides.duplicate()
				per_spawn_overrides["race"] = str(snap["race_id"])
				if not str(snap.get("gender", "")).is_empty():
					per_spawn_overrides["gender"] = str(snap["gender"])

			var npc = _spawn_character(template_id, pos, per_spawn_overrides)
			if npc:
				npc.AI_enabled = true
				# Per-spawn dialogue override (TopDownCharacterDatabase only reads
				# template.dialogue; we wire the spawn-level override here).
				if spawn_overrides.has("dialogue") and "dialogues" in npc:
					npc.dialogues = [str(spawn_overrides["dialogue"])]
				# Per-template spawn ordinal: the uid disambiguator for
				# non-service persistence (two town_guard spawns must not
				# collide on one save key). Stamped BEFORE restore.
				var ordinal: int = int(_spawn_ordinals.get(template_id, 0))
				_spawn_ordinals[template_id] = ordinal + 1
				npc.set_meta("spawn_ordinal", ordinal)
				# Restore persisted live_state for service NPCs whose region we've
				# visited before (lets trades stick across map transitions).
				_maybe_restore_npc_state(npc, template_id, spawn_overrides.get("unique_name", ""))
				# NPCs hidden by default; made visible when inside party LOS
				npc.visible = false
				# Give NPCs their own LOS cone (hidden until stealth mode)
				_add_npc_line_of_sight_light(npc)

# ---------------------------------------------------------------------------
# Combat test mode
# ---------------------------------------------------------------------------

func start_combat_test(player_configs: Array, rival_configs: Array, override_rival_faction: bool) -> void:
	# Replace the active party so _spawn_player_and_party uses the test loadout.
	party_state.clear()
	for cfg in player_configs:
		party_state.append({
			"template_id": cfg.get("template_id", ""),
			"overrides": {
				"extra_abilities": cfg.get("abilities", []),
				"extra_equipment": cfg.get("items", []),
			},
			"live_state": null,
		})

	# Stash rival configs for _spawn_rival_party (called from load_map).
	_pending_rival_spawns = rival_configs.duplicate(true)
	_pending_rival_override_faction = override_rival_faction

	# load_map would snapshot the outgoing party into the new rows (paired by
	# party_index) and rebuild each test character from it (inventory, worn
	# gear, equip conditions, HP) instead of the configured loadout, and its
	# departure pass could stamp "away" on them.
	_skip_party_save = true
	load_map("colosseum")
	_skip_party_save = false

func _spawn_rival_party() -> void:
	# Anchor on the actual player spawn so we line up with whatever Maps.json says.
	var player_anchor: Vector2 = Vector2(768, 768)
	var spawns: Dictionary = current_map_data.get("player_spawns", {})
	if spawns.has("default"):
		var pos_arr = spawns["default"].get("position", [768, 768])
		player_anchor = Vector2(pos_arr[0], pos_arr[1])

	# Place rivals 232px south of the player anchor (opposite end of the arena).
	var arc_center: Vector2 = player_anchor + Vector2(0, 232)
	var n: int = _pending_rival_spawns.size()

	for i in range(n):
		var cfg = _pending_rival_spawns[i]
		var t: float = (float(i) - (n - 1) / 2.0) * 60.0
		var pos: Vector2 = arc_center + Vector2(t, 0)

		var overrides: Dictionary = {
			"extra_abilities": cfg.get("abilities", []),
			"extra_equipment": cfg.get("items", []),
		}
		if _pending_rival_override_faction:
			overrides["faction"] = "rival_party"

		var rival = _spawn_character(cfg.get("template_id", ""), pos, overrides)
		if rival:
			rival.AI_enabled = true
			_add_npc_line_of_sight_light(rival)

	_pending_rival_spawns.clear()
	_pending_rival_override_faction = false

# ---------------------------------------------------------------------------
# Core character spawn helper
# ---------------------------------------------------------------------------
 
func _spawn_character(template_id: String, pos: Vector2, overrides: Dictionary = {}) -> ProceduralCharacter:
	# Check template-level spawn conditions before creating the character
	var template = TopDownCharacterDatabase.get_template(template_id)
	var spawn_conditions = template.get("spawn_conditions", {})
	if not spawn_conditions.is_empty() and not check_spawn_conditions(spawn_conditions):
		return null

	var character = CharacterScene.instantiate()

	# Position first (before body creation reads it)
	character.position = pos

	# Add to scene tree BEFORE build_character so that _ready() fires
	# and the Inventory node exists when equipment is granted
	add_child(character)

	# Build from template — this applies race, background, stats, equipment
	TopDownCharacterDatabase.build_character(character, template_id, overrides)

	# Connect signals
	character.character_died.connect(_on_character_died.bind(character))
	# Witnessing system: when this character is damaged, ping nearby NPCs so
	# AT_EASE civilians flip to UNAWARE and head over to investigate.
	character.damaged_by.connect(_on_character_damaged.bind(character))

	# Track in scene
	characters_in_scene.append(character)

	# Seed elevation before sight-cone lights are added: a warp arrival onto a
	# deck must read deck elevation on frame 0 or its cone stays ground-tier.
	character._refresh_elevation()

	# Visible-ally adrenaline: wire bi-directional witness connections so any
	# character who shares this character's faction grants them +1 adrenaline
	# when wounded/severed/killed within vision range. Cheap on spawn; resource
	# logic is gated inside the character on max_adrenaline > 0.
	_wire_ally_witness(character)

	# Vow of Poverty: VowManager listens for gold pickups via Inventory.
	if VowManager and VowManager.has_method("register_inventory"):
		VowManager.register_inventory(character)

	# Quest hooks: subscribes to death + inventory.item_added and seeds
	# char_at::<template_id> for this character.
	if QuestManager:
		QuestManager.register_character(character)

	return character


func _wire_ally_witness(new_char) -> void:
	if new_char == null or not is_instance_valid(new_char):
		return
	for existing in characters_in_scene:
		if existing == new_char or not is_instance_valid(existing):
			continue
		new_char.connect_ally_witness(existing)
		existing.connect_ally_witness(new_char)
 



	
func load_map(map_id: String, from_map: String = "", spawn_override: String = "") -> void:
	# Validate target before tearing down the current map so a missing asset
	# (e.g. world-map PNG not yet pushed) leaves us on the current map
	# instead of in a broken empty state.
	var new_map_data: Dictionary = MapDatabase.get_map_data(map_id)
	if new_map_data.is_empty():
		push_error("Unknown map: " + map_id)
		# A blank id is a harness/boot path, never a clicked warp.
		if not map_id.is_empty():
			_announce_way_closed("That way leads nowhere yet.")
		return
	var new_images: Dictionary = new_map_data.get("images", {})
	var validate_path: String = new_images.get("structures", "")
	if validate_path.is_empty() or not ResourceLoader.exists(validate_path):
		validate_path = new_images.get("map", "")
	if validate_path.is_empty() or not ResourceLoader.exists(validate_path):
		push_error("Map '%s' has no loadable image (looked for %s); aborting load." % [map_id, new_images])
		_announce_way_closed("The way to %s is not open yet." % str(new_map_data.get("name", map_id)))
		return

	# Same-map stairs and ladders just move the party. A full reload would
	# respawn living enemies at full health and reset alertness, close opened
	# doors, and clear fires, fluids and surfaces.
	if map_id == current_map_id and not spawn_override.is_empty() \
			and current_map_data.get("player_spawns", {}).has(spawn_override):
		_relocate_party(spawn_override)
		return

	# A warp frees the trading NPC and saves the party's packs as they stand,
	# so an open trade is cancelled first: its staged moves go back.
	for w in get_tree().get_nodes_in_group("trade_window"):
		if not w.is_queued_for_deletion() and w.has_method("_on_cancel_pressed"):
			w._on_cancel_pressed()

	# Save party state before cleaning up (preserves HP, inventory, etc.)
	if not party_chars.is_empty() and not _skip_party_save:
		save_party_state()
		# Runs while the party is still assembled and current_map_id still names
		# the map being left: anyone mid-training here decides whether to follow.
		_resolve_departures(current_map_id, map_id)

	# Reset the "ever seen" radar memory — fresh map means fresh dread.
	# Pulse/sighting dicts also get cleared so stale references don't linger.
	_npc_ever_seen.clear()
	_npc_was_truly_seen.clear()
	_npc_pulse_remaining.clear()
	_npc_radar_cooldown.clear()

	# Clean up previous map
	_unload_current_map()

	current_map_data = new_map_data
	current_map_id = map_id

	# 1. Configure GridManager tile size and initialize the grid.
	# World maps have no structures layer — fall back to the main map image.
	# When world_render_scale > 1 the grid (tile size + total dimensions)
	# expands to match the visually-scaled-up world.
	var raw_tile_size: int = current_map_data.get("tile_size", 64)
	var is_world_map: bool = current_map_data.get("is_world_map", false)
	var world_render_scale: float = float(current_map_data.get("world_render_scale", 1.0)) if is_world_map else 1.0
	GridManager.TILE_SIZE = int(round(float(raw_tile_size) * world_render_scale))
	# Combat conversions (tiles -> px against unscaled character art) must not
	# inherit the world map's render inflation — see GridManager.COMBAT_TILE_SIZE.
	GridManager.COMBAT_TILE_SIZE = raw_tile_size
	var images: Dictionary = current_map_data.get("images", {})
	var structured: bool = String(current_map_data.get("format", "")) == "structured"
	if structured:
		# structured maps declare their pixel size (no mask image to measure;
		# world_render_scale only applies to world maps, never structured)
		var ws: Array = current_map_data.get("world_size", [2048, 2048])
		GridManager.initialize(int(ws[0]), int(ws[1]))
	else:
		var dim_src_path: String = images.get("structures", "")
		if dim_src_path.is_empty() or not ResourceLoader.exists(dim_src_path):
			dim_src_path = images.get("map", "")
		var dim_img: Image = load(dim_src_path).get_image()
		GridManager.initialize(
			int(round(dim_img.get_width() * world_render_scale)),
			int(round(dim_img.get_height() * world_render_scale))
		)

	# 2. Tell the MapLoader to build the visual map (floors, structures).
	#    Structured maps (procedural level-editor exports) carry instance
	#    geometry + a finished ground render instead of the 4-PNG mask set.
	#    World maps skip the structures pass and use the world-terrain palette.
	is_world_map = current_map_data.get("is_world_map", false) and not structured

	# 2a. Build the CELL GRAPH first: the fire/fluid sims run on it, and the
	# structured loader reads terrain elevation (GridManager) while spawning
	# structures, so it must exist BEFORE generate_structured_map. Structured
	# maps ship the Stalberg graph, other local maps use a square-tile adapter,
	# world maps get none (fire there is meaningless).
	var graph: CellGraph = null
	if not is_world_map:
		if structured:
			var cg_path: String = current_map_data.get("cell_graph", "")
			if cg_path != "":
				graph = CellGraph.from_structured(cg_path)
		else:
			graph = CellGraph.from_square_tiles()
	GridManager.set_elevation_data(graph if structured else null)

	# the previous map's RoofLayer died with the map_loader child sweep
	roof_layer = null
	if structured:
		map_loader.world_map_mode = false
		map_loader.generate_structured_map(current_map_data)
		# DF-style roof cover: the PAINTED export when the map ships one
		# (MapLoader spawned it from images.roofs), else procedural palette
		# quads from the roof grid. Parented under map_loader either way, so
		# the unload sweep frees it with the rest of the map. Only structured
		# maps carry roof data; legacy battlemaps correctly get nothing.
		roof_layer = map_loader.get_node_or_null("RoofLayer")
		if roof_layer == null and not GridManager.roof_elevations.is_empty():
			roof_layer = RoofLayer.new()
			roof_layer.name = "RoofLayer"
			map_loader.add_child(roof_layer)
		if roof_layer != null:
			roof_layer.visible = roof_view
	else:
		map_loader.world_map_mode = is_world_map
		map_loader.world_render_scale = world_render_scale
		map_loader.map_image_path = images.get("map", "")
		map_loader.mask_image_path = images.get("mask", "")
		map_loader.structure_map_image_path = images.get("structures", "")
		map_loader.structure_mask_path = images.get("structures_mask", "")
		map_loader.generate_map()

	# 2a'. Door Kickers-style unexplored fog: restore (or start) this map's
	# explored mask and hang the filter quad over the whole map. The quad is
	# parented under map_loader so the unload sweep frees it with the map; the
	# MASK persists across warps inside ExplorationManager (MapTriggerState
	# pattern). World maps keep their own warp-reveal loop instead, and a map
	# can opt out in Maps.json with "no_exploration_fog": true.
	var fog_of_war: bool = not current_map_data.get("is_world_map", false) \
		and not current_map_data.get("no_exploration_fog", false)
	ExplorationManager.begin_map(map_id, fog_of_war)
	if fog_of_war:
		var unexplored_fog: ColorRect = UNEXPLORED_FOG_SCRIPT.new()
		unexplored_fog.name = "UnexploredFogLayer"
		map_loader.add_child(unexplored_fog)
	# Hold the first reveal sweep until physics has synced the freshly spawned
	# wall colliders: a sweep before that sees through every wall and would
	# permanently burn the leak into the explored mask.
	_fog_sweep_accum = -0.25

	# 2b. Hand the shared graph to the sims.
	if surface_manager:
		surface_manager.setup_cell_graph(graph)
		# fluids run on the SHARED graph, but only on structured maps -- legacy/
		# world maps keep FluidManager's flat tile sim (cell_fluid stays null)
		if fluid_manager:
			fluid_manager.setup_cell_graph(graph if structured else null)

	# Apply time-scale multiplier. World maps run game time much faster so
	# hunger, hours-of-day, and weather advance on the strategic scale; local
	# maps default to 1.0 which restores realtime pacing on return.
	TimeManager.time_scale = float(current_map_data.get("time_scale_multiplier", 1.0))
 
	# 3. Set up ambient effects (fog, music, weather)
	setup_map_fogs(current_map_data)
	setup_map_music(current_map_data)
	setup_map_weather(current_map_data)

	# 4. Determine which spawn key to use: an explicit override (a warp's
	# target_spawn -- same-map stairs land at their linked arrival marker)
	# wins over the from_<map> arrival convention.
	var spawn_key: String = "default"
	if not spawn_override.is_empty() \
			and current_map_data.get("player_spawns", {}).has(spawn_override):
		spawn_key = spawn_override
	elif not from_map.is_empty():
		var from_key = "from_" + from_map
		if current_map_data.get("player_spawns", {}).has(from_key):
			spawn_key = from_key
 
	# 5. Spawn the player and party
	_spawn_player_and_party(spawn_key)

	# Seed the unexplored fog around each spawned party member (instant, no
	# raycasts): the first budgeted sweep is deliberately delayed until the
	# map's colliders reach the physics space, and without seeding the party
	# would render as blue-grey silhouettes inside its own fog until then.
	for pc in party_chars:
		if is_instance_valid(pc):
			ExplorationManager.seed_explored(GridManager.world_to_map(pc.global_position), 2)

	# 6. Spawn NPCs
	_spawn_npcs(current_map_data.get("npc_spawns", []))

	# 6b. Spawn combat-test rivals if any are pending
	if not _pending_rival_spawns.is_empty():
		_spawn_rival_party()

	# 7. Spawn items
	_spawn_items(current_map_data.get("item_spawns", []))
	# 7a. Revisited map: replace the authored spawns with the visited state
	# (taken items stay gone, emptied chests stay emptied, drops persist).
	_restore_item_state()

	# 7b. Spawn fluids (oil, water, etc.)
	_spawn_fluids(current_map_data.get("fluid_spawns", []))

	# 8. Create warp zones
	_create_warp_zones(current_map_data.get("warp_points", []))

	# 8b. Install dialogue zone controller and process on-load dialogue triggers.
	# Order matters: zones go in first so an on-load dialogue that ends quickly
	# can immediately notice the player standing inside a zone on the next frame.
	_install_dialogue_zones(current_map_data)
	_process_on_load_dialogue_triggers(current_map_data)

	# 8c. Hand the time-based dialogue triggers for this map to the scheduler.
	var scheduler = get_node_or_null("/root/EventScheduler")
	if scheduler:
		scheduler.on_map_entered(map_id, current_map_data.get("dialogue_time_triggers", []))

	# 9. Select the player
	call_deferred("_select_initial_character")

	# Flag every spawned character with whether it's on the world map. The
	# move_speed getter folds in overland_speed_modifier when this is true.
	for c in characters_in_scene:
		if is_instance_valid(c) and "on_world_map" in c:
			c.on_world_map = is_world_map

	# Build the world-map labels + territory overlay. Parented under map_loader
	# so _unload_current_map's child-clear sweeps it up automatically.
	if is_world_map:
		_world_map_overlay = WORLD_MAP_OVERLAY_SCRIPT.new()
		_world_map_overlay.name = "WorldMapOverlay"
		map_loader.add_child(_world_map_overlay)
		_world_map_overlay.configure(current_map_data.get("world_labels", []))
	else:
		_world_map_overlay = null

	# Anyone whose absence has run out walks back in. After the spawn pass so
	# there is a player to stand next to, before map_loaded so listeners see the
	# final roster.
	_resolve_returns(map_id)

	emit_signal("map_loaded", map_id)
	print("[GameScene] Loaded map: %s (spawn: %s)" % [map_id, spawn_key])

# Map-bound dialogue trigger plumbing -------------------------------------

func _install_dialogue_zones(map_data: Dictionary) -> void:
	var zones: Array = map_data.get("dialogue_zones", [])
	if zones.is_empty():
		return
	var DZC = preload("res://Structures/DialogueZoneController.gd")
	var controller = DZC.new()
	controller.name = "DialogueZoneController"
	# Parent under map_loader so _unload_current_map's child-clear sweeps it up.
	map_loader.add_child(controller)
	controller.configure(current_map_id, zones)

func _process_on_load_dialogue_triggers(map_data: Dictionary) -> void:
	var triggers: Array = map_data.get("dialogue_triggers_on_load", [])
	if triggers.is_empty():
		return
	var trigger_state = get_node_or_null("/root/MapTriggerState")
	for t in triggers:
		var tid := str(t.get("id", ""))
		var dialogue_id := str(t.get("dialogue", ""))
		if dialogue_id.is_empty():
			continue
		var one_shot: bool = bool(t.get("one_shot", true))
		if one_shot and trigger_state and trigger_state.has_fired(current_map_id, tid):
			continue
		var prereqs = t.get("prerequisites", [])
		if not DialogueManager.evaluate_prerequisites(prereqs):
			continue
		DialogueManager.start_dialogue(dialogue_id)
		if one_shot and trigger_state and not tid.is_empty():
			trigger_state.mark_fired(current_map_id, tid)

func _unload_current_map() -> void:
	# Snapshot any service-NPC live state so trades stick across map transitions.
	if not _skip_unload_capture:
		_save_service_npc_states()

	# Snapshot world-item state, then actually clear the item nodes. Items
	# were previously LEAKED across transitions — never freed and never
	# erased from items_in_scene, so each revisit re-spawned duplicates on
	# top of ghost nodes. queue_free (not _destroy_item: that path spawns
	# resource drops and fires the destroyed signal).
	if not _skip_unload_capture:
		_capture_item_state()
	for it in items_in_scene:
		if is_instance_valid(it):
			GridManager.unregister_object(GridManager.world_to_map(it.global_position), it)
			it.queue_free()
	items_in_scene.clear()

	# Drop map-scoped scheduled dialogue triggers so they don't fire on the
	# next map. Global triggers are unaffected.
	var scheduler = get_node_or_null("/root/EventScheduler")
	if scheduler:
		scheduler.on_map_exited(current_map_id)

	# Remove all spawned characters
	for character in characters_in_scene:
		if is_instance_valid(character):
			character.queue_free()
	characters_in_scene.clear()
	party_chars.clear()
	player = null
 
	# Remove warp zones
	for zone in warp_zones:
		if is_instance_valid(zone):
			zone.queue_free()
	warp_zones.clear()
 
	# Clear the MapLoader's children (floors, structures)
	for child in map_loader.get_children():
		child.queue_free()

	# Clear fluids
	if fluid_manager:
		fluid_manager.clear_all_water_tiles()

	# Clear surfaces (fire, etc.)
	if surface_manager:
		surface_manager.clear_all_surfaces()
		surface_manager.invalidate_floor_cache()

	# Clear sound-suppression zones (Silence and friends). These parent to the
	# scene root rather than map_loader, so they need an explicit sweep.
	HearingManager.clear_sound_zones()

	# Clear weather VFX
	if weather_vfx_controller:
		weather_vfx_controller.clear_all()

	GridManager.set_elevation_data(null)

	_forced_precip = ""
	var leaving_group: String = current_map_data.get("weather_group", "")
	current_map_id = ""
	current_map_data = {}
	# Timed spell weather on a group map would otherwise keep raining acid on
	# every map sharing the group until the next daily roll. Reverted after
	# current_map_data is cleared, so the old map doesn't announce it.
	if _forced_weather_left > 0.0 and not leaving_group.is_empty() \
			and WeatherManager.get_precipitation(leaving_group) == _forced_weather_type:
		WeatherManager.set_precipitation(leaving_group, _forced_weather_revert)
	_forced_weather_left = 0.0
	_forced_weather_type = ""
	_forced_weather_revert = ""
	_weather_caster = null
	_weather_condition_timers.clear()

# ---------------------------------------------------------------------------
# Ambient setup (fog + music)
# ---------------------------------------------------------------------------

func setup_map_fogs(map_data: Dictionary) -> void:
	if not fog_manager:
		return
	fog_manager.clear_all_fog()
	# Ambient map fog covers the whole map (create_fog_from_id would centre one
	# authored-size cloud on the origin, over the top-left corner only); vision
	# reads the same fog (get_fog_sight_mult_at).
	var map_px := Vector2(GridManager.map_rect.size) * GridManager.TILE_SIZE
	var map_origin := Vector2(GridManager.map_rect.position) * GridManager.TILE_SIZE
	for fog_id in map_data.get("fog_ids", []):
		fog_manager.create_map_fog(fog_id, map_px, map_origin)

func setup_map_music(map_data: Dictionary) -> void:
	var track: String = map_data.get("music_track", "")
	# The combat layer rides on top of this; MusicManager falls back here when
	# the fight ends. Crossing a warp mid-fight keeps the combat track playing.
	# A blank or unresolvable `music_track` resolves to
	# MusicManager.DEFAULT_AMBIENT_TRACK — a map wanting real silence sets
	# `music_track` to MusicManager.SILENCE_KEY.
	MusicManager.set_ambient_track(track)

func setup_map_weather(map_data: Dictionary) -> void:
	_forced_precip = ""
	var weather_group: String = map_data.get("weather_group", "")
	if weather_vfx_controller:
		if weather_group.is_empty():
			weather_vfx_controller.clear_all()
		else:
			weather_vfx_controller.setup_for_map(weather_group)
	if weather_debug_window and weather_debug_window.has_method("set_weather_group"):
		weather_debug_window.set_weather_group(weather_group)
	# Arriving in weather is visible on screen; only later changes are announced.
	_announced_precip = WeatherManager.get_precipitation(weather_group) if not weather_group.is_empty() else "clear"
	# Apply initial weather effects to fluids
	if not weather_group.is_empty():
		var weather = WeatherManager.get_weather(weather_group)
		if not weather.is_empty():
			_apply_weather_fluid_effects(weather)
	# Arriving under some weather: its sight effect applies, unannounced.
	_refresh_weather_state()

## Force a precipitation type onto the current map, e.g. from a weather spell.
## Works regardless of the map's configured weather_group (most maps have none).
## A duration > 0 (spell weather) reverts to the previous precipitation when it
## runs out, unless the weather has changed again in the meantime; while it
## lasts, the conditions it applies (Acid Rain, Freezing Rain) are the
## caster's doing.
func force_weather(precip_type: String, duration: float = 0.0, caster: Node = null) -> void:
	if duration > 0.0:
		if _forced_weather_left <= 0.0:
			_forced_weather_revert = current_precipitation()
		_forced_weather_type = precip_type
		_forced_weather_left = duration
		_weather_caster = caster
	var map_group: String = current_map_data.get("weather_group", "")
	if not map_group.is_empty():
		# Map has a real weather group: update it normally. The resulting
		# weather_changed signal drives both the VFX controller and fluid effects.
		WeatherManager.set_precipitation(map_group, precip_type)
		return
	# Map has no weather group (interiors/dungeons): drive the VFX and fluid
	# effects directly, since no group state exists for the signal path to use.
	_forced_precip = precip_type
	if weather_vfx_controller and weather_vfx_controller.has_method("force_precipitation"):
		weather_vfx_controller.force_precipitation(precip_type)
	_announce_weather_change(precip_type, _refresh_weather_state(true))
	_apply_weather_fluid_effects({"precipitation": precip_type})

func _on_weather_changed(group: String, weather_state: Dictionary) -> void:
	var map_group = current_map_data.get("weather_group", "")
	if group != map_group or map_group.is_empty():
		return
	_announce_weather_change(String(weather_state.get("precipitation", "clear")), _refresh_weather_state(true))
	_apply_weather_fluid_effects(weather_state)

# Precipitation last announced (or present on arrival) for the current map.
# weather_changed also fires for wind-only changes and same-weather daily
# rolls, so only an actual precipitation change is logged.
var _announced_precip: String = "clear"
# "<Spell weather> passes.", set by _tick_forced_weather just before it restores
# the old weather, so the end of a timed spell and the turn are one line.
var _weather_lead: String = ""

## One log line per change: "The weather turns: Heavy Rain." and then what it
## does to the party (`effects`, _refresh_weather_state's note: "Sight drops
## to 50%.", the exposure text), so the line says why the cones just shrank.
func _announce_weather_change(precip: String, effects: String = "") -> void:
	var lead: String = _weather_lead
	_weather_lead = ""
	if precip == _announced_precip:
		var same: String = (lead + " " + effects).strip_edges()
		if not same.is_empty():
			GameLog.add_entry(same)
		return
	_announced_precip = precip
	var pd: Dictionary = WeatherManager.get_precipitation_data(precip)
	var line: String = "The weather turns: %s." % str(pd.get("display_name", precip.replace("_", " ").capitalize()))
	if not lead.is_empty():
		line = lead + " " + line
	if not effects.is_empty():
		line += " " + effects
	GameLog.add_entry(line)

func _count_ice_tiles() -> int:
	var n: int = 0
	for tile_pos in surface_manager.surface_grid:
		if surface_manager.surface_grid[tile_pos].get("surface_id", "") == "ice":
			n += 1
	return n

func _apply_weather_fluid_effects(weather: Dictionary) -> void:
	var precip = weather.get("precipitation", "clear")
	match precip:
		"snow", "heavy_snow", "freezing_rain":
			# Freeze all existing fluids
			if surface_manager:
				var ice_before: int = _count_ice_tiles()
				surface_manager.try_freeze_all_fluids()
				if _count_ice_tiles() > ice_before:
					GameLog.add_entry("Standing puddles freeze into slick ice.")
		"rain", "heavy_rain", "acid_rain":
			# Spawn random water puddles across walkable tiles
			_spawn_rain_puddles(precip)

func _spawn_rain_puddles(precip_type: String) -> void:
	if not fluid_manager:
		return
	# Nothing pools from the sky indoors or on the world map.
	if current_map_data.get("is_world_map", false) or is_map_indoors():
		return
	# What falls is what pools: acid rain leaves acid, everything else water.
	var fluid_type: String = "acid" if precip_type == "acid_rain" else "water"
	var puddle_count: int = 5 if precip_type == "rain" else 12
	var amount: float = 0.35 if precip_type == "rain" else 0.6
	var placed := 0
	var attempts := 0
	var max_attempts := puddle_count * 10

	while placed < puddle_count and attempts < max_attempts:
		attempts += 1
		var rx = randi() % (GridManager.map_rect.size.x)
		var ry = randi() % (GridManager.map_rect.size.y)
		var tile = Vector2i(rx + GridManager.map_rect.position.x, ry + GridManager.map_rect.position.y)
		# Only on walkable, non-wall, non-occupied tiles
		if GridManager.walls.get(tile, true):
			continue
		if surface_manager and surface_manager.has_surface_at(tile):
			continue
		if fluid_manager.get_fluid_type_at(tile) != "":
			continue
		# No puddles under roofs.
		if not is_tile_exposed_to_sky(tile):
			continue
		# gentle: weather must never erase an authored slick (oil etc.)
		fluid_manager.rain_puddle(tile, fluid_type, amount)
		placed += 1

# ---------------------------------------------------------------------------
# Weather and fog vs sight
# ---------------------------------------------------------------------------

# Weather's effect on sight (weather.json visibility_modifier), cached on every
# precipitation change. Map-wide on outdoor maps, the world map included; 1.0
# on maps flagged indoors.
var _weather_vis_mult: float = 1.0
# Precipitation forced by a spell on a map with no weather_group (no
# WeatherManager state holds it there).
var _forced_precip: String = ""
# The precipitation whose effects the log last described (_refresh_weather_state).
var _weather_effects_precip: String = "clear"

## Maps.json "indoors": interiors and underground maps, where weather neither
## falls nor affects sight.
func is_map_indoors() -> bool:
	return bool(current_map_data.get("indoors", false))

## The precipitation actually falling on this map: the weather group's, or a
## spell-forced one on a map without a group.
func current_precipitation() -> String:
	var group: String = current_map_data.get("weather_group", "")
	if not group.is_empty():
		return WeatherManager.get_precipitation(group)
	return _forced_precip if not _forced_precip.is_empty() else "clear"

## Re-reads the falling weather's effect on sight. With `announce` (a real
## change, not a map arrival) it returns how far sight drops or recovers
## (_weather_effects_note, "" when nothing changes for the party), which
## _announce_weather_change adds to its line; otherwise "".
func _refresh_weather_state(announce: bool = false) -> String:
	var precip: String = current_precipitation()
	var prev_mult: float = _weather_vis_mult
	if is_map_indoors():
		_weather_vis_mult = 1.0
	else:
		var pd: Dictionary = WeatherManager.get_precipitation_data(precip)
		_weather_vis_mult = clampf(float(pd.get("visibility_modifier", 1.0)), 0.1, 1.0)
	var note: String = ""
	if announce and precip != _weather_effects_precip:
		note = _weather_effects_note(prev_mult, _weather_vis_mult, precip)
	_weather_effects_precip = precip
	return note

## What a weather change does to the party, for the log: "Sight drops to 50%.",
## "Sight recovers to 75%." or "Full sight returns.", then the weather's
## exposure_text where it can fall on anyone ("Anyone caught in the open
## starts to corrode."). "" when nothing changes for them.
func _weather_effects_note(prev_mult: float, mult: float, precip: String) -> String:
	var parts := PackedStringArray()
	if not is_equal_approx(prev_mult, mult):
		if mult >= 0.999:
			parts.append("Full sight returns.")
		else:
			parts.append("Sight %s to %d%%." % ["drops" if mult < prev_mult else "recovers", roundi(mult * 100.0)])
	var exposure: String = str(WeatherManager.get_precipitation_data(precip).get("exposure_text", ""))
	if not exposure.is_empty() and not is_map_indoors() and not current_map_data.get("is_world_map", false):
		parts.append(exposure)
	return " ".join(parts)

func get_weather_visibility_mult() -> float:
	return _weather_vis_mult

## Sight multiplier from the densest fog or cloud at a world point (1.0 clear).
func get_fog_sight_mult_at(world_pos: Vector2) -> float:
	if fog_manager and fog_manager.has_method("get_sight_multiplier_at"):
		return fog_manager.get_sight_multiplier_at(world_pos)
	return 1.0

# ---------------------------------------------------------------------------
# Weather on whoever stands under open sky
# ---------------------------------------------------------------------------

## Open sky over a tile: not an indoors map, not the world map, and no roof
## (structured maps carry a roof layer; legacy maps have none, so they are
## open everywhere unless flagged indoors).
func is_tile_exposed_to_sky(t: Vector2i) -> bool:
	if is_map_indoors() or current_map_data.get("is_world_map", false):
		return false
	return not GridManager.has_roof(t)

## Whether weather falls on `c`: standing on a roof, or on an unroofed tile.
func is_exposed_to_sky(c) -> bool:
	if is_map_indoors() or current_map_data.get("is_world_map", false):
		return false
	if "on_roof" in c and c.on_roof:
		return true
	return is_tile_exposed_to_sky(GridManager.world_to_map(c.global_position))

# Spell weather with a duration (force_weather): seconds left, the type it
# forced, the precipitation to restore when it runs out, and who cast it.
var _forced_weather_left: float = 0.0
var _forced_weather_type: String = ""
var _forced_weather_revert: String = ""
var _weather_caster: Node = null
# instance_id -> seconds of continuous exposure to condition-bearing weather.
var _weather_condition_timers: Dictionary = {}

## Acid Rain, Freezing Rain: weather.json applies_condition lands on everyone
## out in the open after apply_interval seconds of exposure, and again every
## interval while they stay out, up to max_stacks (so rain alone never
## freezes). Shelter resets the timer. While a caster's spell weather lasts
## the condition is theirs, so its damage counts as their attack.
func _tick_weather_conditions(delta: float) -> void:
	var precip: String = current_precipitation()
	var pd: Dictionary = WeatherManager.get_precipitation_data(precip)
	var cond: String = str(pd.get("applies_condition", ""))
	if cond.is_empty() or is_map_indoors() or current_map_data.get("is_world_map", false):
		if not _weather_condition_timers.is_empty():
			_weather_condition_timers.clear()
		return
	var interval: float = maxf(0.1, float(pd.get("apply_interval", 3.0)))
	var cap: int = int(pd.get("max_stacks", 0))
	var source: Node = null
	if _forced_weather_left > 0.0 and precip == _forced_weather_type and is_instance_valid(_weather_caster):
		source = _weather_caster
	for c in characters_in_scene:
		if not is_instance_valid(c) or not c.is_alive():
			continue
		var id: int = c.get_instance_id()
		if not is_exposed_to_sky(c):
			_weather_condition_timers.erase(id)
			continue
		var t: float = float(_weather_condition_timers.get(id, 0.0)) + delta
		if t < interval:
			_weather_condition_timers[id] = t
			continue
		_weather_condition_timers[id] = 0.0
		var cm = c.get_node_or_null("ConditionManager")
		if cm == null:
			continue
		var existing = cm.conditions.get(cond)
		if cap > 0 and existing != null and existing.stacks >= cap:
			# At the cap: keep it from lapsing while they stay out (re-applying
			# a stackable doesn't refresh its timer).
			var dur: float = float(existing.condition.duration)
			if dur > 0.0 and existing.expires_at > 0.0:
				existing.expires_at = maxf(existing.expires_at, TimeManager.absolute_time() + dur)
			continue
		cm.apply_condition(cond, source, 1)

## Counts down timed spell weather and restores the previous precipitation.
func _tick_forced_weather(delta: float) -> void:
	if _forced_weather_left <= 0.0:
		return
	_forced_weather_left -= delta
	if _forced_weather_left > 0.0:
		return
	var passing: String = _forced_weather_type
	var revert: String = _forced_weather_revert
	_forced_weather_left = 0.0
	_forced_weather_type = ""
	_forced_weather_revert = ""
	_weather_caster = null
	# A daily reroll (or another spell) may already have replaced it.
	if passing.is_empty() or passing == revert or current_precipitation() != passing:
		return
	var pd: Dictionary = WeatherManager.get_precipitation_data(passing)
	# Leads the turn's announcement: "Acid Rain passes. The weather turns: Clear."
	_weather_lead = "%s passes." % str(pd.get("display_name", passing.replace("_", " ").capitalize()))
	force_weather(revert)
	# Nothing announced the turn (no weather_changed came through): say it alone.
	if not _weather_lead.is_empty():
		GameLog.add_entry(_weather_lead)
		_weather_lead = ""

# ---------------------------------------------------------------------------
# Party spawning
# ---------------------------------------------------------------------------

func _spawn_player_and_party(spawn_key: String) -> void:
	var spawns: Dictionary = current_map_data.get("player_spawns", {})
	var spawn_data = spawns.get(spawn_key, spawns.get("default", {}))
	var base_pos_arr = spawn_data.get("position", [400, 400])
	var base_pos = Vector2(base_pos_arr[0], base_pos_arr[1])

	# On the world map the whole party collapses into a single "banner" unit
	# representing the player faction. The rest of the party's live state
	# stays in party_state and is restored intact when we return to a local
	# map. The protagonist's runtime entity stands in for the group.
	var is_world_map: bool = current_map_data.get("is_world_map", false)
	var spawn_count: int = 1 if is_world_map else party_state.size()

	for i in range(spawn_count):
		var entry = party_state[i]
		# A member who stayed behind to finish their training, or who walked off
		# to take other work, has no body in the world until they come back.
		if is_party_member_away(entry):
			continue
		var offset = _party_line_offset(base_pos, i) if not is_world_map else Vector2.ZERO
		# Same guard as _spawn_npcs: a party member built from a race-rolling
		# template must rebuild the race their live_state was captured with,
		# not roll a fresh one for the snapshot to stamp over.
		var member_overrides: Dictionary = entry.get("overrides", {})
		var live = entry.get("live_state")
		if live is Dictionary and not str(live.get("race_id", "")).is_empty():
			member_overrides = member_overrides.duplicate()
			member_overrides["race"] = str(live["race_id"])
			if not str(live.get("gender", "")).is_empty():
				member_overrides["gender"] = str(live["gender"])
		var character = _spawn_character(entry["template_id"], base_pos + offset, member_overrides)
		if not character:
			continue

		party_chars.append(character)
		# Which party_state row this body belongs to. save_party_state used to
		# pair the two arrays positionally, which is only correct while every row
		# spawns; the `away` skip above breaks that, and a desynced pair writes
		# one member's snapshot onto another's row.
		character.set_meta("party_index", i)
		# Party members always play by school-resource rules. TopDownCharacterDatabase
		# defaults to npc_unlimited_resources = true for any template that hasn't
		# opted into the new system; party characters override that here so casts
		# actually drain adrenaline/focus/etc.
		character.npc_unlimited_resources = false
		character.AI_enabled = true
		character.is_player_controlled = false

		# Restore live state if we have one (from map transition / save load)
		if entry.get("live_state"):
			_deserialize_character(character, entry["live_state"])

		# First party member is the player
		if i == 0:
			player = character
			character.is_protagonist = true
			# Re-stamp the issued card. It lives on the character as metadata
			# (not a property) because nothing in the simulation reads it —
			# only the character sheet does, and only to reprint it verbatim.
			var carta: Dictionary = entry.get("overrides", {}).get("carta", {})
			if not carta.is_empty():
				character.set_meta("carta", carta)

		# All party members share the player faction so AI won't target allies
		character.faction_id = "player"
		# Re-wire ally-witness now that faction_id is final (spawn-time wiring
		# happens before this assignment, so no party connections form there).
		_wire_ally_witness(character)

		# Add line-of-sight light
		_add_line_of_sight_light(character)

# Offset of the i-th party member in the arrival line at base_pos.
# Elevation-aware line spawn: on a narrow surface (ladder-top deck, a
# battlement walkway ~20px wide) the +x row walks later members off the
# edge — they'd land at ground level beside the wall, or inside it.
# Collapse onto the base position when the offset tile's surface
# differs; the separation nudge spreads them out safely after spawn.
func _party_line_offset(base_pos: Vector2, i: int) -> Vector2:
	var offset := Vector2(i * 40, 0)
	if offset != Vector2.ZERO:
		var bt := GridManager.world_to_map(base_pos)
		var ot := GridManager.world_to_map(base_pos + offset)
		if ot != bt and (not GridManager.can_step(bt, ot)
				or GridManager.grid_costs.get(ot, INF) == INF):
			offset = Vector2.ZERO
	return offset

## Same-map warp (ladder/stairs): move the living party to the arrival marker
## instead of rebuilding the map, so enemies, doors, fires and fluids stay as
## the player left them. Corpses stay where they fell. Like a full reload it
## drops plans made on the level being left; unlike one it keeps the current
## selection, standing WAIT orders and music, and emits no map_loaded (nor
## re-runs on-load dialogue triggers): the map didn't change.
func _relocate_party(spawn_key: String) -> void:
	var spawn_data = current_map_data.get("player_spawns", {}).get(spawn_key, {})
	var base_pos_arr = spawn_data.get("position", [400, 400])
	var base_pos = Vector2(base_pos_arr[0], base_pos_arr[1])
	var slot: int = 0
	for character in party_chars:
		if not is_instance_valid(character) or not character.is_alive():
			continue
		# A jump in flight re-lerps from its takeoff every frame, so it would
		# carry the body back to its landing on the level being left.
		if character._jump_active:
			character.collision_mask = character._jump_saved_mask
			character._jump_active = false
		character.global_position = base_pos + _party_line_offset(base_pos, slot)
		slot += 1
		character.velocity = Vector2.ZERO
		character.target_position = character.global_position
		# Drop orders and paths planned on the level being left.
		character.abort_planning_input()
		if character.action_queue:
			character.action_queue.cancel_all()
		if character.path_input_handler:
			character.path_input_handler.cancel_path()
		character._nav_waypoints.clear()
		character._nav_index = 0
		character.is_moving = false
		# Spawn semantics: arrivals stand on the surface under the marker
		# (only jumpers ever ride a roof). Re-derives elevation, the sight
		# light tier and the roof-view layer.
		character.on_roof = false
		character._refresh_elevation()
		var ai = character.get_node_or_null("AI")
		if ai:
			ai.nav_path.clear()
			ai.nav_path_index = 0
		ExplorationManager.seed_explored(GridManager.world_to_map(character.global_position), 2)
	# Warp conditions are evaluated when zones are built; rebuild them as the
	# full reload did, so e.g. a key picked up on this level opens its stair.
	for zone in warp_zones:
		if is_instance_valid(zone):
			zone.queue_free()
	warp_zones.clear()
	_create_warp_zones(current_map_data.get("warp_points", []))
	# The LOS passes only run unpaused; refresh now so a warp taken while
	# planning shows who is (and isn't) in view on the new level.
	_update_npc_los_visibility()
	_update_item_los_visibility()
	var focus = primary_selected if is_instance_valid(primary_selected) else player
	if player_camera and focus and is_instance_valid(focus):
		player_camera.manual_pan_active = false
		player_camera.global_position = focus.global_position
		player_camera.reset_smoothing()
	print("[GameScene] Moved party within %s (spawn: %s)" % [current_map_id, spawn_key])

## A warp whose destination can't load: say so instead of silently staying put
## (load_map keeps its push_error for developers).
func _announce_way_closed(log_text: String) -> void:
	var who = primary_selected if is_instance_valid(primary_selected) else player
	if who and is_instance_valid(who):
		who.notify("Way closed", Color(1.0, 0.6, 0.4), log_text)
	else:
		GameLog.add_entry(log_text)

# ---------------------------------------------------------------------------
# Item spawning
# ---------------------------------------------------------------------------

func _spawn_items(item_list: Array) -> void:
	for item_def in item_list:
		if item_def.has("condition") and not check_spawn_conditions(item_def["condition"]):
			continue

		var item_id: String = item_def.get("id", "")
		var pos_arr = item_def.get("position", [0, 0])
		var pos = Vector2(pos_arr[0], pos_arr[1])
		var count: int = item_def.get("count", 1)

		# Per-spawn extras (only applied when present): controlling_faction triggers
		# faction-filtered auto-loot for chests, value overrides the loot target.
		var extras: Dictionary = {}
		if item_def.has("controlling_faction"):
			extras["controlling_faction"] = item_def["controlling_faction"]
		if item_def.has("value"):
			extras["value"] = float(item_def["value"])

		# Ownership resolution chain, first hit wins: per-spawn owner_faction,
		# map-level default_item_owner, the map's jurisdiction when the map
		# declares "settlement": true, else unowned. Deliberately NO
		# "everything on a lawful map is owned" global — that criminalises
		# picking up a stray apple with no authoring signal.
		var owner_f: String = str(item_def.get("owner_faction", ""))
		if owner_f.is_empty():
			owner_f = str(current_map_data.get("default_item_owner", ""))
		if owner_f.is_empty() and bool(current_map_data.get("settlement", false)):
			owner_f = LawDatabase.jurisdiction_for_map(current_map_id)
		if not owner_f.is_empty():
			extras["owner_faction"] = owner_f
		if item_def.has("owner_uid"):
			extras["owner_uid"] = str(item_def["owner_uid"])

		for j in range(count):
			var inst := create_item(item_id, pos, 1, extras)
			# authored placements (editor exports): rotation is radians (the
			# editor's draw transform + all 555 shipped spawns stay under 2*PI),
			# scale a uniform multiplier over the item's base footprint. Both
			# were being exported and silently dropped — every authored long
			# table lay sideways and scaled set pieces (carpets) shrank.
			if inst != null:
				inst.rotation = float(item_def.get("rotation", 0.0))
				var sc := float(item_def.get("scale", 1.0))
				# scale_x/scale_y stretch the item along its OWN axes on top of
				# the uniform scale (node scale is applied before rotation, so
				# the stretch follows the art); negative values mirror the art.
				var sx := sc * float(item_def.get("scale_x", 1.0))
				var sy := sc * float(item_def.get("scale_y", 1.0))
				if sx != 1.0 or sy != 1.0:
					inst.scale = Vector2(sx, sy)
				# surface stacking: z lifts the piece above base items (a pot on
				# a stove) while staying under characters (z=5). Set AFTER
				# create_item — Item._ready already ran and pinned z_index = 1.
				var zb := int(item_def.get("z", 0))
				if zb != 0:
					inst.z_index = 1 + zb

func _spawn_fluids(fluid_list: Array) -> void:
	if not fluid_manager:
		push_warning("FluidManager not available — skipping fluid_spawns")
		return
	for fluid_def in fluid_list:
		var fluid_type: String = fluid_def.get("type", "water")
		var pos_arr = fluid_def.get("position", [0, 0])
		var amount: float = fluid_def.get("amount", 0.5)
		var radius: int = fluid_def.get("radius", 0)
		var center_tile = Vector2i(pos_arr[0], pos_arr[1])

		# Structured maps with an area: pour a CONTIGUOUS pool — the per-tile
		# loop deposited into 13 scattered covering cells, which rendered as
		# faint smudges players read as terrain shading, not an oil slick.
		if radius > 0 and fluid_manager.cell_fluid != null and fluid_manager.cell_fluid.active_sim():
			var wc: Vector2 = GridManager.map_to_world(center_tile)
			var wr: float = (float(radius) + 0.5) * GridManager.TILE_SIZE
			fluid_manager.cell_fluid.pour(wc, fluid_type, amount, wr)
		else:
			# Spawn fluid at center tile and optionally in a radius
			for dx in range(-radius, radius + 1):
				for dy in range(-radius, radius + 1):
					if Vector2(dx, dy).length() <= radius + 0.5:
						var tile = center_tile + Vector2i(dx, dy)
						if not GridManager.walls.get(tile, false):
							fluid_manager.register_fluid(tile, fluid_type, amount)
		# "rate" marks a PERSISTENT source (villa impluvium spring): keep the
		# pool topped up against evaporation. Structured maps only — the cell
		# sim owns sources there; the one-shot deposit above still primes it.
		var rate: float = float(fluid_def.get("rate", 0.0))
		if rate > 0.0 and fluid_manager.cell_fluid != null:
			fluid_manager.cell_fluid.add_source(GridManager.map_to_world(center_tile), fluid_type, rate)

# ---------------------------------------------------------------------------
# Context menu
# ---------------------------------------------------------------------------

## `actor` is the character who opened the menu — the one who will carry out a
## verb like "Attack". Without it the menu had no way to name an attacker and
## made the *target* swing at nothing.
func show_context_menu(target, position: Vector2, actor = null) -> void:
	var context_menu = preload("res://UI/ContextMenu.tscn").instantiate()
	context_menu.global_position = position + Vector2(16, 16)
	context_menu.z_index = 100
	context_menu_open = true

	var options: Array = []
	if target is ProceduralCharacter and not target.is_alive():
		# Corpses: loot only — Trade/Talk/Wait are living verbs.
		options = ["Search Body"]
	elif target is ProceduralCharacter:
		options = target.get("interact_options").duplicate() if "interact_options" in target else ["Inspect"]
		# Inject "Trade" for any non-hostile character. FactionDatabase is the
		# authoritative relationship source. Treat allies/neutrals as
		# tradeable; only true hostiles are blocked. Party members share items
		# through the party panel, so they get no Trade.
		if not FactionDatabase.are_hostile("player", target.faction_id) and not "Trade" in options \
				and not (target in party_chars):
			options.append("Trade")
		# Party members take a hold-ground order: WAIT stops all AI movement
		# (they still auto-attack hostiles entering their line of sight);
		# FOLLOW releases it.
		if target in party_chars:
			options.append("Resume" if bool(target.get("hold_position")) else "Wait Here")
			# A companion is never an attack target.
			options.erase("Attack")
		elif not "Attack" in options and not FactionDatabase.are_hostile("player", target.faction_id) \
				and not (CrimeManager.attribute(target) in party_chars):
			# The peaceful: left-click talks to them, so this is the deliberate
			# way to start a fight (a right-click on a hostile swings instead of
			# opening a menu). The menu names the crime and asks again when the
			# law would (context_menu.gd). Not the party's own summons.
			options.append("Attack")
		# "Talk" only when they have something to say: active_dialogue_id is
		# the talk cursor's and the left-click fast path's test too, so the
		# menu never offers a conversation that opens nothing.
		if "Talk" in options and target.active_dialogue_id() == "":
			options.erase("Talk")
	elif target is Area2D and target.has_meta("target_map"):
		options = ["Enter " + target.get_meta("label", "area")]
	elif target is Door:
		options = target.get_interact_options()
	elif target is Item:
		options = _world_item_options(target)
	elif target is Dictionary:
		# Item context menu — use interact_options from item data
		options = target.get("interact_options", ["Use", "Drop"])

	# Nothing handles "Inspect" (no context-menu arm, characters have no
	# interact(), Item.interact has no case for it), so it is never offered.
	# filter() copies, so item data's own option list is left alone.
	options = options.filter(func(o): return str(o) != "Inspect")
	if options.is_empty():
		# Every option was a dead end: no empty box. Its vbox is only
		# parented in the menu's _ready, so free it too or it leaks.
		if is_instance_valid(context_menu.vbox) and context_menu.vbox.get_parent() == null:
			context_menu.vbox.free()
		context_menu.free()
		call_deferred("set", "context_menu_open", false)
		return

	context_menu.setup(target, options, actor)
	$GameUI.add_child(context_menu)

## World-item context menu options. Readables keep Read/Take; containers keep
## the options something handles ("Open", Item.INTERACT_OPTIONS); every other
## world item is pick-up-able.
func _world_item_options(item: Item) -> Array:
	if item.item_type == "readable":
		return item.options.duplicate() if item.options else ["Read"]
	var is_container: bool = item.num_slots > 0 or (item.options.size() > 0 and str(item.options[0]) == "Open")
	if is_container:
		# A treasure chest's "Inspect" and a world backpack's inventory-only
		# "Drop"/"Equip" have no handler here: they'd close the menu and do
		# nothing, so a chest offers just "Open".
		var usable: Array = []
		for o in item.options:
			if str(o) == "Open" or str(o) in Item.INTERACT_OPTIONS:
				usable.append(o)
		return usable if not usable.is_empty() else ["Open"]
	# A loose world item: the world action is to pick it up. Intrinsic actions
	# (Consume/Throw/Equip) and "Drop" belong to the inventory context menu.
	# Owned items read differently — one string of legibility, no new art.
	if "owner_faction" in item and item.owner_faction != "":
		return ["Pick Up (owned)"]
	return ["Pick Up"]

## Pick up a world item into a party member's inventory, then remove it from the
## world. Returns true on success. Readables are excluded (they use Read/Take).
func pick_up_item(item: Item) -> bool:
	# Queued for free = already taken this frame. Several selected characters all
	# see the same left-click, and remove_world_item leaves the node in the tree
	# until the free, so the second one's probe can still find it.
	if not is_instance_valid(item) or item.is_queued_for_deletion():
		return false
	var character = _resolve_pickup_character()
	if character == null:
		GameLog.add_entry("No one is free to pick that up.")
		return false
	# Reach gate: _resolve_pickup_character returns primary_selected with no
	# distance check anywhere in the chain — without this the player can
	# select someone outside the town gate and take an item from inside the
	# guardhouse, and every witness anchor is wrong. Walk-to-then-take is
	# already expressible through the action queue.
	if character.global_position.distance_to(item.global_position) > CrimeManager.PICKUP_REACH:
		GameLog.add_entry("%s is too far away to reach that." % character.Name)
		return false
	if _refuse_during_trade(character, "pick up", "the " + (item.display_name if item.display_name != "" else str(item.id).replace("_", " "))):
		return false
	var data: Dictionary = item.to_inventory_data()
	if data.is_empty():
		return false
	var item_name: String = str(data.get("display_name", item.display_name if item.display_name != "" else str(item.id).replace("_", " ")))
	# Non-stackables carry "num_stacks": null from Items.json.
	var stacks_v = data.get("num_stacks", 1)
	var count: int = int(stacks_v) if (stacks_v is int or stacks_v is float) else 1
	var equip_slot: String = str(data.get("equip_slot", ""))
	var ok: bool = false
	if (equip_slot == "Main Hand" or equip_slot == "Off Hand") and character.inventory.has_method("stow_weapon_from_data"):
		character.inventory.stow_weapon_from_data(data)
		ok = true
	else:
		ok = character.inventory.add_stack(data)
	if ok:
		if SfxManager and SfxManager.has_method("play"):
			SfxManager.play("chest_item_in", item.global_position)
		GameLog.add_entry("%s picks up %s%s." % [character.Name, item_name, " (x%d)" % count if count > 1 else ""])
		# Report BEFORE the node dies — the payload reads the item's fields.
		# A refused pickup (full inventory) is not a theft.
		CrimeManager.report(character, "take", CrimeManager.take_payload(item))
		remove_world_item(item)
	else:
		# The inventory announces "Inventory full" itself (Inventory.add_failed).
		# add_stack may still have merged part of the stack into one already
		# carried, writing back what is left to `data` (a copy): that part was
		# taken, so it is reported, and only the remainder stays on the ground.
		var left_v = data.get("num_stacks", item.stack_count)
		var left: int = int(left_v) if (left_v is int or left_v is float) else item.stack_count
		if item.is_stackable and left > 0 and left < item.stack_count:
			CrimeManager.report(character, "take", CrimeManager.take_payload(item))
			item.remove_from_stack(item.stack_count - left)
	return ok

## Take a world item out of the world because it went into a pack whole: off
## the grid, out of items_in_scene, then freed. Unlike Item._destroy_item it
## emits no "destroyed", so _on_item_destroyed's salvage (a crate's planks)
## never spawns for an item that was picked up, not broken.
func remove_world_item(item: Item) -> void:
	if not is_instance_valid(item):
		return
	GridManager.unregister_object(item._grid_pos, item)
	items_in_scene.erase(item)
	if item.sprite:
		item.sprite.visible = false
	if item.collision_shape:
		item.collision_shape.disabled = true
	item.queue_free()

## True while a TradeWindow is open. Its Cancel puts every party inventory
## back from the snapshot taken at open, so a pack change made meanwhile (a
## pick-up, gathered water) would be undone: those wait for the trade, as the
## party, chest and service panels' moves do.
func trade_open() -> bool:
	for w in get_tree().get_nodes_in_group("trade_window"):
		if not w.is_queued_for_deletion():
			return true
	return false

## The panels' trade refusal for Game's own pack changes: says so and returns
## true while a trade is open. `what` names the thing in the log line.
func _refuse_during_trade(character, verb: String, what: String) -> bool:
	if not trade_open():
		return false
	SfxManager.play_ui("trade_decline")
	character.notify("Finish the trade first", Color(1.0, 0.6, 0.4),
		"%s can't %s %s while a trade is open: accept or cancel it first." % [character.Name, verb, what])
	return true

# Pick the party member who should receive a picked-up item: the primary-selected
# character, else the first LIVING party member with an inventory. Nothing clears
# primary_selected on death, so a dead primary could otherwise "receive" loot —
# including from its own corpse window at distance 0 (review find).
func _resolve_pickup_character():
	if primary_selected != null and is_instance_valid(primary_selected) \
			and primary_selected.inventory != null and primary_selected.is_alive():
		return primary_selected
	for c in party_chars:
		if is_instance_valid(c) and ("inventory" in c) and c.inventory != null \
				and (not c.has_method("is_alive") or c.is_alive()):
			return c
	return null

# ---------------------------------------------------------------------------
# Chest inventory + Trade windows
# ---------------------------------------------------------------------------

func show_chest_inventory(item: Item) -> void:
	if not is_instance_valid(item):
		return
	# Same reach gate as pick_up_item — this site previously had zero gates.
	var opener = _resolve_pickup_character()
	if opener != null and opener.global_position.distance_to(item.global_position) > CrimeManager.PICKUP_REACH:
		GameLog.add_entry("%s is too far away to reach that." % opener.Name)
		return
	# Locked containers (an Items.json "key") open only for a party carrying the
	# key; otherwise the chest floats "Locked" and the log says so. Corpses
	# (show_loot_window) never lock. Both ways of opening a chest end here.
	if not item.try_unlock_for_party(party_chars):
		return
	var ChestWindow = preload("res://UI/ChestInventoryWindow.tscn")
	var w = ChestWindow.instantiate()
	w.chest_item = item
	$GameUI.add_child(w)

## Corpse looting ("Search Body"): the same window as chests — a corpse quacks
## like a container (`contents` aliases its inventory's dict array on death,
## `display_name` already exists on characters). Same reach gate as chests.
func show_loot_window(corpse) -> void:
	if not is_instance_valid(corpse):
		return
	var opener = _resolve_pickup_character()
	if opener != null and opener.global_position.distance_to(corpse.global_position) > CrimeManager.PICKUP_REACH:
		GameLog.add_entry("%s is too far away to reach that." % opener.Name)
		return
	var ChestWindow = preload("res://UI/ChestInventoryWindow.tscn")
	var w = ChestWindow.instantiate()
	w.chest_item = corpse
	$GameUI.add_child(w)

func show_readable(readable_id: String) -> void:
	# Readables open in a parchment/book-themed reading window and are filed into
	# the journal (ReadableManager), never the inventory. Pure-GDScript window —
	# instantiate the script directly, not a PackedScene.
	if ReadableDatabase == null or not ReadableDatabase.has_readable(readable_id):
		return
	# Don't stack duplicate windows for the same readable.
	for c in $GameUI.get_children():
		if c is ReadableWindow and c.readable_id == readable_id:
			return
	var ReadableWin = load("res://UI/ReadableWindow.gd")
	var w_read = ReadableWin.new()
	w_read.readable_id = readable_id
	$GameUI.add_child(w_read)

func show_trade_window(npc) -> void:
	if not is_instance_valid(npc):
		return
	# Make the party side panel visible so the player can drag from it during trade.
	var party_panel = $GameUI.get_node_or_null("PartySidePanel")
	if party_panel:
		party_panel.visible = true
	var TradeWindow = preload("res://UI/TradeWindow.tscn")
	var w = TradeWindow.instantiate()
	w.npc = npc
	$GameUI.add_child(w)

# ---------------------------------------------------------------------------
# Lighting helpers
# ---------------------------------------------------------------------------

## Fits a sight-cone light to its character's real sight: the wedge matches the
## effective FOV and the radius the current range (conditions, weather, fog at
## the viewer). A zero range (Blinded, Unconscious, dead: can_see_point sees
## nothing) switches the light off via `enabled`, since stealth mode owns
## `visible` on NPC cones.
func _fit_sight_light(light: PointLight2D, c: ProceduralCharacter) -> void:
	var tex: Texture2D = Globals.get_sight_cone_texture(c.effective_fov())
	if light.texture != tex:
		light.texture = tex
	var r: float = c.get_sight_range_px() if c.is_alive() else 0.0
	light.enabled = r >= 1.0
	if r >= 1.0:
		var s: float = r / (tex.get_width() * 0.5)
		if not is_equal_approx(light.texture_scale, s):
			light.texture_scale = s

## Re-fits every drawn cone each frame, paused or not (the party plans while
## paused), so Perceptive, Blinded, weather and walking into fog show at once.
const SIGHT_CONE_NAMES := ["LineOfSight", "NPCLineOfSight", "NPCLineOfSightHigh"]
func _update_sight_cones() -> void:
	for c in characters_in_scene:
		if not is_instance_valid(c):
			continue
		for n in SIGHT_CONE_NAMES:
			var light = c.get_node_or_null(n)
			if light is PointLight2D:
				_fit_sight_light(light, c)
		if c.has_node("NPCLineOfSightHigh"):
			sync_npc_elevated_cone(c)

func _add_line_of_sight_light(character: ProceduralCharacter) -> void:
	var light = PointLight2D.new()
	_fit_sight_light(light, character)
	light.energy = 0.1
	light.name = "LineOfSight"
	light.rotation_degrees = -90
	light.shadow_enabled = true
	light.shadow_item_cull_mask = CollisionLayers.SIGHT_MASK_HIGH if character.current_elevation >= 1.0 else CollisionLayers.SIGHT_MASK_GROUND
	light.z_index = 102
	character.add_child(light)
	# Legibility: cones show STATE, not just geometry — tinted off the AI's
	# alertness. (Deliberately no special colour for outcry-phase witnesses:
	# the amber ! is the channel the player must be able to trust.)
	var ai_node = character.get_node_or_null("AI")
	if ai_node != null and ai_node.has_signal("alertness_changed"):
		ai_node.alertness_changed.connect(func(_old, new_alertness):
			_tint_sight_cone(light, int(new_alertness)))
		_tint_sight_cone(light, int(ai_node.current_alertness))

# AI.Alertness enum order: AT_EASE=0, UNAWARE=1, SUSPICIOUS=2, SEARCHING=3, HOSTILE=4.
func _tint_sight_cone(light: PointLight2D, alertness: int) -> void:
	if not is_instance_valid(light):
		return
	match alertness:
		2:
			light.color = Color(1.0, 0.75, 0.25)   # SUSPICIOUS — amber
			light.energy = 0.12
		3, 4:
			light.color = Color(1.0, 0.3, 0.25)    # SEARCHING/HOSTILE — red
			light.energy = 0.14
		_:
			light.color = Color(0.55, 0.62, 0.72)  # AT_EASE/UNAWARE — dim blue-grey
			light.energy = 0.08

func _add_npc_line_of_sight_light(npc: ProceduralCharacter) -> void:
	"""Add a LOS cone as a child of the NPC. Hidden unless stealth mode is on.
	When the NPC is hidden (not in party LOS), the light hides with it."""
	var light = PointLight2D.new()
	_fit_sight_light(light, npc)
	light.energy = 0.5
	light.color = Color(1.0, 0.3, 0.2)  # strong red tint
	light.name = "NPCLineOfSight"
	light.rotation_degrees = -90
	light.shadow_enabled = true
	light.shadow_item_cull_mask = CollisionLayers.SIGHT_MASK_HIGH if npc.current_elevation >= 1.0 else CollisionLayers.SIGHT_MASK_GROUND
	# Illuminate layer 1 (normal scene objects) so the cone is actually visible
	light.range_item_cull_mask = 1
	light.z_index = 102
	# Follow the current stealth mode (the shared cone rule), so NPCs spawned
	# after a map load or mid-mission match it instead of starting hidden.
	light.visible = _npc_cones_shown(npc)
	npc.add_child(light)

func _apply_material_recursive(node: Node, material: Material) -> void:
	if node is Sprite2D or node is TextureRect:
		node.material = material
	for child in node.get_children():
		_apply_material_recursive(child, material)

func create_item(item_id: String, world_position: Vector2, stack_count: int = 1, extras: Dictionary = {}) -> Item:
	"""Create any item (weapon, equipment, or general item) by its ID and place it in the world.

	The optional `extras` dict can carry per-spawn overrides set on the Item before
	_ready runs — currently `controlling_faction` and `value` (float, used as the
	auto-fill loot target on chests). Existing 3-arg callers continue to work."""
	var item_instance = item_scene.instantiate() as Item
	item_instance.id = item_id
	item_instance.global_position = world_position

	# Set stack count before _ready applies data
	if stack_count > 1:
		item_instance.stack_count = stack_count

	# Apply per-spawn extras BEFORE add_child so they're set when _ready runs
	# and _apply_item_data can use them (e.g. faction-controlled chest fill).
	if extras.has("controlling_faction"):
		item_instance.controlling_faction = String(extras["controlling_faction"])
	if extras.has("value"):
		item_instance.loot_value = float(extras["value"])
	if extras.has("owner_faction"):
		item_instance.owner_faction = String(extras["owner_faction"])
	if extras.has("owner_uid"):
		item_instance.owner_uid = String(extras["owner_uid"])
	if extras.has("stolen_from"):
		item_instance.stolen_from = String(extras["stolen_from"])
	# Quest-proof provenance. Set before add_child like the rest so _ready ->
	# _apply_item_data sees origin_display_name and doesn't clobber the
	# per-instance name with the generic database one.
	if extras.has("origin") and extras["origin"] is Dictionary:
		item_instance.origin = (extras["origin"] as Dictionary).duplicate(true)
	if extras.has("origin_display_name"):
		item_instance.origin_display_name = String(extras["origin_display_name"])

	add_child(item_instance)
	items_in_scene.append(item_instance)

	# Connect signals
	item_instance.destroyed.connect(_on_item_destroyed)

	return item_instance

# --- Surrender (law/crime Phase 7) ---

var _surrender_button: Button = null
var _surrender_poll_accum: float = 0.0
# Unexplored-fog sweep cadence; set negative by load_map to delay the first
# sweep until the new map's colliders are in the physics space.
var _fog_sweep_accum: float = 0.0
const SURRENDER_RADIUS: float = 800.0

func _setup_surrender_button() -> void:
	_surrender_button = Button.new()
	_surrender_button.name = "SurrenderButton"
	_surrender_button.text = "Surrender"
	_surrender_button.visible = false
	_surrender_button.anchor_left = 0.5
	_surrender_button.anchor_right = 0.5
	_surrender_button.anchor_top = 1.0
	_surrender_button.anchor_bottom = 1.0
	_surrender_button.offset_left = -70.0
	_surrender_button.offset_right = 70.0
	_surrender_button.offset_top = -110.0
	_surrender_button.offset_bottom = -70.0
	_surrender_button.pressed.connect(_on_surrender_pressed)
	$GameUI.add_child(_surrender_button)

## Every living non-party character currently hostile to the party and
## within `radius` of any party member.
func hostile_characters_near_party(radius: float = SURRENDER_RADIUS) -> Array:
	var out: Array = []
	for c in characters_in_scene:
		if not is_instance_valid(c) or c in party_chars:
			continue
		if not c.has_method("is_alive") or not c.is_alive():
			continue
		var ai_node = c.get_node_or_null("AI")
		if ai_node == null:
			continue
		var near_and_hostile: bool = false
		for pc in party_chars:
			if not is_instance_valid(pc):
				continue
			if c.global_position.distance_to(pc.global_position) <= radius and ai_node._is_enemy(pc):
				near_and_hostile = true
				break
		if near_and_hostile:
			out.append(c)
	return out

## Every living, conscious hostile that a party member has in sight RIGHT
## NOW — the same LOS answer _update_npc_los_visibility renders sprites from,
## so nothing here is information the player hasn't been shown. Feeds the
## off-screen threat arrows (UI/OffscreenThreatIndicators.gd).
func hostiles_in_party_los() -> Array:
	var out: Array = []
	for c in characters_in_scene:
		if not is_instance_valid(c) or c in party_chars:
			continue
		if not _npc_was_truly_seen.get(c, false):
			continue
		if not c.has_method("is_alive") or not c.is_alive():
			continue
		var cm = c.get_node_or_null("ConditionManager")
		if cm and cm.has_condition("unconscious"):
			continue
		var ai_node = c.get_node_or_null("AI")
		if ai_node == null:
			continue
		for pc in party_chars:
			if is_instance_valid(pc) and pc.is_alive() and ai_node._is_enemy(pc):
				out.append(c)
				break
	return out

func _setup_threat_indicators() -> void:
	var ThreatIndicators = load("res://UI/OffscreenThreatIndicators.gd")
	var ind = ThreatIndicators.new()
	ind.name = "OffscreenThreatIndicators"
	ind.game = self
	$GameUI.add_child(ind)
	# Bottom of the GameUI stack: panels and dialogue draw over the arrows.
	$GameUI.move_child(ind, 0)

func _update_surrender_button(hostiles: Array = []) -> void:
	if _surrender_button == null:
		return
	_surrender_button.visible = not hostiles.is_empty()

## Seconds with no hostile in range before combat music releases back to the
## map's ambient track. Without this, music flickers every time an enemy
## paces across the radius edge or the last one dies mid-swing.
const COMBAT_MUSIC_RELEASE: float = 6.0

var _combat_music_calm_for: float = COMBAT_MUSIC_RELEASE

func _update_combat_music(hostiles: Array) -> void:
	if hostiles.is_empty():
		_combat_music_calm_for += 0.5
		if _combat_music_calm_for >= COMBAT_MUSIC_RELEASE:
			MusicManager.set_combat(false)
	else:
		_combat_music_calm_for = 0.0
		MusicManager.set_combat(true)

func _on_surrender_pressed() -> void:
	var SurrenderPanel = load("res://UI/SurrenderPanel.gd")
	var panel = SurrenderPanel.new()
	panel.game = self
	$GameUI.add_child(panel)
	if not panel.try_open():
		panel.queue_free()

# --- The named caller (law/crime Phase 7) ---
# The three orphaned to_dict/from_dict pairs happened because nobody ever
# called them. This function's entire job is to be that caller. No disk I/O
# in v1 — but two callers ship with it (the headless round-trip test and the
# F11 debug hotkey), so it cannot rot the way the orphans did. Disk save is
# then FileAccess + JSON.stringify around a tested function.
# v1->v2 rule: additive only; every read via .get(key, default).
func build_save_dict() -> Dictionary:
	save_party_state()
	_save_service_npc_states()
	_capture_item_state()
	return {
		"version": 1,
		"party_state": party_state.duplicate(true),
		"npc_state_per_region": npc_state_per_region.duplicate(true),
		"item_state_per_map": item_state_per_map.duplicate(true),
		"factions": FactionDatabase.standing_to_dict(),
		"conditions_note": "per-character condition state rides inside party/npc snapshots",
		"quests": QuestManager.get_save_data(),
		"training": TrainingManager.get_save_data(),
		"readables": ReadableManager.get_save_data(),
		"triggers": MapTriggerState.fired.duplicate(true),
		"world_state": Globals.world_state.duplicate(true),
		"unlocked_locks": unlocked_locks.duplicate(true),
		"known_services": known_services_per_region.duplicate(true),
		# DowntimeDatabase's header claims this "round-trips with the existing
		# save flow"; it did not, so every 7-day result cooldown reset on load.
		"downtime_recent_events": downtime_recent_events.duplicate(true),
		"days_elapsed": TimeManager.days_elapsed,
		"game_time": TimeManager.game_time,
		"date": [TimeManager.current_day, TimeManager.current_month, TimeManager.current_year],
		"current_map_id": current_map_id,
	}

## A disk load: apply the save, then rebuild its map from it. load_map would
## first snapshot the outgoing live party, service NPCs and world items over
## the state just loaded, so those captures are skipped for this one load.
func load_save(d: Dictionary) -> void:
	apply_save_dict(d)
	_skip_party_save = true
	_skip_unload_capture = true
	load_map(str(d.get("current_map_id", current_map_id)))
	_skip_party_save = false
	_skip_unload_capture = false

## Symmetric restore. Does NOT reload the map — a disk load goes through
## load_save, which calls load_map(d.current_map_id) after applying.
func apply_save_dict(d: Dictionary) -> void:
	party_state = d.get("party_state", party_state).duplicate(true)
	npc_state_per_region = d.get("npc_state_per_region", {}).duplicate(true)
	item_state_per_map = d.get("item_state_per_map", {}).duplicate(true)
	FactionDatabase.standing_from_dict(d.get("factions", {}))
	QuestManager.load_save_data(d.get("quests", {}))
	TrainingManager.load_save_data(d.get("training", {}))
	ReadableManager.load_save_data(d.get("readables", {}))
	MapTriggerState.fired = d.get("triggers", {}).duplicate(true)
	Globals.world_state = d.get("world_state", {}).duplicate(true)
	unlocked_locks = d.get("unlocked_locks", {}).duplicate(true)
	known_services_per_region = d.get("known_services", {}).duplicate(true)
	downtime_recent_events = d.get("downtime_recent_events", {}).duplicate(true)
	TimeManager.days_elapsed = int(d.get("days_elapsed", TimeManager.days_elapsed))
	TimeManager.game_time = float(d.get("game_time", TimeManager.game_time))
	var date: Array = d.get("date", [])
	if date.size() == 3:
		# Assign quietly — set_date emits date_changed, whose four listeners
		# perform DAILY bookkeeping (quest day counters, standing decay,
		# weather rolls). Replaying those on load would double-apply a day.
		TimeManager.current_day = int(date[0])
		TimeManager.current_month = int(date[1])
		TimeManager.current_year = int(date[2])
		TimeManager.is_yearturn = int(date[1]) == 0

# --- World-item persistence (law/crime Phase 7) ---

func _capture_item_state() -> void:
	if current_map_id.is_empty():
		return
	var records: Array = []
	for it in items_in_scene:
		if not is_instance_valid(it):
			continue
		var record: Dictionary = {
			"id": str(it.id),
			"x": it.global_position.x,
			"y": it.global_position.y,
			"stack_count": int(it.stack_count) if ("stack_count" in it) else 1,
			"owner_faction": str(it.owner_faction),
			"owner_uid": str(it.owner_uid),
			"stolen_from": str(it.stolen_from),
			"controlling_faction": str(it.controlling_faction),
			"loot_value": float(it.loot_value),
		}
		# Quest-proof provenance survives a map unload, so a bounty head left on
		# the floor is still that victim's head when you come back for it.
		if it.origin is Dictionary and not (it.origin as Dictionary).is_empty():
			record["origin"] = (it.origin as Dictionary).duplicate(true)
		if str(it.origin_display_name) != "":
			record["origin_display_name"] = str(it.origin_display_name)
		if it.contents is Array:
			record["contents"] = (it.contents as Array).duplicate(true)
		records.append(record)
	item_state_per_map[current_map_id] = records

func _restore_item_state() -> void:
	if not item_state_per_map.has(current_map_id):
		return
	# Wholesale replace: drop the authored spawns, rebuild the visited state.
	for it in items_in_scene:
		if is_instance_valid(it):
			GridManager.unregister_object(GridManager.world_to_map(it.global_position), it)
			it.queue_free()
	items_in_scene.clear()
	for record in item_state_per_map[current_map_id]:
		var extras: Dictionary = {}
		for key in ["owner_faction", "owner_uid", "stolen_from", "controlling_faction"]:
			var value: String = str(record.get(key, ""))
			if not value.is_empty():
				extras[key] = value
		var loot_value: float = float(record.get("loot_value", -1.0))
		if loot_value >= 0.0:
			extras["value"] = loot_value
		if record.has("origin") and record["origin"] is Dictionary:
			extras["origin"] = (record["origin"] as Dictionary).duplicate(true)
		if record.has("origin_display_name"):
			extras["origin_display_name"] = str(record["origin_display_name"])
		var item = create_item(str(record.get("id", "")),
			Vector2(float(record.get("x", 0.0)), float(record.get("y", 0.0))), 1, extras)
		if item == null:
			continue
		# THE ORDERING TRAP: _apply_item_data (inside create_item's add_child)
		# auto-fills a faction chest whose contents are empty. Restore must
		# run AFTER create_item returns and must OVERWRITE contents, never
		# merge — otherwise every emptied chest silently refills from the
		# loot table on revisit and theft is pointless.
		if record.has("contents"):
			item.contents = (record["contents"] as Array).duplicate(true)
		var stack_count: int = int(record.get("stack_count", 1))
		if stack_count > 1 and ("stack_count" in item):
			item.stack_count = stack_count
			if item.has_method("_update_stack_label"):
				item._update_stack_label()

# D6: everything a faction owns, derived by scan — never indexed. The three
# sites mutating items_in_scene already disagree (create_item appends,
# _on_item_destroyed erases via signal, ai.pickup_item erases directly
# without the signal), so an index would leak stale entries on day one.
# Cost is irrelevant at shipped item counts. Returns a mixed Array: world
# Item nodes (owner_faction match) + party inventory entry Dictionaries and
# stowed WeaponShapes (stolen_from match — still theirs by right).
func items_owned_by(faction_id: String) -> Array:
	var out: Array = []
	if faction_id.is_empty():
		return out
	for it in items_in_scene:
		if is_instance_valid(it) and ("owner_faction" in it) and it.owner_faction == faction_id:
			out.append(it)
	for c in party_chars:
		if not is_instance_valid(c) or not ("inventory" in c) or c.inventory == null:
			continue
		for entry in c.inventory.items:
			if entry is Dictionary and str(entry.get("stolen_from", "")) == faction_id:
				out.append(entry)
		for w in c.inventory.stowed_items:
			if w != null and ("stolen_from" in w) and w.stolen_from == faction_id:
				out.append(w)
	return out

func _on_item_destroyed(item: Item):
	# Remove from tracking
	items_in_scene.erase(item)

	# Spawn resource items from the destroyed item
	if item.resources.is_empty():
		return

	var spawn_offset = 0
	for resource_id in item.resources:
		var amount = int(item.resources[resource_id])
		if amount <= 0:
			continue

		# Look up the resource in the database to figure out stack sizes
		var resource_data = _lookup_any_item(resource_id)
		var max_stack = int(resource_data.get("max_stack_size", 100)) if resource_data else 100

		# Spawn in stacks up to max_stack_size
		var remaining = amount
		while remaining > 0:
			var this_stack = mini(remaining, max_stack)
			var offset = Vector2(spawn_offset * 12, 0).rotated(randf() * TAU)
			var resource_item = create_item(resource_id, item.global_position + offset, this_stack)
			remaining -= this_stack
			spawn_offset += 1

func _lookup_any_item(item_id: String) -> Dictionary:
	"""Look up item data from any category in the database."""
	var item_key = Globals.name_to_id(item_id)
	if ItemDatabase.weapons.has(item_key):
		return ItemDatabase.weapons[item_key]
	if ItemDatabase.equipment.has(item_key):
		return ItemDatabase.equipment[item_key]
	if ItemDatabase.items.has(item_key):
		return ItemDatabase.items[item_key]
	# Try raw id
	if ItemDatabase.items.has(item_id):
		return ItemDatabase.items[item_id]
	return {}
	

func create_structure(structure_id: String, world_position: Vector2) -> Structure:
	"""Create a structure by its ID and place it in the world."""
	var structure_instance = structure_scene.instantiate() as Structure
	structure_instance.structure_id = structure_id
	structure_instance.global_position = world_position

	add_child(structure_instance)
	structures_in_scene.append(structure_instance)
	# a structure raised mid-map (conjured wall, placed barricade) changes the
	# fuel map exactly like a destroyed one: CellFire indexes structures by
	# tile and only re-sweeps on invalidate_fuel
	if surface_manager and surface_manager.cell_fire and is_instance_valid(surface_manager.cell_fire):
		surface_manager.cell_fire.invalidate_fuel()

	structure_instance.destroyed.connect(_on_structure_destroyed)

	#register to grid
	#make sure loader uses
	return structure_instance

func _on_structure_destroyed(structure: Structure, world_pos: Vector2):
	structures_in_scene.erase(structure)

	# a wall/tree removed by ANY means (melee, ranged, bomb) changes the fuel map:
	# without this, cell fire keeps the destroyed structure's cells as a phantom
	# firebreak (the fuel cache only self-invalidates on fire deaths otherwise)
	if surface_manager and surface_manager.cell_fire and is_instance_valid(surface_manager.cell_fire):
		surface_manager.cell_fire.invalidate_fuel()
	# a destroyed wall un-refcounts its obstacle tiles -> fluid can now flow
	# through the breach, so drop the cell fluid's cached edge blocking
	if fluid_manager and fluid_manager.cell_fluid and is_instance_valid(fluid_manager.cell_fluid):
		fluid_manager.cell_fluid.invalidate_edges()

	if structure.resources.is_empty():
		return

	var spawn_offset = 0
	for resource_id in structure.resources:
		var amount = int(structure.resources[resource_id])
		if amount <= 0:
			continue

		var resource_data = _lookup_any_item(resource_id)
		var max_stack = int(resource_data.get("max_stack_size", 100)) if resource_data else 100

		var remaining = amount
		while remaining > 0:
			var this_stack = mini(remaining, max_stack)
			var offset = Vector2(spawn_offset * 12, 0).rotated(randf() * TAU)
			create_item(resource_id, world_pos + offset, this_stack)
			remaining -= this_stack
			spawn_offset += 1

func _toggle_npc_los_cones() -> void:
	"""Show or hide NPC line-of-sight cones based on stealth mode."""
	for character in characters_in_scene:
		if not is_instance_valid(character):
			continue
		if character in party_chars:
			continue
		_sync_npc_cones(character)

## Whether an NPC's sight cone shows: stealth mode on, off the world map
## (nobody sneaks there, and every other stealth readout hides there too), the
## NPC alive (a corpse sees nothing), and not drawn only by a hearing pulse.
## The pulse's low alpha is modulate, which Light2D ignores, so a glimpsed cone
## would draw at full strength and give away an unseen onlooker's facing and
## range. An NPC hidden outright hides its cone with it, so that case needs
## nothing here.
func _npc_cones_shown(npc) -> bool:
	return stealth_mode and is_instance_valid(npc) and npc.is_alive() \
			and not current_map_data.get("is_world_map", false) \
			and not _npc_only_glimpsed(npc)

## Drawn only by a hearing pulse: pulsing and not truly seen.
func _npc_only_glimpsed(npc) -> bool:
	return _npc_pulse_remaining.has(npc) and not _npc_was_truly_seen.get(npc, false)

## Apply _npc_cones_shown to every sight cone the NPC carries: the red one and
## stealth mode's pink elevated-surface twin (sync_npc_elevated_cone also
## follows the red one each frame).
func _sync_npc_cones(npc) -> void:
	var show_cones: bool = _npc_cones_shown(npc)
	for cone_name in ["NPCLineOfSight", "NPCLineOfSightHigh"]:
		var cone = npc.get_node_or_null(cone_name)
		if cone and cone.visible != show_cones:
			cone.visible = show_cones

## The one way to switch stealth mode (the C key). While it is on, party
## members sneak (ProceduralCharacter.is_sneaking: quieter footsteps, slower
## walk, noticed only inside an onlooker's sight cone), NPC sight cones show,
## and the STEALTH badge and StealthOverlay follow stealth_mode_changed.
func set_stealth_mode(active: bool) -> void:
	if stealth_mode == active:
		return
	stealth_mode = active
	_toggle_npc_los_cones()
	if active:
		sync_npc_elevated_cones()
		if current_map_data.get("is_world_map", false):
			GameLog.add_entry("Stealth mode [b]on[/b]. Nobody sneaks on the world map; the party sneaks once it arrives somewhere.")
		else:
			GameLog.add_entry(("Stealth mode [b]on[/b]: the party sneaks (footsteps %d%% as loud, %d%% walking pace) and is noticed only inside an onlooker's sight cone, even up close. "
				+ "Cones show what onlookers see (pink: raised walkways they can see onto), and an eye marks a party member an onlooker you can see has in view. "
				+ "Relaxed onlookers who spot you sneaking become wary. Left-clicking someone now attacks them rather than talking; right-click for Talk.") % [
				roundi(ProceduralCharacter.SNEAK_NOISE_MULT * 100.0), roundi(ProceduralCharacter.SNEAK_SPEED_MULT * 100.0)])
	else:
		GameLog.add_entry("Stealth mode [b]off[/b].")
	stealth_mode_changed.emit(active)

## Give every NPC that has a sight cone its elevated-surface cone (made on
## first use) and match it to the red one. Called when stealth mode turns on
## and periodically by StealthOverlay while it is on. None on the world map.
func sync_npc_elevated_cones() -> void:
	if current_map_data.get("is_world_map", false):
		return
	for character in characters_in_scene:
		if not is_instance_valid(character) or character in party_chars:
			continue
		if not character.has_node("NPCLineOfSight"):
			continue
		if not character.has_node("NPCLineOfSightHigh"):
			_add_npc_elevated_sight_light(character)
		sync_npc_elevated_cone(character)

## Stealth mode's second, pink cone for an NPC. The red cone of a ground
## viewer is shadowed by every wall, so it drew battlements and decks as
## unseen even though GridManager.sight_line_clear lets the NPC see someone
## standing up there (the target's raised eye tops the wall). This cone is
## shadowed only by tall occluders (SIGHT_MASK_HIGH) and lights only walkway
## art (CollisionLayers.ELEVATED_SURFACE_LIGHT, set by MapLoader on deck art),
## so a walkway glows pink where standing on it would be seen. (Not amber:
## amber is the Suspicious cone tint and the outcry fuse.)
const ELEVATED_CONE_COLOR := Color(1.0, 0.4, 0.65)
func _add_npc_elevated_sight_light(npc: ProceduralCharacter) -> PointLight2D:
	var light := PointLight2D.new()
	light.name = "NPCLineOfSightHigh"
	_fit_sight_light(light, npc)
	light.energy = 0.35
	light.color = ELEVATED_CONE_COLOR
	light.rotation_degrees = -90
	light.shadow_enabled = true
	light.shadow_item_cull_mask = CollisionLayers.SIGHT_MASK_HIGH
	light.range_item_cull_mask = CollisionLayers.ELEVATED_SURFACE_LIGHT
	light.z_index = 102
	npc.add_child(light)
	sync_npc_elevated_cone(npc)
	return light

## Keep an NPC's elevated-surface cone the same wedge, radius and visibility
## as its red one (whatever rule shows or hides the red one), and lit only
## while the NPC stands on the ground (from a walkway the red cone already
## sees onto other walkways). ProceduralCharacter._refresh_elevation calls it
## when the NPC climbs; _update_sight_cones every frame.
func sync_npc_elevated_cone(npc) -> void:
	if npc == null or not is_instance_valid(npc):
		return
	var main_light := npc.get_node_or_null("NPCLineOfSight") as PointLight2D
	var high := npc.get_node_or_null("NPCLineOfSightHigh") as PointLight2D
	if main_light == null or high == null:
		return
	if high.texture != main_light.texture:
		high.texture = main_light.texture
	if not is_equal_approx(high.texture_scale, main_light.texture_scale):
		high.texture_scale = main_light.texture_scale
	high.rotation = main_light.rotation
	if high.visible != main_light.visible:
		high.visible = main_light.visible
	high.enabled = main_light.enabled and npc.get_elevation() < 1.0

# ===== Hearing visibility pulse =====
# When a party member can HEAR an NPC (but doesn't see them), the NPC briefly
# flashes at low alpha so the player gets a momentary fix on their location.
# Tuned to feel like a ghost glimpse, not a solid reveal.
const PULSE_ALPHA: float = 0.45
const PULSE_DURATION: float = 1.0
# Fraction of PULSE_DURATION the alpha holds near PULSE_ALPHA before decaying.
# Non-linear: plateau then cubic falloff (see _hearing_pulse_curve).
const PULSE_PLATEAU_FRAC: float = 0.35

# NPC -> seconds remaining on the most recent hearing pulse.
var _npc_pulse_remaining: Dictionary = {}
# NPC -> was the NPC truly seen on the last LOS pass (for service discovery
# tracking). Replaces reading npc.visible, which is now used for the pulse.
var _npc_was_truly_seen: Dictionary = {}
# NPC -> true if this NPC has EVER been directly seen by a party member this
# map session. First-contact hearing produces a radar ping at the heard
# position; subsequent hearings (once seen at least once) produce the alpha
# sprite pulse. Cleared on map load to restore dread on revisits.
var _npc_ever_seen: Dictionary = {}
# NPC -> cooldown seconds remaining before another radar ping can spawn for
# them. Stops a walking unseen enemy from spawning a ping every footstep.
var _npc_radar_cooldown: Dictionary = {}
const RADAR_PING_COOLDOWN: float = 0.9


# Preloaded scene for the first-contact radar ping. Loaded lazily on first
# use so editor reloads don't crash if the file is missing during dev.
var _radar_ping_scene: PackedScene = null


# Called by HearingManager when any party member hears a sound this NPC made.
# Branches on whether the player has ever directly seen this NPC:
#   - Seen before: restart the alpha sprite pulse (NPC is briefly visible).
#   - Never seen:  spawn a radar ping VFX at the heard position. The sprite
#                  stays invisible — you only know *something* is there.
func trigger_hearing_pulse(npc) -> void:
	if not is_instance_valid(npc):
		return
	if _npc_ever_seen.get(npc, false):
		_npc_pulse_remaining[npc] = PULSE_DURATION
	else:
		# Throttle: each NPC can spawn at most one ping per RADAR_PING_COOLDOWN
		# seconds. Otherwise a walking enemy floods the screen with pings.
		var cd: float = _npc_radar_cooldown.get(npc, 0.0)
		if cd > 0.0:
			return
		_npc_radar_cooldown[npc] = RADAR_PING_COOLDOWN
		_spawn_radar_ping(npc.global_position)


func _spawn_radar_ping(world_pos: Vector2) -> void:
	if _radar_ping_scene == null:
		var path := "res://vfx/radar_ping.tscn"
		if ResourceLoader.exists(path):
			_radar_ping_scene = load(path)
	if _radar_ping_scene == null:
		return
	var ping: Node2D = _radar_ping_scene.instantiate()
	add_child(ping)
	ping.global_position = world_pos
	if ping.has_method("play"):
		ping.play()
	# Soft sonar-blip sound to reinforce the visual ping. Mixed quiet so it
	# reads as a UI feedback layer, not a world event.
	if SfxManager.sound_library.has("radar_ping"):
		SfxManager.play("radar_ping", world_pos, Vector2(0.95, 1.05), -10.0)


# Subscribed to every spawned character's `damaged_by` signal (see
# `_spawn_character`). Broadcasts a "witnessed attack" event to all OTHER
# characters that currently have LOS on the victim, so AT_EASE civilians wake
# up. Bumps to just past the SEARCHING threshold so witnesses immediately
# start heading toward the victim — they saw violence, they're not just
# vaguely suspicious.
func _on_character_damaged(attacker, location: Vector2, _total_damage: float, victim: ProceduralCharacter) -> void:
	if not is_instance_valid(victim):
		return
	# Law: assault/murder gate on damage APPLICATION, not the swing — a miss
	# is not assault. Lethality derives from health here: take_damage clamps
	# current_health BEFORE emitting damaged_by, so a killing blow already
	# reads victim.is_alive() == false (murder). Debounce + self-defence live
	# in CrimeManager/LawDatabase, not here. If the attack IS a crime, the
	# witness fan-out inside report() starts outcry fuses on top of the
	# generic wake below.
	# A condition's damage tick (Burning, Corroding from a caster's spell
	# weather...) carries its applier as `attacker` but is no fresh blow: the
	# hit that applied it already raised the alarm. Ticks reach the law only
	# when they kill or open a new spell of harm (weather has no hit of its
	# own), and never wake bystanders or call the party (see alert_party).
	var dot_tick: bool = victim._condition_tick_damage
	if attacker != null and is_instance_valid(attacker) and attacker != victim:
		if not dot_tick or _dot_tick_reportable(attacker, victim):
			CrimeManager.report(attacker, "attack", CrimeManager.attack_payload(attacker, victim))
		victim.set_meta("dot_harm_by_%d" % attacker.get_instance_id(), TimeManager.absolute_time())
	if dot_tick:
		return
	# The victim's own AI wake-up is handled in ai.gd via the same signal —
	# this loop only wakes bystanders (legal fights startle people too).
	# Enumeration is shared with the crime pipeline: CrimeManager.witnesses_of
	# already skips the actor, party members, and the dead, and its LOS is
	# elevation-aware (a rooftop attack is visible from the street now).
	var victim_elev: float = victim.get_elevation() if victim.has_method("get_elevation") else 0.0
	for entry in CrimeManager.witnesses_of(victim.global_position, victim_elev, attacker):
		var witness = entry["witness"]
		if witness == victim:
			continue
		var ai_node = witness.get_node_or_null("AI")
		if not ai_node or not ai_node.has_method("wake_from_at_ease"):
			continue
		# 65 = SEARCHING threshold (60) + a bit; witnesses move out
		# immediately, but the source identity still has to be confirmed via
		# LOS for HOSTILE (handled by existing target acquisition).
		ai_node.wake_from_at_ease(65.0, location)
	# Party under fire (either side of the blow): call it out to the whole
	# party. This is the ONLY player-side fan-out that fires when the SELECTED
	# character opens a fight — their AI is dormant (AI_enabled false), so the
	# ai.gd _acquire_target hook never runs for them. witnesses_of skips party
	# on purpose (crime pipeline), hence the separate channel here.
	if attacker != null and is_instance_valid(attacker) \
			and attacker in party_chars and attacker != victim:
		alert_party(victim.global_position)
	elif victim in party_chars and attacker != null and is_instance_valid(attacker):
		alert_party(attacker.global_position)


## Seconds without harm from the same attacker after which their next damage
## tick on that victim is a fresh offence again. Longer than any damage tick's
## interval (Chilled's 6 s), so one condition's ticks are a single act.
const DOT_HARM_GAP: float = 10.0

## Whether a condition tick from `attacker` should go to the law: a killing
## tick (murder), or the first harm from them in DOT_HARM_GAP. A companion
## caught in the party's own weather or flames is not an assault.
func _dot_tick_reportable(attacker, victim) -> bool:
	if attacker in party_chars and victim in party_chars:
		return false
	if not victim.is_alive():
		return true
	var last: float = float(victim.get_meta("dot_harm_by_%d" % attacker.get_instance_id(), -1.0e12))
	return TimeManager.absolute_time() - last > DOT_HARM_GAP


# Shared LOS check helper — delegates to the canonical witness-LOS wrapper on
# CrimeManager (elevation-aware, blinded/unconscious-aware). Kept for the
# internal call sites that predate it.
func _has_visual_los(from_char: ProceduralCharacter, target_pos: Vector2, target_elev: float = 0.0) -> bool:
	return CrimeManager.has_visual_los(from_char, target_pos, target_elev)


# ===== VIEW LAYER helpers =====

# The "high layer" is an elevation slice, not just on_roof: battlement decks
# (walk_elev >= 1 story) live up there too — same tiering the sight-cone light
# masks already use. Deck art is painted into the ground PNG, so decks need no
# cover quads; only the LAYER of the viewer matters for what gets hidden.
func _char_on_high_layer(c) -> bool:
	if c == null or not is_instance_valid(c):
		return false
	if "on_roof" in c and c.on_roof:
		return true
	if c.has_method("get_elevation"):
		return c.get_elevation() >= 1.0
	return false


func _set_roof_view(on: bool) -> void:
	if roof_view == on:
		return
	roof_view = on
	if roof_layer != null and is_instance_valid(roof_layer):
		roof_layer.visible = on
	# NPC visibility re-resolves in the per-frame LOS sweep; party members in
	# _apply_party_layer_visibility below.


# Ctrl+scroll layer browse (PlayerCamera routes the wheel here when Ctrl is
# held; plain scroll stays zoom). up=true browses toward the roof slice.
# No-op on maps without roof data — a pinned override there would only make
# hidden-state confusion with nothing visible to explain it.
func step_view_layer(up: bool) -> void:
	if GridManager.roof_elevations.is_empty():
		return
	roof_view_override = 1 if up else 0


# Party members bypass the NPC LOS sweep (always shown), so the ground-view
# rule "roof-walkers are seen only on the higher layer" needs its own pass.
# Meta-guarded so we only flip visibility WE changed — anything else that
# hides a party member (future invisibility etc.) is left alone.
func _apply_party_layer_visibility() -> void:
	for pc in party_chars:
		if not is_instance_valid(pc):
			continue
		var should_hide: bool = (not roof_view) and _char_on_high_layer(pc)
		if should_hide != bool(pc.get_meta("layer_hidden", false)):
			pc.set_meta("layer_hidden", should_hide)
			pc.visible = not should_hide


# Party call-out: raise every party member toward a fight, through walls and
# across the map (they shout — the LOS-gated ally share never reached a member
# standing inside a building). Raise-to-at-least via wake_from_at_ease, so it
# never LOWERS anyone; members already fighting their own target are left
# alone — their firsthand information beats a second-hand call-out. 65 puts
# targetless members over the SEARCHING promotion gate (60): they physically
# move toward the call and confirm by their own eyes en route. Callers are
# one-shot events (target acquisition, damage), never per-tick loops — a
# per-tick location write is the decay-holiday bug (see ai.gd ally share).
func alert_party(location: Vector2) -> void:
	for pc in party_chars:
		if not is_instance_valid(pc) or not pc.has_method("is_alive") or not pc.is_alive():
			continue
		var pai = pc.get_node_or_null("AI")
		if pai == null or not pai.has_method("wake_from_at_ease"):
			continue
		if pai.current_target != null:
			continue
		pai.wake_from_at_ease(65.0, location)


# Non-linear pulse curve. t in [0, 1] where 0 = fresh pulse, 1 = expired.
# Returns alpha multiplier (0..1) applied to PULSE_ALPHA.
# Holds near 1.0 for PULSE_PLATEAU_FRAC of the duration, then cubic decay
# to 0.0 — visible long enough to register, then fades fast.
func _hearing_pulse_curve(t: float) -> float:
	t = clamp(t, 0.0, 1.0)
	if t < PULSE_PLATEAU_FRAC:
		return 1.0
	var decay_t: float = (t - PULSE_PLATEAU_FRAC) / (1.0 - PULSE_PLATEAU_FRAC)
	return pow(1.0 - decay_t, 3.0)


func _tick_hearing_pulses(delta: float) -> void:
	# Decay radar ping cooldowns alongside sprite-pulse timers. Cheap and
	# bounded by the number of NPCs with active cooldowns.
	if not _npc_radar_cooldown.is_empty():
		var radar_expired: Array = []
		for npc in _npc_radar_cooldown.keys():
			if not is_instance_valid(npc):
				radar_expired.append(npc)
				continue
			var v: float = _npc_radar_cooldown[npc] - delta
			if v <= 0.0:
				radar_expired.append(npc)
			else:
				_npc_radar_cooldown[npc] = v
		for npc in radar_expired:
			_npc_radar_cooldown.erase(npc)

	if _npc_pulse_remaining.is_empty():
		return
	var expired: Array = []
	for npc in _npc_pulse_remaining.keys():
		if not is_instance_valid(npc):
			expired.append(npc)
			continue
		var t: float = _npc_pulse_remaining[npc] - delta
		if t <= 0.0:
			expired.append(npc)
		else:
			_npc_pulse_remaining[npc] = t
	for npc in expired:
		_npc_pulse_remaining.erase(npc)
		# Back to hidden outright: the cone returns to its rule (it hides with
		# the NPC until the NPC is seen).
		if is_instance_valid(npc):
			_sync_npc_cones(npc)


func _update_npc_los_visibility() -> void:
	"""NPCs are only visible when inside a party member's sight cone
	AND the line between them isn't blocked by a vision_blocker (layer 3).
	Unseen NPCs may still flash briefly via the hearing pulse system.
	NPC LOS lights are children of the NPC, so they hide when the NPC hides."""
	for npc in characters_in_scene:
		if not is_instance_valid(npc):
			continue
		if npc in party_chars:
			continue
		var seen = _is_character_visible_to_party(npc)

		var was_truly_seen: bool = _npc_was_truly_seen.get(npc, false)
		_npc_was_truly_seen[npc] = seen

		if seen:
			# Direct line of sight overrides any pulse.
			var was_pulsing: bool = _npc_pulse_remaining.has(npc)
			_npc_pulse_remaining.erase(npc)
			if was_pulsing:
				_sync_npc_cones(npc)   # spotted mid-pulse: its cone comes back
			# Mark as "ever seen" for the radar-vs-sprite-pulse branch in
			# trigger_hearing_pulse. Persists for the map session.
			_npc_ever_seen[npc] = true
			# Discovery: first time we lay eyes on a service NPC, mark them
			# known so they appear in the TownServicesPanel even after leaving.
			if not was_truly_seen:
				mark_service_seen(npc)
			# View-layer slice: in ground view, roof-walkers exist only on the
			# higher layer — LOS still CONFIRMS them (alerts, discovery, AI all
			# key on `seen` above), but the render stays on the current slice.
			# In roof view nothing extra hides: the opaque roof quads already
			# cover interior characters by z, and open-ground NPCs remain
			# legitimately visible from above.
			if not roof_view and _char_on_high_layer(npc):
				npc.visible = false
				npc.modulate.a = 0.0
			else:
				npc.visible = true
				npc.modulate.a = 1.0
		elif _npc_pulse_remaining.has(npc):
			var t_remaining: float = _npc_pulse_remaining[npc]
			var t_norm: float = clamp(1.0 - (t_remaining / PULSE_DURATION), 0.0, 1.0)
			var alpha: float = _hearing_pulse_curve(t_norm) * PULSE_ALPHA
			npc.visible = true
			npc.modulate.a = alpha
			# Light2D ignores modulate: an unseen onlooker's cone would flash at
			# full strength, so it stays dark while only the pulse draws it.
			_sync_npc_cones(npc)
		else:
			npc.visible = false
			npc.modulate.a = 0.0

func _sight_line_clear(from_pos: Vector2, to_pos: Vector2, viewer_elev: float = 0.0, target_elev: float = 0.0) -> bool:
	var viewport := get_viewport()
	if not viewport or not viewport.world_2d:
		return true
	return GridManager.sight_line_clear(viewport.world_2d.direct_space_state, from_pos, to_pos, viewer_elev, target_elev)


func _is_position_visible_to_party(target_pos: Vector2, target_elev: float = 0.0, range_mult: float = 1.0) -> bool:
	"""True if any living, sighted party member can see the position: in
	sight range (weather and fog included), inside their FOV cone, and on a
	clear LOS line (ProceduralCharacter.can_see_point, the same test AI
	detection and crime witnesses use). range_mult scales the range (a
	target's visibility)."""
	for ally in party_chars:
		if not is_instance_valid(ally):
			continue
		if ally.can_see_point(target_pos, target_elev, range_mult):
			return true
	return false


## The party-visibility rule for a character: some party member sees its
## position at its elevation, with its visibility scaling their range.
func _is_character_visible_to_party(c) -> bool:
	var elev: float = c.get_elevation() if c.has_method("get_elevation") else 0.0
	var vis: float = c.effective_visibility() if c.has_method("effective_visibility") else 1.0
	return _is_position_visible_to_party(c.global_position, elev, vis)


func _update_item_los_visibility() -> void:
	"""Items follow the same visibility rule as NPCs."""
	for item in items_in_scene:
		if not is_instance_valid(item):
			continue
		item.visible = _is_position_visible_to_party(item.global_position)


## Environmental multiplier on sight range at a world position: the map's
## weather (visibility_modifier) times the densest fog there.
## ProceduralCharacter.get_sight_range_px multiplies it in. 1.0 = clear; it
## never exceeds 1.0 (can_see_point bounds range by the bare stat first).
func get_sight_multiplier_at(world_pos: Vector2) -> float:
	return _weather_vis_mult * get_fog_sight_mult_at(world_pos)


## Whether the party can see `c` right now, by line of sight. Party members
## always count. An NPC gets this frame's answer from _update_npc_los_visibility,
## i.e. _is_character_visible_to_party: some living, sighted party member has
## it in range (weather, fog at either end, its visibility), inside their FOV
## cone, on a clear elevation-aware sight line; a hearing pulse doesn't count
## as seen. That pass is frozen while paused (nothing can move), so the answer
## holds through planning. It is the LOS answer, not "drawn now": in ground
## view a seen roof-walker is still hidden (check c.visible for that). Anything
## that pass doesn't cover (items, structures, a character spawned this frame
## or no longer in characters_in_scene) gets the same test directly. Corpses
## in view count as seen; check is_alive() if that matters.
func is_seen_by_party(c) -> bool:
	if c == null or not is_instance_valid(c):
		return false
	if c in party_chars:
		return true
	if _npc_was_truly_seen.has(c) and c in characters_in_scene:
		return bool(_npc_was_truly_seen[c])
	if not (c is Node2D):
		return false
	if c is ProceduralCharacter:
		return _is_character_visible_to_party(c)
	return _is_position_visible_to_party(c.global_position)

func _process(delta: float) -> void:
	# Update clash cooldowns. Combat collisions are now driven by the
	# Area2D weapon hitbox on each WeaponShape (data/weapon_shape.gd) —
	# no per-frame iteration here.
	if not PauseManager.is_paused:
		var to_remove = []
		for key in clash_cooldowns:
			clash_cooldowns[key] -= delta
			if clash_cooldowns[key] <= 0:
				to_remove.append(key)
		for key in to_remove:
			clash_cooldowns.erase(key)
	# Tick fog effects
		if fog_manager:
			fog_manager.update_fogs(delta, characters_in_scene)
		# Tick fluid condition effects
		if fluid_manager:
			fluid_manager.update_fluid_conditions(delta, characters_in_scene)
			fluid_manager.update_fluid_tick(delta)
		if surface_manager:
			surface_manager.update_surfaces(delta, characters_in_scene, self)
		# Weather that corrodes or chills anyone out in the open; spell
		# weather running out.
		_tick_weather_conditions(delta)
		_tick_forced_weather(delta)
		# Hearing-pulse decay and the party LOS sweeps only run unpaused —
		# they are the most raycast-heavy per-frame work we do, and nothing
		# may change LOS during tactical pause: characters are frozen and
		# Door.interact refuses while paused. If some future feature moves
		# things mid-pause, it must trigger these sweeps itself.
		_tick_hearing_pulses(delta)
		_update_npc_los_visibility()
		_update_item_los_visibility()
		# Unexplored-fog reveal sweep. Slower cadence than the per-frame LOS
		# sweeps above and ray-budgeted inside ExplorationManager; frozen with
		# them during pause (LOS cannot change while paused). The accumulator
		# starts negative on map load so the first sweep waits for physics to
		# sync the new map's wall colliders.
		_fog_sweep_accum += delta
		if _fog_sweep_accum >= ExplorationManager.SWEEP_INTERVAL:
			_fog_sweep_accum = 0.0
			var fog_vp := get_viewport()
			if fog_vp and fog_vp.world_2d:
				ExplorationManager.sweep(party_chars, fog_vp.world_2d.direct_space_state)
		# Surrender button visibility and combat music, polled at 2 Hz off the
		# same hostility sweep.
		_surrender_poll_accum += delta
		if _surrender_poll_accum >= 0.5:
			_surrender_poll_accum = 0.0
			var hostiles: Array = hostile_characters_near_party()
			_update_surrender_button(hostiles)
			_update_combat_music(hostiles)
	# Keep drawn cones equal to real sight, paused too (the party plans while
	# paused): Perceptive, Blinded, weather and fog show at once.
	_update_sight_cones()
	# Update all selection indicators
	for character in selection_indicators.keys():
		if is_instance_valid(character):
			selection_indicators[character].global_position = character.global_position
			selection_indicators[character].visible = PauseManager.is_paused
		else:
			selection_indicators[character].queue_free()
			selection_indicators.erase(character)
	# Camera follows primary selected character (unless user is WASD-panning)
	if primary_selected and is_instance_valid(primary_selected) and player_camera \
			and not player_camera.manual_pan_active:
		player_camera.global_position = player_camera.global_position.lerp(
			primary_selected.global_position, 5.0 * delta)
	# View layer follows the primary selection unless the player is browsing
	# with Ctrl+scroll: climb a roof and the view jumps to the roof slice,
	# drop down and interiors come back. A CHANGE in the auto answer reclaims
	# the view from any manual override.
	var auto_roof := _char_on_high_layer(primary_selected)
	if auto_roof != _roof_view_auto:
		_roof_view_auto = auto_roof
		roof_view_override = -1
	_set_roof_view(auto_roof if roof_view_override < 0 else roof_view_override == 1)
	_apply_party_layer_visibility()
	# Toggle warp hover labels by polling — Area2D mouse_entered/exited is
	# unreliable when overlapping pickable areas exist (characters, items).
	_update_warp_hover_labels()
	# On the world map, reveal city warps only when the banner unit is near.
	if current_map_data.get("is_world_map", false):
		_update_world_warp_reveal()
		_tick_banner_party_conditions(delta)

func _update_warp_hover_labels() -> void:
	# Game.gd extends Node, not Node2D, so get_global_mouse_position() isn't
	# available here. Compute world-space mouse position via the viewport's
	# canvas transform instead.
	var viewport := get_viewport()
	var mouse_pos: Vector2 = viewport.get_canvas_transform().affine_inverse() * viewport.get_mouse_position()
	for area in warp_zones:
		if not is_instance_valid(area):
			continue
		var hover_label: Label = area.get_node_or_null("HoverLabel")
		if hover_label == null:
			continue
		var shape_node: CollisionShape2D = null
		for child in area.get_children():
			if child is CollisionShape2D:
				shape_node = child
				break
		if shape_node == null or not (shape_node.shape is RectangleShape2D):
			hover_label.visible = false
			continue
		var rect_size: Vector2 = (shape_node.shape as RectangleShape2D).size
		var local: Vector2 = area.to_local(mouse_pos) - shape_node.position
		var inside: bool = absf(local.x) <= rect_size.x * 0.5 and absf(local.y) <= rect_size.y * 0.5
		hover_label.visible = inside


# Weapon trait keys are authored capitalised in Items.json ("Melee", "Ranged",
# "Metal", ...) and copied verbatim into WeaponShape.traits, but both STR-bonus
# call sites used to test for lowercase "melee". The check never matched, so
# STRENGTH CONTRIBUTED NOTHING to armed melee damage — only to unarmed strikes.
# Match case-insensitively so the damage table can be authored assuming the
# +STR/10 term actually lands.
func _weapon_is_melee(weapon) -> bool:
	if weapon == null or not weapon.get("traits"):
		return false
	for key in weapon.traits.keys():
		if String(key).to_lower() == "melee":
			return true
	return false


# Attacker-side damage modifiers. All three of these were recomputed from
# conditions every tick and round-tripped through save/load, but NOTHING in the
# character damage path ever read them — every buff granting bonus damage was
# silently inert. They apply here, once, for every weapon/unarmed/thrown hit:
#
#   damage_multiplier          = 0.5 + STR/100      (1.0 at STR 50)
#   bonus_damage               flat, from conditions ("powerful" grants +2)
#   bonus_damage_against_trait = flat "bane"-style bonus vs a target trait
#
# STRENGTH only scales what you swing or throw, so ranged weapons skip the
# multiplier but still take the flat bonuses. Weapon damage in Items.json is
# authored as the FINAL number for an average (STR 50) character, which makes
# the multiplier exactly 1.0 there — the balance table is the STR-50 row.
func _apply_attacker_damage_mods(damage: Dictionary, attacker, target, str_scales: bool) -> void:
	if attacker == null or damage.is_empty():
		return
	if str_scales:
		var mult: float = float(attacker.damage_multiplier)
		if mult != 1.0:
			for dtype in damage.keys():
				damage[dtype] = float(damage[dtype]) * mult

	# Flat bonuses land on the leading damage type after scaling, so a bane
	# bonus is worth the same whether you swing a longsword or a dagger.
	# Trait keys are authored lowercase but capitalised on characters/races,
	# so the bane lookup matches case-insensitively.
	# Rage is NOT a `bonus_damage` stat_modifier: its size tracks the attacker's
	# CURRENT missing HP, which a modifier's constant `value` cannot express. It
	# is read at swing time from the same helper the DR half uses
	# (ProceduralCharacter.rage_bonus) so the two can never disagree. Weapon
	# attacks only, matching `bonus_damage` itself -- ability damage resolves in
	# AbilityEffect._resolve_damage, which never reaches this function.
	var rage_flat: float = float(attacker.rage_bonus()) if attacker.has_method("rage_bonus") else 0.0
	var flat: float = float(attacker.bonus_damage) + _bane_bonus_against(attacker, target) + rage_flat
	if flat != 0.0:
		var keys = damage.keys()
		damage[keys[0]] = maxf(0.0, float(damage[keys[0]]) + flat)


func _bane_bonus_against(attacker, target) -> float:
	if target == null or not attacker.get("bonus_damage_against_trait"):
		return 0.0
	if not ("traits" in target) or not (target.traits is Dictionary):
		return 0.0
	var target_keys := {}
	for k in target.traits.keys():
		if float(target.traits[k]) > 0.0:
			target_keys[String(k).to_lower()] = true
	var total: float = 0.0
	for trait_key in attacker.bonus_damage_against_trait.keys():
		var bonus: float = float(attacker.bonus_damage_against_trait[trait_key])
		if bonus != 0.0 and target_keys.has(String(trait_key).to_lower()):
			total += bonus
	return total


# Weapon-level bane MULTIPLIERS (vs the additive attacker-level bonuses above):
# `damage_vs_trait` {"spectral": 2.0} doubles every damage type against targets
# carrying that trait. `source` is a WeaponShape or a raw item Dictionary
# (thrown items reach their hit callback as data, not nodes).
func _apply_weapon_trait_mult(damage: Dictionary, source, target) -> void:
	if source == null or target == null or damage.is_empty():
		return
	var vs = source.get("damage_vs_trait")
	if not (vs is Dictionary) or vs.is_empty():
		return
	if not ("traits" in target) or not (target.traits is Dictionary):
		return
	var target_keys := {}
	for k in target.traits.keys():
		if float(target.traits[k]) > 0.0:
			target_keys[String(k).to_lower()] = true
	var mult: float = 1.0
	for trait_key in vs.keys():
		if target_keys.has(String(trait_key).to_lower()):
			mult *= float(vs[trait_key])
	if mult != 1.0:
		for dtype in damage.keys():
			damage[dtype] = float(damage[dtype]) * mult


# Unique-item on-hit procs: the item names an ability (`on_hit_ability`) whose
# effects resolve directly at the victim — no cast, no school costs, no
# targeting UI. `source` is a WeaponShape or a raw item Dictionary. The
# ability data may carry "min_damage": procs only when the hit dealt at least
# that much (post-DR).
func _apply_item_on_hit_effects(attacker, target, source, damage_dealt: int, hit_position: Vector2) -> void:
	if source == null or attacker == null:
		return
	# The dead are not targets: a killing blow must not brand/charm/chrome the
	# corpse (take_damage runs before this at every call site).
	if target != null and target.has_method("is_alive") and not target.is_alive():
		return
	var raw = source.get("on_hit_ability")
	var ability_id: String = str(raw) if raw != null else ""
	if ability_id == "" or ability_id == "null":
		return
	var data: Dictionary = AbilityDatabase.get_ability_data(ability_id)
	if data.is_empty():
		return
	if damage_dealt < int(data.get("min_damage", 0)):
		return
	var ability = Ability.from_dict(data)
	for effect in ability.effects:
		AbilityEffect.resolve_effect(effect, attacker, [target], ability, hit_position)
	if attacker is CharacterBody2D and target is CharacterBody2D:
		emit_signal("damage_dealt", attacker, target,
			{"source": source, "damage": damage_dealt, "position": hit_position})


func process_object_hit(
	attacker: ProceduralCharacter,
	target: Node2D,
	hit_position: Vector2,
	weapon: Node2D,
	attack_velocity: float
) -> Dictionary:
	# Build damage dict — duplicate to avoid mutating weapon data
	var attack_damage: Dictionary
	if weapon and not (weapon is AbilityShape):
		attack_damage = weapon.damage.duplicate()
		_apply_attacker_damage_mods(attack_damage, attacker, target, _weapon_is_melee(weapon))
		_apply_weapon_trait_mult(attack_damage, weapon, target)
	else:
		# Unarmed (or AbilityShape held while combat collision detection runs).
		attack_damage = {
			attacker.unarmed_strike_damage_type: float(attacker.unarmed_strike_damage)
		}
		_apply_attacker_damage_mods(attack_damage, attacker, target, true)

	# Objects use take_damage(damage_dict, success_level) and handle DR internally
	target.take_damage(attack_damage, 0)

	# Calculate total damage for penetration check
	var total_damage = 0.0
	var dr = target.damage_resistances if "damage_resistances" in target else {}
	for dtype in attack_damage:
		total_damage += max(0.0, attack_damage[dtype] - dr.get(dtype, 0))

	# Pass null for non-weapon items (e.g., AbilityShape) so penetration math
	# doesn't try to read weapon-specific properties.
	var actual_weapon = weapon if weapon is WeaponShape else null
	var penetration_result = _calculate_penetration(total_damage, attack_velocity, actual_weapon)

	if penetration_result.state == PenetrationState.BOUNCED:
		SfxManager.play("clash", target.global_position)
		HearingManager.emit(target.global_position, 0.9, attacker)
	else:
		# sfx/ has no "impact" key; armor-impact is the solid-object thud.
		SfxManager.play("armor-impact", target.global_position)
		HearingManager.emit(target.global_position, 0.8, attacker)

	# Unique-item on-hit procs on non-bounced hits (condition effects no-op on
	# structures; positional effects like spawn_fluid/cloud still land)
	if weapon and penetration_result.state != PenetrationState.BOUNCED:
		_apply_item_on_hit_effects(attacker, target, weapon, int(total_damage), hit_position)

	return {
		"attacker": attacker,
		"target": target,
		"weapon": weapon,
		"raw_damage": attack_damage,
		"penetration_state": penetration_result.state,
		"penetration_depth": penetration_result.depth,
		"actual_damage": total_damage,
	}
	
func _input(event: InputEvent) -> void:
	# Typing in a text field must never trigger game hotkeys: Node._input runs
	# BEFORE Control gui_input, so a focused LineEdit can't consume the key
	# first — typing "r" in the combat-test filter reloaded the whole scene,
	# "t" toggled WAIT, digits switched the selection.
	if event is InputEventKey:
		var focus := get_viewport().gui_get_focus_owner()
		if focus is LineEdit or focus is TextEdit:
			return
	if event is InputEventKey and event.pressed:
		match event.keycode:
			# F12 / R / P are developer hotkeys: R reloads the scene with no save
			# (autoloads keep quest/time state), so they stay out of release builds.
			KEY_F12:
				if not event.echo and OS.is_debug_build():
					DebugManager.toggle()
			KEY_F11:
				# Save round-trip smoke test: build -> apply -> build must be
				# byte-identical. The debug caller that keeps build_save_dict
				# from rotting the way the three orphaned serializers did.
				if not event.echo and OS.is_debug_build():
					var first: Dictionary = build_save_dict()
					apply_save_dict(first)
					var second: Dictionary = build_save_dict()
					if JSON.stringify(first) == JSON.stringify(second):
						GameLog.add_entry("[save] round-trip OK (%d chars)" % JSON.stringify(first).length())
					else:
						GameLog.add_entry("[save] ROUND-TRIP MISMATCH — check the F11 diff in the console")
						print("[save] first:  ", JSON.stringify(first).length(), " chars")
						print("[save] second: ", JSON.stringify(second).length(), " chars")
			KEY_F8:
				# The carta d'identita, reopened as a read-only character sheet
				# for whoever is selected (the protagonist if nobody is).
				if not event.echo:
					show_character_sheet()
			KEY_R:
				# Restart
				if not event.echo and OS.is_debug_build():
					get_tree().reload_current_scene()
			KEY_P:
				# Print status
				if not event.echo and OS.is_debug_build():
					_print_status()
			KEY_C:
				if not event.echo:
					set_stealth_mode(not stealth_mode)
			KEY_T:
				# WAIT toggle for the selected party members — the hotkey twin
				# of the context menu's Wait Here / Resume pair.
				if not event.echo:
					_toggle_wait_selected()

	# World-map toggle (M) and water gathering (G). Use action lookups so the
	# bindings stay editable from project.godot.
	if event.is_action_pressed("world_map") and not event.is_echo():
		toggle_world_map()
	if event.is_action_pressed("gather_water") and not event.is_echo():
		gather_water_at_party()
	# Number keys 1-9 to select party members (Ctrl+number to toggle multi-select)
	if event is InputEventKey and event.pressed and not event.echo:
		var key = event.keycode
		if key >= KEY_1 and key <= KEY_9:
			var index = key - KEY_1  # 0-8
			var party = get_party()
			if index >= 0 and index < party.size():
				var character = party[index]
				if character and is_instance_valid(character):
					if event.ctrl_pressed:
						toggle_character_selection(character)
					else:
						select_character_by_index(index)
			
func _create_selection_indicator(size: int) -> void:
	"""Create selection indicators — now managed per-character via selection methods"""
	pass  # Indicators are now created/removed in _add/_remove_selection_circle

func _add_selection_circle(character: ProceduralCharacter, color: Color) -> void:
	if character in selection_indicators:
		_update_circle_color(character, color)
		return
	var indicator = Node2D.new()
	# On the ground, under the character it marks — a ring drawn over the body
	# reads as a collar rather than as a footprint. Above PathDrawer.Z_GROUND (2)
	# so the ring stays legible where a path runs through it, below the
	# character root (5). Absolute, so it can't inherit its way back on top.
	indicator.z_as_relative = false
	indicator.z_index = 3
	var circle_drawer = SelectionCircle.new()
	circle_drawer.radius = max(character.collision_radius + 8.0, 20.0)
	circle_drawer.circle_color = color
	circle_drawer.line_width = SELECTION_CIRCLE_WIDTH
	indicator.add_child(circle_drawer)
	add_child(indicator)
	indicator.visible = false
	selection_indicators[character] = indicator

func _remove_selection_circle(character: ProceduralCharacter) -> void:
	if character in selection_indicators:
		selection_indicators[character].queue_free()
		selection_indicators.erase(character)

func _update_circle_color(character: ProceduralCharacter, color: Color) -> void:
	if character in selection_indicators:
		var circle = selection_indicators[character].get_child(0) as SelectionCircle
		circle.circle_color = color
		circle.queue_redraw()

func _refresh_all_circles() -> void:
	"""Update circle colors so primary is white and others are blue."""
	for character in selection_indicators:
		if character == primary_selected:
			_update_circle_color(character, SELECTION_CIRCLE_COLOR)
		else:
			_update_circle_color(character, SELECTION_CIRCLE_COLOR_MULTI)

func _select_initial_character() -> void:
	"""Select the first party character on startup"""
	var party = get_party()
	if party.size() > 0:
		select_character(party[0], 0)

func get_party() -> Array:
	"""Get the party characters array"""
	return party_chars

func select_character_by_index(index: int) -> bool:
	"""Exclusive-select a party member by their index (0-based)"""
	var party = get_party()
	if index >= 0 and index < party.size():
		var character = party[index]
		if character and is_instance_valid(character):
			select_character(character, index)
			return true
	return false

func select_character(character: ProceduralCharacter, index: int = -1) -> void:
	"""Exclusive select: deselect all others, select only this character."""
	# Deselect everyone currently selected
	_deselect_all()

	# Select new
	primary_selected = character
	if player_camera:
		player_camera.manual_pan_active = false  # re-engage follow
	roof_view_override = -1   # fresh selection: their layer drives the view again
	primary_index = index if index >= 0 else get_party().find(character)
	selected_characters.append(character)
	_sync_character_flags()
	_add_selection_circle(character, SELECTION_CIRCLE_COLOR)
	emit_signal("character_selected", character, primary_index)
	emit_signal("selection_changed")

func toggle_character_selection(character: ProceduralCharacter) -> void:
	"""Ctrl+click: add or remove a character from the multi-select group."""
	if character in selected_characters:
		# Don't allow removing the primary if it's the only one
		if character == primary_selected:
			if selected_characters.size() <= 1:
				return
			# Promote another character to primary
			selected_characters.erase(character)
			primary_selected = selected_characters[0]
			if player_camera:
				player_camera.manual_pan_active = false  # re-engage follow on promoted primary
			roof_view_override = -1
			primary_index = get_party().find(primary_selected)
			emit_signal("character_selected", primary_selected, primary_index)
		else:
			selected_characters.erase(character)
		_remove_selection_circle(character)
		emit_signal("character_deselected", character)
	else:
		selected_characters.append(character)
		_add_selection_circle(character, SELECTION_CIRCLE_COLOR_MULTI)
	_sync_character_flags()
	_refresh_all_circles()
	emit_signal("selection_changed")

func _deselect_all() -> void:
	"""Remove all characters from selection."""
	for c in selected_characters.duplicate():
		_remove_selection_circle(c)
		emit_signal("character_deselected", c)
	selected_characters.clear()
	primary_selected = null
	primary_index = 0

func _sync_character_flags() -> void:
	"""Set is_player_controlled and AI_enabled based on selection state."""
	for character in party_chars:
		if not is_instance_valid(character):
			continue
		if character in selected_characters:
			var was_ai: bool = character.AI_enabled
			character.is_player_controlled = true
			character.AI_enabled = false
			if was_ai:
				_clear_companion_ai(character)
		else:
			# Losing input authority must also end any planning gesture still in
			# flight. ProceduralCharacter._handle_input is is_player_controlled-
			# gated, so from the next frame this character can neither confirm NOR
			# cancel what it started: an un-aimed AoE preview rides the cursor
			# forever (AbilityTargeting processes ALWAYS and gates only on
			# is_targeting) and PathInputHandler stays parked in PLACING_ACTION -
			# which is why the only way to clear it was to re-select and confirm.
			# Gated on the previous flag so it is a transition hook rather than a
			# per-call sweep of the whole party, and so re-selecting the character
			# who is ALREADY targeting leaves their live session alone.
			# Confirmed plans are never touched.
			if character.is_player_controlled:
				character.abort_planning_input()
			var was_player: bool = not character.AI_enabled
			character.is_player_controlled = false
			character.AI_enabled = true
			if was_player:
				_clear_companion_ai(character)

## Called once when control of a party member changes hands, never per frame.
## process_ai doesn't run while AI_enabled is false, so a "?" raised while the
## companion was AI-driven would never decay or hide once the player took over,
## and alertness piled up while player-driven (hits, party call-outs) would send
## it SEARCHING toward a stale spot once control is handed back. A fight still
## in view is re-acquired by the next target scan.
func _clear_companion_ai(character: ProceduralCharacter) -> void:
	var ai = character.get_node_or_null("AI")
	if ai and ai.current_state != ai.AIState.DEAD:
		ai.current_target = null
		ai.nav_path.clear()
		ai.nav_path_index = 0
		ai._change_state(ai.AIState.IDLE)
		ai._set_alertness_value(0.0)
	if character._alertness_flash_tween and character._alertness_flash_tween.is_valid():
		character._alertness_flash_tween.kill()
	character._alertness_flash_tween = null
	character._outcry_flash_period = -1.0
	var indicator = character.get_node_or_null("AlertnessIndicator")
	if indicator:
		indicator.visible = false
		indicator.modulate.a = 1.0

func is_character_selected(character: ProceduralCharacter) -> bool:
	return character in selected_characters

func select_next() -> void:
	"""Select next party member (exclusive)"""
	var party = get_party()
	if party.size() == 0:
		return
	var next_index = (primary_index + 1) % party.size()
	select_character_by_index(next_index)

func select_previous() -> void:
	"""Select previous party member (exclusive)"""
	var party = get_party()
	if party.size() == 0:
		return
	var prev_index = (primary_index - 1 + party.size()) % party.size()
	select_character_by_index(prev_index)

func get_selected() -> ProceduralCharacter:
	"""Get the primary selected character"""
	return primary_selected

# T: toggle the WAIT order on every selected party member. Mixed selections
# unify — if anyone is still free the whole selection holds; only when all of
# them already hold does T release them. Same flag + log lines as the context
# menu's Wait Here / Resume, so the two entry points are interchangeable.
func _toggle_wait_selected() -> void:
	var targets: Array = []
	for ch in selected_characters:
		if is_instance_valid(ch) and ch in party_chars \
				and ch.has_method("is_alive") and ch.is_alive():
			targets.append(ch)
	if targets.is_empty():
		return
	var hold := false
	for ch in targets:
		if not ch.hold_position:
			hold = true
			break
	for ch in targets:
		if ch.hold_position != hold:
			ch.hold_position = hold
			GameLog.add_entry(str(ch.Name) + (" holds position." if hold else " moves out."))

# ===== COMBAT CALLBACKS =====

func _on_damage_dealt(attacker: CharacterBody2D, target: CharacterBody2D, info: Dictionary) -> void:
	var attacker_name = "Player" if attacker == player else "Enemy"
	var target_name = "Player" if target == player else "Enemy"
	
	if info.get("limb_disabled", false):
		print("  -> %s DISABLED!" % info["limb_name"])
	if info.get("limb_severed", false):
		print("  -> %s SEVERED!" % info["limb_name"])

func _on_weapon_bounced(attacker: CharacterBody2D, target: CharacterBody2D, limb_type: int) -> void:
	pass

func _on_weapon_clash(char1: CharacterBody2D, char2: CharacterBody2D, winner: CharacterBody2D, power_diff: float) -> void:
	var winner_name = "Player" if winner == player else "Enemy"

func _on_weapon_disarmed(character: CharacterBody2D) -> void:
	var name = "Player" if character == player else "Enemy"

func _on_character_died(character: ProceduralCharacter) -> void:
	var name = "Player" if character == player else "Enemy"
	print("%s has died!" % name)
	var ai_node = character.get_node_or_null("AI")
	if ai_node:
		ai_node.current_state = ai_node.AIState.DEAD
	_drop_quest_trophies(character)
	if character == player:
		print("\n=== GAME OVER ===")
		print("(debug: press R to restart)")

## Quest-proof harvesting. When a character dies, any active quest that declares
## proof sourced from that character's template gets its trophy appended to the
## corpse's own inventory, stamped with the victim's identity. Ordinary
## "Search Body" looting then picks it up — no new interaction verb, because
## _enter_corpse_state aliases `contents` to the SAME Array as inventory.items,
## so an append here is visible in the loot window regardless of which of the two
## death paths runs first.
##
## Hooked to character_died (not _enter_corpse_state) deliberately: that signal
## fires exactly once per real death, while restore_dead_state re-runs the corpse
## setup on every map re-entry and would re-mint the trophy each time.
func _drop_quest_trophies(character) -> void:
	if character == null or not is_instance_valid(character):
		return
	if character.has_meta("quest_trophies_taken"):
		return
	var template_id: String = str(character.template_id) if "template_id" in character else ""
	if template_id.is_empty():
		return
	var specs: Array = QuestManager.proof_specs_for_template(template_id)
	if specs.is_empty():
		return
	var inv = character.get_node_or_null("Inventory")
	if inv == null or not inv.has_method("add_item"):
		return

	character.set_meta("quest_trophies_taken", true)
	var minted: Array = []
	for spec in specs:
		var item_id: String = str(spec.get("item", ""))
		# Two quests wanting the same trophy from the same corpse share one head.
		if item_id.is_empty() or item_id in minted:
			continue
		minted.append(item_id)
		inv.add_item(character.build_trophy_item(item_id))

func _print_status() -> void:
	# get_stats_string no longer exists (P threw a script error) and `enemies`
	# is never filled.
	if not (player and is_instance_valid(player)):
		return
	print("\n=== STATUS ===")
	# get_status_string now lives on ProceduralCharacter itself and prints
	# the single HP pool plus any severed/disabled limbs.
	print("Player: %s" % player.get_status_string())
	print("")



func spawn_character_by_name(char_name: String, spawn_position: Vector2, faction = null) -> ProceduralCharacter:
	for char_data in characters_database:
		if char_data.get("name", "") == char_name:
			var c = spawn_character(char_data, spawn_position)
			if faction:
				c.set_faction(faction)
			c.display_name = char_name
			return c	
	push_warning("Character not found: " + char_name)
	return null

func spawn_character_by_index(index: int, spawn_position: Vector2) -> ProceduralCharacter:
	if index < 0 or index >= characters_database.size():
		push_warning("Character index out of bounds: " + str(index))
		return null
	
	return spawn_character(characters_database[index], spawn_position)

func spawn_character(data: Dictionary, spawn_position: Vector2) -> ProceduralCharacter:
	var container = spawn_container if spawn_container else self
	
	# Create character node
	var character_node = CharacterScene.instantiate()
	character_node.global_position = spawn_position
	
	
	#Add ConditionManager:
	var condition_manager = ConditionManager.new()
	condition_manager.name = "ConditionManager"
	character_node.add_child(condition_manager)
	#character_node.add_child(targeting_system)
	# Load character data
	character_node.load_from_data(data)
	container.add_child(character_node)

	characters_in_scene.append(character_node)
	
	return character_node

func spawn_all_characters(spacing: float = 100.0) -> void:
	var start_x = -((characters_database.size() - 1) * spacing) / 2.0
	
	for i in range(characters_database.size()):
		var pos = Vector2(start_x + i * spacing, 0)
		spawn_character_by_index(i, pos)

func get_character_by_name(char_name: String) -> ProceduralCharacter:
	for character in characters_in_scene:
		if character.character_data.get("name", "") == char_name:
			return character
	return null

func despawn_character(character: ProceduralCharacter) -> void:
	if character in characters_in_scene:
		characters_in_scene.erase(character)
		character.queue_free()

func despawn_all() -> void:
	for character in characters_in_scene:
		character.queue_free()
	characters_in_scene.clear()
	
func _toggle_weapon_debug() -> void:
	var weapon = player.get_current_weapon()
	if weapon:
		weapon.set_debug_draw(not weapon.debug_draw)


# Weapon penetration states
enum PenetrationState { 
	NOT_HITTING,      # No contact
	BOUNCED,          # DR too high, weapon bounced off
	PENETRATING,      # Currently sinking into flesh
	FULLY_PENETRATED, # Reached maximum depth
	STUCK             # Weapon is stuck in target
}

# Active hit tracking (prevents multiple hits per swing)
var active_hits: Dictionary = {}  # attacker_id -> { target_id -> hit_data }

# Weapon clash cooldowns
var clash_cooldowns: Dictionary = {}  # "id1_id2" -> time_remaining

signal damage_dealt(attacker: CharacterBody2D, target: CharacterBody2D, damage_info: Dictionary)
signal weapon_bounced(attacker: CharacterBody2D, target: CharacterBody2D, limb_type: int)
signal weapon_clash(char1: CharacterBody2D, char2: CharacterBody2D, winner: CharacterBody2D, power_diff: float)
signal weapon_knocked_away(character: CharacterBody2D)
signal weapon_disarmed(character: CharacterBody2D)

const CLASH_COOLDOWN: float = 0.3  # Seconds between weapon clashes	

# ===== WEAPON VS BODY COLLISION =====
func process_weapon_hit(
	attacker: ProceduralCharacter,
	target: ProceduralCharacter,
	hit_position: Vector2,
	weapon: Node2D,
	attack_velocity: float
) -> Dictionary:
	# Determine which limb was hit
	var local_hit = target.to_local(hit_position)
	var limb_type = target.get_limb_at_position(
		local_hit,
		target.body_width,
		target.body_height
	)
	# Calculate base damage — DUPLICATE to avoid mutating the weapon's data
	var attack_damage: Dictionary
	if weapon and not (weapon is AbilityShape):
		attack_damage = weapon.damage.duplicate()
		_apply_attacker_damage_mods(attack_damage, attacker, target, _weapon_is_melee(weapon))
		_apply_weapon_trait_mult(attack_damage, weapon, target)
	else:
		attack_damage = {
			attacker.unarmed_strike_damage_type: float(attacker.unarmed_strike_damage)
		}
		_apply_attacker_damage_mods(attack_damage, attacker, target, true)

	# Bide payoff: add accumulated bonus to the first damage type and consume it
	if "bide_pending_bonus" in attacker and attacker.bide_pending_bonus > 0.0:
		var dt_keys = attack_damage.keys()
		if dt_keys.size() > 0:
			var bide_bonus: float = attacker.bide_pending_bonus
			attack_damage[dt_keys[0]] += attacker.bide_pending_bonus
			attacker.bide_pending_bonus = 0.0
			# Announce the payoff so the big number has a visible cause.
			var shown_bonus: int = int(round(bide_bonus))
			if shown_bonus > 0 and is_seen_by_party(attacker):
				Globals.show_floating_text("Bide +%d!" % shown_bonus, hit_position, self, Color.ORANGE, 1, Globals.NOTICE_FONT_SIZE)
				GameLog.add_entry("%s unleashes Bide: +%d damage." % [attacker.Name, shown_bonus])

	# Track whether this swing was an unarmed strike so post-damage mutation
	# procs (e.g. The Claws That Catch) only fire on punches/kicks.
	var is_unarmed: bool = weapon == null or weapon is AbilityShape

	# take_damage applies limb-specific armor DR (via hit_limb) then subtracts
	# from the character's single HP pool. Returns total damage dealt.
	var final_damage = target.take_damage(attack_damage, local_hit, attacker, limb_type)
	var limb = target.get_limb(limb_type)
	var armor_dr = target.get_limb_armor(limb_type) if limb else {}

	# Mutation proc: The Claws That Catch — every unarmed strike attempts a grapple.
	# Whether it lands is purely the target's STR save (grappled.save_stat = "str").
	# Incoming stacks scale with mutation tier so higher-tier claws are both harder
	# to fully resist on application AND persist longer (the periodic tick-save
	# can only chip one stack at a time).
	if is_unarmed and attacker.condition_manager and target.condition_manager:
		var claws: ConditionInstance = attacker.condition_manager.conditions.get("the_claws_that_catch")
		if claws and claws.is_active():
			target.condition_manager.apply_condition("grappled", attacker, claws.stacks, -2.0)

	# Penetration uses the post-DR damage (pass null for non-weapon items like AbilityShape)
	var actual_weapon = weapon if weapon is WeaponShape else null
	var penetration_result = _calculate_penetration(final_damage, attack_velocity, actual_weapon)

	# Unique-item / natural-weapon on-hit procs fire only if we actually
	# penetrated. Unarmed strikes proc the attacker's race/template
	# unarmed_on_hit_ability through the same hook (as a data source, the way
	# thrown items do).
	if penetration_result.state != PenetrationState.BOUNCED:
		var proc_source = weapon
		if is_unarmed and str(attacker.get("unarmed_on_hit_ability")) != "":
			proc_source = {"on_hit_ability": attacker.unarmed_on_hit_ability}
		if proc_source:
			_apply_item_on_hit_effects(attacker, target, proc_source, final_damage, hit_position)

	var result = {
		"attacker": attacker,
		"target": target,
		"weapon": weapon,
		"limb_type": limb_type,
		"limb_name": limb.name if limb else "Unknown",
		"raw_damage": attack_damage,
		"armor_dr": armor_dr,
		"penetration_state": penetration_result.state,
		"penetration_depth": penetration_result.depth,
		"velocity_reduction": penetration_result.velocity_reduction,
		"actual_damage": final_damage,
		"blocked": 0
	}

	if penetration_result.state == PenetrationState.BOUNCED:
		result["blocked"] = attack_damage
		# A fist on plate thuds; only steel on steel clangs.
		SfxManager.play("armor-impact" if is_unarmed else "clash", attacker.position)
		HearingManager.emit(attacker.position, 0.9, attacker)
		emit_signal("weapon_bounced", attacker, target, limb_type)
	else:
		# Punches and kicks thud; claws and bites (slashing/piercing) tear.
		var punch: bool = is_unarmed and str(attacker.unarmed_strike_damage_type) == "bludgeoning"
		SfxManager.play("stun_impact" if punch else "sword-on-flesh", target.position)
		HearingManager.emit(target.position, 0.7, attacker)

	if DebugManager.enabled and collision_visualizer and collision_visualizer.has_method("record_hit"):
		var penetrated: bool = penetration_result.state != PenetrationState.BOUNCED
		var damage_total: float = 0.0
		if final_damage is Dictionary:
			for k in final_damage.keys():
				damage_total += float(final_damage[k])
		else:
			damage_total = float(final_damage)
		collision_visualizer.record_hit(hit_position, result.limb_name, penetrated, damage_total)
		print("[debug] weapon hit: ", attacker.name if attacker else "?", " -> ", target.name if target else "?", " limb=", result.limb_name, " dmg=", damage_total, " state=", PenetrationState.keys()[penetration_result.state])

	return result

func _calculate_penetration(damage: float, velocity: float, weapon: WeaponShape) -> Dictionary:
	"""Calculate how deeply a weapon penetrates based on damage, armor, and velocity"""
	
	if damage <= 0.0:
		return {
			"state": PenetrationState.BOUNCED,
			"depth": 0.0,
			"velocity_reduction": 1.0  # Full stop
		}
	
	# 3. Apply velocity to the total unresisted damage
	# velocity affects initial penetration power
	var velocity_factor = clamp(velocity / 100.0, 0.5, 2.0)
	var penetration_power = damage * velocity_factor
	
	# 4. Flesh resistance (nonlinear - gets harder to penetrate deeper)
	var max_penetration_depth = 1.0
	var flesh_resistance = 10.0  # Base resistance
	
	# Calculate depth using inverse relationship (asymptotic approach to max)
	# Formula: max * (1 - e^(-power / resistance))
	var depth = max_penetration_depth * (1.0 - exp(-penetration_power / (flesh_resistance * 3)))
	
	# 5. Velocity reduction (nonlinear)
	var velocity_reduction = depth * 0.7 + 0.1  # Always lose at least 10% velocity
	
	var state = PenetrationState.PENETRATING
	if depth >= 0.9:
		state = PenetrationState.FULLY_PENETRATED
	
	return {
		"state": state,
		"depth": depth,
		"velocity_reduction": clamp(velocity_reduction, 0.0, 1.0)
	}
	
# ===== WEAPON VS WEAPON COLLISION =====


		# Visual feedback could be added here (screen shake, etc)
func process_weapon_clash(
	char1: ProceduralCharacter,
	char2: ProceduralCharacter,
	clash_position: Vector2
) -> Dictionary:
	"""Process two weapons colliding"""
	
	# Check cooldown
	var clash_key = _get_clash_key(char1, char2)
	if clash_cooldowns.has(clash_key):
		return {"result": "cooldown"}
	
	# Set cooldown
	clash_cooldowns[clash_key] = CLASH_COOLDOWN
	
	
	# Calculate clash power (STR + partial CON for bracing)
	var power1 = char1.clash_power
	var power2 = char2.clash_power

	
	var power_diff = power1 - power2
	var winner: ProceduralCharacter = null
	var loser: ProceduralCharacter = null
	
	var result = {
		"char1": char1,
		"char2": char2,
		"power1": power1,
		"power2": power2,
		"power_diff": abs(power_diff),
		"outcome": "stalemate",
		"winner": null,
		"loser": null
	}
	
	# Determine outcome based on power difference
	if abs(power_diff) < 2.0:
		# Close match - both stagger slightly
		SfxManager.play("clash", char1.position)
		HearingManager.emit(char1.position, 0.9, char1)

		result["outcome"] = "stalemate"
		char2.apply_stagger(0.2) #REMOVE? Or make a condtions
		char1.apply_stagger(0.2)
	elif abs(power_diff) < 5.0:
		# Moderate difference - loser knocked back
		winner = char1 if power_diff > 0 else char2
		loser = char2 if power_diff > 0 else char1
		result["outcome"] = "knockback"
		result["winner"] = winner
		result["loser"] = loser
		loser.apply_stagger(0.3)
		emit_signal("weapon_clash", char1, char2, winner, abs(power_diff))
	elif abs(power_diff) < 10.0:
		# Large difference - weapon knocked away
		winner = char1 if power_diff > 0 else char2
		loser = char2 if power_diff > 0 else char1
		result["outcome"] = "knocked_away"
		result["winner"] = winner
		result["loser"] = loser
		loser.knock_weapon_away()
		emit_signal("weapon_knocked_away", loser)
	else:
		# Massive difference - disarm
		winner = char1 if power_diff > 0 else char2
		loser = char2 if power_diff > 0 else char1
		result["outcome"] = "disarm"
		result["winner"] = winner
		result["loser"] = loser
		loser.disarm_character()
		emit_signal("weapon_disarmed", loser)
	
	return result

func _get_clash_key(char1: CharacterBody2D, char2: CharacterBody2D) -> String:
	var id1 = char1.get_instance_id()
	var id2 = char2.get_instance_id()
	if id1 > id2:
		return "%d_%d" % [id2, id1]
	return "%d_%d" % [id1, id2]

# ===== HIT TRACKING =====
func register_attack_start(attacker: Node2D) -> void:
	"""Called when an attack begins - resets hit tracking for this attack"""
	active_hits[attacker.get_instance_id()] = {}
	# Every melee and ranged swing comes through here: it gives away a
	# concealed (Shrouded) attacker for a few seconds.
	if attacker.has_method("reveal"):
		attacker.reveal()

func register_attack_end(attacker: Node2D) -> void:
	"""Called when an attack ends - clears hit tracking. Also reports a melee
	swing that touched nothing: whiffs used to be completely silent (no log, no
	SFX, no cue), so a character parked outside its own reach looked identical to
	one trading blows, which is what let the reach/stand-off mismatch hide."""
	var attacker_id: int = attacker.get_instance_id()
	if active_hits.has(attacker_id) and active_hits[attacker_id].is_empty():
		_log_melee_whiff(attacker)
	active_hits.erase(attacker_id)

# Party-only so a twenty-body brawl doesn't bury the log. Ranged attacks and
# casts share the attack-tracking plumbing but resolve elsewhere (projectiles,
# AbilityEffect), so an empty hit set means nothing for them.
func _log_melee_whiff(attacker: Node2D) -> void:
	if not (attacker is ProceduralCharacter) or not (attacker in party_chars):
		return
	var anim = attacker.attack_animator
	if anim == null or anim.is_casting:
		return
	if String(anim.current_damage_type) in ["ranged_arrow", "ranged_bullet"]:
		return
	GameLog.add_entry("%s swings and connects with nothing." % attacker.Name)

const MELEE_ELEV_TOLERANCE := 0.75

func _elev_of(n: Node2D) -> float:
	if n.has_method("get_elevation"):
		return n.get_elevation()
	# Structures: tile under their center — a parapet on deck tiles reads deck
	# elevation (unhittable from ground); a ground wall reads terrain.
	return GridManager.effective_elev(GridManager.world_to_map(n.global_position))

func can_hit_target(attacker: Node2D, target: Node2D) -> bool:
	"""Check if this attack can still hit this target (hasn't already)"""
	# The dead are not targets. Normally corpses leave the CHARACTERS layer
	# (deferred), but a second attacker's queued body_entered in the SAME
	# physics flush that killed the target can still reach here — without this
	# gate that contact resolved as a 0-damage armor BOUNCE: clash SFX plus a
	# spurious 0.9 hearing pulse for the AI (review find).
	if target is ProceduralCharacter and not target.is_alive():
		return false
	# Melee cannot reach across stories (deck walker vs ground character).
	if absf(_elev_of(attacker) - _elev_of(target)) > MELEE_ELEV_TOLERANCE:
		_warn_out_of_reach(attacker, target)
		return false

	var attacker_id = attacker.get_instance_id()
	var target_id = target.get_instance_id()

	if not active_hits.has(attacker_id):
		return true

	return not active_hits[attacker_id].has(target_id)

## Tell the player why their melee swing passed through a character on
## another level. Only a selected (player-controlled) swinger warns, never an
## AI-driven companion's automatic swing. With a live target (attack_aim_node,
## set by Attack Target orders) only that body warns; a swing at a clicked
## point warns for the first visible hostile it skips. At most once per swing:
## register_attack_start resets active_hits[aid], and the String key can't
## collide with the int target ids stored there. The key also leaves the hit
## set non-empty, so register_attack_end's generic "connects with nothing"
## line gives way to this more specific one.
func _warn_out_of_reach(attacker: Node2D, target: Node2D) -> void:
	if not (attacker is ProceduralCharacter and target is ProceduralCharacter):
		return
	if not (attacker in selected_characters) or not target.visible:
		return
	var aid: int = attacker.get_instance_id()
	if not active_hits.has(aid) or active_hits[aid].has("_elev_warned"):
		return
	var swinger := attacker as ProceduralCharacter
	var body := target as ProceduralCharacter
	var intended = swinger.attack_aim_node  # untyped: may hold a freed node
	if is_instance_valid(intended):
		if body != intended:
			return
	elif body in party_chars or not body.is_alive() \
			or not body.is_hostile_to_party():
		return
	active_hits[aid]["_elev_warned"] = true
	swinger.notify("Out of reach", Color(1.0, 0.6, 0.4),
		"%s can't reach %s: melee can't strike between levels." % [swinger.Name, body.Name])

# ===== CHARACTER MELEE: REACH + ARC =====
#
# Called from ProceduralCharacter._on_attack_hit at the animation's hit frame.
# This — not the weapon's blade Area2D — is what decides whether a melee swing
# lands on a character. See MeleeReach for the measurements that motivated it.
# The Area2D survives as the object channel (doors, crates), masked to
# CollisionLayers.WEAPON_OBJECT_HITBOX_MASK.
func resolve_melee_swing(attacker: Node2D, hand: String) -> void:
	if not (attacker is ProceduralCharacter) or not attacker.is_alive():
		return
	var anim = attacker.attack_animator
	# attack_hit_frame also fires for casts and for the ranged release; both
	# resolve elsewhere (AbilityEffect, _fire_ranged_async -> projectiles).
	if anim == null or anim.is_casting:
		return
	if String(anim.current_damage_type) in ["ranged_arrow", "ranged_bullet"]:
		return

	var weapon: Node2D = attacker.current_off_hand_item if hand == "Off" else attacker.current_main_hand_item
	if weapon is AbilityShape:
		return
	if weapon is WeaponShape and not weapon.is_melee():
		return

	var damage_type: String = String(attacker.unarmed_strike_damage_type)
	if weapon is WeaponShape:
		damage_type = String(weapon.primary_damage_type)

	# attack_velocity feeds the penetration model. Read off the animator exactly
	# as the Area2D path did — it was never derived from the collision.
	var attack_velocity: float = 0.0
	if weapon is WeaponShape:
		attack_velocity = absf(anim.get_weapon_rotation()) * float(weapon.total_length)

	# Iterating characters_in_scene rather than a physics query keeps this
	# independent of collision layers, and corpses are filtered by is_alive()
	# (they stay in this list on purpose — see CrimeManager).
	# Game.gd's root is a plain Node — borrow the attacker's world for the ray.
	var space: PhysicsDirectSpaceState2D = attacker.get_world_2d().direct_space_state
	for target in characters_in_scene:
		if target == attacker or not is_instance_valid(target):
			continue
		if not (target is ProceduralCharacter) or not target.is_alive():
			continue
		if not MeleeReach.in_swing(attacker, target, weapon, damage_type):
			continue
		# Walls veto blades. The cheap distance/arc test runs first so the ray
		# only fires for actual candidates. Without this, a polearm's reach
		# crossed thin walls and hit characters in the next room — the object
		# channel (blade Area2D) hit the wall too, but never vetoed the
		# character hit.
		if not MeleeReach.blade_line_clear(space, attacker, target):
			continue
		# Shared with the object channel, so both obey the same rules:
		# already-hit-this-swing, dead targets, and the cross-storey veto.
		if not can_hit_target(attacker, target):
			continue
		register_hit(attacker, target)
		process_weapon_hit(attacker, target,
			MeleeReach.contact_point(attacker, target), weapon, attack_velocity)


func register_hit(attacker: Node2D, target: Node2D) -> void:
	"""Mark that this attack has hit this target"""
	var attacker_id = attacker.get_instance_id()
	var target_id = target.get_instance_id()

	if not active_hits.has(attacker_id):
		active_hits[attacker_id] = {}

	active_hits[attacker_id][target_id] = true
# ===== COLLISION DETECTION HELPERS =====

func check_weapon_weapon_collision(
	char1: ProceduralCharacter,
	char2: ProceduralCharacter
) -> Dictionary:
	"""Check if two weapons are colliding"""
	var weapon1
	var weapon2
	var holder1
	var holder2
	
	# Both must be attacking
	if not char1.attack_animator or not char1.attack_animator.is_attacking:
		return {"collision": false}
	if not char2.attack_animator or not char2.attack_animator.is_attacking:
		return {"collision": false}
	if char1.current_hand == "Main":
		weapon1 = char1.current_main_hand_item
		holder1 = char1.main_hand_holder
	else: 
		weapon1 = char1.current_off_hand_item
		holder1 = char1.off_hand_holder
		
	if char2.current_hand == "Main":
		weapon2 = char2.current_main_hand_item
		holder2 = char2.main_hand_holder
	else:
		weapon2 = char2.current_off_hand_item
		holder2 = char2.off_hand_holder
	
	# Get blade points for both weapons in world space
	var tip1_local = weapon1.get_tip_local_position()
	var blade_start1_local = weapon1.get_blade_start_local()
	var tip2_local = weapon2.get_tip_local_position()
	var blade_start2_local = weapon2.get_blade_start_local()

	# Check multiple points along each blade against each other
	var num_checks = 3
	var collision_radius = 8.0  # How close blades need to be to "clash"

	for i in range(num_checks):
		var t1 = float(i) / float(num_checks - 1)
		var point1_local = tip1_local.lerp(blade_start1_local, t1)
		var point1_world = weapon1.to_global(point1_local)

		for j in range(num_checks):
			var t2 = float(j) / float(num_checks - 1)
			var point2_local = tip2_local.lerp(blade_start2_local, t2)
			var point2_world = weapon2.to_global(point2_local)

			if point1_world.distance_to(point2_world) < collision_radius:
				return {
					"collision": true,
					"position": (point1_world + point2_world) / 2
				}
	
	return {"collision": false}

# ===== PROJECTILE SYSTEM =====

func spawn_projectile(shooter: ProceduralCharacter, direction: Vector2, weapon: WeaponShape) -> Node2D:
	"""Spawn a unified Projectile for a ranged weapon shot."""
	var is_pistol := weapon.weapon_type == WeaponShape.WeaponType.PISTOL

	var proj := Projectile.new()
	proj.name = "Projectile"
	proj.z_index = 3
	proj.speed = 1800.0 if is_pistol else 1200.0
	proj.max_range = 700.0 if is_pistol else 900.0

	var sprite := Sprite2D.new()
	if weapon.projectile_texture_path != "" and ResourceLoader.exists(weapon.projectile_texture_path):
		sprite.texture = load(weapon.projectile_texture_path)
		# Scale so the longest side fits the target size; pistol bullets use a
		# smaller target than arrows because their textures are near-square.
		var tex_size: Vector2 = sprite.texture.get_size()
		var longest: float = max(tex_size.x, tex_size.y)
		if longest > 0:
			var target_size: float = 12.0 if is_pistol else 32.0
			var s: float = target_size / longest
			sprite.scale = Vector2(s, s)
	else:
		var img := Image.create(4, 12, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		sprite.texture = ImageTexture.create_from_image(img)
	# Local +PI/2 puts the sprite's "up" axis along the parent body's +X (which
	# Projectile.launch aligns with travel direction), matching the previous
	# parent-rotation of direction.angle() + PI/2.
	sprite.rotation = PI / 2.0
	proj.add_child(sprite)

	proj.hit.connect(_on_weapon_projectile_hit.bind(shooter, weapon))
	proj.expired.connect(_on_weapon_projectile_expired.bind(shooter))

	get_tree().current_scene.add_child(proj)
	proj.launch(shooter.get_weapon_tip_world_position(), direction, shooter)
	return proj


func _on_weapon_projectile_expired(final_pos: Vector2, shooter) -> void:
	# The shot reached max_range (700 px pistol / 900 px bow) without hitting
	# anything; mark where it fell so a party shot doesn't just vanish.
	_splash_if_fluid(final_pos, 1.0)
	if is_instance_valid(shooter) and shooter in party_chars:
		Globals.show_floating_text("Max range", final_pos, self, Color(0.8, 0.8, 0.8), 0, Globals.NOTICE_FONT_SIZE)


func _splash_if_fluid(world_pos: Vector2, strength: float = 1.1) -> void:
	"""Spawn a splash ripple if a fluid tile exists at this world position."""
	if fluid_manager and fluid_manager.get_fluid_type_at(GridManager.world_to_map(world_pos)) != "":
		fluid_manager.add_ripple(world_pos, strength)

func _on_weapon_projectile_hit(collision: KinematicCollision2D, shooter: ProceduralCharacter, weapon: WeaponShape) -> void:
	var collider := collision.get_collider()
	var hit_pos: Vector2 = collision.get_position()
	_splash_if_fluid(hit_pos, 1.1)
	if collider is ProceduralCharacter:
		# Corpses move to the CORPSES layer on death (deferred), so live
		# collisions imply a living target — this guard covers the one-frame
		# window before the deferred layer write lands.
		if not collider.is_alive():
			return
		_process_projectile_hit_character(shooter, collider, hit_pos, weapon)
	elif collider != null:
		_process_projectile_hit_object(shooter, collider, hit_pos, weapon)


func _process_projectile_hit_character(
	shooter: ProceduralCharacter,
	target: ProceduralCharacter,
	hit_position: Vector2,
	weapon: WeaponShape
) -> void:
	var local_hit = target.to_local(hit_position)
	var limb_type = target.get_limb_at_position(local_hit, target.body_width, target.body_height)
	var attack_damage = weapon.damage.duplicate()
	# Ranged: bonus_damage and bane bonuses apply, STR does not (a pistol does
	# not care how strong you are).
	_apply_attacker_damage_mods(attack_damage, shooter, target, false)
	_apply_weapon_trait_mult(attack_damage, weapon, target)
	var dealt: int = target.take_damage(attack_damage, local_hit, shooter, limb_type)
	# dealt > 0 mirrors the melee BOUNCED gate: fully-absorbed hits don't proc
	if dealt > 0:
		_apply_item_on_hit_effects(shooter, target, weapon, dealt, hit_position)

	# A shot fully stopped by armour sounds like armour, not flesh.
	if dealt <= 0:
		SfxManager.play("armor-impact", hit_position)
		HearingManager.emit(hit_position, 1.5 if weapon.weapon_type == WeaponShape.WeaponType.PISTOL else 0.4, shooter)
	elif weapon.weapon_type == WeaponShape.WeaponType.PISTOL:
		SfxManager.play("sword-on-flesh", hit_position)
		HearingManager.emit(hit_position, 1.5, shooter)  # gunshot — very loud
	else:
		SfxManager.play("arrow-body-impact", hit_position)
		HearingManager.emit(hit_position, 0.4, shooter)

func _process_projectile_hit_object(
	_shooter: ProceduralCharacter,
	target: Node2D,
	hit_position: Vector2,
	weapon: WeaponShape
) -> void:
	if target.has_method("take_damage"):
		target.take_damage(weapon.damage.duplicate(), 0)

	if weapon.weapon_type == WeaponShape.WeaponType.PISTOL:
		SfxManager.play("armor-impact", hit_position)
		HearingManager.emit(hit_position, 1.5, _shooter)  # gunshot
	else:
		SfxManager.play("arrow-wall-impact", hit_position)
		HearingManager.emit(hit_position, 0.4, _shooter)

# ===== THROWN ITEM PROJECTILES =====

func _add_thrown_projectile(proj_data: Dictionary) -> void:
	"""Spawn a unified Projectile for a thrown item; spins in flight and drops the item on hit/expire."""
	# A throw is an attack: it gives a concealed thrower away as a swing does
	# (register_attack_start). Both throw paths (ProceduralCharacter's
	# _execute_pending_throw and PartySidePanel's _execute_throw) come here.
	var thrower = proj_data.get("shooter")
	if is_instance_valid(thrower) and thrower.has_method("reveal"):
		thrower.reveal()
	var item_data: Dictionary = proj_data.get("item_data", {})
	var item_id: String = item_data.get("id", "")
	var thrown_damage: Dictionary = proj_data.get("damage", {"bludgeoning": 2})
	var velocity_vec: Vector2 = proj_data["velocity"]

	var proj := Projectile.new()
	proj.name = "ThrownProjectile"
	proj.z_index = 50
	proj.speed = velocity_vec.length()
	proj.max_range = proj_data.get("max_range", 400.0)
	proj.spin_rate = 12.0  # rad/s, matches the previous _update_projectiles spin

	var sprite := Sprite2D.new()
	var sprite_path: String = item_data.get("sprite_path", "")
	if sprite_path.is_empty():
		var item_db_data: Dictionary = _lookup_any_item(item_id)
		sprite_path = item_db_data.get("sprite_path", "")
	if not sprite_path.is_empty() and ResourceLoader.exists(sprite_path):
		sprite.texture = load(sprite_path)
	else:
		var img := Image.create(12, 12, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.7, 0.5, 0.3))
		sprite.texture = ImageTexture.create_from_image(img)
	# Scale to match in-hand appearance: weapons use total_length (matches
	# WeaponShape._auto_scale_sprite); other items use base_width (matches
	# Item.scale_sprite).
	if sprite.texture:
		var tex_size: Vector2 = sprite.texture.get_size()
		var max_dim: float = max(tex_size.x, tex_size.y)
		if max_dim > 0:
			var total_length = item_data.get("total_length", 0.0)
			if total_length is float and total_length > 0:
				var s: float = total_length / max_dim
				sprite.scale = Vector2(s, s)
			else:
				var target_w: float = float(item_data.get("base_width", 16.0))
				var s: float = target_w / max_dim
				sprite.scale = Vector2(s, s)
	sprite.rotation = PI / 2.0
	proj.add_child(sprite)

	# The respawned item keeps its owner (a stolen throw stays stolen) and its
	# quest-proof origin, as a drop does (PartySidePanel._drop_extras).
	var extras: Dictionary = _thrown_item_extras(item_data)
	proj.hit.connect(_on_thrown_projectile_hit.bind(item_id, thrown_damage, proj_data["shooter"], extras))
	proj.expired.connect(_on_thrown_projectile_expired.bind(item_id, extras))

	get_tree().current_scene.add_child(proj)
	proj.launch(proj_data["position"], velocity_vec, proj_data["shooter"])


## create_item extras for a thrown item's respawn: ownership (stolen_from) and
## the quest-proof origin, the same keys PartySidePanel._drop_extras gives a drop.
func _thrown_item_extras(item: Dictionary) -> Dictionary:
	var extras: Dictionary = {}
	var src: String = str(item.get("stolen_from", ""))
	if not src.is_empty():
		extras["owner_faction"] = src
		extras["stolen_from"] = src
	var origin = item.get("origin", null)
	if origin is Dictionary and not (origin as Dictionary).is_empty():
		extras["origin"] = (origin as Dictionary).duplicate(true)
		extras["origin_display_name"] = str(item.get("display_name", ""))
	return extras


func _on_thrown_projectile_hit(collision: KinematicCollision2D, item_id: String, thrown_damage: Dictionary, shooter, extras: Dictionary = {}) -> void:
	var collider := collision.get_collider()
	var hit_pos: Vector2 = collision.get_position()
	_splash_if_fluid(hit_pos, 1.1)
	if collider is ProceduralCharacter:
		if collider.is_alive():
			var local_hit: Vector2 = collider.to_local(hit_pos)
			var limb_type: int = collider.get_limb_at_position(local_hit, collider.body_width, collider.body_height)
			var thrown_final: Dictionary = thrown_damage.duplicate()
			# Thrown weapons scale with STR — you put your arm into it.
			_apply_attacker_damage_mods(thrown_final, shooter, collider, true)
			# Thrown items reach this callback as an id, not a node — re-fetch
			# the canonical item data so unique-item hooks work when thrown too.
			var thrown_data: Dictionary = ItemDatabase.get_item_data(item_id) if not item_id.is_empty() else {}
			_apply_weapon_trait_mult(thrown_final, thrown_data if not thrown_data.is_empty() else null, collider)
			var dealt: int = collider.take_damage(thrown_final, local_hit, shooter, limb_type)
			# dealt > 0 mirrors the melee BOUNCED gate
			if dealt > 0 and not thrown_data.is_empty():
				_apply_item_on_hit_effects(shooter, collider, thrown_data, dealt, hit_pos)
			# A thrown hit on a body was silent: flesh or armour by what got
			# through, and audible to the AI like an arrow strike.
			SfxManager.play("arrow-body-impact" if dealt > 0 else "armor-impact", hit_pos)
			HearingManager.emit(hit_pos, 0.4, shooter if is_instance_valid(shooter) else null)
		# Item drops at the hit point regardless of target liveness.
		if not item_id.is_empty():
			create_item(item_id, hit_pos, 1, extras)
	elif collider != null:
		if collider.has_method("take_damage"):
			collider.take_damage(thrown_damage.duplicate(), 0)
		if not item_id.is_empty():
			create_item(item_id, hit_pos, 1, extras)
		SfxManager.play("sword-fall", hit_pos)


func _on_thrown_projectile_expired(final_position: Vector2, item_id: String, extras: Dictionary = {}) -> void:
	_splash_if_fluid(final_position, 1.0)
	if not item_id.is_empty():
		create_item(item_id, final_position, 1, extras)
	SfxManager.play("sword-fall", final_position)

# ===== SELECTION CIRCLE DRAWER =====

class SelectionCircle extends Node2D:
	var radius: float = 30.0
	var circle_color: Color = Color.WHITE
	var line_width: float = 1.0
	var num_segments: int = 32
	
	func _draw() -> void:
		var points = PackedVector2Array()
		for i in range(num_segments + 1):
			var angle = (float(i) / num_segments) * TAU
			points.append(Vector2(cos(angle), sin(angle)) * radius)

		# Dark under-stroke first: now that the ring sits on the floor instead of
		# on top of the character, it has to hold contrast against pale stone.
		var shadow := Color(0.02, 0.03, 0.06, 0.45)
		for i in range(num_segments):
			draw_line(points[i], points[i + 1], shadow, line_width + 2.5, true)
		for i in range(num_segments):
			draw_line(points[i], points[i + 1], circle_color, line_width, true)
			
			
# ---------------------------------------------------------------------------
# World map: toggle, hidden warp reveal, water gathering
# ---------------------------------------------------------------------------

func toggle_world_map() -> void:
	"""Press M.

	From a local map: enter the Scarlatti world map at its default spawn (the
	rest of the party rides along inside party_state).
	From the world map: if the banner unit stands within any revealed warp's
	reveal_radius_px, take that warp. Otherwise no-op — the player must walk
	closer to a settlement before they can enter it. This makes M the
	"enter this place" hotkey rather than a free toggle."""
	if current_map_data.get("is_world_map", false):
		var nearest = _nearest_revealed_warp()
		if nearest == null:
			GameLog.add_entry("No settlement within reach.")
			return
		var target_map: String = String(nearest.get_meta("target_map", ""))
		if target_map.is_empty():
			return
		load_map(target_map, current_map_id)
	else:
		load_map(WORLD_MAP_ID)

func _nearest_revealed_warp() -> Area2D:
	"""Returns the closest world_warp Area2D within its reveal_radius_px of
	the banner unit, or null if none are in range."""
	if not player or not is_instance_valid(player):
		return null
	var banner_pos: Vector2 = player.global_position
	var best: Area2D = null
	var best_dist: float = INF
	for area in warp_zones:
		if not is_instance_valid(area):
			continue
		if not area.get_meta("world_warp", false):
			continue
		var radius: float = float(area.get_meta("reveal_radius_px", 200.0))
		var dist: float = banner_pos.distance_to(area.global_position)
		if dist <= radius and dist < best_dist:
			best_dist = dist
			best = area
	return best

func _update_world_warp_reveal() -> void:
	"""Show world-map warps only when the banner unit is within reveal_radius_px."""
	if not player or not is_instance_valid(player):
		return
	var banner_pos: Vector2 = player.global_position
	for area in warp_zones:
		if not is_instance_valid(area):
			continue
		if not area.get_meta("world_warp", false):
			continue
		var radius: float = float(area.get_meta("reveal_radius_px", 200.0))
		var dist: float = banner_pos.distance_to(area.global_position)
		var revealed: bool = dist <= radius
		area.visible = revealed
		# Toggling the collision_layer also gates left-click teleport probing.
		area.collision_layer = CollisionLayers.WARPS if revealed else 0

## Companions folded into the world-map banner have no body to tick their
## conditions: expire them in their party_state snapshots on the in-world
## clock, logging each as it runs out (see scripts/TravelConditionClock.gd).
## Swept four times a second, not every frame: these last hours, and at the
## world map's 7200x a quarter second is half an in-world hour.
var _banner_conditions_wait: float = 0.0
func _tick_banner_party_conditions(delta: float = 0.0) -> void:
	_banner_conditions_wait -= delta
	if _banner_conditions_wait > 0.0:
		return
	_banner_conditions_wait = 0.25
	var with_body := {}
	for idx in range(party_chars.size()):
		var c = party_chars[idx]
		if is_instance_valid(c):
			with_body[int(c.get_meta("party_index", idx))] = true
	for line in preload("res://scripts/TravelConditionClock.gd").expire_snapshots(party_state, with_body, TimeManager.absolute_time()):
		GameLog.add_entry(line)

func set_city_controller(city_id: String, faction_id: String) -> void:
	"""Quest hooks / scripted events call this to flip a city's territory color
	on the world map. Silently no-ops on local maps (the overlay isn't loaded).
	Returning to the world map later doesn't preserve the flip yet — the source
	of truth lives in current_map_data; persistence is a follow-up."""
	if _world_map_overlay and is_instance_valid(_world_map_overlay):
		_world_map_overlay.set_city_controller(city_id, faction_id)

func gather_water_at_party() -> void:
	"""Press G: if the player's current character stands adjacent to a water
	tile (a 'world_water' floor on the world map, or a registered water fluid
	on any map), gather a waterskin into their inventory."""
	if not primary_selected or not is_instance_valid(primary_selected):
		return
	var actor: ProceduralCharacter = primary_selected
	var actor_tile: Vector2i = GridManager.world_to_map(actor.global_position)
	if not _is_water_adjacent(actor_tile):
		GameLog.add_entry("No water within reach.")
		return
	if not actor.inventory:
		return
	if _refuse_during_trade(actor, "gather", "water"):
		return
	# Use the real database waterskin (sprite, Consume option, satiety) so the
	# gathered water drinks like any other; the stub is only a fallback.
	var water: Dictionary = _lookup_any_item("waterskin").duplicate(true)
	if water.is_empty():
		water = {
			"display_name": "Waterskin",
			"id": "waterskin",
			"is_stackable": true,
			"max_stack_size": 10,
		}
	# Drawn from a river, not taken from anyone: no ownership rides along.
	for k in ["owner_faction", "owner_uid", "stolen_from", "stolen_value"]:
		water.erase(k)
	var added: bool = actor.inventory.add_item(water)
	# A full pack is announced by the inventory itself (add_failed).
	if added:
		GameLog.add_entry(actor.Name + " gathers water into a waterskin.")
		SfxManager.play("chest_item_in", actor.global_position)

func _is_water_adjacent(tile: Vector2i) -> bool:
	# Checks the tile itself plus 8 neighbours. Counts a 'world_water' floor
	# or any registered water fluid as a valid water source.
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var t = tile + Vector2i(dx, dy)
			if _is_water_at_tile(t):
				return true
	return false

func _is_water_at_tile(tile: Vector2i) -> bool:
	var fid: String = GridManager.floors.get(tile, "")
	if fid == "world_water" or fid == "water":
		return true
	if fluid_manager and fluid_manager.get_fluid_type_at(tile) == "water":
		return true
	return false

func _create_warp_zones(warp_list: Array) -> void:
	for warp_def in warp_list:
		# Check warp conditions (e.g. need a key)
		if warp_def.has("condition") and not check_spawn_conditions(warp_def["condition"]):
			continue

		var pos_arr = warp_def.get("position", [0, 0])
		var size_arr = warp_def.get("size", [30, 30])
		var pos = Vector2(pos_arr[0], pos_arr[1])
		var size = Vector2(size_arr[0], size_arr[1])

		# Create an Area2D with a collision shape
		var area = Area2D.new()
		area.name = "Warp_" + warp_def.get("id", "unknown")
		area.position = pos
		area.set_meta("target_map", warp_def.get("target_map", ""))
		# Unset stays "" (as the readers default it): load_map then picks the
		# from_<map> arrival spawn, and a same-map warp reloads rather than
		# relocating the party to "default".
		area.set_meta("target_spawn", warp_def.get("target_spawn", ""))
		area.set_meta("label", warp_def.get("label", ""))
		# World-map warps stay hidden + unclickable until the party banner
		# gets within reveal_radius_px. _update_world_warp_reveal() flips the
		# arrow visibility and collision_layer each frame.
		if warp_def.get("world_warp", false):
			area.set_meta("world_warp", true)
			area.set_meta("reveal_radius_px", float(warp_def.get("reveal_radius_px", 200.0)))

		# Visible arrow sprite, scaled to a consistent display height
		var arrow := Sprite2D.new()
		arrow.texture = WARP_ARROW_TEXTURE
		var tex_size = arrow.texture.get_size()
		if tex_size.y > 0:
			var scale_factor = WARP_ARROW_DISPLAY_HEIGHT / tex_size.y
			arrow.scale = Vector2(scale_factor, scale_factor)
		arrow.rotation = _warp_arrow_rotation(warp_def, pos)
		arrow.z_index = 100
		area.add_child(arrow)

		# Hover label: the destination map's name, or the warp's own label for
		# same-map ladders/stairs and world-map settlements (_warp_hover_text)
		var hover_label := Label.new()
		hover_label.name = "HoverLabel"
		hover_label.text = _warp_hover_text(warp_def)
		hover_label.add_theme_color_override("font_color", Color(1, 1, 1))
		hover_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
		hover_label.add_theme_constant_override("outline_size", 6)
		hover_label.add_theme_font_size_override("font_size", 20)
		hover_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hover_label.size = Vector2(200, 28)
		hover_label.position = Vector2(-100, -WARP_ARROW_DISPLAY_HEIGHT * 0.75 - 14)
		hover_label.visible = false
		hover_label.z_index = 101
		hover_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		area.add_child(hover_label)

		var shape = CollisionShape2D.new()
		var rect_shape = RectangleShape2D.new()
		# The arrow sprite rotates with the warp's direction, so its bounding
		# box width/height swap for north/south arrows. Use the larger of
		# (texture width, texture height) for both axes so the picking rect
		# fully covers the sprite at any rotation.
		var arrow_world_size: Vector2 = tex_size * arrow.scale
		var max_arrow_dim = max(arrow_world_size.x, arrow_world_size.y)
		rect_shape.size = Vector2(
			max(size.x, max_arrow_dim),
			max(size.y, max_arrow_dim)
		)
		shape.shape = rect_shape
		area.add_child(shape)

		# Warps are detected via PhysicsPointQueryParameters2D from
		# ProceduralCharacter._handle_input — point probes against
		# CollisionLayers.WARPS find them for both left-click (teleport) and
		# right-click (context menu). Hover labels are toggled by per-frame
		# polling in _update_warp_hover_labels(). collision_mask = 0 keeps
		# warps non-colliding with characters, projectiles, vision rays, etc.
		area.collision_layer = CollisionLayers.WARPS
		area.collision_mask = 0

		add_child(area)
		warp_zones.append(area)

		# World-map warps spawn hidden and non-pickable until the party banner
		# closes within reveal_radius_px (see _update_world_warp_reveal).
		if area.get_meta("world_warp", false):
			area.visible = false
			area.collision_layer = 0

# Rotation in radians for the warp arrow sprite. The texture points east (+x),
# so 0 = east, PI/2 = south, PI = west, -PI/2 = north.
func _warp_arrow_rotation(warp_def: Dictionary, pos: Vector2) -> float:
	# 1. Explicit direction wins
	if warp_def.has("direction"):
		match String(warp_def["direction"]).to_lower():
			"east", "right":  return 0.0
			"south", "down":  return PI / 2.0
			"west", "left":   return PI
			"north", "up":    return -PI / 2.0

	# 2. Otherwise, infer from the warp's position relative to the map center:
	#    point toward the nearest edge.
	var map_size = Vector2(
		GridManager.map_rect.size.x * GridManager.TILE_SIZE,
		GridManager.map_rect.size.y * GridManager.TILE_SIZE
	)
	if map_size.x <= 0 or map_size.y <= 0:
		return 0.0
	var dx_left   = pos.x
	var dx_right  = map_size.x - pos.x
	var dy_top    = pos.y
	var dy_bottom = map_size.y - pos.y
	var min_dist = min(min(dx_left, dx_right), min(dy_top, dy_bottom))
	if min_dist == dx_right:
		return 0.0
	elif min_dist == dy_bottom:
		return PI / 2.0
	elif min_dist == dx_left:
		return PI
	else:
		return -PI / 2.0

func _warp_hover_text(warp_def: Dictionary) -> String:
	var target_id: String = warp_def.get("target_map", "")
	# Same-map ladders/stairs and world-map settlements name themselves: the
	# destination map's name would read "Tg Castle Demo" or the wrong town.
	var label: String = str(warp_def.get("label", ""))
	if not label.is_empty() and (warp_def.get("world_warp", false) or target_id == current_map_id):
		return label
	if not target_id.is_empty() and MapDatabase.get_all_map_ids().has(target_id):
		var target_data: Dictionary = MapDatabase.get_map_data(target_id)
		var map_name: String = target_data.get("name", "")
		if not map_name.is_empty():
			return map_name
	return warp_def.get("label", "")
		
func _check_condition(condition_key: String, condition_value = true) -> bool:
	# Time-of-day conditions read TimeManager directly. v1: no wrap-around (use both min/max for ranges within a single day).
	if condition_key == "time_hour_min":
		return TimeManager.current_hour >= int(condition_value)
	if condition_key == "time_hour_max":
		return TimeManager.current_hour <= int(condition_value)
	if not Globals.world_state.has(condition_key):
		push_warning("Missing world_state condition: " + condition_key)
		return false
	var actual = Globals.world_state[condition_key]
	# Support string comparison operators: ">3", "<5", ">=2", "<=10", "!=0"
	if condition_value is String:
		var op = ""
		var val_str = condition_value
		for prefix in [">=", "<=", "!=", ">", "<"]:
			if condition_value.begins_with(prefix):
				op = prefix
				val_str = condition_value.substr(prefix.length()).strip_edges()
				break
		if not op.is_empty():
			var num_val = float(val_str)
			var num_actual = float(actual)
			match op:
				">": return num_actual > num_val
				"<": return num_actual < num_val
				">=": return num_actual >= num_val
				"<=": return num_actual <= num_val
				"!=": return num_actual != num_val
			return false
	# Default: strict equality
	return actual == condition_value

func check_spawn_conditions(spawn_conditions: Dictionary) -> bool:
	for key in spawn_conditions:
		if not _check_condition(key, spawn_conditions[key]):
			return false
	return true

## After ConditionManager.from_dict on a respawned character: from_dict emits no
## condition_applied, and its clear_all_conditions already took the build-time
## VFX, SFX and icons down, so redo what that signal's handler shows for each
## restored instance (and re-suppress what was suppressed). A corpse gets none
## of it. Periodic saves only start once a last-save time exists
## (_try_periodic_save defaults it to "now" and returns), so seed one on the
## condition clock for every condition that rolls them.
func _restore_condition_presentation(character: ProceduralCharacter) -> void:
	var cm = character.condition_manager
	var now: float = TimeManager.absolute_time()
	var alive: bool = character.current_health > 0
	for inst in cm.conditions.values():
		if inst == null or inst.condition == null:
			continue
		if inst.condition.save_stat != "" and inst.condition.save_interval > 0.0:
			cm.last_save_times[inst.condition.id] = now
		if alive:
			character._spawn_condition_vfx(inst)
			character._start_condition_sfx(inst)
			if inst.is_suppressed:
				character._on_condition_suppressed(inst)
	if alive:
		character._refresh_condition_display()
		# _on_condition_applied's Invisible translucency (not while an attack
		# has it suppressed).
		if cm.has_active_condition("invisible"):
			character.modulate.a = 0.35

# ---------------------------------------------------------------------------
# Character state serialization (for party persistence)
# ---------------------------------------------------------------------------
 
func _serialize_character(character: ProceduralCharacter) -> Dictionary:
	## Captures all mutable runtime state that can diverge from the template.
	var state: Dictionary = {}
 
	# --- Identity ---
	state["Name"] = character.Name
	state["display_name"] = character.display_name
	state["faction_id"] = character.faction_id
	state["template_id"] = character.template_id
	state["race_id"] = character.race_id
	state["gender"] = character.gender
	state["creature_size"] = character.creature_size
	state["racial_features"] = character.racial_features.duplicate()
	state["traits"] = character.traits.duplicate()
	state["is_protagonist"] = character.is_protagonist
	state["AI_enabled"] = character.AI_enabled
	state["is_player_controlled"] = character.is_player_controlled

	# --- Core attributes ---
	state["strength"] = character.strength
	state["constitution"] = character.constitution
	state["dexterity"] = character.dexterity
	state["will"] = character.will
	state["intelligence"] = character.intelligence
	state["charisma"] = character.charisma
 
	# --- Attribute modifiers (permanent buffs/debuffs applied outside conditions) ---
	state["strength_modifier"] = character.strength_modifier
	state["constitution_modifier"] = character.constitution_modifier
	state["dexterity_modifier"] = character.dexterity_modifier
	state["will_modifier"] = character.will_modifier
	state["intelligence_modifier"] = character.intelligence_modifier
	state["charisma_modifier"] = character.charisma_modifier
	state["sight_modifier"] = character.sight_modifier
	state["hearing_modifier"] = character.hearing_modifier
	state["fov_modifier"] = character.fov_modifier
	state["mp_regen_modifier"] = character.mp_regen_modifier
	state["crit_threshold_modifier"] = character.crit_threshold_modifier
	state["crit_fail_modifier"] = character.crit_fail_modifier
	state["speed_modifier"] = character.speed_modifier
	state["base_speed_modifier"] = character.base_speed_modifier

	# --- Vitals ---
	state["MP"] = character.MP

	# --- Social / psychological state ---
	# These diverge from the template and are NOT derivable from anything else,
	# so they must ride the snapshot. They were previously omitted, which meant
	# load_map's snapshot-and-respawn wiped a companion's accumulated favour and
	# stress on every single warp. Anything that reads favorability across a map
	# boundary (downtime refusals, training departures) depends on this block.
	state["favorability"] = character.favorability
	state["stress"] = character.stress
	state["active_vows"] = character.active_vows.duplicate(true)
	state["captured_souls"] = character.captured_souls.duplicate(true)
	state["souls"] = character.souls
	state["patron_id"] = character.patron_id
	state["vow_holy_bonus"] = character.vow_holy_bonus
	state["vow_poverty_points"] = character.vow_poverty_points
	state["holy_tier_next_day_pending"] = character.holy_tier_next_day_pending
	state["holy_tier_today"] = character.holy_tier_today
	# School pools, luck and a stored Bide payoff. build_character refills every
	# pool to max (TopDownCharacterDatabase._init_school_resources), so without
	# these each warp refilled spent pools and dropped a pending Bide bonus.
	# Concentration is left out on purpose: it ends with the unload.
	state["adrenaline"] = character.adrenaline
	state["focus"] = character.focus
	state["harmony"] = character.harmony
	state["devotion"] = character.devotion
	state["saint_day_devotion_bonus"] = character.saint_day_devotion_bonus
	state["luck"] = character.luck
	state["bide_pending_bonus"] = character.bide_pending_bonus

	# --- Standing orders ---
	# WAIT survives map transitions and saves: party members are freed and
	# respawned on every warp, and a member parked outside a hazard must not
	# silently resume following (review find: the order evaporated per warp).
	state["hold_position"] = character.hold_position
 
	# --- Appearance ---
	state["skin_color"] = character.skin_color.to_html()
	state["hair_color"] = character.hair_color.to_html()
	state["hair_style"] = character.hair_style  # enum int
	state["body_size_mod"] = character.body_size_mod
 
	# --- Body dimensions ---
	state["body_width"] = character.body_width
	state["body_height"] = character.body_height
	state["head_width"] = character.head_width
	state["head_length"] = character.head_length
	state["shoulder_y_offset"] = character.shoulder_y_offset
 
	# --- Combat stats ---
	state["unarmed_strike_damage"] = character.unarmed_strike_damage
	state["unarmed_strike_damage_type"] = character.unarmed_strike_damage_type
	state["unarmed_on_hit_ability"] = character.unarmed_on_hit_ability
	state["CRIT_THRESHOLD"] = character.CRIT_THRESHOLD
	state["CRIT_FAIL_THRESHOLD"] = character.CRIT_FAIL_THRESHOLD
	state["bonus_damage"] = character.bonus_damage
	state["bonus_damage_against_trait"] = character.bonus_damage_against_trait.duplicate()
	state["restricted_actions_by_trait"] = character.restricted_actions_by_trait.duplicate()
	state["MODIFY_DURATION_BY_TRAIT"] = character.MODIFY_DURATION_BY_TRAIT.duplicate()
	state["targeting_confusion"] = character.targeting_confusion
 
	# --- Sensory ---
	state["sight"] = character.sight
	state["hearing"] = character.hearing
	state["fov_angle_degrees"] = character.fov_angle_degrees
 
	# --- MP regen ---
	state["mp_regen_amount"] = character.mp_regen_amount
	state["mp_regen_interval"] = character.mp_regen_interval
 
	# --- Dialogue ---
	state["dialogue_id"] = character.get("dialogue_id") if "dialogue_id" in character else ""
 
	# --- HP (single bar replaces the old per-limb HP) ---
	state["current_health"] = character.current_health

	# --- Severed limbs / wound state ---
	state["severed_limbs"] = character.severed_limbs.duplicate()
 
	# --- Inventory contents ---
	if character.inventory:
		state["inventory_items"] = []
		for item in character.inventory.items:
			if item is Dictionary:
				state["inventory_items"].append(item.duplicate())
 
	# --- Equipped weapons ---
	# Save weapon data so we can reconstruct them on load.
	# We serialize each equipped weapon's exportable data + which hand it's in.
	if character.inventory:
		state["equipped_weapons"] = []
		var inv = character.inventory
		for weapon in inv.equipped_weapons:
			var weapon_entry: Dictionary = {}
			# Determine hand from the new slot model
			if weapon == inv.main_hand_item:
				weapon_entry["hand"] = "Main"
			elif weapon == inv.off_hand_item:
				weapon_entry["hand"] = "Off"
			else:
				weapon_entry["hand"] = "Stowed"

			if weapon is WeaponShape and weapon.has_method("to_data"):
				weapon_entry["type"] = "weapon"
				weapon_entry["data"] = weapon.to_data()
			elif weapon is AbilityShape:
				weapon_entry["type"] = "ability"
				weapon_entry["data"] = {"ability_id": weapon.ability_id if "ability_id" in weapon else ""}
			else:
				weapon_entry["type"] = "unknown"
				weapon_entry["data"] = {}
			state["equipped_weapons"].append(weapon_entry)

		state["active_weapon_index"] = inv.active_weapon_index
 
	# --- Active conditions ---
	# Full instance snapshot via the ConditionManager serializer: expires_at
	# is absolute time and restores byte-for-byte, so timed conditions keep
	# their true remaining duration across a map transition. (The old
	# hand-rolled {id, stacks, expires_at} snapshot fed the absolute value
	# into apply_condition's RELATIVE duration slot on restore.)
	if character.condition_manager:
		state["condition_state"] = character.condition_manager.to_dict()
 
	# --- Cooldowns (ability cooldowns with remaining time) ---
	if character.cooldowns.size() > 0:
		state["cooldowns"] = character.cooldowns.duplicate()
 
	return state
 
 
func _deserialize_character(character: ProceduralCharacter, state: Dictionary) -> void:
	## Restores a character's runtime state from a previously saved snapshot.
	## Called AFTER build_character / load_from_data so the template is already applied.
	if state.is_empty():
		return
 
	# --- Identity ---
	# A blank Name is from a snapshot taken before build_character set it;
	# keep the template's (display) name rather than restoring the blank.
	if state.has("Name") and str(state["Name"]) != "":
		character.Name = state["Name"]
	if state.has("display_name"):
		character.display_name = state["display_name"]
	if state.has("faction_id"):
		character.faction_id = state["faction_id"]
	if state.has("template_id"):
		character.template_id = state["template_id"]
	if state.has("race_id"):
		character.race_id = state["race_id"]
	if state.has("gender"):
		character.gender = state["gender"]
	if state.has("creature_size"):
		character.creature_size = state["creature_size"]
	if state.has("racial_features"):
		character.racial_features = state["racial_features"]
	if state.has("traits"):
		character.traits = state["traits"]
	if state.has("is_protagonist"):
		character.is_protagonist = state["is_protagonist"]
	if state.has("AI_enabled"):
		character.AI_enabled = state["AI_enabled"]
	if state.has("is_player_controlled"):
		character.is_player_controlled = state["is_player_controlled"]

	# --- Core attributes ---
	if state.has("strength"):    character.strength = state["strength"]
	if state.has("constitution"): character.constitution = state["constitution"]
	if state.has("dexterity"):   character.dexterity = state["dexterity"]
	if state.has("will"):        character.will = state["will"]
	if state.has("intelligence"): character.intelligence = state["intelligence"]
	if state.has("charisma"):    character.charisma = state["charisma"]
 
	# --- Attribute modifiers ---
	if state.has("strength_modifier"):     character.strength_modifier = state["strength_modifier"]
	if state.has("constitution_modifier"): character.constitution_modifier = state["constitution_modifier"]
	if state.has("dexterity_modifier"):    character.dexterity_modifier = state["dexterity_modifier"]
	if state.has("will_modifier"):         character.will_modifier = state["will_modifier"]
	if state.has("intelligence_modifier"): character.intelligence_modifier = state["intelligence_modifier"]
	if state.has("charisma_modifier"):     character.charisma_modifier = state["charisma_modifier"]
	if state.has("sight_modifier"):        character.sight_modifier = state["sight_modifier"]
	if state.has("hearing_modifier"):      character.hearing_modifier = state["hearing_modifier"]
	if state.has("fov_modifier"):          character.fov_modifier = state["fov_modifier"]
	if state.has("mp_regen_modifier"):     character.mp_regen_modifier = state["mp_regen_modifier"]
	if state.has("crit_threshold_modifier"): character.crit_threshold_modifier = state["crit_threshold_modifier"]
	if state.has("crit_fail_modifier"):    character.crit_fail_modifier = state["crit_fail_modifier"]
	if state.has("speed_modifier"):        character.speed_modifier = state["speed_modifier"]
	if state.has("base_speed_modifier"):   character.base_speed_modifier = state["base_speed_modifier"]
 
	# --- Vitals ---
	if state.has("MP"):           character.MP = state["MP"]

	# --- Social / psychological state ---
	# Mirror of the serializer block. stress is clamped against max_stress, which
	# derives from will and is therefore already correct by this point (the
	# attribute restore runs above).
	if state.has("favorability"):  character.favorability = int(state["favorability"])
	if state.has("stress"):        character.stress = clamp(int(state["stress"]), 0, character.max_stress)
	if state.has("active_vows"):   character.active_vows = (state["active_vows"] as Dictionary).duplicate(true)
	if state.has("captured_souls"): character.captured_souls = (state["captured_souls"] as Array).duplicate(true)
	if state.has("souls"):         character.souls = int(state["souls"])
	if state.has("patron_id"):     character.patron_id = str(state["patron_id"])
	if state.has("vow_holy_bonus"): character.vow_holy_bonus = int(state["vow_holy_bonus"])
	if state.has("vow_poverty_points"): character.vow_poverty_points = int(state["vow_poverty_points"])
	if state.has("holy_tier_next_day_pending"):
		character.holy_tier_next_day_pending = int(state["holy_tier_next_day_pending"])
	if state.has("holy_tier_today"): character.holy_tier_today = int(state["holy_tier_today"])
	# School pools go back below, after the saved conditions (their maxima read
	# condition bonuses); saint_day_devotion_bonus feeds max_devotion.
	if state.has("saint_day_devotion_bonus"):
		character.saint_day_devotion_bonus = int(state["saint_day_devotion_bonus"])
	if state.has("luck"):       character.luck = int(state["luck"])
	if state.has("bide_pending_bonus"):
		character.bide_pending_bonus = maxf(0.0, float(state["bide_pending_bonus"]))

	# setter drives the stop-hand indicator, so restore re-shows the badge
	character.hold_position = bool(state.get("hold_position", false))
 
	# --- Appearance ---
	if state.has("skin_color"):
		character.skin_color = Color.html(state["skin_color"])
		character.body_color = character.skin_color.darkened(0.15)
	if state.has("hair_color"):
		character.hair_color = Color.html(state["hair_color"])
	if state.has("hair_style"):
		character.hair_style = state["hair_style"] as ProceduralCharacter.HairStyle
	if state.has("body_size_mod"):
		character.body_size_mod = state["body_size_mod"]
 
	# --- Body dimensions ---
	if state.has("body_width"):        character.body_width = state["body_width"]
	if state.has("body_height"):       character.body_height = state["body_height"]
	if state.has("head_width"):        character.head_width = state["head_width"]
	if state.has("head_length"):       character.head_length = state["head_length"]
	if state.has("shoulder_y_offset"): character.shoulder_y_offset = state["shoulder_y_offset"]
 
	# --- Combat stats ---
	if state.has("unarmed_strike_damage"):
		character.unarmed_strike_damage = state["unarmed_strike_damage"]
	if state.has("unarmed_strike_damage_type"):
		character.unarmed_strike_damage_type = state["unarmed_strike_damage_type"]
	if state.has("unarmed_on_hit_ability"):
		character.unarmed_on_hit_ability = state["unarmed_on_hit_ability"]
	if state.has("CRIT_THRESHOLD"):
		character.CRIT_THRESHOLD = state["CRIT_THRESHOLD"]
	if state.has("CRIT_FAIL_THRESHOLD"):
		character.CRIT_FAIL_THRESHOLD = state["CRIT_FAIL_THRESHOLD"]
	if state.has("bonus_damage"):
		character.bonus_damage = state["bonus_damage"]
	if state.has("bonus_damage_against_trait"):
		character.bonus_damage_against_trait = state["bonus_damage_against_trait"]
	if state.has("restricted_actions_by_trait"):
		character.restricted_actions_by_trait = state["restricted_actions_by_trait"]
	if state.has("MODIFY_DURATION_BY_TRAIT"):
		character.MODIFY_DURATION_BY_TRAIT = state["MODIFY_DURATION_BY_TRAIT"]
	if state.has("targeting_confusion"):
		character.targeting_confusion = state["targeting_confusion"]
 
	# --- Sensory ---
	if state.has("sight"):            character.sight = state["sight"]
	if state.has("hearing"):          character.hearing = state["hearing"]
	if state.has("fov_angle_degrees"): character.fov_angle_degrees = state["fov_angle_degrees"]
 
	# --- MP regen ---
	if state.has("mp_regen_amount"):   character.mp_regen_amount = state["mp_regen_amount"]
	if state.has("mp_regen_interval"): character.mp_regen_interval = state["mp_regen_interval"]
 
	# --- Dialogue ---
	if state.has("dialogue_id") and "dialogue_id" in character:
		character.dialogue_id = state["dialogue_id"]
 
	# --- HP (single bar) ---
	# Restored AFTER attributes so max_health (derived from constitution) is
	# already correct when we clamp. Falls back to max_health if missing.
	if state.has("current_health"):
		character.current_health = clamp(int(state["current_health"]), 0, character.max_health)
		character.health_changed.emit(character.current_health, character.max_health, character)

	# --- Severed limbs ---
	if state.has("severed_limbs"):
		character.severed_limbs = state["severed_limbs"]
		# Mirror the dict into each Limb's is_severed flag so the visual
		# update + equipment-drop logic stays consistent on reload.
		for limb_type in character.severed_limbs:
			if character.severed_limbs[limb_type] and character.limbs.has(limb_type):
				character.limbs[limb_type].is_severed = true
 
	# --- Inventory: clear template items, restore saved ones ---
	if character.inventory and state.has("inventory_items"):
		character.inventory.items.clear()
		# Restoring saved items must refuse none of them, and merge none: put
		# each saved dict back as it was. add_item would cap (a worn pack's
		# overflow, or a pack that left its wearer without coming off, e.g.
		# robbed) and fold a second stack of one id into the first one +1 at a
		# time ([10, 5, 7] arrows came back as [12]), dropping a stolen tag.
		# rebuild_worn_from_inventory below sets the real cap (worn packs' slots).
		# Announced per item as add_item did (panels, quest and vow listeners).
		for item_data in state["inventory_items"]:
			if item_data is Dictionary:
				character.inventory.items.append(item_data)
				character.inventory.item_added.emit(item_data)
		# The body still wears the template's gear (and its worn conditions):
		# put the saved gear back on from the _equipped flags.
		character.rebuild_worn_from_inventory()
 
	# --- Equipped weapons: reconstruct and equip ---
	if character.inventory and state.has("equipped_weapons"):
		# Clear any template-granted equipment first
		while character.inventory.equipped_weapons.size() > 0:
			var removed = character.inventory.unequip_weapon(0)
			if removed and removed is Node:
				removed.queue_free()
 
		for weapon_entry in state["equipped_weapons"]:
			var hand: String = weapon_entry.get("hand", "Main")
			var wtype: String = weapon_entry.get("type", "unknown")
			var data: Dictionary = weapon_entry.get("data", {})
 
			match wtype:
				"weapon":
					if not data.is_empty():
						if hand == "Stowed":
							character.inventory.stow_weapon_from_data(data)
						else:
							character.inventory.equip_weapon_from_data(data, hand)
				"ability":
					var ability_id = data.get("ability_id", "")
					if ability_id != "":
						if hand == "Stowed":
							character.inventory.stow_ability_from_id(ability_id)
						else:
							character.inventory.equip_ability_from_id(ability_id, hand)
 
		# Restore active weapon selection
		if state.has("active_weapon_index"):
			var idx = state["active_weapon_index"]
			if idx >= -1 and idx < character.inventory.equipped_weapons.size():
				character.inventory.set_active_weapon(idx)
 
	# A snapshot from before starting weapons stopped leaving a hidden item dict
	# beside their WeaponShape: drop those copies, and stow any weapon an AI
	# picked up as a dict (Inventory.migrate_hand_dicts). A corpse's weapon
	# dicts are its loot, so the dead keep theirs.
	if character.inventory and state.has("inventory_items") and character.current_health > 0:
		character.inventory.migrate_hand_dicts()

	# --- Conditions: restore saved instances (after inventory, which the
	# grants_ability re-grant guard relies on) ---
	if character.condition_manager and state.has("condition_state"):
		character.condition_manager.from_dict(state["condition_state"])
		_restore_condition_presentation(character)
 
	# School pools over the build-time refill, clamped to their maxima. Here,
	# not with the other stats: a maximum a condition raises (downtime's
	# Focused, +1 max focus) only counts once from_dict has recalculated the
	# stats; traits and vow_holy_bonus (max_devotion) were restored above.
	if state.has("adrenaline"): character.adrenaline = clamp(int(state["adrenaline"]), 0, character.max_adrenaline)
	if state.has("focus"):      character.focus = clamp(int(state["focus"]), 0, character.max_focus)
	if state.has("harmony"):    character.harmony = clamp(int(state["harmony"]), 0, character.max_harmony)
	if state.has("devotion"):   character.devotion = clamp(int(state["devotion"]), 0, character.max_devotion)

	# --- Cooldowns ---
	if state.has("cooldowns"):
		character.cooldowns = state["cooldowns"]
 
	# Refresh visuals after all state is restored
	if character.has_method("_update_colors"):
		character._update_colors()

	# A character saved at 0 HP is dead: re-enter the corpse state so it doesn't
	# respawn walking around. restore_dead_state skips the death scream/signal so
	# one-shot death events don't re-fire on every map transition.
	if character.current_health <= 0 and character.has_method("restore_dead_state"):
		character.restore_dead_state()
