# tools/build_theme.gd
# Regenerates res://ui/fairy_chess_theme.tres, which project.godot wires up as
# the project-wide theme. Run it headless from the project root:
#
#   Godot_v4.6-stable_win64_console.exe --headless --path . --script tools/build_theme.gd
#
# This script is the source of truth for the theme -- edit here, re-run, commit
# the regenerated .tres. Hand-editing the .tres is a trap: a wrong load_steps
# count or a typo'd SubResource id makes it unloadable, and Godot then falls
# back to the default theme silently.
#
# Two font tiers, deliberately:
#   display -> Cinzel, the same face the main game uses. Its lowercase renders
#              as small caps, which is handsome for titles and unreadable for
#              dense text.
#   body    -> Godot's built-in Open Sans SemiBold, reached by leaving
#              Theme.default_font unset. Nothing to ship, and the semibold
#              weight holds up against the wood background.
extends SceneTree

const OUT_PATH := "res://ui/fairy_chess_theme.tres"
const FONT_PATH := "res://Fonts/Cinzel-Regular.ttf"

# --- Palette -----------------------------------------------------------------
# Warm tones are sampled from this game's own art (logo, table, portrait frame);
# the golds are the main game's signature accent, so the minigame reads as part
# of the same product once it is embedded.
const PANEL       := Color(0.161, 0.129, 0.110)  # #29211C
const PANEL_DEEP  := Color(0.133, 0.094, 0.059)  # #22180F
const BRONZE      := Color(0.318, 0.235, 0.169)  # #513C2B
const BRONZE_LIT  := Color(0.420, 0.286, 0.176)  # #6B492D
const BRONZE_HI   := Color(0.553, 0.412, 0.302)  # #8D694D
const GOLD        := Color(0.600, 0.451, 0.200)  # #997333
const GOLD_BRIGHT := Color(0.851, 0.722, 0.400)  # #D9B866
const GOLD_HEAD   := Color(0.851, 0.749, 0.400)  # #D9BF66
const GOLD_HI     := Color(1.000, 0.900, 0.400)  # #FFE666
const CREAM       := Color(0.984, 0.847, 0.698)  # #FBD8B2
const TAN         := Color(0.741, 0.608, 0.463)  # #BD9B76
const INK         := Color(0.102, 0.098, 0.098)  # #1A1919
const INERT       := Color(0.550, 0.550, 0.650)  # #8C8CA6
const HUD_TEXT    := Color(1.000, 1.000, 1.000)  # #FFFFFF
# The board stays in the warm family, but the light square is a real ivory
# rather than a tan: with both squares brown the board read as one mass against
# the wooden table. Square separation 4.47:1 -> 6.83:1.
const TILE_LIGHT  := Color(0.910, 0.851, 0.745)  # #E8D9BE
const TILE_DARK   := Color(0.353, 0.251, 0.188)  # #5A4030


func _alpha(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, a)


