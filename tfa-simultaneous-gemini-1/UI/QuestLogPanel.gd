# UI/QuestLogPanel.gd
# Parchment-styled quest log toggled with the J key. Renders active quests
# (icon + display name) and a nested checklist of their stages:
#   done    -> [s]☑ name[/s]
#   current -> ☐ name + description
# Future stages are hidden (decision: "hide until reached").
# Listens to QuestManager signals and refreshes live.
extends PanelContainer

const PANEL_WIDTH := 420.0
const PANEL_HEIGHT := 520.0
const SLIDE_DURATION := 0.3
const PARCHMENT_PATH := "res://UI/paper texture.png"
const DEFAULT_ICON_PATH := "res://Icons/dummy_icon.png"

var panel_visible: bool = false
var _shown_x: float = 0.0
var _hidden_x: float = 0.0
var _tween: Tween = null

var _margin: MarginContainer
var _scroll: ScrollContainer
var _content_vbox: VBoxContainer

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP

	# Parchment background
	var style := StyleBoxTexture.new()
	if ResourceLoader.exists(PARCHMENT_PATH):
		style.texture = load(PARCHMENT_PATH)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 16
	style.content_margin_bottom = 16
	add_theme_stylebox_override("panel", style)

	# Sizing & anchor (top-left, slides in from the left edge)
	custom_minimum_size = Vector2(PANEL_WIDTH, PANEL_HEIGHT)
	size = Vector2(PANEL_WIDTH, PANEL_HEIGHT)
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 0.0
	offset_top = 80.0
	# Hidden position = fully off-screen to the left.
	_hidden_x = -PANEL_WIDTH - 8.0
	_shown_x = 16.0
	offset_left = _hidden_x
	offset_right = offset_left + PANEL_WIDTH
	visible = true  # we slide rather than toggle visibility, mirroring PartySidePanel

	# Layout
	_margin = MarginContainer.new()
	_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_margin)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_margin.add_child(_scroll)

	_content_vbox = VBoxContainer.new()
	_content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_vbox.add_theme_constant_override("separation", 12)
	_scroll.add_child(_content_vbox)

	# Hook QuestManager signals (after autoloads are ready)
	call_deferred("_connect_quest_manager")
	call_deferred("_refresh")

func _connect_quest_manager() -> void:
	if QuestManager == null:
		return
	if not QuestManager.quest_updated.is_connected(_on_quest_event):
		QuestManager.quest_updated.connect(_on_quest_event)
	if not QuestManager.quest_stage_changed.is_connected(_on_quest_stage_changed):
		QuestManager.quest_stage_changed.connect(_on_quest_stage_changed)
	if not QuestManager.quest_completed.is_connected(_on_quest_event):
		QuestManager.quest_completed.connect(_on_quest_event)
	if not QuestManager.quest_failed.is_connected(_on_quest_event):
		QuestManager.quest_failed.connect(_on_quest_event)

func _on_quest_event(_quest_id: String) -> void:
	# Defer to next frame: the signal often fires mid-init (autoload deferred
	# auto-start), and rebuilding RichTextLabel trees during scene setup has
	# caused engine-side layout crashes.
	call_deferred("_refresh")

func _on_quest_stage_changed(_quest_id: String, _old: String, _new: String) -> void:
	call_deferred("_refresh")

# ---------------------------------------------------------------------------
# Toggle (J key)
# ---------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_J:
			_toggle_panel()
			get_viewport().set_input_as_handled()

