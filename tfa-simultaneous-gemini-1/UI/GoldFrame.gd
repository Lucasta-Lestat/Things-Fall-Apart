# =====================
# UI/GoldFrame.gd - The dark, gold-bordered frame the HUD panels share (Town
# Services, Camp, the game log and its button). One place for the look, so a
# new panel matches the others instead of picking its own colours.
#   const GoldFrame = preload("res://UI/GoldFrame.gd")
#   add_theme_stylebox_override("panel", GoldFrame.panel_style())
# =====================

extends RefCounted

const BG_COLOR := Color(0.10, 0.12, 0.16, 0.92)
const BORDER_COLOR := Color(0.6, 0.45, 0.2, 1.0)
# Panel headers ("Town Services", "Camp").
const HEADER_COLOR := Color(0.85, 0.75, 0.4)
# Secondary text on the frame (the Camp panel's day line).
const MUTED_COLOR := Color(0.75, 0.68, 0.45)

## The panel background: dark fill, 1 px gold border, 4 px corners.
static func panel_style() -> StyleBoxFlat:
	var bg := StyleBoxFlat.new()
	bg.bg_color = BG_COLOR
	bg.set_corner_radius_all(4)
	bg.set_border_width_all(1)
	bg.border_color = BORDER_COLOR
	return bg

## Button states on the same frame: the border brightens to the header gold
## when hovered or pressed (a toggled-on button stays lit).
static func apply_to_button(button: Button) -> void:
	var normal := panel_style()
	normal.set_content_margin_all(4)
	normal.content_margin_left = 8
	normal.content_margin_right = 8
	var lit := normal.duplicate() as StyleBoxFlat
	lit.border_color = HEADER_COLOR
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", lit)
	button.add_theme_stylebox_override("pressed", lit)
	button.add_theme_stylebox_override("hover_pressed", lit)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(c, HEADER_COLOR)
	button.add_theme_font_size_override("font_size", 13)
