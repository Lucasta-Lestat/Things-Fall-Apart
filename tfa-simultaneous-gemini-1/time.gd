extends Label

@export var show_seconds: bool = false
@export var use_12_hour_format: bool = false
@export var show_date: bool = true

func _ready() -> void:
	TimeManager.connect("time_updated", _on_time_updated)
	TimeManager.connect("date_changed", _on_date_changed)

	# Pin to top-left with a small margin
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 0.0
	offset_left = 16
	offset_top = 16
	grow_horizontal = Control.GROW_DIRECTION_END
	grow_vertical = Control.GROW_DIRECTION_END

	var panel := _find_party_panel()
	if panel:
		visible = panel.panel_visible
		panel.connect("panel_visibility_changed", _on_party_panel_toggled)

	update_display()

func _find_party_panel() -> Node:
	var parent := get_parent()
	if parent and parent.has_node("PartySidePanel"):
		return parent.get_node("PartySidePanel")
	return null

func _on_party_panel_toggled(now_visible: bool) -> void:
	visible = now_visible

func _on_time_updated(_hour, _minute, _second):
	update_display()

func _on_date_changed(_day, _month, _year):
	update_display()

func update_display():
	var time_str = TimeManager.get_time_string(use_12_hour_format)
	var date_str = TimeManager.get_date_string()
	if show_date:
		self.text = "%s\n%s" % [date_str, time_str]
	else:
		self.text = time_str
