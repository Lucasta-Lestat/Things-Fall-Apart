## MoonToggleButton
## Crescent-moon icon next to the time label. Click toggles Game.downtime_mode_active.
## Mirrors the party-panel visibility hook used by time.gd so the button hides
## along with the rest of the HUD when the user presses Tab.
extends TextureButton

const ICON_PATH := "res://UI/UI Icons/moon.png"

var _game: Node = null

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	ignore_texture_size = true
	custom_minimum_size = Vector2(28, 28)

	# Pin to the top-left, just to the right of the TimeLabel. We position
	# dynamically via _reposition() because the label's width changes with the
	# date string (e.g. "PRIMIDAY, WITHERUMNAL 1, 1945" is much wider than
	# "DECIDAY, THAW 5, 1945").
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 0.0
	grow_horizontal = Control.GROW_DIRECTION_END
	grow_vertical = Control.GROW_DIRECTION_END

	if ResourceLoader.exists(ICON_PATH):
		texture_normal = load(ICON_PATH)
	else:
		texture_normal = _make_placeholder_crescent()

	tooltip_text = "Downtime"
	pressed.connect(_on_pressed)

	_game = get_node_or_null("/root/Game")

	# Hide together with the rest of the HUD when the party panel collapses.
	var panel := _find_party_panel()
	if panel:
		visible = bool(panel.panel_visible)
		if panel.has_signal("panel_visibility_changed"):
			panel.connect("panel_visibility_changed", _on_party_panel_toggled)

	# Track the time label's bounding box so we always sit just to its right
	# even when the date string lengthens (TimeManager re-renders text every
	# minute, which triggers Label.resized).
	var time_label: Label = _find_time_label()
	if time_label:
		if not time_label.resized.is_connected(_reposition):
			time_label.resized.connect(_reposition)
	call_deferred("_reposition")

func _find_time_label() -> Label:
	var parent := get_parent()
	if parent and parent.has_node("TimeLabel"):
		return parent.get_node("TimeLabel") as Label
	return null

func _reposition() -> void:
	var time_label: Label = _find_time_label()
	if time_label == null:
		# Fall back to a generous fixed offset that clears most date strings.
		offset_left = 310
		offset_top = 16
	else:
		var label_rect: Rect2 = time_label.get_global_rect()
		offset_left = label_rect.position.x + label_rect.size.x + 8
		# Centre vertically on the label so the icon doesn't sit above the
		# first line.
		offset_top = label_rect.position.y + (label_rect.size.y - 28) * 0.5
	offset_right = offset_left + 28
	offset_bottom = offset_top + 28

func _on_pressed() -> void:
	if _game == null:
		_game = get_node_or_null("/root/Game")
	if _game == null:
		return
	_game.set_downtime_mode(not bool(_game.downtime_mode_active))

func _find_party_panel() -> Node:
	var parent := get_parent()
	if parent and parent.has_node("PartySidePanel"):
		return parent.get_node("PartySidePanel")
	return null

func _on_party_panel_toggled(now_visible: bool) -> void:
	visible = now_visible

# Procedural crescent fallback so the button always renders even before art is delivered.
func _make_placeholder_crescent() -> Texture2D:
	var size := 28
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx := float(size) * 0.5
	var cy := float(size) * 0.5
	var r_outer := float(size) * 0.45
	var r_inner := float(size) * 0.38
	var off := float(size) * 0.18
	for y in range(size):
		for x in range(size):
			var dx := float(x) - cx
			var dy := float(y) - cy
			var d_outer := sqrt(dx * dx + dy * dy)
			var dx2 := float(x) - (cx + off)
			var d_inner := sqrt(dx2 * dx2 + dy * dy)
			if d_outer <= r_outer and d_inner > r_inner:
				img.set_pixel(x, y, Color(0.95, 0.92, 0.65, 1.0))
	return ImageTexture.create_from_image(img)
