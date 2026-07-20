# Game.gd
# Attach to your main scene or a manager node
extends Node

const ProceduralCharacterScript = preload("res://Characters/ProceduralCharacter.gd")
const WORLD_MAP_OVERLAY_SCRIPT = preload("res://WorldMap/WorldMapOverlay.gd")
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
var _pending_rival_spawns: Array = []
var _pending_rival_override_faction: bool = false


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
var current_map_id: String = "tg_castle_demo"  # TEMP: castle-demo export (set "tg_export" for the fort map, "cemetery" for the built-in)
var current_map_data: Dictionary = {}
var warp_zones: Array = []
var context_menu_open: bool = false
var stealth_mode: bool = false
# Session-scoped unlock memory, keyed "<map_id>|door|<hinge_x>,<hinge_y>" (export-px
# ints from the geometry JSON hinge). Written by Door.interact on successful unlock,
# re-applied by MapLoader on door spawn. Intentionally NOT cleared in
# _unload_current_map: every warp (incl. same-map stairs) is a full reload, and a
# consumed key must never soft-lock the player. Include in the save system when one lands.
var unlocked_locks: Dictionary = {}

const WORLD_MAP_ID: String = "scarlatti_world"
# Active WorldMapOverlay (only present while we're on a world map). Used by
# set_city_controller() to flip ownership at runtime, civ-style.
var _world_map_overlay: Node2D = null

var factions: Dictionary
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
]

# Service-NPC state per region. Lets trades and inventory changes survive
# map transitions and saves. Keyed by region_id -> npc_uid -> live_state dict
# (same shape as party_state[i].live_state).
var npc_state_per_region: Dictionary = {}

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

func set_downtime_mode(active: bool) -> void:
	if downtime_mode_active == active:
		return
	downtime_mode_active = active
	downtime_mode_changed.emit(active)

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

	load_map(current_map_id)
 
func save_party_state() -> void:
	## Snapshots every living party member's runtime state so it survives
	## map transitions and can be written to a save file.
	for i in range(party_state.size()):
		if i >= party_chars.size():
			break
		var character = party_chars[i]
		if not is_instance_valid(character):
			continue
		party_state[i]["live_state"] = _serialize_character(character)
 
 
func load_party_state_from_save(saved: Array) -> void:
	## Called when loading a save file. Replaces party_state entirely.
	party_state = saved


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

func _save_service_npc_states() -> void:
	## Walk the live scene; for any NPC with titles, snapshot its runtime state
	## into npc_state_per_region[region][uid].
	var region_id: String = RegionDatabase.get_region_for_map(current_map_id)
	if region_id.is_empty():
		return
	if not npc_state_per_region.has(region_id):
		npc_state_per_region[region_id] = {}
	for c in characters_in_scene:
		if c in party_chars:
			continue
		if not _is_service_npc(c):
			continue
		var template_id: String = str(c.get_meta("template_id", ""))
		if template_id.is_empty():
			# Fallback: derive from display_name (won't survive renames but is rare)
			template_id = str(c.display_name).to_lower().replace(" ", "_")
		var unique_name: String = str(c.get_meta("unique_name", ""))
		var uid: String = _build_npc_uid(template_id, unique_name)
		npc_state_per_region[region_id][uid] = _serialize_character(c)

func _maybe_restore_npc_state(npc, template_id: String, unique_name: String) -> void:
	## On NPC spawn, if we have a cached snapshot from a previous visit, replay it.
	## Also tags the live node with template_id + unique_name for save-on-unload.
	if not is_instance_valid(npc):
		return
	npc.set_meta("template_id", template_id)
	npc.set_meta("unique_name", unique_name)
	if not _is_service_npc(npc):
		return
	var region_id: String = RegionDatabase.get_region_for_map(current_map_id)
	if region_id.is_empty():
		return
	var bucket: Dictionary = npc_state_per_region.get(region_id, {})
	var uid: String = _build_npc_uid(template_id, unique_name)
	if bucket.has(uid):
		_deserialize_character(npc, bucket[uid])

func mark_service_seen(npc) -> void:
	## Records discovery so an illegal service shows up in the panel even
	## after the party leaves the map.
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
 
