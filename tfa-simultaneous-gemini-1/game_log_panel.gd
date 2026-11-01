# =====================
# game_log_panel.gd - On-screen view of the GameLog autoload.
# Game._ready instances this under GameUI; it builds its own children so it
# doesn't depend on a hand-made node tree in game.tscn.
#
# Hidden until the player opens it: the "Log" button at the bottom right (left
# of the party panel) or the L key toggles it. While it is closed the button
# counts the entries that arrived unseen. Tab hides the button and an open log
# with the rest of the HUD and brings them back. Drawn on the shared gold
# frame (UI/GoldFrame.gd) like the Town Services and Camp panels.
# =====================

extends PanelContainer

const GoldFrame = preload("res://UI/GoldFrame.gd")

var scroll_container: ScrollContainer
var log_content: VBoxContainer
# The open/close button (a sibling under GameUI) and its unread badge.
var toggle_button: Button
var unread_badge: Label
var unread_count: int = 0

var auto_scroll: bool = true
const MAX_VISIBLE_ENTRIES: int = 50
const PANEL_SIZE := Vector2(400, 170)
const BUTTON_SIZE := Vector2(56, 26)
const BUTTON_GAP := 4.0           # between the button and the open log above it
const RIGHT_MARGIN := 260.0   # clear of PartySidePanel (250 px wide)
const BOTTOM_MARGIN := 10.0
const DIALOGUE_BAND := 200.0  # DialoguePanel height; lift above it while it shows
const TOGGLE_KEY := KEY_L
const TIME_COLOR := GoldFrame.MUTED_COLOR

var _dialogue_panel: Control = null
# The player's open/closed choice; `visible` also follows the Tab HUD toggle.
var _user_open: bool = false

func _ready():
	name = "LogPanel"
	# Keep receiving entries and scroll input while the tree is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Click-through: the log sits over the play field, and any non-IGNORE
	# control there makes ProceduralCharacter._handle_input treat the spot as
	# UI. Only the scrollbar takes the mouse, so history can still be read.
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style := GoldFrame.panel_style()
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

	# Bottom-right, left of the party panel, above its button.
	anchor_left = 1.0
	anchor_top = 1.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	custom_minimum_size = PANEL_SIZE
	offset_right = -RIGHT_MARGIN
	offset_left = -RIGHT_MARGIN - PANEL_SIZE.x

	_build_toggle_button()
	visible = false
	_place(false)

	var parent := get_parent()
	if parent:
		# A sibling, not a child: a PanelContainer lays out its children.
		parent.add_child.call_deferred(toggle_button)
	if parent and parent.has_node("DialoguePanel"):
		_dialogue_panel = parent.get_node("DialoguePanel")
		_dialogue_panel.visibility_changed.connect(_on_dialogue_visibility_changed)
		_place(_dialogue_panel.visible)
	# Both are HUD: they follow the party panel's Tab toggle like the clock
	# does. An open log comes back with the HUD; L still shows it while the
	# HUD is hidden.
	if parent and parent.has_node("PartySidePanel"):
		var panel = parent.get_node("PartySidePanel")
		_on_hud_toggled(panel.panel_visible)
		panel.panel_visibility_changed.connect(_on_hud_toggled)

	GameLog.entry_added.connect(_on_entry_added)
	GameLog.entry_repeated.connect(_on_entry_repeated)
	for entry in GameLog.get_entries():
		_add_log_label(entry.text, entry.game_time, int(entry.get("count", 1)))
	_scroll_to_bottom.call_deferred()

func _exit_tree() -> void:
	# The button lives under GameUI, not under us.
	if toggle_button and is_instance_valid(toggle_button) and not toggle_button.is_queued_for_deletion():
		toggle_button.queue_free()

