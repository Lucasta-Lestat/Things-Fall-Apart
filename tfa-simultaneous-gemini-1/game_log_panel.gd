# =====================
# game_log_panel.gd - On-screen view of the GameLog autoload.
# Game._ready instances this under GameUI; it builds its own children so it
# doesn't depend on a hand-made node tree in game.tscn.
# =====================

extends PanelContainer

var scroll_container: ScrollContainer
var log_content: VBoxContainer

var auto_scroll: bool = true
const MAX_VISIBLE_ENTRIES: int = 50
const PANEL_SIZE := Vector2(400, 170)
const RIGHT_MARGIN := 260.0   # clear of PartySidePanel (250 px wide)
const BOTTOM_MARGIN := 10.0
const DIALOGUE_BAND := 200.0  # DialoguePanel height; lift above it while it shows
const TEXT_COLOR := Color(0.15, 0.1, 0.05)
const TIME_COLOR := "#6b5530"

var _dialogue_panel: Control = null

func _ready():
	name = "LogPanel"
	# Keep receiving entries and scroll input while the tree is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Click-through: the log sits over the play field, and any non-IGNORE
	# control there makes ProceduralCharacter._handle_input treat the spot as
	# UI. Only the scrollbar takes the mouse, so history can still be read.
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style = StyleBoxTexture.new()
	style.texture = preload("res://UI/paper texture.png")
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	add_theme_stylebox_override("panel", style)

	scroll_container = ScrollContainer.new()
	scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scroll_container)
	log_content = VBoxContainer.new()
	log_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	log_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_container.add_child(log_content)

	# Bottom-right, left of the party panel.
	anchor_left = 1.0
	anchor_top = 1.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	custom_minimum_size = PANEL_SIZE
	offset_right = -RIGHT_MARGIN
	offset_left = -RIGHT_MARGIN - PANEL_SIZE.x
	_place(false)

	var parent := get_parent()
	if parent and parent.has_node("DialoguePanel"):
		_dialogue_panel = parent.get_node("DialoguePanel")
		_dialogue_panel.visibility_changed.connect(_on_dialogue_visibility_changed)
	# Follow the party panel's Tab toggle, like the clock does.
	if parent and parent.has_node("PartySidePanel"):
		var panel = parent.get_node("PartySidePanel")
		visible = panel.panel_visible
		panel.panel_visibility_changed.connect(func(now_visible): visible = now_visible)

	GameLog.entry_added.connect(_on_entry_added)
	GameLog.entry_repeated.connect(_on_entry_repeated)
	for entry in GameLog.get_entries():
		_add_log_label(entry.text, entry.game_time, int(entry.get("count", 1)))
	_scroll_to_bottom.call_deferred()

func _place(above_dialogue: bool) -> void:
	var bottom := BOTTOM_MARGIN + (DIALOGUE_BAND if above_dialogue else 0.0)
	offset_bottom = -bottom
	offset_top = -bottom - PANEL_SIZE.y

func _on_dialogue_visibility_changed() -> void:
	_place(_dialogue_panel.visible)

func _on_entry_added(text: String, timestamp: String):
	_add_log_label(text, timestamp)
	if auto_scroll:
		await get_tree().process_frame
		_scroll_to_bottom()

func _on_entry_repeated(count: int) -> void:
	if log_content.get_child_count() == 0:
		return
	var label: RichTextLabel = log_content.get_child(log_content.get_child_count() - 1)
	label.text = _format_entry(label.get_meta("base_text", ""), label.get_meta("timestamp", ""), count)

func _format_entry(text: String, timestamp: String, count: int) -> String:
	var repeat := " [color=%s](x%d)[/color]" % [TIME_COLOR, count] if count > 1 else ""
	return "[color=%s][%s][/color] %s%s" % [TIME_COLOR, timestamp, text, repeat]

func _scroll_to_bottom() -> void:
	scroll_container.scroll_vertical = int(scroll_container.get_v_scroll_bar().max_value)

func _add_log_label(text: String, timestamp: String, count: int = 1):
	var label = RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("default_color", TEXT_COLOR)
	label.set_meta("base_text", text)
	label.set_meta("timestamp", timestamp)
	label.text = _format_entry(text, timestamp, count)
	log_content.add_child(label)

	while log_content.get_child_count() > MAX_VISIBLE_ENTRIES:
		var old_child = log_content.get_child(0)
		log_content.remove_child(old_child)
		old_child.queue_free()