func _spawn_npcs(npc_list: Array) -> void:
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

			var npc = _spawn_character(template_id, pos, spawn_overrides)
			if npc:
				npc.AI_enabled = true
				# Per-spawn dialogue override (TopDownCharacterDatabase only reads
				# template.dialogue; we wire the spawn-level override here).
				if spawn_overrides.has("dialogue") and "dialogues" in npc:
					npc.dialogues = [str(spawn_overrides["dialogue"])]
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

	load_map("colosseum")

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
		return
	var new_images: Dictionary = new_map_data.get("images", {})
	var validate_path: String = new_images.get("structures", "")
	if validate_path.is_empty() or not ResourceLoader.exists(validate_path):
		validate_path = new_images.get("map", "")
	if validate_path.is_empty() or not ResourceLoader.exists(validate_path):
		push_error("Map '%s' has no loadable image (looked for %s); aborting load." % [map_id, new_images])
		return

	# Save party state before cleaning up (preserves HP, inventory, etc.)
	if not party_chars.is_empty():
		save_party_state()

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

	if structured:
		map_loader.world_map_mode = false
		map_loader.generate_structured_map(current_map_data)
	else:
		map_loader.world_map_mode = is_world_map
		map_loader.world_render_scale = world_render_scale
		map_loader.map_image_path = images.get("map", "")
		map_loader.mask_image_path = images.get("mask", "")
		map_loader.structure_map_image_path = images.get("structures", "")
		map_loader.structure_mask_path = images.get("structures_mask", "")
		map_loader.generate_map()

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

	# 6. Spawn NPCs
	_spawn_npcs(current_map_data.get("npc_spawns", []))

	# 6b. Spawn combat-test rivals if any are pending
	if not _pending_rival_spawns.is_empty():
		_spawn_rival_party()

	# 7. Spawn items
	_spawn_items(current_map_data.get("item_spawns", []))

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
	_save_service_npc_states()

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

	# Clear weather VFX
	if weather_vfx_controller:
		weather_vfx_controller.clear_all()

	GridManager.set_elevation_data(null)

	current_map_id = ""
	current_map_data = {}

# ---------------------------------------------------------------------------
# Ambient setup (fog + music)
# ---------------------------------------------------------------------------

func setup_map_fogs(map_data: Dictionary) -> void:
	if not fog_manager:
		return
	fog_manager.clear_all_fog()
	for fog_id in map_data.get("fog_ids", []):
		fog_manager.create_fog_from_id(fog_id)

func setup_map_music(map_data: Dictionary) -> void:
	var track: String = map_data.get("music_track", "")
	if not track.is_empty():
		MusicManager.play(track)
	else:
		MusicManager.stop()

func setup_map_weather(map_data: Dictionary) -> void:
	var weather_group: String = map_data.get("weather_group", "")
	if weather_vfx_controller:
		if weather_group.is_empty():
			weather_vfx_controller.clear_all()
		else:
			weather_vfx_controller.setup_for_map(weather_group)
	if weather_debug_window and weather_debug_window.has_method("set_weather_group"):
		weather_debug_window.set_weather_group(weather_group)
	# Apply initial weather effects to fluids
	if not weather_group.is_empty():
		var weather = WeatherManager.get_weather(weather_group)
		if not weather.is_empty():
			_apply_weather_fluid_effects(weather)

## Force a precipitation type onto the current map, e.g. from a weather spell.
## Works regardless of the map's configured weather_group (most maps have none).
func force_weather(precip_type: String) -> void:
	var map_group: String = current_map_data.get("weather_group", "")
	if not map_group.is_empty():
		# Map has a real weather group: update it normally. The resulting
		# weather_changed signal drives both the VFX controller and fluid effects.
		WeatherManager.set_precipitation(map_group, precip_type)
		return
	# Map has no weather group (interiors/dungeons): drive the VFX and fluid
	# effects directly, since no group state exists for the signal path to use.
	if weather_vfx_controller and weather_vfx_controller.has_method("force_precipitation"):
		weather_vfx_controller.force_precipitation(precip_type)
	_apply_weather_fluid_effects({"precipitation": precip_type})

