extends Node2D
class_name WorldMapOverlay

# Draws translucent faction-colored "territory" circles around every city on
# the world map and stamps each city's name as a Label. Borders emanate from
# the city's center out to its configured radius; calling set_city_controller
# at runtime swaps the controller and recolors live (like Civilization borders
# flipping when a region changes hands).

const TERRITORY_ALPHA: float = 0.30
const TERRITORY_RING_THICKNESS: float = 6.0
const TERRITORY_DEFAULT_COLOR: Color = Color(0.55, 0.55, 0.55)  # neutral grey
const LABEL_FONT_SIZE: int = 30
const LABEL_OUTLINE_SIZE: int = 6
const Z_INDEX: int = 50  # above tiles, below characters

# Internal city records. Each entry is a Dictionary with:
#   id, name, position (Vector2), controller (String), territory_radius_px (float)
var _cities: Array = []
# Per-city label nodes so we can keep them positioned and update if needed.
var _label_nodes: Dictionary = {}  # city_id -> Label


func _ready() -> void:
	z_index = Z_INDEX


func configure(labels: Array) -> void:
	"""Replace the city set from a Maps.json world_labels array. Safe to call
	multiple times — old labels are cleared first."""
	_clear()
	for entry in labels:
		var pos_arr = entry.get("position", [0, 0])
		var city: Dictionary = {
			"id": str(entry.get("id", "")),
			"name": str(entry.get("name", "")),
			"position": Vector2(pos_arr[0], pos_arr[1]),
			"controller": str(entry.get("controller", "neutral")),
			"territory_radius_px": float(entry.get("territory_radius_px", 200.0)),
		}
		_cities.append(city)
		_spawn_label(city)
	queue_redraw()


func set_city_controller(city_id: String, faction_id: String) -> void:
	"""Civ-style border flip: change which faction owns a city and recolor."""
	for city in _cities:
		if city["id"] == city_id:
			city["controller"] = faction_id
			queue_redraw()
			return
	push_warning("[WorldMapOverlay] set_city_controller: unknown city '%s'" % city_id)


func get_city_controller(city_id: String) -> String:
	for city in _cities:
		if city["id"] == city_id:
			return city["controller"]
	return ""


func _spawn_label(city: Dictionary) -> void:
	var label := Label.new()
	label.name = "Label_" + city["id"]
	label.text = city["name"]
	label.add_theme_font_size_override("font_size", LABEL_FONT_SIZE)
	label.add_theme_color_override("font_color", Color(1, 1, 1))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	label.add_theme_constant_override("outline_size", LABEL_OUTLINE_SIZE)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.size = Vector2(260, LABEL_FONT_SIZE + 10)
	# Center the label on the city; nudge upward a bit so it sits just above
	# the marker rather than over it.
	label.position = city["position"] - Vector2(130, LABEL_FONT_SIZE + 12)
	label.z_index = 1  # above the territory circle drawn in _draw()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	_label_nodes[city["id"]] = label


func _clear() -> void:
	for child in _label_nodes.values():
		if is_instance_valid(child):
			child.queue_free()
	_label_nodes.clear()
	_cities.clear()


func _draw() -> void:
	for city in _cities:
		var color: Color = _faction_color(city["controller"])
		var center: Vector2 = city["position"]
		var radius: float = city["territory_radius_px"]
		# Filled disc with low alpha so the underlying map shows through.
		var fill := color
		fill.a = TERRITORY_ALPHA
		draw_circle(center, radius, fill)
		# Solid edge ring so border lines stay legible even on busy terrain.
		var edge := color
		edge.a = 0.85
		draw_arc(center, radius, 0.0, TAU, 64, edge, TERRITORY_RING_THICKNESS, true)


func _faction_color(faction_id: String) -> Color:
	# Neutral / unknown cities use a desaturated grey instead of disappearing.
	if faction_id.is_empty() or faction_id == "neutral":
		return TERRITORY_DEFAULT_COLOR
	var fac: Dictionary = FactionDatabase.get_faction_data(faction_id)
	if fac.is_empty():
		return TERRITORY_DEFAULT_COLOR
	var hex: String = str(fac.get("territory_color", fac.get("color", "")))
	if hex.is_empty():
		return TERRITORY_DEFAULT_COLOR
	return Color(hex)
