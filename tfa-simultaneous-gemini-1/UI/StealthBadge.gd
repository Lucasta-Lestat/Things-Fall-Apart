# =====================
# UI/StealthBadge.gd - The persistent STEALTH badge on Game.hud_status. Shown
# while stealth mode is on (C), except on the world map and in downtime, where
# nobody sneaks. Like the rest of the status strip it ignores the Tab HUD
# toggle. Hover it for what sneaking does.
# =====================

extends PanelContainer

const TEXT_COLOR := Color(0.55, 0.8, 1.0)

var _game: Node = null

func _init() -> void:
	name = "StealthBadge"
	# PASS (not IGNORE) so the tooltip shows; HudStatusBar.add_widget keeps it.
	mouse_filter = Control.MOUSE_FILTER_PASS
	visible = false

func _ready() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.08, 0.15, 0.75)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	add_theme_stylebox_override("panel", sb)

	var label := Label.new()
	label.text = "STEALTH"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", TEXT_COLOR)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 5)
	add_child(label)

	tooltip_text = ("Sneaking (C to stop): footsteps %d%% as loud, %d%% walking pace.\n"
		+ "Onlookers notice you only inside their sight cone, even up close.\n"
		+ "Sight cones show what onlookers see; pink marks raised walkways they can see onto.\n"
		+ "An eye over a party member means an onlooker you can see has them in view.\n"
		+ "Relaxed onlookers who see you sneaking become wary.") % [
			roundi(ProceduralCharacter.SNEAK_NOISE_MULT * 100.0), roundi(ProceduralCharacter.SNEAK_SPEED_MULT * 100.0)]

	_game = get_node_or_null("/root/Game")
	if _game:
		for sig in ["stealth_mode_changed", "map_loaded", "downtime_mode_changed"]:
			if _game.has_signal(sig):
				_game.connect(sig, _on_state_changed)
	_refresh()

func _on_state_changed(_arg = null) -> void:
	_refresh()

func _refresh() -> void:
	if _game == null or not is_instance_valid(_game):
		visible = false
		return
	visible = bool(_game.stealth_mode) \
		and not _game.current_map_data.get("is_world_map", false) \
		and not _game.downtime_mode_active