func _on_weather_changed(group: String, weather_state: Dictionary) -> void:
	var map_group = current_map_data.get("weather_group", "")
	if group != map_group or map_group.is_empty():
		return
	_apply_weather_fluid_effects(weather_state)

func _apply_weather_fluid_effects(weather: Dictionary) -> void:
	var precip = weather.get("precipitation", "clear")
	match precip:
		"snow", "heavy_snow", "freezing_rain":
			# Freeze all existing fluids
			if surface_manager:
				surface_manager.try_freeze_all_fluids()
		"rain", "heavy_rain", "acid_rain":
			# Spawn random water puddles across walkable tiles
			_spawn_rain_puddles(precip)

func _spawn_rain_puddles(precip_type: String) -> void:
	if not fluid_manager:
		return
	var puddle_count: int = 5 if precip_type == "rain" else 12
	var amount: float = 0.3 if precip_type == "rain" else 0.6
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
		fluid_manager.register_fluid(tile, "water", amount)
		placed += 1

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
		var offset = Vector2(i * 40, 0) if not is_world_map else Vector2.ZERO
		# Elevation-aware line spawn: on a narrow surface (ladder-top deck, a
		# battlement walkway ~20px wide) the +x row walks later members off the
		# edge — they'd land at ground level beside the wall, or inside it.
		# Collapse onto the base position when the offset tile's surface
		# differs; the separation nudge spreads them out safely after spawn.
		if offset != Vector2.ZERO:
			var bt := GridManager.world_to_map(base_pos)
			var ot := GridManager.world_to_map(base_pos + offset)
			if ot != bt and (not GridManager.can_step(bt, ot)
					or GridManager.grid_costs.get(ot, INF) == INF):
				offset = Vector2.ZERO
		var character = _spawn_character(entry["template_id"], base_pos + offset, entry.get("overrides", {}))
		if not character:
			continue

		party_chars.append(character)
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

		# All party members share the player faction so AI won't target allies
		character.faction_id = "player"
		# Re-wire ally-witness now that faction_id is final (spawn-time wiring
		# happens before this assignment, so no party connections form there).
		_wire_ally_witness(character)

		# Add line-of-sight light
		_add_line_of_sight_light(character)

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

		for j in range(count):
			create_item(item_id, pos, 1, extras)

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

		# Spawn fluid at center tile and optionally in a radius
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				if Vector2(dx, dy).length() <= radius + 0.5:
					var tile = center_tile + Vector2i(dx, dy)
					if not GridManager.walls.get(tile, false):
						fluid_manager.register_fluid(tile, fluid_type, amount)

# ---------------------------------------------------------------------------
# Context menu
# ---------------------------------------------------------------------------

func show_context_menu(target, position: Vector2) -> void:
	var context_menu = preload("res://UI/ContextMenu.tscn").instantiate()
	context_menu.global_position = position + Vector2(16, 16)
	context_menu.z_index = 100
	context_menu_open = true

	var options: Array = []
	if target is ProceduralCharacter:
		options = target.get("interact_options").duplicate() if "interact_options" in target else ["Inspect"]
		# Inject "Trade" for any non-hostile character. FactionDatabase is the
		# authoritative relationship source (Game.factions is unused in current
		# code paths). Treat allies/neutrals as tradeable; only true enemies
		# are blocked.
		if not FactionDatabase.are_enemies("player", target.faction_id) and not "Trade" in options:
			options.append("Trade")
	elif target is Area2D and target.has_meta("target_map"):
		options = ["Enter " + target.get_meta("label", "area")]
	elif target is Door:
		options = target.get_interact_options()
	elif target is Item:
		options = _world_item_options(target)
	elif target is Dictionary:
		# Item context menu — use interact_options from item data
		options = target.get("interact_options", ["Use", "Drop"])

	context_menu.setup(target, options)
	$GameUI.add_child(context_menu)