func _toggle_panel() -> void:
	if _tween and _tween.is_running():
		_tween.kill()
	panel_visible = not panel_visible
	var target_x: float = _shown_x if panel_visible else _hidden_x
	_tween = create_tween()
	_tween.tween_property(self, "offset_left", target_x, SLIDE_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.parallel().tween_property(self, "offset_right", target_x + PANEL_WIDTH, SLIDE_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if SfxManager and SfxManager.has_method("play_ui"):
		SfxManager.play_ui("ui-navigation")
	if panel_visible:
		_refresh()

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------

func _refresh() -> void:
	print("[QuestLogPanel] _refresh BEGIN")
	if _content_vbox == null:
		print("[QuestLogPanel] _refresh: _content_vbox is null, bail")
		return
	if not is_inside_tree():
		print("[QuestLogPanel] _refresh: not in tree, bail")
		return
	for child in _content_vbox.get_children():
		child.queue_free()

	if QuestManager == null or QuestDatabase == null:
		print("[QuestLogPanel] _refresh: QM/QD null, bail")
		return

	var active_ids: Array = QuestManager.get_active_quests()
	var completed_ids: Array = QuestManager.get_completed_quests()
	var failed_ids: Array = QuestManager.get_failed_quests()

	# Title
	var title := RichTextLabel.new()
	title.bbcode_enabled = true
	title.fit_content = true
	title.scroll_active = false
	title.text = "[b][color=#3b2a14]Quest Log[/color][/b]"
	title.add_theme_font_size_override("normal_font_size", 22)
	_content_vbox.add_child(title)

	if active_ids.is_empty() and completed_ids.is_empty() and failed_ids.is_empty():
		var empty := RichTextLabel.new()
		empty.bbcode_enabled = true
		empty.fit_content = true
		empty.scroll_active = false
		empty.text = "[i][color=#5a4225]No quests yet.[/color][/i]"
		_content_vbox.add_child(empty)
		return

	for qid in active_ids:
		print("[QuestLogPanel] _refresh build active=", qid)
		_content_vbox.add_child(_build_quest_block(qid, "active"))
	for qid in completed_ids:
		_content_vbox.add_child(_build_quest_block(qid, "completed"))
	for qid in failed_ids:
		_content_vbox.add_child(_build_quest_block(qid, "failed"))
	print("[QuestLogPanel] _refresh END (built ", active_ids.size(), " active)")

func _build_quest_block(quest_id: String, group: String) -> Control:
	var q: Dictionary = QuestDatabase.get_quest(quest_id)
	var display_name: String = str(q.get("display_name", quest_id))
	var icon_path: String = str(q.get("icon", ""))

	var block := VBoxContainer.new()
	block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	block.add_theme_constant_override("separation", 4)

	# Header: icon + display name
	var header := HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_theme_constant_override("separation", 8)

	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(40, 40)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	if not icon_path.is_empty() and ResourceLoader.exists(icon_path):
		icon.texture = load(icon_path)
	elif ResourceLoader.exists(DEFAULT_ICON_PATH):
		icon.texture = load(DEFAULT_ICON_PATH)
	header.add_child(icon)

	var name_label := RichTextLabel.new()
	name_label.bbcode_enabled = true
	name_label.fit_content = true
	name_label.scroll_active = false
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tag := ""
	if group == "completed":
		tag = "  [i](completed)[/i]"
	elif group == "failed":
		tag = "  [i](failed)[/i]"
	if group == "completed":
		name_label.text = "[b][s][color=#3b2a14]%s[/color][/s][/b]%s" % [display_name, tag]
	elif group == "failed":
		name_label.text = "[b][color=#7a1f1f]%s[/color][/b]%s" % [display_name, tag]
	else:
		name_label.text = "[b][color=#2c1f08]%s[/color][/b]" % display_name
	name_label.add_theme_font_size_override("normal_font_size", 16)
	name_label.add_theme_font_size_override("bold_font_size", 16)
	header.add_child(name_label)
	block.add_child(header)

	# Nested checklist
	var checklist: Array = QuestManager.get_quest_checklist(quest_id)
	for entry in checklist:
		block.add_child(_build_checklist_row(entry))

	return block

func _build_checklist_row(entry: Dictionary) -> Control:
	var row := VBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 2)

	var status: String = str(entry.get("status", "future"))
	var name_text: String = str(entry.get("name", ""))
	var desc_text: String = str(entry.get("description", ""))

	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("normal_font_size", 14)

	# Indent so the checklist visually nests under the quest title.
	var indent := "    "
	match status:
		"done":
			label.text = "%s[s][color=#5a4225]☑ %s[/color][/s]" % [indent, name_text]
		"current":
			label.text = "%s[color=#2c1f08]☐ %s[/color]" % [indent, name_text]
		"failed":
			label.text = "%s[color=#7a1f1f]✗ %s[/color]" % [indent, name_text]
		_:
			label.text = "%s[color=#7a6a55]☐ %s[/color]" % [indent, name_text]
	row.add_child(label)

	# Show description only for the active stage.
	if status == "current" and not desc_text.is_empty():
		var desc := RichTextLabel.new()
		desc.bbcode_enabled = true
		desc.fit_content = true
		desc.scroll_active = false
		desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		desc.add_theme_font_size_override("normal_font_size", 12)
		desc.text = "%s    [i][color=#5a4225]%s[/color][/i]" % [indent, desc_text]
		row.add_child(desc)

	return row