func _build_toggle_button() -> void:
	toggle_button = Button.new()
	toggle_button.name = "LogButton"
	toggle_button.text = "Log"
	toggle_button.toggle_mode = true
	# Never take keyboard focus: Space (pause) would press a focused button.
	toggle_button.focus_mode = Control.FOCUS_NONE
	toggle_button.mouse_filter = Control.MOUSE_FILTER_STOP
	toggle_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	toggle_button.process_mode = Node.PROCESS_MODE_ALWAYS
	GoldFrame.apply_to_button(toggle_button)
	toggle_button.anchor_left = 1.0
	toggle_button.anchor_top = 1.0
	toggle_button.anchor_right = 1.0
	toggle_button.anchor_bottom = 1.0
	toggle_button.custom_minimum_size = BUTTON_SIZE
	toggle_button.offset_right = -RIGHT_MARGIN
	toggle_button.offset_left = -RIGHT_MARGIN - BUTTON_SIZE.x
	toggle_button.toggled.connect(_on_button_toggled)
	# set_open's ui-navigation is its sound.
	toggle_button.set_meta("sfx_silent", true)

	# Unread count, on the button's top-right corner; hidden at zero.
	unread_badge = Label.new()
	unread_badge.name = "UnreadBadge"
	unread_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	unread_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var badge_style := GoldFrame.panel_style()
	badge_style.content_margin_left = 4
	badge_style.content_margin_right = 4
	badge_style.content_margin_top = 0
	badge_style.content_margin_bottom = 0
	unread_badge.add_theme_stylebox_override("normal", badge_style)
	unread_badge.add_theme_color_override("font_color", GoldFrame.HEADER_COLOR)
	unread_badge.add_theme_font_size_override("font_size", 11)
	unread_badge.anchor_left = 1.0
	unread_badge.anchor_right = 1.0
	unread_badge.offset_left = -10
	unread_badge.offset_top = -10
	unread_badge.grow_horizontal = Control.GROW_DIRECTION_END
	unread_badge.visible = false
	toggle_button.add_child(unread_badge)
	_update_button()

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	# Plain L only: Ctrl+L and friends belong to Godot's text/file UI.
	if event.keycode != TOGGLE_KEY or event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		return
	# Typing in a text field (character creation, a filter) is not a hotkey.
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	# What the player sees decides: an open log hidden by Tab is shown.
	set_open(not visible)
	get_viewport().set_input_as_handled()

## Open or close the log. Opening marks everything read and shows the latest.
func set_open(open: bool) -> void:
	if open == _user_open and open == visible:
		return
	_user_open = open
	visible = open
	if open:
		unread_count = 0
		_scroll_to_bottom.call_deferred()
	if toggle_button.button_pressed != open:
		toggle_button.set_pressed_no_signal(open)
	_update_button()
	SfxManager.play_ui("ui-navigation")

func is_open() -> bool:
	return _user_open

func _on_button_toggled(pressed: bool) -> void:
	set_open(pressed)

# Tab: the button and an open log hide with the rest of the HUD and return
# with it; the log's open/closed choice is kept.
func _on_hud_toggled(now_visible: bool) -> void:
	toggle_button.visible = now_visible
	visible = _user_open and now_visible

func _update_button() -> void:
	if unread_badge:
		unread_badge.visible = unread_count > 0 and not _user_open
		unread_badge.text = "99+" if unread_count > 99 else str(unread_count)
	if toggle_button:
		var tip := "Game log (L): %s the message log." % ("hide" if _user_open else "show")
		if unread_count > 0 and not _user_open:
			tip += "\n%d new %s since you last looked." % [unread_count, "entry" if unread_count == 1 else "entries"]
		toggle_button.tooltip_text = tip

func _place(above_dialogue: bool) -> void:
	var bottom := BOTTOM_MARGIN + (DIALOGUE_BAND if above_dialogue else 0.0)
	if toggle_button:
		toggle_button.offset_bottom = -bottom
		toggle_button.offset_top = -bottom - BUTTON_SIZE.y
	bottom += BUTTON_SIZE.y + BUTTON_GAP
	offset_bottom = -bottom
	offset_top = -bottom - PANEL_SIZE.y

func _on_dialogue_visibility_changed() -> void:
	_place(_dialogue_panel.visible)

func _on_entry_added(text: String, timestamp: String):
	_add_log_label(text, timestamp)
	if not _user_open:
		unread_count += 1
		_update_button()
	if auto_scroll:
		await get_tree().process_frame
		_scroll_to_bottom()

func _on_entry_repeated(count: int) -> void:
	if log_content.get_child_count() == 0:
		return
	var label: RichTextLabel = log_content.get_child(log_content.get_child_count() - 1)
	label.text = _format_entry(label.get_meta("base_text", ""), label.get_meta("timestamp", ""), count)

func _format_entry(text: String, timestamp: String, count: int) -> String:
	var time_hex := TIME_COLOR.to_html(false)
	var repeat := " [color=#%s](x%d)[/color]" % [time_hex, count] if count > 1 else ""
	return "[color=#%s][%s][/color] %s%s" % [time_hex, timestamp, text, repeat]

func _scroll_to_bottom() -> void:
	scroll_container.scroll_vertical = int(scroll_container.get_v_scroll_bar().max_value)

func _add_log_label(text: String, timestamp: String, count: int = 1):
	var label = RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.set_meta("base_text", text)
	label.set_meta("timestamp", timestamp)
	label.text = _format_entry(text, timestamp, count)
	log_content.add_child(label)

	while log_content.get_child_count() > MAX_VISIBLE_ENTRIES:
		var old_child = log_content.get_child(0)
		log_content.remove_child(old_child)
		old_child.queue_free()