## World-item context menu options. Readables keep Read/Take; containers keep
## their own options (Open/Inspect); every other world item is pick-up-able.
func _world_item_options(item: Item) -> Array:
	if item.item_type == "readable":
		return item.options.duplicate() if item.options else ["Read"]
	var is_container: bool = item.num_slots > 0 or (item.options.size() > 0 and str(item.options[0]) == "Open")
	if is_container:
		return item.options.duplicate() if item.options else ["Open"]
	# A loose world item: the world action is to pick it up. Intrinsic actions
	# (Consume/Throw/Equip) and "Drop" belong to the inventory context menu.
	return ["Pick Up"]

## Pick up a world item into a party member's inventory, then remove it from the
## world. Returns true on success. Readables are excluded (they use Read/Take).
func pick_up_item(item: Item) -> bool:
	if not is_instance_valid(item):
		return false
	var character = _resolve_pickup_character()
	if character == null:
		GameLog.add_entry("No one is free to pick that up.")
		return false
	var data: Dictionary = item.to_inventory_data()
	if data.is_empty():
		return false
	var equip_slot: String = str(data.get("equip_slot", ""))
	var ok: bool = false
	if (equip_slot == "Main Hand" or equip_slot == "Off Hand") and character.inventory.has_method("stow_weapon_from_data"):
		character.inventory.stow_weapon_from_data(data)
		ok = true
	else:
		ok = character.inventory.add_stack(data)
	if ok:
		if SfxManager and SfxManager.has_method("play"):
			SfxManager.play("pickup", item.global_position)
		item._destroy_item()
	else:
		GameLog.add_entry("%s's inventory is full." % character.Name)
	return ok

# Pick the party member who should receive a picked-up item: the primary-selected
# character, else the first party member with an inventory.
func _resolve_pickup_character():
	if primary_selected != null and is_instance_valid(primary_selected) and primary_selected.inventory != null:
		return primary_selected
	for c in party_chars:
		if is_instance_valid(c) and ("inventory" in c) and c.inventory != null:
			return c
	return null

# ---------------------------------------------------------------------------
# Chest inventory + Trade windows
# ---------------------------------------------------------------------------

func show_chest_inventory(item: Item) -> void:
	if not is_instance_valid(item):
		return
	var ChestWindow = preload("res://UI/ChestInventoryWindow.tscn")
	var w = ChestWindow.instantiate()
	w.chest_item = item
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

func _add_line_of_sight_light(character: ProceduralCharacter) -> void:
	var light = PointLight2D.new()
	light.texture = Globals.SIGHT_TEXTURE
	light.energy = 0.1
	var master_radius = 512.0
	var desired_radius = 1440.0 * character.sight
	light.texture_scale = desired_radius / master_radius
	light.name = "LineOfSight"
	light.rotation_degrees = -90
	light.shadow_enabled = true
	light.shadow_item_cull_mask = CollisionLayers.SIGHT_MASK_HIGH if character.current_elevation >= 1.0 else CollisionLayers.SIGHT_MASK_GROUND
	light.z_index = 102
	character.add_child(light)

func _add_npc_line_of_sight_light(npc: ProceduralCharacter) -> void:
	"""Add a LOS cone as a child of the NPC. Hidden unless stealth mode is on.
	When the NPC is hidden (not in party LOS), the light hides with it."""
	var light = PointLight2D.new()
	light.texture = Globals.SIGHT_TEXTURE
	light.energy = 0.5
	light.color = Color(1.0, 0.3, 0.2)  # strong red tint
	var master_radius = 512.0
	var desired_radius = 1440.0 * npc.sight
	light.texture_scale = desired_radius / master_radius
	light.name = "NPCLineOfSight"
	light.rotation_degrees = -90
	light.shadow_enabled = true
	light.shadow_item_cull_mask = CollisionLayers.SIGHT_MASK_HIGH if npc.current_elevation >= 1.0 else CollisionLayers.SIGHT_MASK_GROUND
	# Illuminate layer 1 (normal scene objects) so the cone is actually visible
	light.range_item_cull_mask = 1
	light.z_index = 102
	light.visible = false
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

	add_child(item_instance)
	items_in_scene.append(item_instance)

	# Connect signals
	item_instance.destroyed.connect(_on_item_destroyed)

	return item_instance

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
		var npc_los = character.get_node_or_null("NPCLineOfSight")
		if npc_los:
			npc_los.visible = stealth_mode

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
	# The victim's own AI wake-up is handled in ai.gd via the same signal —
	# this function only handles witnesses.
	for c in characters_in_scene:
		if c == victim or c == attacker:
			continue
		if not is_instance_valid(c) or not c.has_method("is_alive") or not c.is_alive():
			continue
		# Skip party members — they're player-controlled, not AI-driven. Bumping
		# their alertness puts a "?" over their head every time the player swings
		# a sword, which is just noise.
		if c in party_chars:
			continue
		var ai_node = c.get_node_or_null("AI")
		if not ai_node or not ai_node.has_method("wake_from_at_ease"):
			continue
		# LOS on the victim required — must literally see the attack.
		if not _has_visual_los(c, victim.global_position):
			continue
		# 65 = SEARCHING threshold (60) + a bit; witnesses move out
		# immediately, but the source identity still has to be confirmed via
		# LOS for HOSTILE (handled by existing target acquisition).
		ai_node.wake_from_at_ease(65.0, location)


