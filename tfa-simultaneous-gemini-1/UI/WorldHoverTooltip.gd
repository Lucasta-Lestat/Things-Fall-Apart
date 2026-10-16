# =====================
# UI/WorldHoverTooltip.gd - The single hover tooltip for things in the WORLD
# (characters, tiles, hazards). UI controls keep their own tooltip_text.
# Game._ready instances it under GameUI as Game.world_tooltip. It ships with
# no providers; features register one each:
#
#   game.world_tooltip.add_provider("hazards", _hazard_text, true, 10)
#
# A provider is called as provider.call(world_pos: Vector2) and returns a
# String (BBCode allowed); "" means it has nothing to say there. Providers are
# asked in descending priority (ties: first registered first), paused_only
# ones only while PauseManager.is_paused, and the first non-empty text wins.
# =====================

extends PanelContainer

const REFRESH_SEC := 0.1
const CURSOR_OFFSET := Vector2(18, 18)
const MAX_TEXT_WIDTH := 320.0   # unwrapped up to this, then word-wrapped at it
const FONT_SIZE := 14
const TEXT_COLOR := Color(0.93, 0.9, 0.84)
const NO_CELL := Vector2i(-2147483648, -2147483648)

# id -> {"callable", "paused_only", "priority", "order"}
var _providers: Dictionary = {}
var _sorted: Array = []  # the records above, in the order they are asked
var _next_order: int = 0

var _label: RichTextLabel
var _game: Node = null
var _text: String = ""
var _refresh_left: float = 0.0
var _last_cell: Vector2i = NO_CELL

func _ready() -> void:
	name = "WorldHoverTooltip"
	# Hovering is for planning, so it must keep working while the tree is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Click-through, children included: any non-IGNORE control here would make
	# ProceduralCharacter._handle_input read the cursor as over UI.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 100
	visible = false

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.05, 0.04, 0.88)
	style.set_border_width_all(1)
	style.border_color = Color(0.45, 0.4, 0.3)
	style.set_corner_radius_all(4)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	add_theme_stylebox_override("panel", style)

	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("normal_font_size", FONT_SIZE)
	_label.add_theme_font_size_override("bold_font_size", FONT_SIZE)
	_label.add_theme_font_size_override("italics_font_size", FONT_SIZE)
	_label.add_theme_color_override("default_color", TEXT_COLOR)
	add_child(_label)

	_game = get_node_or_null("/root/Game")

# ---------------------------------------------------------------------------
# Provider API
# ---------------------------------------------------------------------------

## Register (or replace) the provider `id`. Higher priority is asked first.
## paused_only providers are skipped unless the game is paused.
func add_provider(id: String, provider: Callable, paused_only: bool = false, priority: int = 0) -> void:
	_providers[id] = {
		"callable": provider,
		"paused_only": paused_only,
		"priority": priority,
		"order": _next_order,
	}
	_next_order += 1
	_resort()

func remove_provider(id: String) -> void:
	if _providers.erase(id):
		_resort()

func _resort() -> void:
	_sorted = _providers.values()
	_sorted.sort_custom(func(a, b):
		if a.priority != b.priority:
			return a.priority > b.priority
		return a.order < b.order)
	# Ask again on the next frame rather than showing a stale answer.
	_last_cell = NO_CELL

# ---------------------------------------------------------------------------
# Per-frame update
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _sorted.is_empty() or _blocked():
		_hide()
		return
	var vp := get_viewport()
	# GameUI is a CanvasLayer, so map the mouse through the world camera.
	var world_pos: Vector2 = vp.get_canvas_transform().affine_inverse() * vp.get_mouse_position()
	var cell := Vector2i((world_pos / float(maxi(1, GridManager.TILE_SIZE))).floor())
	_refresh_left -= delta
	if cell != _last_cell or _refresh_left <= 0.0:
		_last_cell = cell
		_refresh_left = REFRESH_SEC
		_set_text(_query(world_pos))
	if _text.is_empty():
		visible = false
		return
	_place()
	visible = true

## True when the world isn't what the cursor is pointing at.
func _blocked() -> bool:
	if _game == null or not is_instance_valid(_game):
		_game = get_node_or_null("/root/Game")
	if _game != null:
		# PopupMenus live in their own Window, invisible to gui_get_hovered_control.
		# == true, not bool(): get() is null on a stand-in Game without the flag.
		if _game.get("context_menu_open") == true:
			return true
		var dialogue = _game.get_node_or_null("GameUI/DialoguePanel")
		if dialogue is CanvasItem and dialogue.visible:
			return true
	# Same test as ProceduralCharacter._handle_input: a hovered control with a
	# CanvasLayer ancestor is real UI. World-space controls (fog overlays) aren't.
	var node: Node = get_viewport().gui_get_hovered_control()
	while node != null:
		if node is CanvasLayer:
			return true
		node = node.get_parent()
	return false

func _query(world_pos: Vector2) -> String:
	var paused: bool = PauseManager.is_paused
	for rec in _sorted:
		if rec.paused_only and not paused:
			continue
		var provider: Callable = rec.callable
		if not provider.is_valid():
			continue
		var result = provider.call(world_pos)
		if result != null and str(result) != "":
			return str(result)
	return ""

func _set_text(t: String) -> void:
	if t == _text:
		return
	_text = t
	# Natural width first; only text wider than MAX_TEXT_WIDTH wraps at it.
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_label.custom_minimum_size = Vector2.ZERO
	_label.text = t
	if _label.get_content_width() > MAX_TEXT_WIDTH:
		_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_label.custom_minimum_size = Vector2(MAX_TEXT_WIDTH, 0)
	reset_size()

## Mouse + CURSOR_OFFSET, clamped so the whole panel stays on screen.
func _place() -> void:
	reset_size()
	var vp := get_viewport()
	var screen: Vector2 = vp.get_visible_rect().size
	var pos: Vector2 = vp.get_mouse_position() + CURSOR_OFFSET
	pos.x = clampf(pos.x, 0.0, maxf(0.0, screen.x - size.x))
	pos.y = clampf(pos.y, 0.0, maxf(0.0, screen.y - size.y))
	position = pos

func _hide() -> void:
	visible = false
	# Re-ask as soon as the cursor is back over the world.
	_last_cell = NO_CELL
