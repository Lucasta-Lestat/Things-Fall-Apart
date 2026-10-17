## CenterPartyPortraits
## Visible only while Game.downtime_mode_active is true. Shows a centred row
## of party portraits the player can drag onto activity cards (left panel) or
## the camp panel (right). Drag payload is
##   { "kind": "portrait", "source_character": <ProceduralCharacter> }
## — TownServicesPanel and CampDowntimePanel inspect "kind" to distinguish
## portrait drops from existing inventory drops.
##
## Extends PanelContainer (not Control) so the node auto-sizes to fit its
## HBox of portraits. A bare Control anchored centre with no offsets is
## zero-width, which silently breaks drag pick-up — _get_drag_data is only
## called when the cursor is inside the Control's rect.
extends PanelContainer

const PORTRAIT_SIZE := Vector2(64, 64)
const DUMMY_ICON_PATH := "res://Icons/dummy_icon.png"
const DEAD_TINT := Color(1.0, 0.3, 0.3, 1.0)  # matches PartySidePanel

var game_node: Node = null
var _row: HBoxContainer = null
var _portraits: Array = []  # Array of {rect: TextureRect, character: Node}

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

	# Centred horizontal strip near the top of the viewport. PanelContainer
	# sizes to fit its child HBox so the clickable rect actually covers the
	# visible portraits.
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.0
	anchor_bottom = 0.0
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	offset_top = 80

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.12, 0.16, 0.85)
	sb.set_corner_radius_all(6)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.6, 0.45, 0.2, 1.0)
	sb.set_content_margin_all(8)
	add_theme_stylebox_override("panel", sb)

	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 8)
	# IGNORE so clicks fall through the HBox to the PanelContainer above,
	# where _get_drag_data is defined.
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_row)

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
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		# IGNORE so drags reach this panel; the hover tooltip comes from
		# _get_tooltip below, since an IGNORE rect never shows its own.
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_load_portrait(rect, c)
		_tint_if_dead(rect, c)
		# Downtime mishaps can drop HP to 0 while the strip is up; re-tint then.
		if c.has_signal("health_changed") and not c.health_changed.is_connected(_on_party_health_changed):
			c.health_changed.connect(_on_party_health_changed)
		_row.add_child(rect)
		_portraits.append({"rect": rect, "character": c})

func _tint_if_dead(rect: TextureRect, character) -> void:
	var dead: bool = character.has_method("is_alive") and not character.is_alive()
	rect.modulate = DEAD_TINT if dead else Color.WHITE

func _on_party_health_changed(_new_health: int, _max_health: int, character) -> void:
	for entry in _portraits:
		if entry["character"] == character and is_instance_valid(entry["rect"]):
			_tint_if_dead(entry["rect"], character)

func _load_portrait(rect: TextureRect, character) -> void:
	# Per-character portrait (character creation) first, template icon second.
	var icon_path: String = String(character.get("icon_path")) if "icon_path" in character else ""
	if icon_path.is_empty():
		var template: Dictionary = TopDownCharacterDatabase.get_template(
			character.get("template_id") if "template_id" in character else String(character.display_name).to_lower()
		)
		icon_path = String(template.get("icon", ""))
	if not icon_path.is_empty() and ResourceLoader.exists(icon_path):
		rect.texture = load(icon_path)
	elif ResourceLoader.exists(DUMMY_ICON_PATH):
		rect.texture = load(DUMMY_ICON_PATH)
	else:
		var img := Image.create(int(PORTRAIT_SIZE.x), int(PORTRAIT_SIZE.y), false, Image.FORMAT_RGBA8)
		img.fill(Color(0.5, 0.5, 0.5))
		rect.texture = ImageTexture.create_from_image(img)

func _char_name(character) -> String:
	return String(character.display_name) if "display_name" in character else String(character.name)

# Hover tooltip for the portrait under the cursor. Built on demand so HP,
# stress and conditions are current; the party side panel that normally
# shows them is hidden during downtime.
func _get_tooltip(at_position: Vector2) -> String:
	var portrait = _find_portrait_at(at_position)
	if portrait == null:
		return ""
	var c = portrait["character"]
	if not is_instance_valid(c):
		return ""
	var dead: bool = c.has_method("is_alive") and not c.is_alive()
	var lines: Array[String] = [_char_name(c) + (" (dead)" if dead else "")]
	if "current_health" in c and "max_health" in c:
		lines.append("HP %d/%d" % [int(c.current_health), int(c.max_health)])
	if "stress" in c and "max_stress" in c:
		lines.append("Stress %d/%d" % [int(c.stress), int(c.max_stress)])
	var cm = c.get_node_or_null("ConditionManager")
	if cm:
		# The party panel is hidden in downtime, so this is where a hangover's
		# or a blessing's hours show: "Hungover (9h 00m)", as in its tooltips.
		var names: Array[String] = []
		var now: float = TimeManager.absolute_time()
		for cond_id in cm.conditions:
			names.append(cm.conditions[cond_id].get_summary(now))
		if not names.is_empty():
			lines.append(", ".join(names))
	return "\n".join(lines)

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
	if not is_instance_valid(character):
		return null
	if character.has_method("is_alive") and not character.is_alive():
		# Floats over them too: the game log starts closed.
		if character.has_method("notify"):
			character.notify("Dead", Color(1.0, 0.6, 0.4), "%s is dead and can't take part in downtime." % _char_name(character))
		else:
			GameLog.add_entry("%s is dead and can't take part in downtime." % _char_name(character))
		return null
	var rect: TextureRect = portrait["rect"]
	# Drag preview is a copy of the portrait sprite.
	var preview := TextureRect.new()
	preview.texture = rect.texture
	preview.custom_minimum_size = PORTRAIT_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
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