# Shared LOS check helper: position visible to `from_char` given their FOV,
# sight range, and any wall occlusion. Mirrors the per-ally checks already
# inlined in `_update_npc_los_visibility`.
func _has_visual_los(from_char: ProceduralCharacter, target_pos: Vector2) -> bool:
	if not is_instance_valid(from_char) or not from_char.has_method("is_alive") or not from_char.is_alive():
		return false
	var cm = from_char.get_node_or_null("ConditionManager")
	if cm and (cm.has_condition("blinded") or cm.has_condition("unconscious")):
		return false
	var to_target: Vector2 = target_pos - from_char.global_position
	var dist: float = to_target.length()
	if dist > 1440.0 * from_char.sight:
		return false
	var facing_dir: Vector2 = Vector2.UP.rotated(from_char.rotation)
	var angle: float = facing_dir.angle_to(to_target.normalized())
	if abs(angle) > deg_to_rad(from_char.fov_angle_degrees * 0.5):
		return false
	return _sight_line_clear(from_char.global_position, target_pos, from_char.get_elevation())


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
		var seen = false
		for ally in party_chars:
			if not is_instance_valid(ally) or not ally.is_alive():
				continue
			var _cm = ally.get_node_or_null("ConditionManager")
			if _cm and (_cm.has_condition("blinded") or _cm.has_condition("unconscious")):
				continue
			var to_npc = npc.global_position - ally.global_position
			var dist = to_npc.length()
			var sight_range = 1440.0 * ally.sight
			if dist > sight_range:
				continue
			var facing_dir = Vector2.UP.rotated(ally.rotation)
			var angle_to_npc = facing_dir.angle_to(to_npc.normalized())
			var half_fov = deg_to_rad(ally.fov_angle_degrees * 0.5)
			if abs(angle_to_npc) <= half_fov and _sight_line_clear(ally.global_position, npc.global_position, ally.get_elevation(), npc.get_elevation()):
				seen = true
				break

		var was_truly_seen: bool = _npc_was_truly_seen.get(npc, false)
		_npc_was_truly_seen[npc] = seen

		if seen:
			# Direct line of sight overrides any pulse.
			npc.visible = true
			npc.modulate.a = 1.0
			_npc_pulse_remaining.erase(npc)
			# Mark as "ever seen" for the radar-vs-sprite-pulse branch in
			# trigger_hearing_pulse. Persists for the map session.
			_npc_ever_seen[npc] = true
			# Discovery: first time we lay eyes on a service NPC, mark them
			# known so they appear in the TownServicesPanel even after leaving.
			if not was_truly_seen:
				mark_service_seen(npc)
		elif _npc_pulse_remaining.has(npc):
			var t_remaining: float = _npc_pulse_remaining[npc]
			var t_norm: float = clamp(1.0 - (t_remaining / PULSE_DURATION), 0.0, 1.0)
			var alpha: float = _hearing_pulse_curve(t_norm) * PULSE_ALPHA
			npc.visible = true
			npc.modulate.a = alpha
		else:
			npc.visible = false
			npc.modulate.a = 0.0

