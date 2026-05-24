@tool
extends Control

# Palette dock for the hex_world_editor plugin. Lists every tile in HexTileDatabase
# and every icon in HexIconDatabase as a toggleable button. Click a button to make
# that tile/icon "current"; the EditorPlugin reads `current_kind` + `current_id`
# from this dock when the user clicks in the 2D viewport.

signal selection_changed(kind: StringName, id: StringName)

enum Kind { TILE, ICON }

const _BTN_MIN_SIZE := Vector2(124, 90)

@onready var tabs: TabContainer = $Tabs
@onready var tile_grid: GridContainer = $Tabs/Tiles/Scroll/Grid
@onready var icon_grid: GridContainer = $Tabs/Icons/Scroll/Grid
@onready var hint_label: Label = $Hint

var current_kind: StringName = ""    # "tile" or "icon" or ""
var current_id: StringName = ""
var _tile_group: ButtonGroup
var _icon_group: ButtonGroup


func _ready() -> void:
	_tile_group = ButtonGroup.new()
	_icon_group = ButtonGroup.new()
	_tile_group.allow_unpress = true
	_icon_group.allow_unpress = true
	_rebuild_all()
	# In case databases finish loading after we did, rebuild on signal.
	var tdb := _singleton("HexTileDatabase")
	if tdb and tdb.has_signal("hex_tile_definitions_loaded"):
		tdb.hex_tile_definitions_loaded.connect(_rebuild_tiles)
	var idb := _singleton("HexIconDatabase")
	if idb and idb.has_signal("hex_icon_definitions_loaded"):
		idb.hex_icon_definitions_loaded.connect(_rebuild_icons)


func _singleton(n: String) -> Node:
	var root = Engine.get_main_loop().root if Engine.get_main_loop() else null
	return root.get_node_or_null(n) if root else null


func _rebuild_all() -> void:
	_rebuild_tiles()
	_rebuild_icons()


func _rebuild_tiles() -> void:
	for child in tile_grid.get_children():
		child.queue_free()
	var db = _singleton("HexTileDatabase")
	if db == null:
		return
	var ids: Array = db.get_all_tile_ids()
	ids.sort()
	for tile_id in ids:
		var def = db.get_definition(tile_id)
		if def == null:
			continue
		var btn := _make_button(def, _tile_group)
		btn.toggled.connect(_on_tile_toggled.bind(StringName(tile_id)))
		tile_grid.add_child(btn)


func _rebuild_icons() -> void:
	for child in icon_grid.get_children():
		child.queue_free()
	var db = _singleton("HexIconDatabase")
	if db == null:
		return
	var ids: Array = db.get_all_icon_ids()
	ids.sort()
	for icon_id in ids:
		var def = db.get_definition(icon_id)
		if def == null:
			continue
		var btn := _make_button(def, _icon_group)
		btn.toggled.connect(_on_icon_toggled.bind(StringName(icon_id)))
		icon_grid.add_child(btn)


func _make_button(def: Dictionary, group: ButtonGroup) -> Button:
	var btn := Button.new()
	btn.toggle_mode = true
	btn.button_group = group
	btn.custom_minimum_size = _BTN_MIN_SIZE
	btn.tooltip_text = "%s\n(%s)" % [def.get("name", "?"), def.get("id", "?")]
	btn.text = def.get("name", "?")
	btn.clip_text = true
	btn.expand_icon = true
	btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	btn.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	var icon_path: String = def.get("icon_path", def.get("texture", ""))
	if icon_path != "":
		var tex = load(icon_path)
		if tex:
			btn.icon = tex
	return btn


func _on_tile_toggled(pressed: bool, tile_id: StringName) -> void:
	if pressed:
		current_kind = StringName("tile")
		current_id = tile_id
		hint_label.text = "Painting tile: %s   (LMB place, RMB erase)" % tile_id
		emit_signal("selection_changed", current_kind, current_id)
	elif current_id == tile_id:
		_clear_selection()


func _on_icon_toggled(pressed: bool, icon_id: StringName) -> void:
	if pressed:
		current_kind = StringName("icon")
		current_id = icon_id
		hint_label.text = "Painting icon: %s   (LMB place, RMB erase)" % icon_id
		emit_signal("selection_changed", current_kind, current_id)
	elif current_id == icon_id:
		_clear_selection()


func _clear_selection() -> void:
	current_kind = ""
	current_id = ""
	hint_label.text = "Select a tile or icon to paint."
	emit_signal("selection_changed", current_kind, current_id)


func get_current_kind() -> StringName:
	return current_kind


func get_current_id() -> StringName:
	return current_id
