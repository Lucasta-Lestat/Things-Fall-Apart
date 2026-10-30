extends Node2D
# Light sources reach the game (P2-C, docs/export_contract.md in Terrain
# Generation):
#   1. a contract-2 Maps.json row's "lights" list becomes one PointLight2D per
#      row under MapLoader's MapLights node: position, level -> radius/energy
#      (EquipmentEffects.make_light), colour (absent = the fire colour), shadow
#      flag (absent = shadowed with LIGHT_SHADOW_MASK); malformed rows are
#      skipped and MAP_LIGHTS_MAX caps the count;
#   2. a row without "lights" (contract 1) spawns no map lights at all;
#   2b. map lights stay dark under the unexplored fog until a tile next to
#      them is explored (MapLoader.update_map_light_visibility);
#   3. the placed fire props (brazier, campfire, torch) emit light through
#      Items.json emits_light in the explicit warm light_color, not a trait.
# Synthetic map through the real generate_structured_map; this node stands in
# for Game (group "game", current scene). Headless-safe.
#   godot --headless --path . res://tests/map_lights_check.tscn
# Judge by the PASS/FAIL lines and "MAP LIGHTS DONE: N checks, M FAIL".

const MAP_LOADER := preload("res://Structures/MapLoader.gd")
const ITEM_SCENE := preload("res://Structures/Objects/Item.tscn")
const EquipmentEffects = preload("res://Items/equipment_effects.gd")
const FIRE := Color(1.0, 0.6, 0.25)

# --- Game stand-in state (read by the scripts under test) ---
var characters_in_scene: Array = []
var items_in_scene: Array = []
var party_chars: Array = []
var selected_characters: Array = []
var context_menu_open := false
var primary_selected = null
var stealth_mode := false
var current_map_data: Dictionary = {}
var current_map_id := "map_lights_test"
var fog_manager = null
var map_loader = null

var _fails := 0
var _checks := 0


func is_seen_by_party(c) -> bool:
	return c in party_chars