func _sight_line_clear(from_pos: Vector2, to_pos: Vector2, viewer_elev: float = 0.0, target_elev: float = 0.0) -> bool:
	var viewport := get_viewport()
	if not viewport or not viewport.world_2d:
		return true
	return GridManager.sight_line_clear(viewport.world_2d.direct_space_state, from_pos, to_pos, viewer_elev, target_elev)


func _is_position_visible_to_party(target_pos: Vector2) -> bool:
	"""True if any non-blinded party member has the position in sight range,
	inside their FOV cone, and on a clear LOS line. Mirrors the per-ally
	checks in _update_npc_los_visibility."""
	for ally in party_chars:
		if not is_instance_valid(ally) or not ally.is_alive():
			continue
		var cm = ally.get_node_or_null("ConditionManager")
		if cm and (cm.has_condition("blinded") or cm.has_condition("unconscious")):
			continue
		var to_target = target_pos - ally.global_position
		var dist = to_target.length()
		if dist > 1440.0 * ally.sight:
			continue
		var facing_dir = Vector2.UP.rotated(ally.rotation)
		var angle = facing_dir.angle_to(to_target.normalized())
		if abs(angle) > deg_to_rad(ally.fov_angle_degrees * 0.5):
			continue
		if _sight_line_clear(ally.global_position, target_pos, ally.get_elevation()):
			return true
	return false


func _update_item_los_visibility() -> void:
	"""Items follow the same visibility rule as NPCs."""
	for item in items_in_scene:
		if not is_instance_valid(item):
			continue
		item.visible = _is_position_visible_to_party(item.global_position)

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
	# Update all selection indicators
	for character in selection_indicators.keys():
		if is_instance_valid(character):
			selection_indicators[character].global_position = character.global_position
			selection_indicators[character].visible = PauseManager.is_paused
		else:
			selection_indicators[character].queue_free()
			selection_indicators.erase(character)
	# Tick hearing pulse timers before applying visibility, so freshly-expired
	# pulses go fully transparent this frame instead of next.
	_tick_hearing_pulses(delta)
	# Update NPC and item visibility based on party line-of-sight
	_update_npc_los_visibility()
	_update_item_los_visibility()
	# Camera follows primary selected character (unless user is WASD-panning)
	if primary_selected and is_instance_valid(primary_selected) and player_camera \
			and not player_camera.manual_pan_active:
		player_camera.global_position = player_camera.global_position.lerp(
			primary_selected.global_position, 5.0 * delta)
	# Toggle warp hover labels by polling — Area2D mouse_entered/exited is
	# unreliable when overlapping pickable areas exist (characters, items).
	_update_warp_hover_labels()
	# On the world map, reveal city warps only when the banner unit is near.
	if current_map_data.get("is_world_map", false):
		_update_world_warp_reveal()

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
		if weapon.get("traits") and "melee" in weapon.traits:
			var str_bonus = attacker.strength / 10.0
			for dtype in attack_damage:
				attack_damage[dtype] += str_bonus
	else:
		# Unarmed (or AbilityShape held while combat collision detection runs).
		attack_damage = {
			attacker.unarmed_strike_damage_type:
				attacker.unarmed_strike_damage + attacker.strength / 10.0
		}

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
		SfxManager.play("impact", target.global_position)
		HearingManager.emit(target.global_position, 0.8, attacker)

	# Trigger weapon ability on non-bounced hits
	if weapon and penetration_result.state != PenetrationState.BOUNCED:
		if weapon.get("use_ability") and weapon.get("ability"):
			attacker._resolve_ability_effects(weapon.ability, hit_position)

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
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_F12:
				if not event.echo:
					DebugManager.toggle()
			KEY_R:
				# Restart
				get_tree().reload_current_scene()
			KEY_P:
				# Print status
				_print_status()
			KEY_C:
				if not event.echo:
					stealth_mode = not stealth_mode
					_toggle_npc_los_cones()

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
	indicator.z_index = 100
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
			character.is_player_controlled = true
			character.AI_enabled = false
		else:
			character.is_player_controlled = false
			character.AI_enabled = true

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
	if character == player:
		print("\n=== GAME OVER ===")
		print("Press R to restart")

