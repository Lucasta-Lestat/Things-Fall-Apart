## CenterPartyPortraits
## Visible only while Game.downtime_mode_active is true. Shows a centred row
## of party portraits the player can drag onto activity cards (left panel) or
## the camp panel (right). Drag payload is
##   { "kind": "portrait", "source_character": <ProceduralCharacter> }
## — TownServicesPanel and CampDowntimePanel inspect "kind" to distinguish
## portrait drops from existing inventory drops.
extends Control

const PORTRAIT_SIZE := Vector2(64, 64)
const DUMMY_ICON_PATH := "res://Icons/dummy_icon.png"

var game_node: Node = null
var _row: HBoxContainer = null
var _portraits: Array = []  # Array of {rect: TextureRect, character: Node}

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

	# Centred horizontal strip near the top of the viewport.
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.0
	anchor_bottom = 0.0
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	offset_top = 80
	offset_bottom = 80 + PORTRAIT_SIZE.y + 16

	var bg := PanelContainer.new()
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	bg.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.12, 0.16, 0.85)
	sb.set_corner_radius_all(6)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.6, 0.45, 0.2, 1.0)
	sb.set_content_margin_all(8)
	bg.add_theme_stylebox_override("panel", sb)
	add_child(bg)

	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 8)
	_row.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.add_child(_row)

	game_node = get_node_or_null("/root/Game")
	if game_node:
		if game_node.has_signal("downtime_mode_changed"):
			game_node.connect("downtime_mode_changed", _on_downtime_mode_changed)
		if game_node.has_signal("map_loaded"):
			game_node.connect("map_loaded", _on_map_loaded)
	call_deferred("_rebuild_portraits")

func _on_downtime_mode_changed(active: bool) -> void:
	visible = active
	if active:
		_rebuild_portraits()

func _on_map_loaded(_map_id: String) -> void:
	# Party members may have changed during a map transition; rebuild lazily.
	if visible:
		call_deferred("_rebuild_portraits")

func _rebuild_portraits() -> void:
	if _row == null:
		return
	for child in _row.get_children():
		child.queue_free()
	_portraits.clear()
	if game_node == null:
		return
	for c in game_node.party_chars:
		if not is_instance_valid(c):
			continue
		var rect := TextureRect.new()
		rect.custom_minimum_size = PORTRAIT_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_load_portrait(rect, c)
		rect.tooltip_text = String(c.display_name) if "display_name" in c else String(c.name)
		_row.add_child(rect)
		_portraits.append({"rect": rect, "character": c})

func _load_portrait(rect: TextureRect, character) -> void:
	var template: Dictionary = TopDownCharacterDatabase.get_template(
		character.get("template_id") if "template_id" in character else String(character.display_name).to_lower()
	)
	var icon_path: String = String(template.get("icon", ""))
	if not icon_path.is_empty() and ResourceLoader.exists(icon_path):
		rect.texture = load(icon_path)
	elif ResourceLoader.exists(DUMMY_ICON_PATH):
		rect.texture = load(DUMMY_ICON_PATH)
	else:
		var img := Image.create(int(PORTRAIT_SIZE.x), int(PORTRAIT_SIZE.y), false, Image.FORMAT_RGBA8)
		img.fill(Color(0.5, 0.5, 0.5))
		rect.texture = ImageTexture.create_from_image(img)

# ---------------------------------------------------------------------------
# Drag source
# ---------------------------------------------------------------------------

func _get_drag_data(at_position: Vector2):
	if not visible:
		return null
	var portrait = _find_portrait_at(at_position)
	if portrait == null:
		return null
	var character = portrait["character"]
	var rect: TextureRect = portrait["rect"]
	# Drag preview is a copy of the portrait sprite.
	var preview := TextureRect.new()
	preview.texture = rect.texture
	preview.custom_minimum_size = PORTRAIT_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	set_drag_preview(preview)
	return {
		"kind": "portrait",
		"source_character": character,
	}

func _find_portrait_at(local_pos: Vector2) -> Variant:
	var global_pos = get_global_transform() * local_pos
	for entry in _portraits:
		var r: TextureRect = entry["rect"]
		if r.get_global_rect().has_point(global_pos):
			return entry
	return null
