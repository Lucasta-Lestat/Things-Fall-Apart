# res://tests/party_panel_tab_test.gd
# Headless regression harness: Tab hides the party side panel with the rest of
# the HUD, and brings it back.
#
# The panel is right-anchored and grows to the left (game.tscn), and the hide
# slid only offset_left to the screen edge, squeezing it to zero width. Once its
# ScrollContainer's horizontal mode became DISABLED (6aae4699), the panel's
# minimum width became the rows' ~244 px, so the squeezed panel grew straight
# back over the screen: Tab hid the clock, moon and log button, and the party
# panel stayed. The checks use real Tab key events through Input, so a node
# eating Tab would fail them too.
# Run:  godot --headless --path . res://tests/party_panel_tab_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

var failures := 0
var game = null
var psp = null

func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])

func _await_frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

func _key(code: int, pressed: bool) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = pressed
	return e

func _press_tab() -> void:
	Input.parse_input_event(_key(KEY_TAB, true))
	Input.parse_input_event(_key(KEY_TAB, false))
	await _await_frames(2)

# Let a slide finish (SLIDE_DURATION 0.3 s) and the layout settle.
func _await_slide() -> void:
	await get_tree().create_timer(psp.SLIDE_DURATION + 0.25, true, false, true).timeout
	await _await_frames(3)

func _ready() -> void:
	TimeManager.pause_time()
	# Headless windows are 64x64; give the root a real screen so "off screen"
	# means something.
	get_tree().root.size = Vector2i(1900, 1080)
	await get_tree().process_frame
	game = load("res://game.tscn").instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _await_frames(2)
	game.load_map("town_square")
	await _await_frames(10)
	for c in game.party_chars:
		c.AI_enabled = false
	psp = game.get_node("GameUI/PartySidePanel")

	await _case_tab_hides_and_shows()
	await _case_tab_mid_slide()
	await _case_over_wide_row()

	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _screen_right() -> float:
	return psp.get_viewport_rect().end.x

func _shown_ok() -> bool:
	var r: Rect2 = psp.get_global_rect()
	return psp.panel_visible and psp.is_visible_in_tree() \
		and is_equal_approx(r.end.x, _screen_right()) \
		and is_equal_approx(r.size.x, psp.PANEL_WIDTH)

# Nothing of the panel left on screen: parked past the right edge, and hidden.
func _hidden_ok() -> bool:
	var r: Rect2 = psp.get_global_rect()
	return not psp.panel_visible and not psp.is_visible_in_tree() \
		and r.position.x >= _screen_right() - 0.5

func _rect_str() -> String:
	return "rect %s screen right %s panel_visible %s visible %s min %s" % [
		psp.get_global_rect(), _screen_right(), psp.panel_visible, psp.visible,
		psp.get_combined_minimum_size()]

func _case_tab_hides_and_shows() -> void:
	var ui: Node = game.get_node("GameUI")
	var clock: Control = ui.get_node("TimeLabel")
	_check("setup.shown-at-right-edge", _shown_ok(), _rect_str())
	_check("setup.rows-as-wide-as-the-strip", psp.get_combined_minimum_size().x > psp.PANEL_WIDTH * 0.5,
		"min %s (the bug needs a real minimum width to show)" % psp.get_combined_minimum_size())
	_check("setup.clock-shown", clock.visible)

	await _press_tab()
	await _await_slide()
	_check("tab.panel-off-screen", _hidden_ok(), _rect_str())
	_check("tab.rest-of-hud-hides-too", not clock.visible)

	await _press_tab()
	await _await_slide()
	_check("tab-again.panel-back", _shown_ok(), _rect_str())
	_check("tab-again.rest-of-hud-back", clock.visible)

# A second Tab while the hide is still sliding turns it around: the panel ends
# shown, and the cancelled hide doesn't switch it off afterwards.
func _case_tab_mid_slide() -> void:
	await _press_tab()
	await _press_tab()
	await _await_slide()
	await _await_slide()
	_check("mid-slide.reversed-hide-ends-shown", _shown_ok(), _rect_str())

	await _press_tab()
	await _await_slide()
	await _press_tab()
	await _press_tab()
	await _await_slide()
	await _await_slide()
	_check("mid-slide.reversed-show-ends-hidden", _hidden_ok(), _rect_str())
	await _press_tab()
	await _await_slide()
	_check("mid-slide.shown-again", _shown_ok(), _rect_str())

# A row wider than PANEL_WIDTH (what _warn_if_too_wide reports) widens the
# panel; hidden, none of it may stay on screen.
func _case_over_wide_row() -> void:
	var wide := Control.new()
	wide.custom_minimum_size = Vector2(psp.PANEL_WIDTH + 150.0, 4)
	psp.vbox.add_child(wide)
	await _await_frames(3)
	await _press_tab()
	await _await_slide()
	_check("over-wide.panel-hidden", _hidden_ok() or (not psp.panel_visible and not psp.is_visible_in_tree()),
		_rect_str())
	await _press_tab()
	await _await_slide()
	_check("over-wide.panel-back", psp.panel_visible and psp.is_visible_in_tree(), _rect_str())
	wide.queue_free()
	await _await_frames(3)