func _print_status() -> void:
	print("\n=== STATUS ===")
	print("Player: %s" % player.get_stats_string())
	# get_status_string now lives on ProceduralCharacter itself and prints
	# the single HP pool plus any severed/disabled limbs.
	print(player.get_status_string())
	print("")
	for i in range(enemies.size()):
		var enemy = enemies[i]
		if enemy.is_alive():
			print("Enemy %d: %s" % [i+1, enemy.get_stats_string()])



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
		if weapon.get("traits") and "melee" in weapon.traits:
			var str_bonus = attacker.strength / 10.0
			# Get all damage type keys (e.g., ["physical", "fire"])
			var damage_types = attack_damage.keys()
			# Apply to the first one available, provided the dictionary isn't empty
			if damage_types.size() > 0:
				var first_type = damage_types[0]
				attack_damage[first_type] += str_bonus
	else:
		attack_damage = {
			attacker.unarmed_strike_damage_type:
				attacker.unarmed_strike_damage + attacker.strength / 10.0
		}

	# Bide payoff: add accumulated bonus to the first damage type and consume it
	if "bide_pending_bonus" in attacker and attacker.bide_pending_bonus > 0.0:
		var dt_keys = attack_damage.keys()
		if dt_keys.size() > 0:
			attack_damage[dt_keys[0]] += attacker.bide_pending_bonus
			attacker.bide_pending_bonus = 0.0

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

	# Trigger weapon ability only if we actually penetrated
	if weapon and penetration_result.state != PenetrationState.BOUNCED:
		if weapon.get("use_ability") and weapon.get("ability"):
			attacker._resolve_ability_effects(weapon.ability, hit_position)

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
		SfxManager.play("clash", attacker.position)
		HearingManager.emit(attacker.position, 0.9, attacker)
		emit_signal("weapon_bounced", attacker, target, limb_type)
	else:
		SfxManager.play("sword-on-flesh", target.position)
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

func register_attack_end(attacker: Node2D) -> void:
	"""Called when an attack ends - clears hit tracking"""
	active_hits.erase(attacker.get_instance_id())

const MELEE_ELEV_TOLERANCE := 0.75

func _elev_of(n: Node2D) -> float:
	if n.has_method("get_elevation"):
		return n.get_elevation()
	# Structures: tile under their center — a parapet on deck tiles reads deck
	# elevation (unhittable from ground); a ground wall reads terrain.
	return GridManager.effective_elev(GridManager.world_to_map(n.global_position))

func can_hit_target(attacker: Node2D, target: Node2D) -> bool:
	"""Check if this attack can still hit this target (hasn't already)"""
	# Melee cannot reach across stories (deck walker vs ground character).
	if absf(_elev_of(attacker) - _elev_of(target)) > MELEE_ELEV_TOLERANCE:
		return false

	var attacker_id = attacker.get_instance_id()
	var target_id = target.get_instance_id()

	if not active_hits.has(attacker_id):
		return true

	return not active_hits[attacker_id].has(target_id)

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

	get_tree().current_scene.add_child(proj)
	proj.launch(shooter.get_weapon_tip_world_position(), direction, shooter)
	return proj


func _splash_if_fluid(world_pos: Vector2, strength: float = 1.1) -> void:
	"""Spawn a splash ripple if a fluid tile exists at this world position."""
	if fluid_manager and fluid_manager.get_fluid_type_at(GridManager.world_to_map(world_pos)) != "":
		fluid_manager.add_ripple(world_pos, strength)

func _on_weapon_projectile_hit(collision: KinematicCollision2D, shooter: ProceduralCharacter, weapon: WeaponShape) -> void:
	var collider := collision.get_collider()
	var hit_pos: Vector2 = collision.get_position()
	_splash_if_fluid(hit_pos, 1.1)
	if collider is ProceduralCharacter:
		# body_collision_shape is disabled on death, so live collisions imply a
		# living target — but guard anyway in case of mid-frame state changes.
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
	target.take_damage(attack_damage, local_hit, shooter, limb_type)

	if weapon.weapon_type == WeaponShape.WeaponType.PISTOL:
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

	proj.hit.connect(_on_thrown_projectile_hit.bind(item_id, thrown_damage, proj_data["shooter"]))
	proj.expired.connect(_on_thrown_projectile_expired.bind(item_id))

	get_tree().current_scene.add_child(proj)
	proj.launch(proj_data["position"], velocity_vec, proj_data["shooter"])