func _report(check_name: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("%s %s: %s" % ["PASS" if ok else "FAIL", check_name, detail])


func _ready() -> void:
	add_to_group("game")
	TimeManager.pause_time()
	GridManager.TILE_SIZE = 64
	GridManager.initialize(1024, 1024)
	await get_tree().process_frame
	_case_contract2_row()
	_case_contract1_row()
	_case_cap()
	_case_fog_visibility()
	await _case_fire_props()
	print("MAP LIGHTS DONE: %d checks, %d FAIL" % [_checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


# A structured row with only what generate_structured_map needs (a ground
# image that exists, no floors or structures) plus the keys under test.
func _row(extra: Dictionary) -> Dictionary:
	var row := {"id": "map_lights_test", "format": "structured", "images": {"map": "res://icon.svg"},
		"tile_size": 64, "world_size": [1024, 1024], "floors": [], "structures": []}
	row.merge(extra, true)
	return row


func _loader() -> Node2D:
	var ml: Node2D = MAP_LOADER.new()
	add_child(ml)
	return ml


func _same_colour(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 1e-4 and absf(a.g - b.g) < 1e-4 and absf(a.b - b.b) < 1e-4


func _case_contract2_row() -> void:
	var ml := _loader()
	ml.generate_structured_map(_row({"export_contract": 2.0, "lights": [
		{"position": [100, 200], "level": 0.84, "source": "forge"},
		{"position": [400.0, 410.0], "level": 0.5, "color": [0.9, 0.7, 0.5], "shadow": false, "source": "hearth"},
		{"position": [10, 10]},                       # no level: skipped
		{"level": 0.3},                               # no position: skipped
		"not a row"]}))
	var root: Node2D = ml.get("map_lights")
	_report("c2.map-lights-node", root != null and root.get_parent() == ml and root.name == "MapLights")
	if root == null:
		ml.queue_free()
		return
	var lights: Array = root.get_children()
	_report("c2.count", lights.size() == 2, "%d lights (2 valid rows of 5)" % lights.size())
	if lights.size() == 2:
		var a: PointLight2D = lights[0]
		var b: PointLight2D = lights[1]
		_report("c2.position", a.position == Vector2(100, 200) and b.position == Vector2(400, 410),
			"%s %s" % [str(a.position), str(b.position)])
		_report("c2.level-energy", is_equal_approx(a.energy, 0.35 + 0.65 * 0.84), str(a.energy))
		_report("c2.level-radius", is_equal_approx(a.texture_scale,
			2.0 * EquipmentEffects.light_radius_px(0.84) / float(EquipmentEffects.LIGHT_TEX_SIZE)), str(a.texture_scale))
		_report("c2.default-colour-is-fire", _same_colour(a.color, FIRE)
			and a.color == EquipmentEffects.LIGHT_TRAIT_COLORS["fire"], str(a.color))
		_report("c2.explicit-colour", _same_colour(b.color, Color(0.9, 0.7, 0.5)), str(b.color))
		_report("c2.default-shadowed", a.shadow_enabled
			and a.shadow_item_cull_mask == CollisionLayers.LIGHT_SHADOW_MASK, str(a.shadow_item_cull_mask))
		_report("c2.shadow-false", not b.shadow_enabled)
		_report("c2.source-informational", String(a.get_meta("source", "")) == "forge"
			and String(b.get_meta("source", "")) == "hearth")
		_report("c2.ground-unlit-sprite", ml.get("structured_ground") != null)
	ml.queue_free()


func _case_contract1_row() -> void:
	var ml := _loader()
	ml.generate_structured_map(_row({}))
	_report("c1.no-map-lights", ml.get("map_lights") == null and ml.get_node_or_null("MapLights") == null)
	var ml2 := _loader()
	ml2.generate_structured_map(_row({"lights": []}))
	_report("c1.empty-list-no-node", ml2.get("map_lights") == null)
	ml.queue_free()
	ml2.queue_free()


func _case_cap() -> void:
	var rows: Array = []
	for i in MAP_LOADER.MAP_LIGHTS_MAX + 8:
		rows.append({"position": [20 * i, 30], "level": 0.2})
	var ml := _loader()
	ml.generate_structured_map(_row({"export_contract": 2, "lights": rows}))
	var root: Node2D = ml.get("map_lights")
	var n: int = root.get_child_count() if root != null else -1
	_report("cap.map-lights-max", n == MAP_LOADER.MAP_LIGHTS_MAX, "%d of %d rows" % [n, rows.size()])
	ml.queue_free()


# Map lights follow the unexplored fog (ExplorationManager), not the item LOS
# rule: dark until a tile within MAP_LIGHT_REVEAL_TILES (1) is explored, and
# always lit on a map without that fog.
func _case_fog_visibility() -> void:
	var ml := _loader()
	ml.generate_structured_map(_row({"export_contract": 2, "lights": [
		{"position": [96, 96], "level": 0.5, "source": "hearth"},      # tile (1, 1)
		{"position": [800, 800], "level": 0.5, "source": "forge"}]}))   # tile (12, 12)
	var root: Node2D = ml.get("map_lights")
	var n: int = root.get_child_count() if root != null else -1
	_report("fog.two-lights", n == 2, "%d lights" % n)
	if n != 2:
		ml.queue_free()
		return
	var a: Node2D = root.get_child(0)
	var b: Node2D = root.get_child(1)
	ExplorationManager.begin_map("map_lights_fog_test", true)
	ml.update_map_light_visibility()
	_report("fog.unexplored-dark", not a.visible and not b.visible, "%s %s" % [a.visible, b.visible])
	ExplorationManager.seed_explored(Vector2i(3, 3))   # two tiles from (1, 1)
	ml.update_map_light_visibility()
	_report("fog.two-tiles-off-still-dark", not a.visible)
	ExplorationManager.seed_explored(Vector2i(2, 2))   # a neighbour of (1, 1)
	ml.update_map_light_visibility()
	_report("fog.explored-neighbour-lit", a.visible and not b.visible, "%s %s" % [a.visible, b.visible])
	ExplorationManager.begin_map("map_lights_fog_off", false)
	ml.update_map_light_visibility()
	_report("fog.no-fog-map-lit", a.visible and b.visible, "%s %s" % [a.visible, b.visible])
	ExplorationManager.clear_map("map_lights_fog_test")
	ml.queue_free()


func _case_fire_props() -> void:
	var want := {"brazier": 0.5, "campfire": 0.6, "torch": 0.35}
	var placed: Array = []
	var x := 200.0
	for id in want:
		var it = ITEM_SCENE.instantiate()
		it.id = id
		it.global_position = Vector2(x, 700)
		x += 200.0
		add_child(it)
		items_in_scene.append(it)
		placed.append(it)
	await get_tree().process_frame
	for it in placed:
		var id := String(it.id)
		var d: Dictionary = ItemDatabase.items.get(id, {})
		_report("prop.%s-data" % id, is_equal_approx(EquipmentEffects.light_level(d), float(want[id]))
			and EquipmentEffects.explicit_light_color(d.get("light_color")) is Color, str(d.get("emits_light")))
		var l: PointLight2D = it.get_node_or_null("EmittedLight")
		_report("prop.%s-emits-light" % id, l != null)
		if l == null:
			continue
		_report("prop.%s-warm-colour" % id, _same_colour(l.color, FIRE), str(l.color))
		_report("prop.%s-energy" % id, is_equal_approx(l.energy, 0.35 + 0.65 * float(want[id])), str(l.energy))
		_report("prop.%s-shadowed" % id, l.shadow_enabled)
	# the traits alone would have given the default warm white (Metal / Wood)
	_report("prop.trait-colour-differs", not _same_colour(EquipmentEffects.light_color({"Metal": 2}), FIRE))
	for it in placed:
		it.queue_free()
