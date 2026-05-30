## CampDowntimePanel
## Right-side panel shown only in downtime mode (PartySidePanel hides during
## downtime, this takes its place). Renders the camp-stack activities — rest,
## watch, cook, bushcraft, hunting, meditation — as parchment cards that accept
## portrait drops. Each drop routes to DowntimeResolver.begin_drop.
extends PanelContainer

const PANEL_WIDTH := 250.0
const SLIDE_DURATION := 0.3
const DOWNTIME_CARDS_DIR := "res://UI/Assets/downtime_cards/"
const DEFAULT_DOWNTIME_CARD := "res://UI/Assets/downtime_cards/default.png"
const SERVICE_CARDS_DEFAULT := "res://UI/Assets/service_cards/default.png"

var game_node: Node = null
var party_panel: Node = null
var _scroll: ScrollContainer
var _vbox: VBoxContainer
var _header_label: Label
var _tween: Tween = null
var _cards: Array = []  # Array of {activity_id: String, container: Control}

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	game_node = get_node_or_null("/root/Game")

	# Anchored to the right edge (mirror of PartySidePanel).
	anchor_left = 1.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = -PANEL_WIDTH
	offset_right = 0
	offset_top = 0
	offset_bottom = 0
	grow_horizontal = Control.GROW_DIRECTION_BEGIN

	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.10, 0.12, 0.16, 0.92)
	bg.set_corner_radius_all(4)
	bg.set_border_width_all(1)
	bg.border_color = Color(0.6, 0.45, 0.2, 1.0)
	add_theme_stylebox_override("panel", bg)

	var outer := VBoxContainer.new()
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(outer)

	_header_label = Label.new()
	_header_label.text = "Camp"
	_header_label.add_theme_font_size_override("font_size", 13)
	_header_label.add_theme_color_override("font_color", Color(0.85, 0.75, 0.4))
	_header_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	outer.add_child(_header_label)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	outer.add_child(_scroll)

	_vbox = VBoxContainer.new()
	_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.mouse_filter = Control.MOUSE_FILTER_STOP
	_vbox.add_theme_constant_override("separation", 6)
	_scroll.add_child(_vbox)

	if game_node and game_node.has_signal("downtime_mode_changed"):
		game_node.connect("downtime_mode_changed", _on_downtime_mode_changed)

	call_deferred("_repopulate")

func _on_downtime_mode_changed(active: bool) -> void:
	visible = active
	if active:
		_repopulate()

func _repopulate() -> void:
	for child in _vbox.get_children():
		child.queue_free()
	_cards.clear()
	var map_id: String = ""
	if game_node and "current_map_id" in game_node:
		map_id = String(game_node.current_map_id)
	var ids: Array = DowntimeDatabase.get_camp_activities_for_map(map_id)
	for aid in ids:
		var activity: Dictionary = DowntimeDatabase.get_activity(String(aid))
		if activity.is_empty():
			continue
		var card := _build_activity_card(String(aid), activity)
		if card:
			_vbox.add_child(card)

func _build_activity_card(activity_id: String, activity: Dictionary) -> Control:
	var card_panel := PanelContainer.new()
	card_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	# Godot 4 does NOT bubble _can_drop_data past STOP controls. Use
	# set_drag_forwarding to attach per-card drag-drop callbacks directly.
	card_panel.set_drag_forwarding(
		Callable(),
		_card_can_drop_data.bind(activity_id),
		_card_drop_data.bind(activity_id),
	)

	var card_tex: Texture2D = _get_downtime_card_texture(activity_id)
	if card_tex != null:
		var sb := StyleBoxTexture.new()
		sb.texture = card_tex
		sb.texture_margin_left = 16
		sb.texture_margin_right = 16
		sb.texture_margin_top = 16
		sb.texture_margin_bottom = 16
		sb.set_content_margin_all(8)
		card_panel.add_theme_stylebox_override("panel", sb)

	var container := VBoxContainer.new()
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card_panel.add_child(container)

	var title_label := Label.new()
	title_label.text = String(activity.get("name", activity_id))
	title_label.add_theme_font_size_override("font_size", 13)
	title_label.add_theme_color_override("font_color", Color(0.15, 0.10, 0.05))
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.add_child(title_label)

	var desc_label := Label.new()
	desc_label.text = String(activity.get("description", "")).left(120)
	desc_label.add_theme_font_size_override("font_size", 10)
	desc_label.add_theme_color_override("font_color", Color(0.30, 0.22, 0.10))
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.add_child(desc_label)

	var check: String = String(activity.get("ability_check", ""))
	if not check.is_empty():
		var meta_label := Label.new()
		meta_label.text = "Check: %s" % check
		meta_label.add_theme_font_size_override("font_size", 9)
		meta_label.add_theme_color_override("font_color", Color(0.40, 0.28, 0.10))
		meta_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		container.add_child(meta_label)

	_cards.append({"activity_id": activity_id, "container": card_panel})
	return card_panel

# ---------------------------------------------------------------------------
# Per-card drag-drop callbacks. Attached via set_drag_forwarding so they fire
# on the specific card without depending on _can_drop_data bubbling up.
# ---------------------------------------------------------------------------

func _card_can_drop_data(_at_position: Vector2, data, activity_id: String) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	if String(data.get("kind", "")) != "portrait":
		return false
	print("[Downtime] CampDowntimePanel._card_can_drop_data accept on '%s'" % activity_id)
	return true

func _card_drop_data(_at_position: Vector2, data, activity_id: String) -> void:
	if typeof(data) != TYPE_DICTIONARY:
		return
	var source_char = data.get("source_character")
	if not is_instance_valid(source_char):
		return
	print("[Downtime] CampDowntimePanel._card_drop_data routing: activity='%s'" % activity_id)
	# Camp activities are always available regardless of region; pass "".
	DowntimeResolver.begin_drop(source_char, activity_id, "")

func _get_downtime_card_texture(activity_id: String) -> Texture2D:
	var path := DOWNTIME_CARDS_DIR + activity_id + ".png"
	if ResourceLoader.exists(path):
		return load(path)
	if ResourceLoader.exists(DEFAULT_DOWNTIME_CARD):
		return load(DEFAULT_DOWNTIME_CARD)
	# Fall back to the service-card default so the panel still draws something
	# evocative before bespoke downtime art is added.
	if ResourceLoader.exists(SERVICE_CARDS_DEFAULT):
		return load(SERVICE_CARDS_DEFAULT)
	return null

# ---------------------------------------------------------------------------
# Drag/drop (portrait drops only)
# ---------------------------------------------------------------------------

func _can_drop_data(at_position: Vector2, data) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	if String(data.get("kind", "")) != "portrait":
		return false
	if data.get("source_character") == null:
		return false
	return not _find_card_at(at_position).is_empty()

func _drop_data(at_position: Vector2, data) -> void:
	var card := _find_card_at(at_position)
	if card.is_empty():
		return
	var character = data.get("source_character")
	if character == null or not is_instance_valid(character):
		return
	# Camp activities are always available regardless of region; pass "" so
	# region-specific result buckets are skipped.
	DowntimeResolver.begin_drop(character, String(card["activity_id"]), "")

func _find_card_at(local_pos: Vector2) -> Dictionary:
	var global_pos = get_global_transform() * local_pos
	for c in _cards:
		var container: Control = c["container"]
		if container.get_global_rect().has_point(global_pos):
			return c
	return {}
