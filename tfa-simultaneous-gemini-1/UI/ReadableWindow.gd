# UI/ReadableWindow.gd
# Floating, parchment/book-themed window that displays a readable (note, letter,
# scroll, book, or tome). Modeled on ChestInventoryWindow. Content comes from
# ReadableDatabase; opening marks the readable read and files it in the journal
# via ReadableManager. Pure GDScript — instantiate with load(...).new(), NOT a
# PackedScene (see Game.show_readable).
extends PanelContainer
class_name ReadableWindow

const PARCHMENT_PATH := "res://UI/paper texture.png"
const BOOK_BG_PATH := "res://UI/book-page.png"

# Set by Game.show_readable before add_child.
var readable_id: String = ""

var _pages: Array = []
var _page_index: int = 0
var _body_label: RichTextLabel
var _page_indicator: Label

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP

	if ReadableDatabase == null or not ReadableDatabase.has_readable(readable_id):
		push_warning("ReadableWindow: unknown readable_id '%s'" % readable_id)
		queue_free()
		return

	var kind: String = ReadableDatabase.get_kind(readable_id)
	var title: String = ReadableDatabase.get_title(readable_id)
	_pages = ReadableDatabase.get_pages(readable_id)
	if _pages.is_empty():
		_pages = [""]

	# Center on screen.
	custom_minimum_size = Vector2(460, 540)
	anchor_left = 0.5
	anchor_top = 0.5
	anchor_right = 0.5
	anchor_bottom = 0.5
	offset_left = -230
	offset_top = -270
	offset_right = 230
	offset_bottom = 270

	add_theme_stylebox_override("panel", _make_kind_stylebox(kind))

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(vbox)

	# Header: title + close button.
	var header := HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(header)

	var title_label := RichTextLabel.new()
	title_label.bbcode_enabled = true
	title_label.fit_content = true
	title_label.scroll_active = false
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.text = "[b][color=#3b2a14]%s[/color][/b]" % title
	title_label.add_theme_font_size_override("normal_font_size", 20)
	title_label.add_theme_font_size_override("bold_font_size", 20)
	header.add_child(title_label)

	var close_btn := Button.new()
	close_btn.text = "X"
	close_btn.custom_minimum_size = Vector2(28, 28)
	close_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	close_btn.pressed.connect(_on_close_pressed)
	header.add_child(close_btn)

	vbox.add_child(HSeparator.new())

	# Body (scrollable).
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	vbox.add_child(scroll)

	_body_label = RichTextLabel.new()
	_body_label.bbcode_enabled = true
	_body_label.fit_content = true
	_body_label.scroll_active = false
	_body_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_label.add_theme_font_size_override("normal_font_size", 16)
	_body_label.add_theme_color_override("default_color", Color(0.17, 0.12, 0.03))
	scroll.add_child(_body_label)

	# Pagination footer (only for multi-page books).
	if _pages.size() > 1:
		var footer := HBoxContainer.new()
		footer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		footer.alignment = BoxContainer.ALIGNMENT_CENTER
		vbox.add_child(footer)

		var prev_btn := Button.new()
		prev_btn.text = "‹ Prev"
		prev_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		prev_btn.pressed.connect(_on_prev_pressed)
		footer.add_child(prev_btn)

		_page_indicator = Label.new()
		_page_indicator.custom_minimum_size = Vector2(80, 0)
		_page_indicator.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_page_indicator.add_theme_color_override("font_color", Color(0.23, 0.16, 0.05))
		footer.add_child(_page_indicator)

		var next_btn := Button.new()
		next_btn.text = "Next ›"
		next_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		next_btn.pressed.connect(_on_next_pressed)
		footer.add_child(next_btn)

	_render_page()

	# Opening a readable counts as reading it: file it in the journal + mark read.
	if ReadableManager != null:
		ReadableManager.mark_read(readable_id)

	if SfxManager != null and SfxManager.has_method("play_ui"):
		SfxManager.play_ui("ui-navigation")

func _make_kind_stylebox(kind: String) -> StyleBox:
	var k: String = kind.to_lower()
	var tex_path: String = PARCHMENT_PATH
	if k == "book" or k == "tome":
		tex_path = BOOK_BG_PATH
	if ResourceLoader.exists(tex_path):
		var sb := StyleBoxTexture.new()
		sb.texture = load(tex_path)
		sb.content_margin_left = 24
		sb.content_margin_right = 24
		sb.content_margin_top = 20
		sb.content_margin_bottom = 20
		return sb
	# Fallback: aged-paper flat box (used when the book art isn't present yet).
	var flat := StyleBoxFlat.new()
	flat.bg_color = Color(0.86, 0.80, 0.62)
	flat.border_color = Color(0.45, 0.32, 0.16)
	flat.set_border_width_all(3)
	flat.set_corner_radius_all(6)
	flat.set_content_margin_all(20)
	return flat

func _render_page() -> void:
	if _body_label == null:
		return
	var idx: int = clampi(_page_index, 0, _pages.size() - 1)
	_page_index = idx
	_body_label.text = str(_pages[idx])
	if _page_indicator != null:
		_page_indicator.text = "%d / %d" % [idx + 1, _pages.size()]

func _on_prev_pressed() -> void:
	if _page_index > 0:
		_page_index -= 1
		_render_page()
		if SfxManager != null and SfxManager.has_method("play_ui"):
			SfxManager.play_ui("ui-navigation")

func _on_next_pressed() -> void:
	if _page_index < _pages.size() - 1:
		_page_index += 1
		_render_page()
		if SfxManager != null and SfxManager.has_method("play_ui"):
			SfxManager.play_ui("ui-navigation")

func _on_close_pressed() -> void:
	if SfxManager != null and SfxManager.has_method("play_ui"):
		SfxManager.play_ui("ui-navigation")
	queue_free()