func _on_thrown_projectile_hit(collision: KinematicCollision2D, item_id: String, thrown_damage: Dictionary, shooter) -> void:
	var collider := collision.get_collider()
	var hit_pos: Vector2 = collision.get_position()
	_splash_if_fluid(hit_pos, 1.1)
	if collider is ProceduralCharacter:
		if collider.is_alive():
			var local_hit: Vector2 = collider.to_local(hit_pos)
			var limb_type: int = collider.get_limb_at_position(local_hit, collider.body_width, collider.body_height)
			collider.take_damage(thrown_damage.duplicate(), local_hit, shooter, limb_type)
		# Item drops at the hit point regardless of target liveness.
		if not item_id.is_empty():
			create_item(item_id, hit_pos)
	elif collider != null:
		if collider.has_method("take_damage"):
			collider.take_damage(thrown_damage.duplicate(), 0)
		if not item_id.is_empty():
			create_item(item_id, hit_pos)
		SfxManager.play("sword-fall", hit_pos)


func _on_thrown_projectile_expired(final_position: Vector2, item_id: String) -> void:
	_splash_if_fluid(final_position, 1.0)
	if not item_id.is_empty():
		create_item(item_id, final_position)
	SfxManager.play("sword-fall", final_position)

# ===== SELECTION CIRCLE DRAWER =====

class SelectionCircle extends Node2D:
	var radius: float = 30.0
	var circle_color: Color = Color.WHITE
	var line_width: float = 1.0
	var num_segments: int = 32
	
	func _draw() -> void:
		# Draw circle outline
		var points = PackedVector2Array()
		for i in range(num_segments + 1):
			var angle = (float(i) / num_segments) * TAU
			points.append(Vector2(cos(angle), sin(angle)) * radius)
		
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
	var added: bool = actor.inventory.add_item({
		"display_name": "Waterskin",
		"id": "waterskin",
		"is_stackable": true,
		"max_stack_size": 10,
	})
	if added:
		GameLog.add_entry(actor.Name + " gathers water into a waterskin.")
		SfxManager.play("pickup", actor.global_position)
	else:
		GameLog.add_entry("Inventory full — can't carry more water.")

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
		area.set_meta("target_spawn", warp_def.get("target_spawn", "default"))
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

		# Hover label with the destination map's name (falls back to warp label)
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

	# --- Vitals ---
	state["MP"] = character.MP
 
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
	if character.condition_manager:
		state["active_conditions"] = []
		for cond_id in character.condition_manager.conditions:
			var instance = character.condition_manager.conditions[cond_id]
			state["active_conditions"].append({
				"id": cond_id,
				"stacks": instance.stacks,
				"expires_at": instance.expires_at if instance.get("expires_at") != null else -1.0,
			})
 
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
	if state.has("Name"):
		character.Name = state["Name"]
	if state.has("display_name"):
		character.display_name = state["display_name"]
	if state.has("faction_id"):
		character.faction_id = state["faction_id"]
	if state.has("template_id"):
		character.template_id = state["template_id"]
	if state.has("race_id"):
		character.race_id = state["race_id"]
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
 
	# --- Vitals ---
	if state.has("MP"):           character.MP = state["MP"]
 
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
		for item_data in state["inventory_items"]:
			character.inventory.add_item(item_data)
 
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
 
	# --- Conditions: reapply saved conditions ---
	if character.condition_manager and state.has("active_conditions"):
		for cond_entry in state["active_conditions"]:
			var cond_id: String = cond_entry.get("id", "")
			var stacks: int = cond_entry.get("stacks", 1)
			var expires: float = cond_entry.get("expires_at", -1.0)
			if cond_id != "":
				character.condition_manager.apply_condition(cond_id, null, stacks, expires)
 
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
