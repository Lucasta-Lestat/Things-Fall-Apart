# =====================
# UI/HudStatusBar.gd - Always-visible status strip at the top-left, just under
# the clock (TimeLabel). Game._ready instances it under GameUI as
# Game.hud_status. It ships empty; features append small widgets:
#
#   game.hud_status.add_widget(my_badge)
#
# Unlike the clock and log it ignores the Tab HUD toggle, so a status the
# player must always know (sneaking, wind) stays on screen. When a flush-left
# panel (Town Services from y=64, the quest log from y=80) is open it moves
# beside the panel instead of covering its top, following the panel's slide.
# =====================

extends HBoxContainer

const LEFT_MARGIN := 16.0       # lines up with TimeLabel's offset_left
const GAP_BELOW_CLOCK := 4.0
const FALLBACK_TOP := 64.0      # if there's no TimeLabel to sit under
const GAP_BESIDE_PANEL := 8.0
# GameUI children that sit flush left under the clock; the strip steps aside.
const LEFT_PANELS := ["TownServicesPanel", "QuestLogPanel"]

func _ready() -> void:
	name = "HudStatusBar"
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Click-through, like the log: a non-IGNORE control here would make
	# ProceduralCharacter._handle_input treat the spot as UI.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 8)

	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 0.0
	grow_horizontal = Control.GROW_DIRECTION_END
	grow_vertical = Control.GROW_DIRECTION_END

	# The clock is two lines (date, time) and its height can change with the
	# font, so follow its rect rather than hard-coding a top offset.
	var time_label := _find_time_label()
	if time_label and not time_label.resized.is_connected(_reposition):
		time_label.resized.connect(_reposition)
	_reposition()
	_reposition.call_deferred()

# Every frame: the services panel and quest log tween in and out (Tab, J) and
# the services panel shows/hides per region, none emitting anything the strip
# could wait for.
func _process(_delta: float) -> void:
	_reposition()

## Append a widget to the strip. It is made click-through (IGNORE) unless it
## has set MOUSE_FILTER_PASS itself to get a hover tooltip.
func add_widget(c: Control) -> void:
	if c == null:
		return
	if c.mouse_filter != Control.MOUSE_FILTER_PASS:
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(c)

func _find_time_label() -> Control:
	var parent := get_parent()
	if parent and parent.has_node("TimeLabel"):
		return parent.get_node("TimeLabel") as Control
	return null

func _find_left_panels() -> Array:
	var out: Array = []
	var parent := get_parent()
	if parent == null:
		return out
	for n in LEFT_PANELS:
		var c := parent.get_node_or_null(n) as Control
		if c:
			out.append(c)
	return out

func _reposition() -> void:
	var top := FALLBACK_TOP
	var time_label := _find_time_label()
	if time_label:
		# Hidden by Tab or not, the clock keeps its rect, so the strip stays put.
		top = time_label.position.y + time_label.size.y + GAP_BELOW_CLOCK
	var left := LEFT_MARGIN
	# Both slide off-screen rather than hide, so test where they are now.
	for panel in _find_left_panels():
		if not panel.visible:
			continue
		var r: Rect2 = panel.get_rect()
		if r.end.x > LEFT_MARGIN and r.position.y < top + maxf(size.y, 1.0) and r.end.y > top:
			left = maxf(left, r.end.x + GAP_BESIDE_PANEL)
	if is_equal_approx(offset_left, left) and is_equal_approx(offset_top, top):
		return
	offset_left = left
	offset_top = top
	offset_right = left
	offset_bottom = top
