@tool
extends EditorPlugin

# Editor plugin for authoring hex-based world maps.
#
# Behavior:
#   - Adds a "WorldMap" custom Node2D you can spawn in any 2D scene
#   - Adds a "Hex Palette" dock on the right side with tabs for Tiles + Icons
#   - When a WorldMap is the current selection, left-click in the viewport
#     paints the currently selected palette item on the hex under the cursor;
#     right-click erases whatever's on that hex (icon takes priority over tile).

const WorldMapScript = preload("res://addons/hex_world_editor/world_map.gd")
const PaletteDock = preload("res://addons/hex_world_editor/palette_dock.tscn")

var _palette: Control = null
var _current_map: Node2D = null


func _enter_tree() -> void:
	var icon: Texture2D = null
	# Use the project icon for the custom-type entry; harmless if missing.
	if FileAccess.file_exists("res://icon.svg"):
		icon = load("res://icon.svg")
	add_custom_type("WorldMap", "Node2D", WorldMapScript, icon)
	_palette = PaletteDock.instantiate()
	_palette.name = "HexPalette"
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _palette)


func _exit_tree() -> void:
	remove_custom_type("WorldMap")
	if _palette:
		remove_control_from_docks(_palette)
		_palette.queue_free()
		_palette = null
	_current_map = null


# `_handles` + `_edit` together let _forward_canvas_gui_input fire only when a
# WorldMap is currently selected.
func _handles(object) -> bool:
	return object != null and object.get_script() == WorldMapScript


func _edit(object) -> void:
	if object != null and object.get_script() == WorldMapScript:
		_current_map = object
	else:
		_current_map = null


func _make_visible(visible: bool) -> void:
	if not visible:
		_current_map = null


func _forward_canvas_gui_input(event: InputEvent) -> bool:
	if _current_map == null or _palette == null:
		return false

	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		var local_pos: Vector2 = _current_map.get_local_mouse_position()
		var coord: Vector2i = _current_map.world_to_hex(local_pos)

		if mb.button_index == MOUSE_BUTTON_LEFT:
			var kind: StringName = _palette.get_current_kind()
			var id: StringName = _palette.get_current_id()
			if String(kind) == "tile":
				_current_map.place_tile(coord, id)
			elif String(kind) == "icon":
				_current_map.place_icon(coord, id)
			else:
				return false  # no selection, let the click pass through
			_mark_dirty()
			return true

		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			# Erase: prefer removing an icon if one is there, otherwise the tile.
			if _current_map.icon_placements.has(coord):
				_current_map.remove_icon(coord)
			elif _current_map.tile_placements.has(coord):
				_current_map.remove_tile(coord)
			else:
				return false
			_mark_dirty()
			return true

	return false


func _mark_dirty() -> void:
	if _current_map and _current_map.is_inside_tree():
		# Tell the editor the scene needs saving.
		var undo := get_undo_redo()
		# We don't actually use undo/redo for the painting itself in MVP; flag
		# the scene as modified by touching a property.
		_current_map.notify_property_list_changed()