func _flat(bg: Color, border: Color, bw: int, radius: int, mh: int, mv: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(bw)
	s.set_corner_radius_all(radius)
	s.content_margin_left = mh
	s.content_margin_right = mh
	s.content_margin_top = mv
	s.content_margin_bottom = mv
	return s


func _empty(m: int) -> StyleBoxEmpty:
	var s := StyleBoxEmpty.new()
	s.content_margin_left = m
	s.content_margin_right = m
	s.content_margin_top = m
	s.content_margin_bottom = m
	return s


func _init() -> void:
	var cinzel: Font = load(FONT_PATH)
	if cinzel == null:
		push_error("Cinzel not imported -- run the editor once, or --headless --import.")
		quit(1)
		return

	var t := Theme.new()
	# default_font is deliberately UNSET so it falls through to the engine's
	# Open Sans SemiBold (the body tier). Setting it -- or setting
	# gui/theme/custom_font in project.godot -- would force Cinzel onto every
	# control and overflow the piece-name column.
	t.default_font_size = 14

	# ---------- Label ----------
	t.set_color("font_color", "Label", CREAM)
	t.set_color("font_outline_color", "Label", INK)
	t.set_constant("outline_size", "Label", 0)

	# Labels that sit on bare wood need an outline: white-on-wood measures only
	# 4.46:1 over bright grain, but an ink outline makes the effective local
	# background #1A1919 regardless of what is behind it.
	t.set_type_variation("HudLabel", "Label")
	t.set_font("font", "HudLabel", cinzel)
	t.set_font_size("font_size", "HudLabel", 16)
	t.set_color("font_color", "HudLabel", HUD_TEXT)
	t.set_color("font_outline_color", "HudLabel", INK)
	t.set_constant("outline_size", "HudLabel", 4)

	t.set_type_variation("PanelHeading", "Label")
	t.set_font("font", "PanelHeading", cinzel)
	t.set_font_size("font_size", "PanelHeading", 14)
	t.set_color("font_color", "PanelHeading", GOLD_HEAD)

	# White rather than cream: this label sits on bare wood, and cream measured
	# only 3.31:1 over bright grain. White is 11.2:1 typical / 4.46:1 worst, and
	# the outline covers the rest. The heavier outline is for Cinzel's thin
	# hairlines, which the 4px version was not quite carrying at this size.
	t.set_type_variation("ProfileName", "Label")
	t.set_font("font", "ProfileName", cinzel)
	t.set_font_size("font_size", "ProfileName", 16)
	t.set_color("font_color", "ProfileName", HUD_TEXT)
	t.set_color("font_outline_color", "ProfileName", INK)
	t.set_constant("outline_size", "ProfileName", 6)

	t.set_type_variation("ModalTitle", "Label")
	t.set_font("font", "ModalTitle", cinzel)
	t.set_font_size("font_size", "ModalTitle", 24)
	t.set_color("font_color", "ModalTitle", GOLD_HI)

	t.set_type_variation("ModalVs", "Label")
	t.set_font("font", "ModalVs", cinzel)
	t.set_font_size("font_size", "ModalVs", 18)
	t.set_color("font_color", "ModalVs", TAN)

	t.set_type_variation("ModalHint", "Label")
	t.set_font_size("font_size", "ModalHint", 12)
	t.set_color("font_color", "ModalHint", TAN)

	t.set_type_variation("GameOverTitle", "Label")
	t.set_font("font", "GameOverTitle", cinzel)
	t.set_font_size("font_size", "GameOverTitle", 30)
	t.set_color("font_color", "GameOverTitle", GOLD_HI)

	# Piece names sit inside the tray panel, so they need no outline -- and they
	# stay on the body face, where Cinzel would be both wider and less legible.
	t.set_type_variation("PieceName", "Label")
	t.set_font_size("font_size", "PieceName", 11)
	t.set_color("font_color", "PieceName", CREAM)

	# ---------- Button ----------
	t.set_font("font", "Button", cinzel)
	t.set_font_size("font_size", "Button", 14)
	t.set_color("font_color", "Button", CREAM)
	t.set_color("font_hover_color", "Button", GOLD_HI)
	t.set_color("font_pressed_color", "Button", GOLD_HI)
	t.set_color("font_hover_pressed_color", "Button", GOLD_HI)
	t.set_color("font_focus_color", "Button", CREAM)
	t.set_color("font_disabled_color", "Button", INERT)
	t.set_constant("h_separation", "Button", 6)
	t.set_constant("icon_max_width", "Button", 56)
	t.set_constant("outline_size", "Button", 0)
	t.set_stylebox("normal", "Button", _flat(_alpha(BRONZE, 0.85), GOLD, 1, 4, 12, 6))
	t.set_stylebox("hover", "Button", _flat(_alpha(BRONZE_LIT, 0.92), GOLD_BRIGHT, 1, 4, 12, 6))
	t.set_stylebox("pressed", "Button", _flat(_alpha(PANEL, 0.95), GOLD_BRIGHT, 1, 4, 12, 6))
	t.set_stylebox("disabled", "Button", _flat(_alpha(PANEL, 0.60), _alpha(GOLD, 0.40), 1, 4, 12, 6))
	t.set_stylebox("focus", "Button", _flat(Color(0, 0, 0, 0), GOLD_HI, 2, 4, 12, 6))

	# Promotion / action picker grid buttons: icon above label, so squarer.
	t.set_type_variation("PickerButton", "Button")
	t.set_constant("icon_max_width", "PickerButton", 56)
	t.set_stylebox("normal", "PickerButton", _flat(_alpha(BRONZE, 0.85), GOLD, 1, 6, 8, 8))
	t.set_stylebox("hover", "PickerButton", _flat(_alpha(BRONZE_LIT, 0.92), GOLD_BRIGHT, 2, 6, 8, 8))

	# Profile-picker White/Black slots. The active one gets a brighter fill and a
	# 2px rim rather than a modulate, which would tint text and border together.
	t.set_type_variation("SlotButton", "Button")

	t.set_type_variation("SlotButtonActive", "Button")
	t.set_color("font_color", "SlotButtonActive", GOLD_HI)
	t.set_stylebox("normal", "SlotButtonActive", _flat(_alpha(BRONZE_LIT, 0.95), GOLD_HI, 2, 4, 12, 6))
	t.set_stylebox("hover", "SlotButtonActive", _flat(_alpha(BRONZE_HI, 0.95), GOLD_HI, 2, 4, 12, 6))

	# ---------- CheckBox (the AI toggle; the project has no CheckButton) ----------
	# The engine's check glyphs are monochrome and read fine on dark, so only the
	# text and the focus ring are restyled.
	t.set_font("font", "CheckBox", cinzel)
	t.set_font_size("font_size", "CheckBox", 14)
	t.set_color("font_color", "CheckBox", CREAM)
	t.set_color("font_hover_color", "CheckBox", GOLD_HI)
	t.set_color("font_pressed_color", "CheckBox", GOLD_HI)
	t.set_color("font_disabled_color", "CheckBox", INERT)
	t.set_constant("h_separation", "CheckBox", 6)
	t.set_stylebox("normal", "CheckBox", _empty(4))
	t.set_stylebox("hover", "CheckBox", _empty(4))
	t.set_stylebox("pressed", "CheckBox", _empty(4))
	t.set_stylebox("disabled", "CheckBox", _empty(4))
	t.set_stylebox("focus", "CheckBox", _flat(Color(0, 0, 0, 0), GOLD_HI, 1, 3, 4, 4))

	# ---------- Panels ----------
	# Embedded panels (the game-over card) take the main game's tighter recipe.
	t.set_stylebox("panel", "PanelContainer", _flat(_alpha(PANEL, 0.92), GOLD, 1, 4, 10, 10))

	# Floating modals sit above a scrim, so they carry a heavier rim.
	t.set_type_variation("ModalPanel", "PanelContainer")
	t.set_stylebox("panel", "ModalPanel", _flat(_alpha(PANEL, 0.96), GOLD_BRIGHT, 2, 6, 16, 16))

	# The reserve trays. This plate is what stops pewter piece art from
	# disappearing against the wood.
	t.set_stylebox("panel", "ScrollContainer",
		_flat(_alpha(PANEL_DEEP, 0.55), _alpha(GOLD, 0.50), 1, 4, 6, 6))

	for bar in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", bar, _flat(_alpha(PANEL_DEEP, 0.50), Color(0, 0, 0, 0), 0, 3, 3, 3))
		t.set_stylebox("scroll_focus", bar, _flat(_alpha(PANEL_DEEP, 0.50), Color(0, 0, 0, 0), 0, 3, 3, 3))
		t.set_stylebox("grabber", bar, _flat(BRONZE_LIT, Color(0, 0, 0, 0), 0, 3, 3, 3))
		t.set_stylebox("grabber_highlight", bar, _flat(BRONZE_HI, Color(0, 0, 0, 0), 0, 3, 3, 3))
		t.set_stylebox("grabber_pressed", bar, _flat(GOLD_BRIGHT, Color(0, 0, 0, 0), 0, 3, 3, 3))

	# ---------- Tooltips ----------
	t.set_stylebox("panel", "TooltipPanel", _flat(_alpha(INK, 0.95), GOLD, 1, 4, 8, 8))
	t.set_font_size("font_size", "TooltipLabel", 12)
	t.set_color("font_color", "TooltipLabel", CREAM)
	t.set_constant("outline_size", "TooltipLabel", 0)

	# ---------- Container rhythm ----------
	# BoxContainer covers both VBoxContainer and HBoxContainer by inheritance.
	t.set_constant("separation", "BoxContainer", 10)
	t.set_constant("h_separation", "GridContainer", 10)
	t.set_constant("v_separation", "GridContainer", 10)
	t.set_constant("margin_left", "MarginContainer", 20)
	t.set_constant("margin_top", "MarginContainer", 20)
	t.set_constant("margin_right", "MarginContainer", 20)
	t.set_constant("margin_bottom", "MarginContainer", 20)

	# ---------- Custom types read by _draw() ----------
	# get_theme_color() errors and returns black on a missing key, so every name
	# looked up in highlight_layer.gd / chessboard_display.gd must exist here.
	t.set_color("scrim", "Modal", Color(0, 0, 0, 0.58))

	t.set_color("tile_light", "Chessboard", TILE_LIGHT)
	t.set_color("tile_dark", "Chessboard", TILE_DARK)
	# The highlight colours are gameplay signals, not chrome -- carried over
	# unchanged, but now tunable from one place.
	t.set_color("select_own", "Chessboard", Color(0, 1, 0, 0.30))
	t.set_color("select_preview", "Chessboard", Color(1, 0.7, 0.1, 0.30))
	t.set_color("move", "Chessboard", Color(0, 0.5, 1, 0.5))
	# Deeper than the old pale cyan/yellow. Both of these are drawn on a light
	# ivory square now, where the pale versions measured 1.06:1 and 1.13:1 --
	# the conditional ring in particular was a thin arc and simply vanished.
	# These sit mid-luminance so they read on ivory AND walnut (~2.5:1 on each).
	t.set_color("move_conditional", "Chessboard", Color(0.195, 0.574, 0.650, 0.95))
	t.set_color("capture_hint", "Chessboard", Color(1, 0.2, 0.1, 0.5))
	t.set_color("shoot", "Chessboard", Color(1, 0, 0, 0.5))
	t.set_color("friendly_fire", "Chessboard", Color(1, 0.65, 0, 0.6))
	t.set_color("promote", "Chessboard", Color(0.600, 0.525, 0.150, 0.95))
	t.set_color("convert", "Chessboard", Color(0.7, 0.2, 0.9, 0.5))
	t.set_color("cannon", "Chessboard", Color(1, 0.5, 0, 0.5))
	# Two-pass ring: a dark pass under a light one, so the marker survives on
	# both tile colours.
	t.set_color("ring", "Chessboard", _alpha(CREAM, 0.90))
	t.set_color("ring_shadow", "Chessboard", _alpha(INK, 0.80))

	var err := ResourceSaver.save(t, OUT_PATH)
	if err != OK:
		push_error("Theme save failed: %d" % err)
		quit(1)
		return
	print("Wrote ", OUT_PATH)
	quit(0)
