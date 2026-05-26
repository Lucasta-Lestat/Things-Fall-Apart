@tool
extends Node2D
class_name WorldMap

# A hex-based world map. Stores which biome hex tile + optional building icon is
# placed at each axial-offset coordinate. Designed to be edited in the Godot
# editor via the hex_world_editor plugin (left-click paints, right-click erases),
# but also useful at runtime by reading `tile_placements`/`icon_placements`.
#
# Coordinate system: offset coordinates on a flat-top hex grid. Column 0 is the
# leftmost; rows increase downward. Odd columns are shifted DOWN by half a row
# pitch (so column 1 row 0 sits in between rows 0 and 1 of column 0).

# Width of a hex in pixels (left-point to right-point). Must match the carved
# hex PNGs produced by tools/generate_hex_landscape.py (currently 384).
const HEX_WIDTH := 384.0
const HEX_HEIGHT := HEX_WIDTH * 0.8660254  # W * sqrt(3) / 2
const COL_PITCH := HEX_WIDTH * 0.75
const ROW_PITCH := HEX_HEIGHT

# Storage. Keys are Vector2i(col, row); values are StringName tile/icon ids.
@export var tile_placements: Dictionary = {}
@export var icon_placements: Dictionary = {}

# Editor-time grid preview.
@export var show_grid_preview: bool = true
@export var grid_color: Color = Color(1.0, 1.0, 1.0, 0.12)
@export_range(1, 64) var grid_preview_radius: int = 12  # rings of empty hexes drawn around (0,0)


func hex_center(coord: Vector2i) -> Vector2:
	var col := coord.x
	var row := coord.y
	var x := col * COL_PITCH
	var y_offset := (ROW_PITCH * 0.5) if (col & 1) else 0.0
	var y := y_offset + row * ROW_PITCH
	return Vector2(x, y)


# Approximate world-to-hex: pick the candidate hex closest to `pos`.
# (Bucketing alone gets the wrong hex near corners; we test the immediate
# neighbours too and choose the closest center.)
func world_to_hex(pos: Vector2) -> Vector2i:
	var col := int(round(pos.x / COL_PITCH))
	var y_offset := (ROW_PITCH * 0.5) if (col & 1) else 0.0
	var row := int(round((pos.y - y_offset) / ROW_PITCH))
	var best := Vector2i(col, row)
	var best_dist_sq := (hex_center(best) - pos).length_squared()
	for dc in [-1, 0, 1]:
		for dr in [-1, 0, 1]:
			if dc == 0 and dr == 0:
				continue
			var candidate := Vector2i(col + dc, row + dr)
			var d := (hex_center(candidate) - pos).length_squared()
			if d < best_dist_sq:
				best = candidate
				best_dist_sq = d
	return best


func place_tile(coord: Vector2i, tile_id: StringName) -> void:
	if String(tile_id) == "":
		return
	tile_placements[coord] = tile_id
	queue_redraw()


func remove_tile(coord: Vector2i) -> void:
	if tile_placements.has(coord):
		tile_placements.erase(coord)
		queue_redraw()


func place_icon(coord: Vector2i, icon_id: StringName) -> void:
	if String(icon_id) == "":
		return
	icon_placements[coord] = icon_id
	queue_redraw()


func remove_icon(coord: Vector2i) -> void:
	if icon_placements.has(coord):
		icon_placements.erase(coord)
		queue_redraw()


func _draw() -> void:
	# Optional faint hex-grid background for editor authoring.
	if show_grid_preview and Engine.is_editor_hint():
		_draw_grid_preview()

	# Tiles first…
	for coord in tile_placements.keys():
		var tex := _tile_texture(String(tile_placements[coord]))
		if tex == null:
			continue
		var center := hex_center(coord)
		var sz := tex.get_size()
		draw_texture(tex, center - sz * 0.5)

	# …then icons on top.
	for coord in icon_placements.keys():
		var tex := _icon_texture(String(icon_placements[coord]))
		if tex == null:
			continue
		var center := hex_center(coord)
		var sz := tex.get_size()
		# Scale icon down so it sits comfortably inside the hex.
		var max_dim := HEX_WIDTH * 0.55
		var scale := min(max_dim / sz.x, max_dim / sz.y)
		var dst_size := sz * scale
		draw_texture_rect(tex, Rect2(center - dst_size * 0.5, dst_size), false)


func _tile_texture(tile_id: String) -> Texture2D:
	if tile_id == "":
		return null
	var db_node = _get_singleton("HexTileDatabase")
	if db_node == null:
		return null
	var def = db_node.get_definition(tile_id)
	if def == null:
		return null
	var tex_path: String = def.get("texture", "")
	if tex_path == "":
		var alts: Array = def.get("alternate_textures", [])
		if alts.size() > 0:
			tex_path = alts[0]
	if tex_path == "":
		return null
	return load(tex_path) as Texture2D


func _icon_texture(icon_id: String) -> Texture2D:
	if icon_id == "":
		return null
	var db_node = _get_singleton("HexIconDatabase")
	if db_node == null:
		return null
	var def = db_node.get_definition(icon_id)
	if def == null:
		return null
	var tex_path: String = def.get("texture", "")
	if tex_path == "":
		return null
	return load(tex_path) as Texture2D


# Autoload singletons aren't available via Engine.get_singleton(); instead the
# editor and runtime both expose them as nodes on /root. Look them up there.
func _get_singleton(name: String) -> Node:
	if Engine.is_editor_hint():
		var root := Engine.get_main_loop().root
		return root.get_node_or_null(name)
	return get_tree().root.get_node_or_null(name) if get_tree() else null


func _draw_grid_preview() -> void:
	# Draw `grid_preview_radius` rings of empty hex outlines around origin so the
	# user has a visual reference while painting on a fresh map.
	var r := grid_preview_radius
	for col in range(-r, r + 1):
		for row in range(-r, r + 1):
			_draw_hex_outline(Vector2i(col, row), grid_color)


func _draw_hex_outline(coord: Vector2i, color: Color) -> void:
	var c := hex_center(coord)
	var w := HEX_WIDTH * 0.5
	var h := HEX_HEIGHT * 0.5
	# Flat-top hex: 6 vertices at (±w/2, ±h), (±w, 0).
	var pts := PackedVector2Array([
		c + Vector2(-w * 0.5, -h),
		c + Vector2(w * 0.5, -h),
		c + Vector2(w, 0),
		c + Vector2(w * 0.5, h),
		c + Vector2(-w * 0.5, h),
		c + Vector2(-w, 0),
		c + Vector2(-w * 0.5, -h),  # close the loop
	])
	draw_polyline(pts, color, 1.0, true)
